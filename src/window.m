// user32 windows on Cocoa: the application, the game window, the message queue, and the display
// metrics the game sizes its swapchain from.
#include "user32.h"

Window *g_window;
void (*g_window_resized)(void *hwnd, int w, int h, double scale);

#define MAKELPARAM(low, high) ((LPARAM)(uint16_t)(low) | (LPARAM)(uint16_t)(high) << 16)

static LRESULT send_message(Window *w, UINT message, WPARAM wparam, LPARAM lparam) {
    if (!w || !w->proc) return 0;
    TRACE("send %p msg=%#x wparam=%#lx lparam=%#lx", (void *)w, message, (unsigned long)wparam, (long)lparam);
    return w->proc(w, message, wparam, lparam);
}

NSSize client_size_in_pixels(Window *w) {
    return [w->ns.contentView convertRectToBacking:w->ns.contentView.bounds].size;
}

static LPARAM size_lparam(Window *w) {
    NSSize size = client_size_in_pixels(w);
    return MAKELPARAM(size.width, size.height);
}

// ---------------------------------------------------------------- message queue (main thread only)
#define QUEUE_CAPACITY 4096
static MSG g_queue[QUEUE_CAPACITY];
static int g_queue_length;

void post_message(Window *w, UINT message, WPARAM wparam, LPARAM lparam) {
    MSG *last = g_queue_length ? &g_queue[g_queue_length - 1] : NULL;
    if (message == WM_MOUSEMOVE && last && last->message == WM_MOUSEMOVE) { // coalesce, as Windows does
        last->wParam = wparam;
        last->lParam = lparam;
        return;
    }
    if (g_queue_length == QUEUE_CAPACITY) { // drop the oldest
        memmove(g_queue, g_queue + 1, (QUEUE_CAPACITY - 1) * sizeof *g_queue);
        g_queue_length--;
    }
    g_queue[g_queue_length++] = (MSG){
        .hwnd = w,
        .message = message,
        .wParam = wparam,
        .lParam = lparam,
        .time = (DWORD)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000),
    };
}

// ---------------------------------------------------------------- Cocoa
// A borderless window refuses key status by default, and AppKit moves windows out from under the menu bar
// and the camera housing; fullscreen needs both overridden.
@interface GameWindow : NSWindow
@property(assign) BOOL fullscreen;
@end

@implementation GameWindow
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (BOOL)canBecomeMainWindow {
    return YES;
}
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen {
    return self.fullscreen ? frame : [super constrainFrameRect:frame toScreen:screen];
}
@end

@interface WindowDelegate : NSObject <NSWindowDelegate>
@property(assign) Window *window;
@end

@implementation WindowDelegate
- (void)windowDidBecomeKey:(NSNotification *)notification {
    post_message(self.window, WM_ACTIVATEAPP, true, 0);
    post_message(self.window, WM_ACTIVATE, WA_ACTIVE, 0);
    post_message(self.window, WM_SETFOCUS, 0, 0);
}

- (void)windowDidResignKey:(NSNotification *)notification {
    input_release_all();
    post_message(self.window, WM_ACTIVATE, WA_INACTIVE, 0);
    post_message(self.window, WM_KILLFOCUS, 0, 0);
    post_message(self.window, WM_ACTIVATEAPP, false, 0);
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    post_message(self.window, WM_CLOSE, 0, 0); // the game decides; it posts WM_QUIT via DefWindowProc
    return NO;
}

- (void)windowDidResize:(NSNotification *)notification {
    NSSize size = client_size_in_pixels(self.window);
    if (g_window_resized) g_window_resized(self.window, size.width, size.height, self.window->ns.backingScaleFactor);
    post_message(self.window, WM_SIZE, 0, size_lparam(self.window));
}
@end

void cocoa_init(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        [NSApp activateIgnoringOtherApps:YES];
        // A game: no App Nap, no automatic termination, timers and threads scheduled for low latency.
        static id activity;
        activity =
            [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                                                         reason:@"Running the game"];
    }
}

void cocoa_pump(void) {
    @autoreleasepool {
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                           untilDate:NSDate.distantPast
                                              inMode:NSDefaultRunLoopMode
                                             dequeue:YES]))
            if (!handle_input_event(event)) [NSApp sendEvent:event];
    }
}

// Fullscreen is a borderless window over the whole screen (camera housing included) with the Dock and menu bar
// hidden. Unlike macOS' own fullscreen it switches instantly, in the same Space.
static NSRect g_windowed_frame;
static NSWindowStyleMask g_windowed_style;

static void apply_fullscreen(Window *w, bool fullscreen) {
    GameWindow *ns = (GameWindow *)w->ns;
    if (ns.fullscreen == fullscreen) return;
    if (fullscreen) {
        g_windowed_frame = ns.frame;
        g_windowed_style = ns.styleMask;
        NSScreen *screen = ns.screen ?: NSScreen.mainScreen;
        ns.fullscreen = YES;
        NSApp.presentationOptions = NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
        ns.styleMask = NSWindowStyleMaskBorderless;
        [ns setFrame:screen.frame display:YES animate:NO];
    } else {
        ns.fullscreen = NO;
        NSApp.presentationOptions = NSApplicationPresentationDefault;
        ns.styleMask = g_windowed_style;
        [ns setFrame:g_windowed_frame display:YES animate:NO];
    }
    [ns makeKeyAndOrderFront:nil];
}

void cocoa_window_set_fullscreen(void *hwnd, bool fullscreen) {
    Window *w = hwnd ? hwnd : g_window;
    if (!w) return;
    if ([NSThread isMainThread])
        apply_fullscreen(w, fullscreen);
    else
        dispatch_async(dispatch_get_main_queue(), ^{ apply_fullscreen(w, fullscreen); });
}

bool cocoa_window_is_fullscreen(void *hwnd) {
    Window *w = hwnd ? hwnd : g_window;
    return w && ((GameWindow *)w->ns).fullscreen;
}

void cocoa_window_size(void *hwnd, int *w, int *h) {
    NSSize size = client_size_in_pixels(hwnd ? hwnd : g_window);
    *w = size.width;
    *h = size.height;
}

void *cocoa_window_view(void *hwnd, double *scale) {
    Window *w = hwnd ? hwnd : g_window;
    if (scale) *scale = w->ns.backingScaleFactor;
    return (__bridge void *)w->ns.contentView;
}

void cocoa_set_title(void *hwnd, const char *title) {
    Window *w = hwnd ? hwnd : g_window;
    NSString *text = @(title);
    dispatch_async(dispatch_get_main_queue(), ^{ w->ns.title = text; });
}

// ---------------------------------------------------------------- window classes
typedef struct {
    WCHAR name[64];
    WNDPROC proc;
} WindowClass;

#define FIRST_CLASS_ATOM 0xC000
static WindowClass g_classes[32];
static int g_class_count;

static bool is_atom(const WCHAR *name) { return (uintptr_t)name <= 0xffff; } // MAKEINTATOM

static bool wide_equal(const WCHAR *a, const WCHAR *b) {
    while (*a && *a == *b) a++, b++;
    return *a == *b;
}

SHIM(WORD, RegisterClassExW, const WNDCLASSEXW *wc) {
    WindowClass *c = &g_classes[g_class_count++];
    c->proc = wc->lpfnWndProc;
    if (!is_atom(wc->lpszClassName)) {
        size_t len = wlen(wc->lpszClassName), max = sizeof c->name / sizeof(WCHAR) - 1;
        memcpy(c->name, wc->lpszClassName, (len < max ? len : max) * sizeof(WCHAR));
    }
    return FIRST_CLASS_ATOM + g_class_count; // atom of class i is FIRST_CLASS_ATOM + i + 1
}

static WNDPROC find_class_proc(const WCHAR *name) {
    for (int i = 0; i < g_class_count; i++)
        if (is_atom(name) ? (uintptr_t)name == FIRST_CLASS_ATOM + i + 1u : wide_equal(g_classes[i].name, name))
            return g_classes[i].proc;
    return NULL;
}

// ---------------------------------------------------------------- windows
static NSWindow *create_ns_window(const char *title, int pixel_width, int pixel_height, Window *owner) {
    CGFloat scale = NSScreen.mainScreen.backingScaleFactor; // the window opens on the main screen
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                              NSWindowStyleMaskResizable;
    NSWindow *ns = [[GameWindow alloc] initWithContentRect:NSMakeRect(0, 0, pixel_width / scale, pixel_height / scale)
                                                 styleMask:style
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    ns.title = @(title);
    ns.releasedWhenClosed = NO;
    ns.acceptsMouseMovedEvents = YES;
    ns.backgroundColor = NSColor.blackColor; // shown until the first frame is presented
    ns.contentView.wantsLayer = YES;
    ns.contentView.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);

    // NSWindow.delegate is weak: keep delegates alive, or close/focus/resize notifications never arrive.
    static NSMutableArray *delegates;
    if (!delegates) delegates = [NSMutableArray new];
    WindowDelegate *delegate = [WindowDelegate new];
    delegate.window = owner;
    [delegates addObject:delegate];
    ns.delegate = delegate;
    [ns center];
    return ns;
}

SHIM(HWND, CreateWindowExW, DWORD ex_style, const WCHAR *class_name, const WCHAR *title, DWORD style, int x, int y,
     int width, int height, HWND parent, HANDLE menu, HANDLE instance, void *param) {
    Window *w = calloc(1, sizeof *w);
    w->proc = find_class_proc(class_name);
    if (width <= 0) width = 1280; // also CW_USEDEFAULT (INT_MIN)
    if (height <= 0) height = 720;
    char *utf8_title = title ? w2u(title) : strdup("");
    LOG("CreateWindowExW(\"%s\", %dx%d)", utf8_title, width, height);
    @autoreleasepool {
        w->ns = create_ns_window(utf8_title, width, height, w);
    }
    free(utf8_title);
    g_window = w;
    w->longs[-GWL_STYLE] = style;
    w->longs[-GWL_EXSTYLE] = ex_style;

    CREATESTRUCTW create = {
        .lpCreateParams = param,
        .hInstance = instance,
        .hMenu = menu,
        .hwndParent = parent,
        .cy = height,
        .cx = width,
        .y = y,
        .x = x,
        .style = (LONG)style,
        .lpszName = title,
        .lpszClass = class_name,
        .dwExStyle = ex_style,
    };
    send_message(w, WM_NCCREATE, 0, (LPARAM)&create);
    send_message(w, WM_CREATE, 0, (LPARAM)&create);
    if (style & WS_VISIBLE) {
        [w->ns makeKeyAndOrderFront:nil];
        cocoa_pump();
    }
    // The game runs fullscreen unless LOADER_WINDOWED is set; the switch is instant, so the size the game
    // reads next is already the final one.
    if (!getenv("LOADER_WINDOWED")) {
        cocoa_window_set_fullscreen(w, true);
        cocoa_pump();
        input_hide_cursor_until_game_decides();
    }
    LOG("window id %ld (screencapture -l <id> saves it)", (long)w->ns.windowNumber);
    return w;
}

SHIM(WBOOL, ShowWindow, Window *w, int command) {
    if (!w) return false;
    LOG("ShowWindow(%d)", command);
    if (command)
        [w->ns makeKeyAndOrderFront:nil];
    else
        [w->ns orderOut:nil];
    cocoa_pump();
    send_message(w, WM_SHOWWINDOW, command != 0, 0);
    send_message(w, WM_SIZE, 0, size_lparam(w));
    return true;
}

SHIM(WBOOL, UpdateWindow, Window *w) { return true; }

SHIM(WBOOL, SetWindowTextW, Window *w, const WCHAR *text) {
    if (!w) return false;
    char *utf8 = w2u(text);
    w->ns.title = utf8 ? @(utf8) : @"";
    free(utf8);
    return true;
}

SHIM(WBOOL, SetWindowPos, Window *w, HWND insert_after, int x, int y, int width, int height, UINT flags) {
    if (!w) return false;
    LOG("SetWindowPos(%d,%d %dx%d flags 0x%x)", x, y, width, height, flags);
    if (!(flags & SWP_NOSIZE) && width > 0 && height > 0) {
        CGFloat scale = w->ns.backingScaleFactor;
        [w->ns setContentSize:NSMakeSize(width / scale, height / scale)];
    }
    return true;
}

static bool valid_long_index(int index) { return index < 0 && index > -32; }

SHIM(intptr_t, SetWindowLongPtrW, Window *w, int index, intptr_t value) {
    if (!w || !valid_long_index(index)) return 0;
    // The game subclasses its window and then calls the previous window procedure itself.
    intptr_t previous = index == GWLP_WNDPROC ? (intptr_t)w->proc : w->longs[-index];
    w->longs[-index] = value;
    if (index == GWLP_WNDPROC) w->proc = (WNDPROC)value;
    return previous;
}

SHIM(LONG, SetWindowLongW, Window *w, int index, LONG value) {
    if (!w || !valid_long_index(index)) return 0;
    LOG("SetWindowLong(%d, 0x%x)", index, (unsigned)value);
    LONG previous = (LONG)w->longs[-index];
    w->longs[-index] = value;
    return previous;
}

SHIM(LONG, GetWindowLongW, Window *w, int index) { return w && valid_long_index(index) ? (LONG)w->longs[-index] : 0; }

// ---------------------------------------------------------------- geometry (pixels; screen origin at top left)
static RECT client_rect(Window *w) {
    NSSize size = client_size_in_pixels(w);
    return (RECT){0, 0, size.width, size.height};
}

SHIM(WBOOL, GetClientRect, Window *w, RECT *rect) {
    if (!w) return false; // the game asks with a NULL window while switching modes
    *rect = client_rect(w);
    return true;
}

SHIM(WBOOL, GetWindowRect, Window *w, RECT *rect) {
    if (!w) return false;
    FIXME("GetWindowRect: returns the client rectangle");
    *rect = client_rect(w);
    return true;
}

SHIM(WBOOL, AdjustWindowRect, RECT *rect, DWORD style, WBOOL menu) {
    FIXME("AdjustWindowRect: no frame is added");
    return true;
}

static NSPoint client_origin_on_screen(Window *w) {
    NSView *view = w->ns.contentView;
    NSRect r = [w->ns convertRectToScreen:[view convertRect:view.bounds toView:nil]];
    CGFloat scale = w->ns.backingScaleFactor, screen_height = NSScreen.screens[0].frame.size.height;
    return NSMakePoint(r.origin.x * scale, (screen_height - (r.origin.y + r.size.height)) * scale);
}

SHIM(WBOOL, ClientToScreen, Window *w, POINT *p) {
    if (!(w = w ? w : g_window)) return false;
    NSPoint origin = client_origin_on_screen(w);
    p->x += origin.x;
    p->y += origin.y;
    return true;
}

SHIM(WBOOL, ScreenToClient, Window *w, POINT *p) {
    if (!(w = w ? w : g_window)) return false;
    NSPoint origin = client_origin_on_screen(w);
    p->x -= origin.x;
    p->y -= origin.y;
    return true;
}

SHIM(WBOOL, ValidateRect, Window *w, const RECT *rect) { return true; }
SHIM(HWND, GetActiveWindow, void) { return g_window; }
SHIM(HWND, WindowFromPoint, POINT point) { return g_window; }

// ---------------------------------------------------------------- display and monitors
// The "display" the game sees. By default it is the window's client area, so the game's
// fullscreen-sized swapchain matches the window. LOADER_DISPLAY=native reports the real pixel
// mode of the screen the window is on.
static CGDisplayModeRef current_display_mode(void) {
    NSScreen *screen = g_window && g_window->ns.screen ? g_window->ns.screen : NSScreen.mainScreen;
    return CGDisplayCopyDisplayMode([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
}

static NSSize display_size(void) {
    const char *mode = getenv("LOADER_DISPLAY");
    if (g_window && !(mode && !strcmp(mode, "native"))) return client_size_in_pixels(g_window);
    CGDisplayModeRef m = current_display_mode();
    NSSize size = NSMakeSize(CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m));
    CGDisplayModeRelease(m);
    return size;
}

static DWORD display_refresh_rate(void) {
    CGDisplayModeRef m = current_display_mode();
    double hz = CGDisplayModeGetRefreshRate(m);
    CGDisplayModeRelease(m);
    return hz > 0 ? (DWORD)(hz + 0.5) : 60;
}

static RECT display_rect(void) {
    NSSize size = display_size();
    return (RECT){0, 0, size.width, size.height};
}

#define PRIMARY_MONITOR ((HANDLE)1)

SHIM(int, GetSystemMetrics, int index) {
    NSSize size = display_size();
    switch (index) {
    case SM_CXSCREEN:
    case SM_CXFULLSCREEN:
    case SM_CXVIRTUALSCREEN: return size.width;
    case SM_CYSCREEN:
    case SM_CYFULLSCREEN:
    case SM_CYVIRTUALSCREEN: return size.height;
    case SM_CMONITORS: return 1;
    default: return 0;
    }
}

typedef WINAPI WBOOL (*MONITORENUMPROC)(HANDLE monitor, HANDLE dc, RECT *rect, LPARAM data);

SHIM(WBOOL, EnumDisplayMonitors, HANDLE dc, const RECT *clip, MONITORENUMPROC callback, LPARAM data) {
    RECT rect = display_rect();
    callback(PRIMARY_MONITOR, NULL, &rect, data);
    return true;
}

SHIM(HANDLE, MonitorFromWindow, Window *w, DWORD flags) { return PRIMARY_MONITOR; }

static void fill_monitor_info(MONITORINFOEX *info, bool wide) {
    info->rcMonitor = info->rcWork = display_rect();
    info->dwFlags = MONITORINFOF_PRIMARY;
    if (info->cbSize < sizeof(MONITORINFOEX) - sizeof info->szDeviceW + sizeof info->szDeviceA) return;
    if (wide) {
        WCHAR *name = u2w("\\\\.\\DISPLAY1");
        memcpy(info->szDeviceW, name, (wlen(name) + 1) * sizeof(WCHAR));
        free(name);
    } else {
        strlcpy(info->szDeviceA, "\\\\.\\DISPLAY1", sizeof info->szDeviceA);
    }
}

SHIM(WBOOL, GetMonitorInfoW, HANDLE monitor, MONITORINFOEX *info) {
    fill_monitor_info(info, true);
    return true;
}

SHIM(WBOOL, GetMonitorInfoA, HANDLE monitor, MONITORINFOEX *info) {
    fill_monitor_info(info, false);
    return true;
}

// One display mode: the current one.
SHIM(WBOOL, EnumDisplaySettingsA, const char *device, DWORD mode, DEVMODEA *dm) {
    if (mode != ENUM_CURRENT_SETTINGS && mode != ENUM_REGISTRY_SETTINGS && mode != 0) return false;
    NSSize size = display_size();
    dm->dmFields = DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
    dm->dmBitsPerPel = 32;
    dm->dmPelsWidth = size.width;
    dm->dmPelsHeight = size.height;
    dm->dmDisplayFrequency = display_refresh_rate();
    return true;
}

SHIM(WBOOL, SystemParametersInfoW, UINT action, UINT param, void *value, UINT flags) {
    FIXME("SystemParametersInfoW(%#x): not supported", action);
    return false;
}

// ---------------------------------------------------------------- messages
SHIM(WBOOL, PeekMessageW, MSG *out, HWND hwnd, UINT first, UINT last, UINT flags) {
    cocoa_pump();
    for (int i = 0; i < g_queue_length; i++) {
        MSG *m = &g_queue[i];
        if (hwnd && hwnd != INVALID_HANDLE_VALUE && m->hwnd != hwnd) continue;
        if ((first || last) && (m->message < first || m->message > last)) continue;
        *out = *m;
        if (flags & PM_REMOVE) {
            memmove(m, m + 1, (g_queue_length - i - 1) * sizeof *m);
            g_queue_length--;
        }
        return true;
    }
    return false;
}

// WM_CHAR is posted directly from the key events (see input.m).
SHIM(WBOOL, TranslateMessage, const MSG *message) { return false; }

SHIM(LRESULT, DispatchMessageW, const MSG *m) { return send_message(m->hwnd, m->message, m->wParam, m->lParam); }

SHIM(LRESULT, DefWindowProcW, Window *w, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_CLOSE) post_message(w, WM_QUIT, 0, 0); // DestroyWindow + PostQuitMessage, in short
    return 0;
}

SHIM(LPARAM, GetMessageExtraInfo, void) { return 0; }

SHIM(int, MessageBoxW, HWND owner, const WCHAR *text, const WCHAR *caption, UINT type) {
    char *t = w2u(text), *c = w2u(caption);
    LOG("MessageBox [%s]: %s", c, t);
    free(t);
    free(c);
    return 1; // IDOK
}

SHIM(int, MessageBoxA, HWND owner, const char *text, const char *caption, UINT type) {
    LOG("MessageBox [%s]: %s", caption, text);
    return 1; // IDOK
}

// USER32 shims backed by Cocoa. HWND is a pointer to a Win struct wrapping an NSWindow.
#import <Cocoa/Cocoa.h>
#include "shim.h"

#define WM_CREATE 0x0001
#define WM_SIZE 0x0005
#define WM_ACTIVATE 0x0006
#define WM_SETFOCUS 0x0007
#define WM_CLOSE 0x0010
#define WM_QUIT 0x0012
#define WM_SHOWWINDOW 0x0018

typedef WINAPI intptr_t (*WndProc)(void *hwnd, unsigned msg, uintptr_t wp, intptr_t lp);

typedef struct Win {
    NSWindow *ns;
    WndProc proc;
    intptr_t longs[32];  // index = -idx for negative GWL_* values
} Win;

typedef struct { void *hwnd; uint32_t msg, _pad; uintptr_t wp; intptr_t lp; DWORD time; int32_t x, y; DWORD priv; } MSG;

static Win *g_last_win;
void (*g_window_resized)(void *hwnd, int w, int h, double scale);

// Posted-message queue (main thread only). Consecutive WM_MOUSEMOVEs are coalesced like Windows does.
#define QCAP 4096
static MSG g_queue[QCAP];
static int g_qlen;

static void post(Win *w, unsigned msg, uintptr_t wp, intptr_t lp) {
    if (msg == 0x0200 && g_qlen && g_queue[g_qlen - 1].msg == 0x0200) {
        g_queue[g_qlen - 1].wp = wp;
        g_queue[g_qlen - 1].lp = lp;
        return;
    }
    if (g_qlen == QCAP) { memmove(g_queue, g_queue + 1, (QCAP - 1) * sizeof *g_queue); g_qlen--; }
    g_queue[g_qlen++] = (MSG){.hwnd = w, .msg = msg, .wp = wp, .lp = lp,
                              .time = (DWORD)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000)};
}
static bool input_event(NSEvent *e);

static intptr_t win_send(Win *w, unsigned msg, uintptr_t wp, intptr_t lp) {
    if (!w || !w->proc) return 0;
    TRACE("send hwnd=%p msg=%#x wp=%#lx lp=%#lx", (void *)w, msg, (unsigned long)wp, (long)lp);
    return w->proc(w, msg, wp, lp);
}

@interface WinDelegate : NSObject <NSWindowDelegate>
@property(assign) Win *win;
@end
@implementation WinDelegate
- (void)windowDidBecomeKey:(NSNotification *)n {
    post(self.win, 0x001C /* WM_ACTIVATEAPP */, 1, 0);
    post(self.win, WM_ACTIVATE, 1 /* WA_ACTIVE */, 0);
    post(self.win, WM_SETFOCUS, 0, 0);
}
- (void)windowDidResignKey:(NSNotification *)n {
    post(self.win, WM_ACTIVATE, 0, 0);
    post(self.win, 0x0008 /* WM_KILLFOCUS */, 0, 0);
    post(self.win, 0x001C /* WM_ACTIVATEAPP */, 0, 0);
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    post(self.win, WM_CLOSE, 0, 0);
    return NO;
}
- (void)windowDidResize:(NSNotification *)n {
    NSRect r = [self.win->ns.contentView convertRectToBacking:self.win->ns.contentView.bounds];
    if (g_window_resized) g_window_resized(self.win, (int)r.size.width, (int)r.size.height, self.win->ns.backingScaleFactor);
    post(self.win, WM_SIZE, 0, ((intptr_t)r.size.height << 16) | (intptr_t)r.size.width);
}
@end

void cocoa_init(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

void cocoa_pump(void) {
    @autoreleasepool {
        NSEvent *e;
        while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
                                          inMode:NSDefaultRunLoopMode dequeue:YES]))
            if (!input_event(e)) [NSApp sendEvent:e];
    }
}

// ---- classes
typedef struct { WCHAR name[64]; WndProc proc; } Cls;
static Cls g_classes[32];
static int g_nclasses;

static int wstreq(const WCHAR *a, const WCHAR *b) {
    while (*a && *a == *b) a++, b++;
    return *a == *b;
}

SHIM(uint16_t, RegisterClassExW, const uint8_t *wc) {
    Cls *c = &g_classes[g_nclasses++];
    c->proc = *(WndProc *)(wc + 8);
    const WCHAR *n = *(const WCHAR **)(wc + 64);
    if ((uintptr_t)n > 0xffff) memcpy(c->name, n, (wlen(n) < 63 ? wlen(n) + 1 : 63) * 2);
    char *u = w2u(c->name);
    LOG("RegisterClassExW(%s) proc=%p", u, (void *)c->proc);
    free(u);
    return 0xC000 + g_nclasses;
}

SHIM(void *, CreateWindowExW, DWORD ex, const WCHAR *cls, const WCHAR *title, DWORD style, int x, int y, int w, int h,
     void *parent, void *menu, void *inst, void *param) {
    (void)parent; (void)menu;
    Win *win = calloc(1, sizeof *win);
    for (int i = 0; i < g_nclasses; i++)
        if (((uintptr_t)cls <= 0xffff && (uintptr_t)cls == 0xC001u + i) ||
            ((uintptr_t)cls > 0xffff && wstreq(g_classes[i].name, cls)))
            win->proc = g_classes[i].proc;
    if (w == (int)0x80000000 || w <= 0) w = 1280;
    if (h == (int)0x80000000 || h <= 0) h = 720;
    char *t = title ? w2u(title) : strdup("");
    LOG("CreateWindowExW(\"%s\", %dx%d, style=%#x ex=%#x)", t, w, h, style, ex);
    @autoreleasepool {
        CGFloat scale = NSScreen.mainScreen.backingScaleFactor;  // the window opens on the main screen
        NSRect r = NSMakeRect(100, 100, w / scale, h / scale);
        win->ns = [[NSWindow alloc] initWithContentRect:r
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
        win->ns.title = [NSString stringWithUTF8String:t];
        win->ns.releasedWhenClosed = NO;
        win->ns.acceptsMouseMovedEvents = YES;
        win->ns.backgroundColor = NSColor.blackColor;  // shown until the first Present
        win->ns.contentView.wantsLayer = YES;
        win->ns.contentView.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        // NSWindow.delegate is weak: keep the delegate alive ourselves, or close/focus/resize
        // notifications silently never arrive.
        static NSMutableArray *delegates;
        if (!delegates) delegates = [NSMutableArray new];
        WinDelegate *d = [WinDelegate new];
        d.win = win;
        [delegates addObject:d];
        win->ns.delegate = d;
        [win->ns center];
    }
    free(t);
    g_last_win = win;
    win->longs[16] = style;
    win->longs[20] = ex;
    uint8_t cs[80] = {0};
    *(void **)cs = param;
    *(void **)(cs + 8) = inst;
    *(int *)(cs + 32) = h; *(int *)(cs + 36) = w; *(int *)(cs + 40) = y; *(int *)(cs + 44) = x;
    *(int32_t *)(cs + 48) = style;
    *(const WCHAR **)(cs + 56) = title;
    *(const WCHAR **)(cs + 64) = cls;
    *(DWORD *)(cs + 72) = ex;
    win_send(win, 0x0081 /* WM_NCCREATE */, 0, (intptr_t)cs);
    win_send(win, WM_CREATE, 0, (intptr_t)cs);
    if (style & 0x10000000 /* WS_VISIBLE */) {
        [win->ns makeKeyAndOrderFront:nil];
        cocoa_pump();
    }
    return win;
}

SHIM(WBOOL, ShowWindow, Win *w, int cmd) {
    if (!w) { FIXME("ShowWindow(NULL hwnd)"); return 0; }
    LOG("ShowWindow(%p, %d)", (void *)w, cmd);
    if (cmd) [w->ns makeKeyAndOrderFront:nil];
    else [w->ns orderOut:nil];
    cocoa_pump();
    NSRect r = [w->ns.contentView convertRectToBacking:w->ns.contentView.bounds];
    // Ask the window server (not just AppKit) whether our window is on screen.
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    bool onscreen = false;
    for (NSDictionary *d in (__bridge NSArray *)list)
        if ([d[(id)kCGWindowNumber] integerValue] == w->ns.windowNumber) onscreen = true;
    CFRelease(list);
    LOG("window #%ld visible=%d onscreen(window server)=%d backing=%.0fx%.0f", (long)w->ns.windowNumber,
        w->ns.isVisible, onscreen, r.size.width, r.size.height);
    win_send(w, WM_SHOWWINDOW, cmd != 0, 0);
    win_send(w, WM_SIZE, 0, ((intptr_t)r.size.height << 16) | (intptr_t)r.size.width);
    return 1;
}
SHIM(WBOOL, UpdateWindow, Win *w) { (void)w; return 1; }
SHIM(WBOOL, SetWindowTextW, Win *w, const WCHAR *t) {
    if (!w) { FIXME("SetWindowTextW(NULL hwnd)"); return 0; }
    char *u = w2u(t);
    w->ns.title = [NSString stringWithUTF8String:u];
    free(u);
    return 1;
}
SHIM(WBOOL, SetWindowPos, Win *w, void *after, int x, int y, int cx, int cy, unsigned fl) {
    if (!w) { FIXME("SetWindowPos(NULL hwnd)"); return 0; }
    (void)after; (void)x; (void)y;
    if (!(fl & 1) && cx > 0 && cy > 0) {
        CGFloat s = w->ns.backingScaleFactor;
        [w->ns setContentSize:NSMakeSize(cx / s, cy / s)];
    }
    return 1;
}
SHIM(intptr_t, SetWindowLongPtrW, Win *w, int idx, intptr_t v) {
    if (!w) { FIXME("SetWindowLongPtrW(NULL hwnd)"); return 0; }
    if (idx >= 0 || idx < -31) return 0;
    intptr_t old = idx == -4 ? (intptr_t)w->proc : w->longs[-idx];  // GWLP_WNDPROC: callers chain to the old proc
    w->longs[-idx] = v;
    if (idx == -4) w->proc = (WndProc)v;
    return old;
}
SHIM(int32_t, SetWindowLongW, Win *w, int idx, int32_t v) {
    if (!w) { FIXME("SetWindowLongW(NULL hwnd)"); return 0; }
    if (idx >= 0 || idx < -31) return 0;
    int32_t old = (int32_t)w->longs[-idx];
    w->longs[-idx] = v;
    return old;
}
SHIM(int32_t, GetWindowLongW, Win *w, int idx) {
    if (!w) { FIXME("GetWindowLongW(NULL hwnd)"); return 0; } return idx < 0 && idx >= -31 ? (int32_t)w->longs[-idx] : 0; }

static void put_rect(int32_t *r, NSRect b) {
    r[0] = 0; r[1] = 0; r[2] = (int32_t)b.size.width; r[3] = (int32_t)b.size.height;
}
SHIM(WBOOL, GetClientRect, Win *w, int32_t *r) {
    if (!w) { FIXME("GetClientRect(NULL hwnd)"); return 0; }
    put_rect(r, [w->ns.contentView convertRectToBacking:w->ns.contentView.bounds]);
    return 1;
}
SHIM(WBOOL, GetWindowRect, Win *w, int32_t *r) {
    if (!w) { FIXME("GetWindowRect(NULL hwnd)"); return 0; } FIXME("GetWindowRect: returns client rect");
    put_rect(r, [w->ns.contentView convertRectToBacking:w->ns.contentView.bounds]);
    return 1;
}
SHIM(WBOOL, AdjustWindowRect, int32_t *r, DWORD style, WBOOL menu) { FIXME("AdjustWindowRect(style=%#x): returns client rect unchanged", style); (void)r; (void)style; (void)menu; return 1; }
// Screen pixels: origin at the top-left of the main screen, in backing pixels.
static NSPoint client_origin_px(Win *w) {
    NSRect c = [w->ns convertRectToScreen:[w->ns.contentView convertRect:w->ns.contentView.bounds toView:nil]];
    CGFloat s = w->ns.backingScaleFactor, sh = NSScreen.screens[0].frame.size.height;
    return NSMakePoint(c.origin.x * s, (sh - (c.origin.y + c.size.height)) * s);
}
SHIM(WBOOL, ClientToScreen, Win *w, int32_t *p) {
    if (!w && !g_last_win) return 0;
    NSPoint o = client_origin_px(w ? w : g_last_win);
    p[0] += (int32_t)o.x; p[1] += (int32_t)o.y;
    return 1;
}
SHIM(WBOOL, ScreenToClient, Win *w, int32_t *p) {
    if (!w && !g_last_win) return 0;
    NSPoint o = client_origin_px(w ? w : g_last_win);
    p[0] -= (int32_t)o.x; p[1] -= (int32_t)o.y;
    return 1;
}
SHIM(WBOOL, ValidateRect, Win *w, void *r) { (void)w; (void)r; return 1; }

// The "display" the game sees. Default: the window's client area in backing pixels, so the game's
// fullscreen-sized swapchain matches the window. LOADER_DISPLAY=native: the real pixel mode of the
// screen the window is on.
static NSScreen *game_screen(void) {
    return g_last_win && g_last_win->ns.screen ? g_last_win->ns.screen : NSScreen.mainScreen;
}
static CGDisplayModeRef screen_mode(void) {
    CGDirectDisplayID id = [game_screen().deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    return CGDisplayCopyDisplayMode(id);
}
static NSSize screen_px(void) {
    const char *m = getenv("LOADER_DISPLAY");
    if (g_last_win && !(m && !strcmp(m, "native"))) {
        NSRect r = [g_last_win->ns.contentView convertRectToBacking:g_last_win->ns.contentView.bounds];
        return r.size;
    }
    CGDisplayModeRef mode = screen_mode();
    NSSize s = NSMakeSize(CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode));
    CGDisplayModeRelease(mode);
    return s;
}
static uint32_t screen_hz(void) {
    CGDisplayModeRef mode = screen_mode();
    double hz = CGDisplayModeGetRefreshRate(mode);
    CGDisplayModeRelease(mode);
    return hz > 0 ? (uint32_t)(hz + 0.5) : 60;
}
SHIM(int, GetSystemMetrics, int i) {
    NSSize s = screen_px();
    switch (i) {
    case 0: case 16: case 78: return (int)s.width;
    case 1: case 17: case 79: return (int)s.height;
    case 80: return 1;  // SM_CMONITORS
    default: return 0;
    }
}
typedef WINAPI WBOOL (*MonitorEnumProc)(void *, void *, int32_t *, intptr_t);
SHIM(WBOOL, EnumDisplayMonitors, void *dc, void *clip, MonitorEnumProc fn, intptr_t data) {
    (void)dc; (void)clip;
    NSSize s = screen_px();
    int32_t r[4] = {0, 0, (int32_t)s.width, (int32_t)s.height};
    fn((void *)1, NULL, r, data);
    return 1;
}
SHIM(void *, MonitorFromWindow, Win *w, DWORD fl) { (void)w; (void)fl; return (void *)1; }
static WBOOL monitor_info(uint8_t *mi, int wide) {
    NSSize s = screen_px();
    int32_t *r = (int32_t *)(mi + 4);
    r[0] = 0; r[1] = 0; r[2] = (int32_t)s.width; r[3] = (int32_t)s.height;
    r[4] = 0; r[5] = 0; r[6] = (int32_t)s.width; r[7] = (int32_t)s.height;
    *(DWORD *)(mi + 36) = 1;
    if (*(DWORD *)mi >= 72) {
        if (wide) { WCHAR *n = u2w("\\\\.\\DISPLAY1"); memcpy(mi + 40, n, (wlen(n) + 1) * 2); free(n); }
        else strcpy((char *)mi + 40, "\\\\.\\DISPLAY1");
    }
    return 1;
}
SHIM(WBOOL, GetMonitorInfoW, void *m, uint8_t *mi) { (void)m; return monitor_info(mi, 1); }
SHIM(WBOOL, GetMonitorInfoA, void *m, uint8_t *mi) { (void)m; return monitor_info(mi, 0); }
SHIM(WBOOL, EnumDisplaySettingsA, const char *dev, DWORD mode, uint8_t *dm) {
    (void)dev;
    if (mode != 0xFFFFFFFF && mode != 0xFFFFFFFE && mode != 0) return 0;
    NSSize s = screen_px();
    *(uint32_t *)(dm + 40) = 0x5C0000;
    *(uint32_t *)(dm + 104) = 32;
    *(uint32_t *)(dm + 108) = (uint32_t)s.width;
    *(uint32_t *)(dm + 112) = (uint32_t)s.height;
    *(uint32_t *)(dm + 120) = screen_hz();
    return 1;
}

// ---- messages
SHIM(WBOOL, PeekMessageW, MSG *m, void *hwnd, unsigned lo, unsigned hi, unsigned remove) {
    cocoa_pump();
    for (int i = 0; i < g_qlen; i++) {
        MSG *q = &g_queue[i];
        if (hwnd && hwnd != (void *)-1 && q->hwnd != hwnd) continue;
        if ((lo || hi) && (q->msg < lo || q->msg > hi)) continue;
        *m = *q;
        if (remove & 1) { memmove(q, q + 1, (g_qlen - i - 1) * sizeof *q); g_qlen--; }
        return 1;
    }
    return 0;
}
SHIM(WBOOL, TranslateMessage, const MSG *m) { FIXME("TranslateMessage: WM_CHAR is generated at pump time"); (void)m; return 0; }
SHIM(intptr_t, DispatchMessageW, const MSG *m) { return win_send(m->hwnd, m->msg, m->wp, m->lp); }
SHIM(intptr_t, DefWindowProcW, Win *w, unsigned msg, uintptr_t wp, intptr_t lp) {
    (void)wp; (void)lp;
    if (msg == WM_CLOSE) post(w, WM_QUIT, 0, 0);
    return 0;
}
SHIM(intptr_t, GetMessageExtraInfo, void) { return 0; }
SHIM(void *, GetActiveWindow, void) { return g_last_win; }
SHIM(void *, WindowFromPoint, int64_t pt) { (void)pt; return g_last_win; }
SHIM(int, MessageBoxW, void *w, const WCHAR *text, const WCHAR *cap, unsigned t) {
    (void)w; (void)t;
    char *a = w2u(text), *b = w2u(cap);
    LOG("MessageBoxW[%s]: %s", b, a);
    free(a); free(b);
    return 1;
}
SHIM(int, MessageBoxA, void *w, const char *text, const char *cap, unsigned t) {
    (void)w; (void)t;
    LOG("MessageBoxA[%s]: %s", cap, text);
    return 1;
}

// ---- input / cursor (minimal)
SHIM(void *, LoadCursorW, void *inst, const WCHAR *n) { (void)inst; (void)n; return (void *)1; }
SHIM(void *, LoadIconW, void *inst, const WCHAR *n) { (void)inst; (void)n; return (void *)1; }
static int g_cursor_count;
SHIM(int, ShowCursor, WBOOL show) {
    int was = g_cursor_count;
    g_cursor_count += show ? 1 : -1;
    if (was >= 0 && g_cursor_count < 0) [NSCursor hide];
    if (was < 0 && g_cursor_count >= 0) [NSCursor unhide];
    return g_cursor_count;
}
// A non-NULL clip rect is used for mouse-look: detach the cursor so it stays put; raw deltas keep flowing.
SHIM(WBOOL, ClipCursor, const int32_t *r) {
    static bool clipped;
    if ((r != NULL) != clipped) {
        clipped = r != NULL;
        CGAssociateMouseAndMouseCursorPosition(!clipped);
        TRACE("ClipCursor(%s)", clipped ? "on" : "off");
    }
    return 1;
}
SHIM(void *, SetCapture, Win *w) { FIXME("SetCapture"); (void)w; return NULL; }
SHIM(WBOOL, ReleaseCapture, void) { return 1; }
SHIM(WBOOL, GetCursorPos, int32_t *p) {
    NSPoint m = NSEvent.mouseLocation;
    CGFloat s = NSScreen.mainScreen.backingScaleFactor;
    p[0] = (int32_t)(m.x * s);
    p[1] = (int32_t)((NSScreen.screens[0].frame.size.height - m.y) * s);
    return 1;
}

// ---------------------------------------------------------------- keyboard / mouse translation
// macOS virtual key code -> Windows VK and set-1 scan code (bit 8 = extended key).
static const struct { uint8_t vk; uint16_t sc; } g_keymap[128] = {
    [0x00] = {'A', 0x1E}, [0x01] = {'S', 0x1F}, [0x02] = {'D', 0x20}, [0x03] = {'F', 0x21}, [0x04] = {'H', 0x23},
    [0x05] = {'G', 0x22}, [0x06] = {'Z', 0x2C}, [0x07] = {'X', 0x2D}, [0x08] = {'C', 0x2E}, [0x09] = {'V', 0x2F},
    [0x0A] = {0xE2, 0x56}, [0x0B] = {'B', 0x30}, [0x0C] = {'Q', 0x10}, [0x0D] = {'W', 0x11}, [0x0E] = {'E', 0x12},
    [0x0F] = {'R', 0x13}, [0x10] = {'Y', 0x15}, [0x11] = {'T', 0x14}, [0x12] = {'1', 0x02}, [0x13] = {'2', 0x03},
    [0x14] = {'3', 0x04}, [0x15] = {'4', 0x05}, [0x16] = {'6', 0x07}, [0x17] = {'5', 0x06}, [0x18] = {0xBB, 0x0D},
    [0x19] = {'9', 0x0A}, [0x1A] = {'7', 0x08}, [0x1B] = {0xBD, 0x0C}, [0x1C] = {'8', 0x09}, [0x1D] = {'0', 0x0B},
    [0x1E] = {0xDD, 0x1B}, [0x1F] = {'O', 0x18}, [0x20] = {'U', 0x16}, [0x21] = {0xDB, 0x1A}, [0x22] = {'I', 0x17},
    [0x23] = {'P', 0x19}, [0x24] = {0x0D, 0x1C}, [0x25] = {'L', 0x26}, [0x26] = {'J', 0x24}, [0x27] = {0xDE, 0x28},
    [0x28] = {'K', 0x25}, [0x29] = {0xBA, 0x27}, [0x2A] = {0xDC, 0x2B}, [0x2B] = {0xBC, 0x33}, [0x2C] = {0xBF, 0x35},
    [0x2D] = {'N', 0x31}, [0x2E] = {'M', 0x32}, [0x2F] = {0xBE, 0x34}, [0x30] = {0x09, 0x0F}, [0x31] = {0x20, 0x39},
    [0x32] = {0xC0, 0x29}, [0x33] = {0x08, 0x0E}, [0x35] = {0x1B, 0x01}, [0x37] = {0x5B, 0x15B}, [0x38] = {0xA0, 0x2A},
    [0x39] = {0x14, 0x3A}, [0x3A] = {0xA4, 0x38}, [0x3B] = {0xA2, 0x1D}, [0x3C] = {0xA1, 0x36}, [0x3D] = {0xA5, 0x138},
    [0x3E] = {0xA3, 0x11D}, [0x41] = {0x6E, 0x53}, [0x43] = {0x6A, 0x37}, [0x45] = {0x6B, 0x4E}, [0x4B] = {0x6F, 0x135},
    [0x4C] = {0x0D, 0x11C}, [0x4E] = {0x6D, 0x4A}, [0x52] = {0x60, 0x52}, [0x53] = {0x61, 0x4F}, [0x54] = {0x62, 0x50},
    [0x55] = {0x63, 0x51}, [0x56] = {0x64, 0x4B}, [0x57] = {0x65, 0x4C}, [0x58] = {0x66, 0x4D}, [0x59] = {0x67, 0x47},
    [0x5B] = {0x68, 0x48}, [0x5C] = {0x69, 0x49}, [0x60] = {0x74, 0x3F}, [0x61] = {0x75, 0x40}, [0x62] = {0x76, 0x41},
    [0x63] = {0x72, 0x3D}, [0x64] = {0x77, 0x42}, [0x65] = {0x78, 0x43}, [0x67] = {0x7A, 0x57}, [0x6D] = {0x79, 0x44},
    [0x6F] = {0x7B, 0x58}, [0x72] = {0x2D, 0x152}, [0x73] = {0x24, 0x147}, [0x74] = {0x21, 0x149}, [0x75] = {0x2E, 0x153},
    [0x76] = {0x73, 0x3E}, [0x77] = {0x23, 0x14F}, [0x78] = {0x71, 0x3C}, [0x79] = {0x22, 0x151}, [0x7A] = {0x70, 0x3B},
    [0x7B] = {0x25, 0x14B}, [0x7C] = {0x27, 0x14D}, [0x7D] = {0x28, 0x150}, [0x7E] = {0x26, 0x148},
};
static uint8_t g_keydown[256];  // by VK, includes generic SHIFT/CONTROL/MENU and mouse buttons
static int g_mouse_buttons;     // MK_* bits

// Raw input: registered usages and the records handed out through WM_INPUT.
static bool g_raw_mouse, g_raw_kbd, g_raw_kbd_nolegacy, g_raw_mouse_nolegacy;
#define RAWCAP 1024
static uint8_t g_raw[RAWCAP][48];
static uint32_t g_raw_next;

static void post_raw(Win *w, const uint8_t rec[48]) {
    uint32_t i = g_raw_next++ % RAWCAP;
    memcpy(g_raw[i], rec, 48);
    post(w, 0x00FF /* WM_INPUT */, 0 /* RIM_INPUT */, (intptr_t)(0x10000 + i));
}

static void key_event(Win *w, int code, bool down, bool repeat) {
    if (code < 0 || code > 127 || !g_keymap[code].vk) return;
    uint8_t vk = g_keymap[code].vk;
    uint16_t sc = g_keymap[code].sc;
    // Legacy messages use the generic modifier VKs; GetAsyncKeyState answers both forms.
    uint8_t mvk = (vk == 0xA0 || vk == 0xA1) ? 0x10 : (vk == 0xA2 || vk == 0xA3) ? 0x11 : (vk == 0xA4 || vk == 0xA5) ? 0x12 : vk;
    g_keydown[vk] = down;
    if (mvk != vk) {  // generic modifier is down while either side is
        int l = 0xA0 + (mvk - 0x10) * 2;
        g_keydown[mvk] = g_keydown[l] || g_keydown[l + 1];
    }
    bool alt = g_keydown[0x12];
    if (!g_raw_kbd_nolegacy) {
        intptr_t lp = 1 | (intptr_t)(sc & 0xff) << 16 | (intptr_t)((sc >> 8) & 1) << 24 | (intptr_t)alt << 29 |
                      (intptr_t)(repeat || !down) << 30 | (intptr_t)!down << 31;
        unsigned msg = alt && mvk != 0x12 ? (down ? 0x0104 : 0x0105) : (down ? 0x0100 : 0x0101);  // WM_SYS* with Alt
        post(w, msg, mvk, lp);
    }
    if (g_raw_kbd && !repeat) {
        uint8_t rec[48] = {0};
        *(uint32_t *)rec = 1;              // RIM_TYPEKEYBOARD
        *(uint32_t *)(rec + 4) = 40;
        *(uint64_t *)(rec + 8) = 0x10001;  // hDevice: NULL marks synthetic input, which apps often ignore
        *(uint16_t *)(rec + 24) = sc & 0xff;                                    // MakeCode
        *(uint16_t *)(rec + 26) = (uint16_t)((down ? 0 : 1) | ((sc >> 8) ? 2 : 0));  // RI_KEY_BREAK | RI_KEY_E0
        *(uint16_t *)(rec + 30) = mvk;                                         // VKey
        *(uint32_t *)(rec + 32) = down ? 0x0100 : 0x0101;
        post_raw(w, rec);
    }
    TRACE("key %s vk=%#x sc=%#x", down ? "down" : "up", vk, sc);
}

static intptr_t mouse_lparam(Win *w, NSEvent *e) {
    NSPoint p = [w->ns.contentView convertPoint:e.locationInWindow fromView:nil];
    NSRect b = w->ns.contentView.bounds;
    CGFloat s = w->ns.backingScaleFactor;
    int x = (int)(p.x * s), y = (int)((b.size.height - p.y) * s);
    return (intptr_t)(uint16_t)x | (intptr_t)(uint16_t)y << 16;
}

static void raw_mouse(Win *w, int dx, int dy, uint16_t bflags, int16_t wheel) {
    if (!g_raw_mouse) return;
    uint8_t rec[48] = {0};
    *(uint32_t *)rec = 0;                  // RIM_TYPEMOUSE
    *(uint32_t *)(rec + 4) = 48;
    *(uint64_t *)(rec + 8) = 0x10002;      // hDevice
    *(uint16_t *)(rec + 28) = bflags;      // usButtonFlags
    *(uint16_t *)(rec + 30) = (uint16_t)wheel;
    *(int32_t *)(rec + 36) = dx;           // lLastX (relative)
    *(int32_t *)(rec + 40) = dy;
    post_raw(w, rec);
}

// Returns true when the event was consumed as game input.
static bool input_event(NSEvent *e) {
    Win *w = g_last_win;
    if (!w || e.window != w->ns) return false;
    switch (e.type) {
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp: {
        bool down = e.type == NSEventTypeKeyDown;
        if (down && (e.modifierFlags & NSEventModifierFlagCommand)) {
            if ([e.charactersIgnoringModifiers isEqualToString:@"q"]) post(w, WM_CLOSE, 0, 0);
            return false;  // other Cmd shortcuts go to AppKit
        }
        key_event(w, e.keyCode, down, down && e.isARepeat);
        if (down && !g_raw_kbd_nolegacy) {
            NSString *c = e.characters;
            for (NSUInteger i = 0; i < c.length; i++) {
                unichar ch = [c characterAtIndex:i];
                if (ch >= 0xF700 && ch <= 0xF8FF) continue;  // function-key private-use range
                if (ch == 0x7F) ch = 0x08;                    // macOS Delete -> Backspace
                post(w, g_keydown[0x12] ? 0x0106 /* WM_SYSCHAR */ : 0x0102 /* WM_CHAR */, ch, 1);
            }
        }
        return true;
    }
    case NSEventTypeFlagsChanged: {
        static const struct { int code; NSEventModifierFlags flag; } mods[] = {
            {0x38, NSEventModifierFlagShift}, {0x3C, NSEventModifierFlagShift}, {0x3B, NSEventModifierFlagControl},
            {0x3E, NSEventModifierFlagControl}, {0x3A, NSEventModifierFlagOption}, {0x3D, NSEventModifierFlagOption},
            {0x37, NSEventModifierFlagCommand}, {0x39, NSEventModifierFlagCapsLock}};
        for (unsigned i = 0; i < sizeof mods / sizeof *mods; i++)
            if (mods[i].code == e.keyCode) {
                // Left/right share a flag; the key's own state flips on each event for that key code.
                bool down = !g_keydown[g_keymap[e.keyCode].vk];
                if (!(e.modifierFlags & mods[i].flag)) down = false;
                key_event(w, e.keyCode, down, false);
            }
        return true;
    }
    case NSEventTypeMouseMoved:
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged: {
        if (!g_raw_mouse_nolegacy) post(w, 0x0200 /* WM_MOUSEMOVE */, g_mouse_buttons, mouse_lparam(w, e));
        CGFloat s = w->ns.backingScaleFactor;
        raw_mouse(w, (int)lround(e.deltaX * s), (int)lround(e.deltaY * s), 0, 0);
        return false;  // still let AppKit track the cursor
    }
    case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp: {
        NSPoint p = [w->ns.contentView convertPoint:e.locationInWindow fromView:nil];
        if (!NSPointInRect(p, w->ns.contentView.bounds)) return false;  // title bar etc.
        bool down = e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeRightMouseDown || e.type == NSEventTypeOtherMouseDown;
        int b = e.type <= NSEventTypeLeftMouseUp ? 0 : (e.type == NSEventTypeRightMouseDown || e.type == NSEventTypeRightMouseUp) ? 1
                : e.buttonNumber == 2 ? 2 : e.buttonNumber == 3 ? 3 : 4;
        static const int mk[] = {0x01, 0x02, 0x10, 0x20, 0x40};
        static const uint8_t vk[] = {0x01, 0x02, 0x04, 0x05, 0x06};
        static const unsigned msg_down[] = {0x0201, 0x0204, 0x0207, 0x020B, 0x020B};
        static const uint16_t raw_flag[] = {0x0001, 0x0004, 0x0010, 0x0040, 0x0100};
        if (down) g_mouse_buttons |= mk[b]; else g_mouse_buttons &= ~mk[b];
        g_keydown[vk[b]] = down;
        if (!g_raw_mouse_nolegacy)
            post(w, msg_down[b] + (down ? 0 : 1), g_mouse_buttons | (b >= 3 ? (b == 3 ? 1 : 2) << 16 : 0), mouse_lparam(w, e));
        raw_mouse(w, 0, 0, (uint16_t)(raw_flag[b] << (down ? 0 : 1)), 0);
        return down && b == 0 ? false : true;  // left-down still activates/focuses the window
    }
    case NSEventTypeScrollWheel: {
        int d = (int)lround(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 4 : 120));
        if (!d) return true;
        if (!g_raw_mouse_nolegacy) post(w, 0x020A /* WM_MOUSEWHEEL */, (uintptr_t)(uint16_t)d << 16 | g_mouse_buttons, mouse_lparam(w, e));
        raw_mouse(w, 0, 0, 0x0400 /* RI_MOUSE_WHEEL */, (int16_t)d);
        return true;
    }
    default:
        return false;
    }
}

SHIM(int16_t, GetAsyncKeyState, int vk) { return vk >= 0 && vk < 256 && g_keydown[vk] ? (int16_t)0x8000 : 0; }
SHIM(WBOOL, RegisterRawInputDevices, const uint8_t *d, unsigned n, unsigned sz) {
    for (unsigned i = 0; i < n; i++) {
        uint16_t page = *(uint16_t *)(d + i * sz), usage = *(uint16_t *)(d + i * sz + 2);
        uint32_t fl = *(uint32_t *)(d + i * sz + 4);
        bool remove = fl & 0x1, nolegacy = fl & 0x30;
        LOG("RegisterRawInputDevices(page=%#x usage=%#x flags=%#x)", page, usage, fl);
        if (page != 1) continue;
        if (usage == 2) { g_raw_mouse = !remove; g_raw_mouse_nolegacy = !remove && nolegacy; }
        if (usage == 6) { g_raw_kbd = !remove && !getenv("LOADER_NO_RAW_KBD"); g_raw_kbd_nolegacy = g_raw_kbd && nolegacy; }
    }
    return 1;
}
// GetRawInputData(HRAWINPUT, RID_INPUT/RID_HEADER, data, *size, header_size)
SHIM(unsigned, GetRawInputData, void *h, unsigned cmd, void *data, unsigned *sz, unsigned hs) {
    (void)hs;
    uintptr_t i = (uintptr_t)h - 0x10000;
    if (i >= RAWCAP) return (unsigned)-1;
    const uint8_t *rec = g_raw[i];
    unsigned need = cmd == 0x10000005 /* RID_HEADER */ ? 24 : *(uint32_t *)(rec + 4);
    if (!data) { *sz = need; return 0; }
    if (*sz < need) return (unsigned)-1;
    memcpy(data, rec, need);
    return need;
}
SHIM(void *, RegisterDeviceNotificationW, void *h, void *f, DWORD fl) { (void)h; (void)f; (void)fl; return (void *)1; }
SHIM(WBOOL, GetTouchInputInfo, void *h, unsigned n, void *in, int sz) { FIXME("GetTouchInputInfo"); (void)h; (void)n; (void)in; (void)sz; return 0; }
SHIM(WBOOL, CloseTouchInputHandle, void *h) { (void)h; return 1; }
SHIM(WBOOL, SystemParametersInfoW, unsigned a, unsigned b, void *p, unsigned w) { FIXME("SystemParametersInfoW(action=%#x)", a); (void)a; (void)b; (void)p; (void)w; return 0; }
SHIM(WBOOL, OpenClipboard, void *w) { FIXME("OpenClipboard"); (void)w; return 0; }
SHIM(WBOOL, CloseClipboard, void) { return 1; }
SHIM(WBOOL, EmptyClipboard, void) { return 1; }
SHIM(void *, SetClipboardData, unsigned f, void *h) { FIXME("SetClipboardData"); (void)f; (void)h; return NULL; }

void cocoa_window_size(void *hwnd, int *w, int *h) {
    Win *win = hwnd ? hwnd : g_last_win;
    NSRect r = [win->ns.contentView convertRectToBacking:win->ns.contentView.bounds];
    *w = (int)r.size.width;
    *h = (int)r.size.height;
}

void *cocoa_window_view(void *hwnd, double *scale) {
    Win *win = hwnd ? hwnd : g_last_win;
    if (scale) *scale = win->ns.backingScaleFactor;
    return (__bridge void *)win->ns.contentView;
}

void cocoa_set_title(void *hwnd, const char *title) {
    Win *win = hwnd ? hwnd : g_last_win;
    NSString *t = [NSString stringWithUTF8String:title];
    dispatch_async(dispatch_get_main_queue(), ^{ win->ns.title = t; });
}

// user32 input on Cocoa: keyboard and mouse events become WM_* messages and Raw Input records
// (the game registers raw keyboard and mouse), plus key state, cursor, clipboard and touch stubs.
#include "user32.h"
#import <Carbon/Carbon.h> // kVK_* key codes

// macOS key code -> Windows virtual key and set-1 scan code.
#define EXT 0x100 // extended scan code (E0 prefix)
static const struct {
    BYTE vk;
    WORD scan;
} g_keys[128] = {
    [kVK_ANSI_A] = {'A', 0x1E},
    [kVK_ANSI_B] = {'B', 0x30},
    [kVK_ANSI_C] = {'C', 0x2E},
    [kVK_ANSI_D] = {'D', 0x20},
    [kVK_ANSI_E] = {'E', 0x12},
    [kVK_ANSI_F] = {'F', 0x21},
    [kVK_ANSI_G] = {'G', 0x22},
    [kVK_ANSI_H] = {'H', 0x23},
    [kVK_ANSI_I] = {'I', 0x17},
    [kVK_ANSI_J] = {'J', 0x24},
    [kVK_ANSI_K] = {'K', 0x25},
    [kVK_ANSI_L] = {'L', 0x26},
    [kVK_ANSI_M] = {'M', 0x32},
    [kVK_ANSI_N] = {'N', 0x31},
    [kVK_ANSI_O] = {'O', 0x18},
    [kVK_ANSI_P] = {'P', 0x19},
    [kVK_ANSI_Q] = {'Q', 0x10},
    [kVK_ANSI_R] = {'R', 0x13},
    [kVK_ANSI_S] = {'S', 0x1F},
    [kVK_ANSI_T] = {'T', 0x14},
    [kVK_ANSI_U] = {'U', 0x16},
    [kVK_ANSI_V] = {'V', 0x2F},
    [kVK_ANSI_W] = {'W', 0x11},
    [kVK_ANSI_X] = {'X', 0x2D},
    [kVK_ANSI_Y] = {'Y', 0x15},
    [kVK_ANSI_Z] = {'Z', 0x2C},
    [kVK_ANSI_1] = {'1', 0x02},
    [kVK_ANSI_2] = {'2', 0x03},
    [kVK_ANSI_3] = {'3', 0x04},
    [kVK_ANSI_4] = {'4', 0x05},
    [kVK_ANSI_5] = {'5', 0x06},
    [kVK_ANSI_6] = {'6', 0x07},
    [kVK_ANSI_7] = {'7', 0x08},
    [kVK_ANSI_8] = {'8', 0x09},
    [kVK_ANSI_9] = {'9', 0x0A},
    [kVK_ANSI_0] = {'0', 0x0B},
    [kVK_ANSI_Minus] = {VK_OEM_MINUS, 0x0C},
    [kVK_ANSI_Equal] = {VK_OEM_PLUS, 0x0D},
    [kVK_ANSI_LeftBracket] = {VK_OEM_4, 0x1A},
    [kVK_ANSI_RightBracket] = {VK_OEM_6, 0x1B},
    [kVK_ANSI_Semicolon] = {VK_OEM_1, 0x27},
    [kVK_ANSI_Quote] = {VK_OEM_7, 0x28},
    [kVK_ANSI_Grave] = {VK_OEM_3, 0x29},
    [kVK_ANSI_Backslash] = {VK_OEM_5, 0x2B},
    [kVK_ANSI_Comma] = {VK_OEM_COMMA, 0x33},
    [kVK_ANSI_Period] = {VK_OEM_PERIOD, 0x34},
    [kVK_ANSI_Slash] = {VK_OEM_2, 0x35},
    [kVK_ISO_Section] = {VK_OEM_102, 0x56},
    [kVK_Escape] = {VK_ESCAPE, 0x01},
    [kVK_Tab] = {VK_TAB, 0x0F},
    [kVK_Return] = {VK_RETURN, 0x1C},
    [kVK_Space] = {VK_SPACE, 0x39},
    [kVK_Delete] = {VK_BACK, 0x0E},
    [kVK_ForwardDelete] = {VK_DELETE, EXT | 0x53},
    [kVK_CapsLock] = {VK_CAPITAL, 0x3A},
    [kVK_Help] = {VK_INSERT, EXT | 0x52},
    [kVK_Shift] = {VK_LSHIFT, 0x2A},
    [kVK_RightShift] = {VK_RSHIFT, 0x36},
    [kVK_Control] = {VK_LCONTROL, 0x1D},
    [kVK_RightControl] = {VK_RCONTROL, EXT | 0x1D},
    [kVK_Option] = {VK_LMENU, 0x38},
    [kVK_RightOption] = {VK_RMENU, EXT | 0x38},
    [kVK_Command] = {VK_LWIN, EXT | 0x5B},
    [kVK_LeftArrow] = {VK_LEFT, EXT | 0x4B},
    [kVK_RightArrow] = {VK_RIGHT, EXT | 0x4D},
    [kVK_UpArrow] = {VK_UP, EXT | 0x48},
    [kVK_DownArrow] = {VK_DOWN, EXT | 0x50},
    [kVK_Home] = {VK_HOME, EXT | 0x47},
    [kVK_End] = {VK_END, EXT | 0x4F},
    [kVK_PageUp] = {VK_PRIOR, EXT | 0x49},
    [kVK_PageDown] = {VK_NEXT, EXT | 0x51},
    [kVK_F1] = {VK_F1 + 0, 0x3B},
    [kVK_F2] = {VK_F1 + 1, 0x3C},
    [kVK_F3] = {VK_F1 + 2, 0x3D},
    [kVK_F4] = {VK_F1 + 3, 0x3E},
    [kVK_F5] = {VK_F1 + 4, 0x3F},
    [kVK_F6] = {VK_F1 + 5, 0x40},
    [kVK_F7] = {VK_F1 + 6, 0x41},
    [kVK_F8] = {VK_F1 + 7, 0x42},
    [kVK_F9] = {VK_F1 + 8, 0x43},
    [kVK_F10] = {VK_F1 + 9, 0x44},
    [kVK_F11] = {VK_F1 + 10, 0x57},
    [kVK_F12] = {VK_F1 + 11, 0x58},
    [kVK_ANSI_Keypad0] = {VK_NUMPAD0 + 0, 0x52},
    [kVK_ANSI_Keypad1] = {VK_NUMPAD0 + 1, 0x4F},
    [kVK_ANSI_Keypad2] = {VK_NUMPAD0 + 2, 0x50},
    [kVK_ANSI_Keypad3] = {VK_NUMPAD0 + 3, 0x51},
    [kVK_ANSI_Keypad4] = {VK_NUMPAD0 + 4, 0x4B},
    [kVK_ANSI_Keypad5] = {VK_NUMPAD0 + 5, 0x4C},
    [kVK_ANSI_Keypad6] = {VK_NUMPAD0 + 6, 0x4D},
    [kVK_ANSI_Keypad7] = {VK_NUMPAD0 + 7, 0x47},
    [kVK_ANSI_Keypad8] = {VK_NUMPAD0 + 8, 0x48},
    [kVK_ANSI_Keypad9] = {VK_NUMPAD0 + 9, 0x49},
    [kVK_ANSI_KeypadDecimal] = {VK_DECIMAL, 0x53},
    [kVK_ANSI_KeypadMultiply] = {VK_MULTIPLY, 0x37},
    [kVK_ANSI_KeypadPlus] = {VK_ADD, 0x4E},
    [kVK_ANSI_KeypadMinus] = {VK_SUBTRACT, 0x4A},
    [kVK_ANSI_KeypadDivide] = {VK_DIVIDE, EXT | 0x35},
    [kVK_ANSI_KeypadEnter] = {VK_RETURN, EXT | 0x1C},
};

static bool g_key_down[256];   // by VK, including the generic VK_SHIFT/CONTROL/MENU and mouse buttons
static WPARAM g_mouse_buttons; // MK_* flags

// Legacy key messages use the generic modifier keys; Raw Input and GetAsyncKeyState know both sides.
static BYTE generic_vk(BYTE vk) {
    switch (vk) {
    case VK_LSHIFT:
    case VK_RSHIFT: return VK_SHIFT;
    case VK_LCONTROL:
    case VK_RCONTROL: return VK_CONTROL;
    case VK_LMENU:
    case VK_RMENU: return VK_MENU;
    default: return vk;
    }
}

// ---------------------------------------------------------------- Raw Input
static bool g_raw_mouse, g_raw_keyboard, g_raw_mouse_only, g_raw_keyboard_only; // *_only: RIDEV_NOLEGACY

#define RAW_SLOTS           1024
#define FIRST_RAW_HANDLE    0x10000           // HRAWINPUT values are FIRST_RAW_HANDLE + slot
#define RAW_KEYBOARD_DEVICE ((HANDLE)0x10001) // a NULL device would mark the input as synthetic
#define RAW_MOUSE_DEVICE    ((HANDLE)0x10002)
static RAWINPUT g_raw[RAW_SLOTS];
static uint32_t g_raw_next;

// Mouse motion arrives far faster than a game drains its queue. Consecutive motion is merged into the newest
// unread record, so it can neither fill the ring (overwriting queued key events) nor lag behind the hand.
static int g_pending_motion = -1; // slot of the newest queued, unread motion record, or -1

static void post_raw_input(const RAWINPUT *input) {
    uint32_t slot = g_raw_next++ % RAW_SLOTS;
    g_raw[slot] = *input;
    post_message(g_window, WM_INPUT, RIM_INPUT, FIRST_RAW_HANDLE + (LPARAM)slot);
}

static void post_raw_mouse(int dx, int dy, WORD button_flags, short wheel) {
    if (!g_raw_mouse) return;
    RAWINPUT input = {.header = {RIM_TYPEMOUSE, sizeof input, RAW_MOUSE_DEVICE, RIM_INPUT}};
    input.data.mouse.usButtonFlags = button_flags;
    input.data.mouse.usButtonData = (WORD)wheel;
    input.data.mouse.lLastX = dx; // relative motion
    input.data.mouse.lLastY = dy;
    bool motion_only = !button_flags && !wheel;
    if (motion_only && g_pending_motion >= 0) {
        g_raw[g_pending_motion].data.mouse.lLastX += dx;
        g_raw[g_pending_motion].data.mouse.lLastY += dy;
        return;
    }
    post_raw_input(&input);
    g_pending_motion = motion_only ? (int)((g_raw_next - 1) % RAW_SLOTS) : -1;
}

SHIM(WBOOL, RegisterRawInputDevices, const RAWINPUTDEVICE *devices, UINT count, UINT size) {
    for (UINT i = 0; i < count; i++) {
        const RAWINPUTDEVICE *d = &devices[i];
        bool enable = !(d->dwFlags & RIDEV_REMOVE), legacy = !(d->dwFlags & RIDEV_NOLEGACY);
        if (d->usUsagePage != HID_USAGE_PAGE_GENERIC) continue;
        if (d->usUsage == HID_USAGE_GENERIC_MOUSE) {
            g_raw_mouse = enable;
            g_raw_mouse_only = enable && !legacy;
        } else if (d->usUsage == HID_USAGE_GENERIC_KEYBOARD) {
            g_raw_keyboard = enable;
            g_raw_keyboard_only = enable && !legacy;
        }
    }
    return true;
}

SHIM(UINT, GetRawInputData, HANDLE handle, UINT command, void *data, UINT *size, UINT header_size) {
    uintptr_t slot = (uintptr_t)handle - FIRST_RAW_HANDLE;
    if (slot >= RAW_SLOTS) return (UINT)-1;
    if ((int)slot == g_pending_motion) g_pending_motion = -1; // read: later motion needs a new record
    const RAWINPUT *input = &g_raw[slot];
    UINT needed = command == RID_HEADER ? sizeof input->header : input->header.dwSize;
    if (!data) {
        *size = needed;
        return 0;
    }
    if (*size < needed) return (UINT)-1;
    memcpy(data, input, needed);
    return needed;
}

// ---------------------------------------------------------------- keyboard
static void key_event(unsigned short mac_code, bool down, bool repeat) {
    if (mac_code >= 128 || !g_keys[mac_code].vk) return;
    BYTE vk = g_keys[mac_code].vk, legacy_vk = generic_vk(vk);
    WORD scan = g_keys[mac_code].scan;

    g_key_down[vk] = down;
    if (legacy_vk != vk) { // the generic modifier is down while either side is
        BYTE left = legacy_vk == VK_SHIFT ? VK_LSHIFT : legacy_vk == VK_CONTROL ? VK_LCONTROL : VK_LMENU;
        g_key_down[legacy_vk] = g_key_down[left] || g_key_down[left + 1];
    }
    bool alt = g_key_down[VK_MENU];

    if (!g_raw_keyboard_only) {
        // lParam: repeat count, scan code, extended flag, context (Alt), previous state, transition.
        LPARAM lparam = 1 | (LPARAM)(scan & 0xFF) << 16 | (LPARAM)((scan & EXT) != 0) << 24 | (LPARAM)alt << 29 |
                        (LPARAM)(repeat || !down) << 30 | (LPARAM)!down << 31;
        bool system = alt && legacy_vk != VK_MENU; // Alt+key is a "system" key
        UINT message = system ? (down ? WM_SYSKEYDOWN : WM_SYSKEYUP) : (down ? WM_KEYDOWN : WM_KEYUP);
        post_message(g_window, message, legacy_vk, lparam);
    }
    if (g_raw_keyboard && !repeat) {
        g_pending_motion = -1; // keep events in order
        RAWINPUT input = {.header = {RIM_TYPEKEYBOARD, sizeof input.header + sizeof input.data.keyboard,
                                     RAW_KEYBOARD_DEVICE, RIM_INPUT}};
        input.data.keyboard.MakeCode = scan & 0xFF;
        input.data.keyboard.Flags = (down ? 0 : RI_KEY_BREAK) | ((scan & EXT) ? RI_KEY_E0 : 0);
        input.data.keyboard.VKey = legacy_vk;
        input.data.keyboard.Message = down ? WM_KEYDOWN : WM_KEYUP;
        post_raw_input(&input);
    }
}

static void post_characters(NSString *characters) {
    for (NSUInteger i = 0; i < characters.length; i++) {
        unichar c = [characters characterAtIndex:i];
        if (c >= NSUpArrowFunctionKey && c <= 0xF8FF) continue; // function keys, not text
        if (c == NSDeleteCharacter) c = '\b';                   // the Mac Delete key is Backspace
        post_message(g_window, g_key_down[VK_MENU] ? WM_SYSCHAR : WM_CHAR, c, 1);
    }
}

static bool handle_key(NSEvent *e) {
    bool down = e.type == NSEventTypeKeyDown;
    if (down && (e.modifierFlags & NSEventModifierFlagCommand)) {
        if ([e.charactersIgnoringModifiers isEqualToString:@"q"]) post_message(g_window, WM_CLOSE, 0, 0);
        return false; // other Cmd shortcuts go to AppKit
    }
    key_event(e.keyCode, down, down && e.isARepeat);
    if (down && !g_raw_keyboard_only) post_characters(e.characters);
    return true;
}

// Modifier keys arrive as flag changes; left and right share one flag, so track each key by code.
static bool handle_modifier(NSEvent *e) {
    static const struct {
        unsigned short code;
        NSEventModifierFlags flag;
    } modifiers[] = {
        {kVK_Shift, NSEventModifierFlagShift},     {kVK_RightShift, NSEventModifierFlagShift},
        {kVK_Control, NSEventModifierFlagControl}, {kVK_RightControl, NSEventModifierFlagControl},
        {kVK_Option, NSEventModifierFlagOption},   {kVK_RightOption, NSEventModifierFlagOption},
        {kVK_Command, NSEventModifierFlagCommand}, {kVK_CapsLock, NSEventModifierFlagCapsLock},
    };
    for (size_t i = 0; i < sizeof modifiers / sizeof *modifiers; i++) {
        if (modifiers[i].code != e.keyCode) continue;
        bool down = (e.modifierFlags & modifiers[i].flag) && !g_key_down[g_keys[e.keyCode].vk];
        key_event(e.keyCode, down, false);
    }
    return true;
}

SHIM(short, GetAsyncKeyState, int vk) {
    return vk >= 0 && vk < 256 && g_key_down[vk] ? (short)0x8000 : 0; // high bit: currently down
}

// ---------------------------------------------------------------- mouse
static LPARAM mouse_position(NSEvent *e) {
    NSView *view = g_window->ns.contentView;
    NSPoint p = [view convertPoint:e.locationInWindow fromView:nil];
    CGFloat scale = g_window->ns.backingScaleFactor;
    int x = p.x * scale, y = (view.bounds.size.height - p.y) * scale; // origin at the top left
    return (LPARAM)(uint16_t)x | (LPARAM)(uint16_t)y << 16;
}

static bool handle_mouse_move(NSEvent *e) {
    if (!g_raw_mouse_only) post_message(g_window, WM_MOUSEMOVE, g_mouse_buttons, mouse_position(e));
    CGFloat scale = g_window->ns.backingScaleFactor;
    post_raw_mouse(lround(e.deltaX * scale), lround(e.deltaY * scale), 0, 0);
    return false; // AppKit still tracks the cursor
}

static bool handle_mouse_button(NSEvent *e) {
    NSView *view = g_window->ns.contentView;
    if (!NSPointInRect([view convertPoint:e.locationInWindow fromView:nil], view.bounds)) return false; // title bar

    // Buttons: left, right, middle, X1, X2.
    static const WPARAM mk[] = {MK_LBUTTON, MK_RBUTTON, MK_MBUTTON, MK_XBUTTON1, MK_XBUTTON2};
    static const BYTE vk[] = {VK_LBUTTON, VK_RBUTTON, VK_MBUTTON, VK_XBUTTON1, VK_XBUTTON2};
    static const UINT down_message[] = {WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN, WM_XBUTTONDOWN};
    bool down = e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeRightMouseDown ||
                e.type == NSEventTypeOtherMouseDown;
    int button = e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeLeftMouseUp     ? 0
                 : e.type == NSEventTypeRightMouseDown || e.type == NSEventTypeRightMouseUp ? 1
                 : e.buttonNumber == 2                                                      ? 2
                 : e.buttonNumber == 3                                                      ? 3
                                                                                            : 4;
    if (down)
        g_mouse_buttons |= mk[button];
    else
        g_mouse_buttons &= ~mk[button];
    g_key_down[vk[button]] = down;

    if (!g_raw_mouse_only) {
        WPARAM xbutton = button == 3 ? 1 : button == 4 ? 2 : 0; // XBUTTON1 / XBUTTON2 in the high word
        post_message(g_window, down_message[button] + !down, g_mouse_buttons | xbutton << 16, mouse_position(e));
    }
    // RI_MOUSE_*_BUTTON_DOWN flags are 1 << (2 * button); UP is the next bit.
    post_raw_mouse(0, 0, (WORD)(RI_MOUSE_LEFT_BUTTON_DOWN << (2 * button + !down)), 0);
    return !(down && button == 0); // a left click still activates the window
}

static bool handle_scroll(NSEvent *e) {
    // Trackpads report fine-grained deltas; wheels report lines (one notch = WHEEL_DELTA).
    int delta = lround(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 4 : WHEEL_DELTA));
    if (!delta) return true;
    if (!g_raw_mouse_only)
        post_message(g_window, WM_MOUSEWHEEL, (WPARAM)(uint16_t)delta << 16 | g_mouse_buttons, mouse_position(e));
    post_raw_mouse(0, 0, RI_MOUSE_WHEEL, (short)delta);
    return true;
}

bool handle_input_event(NSEvent *e) {
    if (!g_window || e.window != g_window->ns) return false;
    switch (e.type) {
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp: return handle_key(e);
    case NSEventTypeFlagsChanged: return handle_modifier(e);
    case NSEventTypeMouseMoved:
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged: return handle_mouse_move(e);
    case NSEventTypeLeftMouseDown:
    case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseDown:
    case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseDown:
    case NSEventTypeOtherMouseUp: return handle_mouse_button(e);
    case NSEventTypeScrollWheel: return handle_scroll(e);
    default: return false;
    }
}

// ---------------------------------------------------------------- cursor
SHIM(HANDLE, LoadCursorW, HANDLE instance, const WCHAR *name) { return (HANDLE)1; }
SHIM(HANDLE, LoadIconW, HANDLE instance, const WCHAR *name) { return (HANDLE)1; }

// The cursor is shown while the display counter is >= 0.
SHIM(int, ShowCursor, WBOOL show) {
    static int counter;
    int previous = counter;
    counter += show ? 1 : -1;
    if (previous >= 0 && counter < 0) [NSCursor hide];
    if (previous < 0 && counter >= 0) [NSCursor unhide];
    return counter;
}

// A clip rectangle means mouse-look: keep the cursor still while raw deltas keep flowing.
SHIM(WBOOL, ClipCursor, const RECT *rect) {
    static bool clipped;
    if ((rect != NULL) != clipped) {
        clipped = rect != NULL;
        CGAssociateMouseAndMouseCursorPosition(!clipped);
    }
    return true;
}

SHIM(WBOOL, GetCursorPos, POINT *p) {
    NSPoint mouse = NSEvent.mouseLocation; // bottom-left origin, in points
    CGFloat scale = NSScreen.mainScreen.backingScaleFactor;
    p->x = mouse.x * scale;
    p->y = (NSScreen.screens[0].frame.size.height - mouse.y) * scale;
    return true;
}

SHIM(HWND, SetCapture, Window *w) { return NULL; } // Cocoa already delivers drags outside the window
SHIM(WBOOL, ReleaseCapture, void) { return true; }

// ---------------------------------------------------------------- devices, touch, clipboard
SHIM(HANDLE, RegisterDeviceNotificationW, HANDLE recipient, void *filter, DWORD flags) { return (HANDLE)1; }

SHIM(WBOOL, GetTouchInputInfo, HANDLE touch, UINT count, void *inputs, int size) {
    FIXME("GetTouchInputInfo: no touch input");
    return false;
}

SHIM(WBOOL, CloseTouchInputHandle, HANDLE touch) { return true; }

SHIM(WBOOL, OpenClipboard, HWND owner) {
    FIXME("OpenClipboard: no clipboard");
    return false;
}

SHIM(WBOOL, CloseClipboard, void) { return true; }
SHIM(WBOOL, EmptyClipboard, void) { return true; }
SHIM(HANDLE, SetClipboardData, UINT format, HANDLE data) { return NULL; }

// The window lost focus: key-up events will not arrive, so release everything the game believes is held.
void input_release_all(void) {
    for (unsigned short code = 0; code < 128; code++)
        if (g_keys[code].vk && g_key_down[g_keys[code].vk]) key_event(code, false, false);
    g_mouse_buttons = 0;
    for (BYTE vk = VK_LBUTTON; vk <= VK_XBUTTON2; vk++) g_key_down[vk] = false;
}

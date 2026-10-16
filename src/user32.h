// Internals shared by the user32 shims (window.m, input.m).
#pragma once
#include "shim.h"
#import <Cocoa/Cocoa.h>

// An HWND is a pointer to one of these.
typedef struct Window {
    NSWindow *ns;
    WNDPROC proc;
    intptr_t longs[32]; // SetWindowLong values, indexed by -index for the negative GWL_* indices
} Window;

extern Window *g_window; // the game's only window

void post_message(Window *w, UINT message, WPARAM wparam, LPARAM lparam);
bool handle_input_event(NSEvent *event);         // true if consumed as game input
void input_hide_cursor_until_game_decides(void); // hides the cursor until the game first touches it
void input_release_all(void);
CGFloat game_scale(Window *w); // pixels per point as the game sees them (NULL: the main screen)                    //
                               // releases held keys and buttons, e.g. on losing focus

NSSize client_size_in_pixels(Window *w);

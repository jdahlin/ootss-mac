// Shared declarations for the PE loader and its Win32 shims.
#pragma once
#include "win32.h"
#include <stdbool.h>
#include <stdio.h>

// Windows x64 calling convention. Every function the game calls directly must use it.
#define WINAPI __attribute__((ms_abi))

// ---- import table
// Register `fn` (an ms_abi function) as the implementation of import `name`. Registering an
// existing name replaces it. Imports by ordinal are named "dll#ordinal", e.g. "d3d12.dll#101".
void shim_register(const char *name, void *fn);
void *shim_lookup(const char *name);

// Define an import shim: SHIM(return_type, ImportName, parameters...) { body }
#define SHIM(ret, name, ...)                                                                                           \
    static WINAPI ret name##_shim(__VA_ARGS__);                                                                        \
    __attribute__((constructor)) static void name##_register(void) { shim_register(#name, (void *)name##_shim); }      \
    static WINAPI ret name##_shim(__VA_ARGS__)

// A trampoline that loads r10d = tag and jumps to target; gives shared handlers per-slot context.
void *make_tagged_thunk(uint32_t tag, void *target);

// ---- logging. Every line starts with seconds since launch.
extern bool g_trace; // LOADER_TRACE=1
double log_time(void);
#define LOG_LINE(tag, ...)                                                                                             \
    do {                                                                                                               \
        fprintf(stderr, "%8.3f [" tag "] ", log_time());                                                               \
        fprintf(stderr, __VA_ARGS__);                                                                                  \
        fputc('\n', stderr);                                                                                           \
    } while (0)
#define LOG(...) LOG_LINE("loader", __VA_ARGS__)
#define TRACE(...)                                                                                                     \
    do {                                                                                                               \
        if (g_trace) LOG_LINE("shim", __VA_ARGS__);                                                                    \
    } while (0)
// A shim that is knowingly partial. Logs its first few calls so misbehaviour can be traced back to it.
#define FIXME(...)                                                                                                     \
    do {                                                                                                               \
        static int fixme_count;                                                                                        \
        if (fixme_count++ < 3) LOG_LINE("fixme", __VA_ARGS__);                                                         \
    } while (0)

// ---- the loaded game
extern uint8_t *g_image_base;
extern size_t g_image_size;
extern char g_exe_unix_path[1024];
extern WCHAR g_exe_win_path[1024]; // Z:\...\sinking_star.exe (Z: is /, as in Wine)

// ---- per-thread Windows state. On macOS x86_64, %gs points at the pthread TSD array; the TEB
// fields the game reads through %gs are stored in otherwise unused TSD slots (see loader.c).
#define TEB_SELF        0x30 // gs:[0x30] = TEB.NtTib.Self
#define TEB_TLS_POINTER 0x58 // gs:[0x58] = TEB.ThreadLocalStoragePointer
#define TEB_PEB         0x60 // TEB.ProcessEnvironmentBlock
#define PEB_IMAGE_BASE  0x10 // PEB.ImageBaseAddress
typedef struct Teb {
    uint8_t raw[0x1000]; // the Windows TEB layout, only the fields above are filled in
    void *tls_array[64];
    DWORD last_error;
} Teb;
Teb *teb_setup_current_thread(void);
Teb *teb_current(void);
void set_last_error(DWORD error);

// ---- strings (strings.c). All returned strings are malloc'd.
size_t wlen(const WCHAR *s);
char *w2u(const WCHAR *s);             // UTF-16 -> UTF-8
char *w2u_n(const WCHAR *s, long n);   // n < 0: up to the terminator
WCHAR *u2w(const char *s);             // UTF-8 -> UTF-16
char *win_to_unix_path(const char *p); // "Z:\a\b" -> "/a/b"
int win_vformat(char *out, size_t cap, const char *fmt, uint64_t *args, bool wide_strings);

// ---- kernel objects. HANDLEs we create point at a WHandle; D3DMetal creates its own event handles.
enum { H_FILE = 1, H_EVENT, H_SEMAPHORE, H_THREAD, H_MAPPING, H_FIND };
#define WHANDLE_MAGIC 0x4C444E48u // "HNDL"
typedef struct WHandle {
    uint32_t magic;
    int type;
    int fd;
    void *obj;
} WHandle;
WHandle *handle_new(int type);
bool handle_is_ours(const void *h);

// ---- D3D backend (d3d.m). Win32 events are created as dmn events so D3DMetal can signal them.
typedef struct {
    void *(*create)(int manual_reset, int initial_state);
    void (*signal)(void *h);
    void (*clear)(void *h);
    void (*close)(void *h);
    int (*wait)(void *h, uint64_t timeout_ns); // 0 signaled, 1 timeout, -1 failed
} DmnEvents;
extern DmnEvents g_dmn_ev;
void d3d_backend_init(void);

// ---- audio (audio.c)
HRESULT audio_create_instance(const GUID *clsid, const GUID *iid, void **out);

// ---- Cocoa (user32.m)
void cocoa_init(void);
void cocoa_pump(void);
void cocoa_window_set_fullscreen(void *hwnd, bool fullscreen);
bool cocoa_window_is_fullscreen(void *hwnd);
void icon_apply(void); // the game's own icon, in the Dock
bool icon_write_png(const char *path);
void cocoa_window_size(void *hwnd, int *w, int *h);  // backing pixels
void *cocoa_window_view(void *hwnd, double *scale);  // the content NSView
void cocoa_set_title(void *hwnd, const char *title); // any thread
extern void (*g_window_resized)(void *hwnd, int w, int h, double scale);

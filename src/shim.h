// Shared declarations for the x86_64 PE loader and its Win32 shims.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define WINAPI __attribute__((ms_abi))

typedef uint16_t WCHAR;
typedef int32_t WBOOL;
typedef uint32_t DWORD;
typedef void *HANDLE;

// Register `fn` (an ms_abi function) as the implementation of import `name`.
void shim_register(const char *name, void *fn);
void *shim_lookup(const char *name);

// Define an import shim: SHIM(ret, Name, args...) { body }
#define SHIM(ret, name, ...)                                                  \
    static WINAPI ret name##_shim(__VA_ARGS__);                               \
    __attribute__((constructor)) static void name##_reg(void) {               \
        shim_register(#name, (void *)name##_shim);                            \
    }                                                                         \
    static WINAPI ret name##_shim(__VA_ARGS__)

extern int g_trace;  // LOADER_TRACE=1 logs every shim call that uses TRACE()
// Every loader log line starts with seconds since launch.
double log_time(void);
#define TRACE(...) do { if (g_trace) { fprintf(stderr, "%8.3f [shim] ", log_time()); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)
// FIXME: a shim that is knowingly partial or a stub. Logs the first few calls per call site so
// misbehaviour during bootstrap can be traced back to an incomplete implementation.
#define FIXME(...) do { static int _fixme_n; if (_fixme_n++ < 3) { fprintf(stderr, "%8.3f [fixme] ", log_time()); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)
#define LOG(...) do { fprintf(stderr, "%8.3f [loader] ", log_time()); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)

// PE image
extern uint8_t *g_image_base;
extern size_t g_image_size;
extern char g_exe_unix_path[1024];
extern WCHAR g_exe_win_path[1024];

// Per-thread Windows state (subset of TEB)
typedef struct Teb {
    uint8_t raw[0x1000];  // TEB layout: +0x08 StackBase, +0x10 StackLimit, +0x30 Self, +0x58 TLS array
    void *tls_array[64];
    DWORD last_error;
} Teb;
Teb *teb_setup_current_thread(void);
Teb *teb_current(void);
void set_last_error(DWORD e);

// Strings
size_t wlen(const WCHAR *s);
char *w2u(const WCHAR *s);                // malloc'd UTF-8
char *w2u_n(const WCHAR *s, long n);
WCHAR *u2w(const char *s);                // malloc'd UTF-16
char *win_to_unix_path(const char *p);    // malloc'd

// Handles
enum { H_FILE = 1, H_EVENT, H_SEMAPHORE, H_THREAD, H_MAPPING, H_FIND, H_PROCESS };
#define WHANDLE_MAGIC 0x4C444E48u  // "HNDL"
typedef struct WHandle {
    uint32_t magic;  // distinguishes our handles from D3DMetal (dmn) event handles
    int type;
    int fd;
    void *obj;
} WHandle;
WHandle *handle_new(int type);

// D3D backend (d3d_backend.m). When D3DMetal is active, Win32 events are dmn events so
// D3DMetal can signal them; ev.create is NULL otherwise.
typedef struct {
    void *(*create)(int manual_reset, int initial_state);
    void (*signal)(void *h);
    void (*clear)(void *h);
    void (*close)(void *h);
    int (*wait)(void *h, uint64_t timeout_ns);  // 0 signaled, 1 timeout, -1 failed
} DmnEvents;
extern DmnEvents g_dmn_ev;
void d3d_backend_init(void);
bool handle_is_ours(const void *h);

// Cocoa (user32_cocoa.m)
void cocoa_init(void);
void cocoa_pump(void);
void cocoa_window_size(void *hwnd, int *w, int *h);  // backing pixels
void *cocoa_window_view(void *hwnd, double *scale);  // NSView * (content view)
void cocoa_set_title(void *hwnd, const char *title);  // any thread
extern void (*g_window_resized)(void *hwnd, int w, int h, double scale);  // set by the D3D backend

// Trampoline that loads r10 = tag then jumps to target (used for per-slot COM stubs)
void *make_tagged_thunk(uint32_t tag, void *target);

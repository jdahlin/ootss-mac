// D3D12/DXGI via Apple's D3DMetal (Game Porting Toolkit), hosted by d3dmetal-native.
//
// The game calls D3DMetal's COM objects directly (both sides use ms_abi). We only hook
// IDXGIFactory::CreateSwapChainForHwnd to turn our HWND into a dmn pseudo-HWND bound to the window's NSView,
// and optionally IDXGISwapChain::Present for an fps readout in the window title (LOADER_FPS=1).
//
// Paths: libd3dmetal-native.dylib next to the executable (or LOADER_DMN_LIB);
//        D3DMetal.framework from D3DMETAL_FRAMEWORK_PATH or an installed GPTK.
#include "shim.h"
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <glob.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <pthread.h>
#include <time.h>

DmnEvents g_dmn_ev;

typedef struct {
    size_t struct_size;
    const char *framework_path;
    void *log_cb;
    void *log_ctx;
} DmnOptions;

static struct {
    int (*init)(const DmnOptions *);
    const char *(*framework_path)(void);
    int (*set_executable_path)(const char *);
    void *(*window_create_for_view)(NSView *);
    void *(*window_get_hwnd)(void *);
    void (*window_set_size)(void *, uint32_t, uint32_t, double);
    WINAPI HRESULT (*CreateDXGIFactory2)(uint32_t, const void *, void **);
    WINAPI HRESULT (*D3D12CreateDevice)(void *, uint32_t, const void *, void **);
} dmn;

// ---- HWND translation: our Win* -> dmn pseudo-HWND (one per window)
static struct {
    void *ours, *dmn_window, *dmn_hwnd;
} g_hwnds[8];
static int g_nhwnds;

static void window_resized(void *hwnd, int w, int h, double scale) {
    for (int i = 0; i < g_nhwnds; i++)
        if (g_hwnds[i].ours == hwnd) dmn.window_set_size(g_hwnds[i].dmn_window, w, h, scale);
}

static void *dmn_hwnd_for(void *hwnd) {
    g_window_resized = window_resized;
    for (int i = 0; i < g_nhwnds; i++)
        if (g_hwnds[i].ours == hwnd) return g_hwnds[i].dmn_hwnd;
    double scale = 1;
    NSView *view = (__bridge NSView *)cocoa_window_view(hwnd, &scale);
    void *w = dmn.window_create_for_view(view);
    int pw, ph;
    cocoa_window_size(hwnd, &pw, &ph);
    dmn.window_set_size(w, pw, ph, scale);
    void *h = dmn.window_get_hwnd(w);
    g_hwnds[g_nhwnds++] = (typeof(g_hwnds[0])){hwnd, w, h};
    return h;
}

// ---- fps readout: Present is patched in place (d3dmetal-native keys its own hooks on vtable identity)
enum { SLOT_PRESENT = 8 };
typedef WINAPI HRESULT (*PresentFn)(void *, uint32_t, uint32_t);
static PresentFn g_orig_present;
static void *g_fps_hwnd;

static WINAPI HRESULT hook_Present(void *self, uint32_t sync, uint32_t flags) {
    static uint64_t frames, t0;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!t0) t0 = now;
    if (++frames && now - t0 >= 500000000ull) {
        double fps = frames * 1e9 / (now - t0);
        char title[96];
        snprintf(title, sizeof title, "Order of the Sinking Star | %.1f fps | %.1f ms", fps, 1000.0 / fps);
        cocoa_set_title(g_fps_hwnd, title);
        frames = 0;
        t0 = now;
    }
    return g_orig_present(self, sync, flags);
}

static void patch_present(void *swapchain) {
    void **vt = *(void ***)swapchain;
    if (vt[SLOT_PRESENT] == (void *)hook_Present) return;
    uintptr_t page = (uintptr_t)&vt[SLOT_PRESENT] & ~0xfffull;
    if (vm_protect(mach_task_self(), page, 0x1000, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        return;
    g_orig_present = (PresentFn)vt[SLOT_PRESENT];
    vt[SLOT_PRESENT] = (void *)hook_Present;
}

// ---- factory hook. D3DMetal's vtables are read-only, so each factory object gets a writable copy
// with QueryInterface (to patch interfaces it returns) and CreateSwapChainForHwnd swapped.
enum { SLOT_QI = 0, SLOT_CREATE_SWAPCHAIN_FOR_HWND = 15, FACTORY_SLOTS = 32 /* IDXGIFactory7 */ };
typedef WINAPI HRESULT (*QIFn)(void *, const void *, void **);
typedef WINAPI HRESULT (*CreateSCForHwndFn)(void *, void *, void *, const void *, const void *, void *,
                                                            void **);
static QIFn g_orig_qi;
static CreateSCForHwndFn g_orig_csc;
static void patch_factory(void *obj);

static WINAPI HRESULT hook_QueryInterface(void *self, const void *iid, void **out) {
    HRESULT r = g_orig_qi(self, iid, out);
    if (r == 0 && out && *out) patch_factory(*out);
    return r;
}

static WINAPI HRESULT hook_CreateSwapChainForHwnd(void *self, void *dev, void *hwnd, const void *desc,
                                                                  const void *fs, void *restrict_out, void **out) {
    HRESULT r = g_orig_csc(self, dev, dmn_hwnd_for(hwnd), desc, fs, restrict_out, out);
    const uint32_t *d = desc;
    LOG("d3d: swapchain %ux%u, %u buffers -> %#x", d[0], d[1], d[7], r);
    if (r == 0 && out && *out && getenv("LOADER_FPS")) {
        g_fps_hwnd = hwnd;
        patch_present(*out);
    }
    return r;
}

static void patch_factory(void *obj) {
    void **vt = *(void ***)obj;
    if (vt[SLOT_QI] == (void *)hook_QueryInterface) return;
    if (!g_orig_qi) {
        g_orig_qi = (QIFn)vt[SLOT_QI];
        g_orig_csc = (CreateSCForHwndFn)vt[SLOT_CREATE_SWAPCHAIN_FOR_HWND];
    }
    void **copy = malloc(FACTORY_SLOTS * sizeof *copy);
    memcpy(copy, vt, FACTORY_SLOTS * sizeof *copy);
    copy[SLOT_QI] = (void *)hook_QueryInterface;
    copy[SLOT_CREATE_SWAPCHAIN_FOR_HWND] = (void *)hook_CreateSwapChainForHwnd;
    *(void ***)obj = copy;
}

static WINAPI HRESULT CreateDXGIFactory2_metal(uint32_t fl, const void *iid, void **out) {
    HRESULT r = dmn.CreateDXGIFactory2(fl, iid, out);
    if (r == 0) patch_factory(*out);
    return r;
}

// D3DMetal's first factory creation costs seconds (one-time Metal/shader-converter setup). Doing it on a
// background thread at startup overlaps that with the game's own initialization.
static void *prewarm(void *arg) {
    static const GUID IID_IDXGIFactory1 = {
        0x770aae78, 0xf26f, 0x4dba, {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}};
    void *f = NULL;
    if (dmn.CreateDXGIFactory2(0, &IID_IDXGIFactory1, &f) == 0 && f)
        ((WINAPI uint32_t (*)(void *))(*(void ***)f)[2])(f); // Release
    return NULL;
}

static const char *find_framework(const char *exe_dir) {
    const char *e = getenv("D3DMETAL_FRAMEWORK_PATH");
    if (e) return e;
    static char path[1024];
    snprintf(path, sizeof path, "%s/D3DMetal.framework", exe_dir); // copied or symlinked next to the binary
    if (access(path, R_OK) == 0) return path;
    // GPTK downloaded by Wine front-ends (e.g. GameHub).
    char pat[1024];
    snprintf(pat, sizeof pat,
             "%s/Library/Application Support/*/wine-engine/downloads/gptk-*/external/D3DMetal.framework",
             getenv("HOME"));
    glob_t g;
    if (glob(pat, 0, NULL, &g) == 0 && g.gl_pathc) {
        snprintf(path, sizeof path, "%s", g.gl_pathv[g.gl_pathc - 1]); // newest sorts last
        globfree(&g);
        return path;
    }
    return NULL;
}

void d3d_backend_init(void) {
    char exe[1024], dir[1024], lib[1100];
    uint32_t sz = sizeof exe;
    _NSGetExecutablePath(exe, &sz);
    snprintf(dir, sizeof dir, "%s", dirname(exe));
    const char *e = getenv("LOADER_DMN_LIB");
    snprintf(lib, sizeof lib, "%s", e ? e : "");
    if (!e) snprintf(lib, sizeof lib, "%s/libd3dmetal-native.dylib", dir);
    void *h = dlopen(lib, RTLD_NOW);
    if (!h) {
        fprintf(stderr, "error: cannot load %s: %s\n", lib, dlerror());
        exit(1);
    }
#define SYM(field, name) dmn.field = dlsym(h, name)
    SYM(init, "dmn_init");
    SYM(framework_path, "dmn_framework_path");
    SYM(set_executable_path, "dmn_set_executable_path");
    SYM(window_create_for_view, "dmn_window_create_for_view");
    SYM(window_get_hwnd, "dmn_window_get_hwnd");
    SYM(window_set_size, "dmn_window_set_size");
    SYM(CreateDXGIFactory2, "CreateDXGIFactory2");
    SYM(D3D12CreateDevice, "D3D12CreateDevice");
#undef SYM
    g_dmn_ev.create = dlsym(h, "dmn_event_create");
    g_dmn_ev.signal = dlsym(h, "dmn_event_signal");
    g_dmn_ev.clear = dlsym(h, "dmn_event_clear");
    g_dmn_ev.close = dlsym(h, "dmn_event_close");
    g_dmn_ev.wait = dlsym(h, "dmn_event_wait");

    dmn.set_executable_path(g_exe_unix_path); // D3DMetal's per-app profiles key on the exe name
    setenv("DMN_RETINA", "1", 0);
    // The game is GPU-bound; with display sync every queued frame adds input latency. A composited
    // macOS window does not tear, so present immediately unless the user overrides it.
    setenv("DMN_VSYNC", "0", 0);
    DmnOptions o = {sizeof o, find_framework(dir), NULL, NULL};
    if (dmn.init(&o)) {
        fprintf(stderr, "error: D3DMetal.framework not found (set D3DMETAL_FRAMEWORK_PATH, see README)\n");
        exit(1);
    }
    LOG("d3d: D3DMetal %s", dmn.framework_path());
    pthread_t t;
    pthread_create(&t, NULL, prewarm, NULL);
    pthread_detach(t);
    shim_register("CreateDXGIFactory2", (void *)CreateDXGIFactory2_metal);
    shim_register("d3d12.dll#101", (void *)dmn.D3D12CreateDevice); // ordinal 101 = D3D12CreateDevice
}

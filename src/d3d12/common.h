// D3D12 and DXGI on Metal: shared definitions for the backend.
//
// Uses Microsoft's own d3d12.h (DirectX-Headers, via its WSL adapter for non-Windows builds), with two
// adjustments for running inside a Windows x64 process:
//   - COM methods use the Windows calling convention (ms_abi), because the game calls them directly.
//   - Windows' BOOL is renamed WINBOOL, because Objective-C has its own BOOL.
// Metal must be imported before the adapter, which defines `interface` as a macro.
//
// This translation unit family does not include shim.h: its win32.h types would clash with Microsoft's.
// Files are compiled without ARC; objects retain and release their Metal objects explicitly.
#pragma once
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#undef TRUE // Foundation's; the adapter redefines them identically
#undef FALSE
#define BOOL WINBOOL
#include <wsl/winadapter.h>
#undef STDMETHODCALLTYPE
#define STDMETHODCALLTYPE __attribute__((ms_abi))
#include <directx/d3d12.h>
#include <directx/dxgiformat.h>
#undef BOOL

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#undef WINAPI
#define WINAPI           __attribute__((ms_abi))
#define GUID_EQUAL(a, b) (memcmp((a), (b), sizeof(GUID)) == 0)

// ---- from the loader (declared here instead of including shim.h)
double log_time(void);
void shim_register(const char *name, void *fn);
void *shim_lookup(const char *name);
void *make_tagged_thunk(uint32_t tag, void *target);
void *cocoa_window_view(void *hwnd, double *scale);
void cocoa_window_set_fullscreen(void *hwnd, bool fullscreen);
bool cocoa_window_is_fullscreen(void *hwnd);
void cocoa_window_size(void *hwnd, int *w, int *h);
void cpu_log_frame(void);
void cpu_log_submit(void);

#define D3D_LOG(...)                                                                                                   \
    do {                                                                                                               \
        fprintf(stderr, "%8.3f [d3d12] ", log_time());                                                                 \
        fprintf(stderr, __VA_ARGS__);                                                                                  \
        fputc('\n', stderr);                                                                                           \
    } while (0)
#define D3D_TODO(...)                                                                                                  \
    do {                                                                                                               \
        static int todo_count;                                                                                         \
        if (todo_count++ < 3) D3D_LOG("todo: " __VA_ARGS__);                                                           \
    } while (0)

// ---- COM objects
// Every object starts with its vtable pointer, so it can be handed to the game as any of its
// interfaces. `iids` lists the interfaces QueryInterface answers with the same object.
typedef struct Object {
    const void *vtbl;
    const IID *const *iids;
    atomic_int refs;
    void (*destroy)(struct Object *);
    struct Device *device; // owning device, for GetDevice
} Object;

void object_init(Object *o, const void *vtbl, const IID *const *iids, struct Device *device);
HRESULT object_query(Object *o, REFIID iid, void **out);
ULONG object_add_ref(Object *o);
ULONG object_release(Object *o);

// The IUnknown and ID3D12Object entries every D3D12 vtable starts with.
HRESULT STDMETHODCALLTYPE com_QueryInterface(void *self, REFIID iid, void **out);
ULONG STDMETHODCALLTYPE com_AddRef(void *self);
ULONG STDMETHODCALLTYPE com_Release(void *self);
HRESULT STDMETHODCALLTYPE com_GetPrivateData(void *self, REFGUID guid, UINT *size, void *data);
HRESULT STDMETHODCALLTYPE com_SetPrivateData(void *self, REFGUID guid, UINT size, const void *data);
HRESULT STDMETHODCALLTYPE com_SetPrivateDataInterface(void *self, REFGUID guid, const IUnknown *data);
HRESULT STDMETHODCALLTYPE com_SetName(void *self, LPCWSTR name);
HRESULT STDMETHODCALLTYPE com_GetDevice(void *self, REFIID iid, void **device);

#define ID3D12_OBJECT_METHODS                                                                                          \
    .QueryInterface = (void *)com_QueryInterface, .AddRef = (void *)com_AddRef, .Release = (void *)com_Release,        \
    .GetPrivateData = (void *)com_GetPrivateData, .SetPrivateData = (void *)com_SetPrivateData,                        \
    .SetPrivateDataInterface = (void *)com_SetPrivateDataInterface, .SetName = (void *)com_SetName

// Unimplemented methods: every NULL slot in `vtbl` becomes a stub that logs "<interface> slot N" once
// and returns E_NOTIMPL. Call once per vtable before first use.
void fill_unimplemented(void *vtbl, size_t size, const char *interface_name);
#define FILL_UNIMPLEMENTED(vtbl) fill_unimplemented(&(vtbl), sizeof(vtbl), #vtbl)

// Methods returning a struct use MSVC's ABI: the caller passes a hidden result pointer after `this`
// and gets it back. d3d12.h only declares that form for _WIN32, so those methods are written with the
// explicit RetVal parameter and cast into the vtable.

// ---- shared objects
typedef struct Device {
    Object object;
    id<MTLDevice> mtl;
} Device;

id<MTLDevice> backend_mtl_device(void);
MTLPixelFormat mtl_format(DXGI_FORMAT format);                       // a typed format, as a view or attachment uses it
MTLPixelFormat mtl_resource_format(const D3D12_RESOURCE_DESC *desc); // also resolves typeless formats
MTLVertexFormat mtl_vertex_format(DXGI_FORMAT format);
UINT format_bytes_per_block(DXGI_FORMAT format, UINT *block_size); // block_size: 1 or 4 (BC)

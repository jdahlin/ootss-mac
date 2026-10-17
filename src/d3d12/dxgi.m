// DXGI on Metal: factory, adapter and a flip-model swapchain presented through a CAMetalLayer.
//
// DirectX-Headers has no DXGI, so the vtables here are plain slot arrays. Slot numbers follow the
// DXGI interface inheritance order (IUnknown, IDXGIObject, ...), see the constants below.
#include "objects.h"

#define DXGI_ERROR_NOT_FOUND_HR ((HRESULT)0x887A0002)

// ---------------------------------------------------------------- GUIDs
#define GUID_DEF(name, a, b, c, d0, d1, d2, d3, d4, d5, d6, d7)                                                        \
    static const GUID name = {a, b, c, {d0, d1, d2, d3, d4, d5, d6, d7}}
GUID_DEF(IID_IDXGIObject, 0xaec22fb8, 0x76f3, 0x4639, 0x9b, 0xe0, 0x28, 0xeb, 0x43, 0xa6, 0x7a, 0x2e);
GUID_DEF(IID_IDXGIFactory, 0x7b7166ec, 0x21c7, 0x44ae, 0xb2, 0x1a, 0xc9, 0xae, 0x32, 0x1a, 0xe3, 0x69);
GUID_DEF(IID_IDXGIFactory1, 0x770aae78, 0xf26f, 0x4dba, 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87);
GUID_DEF(IID_IDXGIFactory2, 0x50c83a1c, 0xe072, 0x4c48, 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0);
GUID_DEF(IID_IDXGIFactory3, 0x25483823, 0xcd46, 0x4c7d, 0x86, 0xca, 0x47, 0xaa, 0x95, 0xb8, 0x37, 0xbd);
GUID_DEF(IID_IDXGIFactory4, 0x1bc6ea02, 0xef36, 0x464f, 0xbf, 0x0c, 0x21, 0xca, 0x39, 0xe5, 0x16, 0x8a);
GUID_DEF(IID_IDXGIFactory5, 0x7632e1f5, 0xee65, 0x4dca, 0x87, 0xfd, 0x84, 0xcd, 0x75, 0xf8, 0x83, 0x8d);
GUID_DEF(IID_IDXGIAdapter, 0x2411e7e1, 0x12ac, 0x4ccf, 0xbd, 0x14, 0x97, 0x98, 0xe8, 0x53, 0x4d, 0xc0);
GUID_DEF(IID_IDXGIAdapter1, 0x29038f61, 0x3839, 0x4626, 0x91, 0xfd, 0x08, 0x68, 0x79, 0x01, 0x1a, 0x05);
GUID_DEF(IID_IDXGISwapChain, 0x310d36a0, 0xd2e7, 0x4c0a, 0xaa, 0x04, 0x6a, 0x9d, 0x23, 0xb8, 0x88, 0x6a);
GUID_DEF(IID_IDXGISwapChain1, 0x790a45f7, 0x0d42, 0x4876, 0x98, 0x3a, 0x0a, 0x55, 0xcf, 0xe6, 0xf4, 0xaa);
GUID_DEF(IID_IDXGISwapChain2, 0xa8be2ac4, 0x199f, 0x4946, 0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7);
GUID_DEF(IID_IDXGISwapChain3, 0x94d99bdb, 0xf1f8, 0x4ab0, 0xb2, 0x36, 0x7d, 0xa0, 0x17, 0x0e, 0xda, 0xb1);

// ---------------------------------------------------------------- structures (dxgi.h, dxgi1_2.h)
typedef struct {
    UINT Width, Height;
    DXGI_FORMAT Format;
    UINT Stereo;
    DXGI_SAMPLE_DESC SampleDesc;
    UINT BufferUsage, BufferCount, Scaling, SwapEffect, AlphaMode, Flags;
} SwapChainDesc1;

typedef struct {
    uint16_t Description[128]; // UTF-16; the adapter header's WCHAR is 4 bytes on macOS
    UINT VendorId, DeviceId, SubSysId, Revision;
    SIZE_T DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
    LUID AdapterLuid;
    UINT Flags; // DXGI_ADAPTER_DESC1 only
} AdapterDesc1;

_Static_assert(sizeof(SwapChainDesc1) == 48, "DXGI_SWAP_CHAIN_DESC1");
_Static_assert(sizeof(AdapterDesc1) == 312, "DXGI_ADAPTER_DESC1");

#define DXGI_USAGE_RENDER_TARGET_OUTPUT 0x20
#define DXGI_PRESENT_TEST               0x1
#define APPLE_VENDOR_ID                 0x106B

static void utf8_to_utf16(const char *s, uint16_t *out, size_t max) {
    if (!s) s = "Metal GPU";
    size_t i = 0;
    for (; s[i] && i + 1 < max; i++) out[i] = (uint8_t)s[i]; // ASCII is enough for adapter names
    out[i] = 0;
}

// ---------------------------------------------------------------- slots
enum { // IDXGIObject / IUnknown
    SLOT_SET_PRIVATE_DATA = 3,
    SLOT_SET_PRIVATE_DATA_INTERFACE,
    SLOT_GET_PRIVATE_DATA,
    SLOT_GET_PARENT,
};
enum { // IDXGIFactory .. IDXGIFactory5
    FACTORY_ENUM_ADAPTERS = 7,
    FACTORY_MAKE_WINDOW_ASSOCIATION,
    FACTORY_GET_WINDOW_ASSOCIATION,
    FACTORY_CREATE_SWAP_CHAIN,
    FACTORY_CREATE_SOFTWARE_ADAPTER,
    FACTORY1_ENUM_ADAPTERS1 = 12,
    FACTORY1_IS_CURRENT,
    FACTORY2_IS_WINDOWED_STEREO_ENABLED = 14,
    FACTORY2_CREATE_SWAP_CHAIN_FOR_HWND,
    FACTORY3_GET_CREATION_FLAGS = 25,
    FACTORY4_ENUM_ADAPTER_BY_LUID = 26,
    FACTORY4_ENUM_WARP_ADAPTER,
    FACTORY5_CHECK_FEATURE_SUPPORT = 28,
    FACTORY_SLOT_COUNT = 29,
};
enum { // IDXGIAdapter, IDXGIAdapter1
    ADAPTER_ENUM_OUTPUTS = 7,
    ADAPTER_GET_DESC,
    ADAPTER_CHECK_INTERFACE_SUPPORT,
    ADAPTER1_GET_DESC1,
    ADAPTER_SLOT_COUNT,
};
enum { // IDXGIDeviceSubObject, IDXGISwapChain .. IDXGISwapChain3
    SWAPCHAIN_GET_DEVICE = 7,
    SWAPCHAIN_PRESENT,
    SWAPCHAIN_GET_BUFFER,
    SWAPCHAIN_SET_FULLSCREEN_STATE,
    SWAPCHAIN_GET_FULLSCREEN_STATE,
    SWAPCHAIN_GET_DESC,
    SWAPCHAIN_RESIZE_BUFFERS,
    SWAPCHAIN_RESIZE_TARGET,
    SWAPCHAIN_GET_CONTAINING_OUTPUT,
    SWAPCHAIN_GET_FRAME_STATISTICS,
    SWAPCHAIN_GET_LAST_PRESENT_COUNT,
    SWAPCHAIN1_GET_DESC1 = 18,
    SWAPCHAIN1_GET_FULLSCREEN_DESC,
    SWAPCHAIN1_GET_HWND,
    SWAPCHAIN1_GET_CORE_WINDOW,
    SWAPCHAIN1_PRESENT1,
    SWAPCHAIN1_IS_TEMPORARY_MONO_SUPPORTED,
    SWAPCHAIN1_GET_RESTRICT_TO_OUTPUT,
    SWAPCHAIN1_SET_BACKGROUND_COLOR,
    SWAPCHAIN1_GET_BACKGROUND_COLOR,
    SWAPCHAIN1_SET_ROTATION,
    SWAPCHAIN1_GET_ROTATION,
    SWAPCHAIN2_SET_SOURCE_SIZE = 29,
    SWAPCHAIN2_GET_SOURCE_SIZE,
    SWAPCHAIN2_SET_MAXIMUM_FRAME_LATENCY,
    SWAPCHAIN2_GET_MAXIMUM_FRAME_LATENCY,
    SWAPCHAIN2_GET_FRAME_LATENCY_WAITABLE_OBJECT,
    SWAPCHAIN2_SET_MATRIX_TRANSFORM,
    SWAPCHAIN2_GET_MATRIX_TRANSFORM,
    SWAPCHAIN3_GET_CURRENT_BACK_BUFFER_INDEX = 36,
    SWAPCHAIN3_CHECK_COLOR_SPACE_SUPPORT,
    SWAPCHAIN3_SET_COLOR_SPACE1,
    SWAPCHAIN3_RESIZE_BUFFERS1,
    SWAPCHAIN_SLOT_COUNT,
};

// ---------------------------------------------------------------- adapter
typedef struct Adapter {
    Object object;
} Adapter;

static Adapter g_adapter;

static HRESULT STDMETHODCALLTYPE adapter_GetDesc1(Adapter *a, AdapterDesc1 *desc) {
    memset(desc, 0, sizeof *desc);
    utf8_to_utf16(backend_mtl_device().name.UTF8String, desc->Description, 128);
    desc->VendorId = APPLE_VENDOR_ID;
    desc->DeviceId = 1;
    // Unified memory: report the recommended working set as video memory.
    desc->DedicatedVideoMemory = backend_mtl_device().recommendedMaxWorkingSetSize;
    desc->SharedSystemMemory = backend_mtl_device().recommendedMaxWorkingSetSize;
    desc->AdapterLuid = (LUID){0x1234, 0};
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE adapter_GetDesc(Adapter *a, AdapterDesc1 *desc) { return adapter_GetDesc1(a, desc); }

static HRESULT STDMETHODCALLTYPE adapter_EnumOutputs(Adapter *a, UINT index, void **output) {
    *output = NULL;
    return DXGI_ERROR_NOT_FOUND_HR; // the game picks its own window size; no output enumeration needed yet
}

static HRESULT STDMETHODCALLTYPE adapter_CheckInterfaceSupport(Adapter *a, REFGUID iid, LARGE_INTEGER *umd) {
    if (umd) umd->QuadPart = 0x001F000000000000ll; // pretend driver version 31.0.0.0
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE adapter_GetParent(Adapter *a, REFIID iid, void **parent);

static void *adapter_vtbl[ADAPTER_SLOT_COUNT];
static const IID *const adapter_iids[] = {&IID_IDXGIAdapter1, &IID_IDXGIAdapter, &IID_IDXGIObject, NULL};

static Adapter *adapter_get(void) {
    if (!g_adapter.object.vtbl) {
        adapter_vtbl[0] = com_QueryInterface;
        adapter_vtbl[1] = com_AddRef;
        adapter_vtbl[2] = com_Release;
        adapter_vtbl[SLOT_SET_PRIVATE_DATA] = com_SetPrivateData;
        adapter_vtbl[SLOT_SET_PRIVATE_DATA_INTERFACE] = com_SetPrivateDataInterface;
        adapter_vtbl[SLOT_GET_PRIVATE_DATA] = com_GetPrivateData;
        adapter_vtbl[SLOT_GET_PARENT] = adapter_GetParent;
        adapter_vtbl[ADAPTER_ENUM_OUTPUTS] = adapter_EnumOutputs;
        adapter_vtbl[ADAPTER_GET_DESC] = adapter_GetDesc;
        adapter_vtbl[ADAPTER_CHECK_INTERFACE_SUPPORT] = adapter_CheckInterfaceSupport;
        adapter_vtbl[ADAPTER1_GET_DESC1] = adapter_GetDesc1;
        fill_unimplemented(adapter_vtbl, sizeof adapter_vtbl, "IDXGIAdapter1");
        object_init(&g_adapter.object, adapter_vtbl, adapter_iids, NULL);
        object_add_ref(&g_adapter.object); // statically allocated: never freed
    }
    return &g_adapter;
}

// ---------------------------------------------------------------- swapchain
typedef struct SwapChain {
    Object object;
    CommandQueue *queue;
    void *hwnd;
    CAMetalLayer *layer;
    SwapChainDesc1 desc;
    Resource *buffers[16];
    UINT index; // next back buffer to present
    uint64_t presents;
    HANDLE latency_event;
    UINT max_latency;
} SwapChain;

// The back buffer keeps the channel order the game renders in; CAMetalLayer takes RGBA8 as well as BGRA8.
static MTLPixelFormat swapchain_pixel_format(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R16G16B16A16_FLOAT: return MTLPixelFormatRGBA16Float;
    case DXGI_FORMAT_R8G8B8A8_UNORM: return MTLPixelFormatRGBA8Unorm;
    default: return MTLPixelFormatBGRA8Unorm;
    }
}

static void swapchain_create_buffers(SwapChain *s) {
    MTLPixelFormat format = swapchain_pixel_format(s->desc.Format);
    MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                 width:s->desc.Width
                                                                                height:s->desc.Height
                                                                             mipmapped:NO];
    t.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
              MTLTextureUsagePixelFormatView;
    t.storageMode = MTLStorageModePrivate;
    for (UINT i = 0; i < s->desc.BufferCount && i < 16; i++) {
        if (s->buffers[i]) object_release(&s->buffers[i]->object);
        id<MTLTexture> texture = [s->queue->object.device->mtl newTextureWithDescriptor:t];
        s->buffers[i] = resource_from_texture(s->queue->object.device, texture, s->desc.Format);
        s->buffers[i]->is_backbuffer = true;
        [texture release];
    }
    s->layer.drawableSize = CGSizeMake(s->desc.Width, s->desc.Height);
}

static HRESULT STDMETHODCALLTYPE swapchain_Present(SwapChain *s, UINT sync_interval, UINT flags) {
    if (flags & DXGI_PRESENT_TEST) return S_OK;
    static int benchmark = -1; // D3D12_NO_PRESENT=1: never show frames, so the game runs as fast as the GPU allows
    if (benchmark < 0) benchmark = getenv("D3D12_NO_PRESENT") != NULL;
    @autoreleasepool {
        id<CAMetalDrawable> drawable = benchmark ? nil : [s->layer nextDrawable];
        if (drawable) {
            id<MTLCommandBuffer> cb = [s->queue->mtl commandBuffer];
            id<MTLTexture> source = s->buffers[s->index]->texture;
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromTexture:source
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(MIN(source.width, drawable.texture.width),
                                              MIN(source.height, drawable.texture.height), 1)
                        toTexture:drawable.texture
                 destinationSlice:0
                 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
            // D3D12_LOG_PRESENT=1: report how much of the back buffer is non-black (BGRA8 only).
            id<MTLBuffer> probe = nil;
            if (getenv("D3D12_LOG_PRESENT") && s->presents % 20 == 0 &&
                (source.pixelFormat == MTLPixelFormatBGRA8Unorm || source.pixelFormat == MTLPixelFormatRGBA8Unorm)) {
                probe = [s->queue->object.device->mtl newBufferWithLength:source.width * source.height * 4
                                                                  options:MTLResourceStorageModeShared];
                [blit copyFromTexture:source
                                 sourceSlice:0
                                 sourceLevel:0
                                sourceOrigin:MTLOriginMake(0, 0, 0)
                                  sourceSize:MTLSizeMake(source.width, source.height, 1)
                                    toBuffer:probe
                           destinationOffset:0
                      destinationBytesPerRow:source.width * 4
                    destinationBytesPerImage:source.width * source.height * 4];
            }
            [blit endEncoding];
            [cb presentDrawable:drawable];
            [cb commit];
            if (probe) {
                [cb waitUntilCompleted];
                const uint8_t *px = probe.contents;
                size_t lit = 0, n = source.width * source.height;
                for (size_t i = 0; i < n; i++) lit += (px[i * 4] | px[i * 4 + 1] | px[i * 4 + 2]) != 0;
                const char *dump = getenv("D3D12_DUMP_FRAME"); // a PPM of the first probed frame after 100 presents
                if (dump && s->presents == 100) {
                    FILE *f = fopen(dump, "wb");
                    if (f) {
                        fprintf(f, "P6\n%lu %lu\n255\n", (unsigned long)source.width, (unsigned long)source.height);
                        for (size_t i = 0; i < n; i++) {
                            bool bgra = source.pixelFormat == MTLPixelFormatBGRA8Unorm;
                            uint8_t rgb[3] = {px[i * 4 + (bgra ? 2 : 0)], px[i * 4 + 1], px[i * 4 + (bgra ? 0 : 2)]};
                            fwrite(rgb, 1, 3, f);
                        }
                        fclose(f);
                    }
                }
                D3D_LOG("present %llu: %zu of %zu pixels non-black", (unsigned long long)s->presents, lit, n);
                [probe release];
            }
        }
    }
    s->index = (s->index + 1) % s->desc.BufferCount;
    s->presents++;
    cpu_log_frame();
    static long max_presents = -2; // D3D12_MAX_PRESENTS=n: exit after n frames, for bounded debug runs
    if (max_presents == -2) max_presents = getenv("D3D12_MAX_PRESENTS") ? atol(getenv("D3D12_MAX_PRESENTS")) : -1;
    if (max_presents >= 0 && (long)s->presents >= max_presents) exit(0);
    static WINAPI WINBOOL (*set_event)(HANDLE);
    if (!set_event) set_event = shim_lookup("SetEvent");
    if (s->latency_event) set_event(s->latency_event);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swapchain_Present1(SwapChain *s, UINT sync_interval, UINT flags, const void *params) {
    return swapchain_Present(s, sync_interval, flags);
}

static HRESULT STDMETHODCALLTYPE swapchain_GetBuffer(SwapChain *s, UINT index, REFIID iid, void **surface) {
    if (index >= s->desc.BufferCount) return E_INVALIDARG;
    return object_query(&s->buffers[index]->object, iid, surface);
}

static UINT STDMETHODCALLTYPE swapchain_GetCurrentBackBufferIndex(SwapChain *s) { return s->index; }

static HRESULT STDMETHODCALLTYPE swapchain_ResizeBuffers(SwapChain *s, UINT count, UINT width, UINT height,
                                                         DXGI_FORMAT format, UINT flags) {
    D3D_LOG("ResizeBuffers(%u, %ux%u)", count, width, height);
    if (!width || !height) {
        int w, h;
        cocoa_window_size(s->hwnd, &w, &h);
        width = w;
        height = h;
    }
    if (count) s->desc.BufferCount = count;
    if (format) s->desc.Format = format;
    s->desc.Width = width;
    s->desc.Height = height;
    s->desc.Flags = flags;
    swapchain_create_buffers(s);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swapchain_ResizeBuffers1(SwapChain *s, UINT count, UINT width, UINT height,
                                                          DXGI_FORMAT format, UINT flags, const UINT *masks,
                                                          IUnknown *const *queues) {
    return swapchain_ResizeBuffers(s, count, width, height, format, flags);
}

static HRESULT STDMETHODCALLTYPE swapchain_GetDesc1(SwapChain *s, SwapChainDesc1 *desc) {
    *desc = s->desc;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swapchain_GetHwnd(SwapChain *s, void **hwnd) {
    *hwnd = s->hwnd;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swapchain_SetFullscreenState(SwapChain *s, WINBOOL fullscreen, void *target) {
    D3D_LOG("SetFullscreenState(%d)", fullscreen);
    cocoa_window_set_fullscreen(s->hwnd, fullscreen); // the game then sees the window grow and resizes its buffers
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swapchain_GetFullscreenState(SwapChain *s, WINBOOL *fullscreen, void **target) {
    if (fullscreen) *fullscreen = cocoa_window_is_fullscreen(s->hwnd);
    if (target) *target = NULL;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swapchain_GetFrameStatistics(SwapChain *s, void *stats) {
    return (HRESULT)0x887A000B; // DXGI_ERROR_FRAME_STATISTICS_DISJOINT
}

static HRESULT STDMETHODCALLTYPE swapchain_GetLastPresentCount(SwapChain *s, UINT *count) {
    *count = (UINT)s->presents;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swapchain_SetMaximumFrameLatency(SwapChain *s, UINT latency) {
    s->max_latency = latency;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swapchain_GetMaximumFrameLatency(SwapChain *s, UINT *latency) {
    *latency = s->max_latency;
    return S_OK;
}

static HANDLE STDMETHODCALLTYPE swapchain_GetFrameLatencyWaitableObject(SwapChain *s) { return s->latency_event; }

static HRESULT STDMETHODCALLTYPE swapchain_CheckColorSpaceSupport(SwapChain *s, UINT color_space, UINT *support) {
    *support = color_space == 0 ? 1 : 0; // DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709 only
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swapchain_SetColorSpace1(SwapChain *s, UINT color_space) { return S_OK; }

static void swapchain_destroy(Object *o) {
    SwapChain *s = (SwapChain *)o;
    for (int i = 0; i < 16; i++)
        if (s->buffers[i]) object_release(&s->buffers[i]->object);
    [s->layer release];
    free(s);
}

static void *swapchain_vtbl[SWAPCHAIN_SLOT_COUNT];
static const IID *const swapchain_iids[] = {&IID_IDXGISwapChain3, &IID_IDXGISwapChain2, &IID_IDXGISwapChain1,
                                            &IID_IDXGISwapChain,  &IID_IDXGIObject,     NULL};

static HRESULT swapchain_create(Device *device, CommandQueue *queue, void *hwnd, const SwapChainDesc1 *desc,
                                void **out) {
    if (!swapchain_vtbl[0]) {
        swapchain_vtbl[0] = com_QueryInterface;
        swapchain_vtbl[1] = com_AddRef;
        swapchain_vtbl[2] = com_Release;
        swapchain_vtbl[SLOT_SET_PRIVATE_DATA] = com_SetPrivateData;
        swapchain_vtbl[SLOT_SET_PRIVATE_DATA_INTERFACE] = com_SetPrivateDataInterface;
        swapchain_vtbl[SLOT_GET_PRIVATE_DATA] = com_GetPrivateData;
        swapchain_vtbl[SWAPCHAIN_GET_DEVICE] = com_GetDevice;
        swapchain_vtbl[SWAPCHAIN_PRESENT] = swapchain_Present;
        swapchain_vtbl[SWAPCHAIN_GET_BUFFER] = swapchain_GetBuffer;
        swapchain_vtbl[SWAPCHAIN_SET_FULLSCREEN_STATE] = swapchain_SetFullscreenState;
        swapchain_vtbl[SWAPCHAIN_GET_FULLSCREEN_STATE] = swapchain_GetFullscreenState;
        swapchain_vtbl[SWAPCHAIN_RESIZE_BUFFERS] = swapchain_ResizeBuffers;
        swapchain_vtbl[SWAPCHAIN_GET_FRAME_STATISTICS] = swapchain_GetFrameStatistics;
        swapchain_vtbl[SWAPCHAIN_GET_LAST_PRESENT_COUNT] = swapchain_GetLastPresentCount;
        swapchain_vtbl[SWAPCHAIN1_GET_DESC1] = swapchain_GetDesc1;
        swapchain_vtbl[SWAPCHAIN1_GET_HWND] = swapchain_GetHwnd;
        swapchain_vtbl[SWAPCHAIN1_PRESENT1] = swapchain_Present1;
        swapchain_vtbl[SWAPCHAIN2_SET_MAXIMUM_FRAME_LATENCY] = swapchain_SetMaximumFrameLatency;
        swapchain_vtbl[SWAPCHAIN2_GET_MAXIMUM_FRAME_LATENCY] = swapchain_GetMaximumFrameLatency;
        swapchain_vtbl[SWAPCHAIN2_GET_FRAME_LATENCY_WAITABLE_OBJECT] = swapchain_GetFrameLatencyWaitableObject;
        swapchain_vtbl[SWAPCHAIN3_GET_CURRENT_BACK_BUFFER_INDEX] = swapchain_GetCurrentBackBufferIndex;
        swapchain_vtbl[SWAPCHAIN3_CHECK_COLOR_SPACE_SUPPORT] = swapchain_CheckColorSpaceSupport;
        swapchain_vtbl[SWAPCHAIN3_SET_COLOR_SPACE1] = swapchain_SetColorSpace1;
        swapchain_vtbl[SWAPCHAIN3_RESIZE_BUFFERS1] = swapchain_ResizeBuffers1;
        fill_unimplemented(swapchain_vtbl, sizeof swapchain_vtbl, "IDXGISwapChain3");
    }
    SwapChain *s = calloc(1, sizeof *s);
    object_init(&s->object, swapchain_vtbl, swapchain_iids, device);
    s->object.destroy = swapchain_destroy;
    s->queue = queue;
    s->hwnd = hwnd;
    s->desc = *desc;
    s->max_latency = 3;
    if (!s->desc.Width || !s->desc.Height) {
        int w, h;
        cocoa_window_size(hwnd, &w, &h);
        s->desc.Width = w;
        s->desc.Height = h;
    }

    // Install a CAMetalLayer as the window view's layer.
    double scale;
    NSView *view = (NSView *)cocoa_window_view(hwnd, &scale);
    s->layer = [[CAMetalLayer layer] retain];
    s->layer.device = device->mtl;
    s->layer.pixelFormat = swapchain_pixel_format(s->desc.Format);
    s->layer.framebufferOnly = NO; // the presented texture is a blit destination
    s->layer.contentsScale = scale;
    s->layer.displaySyncEnabled = getenv("D3D12_VSYNC") != NULL;
    void (^install_layer)(void) = ^{
      view.wantsLayer = YES;
      view.layer = s->layer;
    };
    if ([NSThread isMainThread]) // dispatch_sync to the main queue from the main thread would deadlock
        install_layer();
    else
        dispatch_sync(dispatch_get_main_queue(), install_layer);
    swapchain_create_buffers(s);

    static WINAPI HANDLE (*create_event)(void *, WINBOOL, WINBOOL, const WCHAR *);
    if (!create_event) create_event = shim_lookup("CreateEventW");
    s->latency_event = create_event(NULL, TRUE, TRUE, NULL); // manual reset, initially signaled

    D3D_LOG("swapchain %ux%u, %u buffers, format %d", s->desc.Width, s->desc.Height, s->desc.BufferCount,
            s->desc.Format);
    HRESULT hr = object_query(&s->object, &IID_IDXGISwapChain3, out);
    object_release(&s->object);
    return hr;
}

// ---------------------------------------------------------------- factory
typedef struct Factory {
    Object object;
} Factory;

static Factory g_factory;

static HRESULT STDMETHODCALLTYPE factory_EnumAdapters1(Factory *f, UINT index, void **adapter) {
    if (index != 0) {
        *adapter = NULL;
        return DXGI_ERROR_NOT_FOUND_HR;
    }
    return object_query(&adapter_get()->object, &IID_IDXGIAdapter1, adapter);
}

static HRESULT STDMETHODCALLTYPE factory_EnumWarpAdapter(Factory *f, REFIID iid, void **adapter) {
    return object_query(&adapter_get()->object, iid, adapter);
}

static HRESULT STDMETHODCALLTYPE factory_EnumAdapterByLuid(Factory *f, LUID luid, REFIID iid, void **adapter) {
    return object_query(&adapter_get()->object, iid, adapter);
}

static HRESULT STDMETHODCALLTYPE factory_MakeWindowAssociation(Factory *f, void *hwnd, UINT flags) { return S_OK; }
static WINBOOL STDMETHODCALLTYPE factory_IsCurrent(Factory *f) { return TRUE; }
static UINT STDMETHODCALLTYPE factory_GetCreationFlags(Factory *f) { return 0; }
static WINBOOL STDMETHODCALLTYPE factory_IsWindowedStereoEnabled(Factory *f) { return FALSE; }

#define DXGI_FEATURE_PRESENT_ALLOW_TEARING 0
static HRESULT STDMETHODCALLTYPE factory_CheckFeatureSupport(Factory *f, UINT feature, void *data, UINT size) {
    if (feature == DXGI_FEATURE_PRESENT_ALLOW_TEARING && size >= sizeof(WINBOOL)) {
        *(WINBOOL *)data = TRUE;
        return S_OK;
    }
    return E_NOTIMPL;
}

static HRESULT STDMETHODCALLTYPE factory_CreateSwapChainForHwnd(Factory *f, IUnknown *queue_object, void *hwnd,
                                                                const SwapChainDesc1 *desc, const void *fullscreen,
                                                                void *restrict_output, void **out) {
    CommandQueue *queue = (CommandQueue *)queue_object;
    return swapchain_create(queue->object.device, queue, hwnd, desc, out);
}

static HRESULT STDMETHODCALLTYPE adapter_GetParent(Adapter *a, REFIID iid, void **parent) {
    return object_query(&g_factory.object, iid, parent);
}

static void *factory_vtbl[FACTORY_SLOT_COUNT];
static const IID *const factory_iids[] = {
    &IID_IDXGIFactory5, &IID_IDXGIFactory4, &IID_IDXGIFactory3, &IID_IDXGIFactory2,
    &IID_IDXGIFactory1, &IID_IDXGIFactory,  &IID_IDXGIObject,   NULL};

HRESULT dxgi_create_factory(UINT flags, REFIID iid, void **out) {
    if (!g_factory.object.vtbl) {
        factory_vtbl[0] = com_QueryInterface;
        factory_vtbl[1] = com_AddRef;
        factory_vtbl[2] = com_Release;
        factory_vtbl[SLOT_SET_PRIVATE_DATA] = com_SetPrivateData;
        factory_vtbl[SLOT_SET_PRIVATE_DATA_INTERFACE] = com_SetPrivateDataInterface;
        factory_vtbl[SLOT_GET_PRIVATE_DATA] = com_GetPrivateData;
        factory_vtbl[FACTORY_ENUM_ADAPTERS] = factory_EnumAdapters1;
        factory_vtbl[FACTORY_MAKE_WINDOW_ASSOCIATION] = factory_MakeWindowAssociation;
        factory_vtbl[FACTORY1_ENUM_ADAPTERS1] = factory_EnumAdapters1;
        factory_vtbl[FACTORY1_IS_CURRENT] = factory_IsCurrent;
        factory_vtbl[FACTORY2_IS_WINDOWED_STEREO_ENABLED] = factory_IsWindowedStereoEnabled;
        factory_vtbl[FACTORY2_CREATE_SWAP_CHAIN_FOR_HWND] = factory_CreateSwapChainForHwnd;
        factory_vtbl[FACTORY3_GET_CREATION_FLAGS] = factory_GetCreationFlags;
        factory_vtbl[FACTORY4_ENUM_ADAPTER_BY_LUID] = factory_EnumAdapterByLuid;
        factory_vtbl[FACTORY4_ENUM_WARP_ADAPTER] = factory_EnumWarpAdapter;
        factory_vtbl[FACTORY5_CHECK_FEATURE_SUPPORT] = factory_CheckFeatureSupport;
        fill_unimplemented(factory_vtbl, sizeof factory_vtbl, "IDXGIFactory5");
        object_init(&g_factory.object, factory_vtbl, factory_iids, NULL);
    }
    return object_query(&g_factory.object, iid, out);
}

// ---------------------------------------------------------------- entry points the game imports
static WINAPI HRESULT entry_CreateDXGIFactory2(UINT flags, REFIID iid, void **out) {
    return dxgi_create_factory(flags, iid, out);
}

// d3d12.dll ordinal 101 is D3D12CreateDevice(adapter, minimum_feature_level, iid, out).
static WINAPI HRESULT entry_D3D12CreateDevice(void *adapter, D3D_FEATURE_LEVEL minimum, REFIID iid,
                                                              void **out) {
    if (minimum > D3D_FEATURE_LEVEL_12_1) return E_INVALIDARG;
    return d3d12_create_device(adapter, iid, out);
}

void d3d12_backend_register(void) {
    shim_register("CreateDXGIFactory2", (void *)entry_CreateDXGIFactory2);
    shim_register("d3d12.dll#101", (void *)entry_D3D12CreateDevice);
}

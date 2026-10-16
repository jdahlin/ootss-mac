// Descriptor heaps and views.
//
// A shader-visible heap is an MTLBuffer of DescriptorEntry (Metal's descriptor table format), so the
// game's GPU descriptor handles are plain GPU addresses into it. CPU handles are pseudo handles:
// (heap id << 40) | (index * DESCRIPTOR_STRIDE), resolved through a small registry. Render and depth
// targets keep their binding information in a parallel View array, since the CPU binds them.
#include "objects.h"

// ---------------------------------------------------------------- registry
#define MAX_HEAPS         1024
#define HANDLE_INDEX_BITS 40

static DescriptorHeap *g_heaps[MAX_HEAPS];
static atomic_uint g_next_heap_id = 1;

DescriptorHeap *descriptor_heap_for_handle(D3D12_CPU_DESCRIPTOR_HANDLE handle, uint32_t *index) {
    uint64_t id = handle.ptr >> HANDLE_INDEX_BITS;
    if (id == 0 || id >= MAX_HEAPS || !g_heaps[id]) return NULL;
    uint64_t offset = handle.ptr & ((1ull << HANDLE_INDEX_BITS) - 1);
    *index = (uint32_t)(offset / DESCRIPTOR_STRIDE);
    return *index < g_heaps[id]->desc.NumDescriptors ? g_heaps[id] : NULL;
}

static DescriptorEntry *entry_for(D3D12_CPU_DESCRIPTOR_HANDLE h, View **view) {
    uint32_t index;
    DescriptorHeap *heap = descriptor_heap_for_handle(h, &index);
    if (!heap) {
        D3D_TODO("descriptor handle %#llx is not in any heap", (unsigned long long)h.ptr);
        return NULL;
    }
    if (view) *view = &heap->views[index];
    return (DescriptorEntry *)heap->table.contents + index;
}

const View *descriptor_view(D3D12_CPU_DESCRIPTOR_HANDLE handle) {
    View *view = NULL;
    return entry_for(handle, &view) ? view : NULL;
}

void descriptors_copy(D3D12_CPU_DESCRIPTOR_HANDLE dst, D3D12_CPU_DESCRIPTOR_HANDLE src, UINT count) {
    uint32_t di, si;
    DescriptorHeap *dh = descriptor_heap_for_handle(dst, &di), *sh = descriptor_heap_for_handle(src, &si);
    if (!dh || !sh) return;
    count = MIN(count, MIN(dh->desc.NumDescriptors - di, sh->desc.NumDescriptors - si));
    memmove((DescriptorEntry *)dh->table.contents + di, (DescriptorEntry *)sh->table.contents + si,
            count * sizeof(DescriptorEntry));
    memmove(dh->views + di, sh->views + si, count * sizeof(View));
}

// ---------------------------------------------------------------- ID3D12DescriptorHeap
static void descriptor_heap_destroy(Object *o) {
    DescriptorHeap *h = (DescriptorHeap *)o;
    g_heaps[h->id] = NULL;
    [h->table release];
    free(h->views);
    free(h);
}

static D3D12_DESCRIPTOR_HEAP_DESC *STDMETHODCALLTYPE heap_GetDesc(DescriptorHeap *h, D3D12_DESCRIPTOR_HEAP_DESC *ret) {
    *ret = h->desc;
    return ret;
}

static D3D12_CPU_DESCRIPTOR_HANDLE *STDMETHODCALLTYPE heap_GetCPUStart(DescriptorHeap *h,
                                                                       D3D12_CPU_DESCRIPTOR_HANDLE *ret) {
    ret->ptr = (SIZE_T)h->id << HANDLE_INDEX_BITS;
    return ret;
}

static D3D12_GPU_DESCRIPTOR_HANDLE *STDMETHODCALLTYPE heap_GetGPUStart(DescriptorHeap *h,
                                                                       D3D12_GPU_DESCRIPTOR_HANDLE *ret) {
    ret->ptr = (h->desc.Flags & D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE) ? h->table.gpuAddress : 0;
    return ret;
}

static ID3D12DescriptorHeapVtbl heap_vtbl = {
    ID3D12_OBJECT_METHODS,
    .GetDevice = (void *)com_GetDevice,
    .GetDesc = (void *)heap_GetDesc,
    .GetCPUDescriptorHandleForHeapStart = (void *)heap_GetCPUStart,
    .GetGPUDescriptorHandleForHeapStart = (void *)heap_GetGPUStart,
};
static const IID *const heap_iids[] = {&IID_ID3D12DescriptorHeap, &IID_ID3D12Pageable, &IID_ID3D12DeviceChild,
                                       &IID_ID3D12Object, NULL};

HRESULT descriptor_heap_create(Device *device, const D3D12_DESCRIPTOR_HEAP_DESC *desc, REFIID iid, void **out) {
    static bool vtbl_ready;
    if (!vtbl_ready++) FILL_UNIMPLEMENTED(heap_vtbl);
    uint32_t id = atomic_fetch_add(&g_next_heap_id, 1);
    if (id >= MAX_HEAPS) return E_OUTOFMEMORY;

    DescriptorHeap *h = calloc(1, sizeof *h);
    object_init(&h->object, &heap_vtbl, heap_iids, device);
    h->object.destroy = descriptor_heap_destroy;
    h->desc = *desc;
    h->id = id;
    UINT count = MAX(desc->NumDescriptors, 1);
    h->table = [device->mtl newBufferWithLength:count * sizeof(DescriptorEntry)
                                        options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
    h->views = calloc(count, sizeof(View));
    residency_add(h->table);
    g_heaps[id] = h;
    HRESULT hr = object_query(&h->object, iid, out);
    object_release(&h->object);
    return hr;
}

// ---------------------------------------------------------------- views
static void clear_slot(DescriptorEntry *entry, View *view, ViewKind kind) {
    memset(entry, 0, sizeof *entry);
    memset(view, 0, sizeof *view);
    view->kind = kind;
}

// Number of levels or slices when the view says "all remaining" (-1).
static NSUInteger remaining(UINT requested, NSUInteger available, UINT first) {
    return requested == (UINT)-1 ? available - MIN(first, available) : requested;
}

void descriptor_create_cbv(Device *device, const D3D12_CONSTANT_BUFFER_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE h) {
    View *view;
    DescriptorEntry *entry = entry_for(h, &view);
    if (!entry) return;
    clear_slot(entry, view, VIEW_CBV);
    if (desc) binding_set_buffer(entry, desc->BufferLocation, desc->SizeInBytes);
}

// Buffer views: raw and structured buffers are addressed directly. Typed buffers would need a texture view
// of the buffer; they are treated as raw until the game shows one.
static void set_buffer_descriptor(DescriptorEntry *entry, Resource *r, UINT64 first, UINT count, UINT stride,
                                  bool typed) {
    if (typed) D3D_TODO("typed buffer view is treated as a raw buffer");
    if (!stride) stride = 4;
    binding_set_buffer(entry, r->buffer.gpuAddress + first * stride, (uint32_t)MIN((UINT64)count * stride, UINT32_MAX));
}

static NSRange all_levels(Resource *r) { return NSMakeRange(0, r->texture.mipmapLevelCount); }
static NSRange all_slices(Resource *r) { return NSMakeRange(0, r->texture.arrayLength); }

void descriptor_create_srv(Device *device, Resource *r, const D3D12_SHADER_RESOURCE_VIEW_DESC *desc,
                           D3D12_CPU_DESCRIPTOR_HANDLE h) {
    View *view;
    DescriptorEntry *entry = entry_for(h, &view);
    if (!entry) return;
    clear_slot(entry, view, VIEW_SRV);
    if (!r) return; // a null descriptor reads zeros
    view->resource = r;

    if (r->buffer) {
        if (!desc) return binding_set_buffer(entry, r->buffer.gpuAddress, (uint32_t)r->buffer.length);
        const D3D12_BUFFER_SRV *b = &desc->Buffer;
        bool raw = b->Flags & D3D12_BUFFER_SRV_FLAG_RAW;
        set_buffer_descriptor(entry, r, b->FirstElement, b->NumElements, raw ? 4 : b->StructureByteStride,
                              !raw && !b->StructureByteStride && desc->Format != DXGI_FORMAT_UNKNOWN);
        return;
    }

    DXGI_FORMAT dxgi = desc && desc->Format != DXGI_FORMAT_UNKNOWN ? desc->Format : r->desc.Format;
    MTLPixelFormat format = desc && desc->Format != DXGI_FORMAT_UNKNOWN ? mtl_format(dxgi) : r->pixel_format;
    NSRange levels = all_levels(r), slices = all_slices(r);
    MTLTextureType type = MTLTextureType2DArray;
    float min_lod = 0;
    if (desc) {
        switch (desc->ViewDimension) {
        case D3D12_SRV_DIMENSION_TEXTURE1D:
        case D3D12_SRV_DIMENSION_TEXTURE2D:
            levels = NSMakeRange(desc->Texture2D.MostDetailedMip,
                                 remaining(desc->Texture2D.MipLevels, levels.length, desc->Texture2D.MostDetailedMip));
            slices = NSMakeRange(0, 1);
            min_lod = desc->Texture2D.ResourceMinLODClamp;
            break;
        case D3D12_SRV_DIMENSION_TEXTURE1DARRAY:
        case D3D12_SRV_DIMENSION_TEXTURE2DARRAY:
            levels = NSMakeRange(
                desc->Texture2DArray.MostDetailedMip,
                remaining(desc->Texture2DArray.MipLevels, levels.length, desc->Texture2DArray.MostDetailedMip));
            slices = NSMakeRange(
                desc->Texture2DArray.FirstArraySlice,
                remaining(desc->Texture2DArray.ArraySize, slices.length, desc->Texture2DArray.FirstArraySlice));
            min_lod = desc->Texture2DArray.ResourceMinLODClamp;
            break;
        case D3D12_SRV_DIMENSION_TEXTURE2DMS:
            levels = NSMakeRange(0, 1);
            slices = NSMakeRange(0, 1);
            type = r->texture.textureType;
            break;
        case D3D12_SRV_DIMENSION_TEXTURE2DMSARRAY:
            levels = NSMakeRange(0, 1);
            slices = NSMakeRange(
                desc->Texture2DMSArray.FirstArraySlice,
                remaining(desc->Texture2DMSArray.ArraySize, slices.length, desc->Texture2DMSArray.FirstArraySlice));
            type = r->texture.textureType;
            break;
        case D3D12_SRV_DIMENSION_TEXTURE3D:
            levels = NSMakeRange(desc->Texture3D.MostDetailedMip,
                                 remaining(desc->Texture3D.MipLevels, levels.length, desc->Texture3D.MostDetailedMip));
            slices = NSMakeRange(0, 1);
            type = MTLTextureType3D;
            min_lod = desc->Texture3D.ResourceMinLODClamp;
            break;
        case D3D12_SRV_DIMENSION_TEXTURECUBE:
            levels =
                NSMakeRange(desc->TextureCube.MostDetailedMip,
                            remaining(desc->TextureCube.MipLevels, levels.length, desc->TextureCube.MostDetailedMip));
            slices = NSMakeRange(0, 6);
            type = MTLTextureTypeCubeArray;
            min_lod = desc->TextureCube.ResourceMinLODClamp;
            break;
        case D3D12_SRV_DIMENSION_TEXTURECUBEARRAY:
            levels = NSMakeRange(
                desc->TextureCubeArray.MostDetailedMip,
                remaining(desc->TextureCubeArray.MipLevels, levels.length, desc->TextureCubeArray.MostDetailedMip));
            slices = NSMakeRange(desc->TextureCubeArray.First2DArrayFace, desc->TextureCubeArray.NumCubes * 6);
            type = MTLTextureTypeCubeArray;
            min_lod = desc->TextureCubeArray.ResourceMinLODClamp;
            break;
        default: D3D_TODO("SRV dimension %d", desc->ViewDimension); break;
        }
    } else if (r->texture.textureType == MTLTextureType3D) {
        type = MTLTextureType3D;
    }
    id<MTLTexture> texture = resource_view(r, format, type, levels, slices);
    if (texture) binding_set_texture(entry, texture, min_lod);
}

void descriptor_create_uav(Device *device, Resource *r, const D3D12_UNORDERED_ACCESS_VIEW_DESC *desc,
                           D3D12_CPU_DESCRIPTOR_HANDLE h) {
    View *view;
    DescriptorEntry *entry = entry_for(h, &view);
    if (!entry) return;
    clear_slot(entry, view, VIEW_UAV);
    if (!r) return;
    view->resource = r;

    if (r->buffer) {
        if (!desc) return binding_set_buffer(entry, r->buffer.gpuAddress, (uint32_t)r->buffer.length);
        const D3D12_BUFFER_UAV *b = &desc->Buffer;
        if (b->CounterOffsetInBytes) D3D_TODO("UAV counters are not supported");
        bool raw = b->Flags & D3D12_BUFFER_UAV_FLAG_RAW;
        set_buffer_descriptor(entry, r, b->FirstElement, b->NumElements, raw ? 4 : b->StructureByteStride,
                              !raw && !b->StructureByteStride && desc->Format != DXGI_FORMAT_UNKNOWN);
        return;
    }

    MTLPixelFormat format = desc && desc->Format != DXGI_FORMAT_UNKNOWN ? mtl_format(desc->Format) : r->pixel_format;
    NSRange levels = NSMakeRange(0, 1), slices = all_slices(r);
    MTLTextureType type = MTLTextureType2DArray;
    if (desc) {
        switch (desc->ViewDimension) {
        case D3D12_UAV_DIMENSION_TEXTURE1D:
        case D3D12_UAV_DIMENSION_TEXTURE2D:
            levels = NSMakeRange(desc->Texture2D.MipSlice, 1);
            slices = NSMakeRange(0, 1);
            break;
        case D3D12_UAV_DIMENSION_TEXTURE1DARRAY:
        case D3D12_UAV_DIMENSION_TEXTURE2DARRAY:
            levels = NSMakeRange(desc->Texture2DArray.MipSlice, 1);
            slices = NSMakeRange(
                desc->Texture2DArray.FirstArraySlice,
                remaining(desc->Texture2DArray.ArraySize, slices.length, desc->Texture2DArray.FirstArraySlice));
            break;
        case D3D12_UAV_DIMENSION_TEXTURE3D:
            levels = NSMakeRange(desc->Texture3D.MipSlice, 1);
            slices = NSMakeRange(0, 1);
            type = MTLTextureType3D;
            break;
        default: D3D_TODO("UAV dimension %d", desc->ViewDimension); break;
        }
    }
    id<MTLTexture> texture = resource_view(r, format, type, levels, slices);
    if (texture) binding_set_texture(entry, texture, 0);
}

void descriptor_create_rtv(Device *device, Resource *r, const D3D12_RENDER_TARGET_VIEW_DESC *desc,
                           D3D12_CPU_DESCRIPTOR_HANDLE h) {
    View *view;
    DescriptorEntry *entry = entry_for(h, &view);
    if (!entry) return;
    clear_slot(entry, view, VIEW_RTV);
    view->resource = r;
    view->format = desc && desc->Format != DXGI_FORMAT_UNKNOWN ? desc->Format : (r ? r->desc.Format : 0);
    view->slice_count = 1;
    if (!desc) return;
    view->dimension = desc->ViewDimension;
    switch (desc->ViewDimension) {
    case D3D12_RTV_DIMENSION_TEXTURE2D: view->mip = desc->Texture2D.MipSlice; break;
    case D3D12_RTV_DIMENSION_TEXTURE2DARRAY:
        view->mip = desc->Texture2DArray.MipSlice;
        view->first_slice = desc->Texture2DArray.FirstArraySlice;
        view->slice_count = desc->Texture2DArray.ArraySize;
        break;
    case D3D12_RTV_DIMENSION_TEXTURE2DMSARRAY:
        view->first_slice = desc->Texture2DMSArray.FirstArraySlice;
        view->slice_count = desc->Texture2DMSArray.ArraySize;
        break;
    case D3D12_RTV_DIMENSION_TEXTURE3D:
        view->mip = desc->Texture3D.MipSlice;
        view->first_slice = desc->Texture3D.FirstWSlice;
        view->slice_count = desc->Texture3D.WSize;
        break;
    default: break;
    }
}

void descriptor_create_dsv(Device *device, Resource *r, const D3D12_DEPTH_STENCIL_VIEW_DESC *desc,
                           D3D12_CPU_DESCRIPTOR_HANDLE h) {
    View *view;
    DescriptorEntry *entry = entry_for(h, &view);
    if (!entry) return;
    clear_slot(entry, view, VIEW_DSV);
    view->resource = r;
    view->format = desc && desc->Format != DXGI_FORMAT_UNKNOWN ? desc->Format : (r ? r->desc.Format : 0);
    view->slice_count = 1;
    if (!desc) return;
    view->dimension = desc->ViewDimension;
    switch (desc->ViewDimension) {
    case D3D12_DSV_DIMENSION_TEXTURE2D: view->mip = desc->Texture2D.MipSlice; break;
    case D3D12_DSV_DIMENSION_TEXTURE2DARRAY:
        view->mip = desc->Texture2DArray.MipSlice;
        view->first_slice = desc->Texture2DArray.FirstArraySlice;
        view->slice_count = desc->Texture2DArray.ArraySize;
        break;
    case D3D12_DSV_DIMENSION_TEXTURE2DMSARRAY:
        view->first_slice = desc->Texture2DMSArray.FirstArraySlice;
        view->slice_count = desc->Texture2DMSArray.ArraySize;
        break;
    default: break;
    }
}

// ---------------------------------------------------------------- samplers
static MTLSamplerAddressMode address_mode(D3D12_TEXTURE_ADDRESS_MODE m) {
    switch (m) {
    case D3D12_TEXTURE_ADDRESS_MODE_MIRROR: return MTLSamplerAddressModeMirrorRepeat;
    case D3D12_TEXTURE_ADDRESS_MODE_CLAMP: return MTLSamplerAddressModeClampToEdge;
    case D3D12_TEXTURE_ADDRESS_MODE_BORDER: return MTLSamplerAddressModeClampToBorderColor;
    case D3D12_TEXTURE_ADDRESS_MODE_MIRROR_ONCE: return MTLSamplerAddressModeMirrorClampToEdge;
    default: return MTLSamplerAddressModeRepeat;
    }
}

MTLCompareFunction compare_function(D3D12_COMPARISON_FUNC f) {
    switch (f) {
    case D3D12_COMPARISON_FUNC_NEVER: return MTLCompareFunctionNever;
    case D3D12_COMPARISON_FUNC_LESS: return MTLCompareFunctionLess;
    case D3D12_COMPARISON_FUNC_EQUAL: return MTLCompareFunctionEqual;
    case D3D12_COMPARISON_FUNC_LESS_EQUAL: return MTLCompareFunctionLessEqual;
    case D3D12_COMPARISON_FUNC_GREATER: return MTLCompareFunctionGreater;
    case D3D12_COMPARISON_FUNC_NOT_EQUAL: return MTLCompareFunctionNotEqual;
    case D3D12_COMPARISON_FUNC_GREATER_EQUAL: return MTLCompareFunctionGreaterEqual;
    default: return MTLCompareFunctionAlways;
    }
}

// D3D12_FILTER: bits 0-1 mip, 2-3 mag, 4-5 min (1 = linear), 0x40 anisotropic, bits 7-8 reduction (1 = comparison).
#define FILTER_MIP_LINEAR           0x01
#define FILTER_MAG_LINEAR           0x04
#define FILTER_MIN_LINEAR           0x10
#define FILTER_ANISOTROPIC          0x40
#define FILTER_REDUCTION_SHIFT      7
#define FILTER_REDUCTION_COMPARISON 1

id<MTLSamplerState> sampler_state(Device *device, const D3D12_SAMPLER_DESC *desc) {
    static struct {
        D3D12_SAMPLER_DESC desc;
        id<MTLSamplerState> state;
    } cache[512];
    static int count;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < count; i++) {
        if (!memcmp(&cache[i].desc, desc, sizeof *desc)) {
            id<MTLSamplerState> hit = cache[i].state;
            pthread_mutex_unlock(&lock);
            return hit;
        }
    }
    MTLSamplerDescriptor *d = [[MTLSamplerDescriptor alloc] init];
    d.minFilter = (desc->Filter & FILTER_MIN_LINEAR) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.magFilter = (desc->Filter & FILTER_MAG_LINEAR) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = (desc->Filter & FILTER_MIP_LINEAR) ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
    d.maxAnisotropy = (desc->Filter & FILTER_ANISOTROPIC) ? MAX(MIN(desc->MaxAnisotropy, 16), 1) : 1;
    d.sAddressMode = address_mode(desc->AddressU);
    d.tAddressMode = address_mode(desc->AddressV);
    d.rAddressMode = address_mode(desc->AddressW);
    d.lodMinClamp = desc->MinLOD;
    d.lodMaxClamp = desc->MaxLOD;
    if (((desc->Filter >> FILTER_REDUCTION_SHIFT) & 3) == FILTER_REDUCTION_COMPARISON)
        d.compareFunction = compare_function(desc->ComparisonFunc);
    const FLOAT *b = desc->BorderColor;
    d.borderColor = b[3] == 0                               ? MTLSamplerBorderColorTransparentBlack
                    : (b[0] == 0 && b[1] == 0 && b[2] == 0) ? MTLSamplerBorderColorOpaqueBlack
                                                            : MTLSamplerBorderColorOpaqueWhite;
    d.supportArgumentBuffers = YES;
    id<MTLSamplerState> state = [device->mtl newSamplerStateWithDescriptor:d];
    [d release];
    if (count < 512) cache[count++] = (typeof(cache[0])){*desc, state}; // kept for the process lifetime
    pthread_mutex_unlock(&lock);
    return state;
}

void descriptor_create_sampler(Device *device, const D3D12_SAMPLER_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE h) {
    View *view;
    DescriptorEntry *entry = entry_for(h, &view);
    if (!entry) return;
    clear_slot(entry, view, VIEW_SAMPLER);
    binding_set_sampler(entry, sampler_state(device, desc), desc->MipLODBias);
}

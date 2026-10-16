// Resources, their Metal views, residency, and the GPU address map.
#include "objects.h"

// ---------------------------------------------------------------- residency
static id<MTLResidencySet> g_residency;
static bool g_residency_dirty;
static pthread_mutex_t g_residency_lock = PTHREAD_MUTEX_INITIALIZER;

static id<MTLResidencySet> residency_set(void) { // lock held
    if (!g_residency) {
        MTLResidencySetDescriptor *desc = [[MTLResidencySetDescriptor alloc] init];
        desc.label = @"all D3D12 allocations";
        desc.initialCapacity = 1 << 15;
        NSError *error = nil;
        g_residency = [backend_mtl_device() newResidencySetWithDescriptor:desc error:&error];
        [desc release];
        if (!g_residency) D3D_LOG("cannot create a residency set: %s", error.localizedDescription.UTF8String);
    }
    return g_residency;
}

void residency_add(id<MTLAllocation> allocation) {
    pthread_mutex_lock(&g_residency_lock);
    [residency_set() addAllocation:allocation];
    g_residency_dirty = true;
    pthread_mutex_unlock(&g_residency_lock);
}

void residency_attach(Device *device, id<MTLCommandQueue> queue) {
    pthread_mutex_lock(&g_residency_lock);
    [queue addResidencySet:residency_set()];
    pthread_mutex_unlock(&g_residency_lock);
}

void residency_commit(void) {
    pthread_mutex_lock(&g_residency_lock);
    if (g_residency_dirty) {
        [g_residency commit];
        g_residency_dirty = false;
    }
    pthread_mutex_unlock(&g_residency_lock);
}

// ---------------------------------------------------------------- GPU address map (buffers)
typedef struct {
    uint64_t start, end;
    id<MTLBuffer> buffer;
} AddressRange;

static AddressRange *g_ranges;
static size_t g_range_count, g_range_capacity;
static pthread_mutex_t g_ranges_lock = PTHREAD_MUTEX_INITIALIZER;

static void address_map_add(id<MTLBuffer> buffer) {
    pthread_mutex_lock(&g_ranges_lock);
    if (g_range_count == g_range_capacity) {
        g_range_capacity = g_range_capacity ? g_range_capacity * 2 : 256;
        g_ranges = realloc(g_ranges, g_range_capacity * sizeof *g_ranges);
    }
    uint64_t start = buffer.gpuAddress;
    size_t i = g_range_count;
    while (i > 0 && g_ranges[i - 1].start > start) {
        g_ranges[i] = g_ranges[i - 1];
        i--;
    }
    g_ranges[i] = (AddressRange){start, start + buffer.length, buffer};
    g_range_count++;
    pthread_mutex_unlock(&g_ranges_lock);
}

static void address_map_remove(id<MTLBuffer> buffer) {
    pthread_mutex_lock(&g_ranges_lock);
    for (size_t i = 0; i < g_range_count; i++) {
        if (g_ranges[i].buffer == buffer) {
            memmove(&g_ranges[i], &g_ranges[i + 1], (g_range_count - i - 1) * sizeof *g_ranges);
            g_range_count--;
            break;
        }
    }
    pthread_mutex_unlock(&g_ranges_lock);
}

bool buffer_for_address(uint64_t gpu_address, id<MTLBuffer> *buffer, uint64_t *offset) {
    bool found = false;
    pthread_mutex_lock(&g_ranges_lock);
    size_t lo = 0, hi = g_range_count;
    while (lo < hi) { // last range starting at or before the address
        size_t mid = (lo + hi) / 2;
        if (g_ranges[mid].start <= gpu_address)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo > 0 && gpu_address < g_ranges[lo - 1].end) {
        *buffer = g_ranges[lo - 1].buffer;
        *offset = gpu_address - g_ranges[lo - 1].start;
        found = true;
    }
    pthread_mutex_unlock(&g_ranges_lock);
    return found;
}

// ---------------------------------------------------------------- ID3D12Resource
static void resource_destroy(Object *o) {
    Resource *r = (Resource *)o;
    if (r->buffer) address_map_remove(r->buffer);
    for (int i = 0; i < r->view_count; i++) [r->views[i].texture release];
    free(r->views);
    [r->buffer release];
    [r->texture release];
    free(r);
}

static HRESULT STDMETHODCALLTYPE resource_Map(Resource *r, UINT subresource, const D3D12_RANGE *read, void **data) {
    if (!r->buffer) return E_INVALIDARG; // only buffers live in CPU-visible heaps here
    if (data) *data = r->buffer.contents;
    return S_OK;
}

static void STDMETHODCALLTYPE resource_Unmap(Resource *r, UINT subresource, const D3D12_RANGE *written) {}

static D3D12_RESOURCE_DESC *STDMETHODCALLTYPE resource_GetDesc(Resource *r, D3D12_RESOURCE_DESC *ret) {
    *ret = r->desc;
    return ret;
}

static D3D12_GPU_VIRTUAL_ADDRESS STDMETHODCALLTYPE resource_GetGPUVirtualAddress(Resource *r) {
    return r->buffer ? r->buffer.gpuAddress : 0;
}

static HRESULT STDMETHODCALLTYPE resource_GetHeapProperties(Resource *r, D3D12_HEAP_PROPERTIES *props,
                                                            D3D12_HEAP_FLAGS *flags) {
    if (props) *props = (D3D12_HEAP_PROPERTIES){.Type = r->heap_type, .CreationNodeMask = 1, .VisibleNodeMask = 1};
    if (flags) *flags = D3D12_HEAP_FLAG_NONE;
    return S_OK;
}

static ID3D12ResourceVtbl resource_vtbl = {
    ID3D12_OBJECT_METHODS,
    .GetDevice = (void *)com_GetDevice,
    .Map = (void *)resource_Map,
    .Unmap = (void *)resource_Unmap,
    .GetDesc = (void *)resource_GetDesc, // hidden result pointer, see common.h
    .GetGPUVirtualAddress = (void *)resource_GetGPUVirtualAddress,
    .GetHeapProperties = (void *)resource_GetHeapProperties,
};
static const IID *const resource_iids[] = {&IID_ID3D12Resource, &IID_ID3D12Pageable, &IID_ID3D12DeviceChild,
                                           &IID_ID3D12Object, NULL};

static Resource *resource_new(Device *device, const D3D12_RESOURCE_DESC *desc, D3D12_HEAP_TYPE heap_type) {
    static bool vtbl_ready;
    if (!vtbl_ready) {
        FILL_UNIMPLEMENTED(resource_vtbl);
        vtbl_ready = true;
    }
    Resource *r = calloc(1, sizeof *r);
    object_init(&r->object, &resource_vtbl, resource_iids, device);
    r->object.destroy = resource_destroy;
    r->desc = *desc;
    r->heap_type = heap_type;
    pthread_mutex_init(&r->views_lock, NULL);
    return r;
}

// ---------------------------------------------------------------- textures
static bool has_flag(const D3D12_RESOURCE_DESC *d, D3D12_RESOURCE_FLAGS f) { return (d->Flags & f) != 0; }

static MTLTextureType texture_type(const D3D12_RESOURCE_DESC *d) {
    if (d->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) return MTLTextureType3D;
    if (d->SampleDesc.Count > 1)
        return d->DepthOrArraySize > 1 ? MTLTextureType2DMultisampleArray : MTLTextureType2DMultisample;
    return MTLTextureType2DArray; // 1D and 2D textures are all arrays, as the converted shaders expect
}

static MTLTextureDescriptor *texture_descriptor(const D3D12_RESOURCE_DESC *d, MTLPixelFormat format) {
    MTLTextureDescriptor *t = [[MTLTextureDescriptor alloc] init];
    t.textureType = texture_type(d);
    t.pixelFormat = format;
    t.width = d->Width;
    t.height = d->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE1D ? 1 : d->Height;
    t.depth = d->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? d->DepthOrArraySize : 1;
    t.arrayLength = d->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? 1 : MAX(d->DepthOrArraySize, 1);
    t.mipmapLevelCount = d->MipLevels ? d->MipLevels : 1;
    t.sampleCount = d->SampleDesc.Count ? d->SampleDesc.Count : 1;
    t.storageMode = MTLStorageModePrivate;
    t.hazardTrackingMode = MTLHazardTrackingModeUntracked;
    t.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    if (has_flag(d, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET) || has_flag(d, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL))
        t.usage |= MTLTextureUsageRenderTarget;
    if (has_flag(d, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS)) t.usage |= MTLTextureUsageShaderWrite;
    return t;
}

HRESULT resource_create(Device *device, const D3D12_HEAP_PROPERTIES *heap, const D3D12_RESOURCE_DESC *desc, REFIID iid,
                        void **out) {
    Resource *r = resource_new(device, desc, heap ? heap->Type : D3D12_HEAP_TYPE_DEFAULT);
    if (desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) {
        r->buffer =
            [device->mtl newBufferWithLength:MAX(desc->Width, 1)
                                     options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
        if (r->buffer) {
            address_map_add(r->buffer);
            residency_add(r->buffer);
        }
    } else {
        r->pixel_format = mtl_resource_format(desc);
        MTLTextureDescriptor *t = texture_descriptor(desc, r->pixel_format);
        r->texture = [device->mtl newTextureWithDescriptor:t];
        [t release];
        if (r->texture) residency_add(r->texture);
    }
    if (!r->buffer && !r->texture) {
        D3D_LOG("could not create resource (dimension %d, %llu x %u, format %d)", desc->Dimension,
                (unsigned long long)desc->Width, desc->Height, desc->Format);
        free(r);
        return E_OUTOFMEMORY;
    }
    if (!out) { // existence check only
        object_release(&r->object);
        return S_FALSE;
    }
    HRESULT hr = object_query(&r->object, iid, out);
    object_release(&r->object);
    return hr;
}

Resource *resource_from_texture(Device *device, id<MTLTexture> texture, DXGI_FORMAT format) {
    D3D12_RESOURCE_DESC desc = {
        .Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D,
        .Width = texture.width,
        .Height = (UINT)texture.height,
        .DepthOrArraySize = (UINT16)texture.arrayLength,
        .MipLevels = 1,
        .Format = format,
        .SampleDesc = {1, 0},
        .Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
    };
    Resource *r = resource_new(device, &desc, D3D12_HEAP_TYPE_DEFAULT);
    r->texture = [texture retain];
    r->pixel_format = texture.pixelFormat;
    residency_add(texture);
    return r;
}

// Views are keyed by every property that changes the view; a view of the whole texture is the texture.
id<MTLTexture> resource_view(Resource *r, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices) {
    id<MTLTexture> base = r->texture;
    // Depth formats cannot be reinterpreted as color; only the stencil plane has a view format of its own.
    bool stencil_view = format == MTLPixelFormatX32_Stencil8 || format == MTLPixelFormatX24_Stencil8;
    bool depth_base = base.pixelFormat == MTLPixelFormatDepth16Unorm ||
                      base.pixelFormat == MTLPixelFormatDepth32Float ||
                      base.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                      base.pixelFormat == MTLPixelFormatDepth24Unorm_Stencil8;
    if (depth_base && !stencil_view) format = base.pixelFormat;
    if (format == base.pixelFormat && type == base.textureType && levels.location == 0 &&
        levels.length == base.mipmapLevelCount && slices.location == 0 &&
        (slices.length == base.arrayLength || type == MTLTextureType3D))
        return base;

    uint64_t key = (uint64_t)format | (uint64_t)type << 16 | (uint64_t)levels.location << 24 |
                   (uint64_t)levels.length << 32 | (uint64_t)slices.location << 40 | (uint64_t)slices.length << 52;
    pthread_mutex_lock(&r->views_lock);
    for (int i = 0; i < r->view_count; i++) {
        if (r->views[i].key == key) {
            id<MTLTexture> hit = r->views[i].texture;
            pthread_mutex_unlock(&r->views_lock);
            return hit;
        }
    }
    id<MTLTexture> view = [base newTextureViewWithPixelFormat:format textureType:type levels:levels slices:slices];
    if (!view)
        D3D_TODO("cannot view texture (format %lu, type %lu, %lu levels, %lu slices)", (unsigned long)format,
                 (unsigned long)type, (unsigned long)levels.length, (unsigned long)slices.length);
    if (view) {
        if (r->view_count == r->view_capacity) {
            r->view_capacity = r->view_capacity ? r->view_capacity * 2 : 4;
            r->views = realloc(r->views, r->view_capacity * sizeof *r->views);
        }
        r->views[r->view_count++] = (TextureView){key, view};
    }
    pthread_mutex_unlock(&r->views_lock);
    return view;
}

// ---------------------------------------------------------------- copyable footprints
UINT64 copyable_footprints(const D3D12_RESOURCE_DESC *desc, UINT first, UINT count, UINT64 base,
                           D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts, UINT *rows, UINT64 *row_sizes) {
    if (desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) {
        if (layouts)
            layouts[0] =
                (D3D12_PLACED_SUBRESOURCE_FOOTPRINT){base,
                                                     {desc->Format, (UINT)desc->Width, 1, 1,
                                                      (UINT)((desc->Width + D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1) &
                                                             ~(UINT64)(D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1))}};
        if (rows) rows[0] = 1;
        if (row_sizes) row_sizes[0] = desc->Width;
        return desc->Width;
    }
    UINT mips = desc->MipLevels ? desc->MipLevels : 1, block;
    UINT bytes = format_bytes_per_block(desc->Format, &block);
    UINT64 offset = base;
    for (UINT i = 0; i < count; i++) {
        UINT mip = (first + i) % mips;
        UINT width = MAX((UINT)(desc->Width >> mip), 1u), height = MAX(desc->Height >> mip, 1u);
        UINT depth = desc->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? MAX(desc->DepthOrArraySize >> mip, 1) : 1;
        UINT row_count = (height + block - 1) / block;
        UINT64 row_size = (UINT64)((width + block - 1) / block) * bytes;
        UINT pitch = (UINT)((row_size + D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1) &
                            ~(UINT64)(D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1));
        offset = (offset + D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT - 1) &
                 ~(UINT64)(D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT - 1);
        if (layouts)
            layouts[i] = (D3D12_PLACED_SUBRESOURCE_FOOTPRINT){offset, {desc->Format, width, height, depth, pitch}};
        if (rows) rows[i] = row_count;
        if (row_sizes) row_sizes[i] = row_size;
        offset += (UINT64)pitch * row_count * depth;
    }
    return offset - base;
}

// ---------------------------------------------------------------- ID3D12Heap
static D3D12_HEAP_DESC *STDMETHODCALLTYPE heap_GetDesc(Heap *h, D3D12_HEAP_DESC *ret) {
    *ret = h->desc;
    return ret;
}

static ID3D12HeapVtbl heap_vtbl = {ID3D12_OBJECT_METHODS, .GetDevice = (void *)com_GetDevice,
                                   .GetDesc = (void *)heap_GetDesc};
static const IID *const heap_iids[] = {&IID_ID3D12Heap, &IID_ID3D12Pageable, &IID_ID3D12DeviceChild, &IID_ID3D12Object,
                                       NULL};

static void free_object(Object *o) { free(o); }

HRESULT heap_create(Device *device, const D3D12_HEAP_DESC *desc, REFIID iid, void **out) {
    static bool vtbl_ready;
    if (!vtbl_ready++) FILL_UNIMPLEMENTED(heap_vtbl);
    Heap *h = calloc(1, sizeof *h);
    object_init(&h->object, &heap_vtbl, heap_iids, device);
    h->object.destroy = free_object;
    h->desc = *desc;
    HRESULT hr = object_query(&h->object, iid, out);
    object_release(&h->object);
    return hr;
}

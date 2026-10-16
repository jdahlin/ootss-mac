// Resources, heaps, descriptor heaps and the small state objects (root signatures, pipelines, command
// signatures).
#include "objects.h"

// ---------------------------------------------------------------- ID3D12Resource
static void resource_destroy(Object *o) {
    Resource *r = (Resource *)o;
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
    return r;
}

static MTLTextureDescriptor *texture_descriptor(const D3D12_RESOURCE_DESC *desc) {
    MTLTextureDescriptor *t = [MTLTextureDescriptor new];
    t.pixelFormat = mtl_format(desc->Format);
    t.width = desc->Width;
    t.height = desc->Height;
    t.mipmapLevelCount = desc->MipLevels ? desc->MipLevels : 1;
    t.sampleCount = desc->SampleDesc.Count ? desc->SampleDesc.Count : 1;
    t.storageMode = MTLStorageModePrivate;
    t.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    if (desc->Flags & (D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL))
        t.usage |= MTLTextureUsageRenderTarget;
    if (desc->Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS) t.usage |= MTLTextureUsageShaderWrite;
    switch (desc->Dimension) {
    case D3D12_RESOURCE_DIMENSION_TEXTURE1D:
        t.textureType = desc->DepthOrArraySize > 1 ? MTLTextureType1DArray : MTLTextureType1D;
        t.arrayLength = desc->DepthOrArraySize;
        break;
    case D3D12_RESOURCE_DIMENSION_TEXTURE3D:
        t.textureType = MTLTextureType3D;
        t.depth = desc->DepthOrArraySize;
        break;
    default: // TEXTURE2D
        t.textureType = t.sampleCount > 1            ? MTLTextureType2DMultisample
                        : desc->DepthOrArraySize > 1 ? MTLTextureType2DArray
                                                     : MTLTextureType2D;
        t.arrayLength = desc->DepthOrArraySize;
        break;
    }
    return t;
}

HRESULT resource_create(Device *device, const D3D12_HEAP_PROPERTIES *heap, const D3D12_RESOURCE_DESC *desc, REFIID iid,
                        void **out) {
    Resource *r = resource_new(device, desc, heap ? heap->Type : D3D12_HEAP_TYPE_DEFAULT);
    if (desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) {
        r->buffer = [device->mtl newBufferWithLength:desc->Width options:MTLResourceStorageModeShared];
    } else {
        MTLTextureDescriptor *t = texture_descriptor(desc);
        r->texture = [device->mtl newTextureWithDescriptor:t];
        [t release];
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
        .DepthOrArraySize = 1,
        .MipLevels = 1,
        .Format = format,
        .SampleDesc = {1, 0},
        .Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
    };
    Resource *r = resource_new(device, &desc, D3D12_HEAP_TYPE_DEFAULT);
    r->texture = [texture retain];
    return r;
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

static HRESULT give(Object *o, REFIID iid, void **out) {
    if (!out) {
        object_release(o);
        return S_FALSE;
    }
    HRESULT hr = object_query(o, iid, out);
    object_release(o);
    return hr;
}

static void free_object(Object *o) { free(o); }

HRESULT heap_create(Device *device, const D3D12_HEAP_DESC *desc, REFIID iid, void **out) {
    static bool vtbl_ready;
    if (!vtbl_ready++) FILL_UNIMPLEMENTED(heap_vtbl);
    Heap *h = calloc(1, sizeof *h);
    object_init(&h->object, &heap_vtbl, heap_iids, device);
    h->object.destroy = free_object;
    h->desc = *desc;
    return give(&h->object, iid, out);
}

// ---------------------------------------------------------------- ID3D12DescriptorHeap
static uint64_t g_next_gpu_descriptor_base = 0x100000000000ull; // GPU handles are opaque to the game

static void descriptor_heap_destroy(Object *o) {
    free(((DescriptorHeap *)o)->descriptors);
    free(o);
}

static D3D12_DESCRIPTOR_HEAP_DESC *STDMETHODCALLTYPE descriptor_heap_GetDesc(DescriptorHeap *h,
                                                                             D3D12_DESCRIPTOR_HEAP_DESC *ret) {
    *ret = h->desc;
    return ret;
}

static D3D12_CPU_DESCRIPTOR_HANDLE *STDMETHODCALLTYPE descriptor_heap_GetCPUStart(DescriptorHeap *h,
                                                                                  D3D12_CPU_DESCRIPTOR_HANDLE *ret) {
    ret->ptr = (SIZE_T)h->descriptors;
    return ret;
}

static D3D12_GPU_DESCRIPTOR_HANDLE *STDMETHODCALLTYPE descriptor_heap_GetGPUStart(DescriptorHeap *h,
                                                                                  D3D12_GPU_DESCRIPTOR_HANDLE *ret) {
    ret->ptr = h->gpu_base;
    return ret;
}

static ID3D12DescriptorHeapVtbl descriptor_heap_vtbl = {
    ID3D12_OBJECT_METHODS,
    .GetDevice = (void *)com_GetDevice,
    .GetDesc = (void *)descriptor_heap_GetDesc,
    .GetCPUDescriptorHandleForHeapStart = (void *)descriptor_heap_GetCPUStart,
    .GetGPUDescriptorHandleForHeapStart = (void *)descriptor_heap_GetGPUStart,
};
static const IID *const descriptor_heap_iids[] = {&IID_ID3D12DescriptorHeap, &IID_ID3D12Pageable,
                                                  &IID_ID3D12DeviceChild, &IID_ID3D12Object, NULL};

HRESULT descriptor_heap_create(Device *device, const D3D12_DESCRIPTOR_HEAP_DESC *desc, REFIID iid, void **out) {
    static bool vtbl_ready;
    if (!vtbl_ready++) FILL_UNIMPLEMENTED(descriptor_heap_vtbl);
    DescriptorHeap *h = calloc(1, sizeof *h);
    object_init(&h->object, &descriptor_heap_vtbl, descriptor_heap_iids, device);
    h->object.destroy = descriptor_heap_destroy;
    h->desc = *desc;
    h->descriptors = calloc(desc->NumDescriptors ? desc->NumDescriptors : 1, DESCRIPTOR_SIZE);
    if (desc->Flags & D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE) {
        h->gpu_base = g_next_gpu_descriptor_base;
        g_next_gpu_descriptor_base += ((uint64_t)desc->NumDescriptors * DESCRIPTOR_SIZE + 0xffff) & ~0xffffull;
    }
    return give(&h->object, iid, out);
}

// ---------------------------------------------------------------- root signatures, pipelines, command signatures
static void root_signature_destroy(Object *o) {
    free(((RootSignature *)o)->blob);
    free(o);
}

static ID3D12RootSignatureVtbl root_signature_vtbl = {ID3D12_OBJECT_METHODS, .GetDevice = (void *)com_GetDevice};
static const IID *const root_signature_iids[] = {&IID_ID3D12RootSignature, &IID_ID3D12DeviceChild, &IID_ID3D12Object,
                                                 NULL};

HRESULT root_signature_create(Device *device, const void *blob, size_t size, REFIID iid, void **out) {
    RootSignature *r = calloc(1, sizeof *r);
    object_init(&r->object, &root_signature_vtbl, root_signature_iids, device);
    r->object.destroy = root_signature_destroy;
    r->blob = malloc(size);
    memcpy(r->blob, blob, size);
    r->blob_size = size;
    return give(&r->object, iid, out);
}

static HRESULT STDMETHODCALLTYPE pipeline_GetCachedBlob(PipelineState *p, void **blob) {
    *blob = NULL;
    return E_NOTIMPL;
}

static ID3D12PipelineStateVtbl pipeline_state_vtbl = {ID3D12_OBJECT_METHODS, .GetDevice = (void *)com_GetDevice,
                                                      .GetCachedBlob = (void *)pipeline_GetCachedBlob};
static const IID *const pipeline_state_iids[] = {&IID_ID3D12PipelineState, &IID_ID3D12Pageable, &IID_ID3D12DeviceChild,
                                                 &IID_ID3D12Object, NULL};

static void pipeline_state_destroy(Object *o) {
    PipelineState *p = (PipelineState *)o;
    for (int i = 0; i < p->stage_count; i++) {
        [p->libraries[i] release];
        [p->functions[i] release];
    }
    free(p);
}

HRESULT pipeline_state_create(Device *device, bool compute, const D3D12_SHADER_BYTECODE *const *stages, int count,
                              REFIID iid, void **out) {
    PipelineState *p = calloc(1, sizeof *p);
    object_init(&p->object, &pipeline_state_vtbl, pipeline_state_iids, device);
    p->object.destroy = pipeline_state_destroy;
    p->compute = compute;
    for (int i = 0; i < count && p->stage_count < MAX_PIPELINE_STAGES; i++) {
        if (!stages[i]->pShaderBytecode) continue; // unused stage
        NSString *function = nil;
        id<MTLLibrary> library = shader_library_create(device->mtl, stages[i], &function);
        if (!library) continue; // already logged; the pipeline stays unusable but creation succeeds
        p->libraries[p->stage_count] = library;
        p->functions[p->stage_count++] = [function retain];
    }
    return give(&p->object, iid, out);
}

static ID3D12CommandSignatureVtbl command_signature_vtbl = {ID3D12_OBJECT_METHODS, .GetDevice = (void *)com_GetDevice};
static const IID *const command_signature_iids[] = {&IID_ID3D12CommandSignature, &IID_ID3D12Pageable,
                                                    &IID_ID3D12DeviceChild, &IID_ID3D12Object, NULL};

HRESULT command_signature_create(Device *device, const D3D12_COMMAND_SIGNATURE_DESC *desc, REFIID iid, void **out) {
    CommandSignature *c = calloc(1, sizeof *c);
    object_init(&c->object, &command_signature_vtbl, command_signature_iids, device);
    c->object.destroy = free_object;
    c->desc = *desc; // pArgumentDescs is not copied yet (indirect execution is not implemented)
    return give(&c->object, iid, out);
}

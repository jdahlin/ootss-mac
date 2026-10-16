// ID3D12CommandAllocator and ID3D12GraphicsCommandList6. Lists record commands; ExecuteCommandLists
// replays them into a Metal command buffer (see command_list_execute).
#include "objects.h"

// ---------------------------------------------------------------- ID3D12CommandAllocator
static HRESULT STDMETHODCALLTYPE allocator_Reset(CommandAllocator *a) { return S_OK; }

static ID3D12CommandAllocatorVtbl allocator_vtbl = {ID3D12_OBJECT_METHODS, .GetDevice = (void *)com_GetDevice,
                                                    .Reset = (void *)allocator_Reset};
static const IID *const allocator_iids[] = {&IID_ID3D12CommandAllocator, &IID_ID3D12Pageable, &IID_ID3D12DeviceChild,
                                            &IID_ID3D12Object, NULL};

static void free_object(Object *o) { free(o); }

HRESULT command_allocator_create(Device *device, REFIID iid, void **out) {
    static bool vtbl_ready;
    if (!vtbl_ready) {
        FILL_UNIMPLEMENTED(allocator_vtbl);
        vtbl_ready = true;
    }
    CommandAllocator *a = calloc(1, sizeof *a);
    object_init(&a->object, &allocator_vtbl, allocator_iids, device);
    a->object.destroy = free_object;
    HRESULT hr = object_query(&a->object, iid, out);
    object_release(&a->object);
    return hr;
}

// ---------------------------------------------------------------- recording
static Command *record(CommandList *l, CommandType type) {
    if (l->count == l->capacity) {
        size_t capacity = l->capacity ? l->capacity * 2 : 64;
        Command *grown = realloc(l->commands, capacity * sizeof *l->commands);
        if (!grown) abort();
        l->commands = grown;
        l->capacity = capacity;
    }
    Command *c = &l->commands[l->count++];
    memset(c, 0, sizeof *c);
    c->type = type;
    return c;
}

static HRESULT STDMETHODCALLTYPE list_Close(CommandList *l) { return S_OK; }

static HRESULT STDMETHODCALLTYPE list_Reset(CommandList *l, ID3D12CommandAllocator *allocator,
                                            ID3D12PipelineState *initial_state) {
    l->count = 0;
    return S_OK;
}

static D3D12_COMMAND_LIST_TYPE STDMETHODCALLTYPE list_GetType(CommandList *l) { return l->type; }

static void STDMETHODCALLTYPE list_ClearRenderTargetView(CommandList *l, D3D12_CPU_DESCRIPTOR_HANDLE rtv,
                                                         const FLOAT color[4], UINT rect_count,
                                                         const D3D12_RECT *rects) {
    if (rect_count) D3D_TODO("ClearRenderTargetView with rectangles clears the whole target");
    Command *c = record(l, CMD_CLEAR_RTV);
    c->clear_rtv.rtv = *descriptor_at(rtv);
    memcpy(c->clear_rtv.color, color, sizeof c->clear_rtv.color);
}

static void STDMETHODCALLTYPE list_CopyBufferRegion(CommandList *l, ID3D12Resource *dst, UINT64 dst_offset,
                                                    ID3D12Resource *src, UINT64 src_offset, UINT64 size) {
    Command *c = record(l, CMD_COPY_BUFFER);
    c->copy_buffer.dst = (Resource *)dst;
    c->copy_buffer.src = (Resource *)src;
    c->copy_buffer.dst_offset = dst_offset;
    c->copy_buffer.src_offset = src_offset;
    c->copy_buffer.size = size;
}

static void STDMETHODCALLTYPE list_CopyTextureRegion(CommandList *l, const D3D12_TEXTURE_COPY_LOCATION *dst, UINT x,
                                                     UINT y, UINT z, const D3D12_TEXTURE_COPY_LOCATION *src,
                                                     const D3D12_BOX *box) {
    Command *c = record(l, CMD_COPY_TEXTURE);
    c->copy_texture.dst = *dst;
    c->copy_texture.src = *src;
    c->copy_texture.x = x;
    c->copy_texture.y = y;
    c->copy_texture.z = z;
    if (box) c->copy_texture.box = *box;
    c->copy_texture.has_box = box != NULL;
}

static void STDMETHODCALLTYPE list_CopyResource(CommandList *l, ID3D12Resource *dst, ID3D12Resource *src) {
    Command *c = record(l, CMD_COPY_RESOURCE);
    c->copy_resource.dst = (Resource *)dst;
    c->copy_resource.src = (Resource *)src;
}

// Metal tracks hazards for resources it allocated, so transitions need no work yet.
static void STDMETHODCALLTYPE list_ResourceBarrier(CommandList *l, UINT count, const D3D12_RESOURCE_BARRIER *barriers) {
}

// State setting and drawing are accepted and ignored until pipelines exist (they need translated shaders);
// each logs once so the missing work is visible.
#define IGNORED_COMMAND(name, ...)                                                                                     \
    static void STDMETHODCALLTYPE list_##name(CommandList *l, ##__VA_ARGS__) { D3D_TODO(#name " is ignored"); }

IGNORED_COMMAND(ClearState, ID3D12PipelineState *state)
IGNORED_COMMAND(DrawInstanced, UINT a, UINT b, UINT c, UINT d)
IGNORED_COMMAND(DrawIndexedInstanced, UINT a, UINT b, UINT c, INT d, UINT e)
IGNORED_COMMAND(Dispatch, UINT x, UINT y, UINT z)
IGNORED_COMMAND(IASetPrimitiveTopology, D3D12_PRIMITIVE_TOPOLOGY topology)
IGNORED_COMMAND(RSSetViewports, UINT count, const D3D12_VIEWPORT *viewports)
IGNORED_COMMAND(RSSetScissorRects, UINT count, const D3D12_RECT *rects)
IGNORED_COMMAND(OMSetBlendFactor, const FLOAT factor[4])
IGNORED_COMMAND(OMSetStencilRef, UINT ref)
IGNORED_COMMAND(SetPipelineState, ID3D12PipelineState *state)
IGNORED_COMMAND(ExecuteBundle, ID3D12GraphicsCommandList *bundle)
IGNORED_COMMAND(SetDescriptorHeaps, UINT count, ID3D12DescriptorHeap *const *heaps)
IGNORED_COMMAND(SetComputeRootSignature, ID3D12RootSignature *root)
IGNORED_COMMAND(SetGraphicsRootSignature, ID3D12RootSignature *root)
IGNORED_COMMAND(SetComputeRootDescriptorTable, UINT index, D3D12_GPU_DESCRIPTOR_HANDLE handle)
IGNORED_COMMAND(SetGraphicsRootDescriptorTable, UINT index, D3D12_GPU_DESCRIPTOR_HANDLE handle)
IGNORED_COMMAND(SetComputeRoot32BitConstants, UINT index, UINT count, const void *data, UINT offset)
IGNORED_COMMAND(SetGraphicsRoot32BitConstants, UINT index, UINT count, const void *data, UINT offset)
IGNORED_COMMAND(IASetIndexBuffer, const D3D12_INDEX_BUFFER_VIEW *view)
IGNORED_COMMAND(IASetVertexBuffers, UINT start, UINT count, const D3D12_VERTEX_BUFFER_VIEW *views)
IGNORED_COMMAND(OMSetRenderTargets, UINT count, const D3D12_CPU_DESCRIPTOR_HANDLE *rtvs, WINBOOL single,
                const D3D12_CPU_DESCRIPTOR_HANDLE *dsv)
IGNORED_COMMAND(ClearDepthStencilView, D3D12_CPU_DESCRIPTOR_HANDLE dsv, D3D12_CLEAR_FLAGS flags, FLOAT depth,
                UINT8 stencil, UINT count, const D3D12_RECT *rects)
IGNORED_COMMAND(ExecuteIndirect, ID3D12CommandSignature *signature, UINT max, ID3D12Resource *args, UINT64 offset,
                ID3D12Resource *count_buffer, UINT64 count_offset)

static ID3D12GraphicsCommandList6Vtbl list_vtbl = {
    ID3D12_OBJECT_METHODS,
    .GetDevice = (void *)com_GetDevice,
    .GetType = (void *)list_GetType,
    .Close = (void *)list_Close,
    .Reset = (void *)list_Reset,
    .ClearRenderTargetView = (void *)list_ClearRenderTargetView,
    .CopyBufferRegion = (void *)list_CopyBufferRegion,
    .CopyTextureRegion = (void *)list_CopyTextureRegion,
    .CopyResource = (void *)list_CopyResource,
    .ResourceBarrier = (void *)list_ResourceBarrier,
    .ClearState = (void *)list_ClearState,
    .DrawInstanced = (void *)list_DrawInstanced,
    .DrawIndexedInstanced = (void *)list_DrawIndexedInstanced,
    .Dispatch = (void *)list_Dispatch,
    .IASetPrimitiveTopology = (void *)list_IASetPrimitiveTopology,
    .RSSetViewports = (void *)list_RSSetViewports,
    .RSSetScissorRects = (void *)list_RSSetScissorRects,
    .OMSetBlendFactor = (void *)list_OMSetBlendFactor,
    .OMSetStencilRef = (void *)list_OMSetStencilRef,
    .SetPipelineState = (void *)list_SetPipelineState,
    .ExecuteBundle = (void *)list_ExecuteBundle,
    .SetDescriptorHeaps = (void *)list_SetDescriptorHeaps,
    .SetComputeRootSignature = (void *)list_SetComputeRootSignature,
    .SetGraphicsRootSignature = (void *)list_SetGraphicsRootSignature,
    .SetComputeRootDescriptorTable = (void *)list_SetComputeRootDescriptorTable,
    .SetGraphicsRootDescriptorTable = (void *)list_SetGraphicsRootDescriptorTable,
    .SetComputeRoot32BitConstants = (void *)list_SetComputeRoot32BitConstants,
    .SetGraphicsRoot32BitConstants = (void *)list_SetGraphicsRoot32BitConstants,
    .IASetIndexBuffer = (void *)list_IASetIndexBuffer,
    .IASetVertexBuffers = (void *)list_IASetVertexBuffers,
    .OMSetRenderTargets = (void *)list_OMSetRenderTargets,
    .ClearDepthStencilView = (void *)list_ClearDepthStencilView,
    .ExecuteIndirect = (void *)list_ExecuteIndirect,
};
static const IID *const list_iids[] = {&IID_ID3D12GraphicsCommandList6,
                                       &IID_ID3D12GraphicsCommandList5,
                                       &IID_ID3D12GraphicsCommandList4,
                                       &IID_ID3D12GraphicsCommandList3,
                                       &IID_ID3D12GraphicsCommandList2,
                                       &IID_ID3D12GraphicsCommandList1,
                                       &IID_ID3D12GraphicsCommandList,
                                       &IID_ID3D12CommandList,
                                       &IID_ID3D12DeviceChild,
                                       &IID_ID3D12Object,
                                       NULL};

static void list_destroy(Object *o) {
    free(((CommandList *)o)->commands);
    free(o);
}

HRESULT command_list_create(Device *device, D3D12_COMMAND_LIST_TYPE type, REFIID iid, void **out) {
    static bool vtbl_ready;
    if (!vtbl_ready) {
        FILL_UNIMPLEMENTED(list_vtbl);
        vtbl_ready = true;
    }
    CommandList *l = calloc(1, sizeof *l);
    object_init(&l->object, &list_vtbl, list_iids, device);
    l->object.destroy = list_destroy;
    l->type = type;
    HRESULT hr = object_query(&l->object, iid, out);
    object_release(&l->object);
    return hr;
}

// ---------------------------------------------------------------- replay
static void subresource_position(Resource *r, UINT subresource, NSUInteger *level, NSUInteger *slice) {
    UINT mips = r->desc.MipLevels ? r->desc.MipLevels : 1;
    *level = subresource % mips;
    *slice = subresource / mips;
}

static void replay_clear(const Command *c, id<MTLCommandBuffer> cb) {
    const Descriptor *rtv = &c->clear_rtv.rtv;
    if (rtv->kind != DESCRIPTOR_RTV || !rtv->resource || !rtv->resource->texture) return;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = rtv->resource->texture;
    if (rtv->has_view_desc && rtv->rtv.ViewDimension == D3D12_RTV_DIMENSION_TEXTURE2D)
        pass.colorAttachments[0].level = rtv->rtv.Texture2D.MipSlice;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    const float *k = c->clear_rtv.color;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(k[0], k[1], k[2], k[3]);
    [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
}

static void replay_copy_texture(const Command *c, id<MTLBlitCommandEncoder> blit) {
    const D3D12_TEXTURE_COPY_LOCATION *dst = &c->copy_texture.dst, *src = &c->copy_texture.src;
    Resource *dst_r = (Resource *)dst->pResource, *src_r = (Resource *)src->pResource;
    MTLOrigin origin = MTLOriginMake(c->copy_texture.x, c->copy_texture.y, c->copy_texture.z);

    if (src->Type == D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT &&
        dst->Type == D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX) {
        const D3D12_SUBRESOURCE_FOOTPRINT *f = &src->PlacedFootprint.Footprint;
        NSUInteger level, slice;
        subresource_position(dst_r, dst->SubresourceIndex, &level, &slice);
        UINT block;
        format_bytes_per_block(f->Format, &block);
        UINT rows = (f->Height + block - 1) / block;
        [blit copyFromBuffer:src_r->buffer
                   sourceOffset:src->PlacedFootprint.Offset
              sourceBytesPerRow:f->RowPitch
            sourceBytesPerImage:(NSUInteger)f->RowPitch * rows
                     sourceSize:MTLSizeMake(f->Width, f->Height, f->Depth)
                      toTexture:dst_r->texture
               destinationSlice:slice
               destinationLevel:level
              destinationOrigin:origin];
    } else if (src->Type == D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX &&
               dst->Type == D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT) {
        const D3D12_SUBRESOURCE_FOOTPRINT *f = &dst->PlacedFootprint.Footprint;
        NSUInteger level, slice;
        subresource_position(src_r, src->SubresourceIndex, &level, &slice);
        [blit copyFromTexture:src_r->texture
                         sourceSlice:slice
                         sourceLevel:level
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(f->Width, f->Height, f->Depth)
                            toBuffer:dst_r->buffer
                   destinationOffset:dst->PlacedFootprint.Offset
              destinationBytesPerRow:f->RowPitch
            destinationBytesPerImage:(NSUInteger)f->RowPitch * f->Height];
    } else { // texture to texture
        NSUInteger src_level, src_slice, dst_level, dst_slice;
        subresource_position(src_r, src->SubresourceIndex, &src_level, &src_slice);
        subresource_position(dst_r, dst->SubresourceIndex, &dst_level, &dst_slice);
        const D3D12_BOX *b = &c->copy_texture.box;
        MTLOrigin src_origin =
            c->copy_texture.has_box ? MTLOriginMake(b->left, b->top, b->front) : MTLOriginMake(0, 0, 0);
        MTLSize size = c->copy_texture.has_box ? MTLSizeMake(b->right - b->left, b->bottom - b->top, b->back - b->front)
                                               : MTLSizeMake(MAX(src_r->texture.width >> src_level, 1ul),
                                                             MAX(src_r->texture.height >> src_level, 1ul), 1);
        [blit copyFromTexture:src_r->texture
                  sourceSlice:src_slice
                  sourceLevel:src_level
                 sourceOrigin:src_origin
                   sourceSize:size
                    toTexture:dst_r->texture
             destinationSlice:dst_slice
             destinationLevel:dst_level
            destinationOrigin:origin];
    }
}

void command_list_execute(CommandList *l, id<MTLCommandBuffer> cb) {
    id<MTLBlitCommandEncoder> blit = nil; // consecutive copies share one blit encoder
    for (size_t i = 0; i < l->count; i++) {
        const Command *c = &l->commands[i];
        bool is_copy = c->type != CMD_CLEAR_RTV;
        if (is_copy && !blit) blit = [cb blitCommandEncoder];
        if (!is_copy && blit) {
            [blit endEncoding];
            blit = nil;
        }
        switch (c->type) {
        case CMD_CLEAR_RTV: replay_clear(c, cb); break;
        case CMD_COPY_BUFFER:
            [blit copyFromBuffer:c->copy_buffer.src->buffer
                     sourceOffset:c->copy_buffer.src_offset
                         toBuffer:c->copy_buffer.dst->buffer
                destinationOffset:c->copy_buffer.dst_offset
                             size:c->copy_buffer.size];
            break;
        case CMD_COPY_TEXTURE: replay_copy_texture(c, blit); break;
        case CMD_COPY_RESOURCE:
            if (c->copy_resource.src->buffer)
                [blit copyFromBuffer:c->copy_resource.src->buffer
                         sourceOffset:0
                             toBuffer:c->copy_resource.dst->buffer
                    destinationOffset:0
                                 size:c->copy_resource.src->buffer.length];
            else
                [blit copyFromTexture:c->copy_resource.src->texture toTexture:c->copy_resource.dst->texture];
            break;
        }
    }
    if (blit) [blit endEncoding];
}

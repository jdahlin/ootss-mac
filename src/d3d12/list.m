// ID3D12CommandAllocator and ID3D12GraphicsCommandList6. Lists record commands; ExecuteCommandLists
// replays them into a Metal command buffer (see command_list_execute).
#include "commands.h"

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

static void copy_view(View *dst, D3D12_CPU_DESCRIPTOR_HANDLE handle) {
    const View *v = descriptor_view(handle);
    if (v)
        *dst = *v;
    else
        memset(dst, 0, sizeof *dst);
}

static HRESULT STDMETHODCALLTYPE list_Close(CommandList *l) { return S_OK; }

static HRESULT STDMETHODCALLTYPE list_Reset(CommandList *l, ID3D12CommandAllocator *allocator,
                                            ID3D12PipelineState *initial_state) {
    l->count = 0;
    if (initial_state) {
        Command *c = record(l, CMD_SET_PIPELINE);
        c->pipeline = (PipelineState *)initial_state;
    }
    return S_OK;
}

static D3D12_COMMAND_LIST_TYPE STDMETHODCALLTYPE list_GetType(CommandList *l) { return l->type; }

static void STDMETHODCALLTYPE list_ClearState(CommandList *l, ID3D12PipelineState *state) {
    if (state) {
        Command *c = record(l, CMD_SET_PIPELINE);
        c->pipeline = (PipelineState *)state;
    }
}

static void STDMETHODCALLTYPE list_SetPipelineState(CommandList *l, ID3D12PipelineState *state) {
    Command *c = record(l, CMD_SET_PIPELINE);
    c->pipeline = (PipelineState *)state;
}

// ---- state
static void set_root_signature(CommandList *l, ID3D12RootSignature *root, bool compute) {
    Command *c = record(l, CMD_SET_ROOT_SIGNATURE);
    c->compute = compute;
    c->root_signature = (RootSignature *)root;
}
static void STDMETHODCALLTYPE list_SetComputeRootSignature(CommandList *l, ID3D12RootSignature *root) {
    set_root_signature(l, root, true);
}
static void STDMETHODCALLTYPE list_SetGraphicsRootSignature(CommandList *l, ID3D12RootSignature *root) {
    set_root_signature(l, root, false);
}

static void set_root_address(CommandList *l, UINT index, uint64_t value, bool compute) {
    Command *c = record(l, CMD_ROOT_ADDRESS);
    c->compute = compute;
    c->root_address.index = index;
    c->root_address.value = value;
}
#define ROOT_ADDRESS_METHODS(prefix, compute, name, argtype)                                                           \
    static void STDMETHODCALLTYPE list_##prefix##name(CommandList *l, UINT index, argtype value) {                     \
        set_root_address(l, index, (uint64_t)value, compute);                                                          \
    }
static void STDMETHODCALLTYPE list_ComputeRootDescriptorTable(CommandList *l, UINT index,
                                                              D3D12_GPU_DESCRIPTOR_HANDLE handle) {
    set_root_address(l, index, handle.ptr, true);
}
static void STDMETHODCALLTYPE list_GraphicsRootDescriptorTable(CommandList *l, UINT index,
                                                               D3D12_GPU_DESCRIPTOR_HANDLE handle) {
    set_root_address(l, index, handle.ptr, false);
}
ROOT_ADDRESS_METHODS(Compute, true, RootConstantBufferView, D3D12_GPU_VIRTUAL_ADDRESS)
ROOT_ADDRESS_METHODS(Graphics, false, RootConstantBufferView, D3D12_GPU_VIRTUAL_ADDRESS)
ROOT_ADDRESS_METHODS(Compute, true, RootShaderResourceView, D3D12_GPU_VIRTUAL_ADDRESS)
ROOT_ADDRESS_METHODS(Graphics, false, RootShaderResourceView, D3D12_GPU_VIRTUAL_ADDRESS)
ROOT_ADDRESS_METHODS(Compute, true, RootUnorderedAccessView, D3D12_GPU_VIRTUAL_ADDRESS)
ROOT_ADDRESS_METHODS(Graphics, false, RootUnorderedAccessView, D3D12_GPU_VIRTUAL_ADDRESS)

static void set_constants(CommandList *l, UINT index, UINT count, const void *data, UINT offset, bool compute) {
    if (count > MAX_ROOT_CONSTANT_VALUES) {
        D3D_LOG("root constants: %u values exceed the recorded maximum", count);
        count = MAX_ROOT_CONSTANT_VALUES;
    }
    Command *c = record(l, CMD_ROOT_CONSTANTS);
    c->compute = compute;
    c->root_constants.index = index;
    c->root_constants.dest_offset = offset;
    c->root_constants.count = count;
    memcpy(c->root_constants.values, data, count * sizeof(uint32_t));
}
static void STDMETHODCALLTYPE list_SetComputeRoot32BitConstants(CommandList *l, UINT index, UINT count,
                                                                const void *data, UINT offset) {
    set_constants(l, index, count, data, offset, true);
}
static void STDMETHODCALLTYPE list_SetGraphicsRoot32BitConstants(CommandList *l, UINT index, UINT count,
                                                                 const void *data, UINT offset) {
    set_constants(l, index, count, data, offset, false);
}
static void STDMETHODCALLTYPE list_SetComputeRoot32BitConstant(CommandList *l, UINT index, UINT value, UINT offset) {
    set_constants(l, index, 1, &value, offset, true);
}
static void STDMETHODCALLTYPE list_SetGraphicsRoot32BitConstant(CommandList *l, UINT index, UINT value, UINT offset) {
    set_constants(l, index, 1, &value, offset, false);
}

static void STDMETHODCALLTYPE list_SetDescriptorHeaps(CommandList *l, UINT count, ID3D12DescriptorHeap *const *heaps) {
    Command *c = record(l, CMD_SET_HEAPS);
    for (UINT i = 0; i < count && i < MAX_LIST_HEAPS; i++)
        c->heaps.heaps[c->heaps.count++] = (DescriptorHeap *)heaps[i];
}

static void STDMETHODCALLTYPE list_IASetPrimitiveTopology(CommandList *l, D3D12_PRIMITIVE_TOPOLOGY topology) {
    record(l, CMD_TOPOLOGY)->topology = topology;
}

static void STDMETHODCALLTYPE list_IASetIndexBuffer(CommandList *l, const D3D12_INDEX_BUFFER_VIEW *view) {
    Command *c = record(l, CMD_INDEX_BUFFER);
    if (view) c->index_buffer = *view;
}

static void STDMETHODCALLTYPE list_IASetVertexBuffers(CommandList *l, UINT start, UINT count,
                                                      const D3D12_VERTEX_BUFFER_VIEW *views) {
    Command *c = record(l, CMD_VERTEX_BUFFERS);
    if (count > MAX_VERTEX_SLOTS) count = MAX_VERTEX_SLOTS;
    c->vertex_buffers.start = start;
    c->vertex_buffers.count = count;
    if (views) memcpy(c->vertex_buffers.views, views, count * sizeof *views);
}

static void STDMETHODCALLTYPE list_RSSetViewports(CommandList *l, UINT count, const D3D12_VIEWPORT *viewports) {
    Command *c = record(l, CMD_VIEWPORTS);
    c->viewports.count = MIN(count, (UINT)MAX_VIEWPORTS);
    memcpy(c->viewports.viewports, viewports, c->viewports.count * sizeof *viewports);
}

static void STDMETHODCALLTYPE list_RSSetScissorRects(CommandList *l, UINT count, const D3D12_RECT *rects) {
    Command *c = record(l, CMD_SCISSORS);
    c->scissors.count = MIN(count, (UINT)MAX_VIEWPORTS);
    memcpy(c->scissors.rects, rects, c->scissors.count * sizeof *rects);
}

static void STDMETHODCALLTYPE list_OMSetBlendFactor(CommandList *l, const FLOAT factor[4]) {
    Command *c = record(l, CMD_BLEND_FACTOR);
    if (factor) memcpy(c->blend_factor, factor, sizeof c->blend_factor);
}

static void STDMETHODCALLTYPE list_OMSetStencilRef(CommandList *l, UINT ref) {
    record(l, CMD_STENCIL_REF)->stencil_ref = ref;
}

static void STDMETHODCALLTYPE list_OMSetRenderTargets(CommandList *l, UINT count,
                                                      const D3D12_CPU_DESCRIPTOR_HANDLE *rtvs, WINBOOL single,
                                                      const D3D12_CPU_DESCRIPTOR_HANDLE *dsv) {
    Command *c = record(l, CMD_RENDER_TARGETS);
    c->targets.count = MIN(count, (UINT)MAX_RENDER_TARGETS);
    for (UINT i = 0; i < c->targets.count; i++) {
        D3D12_CPU_DESCRIPTOR_HANDLE h =
            single ? (D3D12_CPU_DESCRIPTOR_HANDLE){rtvs[0].ptr + i * DESCRIPTOR_STRIDE} : rtvs[i];
        copy_view(&c->targets.colors[i], h);
    }
    if (dsv) {
        copy_view(&c->targets.depth, *dsv);
        c->targets.has_depth = c->targets.depth.resource != NULL;
    }
}

// ---- clears
static void STDMETHODCALLTYPE list_ClearRenderTargetView(CommandList *l, D3D12_CPU_DESCRIPTOR_HANDLE rtv,
                                                         const FLOAT color[4], UINT rect_count,
                                                         const D3D12_RECT *rects) {
    if (rect_count) D3D_TODO("ClearRenderTargetView with rectangles clears the whole target");
    Command *c = record(l, CMD_CLEAR_COLOR);
    copy_view(&c->clear_color.view, rtv);
    memcpy(c->clear_color.color, color, sizeof c->clear_color.color);
}

static void STDMETHODCALLTYPE list_ClearDepthStencilView(CommandList *l, D3D12_CPU_DESCRIPTOR_HANDLE dsv,
                                                         D3D12_CLEAR_FLAGS flags, FLOAT depth, UINT8 stencil,
                                                         UINT rect_count, const D3D12_RECT *rects) {
    if (rect_count) D3D_TODO("ClearDepthStencilView with rectangles clears the whole target");
    Command *c = record(l, CMD_CLEAR_DEPTH);
    copy_view(&c->clear_depth.view, dsv);
    c->clear_depth.flags = flags;
    c->clear_depth.depth = depth;
    c->clear_depth.stencil = stencil;
}

// ---- draws
static void STDMETHODCALLTYPE list_DrawInstanced(CommandList *l, UINT vertex_count, UINT instance_count,
                                                 UINT start_vertex, UINT start_instance) {
    Command *c = record(l, CMD_DRAW);
    c->draw.vertex_count = vertex_count;
    c->draw.instance_count = instance_count;
    c->draw.start_vertex = start_vertex;
    c->draw.start_instance = start_instance;
}

static void STDMETHODCALLTYPE list_DrawIndexedInstanced(CommandList *l, UINT index_count, UINT instance_count,
                                                        UINT start_index, INT base_vertex, UINT start_instance) {
    Command *c = record(l, CMD_DRAW_INDEXED);
    c->draw_indexed.index_count = index_count;
    c->draw_indexed.instance_count = instance_count;
    c->draw_indexed.start_index = start_index;
    c->draw_indexed.base_vertex = base_vertex;
    c->draw_indexed.start_instance = start_instance;
}

static void STDMETHODCALLTYPE list_Dispatch(CommandList *l, UINT x, UINT y, UINT z) {
    Command *c = record(l, CMD_DISPATCH);
    c->dispatch.x = x;
    c->dispatch.y = y;
    c->dispatch.z = z;
}

static void STDMETHODCALLTYPE list_ExecuteIndirect(CommandList *l, ID3D12CommandSignature *signature, UINT max_count,
                                                   ID3D12Resource *arguments, UINT64 arguments_offset,
                                                   ID3D12Resource *count_buffer, UINT64 count_offset) {
    Command *c = record(l, CMD_EXECUTE_INDIRECT);
    c->indirect.signature = (CommandSignature *)signature;
    c->indirect.max_count = max_count;
    c->indirect.arguments = (Resource *)arguments;
    c->indirect.arguments_offset = arguments_offset;
    c->indirect.count_buffer = (Resource *)count_buffer;
    c->indirect.count_offset = count_offset;
}

static void STDMETHODCALLTYPE list_ExecuteBundle(CommandList *l, ID3D12GraphicsCommandList *bundle) {
    record(l, CMD_EXECUTE_BUNDLE)->bundle = (CommandList *)bundle;
}

// ---- copies
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

static void STDMETHODCALLTYPE list_ResolveSubresource(CommandList *l, ID3D12Resource *dst, UINT dst_subresource,
                                                      ID3D12Resource *src, UINT src_subresource, DXGI_FORMAT format) {
    Command *c = record(l, CMD_RESOLVE);
    c->resolve.dst = (Resource *)dst;
    c->resolve.src = (Resource *)src;
    c->resolve.dst_subresource = dst_subresource;
    c->resolve.src_subresource = src_subresource;
    c->resolve.format = format;
}

// Metal tracks nothing for our untracked resources, so ordering comes from the queue's fence chain and
// barriers need no work.
static void STDMETHODCALLTYPE list_ResourceBarrier(CommandList *l, UINT count, const D3D12_RESOURCE_BARRIER *barriers) {
}
static void STDMETHODCALLTYPE list_Ignored(CommandList *l) {}

static ID3D12GraphicsCommandList6Vtbl list_vtbl = {
    ID3D12_OBJECT_METHODS,
    .GetDevice = (void *)com_GetDevice,
    .GetType = (void *)list_GetType,
    .Close = (void *)list_Close,
    .Reset = (void *)list_Reset,
    .ClearState = (void *)list_ClearState,
    .DrawInstanced = (void *)list_DrawInstanced,
    .DrawIndexedInstanced = (void *)list_DrawIndexedInstanced,
    .Dispatch = (void *)list_Dispatch,
    .CopyBufferRegion = (void *)list_CopyBufferRegion,
    .CopyTextureRegion = (void *)list_CopyTextureRegion,
    .CopyResource = (void *)list_CopyResource,
    .ResolveSubresource = (void *)list_ResolveSubresource,
    .IASetPrimitiveTopology = (void *)list_IASetPrimitiveTopology,
    .RSSetViewports = (void *)list_RSSetViewports,
    .RSSetScissorRects = (void *)list_RSSetScissorRects,
    .OMSetBlendFactor = (void *)list_OMSetBlendFactor,
    .OMSetStencilRef = (void *)list_OMSetStencilRef,
    .SetPipelineState = (void *)list_SetPipelineState,
    .ResourceBarrier = (void *)list_ResourceBarrier,
    .ExecuteBundle = (void *)list_ExecuteBundle,
    .SetDescriptorHeaps = (void *)list_SetDescriptorHeaps,
    .SetComputeRootSignature = (void *)list_SetComputeRootSignature,
    .SetGraphicsRootSignature = (void *)list_SetGraphicsRootSignature,
    .SetComputeRootDescriptorTable = (void *)list_ComputeRootDescriptorTable,
    .SetGraphicsRootDescriptorTable = (void *)list_GraphicsRootDescriptorTable,
    .SetComputeRoot32BitConstant = (void *)list_SetComputeRoot32BitConstant,
    .SetGraphicsRoot32BitConstant = (void *)list_SetGraphicsRoot32BitConstant,
    .SetComputeRoot32BitConstants = (void *)list_SetComputeRoot32BitConstants,
    .SetGraphicsRoot32BitConstants = (void *)list_SetGraphicsRoot32BitConstants,
    .SetComputeRootConstantBufferView = (void *)list_ComputeRootConstantBufferView,
    .SetGraphicsRootConstantBufferView = (void *)list_GraphicsRootConstantBufferView,
    .SetComputeRootShaderResourceView = (void *)list_ComputeRootShaderResourceView,
    .SetGraphicsRootShaderResourceView = (void *)list_GraphicsRootShaderResourceView,
    .SetComputeRootUnorderedAccessView = (void *)list_ComputeRootUnorderedAccessView,
    .SetGraphicsRootUnorderedAccessView = (void *)list_GraphicsRootUnorderedAccessView,
    .IASetIndexBuffer = (void *)list_IASetIndexBuffer,
    .IASetVertexBuffers = (void *)list_IASetVertexBuffers,
    .OMSetRenderTargets = (void *)list_OMSetRenderTargets,
    .ClearDepthStencilView = (void *)list_ClearDepthStencilView,
    .ClearRenderTargetView = (void *)list_ClearRenderTargetView,
    .ExecuteIndirect = (void *)list_ExecuteIndirect,
    .DiscardResource = (void *)list_Ignored,
    .SetMarker = (void *)list_Ignored,
    .BeginEvent = (void *)list_Ignored,
    .EndEvent = (void *)list_Ignored,
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

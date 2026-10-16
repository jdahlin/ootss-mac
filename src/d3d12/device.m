// ID3D12Device2: object creation, descriptors and feature reporting.
#include <unistd.h>
#include "objects.h"

static Device *g_device;

id<MTLDevice> backend_mtl_device(void) {
    static id<MTLDevice> device;
    if (!device) device = MTLCreateSystemDefaultDevice();
    return device;
}

// ---------------------------------------------------------------- object creation
static HRESULT STDMETHODCALLTYPE device_CreateCommandQueue(Device *d, const D3D12_COMMAND_QUEUE_DESC *desc, REFIID iid,
                                                           void **out) {
    return command_queue_create(d, desc, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandAllocator(Device *d, D3D12_COMMAND_LIST_TYPE type, REFIID iid,
                                                               void **out) {
    return command_allocator_create(d, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandList(Device *d, UINT node_mask, D3D12_COMMAND_LIST_TYPE type,
                                                          ID3D12CommandAllocator *allocator,
                                                          ID3D12PipelineState *initial_state, REFIID iid, void **out) {
    return command_list_create(d, type, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateFence(Device *d, UINT64 initial, D3D12_FENCE_FLAGS flags, REFIID iid,
                                                    void **out) {
    return fence_create(d, initial, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateDescriptorHeap(Device *d, const D3D12_DESCRIPTOR_HEAP_DESC *desc,
                                                             REFIID iid, void **out) {
    return descriptor_heap_create(d, desc, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateHeap(Device *d, const D3D12_HEAP_DESC *desc, REFIID iid, void **out) {
    return heap_create(d, desc, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateRootSignature(Device *d, UINT node_mask, const void *blob, SIZE_T size,
                                                            REFIID iid, void **out) {
    return root_signature_create(d, blob, size, iid, out);
}

// D3D12_DUMP_SHADERS=<directory> writes every shader the game creates pipelines from, named by its hash.
static void dump_shader(const D3D12_SHADER_BYTECODE *code, const char *stage) {
    const char *dir = getenv("D3D12_DUMP_SHADERS");
    if (!dir || !code->pShaderBytecode || code->BytecodeLength < 20) return;
    const uint8_t *bytes = code->pShaderBytecode;
    char path[1024];
    int n = snprintf(path, sizeof path, "%s/%s-", dir, stage);
    for (int i = 4; i < 20; i++) n += snprintf(path + n, sizeof path - n, "%02x", bytes[i]); // the container hash
    snprintf(path + n, sizeof path - n, ".dxbc");
    if (access(path, F_OK) == 0) return;
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fwrite(bytes, 1, code->BytecodeLength, f);
    fclose(f);
}

// D3D12_LOG_PSO=1 prints one line per graphics pipeline describing the state it needs.
static void log_graphics_pipeline(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *d) {
    if (!getenv("D3D12_LOG_PSO")) return;
    char layout[512] = "", targets[256] = "", blend[64] = "";
    for (UINT i = 0; i < d->InputLayout.NumElements; i++) {
        const D3D12_INPUT_ELEMENT_DESC *e = &d->InputLayout.pInputElementDescs[i];
        snprintf(layout + strlen(layout), sizeof layout - strlen(layout), "%s%u:f%d@%u/s%u%s", i ? "," : "",
                 e->SemanticIndex, e->Format, e->AlignedByteOffset, e->InputSlot,
                 e->InputSlotClass == D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA ? "i" : "");
    }
    for (UINT i = 0; i < d->NumRenderTargets; i++)
        snprintf(targets + strlen(targets), sizeof targets - strlen(targets), "%s%d", i ? "," : "", d->RTVFormats[i]);
    for (UINT i = 0; i < d->NumRenderTargets; i++) {
        const D3D12_RENDER_TARGET_BLEND_DESC *b = &d->BlendState.RenderTarget[i];
        if (b->BlendEnable)
            snprintf(blend + strlen(blend), sizeof blend - strlen(blend), "[rt%u c%d/%d/%d a%d/%d/%d]", i, b->SrcBlend,
                     b->DestBlend, b->BlendOp, b->SrcBlendAlpha, b->DestBlendAlpha, b->BlendOpAlpha);
    }
    D3D_LOG("PSO stages=%c%c%c%c%c topo=%d rt=%s dsv=%d samples=%u depth=%d/%d/%d stencil=%d cull=%d fill=%d "
            "bias=%d clip=%d alpha2cov=%d indep=%d logic=%d strip=%d layout=%s blend=%s",
            d->VS.pShaderBytecode ? 'V' : '-', d->PS.pShaderBytecode ? 'P' : '-', d->DS.pShaderBytecode ? 'D' : '-',
            d->HS.pShaderBytecode ? 'H' : '-', d->GS.pShaderBytecode ? 'G' : '-', d->PrimitiveTopologyType, targets,
            d->DSVFormat, d->SampleDesc.Count, d->DepthStencilState.DepthEnable, d->DepthStencilState.DepthWriteMask,
            d->DepthStencilState.DepthFunc, d->DepthStencilState.StencilEnable, d->RasterizerState.CullMode,
            d->RasterizerState.FillMode, d->RasterizerState.DepthBias, d->RasterizerState.DepthClipEnable,
            d->BlendState.AlphaToCoverageEnable, d->BlendState.IndependentBlendEnable,
            d->BlendState.RenderTarget[0].LogicOpEnable, d->IBStripCutValue, layout[0] ? layout : "-",
            blend[0] ? blend : "-");
}

static HRESULT STDMETHODCALLTYPE device_CreateGraphicsPipelineState(Device *d,
                                                                    const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc,
                                                                    REFIID iid, void **out) {
    log_graphics_pipeline(desc);
    dump_shader(&desc->VS, "vs");
    dump_shader(&desc->PS, "ps");
    dump_shader(&desc->DS, "ds");
    dump_shader(&desc->HS, "hs");
    dump_shader(&desc->GS, "gs");
    return graphics_pipeline_create(d, desc, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateComputePipelineState(Device *d,
                                                                   const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc,
                                                                   REFIID iid, void **out) {
    dump_shader(&desc->CS, "cs");
    return compute_pipeline_create(d, desc, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreatePipelineState(Device *d, const D3D12_PIPELINE_STATE_STREAM_DESC *desc,
                                                            REFIID iid, void **out) {
    D3D_TODO("CreatePipelineState (stream form) is not supported");
    return E_NOTIMPL;
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandSignature(Device *d, const D3D12_COMMAND_SIGNATURE_DESC *desc,
                                                               ID3D12RootSignature *root, REFIID iid, void **out) {
    return command_signature_create(d, desc, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateCommittedResource(Device *d, const D3D12_HEAP_PROPERTIES *heap,
                                                                D3D12_HEAP_FLAGS flags, const D3D12_RESOURCE_DESC *desc,
                                                                D3D12_RESOURCE_STATES state,
                                                                const D3D12_CLEAR_VALUE *clear, REFIID iid,
                                                                void **out) {
    return resource_create(d, heap, desc, iid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreatePlacedResource(Device *d, ID3D12Heap *heap, UINT64 offset,
                                                             const D3D12_RESOURCE_DESC *desc,
                                                             D3D12_RESOURCE_STATES state,
                                                             const D3D12_CLEAR_VALUE *clear, REFIID iid, void **out) {
    return resource_create(d, &((Heap *)heap)->desc.Properties, desc, iid, out);
}

// ---------------------------------------------------------------- descriptors
static UINT STDMETHODCALLTYPE device_GetDescriptorHandleIncrementSize(Device *d, D3D12_DESCRIPTOR_HEAP_TYPE type) {
    return DESCRIPTOR_STRIDE;
}

static void STDMETHODCALLTYPE device_CreateConstantBufferView(Device *d, const D3D12_CONSTANT_BUFFER_VIEW_DESC *view,
                                                              D3D12_CPU_DESCRIPTOR_HANDLE handle) {
    descriptor_create_cbv(d, view, handle);
}

static void STDMETHODCALLTYPE device_CreateShaderResourceView(Device *d, ID3D12Resource *resource,
                                                              const D3D12_SHADER_RESOURCE_VIEW_DESC *view,
                                                              D3D12_CPU_DESCRIPTOR_HANDLE handle) {
    descriptor_create_srv(d, (Resource *)resource, view, handle);
}

static void STDMETHODCALLTYPE device_CreateUnorderedAccessView(Device *d, ID3D12Resource *resource,
                                                               ID3D12Resource *counter,
                                                               const D3D12_UNORDERED_ACCESS_VIEW_DESC *view,
                                                               D3D12_CPU_DESCRIPTOR_HANDLE handle) {
    if (counter) D3D_TODO("UAV counters are ignored");
    descriptor_create_uav(d, (Resource *)resource, view, handle);
}

static void STDMETHODCALLTYPE device_CreateRenderTargetView(Device *d, ID3D12Resource *resource,
                                                            const D3D12_RENDER_TARGET_VIEW_DESC *view,
                                                            D3D12_CPU_DESCRIPTOR_HANDLE handle) {
    descriptor_create_rtv(d, (Resource *)resource, view, handle);
}

static void STDMETHODCALLTYPE device_CreateDepthStencilView(Device *d, ID3D12Resource *resource,
                                                            const D3D12_DEPTH_STENCIL_VIEW_DESC *view,
                                                            D3D12_CPU_DESCRIPTOR_HANDLE handle) {
    descriptor_create_dsv(d, (Resource *)resource, view, handle);
}

static void STDMETHODCALLTYPE device_CreateSampler(Device *d, const D3D12_SAMPLER_DESC *view,
                                                   D3D12_CPU_DESCRIPTOR_HANDLE handle) {
    descriptor_create_sampler(d, view, handle);
}

static void STDMETHODCALLTYPE device_CopyDescriptorsSimple(Device *d, UINT count, D3D12_CPU_DESCRIPTOR_HANDLE dst,
                                                           D3D12_CPU_DESCRIPTOR_HANDLE src,
                                                           D3D12_DESCRIPTOR_HEAP_TYPE type) {
    descriptors_copy(dst, src, count);
}

static void STDMETHODCALLTYPE device_CopyDescriptors(Device *d, UINT dst_range_count,
                                                     const D3D12_CPU_DESCRIPTOR_HANDLE *dst_starts,
                                                     const UINT *dst_sizes, UINT src_range_count,
                                                     const D3D12_CPU_DESCRIPTOR_HANDLE *src_starts,
                                                     const UINT *src_sizes, D3D12_DESCRIPTOR_HEAP_TYPE type) {
    // Walk both range lists in step, one descriptor at a time.
    UINT di = 0, si = 0, d_off = 0, s_off = 0;
    while (di < dst_range_count && si < src_range_count) {
        UINT d_size = dst_sizes ? dst_sizes[di] : 1, s_size = src_sizes ? src_sizes[si] : 1;
        D3D12_CPU_DESCRIPTOR_HANDLE dst = {dst_starts[di].ptr + (size_t)d_off * DESCRIPTOR_STRIDE};
        D3D12_CPU_DESCRIPTOR_HANDLE src = {src_starts[si].ptr + (size_t)s_off * DESCRIPTOR_STRIDE};
        descriptors_copy(dst, src, 1);
        if (++d_off == d_size) di++, d_off = 0;
        if (++s_off == s_size) si++, s_off = 0;
    }
}

// ---------------------------------------------------------------- sizes and layouts
static void STDMETHODCALLTYPE device_GetCopyableFootprints(Device *d, const D3D12_RESOURCE_DESC *desc, UINT first,
                                                           UINT count, UINT64 base,
                                                           D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts, UINT *rows,
                                                           UINT64 *row_sizes, UINT64 *total) {
    UINT64 size = copyable_footprints(desc, first, count, base, layouts, rows, row_sizes);
    if (total) *total = size;
}

static D3D12_RESOURCE_ALLOCATION_INFO *STDMETHODCALLTYPE device_GetResourceAllocationInfo(
    Device *d, D3D12_RESOURCE_ALLOCATION_INFO *ret, UINT visible_mask, UINT count, const D3D12_RESOURCE_DESC *descs) {
    const UINT64 alignment = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
    UINT64 total = 0;
    for (UINT i = 0; i < count; i++) {
        UINT mips = descs[i].MipLevels ? descs[i].MipLevels : 1;
        UINT layers = descs[i].Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? 1 : descs[i].DepthOrArraySize;
        UINT64 size = copyable_footprints(&descs[i], 0, mips * (layers ? layers : 1), 0, NULL, NULL, NULL);
        total = ((total + alignment - 1) & ~(alignment - 1)) + size;
    }
    *ret = (D3D12_RESOURCE_ALLOCATION_INFO){(total + alignment - 1) & ~(alignment - 1), alignment};
    return ret;
}

static LUID *STDMETHODCALLTYPE device_GetAdapterLuid(Device *d, LUID *ret) {
    *ret = (LUID){0x1234, 0};
    return ret;
}

// ---------------------------------------------------------------- features
static HRESULT STDMETHODCALLTYPE device_CheckFeatureSupport(Device *d, D3D12_FEATURE feature, void *data, UINT size) {
    switch (feature) {
    case D3D12_FEATURE_D3D12_OPTIONS: {
        D3D12_FEATURE_DATA_D3D12_OPTIONS *o = data;
        memset(o, 0, size);
        o->ResourceBindingTier = D3D12_RESOURCE_BINDING_TIER_3;
        o->ResourceHeapTier = D3D12_RESOURCE_HEAP_TIER_2;
        o->TypedUAVLoadAdditionalFormats = TRUE;
        o->MaxGPUVirtualAddressBitsPerResource = 40;
        return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS1: {
        D3D12_FEATURE_DATA_D3D12_OPTIONS1 *o = data;
        memset(o, 0, size);
        o->WaveOps = TRUE; // Apple GPUs run 32-wide SIMD groups
        o->WaveLaneCountMin = o->WaveLaneCountMax = 32;
        o->TotalLaneCount = 32 * 32;
        o->ExpandedComputeResourceStates = TRUE;
        o->Int64ShaderOps = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_FEATURE_LEVELS: {
        D3D12_FEATURE_DATA_FEATURE_LEVELS *f = data;
        f->MaxSupportedFeatureLevel = D3D_FEATURE_LEVEL_1_0_CORE; // "none": below the lowest real level
        for (UINT i = 0; i < f->NumFeatureLevels; i++)
            if (f->pFeatureLevelsRequested[i] <= D3D_FEATURE_LEVEL_12_1 &&
                f->pFeatureLevelsRequested[i] > f->MaxSupportedFeatureLevel)
                f->MaxSupportedFeatureLevel = f->pFeatureLevelsRequested[i];
        return S_OK;
    }
    case D3D12_FEATURE_FORMAT_SUPPORT: {
        D3D12_FEATURE_DATA_FORMAT_SUPPORT *f = data;
        memset(&f->Support1, 0xFF, sizeof f->Support1); // every capability bit
        memset(&f->Support2, 0xFF, sizeof f->Support2);
        return S_OK;
    }
    case D3D12_FEATURE_SHADER_MODEL: {
        D3D12_FEATURE_DATA_SHADER_MODEL *m = data;
        if (m->HighestShaderModel > D3D_SHADER_MODEL_6_6) m->HighestShaderModel = D3D_SHADER_MODEL_6_6;
        return S_OK;
    }
    case D3D12_FEATURE_ROOT_SIGNATURE: {
        D3D12_FEATURE_DATA_ROOT_SIGNATURE *r = data;
        if (r->HighestVersion > D3D_ROOT_SIGNATURE_VERSION_1_1) r->HighestVersion = D3D_ROOT_SIGNATURE_VERSION_1_1;
        return S_OK;
    }
    case D3D12_FEATURE_ARCHITECTURE1: {
        D3D12_FEATURE_DATA_ARCHITECTURE1 *a = data;
        a->TileBasedRenderer = FALSE;
        a->UMA = a->CacheCoherentUMA = TRUE;
        a->IsolatedMMU = FALSE;
        return S_OK;
    }
    default: // everything else: the zeroed structure means "not supported"
        memset(data, 0, size);
        return S_OK;
    }
}

static UINT STDMETHODCALLTYPE device_GetNodeCount(Device *d) { return 1; }
static HRESULT STDMETHODCALLTYPE device_GetDeviceRemovedReason(Device *d) { return S_OK; }
static HRESULT STDMETHODCALLTYPE device_SetStablePowerState(Device *d, WINBOOL enable) { return S_OK; }

// Residency is managed by Metal.
static HRESULT STDMETHODCALLTYPE device_MakeResident(Device *d, UINT count, ID3D12Pageable *const *objects) {
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE device_SetResidencyPriority(Device *d, UINT count, ID3D12Pageable *const *objects,
                                                             const D3D12_RESIDENCY_PRIORITY *priorities) {
    return S_OK;
}

static ID3D12Device2Vtbl device_vtbl = {
    .QueryInterface = (void *)com_QueryInterface,
    .AddRef = (void *)com_AddRef,
    .Release = (void *)com_Release,
    .GetPrivateData = (void *)com_GetPrivateData,
    .SetPrivateData = (void *)com_SetPrivateData,
    .SetPrivateDataInterface = (void *)com_SetPrivateDataInterface,
    .SetName = (void *)com_SetName,
    .GetNodeCount = (void *)device_GetNodeCount,
    .CreateCommandQueue = (void *)device_CreateCommandQueue,
    .CreateCommandAllocator = (void *)device_CreateCommandAllocator,
    .CreateGraphicsPipelineState = (void *)device_CreateGraphicsPipelineState,
    .CreateComputePipelineState = (void *)device_CreateComputePipelineState,
    .CreateCommandList = (void *)device_CreateCommandList,
    .CheckFeatureSupport = (void *)device_CheckFeatureSupport,
    .CreateDescriptorHeap = (void *)device_CreateDescriptorHeap,
    .GetDescriptorHandleIncrementSize = (void *)device_GetDescriptorHandleIncrementSize,
    .CreateRootSignature = (void *)device_CreateRootSignature,
    .CreateConstantBufferView = (void *)device_CreateConstantBufferView,
    .CreateShaderResourceView = (void *)device_CreateShaderResourceView,
    .CreateUnorderedAccessView = (void *)device_CreateUnorderedAccessView,
    .CreateRenderTargetView = (void *)device_CreateRenderTargetView,
    .CreateDepthStencilView = (void *)device_CreateDepthStencilView,
    .CreateSampler = (void *)device_CreateSampler,
    .CopyDescriptors = (void *)device_CopyDescriptors,
    .CopyDescriptorsSimple = (void *)device_CopyDescriptorsSimple,
    .GetResourceAllocationInfo = (void *)device_GetResourceAllocationInfo, // hidden result pointer
    .CreateCommittedResource = (void *)device_CreateCommittedResource,
    .CreateHeap = (void *)device_CreateHeap,
    .CreatePlacedResource = (void *)device_CreatePlacedResource,
    .MakeResident = (void *)device_MakeResident,
    .Evict = (void *)device_MakeResident,
    .CreateFence = (void *)device_CreateFence,
    .GetDeviceRemovedReason = (void *)device_GetDeviceRemovedReason,
    .GetCopyableFootprints = (void *)device_GetCopyableFootprints,
    .SetStablePowerState = (void *)device_SetStablePowerState,
    .CreateCommandSignature = (void *)device_CreateCommandSignature,
    .GetAdapterLuid = (void *)device_GetAdapterLuid, // hidden result pointer
    .SetResidencyPriority = (void *)device_SetResidencyPriority,
    .CreatePipelineState = (void *)device_CreatePipelineState,
};
static const IID *const device_iids[] = {&IID_ID3D12Device2, &IID_ID3D12Device1, &IID_ID3D12Device, &IID_ID3D12Object,
                                         NULL};

HRESULT d3d12_create_device(void *adapter, REFIID iid, void **out) {
    if (!g_device) {
        FILL_UNIMPLEMENTED(device_vtbl);
        g_device = calloc(1, sizeof *g_device);
        object_init(&g_device->object, &device_vtbl, device_iids, g_device);
        g_device->mtl = [backend_mtl_device() retain];
        D3D_LOG("device: %s", g_device->mtl.name.UTF8String);
    }
    if (!out) return S_FALSE; // capability check only
    return object_query(&g_device->object, iid, out);
}

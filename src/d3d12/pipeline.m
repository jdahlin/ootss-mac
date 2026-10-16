// Pipeline state objects: render and compute pipelines, depth-stencil state, command signatures.
#include <ctype.h>
#include "objects.h"

MTLCompareFunction compare_function(D3D12_COMPARISON_FUNC f); // descriptor.m

// ---------------------------------------------------------------- state translation
static MTLBlendFactor blend_factor(D3D12_BLEND b) {
    switch (b) {
    case D3D12_BLEND_ZERO: return MTLBlendFactorZero;
    case D3D12_BLEND_ONE: return MTLBlendFactorOne;
    case D3D12_BLEND_SRC_COLOR: return MTLBlendFactorSourceColor;
    case D3D12_BLEND_INV_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
    case D3D12_BLEND_SRC_ALPHA: return MTLBlendFactorSourceAlpha;
    case D3D12_BLEND_INV_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
    case D3D12_BLEND_DEST_ALPHA: return MTLBlendFactorDestinationAlpha;
    case D3D12_BLEND_INV_DEST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
    case D3D12_BLEND_DEST_COLOR: return MTLBlendFactorDestinationColor;
    case D3D12_BLEND_INV_DEST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
    case D3D12_BLEND_SRC_ALPHA_SAT: return MTLBlendFactorSourceAlphaSaturated;
    case D3D12_BLEND_BLEND_FACTOR: return MTLBlendFactorBlendColor;
    case D3D12_BLEND_INV_BLEND_FACTOR: return MTLBlendFactorOneMinusBlendColor;
    case D3D12_BLEND_SRC1_COLOR: return MTLBlendFactorSource1Color;
    case D3D12_BLEND_INV_SRC1_COLOR: return MTLBlendFactorOneMinusSource1Color;
    case D3D12_BLEND_SRC1_ALPHA: return MTLBlendFactorSource1Alpha;
    case D3D12_BLEND_INV_SRC1_ALPHA: return MTLBlendFactorOneMinusSource1Alpha;
    default: return MTLBlendFactorOne;
    }
}

static MTLBlendOperation blend_operation(D3D12_BLEND_OP op) {
    switch (op) {
    case D3D12_BLEND_OP_SUBTRACT: return MTLBlendOperationSubtract;
    case D3D12_BLEND_OP_REV_SUBTRACT: return MTLBlendOperationReverseSubtract;
    case D3D12_BLEND_OP_MIN: return MTLBlendOperationMin;
    case D3D12_BLEND_OP_MAX: return MTLBlendOperationMax;
    default: return MTLBlendOperationAdd;
    }
}

static MTLColorWriteMask write_mask(UINT8 mask) {
    return ((mask & D3D12_COLOR_WRITE_ENABLE_RED) ? MTLColorWriteMaskRed : 0) |
           ((mask & D3D12_COLOR_WRITE_ENABLE_GREEN) ? MTLColorWriteMaskGreen : 0) |
           ((mask & D3D12_COLOR_WRITE_ENABLE_BLUE) ? MTLColorWriteMaskBlue : 0) |
           ((mask & D3D12_COLOR_WRITE_ENABLE_ALPHA) ? MTLColorWriteMaskAlpha : 0);
}

static MTLStencilOperation stencil_operation(D3D12_STENCIL_OP op) {
    switch (op) {
    case D3D12_STENCIL_OP_ZERO: return MTLStencilOperationZero;
    case D3D12_STENCIL_OP_REPLACE: return MTLStencilOperationReplace;
    case D3D12_STENCIL_OP_INCR_SAT: return MTLStencilOperationIncrementClamp;
    case D3D12_STENCIL_OP_DECR_SAT: return MTLStencilOperationDecrementClamp;
    case D3D12_STENCIL_OP_INVERT: return MTLStencilOperationInvert;
    case D3D12_STENCIL_OP_INCR: return MTLStencilOperationIncrementWrap;
    case D3D12_STENCIL_OP_DECR: return MTLStencilOperationDecrementWrap;
    default: return MTLStencilOperationKeep;
    }
}

static MTLStencilDescriptor *stencil_descriptor(const D3D12_DEPTH_STENCILOP_DESC *op, UINT8 read_mask,
                                                UINT8 write_mask_) {
    MTLStencilDescriptor *s = [[MTLStencilDescriptor alloc] init];
    s.stencilCompareFunction = compare_function(op->StencilFunc);
    s.stencilFailureOperation = stencil_operation(op->StencilFailOp);
    s.depthFailureOperation = stencil_operation(op->StencilDepthFailOp);
    s.depthStencilPassOperation = stencil_operation(op->StencilPassOp);
    s.readMask = read_mask;
    s.writeMask = write_mask_;
    return [s autorelease];
}

static id<MTLDepthStencilState> make_depth_stencil_state(Device *device, const D3D12_DEPTH_STENCIL_DESC *d) {
    MTLDepthStencilDescriptor *desc = [[MTLDepthStencilDescriptor alloc] init];
    desc.depthCompareFunction = d->DepthEnable ? compare_function(d->DepthFunc) : MTLCompareFunctionAlways;
    desc.depthWriteEnabled = d->DepthEnable && d->DepthWriteMask == D3D12_DEPTH_WRITE_MASK_ALL;
    if (d->StencilEnable) {
        desc.frontFaceStencil = stencil_descriptor(&d->FrontFace, d->StencilReadMask, d->StencilWriteMask);
        desc.backFaceStencil = stencil_descriptor(&d->BackFace, d->StencilReadMask, d->StencilWriteMask);
    }
    id<MTLDepthStencilState> state = [device->mtl newDepthStencilStateWithDescriptor:desc];
    [desc release];
    return state;
}

static MTLPrimitiveTopologyClass topology_class(D3D12_PRIMITIVE_TOPOLOGY_TYPE t) {
    switch (t) {
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT: return MTLPrimitiveTopologyClassPoint;
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE: return MTLPrimitiveTopologyClassLine;
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE: return MTLPrimitiveTopologyClassTriangle;
    default: return MTLPrimitiveTopologyClassUnspecified;
    }
}

// ---------------------------------------------------------------- vertex input
static UINT vertex_bytes(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R32G32B32A32_FLOAT:
    case DXGI_FORMAT_R32G32B32A32_UINT:
    case DXGI_FORMAT_R32G32B32A32_SINT: return 16;
    case DXGI_FORMAT_R32G32B32_FLOAT:
    case DXGI_FORMAT_R32G32B32_UINT:
    case DXGI_FORMAT_R32G32B32_SINT: return 12;
    case DXGI_FORMAT_R32G32_FLOAT:
    case DXGI_FORMAT_R32G32_UINT:
    case DXGI_FORMAT_R32G32_SINT:
    case DXGI_FORMAT_R16G16B16A16_FLOAT:
    case DXGI_FORMAT_R16G16B16A16_UNORM:
    case DXGI_FORMAT_R16G16B16A16_SNORM:
    case DXGI_FORMAT_R16G16B16A16_UINT:
    case DXGI_FORMAT_R16G16B16A16_SINT: return 8;
    case DXGI_FORMAT_R16G16_FLOAT:
    case DXGI_FORMAT_R16G16_UNORM:
    case DXGI_FORMAT_R16G16_SNORM:
    case DXGI_FORMAT_R16G16_UINT:
    case DXGI_FORMAT_R16G16_SINT: return 4;
    case DXGI_FORMAT_R8G8_UNORM:
    case DXGI_FORMAT_R8G8_UINT: return 2;
    default: return 4; // R8G8B8A8_*, R10G10B10A2, R32_*
    }
}

// The shader names its inputs by lower-case semantic and index ("texcoord1"); the layout by name and index.
static bool find_attribute(const ShaderInfo *info, const D3D12_INPUT_ELEMENT_DESC *e, uint32_t *attribute) {
    char name[64];
    snprintf(name, sizeof name, "%s%u", e->SemanticName, e->SemanticIndex);
    for (char *c = name; *c; c++) *c = tolower((unsigned char)*c);
    for (uint32_t i = 0; i < info->input_count; i++) {
        if (!strcmp(info->inputs[i].name, name)) {
            *attribute = info->inputs[i].attribute;
            return true;
        }
    }
    return false;
}

static MTLVertexDescriptor *make_vertex_descriptor(const D3D12_INPUT_LAYOUT_DESC *layout, const ShaderInfo *info) {
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    UINT next_offset[D3D12_IA_VERTEX_INPUT_RESOURCE_SLOT_COUNT] = {0};
    for (UINT i = 0; i < layout->NumElements; i++) {
        const D3D12_INPUT_ELEMENT_DESC *e = &layout->pInputElementDescs[i];
        UINT slot = e->InputSlot;
        UINT offset = e->AlignedByteOffset == D3D12_APPEND_ALIGNED_ELEMENT ? next_offset[slot] : e->AlignedByteOffset;
        next_offset[slot] = offset + vertex_bytes(e->Format);

        uint32_t attribute;
        if (!find_attribute(info, e, &attribute)) continue; // not read by the shader

        // Metal rejects a buffer layout that no attribute uses, so layouts are set only here.
        NSUInteger buffer_index = BIND_VERTEX_BUFFERS + slot;
        MTLVertexBufferLayoutDescriptor *l = vd.layouts[buffer_index];
        l.stride = MTLBufferLayoutStrideDynamic; // the stride comes from the vertex buffer view at draw time
        bool per_instance = e->InputSlotClass == D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA;
        l.stepFunction = per_instance ? MTLVertexStepFunctionPerInstance : MTLVertexStepFunctionPerVertex;
        l.stepRate = per_instance ? MAX(e->InstanceDataStepRate, 1) : 1;

        MTLVertexAttributeDescriptor *a = vd.attributes[BIND_FIRST_STAGE_IN_ATTRIBUTE + attribute];
        a.format = mtl_vertex_format(e->Format);
        a.offset = offset;
        a.bufferIndex = buffer_index;
    }
    return vd;
}

// ---------------------------------------------------------------- ID3D12PipelineState
static void pipeline_destroy(Object *o) {
    PipelineState *p = (PipelineState *)o;
    [p->render release];
    [p->compute_state release];
    [p->depth_stencil release];
    free(p);
}

static HRESULT STDMETHODCALLTYPE pipeline_GetCachedBlob(PipelineState *p, void **blob) {
    *blob = NULL;
    return E_NOTIMPL;
}

static ID3D12PipelineStateVtbl pipeline_vtbl = {ID3D12_OBJECT_METHODS, .GetDevice = (void *)com_GetDevice,
                                                .GetCachedBlob = (void *)pipeline_GetCachedBlob};
static const IID *const pipeline_iids[] = {&IID_ID3D12PipelineState, &IID_ID3D12Pageable, &IID_ID3D12DeviceChild,
                                           &IID_ID3D12Object, NULL};

static PipelineState *pipeline_new(Device *device, bool compute) {
    static bool vtbl_ready;
    if (!vtbl_ready++) FILL_UNIMPLEMENTED(pipeline_vtbl);
    PipelineState *p = calloc(1, sizeof *p);
    object_init(&p->object, &pipeline_vtbl, pipeline_iids, device);
    p->object.destroy = pipeline_destroy;
    p->compute = compute;
    return p;
}

static HRESULT pipeline_give(PipelineState *p, REFIID iid, void **out) {
    HRESULT hr = object_query(&p->object, iid, out);
    object_release(&p->object);
    return out ? hr : S_FALSE;
}

// A function from a converted library. Some carry function constants (dual-source blending); we never use them.
static id<MTLFunction> library_function(id<MTLLibrary> library, NSString *name) {
    MTLFunctionConstantValues *constants = [[MTLFunctionConstantValues alloc] init];
    bool no = false;
    [constants setConstantValue:&no type:MTLDataTypeBool withName:@"dualSourceEnabled"];
    NSError *error = nil;
    id<MTLFunction> function = [library newFunctionWithName:name constantValues:constants error:&error];
    [constants release];
    if (!function) {
        function = [library newFunctionWithName:name]; // no such constant
    }
    if (!function)
        D3D_LOG("no function %s in a converted shader: %s", name.UTF8String, error.localizedDescription.UTF8String);
    return function;
}

HRESULT graphics_pipeline_create(Device *device, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, REFIID iid,
                                 void **out) {
    PipelineState *p = pipeline_new(device, false);
    p->topology_type = desc->PrimitiveTopologyType;
    p->sample_count = MAX(desc->SampleDesc.Count, 1);
    p->cull_mode = desc->RasterizerState.CullMode == D3D12_CULL_MODE_NONE    ? MTLCullModeNone
                   : desc->RasterizerState.CullMode == D3D12_CULL_MODE_FRONT ? MTLCullModeFront
                                                                             : MTLCullModeBack;
    p->fill_mode = desc->RasterizerState.FillMode == D3D12_FILL_MODE_WIREFRAME ? MTLTriangleFillModeLines
                                                                               : MTLTriangleFillModeFill;
    p->depth_clip = desc->RasterizerState.DepthClipEnable ? MTLDepthClipModeClip : MTLDepthClipModeClamp;
    p->depth_bias = desc->RasterizerState.DepthBias;
    p->slope_scaled_depth_bias = desc->RasterizerState.SlopeScaledDepthBias;
    p->depth_bias_clamp = desc->RasterizerState.DepthBiasClamp;
    p->front_counter_clockwise = desc->RasterizerState.FrontCounterClockwise;
    p->depth_stencil = make_depth_stencil_state(device, &desc->DepthStencilState);

    NSString *vs_name = nil, *ps_name = nil;
    ShaderInfo vs_info = {0}, ps_info = {0};
    id<MTLLibrary> vs_lib =
        shader_library_create(device->mtl, &desc->VS, (RootSignature *)desc->pRootSignature, &vs_name, &vs_info);
    id<MTLLibrary> ps_lib =
        desc->PS.pShaderBytecode
            ? shader_library_create(device->mtl, &desc->PS, (RootSignature *)desc->pRootSignature, &ps_name, &ps_info)
            : nil;
    if (!vs_lib || (desc->PS.pShaderBytecode && !ps_lib)) {
        [vs_lib release];
        [ps_lib release];
        return pipeline_give(p, iid, out); // unusable pipeline; creation still succeeds
    }

    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = [library_function(vs_lib, vs_name) autorelease];
    if (ps_lib) d.fragmentFunction = [library_function(ps_lib, ps_name) autorelease];
    d.vertexDescriptor = make_vertex_descriptor(&desc->InputLayout, &vs_info);
    d.rasterSampleCount = p->sample_count;
    d.alphaToCoverageEnabled = desc->BlendState.AlphaToCoverageEnable;
    d.inputPrimitiveTopology = topology_class(desc->PrimitiveTopologyType);
    d.label = [NSString stringWithFormat:@"%@+%@", vs_name, ps_name];

    for (UINT i = 0; i < desc->NumRenderTargets; i++) {
        const D3D12_RENDER_TARGET_BLEND_DESC *b =
            &desc->BlendState.RenderTarget[desc->BlendState.IndependentBlendEnable ? i : 0];
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
        c.pixelFormat = mtl_format(desc->RTVFormats[i]);
        c.writeMask = write_mask(b->RenderTargetWriteMask);
        if (b->BlendEnable) {
            c.blendingEnabled = YES;
            c.sourceRGBBlendFactor = blend_factor(b->SrcBlend);
            c.destinationRGBBlendFactor = blend_factor(b->DestBlend);
            c.rgbBlendOperation = blend_operation(b->BlendOp);
            c.sourceAlphaBlendFactor = blend_factor(b->SrcBlendAlpha);
            c.destinationAlphaBlendFactor = blend_factor(b->DestBlendAlpha);
            c.alphaBlendOperation = blend_operation(b->BlendOpAlpha);
        }
    }
    if (desc->DSVFormat != DXGI_FORMAT_UNKNOWN) {
        MTLPixelFormat depth = mtl_format(desc->DSVFormat);
        d.depthAttachmentPixelFormat = depth;
        if (depth == MTLPixelFormatDepth32Float_Stencil8) d.stencilAttachmentPixelFormat = depth;
    }

    NSError *error = nil;
    p->render = [device->mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p->render) D3D_LOG("render pipeline %s failed: %s", d.label.UTF8String, error.localizedDescription.UTF8String);
    p->valid = p->render != nil;
    [d release];
    [vs_lib release];
    [ps_lib release];
    return pipeline_give(p, iid, out);
}

HRESULT compute_pipeline_create(Device *device, const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc, REFIID iid, void **out) {
    PipelineState *p = pipeline_new(device, true);
    NSString *name = nil;
    ShaderInfo info = {0};
    id<MTLLibrary> lib =
        shader_library_create(device->mtl, &desc->CS, (RootSignature *)desc->pRootSignature, &name, &info);
    if (lib) {
        NSError *error = nil;
        id<MTLFunction> function = library_function(lib, name);
        p->compute_state = [device->mtl newComputePipelineStateWithFunction:function error:&error];
        if (!p->compute_state)
            D3D_LOG("compute pipeline %s failed: %s", name.UTF8String, error.localizedDescription.UTF8String);
        p->threads_per_group = MTLSizeMake(MAX(info.threads_per_group[0], 1), MAX(info.threads_per_group[1], 1),
                                           MAX(info.threads_per_group[2], 1));
        p->valid = p->compute_state != nil;
        [function release];
        [lib release];
    }
    return pipeline_give(p, iid, out);
}

// ---------------------------------------------------------------- ID3D12CommandSignature
static void free_object(Object *o) { free(o); }

static ID3D12CommandSignatureVtbl command_signature_vtbl = {ID3D12_OBJECT_METHODS, .GetDevice = (void *)com_GetDevice};
static const IID *const command_signature_iids[] = {&IID_ID3D12CommandSignature, &IID_ID3D12Pageable,
                                                    &IID_ID3D12DeviceChild, &IID_ID3D12Object, NULL};

HRESULT command_signature_create(Device *device, const D3D12_COMMAND_SIGNATURE_DESC *desc, REFIID iid, void **out) {
    CommandSignature *c = calloc(1, sizeof *c);
    object_init(&c->object, &command_signature_vtbl, command_signature_iids, device);
    c->object.destroy = free_object;
    c->byte_stride = desc->ByteStride;
    c->argument_count = MIN(desc->NumArgumentDescs, 8u);
    memcpy(c->arguments, desc->pArgumentDescs, c->argument_count * sizeof *c->arguments);
    char layout[256] = "";
    for (UINT i = 0; i < c->argument_count; i++) {
        const D3D12_INDIRECT_ARGUMENT_DESC *a = &c->arguments[i];
        size_t n = strlen(layout);
        snprintf(layout + n, sizeof layout - n, " %d", (int)a->Type);
        if (a->Type == D3D12_INDIRECT_ARGUMENT_TYPE_CONSTANT)
            snprintf(layout + strlen(layout), sizeof layout - strlen(layout), "(root %u, +%u, %u values)",
                     a->Constant.RootParameterIndex, a->Constant.DestOffsetIn32BitValues,
                     a->Constant.Num32BitValuesToSet);
    }
    D3D_LOG("command signature: stride %u, arguments:%s", desc->ByteStride, layout);
    HRESULT hr = object_query(&c->object, iid, out);
    object_release(&c->object);
    return hr;
}

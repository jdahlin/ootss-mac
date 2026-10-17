// Replays recorded command lists into a Metal command buffer.
//
// State is tracked the way D3D12 has it (pipeline, root arguments, targets, ...) and applied to Metal
// encoders lazily: a render encoder is opened by the first draw after the render targets change, compute
// and blit work get their own encoders, and clears are folded into the next pass over the same target.
// Resources are untracked, so every encoder waits for the previous one through the queue's MTLFence.
#include "commands.h"

#define ROOT_ARGUMENTS_MAX 2048 // bytes of top-level argument buffer we can shadow
#define PENDING_CLEARS_MAX 16
#define NO_ATTACHMENT_SIZE 4096 // render passes without attachments still need a size

enum {
    DIRTY_PIPELINE = 1 << 0,
    DIRTY_VIEWPORTS = 1 << 1,
    DIRTY_SCISSORS = 1 << 2,
    DIRTY_BLEND_FACTOR = 1 << 3,
    DIRTY_STENCIL_REF = 1 << 4,
    DIRTY_VERTEX_BUFFERS = 1 << 5,
    DIRTY_HEAPS = 1 << 6,
    DIRTY_ROOT = 1 << 7,
    DIRTY_ALL = 0xff,
};

typedef enum { ENCODER_NONE, ENCODER_RENDER, ENCODER_COMPUTE, ENCODER_BLIT } EncoderKind;

typedef struct PendingClear {
    bool depth;
    View view;
    float color[4];
    D3D12_CLEAR_FLAGS flags;
    float depth_value;
    uint8_t stencil_value;
} PendingClear;

typedef struct RootState {
    RootSignature *signature;
    uint8_t arguments[ROOT_ARGUMENTS_MAX];
} RootState;

typedef struct Replay {
    CommandQueue *queue;
    id<MTLCommandBuffer> cb;
    EncoderKind kind;
    id<MTLRenderCommandEncoder> render;
    id<MTLComputeCommandEncoder> compute;
    id<MTLBlitCommandEncoder> blit;
    unsigned dirty;         // graphics state not yet applied to the current render encoder
    unsigned compute_dirty; // same for the compute encoder

    PipelineState *graphics_pipeline, *compute_pipeline;
    RootState graphics_root, compute_root;
    DescriptorHeap *heaps[MAX_LIST_HEAPS];
    D3D12_PRIMITIVE_TOPOLOGY topology;
    D3D12_VERTEX_BUFFER_VIEW vertex_buffers[MAX_VERTEX_SLOTS];
    D3D12_INDEX_BUFFER_VIEW index_buffer;
    uint32_t viewport_count, scissor_count;
    D3D12_VIEWPORT viewports[MAX_VIEWPORTS];
    D3D12_RECT scissors[MAX_VIEWPORTS];
    float blend_factor[4];
    uint32_t stencil_ref;

    uint32_t target_count;
    View colors[MAX_RENDER_TARGETS];
    View depth;
    bool has_depth;
    bool targets_open;    // the open render encoder draws to the current targets
    bool outputless_open; // the open render encoder is an attachment-less pass (see prepare_draw_checked)
    UINT outputless_samples;

    Profile *profile;
    int pass_slot;                // profile slot of the open encoder, or -1
    unsigned pass_count;          // draws or dispatches in the open encoder
    PipelineState *pass_pipeline; // the compute shader of the open compute encoder (profiling)

    PendingClear pending[PENDING_CLEARS_MAX];
    int pending_count;
} Replay;

// ---------------------------------------------------------------- encoders
static id<MTLTexture> attachment_texture(const View *v);
static void select_slice(const View *v, id<MTLTexture> texture, NSUInteger *level, NSUInteger *slice,
                         NSUInteger *plane);

static struct {
    unsigned lists, draws, skipped, dispatches, passes, indirect, backbuffer_draws, backbuffer_clears;
} g_stats;

// D3D12_PROBE_LIST=<n> reports, for the n-th executed list, how much of each render pass's first target is
// non-zero once the list has run. A debugging aid for "everything is black" problems.
static void probe_target(Replay *r, const View *v, unsigned pass) {
    static int target = -2;
    if (target == -2) target = getenv("D3D12_PROBE_LIST") ? atoi(getenv("D3D12_PROBE_LIST")) : -1;
    if (target < 0 || (unsigned)target != g_stats.lists || !v->resource || !v->resource->texture) return;
    id<MTLTexture> t = attachment_texture(v);
    NSUInteger bpp = 0;
    switch (t.pixelFormat) {
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatRG11B10Float:
    case MTLPixelFormatR32Float:
    case MTLPixelFormatRGB10A2Unorm: bpp = 4; break;
    case MTLPixelFormatRGBA16Float: bpp = 8; break;
    case MTLPixelFormatR16Float:
    case MTLPixelFormatRG8Unorm: bpp = 2; break;
    case MTLPixelFormatR8Unorm: bpp = 1; break;
    default: break;
    }
    if (!bpp || t.sampleCount > 1) {
        D3D_LOG("probe pass %u: %lux%lu format %lu samples %lu not read back", pass, (unsigned long)t.width,
                (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)t.sampleCount);
        return;
    }
    NSUInteger w = MAX(t.width >> v->mip, 1ul), h = MAX(t.height >> v->mip, 1ul);
    id<MTLBuffer> buffer = [r->cb.device newBufferWithLength:w * h * bpp options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [r->cb blitCommandEncoder];
    [blit waitForFence:r->queue->fence];
    NSUInteger level, slice, plane;
    select_slice(v, t, &level, &slice, &plane);
    [blit copyFromTexture:t
                     sourceSlice:slice
                     sourceLevel:level
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(w, h, 1)
                        toBuffer:buffer
               destinationOffset:0
          destinationBytesPerRow:w * bpp
        destinationBytesPerImage:w * h * bpp];
    [blit updateFence:r->queue->fence];
    [blit endEncoding];
    unsigned long format = t.pixelFormat;
    [r->cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
      const uint8_t *px = buffer.contents;
      size_t lit = 0, n = w * h * bpp;
      for (size_t i = 0; i < n; i++) lit += px[i] != 0;
      D3D_LOG("probe pass %u: %lux%lu format %lu, %.1f%% of bytes non-zero", pass, (unsigned long)w, (unsigned long)h,
              format, 100.0 * lit / n);
      [buffer release];
    }];
}

static bool fences_disabled(void) { // D3D12_NO_FENCE=1 (unsafe, for measuring what the fence chain costs)
    static int disabled = -1;
    if (disabled < 0) disabled = getenv("D3D12_NO_FENCE") != NULL;
    return disabled;
}

static void end_encoder(Replay *r) {
    View probed = r->colors[0];
    bool was_render = r->kind == ENCODER_RENDER;
    unsigned pass = g_stats.passes;
    id<MTLCommandEncoder> e = nil;
    switch (r->kind) {
    case ENCODER_RENDER:
        [r->render updateFence:r->queue->fence afterStages:MTLRenderStageFragment];
        e = r->render;
        break;
    case ENCODER_COMPUTE:
        [r->compute updateFence:r->queue->fence];
        e = r->compute;
        break;
    case ENCODER_BLIT:
        [r->blit updateFence:r->queue->fence];
        e = r->blit;
        break;
    case ENCODER_NONE: return;
    }
    [e endEncoding];
    if (r->profile && r->pass_slot >= 0) {
        char key[64];
        if (was_render && probed.resource && probed.resource->texture)
            snprintf(key, sizeof key, "render %lux%lu fmt %lu x%lu%s", (unsigned long)probed.resource->texture.width,
                     (unsigned long)probed.resource->texture.height,
                     (unsigned long)probed.resource->texture.pixelFormat,
                     (unsigned long)probed.resource->texture.sampleCount, r->has_depth ? "+depth" : "");
        else if (was_render)
            snprintf(key, sizeof key, "render (clear or resolve)");
        else
            snprintf(key, sizeof key, "%s", r->kind == ENCODER_COMPUTE ? "compute" : "blit");
        if (r->kind == ENCODER_COMPUTE && r->pass_pipeline)
            snprintf(key, sizeof key, "compute %08x %lux%lux%lu", r->pass_pipeline->id,
                     (unsigned long)r->pass_pipeline->threads_per_group.width,
                     (unsigned long)r->pass_pipeline->threads_per_group.height,
                     (unsigned long)r->pass_pipeline->threads_per_group.depth);
        profile_label(r->profile, r->pass_slot, key, r->pass_count);
    }
    r->pass_slot = -1;
    r->pass_count = 0;
    r->queue->fence_used = true;
    r->kind = ENCODER_NONE;
    r->render = nil;
    r->compute = nil;
    r->blit = nil;
    r->targets_open = false;
    r->outputless_open = false;
    if (was_render) probe_target(r, &probed, pass);
}

static id<MTLRenderCommandEncoder> open_render(Replay *r, MTLRenderPassDescriptor *pass) {
    end_encoder(r);
    if (r->profile && (r->pass_slot = profile_slot(r->profile)) >= 0) {
        MTLRenderPassSampleBufferAttachmentDescriptor *a = pass.sampleBufferAttachments[0];
        a.sampleBuffer = profile_samples(r->profile);
        a.startOfVertexSampleIndex = 2 * r->pass_slot;
        a.endOfVertexSampleIndex = MTLCounterDontSample;
        a.startOfFragmentSampleIndex = MTLCounterDontSample;
        a.endOfFragmentSampleIndex = 2 * r->pass_slot + 1;
    }
    id<MTLRenderCommandEncoder> e = [r->cb renderCommandEncoderWithDescriptor:pass];
    if (r->queue->fence_used && !fences_disabled()) [e waitForFence:r->queue->fence beforeStages:MTLRenderStageVertex];
    g_stats.passes++;
    r->render = e;
    r->kind = ENCODER_RENDER;
    r->dirty = DIRTY_ALL;
    return e;
}

static id<MTLComputeCommandEncoder> compute_encoder(Replay *r) {
    if (r->kind == ENCODER_COMPUTE) return r->compute;
    end_encoder(r);
    MTLComputePassDescriptor *pass = [MTLComputePassDescriptor computePassDescriptor];
    if (r->profile && (r->pass_slot = profile_slot(r->profile)) >= 0) {
        pass.sampleBufferAttachments[0].sampleBuffer = profile_samples(r->profile);
        pass.sampleBufferAttachments[0].startOfEncoderSampleIndex = 2 * r->pass_slot;
        pass.sampleBufferAttachments[0].endOfEncoderSampleIndex = 2 * r->pass_slot + 1;
    }
    r->compute = [r->cb computeCommandEncoderWithDescriptor:pass];
    if (r->queue->fence_used && !fences_disabled()) [r->compute waitForFence:r->queue->fence];
    r->kind = ENCODER_COMPUTE;
    r->compute_dirty = DIRTY_ALL;
    return r->compute;
}

static id<MTLBlitCommandEncoder> blit_encoder(Replay *r) {
    if (r->kind == ENCODER_BLIT) return r->blit;
    end_encoder(r);
    MTLBlitPassDescriptor *pass = [MTLBlitPassDescriptor blitPassDescriptor];
    if (r->profile && (r->pass_slot = profile_slot(r->profile)) >= 0) {
        pass.sampleBufferAttachments[0].sampleBuffer = profile_samples(r->profile);
        pass.sampleBufferAttachments[0].startOfEncoderSampleIndex = 2 * r->pass_slot;
        pass.sampleBufferAttachments[0].endOfEncoderSampleIndex = 2 * r->pass_slot + 1;
    }
    r->blit = [r->cb blitCommandEncoderWithDescriptor:pass];
    if (r->queue->fence_used && !fences_disabled()) [r->blit waitForFence:r->queue->fence];
    r->kind = ENCODER_BLIT;
    return r->blit;
}

// ---------------------------------------------------------------- attachments and clears
static bool view_equal(const View *a, const View *b) {
    return a->resource == b->resource && a->mip == b->mip && a->first_slice == b->first_slice &&
           a->slice_count == b->slice_count && a->format == b->format;
}

static id<MTLTexture> attachment_texture(const View *v) {
    Resource *r = v->resource;
    MTLPixelFormat format = v->format ? mtl_format((DXGI_FORMAT)v->format) : r->pixel_format;
    if (format == MTLPixelFormatInvalid || format == r->pixel_format) return r->texture;
    return resource_view(r, format, r->texture.textureType, NSMakeRange(0, r->texture.mipmapLevelCount),
                         NSMakeRange(0, MAX(r->texture.arrayLength, 1)));
}

static bool has_stencil(MTLPixelFormat f) {
    return f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatDepth24Unorm_Stencil8 ||
           f == MTLPixelFormatX32_Stencil8 || f == MTLPixelFormatStencil8;
}

static void select_slice(const View *v, id<MTLTexture> texture, NSUInteger *level, NSUInteger *slice,
                         NSUInteger *plane) {
    *level = v->mip;
    *slice = 0;
    *plane = 0;
    if (texture.textureType == MTLTextureType3D)
        *plane = v->first_slice;
    else if (texture.arrayLength > 1 || texture.textureType == MTLTextureType2DArray)
        *slice = v->first_slice;
}

static PendingClear *take_pending(Replay *r, const View *v, bool depth) {
    for (int i = 0; i < r->pending_count; i++) {
        PendingClear *p = &r->pending[i];
        if (p->depth == depth && view_equal(&p->view, v)) return p;
    }
    return NULL;
}

static void drop_pending(Replay *r, PendingClear *p) { *p = r->pending[--r->pending_count]; }

static void configure_color(MTLRenderPassColorAttachmentDescriptor *a, const View *v, const PendingClear *clear) {
    a.texture = attachment_texture(v);
    NSUInteger level, slice, plane;
    select_slice(v, a.texture, &level, &slice, &plane);
    a.level = level;
    a.slice = slice;
    a.depthPlane = plane;
    a.storeAction = MTLStoreActionStore;
    if (clear) {
        a.loadAction = MTLLoadActionClear;
        a.clearColor = MTLClearColorMake(clear->color[0], clear->color[1], clear->color[2], clear->color[3]);
    } else {
        a.loadAction = MTLLoadActionLoad;
    }
}

static void configure_depth(MTLRenderPassDescriptor *pass, const View *v, const PendingClear *clear) {
    id<MTLTexture> texture = attachment_texture(v);
    NSUInteger level, slice, plane;
    select_slice(v, texture, &level, &slice, &plane);
    bool clear_depth = clear && (clear->flags & D3D12_CLEAR_FLAG_DEPTH);
    bool clear_stencil = clear && (clear->flags & D3D12_CLEAR_FLAG_STENCIL);
    if (texture.pixelFormat != MTLPixelFormatStencil8) {
        pass.depthAttachment.texture = texture;
        pass.depthAttachment.level = level;
        pass.depthAttachment.slice = slice;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.loadAction = clear_depth ? MTLLoadActionClear : MTLLoadActionLoad;
        if (clear_depth) pass.depthAttachment.clearDepth = clear->depth_value;
    }
    if (has_stencil(texture.pixelFormat)) {
        pass.stencilAttachment.texture = texture;
        pass.stencilAttachment.level = level;
        pass.stencilAttachment.slice = slice;
        pass.stencilAttachment.storeAction = MTLStoreActionStore;
        pass.stencilAttachment.loadAction = clear_stencil ? MTLLoadActionClear : MTLLoadActionLoad;
        if (clear_stencil) pass.stencilAttachment.clearStencil = clear->stencil_value;
    }
}

// Executes a clear that no later pass absorbed.
static void flush_clear(Replay *r, const PendingClear *clear) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    if (clear->depth)
        configure_depth(pass, &clear->view, clear);
    else
        configure_color(pass.colorAttachments[0], &clear->view, clear);
    open_render(r, pass);
    end_encoder(r);
}

static void flush_clears(Replay *r) {
    while (r->pending_count) {
        PendingClear clear = r->pending[--r->pending_count];
        flush_clear(r, &clear);
    }
}

static void add_pending(Replay *r, const PendingClear *clear) {
    end_encoder(r);                              // draws recorded before the clear must run before it
    for (int i = 0; i < r->pending_count; i++) { // a newer clear of the same target replaces the older
        PendingClear *p = &r->pending[i];
        if (p->depth == clear->depth && view_equal(&p->view, &clear->view)) {
            if (clear->depth && (p->flags & ~clear->flags)) {
                PendingClear merged = *clear; // keep the older clear of the aspect this one leaves alone
                merged.flags |= p->flags;
                if (!(clear->flags & D3D12_CLEAR_FLAG_DEPTH)) merged.depth_value = p->depth_value;
                if (!(clear->flags & D3D12_CLEAR_FLAG_STENCIL)) merged.stencil_value = p->stencil_value;
                *p = merged;
            } else {
                *p = *clear;
            }
            return;
        }
    }
    if (r->pending_count == PENDING_CLEARS_MAX) {
        PendingClear oldest = r->pending[0];
        r->pending[0] = r->pending[--r->pending_count];
        flush_clear(r, &oldest);
    }
    r->pending[r->pending_count++] = *clear;
}

// ---------------------------------------------------------------- graphics state
static MTLPrimitiveType primitive_type(D3D12_PRIMITIVE_TOPOLOGY t) {
    switch (t) {
    case D3D_PRIMITIVE_TOPOLOGY_POINTLIST: return MTLPrimitiveTypePoint;
    case D3D_PRIMITIVE_TOPOLOGY_LINELIST: return MTLPrimitiveTypeLine;
    case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP: return MTLPrimitiveTypeLineStrip;
    case D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: return MTLPrimitiveTypeTriangleStrip;
    case D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST: return MTLPrimitiveTypeTriangle;
    default: D3D_TODO("primitive topology %d is drawn as a triangle list", (int)t); return MTLPrimitiveTypeTriangle;
    }
}

static bool ensure_render(Replay *r) {
    if (r->render && r->targets_open) return true;
    // No targets is legal (draws that only write UAVs); the pass then needs an explicit size.

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    PendingClear *used[MAX_RENDER_TARGETS + 1];
    int used_count = 0;
    for (uint32_t i = 0; i < r->target_count; i++) {
        const View *v = &r->colors[i];
        if (!v->resource) continue;
        PendingClear *p = take_pending(r, v, false);
        configure_color(pass.colorAttachments[i], v, p);
        if (p) used[used_count++] = p;
    }
    if (r->has_depth) {
        PendingClear *p = take_pending(r, &r->depth, true);
        configure_depth(pass, &r->depth, p);
        if (p) used[used_count++] = p;
    }
    // Clears for other targets run first, as clear-only passes.
    PendingClear absorbed[MAX_RENDER_TARGETS + 1];
    for (int i = 0; i < used_count; i++) absorbed[i] = *used[i];
    for (int i = 0; i < used_count; i++) {
        PendingClear *p = take_pending(r, &absorbed[i].view, absorbed[i].depth);
        if (p) drop_pending(r, p);
    }
    flush_clears(r);

    if (!pass.colorAttachments[0].texture && !pass.depthAttachment.texture && !pass.stencilAttachment.texture) {
        pass.renderTargetWidth = NO_ATTACHMENT_SIZE;
        pass.renderTargetHeight = NO_ATTACHMENT_SIZE;
        pass.defaultRasterSampleCount = 1;
    }
    open_render(r, pass);
    r->targets_open = true;
    return true;
}

static MTLScissorRect clamp_scissor(Replay *r, const D3D12_RECT *rect) {
    NSUInteger width = 0, height = 0;
    id<MTLTexture> t = r->target_count && r->colors[0].resource ? r->colors[0].resource->texture
                                                                : (r->has_depth ? r->depth.resource->texture : nil);
    if (t) {
        width = MAX(t.width >> r->colors[0].mip, 1ul);
        height = MAX(t.height >> r->colors[0].mip, 1ul);
    }
    NSInteger left = MAX(rect->left, 0), top = MAX(rect->top, 0);
    NSInteger right = rect->right, bottom = rect->bottom;
    if (t) {
        right = MIN(right, (NSInteger)width);
        bottom = MIN(bottom, (NSInteger)height);
    }
    return (MTLScissorRect){(NSUInteger)left, (NSUInteger)top, (NSUInteger)MAX(right - left, 0),
                            (NSUInteger)MAX(bottom - top, 0)};
}

static void bind_heaps(Replay *r, id<MTLRenderCommandEncoder> render, id<MTLComputeCommandEncoder> compute) {
    for (int i = 0; i < MAX_LIST_HEAPS; i++) {
        DescriptorHeap *h = r->heaps[i];
        if (!h) continue;
        NSUInteger index =
            h->desc.Type == D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER ? BIND_SAMPLER_HEAP : BIND_DESCRIPTOR_HEAP;
        if (render) {
            [render setVertexBuffer:h->table offset:0 atIndex:index];
            [render setFragmentBuffer:h->table offset:0 atIndex:index];
        } else {
            [compute setBuffer:h->table offset:0 atIndex:index];
        }
    }
}

static void apply_render_state(Replay *r) {
    id<MTLRenderCommandEncoder> e = r->render;
    PipelineState *p = r->graphics_pipeline;
    unsigned dirty = r->dirty;
    r->dirty = 0;
    if (dirty & DIRTY_PIPELINE) {
        [e setRenderPipelineState:p->render];
        if (p->depth_stencil) [e setDepthStencilState:p->depth_stencil];
        [e setCullMode:getenv("D3D12_NO_CULL") ? MTLCullModeNone : p->cull_mode];
        bool ccw = p->front_counter_clockwise != (getenv("D3D12_FLIP_WINDING") != NULL);
        [e setFrontFacingWinding:ccw ? MTLWindingCounterClockwise : MTLWindingClockwise];
        [e setTriangleFillMode:p->fill_mode];
        [e setDepthClipMode:p->depth_clip];
        [e setDepthBias:p->depth_bias slopeScale:p->slope_scaled_depth_bias clamp:p->depth_bias_clamp];
    }
    if (dirty & DIRTY_VIEWPORTS) {
        MTLViewport vp[MAX_VIEWPORTS];
        for (uint32_t i = 0; i < r->viewport_count; i++)
            vp[i] = (MTLViewport){r->viewports[i].TopLeftX, r->viewports[i].TopLeftY, r->viewports[i].Width,
                                  r->viewports[i].Height,   r->viewports[i].MinDepth, r->viewports[i].MaxDepth};
        if (r->viewport_count) [e setViewports:vp count:r->viewport_count];
    }
    if (dirty & DIRTY_SCISSORS) {
        MTLScissorRect sc[MAX_VIEWPORTS];
        for (uint32_t i = 0; i < r->scissor_count; i++) sc[i] = clamp_scissor(r, &r->scissors[i]);
        if (r->scissor_count) [e setScissorRects:sc count:r->scissor_count];
    }
    if (dirty & DIRTY_BLEND_FACTOR)
        [e setBlendColorRed:r->blend_factor[0]
                      green:r->blend_factor[1]
                       blue:r->blend_factor[2]
                      alpha:r->blend_factor[3]];
    if (dirty & DIRTY_STENCIL_REF) [e setStencilReferenceValue:r->stencil_ref];
    if (dirty & DIRTY_VERTEX_BUFFERS) {
        for (uint32_t slot = 0; slot < MAX_VERTEX_SLOTS; slot++) {
            const D3D12_VERTEX_BUFFER_VIEW *v = &r->vertex_buffers[slot];
            id<MTLBuffer> buffer;
            uint64_t offset;
            if (!v->BufferLocation || !buffer_for_address(v->BufferLocation, &buffer, &offset)) continue;
            [e setVertexBuffer:buffer
                         offset:offset
                attributeStride:v->StrideInBytes
                        atIndex:BIND_VERTEX_BUFFERS + slot];
        }
    }
    if (dirty & DIRTY_HEAPS) bind_heaps(r, e, nil);
    if (dirty & DIRTY_ROOT) {
        uint32_t size = r->graphics_root.signature ? r->graphics_root.signature->argument_buffer_size : 0;
        if (size) {
            [e setVertexBytes:r->graphics_root.arguments length:size atIndex:BIND_TOP_LEVEL];
            [e setFragmentBytes:r->graphics_root.arguments length:size atIndex:BIND_TOP_LEVEL];
        }
    }
}

static bool prepare_draw_checked(Replay *r);
static bool prepare_draw(Replay *r) {
    bool ok = prepare_draw_checked(r);
    if (ok) {
        g_stats.draws++;
        r->pass_count++;
    } else {
        g_stats.skipped++;
    }
    return ok;
}

static bool prepare_draw_checked(Replay *r) {
    PipelineState *p = r->graphics_pipeline;
    if (!p || p->compute || !p->valid || !p->render) {
        D3D_TODO("draw without a usable graphics pipeline is skipped");
        return false;
    }
    if (!p->has_outputs && (r->target_count || r->has_depth)) {
        // A pipeline that writes nothing, drawn while targets are bound (only its side effects count). Metal
        // needs the pass to match the pipeline, so it gets an attachment-less pass of the targets' size.
        if (!r->outputless_open || r->outputless_samples != p->sample_count) {
            const View *v = r->target_count && r->colors[0].resource ? &r->colors[0] : &r->depth;
            id<MTLTexture> t = v->resource ? v->resource->texture : nil;
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.renderTargetWidth = t ? MAX(t.width >> v->mip, 1ul) : NO_ATTACHMENT_SIZE;
            pass.renderTargetHeight = t ? MAX(t.height >> v->mip, 1ul) : NO_ATTACHMENT_SIZE;
            pass.defaultRasterSampleCount = p->sample_count;
            flush_clears(r);
            open_render(r, pass);
            r->outputless_open = true;
            r->outputless_samples = p->sample_count;
        }
    } else if (!ensure_render(r)) {
        D3D_TODO("draw without render targets is skipped");
        return false;
    }
    apply_render_state(r);
    if (r->colors[0].resource && r->colors[0].resource->is_backbuffer) g_stats.backbuffer_draws++;
    return true;
}

static bool index_binding(Replay *r, MTLIndexType *type, id<MTLBuffer> *buffer, uint64_t *offset) {
    const D3D12_INDEX_BUFFER_VIEW *v = &r->index_buffer;
    if (!v->BufferLocation || !buffer_for_address(v->BufferLocation, buffer, offset)) return false;
    *type = v->Format == DXGI_FORMAT_R16_UINT ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
    return true;
}

// ---------------------------------------------------------------- commands
static void set_root_address(Replay *r, const Command *c) {
    RootState *root = c->compute ? &r->compute_root : &r->graphics_root;
    RootSignature *rs = root->signature;
    if (!rs || c->root_address.index >= rs->parameter_count) return;
    const RootParameter *p = &rs->parameters[c->root_address.index];
    if (p->offset + sizeof(uint64_t) > ROOT_ARGUMENTS_MAX) return;
    memcpy(root->arguments + p->offset, &c->root_address.value, sizeof(uint64_t));
    if (c->compute)
        r->compute_dirty |= DIRTY_ROOT;
    else
        r->dirty |= DIRTY_ROOT;
}

static void set_root_constants(Replay *r, const Command *c) {
    RootState *root = c->compute ? &r->compute_root : &r->graphics_root;
    RootSignature *rs = root->signature;
    if (!rs || c->root_constants.index >= rs->parameter_count) return;
    const RootParameter *p = &rs->parameters[c->root_constants.index];
    uint32_t offset = p->offset + c->root_constants.dest_offset * sizeof(uint32_t);
    uint32_t size = c->root_constants.count * sizeof(uint32_t);
    if (offset + size > ROOT_ARGUMENTS_MAX) return;
    memcpy(root->arguments + offset, c->root_constants.values, size);
    if (c->compute)
        r->compute_dirty |= DIRTY_ROOT;
    else
        r->dirty |= DIRTY_ROOT;
}

static void set_root_signature(Replay *r, const Command *c) {
    RootState *root = c->compute ? &r->compute_root : &r->graphics_root;
    root->signature = c->root_signature;
    if (!root->signature) return;
    // Static samplers are a descriptor table the root signature provides.
    if (root->signature->static_sampler_offset >= 0 && root->signature->static_sampler_table) {
        uint64_t address = root->signature->static_sampler_table.gpuAddress;
        memcpy(root->arguments + root->signature->static_sampler_offset, &address, sizeof address);
    }
    if (c->compute)
        r->compute_dirty |= DIRTY_ROOT;
    else
        r->dirty |= DIRTY_ROOT;
}

static void set_targets(Replay *r, const Command *c) {
    bool same = r->target_count == c->targets.count && r->has_depth == c->targets.has_depth &&
                (!c->targets.has_depth || view_equal(&r->depth, &c->targets.depth));
    for (uint32_t i = 0; same && i < c->targets.count; i++) same = view_equal(&r->colors[i], &c->targets.colors[i]);
    if (same) return;
    end_encoder(r);
    r->target_count = c->targets.count;
    memcpy(r->colors, c->targets.colors, sizeof r->colors);
    r->has_depth = c->targets.has_depth;
    r->depth = c->targets.depth;
}

static void do_draw(Replay *r, const Command *c) {
    if (!prepare_draw(r)) return;
    MTLPrimitiveType primitive = primitive_type(r->topology);
    if (c->type == CMD_DRAW) {
        binding_draw(r->render, primitive, c->draw.start_vertex, c->draw.vertex_count, c->draw.instance_count,
                     c->draw.start_instance);
        return;
    }
    MTLIndexType type;
    id<MTLBuffer> buffer;
    uint64_t offset;
    if (!index_binding(r, &type, &buffer, &offset)) {
        D3D_TODO("indexed draw without an index buffer is skipped");
        return;
    }
    offset += (uint64_t)c->draw_indexed.start_index * (type == MTLIndexTypeUInt16 ? 2 : 4);
    binding_draw_indexed(r->render, primitive, c->draw_indexed.index_count, type, buffer, offset,
                         c->draw_indexed.instance_count, c->draw_indexed.base_vertex, c->draw_indexed.start_instance);
}

static void do_dispatch(Replay *r, const Command *c) {
    PipelineState *p = r->compute_pipeline;
    if (!p || !p->compute || !p->valid) {
        D3D_TODO("dispatch without a usable compute pipeline is skipped");
        return;
    }
    flush_clears(r);
    g_stats.dispatches++;
    if (r->profile && r->kind == ENCODER_COMPUTE && r->pass_pipeline != p) end_encoder(r); // one label per shader
    r->pass_pipeline = p;
    r->pass_count++;
    id<MTLComputeCommandEncoder> e = compute_encoder(r);
    unsigned dirty = r->compute_dirty;
    r->compute_dirty = 0;
    if (dirty & DIRTY_PIPELINE) [e setComputePipelineState:p->compute_state];
    if (dirty & DIRTY_HEAPS) bind_heaps(r, nil, e);
    uint32_t size = r->compute_root.signature ? r->compute_root.signature->argument_buffer_size : 0;
    if ((dirty & DIRTY_ROOT) && size) [e setBytes:r->compute_root.arguments length:size atIndex:BIND_TOP_LEVEL];
    [e dispatchThreadgroups:MTLSizeMake(c->dispatch.x, c->dispatch.y, c->dispatch.z)
        threadsPerThreadgroup:p->threads_per_group];
}

// Signatures that are a single plain draw or dispatch map straight onto Metal's indirect commands, whose
// argument structures match D3D12's. Signatures that change root arguments per command are not supported.
static void do_execute_indirect(Replay *r, const Command *c) {
    const CommandSignature *s = c->indirect.signature;
    if (!s || !c->indirect.arguments) return;
    D3D12_INDIRECT_ARGUMENT_TYPE action = s->arguments[s->argument_count - 1].Type;
    bool dispatch = action == D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH;
    if (s->argument_count != 1 || (!dispatch && action != D3D12_INDIRECT_ARGUMENT_TYPE_DRAW &&
                                   action != D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED)) {
        D3D_TODO("ExecuteIndirect with %u arguments (last type %d) is skipped", s->argument_count, (int)action);
        return;
    }
    if (c->indirect.count_buffer) D3D_TODO("ExecuteIndirect count buffer is ignored, max_count commands are issued");
    g_stats.indirect++;

    if (dispatch) {
        PipelineState *p = r->compute_pipeline;
        if (!p || !p->compute || !p->valid) return;
        flush_clears(r);
        id<MTLComputeCommandEncoder> e = compute_encoder(r);
        unsigned dirty = r->compute_dirty;
        r->compute_dirty = 0;
        if (dirty & DIRTY_PIPELINE) [e setComputePipelineState:p->compute_state];
        if (dirty & DIRTY_HEAPS) bind_heaps(r, nil, e);
        uint32_t size = r->compute_root.signature ? r->compute_root.signature->argument_buffer_size : 0;
        if ((dirty & DIRTY_ROOT) && size) [e setBytes:r->compute_root.arguments length:size atIndex:BIND_TOP_LEVEL];
        for (UINT i = 0; i < c->indirect.max_count; i++)
            [e dispatchThreadgroupsWithIndirectBuffer:c->indirect.arguments->buffer
                                 indirectBufferOffset:c->indirect.arguments_offset + (uint64_t)i * s->byte_stride
                                threadsPerThreadgroup:p->threads_per_group];
        return;
    }

    if (!prepare_draw(r)) return;
    MTLPrimitiveType primitive = primitive_type(r->topology);
    id<MTLBuffer> index_buffer = nil;
    uint64_t index_offset = 0;
    MTLIndexType type = MTLIndexTypeUInt32;
    if (action == D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED && !index_binding(r, &type, &index_buffer, &index_offset))
        return;
    for (UINT i = 0; i < c->indirect.max_count; i++) {
        uint64_t offset = c->indirect.arguments_offset + (uint64_t)i * s->byte_stride;
        if (action == D3D12_INDIRECT_ARGUMENT_TYPE_DRAW)
            binding_draw_indirect(r->render, primitive, c->indirect.arguments->buffer, offset);
        else
            binding_draw_indexed_indirect(r->render, primitive, type, index_buffer, index_offset,
                                          c->indirect.arguments->buffer, offset);
    }
}

static void subresource_position(Resource *res, UINT subresource, NSUInteger *level, NSUInteger *slice) {
    UINT mips = res->desc.MipLevels ? res->desc.MipLevels : 1;
    *level = subresource % mips;
    *slice = subresource / mips;
}

static void do_copy_texture(Replay *r, const Command *c) {
    id<MTLBlitCommandEncoder> blit = blit_encoder(r);
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
                     sourceSize:MTLSizeMake(
                                    MIN((NSUInteger)f->Width, MAX(dst_r->texture.width >> level, 1ul) - origin.x),
                                    MIN((NSUInteger)f->Height, MAX(dst_r->texture.height >> level, 1ul) - origin.y),
                                    MIN((NSUInteger)f->Depth, MAX(dst_r->texture.depth >> level, 1ul) - origin.z))
                      toTexture:dst_r->texture
               destinationSlice:slice
               destinationLevel:level
              destinationOrigin:origin];
    } else if (src->Type == D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX &&
               dst->Type == D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT) {
        const D3D12_SUBRESOURCE_FOOTPRINT *f = &dst->PlacedFootprint.Footprint;
        NSUInteger level, slice;
        subresource_position(src_r, src->SubresourceIndex, &level, &slice);
        UINT block;
        format_bytes_per_block(f->Format, &block);
        UINT rows = (f->Height + block - 1) / block;
        [blit copyFromTexture:src_r->texture
                         sourceSlice:slice
                         sourceLevel:level
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(f->Width, f->Height, f->Depth)
                            toBuffer:dst_r->buffer
                   destinationOffset:dst->PlacedFootprint.Offset
              destinationBytesPerRow:f->RowPitch
            destinationBytesPerImage:(NSUInteger)f->RowPitch * rows];
    } else { // texture to texture
        NSUInteger src_level, src_slice, dst_level, dst_slice;
        subresource_position(src_r, src->SubresourceIndex, &src_level, &src_slice);
        subresource_position(dst_r, dst->SubresourceIndex, &dst_level, &dst_slice);
        const D3D12_BOX *b = &c->copy_texture.box;
        bool box = c->copy_texture.has_box;
        MTLOrigin src_origin = box ? MTLOriginMake(b->left, b->top, b->front) : MTLOriginMake(0, 0, 0);
        MTLSize size =
            box ? MTLSizeMake(b->right - b->left, b->bottom - b->top, b->back - b->front)
                : MTLSizeMake(MAX(src_r->texture.width >> src_level, 1ul), MAX(src_r->texture.height >> src_level, 1ul),
                              MAX(src_r->texture.depth >> src_level, 1ul));
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

static void do_copy_resource(Replay *r, const Command *c) {
    id<MTLBlitCommandEncoder> blit = blit_encoder(r);
    Resource *src = c->copy_resource.src, *dst = c->copy_resource.dst;
    if (src->buffer && dst->buffer)
        [blit copyFromBuffer:src->buffer
                 sourceOffset:0
                     toBuffer:dst->buffer
            destinationOffset:0
                         size:src->buffer.length];
    else if (src->texture && dst->texture)
        [blit copyFromTexture:src->texture toTexture:dst->texture];
}

static void do_resolve(Replay *r, const Command *c) {
    Resource *src = c->resolve.src, *dst = c->resolve.dst;
    if (!src->texture || !dst->texture) return;
    NSUInteger src_level, src_slice, dst_level, dst_slice;
    subresource_position(src, c->resolve.src_subresource, &src_level, &src_slice);
    subresource_position(dst, c->resolve.dst_subresource, &dst_level, &dst_slice);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassColorAttachmentDescriptor *a = pass.colorAttachments[0];
    a.texture = src->texture;
    a.level = src_level;
    a.slice = src->texture.arrayLength > 1 ? src_slice : 0;
    a.resolveTexture = dst->texture;
    a.resolveLevel = dst_level;
    a.resolveSlice = dst->texture.arrayLength > 1 ? dst_slice : 0;
    a.loadAction = MTLLoadActionLoad;
    a.storeAction = MTLStoreActionMultisampleResolve;
    open_render(r, pass);
    end_encoder(r);
}

static void replay_commands(Replay *r, const CommandList *list);

static void replay_command(Replay *r, const Command *c) {
    switch (c->type) {
    case CMD_SET_PIPELINE:
        if (c->pipeline && c->pipeline->compute) {
            r->compute_pipeline = c->pipeline;
            r->compute_dirty |= DIRTY_PIPELINE;
        } else {
            r->graphics_pipeline = c->pipeline;
            r->dirty |= DIRTY_PIPELINE;
        }
        break;
    case CMD_SET_ROOT_SIGNATURE: set_root_signature(r, c); break;
    case CMD_ROOT_ADDRESS: set_root_address(r, c); break;
    case CMD_ROOT_CONSTANTS: set_root_constants(r, c); break;
    case CMD_SET_HEAPS:
        memset(r->heaps, 0, sizeof r->heaps);
        for (uint32_t i = 0; i < c->heaps.count; i++) r->heaps[i] = c->heaps.heaps[i];
        r->dirty |= DIRTY_HEAPS;
        r->compute_dirty |= DIRTY_HEAPS;
        break;
    case CMD_TOPOLOGY: r->topology = c->topology; break;
    case CMD_VERTEX_BUFFERS:
        for (uint32_t i = 0; i < c->vertex_buffers.count; i++)
            r->vertex_buffers[c->vertex_buffers.start + i] = c->vertex_buffers.views[i];
        r->dirty |= DIRTY_VERTEX_BUFFERS;
        break;
    case CMD_INDEX_BUFFER: r->index_buffer = c->index_buffer; break;
    case CMD_VIEWPORTS:
        r->viewport_count = c->viewports.count;
        memcpy(r->viewports, c->viewports.viewports, sizeof r->viewports);
        r->dirty |= DIRTY_VIEWPORTS;
        break;
    case CMD_SCISSORS:
        r->scissor_count = c->scissors.count;
        memcpy(r->scissors, c->scissors.rects, sizeof r->scissors);
        r->dirty |= DIRTY_SCISSORS;
        break;
    case CMD_BLEND_FACTOR:
        memcpy(r->blend_factor, c->blend_factor, sizeof r->blend_factor);
        r->dirty |= DIRTY_BLEND_FACTOR;
        break;
    case CMD_STENCIL_REF:
        r->stencil_ref = c->stencil_ref;
        r->dirty |= DIRTY_STENCIL_REF;
        break;
    case CMD_RENDER_TARGETS: set_targets(r, c); break;
    case CMD_CLEAR_COLOR:
        if (c->clear_color.view.resource) {
            PendingClear clear = {.depth = false, .view = c->clear_color.view};
            memcpy(clear.color, c->clear_color.color, sizeof clear.color);
            add_pending(r, &clear);
        }
        break;
    case CMD_CLEAR_DEPTH:
        if (c->clear_depth.view.resource) {
            PendingClear clear = {.depth = true,
                                  .view = c->clear_depth.view,
                                  .flags = c->clear_depth.flags,
                                  .depth_value = c->clear_depth.depth,
                                  .stencil_value = c->clear_depth.stencil};
            add_pending(r, &clear);
        }
        break;
    case CMD_DRAW:
    case CMD_DRAW_INDEXED: do_draw(r, c); break;
    case CMD_DISPATCH: do_dispatch(r, c); break;
    case CMD_COPY_BUFFER:
        flush_clears(r);
        [blit_encoder(r) copyFromBuffer:c->copy_buffer.src->buffer
                           sourceOffset:c->copy_buffer.src_offset
                               toBuffer:c->copy_buffer.dst->buffer
                      destinationOffset:c->copy_buffer.dst_offset
                                   size:c->copy_buffer.size];
        break;
    case CMD_COPY_TEXTURE:
        flush_clears(r);
        do_copy_texture(r, c);
        break;
    case CMD_COPY_RESOURCE:
        flush_clears(r);
        do_copy_resource(r, c);
        break;
    case CMD_RESOLVE:
        flush_clears(r);
        do_resolve(r, c);
        break;
    case CMD_EXECUTE_INDIRECT: do_execute_indirect(r, c); break;
    case CMD_EXECUTE_BUNDLE:
        if (c->bundle) replay_commands(r, c->bundle);
        break;
    }
}

static void replay_commands(Replay *r, const CommandList *list) {
    for (size_t i = 0; i < list->count; i++) replay_command(r, &list->commands[i]);
}

void command_list_execute(CommandList *list, CommandQueue *queue, id<MTLCommandBuffer> cb) {
    Replay *r = calloc(1, sizeof *r);
    r->queue = queue;
    r->cb = cb;
    r->profile = profile_for(cb);
    r->pass_slot = -1;
    r->topology = D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
    replay_commands(r, list);
    flush_clears(r);
    end_encoder(r);
    free(r);
    if (++g_stats.lists % 60 == 0)
        D3D_LOG("replay: %u lists, %u passes, %u draws (%u to the back buffer), %u skipped, %u dispatches",
                g_stats.lists, g_stats.passes, g_stats.draws, g_stats.backbuffer_draws, g_stats.skipped,
                g_stats.dispatches);
}

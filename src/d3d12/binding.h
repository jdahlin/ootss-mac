// Thin wrappers around Apple's Metal Shader Converter runtime header (metal_irconverter_runtime.h),
// which must be compiled with ARC. Everything else in the backend uses these.
#pragma once
#import <Metal/Metal.h>

// A descriptor as shaders read it from a descriptor table (IRDescriptorTableEntry).
typedef struct DescriptorEntry {
    uint64_t gpu_address;     // buffers: GPU address; samplers: sampler resource ID
    uint64_t texture_view_id; // textures: resource ID
    uint64_t metadata;        // buffers: size and flags; textures: min LOD clamp; samplers: LOD bias
} DescriptorEntry;

void binding_set_buffer(DescriptorEntry *entry, uint64_t gpu_address, uint32_t size_in_bytes);
void binding_set_texture(DescriptorEntry *entry, id<MTLTexture> texture, float min_lod_clamp);
void binding_set_sampler(DescriptorEntry *entry, id<MTLSamplerState> sampler, float lod_bias);

// Draws that also bind the draw-parameters buffer the converted vertex shaders read (SV_VertexID bases).
void binding_draw(id<MTLRenderCommandEncoder> encoder, MTLPrimitiveType primitive, uint64_t vertex_start,
                  uint64_t vertex_count, uint64_t instance_count, uint64_t base_instance);
void binding_draw_indexed(id<MTLRenderCommandEncoder> encoder, MTLPrimitiveType primitive, uint64_t index_count,
                          MTLIndexType index_type, id<MTLBuffer> index_buffer, uint64_t index_buffer_offset,
                          uint64_t instance_count, int64_t base_vertex, uint64_t base_instance);
void binding_draw_indirect(id<MTLRenderCommandEncoder> encoder, MTLPrimitiveType primitive, id<MTLBuffer> indirect,
                           uint64_t indirect_offset);
void binding_draw_indexed_indirect(id<MTLRenderCommandEncoder> encoder, MTLPrimitiveType primitive,
                                   MTLIndexType index_type, id<MTLBuffer> index_buffer, uint64_t index_buffer_offset,
                                   id<MTLBuffer> indirect, uint64_t indirect_offset);

// Binding indices shared by all converted shaders (kIR* constants).
enum {
    BIND_DESCRIPTOR_HEAP = 0,
    BIND_SAMPLER_HEAP = 1,
    BIND_TOP_LEVEL = 2,
    BIND_DRAW_ARGUMENTS = 4,
    BIND_VERTEX_BUFFERS = 6,
    BIND_FIRST_STAGE_IN_ATTRIBUTE = 11,
};

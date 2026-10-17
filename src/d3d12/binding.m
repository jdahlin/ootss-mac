// Compiled with ARC (see the Makefile): Apple's runtime header requires it.
#import <Metal/Metal.h>
#define IR_PRIVATE_IMPLEMENTATION
#include <metal_irconverter_runtime/metal_irconverter_runtime.h>
#include "binding.h"

_Static_assert(sizeof(IRDescriptorTableEntry) == sizeof(DescriptorEntry), "descriptor entry layout");
_Static_assert(BIND_TOP_LEVEL == 2 && BIND_DRAW_ARGUMENTS == 4 && BIND_VERTEX_BUFFERS == 6 &&
                   BIND_FIRST_STAGE_IN_ATTRIBUTE == 11,
               "bind points must match the converter's");

void binding_set_buffer(DescriptorEntry *entry, uint64_t gpu_address, uint32_t size_in_bytes) {
    IRDescriptorTableSetBuffer((IRDescriptorTableEntry *)entry, gpu_address, size_in_bytes);
}

void binding_set_texture(DescriptorEntry *entry, id<MTLTexture> texture, float min_lod_clamp) {
    IRDescriptorTableSetTexture((IRDescriptorTableEntry *)entry, texture, min_lod_clamp, 0);
}

void binding_set_sampler(DescriptorEntry *entry, id<MTLSamplerState> sampler, float lod_bias) {
    IRDescriptorTableSetSampler((IRDescriptorTableEntry *)entry, sampler, lod_bias);
}

void binding_draw(id<MTLRenderCommandEncoder> encoder, MTLPrimitiveType primitive, uint64_t vertex_start,
                  uint64_t vertex_count, uint64_t instance_count, uint64_t base_instance) {
    IRRuntimeDrawPrimitives(encoder, primitive, vertex_start, vertex_count, instance_count, base_instance);
}

void binding_draw_indexed(id<MTLRenderCommandEncoder> encoder, MTLPrimitiveType primitive, uint64_t index_count,
                          MTLIndexType index_type, id<MTLBuffer> index_buffer, uint64_t index_buffer_offset,
                          uint64_t instance_count, int64_t base_vertex, uint64_t base_instance) {
    IRRuntimeDrawIndexedPrimitives(encoder, primitive, index_count, index_type, index_buffer, index_buffer_offset,
                                   instance_count, base_vertex, base_instance);
}

// The runtime's indirect draws bind the draw arguments but not the draw info (index type) the converted vertex
// shaders also read; the direct draws set both.
static void set_draw_info(id<MTLRenderCommandEncoder> encoder, MTLPrimitiveType primitive, uint16_t index_type) {
    IRRuntimeDrawInfo info = {.indexType = index_type, .primitiveTopology = (uint8_t)primitive};
    [encoder setVertexBytes:&info length:sizeof info atIndex:kIRArgumentBufferUniformsBindPoint];
}

void binding_draw_indirect(id<MTLRenderCommandEncoder> encoder, MTLPrimitiveType primitive, id<MTLBuffer> indirect,
                           uint64_t indirect_offset) {
    set_draw_info(encoder, primitive, 0);
    IRRuntimeDrawPrimitives(encoder, primitive, indirect, indirect_offset);
}

void binding_draw_indexed_indirect(id<MTLRenderCommandEncoder> encoder, MTLPrimitiveType primitive,
                                   MTLIndexType index_type, id<MTLBuffer> index_buffer, uint64_t index_buffer_offset,
                                   id<MTLBuffer> indirect, uint64_t indirect_offset) {
    set_draw_info(encoder, primitive, (uint16_t)(index_type + 1)); // as the direct indexed draw encodes it
    IRRuntimeDrawIndexedPrimitives(encoder, primitive, index_type, index_buffer, index_buffer_offset, indirect,
                                   indirect_offset);
}

// The backend's D3D12 objects and how they map to Metal.
//
// Resources: buffers are MTLBuffers (shared storage; the GPU address is Metal's), textures are MTLTextures
// created as arrays (the converted shaders require array texture types).
// Descriptors: heaps hold Metal-format descriptor entries in a GPU-readable buffer, so shaders read
// descriptor tables directly. CPU descriptor handles are pseudo handles (heap id and index).
// Residency: every allocation joins one residency set attached to the queue; nothing is tracked per draw.
#pragma once
#include "common.h"
#include "binding.h"
#include "converter.h"

// ---------------------------------------------------------------- resources
typedef struct TextureView {
    uint64_t key;
    id<MTLTexture> texture;
} TextureView;

typedef struct Resource {
    Object object;
    D3D12_RESOURCE_DESC desc;
    D3D12_HEAP_TYPE heap_type;
    id<MTLBuffer> buffer;
    id<MTLTexture> texture;
    MTLPixelFormat pixel_format;
    bool is_backbuffer; // a swapchain buffer
    pthread_mutex_t views_lock;
    TextureView *views; // cache of views of `texture`, keyed by format, type and subresource range
    int view_count, view_capacity;
} Resource;

HRESULT resource_create(Device *device, const D3D12_HEAP_PROPERTIES *heap, const D3D12_RESOURCE_DESC *desc, REFIID iid,
                        void **out);
Resource *resource_from_texture(Device *device, id<MTLTexture> texture, DXGI_FORMAT format); // swapchain buffers

// A view of a texture resource, cached. `type` follows the array rules of the converted shaders.
id<MTLTexture> resource_view(Resource *r, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices);

// Buffers are found by GPU address when the game passes addresses (vertex, index and constant buffers).
bool buffer_for_address(uint64_t gpu_address, id<MTLBuffer> *buffer, uint64_t *offset);

// Residency: all allocations stay resident; the set is attached to every queue.
void residency_add(id<MTLAllocation> allocation);
void residency_attach(Device *device, id<MTLCommandQueue> queue);
void residency_commit(void); // call before submitting work that may use new allocations

typedef struct Heap {
    Object object;
    D3D12_HEAP_DESC desc;
} Heap;

// ---------------------------------------------------------------- descriptors
typedef enum { VIEW_NONE, VIEW_CBV, VIEW_SRV, VIEW_UAV, VIEW_RTV, VIEW_DSV, VIEW_SAMPLER } ViewKind;

// What the command list needs to know about a view beyond its Metal-format entry (render targets and
// depth targets are bound by the CPU, not read by shaders).
typedef struct View {
    Resource *resource;
    uint8_t kind;
    uint8_t dimension; // D3D12_RTV_DIMENSION / D3D12_DSV_DIMENSION
    uint16_t mip, first_slice, slice_count;
    uint32_t format; // DXGI_FORMAT of the view
} View;

#define DESCRIPTOR_STRIDE sizeof(DescriptorEntry)

typedef struct DescriptorHeap {
    Object object;
    D3D12_DESCRIPTOR_HEAP_DESC desc;
    uint32_t id;
    id<MTLBuffer> table; // desc.NumDescriptors entries, read by shaders
    View *views;         // parallel to the table
} DescriptorHeap;

// CPU handle -> heap and index, or NULL.
DescriptorHeap *descriptor_heap_for_handle(D3D12_CPU_DESCRIPTOR_HANDLE handle, uint32_t *index);
const View *descriptor_view(D3D12_CPU_DESCRIPTOR_HANDLE handle);
void descriptors_copy(D3D12_CPU_DESCRIPTOR_HANDLE dst, D3D12_CPU_DESCRIPTOR_HANDLE src, UINT count);

void descriptor_create_cbv(Device *device, const D3D12_CONSTANT_BUFFER_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE h);
void descriptor_create_srv(Device *device, Resource *r, const D3D12_SHADER_RESOURCE_VIEW_DESC *desc,
                           D3D12_CPU_DESCRIPTOR_HANDLE h);
void descriptor_create_uav(Device *device, Resource *r, const D3D12_UNORDERED_ACCESS_VIEW_DESC *desc,
                           D3D12_CPU_DESCRIPTOR_HANDLE h);
void descriptor_create_rtv(Device *device, Resource *r, const D3D12_RENDER_TARGET_VIEW_DESC *desc,
                           D3D12_CPU_DESCRIPTOR_HANDLE h);
void descriptor_create_dsv(Device *device, Resource *r, const D3D12_DEPTH_STENCIL_VIEW_DESC *desc,
                           D3D12_CPU_DESCRIPTOR_HANDLE h);
void descriptor_create_sampler(Device *device, const D3D12_SAMPLER_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE h);

MTLCompareFunction compare_function(D3D12_COMPARISON_FUNC f);

// A sampler state usable from argument buffers (also used for root signatures' static samplers).
id<MTLSamplerState> sampler_state(Device *device, const D3D12_SAMPLER_DESC *desc);

// ---------------------------------------------------------------- root signatures
// Where each root parameter lives in the top-level argument buffer the converted shaders read.
#define MAX_ROOT_PARAMETERS 32
typedef struct RootParameter {
    D3D12_ROOT_PARAMETER_TYPE type;
    uint32_t offset; // bytes into the top-level argument buffer
    uint32_t size;   // bytes: 4 * Num32BitValues for constants, 8 for tables and root descriptors
} RootParameter;

typedef struct RootSignature {
    Object object;
    uint32_t parameter_count;
    RootParameter parameters[MAX_ROOT_PARAMETERS];
    uint32_t argument_buffer_size;
    // Static samplers become a descriptor table of samplers that we provide.
    id<MTLBuffer> static_sampler_table;
    int32_t static_sampler_offset; // into the argument buffer, or -1
    IRRootSignature *ir;           // shaders are converted against this, so their layout matches the offsets above
    uint64_t key;                  // identifies the signature in the shader cache
} RootSignature;

HRESULT root_signature_create(Device *device, const void *blob, size_t size, REFIID iid, void **out);

// ---------------------------------------------------------------- pipelines
typedef struct ShaderInfo { // reflection saved next to the converted library
    uint32_t input_count;
    struct {
        char name[60]; // lower-case semantic and index, e.g. "texcoord1"
        uint32_t attribute;
    } inputs[16];
    uint32_t threads_per_group[3]; // compute shaders
} ShaderInfo;

typedef struct PipelineState {
    Object object;
    bool compute;
    id<MTLRenderPipelineState> render;
    id<MTLComputePipelineState> compute_state;
    id<MTLDepthStencilState> depth_stencil;
    MTLSize threads_per_group;
    MTLCullMode cull_mode;
    bool front_counter_clockwise;
    MTLTriangleFillMode fill_mode;
    MTLDepthClipMode depth_clip;
    float depth_bias, slope_scaled_depth_bias, depth_bias_clamp;
    UINT sample_count;
    D3D12_PRIMITIVE_TOPOLOGY_TYPE topology_type;
    bool valid;
} PipelineState;

// Converts DXIL to a Metal library through Apple's Metal Shader Converter (see shader.m).
id<MTLLibrary> shader_library_create(id<MTLDevice> device, const D3D12_SHADER_BYTECODE *code,
                                     const struct RootSignature *root, NSString **function, ShaderInfo *info);

HRESULT graphics_pipeline_create(Device *device, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, REFIID iid,
                                 void **out);
HRESULT compute_pipeline_create(Device *device, const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc, REFIID iid, void **out);

typedef struct CommandSignature {
    Object object;
    UINT byte_stride;
    UINT argument_count;
    D3D12_INDIRECT_ARGUMENT_DESC arguments[8];
} CommandSignature;

// ---------------------------------------------------------------- command lists
typedef struct CommandList CommandList;

typedef struct CommandAllocator {
    Object object;
} CommandAllocator;

HRESULT command_list_create(Device *device, D3D12_COMMAND_LIST_TYPE type, REFIID iid, void **out);

// ---------------------------------------------------------------- queue and fences
typedef struct Fence {
    Object object;
    id<MTLSharedEvent> event;
    MTLSharedEventListener *listener;
} Fence;

typedef struct CommandQueue {
    Object object;
    D3D12_COMMAND_QUEUE_DESC desc;
    id<MTLCommandQueue> mtl;
    id<MTLFence> fence; // orders encoders: every encoder waits for the previous one
    bool fence_used;
} CommandQueue;

// Replays a recorded list into a Metal command buffer on the queue.
void command_list_execute(CommandList *list, CommandQueue *queue, id<MTLCommandBuffer> cb);

HRESULT fence_create(Device *device, UINT64 initial, REFIID iid, void **out);
HRESULT command_queue_create(Device *device, const D3D12_COMMAND_QUEUE_DESC *desc, REFIID iid, void **out);
HRESULT command_allocator_create(Device *device, REFIID iid, void **out);
HRESULT descriptor_heap_create(Device *device, const D3D12_DESCRIPTOR_HEAP_DESC *desc, REFIID iid, void **out);
HRESULT heap_create(Device *device, const D3D12_HEAP_DESC *desc, REFIID iid, void **out);
HRESULT command_signature_create(Device *device, const D3D12_COMMAND_SIGNATURE_DESC *desc, REFIID iid, void **out);

// GetCopyableFootprints, shared with CopyTextureRegion.
UINT64 copyable_footprints(const D3D12_RESOURCE_DESC *desc, UINT first, UINT count, UINT64 base,
                           D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts, UINT *rows, UINT64 *row_sizes);

HRESULT d3d12_create_device(void *adapter, REFIID iid, void **out);
HRESULT dxgi_create_factory(UINT flags, REFIID iid, void **out);
void d3d12_backend_register(void); // registers the DXGI/D3D12 entry points with the loader

// The backend's D3D12 objects and how they map to Metal.
#pragma once
#include "common.h"

// ---- resources: buffers are MTLBuffers (shared storage, so Map works and gpuAddress is the GPU VA);
// textures are MTLTextures. Placed resources get their own allocation (heap aliasing is not modelled).
typedef struct Resource {
    Object object;
    D3D12_RESOURCE_DESC desc;
    D3D12_HEAP_TYPE heap_type;
    id<MTLBuffer> buffer;
    id<MTLTexture> texture;
} Resource;

HRESULT resource_create(Device *device, const D3D12_HEAP_PROPERTIES *heap, const D3D12_RESOURCE_DESC *desc, REFIID iid,
                        void **out);
Resource *resource_from_texture(Device *device, id<MTLTexture> texture, DXGI_FORMAT format); // swapchain buffers

typedef struct Heap {
    Object object;
    D3D12_HEAP_DESC desc;
} Heap;

// ---- descriptors: a CPU descriptor handle points at one of these, inside a descriptor heap.
typedef enum {
    DESCRIPTOR_NONE,
    DESCRIPTOR_CBV,
    DESCRIPTOR_SRV,
    DESCRIPTOR_UAV,
    DESCRIPTOR_RTV,
    DESCRIPTOR_DSV,
    DESCRIPTOR_SAMPLER
} DescriptorKind;

typedef struct Descriptor {
    DescriptorKind kind;
    Resource *resource; // not retained; the game keeps resources alive while views exist
    union {
        D3D12_CONSTANT_BUFFER_VIEW_DESC cbv;
        D3D12_SHADER_RESOURCE_VIEW_DESC srv;
        D3D12_UNORDERED_ACCESS_VIEW_DESC uav;
        D3D12_RENDER_TARGET_VIEW_DESC rtv;
        D3D12_DEPTH_STENCIL_VIEW_DESC dsv;
        D3D12_SAMPLER_DESC sampler;
    };
    bool has_view_desc;
} Descriptor;

#define DESCRIPTOR_SIZE ((sizeof(Descriptor) + 15) & ~(size_t)15) // GetDescriptorHandleIncrementSize

typedef struct DescriptorHeap {
    Object object;
    D3D12_DESCRIPTOR_HEAP_DESC desc;
    uint8_t *descriptors; // desc.NumDescriptors * DESCRIPTOR_SIZE
    uint64_t gpu_base;    // GPU handles are gpu_base + index * DESCRIPTOR_SIZE
} DescriptorHeap;

static inline Descriptor *descriptor_at(D3D12_CPU_DESCRIPTOR_HANDLE handle) { return (Descriptor *)handle.ptr; }

// ---- pipelines (shaders are not translated yet)
typedef struct RootSignature {
    Object object;
    void *blob;
    size_t blob_size;
} RootSignature;

// A pipeline keeps the converted Metal library of each shader stage it was created from.
#define MAX_PIPELINE_STAGES 5 // vertex, pixel, domain, hull, geometry (compute uses one)
typedef struct PipelineState {
    Object object;
    bool compute;
    int stage_count;
    id<MTLLibrary> libraries[MAX_PIPELINE_STAGES];
    NSString *functions[MAX_PIPELINE_STAGES];
} PipelineState;

// Converts DXIL to a Metal library through Apple's Metal Shader Converter (see shader.m).
id<MTLLibrary> shader_library_create(id<MTLDevice> device, const D3D12_SHADER_BYTECODE *code, NSString **function);

typedef struct CommandSignature {
    Object object;
    D3D12_COMMAND_SIGNATURE_DESC desc;
} CommandSignature;

// ---- command lists record commands; ExecuteCommandLists replays them into a Metal command buffer.
typedef enum { CMD_CLEAR_RTV, CMD_COPY_BUFFER, CMD_COPY_TEXTURE, CMD_COPY_RESOURCE } CommandType;

typedef struct Command {
    CommandType type;
    union {
        struct {
            Descriptor rtv;
            float color[4];
        } clear_rtv;
        struct {
            Resource *dst, *src;
            UINT64 dst_offset, src_offset, size;
        } copy_buffer;
        struct {
            D3D12_TEXTURE_COPY_LOCATION dst, src;
            UINT x, y, z;
            D3D12_BOX box;
            bool has_box;
        } copy_texture;
        struct {
            Resource *dst, *src;
        } copy_resource;
    };
} Command;

typedef struct CommandList {
    Object object;
    D3D12_COMMAND_LIST_TYPE type;
    Command *commands;
    size_t count, capacity;
} CommandList;

void command_list_execute(CommandList *list, id<MTLCommandBuffer> cb);

typedef struct CommandAllocator {
    Object object;
} CommandAllocator;

// ---- queue and fences
typedef struct Fence {
    Object object;
    id<MTLSharedEvent> event;
    MTLSharedEventListener *listener;
} Fence;

typedef struct CommandQueue {
    Object object;
    D3D12_COMMAND_QUEUE_DESC desc;
    id<MTLCommandQueue> mtl;
} CommandQueue;

HRESULT fence_create(Device *device, UINT64 initial, REFIID iid, void **out);

// ---- object constructors used by the device
HRESULT command_queue_create(Device *device, const D3D12_COMMAND_QUEUE_DESC *desc, REFIID iid, void **out);
HRESULT command_allocator_create(Device *device, REFIID iid, void **out);
HRESULT command_list_create(Device *device, D3D12_COMMAND_LIST_TYPE type, REFIID iid, void **out);
HRESULT descriptor_heap_create(Device *device, const D3D12_DESCRIPTOR_HEAP_DESC *desc, REFIID iid, void **out);
HRESULT heap_create(Device *device, const D3D12_HEAP_DESC *desc, REFIID iid, void **out);
HRESULT root_signature_create(Device *device, const void *blob, size_t size, REFIID iid, void **out);
HRESULT pipeline_state_create(Device *device, bool compute, const D3D12_SHADER_BYTECODE *const *stages, int count,
                              REFIID iid, void **out);
HRESULT command_signature_create(Device *device, const D3D12_COMMAND_SIGNATURE_DESC *desc, REFIID iid, void **out);

// GetCopyableFootprints, shared with CopyTextureRegion.
UINT64 copyable_footprints(const D3D12_RESOURCE_DESC *desc, UINT first, UINT count, UINT64 base,
                           D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts, UINT *rows, UINT64 *row_sizes);

HRESULT d3d12_create_device(void *adapter, REFIID iid, void **out);
HRESULT dxgi_create_factory(UINT flags, REFIID iid, void **out);
void d3d12_backend_register(void); // registers the DXGI/D3D12 entry points with the loader

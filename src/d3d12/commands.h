// Recorded command lists. list.m records D3D12 calls into Command structures; replay.m turns them into
// Metal encoders when the list is executed.
#pragma once
#include "objects.h"

#define MAX_VIEWPORTS            8
#define MAX_VERTEX_SLOTS         8
#define MAX_RENDER_TARGETS       8
#define MAX_ROOT_CONSTANT_VALUES 32
#define MAX_LIST_HEAPS           2 // one CBV/SRV/UAV heap and one sampler heap

typedef enum {
    CMD_SET_PIPELINE,
    CMD_SET_ROOT_SIGNATURE,
    CMD_ROOT_ADDRESS, // a descriptor table (GPU handle) or a root CBV/SRV/UAV (GPU address)
    CMD_ROOT_CONSTANTS,
    CMD_SET_HEAPS,
    CMD_TOPOLOGY,
    CMD_VERTEX_BUFFERS,
    CMD_INDEX_BUFFER,
    CMD_VIEWPORTS,
    CMD_SCISSORS,
    CMD_BLEND_FACTOR,
    CMD_STENCIL_REF,
    CMD_RENDER_TARGETS,
    CMD_CLEAR_COLOR,
    CMD_CLEAR_DEPTH,
    CMD_DRAW,
    CMD_DRAW_INDEXED,
    CMD_DISPATCH,
    CMD_COPY_BUFFER,
    CMD_COPY_TEXTURE,
    CMD_COPY_RESOURCE,
    CMD_RESOLVE,
    CMD_EXECUTE_INDIRECT,
    CMD_EXECUTE_BUNDLE,
} CommandType;

typedef struct Command {
    CommandType type;
    bool compute; // for root arguments: the compute or the graphics root
    union {
        PipelineState *pipeline;
        RootSignature *root_signature;
        struct {
            uint32_t index;
            uint64_t value;
        } root_address;
        struct {
            uint32_t index, dest_offset, count;
            uint32_t values[MAX_ROOT_CONSTANT_VALUES];
        } root_constants;
        struct {
            DescriptorHeap *heaps[MAX_LIST_HEAPS];
            uint32_t count;
        } heaps;
        D3D12_PRIMITIVE_TOPOLOGY topology;
        struct {
            uint32_t start, count;
            D3D12_VERTEX_BUFFER_VIEW views[MAX_VERTEX_SLOTS];
        } vertex_buffers;
        D3D12_INDEX_BUFFER_VIEW index_buffer;
        struct {
            uint32_t count;
            D3D12_VIEWPORT viewports[MAX_VIEWPORTS];
        } viewports;
        struct {
            uint32_t count;
            D3D12_RECT rects[MAX_VIEWPORTS];
        } scissors;
        float blend_factor[4];
        uint32_t stencil_ref;
        struct {
            uint32_t count;
            View colors[MAX_RENDER_TARGETS];
            View depth;
            bool has_depth;
        } targets;
        struct {
            View view;
            float color[4];
        } clear_color;
        struct {
            View view;
            D3D12_CLEAR_FLAGS flags;
            float depth;
            uint8_t stencil;
        } clear_depth;
        struct {
            uint32_t vertex_count, instance_count, start_vertex, start_instance;
        } draw;
        struct {
            uint32_t index_count, instance_count, start_index;
            int32_t base_vertex;
            uint32_t start_instance;
        } draw_indexed;
        struct {
            uint32_t x, y, z;
        } dispatch;
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
        struct {
            Resource *dst, *src;
            UINT dst_subresource, src_subresource;
            DXGI_FORMAT format;
        } resolve;
        struct {
            CommandSignature *signature;
            UINT max_count;
            Resource *arguments, *count_buffer;
            UINT64 arguments_offset, count_offset;
        } indirect;
        struct CommandList *bundle;
    };
} Command;

struct CommandList {
    Object object;
    D3D12_COMMAND_LIST_TYPE type;
    Command *commands;
    size_t count, capacity;
};

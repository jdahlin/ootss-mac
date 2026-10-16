// ID3D12CommandQueue on an MTLCommandQueue, ID3D12Fence on an MTLSharedEvent.
#include "objects.h"
#include <unistd.h>

// ---------------------------------------------------------------- ID3D12Fence
static void fence_destroy(Object *o) {
    Fence *f = (Fence *)o;
    [f->event release];
    [f->listener release];
    free(f);
}

static UINT64 STDMETHODCALLTYPE fence_GetCompletedValue(Fence *f) { return f->event.signaledValue; }

static HRESULT STDMETHODCALLTYPE fence_Signal(Fence *f, UINT64 value) {
    f->event.signaledValue = value; // CPU-side signal
    return S_OK;
}

// The event HANDLE comes from the game's CreateEventW (our kernel32 shim); signal it through SetEvent.
static HRESULT STDMETHODCALLTYPE fence_SetEventOnCompletion(Fence *f, UINT64 value, HANDLE event) {
    if (!event) { // NULL: block until the fence reaches the value
        while (f->event.signaledValue < value) usleep(50);
        return S_OK;
    }
    static WINAPI WINBOOL (*set_event)(HANDLE);
    if (!set_event) set_event = shim_lookup("SetEvent");
    [f->event notifyListener:f->listener atValue:value block:^(id<MTLSharedEvent> e, uint64_t v) { set_event(event); }];
    return S_OK;
}

static ID3D12FenceVtbl fence_vtbl = {
    ID3D12_OBJECT_METHODS,
    .GetDevice = (void *)com_GetDevice,
    .GetCompletedValue = (void *)fence_GetCompletedValue,
    .SetEventOnCompletion = (void *)fence_SetEventOnCompletion,
    .Signal = (void *)fence_Signal,
};
static const IID *const fence_iids[] = {&IID_ID3D12Fence, &IID_ID3D12Pageable, &IID_ID3D12DeviceChild,
                                        &IID_ID3D12Object, NULL};

HRESULT fence_create(Device *device, UINT64 initial, REFIID iid, void **out) {
    static bool vtbl_ready;
    if (!vtbl_ready) {
        FILL_UNIMPLEMENTED(fence_vtbl);
        vtbl_ready = true;
    }
    Fence *f = calloc(1, sizeof *f);
    object_init(&f->object, &fence_vtbl, fence_iids, device);
    f->object.destroy = fence_destroy;
    f->event = [device->mtl newSharedEvent];
    f->event.signaledValue = initial;
    f->listener = [[MTLSharedEventListener alloc] init];
    HRESULT hr = object_query(&f->object, iid, out);
    object_release(&f->object);
    return hr;
}

// ---------------------------------------------------------------- ID3D12CommandQueue
static void queue_destroy(Object *o) {
    [((CommandQueue *)o)->fence release];
    [((CommandQueue *)o)->mtl release];
    free(o);
}

// At most this many command buffers are in flight, so a game that runs ahead cannot queue unbounded GPU work.
#define MAX_COMMAND_BUFFERS_IN_FLIGHT 8

static void commit(id<MTLCommandBuffer> cb) {
    static dispatch_semaphore_t in_flight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ in_flight = dispatch_semaphore_create(MAX_COMMAND_BUFFERS_IN_FLIGHT); });
    dispatch_semaphore_wait(in_flight, DISPATCH_TIME_FOREVER);
    residency_commit();
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
      dispatch_semaphore_signal(in_flight);
      if (done.error) D3D_LOG("command buffer failed: %s", done.error.localizedDescription.UTF8String);
    }];
    [cb commit];
}

static void STDMETHODCALLTYPE queue_ExecuteCommandLists(CommandQueue *q, UINT count, ID3D12CommandList *const *lists) {
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [q->mtl commandBuffer];
        for (UINT i = 0; i < count; i++) command_list_execute((CommandList *)lists[i], q, cb);
        commit(cb);
    }
}

// Signal and Wait are ordered with the work already submitted to this queue.
static HRESULT STDMETHODCALLTYPE queue_Signal(CommandQueue *q, Fence *f, UINT64 value) {
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [q->mtl commandBuffer];
        [cb encodeSignalEvent:f->event value:value];
        [cb commit];
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE queue_Wait(CommandQueue *q, Fence *f, UINT64 value) {
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [q->mtl commandBuffer];
        [cb encodeWaitForEvent:f->event value:value];
        [cb commit];
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE queue_GetTimestampFrequency(CommandQueue *q, UINT64 *frequency) {
    *frequency = 1000000000; // GPU timestamps are reported in nanoseconds
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE queue_GetClockCalibration(CommandQueue *q, UINT64 *gpu, UINT64 *cpu) {
    *gpu = *cpu = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    return S_OK;
}

static D3D12_COMMAND_QUEUE_DESC *STDMETHODCALLTYPE queue_GetDesc(CommandQueue *q, D3D12_COMMAND_QUEUE_DESC *ret) {
    *ret = q->desc;
    return ret;
}

static ID3D12CommandQueueVtbl queue_vtbl = {
    ID3D12_OBJECT_METHODS,
    .GetDevice = (void *)com_GetDevice,
    .ExecuteCommandLists = (void *)queue_ExecuteCommandLists,
    .Signal = (void *)queue_Signal,
    .Wait = (void *)queue_Wait,
    .GetTimestampFrequency = (void *)queue_GetTimestampFrequency,
    .GetClockCalibration = (void *)queue_GetClockCalibration,
    .GetDesc = (void *)queue_GetDesc, // hidden result pointer, see common.h
};
static const IID *const queue_iids[] = {&IID_ID3D12CommandQueue, &IID_ID3D12Pageable, &IID_ID3D12DeviceChild,
                                        &IID_ID3D12Object, NULL};

HRESULT command_queue_create(Device *device, const D3D12_COMMAND_QUEUE_DESC *desc, REFIID iid, void **out) {
    static bool vtbl_ready;
    if (!vtbl_ready) {
        FILL_UNIMPLEMENTED(queue_vtbl);
        vtbl_ready = true;
    }
    CommandQueue *q = calloc(1, sizeof *q);
    object_init(&q->object, &queue_vtbl, queue_iids, device);
    q->object.destroy = queue_destroy;
    q->desc = *desc;
    q->mtl = [device->mtl newCommandQueueWithMaxCommandBufferCount:256];
    q->fence = [device->mtl newFence];
    residency_attach(device, q->mtl);
    HRESULT hr = object_query(&q->object, iid, out);
    object_release(&q->object);
    return hr;
}

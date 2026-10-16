// MMDevice + WASAPI (shared-mode rendering) on CoreAudio, enough for the game's statically linked Wwise.
//
//   IMMDeviceEnumerator -> IMMDevice (+ IPropertyStore, IMMEndpoint) -> IAudioClient3
//                       -> IAudioRenderClient, IAudioClock, IAudioSessionControl2, ISimpleAudioVolume
//
// There is one endpoint: the default macOS output, presented as 48 kHz float32 stereo. Frames the game
// renders go through a single-producer/single-consumer ring to an AUHAL output unit. Its render callback
// also signals the client's event once per period, which drives Wwise's event-driven render loop.
#include "shim.h"
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define SAMPLE_RATE   48000
#define CHANNELS      2
#define PERIOD_FRAMES 480        // 10 ms, the usual shared-mode engine period
#define HNS_PER_SEC   10000000ll // REFERENCE_TIME is in 100 ns units
#define PERIOD_HNS    (HNS_PER_SEC / 100)

// audioclient.h / mmdeviceapi.h
#define AUDCLNT_SHAREMODE_SHARED          0
#define AUDCLNT_STREAMFLAGS_EVENTCALLBACK 0x00040000
#define AUDCLNT_BUFFERFLAGS_SILENT        0x2
#define AUDCLNT_E_NOT_INITIALIZED         ((HRESULT)0x88890001)
#define AUDCLNT_E_ALREADY_INITIALIZED     ((HRESULT)0x88890002)
#define AUDCLNT_E_DEVICE_INVALIDATED      ((HRESULT)0x88890004)
#define AUDCLNT_E_BUFFER_TOO_LARGE        ((HRESULT)0x88890006)
#define AUDCLNT_E_UNSUPPORTED_FORMAT      ((HRESULT)0x88890008)
#define DEVICE_STATE_ACTIVE               0x1
#define AUDIO_SESSION_STATE_ACTIVE        1
enum { eRender, eCapture, eAll };

// ---------------------------------------------------------------- GUIDs
static const GUID CLSID_MMDeviceEnumerator = {
    0xbcde0395, 0xe52f, 0x467c, {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}};
static const GUID IID_IUnknown = {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID IID_IMMDeviceEnumerator = {
    0xa95664d2, 0x9614, 0x4f35, {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}};
static const GUID IID_IMMDevice = {0xd666063f, 0x1587, 0x4e43, {0x81, 0xf1, 0xb9, 0x48, 0xe8, 0x07, 0x36, 0x3f}};
static const GUID IID_IMMEndpoint = {0x1be09788, 0x6894, 0x4089, {0x85, 0x86, 0x9a, 0x2a, 0x6c, 0x26, 0x5a, 0xc5}};
static const GUID IID_IMMDeviceCollection = {
    0x0bd7a1be, 0x7a1a, 0x44db, {0x83, 0x97, 0xcc, 0x53, 0x92, 0x38, 0x7b, 0x5e}};
static const GUID IID_IPropertyStore = {0x886d8eeb, 0x8cf2, 0x4446, {0x8d, 0x02, 0xcd, 0xba, 0x1d, 0xbd, 0xcf, 0x99}};
static const GUID IID_IAudioClient = {0x1cb9ad4c, 0xdbfa, 0x4c32, {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}};
static const GUID IID_IAudioClient2 = {0x726778cd, 0xf60a, 0x4eda, {0x82, 0xde, 0xe4, 0x76, 0x10, 0xcd, 0x78, 0xaa}};
static const GUID IID_IAudioClient3 = {0x7ed4ee07, 0x8e67, 0x4cd4, {0x8c, 0x1a, 0x2b, 0x7a, 0x59, 0x87, 0xad, 0x42}};
static const GUID IID_IAudioRenderClient = {
    0xf294acfc, 0x3146, 0x4483, {0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2}};
static const GUID IID_IAudioClock = {0xcd63314f, 0x3fba, 0x4a1b, {0x81, 0x2c, 0xef, 0x96, 0x35, 0x87, 0x28, 0xe7}};
static const GUID IID_IAudioSessionControl = {
    0xf4b1a599, 0x7266, 0x4319, {0xa8, 0xca, 0xe7, 0x0a, 0xcb, 0x11, 0xe8, 0xcd}};
static const GUID IID_IAudioSessionControl2 = {
    0xbfb7ff88, 0x7239, 0x4fc9, {0x8f, 0xa2, 0x07, 0xc9, 0x50, 0xbe, 0x9c, 0x6d}};
static const GUID IID_ISimpleAudioVolume = {
    0x87ce5498, 0x68d6, 0x44e5, {0x92, 0x15, 0x6d, 0xa4, 0x7e, 0xf8, 0x83, 0xd8}};
static const GUID KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = {
    0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const PROPERTYKEY PKEY_Device_FriendlyName = {
    {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};
static const PROPERTYKEY PKEY_AudioEngine_DeviceFormat = {
    {0xf19f064d, 0x082c, 0x4e27, {0xbc, 0x73, 0x68, 0x82, 0xa1, 0xbb, 0x8e, 0x4c}}, 0};

static bool guid_equal(const GUID *a, const GUID *b) { return !memcmp(a, b, sizeof *a); }

// ---------------------------------------------------------------- objects
// Every object starts with its vtable. `iids` lists what QueryInterface answers with the same object.
typedef struct Object {
    void **vtbl;
    const GUID *const *iids;
    volatile int refs;
    struct Client *client; // services (render client, clock, session, volume) belong to a client
} Object;

static Object *object_new(void **vtbl, const GUID *const *iids, struct Client *client) {
    Object *o = calloc(1, sizeof *o);
    *o = (Object){vtbl, iids, 1, client};
    return o;
}

static WINAPI HRESULT QueryInterface(Object *o, const GUID *iid, void **out) {
    bool supported = guid_equal(iid, &IID_IUnknown);
    for (const GUID *const *i = o->iids; *i && !supported; i++) supported = guid_equal(iid, *i);
    if (!supported) {
        LOG("audio: QueryInterface({%08x-...}) -> E_NOINTERFACE", iid->Data1);
        *out = NULL;
        return E_NOINTERFACE;
    }
    __sync_add_and_fetch(&o->refs, 1);
    *out = o;
    return S_OK;
}

static WINAPI ULONG AddRef(Object *o) { return __sync_add_and_fetch(&o->refs, 1); }

static WINAPI ULONG Release(Object *o) {
    int refs = __sync_sub_and_fetch(&o->refs, 1);
    return refs < 0 ? 0 : refs; // objects are tiny and never freed: Wwise keeps them for the whole run
}

// Methods the game never needs; they log once and fail.
#define NOT_IMPLEMENTED(name)                                                                                          \
    static WINAPI HRESULT name(void) {                                                                                 \
        FIXME("audio: " #name " is not implemented");                                                                  \
        return E_NOTIMPL;                                                                                              \
    }

#define IUNKNOWN_METHODS (void *)QueryInterface, (void *)AddRef, (void *)Release

// ---------------------------------------------------------------- the stream
typedef struct Client {
    Object object;
    bool initialized, started, event_driven;
    WORD channels, bits, block_align;
    bool is_float;
    uint32_t buffer_frames;
    float *ring; // interleaved stereo float, ring_frames long
    uint32_t ring_frames;
    _Atomic uint64_t written, played; // frame counters
    uint8_t *staging;                 // what GetBuffer hands out, in the client's format
    HANDLE event;
    AudioComponentInstance unit;
} Client;

static WINAPI WBOOL (*g_set_event)(HANDLE);

static uint32_t queued_frames(Client *c) { return (uint32_t)(atomic_load(&c->written) - atomic_load(&c->played)); }

// CoreAudio render thread: drain the ring (silence on underrun), then wake the game's audio thread.
static OSStatus render(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus,
                       UInt32 frames, AudioBufferList *io) {
    Client *c = context;
    float *out = io->mBuffers[0].mData;
    uint64_t written = atomic_load_explicit(&c->written, memory_order_acquire);
    uint64_t played = atomic_load_explicit(&c->played, memory_order_relaxed);
    uint32_t available = (uint32_t)(written - played), take = available < frames ? available : frames;
    for (uint32_t i = 0; i < take; i++) {
        uint32_t slot = (uint32_t)((played + i) % c->ring_frames);
        out[CHANNELS * i] = c->ring[CHANNELS * slot];
        out[CHANNELS * i + 1] = c->ring[CHANNELS * slot + 1];
    }
    memset(out + CHANNELS * take, 0, (frames - take) * CHANNELS * sizeof(float));
    static int muted = -1; // LOADER_MUTE=1: keep the game's audio clock running but output silence
    if (muted < 0) muted = getenv("LOADER_MUTE") != NULL;
    if (muted) memset(out, 0, frames * CHANNELS * sizeof(float));
    static atomic_bool reported; // a one-time sign that the game's sound reaches the device
    for (uint32_t i = 0; take && i < take * CHANNELS && !atomic_load(&reported); i++)
        if (out[i] != 0.0f && !atomic_exchange(&reported, true)) LOG("audio: first non-silent output");
    atomic_store_explicit(&c->played, played + take, memory_order_release);
    if (c->event_driven && c->event) g_set_event(c->event);
    return noErr;
}

static bool open_output_unit(Client *c) {
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_DefaultOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    if (!component || AudioComponentInstanceNew(component, &c->unit)) return false;

    AudioStreamBasicDescription format = {
        .mSampleRate = SAMPLE_RATE,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = CHANNELS * sizeof(float),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = CHANNELS * sizeof(float),
        .mChannelsPerFrame = CHANNELS,
        .mBitsPerChannel = 32,
    };
    AURenderCallbackStruct callback = {render, c};
    UInt32 period = PERIOD_FRAMES;
    AudioUnitSetProperty(c->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format);
    AudioUnitSetProperty(c->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                         sizeof callback);
    AudioUnitSetProperty(c->unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &period,
                         sizeof period);
    return AudioUnitInitialize(c->unit) == noErr;
}

static WAVEFORMATEXTENSIBLE *new_mix_format(void) {
    WAVEFORMATEXTENSIBLE *f = malloc(sizeof *f); // freed by the caller with CoTaskMemFree
    *f = (WAVEFORMATEXTENSIBLE){
        .Format =
            {
                .wFormatTag = WAVE_FORMAT_EXTENSIBLE,
                .nChannels = CHANNELS,
                .nSamplesPerSec = SAMPLE_RATE,
                .nAvgBytesPerSec = SAMPLE_RATE * CHANNELS * sizeof(float),
                .nBlockAlign = CHANNELS * sizeof(float),
                .wBitsPerSample = 32,
                .cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX),
            },
        .wValidBitsPerSample = 32,
        .dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT,
        .SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
    };
    return f;
}

static bool format_is_float(const WAVEFORMATEX *f) {
    return f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ||
           (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
            guid_equal(&((const WAVEFORMATEXTENSIBLE *)f)->SubFormat, &KSDATAFORMAT_SUBTYPE_IEEE_FLOAT));
}

// We accept 48 kHz float32 or int16, any channel count (the first two channels are played).
static bool format_supported(const WAVEFORMATEX *f) {
    bool is_float = format_is_float(f);
    return f->nSamplesPerSec == SAMPLE_RATE && f->nChannels &&
           (is_float ? f->wBitsPerSample == 32 : f->wBitsPerSample == 16);
}

// ---------------------------------------------------------------- IAudioClient3
static HRESULT initialize(Client *c, DWORD flags, int64_t duration_hns, const WAVEFORMATEX *format) {
    if (c->initialized) return AUDCLNT_E_ALREADY_INITIALIZED;
    LOG("audio: Initialize(%lld ms, %u Hz, %u ch, %u bit %s)", (long long)duration_hns / 10000, format->nSamplesPerSec,
        format->nChannels, format->wBitsPerSample, format_is_float(format) ? "float" : "int");
    if (!format_supported(format)) return AUDCLNT_E_UNSUPPORTED_FORMAT;

    c->channels = format->nChannels;
    c->bits = format->wBitsPerSample;
    c->block_align = format->nBlockAlign;
    c->is_float = format_is_float(format);
    c->event_driven = flags & AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    c->buffer_frames = (uint32_t)(duration_hns * SAMPLE_RATE / HNS_PER_SEC);
    if (c->buffer_frames < 2 * PERIOD_FRAMES) c->buffer_frames = 2 * PERIOD_FRAMES;
    c->ring_frames = c->buffer_frames * 2;
    c->ring = calloc(c->ring_frames, CHANNELS * sizeof(float));
    c->staging = calloc(c->buffer_frames, c->block_align);
    if (!open_output_unit(c)) {
        LOG("audio: could not open the CoreAudio output unit");
        return AUDCLNT_E_DEVICE_INVALIDATED;
    }
    c->initialized = true;
    return S_OK;
}

static WINAPI HRESULT Initialize(Client *c, int share_mode, DWORD flags, int64_t duration,
                                                 int64_t period, const WAVEFORMATEX *format, const GUID *session) {
    if (share_mode != AUDCLNT_SHAREMODE_SHARED) return AUDCLNT_E_UNSUPPORTED_FORMAT;
    return initialize(c, flags, duration, format);
}

static WINAPI HRESULT InitializeSharedAudioStream(Client *c, DWORD flags, UINT period_frames,
                                                                  const WAVEFORMATEX *format, const GUID *session) {
    return initialize(c, flags, 2 * (int64_t)period_frames * HNS_PER_SEC / SAMPLE_RATE, format);
}

static WINAPI HRESULT GetBufferSize(Client *c, UINT *frames) {
    if (!c->initialized) return AUDCLNT_E_NOT_INITIALIZED;
    *frames = c->buffer_frames;
    return S_OK;
}

static WINAPI HRESULT GetStreamLatency(Client *c, int64_t *latency) {
    *latency = PERIOD_HNS;
    return S_OK;
}

static WINAPI HRESULT GetCurrentPadding(Client *c, UINT *frames) {
    if (!c->initialized) return AUDCLNT_E_NOT_INITIALIZED;
    *frames = queued_frames(c);
    return S_OK;
}

static WINAPI HRESULT IsFormatSupported(Client *c, int share_mode, const WAVEFORMATEX *format,
                                                        WAVEFORMATEXTENSIBLE **closest) {
    if (closest) *closest = NULL;
    if (share_mode == AUDCLNT_SHAREMODE_SHARED && format_supported(format)) return S_OK;
    if (share_mode == AUDCLNT_SHAREMODE_SHARED && closest) {
        *closest = new_mix_format();
        return S_FALSE;
    }
    return AUDCLNT_E_UNSUPPORTED_FORMAT;
}

static WINAPI HRESULT GetMixFormat(Client *c, WAVEFORMATEXTENSIBLE **format) {
    *format = new_mix_format();
    return S_OK;
}

static WINAPI HRESULT GetDevicePeriod(Client *c, int64_t *default_period, int64_t *minimum_period) {
    if (default_period) *default_period = PERIOD_HNS;
    if (minimum_period) *minimum_period = PERIOD_HNS / 3;
    return S_OK;
}

static WINAPI HRESULT Start(Client *c) {
    if (!c->initialized) return AUDCLNT_E_NOT_INITIALIZED;
    if (!c->started) AudioOutputUnitStart(c->unit);
    c->started = true;
    return S_OK;
}

static WINAPI HRESULT Stop(Client *c) {
    if (c->started) AudioOutputUnitStop(c->unit);
    c->started = false;
    return S_OK;
}

static WINAPI HRESULT Reset(Client *c) {
    atomic_store(&c->played, atomic_load(&c->written));
    return S_OK;
}

static WINAPI HRESULT SetEventHandle(Client *c, HANDLE event) {
    c->event = event;
    return S_OK;
}

static WINAPI HRESULT IsOffloadCapable(Client *c, int category, WBOOL *capable) {
    *capable = false;
    return S_OK;
}

static WINAPI HRESULT SetClientProperties(Client *c, const void *properties) { return S_OK; }

static WINAPI HRESULT GetSharedModeEnginePeriod(Client *c, const WAVEFORMATEX *format,
                                                                UINT *default_period, UINT *fundamental_period,
                                                                UINT *minimum_period, UINT *maximum_period) {
    *default_period = *fundamental_period = *minimum_period = *maximum_period = PERIOD_FRAMES;
    return S_OK;
}

static WINAPI HRESULT GetCurrentSharedModeEnginePeriod(Client *c, WAVEFORMATEXTENSIBLE **format,
                                                                       UINT *period) {
    *format = new_mix_format();
    *period = PERIOD_FRAMES;
    return S_OK;
}

NOT_IMPLEMENTED(GetBufferSizeLimits)
static WINAPI HRESULT GetService(Client *c, const GUID *iid, void **out);

static void *client_vtbl[] = {
    IUNKNOWN_METHODS,
    // IAudioClient
    Initialize,
    GetBufferSize,
    GetStreamLatency,
    GetCurrentPadding,
    IsFormatSupported,
    GetMixFormat,
    GetDevicePeriod,
    Start,
    Stop,
    Reset,
    SetEventHandle,
    GetService,
    // IAudioClient2
    IsOffloadCapable,
    SetClientProperties,
    GetBufferSizeLimits,
    // IAudioClient3
    GetSharedModeEnginePeriod,
    GetCurrentSharedModeEnginePeriod,
    InitializeSharedAudioStream,
};
static const GUID *const client_iids[] = {&IID_IAudioClient, &IID_IAudioClient2, &IID_IAudioClient3, NULL};

// ---------------------------------------------------------------- IAudioRenderClient
static WINAPI HRESULT GetBuffer(Object *o, UINT frames, uint8_t **data) {
    Client *c = o->client;
    if (frames > c->buffer_frames - queued_frames(c)) return AUDCLNT_E_BUFFER_TOO_LARGE;
    *data = c->staging;
    return S_OK;
}

// Convert the staged frames to stereo float and append them to the ring.
static WINAPI HRESULT ReleaseBuffer(Object *o, UINT frames, DWORD flags) {
    Client *c = o->client;
    uint64_t written = atomic_load_explicit(&c->written, memory_order_relaxed);
    for (UINT i = 0; i < frames; i++) {
        float left = 0, right = 0;
        if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
            const uint8_t *frame = c->staging + (size_t)i * c->block_align;
            if (c->is_float) {
                const float *s = (const float *)frame;
                left = s[0];
                right = c->channels > 1 ? s[1] : left;
            } else {
                const int16_t *s = (const int16_t *)frame;
                left = s[0] / 32768.f;
                right = c->channels > 1 ? s[1] / 32768.f : left;
            }
        }
        uint32_t slot = (uint32_t)((written + i) % c->ring_frames);
        c->ring[CHANNELS * slot] = left;
        c->ring[CHANNELS * slot + 1] = right;
    }
    atomic_store_explicit(&c->written, written + frames, memory_order_release);
    return S_OK;
}

static void *render_client_vtbl[] = {IUNKNOWN_METHODS, GetBuffer, ReleaseBuffer};
static const GUID *const render_client_iids[] = {&IID_IAudioRenderClient, NULL};

// ---------------------------------------------------------------- IAudioClock: frames played at SAMPLE_RATE
static WINAPI HRESULT GetFrequency(Object *o, uint64_t *frequency) {
    *frequency = SAMPLE_RATE;
    return S_OK;
}

static WINAPI HRESULT GetPosition(Object *o, uint64_t *position, uint64_t *qpc_position) {
    *position = atomic_load(&o->client->played);
    if (qpc_position) *qpc_position = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 100;
    return S_OK;
}

static WINAPI HRESULT GetCharacteristics(Object *o, DWORD *characteristics) {
    *characteristics = 0;
    return S_OK;
}

static void *clock_vtbl[] = {IUNKNOWN_METHODS, GetFrequency, GetPosition, GetCharacteristics};
static const GUID *const clock_iids[] = {&IID_IAudioClock, NULL};

// ---------------------------------------------------------------- IAudioSessionControl2, ISimpleAudioVolume
static WINAPI HRESULT GetState(Object *o, int *state) {
    *state = AUDIO_SESSION_STATE_ACTIVE;
    return S_OK;
}

static WINAPI HRESULT RegisterAudioSessionNotification(Object *o, void *client) { return S_OK; }

NOT_IMPLEMENTED(GetDisplayName)
NOT_IMPLEMENTED(SetDisplayName)
NOT_IMPLEMENTED(GetIconPath)
NOT_IMPLEMENTED(SetIconPath)
NOT_IMPLEMENTED(GetGroupingParam)
NOT_IMPLEMENTED(SetGroupingParam)
NOT_IMPLEMENTED(GetSessionIdentifier)
NOT_IMPLEMENTED(GetSessionInstanceIdentifier)
NOT_IMPLEMENTED(GetProcessId)
NOT_IMPLEMENTED(IsSystemSoundsSession)
NOT_IMPLEMENTED(SetDuckingPreference)

static void *session_vtbl[] = {
    IUNKNOWN_METHODS,
    // IAudioSessionControl
    GetState,
    GetDisplayName,
    SetDisplayName,
    GetIconPath,
    SetIconPath,
    GetGroupingParam,
    SetGroupingParam,
    RegisterAudioSessionNotification,
    RegisterAudioSessionNotification /* Unregister */,
    // IAudioSessionControl2
    GetSessionIdentifier,
    GetSessionInstanceIdentifier,
    GetProcessId,
    IsSystemSoundsSession,
    SetDuckingPreference,
};
static const GUID *const session_iids[] = {&IID_IAudioSessionControl, &IID_IAudioSessionControl2, NULL};

static WINAPI HRESULT GetMasterVolume(Object *o, float *level) {
    *level = 1;
    return S_OK;
}

static WINAPI HRESULT GetMute(Object *o, WBOOL *muted) {
    *muted = false;
    return S_OK;
}

NOT_IMPLEMENTED(SetMasterVolume)
NOT_IMPLEMENTED(SetMute)

static void *volume_vtbl[] = {IUNKNOWN_METHODS, SetMasterVolume, GetMasterVolume, SetMute, GetMute};
static const GUID *const volume_iids[] = {&IID_ISimpleAudioVolume, NULL};

static WINAPI HRESULT GetService(Client *c, const GUID *iid, void **out) {
    void **vtbl = guid_equal(iid, &IID_IAudioRenderClient) ? render_client_vtbl
                  : guid_equal(iid, &IID_IAudioClock)      ? clock_vtbl
                  : guid_equal(iid, &IID_IAudioSessionControl) || guid_equal(iid, &IID_IAudioSessionControl2)
                      ? session_vtbl
                  : guid_equal(iid, &IID_ISimpleAudioVolume) ? volume_vtbl
                                                             : NULL;
    const GUID *const *iids = vtbl == render_client_vtbl ? render_client_iids
                              : vtbl == clock_vtbl       ? clock_iids
                              : vtbl == session_vtbl     ? session_iids
                                                         : volume_iids;
    if (!vtbl) {
        LOG("audio: GetService({%08x-...}) -> E_NOINTERFACE", iid->Data1);
        *out = NULL;
        return E_NOINTERFACE;
    }
    *out = object_new(vtbl, iids, c);
    return S_OK;
}

// ---------------------------------------------------------------- IMMDevice, IPropertyStore, IMMEndpoint
static WINAPI HRESULT GetCount(Object *o, DWORD *count) {
    *count = 2;
    return S_OK;
}

static WINAPI HRESULT GetValue(Object *o, const PROPERTYKEY *key, PROPVARIANT *value) {
    memset(value, 0, sizeof *value); // VT_EMPTY unless known
    if (guid_equal(&key->fmtid, &PKEY_Device_FriendlyName.fmtid) && key->pid == PKEY_Device_FriendlyName.pid) {
        value->vt = VT_LPWSTR;
        value->pwszVal = u2w("Speakers (macOS default output)");
    } else if (guid_equal(&key->fmtid, &PKEY_AudioEngine_DeviceFormat.fmtid) &&
               key->pid == PKEY_AudioEngine_DeviceFormat.pid) {
        value->vt = VT_BLOB;
        value->blob.cbSize = sizeof(WAVEFORMATEXTENSIBLE);
        value->blob.pBlobData = (BYTE *)new_mix_format();
    }
    return S_OK;
}

NOT_IMPLEMENTED(GetAt)
NOT_IMPLEMENTED(SetValue)
NOT_IMPLEMENTED(Commit)

static void *property_store_vtbl[] = {IUNKNOWN_METHODS, GetCount, GetAt, GetValue, SetValue, Commit};
static const GUID *const property_store_iids[] = {&IID_IPropertyStore, NULL};

static WINAPI HRESULT GetDataFlow(Object *o, int *flow) {
    *flow = eRender;
    return S_OK;
}

static void *endpoint_vtbl[] = {IUNKNOWN_METHODS, GetDataFlow};
static const GUID *const endpoint_iids[] = {&IID_IMMEndpoint, NULL};

static WINAPI HRESULT Activate(Object *o, const GUID *iid, DWORD context, void *params, void **out) {
    if (guid_equal(iid, &IID_IAudioClient) || guid_equal(iid, &IID_IAudioClient2) ||
        guid_equal(iid, &IID_IAudioClient3)) {
        Client *c = calloc(1, sizeof *c);
        c->object = (Object){client_vtbl, client_iids, 1, c};
        *out = c;
        return S_OK;
    }
    if (guid_equal(iid, &IID_ISimpleAudioVolume)) {
        *out = object_new(volume_vtbl, volume_iids, NULL);
        return S_OK;
    }
    LOG("audio: IMMDevice::Activate({%08x-...}) -> E_NOINTERFACE", iid->Data1);
    *out = NULL;
    return E_NOINTERFACE;
}

static WINAPI HRESULT OpenPropertyStore(Object *o, DWORD access, void **out) {
    *out = object_new(property_store_vtbl, property_store_iids, NULL);
    return S_OK;
}

static WINAPI HRESULT GetId(Object *o, WCHAR **id) {
    *id = u2w("{0.0.0.00000000}.{coreaudio-default-output}");
    return S_OK;
}

static WINAPI HRESULT GetDeviceState(Object *o, DWORD *state) {
    *state = DEVICE_STATE_ACTIVE;
    return S_OK;
}

static void *device_vtbl[] = {IUNKNOWN_METHODS, Activate, OpenPropertyStore, GetId, GetDeviceState};
static const GUID *const device_iids[] = {&IID_IMMDevice, NULL};

// IMMDevice also answers IMMEndpoint with a separate object.
static WINAPI HRESULT DeviceQueryInterface(Object *o, const GUID *iid, void **out) {
    if (guid_equal(iid, &IID_IMMEndpoint)) {
        *out = object_new(endpoint_vtbl, endpoint_iids, NULL);
        return S_OK;
    }
    return QueryInterface(o, iid, out);
}

// ---------------------------------------------------------------- IMMDeviceEnumerator, IMMDeviceCollection
static Object *new_device(void) {
    Object *device = object_new(device_vtbl, device_iids, NULL);
    return device;
}

static WINAPI HRESULT GetDefaultAudioEndpoint(Object *o, int flow, int role, void **out) {
    if (flow != eRender) { // no capture devices
        *out = NULL;
        return E_NOTFOUND;
    }
    *out = new_device();
    return S_OK;
}

static WINAPI HRESULT GetDevice(Object *o, const WCHAR *id, void **out) {
    return GetDefaultAudioEndpoint(o, eRender, 0, out);
}

static WINAPI HRESULT CollectionGetCount(Object *o, UINT *count) {
    *count = (UINT)(uintptr_t)o->client; // number of render devices, see EnumAudioEndpoints
    return S_OK;
}

static WINAPI HRESULT Item(Object *o, UINT index, void **out) {
    if (index >= (UINT)(uintptr_t)o->client) return E_NOTFOUND;
    *out = new_device();
    return S_OK;
}

static void *collection_vtbl[] = {IUNKNOWN_METHODS, CollectionGetCount, Item};
static const GUID *const collection_iids[] = {&IID_IMMDeviceCollection, NULL};

static WINAPI HRESULT EnumAudioEndpoints(Object *o, int flow, DWORD state_mask, void **out) {
    bool render = flow == eRender || flow == eAll;
    *out = object_new(collection_vtbl, collection_iids, (Client *)(uintptr_t)render);
    return S_OK;
}

static WINAPI HRESULT RegisterEndpointNotificationCallback(Object *o, void *client) { return S_OK; }

static void *enumerator_vtbl[] = {
    IUNKNOWN_METHODS,
    EnumAudioEndpoints,
    GetDefaultAudioEndpoint,
    GetDevice,
    RegisterEndpointNotificationCallback,
    RegisterEndpointNotificationCallback /* Unregister */,
};
static const GUID *const enumerator_iids[] = {&IID_IMMDeviceEnumerator, NULL};

// Called by the CoCreateInstance shim.
HRESULT audio_create_instance(const GUID *clsid, const GUID *iid, void **out) {
    if (!guid_equal(clsid, &CLSID_MMDeviceEnumerator)) return REGDB_E_CLASSNOTREG;
    if (!g_set_event) g_set_event = shim_lookup("SetEvent");
    device_vtbl[0] = (void *)DeviceQueryInterface;
    Object *enumerator = object_new(enumerator_vtbl, enumerator_iids, NULL);
    HRESULT r = QueryInterface(enumerator, iid, out);
    Release(enumerator); // the caller now holds the only reference
    if (r != S_OK) free(enumerator);
    return r;
}

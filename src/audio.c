// MMDevice + WASAPI (shared mode, render only) on CoreAudio, enough for the game's statically linked Wwise.
//
// Objects: IMMDeviceEnumerator -> IMMDevice (+IMMEndpoint, IPropertyStore) -> IAudioClient(3)
//          -> IAudioRenderClient / IAudioClock / IAudioSessionControl / ISimpleAudioVolume.
// The client exposes one 48 kHz float32 stereo endpoint (the default macOS output). Rendered frames go
// through a single-producer/single-consumer ring to an AUHAL output unit, whose callback also signals
// the client's event handle once per period (event-driven mode).
// Unimplemented methods log "audio: unimplemented X::Y" and return E_NOTIMPL.
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "shim.h"

typedef uint32_t HRESULT;
#define S_OK 0
#define S_FALSE 1
#define E_NOTIMPL 0x80004001u
#define E_NOINTERFACE 0x80004002u
#define E_POINTER 0x80004003u
#define AUDCLNT_E_NOT_INITIALIZED 0x88890001u
#define AUDCLNT_E_ALREADY_INITIALIZED 0x88890002u
#define AUDCLNT_E_BUFFER_TOO_LARGE 0x88890006u
#define AUDCLNT_E_UNSUPPORTED_FORMAT 0x88890008u
#define AUDCLNT_S_BUFFER_EMPTY 0x08890001u

#define RATE 48000
#define PERIOD_FRAMES 480                      // 10 ms, the usual shared-mode engine period
#define PERIOD_HNS 100000ll                    // in 100 ns units

// ---------------------------------------------------------------- GUIDs
typedef struct { uint8_t b[16]; } GUID;
static GUID guid(const char *s) {  // "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -> Windows memory layout
    unsigned d1, d2, d3, b[8];
    sscanf(s, "%8x-%4x-%4x-%2x%2x-%2x%2x%2x%2x%2x%2x", &d1, &d2, &d3, &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &b[7]);
    GUID g;
    memcpy(g.b, &d1, 4);
    memcpy(g.b + 4, &d2, 2);
    memcpy(g.b + 6, &d3, 2);
    for (int i = 0; i < 8; i++) g.b[8 + i] = (uint8_t)b[i];
    return g;
}
static bool guid_eq(const void *a, const char *s) { GUID g = guid(s); return !memcmp(a, g.b, 16); }

#define CLSID_MMDeviceEnumerator   "bcde0395-e52f-467c-8e3d-c4579291692e"
#define IID_IUnknown               "00000000-0000-0000-c000-000000000046"
#define IID_IMMDeviceEnumerator    "a95664d2-9614-4f35-a746-de8db63617e6"
#define IID_IMMDevice              "d666063f-1587-4e43-81f1-b948e807363f"
#define IID_IMMEndpoint            "1be09788-6894-4089-8586-9a2a6c265ac5"
#define IID_IMMDeviceCollection    "0bd7a1be-7a1a-44db-8397-cc5392387b5e"
#define IID_IPropertyStore         "886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"
#define IID_IAudioClient           "1cb9ad4c-dbfa-4c32-b178-c2f568a703b2"
#define IID_IAudioClient2          "726778cd-f60a-4eda-82de-e47610cd78aa"
#define IID_IAudioClient3          "7ed4ee07-8e67-4cd4-8c1a-2b7a5987ad42"
#define IID_IAudioRenderClient     "f294acfc-3146-4483-a7bf-addca7c260e2"
#define IID_IAudioClock            "cd63314f-3fba-4a1b-812c-ef96358728e7"
#define IID_IAudioSessionControl   "f4b1a599-7266-4319-a8ca-e70acb11e8cd"
#define IID_IAudioSessionControl2  "bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"
#define IID_ISimpleAudioVolume     "87ce5498-68d6-44e5-9215-6da47ef883d8"
#define IID_IAudioStreamVolume     "93014887-242d-4068-8a15-cf5e93b90fe3"
#define KSDATAFORMAT_SUBTYPE_FLOAT "00000003-0000-0010-8000-00aa00389b71"
#define KSDATAFORMAT_SUBTYPE_PCM   "00000001-0000-0010-8000-00aa00389b71"
#define PKEY_Device_FriendlyName   "a45c254e-df1c-4efd-8020-67d146a850e0"   // pid 14
#define PKEY_AudioEngine_DeviceFormat "f19f064d-082c-4e27-bc73-6882a1bb8e4c" // pid 0

// ---------------------------------------------------------------- tiny COM object model
enum { A_ENUM, A_DEVICE, A_ENDPOINT, A_PROPS, A_COLLECTION, A_CLIENT, A_RENDER, A_CLOCK, A_SESSION, A_VOLUME, A_STREAMVOL, A_COUNT };
static const char *const g_aiface[A_COUNT] = {"IMMDeviceEnumerator", "IMMDevice", "IMMEndpoint", "IPropertyStore",
    "IMMDeviceCollection", "IAudioClient3", "IAudioRenderClient", "IAudioClock", "IAudioSessionControl2",
    "ISimpleAudioVolume", "IAudioStreamVolume"};
static const char *const m_unknown[] = {"QueryInterface", "AddRef", "Release"};
static const char *const m_enum[] = {"EnumAudioEndpoints", "GetDefaultAudioEndpoint", "GetDevice",
    "RegisterEndpointNotificationCallback", "UnregisterEndpointNotificationCallback", NULL};
static const char *const m_device[] = {"Activate", "OpenPropertyStore", "GetId", "GetState", NULL};
static const char *const m_endpoint[] = {"GetDataFlow", NULL};
static const char *const m_props[] = {"GetCount", "GetAt", "GetValue", "SetValue", "Commit", NULL};
static const char *const m_collection[] = {"GetCount", "Item", NULL};
static const char *const m_client[] = {"Initialize", "GetBufferSize", "GetStreamLatency", "GetCurrentPadding",
    "IsFormatSupported", "GetMixFormat", "GetDevicePeriod", "Start", "Stop", "Reset", "SetEventHandle", "GetService",
    "IsOffloadCapable", "SetClientProperties", "GetBufferSizeLimits",                       // IAudioClient2
    "GetSharedModeEnginePeriod", "GetCurrentSharedModeEnginePeriod", "InitializeSharedAudioStream", NULL};  // 3
static const char *const m_render[] = {"GetBuffer", "ReleaseBuffer", NULL};
static const char *const m_clock[] = {"GetFrequency", "GetPosition", "GetCharacteristics", NULL};
static const char *const m_session[] = {"GetState", "GetDisplayName", "SetDisplayName", "GetIconPath", "SetIconPath",
    "GetGroupingParam", "SetGroupingParam", "RegisterAudioSessionNotification", "UnregisterAudioSessionNotification",
    "GetSessionIdentifier", "GetSessionInstanceIdentifier", "GetProcessId", "IsSystemSoundsSession", "SetDuckingPreference", NULL};
static const char *const m_volume[] = {"SetMasterVolume", "GetMasterVolume", "SetMute", "GetMute", NULL};
static const char *const m_streamvol[] = {"GetChannelCount", "SetChannelVolume", "GetChannelVolume", "SetAllVolumes", "GetAllVolumes", NULL};
static const char *const *const g_amethods[A_COUNT] = {m_enum, m_device, m_endpoint, m_props, m_collection, m_client,
    m_render, m_clock, m_session, m_volume, m_streamvol};

typedef struct AObj {
    void **vtbl;
    int kind;
    volatile int refs;
    struct AObj *client;  // for services: the owning client
} AObj;

// ---------------------------------------------------------------- the one stream
typedef struct {
    AObj obj;
    bool initialized, started, event_driven;
    uint32_t channels, bits, is_float, block_align;
    uint32_t buffer_frames;
    float *ring;                       // stereo float frames
    uint32_t ring_frames;
    _Atomic uint64_t written, played;  // frame counters
    uint8_t *staging;                  // what GetBuffer hands out
    uint32_t staged;
    HANDLE event;
    AudioComponentInstance unit;
} Client;

static Client *g_client;
static WINAPI WBOOL (*g_set_event)(HANDLE);

static OSStatus render_cb(void *ctx, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts, UInt32 bus, UInt32 n,
                          AudioBufferList *io) {
    (void)fl; (void)ts; (void)bus;
    Client *c = ctx;
    float *out = io->mBuffers[0].mData;  // interleaved stereo float
    uint64_t w = atomic_load_explicit(&c->written, memory_order_acquire);
    uint64_t p = atomic_load_explicit(&c->played, memory_order_relaxed);
    uint32_t avail = (uint32_t)(w - p), take = avail < n ? avail : n;
    for (uint32_t i = 0; i < take; i++) {
        uint32_t r = (uint32_t)((p + i) % c->ring_frames);
        out[2 * i] = c->ring[2 * r];
        out[2 * i + 1] = c->ring[2 * r + 1];
    }
    memset(out + 2 * take, 0, (n - take) * 2 * sizeof(float));
    atomic_store_explicit(&c->played, p + take, memory_order_release);
    if (c->event_driven && c->event) g_set_event(c->event);
    return noErr;
}

static bool start_unit(Client *c) {
    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    if (!comp || AudioComponentInstanceNew(comp, &c->unit)) return false;
    AudioStreamBasicDescription f = {.mSampleRate = RATE, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, .mBytesPerPacket = 8, .mFramesPerPacket = 1,
        .mBytesPerFrame = 8, .mChannelsPerFrame = 2, .mBitsPerChannel = 32};
    AudioUnitSetProperty(c->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
    AURenderCallbackStruct cb = {render_cb, c};
    AudioUnitSetProperty(c->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    UInt32 frames = PERIOD_FRAMES;
    AudioUnitSetProperty(c->unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, sizeof frames);
    return AudioUnitInitialize(c->unit) == noErr;
}

// ---------------------------------------------------------------- unimplemented slots
static const char *g_aname[256];
static uint32_t g_naname;
__attribute__((used)) static WINAPI HRESULT audio_unimpl(uint32_t id) {
    LOG("audio: unimplemented %s", id < g_naname ? g_aname[id] : "?");
    return E_NOTIMPL;
}
__asm__(".intel_syntax noprefix\n"
        "_audio_unimpl_entry:\n"
        "  mov ecx, r10d\n  jmp _audio_unimpl\n"
        ".att_syntax\n");
extern char audio_unimpl_entry[];

// ---------------------------------------------------------------- methods
static AObj *aobj_new(int kind, AObj *client);

static WINAPI HRESULT a_QueryInterface(AObj *o, const void *iid, void **out) {
    static const char *const fam[A_COUNT][4] = {
        {IID_IMMDeviceEnumerator}, {IID_IMMDevice}, {IID_IMMEndpoint}, {IID_IPropertyStore}, {IID_IMMDeviceCollection},
        {IID_IAudioClient, IID_IAudioClient2, IID_IAudioClient3}, {IID_IAudioRenderClient}, {IID_IAudioClock},
        {IID_IAudioSessionControl, IID_IAudioSessionControl2}, {IID_ISimpleAudioVolume}, {IID_IAudioStreamVolume}};
    bool ok = guid_eq(iid, IID_IUnknown);
    for (int i = 0; i < 4 && fam[o->kind][i] && !ok; i++) ok = guid_eq(iid, fam[o->kind][i]);
    if (ok) { __sync_add_and_fetch(&o->refs, 1); *out = o; return S_OK; }
    if (o->kind == A_DEVICE && guid_eq(iid, IID_IMMEndpoint)) { *out = aobj_new(A_ENDPOINT, NULL); return S_OK; }
    const uint32_t *g = iid;
    LOG("audio: %s QueryInterface({%08x-...}) -> E_NOINTERFACE", g_aiface[o->kind], g[0]);
    *out = NULL;
    return E_NOINTERFACE;
}
static WINAPI uint32_t a_AddRef(AObj *o) { return __sync_add_and_fetch(&o->refs, 1); }
static WINAPI uint32_t a_Release(AObj *o) { int r = __sync_sub_and_fetch(&o->refs, 1); return r < 0 ? 0 : r; }

// IMMDeviceEnumerator
static WINAPI HRESULT e_GetDefaultAudioEndpoint(AObj *o, int flow, int role, void **out) {
    (void)o;
    LOG("audio: GetDefaultAudioEndpoint(flow=%d, role=%d)", flow, role);
    if (flow != 0) { *out = NULL; return 0x80070490; }  // E_NOTFOUND: no capture devices
    *out = aobj_new(A_DEVICE, NULL);
    return S_OK;
}
static WINAPI HRESULT e_GetDevice(AObj *o, const WCHAR *id, void **out) { (void)id; return e_GetDefaultAudioEndpoint(o, 0, 0, out); }
static WINAPI HRESULT e_EnumAudioEndpoints(AObj *o, int flow, DWORD mask, void **out) {
    (void)o; (void)mask;
    AObj *c = aobj_new(A_COLLECTION, NULL);
    c->client = (AObj *)(intptr_t)(flow == 0 || flow == 2);  // count of render devices
    *out = c;
    return S_OK;
}
static WINAPI HRESULT e_RegisterCallback(AObj *o, void *cb) { (void)o; (void)cb; return S_OK; }
static WINAPI HRESULT col_GetCount(AObj *o, uint32_t *n) { *n = (uint32_t)(intptr_t)o->client; return S_OK; }
static WINAPI HRESULT col_Item(AObj *o, uint32_t i, void **out) {
    if (i >= (uint32_t)(intptr_t)o->client) return E_NOTIMPL;
    *out = aobj_new(A_DEVICE, NULL);
    return S_OK;
}

// IMMDevice
static WINAPI HRESULT d_Activate(AObj *o, const void *iid, DWORD ctx, void *params, void **out) {
    (void)o; (void)ctx; (void)params;
    if (guid_eq(iid, IID_IAudioClient) || guid_eq(iid, IID_IAudioClient2) || guid_eq(iid, IID_IAudioClient3)) {
        Client *c = calloc(1, sizeof *c);
        AObj *a = aobj_new(A_CLIENT, NULL);
        c->obj = *a;
        free(a);
        *out = c;
        LOG("audio: IMMDevice::Activate(IAudioClient) -> %p", (void *)c);
        return S_OK;
    }
    if (guid_eq(iid, IID_IAudioStreamVolume) || guid_eq(iid, IID_ISimpleAudioVolume)) {
        *out = aobj_new(guid_eq(iid, IID_ISimpleAudioVolume) ? A_VOLUME : A_STREAMVOL, NULL);
        return S_OK;
    }
    const uint32_t *g = iid;
    LOG("audio: IMMDevice::Activate({%08x-...}) -> E_NOINTERFACE", g[0]);
    *out = NULL;
    return E_NOINTERFACE;
}
static WINAPI HRESULT d_OpenPropertyStore(AObj *o, DWORD access, void **out) { (void)o; (void)access; *out = aobj_new(A_PROPS, NULL); return S_OK; }
static WINAPI HRESULT d_GetId(AObj *o, WCHAR **out) { (void)o; *out = u2w("{0.0.0.00000000}.{coreaudio-default-output}"); return S_OK; }
static WINAPI HRESULT d_GetState(AObj *o, DWORD *st) { (void)o; *st = 1; return S_OK; }  // DEVICE_STATE_ACTIVE
static WINAPI HRESULT ep_GetDataFlow(AObj *o, int *f) { (void)o; *f = 0; return S_OK; }   // eRender

static void fill_mix_format(uint8_t *w) {
    memset(w, 0, 40);
    *(uint16_t *)w = 0xFFFE;                  // WAVE_FORMAT_EXTENSIBLE
    *(uint16_t *)(w + 2) = 2;
    *(uint32_t *)(w + 4) = RATE;
    *(uint32_t *)(w + 8) = RATE * 8;
    *(uint16_t *)(w + 12) = 8;
    *(uint16_t *)(w + 14) = 32;
    *(uint16_t *)(w + 16) = 22;
    *(uint16_t *)(w + 18) = 32;               // wValidBitsPerSample
    *(uint32_t *)(w + 20) = 3;                // SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT
    GUID g = guid(KSDATAFORMAT_SUBTYPE_FLOAT);
    memcpy(w + 24, g.b, 16);
}

// IPropertyStore: friendly name and device format.
static WINAPI HRESULT p_GetCount(AObj *o, DWORD *n) { (void)o; *n = 2; return S_OK; }
static WINAPI HRESULT p_GetValue(AObj *o, const uint8_t *key, uint8_t *pv) {
    (void)o;
    memset(pv, 0, 24);
    uint32_t pid = *(const uint32_t *)(key + 16);
    if (guid_eq(key, PKEY_Device_FriendlyName) && pid == 14) {
        *(uint16_t *)pv = 31;                 // VT_LPWSTR
        *(WCHAR **)(pv + 8) = u2w("Speakers (macOS default output)");
    } else if (guid_eq(key, PKEY_AudioEngine_DeviceFormat) && pid == 0) {
        *(uint16_t *)pv = 65;                 // VT_BLOB
        uint8_t *w = malloc(40);
        fill_mix_format(w);
        *(uint32_t *)(pv + 8) = 40;
        *(uint8_t **)(pv + 16) = w;
    }
    return S_OK;  // VT_EMPTY for anything else
}

// IAudioClient
static HRESULT client_init(Client *c, uint32_t flags, int64_t dur, const uint8_t *fmt) {
    if (c->initialized) return AUDCLNT_E_ALREADY_INITIALIZED;
    uint16_t tag = *(uint16_t *)fmt;
    c->channels = *(uint16_t *)(fmt + 2);
    c->bits = *(uint16_t *)(fmt + 14);
    c->block_align = *(uint16_t *)(fmt + 12);
    uint32_t rate = *(uint32_t *)(fmt + 4);
    c->is_float = tag == 3 || (tag == 0xFFFE && guid_eq(fmt + 24, KSDATAFORMAT_SUBTYPE_FLOAT));
    LOG("audio: Initialize(flags=%#x, dur=%lldms, %u Hz, %u ch, %u bit %s)", flags, (long long)dur / 10000, rate, c->channels,
        c->bits, c->is_float ? "float" : "int");
    if (rate != RATE || !c->channels || !((c->is_float && c->bits == 32) || (!c->is_float && c->bits == 16)))
        return AUDCLNT_E_UNSUPPORTED_FORMAT;
    c->event_driven = flags & 0x40000;       // AUDCLNT_STREAMFLAGS_EVENTCALLBACK
    uint32_t frames = (uint32_t)(dur * RATE / 10000000);
    if (frames < 2 * PERIOD_FRAMES) frames = 2 * PERIOD_FRAMES;
    c->buffer_frames = frames;
    c->ring_frames = frames * 2;
    c->ring = calloc(c->ring_frames, 2 * sizeof(float));
    c->staging = calloc(frames, c->block_align);
    if (!start_unit(c)) { LOG("audio: CoreAudio output unit failed"); return 0x88890004; }  // DEVICE_INVALIDATED
    c->initialized = true;
    return S_OK;
}
static WINAPI HRESULT c_Initialize(Client *c, int mode, DWORD flags, int64_t dur, int64_t period, const uint8_t *fmt, const void *sess) {
    (void)period; (void)sess;
    if (mode != 0) return AUDCLNT_E_UNSUPPORTED_FORMAT;  // exclusive mode not supported
    return client_init(c, flags, dur, fmt);
}
static WINAPI HRESULT c_InitializeSharedAudioStream(Client *c, DWORD flags, uint32_t period, const uint8_t *fmt, const void *sess) {
    (void)sess;
    return client_init(c, flags, (int64_t)period * 10000000 / RATE * 2, fmt);
}
static WINAPI HRESULT c_GetBufferSize(Client *c, uint32_t *n) {
    if (!c->initialized) return AUDCLNT_E_NOT_INITIALIZED;
    *n = c->buffer_frames;
    return S_OK;
}
static WINAPI HRESULT c_GetStreamLatency(Client *c, int64_t *l) { (void)c; *l = PERIOD_HNS; return S_OK; }
static uint32_t padding(Client *c) { return (uint32_t)(atomic_load(&c->written) - atomic_load(&c->played)); }
static WINAPI HRESULT c_GetCurrentPadding(Client *c, uint32_t *n) {
    if (!c->initialized) return AUDCLNT_E_NOT_INITIALIZED;
    *n = padding(c);
    return S_OK;
}
static WINAPI HRESULT c_IsFormatSupported(Client *c, int mode, const uint8_t *fmt, uint8_t **closest) {
    (void)c;
    if (closest) *closest = NULL;
    uint16_t tag = *(uint16_t *)fmt, bits = *(uint16_t *)(fmt + 14);
    uint32_t rate = *(uint32_t *)(fmt + 4);
    bool fl = tag == 3 || (tag == 0xFFFE && guid_eq(fmt + 24, KSDATAFORMAT_SUBTYPE_FLOAT));
    bool ok = mode == 0 && rate == RATE && ((fl && bits == 32) || (!fl && bits == 16));
    if (!ok && closest && mode == 0) {
        *closest = malloc(40);
        fill_mix_format(*closest);
        return S_FALSE;
    }
    return ok ? S_OK : AUDCLNT_E_UNSUPPORTED_FORMAT;
}
static WINAPI HRESULT c_GetMixFormat(Client *c, uint8_t **out) { (void)c; *out = malloc(40); fill_mix_format(*out); return S_OK; }
static WINAPI HRESULT c_GetDevicePeriod(Client *c, int64_t *def, int64_t *min) {
    (void)c;
    if (def) *def = PERIOD_HNS;
    if (min) *min = PERIOD_HNS / 3;
    return S_OK;
}
static WINAPI HRESULT c_Start(Client *c) {
    if (!c->initialized) return AUDCLNT_E_NOT_INITIALIZED;
    if (!c->started) AudioOutputUnitStart(c->unit);
    c->started = true;
    LOG("audio: Start");
    return S_OK;
}
static WINAPI HRESULT c_Stop(Client *c) {
    if (c->started) AudioOutputUnitStop(c->unit);
    c->started = false;
    return S_OK;
}
static WINAPI HRESULT c_Reset(Client *c) { atomic_store(&c->played, atomic_load(&c->written)); return S_OK; }
static WINAPI HRESULT c_SetEventHandle(Client *c, HANDLE e) { c->event = e; return S_OK; }
static WINAPI HRESULT c_GetService(Client *c, const void *iid, void **out) {
    int kind = guid_eq(iid, IID_IAudioRenderClient) ? A_RENDER : guid_eq(iid, IID_IAudioClock) ? A_CLOCK
             : guid_eq(iid, IID_IAudioSessionControl) || guid_eq(iid, IID_IAudioSessionControl2) ? A_SESSION
             : guid_eq(iid, IID_ISimpleAudioVolume) ? A_VOLUME : guid_eq(iid, IID_IAudioStreamVolume) ? A_STREAMVOL : -1;
    if (kind < 0) {
        const uint32_t *g = iid;
        LOG("audio: GetService({%08x-...}) -> E_NOINTERFACE", g[0]);
        *out = NULL;
        return E_NOINTERFACE;
    }
    *out = aobj_new(kind, &c->obj);
    if (kind == A_RENDER) g_client = c;
    return S_OK;
}
static WINAPI HRESULT c_IsOffloadCapable(Client *c, int cat, WBOOL *b) { (void)c; (void)cat; *b = 0; return S_OK; }
static WINAPI HRESULT c_SetClientProperties(Client *c, const void *p) { (void)c; (void)p; return S_OK; }
static WINAPI HRESULT c_GetSharedModeEnginePeriod(Client *c, const void *f, uint32_t *def, uint32_t *fund, uint32_t *mn, uint32_t *mx) {
    (void)c; (void)f;
    *def = PERIOD_FRAMES; *fund = PERIOD_FRAMES; *mn = PERIOD_FRAMES; *mx = PERIOD_FRAMES;
    return S_OK;
}
static WINAPI HRESULT c_GetCurrentSharedModeEnginePeriod(Client *c, uint8_t **f, uint32_t *p) {
    (void)c;
    *f = malloc(40);
    fill_mix_format(*f);
    *p = PERIOD_FRAMES;
    return S_OK;
}

// IAudioRenderClient
static Client *client_of(AObj *o) { return (Client *)o->client; }
static WINAPI HRESULT r_GetBuffer(AObj *o, uint32_t n, uint8_t **data) {
    Client *c = client_of(o);
    if (n > c->buffer_frames - padding(c)) return AUDCLNT_E_BUFFER_TOO_LARGE;
    c->staged = n;
    *data = c->staging;
    return S_OK;
}
static WINAPI HRESULT r_ReleaseBuffer(AObj *o, uint32_t n, DWORD flags) {
    Client *c = client_of(o);
    uint64_t w = atomic_load_explicit(&c->written, memory_order_relaxed);
    for (uint32_t i = 0; i < n; i++) {
        float l = 0, r = 0;
        if (!(flags & 2)) {  // AUDCLNT_BUFFERFLAGS_SILENT
            const uint8_t *f = c->staging + (size_t)i * c->block_align;
            if (c->is_float) { l = ((const float *)f)[0]; r = c->channels > 1 ? ((const float *)f)[1] : l; }
            else { l = ((const int16_t *)f)[0] / 32768.f; r = c->channels > 1 ? ((const int16_t *)f)[1] / 32768.f : l; }
        }
        uint32_t k = (uint32_t)((w + i) % c->ring_frames);
        c->ring[2 * k] = l;
        c->ring[2 * k + 1] = r;
    }
    atomic_store_explicit(&c->written, w + n, memory_order_release);
    return S_OK;
}

// IAudioClock: position in frames at RATE
static WINAPI HRESULT k_GetFrequency(AObj *o, uint64_t *f) { (void)o; *f = RATE; return S_OK; }
static WINAPI HRESULT k_GetPosition(AObj *o, uint64_t *pos, uint64_t *qpc) {
    *pos = atomic_load(&client_of(o)->played);
    if (qpc) *qpc = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 100;
    return S_OK;
}
static WINAPI HRESULT k_GetCharacteristics(AObj *o, DWORD *c) { (void)o; *c = 0; return S_OK; }

// Session / volume: inert
static WINAPI HRESULT s_ok1(AObj *o, void *a) { (void)o; (void)a; return S_OK; }
static WINAPI HRESULT s_GetState(AObj *o, int *st) { (void)o; *st = 1; return S_OK; }
static WINAPI HRESULT v_GetMasterVolume(AObj *o, float *v) { (void)o; *v = 1; return S_OK; }
static WINAPI HRESULT v_GetMute(AObj *o, WBOOL *m) { (void)o; *m = 0; return S_OK; }
static WINAPI HRESULT sv_GetChannelCount(AObj *o, uint32_t *n) { (void)o; *n = 2; return S_OK; }

// ---------------------------------------------------------------- vtable assembly
typedef struct { int kind; const char *m; void *fn; } AImpl;
#define AI(k, m, f) {k, m, (void *)f}
static const AImpl g_aimpls[] = {
    AI(-1, "QueryInterface", a_QueryInterface), AI(-1, "AddRef", a_AddRef), AI(-1, "Release", a_Release),
    AI(A_ENUM, "GetDefaultAudioEndpoint", e_GetDefaultAudioEndpoint), AI(A_ENUM, "GetDevice", e_GetDevice),
    AI(A_ENUM, "EnumAudioEndpoints", e_EnumAudioEndpoints),
    AI(A_ENUM, "RegisterEndpointNotificationCallback", e_RegisterCallback),
    AI(A_ENUM, "UnregisterEndpointNotificationCallback", e_RegisterCallback),
    AI(A_COLLECTION, "GetCount", col_GetCount), AI(A_COLLECTION, "Item", col_Item),
    AI(A_DEVICE, "Activate", d_Activate), AI(A_DEVICE, "OpenPropertyStore", d_OpenPropertyStore),
    AI(A_DEVICE, "GetId", d_GetId), AI(A_DEVICE, "GetState", d_GetState), AI(A_ENDPOINT, "GetDataFlow", ep_GetDataFlow),
    AI(A_PROPS, "GetCount", p_GetCount), AI(A_PROPS, "GetValue", p_GetValue),
    AI(A_CLIENT, "Initialize", c_Initialize), AI(A_CLIENT, "GetBufferSize", c_GetBufferSize),
    AI(A_CLIENT, "GetStreamLatency", c_GetStreamLatency), AI(A_CLIENT, "GetCurrentPadding", c_GetCurrentPadding),
    AI(A_CLIENT, "IsFormatSupported", c_IsFormatSupported), AI(A_CLIENT, "GetMixFormat", c_GetMixFormat),
    AI(A_CLIENT, "GetDevicePeriod", c_GetDevicePeriod), AI(A_CLIENT, "Start", c_Start), AI(A_CLIENT, "Stop", c_Stop),
    AI(A_CLIENT, "Reset", c_Reset), AI(A_CLIENT, "SetEventHandle", c_SetEventHandle), AI(A_CLIENT, "GetService", c_GetService),
    AI(A_CLIENT, "IsOffloadCapable", c_IsOffloadCapable), AI(A_CLIENT, "SetClientProperties", c_SetClientProperties),
    AI(A_CLIENT, "GetSharedModeEnginePeriod", c_GetSharedModeEnginePeriod),
    AI(A_CLIENT, "GetCurrentSharedModeEnginePeriod", c_GetCurrentSharedModeEnginePeriod),
    AI(A_CLIENT, "InitializeSharedAudioStream", c_InitializeSharedAudioStream),
    AI(A_RENDER, "GetBuffer", r_GetBuffer), AI(A_RENDER, "ReleaseBuffer", r_ReleaseBuffer),
    AI(A_CLOCK, "GetFrequency", k_GetFrequency), AI(A_CLOCK, "GetPosition", k_GetPosition),
    AI(A_CLOCK, "GetCharacteristics", k_GetCharacteristics),
    AI(A_SESSION, "GetState", s_GetState), AI(A_SESSION, "RegisterAudioSessionNotification", s_ok1),
    AI(A_SESSION, "UnregisterAudioSessionNotification", s_ok1),
    AI(A_VOLUME, "GetMasterVolume", v_GetMasterVolume), AI(A_VOLUME, "GetMute", v_GetMute),
    AI(A_STREAMVOL, "GetChannelCount", sv_GetChannelCount),
};

static void **g_avt[A_COUNT];
static void **build_avtable(int kind) {
    int n = 3;
    while (g_amethods[kind][n - 3]) n++;
    void **vt = calloc(n, sizeof *vt);
    for (int i = 0; i < n; i++) {
        const char *m = i < 3 ? m_unknown[i] : g_amethods[kind][i - 3];
        void *fn = NULL;
        for (size_t j = 0; j < sizeof g_aimpls / sizeof *g_aimpls && !fn; j++)
            if ((g_aimpls[j].kind == kind || g_aimpls[j].kind == -1) && !strcmp(g_aimpls[j].m, m)) fn = g_aimpls[j].fn;
        if (!fn) {
            char name[96];
            snprintf(name, sizeof name, "%s::%s", g_aiface[kind], m);
            g_aname[g_naname] = strdup(name);
            fn = make_tagged_thunk(g_naname++, audio_unimpl_entry);
        }
        vt[i] = fn;
    }
    return vt;
}

static pthread_mutex_t g_alock = PTHREAD_MUTEX_INITIALIZER;
static AObj *aobj_new(int kind, AObj *client) {
    pthread_mutex_lock(&g_alock);
    if (!g_avt[kind]) g_avt[kind] = build_avtable(kind);
    pthread_mutex_unlock(&g_alock);
    AObj *o = calloc(1, sizeof *o);
    o->vtbl = g_avt[kind];
    o->kind = kind;
    o->refs = 1;
    o->client = client;
    return o;
}

// Called by the CoCreateInstance shim.
HRESULT audio_create_instance(const void *clsid, const void *iid, void **out) {
    if (!guid_eq(clsid, CLSID_MMDeviceEnumerator)) return 0x80040154;  // REGDB_E_CLASSNOTREG
    if (!g_set_event) g_set_event = shim_lookup("SetEvent");
    AObj *e = aobj_new(A_ENUM, NULL);
    HRESULT r = a_QueryInterface(e, iid, out);
    LOG("audio: CoCreateInstance(MMDeviceEnumerator) -> %#x", r);
    return r;
}

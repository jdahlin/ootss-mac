// GPU profiling (D3D12_PROFILE=1): every Metal encoder is bracketed by GPU timestamps, labelled by what it
// drew, and the totals per label are logged as the average per frame. Apple GPUs sample counters at encoder
// (stage) boundaries only, so the resolution is one encoder.
#include "objects.h"
#include <mach/mach_time.h>

#define PROFILE_ENCODERS     1024 // per command buffer
#define PROFILE_LABELS       96
#define PROFILE_REPORT_EVERY 120

typedef struct ProfileEntry {
    char key[64];
    uint32_t count; // draws or dispatches
} ProfileEntry;

struct Profile {
    id<MTLCounterSampleBuffer> samples;
    ProfileEntry entries[PROFILE_ENCODERS];
    uint32_t used;
    id<MTLDevice> device;
};

static bool profiling(void) {
    static int on = -1;
    if (on < 0) on = getenv("D3D12_PROFILE") != NULL;
    return on;
}

static Profile *g_building; // the command buffer being filled
static id g_building_owner;

Profile *profile_for(id<MTLCommandBuffer> cb) {
    if (!profiling()) return NULL;
    if (g_building && g_building_owner == cb) return g_building;
    Profile *p = calloc(1, sizeof *p);
    p->device = cb.device;
    id<MTLCounterSet> set = nil;
    for (id<MTLCounterSet> s in p->device.counterSets)
        if ([s.name isEqualToString:MTLCommonCounterSetTimestamp]) set = s;
    if (!set) {
        free(p);
        return NULL;
    }
    MTLCounterSampleBufferDescriptor *d = [[MTLCounterSampleBufferDescriptor alloc] init];
    d.counterSet = set;
    d.storageMode = MTLStorageModeShared;
    d.sampleCount = 2 * PROFILE_ENCODERS;
    NSError *error = nil;
    p->samples = [p->device newCounterSampleBufferWithDescriptor:d error:&error];
    [d release];
    if (!p->samples) {
        D3D_LOG("profile: %s", error.localizedDescription.UTF8String);
        free(p);
        return NULL;
    }
    g_building = p;
    g_building_owner = cb;
    return p;
}

id<MTLCounterSampleBuffer> profile_samples(Profile *p) { return p->samples; }

int profile_slot(Profile *p) { return p->used < PROFILE_ENCODERS ? (int)p->used++ : -1; }

void profile_label(Profile *p, int slot, const char *key, uint32_t count) {
    if (slot < 0) return;
    int earlier = 0; // "#n": the n-th encoder with this label in the command buffer
    for (int i = 0; i < slot; i++) {
        size_t n = strlen(key);
        if (!strncmp(p->entries[i].key, key, n) && p->entries[i].key[n] == '#') earlier++;
    }
    char numbered[64];
    snprintf(numbered, sizeof numbered, "%s#%d", key, earlier);
    key = numbered;
    snprintf(p->entries[slot].key, sizeof p->entries[slot].key, "%s", key);
    p->entries[slot].count = count;
}

// ---- aggregation
typedef struct Total {
    char key[64];
    double ns;
    uint64_t passes, count;
} Total;

static Total g_totals[PROFILE_LABELS];
static int g_total_count;
static uint64_t g_frames;
static double g_ns_per_tick;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_cpu0, g_gpu0;

static int compare_totals(const void *a, const void *b) {
    double d = ((const Total *)b)->ns - ((const Total *)a)->ns;
    return d > 0 ? 1 : d < 0 ? -1 : 0;
}

static void report(void) {
    qsort(g_totals, g_total_count, sizeof *g_totals, compare_totals);
    double all = 0;
    for (int i = 0; i < g_total_count; i++) all += g_totals[i].ns;
    D3D_LOG("profile: %.2f ms of encoders per frame, %d frames", all / 1e6 / g_frames, (int)g_frames);
    for (int i = 0; i < g_total_count && i < 14; i++)
        D3D_LOG("  %5.2f ms %4.1f%%  %5.1f passes %7.1f draws  %s", g_totals[i].ns / 1e6 / g_frames,
                100 * g_totals[i].ns / all, (double)g_totals[i].passes / g_frames, (double)g_totals[i].count / g_frames,
                g_totals[i].key);
    g_total_count = 0;
    g_frames = 0;
}

void profile_finish(Profile *p, id<MTLCommandBuffer> cb) {
    if (!p) return;
    g_building = NULL;
    g_building_owner = nil;
    if (!g_cpu0) {
        MTLTimestamp cpu, gpu;
        [p->device sampleTimestamps:&cpu gpuTimestamp:&gpu];
        g_cpu0 = cpu;
        g_gpu0 = gpu;
    }
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
      NSData *data = [p->samples resolveCounterRange:NSMakeRange(0, 2 * p->used)];
      const MTLCounterResultTimestamp *t = data.bytes;
      pthread_mutex_lock(&g_lock);
      if (g_ns_per_tick == 0) { // GPU ticks to nanoseconds, from the clocks' relative rates
          MTLTimestamp cpu, gpu;
          [p->device sampleTimestamps:&cpu gpuTimestamp:&gpu];
          mach_timebase_info_data_t tb;
          mach_timebase_info(&tb);
          if (gpu > g_gpu0 + 1000000 && cpu > g_cpu0)
              g_ns_per_tick = (double)(cpu - g_cpu0) * tb.numer / tb.denom / (double)(gpu - g_gpu0);
      }
      if (g_ns_per_tick > 0) {
          for (uint32_t i = 0; i < p->used; i++) {
              uint64_t a = t[2 * i].timestamp, b = t[2 * i + 1].timestamp;
              if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || b < a) continue;
              Total *total = NULL;
              for (int k = 0; k < g_total_count; k++)
                  if (!strcmp(g_totals[k].key, p->entries[i].key)) total = &g_totals[k];
              if (!total && g_total_count < PROFILE_LABELS) {
                  total = &g_totals[g_total_count++];
                  memset(total, 0, sizeof *total);
                  snprintf(total->key, sizeof total->key, "%s", p->entries[i].key);
              }
              if (!total) continue;
              total->ns += (double)(b - a) * g_ns_per_tick;
              total->passes++;
              total->count += p->entries[i].count;
          }
          if (++g_frames == PROFILE_REPORT_EVERY) report();
      }
      pthread_mutex_unlock(&g_lock);
      [p->samples release];
      free(p);
    }];
}

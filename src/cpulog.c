// LOADER_CPU_LOG=1: once a second, logs CPU time as the kernel accounts it: the whole process per frame, and
// the busiest threads. Our own timers would miss work in Metal's and the game's threads, and would add cost.
#include "shim.h"
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

#define MAX_TRACKED_THREADS 256
#define REPORTED_THREADS    14

static _Atomic uint64_t g_frames;
static mach_port_t g_main_thread;

static _Atomic uint64_t g_submits;

void cpu_log_frame(void) { atomic_fetch_add_explicit(&g_frames, 1, memory_order_relaxed); }
void cpu_log_submit(void) { atomic_fetch_add_explicit(&g_submits, 1, memory_order_relaxed); }

typedef struct {
    uint64_t id;
    double seconds, kernel_seconds; // CPU time at the previous report
} ThreadTotal;

static double timeval_seconds(struct timeval t) { return t.tv_sec + t.tv_usec / 1e6; }

typedef struct {
    double delta, kernel_delta;
    uint64_t id;
    char name[64];
} ThreadDelta;

static int by_delta(const void *a, const void *b) {
    double d = ((const ThreadDelta *)b)->delta - ((const ThreadDelta *)a)->delta;
    return d > 0 ? 1 : d < 0 ? -1 : 0;
}

static void *cpu_log_thread(void *arg) {
    static ThreadTotal totals[MAX_TRACKED_THREADS];
    int total_count = 0;
    struct rusage previous;
    getrusage(RUSAGE_SELF, &previous);
    uint64_t previous_frames = atomic_load(&g_frames), previous_submits = atomic_load(&g_submits);
    double previous_wall = log_time();
    for (;;) {
        sleep(1);
        struct rusage now;
        getrusage(RUSAGE_SELF, &now);
        uint64_t frames = atomic_load(&g_frames), submits = atomic_load(&g_submits);
        double wall = log_time();
        double cpu = timeval_seconds(now.ru_utime) + timeval_seconds(now.ru_stime) -
                     timeval_seconds(previous.ru_utime) - timeval_seconds(previous.ru_stime);
        uint64_t frame_count = frames - previous_frames;

        thread_act_array_t threads;
        mach_msg_type_number_t count;
        ThreadDelta deltas[MAX_TRACKED_THREADS];
        int delta_count = 0;
        if (task_threads(mach_task_self(), &threads, &count) == KERN_SUCCESS) {
            for (mach_msg_type_number_t i = 0; i < count; i++) {
                thread_extended_info_data_t ext;
                mach_msg_type_number_t ext_count = THREAD_EXTENDED_INFO_COUNT;
                thread_identifier_info_data_t ident;
                mach_msg_type_number_t ident_count = THREAD_IDENTIFIER_INFO_COUNT;
                if (thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&ext, &ext_count) == KERN_SUCCESS &&
                    thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &ident_count) ==
                        KERN_SUCCESS) {
                    double seconds = (ext.pth_user_time + ext.pth_system_time) / 1e9;
                    double kernel_seconds = ext.pth_system_time / 1e9;
                    ThreadTotal *t = NULL;
                    for (int k = 0; k < total_count; k++)
                        if (totals[k].id == ident.thread_id) t = &totals[k];
                    if (!t && total_count < MAX_TRACKED_THREADS) {
                        t = &totals[total_count++];
                        t->id = ident.thread_id;
                        t->seconds = seconds;
                        t->kernel_seconds = kernel_seconds;
                    }
                    if (t && delta_count < MAX_TRACKED_THREADS) {
                        ThreadDelta *d = &deltas[delta_count++];
                        d->delta = seconds - t->seconds;
                        d->kernel_delta = kernel_seconds - t->kernel_seconds;
                        d->id = ident.thread_id;
                        snprintf(d->name, sizeof d->name, "%s",
                                 threads[i] == g_main_thread ? "main"
                                 : ext.pth_name[0]           ? ext.pth_name
                                                             : "unnamed");
                        t->seconds = seconds;
                        t->kernel_seconds = kernel_seconds;
                    }
                }
                mach_port_deallocate(mach_task_self(), threads[i]);
            }
            vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof *threads);
        }
        qsort(deltas, delta_count, sizeof *deltas, by_delta);
        char line[2048];
        double sys = timeval_seconds(now.ru_stime) - timeval_seconds(previous.ru_stime);
        int n = snprintf(
            line, sizeof line,
            "cpu: %.1f%% of a core (%.1f%% kernel), %llu frames, %.2f ms per frame, %llu submits, %u threads |",
            100 * cpu / (wall - previous_wall), 100 * sys / (wall - previous_wall), (unsigned long long)frame_count,
            frame_count ? 1000 * cpu / frame_count : 0, (unsigned long long)(submits - previous_submits),
            (unsigned)count);
        for (int i = 0; i < delta_count && i < REPORTED_THREADS; i++)
            n += snprintf(line + n, sizeof line - n, " [%s %.1f%% k%.1f]", deltas[i].name,
                          100 * deltas[i].delta / (wall - previous_wall),
                          100 * deltas[i].kernel_delta / (wall - previous_wall));
        LOG("%s", line);
        previous = now;
        previous_frames = frames;
        previous_submits = submits;
        previous_wall = wall;
    }
    return arg;
}

void cpu_log_start(void) {
    if (!getenv("LOADER_CPU_LOG")) return;
    g_main_thread = mach_thread_self();
    pthread_t thread;
    pthread_create(&thread, NULL, cpu_log_thread, NULL);
    pthread_detach(thread);
}

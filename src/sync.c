// kernel32 synchronization: threads, events, semaphores, waits, critical sections and APCs.
//
// One global mutex and condition variable guard every waitable object we create. That keeps
// WaitForMultipleObjects simple and correct, and the game waits rarely enough for it not to matter.
// Event handles created by D3DMetal are not ours; waits involving them poll (see wait_with_foreign).
#include "kernel32.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_changed = PTHREAD_COND_INITIALIZER;

typedef struct {
    bool manual_reset, signaled;
} Event;

typedef struct {
    LONG count, max;
} Semaphore;

typedef struct {
    pthread_t thread;
    WINAPI DWORD (*start)(void *);
    void *arg;
    bool suspended, finished;
    DWORD exit_code;
} Thread;

WHandle *handle_new(int type) {
    WHandle *h = calloc(1, sizeof *h);
    h->magic = WHANDLE_MAGIC;
    h->type = type;
    h->fd = -1;
    return h;
}

bool handle_is_ours(const void *h) {
    return h && (uintptr_t)h > 0x10000 && ((const WHandle *)h)->magic == WHANDLE_MAGIC;
}

// Must hold g_lock. `consume` takes the signal (auto-reset events, semaphores) when satisfied.
static bool is_signaled(WHandle *h, bool consume) {
    switch (h->type) {
    case H_EVENT: {
        Event *e = h->obj;
        if (!e->signaled) return false;
        if (consume && !e->manual_reset) e->signaled = false;
        return true;
    }
    case H_SEMAPHORE: {
        Semaphore *s = h->obj;
        if (s->count <= 0) return false;
        if (consume) s->count--;
        return true;
    }
    case H_THREAD: return ((Thread *)h->obj)->finished;
    default: return true;
    }
}

// ---------------------------------------------------------------- APCs
typedef struct Apc {
    CompletionRoutine fn;
    DWORD error, bytes;
    OVERLAPPED *overlapped;
    struct Apc *next;
} Apc;

static __thread Apc *t_apcs;

void queue_apc(CompletionRoutine fn, DWORD error, DWORD bytes, OVERLAPPED *overlapped) {
    Apc *apc = calloc(1, sizeof *apc), **tail = &t_apcs;
    *apc = (Apc){fn, error, bytes, overlapped, NULL};
    while (*tail) tail = &(*tail)->next;
    *tail = apc;
}

bool run_apcs(void) {
    bool ran = false;
    while (t_apcs) {
        Apc *apc = t_apcs;
        t_apcs = apc->next;
        apc->fn(apc->error, apc->bytes, apc->overlapped);
        free(apc);
        ran = true;
    }
    return ran;
}

// ---------------------------------------------------------------- waits
static uint64_t now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000; }

// Waits that include D3DMetal event handles: poll every handle until satisfied or timed out.
static DWORD wait_with_foreign(DWORD count, WHandle **handles, bool wait_all, DWORD timeout_ms) {
    enum { MAX_OBJECTS = 64 }; // MAXIMUM_WAIT_OBJECTS
    bool done[MAX_OBJECTS] = {0};
    uint64_t start = now_ms();
    for (;;) {
        DWORD done_count = 0;
        for (DWORD i = 0; i < count && i < MAX_OBJECTS; i++) {
            if (done[i]) {
                done_count++;
                continue;
            }
            bool signaled;
            if (handle_is_ours(handles[i])) {
                pthread_mutex_lock(&g_lock);
                signaled = is_signaled(handles[i], true);
                pthread_mutex_unlock(&g_lock);
            } else { // a single foreign handle can block in dmn itself
                uint64_t ns = count > 1 ? 0 : timeout_ms == INFINITE ? UINT64_MAX : (uint64_t)timeout_ms * 1000000;
                signaled = g_dmn_ev.wait(handles[i], ns) == 0;
            }
            if (signaled) {
                if (!wait_all) return WAIT_OBJECT_0 + i;
                done[i] = true;
                done_count++;
            }
        }
        if (wait_all && done_count == count) return WAIT_OBJECT_0;
        if (timeout_ms != INFINITE && now_ms() - start >= timeout_ms) return WAIT_TIMEOUT;
        if (count > 1) usleep(200);
    }
}

static DWORD wait_for(DWORD count, WHandle **handles, bool wait_all, DWORD timeout_ms, bool alertable) {
    if (alertable && run_apcs()) return WAIT_IO_COMPLETION;
    for (DWORD i = 0; i < count; i++)
        if (!handle_is_ours(handles[i]) && g_dmn_ev.wait)
            return wait_with_foreign(count, handles, wait_all, timeout_ms);

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }

    DWORD result = WAIT_TIMEOUT;
    pthread_mutex_lock(&g_lock);
    for (;;) {
        if (wait_all) {
            bool all = true;
            for (DWORD i = 0; i < count; i++) all &= is_signaled(handles[i], false);
            if (all) {
                for (DWORD i = 0; i < count; i++) is_signaled(handles[i], true);
                result = WAIT_OBJECT_0;
                break;
            }
        } else {
            DWORD i = 0;
            while (i < count && !is_signaled(handles[i], true)) i++;
            if (i < count) {
                result = WAIT_OBJECT_0 + i;
                break;
            }
        }
        if (timeout_ms == 0) break;
        if (timeout_ms == INFINITE)
            pthread_cond_wait(&g_changed, &g_lock);
        else if (pthread_cond_timedwait(&g_changed, &g_lock, &deadline) == ETIMEDOUT)
            break;
    }
    pthread_mutex_unlock(&g_lock);
    return result;
}

SHIM(DWORD, WaitForSingleObject, WHandle *h, DWORD timeout_ms) { return wait_for(1, &h, false, timeout_ms, false); }

SHIM(DWORD, WaitForSingleObjectEx, WHandle *h, DWORD timeout_ms, WBOOL alertable) {
    return wait_for(1, &h, false, timeout_ms, alertable);
}

SHIM(DWORD, WaitForMultipleObjectsEx, DWORD count, WHandle **handles, WBOOL wait_all, DWORD timeout_ms,
     WBOOL alertable) {
    return wait_for(count, handles, wait_all, timeout_ms, alertable);
}

SHIM(void, Sleep, DWORD ms) { usleep(ms * 1000); }

SHIM(DWORD, SleepEx, DWORD ms, WBOOL alertable) {
    if (alertable && run_apcs()) return WAIT_IO_COMPLETION;
    usleep(ms * 1000);
    return 0;
}

// ---------------------------------------------------------------- events and semaphores
// While D3DMetal is active, events are dmn events, so D3DMetal can signal what the game waits on.
SHIM(HANDLE, CreateEventW, void *security, WBOOL manual_reset, WBOOL initial_state, const WCHAR *name) {
    if (g_dmn_ev.create) return g_dmn_ev.create(manual_reset, initial_state);
    WHandle *h = handle_new(H_EVENT);
    Event *e = calloc(1, sizeof *e);
    *e = (Event){manual_reset, initial_state};
    h->obj = e;
    return h;
}

static void set_event_state(WHandle *h, bool signaled) {
    pthread_mutex_lock(&g_lock);
    ((Event *)h->obj)->signaled = signaled;
    if (signaled) pthread_cond_broadcast(&g_changed);
    pthread_mutex_unlock(&g_lock);
}

SHIM(WBOOL, SetEvent, WHandle *h) {
    if (!handle_is_ours(h) && g_dmn_ev.signal)
        g_dmn_ev.signal(h);
    else
        set_event_state(h, true);
    return true;
}

SHIM(WBOOL, ResetEvent, WHandle *h) {
    if (!handle_is_ours(h) && g_dmn_ev.clear)
        g_dmn_ev.clear(h);
    else
        set_event_state(h, false);
    return true;
}

SHIM(HANDLE, CreateSemaphoreW, void *security, LONG initial, LONG max, const WCHAR *name) {
    WHandle *h = handle_new(H_SEMAPHORE);
    Semaphore *s = calloc(1, sizeof *s);
    *s = (Semaphore){initial, max};
    h->obj = s;
    return h;
}

SHIM(WBOOL, ReleaseSemaphore, WHandle *h, LONG release, LONG *previous) {
    pthread_mutex_lock(&g_lock);
    Semaphore *s = h->obj;
    if (previous) *previous = s->count;
    s->count += release;
    if (s->count > s->max) s->count = s->max;
    pthread_cond_broadcast(&g_changed);
    pthread_mutex_unlock(&g_lock);
    return true;
}

// ---------------------------------------------------------------- critical sections
// The first field (DebugInfo) holds a pointer to a recursive pthread mutex, created on first use.
static pthread_mutex_t *cs_mutex(CRITICAL_SECTION *cs) {
    if (!cs->DebugInfo) {
        pthread_mutex_t *m = malloc(sizeof *m);
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(m, &attr);
        if (!__sync_bool_compare_and_swap(&cs->DebugInfo, NULL, m)) { // another thread won
            pthread_mutex_destroy(m);
            free(m);
        }
    }
    return cs->DebugInfo;
}

SHIM(void, InitializeCriticalSection, CRITICAL_SECTION *cs) {
    memset(cs, 0, sizeof *cs);
    cs_mutex(cs);
}

SHIM(WBOOL, InitializeCriticalSectionAndSpinCount, CRITICAL_SECTION *cs, DWORD spin_count) {
    memset(cs, 0, sizeof *cs);
    cs_mutex(cs);
    return true;
}

SHIM(void, EnterCriticalSection, CRITICAL_SECTION *cs) { pthread_mutex_lock(cs_mutex(cs)); }
SHIM(void, LeaveCriticalSection, CRITICAL_SECTION *cs) { pthread_mutex_unlock(cs_mutex(cs)); }
SHIM(void, DeleteCriticalSection, CRITICAL_SECTION *cs) {}
SHIM(void, InitializeSListHead, void *head) { memset(head, 0, 16); } // SLIST_HEADER

// ---------------------------------------------------------------- threads
#define MIN_THREAD_STACK (8u << 20)

static void *thread_main(void *arg) {
    Thread *t = ((WHandle *)arg)->obj;
    teb_setup_current_thread();
    pthread_mutex_lock(&g_lock);
    while (t->suspended) pthread_cond_wait(&g_changed, &g_lock);
    pthread_mutex_unlock(&g_lock);

    DWORD exit_code = t->start(t->arg);

    pthread_mutex_lock(&g_lock);
    t->finished = true;
    t->exit_code = exit_code;
    pthread_cond_broadcast(&g_changed);
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

static WHandle *spawn_thread(size_t stack_size, void *start, void *arg, DWORD flags, DWORD *thread_id) {
    WHandle *h = handle_new(H_THREAD);
    Thread *t = calloc(1, sizeof *t);
    t->start = start;
    t->arg = arg;
    t->suspended = flags & CREATE_SUSPENDED;
    h->obj = t;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, stack_size > MIN_THREAD_STACK ? stack_size : MIN_THREAD_STACK);
    pthread_create(&t->thread, &attr, thread_main, h);
    if (thread_id) {
        uint64_t id;
        pthread_threadid_np(t->thread, &id);
        *thread_id = (DWORD)id;
    }
    return h;
}

SHIM(HANDLE, CreateThread, void *security, size_t stack_size, void *start, void *arg, DWORD flags, DWORD *thread_id) {
    return spawn_thread(stack_size, start, arg, flags, thread_id);
}

SHIM(uintptr_t, _beginthreadex, void *security, UINT stack_size, void *start, void *arg, UINT flags, UINT *thread_id) {
    return (uintptr_t)spawn_thread(stack_size, start, arg, flags, thread_id);
}

SHIM(DWORD, ResumeThread, WHandle *h) {
    if (!handle_is_ours(h) || h->type != H_THREAD) return 0;
    pthread_mutex_lock(&g_lock);
    Thread *t = h->obj;
    DWORD previous_suspend_count = t->suspended;
    t->suspended = false;
    pthread_cond_broadcast(&g_changed);
    pthread_mutex_unlock(&g_lock);
    return previous_suspend_count;
}

SHIM(WBOOL, SetThreadPriority, HANDLE thread, int priority) { return true; }

SHIM(uint64_t, SetThreadAffinityMask, HANDLE thread, uint64_t mask) {
    FIXME("SetThreadAffinityMask(%#llx): ignored", (unsigned long long)mask);
    return 1; // previous mask
}

SHIM(DWORD, GetCurrentThreadId, void) {
    uint64_t id;
    pthread_threadid_np(NULL, &id);
    return (DWORD)id;
}

SHIM(HANDLE, GetCurrentThread, void) { return (HANDLE)(intptr_t)-2; } // pseudo handle
SHIM(DWORD, GetLastError, void) { return teb_current()->last_error; }

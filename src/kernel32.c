// KERNEL32 shims: threads, sync, files, memory, time, system info.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>
#include "shim.h"

#define INVALID_HANDLE ((HANDLE)(intptr_t)-1)
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_PATH_NOT_FOUND 3
#define ERROR_NO_MORE_FILES 18
#define ERROR_INSUFFICIENT_BUFFER 122
#define ERROR_ALREADY_EXISTS 183
#define WAIT_OBJECT_0 0
#define WAIT_TIMEOUT 0x102
#define WAIT_IO_COMPLETION 0xC0
#define INFINITE 0xFFFFFFFFu

WHandle *handle_new(int type) {
    WHandle *h = calloc(1, sizeof *h);
    h->magic = WHANDLE_MAGIC;
    h->type = type;
    h->fd = -1;
    return h;
}

static void set_errno_error(void) {
    set_last_error(errno == ENOENT ? ERROR_FILE_NOT_FOUND : errno == ENOTDIR ? ERROR_PATH_NOT_FOUND
                   : errno == EEXIST ? ERROR_ALREADY_EXISTS : 5 /* ACCESS_DENIED */);
}

static char *wpath(const WCHAR *w) {
    char *u = w2u(w), *p = win_to_unix_path(u);
    free(u);
    return p;
}

// ---------------------------------------------------------------- sync objects
// One global lock + condvar for all waitable objects keeps multi-object waits simple.
static pthread_mutex_t g_sync = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_sync_cv = PTHREAD_COND_INITIALIZER;

typedef struct { bool manual, signaled; } Event;
typedef struct { long count, max; } Sema;
typedef struct Thread {
    pthread_t pt;
    WINAPI DWORD (*start)(void *);
    void *arg;
    bool suspended, done;
    DWORD exit_code;
} Thread;

static bool signaled_locked(WHandle *h, bool consume) {
    switch (h->type) {
    case H_EVENT: {
        Event *e = h->obj;
        if (!e->signaled) return false;
        if (consume && !e->manual) e->signaled = false;
        return true;
    }
    case H_SEMAPHORE: {
        Sema *s = h->obj;
        if (s->count <= 0) return false;
        if (consume) s->count--;
        return true;
    }
    case H_THREAD: return ((Thread *)h->obj)->done;
    default: return true;
    }
}

// ---- APCs (ReadFileEx/WriteFileEx completions)
typedef WINAPI void (*CompletionRoutine)(DWORD err, DWORD bytes, void *ovl);
typedef struct Apc { CompletionRoutine fn; DWORD err, bytes; void *ovl; struct Apc *next; } Apc;
static __thread Apc *t_apcs;

static int run_apcs(void) {
    int n = 0;
    while (t_apcs) {
        Apc *a = t_apcs;
        t_apcs = a->next;
        a->fn(a->err, a->bytes, a->ovl);
        free(a);
        n++;
    }
    return n;
}

// Waits involving dmn (D3DMetal) event handles: poll them alongside our own objects.
static DWORD wait_many_foreign(DWORD n, WHandle **hs, bool all, DWORD ms) {
    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    bool done[64] = {0};
    for (;;) {
        DWORD ndone = 0;
        for (DWORD i = 0; i < n && i < 64; i++) {
            if (done[i]) { ndone++; continue; }
            bool sig;
            if (handle_is_ours(hs[i])) {
                pthread_mutex_lock(&g_sync);
                sig = signaled_locked(hs[i], true);
                pthread_mutex_unlock(&g_sync);
            } else {
                sig = g_dmn_ev.wait(hs[i], n == 1 ? (ms == INFINITE ? UINT64_MAX : (uint64_t)ms * 1000000ull) : 0) == 0;
            }
            if (sig) {
                if (!all) return WAIT_OBJECT_0 + i;
                done[i] = true;
                ndone++;
            }
        }
        if (all && ndone == n) return WAIT_OBJECT_0;
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t el = (now.tv_sec - t0.tv_sec) * 1000 + (now.tv_nsec - t0.tv_nsec) / 1000000;
        if (ms != INFINITE && el >= ms) return WAIT_TIMEOUT;
        if (n > 1) usleep(200);
    }
}

static DWORD wait_many(DWORD n, WHandle **hs, bool all, DWORD ms, bool alertable) {
    TRACE("wait(n=%u, ms=%d, alertable=%d, apcs=%d, h0=%p ours=%d)", n, (int)ms, alertable, t_apcs != NULL, (void *)hs[0], handle_is_ours(hs[0]));
    if (alertable && run_apcs()) return WAIT_IO_COMPLETION;
    for (DWORD i = 0; i < n; i++)
        if (!handle_is_ours(hs[i]) && g_dmn_ev.wait) return wait_many_foreign(n, hs, all, ms);
    struct timespec dl;
    if (ms != INFINITE) {
        clock_gettime(CLOCK_REALTIME, &dl);
        dl.tv_sec += ms / 1000;
        dl.tv_nsec += (ms % 1000) * 1000000L;
        if (dl.tv_nsec >= 1000000000L) { dl.tv_sec++; dl.tv_nsec -= 1000000000L; }
    }
    pthread_mutex_lock(&g_sync);
    for (;;) {
        if (all) {
            bool ok = true;
            for (DWORD i = 0; i < n; i++) ok &= signaled_locked(hs[i], false);
            if (ok) {
                for (DWORD i = 0; i < n; i++) signaled_locked(hs[i], true);
                pthread_mutex_unlock(&g_sync);
                return WAIT_OBJECT_0;
            }
        } else {
            for (DWORD i = 0; i < n; i++)
                if (signaled_locked(hs[i], true)) { pthread_mutex_unlock(&g_sync); return WAIT_OBJECT_0 + i; }
        }
        if (ms == 0) break;
        if (ms == INFINITE) pthread_cond_wait(&g_sync_cv, &g_sync);
        else if (pthread_cond_timedwait(&g_sync_cv, &g_sync, &dl) == ETIMEDOUT) break;
    }
    pthread_mutex_unlock(&g_sync);
    return WAIT_TIMEOUT;
}

SHIM(HANDLE, CreateEventW, void *sa, WBOOL manual, WBOOL initial, const WCHAR *name) {
    (void)sa; (void)name;
    if (g_dmn_ev.create) return g_dmn_ev.create(manual, initial);
    WHandle *h = handle_new(H_EVENT);
    Event *e = calloc(1, sizeof *e);
    e->manual = manual; e->signaled = initial;
    h->obj = e;
    return h;
}
SHIM(WBOOL, SetEvent, WHandle *h) {
    if (!handle_is_ours(h) && g_dmn_ev.signal) { g_dmn_ev.signal(h); return 1; }
    pthread_mutex_lock(&g_sync);
    ((Event *)h->obj)->signaled = true;
    pthread_cond_broadcast(&g_sync_cv);
    pthread_mutex_unlock(&g_sync);
    return 1;
}
SHIM(WBOOL, ResetEvent, WHandle *h) {
    if (!handle_is_ours(h) && g_dmn_ev.clear) { g_dmn_ev.clear(h); return 1; }
    pthread_mutex_lock(&g_sync);
    ((Event *)h->obj)->signaled = false;
    pthread_mutex_unlock(&g_sync);
    return 1;
}
SHIM(HANDLE, CreateSemaphoreW, void *sa, long initial, long max, const WCHAR *name) {
    (void)sa; (void)name;
    WHandle *h = handle_new(H_SEMAPHORE);
    Sema *s = calloc(1, sizeof *s);
    s->count = initial; s->max = max;
    h->obj = s;
    return h;
}
SHIM(WBOOL, ReleaseSemaphore, WHandle *h, long n, long *prev) {
    pthread_mutex_lock(&g_sync);
    Sema *s = h->obj;
    if (prev) *prev = s->count;
    s->count += n;
    if (s->count > s->max) s->count = s->max;
    pthread_cond_broadcast(&g_sync_cv);
    pthread_mutex_unlock(&g_sync);
    return 1;
}
SHIM(DWORD, WaitForSingleObject, WHandle *h, DWORD ms) { return wait_many(1, &h, false, ms, false); }
SHIM(DWORD, WaitForSingleObjectEx, WHandle *h, DWORD ms, WBOOL alertable) { return wait_many(1, &h, false, ms, alertable); }
SHIM(DWORD, WaitForMultipleObjectsEx, DWORD n, WHandle **hs, WBOOL all, DWORD ms, WBOOL alertable) {
    return wait_many(n, hs, all, ms, alertable);
}
SHIM(void, Sleep, DWORD ms) { usleep(ms * 1000); }
SHIM(DWORD, SleepEx, DWORD ms, WBOOL alertable) {
    if (alertable && run_apcs()) return WAIT_IO_COMPLETION;
    usleep(ms * 1000);
    return 0;
}

// ---- critical sections: pointer to a recursive pthread mutex lives in the first field
static pthread_mutex_t *cs_mutex(void **cs) {
    if (!*cs) {
        pthread_mutex_t *m = malloc(sizeof *m);
        pthread_mutexattr_t a;
        pthread_mutexattr_init(&a);
        pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(m, &a);
        if (!__sync_bool_compare_and_swap(cs, NULL, m)) { pthread_mutex_destroy(m); free(m); }
    }
    return *cs;
}
SHIM(void, InitializeCriticalSection, void **cs) { memset(cs, 0, 40); cs_mutex(cs); }
SHIM(WBOOL, InitializeCriticalSectionAndSpinCount, void **cs, DWORD spin) { (void)spin; memset(cs, 0, 40); cs_mutex(cs); return 1; }
SHIM(void, EnterCriticalSection, void **cs) { pthread_mutex_lock(cs_mutex(cs)); }
SHIM(void, LeaveCriticalSection, void **cs) { pthread_mutex_unlock(cs_mutex(cs)); }
SHIM(void, DeleteCriticalSection, void **cs) { (void)cs; }
SHIM(void, InitializeSListHead, void *h) { memset(h, 0, 16); }

// ---- threads
static void *thread_main(void *p) {
    WHandle *h = p;
    Thread *t = h->obj;
    teb_setup_current_thread();
    pthread_mutex_lock(&g_sync);
    while (t->suspended) pthread_cond_wait(&g_sync_cv, &g_sync);
    pthread_mutex_unlock(&g_sync);
    DWORD rc = t->start(t->arg);
    pthread_mutex_lock(&g_sync);
    t->done = true; t->exit_code = rc;
    pthread_cond_broadcast(&g_sync_cv);
    pthread_mutex_unlock(&g_sync);
    return NULL;
}
static WHandle *spawn(size_t stack, void *start, void *arg, DWORD flags, DWORD *tid) {
    WHandle *h = handle_new(H_THREAD);
    Thread *t = calloc(1, sizeof *t);
    t->start = start; t->arg = arg; t->suspended = flags & 4;
    h->obj = t;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, stack > (8u << 20) ? stack : (8u << 20));
    pthread_create(&t->pt, &a, thread_main, h);
    if (tid) { uint64_t id; pthread_threadid_np(t->pt, &id); *tid = (DWORD)id; }
    TRACE("thread %p start=%p", (void *)h, start);
    return h;
}
SHIM(HANDLE, CreateThread, void *sa, size_t stack, void *start, void *arg, DWORD flags, DWORD *tid) {
    (void)sa; return spawn(stack, start, arg, flags, tid);
}
SHIM(uintptr_t, _beginthreadex, void *sa, unsigned stack, void *start, void *arg, unsigned flags, unsigned *tid) {
    (void)sa; return (uintptr_t)spawn(stack, start, arg, flags, (DWORD *)tid);
}
SHIM(DWORD, ResumeThread, WHandle *h) {
    if ((intptr_t)h < 0 || h->type != H_THREAD) return 0;
    pthread_mutex_lock(&g_sync);
    Thread *t = h->obj;
    DWORD was = t->suspended;
    t->suspended = false;
    pthread_cond_broadcast(&g_sync_cv);
    pthread_mutex_unlock(&g_sync);
    return was;
}
SHIM(WBOOL, SetThreadPriority, HANDLE h, int p) { (void)h; (void)p; return 1; }
SHIM(uint64_t, SetThreadAffinityMask, HANDLE h, uint64_t m) { FIXME("SetThreadAffinityMask(%#llx)", (unsigned long long)m); (void)h; (void)m; return 1; }
SHIM(WBOOL, SetProcessInformation, HANDLE h, int c, void *i, DWORD s) { FIXME("SetProcessInformation(class=%d)", c); (void)h; (void)c; (void)i; (void)s; return 1; }
SHIM(HANDLE, GetCurrentProcess, void) { return (HANDLE)(intptr_t)-1; }
SHIM(HANDLE, GetCurrentThread, void) { return (HANDLE)(intptr_t)-2; }
SHIM(DWORD, GetCurrentProcessId, void) { return getpid(); }
SHIM(DWORD, GetCurrentThreadId, void) { uint64_t id; pthread_threadid_np(NULL, &id); return (DWORD)id; }
SHIM(DWORD, GetLastError, void) { return teb_current()->last_error; }

static int ncpu(void) { int n = 1; size_t l = sizeof n; sysctlbyname("hw.logicalcpu", &n, &l, NULL, 0); return n; }

SHIM(WBOOL, GetProcessAffinityMask, HANDLE h, uint64_t *pm, uint64_t *sm) {
    (void)h;
    uint64_t m = ncpu() >= 64 ? ~0ull : (1ull << ncpu()) - 1;
    *pm = m; *sm = m; return 1;
}

// ---------------------------------------------------------------- files
static WHandle g_std[3] = {{WHANDLE_MAGIC, H_FILE, 0, 0}, {WHANDLE_MAGIC, H_FILE, 1, 0}, {WHANDLE_MAGIC, H_FILE, 2, 0}};

bool handle_is_ours(const void *h) {
    return h && (intptr_t)h > 0x10000 && ((const WHandle *)h)->magic == WHANDLE_MAGIC;
}
SHIM(HANDLE, GetStdHandle, DWORD which) {
    int i = -(int)which - 10;
    return i >= 0 && i < 3 ? &g_std[i] : INVALID_HANDLE;
}
SHIM(WBOOL, GetConsoleMode, HANDLE h, DWORD *m) { FIXME("GetConsoleMode"); (void)h; (void)m; return 0; }
SHIM(WBOOL, SetConsoleMode, HANDLE h, DWORD m) { (void)h; (void)m; return 1; }
SHIM(WBOOL, SetConsoleOutputCP, unsigned cp) { (void)cp; return 1; }

static HANDLE open_file(char *p, DWORD access, DWORD disp) {
    int fl = (access & 0x40000000) ? ((access & 0x80000000) ? O_RDWR : O_WRONLY) : O_RDONLY;
    switch (disp) {
    case 1: fl |= O_CREAT | O_EXCL; break;
    case 2: fl |= O_CREAT | O_TRUNC; break;
    case 4: fl |= O_CREAT; break;
    case 5: fl |= O_TRUNC; break;
    }
    int fd = open(p, fl, 0644);
    TRACE("CreateFile(%s, %#x, %u) -> %d", p, access, disp, fd);
    if (fd < 0) { set_errno_error(); free(p); return INVALID_HANDLE; }
    struct stat st;
    if (!fstat(fd, &st) && S_ISDIR(st.st_mode) && disp != 3) { close(fd); free(p); set_last_error(5); return INVALID_HANDLE; }
    WHandle *h = handle_new(H_FILE);
    h->fd = fd;
    h->obj = p;
    set_last_error(0);
    return h;
}
SHIM(HANDLE, CreateFileW, const WCHAR *n, DWORD acc, DWORD share, void *sa, DWORD disp, DWORD fl, HANDLE t) {
    (void)share; (void)sa; (void)fl; (void)t;
    return open_file(wpath(n), acc, disp);
}
SHIM(HANDLE, CreateFileA, const char *n, DWORD acc, DWORD share, void *sa, DWORD disp, DWORD fl, HANDLE t) {
    (void)share; (void)sa; (void)fl; (void)t;
    return open_file(win_to_unix_path(n), acc, disp);
}
// x64 OVERLAPPED: Internal +0, InternalHigh +8, Offset +16, OffsetHigh +20, hEvent +24
static int64_t ovl_offset(void *ovl) { return (int64_t)((uint64_t)*(uint32_t *)((char *)ovl + 20) << 32 | *(uint32_t *)((char *)ovl + 16)); }
SHIM(WBOOL, ReadFile, WHandle *h, void *buf, DWORD n, DWORD *got, void *ovl) {
    ssize_t r = ovl ? pread(h->fd, buf, n, ovl_offset(ovl)) : read(h->fd, buf, n);
    TRACE("ReadFile(fd=%d, n=%u, ovl=%p) -> %zd", h->fd, n, ovl, r);
    if (r < 0) { set_errno_error(); return 0; }
    if (got) *got = (DWORD)r;
    if (ovl) { ((uint64_t *)ovl)[0] = 0; ((uint64_t *)ovl)[1] = (uint64_t)r; }
    return 1;
}
// Console output gets the same "seconds since launch" prefix as loader logs, at each line start.
static void console_write(int fd, const char *buf, DWORD n) {
    static bool at_line_start[3] = {true, true, true};
    for (DWORD i = 0; i < n;) {
        if (at_line_start[fd]) { dprintf(fd, "%8.3f ", log_time()); at_line_start[fd] = false; }
        const char *nl = memchr(buf + i, '\n', n - i);
        DWORD len = nl ? (DWORD)(nl - (buf + i)) + 1 : n - i;
        write(fd, buf + i, len);
        if (nl) at_line_start[fd] = true;
        i += len;
    }
}

SHIM(WBOOL, WriteFile, WHandle *h, const void *buf, DWORD n, DWORD *put, void *ovl) {
    if (h >= g_std && h < g_std + 3 && h->fd > 0) { console_write(h->fd, buf, n); if (put) *put = n; return 1; }
    ssize_t r = ovl ? pwrite(h->fd, buf, n, ovl_offset(ovl)) : write(h->fd, buf, n);
    if (r < 0) { set_errno_error(); return 0; }
    if (put) *put = (DWORD)r;
    return 1;
}
static void queue_apc(CompletionRoutine fn, DWORD err, DWORD bytes, void *ovl) {
    Apc *a = calloc(1, sizeof *a), **p = &t_apcs;
    *a = (Apc){fn, err, bytes, ovl, NULL};
    while (*p) p = &(*p)->next;
    *p = a;
}
SHIM(WBOOL, ReadFileEx, WHandle *h, void *buf, DWORD n, void *ovl, CompletionRoutine fn) {
    ssize_t r = pread(h->fd, buf, n, ovl_offset(ovl));
    TRACE("ReadFileEx(fd=%d, n=%u, off=%lld) -> %zd", h->fd, n, (long long)ovl_offset(ovl), r);
    if (r < 0) { set_errno_error(); return 0; }
    ((uint64_t *)ovl)[0] = 0;            // Internal = STATUS_SUCCESS
    ((uint64_t *)ovl)[1] = (uint64_t)r;  // InternalHigh = bytes
    queue_apc(fn, 0, (DWORD)r, ovl);
    return 1;
}
SHIM(WBOOL, WriteFileEx, WHandle *h, const void *buf, DWORD n, void *ovl, CompletionRoutine fn) {
    ssize_t r = pwrite(h->fd, buf, n, ovl_offset(ovl));
    if (r < 0) { set_errno_error(); return 0; }
    ((uint64_t *)ovl)[0] = 0;
    ((uint64_t *)ovl)[1] = (uint64_t)r;
    queue_apc(fn, 0, (DWORD)r, ovl);
    return 1;
}
SHIM(WBOOL, FlushFileBuffers, WHandle *h) { fsync(h->fd); return 1; }
SHIM(DWORD, GetFileSize, WHandle *h, DWORD *hi) {
    struct stat st; fstat(h->fd, &st);
    if (hi) *hi = (DWORD)(st.st_size >> 32);
    return (DWORD)st.st_size;
}
SHIM(WBOOL, GetFileSizeEx, WHandle *h, int64_t *sz) {
    struct stat st;
    if (fstat(h->fd, &st)) { set_errno_error(); return 0; }
    *sz = st.st_size; return 1;
}
SHIM(WBOOL, SetFilePointerEx, WHandle *h, int64_t d, int64_t *np, DWORD how) {
    off_t r = lseek(h->fd, d, how == 0 ? SEEK_SET : how == 1 ? SEEK_CUR : SEEK_END);
    if (r < 0) { set_errno_error(); return 0; }
    if (np) *np = r;
    return 1;
}
static uint64_t ts_to_filetime(struct timespec t) {
    return (uint64_t)t.tv_sec * 10000000ull + t.tv_nsec / 100 + 116444736000000000ull;
}
SHIM(WBOOL, GetFileTime, WHandle *h, uint64_t *c, uint64_t *a, uint64_t *w) {
    struct stat st;
    if (fstat(h->fd, &st)) return 0;
    if (c) *c = ts_to_filetime(st.st_birthtimespec);
    if (a) *a = ts_to_filetime(st.st_atimespec);
    if (w) *w = ts_to_filetime(st.st_mtimespec);
    return 1;
}
SHIM(WBOOL, FileTimeToLocalFileTime, const uint64_t *in, uint64_t *out) {
    time_t now = time(NULL); struct tm lt; localtime_r(&now, &lt);
    *out = *in + (int64_t)lt.tm_gmtoff * 10000000ll; return 1;
}
SHIM(WBOOL, FileTimeToSystemTime, const uint64_t *ft, uint16_t *st) {
    uint64_t v = *ft - 116444736000000000ull;
    time_t s = v / 10000000ull; struct tm t; gmtime_r(&s, &t);
    st[0] = t.tm_year + 1900; st[1] = t.tm_mon + 1; st[2] = t.tm_wday; st[3] = t.tm_mday;
    st[4] = t.tm_hour; st[5] = t.tm_min; st[6] = t.tm_sec; st[7] = (v / 10000) % 1000;
    return 1;
}
SHIM(DWORD, GetFileAttributesW, const WCHAR *n) {
    char *p = wpath(n);
    struct stat st;
    int r = stat(p, &st);
    free(p);
    if (r) { set_errno_error(); return 0xFFFFFFFF; }
    return S_ISDIR(st.st_mode) ? 0x10 : 0x80;
}
SHIM(WBOOL, CreateDirectoryW, const WCHAR *n, void *sa) {
    (void)sa;
    char *p = wpath(n);
    int r = mkdir(p, 0755);
    free(p);
    if (r) { set_errno_error(); return 0; }
    return 1;
}
SHIM(WBOOL, DeleteFileW, const WCHAR *n) { char *p = wpath(n); int r = unlink(p); free(p); if (r) set_errno_error(); return !r; }
SHIM(WBOOL, MoveFileW, const WCHAR *a, const WCHAR *b) {
    char *p = wpath(a), *q = wpath(b); int r = rename(p, q); free(p); free(q); if (r) set_errno_error(); return !r;
}
SHIM(WBOOL, ReplaceFileW, const WCHAR *replaced, const WCHAR *replacement, const WCHAR *backup, DWORD f, void *e1, void *e2) {
    (void)backup; (void)f; (void)e1; (void)e2;
    char *p = wpath(replaced), *q = wpath(replacement); int r = rename(q, p); free(p); free(q); if (r) set_errno_error(); return !r;
}
SHIM(WBOOL, SetCurrentDirectoryW, const WCHAR *n) { char *p = wpath(n); int r = chdir(p); free(p); return !r; }

static DWORD put_wpath(const char *unix_abs, WCHAR *buf, DWORD n) {
    char tmp[PATH_MAX + 4];
    snprintf(tmp, sizeof tmp, "Z:%s", unix_abs);
    for (char *c = tmp; *c; c++) if (*c == '/') *c = '\\';
    WCHAR *w = u2w(tmp);
    DWORD l = (DWORD)wlen(w);
    if (l + 1 > n) { free(w); return l + 1; }
    memcpy(buf, w, (l + 1) * 2);
    free(w);
    return l;
}
SHIM(DWORD, GetFullPathNameW, const WCHAR *name, DWORD n, WCHAR *buf, WCHAR **filepart) {
    char *u = w2u(name);
    char abs[PATH_MAX * 2];
    if (u[0] && u[1] == ':') { char *p = win_to_unix_path(u); snprintf(abs, sizeof abs, "%s", p); free(p); }
    else if (u[0] == '\\' || u[0] == '/') { char *p = win_to_unix_path(u); snprintf(abs, sizeof abs, "%s", p); free(p); }
    else { char cwd[PATH_MAX]; getcwd(cwd, sizeof cwd); char *p = win_to_unix_path(u); snprintf(abs, sizeof abs, "%s/%s", cwd, p); free(p); }
    free(u);
    DWORD r = put_wpath(abs, buf, n);
    if (filepart && r < n) {
        *filepart = NULL;
        for (WCHAR *c = buf; *c; c++) if (*c == '\\') *filepart = c + 1;
    }
    return r;
}

// ---- FindFirstFile
typedef struct { DIR *d; char dir[PATH_MAX]; char pat[256]; } Find;
static bool find_fill(Find *f, uint8_t *fd) {
    struct dirent *e;
    while ((e = readdir(f->d))) {
        if (fnmatch(f->pat, e->d_name, FNM_CASEFOLD)) continue;
        char full[PATH_MAX * 2];
        snprintf(full, sizeof full, "%s/%s", f->dir, e->d_name);
        struct stat st;
        stat(full, &st);
        memset(fd, 0, 592);
        *(uint32_t *)fd = S_ISDIR(st.st_mode) ? 0x10 : 0x80;
        *(uint64_t *)(fd + 4) = ts_to_filetime(st.st_birthtimespec);
        *(uint64_t *)(fd + 12) = ts_to_filetime(st.st_atimespec);
        *(uint64_t *)(fd + 20) = ts_to_filetime(st.st_mtimespec);
        *(uint32_t *)(fd + 28) = (uint32_t)(st.st_size >> 32);
        *(uint32_t *)(fd + 32) = (uint32_t)st.st_size;
        WCHAR *w = u2w(e->d_name);
        size_t l = wlen(w); if (l > 259) l = 259;
        memcpy(fd + 44, w, l * 2);
        free(w);
        return true;
    }
    return false;
}
SHIM(HANDLE, FindFirstFileExW, const WCHAR *name, int lvl, uint8_t *fd, int op, void *filt, DWORD fl) {
    (void)lvl; (void)op; (void)filt; (void)fl;
    char *p = wpath(name);
    Find *f = calloc(1, sizeof *f);
    char *slash = strrchr(p, '/');
    if (slash) { *slash = 0; snprintf(f->dir, sizeof f->dir, "%s", *p ? p : "/"); snprintf(f->pat, sizeof f->pat, "%s", slash + 1); }
    else { strcpy(f->dir, "."); snprintf(f->pat, sizeof f->pat, "%s", p); }
    if (!strcmp(f->pat, "*.*")) strcpy(f->pat, "*");
    free(p);
    f->d = opendir(f->dir);
    TRACE("FindFirstFile %s / %s -> %p", f->dir, f->pat, (void *)f->d);
    if (!f->d || !find_fill(f, fd)) {
        if (f->d) closedir(f->d);
        free(f);
        set_last_error(ERROR_FILE_NOT_FOUND);
        return INVALID_HANDLE;
    }
    WHandle *h = handle_new(H_FIND);
    h->obj = f;
    return h;
}
SHIM(WBOOL, FindNextFileW, WHandle *h, uint8_t *fd) {
    if (find_fill(h->obj, fd)) return 1;
    set_last_error(ERROR_NO_MORE_FILES);
    return 0;
}
SHIM(WBOOL, FindClose, WHandle *h) { closedir(((Find *)h->obj)->d); free(h->obj); free(h); return 1; }

SHIM(WBOOL, CloseHandle, WHandle *h) {
    if (!h || (intptr_t)h < 0) return 1;
    if (h >= g_std && h < g_std + 3) return 1;
    if (!handle_is_ours(h)) { if (g_dmn_ev.close) g_dmn_ev.close(h); return 1; }
    if (h->type == H_FILE && h->fd >= 0) { close(h->fd); free(h->obj); }
    if (h->type == H_THREAD) return 1;  // threads may still reference their handle
    free(h);
    return 1;
}

// ---- file mapping
typedef struct { int fd; uint64_t size; } Mapping;
static HANDLE create_mapping(WHandle *file, DWORD hi, DWORD lo) {
    WHandle *h = handle_new(H_MAPPING);
    Mapping *m = calloc(1, sizeof *m);
    m->size = (uint64_t)hi << 32 | lo;
    if ((intptr_t)file == -1) m->fd = -1;
    else {
        m->fd = dup(file->fd);
        if (!m->size) { struct stat st; fstat(m->fd, &st); m->size = st.st_size; }
    }
    h->obj = m;
    return h;
}
SHIM(HANDLE, CreateFileMappingW, WHandle *f, void *sa, DWORD prot, DWORD hi, DWORD lo, const WCHAR *n) {
    (void)sa; (void)prot; (void)n; return create_mapping(f, hi, lo);
}
SHIM(HANDLE, CreateFileMappingA, WHandle *f, void *sa, DWORD prot, DWORD hi, DWORD lo, const char *n) {
    (void)sa; (void)prot; (void)n; return create_mapping(f, hi, lo);
}
SHIM(void *, MapViewOfFile, WHandle *h, DWORD acc, DWORD hi, DWORD lo, size_t n) {
    Mapping *m = h->obj;
    uint64_t off = (uint64_t)hi << 32 | lo;
    if (!n) n = m->size - off;
    bool wr = acc & 2;
    void *p = m->fd < 0 ? mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0)
                        : mmap(NULL, n, PROT_READ | (wr ? PROT_WRITE : 0), wr ? MAP_SHARED : MAP_PRIVATE, m->fd, off);
    return p == MAP_FAILED ? NULL : p;
}
SHIM(WBOOL, UnmapViewOfFile, void *p) { FIXME("UnmapViewOfFile(%p): leaked", p); (void)p; return 1; }  // size unknown; leak for now

// ---------------------------------------------------------------- memory
typedef struct Region { uint8_t *p; size_t n; struct Region *next; } Region;
static Region *g_regions;
static pthread_mutex_t g_regions_lock = PTHREAD_MUTEX_INITIALIZER;

SHIM(void *, VirtualAlloc, void *addr, size_t n, DWORD type, DWORD prot) {
    (void)prot;
    if (addr && !(type & 0x2000)) return addr;  // commit inside an existing reservation
    // Windows reservations are 64 KiB aligned (allocation granularity); allocators rely on it.
    const size_t G = 0x10000;
    n = (n + 0xfff) & ~(size_t)0xfff;
    int pr = PROT_READ | PROT_WRITE | ((prot & 0xF0) ? PROT_EXEC : 0);
    uint8_t *raw = mmap(addr, n + G, pr, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (raw == MAP_FAILED) { set_last_error(8); return NULL; }
    uint8_t *p = (uint8_t *)(((uintptr_t)raw + G - 1) & ~(G - 1));
    if (p > raw) munmap(raw, p - raw);
    if (raw + n + G > p + n) munmap(p + n, raw + n + G - (p + n));
    Region *r = malloc(sizeof *r);
    pthread_mutex_lock(&g_regions_lock);
    *r = (Region){p, n, g_regions};
    g_regions = r;
    pthread_mutex_unlock(&g_regions_lock);
    return p;
}
SHIM(WBOOL, VirtualFree, void *p, size_t n, DWORD type) {
    if (!(type & 0x8000)) { madvise(p, n, MADV_FREE); return 1; }  // decommit
    pthread_mutex_lock(&g_regions_lock);
    for (Region **r = &g_regions; *r; r = &(*r)->next)
        if ((*r)->p == p) { Region *d = *r; munmap(d->p, d->n); *r = d->next; free(d); break; }
    pthread_mutex_unlock(&g_regions_lock);
    return 1;
}
SHIM(size_t, VirtualQuery, void *addr, uint8_t *mbi, size_t len) { FIXME("VirtualQuery(%p)", addr);
    memset(mbi, 0, len);
    uint8_t *base = (uint8_t *)((uintptr_t)addr & ~0xfffull);
    size_t size = 0x1000;
    pthread_t self = pthread_self();
    uint8_t *stop = pthread_get_stackaddr_np(self);
    size_t ssz = pthread_get_stacksize_np(self);
    if ((uint8_t *)addr < stop && (uint8_t *)addr >= stop - ssz) { base = stop - ssz; size = ssz; }
    *(void **)mbi = base;
    *(void **)(mbi + 8) = base;
    *(uint32_t *)(mbi + 16) = 4;
    *(size_t *)(mbi + 24) = size;
    *(uint32_t *)(mbi + 32) = 0x1000;  // MEM_COMMIT
    *(uint32_t *)(mbi + 36) = 4;       // PAGE_READWRITE
    *(uint32_t *)(mbi + 40) = 0x20000; // MEM_PRIVATE
    return 48;
}
SHIM(HANDLE, GetProcessHeap, void) { return (HANDLE)1; }
SHIM(void *, HeapAlloc, HANDLE h, DWORD fl, size_t n) { (void)h; return (fl & 8) ? calloc(1, n) : malloc(n); }
SHIM(void *, HeapReAlloc, HANDLE h, DWORD fl, void *p, size_t n) { (void)h; (void)fl; return realloc(p, n); }
SHIM(WBOOL, HeapFree, HANDLE h, DWORD fl, void *p) { (void)h; (void)fl; free(p); return 1; }
SHIM(void *, GlobalAlloc, unsigned fl, size_t n) { (void)fl; return calloc(1, n); }
SHIM(void *, GlobalLock, void *p) { return p; }
SHIM(WBOOL, GlobalUnlock, void *p) { (void)p; return 1; }
SHIM(void *, LocalFree, void *p) { free(p); return NULL; }
SHIM(WBOOL, GlobalMemoryStatusEx, uint8_t *m) { FIXME("GlobalMemoryStatusEx: approximate");
    uint64_t mem = 0; size_t l = sizeof mem; sysctlbyname("hw.memsize", &mem, &l, NULL, 0);
    *(uint32_t *)(m + 4) = 30;
    for (int o = 8; o <= 48; o += 8) *(uint64_t *)(m + o) = o >= 40 ? (1ull << 47) : mem;
    *(uint64_t *)(m + 16) = mem / 2;
    *(uint64_t *)(m + 56) = 0;
    return 1;
}

// ---------------------------------------------------------------- time
static mach_timebase_info_data_t g_tb;
SHIM(WBOOL, QueryPerformanceFrequency, int64_t *f) { *f = 1000000000; return 1; }
SHIM(WBOOL, QueryPerformanceCounter, int64_t *c) {
    if (!g_tb.denom) mach_timebase_info(&g_tb);
    *c = (int64_t)(mach_absolute_time() * g_tb.numer / g_tb.denom);
    return 1;
}
SHIM(void, GetSystemTimeAsFileTime, uint64_t *ft) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); *ft = ts_to_filetime(t); }
SHIM(void, GetSystemTimePreciseAsFileTime, uint64_t *ft) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); *ft = ts_to_filetime(t); }

// ---------------------------------------------------------------- system info / process
SHIM(void, GetSystemInfo, uint8_t *si) {
    memset(si, 0, 48);
    *(uint16_t *)si = 9;  // AMD64
    *(uint32_t *)(si + 4) = 4096;
    *(uint64_t *)(si + 8) = 0x10000;
    *(uint64_t *)(si + 16) = 0x7ffffffeffffull;
    *(uint64_t *)(si + 24) = ncpu() >= 64 ? ~0ull : (1ull << ncpu()) - 1;
    *(uint32_t *)(si + 32) = ncpu();
    *(uint32_t *)(si + 36) = 8664;
    *(uint32_t *)(si + 40) = 65536;
    *(uint16_t *)(si + 44) = 6;
}
// One RelationProcessorCore record (48 bytes) per logical CPU.
SHIM(WBOOL, GetLogicalProcessorInformationEx, int rel, uint8_t *buf, DWORD *len) { FIXME("GetLogicalProcessorInformationEx(rel=%d): cores only", rel);
    int n = ncpu();
    DWORD need = 48 * n;
    TRACE("GetLogicalProcessorInformationEx(rel=%d, len=%u)", rel, *len);
    if (rel != 0 && rel != 0xffff) { *len = 0; return 1; }
    if (!buf || *len < need) { *len = need; set_last_error(ERROR_INSUFFICIENT_BUFFER); return 0; }
    memset(buf, 0, need);
    for (int i = 0; i < n; i++) {
        uint8_t *r = buf + 48 * i;
        *(uint32_t *)r = 0;
        *(uint32_t *)(r + 4) = 48;
        *(uint16_t *)(r + 30) = 1;              // GroupCount
        *(uint64_t *)(r + 32) = 1ull << i;      // GroupMask[0].Mask
    }
    *len = need;
    return 1;
}
SHIM(void, GetStartupInfoW, uint8_t *si) { memset(si, 0, 104); *(uint32_t *)si = 104; }
SHIM(WBOOL, GetVersionExW, uint8_t *v) {
    *(uint32_t *)(v + 4) = 10; *(uint32_t *)(v + 8) = 0; *(uint32_t *)(v + 12) = 19045; *(uint32_t *)(v + 16) = 2;
    return 1;
}
SHIM(DWORD, GetUserDefaultLCID, void) { return 0x409; }
SHIM(WBOOL, IsProcessorFeaturePresent, DWORD f) { return f != 23; }
SHIM(WBOOL, IsDebuggerPresent, void) { return 0; }
// The game also logs every console line here; shown only with LOADER_DEBUGSTRINGS=1.
SHIM(void, OutputDebugStringA, const char *s) { if (getenv("LOADER_DEBUGSTRINGS")) fprintf(stderr, "%8.3f [debug] %s", log_time(), s); }
SHIM(DWORD, FormatMessageW, DWORD fl, void *src, DWORD id, DWORD lang, WCHAR *buf, DWORD n, void *args) { FIXME("FormatMessageW(%u): generic text", id);
    (void)src; (void)lang; (void)args;
    char tmp[64];
    snprintf(tmp, sizeof tmp, "Windows error %u", id);
    WCHAR *w = u2w(tmp);
    DWORD l = (DWORD)wlen(w);
    if (fl & 0x100) { WCHAR *a = malloc((l + 1) * 2); memcpy(a, w, (l + 1) * 2); *(WCHAR **)buf = a; }
    else if (l < n) memcpy(buf, w, (l + 1) * 2);
    free(w);
    return l;
}
SHIM(int, MultiByteToWideChar, unsigned cp, DWORD fl, const char *s, int n, WCHAR *out, int on) {
    (void)cp; (void)fl;
    char *tmp = n < 0 ? strdup(s) : strndup(s, n);
    WCHAR *w = u2w(tmp);
    int l = (int)wlen(w) + (n < 0 ? 1 : 0);
    if (on) { if (l > on) { free(tmp); free(w); set_last_error(ERROR_INSUFFICIENT_BUFFER); return 0; } memcpy(out, w, l * 2); }
    free(tmp); free(w);
    return l;
}
SHIM(int, WideCharToMultiByte, unsigned cp, DWORD fl, const WCHAR *s, int n, char *out, int on, const char *def, WBOOL *used) {
    (void)cp; (void)fl; (void)def;
    if (used) *used = 0;
    char *u = w2u_n(s, n < 0 ? (long)wlen(s) : n);
    int l = (int)strlen(u) + (n < 0 ? 1 : 0);
    if (on) { if (l > on) { free(u); set_last_error(ERROR_INSUFFICIENT_BUFFER); return 0; } memcpy(out, u, l); }
    free(u);
    return l;
}
SHIM(DWORD, GetModuleFileNameW, HANDLE m, WCHAR *buf, DWORD n) {
    (void)m;
    DWORD l = (DWORD)wlen(g_exe_win_path);
    if (l >= n) { memcpy(buf, g_exe_win_path, n * 2); buf[n - 1] = 0; set_last_error(ERROR_INSUFFICIENT_BUFFER); return n; }
    memcpy(buf, g_exe_win_path, (l + 1) * 2);
    return l;
}
SHIM(HANDLE, GetModuleHandleW, const WCHAR *n) {
    if (!n) return g_image_base;
    // System DLLs "exist" so GetProcAddress lookups reach our shim table.
    char *u = w2u(n);
    bool sys = !strncasecmp(u, "kernel", 6) || !strncasecmp(u, "api-ms-win-", 11) || !strncasecmp(u, "ntdll", 5) ||
               !strncasecmp(u, "user32", 6);
    LOG("GetModuleHandleW(%s) -> %s", u, sys ? "fake" : "NULL");
    free(u);
    return sys ? (HANDLE)0x7ffe0000 : NULL;
}
SHIM(void *, GetProcAddress, HANDLE m, const char *name) {
    if ((uintptr_t)name < 0x10000) { LOG("GetProcAddress(%p, #%lu) -> NULL", m, (unsigned long)(uintptr_t)name); return NULL; }
    void *f = shim_lookup(name);
    LOG("GetProcAddress(%p, %s) -> %p", m, name, f);
    return f;
}
SHIM(HANDLE, LoadLibraryA, const char *n) { LOG("LoadLibraryA(%s) -> NULL", n); set_last_error(126); return NULL; }
SHIM(HANDLE, LoadLibraryW, const WCHAR *n) { char *u = w2u(n); LOG("LoadLibraryW(%s) -> NULL", u); free(u); set_last_error(126); return NULL; }
SHIM(WBOOL, FreeLibrary, HANDLE h) { (void)h; return 1; }
SHIM(DWORD, GetSystemDirectoryW, WCHAR *buf, DWORD n) {
    static const char *s = "C:\\windows\\system32";
    WCHAR *w = u2w(s); DWORD l = (DWORD)wlen(w);
    if (l < n) memcpy(buf, w, (l + 1) * 2);
    free(w);
    return l < n ? l : l + 1;
}
SHIM(unsigned, SetErrorMode, unsigned m) { (void)m; return 0; }
SHIM(void *, SetUnhandledExceptionFilter, void *f) { FIXME("SetUnhandledExceptionFilter(%p)", f); (void)f; return NULL; }
SHIM(long, UnhandledExceptionFilter, void *e) { (void)e; return 0; }
SHIM(void, RaiseException, DWORD code, DWORD fl, DWORD n, const uint64_t *args) {
    (void)fl; (void)n;
    if (code == 0x406D1388) {  // MS_VC_EXCEPTION: SetThreadName, ignored without a debugger
        TRACE("thread name: %s", args ? (const char *)args[1] : "?");
        return;
    }
    LOG("RaiseException(%#x)", code);
    abort();
}
SHIM(void, RtlCaptureContext, void *ctx) { FIXME("RtlCaptureContext"); memset(ctx, 0, 1232); }
SHIM(void *, RtlLookupFunctionEntry, uint64_t pc, uint64_t *base, void *h) { FIXME("RtlLookupFunctionEntry(%#llx)", (unsigned long long)pc); (void)pc; (void)h; *base = 0; return NULL; }
SHIM(void, ExitProcess, unsigned c) { LOG("ExitProcess(%u)", c); exit(c); }
SHIM(WBOOL, TerminateProcess, HANDLE h, unsigned c) { (void)h; LOG("TerminateProcess(%u)", c); _exit(c); }
SHIM(WBOOL, CreateProcessW, const WCHAR *a, WCHAR *cmd, void *p, void *t, WBOOL inh, DWORD fl, void *env, const WCHAR *dir, void *si, void *pi) {
    (void)a; (void)p; (void)t; (void)inh; (void)fl; (void)env; (void)dir; (void)si; (void)pi;
    char *u = w2u(cmd); LOG("CreateProcessW(%s) -> FALSE", u); free(u);
    return 0;
}
SHIM(WBOOL, GetExitCodeProcess, HANDLE h, DWORD *c) { FIXME("GetExitCodeProcess"); (void)h; *c = 0; return 0; }

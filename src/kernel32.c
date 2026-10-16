// kernel32: virtual memory and heaps, time, system information, modules, errors and the process.
#include "kernel32.h"
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

int logical_cpu_count(void) {
    int n = 1;
    size_t len = sizeof n;
    sysctlbyname("hw.logicalcpu", &n, &len, NULL, 0);
    return n;
}

static uint64_t all_cpus_mask(void) {
    int n = logical_cpu_count();
    return n >= 64 ? ~0ull : (1ull << n) - 1;
}

// ---------------------------------------------------------------- virtual memory
// Reservations are remembered so MEM_RELEASE can unmap the whole region.
typedef struct Region {
    uint8_t *base;
    size_t size;
    struct Region *next;
} Region;

static Region *g_regions;
static pthread_mutex_t g_regions_lock = PTHREAD_MUTEX_INITIALIZER;

SHIM(void *, VirtualAlloc, void *address, size_t size, DWORD type, DWORD protect) {
    if (address && !(type & MEM_RESERVE)) return address; // commit inside an existing reservation: already RW

    // Windows reservations are aligned to the 64 KiB allocation granularity, and allocators rely on it:
    // over-allocate, then trim to an aligned window.
    const size_t align = ALLOCATION_GRANULARITY;
    size = (size + 0xfff) & ~(size_t)0xfff;
    int prot = PROT_READ | PROT_WRITE | ((protect & PAGE_EXECUTE_ANY_MASK) ? PROT_EXEC : 0);
    uint8_t *raw = mmap(address, size + align, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (raw == MAP_FAILED) {
        set_last_error(ERROR_NOT_ENOUGH_MEMORY);
        return NULL;
    }
    uint8_t *base = (uint8_t *)(((uintptr_t)raw + align - 1) & ~(align - 1));
    if (base > raw) munmap(raw, base - raw);
    munmap(base + size, raw + size + align - (base + size));

    Region *r = malloc(sizeof *r);
    pthread_mutex_lock(&g_regions_lock);
    *r = (Region){base, size, g_regions};
    g_regions = r;
    pthread_mutex_unlock(&g_regions_lock);
    return base;
}

SHIM(WBOOL, VirtualFree, void *address, size_t size, DWORD type) {
    if (!(type & MEM_RELEASE)) { // decommit: give the pages back but keep the range
        madvise(address, size, MADV_FREE);
        return true;
    }
    pthread_mutex_lock(&g_regions_lock);
    for (Region **r = &g_regions; *r; r = &(*r)->next) {
        if ((*r)->base == address) {
            Region *found = *r;
            munmap(found->base, found->size);
            *r = found->next;
            free(found);
            break;
        }
    }
    pthread_mutex_unlock(&g_regions_lock);
    return true;
}

// Only accurate for the current thread's stack, which is what the game asks about.
SHIM(size_t, VirtualQuery, const void *address, MEMORY_BASIC_INFORMATION *info, size_t size) {
    FIXME("VirtualQuery(%p): only the thread stack is reported accurately", address);
    uint8_t *base = (uint8_t *)((uintptr_t)address & ~0xfffull);
    size_t region = 0x1000;
    uint8_t *stack_top = pthread_get_stackaddr_np(pthread_self());
    size_t stack_size = pthread_get_stacksize_np(pthread_self());
    if ((const uint8_t *)address < stack_top && (const uint8_t *)address >= stack_top - stack_size) {
        base = stack_top - stack_size;
        region = stack_size;
    }
    memset(info, 0, size);
    *info = (MEMORY_BASIC_INFORMATION){
        .BaseAddress = base,
        .AllocationBase = base,
        .AllocationProtect = PAGE_READWRITE,
        .RegionSize = region,
        .State = MEM_COMMIT,
        .Protect = PAGE_READWRITE,
        .Type = MEM_PRIVATE,
    };
    return sizeof *info;
}

SHIM(WBOOL, GlobalMemoryStatusEx, MEMORYSTATUSEX *status) {
    uint64_t physical = 0;
    size_t len = sizeof physical;
    sysctlbyname("hw.memsize", &physical, &len, NULL, 0);
    *status = (MEMORYSTATUSEX){
        .dwLength = sizeof *status,
        .dwMemoryLoad = 30, // percent; approximate, like the "available" figure below
        .ullTotalPhys = physical,
        .ullAvailPhys = physical / 2,
        .ullTotalPageFile = physical,
        .ullAvailPageFile = physical,
        .ullTotalVirtual = 1ull << 47,
        .ullAvailVirtual = 1ull << 47,
    };
    return true;
}

// ---------------------------------------------------------------- heaps
SHIM(HANDLE, GetProcessHeap, void) { return (HANDLE)1; } // every heap is malloc

SHIM(void *, HeapAlloc, HANDLE heap, DWORD flags, size_t size) {
    return (flags & HEAP_ZERO_MEMORY) ? calloc(1, size) : malloc(size);
}

SHIM(void *, HeapReAlloc, HANDLE heap, DWORD flags, void *p, size_t size) { return realloc(p, size); }

SHIM(WBOOL, HeapFree, HANDLE heap, DWORD flags, void *p) {
    free(p);
    return true;
}

SHIM(void *, GlobalAlloc, UINT flags, size_t size) { return calloc(1, size); }
SHIM(void *, GlobalLock, void *memory) { return memory; }
SHIM(WBOOL, GlobalUnlock, void *memory) { return true; }

SHIM(void *, LocalFree, void *memory) {
    free(memory);
    return NULL;
}

// ---------------------------------------------------------------- time
#define NS_PER_SECOND 1000000000

SHIM(WBOOL, QueryPerformanceFrequency, int64_t *frequency) {
    *frequency = NS_PER_SECOND; // the counter below is in nanoseconds
    return true;
}

SHIM(WBOOL, QueryPerformanceCounter, int64_t *counter) {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    *counter = (int64_t)(mach_absolute_time() * timebase.numer / timebase.denom);
    return true;
}

static void system_time_as_filetime(FILETIME *out) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    uint64_t v = timespec_to_filetime(now);
    *out = (FILETIME){(DWORD)v, (DWORD)(v >> 32)};
}

SHIM(void, GetSystemTimeAsFileTime, FILETIME *out) { system_time_as_filetime(out); }
SHIM(void, GetSystemTimePreciseAsFileTime, FILETIME *out) { system_time_as_filetime(out); }

static uint64_t filetime_ticks(const FILETIME *ft) { return (uint64_t)ft->dwHighDateTime << 32 | ft->dwLowDateTime; }

SHIM(WBOOL, FileTimeToLocalFileTime, const FILETIME *utc, FILETIME *local) {
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    uint64_t v = filetime_ticks(utc) + (int64_t)tm.tm_gmtoff * 10000000;
    *local = (FILETIME){(DWORD)v, (DWORD)(v >> 32)};
    return true;
}

SHIM(WBOOL, FileTimeToSystemTime, const FILETIME *ft, SYSTEMTIME *out) {
    uint64_t ticks = filetime_ticks(ft) - FILETIME_UNIX_EPOCH;
    time_t seconds = (time_t)(ticks / 10000000);
    struct tm tm;
    gmtime_r(&seconds, &tm);
    *out = (SYSTEMTIME){
        .wYear = tm.tm_year + 1900,
        .wMonth = tm.tm_mon + 1,
        .wDayOfWeek = tm.tm_wday,
        .wDay = tm.tm_mday,
        .wHour = tm.tm_hour,
        .wMinute = tm.tm_min,
        .wSecond = tm.tm_sec,
        .wMilliseconds = (ticks / 10000) % 1000,
    };
    return true;
}

// ---------------------------------------------------------------- system information
SHIM(void, GetSystemInfo, SYSTEM_INFO *info) {
    *info = (SYSTEM_INFO){
        .wProcessorArchitecture = PROCESSOR_ARCHITECTURE_AMD64,
        .dwPageSize = 4096,
        .lpMinimumApplicationAddress = (void *)0x10000,
        .lpMaximumApplicationAddress = (void *)0x7ffffffeffffull,
        .dwActiveProcessorMask = all_cpus_mask(),
        .dwNumberOfProcessors = logical_cpu_count(),
        .dwProcessorType = PROCESSOR_AMD_X8664,
        .dwAllocationGranularity = ALLOCATION_GRANULARITY,
        .wProcessorLevel = 6,
    };
}

// Reports one RelationProcessorCore record per logical CPU; other relationships are empty.
SHIM(WBOOL, GetLogicalProcessorInformationEx, int relationship, PROCESSOR_CORE_INFO *buf, DWORD *size) {
    int cpus = logical_cpu_count();
    DWORD needed = sizeof *buf * cpus;
    if (relationship != RELATION_PROCESSOR_CORE && relationship != RELATION_ALL) {
        FIXME("GetLogicalProcessorInformationEx(%d): only processor cores are reported", relationship);
        *size = 0;
        return true;
    }
    if (!buf || *size < needed) {
        *size = needed;
        set_last_error(ERROR_INSUFFICIENT_BUFFER);
        return false;
    }
    for (int i = 0; i < cpus; i++) {
        buf[i] = (PROCESSOR_CORE_INFO){
            .Relationship = RELATION_PROCESSOR_CORE,
            .Size = sizeof *buf,
            .GroupCount = 1,
            .GroupMask[0].Mask = 1ull << i,
        };
    }
    *size = needed;
    return true;
}

SHIM(WBOOL, GetProcessAffinityMask, HANDLE process, uint64_t *process_mask, uint64_t *system_mask) {
    *process_mask = *system_mask = all_cpus_mask();
    return true;
}

SHIM(WBOOL, IsProcessorFeaturePresent, DWORD feature) {
    return feature != PF_FASTFAIL_AVAILABLE; // __fastfail (int 0x29) would just crash under us
}

// Windows 10 22H2.
SHIM(WBOOL, GetVersionExW, OSVERSIONINFOW *info) {
    info->dwMajorVersion = 10;
    info->dwMinorVersion = 0;
    info->dwBuildNumber = 19045;
    info->dwPlatformId = VER_PLATFORM_WIN32_NT;
    return true;
}

SHIM(DWORD, GetUserDefaultLCID, void) { return LCID_EN_US; }

SHIM(void, GetStartupInfoW, STARTUPINFOW *info) {
    memset(info, 0, sizeof *info);
    info->cb = sizeof *info;
}

SHIM(DWORD, GetSystemDirectoryW, WCHAR *buf, DWORD size) {
    WCHAR *dir = u2w("C:\\windows\\system32");
    DWORD len = (DWORD)wlen(dir);
    if (len < size) memcpy(buf, dir, (len + 1) * sizeof(WCHAR));
    free(dir);
    return len < size ? len : len + 1;
}

SHIM(WBOOL, SetProcessInformation, HANDLE process, int info_class, void *info, DWORD size) {
    FIXME("SetProcessInformation(class=%d): ignored", info_class);
    return true;
}

// ---------------------------------------------------------------- text conversion (every code page is UTF-8)
SHIM(int, MultiByteToWideChar, UINT code_page, DWORD flags, const char *src, int src_len, WCHAR *dst, int dst_len) {
    char *copy = src_len < 0 ? strdup(src) : strndup(src, src_len);
    WCHAR *wide = u2w(copy);
    int len = (int)wlen(wide) + (src_len < 0 ? 1 : 0); // -1 input length includes the terminator
    free(copy);
    if (dst_len) {
        if (len > dst_len) {
            free(wide);
            set_last_error(ERROR_INSUFFICIENT_BUFFER);
            return 0;
        }
        memcpy(dst, wide, len * sizeof(WCHAR));
    }
    free(wide);
    return len;
}

SHIM(int, WideCharToMultiByte, UINT code_page, DWORD flags, const WCHAR *src, int src_len, char *dst, int dst_len,
     const char *default_char, WBOOL *used_default) {
    if (used_default) *used_default = false;
    char *utf8 = w2u_n(src, src_len < 0 ? (long)wlen(src) : src_len);
    int len = (int)strlen(utf8) + (src_len < 0 ? 1 : 0);
    if (dst_len) {
        if (len > dst_len) {
            free(utf8);
            set_last_error(ERROR_INSUFFICIENT_BUFFER);
            return 0;
        }
        memcpy(dst, utf8, len); // NOLINT(bugprone-not-null-terminated-result): len counts the NUL when src_len < 0
    }
    free(utf8);
    return len;
}

// ---------------------------------------------------------------- modules
#define FAKE_SYSTEM_MODULE ((HANDLE)0x7ffe0000)

SHIM(DWORD, GetModuleFileNameW, HANDLE module, WCHAR *buf, DWORD size) {
    DWORD len = (DWORD)wlen(g_exe_win_path);
    if (len >= size) { // truncated, like Windows
        memcpy(buf, g_exe_win_path, size * sizeof(WCHAR));
        buf[size - 1] = 0;
        set_last_error(ERROR_INSUFFICIENT_BUFFER);
        return size;
    }
    memcpy(buf, g_exe_win_path, (len + 1) * sizeof(WCHAR));
    return len;
}

// System DLLs "exist", so GetProcAddress on them reaches our shim table.
SHIM(HANDLE, GetModuleHandleW, const WCHAR *name) {
    if (!name) return g_image_base;
    char *utf8 = w2u(name);
    bool system = !strncasecmp(utf8, "kernel", 6) || !strncasecmp(utf8, "api-ms-win-", 11) ||
                  !strncasecmp(utf8, "ntdll", 5) || !strncasecmp(utf8, "user32", 6);
    TRACE("GetModuleHandleW(%s) -> %s", utf8, system ? "system module" : "NULL");
    free(utf8);
    return system ? FAKE_SYSTEM_MODULE : NULL;
}

SHIM(void *, GetProcAddress, HANDLE module, const char *name) {
    if ((uintptr_t)name <= 0xffff) return NULL; // by ordinal
    void *fn = shim_lookup(name);
    TRACE("GetProcAddress(%s) -> %p", name, fn);
    return fn;
}

// Optional DLLs the game probes for (XInput, PIX, Wwise plugins) are reported missing.
SHIM(HANDLE, LoadLibraryA, const char *name) {
    TRACE("LoadLibraryA(%s) -> not found", name);
    set_last_error(ERROR_MOD_NOT_FOUND);
    return NULL;
}

SHIM(HANDLE, LoadLibraryW, const WCHAR *name) {
    char *utf8 = w2u(name);
    TRACE("LoadLibraryW(%s) -> not found", utf8);
    free(utf8);
    set_last_error(ERROR_MOD_NOT_FOUND);
    return NULL;
}

SHIM(WBOOL, FreeLibrary, HANDLE module) { return true; }

// ---------------------------------------------------------------- errors, exceptions and debugging
SHIM(UINT, SetErrorMode, UINT mode) { return 0; }
SHIM(WBOOL, IsDebuggerPresent, void) { return false; }

// The game also writes every console line here; shown only with LOADER_DEBUGSTRINGS=1.
SHIM(void, OutputDebugStringA, const char *s) {
    if (getenv("LOADER_DEBUGSTRINGS")) fprintf(stderr, "%8.3f [debug] %s", log_time(), s);
}

SHIM(DWORD, FormatMessageW, DWORD flags, const void *source, DWORD id, DWORD language, WCHAR *buf, DWORD size,
     void *args) {
    char text[64];
    snprintf(text, sizeof text, "Windows error %u", id);
    WCHAR *message = u2w(text);
    DWORD len = (DWORD)wlen(message);
    if (flags & FORMAT_MESSAGE_ALLOCATE_BUFFER)
        *(WCHAR **)buf = message; // the caller frees it with LocalFree
    else if (len < size)
        memcpy(buf, message, (len + 1) * sizeof(WCHAR));
    if (!(flags & FORMAT_MESSAGE_ALLOCATE_BUFFER)) free(message);
    return len;
}

SHIM(void *, SetUnhandledExceptionFilter, void *filter) { return NULL; } // crashes go to our signal handler
SHIM(LONG, UnhandledExceptionFilter, void *exception) { return 0; }

SHIM(void, RaiseException, DWORD code, DWORD flags, DWORD argc, const ULONG_PTR *args) {
    if (code == MS_VC_EXCEPTION) { // a thread naming itself for a debugger
        TRACE("thread name: %s", argc >= 2 ? (const char *)args[1] : "?");
        return;
    }
    LOG("RaiseException(%#x)", code);
    abort();
}

// Used by the game's crash reporter to walk the stack; we report nothing to walk.
SHIM(void, RtlCaptureContext, void *context) { memset(context, 0, 1232); } // sizeof(CONTEXT)
SHIM(void *, RtlLookupFunctionEntry, uint64_t pc, uint64_t *image_base, void *history) {
    *image_base = 0;
    return NULL;
}

// ---------------------------------------------------------------- the process
SHIM(HANDLE, GetCurrentProcess, void) { return INVALID_HANDLE_VALUE; } // pseudo handle (-1)
SHIM(DWORD, GetCurrentProcessId, void) { return getpid(); }

SHIM(void, ExitProcess, UINT code) {
    LOG("ExitProcess(%u)", code);
    exit(code);
}

SHIM(WBOOL, TerminateProcess, HANDLE process, UINT code) {
    LOG("TerminateProcess(%u)", code);
    _exit(code);
}

SHIM(WBOOL, CreateProcessW, const WCHAR *app, WCHAR *command_line, void *process_security, void *thread_security,
     WBOOL inherit, DWORD flags, void *environment, const WCHAR *dir, void *startup, void *info) {
    char *cmd = w2u(command_line);
    LOG("CreateProcessW(%s): not supported", cmd);
    free(cmd);
    return false;
}

SHIM(WBOOL, GetExitCodeProcess, HANDLE process, DWORD *code) {
    *code = 0;
    return false;
}

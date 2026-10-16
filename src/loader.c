// x86_64 macOS loader for sinking_star.exe. Runs under Rosetta 2.
// Maps the PE at its preferred base, resolves imports to ms_abi shims (or logging stubs),
// sets up a Windows-like TEB reachable through %gs, and jumps to the PE entry point.
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>
#include "shim.h"

int g_trace;
static uint64_t g_log_t0;
double log_time(void) {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!g_log_t0) g_log_t0 = now;
    return (now - g_log_t0) / 1e9;
}
uint8_t *g_image_base;
size_t g_image_size;
char g_exe_unix_path[1024];
WCHAR g_exe_win_path[1024];

// ---------------------------------------------------------------- shim registry
typedef struct { const char *name; void *fn; } ShimEntry;
static ShimEntry *g_shims;
static int g_nshims, g_capshims;

// Registering an existing name replaces it (backends override the default shims).
void shim_register(const char *name, void *fn) {
    for (int i = 0; i < g_nshims; i++)
        if (!strcmp(g_shims[i].name, name)) { g_shims[i].fn = fn; return; }
    if (g_nshims == g_capshims) {
        g_capshims = g_capshims ? g_capshims * 2 : 512;
        g_shims = realloc(g_shims, g_capshims * sizeof *g_shims);
    }
    g_shims[g_nshims++] = (ShimEntry){name, fn};
}

void *shim_lookup(const char *name) {
    for (int i = 0; i < g_nshims; i++)
        if (!strcmp(g_shims[i].name, name)) return g_shims[i].fn;
    return NULL;
}

// ---------------------------------------------------------------- unimplemented-import stubs
static const char *volatile g_unimpl_name;

static WINAPI uint64_t unimpl_handler(void) {
    const char *n = g_unimpl_name;
    LOG("UNIMPLEMENTED import called: %s (returning 0)", n);
    if (getenv("LOADER_STRICT")) abort();
    return 0;
}

// Emits: movabs rax,name; movabs r11,&g_unimpl_name; mov [r11],rax; movabs rax,handler; jmp rax
static void *make_stub(const char *name) {
    static uint8_t *page;
    static size_t used = 4096;
    if (used + 40 > 4096) {
        page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        used = 0;
    }
    uint8_t *p = page + used, *s = p;
    uint64_t v;
    *p++ = 0x48; *p++ = 0xB8; v = (uint64_t)strdup(name); memcpy(p, &v, 8); p += 8;
    *p++ = 0x49; *p++ = 0xBB; v = (uint64_t)&g_unimpl_name; memcpy(p, &v, 8); p += 8;
    *p++ = 0x49; *p++ = 0x89; *p++ = 0x03;
    *p++ = 0x48; *p++ = 0xB8; v = (uint64_t)unimpl_handler; memcpy(p, &v, 8); p += 8;
    *p++ = 0xFF; *p++ = 0xE0;
    used += 40;
    return s;
}

// Emits: mov r10d, tag; movabs rax, target; jmp rax
void *make_tagged_thunk(uint32_t tag, void *target) {
    static uint8_t *page;
    static size_t used = 4096;
    if (used + 24 > 4096) {
        page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        used = 0;
    }
    uint8_t *p = page + used, *s = p;
    uint64_t v = (uint64_t)target;
    *p++ = 0x41; *p++ = 0xBA; memcpy(p, &tag, 4); p += 4;
    *p++ = 0x48; *p++ = 0xB8; memcpy(p, &v, 8); p += 8;
    *p++ = 0xFF; *p++ = 0xE0;
    used += 24;
    return s;
}

// ---------------------------------------------------------------- PE loading
#define U16(p) (*(uint16_t *)(p))
#define U32(p) (*(uint32_t *)(p))
#define U64(p) (*(uint64_t *)(p))

static uint8_t *g_nt;  // PE optional header owner
static uint32_t g_entry_rva;
static uint64_t g_tls_dir_va;

static uint8_t *datadir(int i, uint32_t *size) {
    uint8_t *opt = g_nt + 24;
    uint8_t *dd = opt + 112 + i * 8;
    if (size) *size = U32(dd + 4);
    return U32(dd) ? g_image_base + U32(dd) : NULL;
}

static void load_pe(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror(path); exit(1); }
    struct stat st;
    fstat(fd, &st);
    uint8_t *file = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);

    uint8_t *nt = file + U32(file + 0x3c);
    uint8_t *opt = nt + 24;
    uint64_t pref = U64(opt + 24);
    g_image_size = U32(opt + 56);
    uint32_t hdr_size = U32(opt + 60);
    g_entry_rva = U32(opt + 16);

    uint8_t *base = mmap((void *)pref, g_image_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                         MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) { perror("mmap image"); exit(1); }
    if ((uint64_t)base != pref) LOG("image not at preferred base, relocating to %p", base);
    g_image_base = base;
    memcpy(base, file, hdr_size);
    g_nt = base + U32(base + 0x3c);

    int nsec = U16(nt + 6);
    uint8_t *sec = opt + U16(nt + 20);
    for (int i = 0; i < nsec; i++, sec += 40) {
        uint32_t vsize = U32(sec + 8), va = U32(sec + 12), rsize = U32(sec + 16), rptr = U32(sec + 20);
        memcpy(base + va, file + rptr, rsize < vsize || !vsize ? rsize : vsize);
    }
    munmap(file, st.st_size);

    int64_t delta = (int64_t)base - (int64_t)pref;
    uint32_t rsz;
    uint8_t *r = datadir(5, &rsz);
    if (delta && r) {
        for (uint8_t *end = r + rsz; r < end;) {
            uint32_t page = U32(r), bsz = U32(r + 4);
            for (uint32_t i = 8; i < bsz; i += 2) {
                uint16_t e = U16(r + i);
                if ((e >> 12) == 10) U64(base + page + (e & 0xfff)) += delta;
            }
            r += bsz;
        }
    }

    int resolved = 0, stubbed = 0;
    uint8_t *imp = datadir(1, NULL);
    for (; imp && U32(imp + 12); imp += 20) {
        const char *dll = (char *)base + U32(imp + 12);
        uint64_t *ilt = (uint64_t *)(base + (U32(imp) ? U32(imp) : U32(imp + 16)));
        uint64_t *iat = (uint64_t *)(base + U32(imp + 16));
        for (; *ilt; ilt++, iat++) {
            char name[256];
            if (*ilt >> 63) snprintf(name, sizeof name, "%s#%u", dll, (unsigned)(*ilt & 0xffff));
            else snprintf(name, sizeof name, "%s", (char *)base + (uint32_t)*ilt + 2);
            void *fn = shim_lookup(name);
            if (fn) resolved++;
            else { fn = make_stub(name); stubbed++; if (g_trace) LOG("stub %s!%s", dll, name); }
            *iat = (uint64_t)fn;
        }
    }
    LOG("imports: %d shimmed, %d stubbed", resolved, stubbed);

    uint8_t *tls = datadir(9, NULL);
    g_tls_dir_va = (uint64_t)tls;
}

// ---------------------------------------------------------------- TEB / TLS via %gs
// On macOS x86_64 %gs points at the pthread TSD array. Like Wine on macOS we store
// TEB.Self in slot 6 (gs:0x30) and the TLS array in slot 11 (gs:0x58).
static uint8_t g_peb[0x1000];

Teb *teb_setup_current_thread(void) {
    Teb *t = calloc(1, sizeof *t);
    U64(t->raw + 0x30) = (uint64_t)t;
    U64(t->raw + 0x58) = (uint64_t)t->tls_array;
    U64(t->raw + 0x60) = (uint64_t)g_peb;
    U64(g_peb + 0x10) = (uint64_t)g_image_base;  // PEB.ImageBaseAddress
    if (g_tls_dir_va) {
        uint8_t *d = (uint8_t *)g_tls_dir_va;
        uint64_t start = U64(d), end = U64(d + 8), zero = U32(d + 32);
        uint8_t *blk = calloc(1, end - start + zero + 16);
        memcpy(blk, (void *)start, end - start);
        t->tls_array[0] = blk;
        *(uint32_t *)U64(d + 16) = 0;  // AddressOfIndex
    }
    void *self = t, *tlsarr = t->tls_array;
    __asm__ volatile("movq %0, %%gs:0x30" ::"r"(self));
    __asm__ volatile("movq %0, %%gs:0x58" ::"r"(tlsarr));
    return t;
}

Teb *teb_current(void) {
    Teb *t;
    __asm__ volatile("movq %%gs:0x30, %0" : "=r"(t));
    return t;
}

void set_last_error(DWORD e) { teb_current()->last_error = e; }

// ---------------------------------------------------------------- crash reporting
static void crash(int sig, siginfo_t *si, void *ctx) {
    ucontext_t *uc = ctx;
    _STRUCT_X86_THREAD_STATE64 *s = &uc->uc_mcontext->__ss;
    fprintf(stderr, "\n[loader] signal %d at rip=%#llx", sig, s->__rip);
    if (s->__rip >= (uint64_t)g_image_base && s->__rip < (uint64_t)g_image_base + g_image_size)
        fprintf(stderr, " (exe+%#llx)", s->__rip - (uint64_t)g_image_base);
    fprintf(stderr, " fault addr=%p\n", si->si_addr);
    fprintf(stderr, "  rax=%#llx rbx=%#llx rcx=%#llx rdx=%#llx\n  rsi=%#llx rdi=%#llx rbp=%#llx rsp=%#llx\n"
                    "  r8=%#llx r9=%#llx r10=%#llx r11=%#llx\n",
            s->__rax, s->__rbx, s->__rcx, s->__rdx, s->__rsi, s->__rdi, s->__rbp, s->__rsp,
            s->__r8, s->__r9, s->__r10, s->__r11);
    fprintf(stderr, "  stack return addresses in exe:");
    uint64_t *sp = (uint64_t *)s->__rsp;
    for (int i = 0, n = 0; i < 512 && n < 16; i++) {
        uint64_t v = sp[i];
        if (v >= (uint64_t)g_image_base + 0x1000 && v < (uint64_t)g_image_base + 0x65f000) {
            fprintf(stderr, " %#llx", v);
            n++;
        }
    }
    fprintf(stderr, "\n");
    _exit(128 + sig);
}

static void install_crash_handler(void) {
    static uint8_t altstack[1 << 16];
    stack_t ss = {.ss_sp = altstack, .ss_size = sizeof altstack};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = crash;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGABRT};
    for (unsigned i = 0; i < sizeof sigs / sizeof *sigs; i++) sigaction(sigs[i], &sa, NULL);
}

// ---------------------------------------------------------------- main
int main(int argc, char **argv) {
    log_time();  // start the log clock
    g_trace = getenv("LOADER_TRACE") != NULL;
    const char *exe = argc > 1 ? argv[1] : "sinking_star.exe";
    if (!realpath(exe, g_exe_unix_path)) { perror(exe); return 1; }

    // Windows path: Z:\Users\...\sinking_star.exe (Wine convention, Z: = /)
    char win[1100];
    snprintf(win, sizeof win, "Z:%s", g_exe_unix_path);
    for (char *c = win; *c; c++) if (*c == '/') *c = '\\';
    WCHAR *w = u2w(win);
    memcpy(g_exe_win_path, w, (wlen(w) + 1) * 2);
    free(w);

    char dir[1024];
    strcpy(dir, g_exe_unix_path);
    chdir(dirname(dir));

    install_crash_handler();
    cocoa_init();
    d3d_backend_init();
    load_pe(g_exe_unix_path);
    teb_setup_current_thread();

    LOG("jumping to entry point exe+%#x", g_entry_rva);
    int (WINAPI *entry)(void) = (void *)(g_image_base + g_entry_rva);
    int rc = entry();
    LOG("entry returned %d", rc);
    return rc;
}

// x86_64 macOS loader for sinking_star.exe (runs under Rosetta 2).
//
// Maps the PE image at its preferred base, binds its imports to our ms_abi shims (or to stubs that log
// the missing name), sets up a Windows-like TEB reachable through %gs, and jumps to the entry point.
#include "shim.h"
#include <fcntl.h>
#include <libgen.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

bool g_trace;
uint8_t *g_image_base;
size_t g_image_size;
char g_exe_unix_path[1024];
WCHAR g_exe_win_path[1024];

double log_time(void) {
    static uint64_t start;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!start) start = now;
    return (now - start) / 1e9;
}

// ---------------------------------------------------------------- shim registry
typedef struct {
    const char *name;
    void *fn;
} ShimEntry;

static ShimEntry *g_shims;
static size_t g_shim_count, g_shim_capacity;

void shim_register(const char *name, void *fn) {
    for (size_t i = 0; i < g_shim_count; i++) {
        if (!strcmp(g_shims[i].name, name)) {
            g_shims[i].fn = fn;
            return;
        }
    }
    if (g_shim_count == g_shim_capacity) {
        g_shim_capacity = g_shim_capacity ? g_shim_capacity * 2 : 512;
        ShimEntry *grown = realloc(g_shims, g_shim_capacity * sizeof *g_shims);
        if (!grown) abort();
        g_shims = grown;
    }
    g_shims[g_shim_count++] = (ShimEntry){name, fn};
}

void *shim_lookup(const char *name) {
    for (size_t i = 0; i < g_shim_count; i++)
        if (!strcmp(g_shims[i].name, name)) return g_shims[i].fn;
    return NULL;
}

// ---------------------------------------------------------------- generated thunks
// Small machine-code trampolines, written into an executable page.
static uint8_t *code_alloc(size_t size) {
    static uint8_t *page;
    static size_t used = 4096;
    if (used + size > 4096) {
        page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (page == MAP_FAILED) abort();
        used = 0;
    }
    uint8_t *p = page + used;
    used += size;
    return p;
}

static uint8_t *emit(uint8_t *p, const void *bytes, size_t n) {
    memcpy(p, bytes, n);
    return p + n;
}

static uint8_t *emit_mov_imm64(uint8_t *p, uint8_t rex, uint8_t opcode, uint64_t value) {
    p = emit(p, (uint8_t[]){rex, opcode}, 2);
    return emit(p, &value, 8);
}

#define REX_W        0x48
#define REX_WB       0x49
#define MOV_RAX_IMM  0xB8 // with REX.W: movabs rax, imm64
#define MOV_R11_IMM  0xBB // with REX.WB: movabs r11, imm64
#define JMP_RAX      0xFF, 0xE0
#define MOV_R11M_RAX 0x49, 0x89, 0x03 // mov [r11], rax
#define MOV_R10D_IMM 0x41, 0xBA       // mov r10d, imm32

void *make_tagged_thunk(uint32_t tag, void *target) {
    uint8_t *start = code_alloc(24), *p = start;
    p = emit(p, (uint8_t[]){MOV_R10D_IMM}, 2);
    p = emit(p, &tag, 4);
    p = emit_mov_imm64(p, REX_W, MOV_RAX_IMM, (uint64_t)target);
    emit(p, (uint8_t[]){JMP_RAX}, 2);
    return start;
}

// Imports we do not implement get a stub that records its name and calls this handler.
static const char *volatile g_unimplemented_name;

static WINAPI uint64_t unimplemented_import(void) {
    LOG("UNIMPLEMENTED import called: %s (returning 0)", g_unimplemented_name);
    if (getenv("LOADER_STRICT")) abort();
    return 0;
}

static void *make_unimplemented_stub(const char *name) {
    uint8_t *start = code_alloc(40), *p = start;
    p = emit_mov_imm64(p, REX_W, MOV_RAX_IMM, (uint64_t)strdup(name));
    p = emit_mov_imm64(p, REX_WB, MOV_R11_IMM, (uint64_t)&g_unimplemented_name);
    p = emit(p, (uint8_t[]){MOV_R11M_RAX}, 3);
    p = emit_mov_imm64(p, REX_W, MOV_RAX_IMM, (uint64_t)unimplemented_import);
    emit(p, (uint8_t[]){JMP_RAX}, 2);
    return start;
}

// ---------------------------------------------------------------- PE loading
static IMAGE_NT_HEADERS64 *g_nt;
static IMAGE_TLS_DIRECTORY64 *g_tls_directory;

static void *directory(int index, DWORD *size) {
    IMAGE_DATA_DIRECTORY *d = &g_nt->DataDirectory[index];
    if (size) *size = d->Size;
    return d->VirtualAddress ? g_image_base + d->VirtualAddress : NULL;
}

static void apply_relocations(int64_t delta) {
    DWORD size;
    uint8_t *block = directory(IMAGE_DIRECTORY_ENTRY_BASERELOC, &size), *end = block + size;
    if (!delta || !block) return;
    while (block < end) {
        IMAGE_BASE_RELOCATION *r = (IMAGE_BASE_RELOCATION *)block;
        WORD *entries = (WORD *)(r + 1);
        size_t count = (r->SizeOfBlock - sizeof *r) / sizeof *entries;
        for (size_t i = 0; i < count; i++)
            if (entries[i] >> 12 == IMAGE_REL_BASED_DIR64)
                *(uint64_t *)(g_image_base + r->VirtualAddress + (entries[i] & 0xfff)) += delta;
        block += r->SizeOfBlock;
    }
}

static void bind_imports(void) {
    int shimmed = 0, stubbed = 0;
    for (IMAGE_IMPORT_DESCRIPTOR *d = directory(IMAGE_DIRECTORY_ENTRY_IMPORT, NULL); d && d->Name; d++) {
        const char *dll = (char *)g_image_base + d->Name;
        uint64_t *lookup = (uint64_t *)(g_image_base + (d->OriginalFirstThunk ? d->OriginalFirstThunk : d->FirstThunk));
        uint64_t *address = (uint64_t *)(g_image_base + d->FirstThunk);
        for (; *lookup; lookup++, address++) {
            char name[256];
            if (*lookup & IMAGE_ORDINAL_FLAG64)
                snprintf(name, sizeof name, "%s#%u", dll, (unsigned)(*lookup & 0xffff));
            else // IMAGE_IMPORT_BY_NAME: WORD hint, then the name
                snprintf(name, sizeof name, "%s", (char *)g_image_base + (uint32_t)*lookup + sizeof(WORD));
            void *fn = shim_lookup(name);
            if (fn) {
                shimmed++;
            } else {
                fn = make_unimplemented_stub(name);
                stubbed++;
                TRACE("no shim for %s!%s", dll, name);
            }
            *address = (uint64_t)fn;
        }
    }
    LOG("imports: %d shimmed, %d stubbed", shimmed, stubbed);
}

// Returns the entry point.
static void *load_pe(const char *path) {
    int fd = open(path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) {
        perror(path);
        exit(1);
    }
    uint8_t *file = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    const IMAGE_NT_HEADERS64 *nt = (void *)(file + ((IMAGE_DOS_HEADER *)file)->e_lfanew);

    // The game is not position independent in practice: map it where it wants to be.
    g_image_size = nt->SizeOfImage;
    g_image_base =
        mmap((void *)nt->ImageBase, g_image_size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (g_image_base == MAP_FAILED) {
        perror("mmap image");
        exit(1);
    }
    if ((uint64_t)g_image_base != nt->ImageBase) LOG("image relocated to %p", g_image_base);

    memcpy(g_image_base, file, nt->SizeOfHeaders);
    g_nt = (IMAGE_NT_HEADERS64 *)(g_image_base + ((IMAGE_DOS_HEADER *)g_image_base)->e_lfanew);
    const IMAGE_SECTION_HEADER *sections = (const void *)((const uint8_t *)&nt->Magic + nt->SizeOfOptionalHeader);
    for (int i = 0; i < nt->NumberOfSections; i++) {
        const IMAGE_SECTION_HEADER *s = &sections[i];
        size_t n = s->VirtualSize && s->VirtualSize < s->SizeOfRawData ? s->VirtualSize : s->SizeOfRawData;
        memcpy(g_image_base + s->VirtualAddress, file + s->PointerToRawData, n);
    }
    munmap(file, st.st_size);

    apply_relocations((int64_t)g_image_base - (int64_t)g_nt->ImageBase);
    bind_imports();
    g_tls_directory = directory(IMAGE_DIRECTORY_ENTRY_TLS, NULL);
    return g_image_base + g_nt->AddressOfEntryPoint;
}

// ---------------------------------------------------------------- TEB / TLS via %gs
// On macOS x86_64, %gs points at the pthread TSD array. Like Wine on macOS, the TEB fields the
// game reads through %gs are written into TSD slots 6 (gs:0x30) and 11 (gs:0x58), which are unused.
static uint8_t g_peb[0x1000];

Teb *teb_setup_current_thread(void) {
    Teb *t = calloc(1, sizeof *t);
    *(void **)(t->raw + TEB_SELF) = t;
    *(void **)(t->raw + TEB_TLS_POINTER) = t->tls_array;
    *(void **)(t->raw + TEB_PEB) = g_peb;
    *(void **)(g_peb + PEB_IMAGE_BASE) = g_image_base;
    if (g_tls_directory) { // the exe's implicit TLS block (index 0)
        const IMAGE_TLS_DIRECTORY64 *d = g_tls_directory;
        size_t init = d->EndAddressOfRawData - d->StartAddressOfRawData;
        uint8_t *block = calloc(1, init + d->SizeOfZeroFill + 16);
        memcpy(block, (void *)d->StartAddressOfRawData, init);
        t->tls_array[0] = block;
        *(DWORD *)d->AddressOfIndex = 0;
    }
    void *self = t, *tls = t->tls_array;
    __asm__ volatile("movq %0, %%gs:0x30" ::"r"(self)); // TEB_SELF
    __asm__ volatile("movq %0, %%gs:0x58" ::"r"(tls));  // TEB_TLS_POINTER
    return t;
}

Teb *teb_current(void) {
    Teb *t;
    __asm__ volatile("movq %%gs:0x30, %0" : "=r"(t));
    return t;
}

void set_last_error(DWORD error) { teb_current()->last_error = error; }

// ---------------------------------------------------------------- crash reports
static bool in_image(uint64_t address) {
    return address >= (uint64_t)g_image_base && address < (uint64_t)g_image_base + g_image_size;
}

static void crash(int sig, siginfo_t *info, void *context) {
    _STRUCT_X86_THREAD_STATE64 *r = &((ucontext_t *)context)->uc_mcontext->__ss;
    fprintf(stderr, "\n[loader] signal %d at rip=%#llx", sig, r->__rip);
    if (in_image(r->__rip)) fprintf(stderr, " (exe+%#llx)", r->__rip - (uint64_t)g_image_base);
    fprintf(stderr, " fault addr=%p\n", info->si_addr);
    fprintf(stderr, "  rax=%#llx rbx=%#llx rcx=%#llx rdx=%#llx\n", r->__rax, r->__rbx, r->__rcx, r->__rdx);
    fprintf(stderr, "  rsi=%#llx rdi=%#llx rbp=%#llx rsp=%#llx\n", r->__rsi, r->__rdi, r->__rbp, r->__rsp);
    fprintf(stderr, "  r8=%#llx r9=%#llx r10=%#llx r11=%#llx\n", r->__r8, r->__r9, r->__r10, r->__r11);
    fprintf(stderr, "  return addresses into the exe:");
    const uint64_t *stack = (const uint64_t *)r->__rsp;
    for (int i = 0, found = 0; i < 512 && found < 16; i++) {
        if (in_image(stack[i])) {
            fprintf(stderr, " exe+%#llx", stack[i] - (uint64_t)g_image_base);
            found++;
        }
    }
    fprintf(stderr, "\n");
    _exit(128 + sig);
}

static void install_crash_handler(void) {
    static uint8_t alt_stack[1 << 16];
    stack_t ss = {.ss_sp = alt_stack, .ss_size = sizeof alt_stack};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {.sa_sigaction = crash, .sa_flags = SA_SIGINFO | SA_ONSTACK};
    const int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGABRT};
    for (size_t i = 0; i < sizeof signals / sizeof *signals; i++) sigaction(signals[i], &sa, NULL);
}

// ---------------------------------------------------------------- main
int main(int argc, char **argv) {
    log_time(); // start the clock
    g_trace = getenv("LOADER_TRACE") != NULL;
    const char *exe = argc > 1 ? argv[1] : "sinking_star.exe";
    if (!realpath(exe, g_exe_unix_path)) {
        perror(exe);
        return 1;
    }

    // The game sees its own path as Z:\...\sinking_star.exe (Wine's convention, Z: is /).
    char win_path[1100];
    snprintf(win_path, sizeof win_path, "Z:%s", g_exe_unix_path);
    for (char *c = win_path; *c; c++)
        if (*c == '/') *c = '\\';
    WCHAR *w = u2w(win_path);
    memcpy(g_exe_win_path, w, (wlen(w) + 1) * sizeof(WCHAR));
    free(w);

    char dir[1024];
    strlcpy(dir, g_exe_unix_path, sizeof dir);
    if (chdir(dirname(dir))) perror("chdir");

    install_crash_handler();
    cocoa_init();
    d3d_backend_init();
    int(WINAPI * entry)(void) = load_pe(g_exe_unix_path);
    teb_setup_current_thread();

    LOG("starting %s", g_exe_unix_path);
    return entry();
}

// UCRT (api-ms-win-crt-*) and VCRUNTIME140 shims.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "shim.h"

int win_vformat(char *out, size_t cap, const char *fmt, uint64_t *args, int wide_default);

// ---- startup
static int g_argc = 1;
static char *g_argv_store[2] = {"sinking_star.exe", NULL};
static char **g_argv = g_argv_store;
static char *g_env_store[1] = {NULL};
static int g_commode, g_fmode;
typedef WINAPI void (*PVFV)(void);
typedef WINAPI int (*PIFV)(void);

SHIM(int *, __p___argc, void) { return &g_argc; }
SHIM(char ***, __p___argv, void) { return &g_argv; }
SHIM(int *, __p__commode, void) { return &g_commode; }
SHIM(int, _set_fmode, int m) { g_fmode = m; return 0; }
SHIM(void, _set_app_type, int t) { (void)t; }
SHIM(int, _configure_narrow_argv, int m) { (void)m; return 0; }
SHIM(int, _initialize_narrow_environment, void) { return 0; }
SHIM(char **, _get_initial_narrow_environment, void) { return g_env_store; }
SHIM(int, _configthreadlocale, int x) { (void)x; return 1; }
SHIM(void, __setusermatherr, void *f) { (void)f; }
SHIM(int, _set_new_mode, int m) { (void)m; return 0; }
SHIM(int, _callnewh, size_t n) { (void)n; return 0; }
SHIM(int, _initialize_onexit_table, void *t) { (void)t; return 0; }
SHIM(int, _register_onexit_function, void *t, void *f) { (void)t; (void)f; return 0; }
SHIM(int, _execute_onexit_table, void *t) { (void)t; return 0; }
SHIM(int, _crt_atexit, void *f) { (void)f; return 0; }
SHIM(int, _crt_at_quick_exit, void *f) { (void)f; return 0; }
SHIM(void, _register_thread_local_exe_atexit_callback, void *f) { (void)f; }
SHIM(int, _seh_filter_exe, DWORD code, void *ep) { (void)ep; LOG("_seh_filter_exe code=%#x", code); return 0; }
SHIM(int, _seh_filter_dll, DWORD code, void *ep) { (void)ep; (void)code; return 0; }
SHIM(void, _initterm, PVFV *b, PVFV *e) {
    for (; b < e; b++) if (*b) (*b)();
}
SHIM(int, _initterm_e, PIFV *b, PIFV *e) {
    for (; b < e; b++) if (*b) { int r = (*b)(); if (r) return r; }
    return 0;
}
SHIM(void, exit, int c) { LOG("exit(%d)", c); exit(c); }
SHIM(void, _exit, int c) { LOG("_exit(%d)", c); _exit(c); }
SHIM(void, _cexit, void) {}
SHIM(void, _c_exit, void) {}
SHIM(void, terminate, void) { LOG("terminate()"); abort(); }
SHIM(void, _wassert, const WCHAR *m, const WCHAR *f, unsigned l) {
    LOG("assert: %s at %s:%u", w2u(m), w2u(f), l); abort();
}
SHIM(char *, getenv, const char *n) { return getenv(n); }
SHIM(long, strtol, const char *s, char **e, int b) { return (long)(int32_t)strtol(s, e, b); }
SHIM(int64_t, _time64, int64_t *t) { int64_t v = time(NULL); if (t) *t = v; return v; }

// ---- heap
SHIM(void *, malloc, size_t n) { return malloc(n); }
SHIM(void *, calloc, size_t a, size_t b) { return calloc(a, b); }
SHIM(void *, realloc, void *p, size_t n) { return realloc(p, n); }
SHIM(void, free, void *p) { free(p); }

// ---- memory / strings
SHIM(void *, memcpy, void *d, const void *s, size_t n) { return memcpy(d, s, n); }
SHIM(void *, memmove, void *d, const void *s, size_t n) { return memmove(d, s, n); }
SHIM(void *, memset, void *d, int c, size_t n) { return memset(d, c, n); }
SHIM(int, memcmp, const void *a, const void *b, size_t n) { return memcmp(a, b, n); }
SHIM(void *, memchr, const void *a, int c, size_t n) { return memchr(a, c, n); }
SHIM(size_t, strlen, const char *s) { return strlen(s); }
SHIM(int, strcmp, const char *a, const char *b) { return strcmp(a, b); }
SHIM(int, strncmp, const char *a, const char *b, size_t n) { return strncmp(a, b, n); }
SHIM(char *, strncpy, char *d, const char *s, size_t n) { return strncpy(d, s, n); }
SHIM(int, strncpy_s, char *d, size_t dn, const char *s, size_t n) {
    size_t l = strnlen(s, n);
    if (l >= dn) l = dn - 1;
    memcpy(d, s, l); d[l] = 0; return 0;
}
SHIM(char *, strrchr, const char *s, int c) { return strrchr(s, c); }
SHIM(char *, strstr, const char *a, const char *b) { return strstr(a, b); }

static WCHAR *wstrstr(const WCHAR *h, const WCHAR *n) {
    size_t ln = wlen(n);
    for (; *h; h++) if (!memcmp(h, n, ln * 2)) return (WCHAR *)h;
    return ln ? NULL : (WCHAR *)h;
}
SHIM(WCHAR *, wcsstr, const WCHAR *h, const WCHAR *n) { return wstrstr(h, n); }
SHIM(WCHAR *, wcsncpy, WCHAR *d, const WCHAR *s, size_t n) {
    size_t i = 0;
    for (; i < n && s[i]; i++) d[i] = s[i];
    for (; i < n; i++) d[i] = 0;
    return d;
}
SHIM(int, wcsncpy_s, WCHAR *d, size_t dn, const WCHAR *s, size_t n) {
    size_t l = 0;
    while (l < n && s[l]) l++;
    if (l >= dn) l = dn - 1;
    memcpy(d, s, l * 2); d[l] = 0; return 0;
}
SHIM(int, wcsncat_s, WCHAR *d, size_t dn, const WCHAR *s, size_t n) {
    size_t dl = wlen(d), l = 0;
    while (l < n && s[l] && dl + l + 1 < dn) { d[dl + l] = s[l]; l++; }
    d[dl + l] = 0; return 0;
}

// ---- qsort with an ms_abi comparator
typedef WINAPI int (*Cmp)(const void *, const void *);
static int qsort_thunk(void *ctx, const void *a, const void *b) { return ((Cmp)ctx)(a, b); }
SHIM(void, qsort, void *b, size_t n, size_t s, Cmp c) { qsort_r(b, n, s, (void *)c, qsort_thunk); }

// ---- math
SHIM(float, sinf, float x) { return sinf(x); }
SHIM(float, cosf, float x) { return cosf(x); }
SHIM(float, tanf, float x) { return tanf(x); }
SHIM(float, asinf, float x) { return asinf(x); }
SHIM(float, atan2f, float y, float x) { return atan2f(y, x); }
SHIM(float, sqrtf, float x) { return sqrtf(x); }
SHIM(float, expf, float x) { return expf(x); }
SHIM(float, powf, float x, float y) { return powf(x, y); }
SHIM(float, fmodf, float x, float y) { return fmodf(x, y); }
SHIM(float, log10f, float x) { return log10f(x); }
SHIM(double, cos, double x) { return cos(x); }
SHIM(double, exp, double x) { return exp(x); }
SHIM(double, log, double x) { return log(x); }
SHIM(double, log10, double x) { return log10(x); }
SHIM(double, pow, double x, double y) { return pow(x, y); }
SHIM(double, frexp, double x, int *e) { return frexp(x, e); }

// ---- stdio
#define OPT_STANDARD_SNPRINTF 2ull
SHIM(int, __stdio_common_vsprintf, uint64_t opt, char *buf, size_t n, const char *fmt, void *loc, uint64_t *va) {
    (void)loc;
    int len = win_vformat(buf, buf ? n : 0, fmt, va, 0);
    if (buf && (size_t)len >= n && !(opt & OPT_STANDARD_SNPRINTF)) return -1;
    return len;
}
SHIM(int, __stdio_common_vswprintf_s, uint64_t opt, WCHAR *buf, size_t n, const WCHAR *fmt, void *loc, uint64_t *va) {
    (void)opt; (void)loc;
    char *f = w2u(fmt);
    int len = win_vformat(NULL, 0, f, va, 1);
    char *tmp = malloc(len + 1);
    win_vformat(tmp, len + 1, f, va, 1);
    WCHAR *w = u2w(tmp);
    size_t wl = wlen(w);
    int r = (int)wl;
    if (wl >= n) { if (n) buf[0] = 0; r = -1; }
    else memcpy(buf, w, (wl + 1) * 2);
    free(f); free(tmp); free(w);
    return r;
}
SHIM(int, _wfopen_s, FILE **out, const WCHAR *name, const WCHAR *mode) {
    char *n = w2u(name), *m = w2u(mode), *u = win_to_unix_path(n);
    *out = fopen(u, m);
    TRACE("_wfopen_s(%s, %s) -> %p", u, m, (void *)*out);
    free(n); free(m); free(u);
    return *out ? 0 : 2;
}
SHIM(size_t, fwrite, const void *p, size_t s, size_t n, FILE *f) { return fwrite(p, s, n, f); }
SHIM(int, fclose, FILE *f) { return fclose(f); }

// ---- vcruntime exception / setjmp support (not yet implemented)
SHIM(void, _CxxThrowException, void *obj, void *info) { LOG("_CxxThrowException(%p, %p)", obj, info); abort(); }
SHIM(void, _purecall, void) { LOG("_purecall"); abort(); }
SHIM(void, __std_type_info_destroy_list, void *l) { (void)l; }
SHIM(void, __std_exception_copy, const void *a, void *b) { memcpy(b, a, 16); }
SHIM(void, __std_exception_destroy, void *a) { (void)a; }

// ---- setjmp/longjmp with the MSVC x64 _JUMP_BUFFER layout:
// Frame 0, Rbx 8, Rsp 16, Rbp 24, Rsi 32, Rdi 40, R12-R15 48..72, Rip 80, MxCsr 88, FpCsr 92, Xmm6-15 96..240.
// No SEH unwinding is done on longjmp (Frame is ignored).
__asm__(".intel_syntax noprefix\n"
        "_win_setjmp:\n"
        "  mov [rcx], rdx\n  mov [rcx+8], rbx\n  lea rax, [rsp+8]\n  mov [rcx+16], rax\n"
        "  mov [rcx+24], rbp\n  mov [rcx+32], rsi\n  mov [rcx+40], rdi\n"
        "  mov [rcx+48], r12\n  mov [rcx+56], r13\n  mov [rcx+64], r14\n  mov [rcx+72], r15\n"
        "  mov rax, [rsp]\n  mov [rcx+80], rax\n  stmxcsr [rcx+88]\n  fnstcw [rcx+92]\n"
        "  movdqu [rcx+96], xmm6\n  movdqu [rcx+112], xmm7\n  movdqu [rcx+128], xmm8\n  movdqu [rcx+144], xmm9\n"
        "  movdqu [rcx+160], xmm10\n  movdqu [rcx+176], xmm11\n  movdqu [rcx+192], xmm12\n  movdqu [rcx+208], xmm13\n"
        "  movdqu [rcx+224], xmm14\n  movdqu [rcx+240], xmm15\n"
        "  xor eax, eax\n  ret\n"
        "_win_longjmp:\n"
        "  mov rbx, [rcx+8]\n  mov rbp, [rcx+24]\n  mov rsi, [rcx+32]\n  mov rdi, [rcx+40]\n"
        "  mov r12, [rcx+48]\n  mov r13, [rcx+56]\n  mov r14, [rcx+64]\n  mov r15, [rcx+72]\n"
        "  ldmxcsr [rcx+88]\n  fldcw [rcx+92]\n"
        "  movdqu xmm6, [rcx+96]\n  movdqu xmm7, [rcx+112]\n  movdqu xmm8, [rcx+128]\n  movdqu xmm9, [rcx+144]\n"
        "  movdqu xmm10, [rcx+160]\n  movdqu xmm11, [rcx+176]\n  movdqu xmm12, [rcx+192]\n  movdqu xmm13, [rcx+208]\n"
        "  movdqu xmm14, [rcx+224]\n  movdqu xmm15, [rcx+240]\n"
        "  mov eax, edx\n  test eax, eax\n  jnz 1f\n  inc eax\n1:\n"
        "  mov rsp, [rcx+16]\n  jmp qword ptr [rcx+80]\n"
        ".att_syntax\n");
extern char win_setjmp[], win_longjmp[];
__attribute__((constructor)) static void setjmp_reg(void) {
    shim_register("__intrinsic_setjmp", win_setjmp);
    shim_register("longjmp", win_longjmp);
}

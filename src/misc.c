// Small DLLs: advapi32, shell32, ole32, gdi32, winmm, dbghelp, dxgi, d3d12, steam_api64.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "shim.h"

#define E_FAIL 0x80004005u
#define REGDB_E_CLASSNOTREG 0x80040154u

// ---- advapi32: no registry
SHIM(long, RegOpenKeyExA, void *k, const char *s, DWORD o, DWORD sam, void **out) { FIXME("RegOpenKeyExA(%s)", s); (void)k; (void)o; (void)sam; (void)out; TRACE("RegOpenKeyExA(%s)", s); return 2; }
// Only HARDWARE\DESCRIPTION\System\CentralProcessor\0 values are provided.
SHIM(long, RegGetValueA, void *k, const char *s, const char *v, DWORD f, DWORD *t, void *d, DWORD *n) {
    (void)k; (void)f;
    TRACE("RegGetValueA(%s, %s)", s, v);
    if (!s || !strstr(s, "CentralProcessor") || !v) return 2;
    uint8_t buf[128];
    DWORD type, len;
    if (!strcmp(v, "ProcessorNameString")) {
        const char *name = "Apple Silicon (Rosetta 2)";
        type = 1; len = (DWORD)strlen(name) + 1; memcpy(buf, name, len);
    } else if (!strcmp(v, "~MHz")) {
        type = 4; len = 4; *(DWORD *)buf = 3200;
    } else return 2;
    if (t) *t = type;
    if (d && n && *n < len) { *n = len; return 234; }
    if (d) memcpy(d, buf, len);
    if (n) *n = len;
    return 0;
}
SHIM(long, RegQueryValueExA, void *k, const char *v, DWORD *r, DWORD *t, void *d, DWORD *n) { FIXME("RegQueryValueExA(%s)", v ? v : "(null)"); (void)k; (void)v; (void)r; (void)t; (void)d; (void)n; return 2; }
SHIM(long, RegEnumKeyExA, void *k, DWORD i, char *n, DWORD *nl, DWORD *r, char *c, DWORD *cl, void *ft) { FIXME("RegEnumKeyExA(%u)", i); (void)k; (void)i; (void)n; (void)nl; (void)r; (void)c; (void)cl; (void)ft; return 259; }
SHIM(long, RegCloseKey, void *k) { (void)k; return 0; }

// ---- ole32
SHIM(long, CoInitializeEx, void *r, DWORD m) { (void)r; (void)m; return 0; }
SHIM(void, CoUninitialize, void) {}
uint32_t audio_create_instance(const void *clsid, const void *iid, void **out);
SHIM(long, CoCreateInstance, const void *clsid, void *outer, DWORD ctx, const void *iid, void **out) {
    (void)outer; (void)ctx;
    uint32_t r = audio_create_instance(clsid, iid, out);
    if (r == REGDB_E_CLASSNOTREG) {
        const uint32_t *c = clsid;
        LOG("CoCreateInstance({%08x-...}) -> CLASSNOTREG", c[0]);
        *out = NULL;
    }
    return (long)r;
}
SHIM(long, CoCreateGuid, uint8_t *g) { arc4random_buf(g, 16); return 0; }
SHIM(void *, CoTaskMemAlloc, size_t n) { return malloc(n); }
SHIM(void, CoTaskMemFree, void *p) { free(p); }
SHIM(long, PropVariantClear, void *p) { memset(p, 0, 24); return 0; }

// ---- shell32
// Every known folder maps to ~/Library/Application Support (the game appends its own subfolder).
SHIM(long, SHGetKnownFolderPath, const void *id, DWORD fl, void *tok, WCHAR **out) {
    (void)id; (void)fl; (void)tok;
    char p[1100];
    snprintf(p, sizeof p, "Z:%s/Library/Application Support", getenv("HOME"));
    for (char *c = p; *c; c++) if (*c == '/') *c = '\\';
    *out = u2w(p);
    TRACE("SHGetKnownFolderPath -> %s", p);
    return 0;
}
SHIM(void *, ExtractIconW, void *i, const WCHAR *f, unsigned n) { FIXME("ExtractIconW"); (void)i; (void)f; (void)n; return NULL; }
SHIM(int, SHFileOperationW, void *op) { FIXME("SHFileOperationW"); (void)op; return 1; }
SHIM(void, DragFinish, void *d) { (void)d; }
SHIM(unsigned, DragQueryFileW, void *d, unsigned i, WCHAR *f, unsigned n) { FIXME("DragQueryFileW"); (void)d; (void)i; (void)f; (void)n; return 0; }

// ---- gdi32 / winmm
SHIM(void *, CreateSolidBrush, DWORD c) { (void)c; return (void *)1; }
SHIM(unsigned, timeBeginPeriod, unsigned p) { (void)p; return 0; }

// ---- dbghelp (crash reporting only)
SHIM(WBOOL, SymInitialize, void *p, const char *s, WBOOL i) { FIXME("SymInitialize"); (void)p; (void)s; (void)i; return 0; }
SHIM(DWORD, SymSetOptions, DWORD o) { return o; }
SHIM(WBOOL, MiniDumpWriteDump, void *a, DWORD b, void *c, int d, void *e, void *f, void *g) { FIXME("MiniDumpWriteDump"); (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; return 0; }
SHIM(WBOOL, StackWalk64, DWORD m, void *p, void *t, void *f, void *c, void *r, void *a, void *b, void *x) { FIXME("StackWalk64"); (void)m; (void)p; (void)t; (void)f; (void)c; (void)r; (void)a; (void)b; (void)x; return 0; }

// ---- steam_api64: pretend Steam is up, with inert interfaces (no callbacks ever arrive)
static uint8_t g_steam_iface[6][64];
SHIM(WBOOL, SteamAPI_RestartAppIfNecessary, uint32_t app) { LOG("SteamAPI_RestartAppIfNecessary(%u) -> false", app); return 0; }
SHIM(int, SteamInternal_SteamAPI_Init, const char *ver, char *err) { (void)ver; (void)err; LOG("SteamAPI_Init -> OK (fake)"); return 0; }
SHIM(void, SteamAPI_Shutdown, void) {}
SHIM(int32_t, SteamAPI_GetHSteamPipe, void) { return 1; }
SHIM(void *, SteamAPI_SteamApps_v009, void) { return g_steam_iface[0]; }
SHIM(void *, SteamAPI_SteamFriends_v018, void) { return g_steam_iface[1]; }
SHIM(void *, SteamAPI_SteamInput_v007, void) { return g_steam_iface[2]; }
SHIM(void *, SteamAPI_SteamUserStats_v013, void) { return g_steam_iface[3]; }
SHIM(void *, SteamAPI_SteamUser_v023, void) { return g_steam_iface[4]; }
SHIM(void *, SteamAPI_SteamUtils_v011, void) { return g_steam_iface[5]; }
SHIM(void, SteamAPI_ManualDispatch_Init, void) {}
SHIM(void, SteamAPI_ManualDispatch_RunFrame, int32_t pipe) { (void)pipe; }
SHIM(WBOOL, SteamAPI_ManualDispatch_GetNextCallback, int32_t pipe, void *msg) { (void)pipe; (void)msg; return 0; }
SHIM(void, SteamAPI_ManualDispatch_FreeLastCallback, int32_t pipe) { (void)pipe; }
SHIM(WBOOL, SteamAPI_ManualDispatch_GetAPICallResult, int32_t p, uint64_t c, void *cb, int n, int id, WBOOL *f) { (void)p; (void)c; (void)cb; (void)n; (void)id; if (f) *f = 1; return 0; }
SHIM(const char *, SteamAPI_ISteamApps_GetCurrentGameLanguage, void *s) { (void)s; return "english"; }
SHIM(const char *, SteamAPI_ISteamApps_GetAvailableGameLanguages, void *s) { (void)s; return "english"; }
SHIM(WBOOL, SteamAPI_ISteamApps_GetCurrentBetaName, void *s, char *n, int l) { (void)s; if (n && l) n[0] = 0; return 0; }
SHIM(int, SteamAPI_ISteamApps_GetAppBuildId, void *s) { (void)s; return 0; }
SHIM(uint32_t, SteamAPI_ISteamUtils_GetAppID, void *s) { (void)s; return 499170; }
SHIM(WBOOL, SteamAPI_ISteamUtils_IsRunningOnSteamHardware, void *s) { (void)s; return 0; }
SHIM(uint64_t, SteamAPI_ISteamUser_GetSteamID, void *s) { (void)s; return 76561197960265728ull; }
SHIM(WBOOL, SteamAPI_ISteamUserStats_RequestUserStats, void *s, uint64_t id) { (void)s; (void)id; return 0; }
SHIM(WBOOL, SteamAPI_ISteamUserStats_GetAchievement, void *s, const char *n, WBOOL *a) { (void)s; (void)n; if (a) *a = 0; return 0; }
SHIM(WBOOL, SteamAPI_ISteamUserStats_SetAchievement, void *s, const char *n) { (void)s; (void)n; return 0; }
SHIM(WBOOL, SteamAPI_ISteamUserStats_StoreStats, void *s) { (void)s; return 0; }
SHIM(WBOOL, SteamAPI_ISteamInput_Init, void *s, WBOOL explicit_frame) { (void)s; (void)explicit_frame; return 0; }
SHIM(uint64_t, SteamAPI_ISteamInput_GetControllerForGamepadIndex, void *s, int i) { (void)s; (void)i; return 0; }
SHIM(int, SteamAPI_ISteamInput_GetInputTypeForHandle, void *s, uint64_t h) { (void)s; (void)h; return 0; }

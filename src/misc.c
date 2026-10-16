// Small DLLs: advapi32 (registry), ole32 (COM), shell32, gdi32, winmm and dbghelp.
#include "shim.h"
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------- advapi32: registry
// There is no registry. The game only reads the CPU name for its system-info log.
#define CPU_KEY "HARDWARE\\DESCRIPTION\\System\\CentralProcessor"

SHIM(LONG, RegGetValueA, HANDLE key, const char *subkey, const char *value, DWORD flags, DWORD *type, void *data,
     DWORD *size) {
    TRACE("RegGetValueA(%s, %s)", subkey, value);
    if (!subkey || !value || !strstr(subkey, CPU_KEY)) return ERROR_FILE_NOT_FOUND;

    uint8_t buf[64];
    DWORD value_type, len;
    if (!strcmp(value, "ProcessorNameString")) {
        const char *name = "Apple Silicon (Rosetta 2)";
        value_type = REG_SZ;
        len = (DWORD)strlen(name) + 1;
        memcpy(buf, name, len);
    } else if (!strcmp(value, "~MHz")) {
        value_type = REG_DWORD;
        len = sizeof(DWORD);
        *(DWORD *)buf = 3200;
    } else {
        return ERROR_FILE_NOT_FOUND;
    }
    if (type) *type = value_type;
    if (data && size && *size < len) {
        *size = len;
        return ERROR_MORE_DATA;
    }
    if (data) memcpy(data, buf, len);
    if (size) *size = len;
    return ERROR_SUCCESS;
}

SHIM(LONG, RegOpenKeyExA, HANDLE key, const char *subkey, DWORD options, DWORD access, HANDLE *out) {
    FIXME("RegOpenKeyExA(%s)", subkey);
    return ERROR_FILE_NOT_FOUND;
}

SHIM(LONG, RegQueryValueExA, HANDLE key, const char *value, DWORD *reserved, DWORD *type, void *data, DWORD *size) {
    FIXME("RegQueryValueExA(%s)", value ? value : "(default)");
    return ERROR_FILE_NOT_FOUND;
}

SHIM(LONG, RegEnumKeyExA, HANDLE key, DWORD index, char *name, DWORD *name_len, DWORD *reserved, char *cls,
     DWORD *cls_len, FILETIME *written) {
    FIXME("RegEnumKeyExA(%u)", index);
    return ERROR_NO_MORE_ITEMS;
}

SHIM(LONG, RegCloseKey, HANDLE key) { return ERROR_SUCCESS; }

// ---------------------------------------------------------------- ole32: COM
SHIM(HRESULT, CoInitializeEx, void *reserved, DWORD model) { return S_OK; }
SHIM(void, CoUninitialize, void) {}

// The only COM class the game creates is MMDeviceEnumerator (for audio).
SHIM(HRESULT, CoCreateInstance, const GUID *clsid, void *outer, DWORD context, const GUID *iid, void **out) {
    HRESULT r = audio_create_instance(clsid, iid, out);
    if (r == REGDB_E_CLASSNOTREG) {
        LOG("CoCreateInstance({%08x-...}) -> class not registered", clsid->Data1);
        *out = NULL;
    }
    return r;
}

SHIM(HRESULT, CoCreateGuid, GUID *guid) {
    arc4random_buf(guid, sizeof *guid);
    return S_OK;
}

SHIM(void *, CoTaskMemAlloc, size_t size) { return malloc(size); }
SHIM(void, CoTaskMemFree, void *p) { free(p); }

SHIM(HRESULT, PropVariantClear, PROPVARIANT *pv) {
    if (pv->vt == VT_LPWSTR) free(pv->pwszVal);
    if (pv->vt == VT_BLOB) free(pv->blob.pBlobData);
    memset(pv, 0, sizeof *pv);
    return S_OK;
}

// ---------------------------------------------------------------- shell32
// Every known folder maps to ~/Library/Application Support; the game appends its own subfolder.
SHIM(HRESULT, SHGetKnownFolderPath, const GUID *id, DWORD flags, HANDLE token, WCHAR **out) {
    char path[1100];
    snprintf(path, sizeof path, "Z:%s/Library/Application Support", getenv("HOME"));
    for (char *c = path; *c; c++)
        if (*c == '/') *c = '\\';
    *out = u2w(path);
    TRACE("SHGetKnownFolderPath -> %s", path);
    return S_OK;
}

SHIM(HANDLE, ExtractIconW, HANDLE instance, const WCHAR *file, UINT index) {
    FIXME("ExtractIconW");
    return NULL;
}

SHIM(int, SHFileOperationW, void *operation) {
    FIXME("SHFileOperationW");
    return 1; // non-zero: failed
}

SHIM(void, DragFinish, HANDLE drop) {}

SHIM(UINT, DragQueryFileW, HANDLE drop, UINT index, WCHAR *file, UINT size) {
    FIXME("DragQueryFileW");
    return 0;
}

// ---------------------------------------------------------------- gdi32, winmm
SHIM(HANDLE, CreateSolidBrush, DWORD color) { return (HANDLE)1; }
SHIM(UINT, timeBeginPeriod, UINT period) { return 0; }

// ---------------------------------------------------------------- dbghelp: only used for crash dumps
SHIM(WBOOL, SymInitialize, HANDLE process, const char *search_path, WBOOL invade) {
    FIXME("SymInitialize");
    return false;
}

SHIM(DWORD, SymSetOptions, DWORD options) { return options; }

SHIM(WBOOL, MiniDumpWriteDump, HANDLE process, DWORD pid, HANDLE file, int type, void *exception, void *user,
     void *callback) {
    FIXME("MiniDumpWriteDump");
    return false;
}

SHIM(WBOOL, StackWalk64, DWORD machine, HANDLE process, HANDLE thread, void *frame, void *context, void *read,
     void *table_access, void *module_base, void *translate) {
    FIXME("StackWalk64");
    return false;
}

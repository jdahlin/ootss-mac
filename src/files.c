// kernel32 files: CreateFile/ReadFile/WriteFile (including overlapped and *Ex), directory search,
// file mappings, path conversion and console output.
#include "kernel32.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// Map a POSIX errno to the closest Win32 error code.
static void set_error_from_errno(int err) {
    set_last_error(err == ENOENT    ? ERROR_FILE_NOT_FOUND
                   : err == ENOTDIR ? ERROR_PATH_NOT_FOUND
                   : err == EEXIST  ? ERROR_ALREADY_EXISTS
                                    : ERROR_ACCESS_DENIED);
}

// UTF-16 Windows path -> malloc'd UTF-8 Unix path.
static char *unix_path(const WCHAR *path) {
    char *utf8 = w2u(path), *p = win_to_unix_path(utf8);
    free(utf8);
    return p;
}

uint64_t timespec_to_filetime(struct timespec t) {
    return (uint64_t)t.tv_sec * 10000000ull + t.tv_nsec / 100 + FILETIME_UNIX_EPOCH;
}

static FILETIME filetime(struct timespec t) {
    uint64_t v = timespec_to_filetime(t);
    return (FILETIME){(DWORD)v, (DWORD)(v >> 32)};
}

static int64_t overlapped_offset(const OVERLAPPED *o) { return (int64_t)((uint64_t)o->OffsetHigh << 32 | o->Offset); }

static void complete_overlapped(OVERLAPPED *o, ssize_t bytes) {
    o->Internal = 0; // STATUS_SUCCESS
    o->InternalHigh = bytes;
}

// ---------------------------------------------------------------- console
static WHandle g_std_handles[3] = {
    {WHANDLE_MAGIC, H_FILE, STDIN_FILENO, NULL},
    {WHANDLE_MAGIC, H_FILE, STDOUT_FILENO, NULL},
    {WHANDLE_MAGIC, H_FILE, STDERR_FILENO, NULL},
};

static bool is_std_handle(const WHandle *h) { return h >= g_std_handles && h < g_std_handles + 3; }

SHIM(HANDLE, GetStdHandle, DWORD which) {
    // STD_INPUT_HANDLE (-10), STD_OUTPUT_HANDLE (-11), STD_ERROR_HANDLE (-12)
    DWORD index = STD_INPUT_HANDLE - which;
    return index < 3 ? &g_std_handles[index] : INVALID_HANDLE_VALUE;
}

SHIM(WBOOL, GetConsoleMode, HANDLE console, DWORD *mode) { return false; } // not a console: plain text output
SHIM(WBOOL, SetConsoleMode, HANDLE console, DWORD mode) { return true; }
SHIM(WBOOL, SetConsoleOutputCP, UINT code_page) { return true; }

// Console output gets the same "seconds since launch" prefix as loader logs, at each line start.
static void console_write(int fd, const char *buf, DWORD size) {
    static bool at_line_start[3] = {true, true, true};
    for (DWORD i = 0; i < size;) {
        if (at_line_start[fd]) {
            dprintf(fd, "%8.3f ", log_time());
            at_line_start[fd] = false;
        }
        const char *newline = memchr(buf + i, '\n', size - i);
        DWORD len = newline ? (DWORD)(newline - (buf + i)) + 1 : size - i;
        write(fd, buf + i, len);
        if (newline) at_line_start[fd] = true;
        i += len;
    }
}

// ---------------------------------------------------------------- open, read, write
static HANDLE open_file(char *path, DWORD access, DWORD disposition) {
    int flags = (access & GENERIC_WRITE) ? ((access & GENERIC_READ) ? O_RDWR : O_WRONLY) : O_RDONLY;
    switch (disposition) {
    case CREATE_NEW: flags |= O_CREAT | O_EXCL; break;
    case CREATE_ALWAYS: flags |= O_CREAT | O_TRUNC; break;
    case OPEN_ALWAYS: flags |= O_CREAT; break;
    case TRUNCATE_EXISTING: flags |= O_TRUNC; break;
    default: break; // OPEN_EXISTING
    }
    int fd = open(path, flags, 0644);
    TRACE("CreateFile(%s, %#x, %u) -> %d", path, access, disposition, fd);
    if (fd < 0) {
        set_error_from_errno(errno);
        free(path);
        return INVALID_HANDLE_VALUE;
    }
    struct stat st;
    if (!fstat(fd, &st) && S_ISDIR(st.st_mode) && disposition != OPEN_EXISTING) {
        close(fd);
        free(path);
        set_last_error(ERROR_ACCESS_DENIED);
        return INVALID_HANDLE_VALUE;
    }
    WHandle *h = handle_new(H_FILE);
    h->fd = fd;
    h->obj = path;
    set_last_error(ERROR_SUCCESS);
    return h;
}

SHIM(HANDLE, CreateFileW, const WCHAR *name, DWORD access, DWORD share, void *security, DWORD disposition, DWORD flags,
     HANDLE template_file) {
    return open_file(unix_path(name), access, disposition);
}

SHIM(HANDLE, CreateFileA, const char *name, DWORD access, DWORD share, void *security, DWORD disposition, DWORD flags,
     HANDLE template_file) {
    return open_file(win_to_unix_path(name), access, disposition);
}

SHIM(WBOOL, ReadFile, WHandle *h, void *buf, DWORD size, DWORD *read_bytes, OVERLAPPED *overlapped) {
    ssize_t r = overlapped ? pread(h->fd, buf, size, overlapped_offset(overlapped)) : read(h->fd, buf, size);
    TRACE("ReadFile(fd=%d, %u bytes) -> %zd", h->fd, size, r);
    if (r < 0) {
        set_error_from_errno(errno);
        return false;
    }
    if (read_bytes) *read_bytes = (DWORD)r;
    if (overlapped) complete_overlapped(overlapped, r);
    return true;
}

SHIM(WBOOL, WriteFile, WHandle *h, const void *buf, DWORD size, DWORD *written, OVERLAPPED *overlapped) {
    if (is_std_handle(h) && h->fd != STDIN_FILENO) {
        console_write(h->fd, buf, size);
        if (written) *written = size;
        return true;
    }
    ssize_t r = overlapped ? pwrite(h->fd, buf, size, overlapped_offset(overlapped)) : write(h->fd, buf, size);
    if (r < 0) {
        set_error_from_errno(errno);
        return false;
    }
    if (written) *written = (DWORD)r;
    return true;
}

// The *Ex variants complete immediately; the completion routine runs at the next alertable wait.
SHIM(WBOOL, ReadFileEx, WHandle *h, void *buf, DWORD size, OVERLAPPED *overlapped, CompletionRoutine done) {
    ssize_t r = pread(h->fd, buf, size, overlapped_offset(overlapped));
    TRACE("ReadFileEx(fd=%d, %u bytes at %lld) -> %zd", h->fd, size, (long long)overlapped_offset(overlapped), r);
    if (r < 0) {
        set_error_from_errno(errno);
        return false;
    }
    complete_overlapped(overlapped, r);
    queue_apc(done, ERROR_SUCCESS, (DWORD)r, overlapped);
    return true;
}

SHIM(WBOOL, WriteFileEx, WHandle *h, const void *buf, DWORD size, OVERLAPPED *overlapped, CompletionRoutine done) {
    ssize_t r = pwrite(h->fd, buf, size, overlapped_offset(overlapped));
    if (r < 0) {
        set_error_from_errno(errno);
        return false;
    }
    complete_overlapped(overlapped, r);
    queue_apc(done, ERROR_SUCCESS, (DWORD)r, overlapped);
    return true;
}

SHIM(WBOOL, FlushFileBuffers, WHandle *h) { return fsync(h->fd) == 0; }

SHIM(DWORD, GetFileSize, WHandle *h, DWORD *size_high) {
    struct stat st;
    if (fstat(h->fd, &st)) return INVALID_FILE_ATTRIBUTES; // INVALID_FILE_SIZE
    if (size_high) *size_high = (DWORD)(st.st_size >> 32);
    return (DWORD)st.st_size;
}

SHIM(WBOOL, GetFileSizeEx, WHandle *h, int64_t *size) {
    struct stat st;
    if (fstat(h->fd, &st)) {
        set_error_from_errno(errno);
        return false;
    }
    *size = st.st_size;
    return true;
}

SHIM(WBOOL, SetFilePointerEx, WHandle *h, int64_t distance, int64_t *new_position, DWORD method) {
    int whence = method == FILE_BEGIN ? SEEK_SET : method == FILE_CURRENT ? SEEK_CUR : SEEK_END;
    off_t r = lseek(h->fd, distance, whence);
    if (r < 0) {
        set_error_from_errno(errno);
        return false;
    }
    if (new_position) *new_position = r;
    return true;
}

SHIM(WBOOL, GetFileTime, WHandle *h, FILETIME *created, FILETIME *accessed, FILETIME *written) {
    struct stat st;
    if (fstat(h->fd, &st)) return false;
    if (created) *created = filetime(st.st_birthtimespec);
    if (accessed) *accessed = filetime(st.st_atimespec);
    if (written) *written = filetime(st.st_mtimespec);
    return true;
}

SHIM(WBOOL, CloseHandle, WHandle *h) {
    if (!h || h == INVALID_HANDLE_VALUE || (intptr_t)h < 0 || is_std_handle(h)) return true; // pseudo handles
    if (!handle_is_ours(h)) {
        if (g_dmn_ev.close) g_dmn_ev.close(h);
        return true;
    }
    if (h->type == H_FILE && h->fd >= 0) {
        close(h->fd);
        free(h->obj); // the path
    }
    if (h->type == H_THREAD) return true; // the thread still uses its handle
    free(h);
    return true;
}

// ---------------------------------------------------------------- files and directories by name
SHIM(DWORD, GetFileAttributesW, const WCHAR *name) {
    char *path = unix_path(name);
    struct stat st;
    int r = stat(path, &st), err = errno;
    free(path);
    if (r) {
        set_error_from_errno(err);
        return INVALID_FILE_ATTRIBUTES;
    }
    return S_ISDIR(st.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
}

SHIM(WBOOL, CreateDirectoryW, const WCHAR *name, void *security) {
    char *path = unix_path(name);
    int r = mkdir(path, 0755), err = errno;
    free(path);
    if (r) set_error_from_errno(err);
    return r == 0;
}

SHIM(WBOOL, DeleteFileW, const WCHAR *name) {
    char *path = unix_path(name);
    int r = unlink(path), err = errno;
    free(path);
    if (r) set_error_from_errno(err);
    return r == 0;
}

static WBOOL rename_file(const WCHAR *from, const WCHAR *to) {
    char *src = unix_path(from), *dst = unix_path(to);
    int r = rename(src, dst), err = errno;
    free(src);
    free(dst);
    if (r) set_error_from_errno(err);
    return r == 0;
}

SHIM(WBOOL, MoveFileW, const WCHAR *from, const WCHAR *to) { return rename_file(from, to); }

SHIM(WBOOL, ReplaceFileW, const WCHAR *replaced, const WCHAR *replacement, const WCHAR *backup, DWORD flags,
     void *exclude, void *reserved) {
    return rename_file(replacement, replaced);
}

SHIM(WBOOL, SetCurrentDirectoryW, const WCHAR *name) {
    char *path = unix_path(name);
    int r = chdir(path);
    free(path);
    return r == 0;
}

// Write an absolute Unix path as a Windows path ("Z:\..."). Returns the length, or the needed
// size including the terminator when it does not fit.
static DWORD put_windows_path(const char *unix_abs, WCHAR *buf, DWORD size) {
    char tmp[PATH_MAX + 4];
    snprintf(tmp, sizeof tmp, "Z:%s", unix_abs);
    for (char *c = tmp; *c; c++)
        if (*c == '/') *c = '\\';
    WCHAR *w = u2w(tmp);
    DWORD len = (DWORD)wlen(w);
    if (len + 1 > size) {
        free(w);
        return len + 1;
    }
    memcpy(buf, w, (len + 1) * sizeof(WCHAR));
    free(w);
    return len;
}

SHIM(DWORD, GetFullPathNameW, const WCHAR *name, DWORD size, WCHAR *buf, WCHAR **file_part) {
    char *utf8 = w2u(name), *path = win_to_unix_path(utf8);
    bool absolute = (utf8[0] && utf8[1] == ':') || utf8[0] == '\\' || utf8[0] == '/';
    char full[PATH_MAX * 2], cwd[PATH_MAX];
    if (absolute)
        snprintf(full, sizeof full, "%s", path);
    else
        snprintf(full, sizeof full, "%s/%s", getcwd(cwd, sizeof cwd) ? cwd : ".", path);
    free(utf8);
    free(path);

    DWORD r = put_windows_path(full, buf, size);
    if (file_part && r < size) {
        *file_part = NULL;
        for (WCHAR *c = buf; *c; c++)
            if (*c == '\\') *file_part = c + 1;
    }
    return r;
}

// ---------------------------------------------------------------- directory search
typedef struct {
    DIR *dir;
    char path[PATH_MAX];
    char pattern[256];
} Search;

static bool next_match(Search *s, WIN32_FIND_DATAW *out) {
    struct dirent *e;
    while ((e = readdir(s->dir))) {
        if (fnmatch(s->pattern, e->d_name, FNM_CASEFOLD)) continue;
        char full[PATH_MAX * 2];
        snprintf(full, sizeof full, "%s/%s", s->path, e->d_name);
        struct stat st;
        if (stat(full, &st)) continue;
        memset(out, 0, sizeof *out);
        out->dwFileAttributes = S_ISDIR(st.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
        out->ftCreationTime = filetime(st.st_birthtimespec);
        out->ftLastAccessTime = filetime(st.st_atimespec);
        out->ftLastWriteTime = filetime(st.st_mtimespec);
        out->nFileSizeHigh = (DWORD)(st.st_size >> 32);
        out->nFileSizeLow = (DWORD)st.st_size;
        WCHAR *name = u2w(e->d_name);
        size_t len = wlen(name), max = sizeof out->cFileName / sizeof(WCHAR) - 1;
        memcpy(out->cFileName, name, (len < max ? len : max) * sizeof(WCHAR));
        free(name);
        return true;
    }
    return false;
}

SHIM(HANDLE, FindFirstFileExW, const WCHAR *name, int info_level, WIN32_FIND_DATAW *out, int search_op, void *filter,
     DWORD flags) {
    char *path = unix_path(name);
    Search *s = calloc(1, sizeof *s);
    char *slash = strrchr(path, '/');
    if (slash) {
        *slash = 0;
        snprintf(s->path, sizeof s->path, "%s", *path ? path : "/");
        snprintf(s->pattern, sizeof s->pattern, "%s", slash + 1);
    } else {
        snprintf(s->path, sizeof s->path, ".");
        snprintf(s->pattern, sizeof s->pattern, "%s", path);
    }
    if (!strcmp(s->pattern, "*.*")) snprintf(s->pattern, sizeof s->pattern, "*"); // DOS for "everything"
    free(path);

    s->dir = opendir(s->path);
    TRACE("FindFirstFile(%s / %s) -> %p", s->path, s->pattern, (void *)s->dir);
    if (!s->dir || !next_match(s, out)) {
        if (s->dir) closedir(s->dir);
        free(s);
        set_last_error(ERROR_FILE_NOT_FOUND);
        return INVALID_HANDLE_VALUE;
    }
    WHandle *h = handle_new(H_FIND);
    h->obj = s;
    return h;
}

SHIM(WBOOL, FindNextFileW, WHandle *h, WIN32_FIND_DATAW *out) {
    if (next_match(h->obj, out)) return true;
    set_last_error(ERROR_NO_MORE_FILES);
    return false;
}

SHIM(WBOOL, FindClose, WHandle *h) {
    closedir(((Search *)h->obj)->dir);
    free(h->obj);
    free(h);
    return true;
}

// ---------------------------------------------------------------- file mappings
typedef struct {
    int fd; // -1 for anonymous (pagefile-backed) mappings
    uint64_t size;
} Mapping;

static HANDLE create_mapping(WHandle *file, DWORD size_high, DWORD size_low) {
    Mapping *m = calloc(1, sizeof *m);
    m->size = (uint64_t)size_high << 32 | size_low;
    m->fd = -1;
    if ((HANDLE)file != INVALID_HANDLE_VALUE) {
        m->fd = dup(file->fd);
        struct stat st;
        if (m->fd >= 0 && !m->size && !fstat(m->fd, &st)) m->size = st.st_size;
    }
    WHandle *h = handle_new(H_MAPPING);
    h->obj = m;
    return h;
}

SHIM(HANDLE, CreateFileMappingW, WHandle *file, void *security, DWORD protect, DWORD size_high, DWORD size_low,
     const WCHAR *name) {
    return create_mapping(file, size_high, size_low);
}

SHIM(HANDLE, CreateFileMappingA, WHandle *file, void *security, DWORD protect, DWORD size_high, DWORD size_low,
     const char *name) {
    return create_mapping(file, size_high, size_low);
}

SHIM(void *, MapViewOfFile, WHandle *h, DWORD access, DWORD offset_high, DWORD offset_low, size_t size) {
    Mapping *m = h->obj;
    uint64_t offset = (uint64_t)offset_high << 32 | offset_low;
    if (!size) size = m->size - offset;
    bool writable = access & FILE_MAP_WRITE;
    void *p = m->fd < 0 ? mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0)
                        : mmap(NULL, size, PROT_READ | (writable ? PROT_WRITE : 0), writable ? MAP_SHARED : MAP_PRIVATE,
                               m->fd, (off_t)offset);
    return p == MAP_FAILED ? NULL : p;
}

SHIM(WBOOL, UnmapViewOfFile, void *view) {
    FIXME("UnmapViewOfFile(%p): leaked (the view size is not tracked)", view);
    return true;
}

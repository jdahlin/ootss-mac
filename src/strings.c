// UTF-16 <-> UTF-8 conversion, Windows path translation and Windows-style printf.
#include "shim.h"
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#define HIGH_SURROGATE 0xD800
#define LOW_SURROGATE  0xDC00
#define SUPPLEMENTARY  0x10000 // first code point that needs a surrogate pair

size_t wlen(const WCHAR *s) {
    size_t n = 0;
    while (s && s[n]) n++;
    return n;
}

char *w2u_n(const WCHAR *s, long n) {
    if (!s) return NULL;
    if (n < 0) n = (long)wlen(s);
    char *out = malloc(n * 3 + 1), *p = out;
    for (long i = 0; i < n; i++) {
        uint32_t c = s[i];
        if (c >= HIGH_SURROGATE && c < LOW_SURROGATE && i + 1 < n)
            c = SUPPLEMENTARY + ((c - HIGH_SURROGATE) << 10) + (s[++i] - LOW_SURROGATE);
        if (c < 0x80) {
            *p++ = c;
        } else if (c < 0x800) {
            *p++ = 0xC0 | c >> 6;
            *p++ = 0x80 | (c & 0x3F);
        } else if (c < 0x10000) {
            *p++ = 0xE0 | c >> 12;
            *p++ = 0x80 | (c >> 6 & 0x3F);
            *p++ = 0x80 | (c & 0x3F);
        } else {
            *p++ = 0xF0 | c >> 18;
            *p++ = 0x80 | (c >> 12 & 0x3F);
            *p++ = 0x80 | (c >> 6 & 0x3F);
            *p++ = 0x80 | (c & 0x3F);
        }
    }
    *p = 0;
    return out;
}

char *w2u(const WCHAR *s) { return w2u_n(s, -1); }

WCHAR *u2w(const char *s) {
    if (!s) return NULL;
    WCHAR *out = malloc((strlen(s) + 1) * 2 * sizeof(WCHAR)), *p = out;
    for (const uint8_t *u = (const uint8_t *)s; *u;) {
        uint32_t c = *u++;
        if (c >= 0xF0) {
            c = (c & 0x07) << 18 | (u[0] & 0x3F) << 12 | (u[1] & 0x3F) << 6 | (u[2] & 0x3F);
            u += 3;
        } else if (c >= 0xE0) {
            c = (c & 0x0F) << 12 | (u[0] & 0x3F) << 6 | (u[1] & 0x3F);
            u += 2;
        } else if (c >= 0xC0) {
            c = (c & 0x1F) << 6 | (u[0] & 0x3F);
            u += 1;
        }
        if (c >= SUPPLEMENTARY) {
            c -= SUPPLEMENTARY;
            *p++ = HIGH_SURROGATE + (c >> 10);
            *p++ = LOW_SURROGATE + (c & 0x3FF);
        } else {
            *p++ = c;
        }
    }
    *p = 0;
    return out;
}

// "Z:\foo\bar" -> "/foo/bar". Any drive letter maps to / (best effort), "\\?\" prefixes are dropped.
char *win_to_unix_path(const char *p) {
    char drive = p[0] | 0x20; // lower case
    if (drive >= 'a' && drive <= 'z' && p[1] == ':') p += 2;
    if (!strncmp(p, "\\\\?\\", 4)) return win_to_unix_path(p + 4);
    char *out = strdup(p);
    for (char *c = out; *c; c++)
        if (*c == '\\') *c = '/';
    return out;
}

// ---------------------------------------------------------------- printf
// Windows printf semantics differ from macOS: 'l' is 32 bits, %S / %ls are UTF-16, and there are
// MSVC size prefixes (I, I32, I64). Arguments come from an x64 va_list: an array of 8-byte slots.

typedef struct {
    char *buf;
    size_t cap, len; // len keeps counting past cap, for the would-be length
} Output;

static void put(Output *o, const char *s, size_t n) {
    if (o->len < o->cap) memcpy(o->buf + o->len, s, o->len + n < o->cap ? n : o->cap - o->len);
    o->len += n;
}

static void put_formatted(Output *o, const char *spec, ...) {
    va_list ap, copy;
    va_start(ap, spec);
    va_copy(copy, ap);
    int n = vsnprintf(NULL, 0, spec, ap);
    char *tmp = malloc(n + 1);
    vsnprintf(tmp, n + 1, spec, copy);
    put(o, tmp, n);
    free(tmp);
    va_end(copy);
    va_end(ap);
}

// Size prefix of a conversion, in bytes; `wide` is set for 'l' (wide string or char) and 'h' (narrow).
static const char *parse_size(const char *f, int *size, int *wide) {
    *size = 4;
    *wide = -1;
    for (;;) {
        if (f[0] == 'h' && f[1] == 'h') {
            *size = 1;
            *wide = 0;
            f += 2;
        } else if (f[0] == 'h') {
            *size = 2;
            *wide = 0;
            f += 1;
        } else if (f[0] == 'l' && f[1] == 'l') {
            *size = 8;
            f += 2;
        } else if (f[0] == 'l') {
            *size = 4;
            *wide = 1;
            f += 1;
        } else if (!strncmp(f, "I64", 3)) {
            *size = 8;
            f += 3;
        } else if (!strncmp(f, "I32", 3)) {
            *size = 4;
            f += 3;
        } else if (strchr("Izjt", *f)) {
            *size = 8;
            f += 1;
        } else if (*f == 'L') {
            f += 1;
        } else
            return f;
    }
}

int win_vformat(char *out, size_t cap, const char *fmt, uint64_t *args, bool wide_strings) {
    Output o = {out, cap, 0};
    for (const char *f = fmt; *f;) {
        if (*f != '%') {
            const char *next = strchr(f, '%');
            size_t n = next ? (size_t)(next - f) : strlen(f);
            put(&o, f, n);
            f += n;
            continue;
        }
        if (f[1] == '%') {
            put(&o, "%", 1);
            f += 2;
            continue;
        }

        // Rebuild the conversion as a macOS printf spec: flags, width and precision carry over as is.
        char spec[64], *s = spec, *end = spec + sizeof spec - 8;
        *s++ = *f++;
        while (*f && strchr("-+ #0", *f) && s < end) *s++ = *f++;
        if (*f == '*') {
            s += snprintf(s, end - s, "%d", (int)*args++);
            f++;
        } else {
            while (*f >= '0' && *f <= '9' && s < end) *s++ = *f++;
        }
        if (*f == '.') {
            *s++ = *f++;
            if (*f == '*') {
                s += snprintf(s, end - s, "%d", (int)*args++);
                f++;
            } else {
                while (*f >= '0' && *f <= '9' && s < end) *s++ = *f++;
            }
        }
        int size, wide;
        f = parse_size(f, &size, &wide);
        char conversion = *f++;
        uint64_t v = *args++;

        switch (conversion) {
        case 'd':
        case 'i': {
            int64_t x = size == 1 ? (int8_t)v : size == 2 ? (int16_t)v : size == 4 ? (int32_t)v : (int64_t)v;
            strcpy(s, "lld"); // NOLINT: s < end leaves room
            put_formatted(&o, spec, (long long)x);
            break;
        }
        case 'u':
        case 'x':
        case 'X':
        case 'o': {
            uint64_t x = size == 1 ? (uint8_t)v : size == 2 ? (uint16_t)v : size == 4 ? (uint32_t)v : v;
            snprintf(s, 4, "ll%c", conversion);
            put_formatted(&o, spec, (unsigned long long)x);
            break;
        }
        case 'p':
            strcpy(s, "016llX"); // NOLINT: s < end leaves room
            put_formatted(&o, spec, (unsigned long long)v);
            break;
        case 'f':
        case 'F':
        case 'e':
        case 'E':
        case 'g':
        case 'G':
        case 'a':
        case 'A': {
            double d;
            memcpy(&d, &v, sizeof d); // floating point varargs are passed as doubles
            snprintf(s, 2, "%c", conversion);
            put_formatted(&o, spec, d);
            break;
        }
        case 'c':
        case 'C': {
            char c = (char)v;
            put(&o, &c, 1);
            break;
        }
        case 's':
        case 'S': {
            // %s is narrow in printf and wide in wprintf; %S is the opposite; %ls / %hs force it.
            bool w = conversion == 'S' ? !wide_strings : wide_strings;
            if (wide >= 0) w = wide;
            char *converted = v && w ? w2u((const WCHAR *)v) : NULL;
            strcpy(s, "s"); // NOLINT: s < end leaves room
            put_formatted(&o, spec, !v ? "(null)" : w ? converted : (const char *)v);
            free(converted);
            break;
        }
        case 'n': break;
        default: // unknown conversion: print it and do not consume an argument
            put(&o, &conversion, 1);
            args--;
            break;
        }
    }
    if (cap) out[o.len < cap ? o.len : cap - 1] = 0;
    return (int)o.len;
}

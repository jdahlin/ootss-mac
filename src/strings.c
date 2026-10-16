// UTF-16 <-> UTF-8 helpers, Windows path translation, Windows-style printf formatting.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "shim.h"

size_t wlen(const WCHAR *s) {
    size_t n = 0;
    while (s && s[n]) n++;
    return n;
}

char *w2u_n(const WCHAR *s, long n) {
    if (!s) return NULL;
    if (n < 0) n = wlen(s);
    char *o = malloc(n * 3 + 1), *p = o;
    for (long i = 0; i < n; i++) {
        uint32_t c = s[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < n) c = 0x10000 + ((c - 0xD800) << 10) + (s[++i] - 0xDC00);
        if (c < 0x80) *p++ = c;
        else if (c < 0x800) { *p++ = 0xC0 | c >> 6; *p++ = 0x80 | (c & 63); }
        else if (c < 0x10000) { *p++ = 0xE0 | c >> 12; *p++ = 0x80 | (c >> 6 & 63); *p++ = 0x80 | (c & 63); }
        else { *p++ = 0xF0 | c >> 18; *p++ = 0x80 | (c >> 12 & 63); *p++ = 0x80 | (c >> 6 & 63); *p++ = 0x80 | (c & 63); }
    }
    *p = 0;
    return o;
}

char *w2u(const WCHAR *s) { return w2u_n(s, -1); }

WCHAR *u2w(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    WCHAR *o = malloc((n + 1) * 2 * sizeof(WCHAR)), *p = o;
    const uint8_t *u = (const uint8_t *)s;
    while (*u) {
        uint32_t c = *u++;
        if (c >= 0xF0) { c = (c & 7) << 18 | (u[0] & 63) << 12 | (u[1] & 63) << 6 | (u[2] & 63); u += 3; }
        else if (c >= 0xE0) { c = (c & 15) << 12 | (u[0] & 63) << 6 | (u[1] & 63); u += 2; }
        else if (c >= 0xC0) { c = (c & 31) << 6 | (u[0] & 63); u += 1; }
        if (c >= 0x10000) { c -= 0x10000; *p++ = 0xD800 + (c >> 10); *p++ = 0xDC00 + (c & 0x3ff); }
        else *p++ = c;
    }
    *p = 0;
    return o;
}

// "Z:\foo\bar" -> "/foo/bar", "C:\x" -> "/x" (best effort), "a\b" -> "a/b"
char *win_to_unix_path(const char *p) {
    if (((p[0] | 0x20) >= 'a' && (p[0] | 0x20) <= 'z') && p[1] == ':') p += 2;
    if (!strncmp(p, "\\\\?\\", 4)) return win_to_unix_path(p + 4);
    char *o = strdup(p);
    for (char *c = o; *c; c++) if (*c == '\\') *c = '/';
    return o;
}

// Windows printf over an x64 va_list (array of 8-byte slots). Returns would-be length.
int win_vformat(char *out, size_t cap, const char *fmt, uint64_t *args, int wide_strings_default) {
    size_t n = 0;
#define PUT(s, len) do { size_t _l = (len); if (n < cap) memcpy(out + n, s, n + _l < cap ? _l : cap - n); n += _l; } while (0)
    for (const char *f = fmt; *f;) {
        if (*f != '%') { const char *e = strchr(f, '%'); size_t l = e ? (size_t)(e - f) : strlen(f); PUT(f, l); f += l; continue; }
        if (f[1] == '%') { PUT("%", 1); f += 2; continue; }
        char spec[64], *sp = spec;
        *sp++ = *f++;
        while (strchr("-+ #0", *f)) *sp++ = *f++;
        int width = -1, prec = -1;
        if (*f == '*') { width = (int)*args++; f++; sp += snprintf(sp, 16, "%d", width); }
        else while (*f >= '0' && *f <= '9') *sp++ = *f++;
        if (*f == '.') {
            *sp++ = *f++;
            if (*f == '*') { prec = (int)*args++; f++; sp += snprintf(sp, 16, "%d", prec); }
            else while (*f >= '0' && *f <= '9') *sp++ = *f++;
        }
        int size = 4, wide = -1;
        for (;;) {
            if (*f == 'h') { size = f[1] == 'h' ? 1 : 2; wide = 0; f += f[1] == 'h' ? 2 : 1; }
            else if (*f == 'l') { if (f[1] == 'l') { size = 8; f += 2; } else { size = 4; wide = 1; f++; } }
            else if (!strncmp(f, "I64", 3)) { size = 8; f += 3; }
            else if (!strncmp(f, "I32", 3)) { size = 4; f += 3; }
            else if (*f == 'I' || *f == 'z' || *f == 'j' || *f == 't') { size = 8; f++; }
            else if (*f == 'L') { f++; }
            else break;
        }
        char c = *f++;
        char buf[512];
        int l = 0;
        uint64_t v = *args++;
        switch (c) {
        case 'd': case 'i': {
            int64_t x = size == 1 ? (int8_t)v : size == 2 ? (int16_t)v : size == 4 ? (int32_t)v : (int64_t)v;
            strcpy(sp, "lld"); l = snprintf(buf, sizeof buf, spec, (long long)x); break;
        }
        case 'u': case 'x': case 'X': case 'o': {
            uint64_t x = size == 1 ? (uint8_t)v : size == 2 ? (uint16_t)v : size == 4 ? (uint32_t)v : v;
            sp[0] = 'l'; sp[1] = 'l'; sp[2] = c; sp[3] = 0; l = snprintf(buf, sizeof buf, spec, (unsigned long long)x); break;
        }
        case 'p': strcpy(sp, "016llX"); l = snprintf(buf, sizeof buf, spec, (unsigned long long)v); break;
        case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': case 'a': case 'A': {
            double d; memcpy(&d, &v, 8); sp[0] = c; sp[1] = 0; l = snprintf(buf, sizeof buf, spec, d); break;
        }
        case 'c': case 'C': buf[0] = (char)v; l = 1; break;
        case 's': case 'S': {
            int w = c == 'S' ? !wide_strings_default : (wide >= 0 ? wide : wide_strings_default);
            if (wide == 0) w = 0;
            char *tmp = NULL;
            const char *s = (const char *)v;
            if (!s) s = "(null)";
            else if (w) s = tmp = w2u((const WCHAR *)v);
            strcpy(sp, "s");
            int need = snprintf(NULL, 0, spec, s);
            char *big = malloc(need + 1);
            snprintf(big, need + 1, spec, s);
            PUT(big, need);
            free(big); free(tmp);
            continue;
        }
        case 'n': continue;
        default: buf[0] = c; l = 1; args--; break;
        }
        PUT(buf, l < (int)sizeof buf ? l : (int)sizeof buf - 1);
    }
    if (cap) out[n < cap ? n : cap - 1] = 0;
    return (int)n;
#undef PUT
}

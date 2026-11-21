// Complete native ARM64 libSystem / POSIX / libm / pthread / OSAtomic / SysV variadic shims
// for Core BO3+Havok (~195 external stubs).

#include "shim_helpers.h"
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <locale.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <math.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stddef.h>
#include <pthread.h>
#include <CommonCrypto/CommonRandom.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

extern void *bo3_alloc_thread_tlv(void);
extern void bo3_free_thread_tlv(void *tlv);

// ===================== x86_64 SysV ABI Variadic Formatter =====================
// Reads integer args from gpr[0..5] then stack, and float/double args from xmm[0..7] then stack,
// OR from an x86_64 `struct x86_va_list { uint32_t gp_offset; uint32_t fp_offset; void *overflow; void *reg_save; }`.

typedef struct X86VaCursor {
    int      from_valist;
    uint64_t gp_regs[6];
    double   fp_regs[8];
    int      gp_idx;
    int      fp_idx;
    const uint64_t *overflow;
    // x86_64 va_list fields when from_valist != 0
    uint32_t gp_off;
    uint32_t fp_off;
    const uint8_t *ov_ptr;
    const uint8_t *rs_ptr;
} X86VaCursor;

static void va_init_direct(X86VaCursor *c, int first_gp, int first_fp,
                           uint64_t rdi, uint64_t rsi, uint64_t rdx, uint64_t rcx, uint64_t r8, uint64_t r9,
                           GuestXmm x0, GuestXmm x1, GuestXmm x2, GuestXmm x3,
                           GuestXmm x4, GuestXmm x5, GuestXmm x6, GuestXmm x7,
                           uint64_t rsp) {
    memset(c, 0, sizeof(*c));
    c->gp_regs[0] = rdi; c->gp_regs[1] = rsi; c->gp_regs[2] = rdx;
    c->gp_regs[3] = rcx; c->gp_regs[4] = r8;  c->gp_regs[5] = r9;
    c->fp_regs[0] = xmm_to_f64(x0); c->fp_regs[1] = xmm_to_f64(x1);
    c->fp_regs[2] = xmm_to_f64(x2); c->fp_regs[3] = xmm_to_f64(x3);
    c->fp_regs[4] = xmm_to_f64(x4); c->fp_regs[5] = xmm_to_f64(x5);
    c->fp_regs[6] = xmm_to_f64(x6); c->fp_regs[7] = xmm_to_f64(x7);
    c->gp_idx = first_gp;
    c->fp_idx = first_fp;
    c->overflow = (const uint64_t *)(rsp + 8ULL);
}

static void va_init_valist(X86VaCursor *c, const void *x86_va_ptr) {
    memset(c, 0, sizeof(*c));
    c->from_valist = 1;
    if (x86_va_ptr) {
        const uint32_t *u32 = (const uint32_t *)x86_va_ptr;
        const uint8_t *const *ptrs = (const uint8_t *const *)((const uint8_t *)x86_va_ptr + 8);
        c->gp_off = u32[0];
        c->fp_off = u32[1];
        c->ov_ptr = ptrs[0];
        c->rs_ptr = ptrs[1];
    }
}

static uint64_t va_next_gp(X86VaCursor *c) {
    if (!c->from_valist) {
        if (c->gp_idx < 6) return c->gp_regs[c->gp_idx++];
        return *(c->overflow++);
    }
    if (c->gp_off <= 40 && c->rs_ptr) {
        uint64_t v = *(const uint64_t *)(c->rs_ptr + c->gp_off);
        c->gp_off += 8;
        return v;
    }
    uint64_t v = c->ov_ptr ? *(const uint64_t *)c->ov_ptr : 0;
    if (c->ov_ptr) c->ov_ptr += 8;
    return v;
}

static double va_next_fp(X86VaCursor *c) {
    if (!c->from_valist) {
        if (c->fp_idx < 8) return c->fp_regs[c->fp_idx++];
        uint64_t bits = *(c->overflow++);
        double d; memcpy(&d, &bits, 8);
        return d;
    }
    if (c->fp_off <= 160 && c->rs_ptr) {
        double d;
        memcpy(&d, c->rs_ptr + c->fp_off, 8);
        c->fp_off += 16; // x86_64 SysV fp save slots are 16 bytes apart!
        return d;
    }
    double d = 0.0;
    if (c->ov_ptr) { memcpy(&d, c->ov_ptr, 8); c->ov_ptr += 8; }
    return d;
}

// x86_64 `long double` is the 80-bit x87 extended format, always passed in MEMORY (never in xmm):
// 16-byte aligned, 16-byte slot in the stack/overflow argument area. ARM64 Darwin long double == double.
static double x87_ext80_to_double(const uint8_t *p) {
    uint64_t mant;
    uint16_t se;
    memcpy(&mant, p, 8);
    memcpy(&se, p + 8, 2);
    int sign = (se >> 15) & 1;
    int exp = se & 0x7fff;
    double r;
    if (exp == 0x7fff) {
        r = (mant << 1) ? NAN : INFINITY; // integer bit ignored for inf/nan classification
    } else if (exp == 0 && mant == 0) {
        r = 0.0;
    } else {
        int e = (exp == 0 ? 1 : exp) - 16383 - 63;
        r = ldexp((double)mant, e);
    }
    return sign ? -r : r;
}

static double va_next_x87(X86VaCursor *c) {
    const uint8_t *p;
    if (!c->from_valist) {
        uintptr_t a = ((uintptr_t)c->overflow + 15u) & ~(uintptr_t)15u;
        p = (const uint8_t *)a;
        c->overflow = (const uint64_t *)(a + 16u);
    } else {
        if (!c->ov_ptr) return 0.0;
        uintptr_t a = ((uintptr_t)c->ov_ptr + 15u) & ~(uintptr_t)15u;
        p = (const uint8_t *)a;
        c->ov_ptr = (const uint8_t *)(a + 16u);
    }
    return x87_ext80_to_double(p);
}

typedef enum {
    LM_NONE, LM_HH, LM_H, LM_L, LM_LL, LM_Z, LM_T, LM_J, LM_LD, LM_Q, LM_I64
} FormatLength;

typedef enum { ARG_NONE, ARG_GP, ARG_FP, ARG_X87 } FormatArgKind;

typedef struct {
    FormatArgKind kind;
    union { uint64_t gp; double fp; } value;
} FormatArg;

typedef struct {
    const char *body, *width_end, *precision_end, *length, *end;
    FormatLength lm;
    char conv;
    size_t arg, width_arg, precision_arg;
    int has_width_arg, has_precision_arg;
} FormatSpec;

// Leave the cursor in place when these digits are a field width instead of an index.
static size_t fmt_index(const char **cursor) {
    const char *p = *cursor;
    if (*p < '0' || *p > '9') return 0;
    size_t index = 0;
    do {
        unsigned digit = (unsigned)(*p++ - '0');
        index = index > (SIZE_MAX - digit) / 10 ? SIZE_MAX : index * 10 + digit;
    } while (*p >= '0' && *p <= '9');
    if (*p != '$') return 0;
    *cursor = p + 1;
    return index ? index : SIZE_MAX;
}

static FormatSpec fmt_parse(const char *p) {
    FormatSpec spec = {0};
    spec.arg = fmt_index(&p);
    spec.body = p;
    while (*p && strchr("-+ #0'", *p)) p++;
    if (*p == '*') {
        spec.has_width_arg = 1;
        p++;
        spec.width_end = p;
        spec.width_arg = fmt_index(&p);
    } else {
        while (*p >= '0' && *p <= '9') p++;
        spec.width_end = p;
    }
    if (*p == '.') {
        p++;
        if (*p == '*') {
            spec.has_precision_arg = 1;
            p++;
            spec.precision_end = p;
            spec.precision_arg = fmt_index(&p);
        } else {
            while (*p >= '0' && *p <= '9') p++;
            spec.precision_end = p;
        }
    } else {
        spec.precision_end = p;
    }
    spec.length = p;
    switch (*p) {
        case 'h': p++; spec.lm = LM_H; if (*p == 'h') { p++; spec.lm = LM_HH; } break;
        case 'l': p++; spec.lm = LM_L; if (*p == 'l') { p++; spec.lm = LM_LL; } break;
        case 'q': p++; spec.lm = LM_Q; break;
        case 'z': p++; spec.lm = LM_Z; break;
        case 't': p++; spec.lm = LM_T; break;
        case 'j': p++; spec.lm = LM_J; break;
        case 'L': p++; spec.lm = LM_LD; break;
        case 'I': if (strncmp(p, "I64", 3) == 0) { p += 3; spec.lm = LM_I64; } break;
    }
    spec.conv = *p;
    spec.end = *p ? p + 1 : p;
    return spec;
}

static FormatArgKind fmt_arg_kind(FormatSpec spec) {
    if (spec.conv && strchr("diuxXopcsn", spec.conv)) return ARG_GP;
    if (spec.conv && strchr("fFeEgGaA", spec.conv)) return spec.lm == LM_LD ? ARG_X87 : ARG_FP;
    return ARG_NONE;
}

static FormatArg fmt_next_arg(X86VaCursor *va, FormatArgKind kind) {
    FormatArg arg = {.kind = kind};
    switch (kind) {
        case ARG_GP: arg.value.gp = va_next_gp(va); break;
        case ARG_FP: arg.value.fp = va_next_fp(va); break;
        case ARG_X87: arg.value.fp = va_next_x87(va); break;
        case ARG_NONE: break;
    }
    return arg;
}

static int fmt_positional_args(const char *fmt, X86VaCursor *va, FormatArg **out) {
    if (!strchr(fmt, '$')) return 0;
    size_t max = 0, count = 0;
    int sequential = 0;
    for (const char *p = fmt; (p = strchr(p, '%')) != NULL;) {
        if (*++p == '%') { p++; continue; }
        FormatSpec spec = fmt_parse(p);
        p = spec.end;
        const size_t indices[] = {spec.width_arg, spec.precision_arg, spec.arg};
        const int used[] = {spec.has_width_arg, spec.has_precision_arg, fmt_arg_kind(spec) != ARG_NONE};
        for (size_t i = 0; i < 3; i++) {
            if (used[i]) {
                count++;
                if (!indices[i]) sequential = 1;
            }
            if (indices[i] > max) max = indices[i];
        }
    }
    if (!max) return 0;
    if (sequential || max > count || max >= SIZE_MAX / sizeof(FormatArg)) {
        errno = EINVAL;
        return -1;
    }
    FormatArg *args = calloc(max + 1, sizeof(*args));
    if (!args) return -1;
    // Read arguments in argument order so mixed register classes and stack spills follow SysV.
    for (const char *p = fmt; (p = strchr(p, '%')) != NULL;) {
        if (*++p == '%') { p++; continue; }
        FormatSpec spec = fmt_parse(p);
        p = spec.end;
        const size_t indices[] = {spec.width_arg, spec.precision_arg, spec.arg};
        const FormatArgKind kinds[] = {ARG_GP, ARG_GP, fmt_arg_kind(spec)};
        for (size_t i = 0; i < 3; i++) {
            if (!indices[i]) continue;
            FormatArg *arg = &args[indices[i]];
            if (kinds[i] == ARG_NONE || (arg->kind != ARG_NONE && arg->kind != kinds[i])) {
                free(args);
                errno = EINVAL;
                return -1;
            }
            arg->kind = kinds[i];
        }
    }
    for (size_t i = 1; i <= max; i++) {
        if (args[i].kind == ARG_NONE) {
            free(args);
            errno = EINVAL;
            return -1;
        }
    }
    for (size_t i = 1; i <= max; i++) args[i] = fmt_next_arg(va, args[i].kind);
    *out = args;
    return 0;
}

static void fmt_put(char *dst, size_t cap, size_t *total, const char *src, size_t n) {
    if (*total < cap) {
        size_t avail = cap - *total;
        memcpy(dst + *total, src, n < avail ? n : avail);
    }
    *total += n;
}

static int bo3_x86_format(char *dst, size_t dst_sz, const char *fmt, X86VaCursor *va,
                          int full_buffer) {
    size_t cap = dst && dst_sz ? dst_sz - !full_buffer : 0;
    size_t total = 0;
    int error = 0;
    FormatArg *args = NULL;
    if (fmt && fmt_positional_args(fmt, va, &args) < 0) {
        error = errno;
        goto done;
    }

    for (const char *p = fmt; p && *p;) {
        if (*p != '%') {
            const char *lit = p;
            while (*p && *p != '%') p++;
            fmt_put(dst, cap, &total, lit, (size_t)(p - lit));
            continue;
        }
        const char *start = p++;
        if (*p == '%') {
            fmt_put(dst, cap, &total, p++, 1);
            continue;
        }

        FormatSpec spec = fmt_parse(p);
        p = spec.end;
        FormatArgKind kind = fmt_arg_kind(spec);
        size_t width_len = (size_t)(spec.width_end - spec.body);
        const char *precision = spec.width_end;
        if (spec.width_arg) precision = strchr(precision, '$') + 1;
        size_t precision_len = (size_t)(spec.precision_end - precision);
        int wide_int = spec.lm >= LM_L && spec.lm != LM_LD;
        int normalize_int = wide_int && spec.conv && strchr("diuxXo", spec.conv);
        const char *length = spec.length;
        size_t length_len = spec.conv ? (size_t)(p - 1 - length) : 0;
        if (normalize_int) { length = "ll"; length_len = 2; }

        char subfmt[64];
        if (width_len + precision_len + length_len + 3 > sizeof(subfmt)) {
            error = EOVERFLOW;
            break;
        }
        if (kind == ARG_NONE) {
            fmt_put(dst, cap, &total, start, (size_t)(p - start));
            continue;
        }
        subfmt[0] = '%';
        memcpy(subfmt + 1, spec.body, width_len);
        memcpy(subfmt + 1 + width_len, precision, precision_len);
        size_t prefix = 1 + width_len + precision_len;
        memcpy(subfmt + prefix, length, length_len);
        subfmt[prefix + length_len] = spec.conv;
        subfmt[prefix + length_len + 1] = '\0';

        int dyn_w = spec.has_width_arg ? (int)(args ? args[spec.width_arg].value.gp : va_next_gp(va)) : 0;
        int dyn_p = spec.has_precision_arg ? (int)(args ? args[spec.precision_arg].value.gp : va_next_gp(va)) : 0;
        FormatArg arg = args ? args[spec.arg] : fmt_next_arg(va, kind);
        uint64_t gp = kind == ARG_GP ? arg.value.gp : 0;
        size_t avail = total < cap ? cap - total : 0;
        char scratch[1024];
        int n = 0;

        // In C99 mode the destination already has room for snprintf's terminator.
        // MSVC mode needs scratch space if the conversion fills the remaining bytes.
        #define SN_INTO(buf, size, val) do { \
            if (spec.has_width_arg && spec.has_precision_arg) n = snprintf(buf, size, subfmt, dyn_w, dyn_p, val); \
            else if (spec.has_width_arg) n = snprintf(buf, size, subfmt, dyn_w, val); \
            else if (spec.has_precision_arg) n = snprintf(buf, size, subfmt, dyn_p, val); \
            else n = snprintf(buf, size, subfmt, val); \
        } while (0)
        #define CALL_SN(val) do { \
            if (!avail) { SN_INTO(NULL, 0, val); } \
            else if (!full_buffer) { SN_INTO(dst + total, avail + 1, val); } \
            else { \
                size_t scratch_sz = avail < sizeof(scratch) ? avail + 1 : sizeof(scratch); \
                SN_INTO(scratch, scratch_sz, val); \
                if (n > 0) { \
                    size_t bytes = (size_t)n < avail ? (size_t)n : avail; \
                    if (bytes < scratch_sz) memcpy(dst + total, scratch, bytes); \
                    else if ((size_t)n < avail) { SN_INTO(dst + total, avail, val); } \
                    else { \
                        char *tmp = malloc(bytes + 1); \
                        if (!tmp) { n = -1; break; } \
                        SN_INTO(tmp, bytes + 1, val); \
                        if (n >= 0) memcpy(dst + total, tmp, (size_t)n < bytes ? (size_t)n : bytes); \
                        if (n < 0) error = errno; \
                        free(tmp); \
                    } \
                } \
            } \
        } while (0)

        switch (spec.conv) {
            case 'd': case 'i':
                if (wide_int) { CALL_SN((long long)gp); }
                else { CALL_SN((int)gp); }
                break;
            case 'u': case 'x': case 'X': case 'o':
                if (wide_int) { CALL_SN((unsigned long long)gp); }
                else { CALL_SN((unsigned int)gp); }
                break;
            case 'p': CALL_SN((void *)(uintptr_t)gp); break;
            case 'c':
                if (spec.lm == LM_L) { CALL_SN((wint_t)gp); }
                else { CALL_SN((int)gp); }
                break;
            case 's':
                if (spec.lm == LM_L) { CALL_SN(gp ? (const wchar_t *)(uintptr_t)gp : L"(null)"); }
                else { CALL_SN(gp ? (const char *)(uintptr_t)gp : "(null)"); }
                break;
            case 'n':
                if (gp) {
                    void *np = (void *)(uintptr_t)gp;
                    switch (spec.lm) {
                        case LM_HH: *(signed char *)np = (signed char)total; break;
                        case LM_H:  *(short *)np = (short)total; break;
                        case LM_L:  *(long *)np = (long)total; break;
                        case LM_Z:  *(ssize_t *)np = (ssize_t)total; break;
                        case LM_T:  *(ptrdiff_t *)np = (ptrdiff_t)total; break;
                        case LM_J:  *(intmax_t *)np = (intmax_t)total; break;
                        case LM_LL: case LM_Q: case LM_I64: *(long long *)np = (long long)total; break;
                        default:    *(int *)np = (int)total; break;
                    }
                }
                break;
            default:
                if (spec.lm == LM_LD) { CALL_SN((long double)arg.value.fp); }
                else { CALL_SN(arg.value.fp); }
                break;
        }
        #undef CALL_SN
        #undef SN_INTO

        if (n < 0) {
            if (!error) error = errno ? errno : EINVAL;
            break;
        }
        total += (size_t)n;
        if (total > INT_MAX) {
            error = EOVERFLOW;
            break;
        }
    }

done:
    if (dst && dst_sz && (!full_buffer || total < dst_sz)) dst[total < cap ? total : cap] = '\0';
    free(args);
    if (error || total > INT_MAX) {
        errno = error ? error : EOVERFLOW;
        return -1;
    }
    return (int)total;
}

int bo3_x86_vsnprintf(char *dst, size_t dst_sz, const char *fmt, X86VaCursor *va) {
    return bo3_x86_format(dst, dst_sz, fmt, va, 0);
}

int bo3_x86_vsnprintf_unterminated(char *dst, size_t dst_sz, const char *fmt, X86VaCursor *va) {
    return bo3_x86_format(dst, dst_sz, fmt, va, 1);
}

// ===================== Formatted I/O Shims =====================
static int bo3_x86_vfprintf(FILE *fp, const char *fmt, X86VaCursor *va) {
    X86VaCursor va2 = *va;
    char buf[4096];
    char *out = buf;
    int n = bo3_x86_vsnprintf(buf, sizeof(buf), fmt, va);
    if (n >= (int)sizeof(buf) && fp) {
        out = malloc((size_t)n + 1);
        if (!out) return -1;
        int rendered = bo3_x86_vsnprintf(out, (size_t)n + 1, fmt, &va2);
        if (rendered != n) {
            if (rendered >= n) { errno = EOVERFLOW; rendered = -1; }
            n = rendered;
        }
    }
    if (n > 0 && fp && fwrite(out, 1, (size_t)n, fp) != (size_t)n) n = -1;
    if (out != buf) free(out);
    return n;
}

SHIM_DEF(shim__printf) {
    (void)ctx;
    X86VaCursor va;
    va_init_direct(&va, 1, 0, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, rsp);
    return ret_i64(bo3_x86_vfprintf(stdout, (const char *)rdi, &va));
}
SHIM_DEF(shim__fprintf) {
    (void)ctx;
    X86VaCursor va;
    va_init_direct(&va, 2, 0, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, rsp);
    return ret_i64(bo3_x86_vfprintf((FILE *)rdi, (const char *)rsi, &va));
}
SHIM_DEF(shim__vfprintf) {
    SHIM_UNUSED_ALL();
    X86VaCursor va;
    va_init_valist(&va, (const void *)rdx);
    return ret_i64(bo3_x86_vfprintf((FILE *)rdi, (const char *)rsi, &va));
}
SHIM_DEF(shim__sprintf) {
    (void)ctx;
    X86VaCursor va;
    va_init_direct(&va, 2, 0, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, rsp);
    return ret_i64(bo3_x86_vsnprintf((char *)rdi, 1 << 20, (const char *)rsi, &va));
}
SHIM_DEF(shim__snprintf) {
    (void)ctx;
    X86VaCursor va;
    va_init_direct(&va, 3, 0, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, rsp);
    return ret_i64(bo3_x86_vsnprintf((char *)rdi, (size_t)rsi, (const char *)rdx, &va));
}
SHIM_DEF(shim__vsnprintf) {
    SHIM_UNUSED_ALL();
    X86VaCursor va; va_init_valist(&va, (const void *)rcx);
    return ret_i64(bo3_x86_vsnprintf((char *)rdi, (size_t)rsi, (const char *)rdx, &va));
}
SHIM_DEF(shim__vsprintf) {
    SHIM_UNUSED_ALL();
    X86VaCursor va; va_init_valist(&va, (const void *)rdx);
    return ret_i64(bo3_x86_vsnprintf((char *)rdi, 1 << 20, (const char *)rsi, &va));
}
SHIM_DEF(shim____sprintf_chk) {
    // __sprintf_chk(dst, flag, dstlen, fmt, ...)
    (void)ctx;
    X86VaCursor va;
    va_init_direct(&va, 4, 0, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, rsp);
    size_t lim = (rdx == ~0ULL) ? (1 << 20) : (size_t)rdx;
    return ret_i64(bo3_x86_vsnprintf((char *)rdi, lim, (const char *)rcx, &va));
}
SHIM_DEF(shim__sscanf) {
    // Pass up to 12 pointer args directly from x86_64 SysV GP regs + stack
    SHIM_UNUSED_ALL();
    void *a[12];
    a[0] = (void *)rdx; a[1] = (void *)rcx; a[2] = (void *)r8; a[3] = (void *)r9;
    for (int i = 0; i < 8; i++) a[4 + i] = (void *)shim_stack_u64(rsp, (size_t)i);
    int r = sscanf((const char *)rdi, (const char *)rsi,
                   a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11]);
    return ret_i64(r);
}

// ===================== Memory & String Functions =====================
SHIM_DEF(shim__memcpy)           { SHIM_UNUSED_ALL(); return ret_ptr(memcpy((void *)rdi, (const void *)rsi, (size_t)rdx)); }
SHIM_DEF(shim__memmove)          { SHIM_UNUSED_ALL(); return ret_ptr(memmove((void *)rdi, (const void *)rsi, (size_t)rdx)); }
SHIM_DEF(shim__memset)           { SHIM_UNUSED_ALL(); return ret_ptr(memset((void *)rdi, (int)rsi, (size_t)rdx)); }
SHIM_DEF(shim____bzero)          { SHIM_UNUSED_ALL(); memset((void *)rdi, 0, (size_t)rsi); return ret_void(); }
SHIM_DEF(shim__memset_pattern16) { SHIM_UNUSED_ALL(); memset_pattern16((void *)rdi, (const void *)rsi, (size_t)rdx); return ret_void(); }
SHIM_DEF(shim__memcmp)           { SHIM_UNUSED_ALL(); return ret_i64(memcmp((const void *)rdi, (const void *)rsi, (size_t)rdx)); }
SHIM_DEF(shim__memchr)           { SHIM_UNUSED_ALL(); return ret_ptr(memchr((const void *)rdi, (int)rsi, (size_t)rdx)); }
SHIM_DEF(shim__strlen)           { SHIM_UNUSED_ALL(); return ret_u64(strlen((const char *)rdi)); }
SHIM_DEF(shim__strcmp)           { SHIM_UNUSED_ALL(); return ret_i64(strcmp((const char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim__strncmp)          { SHIM_UNUSED_ALL(); return ret_i64(strncmp((const char *)rdi, (const char *)rsi, (size_t)rdx)); }
SHIM_DEF(shim__strcoll)          { SHIM_UNUSED_ALL(); return ret_i64(strcoll((const char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim__strchr)           { SHIM_UNUSED_ALL(); return ret_ptr(strchr((const char *)rdi, (int)rsi)); }
SHIM_DEF(shim__strrchr)          { SHIM_UNUSED_ALL(); return ret_ptr(strrchr((const char *)rdi, (int)rsi)); }
SHIM_DEF(shim__strstr)           { SHIM_UNUSED_ALL(); return ret_ptr(strstr((const char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim__strtok)           { SHIM_UNUSED_ALL(); return ret_ptr(strtok((char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim__strcspn)          { SHIM_UNUSED_ALL(); return ret_u64(strcspn((const char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim__strspn)           { SHIM_UNUSED_ALL(); return ret_u64(strspn((const char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim__strcpy)           { SHIM_UNUSED_ALL(); return ret_ptr(strcpy((char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim____strcpy_chk)     { SHIM_UNUSED_ALL(); return ret_ptr(strcpy((char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim__strncpy)          { SHIM_UNUSED_ALL(); return ret_ptr(strncpy((char *)rdi, (const char *)rsi, (size_t)rdx)); }
SHIM_DEF(shim__strcat)           { SHIM_UNUSED_ALL(); return ret_ptr(strcat((char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim__wcslen)           { SHIM_UNUSED_ALL(); return ret_u64(wcslen((const wchar_t *)rdi)); }
SHIM_DEF(shim__wcscmp)           { SHIM_UNUSED_ALL(); return ret_i64(wcscmp((const wchar_t *)rdi, (const wchar_t *)rsi)); }
SHIM_DEF(shim__wcscpy)           { SHIM_UNUSED_ALL(); return ret_ptr(wcscpy((wchar_t *)rdi, (const wchar_t *)rsi)); }
SHIM_DEF(shim__wcstombs)         { SHIM_UNUSED_ALL(); return ret_u64(wcstombs((char *)rdi, (const wchar_t *)rsi, (size_t)rdx)); }
SHIM_DEF(shim__mblen)            { SHIM_UNUSED_ALL(); return ret_i64(mblen((const char *)rdi, (size_t)rsi)); }
SHIM_DEF(shim__atoi)             { SHIM_UNUSED_ALL(); return ret_i64(atoi((const char *)rdi)); }
SHIM_DEF(shim__atof)             { SHIM_UNUSED_ALL(); return ret_f64(atof((const char *)rdi)); }
SHIM_DEF(shim__strtol)           { SHIM_UNUSED_ALL(); return ret_i64(strtol((const char *)rdi, (char **)rsi, (int)rdx)); }
SHIM_DEF(shim__strtoul)          { SHIM_UNUSED_ALL(); return ret_u64(strtoul((const char *)rdi, (char **)rsi, (int)rdx)); }
SHIM_DEF(shim__strtoll)          { SHIM_UNUSED_ALL(); return ret_i64(strtoll((const char *)rdi, (char **)rsi, (int)rdx)); }
SHIM_DEF(shim__strtoull)         { SHIM_UNUSED_ALL(); return ret_u64(strtoull((const char *)rdi, (char **)rsi, (int)rdx)); }
SHIM_DEF(shim__strtod)           { SHIM_UNUSED_ALL(); return ret_f64(strtod((const char *)rdi, (char **)rsi)); }
SHIM_DEF(shim____tolower)        { SHIM_UNUSED_ALL(); return ret_i64(__tolower((int)rdi)); }
SHIM_DEF(shim____toupper)        { SHIM_UNUSED_ALL(); return ret_i64(__toupper((int)rdi)); }
SHIM_DEF(shim____maskrune)       { SHIM_UNUSED_ALL(); return ret_i64(__maskrune((__darwin_ct_rune_t)rdi, (unsigned long)rsi)); }
SHIM_DEF(shim__strerror)         { SHIM_UNUSED_ALL(); return ret_ptr(strerror((int)rdi)); }
SHIM_DEF(shim__perror)           { SHIM_UNUSED_ALL(); perror((const char *)rdi); return ret_void(); }
SHIM_DEF(shim__putchar)          { SHIM_UNUSED_ALL(); return ret_i64(putchar((int)rdi)); }
SHIM_DEF(shim__localeconv)       { SHIM_UNUSED_ALL(); return ret_ptr(localeconv()); }
SHIM_DEF(shim__setlocale)        { SHIM_UNUSED_ALL(); return ret_ptr(setlocale((int)rdi, (const char *)rsi)); }

// ===================== Heap & Process =====================
SHIM_DEF(shim__malloc)           { SHIM_UNUSED_ALL(); return ret_ptr(malloc((size_t)rdi)); }
SHIM_DEF(shim__calloc)           { SHIM_UNUSED_ALL(); return ret_ptr(calloc((size_t)rdi, (size_t)rsi)); }
SHIM_DEF(shim__realloc)          { SHIM_UNUSED_ALL(); return ret_ptr(realloc((void *)rdi, (size_t)rsi)); }
SHIM_DEF(shim__free)             { SHIM_UNUSED_ALL(); free((void *)rdi); return ret_void(); }
SHIM_DEF(shim__getenv)           { SHIM_UNUSED_ALL(); return ret_ptr(getenv((const char *)rdi)); }
SHIM_DEF(shim__exit)             { SHIM_UNUSED_ALL(); exit((int)rdi); }
SHIM_DEF(shim__abort)            { SHIM_UNUSED_ALL(); abort(); }
SHIM_DEF(shim__system)           { SHIM_UNUSED_ALL(); return ret_i64(system((const char *)rdi)); }
SHIM_DEF(shim____error)          { SHIM_UNUSED_ALL(); return ret_ptr(&errno); }
SHIM_DEF(shim____stack_chk_fail) {
    SHIM_UNUSED_ALL();
    fprintf(stderr, "[bo3_rt] ___stack_chk_fail triggered!\n");
    abort();
}
SHIM_DEF(shim____cxa_atexit)     { SHIM_UNUSED_ALL(); return ret_i64(0); } // clean no-op at exit

// ===================== Math (libm) =====================
SHIM_DEF(shim__sinf)   { SHIM_UNUSED_ALL(); return ret_f32(sinf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__cosf)   { SHIM_UNUSED_ALL(); return ret_f32(cosf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__tanf)   { SHIM_UNUSED_ALL(); return ret_f32(tanf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__asinf)  { SHIM_UNUSED_ALL(); return ret_f32(asinf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__acosf)  { SHIM_UNUSED_ALL(); return ret_f32(acosf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__atanf)  { SHIM_UNUSED_ALL(); return ret_f32(atanf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__atan2f) { SHIM_UNUSED_ALL(); return ret_f32(atan2f(xmm_to_f32(xmm0), xmm_to_f32(xmm1))); }
SHIM_DEF(shim__powf)   { SHIM_UNUSED_ALL(); return ret_f32(powf(xmm_to_f32(xmm0), xmm_to_f32(xmm1))); }
SHIM_DEF(shim__fmodf)  { SHIM_UNUSED_ALL(); return ret_f32(fmodf(xmm_to_f32(xmm0), xmm_to_f32(xmm1))); }
SHIM_DEF(shim__logf)   { SHIM_UNUSED_ALL(); return ret_f32(logf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__log10f) { SHIM_UNUSED_ALL(); return ret_f32(log10f(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__expf)   { SHIM_UNUSED_ALL(); return ret_f32(expf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__exp2f)  { SHIM_UNUSED_ALL(); return ret_f32(exp2f(xmm_to_f32(xmm0))); }
SHIM_DEF(shim____exp10f){ SHIM_UNUSED_ALL(); return ret_f32(powf(10.0f, xmm_to_f32(xmm0))); }
SHIM_DEF(shim__ceilf)  { SHIM_UNUSED_ALL(); return ret_f32(ceilf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__floorf) { SHIM_UNUSED_ALL(); return ret_f32(floorf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__sinhf)  { SHIM_UNUSED_ALL(); return ret_f32(sinhf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__coshf)  { SHIM_UNUSED_ALL(); return ret_f32(coshf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__tanhf)  { SHIM_UNUSED_ALL(); return ret_f32(tanhf(xmm_to_f32(xmm0))); }
SHIM_DEF(shim__modff)  { SHIM_UNUSED_ALL(); return ret_f32(modff(xmm_to_f32(xmm0), (float *)rdi)); }
SHIM_DEF(shim__ldexpf) { SHIM_UNUSED_ALL(); return ret_f32(ldexpf(xmm_to_f32(xmm0), (int)rdi)); }
SHIM_DEF(shim__frexpf) { SHIM_UNUSED_ALL(); return ret_f32(frexpf(xmm_to_f32(xmm0), (int *)rdi)); }
SHIM_DEF(shim____sincosf_stret) {
    SHIM_UNUSED_ALL();
    float x = xmm_to_f32(xmm0);
    return ret_f32x2(sinf(x), cosf(x));
}
SHIM_DEF(shim____sincos_stret) {
    SHIM_UNUSED_ALL();
    double x = xmm_to_f64(xmm0);
    return ret_f64x2(sin(x), cos(x));
}
SHIM_DEF(shim__cos)    { SHIM_UNUSED_ALL(); return ret_f64(cos(xmm_to_f64(xmm0))); }
SHIM_DEF(shim__tan)    { SHIM_UNUSED_ALL(); return ret_f64(tan(xmm_to_f64(xmm0))); }
SHIM_DEF(shim__acos)   { SHIM_UNUSED_ALL(); return ret_f64(acos(xmm_to_f64(xmm0))); }
SHIM_DEF(shim__atan)   { SHIM_UNUSED_ALL(); return ret_f64(atan(xmm_to_f64(xmm0))); }
SHIM_DEF(shim__pow)    { SHIM_UNUSED_ALL(); return ret_f64(pow(xmm_to_f64(xmm0), xmm_to_f64(xmm1))); }
SHIM_DEF(shim__fmod)   { SHIM_UNUSED_ALL(); return ret_f64(fmod(xmm_to_f64(xmm0), xmm_to_f64(xmm1))); }
SHIM_DEF(shim__log)    { SHIM_UNUSED_ALL(); return ret_f64(log(xmm_to_f64(xmm0))); }
SHIM_DEF(shim__exp)    { SHIM_UNUSED_ALL(); return ret_f64(exp(xmm_to_f64(xmm0))); }
SHIM_DEF(shim____exp10){ SHIM_UNUSED_ALL(); return ret_f64(pow(10.0, xmm_to_f64(xmm0))); }
SHIM_DEF(shim____udivti3) {
    SHIM_UNUSED_ALL();
    unsigned __int128 a = ((unsigned __int128)rsi << 64) | rdi;
    unsigned __int128 b = ((unsigned __int128)rcx << 64) | rdx;
    unsigned __int128 q = b ? (a / b) : 0;
    return guest_ret_full((uint64_t)q, (uint64_t)(q >> 64), guest_xmm_zero(), guest_xmm_zero());
}

// ===================== OSAtomic & Pthreads & Semaphores =====================
SHIM_DEF(shim__OSAtomicIncrement32Barrier) {
    SHIM_UNUSED_ALL();
    return ret_i64(__atomic_add_fetch((volatile int32_t *)rdi, 1, __ATOMIC_SEQ_CST));
}
SHIM_DEF(shim__OSAtomicDecrement32Barrier) {
    SHIM_UNUSED_ALL();
    return ret_i64(__atomic_sub_fetch((volatile int32_t *)rdi, 1, __ATOMIC_SEQ_CST));
}
SHIM_DEF(shim__OSAtomicCompareAndSwap32) {
    SHIM_UNUSED_ALL();
    int32_t expected = (int32_t)rdi;
    int32_t desired = (int32_t)rsi;
    int ok = __atomic_compare_exchange_n((volatile int32_t *)rdx, &expected, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return ret_i64(ok ? 1 : 0);
}

SHIM_DEF(shim__pthread_mutex_init)         { SHIM_UNUSED_ALL(); return ret_i64(pthread_mutex_init((pthread_mutex_t *)rdi, (const pthread_mutexattr_t *)rsi)); }
SHIM_DEF(shim__pthread_mutex_destroy)      { SHIM_UNUSED_ALL(); return ret_i64(pthread_mutex_destroy((pthread_mutex_t *)rdi)); }
SHIM_DEF(shim__pthread_mutex_lock)         { SHIM_UNUSED_ALL(); return ret_i64(pthread_mutex_lock((pthread_mutex_t *)rdi)); }
SHIM_DEF(shim__pthread_mutex_trylock)      { SHIM_UNUSED_ALL(); return ret_i64(pthread_mutex_trylock((pthread_mutex_t *)rdi)); }
SHIM_DEF(shim__pthread_mutex_unlock)       { SHIM_UNUSED_ALL(); return ret_i64(pthread_mutex_unlock((pthread_mutex_t *)rdi)); }
SHIM_DEF(shim__pthread_mutexattr_init)     { SHIM_UNUSED_ALL(); return ret_i64(pthread_mutexattr_init((pthread_mutexattr_t *)rdi)); }
SHIM_DEF(shim__pthread_mutexattr_destroy)  { SHIM_UNUSED_ALL(); return ret_i64(pthread_mutexattr_destroy((pthread_mutexattr_t *)rdi)); }
SHIM_DEF(shim__pthread_mutexattr_settype)  { SHIM_UNUSED_ALL(); return ret_i64(pthread_mutexattr_settype((pthread_mutexattr_t *)rdi, (int)rsi)); }
SHIM_DEF(shim__pthread_key_create)         { SHIM_UNUSED_ALL(); return ret_i64(pthread_key_create((pthread_key_t *)rdi, NULL)); }
SHIM_DEF(shim__pthread_key_delete)         { SHIM_UNUSED_ALL(); return ret_i64(pthread_key_delete((pthread_key_t)rdi)); }
SHIM_DEF(shim__pthread_getspecific)        { SHIM_UNUSED_ALL(); return ret_ptr(pthread_getspecific((pthread_key_t)rdi)); }
SHIM_DEF(shim__pthread_setspecific)        { SHIM_UNUSED_ALL(); return ret_i64(pthread_setspecific((pthread_key_t)rdi, (const void *)rsi)); }
SHIM_DEF(shim__pthread_setname_np)         { SHIM_UNUSED_ALL(); return ret_i64(pthread_setname_np((const char *)rdi)); }
SHIM_DEF(shim__pthread_join)               { SHIM_UNUSED_ALL(); return ret_i64(pthread_join((pthread_t)rdi, (void **)rsi)); }
SHIM_DEF(shim__pthread_cancel)             { SHIM_UNUSED_ALL(); return ret_i64(pthread_cancel((pthread_t)rdi)); }

extern uint32_t bo3_init_thread_tid(GuestContext *ctx, uint32_t forced_tid);

typedef struct GuestThreadCleanup {
    void *stk;
    size_t stk_total;
    void *tlv;
} GuestThreadCleanup;

static void bo3_guest_pthread_cleanup(void *arg) {
    GuestThreadCleanup *c = (GuestThreadCleanup *)arg;
    if (c->tlv) { bo3_free_thread_tlv(c->tlv); c->tlv = NULL; }
    if (c->stk) { munmap(c->stk, c->stk_total); c->stk = NULL; }
}

typedef struct GuestThreadLaunch {
    uint64_t start_va;
    uint64_t arg;
} GuestThreadLaunch;

static void *bo3_guest_pthread_entry(void *opaque) {
    GuestThreadLaunch *gl = (GuestThreadLaunch *)opaque;
    uint64_t start_va = gl->start_va;
    uint64_t arg = gl->arg;
    free(gl);

    const size_t STACK_SZ = 8 * 1024 * 1024;
    void *stk = mmap(NULL, STACK_SZ + 16384, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stk == MAP_FAILED) abort();
    if (mprotect(stk, 16384, PROT_NONE) != 0) abort(); // guard page

    GuestContext tctx;
    memset(&tctx, 0, sizeof(tctx));
    tctx.mxcsr = 0x1f80;
    tctx.stack_base = (uint64_t)(uintptr_t)stk + 16384;
    tctx.stack_size = STACK_SZ;
    tctx.tlv_block = bo3_alloc_thread_tlv();
    bo3_init_thread_tid(&tctx, 0);

    GuestThreadCleanup cln = { stk, STACK_SZ + 16384, tctx.tlv_block };
    uint64_t ret_val = 0;
    pthread_cleanup_push(bo3_guest_pthread_cleanup, &cln);

    uint64_t sp = (tctx.stack_base + STACK_SZ - 64) & ~15ULL;
    sp -= 8; *(uint64_t *)sp = 0; // return PC slot

    GuestFn fn = bo3_resolve(start_va, &tctx);
    GuestRet r = fn(&tctx, sp, arg, 0, 0, 0, 0, 0,
                    guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
                    guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    ret_val = r.rax_rdx[0];

    pthread_cleanup_pop(1);
    return (void *)(uintptr_t)ret_val;
}

SHIM_DEF(shim__pthread_create) {
    SHIM_UNUSED_ALL();
    // Deep lifted call chains run on the HOST pthread stack: never accept macOS's 512 KiB worker
    // default. Honor the guest's detach state / larger stack request, but floor it at 16 MiB
    // (matching CreateThread and the guest main thread).
    const size_t MIN_HOST_STACK = 16u << 20;
    size_t stk_sz = MIN_HOST_STACK;
    int detach = PTHREAD_CREATE_JOINABLE;
    const pthread_attr_t *gattr = (const pthread_attr_t *)rsi;
    if (gattr) {
        size_t gsz = 0;
        int gdet = PTHREAD_CREATE_JOINABLE;
        if (pthread_attr_getstacksize(gattr, &gsz) == 0 && gsz > stk_sz) stk_sz = gsz;
        if (pthread_attr_getdetachstate(gattr, &gdet) == 0) detach = gdet;
    }
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, (stk_sz + 16383u) & ~(size_t)16383u);
    pthread_attr_setdetachstate(&a, detach);

    GuestThreadLaunch *gl = (GuestThreadLaunch *)malloc(sizeof(*gl));
    if (!gl) { pthread_attr_destroy(&a); return ret_i64(EAGAIN); }
    gl->start_va = rdx;
    gl->arg = rcx;
    int rc = pthread_create((pthread_t *)rdi, &a, bo3_guest_pthread_entry, gl);
    pthread_attr_destroy(&a);
    if (rc != 0) free(gl);
    return ret_i64(rc);
}

SHIM_DEF(shim__semaphore_create)  { SHIM_UNUSED_ALL(); return ret_i64(semaphore_create((task_t)rdi, (semaphore_t *)rsi, (int)rdx, (int)rcx)); }
SHIM_DEF(shim__semaphore_destroy) { SHIM_UNUSED_ALL(); return ret_i64(semaphore_destroy((task_t)rdi, (semaphore_t)rsi)); }
SHIM_DEF(shim__semaphore_signal)  { SHIM_UNUSED_ALL(); return ret_i64(semaphore_signal((semaphore_t)rdi)); }
SHIM_DEF(shim__semaphore_wait)    { SHIM_UNUSED_ALL(); return ret_i64(semaphore_wait((semaphore_t)rdi)); }

// ===================== qsort / bsearch Guest-Comparator Trampolines =====================
typedef struct GuestCmpThunk {
    GuestContext *ctx;
    uint64_t      rsp;
    GuestFn       cmp_fn;
} GuestCmpThunk;

static int host_qsort_cmp(void *thunk_p, const void *a, const void *b) {
    GuestCmpThunk *t = (GuestCmpThunk *)thunk_p;
    uint64_t sp = (t->rsp - 128) & ~15ULL;
    sp -= 8; *(uint64_t *)sp = 0;
    GuestRet r = t->cmp_fn(t->ctx, sp, (uint64_t)(uintptr_t)a, (uint64_t)(uintptr_t)b, 0, 0, 0, 0,
                           guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
                           guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    return (int)(int32_t)r.rax_rdx[0];
}

SHIM_DEF(shim__qsort) {
    SHIM_UNUSED_ALL();
    if (rsi <= 1) return ret_void();
    GuestCmpThunk t = { ctx, rsp, bo3_resolve(rcx, ctx) };
    qsort_r((void *)rdi, (size_t)rsi, (size_t)rdx, &t, host_qsort_cmp);
    return ret_void();
}

static __thread GuestCmpThunk g_bsearch_thunk;
static int host_bsearch_cmp(const void *a, const void *b) {
    return host_qsort_cmp(&g_bsearch_thunk, a, b);
}

SHIM_DEF(shim__bsearch) {
    SHIM_UNUSED_ALL();
    if (!rdx) return ret_ptr(NULL);
    // A guest comparator may itself call bsearch: keep the outer state on this frame and
    // restore it afterwards so the outer search resumes with its own comparator/rsp.
    GuestCmpThunk saved = g_bsearch_thunk;
    g_bsearch_thunk.ctx = ctx;
    g_bsearch_thunk.rsp = rsp;
    g_bsearch_thunk.cmp_fn = bo3_resolve(r8, ctx);
    void *res = bsearch((const void *)rdi, (const void *)rsi, (size_t)rdx, (size_t)rcx, host_bsearch_cmp);
    g_bsearch_thunk = saved;
    return ret_ptr(res);
}

// ===================== File / Dir / Time / Sys / Socket POSIX =====================
SHIM_DEF(shim__fclose)   { SHIM_UNUSED_ALL(); return ret_i64(fclose((FILE *)rdi)); }
SHIM_DEF(shim__fread)    { SHIM_UNUSED_ALL(); return ret_u64(fread((void *)rdi, (size_t)rsi, (size_t)rdx, (FILE *)rcx)); }
SHIM_DEF(shim__fwrite)   { SHIM_UNUSED_ALL(); return ret_u64(fwrite((const void *)rdi, (size_t)rsi, (size_t)rdx, (FILE *)rcx)); }
SHIM_DEF(shim__fseek)    { SHIM_UNUSED_ALL(); return ret_i64(fseek((FILE *)rdi, (long)rsi, (int)rdx)); }
SHIM_DEF(shim__ftell)    { SHIM_UNUSED_ALL(); return ret_i64(ftell((FILE *)rdi)); }
SHIM_DEF(shim__fflush)   { SHIM_UNUSED_ALL(); return ret_i64(fflush((FILE *)rdi)); }
SHIM_DEF(shim__feof)     { SHIM_UNUSED_ALL(); return ret_i64(feof((FILE *)rdi)); }
SHIM_DEF(shim__ferror)   { SHIM_UNUSED_ALL(); return ret_i64(ferror((FILE *)rdi)); }
SHIM_DEF(shim__clearerr) { SHIM_UNUSED_ALL(); clearerr((FILE *)rdi); return ret_void(); }
SHIM_DEF(shim__fgetc)    { SHIM_UNUSED_ALL(); return ret_i64(fgetc((FILE *)rdi)); }
SHIM_DEF(shim__ungetc)   { SHIM_UNUSED_ALL(); return ret_i64(ungetc((int)rdi, (FILE *)rsi)); }
SHIM_DEF(shim__setvbuf)  { SHIM_UNUSED_ALL(); return ret_i64(setvbuf((FILE *)rdi, (char *)rsi, (int)rdx, (size_t)rcx)); }
SHIM_DEF(shim__read)     { SHIM_UNUSED_ALL(); return ret_i64(read((int)rdi, (void *)rsi, (size_t)rdx)); }
SHIM_DEF(shim__close)    { SHIM_UNUSED_ALL(); return ret_i64(close((int)rdi)); }
// Havok imports legacy Darwin _stat (120-byte struct with 32-bit st_ino at +4 and st_mode at +8),
// whereas ARM64 Darwin stat() writes the 144-byte stat$INODE64 struct (st_mode at +4).
typedef struct DarwinLegacyStat {
    int32_t         st_dev;
    uint32_t        st_ino;
    uint16_t        st_mode;
    uint16_t        st_nlink;
    uint32_t        st_uid;
    uint32_t        st_gid;
    int32_t         st_rdev;
    struct timespec st_atimespec;
    struct timespec st_mtimespec;
    struct timespec st_ctimespec;
    int64_t         st_size;
    int64_t         st_blocks;
    int32_t         st_blksize;
    uint32_t        st_flags;
    uint32_t        st_gen;
    int32_t         st_lspare;
    int64_t         st_qspare[2];
} DarwinLegacyStat;
_Static_assert(sizeof(DarwinLegacyStat) == 120, "DarwinLegacyStat must be 120 bytes");
_Static_assert(offsetof(DarwinLegacyStat, st_mode) == 8, "DarwinLegacyStat.st_mode must be at +8");

SHIM_DEF(shim__stat) {
    SHIM_UNUSED_ALL();
    struct stat st64;
    int rc = stat((const char *)rdi, &st64);
    if (rc == 0 && rsi) {
        DarwinLegacyStat ls;
        memset(&ls, 0, sizeof(ls));
        ls.st_dev       = (int32_t)st64.st_dev;
        ls.st_ino       = (uint32_t)st64.st_ino;
        ls.st_mode      = (uint16_t)st64.st_mode;
        ls.st_nlink     = (uint16_t)st64.st_nlink;
        ls.st_uid       = (uint32_t)st64.st_uid;
        ls.st_gid       = (uint32_t)st64.st_gid;
        ls.st_rdev      = (int32_t)st64.st_rdev;
        ls.st_atimespec = st64.st_atimespec;
        ls.st_mtimespec = st64.st_mtimespec;
        ls.st_ctimespec = st64.st_ctimespec;
        ls.st_size      = (int64_t)st64.st_size;
        ls.st_blocks    = (int64_t)st64.st_blocks;
        ls.st_blksize   = (int32_t)st64.st_blksize;
        ls.st_flags     = (uint32_t)st64.st_flags;
        ls.st_gen       = (uint32_t)st64.st_gen;
        memcpy((void *)rsi, &ls, sizeof(ls));
    }
    return ret_i64(rc);
}
// Core imports plain _readdir (not readdir$INODE64), i.e. the legacy 32-bit-inode Darwin dirent:
//   d_ino u32 @0, d_reclen u16 @4, d_type u8 @6, d_namlen u8 @7, d_name[256] @8  (264 bytes)
// Native ARM64 readdir() returns the 64-bit layout (d_name @21), so translate into a per-DIR*
// buffer (lifetime = until the next readdir/closedir on that stream, as POSIX specifies).
typedef struct DarwinLegacyDirent {
    uint32_t d_ino;
    uint16_t d_reclen;
    uint8_t  d_type;
    uint8_t  d_namlen;
    char     d_name[256];
} DarwinLegacyDirent;
_Static_assert(offsetof(DarwinLegacyDirent, d_name) == 8, "legacy dirent d_name must be at +8");
_Static_assert(sizeof(DarwinLegacyDirent) == 264, "legacy dirent must be 264 bytes");

typedef struct LegacyDirSlot {
    DIR *dir;
    DarwinLegacyDirent ent;
    struct LegacyDirSlot *next;
} LegacyDirSlot;
static pthread_mutex_t g_legacy_dir_lock = PTHREAD_MUTEX_INITIALIZER;
static LegacyDirSlot *g_legacy_dirs = NULL;

static DarwinLegacyDirent *legacy_dir_buf(DIR *d) {
    pthread_mutex_lock(&g_legacy_dir_lock);
    LegacyDirSlot *s = g_legacy_dirs;
    while (s && s->dir != d) s = s->next;
    if (!s) {
        s = (LegacyDirSlot *)calloc(1, sizeof(*s));
        if (s) { s->dir = d; s->next = g_legacy_dirs; g_legacy_dirs = s; }
    }
    pthread_mutex_unlock(&g_legacy_dir_lock);
    return s ? &s->ent : NULL;
}
static void legacy_dir_release(DIR *d) {
    pthread_mutex_lock(&g_legacy_dir_lock);
    for (LegacyDirSlot **pp = &g_legacy_dirs; *pp; pp = &(*pp)->next) {
        if ((*pp)->dir == d) {
            LegacyDirSlot *dead = *pp;
            *pp = dead->next;
            free(dead);
            break;
        }
    }
    pthread_mutex_unlock(&g_legacy_dir_lock);
}

SHIM_DEF(shim__opendir)  { SHIM_UNUSED_ALL(); return ret_ptr(opendir((const char *)rdi)); }
SHIM_DEF(shim__readdir) {
    SHIM_UNUSED_ALL();
    DIR *d = (DIR *)rdi;
    if (!d) { errno = EBADF; return ret_ptr(NULL); }
    struct dirent *de;
    for (;;) {
        de = readdir(d); // EOF -> NULL with errno untouched; error -> NULL with errno set
        if (!de) return ret_ptr(NULL);
        if (de->d_namlen <= 255) break; // (APFS names are <= 255 bytes; skip anything else)
    }
    int saved_errno = errno;
    DarwinLegacyDirent *out = legacy_dir_buf(d);
    if (!out) { errno = ENOMEM; return ret_ptr(NULL); }
    size_t nl = de->d_namlen;
    out->d_ino    = (uint32_t)de->d_ino;
    if (!out->d_ino && de->d_ino) out->d_ino = 1u;
    out->d_type   = de->d_type;
    out->d_namlen = (uint8_t)nl;
    memcpy(out->d_name, de->d_name, nl);
    memset(out->d_name + nl, 0, sizeof(out->d_name) - nl);
    out->d_reclen = (uint16_t)((offsetof(DarwinLegacyDirent, d_name) + nl + 1 + 3) & ~3u);
    errno = saved_errno;
    return ret_ptr(out);
}
// readdir$INODE64 callers expect the native 64-bit-inode layout: pass straight through.
SHIM_DEF(shim__readdir_24_INODE64) { SHIM_UNUSED_ALL(); return ret_ptr(readdir((DIR *)rdi)); }
SHIM_DEF(shim__closedir) {
    SHIM_UNUSED_ALL();
    DIR *d = (DIR *)rdi;
    if (!d) { errno = EBADF; return ret_i64(-1); }
    legacy_dir_release(d);
    return ret_i64(closedir(d));
}

SHIM_DEF(shim__time)         { SHIM_UNUSED_ALL(); return ret_i64(time((time_t *)rdi)); }
SHIM_DEF(shim__gettimeofday) { SHIM_UNUSED_ALL(); return ret_i64(gettimeofday((struct timeval *)rdi, (void *)rsi)); }
SHIM_DEF(shim__localtime)    { SHIM_UNUSED_ALL(); return ret_ptr(localtime((const time_t *)rdi)); }
SHIM_DEF(shim__gmtime)       { SHIM_UNUSED_ALL(); return ret_ptr(gmtime((const time_t *)rdi)); }
SHIM_DEF(shim__mktime)       { SHIM_UNUSED_ALL(); return ret_i64(mktime((struct tm *)rdi)); }
SHIM_DEF(shim__strftime)     { SHIM_UNUSED_ALL(); return ret_u64(strftime((char *)rdi, (size_t)rsi, (const char *)rdx, (const struct tm *)rcx)); }
SHIM_DEF(shim__ctime)        { SHIM_UNUSED_ALL(); return ret_ptr(ctime((const time_t *)rdi)); }
SHIM_DEF(shim__asctime)      { SHIM_UNUSED_ALL(); return ret_ptr(asctime((const struct tm *)rdi)); }
SHIM_DEF(shim__difftime)     { SHIM_UNUSED_ALL(); return ret_f64(difftime((time_t)rdi, (time_t)rsi)); }
SHIM_DEF(shim__clock)        { SHIM_UNUSED_ALL(); return ret_u64(clock()); }
SHIM_DEF(shim__usleep)       { SHIM_UNUSED_ALL(); return ret_i64(usleep((useconds_t)rdi)); }
SHIM_DEF(shim__mach_absolute_time) { SHIM_UNUSED_ALL(); return ret_u64(mach_absolute_time()); }
SHIM_DEF(shim__mach_timebase_info) { SHIM_UNUSED_ALL(); return ret_i64(mach_timebase_info((mach_timebase_info_t)rdi)); }
SHIM_DEF(shim__sysctlbyname) { SHIM_UNUSED_ALL(); return ret_i64(sysctlbyname((const char *)rdi, (void *)rsi, (size_t *)rdx, (void *)rcx, (size_t)r8)); }
SHIM_DEF(shim__CCRandomGenerateBytes) { SHIM_UNUSED_ALL(); return ret_i64(CCRandomGenerateBytes((void *)rdi, (size_t)rsi)); }

SHIM_DEF(shim__socket)       { SHIM_UNUSED_ALL(); return ret_i64(socket((int)rdi, (int)rsi, (int)rdx)); }
SHIM_DEF(shim__bind)         { SHIM_UNUSED_ALL(); return ret_i64(bind((int)rdi, (const struct sockaddr *)rsi, (socklen_t)rdx)); }
SHIM_DEF(shim__listen)       { SHIM_UNUSED_ALL(); return ret_i64(listen((int)rdi, (int)rsi)); }
SHIM_DEF(shim__accept)       { SHIM_UNUSED_ALL(); return ret_i64(accept((int)rdi, (struct sockaddr *)rsi, (socklen_t *)rdx)); }
SHIM_DEF(shim__connect)      { SHIM_UNUSED_ALL(); return ret_i64(connect((int)rdi, (const struct sockaddr *)rsi, (socklen_t)rdx)); }
SHIM_DEF(shim__send)         { SHIM_UNUSED_ALL(); return ret_i64(send((int)rdi, (const void *)rsi, (size_t)rdx, (int)rcx)); }
SHIM_DEF(shim__recv)         { SHIM_UNUSED_ALL(); return ret_i64(recv((int)rdi, (void *)rsi, (size_t)rdx, (int)rcx)); }
SHIM_DEF(shim__sendto)       { SHIM_UNUSED_ALL(); return ret_i64(sendto((int)rdi, (const void *)rsi, (size_t)rdx, (int)rcx, (const struct sockaddr *)r8, (socklen_t)r9)); }
SHIM_DEF(shim__recvfrom)     { SHIM_UNUSED_ALL(); return ret_i64(recvfrom((int)rdi, (void *)rsi, (size_t)rdx, (int)rcx, (struct sockaddr *)r8, (socklen_t *)r9)); }
SHIM_DEF(shim__setsockopt)   { SHIM_UNUSED_ALL(); return ret_i64(setsockopt((int)rdi, (int)rsi, (int)rdx, (const void *)rcx, (socklen_t)r8)); }
SHIM_DEF(shim__getsockname)  { SHIM_UNUSED_ALL(); return ret_i64(getsockname((int)rdi, (struct sockaddr *)rsi, (socklen_t *)rdx)); }
SHIM_DEF(shim__select_24_1050){ SHIM_UNUSED_ALL(); return ret_i64(select((int)rdi, (fd_set *)rsi, (fd_set *)rdx, (fd_set *)rcx, (struct timeval *)r8)); }
SHIM_DEF(shim__poll)         { SHIM_UNUSED_ALL(); return ret_i64(poll((struct pollfd *)rdi, (nfds_t)rsi, (int)rdx)); }
SHIM_DEF(shim__ioctl)        { SHIM_UNUSED_ALL(); return ret_i64(ioctl((int)rdi, (unsigned long)rsi, (void *)rdx)); }
SHIM_DEF(shim__getaddrinfo)  { SHIM_UNUSED_ALL(); return ret_i64(getaddrinfo((const char *)rdi, (const char *)rsi, (const struct addrinfo *)rdx, (struct addrinfo **)rcx)); }
SHIM_DEF(shim__freeaddrinfo) { SHIM_UNUSED_ALL(); freeaddrinfo((struct addrinfo *)rdi); return ret_void(); }
SHIM_DEF(shim__gethostbyname){ SHIM_UNUSED_ALL(); return ret_ptr(gethostbyname((const char *)rdi)); }
SHIM_DEF(shim__gethostname)  { SHIM_UNUSED_ALL(); return ret_i64(gethostname((char *)rdi, (size_t)rsi)); }
SHIM_DEF(shim__inet_addr)    { SHIM_UNUSED_ALL(); return ret_u64(inet_addr((const char *)rdi)); }
SHIM_DEF(shim__inet_ntoa)    { SHIM_UNUSED_ALL(); struct in_addr ia; ia.s_addr = (in_addr_t)rdi; return ret_ptr(inet_ntoa(ia)); }
SHIM_DEF(shim__inet_pton)    { SHIM_UNUSED_ALL(); return ret_i64(inet_pton((int)rdi, (const char *)rsi, (void *)rdx)); }
SHIM_DEF(shim__inet_ntop)    { SHIM_UNUSED_ALL(); return ret_ptr(inet_ntop((int)rdi, (const void *)rsi, (char *)rdx, (socklen_t)rcx)); }
SHIM_DEF(shim____memcpy_chk) { SHIM_UNUSED_ALL(); return ret_ptr(memcpy((void *)rdi, (const void *)rsi, (size_t)rdx)); }
SHIM_DEF(shim____strcat_chk) { SHIM_UNUSED_ALL(); return ret_ptr(strcat((char *)rdi, (const char *)rsi)); }
SHIM_DEF(shim__atol)         { SHIM_UNUSED_ALL(); return ret_i64(atol((const char *)rdi)); }

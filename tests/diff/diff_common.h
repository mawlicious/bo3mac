#pragma once
#include "../../runtime/cpu_state.h"
#include <stdint.h>
#include <string.h>

#define DIFF_ARENA_VA   0x140000000ULL
#define DIFF_ARENA_SIZE 0x10000ULL       // 64 KB
#define DIFF_MEM_VA     0x140000000ULL   // [0x140000000, 0x140004000): 16 KB scratch data (base at +0x1000)
#define DIFF_DATA_BASE  0x140001000ULL   // rdi/rsi safe pointer with +/- 4KB guard
#define DIFF_STACK_TOP  0x14000e000ULL   // guest rsp starts here

#define DIFF_MEM_SNAP_SIZE 256

// Flag masks (subset of RFLAGS we compare)
#define FM_NONE  0x000ULL
#define FM_CF    (1ULL << 0)
#define FM_PF    (1ULL << 2)
#define FM_AF    (1ULL << 4)
#define FM_ZF    (1ULL << 6)
#define FM_SF    (1ULL << 7)
#define FM_DF    (1ULL << 10)
#define FM_OF    (1ULL << 11)
#define FM_ALL6  (FM_CF | FM_PF | FM_AF | FM_ZF | FM_SF | FM_OF)
#define FM_SZP   (FM_SF | FM_ZF | FM_PF)
#define FM_SZPCO (FM_SF | FM_ZF | FM_PF | FM_CF | FM_OF)
#define FM_NOAF  (FM_CF | FM_PF | FM_ZF | FM_SF | FM_OF)

typedef struct DiffTestDesc {
    const char *name;
    void       *fn;          // x86_64 function pointer (in diff_x86) or lifted void(*)(GuestContext*) (in diff_arm64)
    uint64_t    flag_mask;   // which RFLAGS bits are architectural/defined
    uint32_t    iters;       // number of randomized + edge cases
    uint32_t    flags;       // bit 0: approx float (rcp/rsqrt 12-bit tolerance), bit 1: avoid div0, bit 2: tiny shift/mem
} DiffTestDesc;

#define DF_APPROX_FP      (1u << 0)
#define DF_DIV_SAFE       (1u << 1)
#define DF_STRING_OP      (1u << 2)
#define DF_SMALL_IDX      (1u << 3)
#define DF_NAN_CANON_F32  (1u << 4)
#define DF_NAN_CANON_F64  (1u << 5)

typedef struct DiffResult {
    GuestContext ctx;
    uint8_t      mem[DIFF_MEM_SNAP_SIZE];
} DiffResult;

// Deterministic PRNG + adversarial edge-case generator (shared by both diff_x86 and diff_arm64)
static inline uint64_t xorshift64(uint64_t *s) {
    uint64_t x = *s;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *s = x;
    return x;
}

static inline void fill_test_state(uint32_t test_idx, uint32_t iter, uint32_t dflags, GuestContext *ctx, uint8_t *mem) {
    static const uint64_t edge64[] = {
        0ULL, 1ULL, ~0ULL, 0x8000000000000000ULL, 0x7fffffffffffffffULL,
        0x0000000080000000ULL, 0x000000007fffffffULL, 0x00000000ffffffffULL,
        0x0000000000008000ULL, 0x0000000000007fffULL, 0x000000000000ffffULL,
        0x0000000000000080ULL, 0x000000000000007fULL, 0x00000000000000ffULL,
        0x0123456789abcdefULL, 0xfedcba9876543210ULL, 0x0000000100000001ULL,
        0x000000000000001fULL, 0x0000000000000020ULL, 0x000000000000003fULL,
        0x0000000000000040ULL, 0x000000000000000fULL, 0x0000000000000010ULL,
        0x5555555555555555ULL, 0xaaaaaaaaaaaaaaaaULL, 0x0000000000000007ULL,
    };
    static const uint32_t edge_f32[] = {
        0x00000000u, // +0.0
        0x80000000u, // -0.0
        0x3f800000u, // +1.0
        0xbf800000u, // -1.0
        0x3fc00000u, // +1.5
        0xbfc00000u, // -1.5
        0x40200000u, // +2.5
        0xc0200000u, // -2.5
        0x4f000000u, // +2^31 (overflow int32!)
        0xcf000000u, // -2^31 (exact INT32_MIN)
        0xcf000001u, // < -2^31 (overflow int32!)
        0x4effffffu, // largest float < 2^31
        0x5f000000u, // +2^63 (overflow int64!)
        0xdf000000u, // -2^63 (exact INT64_MIN)
        0x7f800000u, // +Inf
        0xff800000u, // -Inf
        0x7fc00000u, // qNaN
        0x00000001u, // min subnormal
        0x42c80000u, // 100.0
        0xc2c80000u, // -100.0
    };
    static const uint64_t edge_f64[] = {
        0x0000000000000000ULL, // +0.0
        0x8000000000000000ULL, // -0.0
        0x3ff0000000000000ULL, // +1.0
        0xbff0000000000000ULL, // -1.0
        0x3ff8000000000000ULL, // +1.5
        0xbff8000000000000ULL, // -1.5
        0x4004000000000000ULL, // +2.5
        0xc004000000000000ULL, // -2.5
        0x41e0000000000000ULL, // +2^31
        0xc1e0000000000000ULL, // -2^31
        0xc1e0000000200000ULL, // -2^31 - 1
        0x41dfffffffc00000ULL, // +2^31 - 1
        0x43e0000000000000ULL, // +2^63
        0xc3e0000000000000ULL, // -2^63
        0x7ff0000000000000ULL, // +Inf
        0xfff0000000000000ULL, // -Inf
        0x7ff8000000000000ULL, // qNaN
        0x4059000000000000ULL, // 100.0
    };

    uint64_t seed = ((uint64_t)(test_idx + 1) * 0x9e3779b97f4a7c15ULL) ^ ((uint64_t)(iter + 1) * 0xbf58476d1ce4e5b9ULL);
    if (seed == 0) seed = 1;

    memset(ctx, 0, sizeof(*ctx));
    for (int i = 0; i < 16; i++) {
        if (iter < 16 && (xorshift64(&seed) & 1)) {
            ctx->gpr[i] = edge64[xorshift64(&seed) % (sizeof(edge64) / sizeof(edge64[0]))];
        } else {
            ctx->gpr[i] = xorshift64(&seed);
        }
    }
    // Always initialize scratch memory and reserve rdi/rsi/rsp/rbp cleanly
    for (int i = 0; i < DIFF_MEM_SNAP_SIZE; i++) {
        mem[i] = (uint8_t)xorshift64(&seed);
    }
    // Fixed stack & data pointers so both x86_64 and arm64 see identical addresses!
    ctx->gpr[G_RSP] = DIFF_STACK_TOP;
    ctx->gpr[G_RBP] = DIFF_DATA_BASE + 128;
    ctx->gpr[G_RDI] = DIFF_DATA_BASE;
    ctx->gpr[G_RSI] = DIFF_DATA_BASE + 64;

    if (dflags & DF_DIV_SAFE) {
        // Keep divisor (rbx/rcx) nonzero and numerator (rdx:rax) small enough not to trap #DE
        int64_t num = (int32_t)(xorshift64(&seed) & 0xfffff) - 0x7ffff;
        int64_t den = (int32_t)(xorshift64(&seed) & 0x7ff) + 1;
        if (xorshift64(&seed) & 1) den = -den;
        ctx->gpr[G_RAX] = (uint64_t)num;
        ctx->gpr[G_RDX] = (num < 0) ? ~0ULL : 0ULL;
        ctx->gpr[G_RBX] = (uint64_t)den;
        ctx->gpr[G_RCX] = (uint64_t)(den > 0 ? den : -den);
        // For unsigned div: make rdx smaller than rcx!
        ctx->gpr[G_R8]  = (xorshift64(&seed) & 0x3ff) + 1; // positive divisor
        ctx->gpr[G_R9]  = (xorshift64(&seed) % ctx->gpr[G_R8]); // high < divisor
    }
    if (dflags & DF_STRING_OP) {
        ctx->gpr[G_RCX] = (xorshift64(&seed) & 7); // 0..7 iterations
        ctx->gpr[G_RDI] = DIFF_DATA_BASE + 64;
        ctx->gpr[G_RSI] = DIFF_DATA_BASE + 128;
    }
    if (dflags & DF_SMALL_IDX) {
        // Signed bit offsets in [-64, +63] for mem `bt`
        int64_t idx = (int64_t)(xorshift64(&seed) % 128) - 64;
        ctx->gpr[G_RCX] = (uint64_t)idx;
        ctx->gpr[G_RDI] = DIFF_DATA_BASE + 64;
    }

    // Fill XMMs with mix of edge floats, edge doubles, and random bits
    for (int i = 0; i < 16; i++) {
        uint32_t mode = (iter + (uint32_t)i) % 3;
        if (mode == 0 && iter < 24) {
            uint32_t f[4];
            for (int k = 0; k < 4; k++) {
                uint32_t fv = edge_f32[xorshift64(&seed) % (sizeof(edge_f32) / sizeof(edge_f32[0]))];
                if ((dflags & DF_APPROX_FP) && ((fv & 0x7f800000u) == 0x7f800000u || (fv & 0x7fffffffu) == 0 || (fv & 0x80000000u))) {
                    fv = 0x3fc00000u + (uint32_t)((xorshift64(&seed) & 0x1ff) << 16); // positive normal
                }
                f[k] = fv;
            }
            ctx->xmm[i] = guest_xmm_make((uint64_t)f[0] | ((uint64_t)f[1] << 32),
                                         (uint64_t)f[2] | ((uint64_t)f[3] << 32));
        } else if (mode == 1 && iter < 24) {
            uint64_t lo = edge_f64[xorshift64(&seed) % (sizeof(edge_f64) / sizeof(edge_f64[0]))];
            uint64_t hi = edge_f64[xorshift64(&seed) % (sizeof(edge_f64) / sizeof(edge_f64[0]))];
            ctx->xmm[i] = guest_xmm_make(lo, hi);
        } else {
            uint64_t lo = xorshift64(&seed);
            uint64_t hi = xorshift64(&seed);
            ctx->xmm[i] = guest_xmm_make(lo, hi);
            if (dflags & DF_APPROX_FP) {
                // Ensure positive normal floats for rcp/rsqrt tolerance tests
                uint32_t f[4];
                for (int k = 0; k < 4; k++) {
                    uint32_t exp = 120 + (uint32_t)(xorshift64(&seed) % 20);
                    uint32_t mant = (uint32_t)(xorshift64(&seed) & 0x7fffff);
                    f[k] = (exp << 23) | mant;
                }
                ctx->xmm[i] = guest_xmm_make((uint64_t)f[0] | ((uint64_t)f[1] << 32),
                                             (uint64_t)f[2] | ((uint64_t)f[3] << 32));
            }
        }
    }

    // Randomize input RFLAGS (keep DF=0 unless string op specifically tests DF)
    uint64_t rf = 2;
    uint64_t rbits = xorshift64(&seed);
    if (rbits & 1)  rf |= FM_CF;
    if (rbits & 2)  rf |= FM_PF;
    if (rbits & 4)  rf |= FM_AF;
    if (rbits & 8)  rf |= FM_ZF;
    if (rbits & 16) rf |= FM_SF;
    if (rbits & 32) rf |= FM_OF;
    if ((dflags & DF_STRING_OP) && (rbits & 64)) rf |= FM_DF;
    ctx->rflags = rf;
    ctx->mxcsr = 0x1f80u;
}

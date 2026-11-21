#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Canonical GPR indices matching x86_64 encoding order
enum {
    G_RAX = 0, G_RCX = 1, G_RDX = 2, G_RBX = 3,
    G_RSP = 4, G_RBP = 5, G_RSI = 6, G_RDI = 7,
    G_R8  = 8, G_R9  = 9, G_R10 = 10, G_R11 = 11,
    G_R12 = 12, G_R13 = 13, G_R14 = 14, G_R15 = 15,
};

// Native 128-bit SIMD vector: lowers to <2 x i64> in ARM64 v0..v7 (exact match with lifted IR!)
typedef uint64_t GuestXmm __attribute__((ext_vector_type(2)));

static inline GuestXmm guest_xmm_zero(void) {
    GuestXmm v = { 0ULL, 0ULL };
    return v;
}
static inline GuestXmm guest_xmm_make(uint64_t lo, uint64_t hi) {
    GuestXmm v = { lo, hi };
    return v;
}
static inline uint64_t guest_xmm_lo(GuestXmm v) { return v[0]; }
static inline uint64_t guest_xmm_hi(GuestXmm v) { return v[1]; }

// 3-element HVA (Homogeneous Vector Aggregate): { <2 x i64>, <2 x i64>, <2 x i64> }
// Under AAPCS64, returns directly in v0 (rax in lane0, rdx in lane1), v1 (xmm0), v2 (xmm1)
// with ZERO sret and 100% identical ABI between C shims and lifted LLVM IR!
typedef struct GuestRet {
    GuestXmm rax_rdx;
    GuestXmm xmm0;
    GuestXmm xmm1;
} GuestRet;

static inline GuestRet guest_ret_i64(uint64_t rax) {
    GuestRet r;
    r.rax_rdx = guest_xmm_make(rax, 0ULL);
    r.xmm0 = guest_xmm_zero();
    r.xmm1 = guest_xmm_zero();
    return r;
}
static inline GuestRet guest_ret_full(uint64_t rax, uint64_t rdx, GuestXmm xmm0, GuestXmm xmm1) {
    GuestRet r;
    r.rax_rdx = guest_xmm_make(rax, rdx);
    r.xmm0 = xmm0;
    r.xmm1 = xmm1;
    return r;
}

// Per-thread guest execution context (passed in x0 to every lifted function)
typedef struct __attribute__((aligned(64))) GuestContext {
    uint64_t gpr[16];      // offset 0x000: used by full-state CC, callbacks, diff harness, traps; gpr[0] carries AL/RAX into variadic calls
    GuestXmm xmm[16];      // offset 0x080: 256 bytes (16-byte aligned)
    uint64_t rflags;       // offset 0x180: bit0=CF, bit2=PF, bit4=AF, bit6=ZF, bit7=SF, bit10=DF, bit11=OF
    uint32_t mxcsr;        // offset 0x188: default 0x1f80
    uint32_t pad0;         // offset 0x18c
    uint64_t stack_base;   // offset 0x190: low address of per-thread guest stack
    uint64_t stack_size;   // offset 0x198: bytes
    void    *tlv_block;    // offset 0x1a0: per-thread Mach-O __thread_data/__thread_bss copy
    uint64_t last_pc;      // offset 0x1a8: diagnostic guest PC on trap/miss
    uint64_t ret_pc_check; // offset 0x1b0: optional debug shadow-stack check
} GuestContext;

// Superset-SysV lifted function pointer signature:
// Maps 1:1 to ARM64 x0..x7 (ctx, rsp, rdi..r9) + v0..v7 (xmm0..xmm7), returns in v0..v2.
typedef GuestRet (*GuestFn)(
    GuestContext *ctx, uint64_t rsp,
    uint64_t rdi, uint64_t rsi, uint64_t rdx, uint64_t rcx, uint64_t r8, uint64_t r9,
    GuestXmm xmm0, GuestXmm xmm1, GuestXmm xmm2, GuestXmm xmm3,
    GuestXmm xmm4, GuestXmm xmm5, GuestXmm xmm6, GuestXmm xmm7
);

// Runtime helpers called from lifted IR
// bo3_resolve maps a guest VA -> lifted GuestFn (enables direct `musttail call %fn(...)` with 0 stack growth!)
GuestFn bo3_resolve(uint64_t target_va, GuestContext *ctx);
void bo3_register_fn(uint64_t guest_va, GuestFn fn);

void bo3_cpuid(uint32_t leaf, uint32_t subleaf, uint32_t *eax, uint32_t *ebx, uint32_t *ecx, uint32_t *edx);
uint64_t bo3_rdtsc(void);
void bo3_trap(uint64_t pc, uint64_t reason, GuestContext *ctx) __attribute__((noreturn));
void *bo3_tlv_get_addr(GuestContext *ctx, void *descriptor);

#ifdef __cplusplus
}
#endif

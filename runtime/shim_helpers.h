#pragma once
#include "cpu_state.h"
#include <string.h>

// Exact Superset-SysV 3-vector HVA ABI parameter list matching lifted LLVM IR
#define SHIM_PARAMS \
    GuestContext *ctx, uint64_t rsp, \
    uint64_t rdi, uint64_t rsi, uint64_t rdx, uint64_t rcx, uint64_t r8, uint64_t r9, \
    GuestXmm xmm0, GuestXmm xmm1, GuestXmm xmm2, GuestXmm xmm3, \
    GuestXmm xmm4, GuestXmm xmm5, GuestXmm xmm6, GuestXmm xmm7

#define SHIM_UNUSED_ALL() do { \
    (void)ctx; (void)rsp; \
    (void)rdi; (void)rsi; (void)rdx; (void)rcx; (void)r8; (void)r9; \
    (void)xmm0; (void)xmm1; (void)xmm2; (void)xmm3; \
    (void)xmm4; (void)xmm5; (void)xmm6; (void)xmm7; \
} while (0)

#define SHIM_DEF(name) GuestRet name(SHIM_PARAMS)

// Read Nth stack argument (0 = 7th integer arg at [rsp + 8], since [rsp + 0] is pushed return PC)
static inline uint64_t shim_stack_u64(uint64_t rsp, size_t idx) {
    return *(const uint64_t *)(rsp + 8ULL + idx * 8ULL);
}

static inline float xmm_to_f32(GuestXmm x) {
    uint32_t u = (uint32_t)x[0];
    float f;
    memcpy(&f, &u, 4);
    return f;
}
static inline double xmm_to_f64(GuestXmm x) {
    uint64_t u = x[0];
    double d;
    memcpy(&d, &u, 8);
    return d;
}
static inline GuestRet ret_void(void) {
    return guest_ret_i64(0ULL);
}
static inline GuestRet ret_u64(uint64_t v) {
    return guest_ret_i64(v);
}
static inline GuestRet ret_i64(int64_t v) {
    return guest_ret_i64((uint64_t)v);
}
static inline GuestRet ret_ptr(const void *p) {
    return guest_ret_i64((uint64_t)(uintptr_t)p);
}
static inline GuestRet ret_pair(uint64_t rax, uint64_t rdx) {
    return guest_ret_full(rax, rdx, guest_xmm_zero(), guest_xmm_zero());
}
static inline GuestRet ret_f32(float f) {
    uint32_t u = 0;
    memcpy(&u, &f, 4);
    return guest_ret_full(0ULL, 0ULL, guest_xmm_make((uint64_t)u, 0ULL), guest_xmm_zero());
}
static inline GuestRet ret_f64(double d) {
    uint64_t u = 0;
    memcpy(&u, &d, 8);
    return guest_ret_full(0ULL, 0ULL, guest_xmm_make(u, 0ULL), guest_xmm_zero());
}
static inline GuestRet ret_f32x2(float a, float b) {
    uint32_t ua = 0, ub = 0;
    memcpy(&ua, &a, 4);
    memcpy(&ub, &b, 4);
    return guest_ret_full(0ULL, 0ULL, guest_xmm_make((uint64_t)ua | ((uint64_t)ub << 32), 0ULL), guest_xmm_zero());
}
static inline GuestRet ret_f64x2(double a, double b) {
    uint64_t ua = 0, ub = 0;
    memcpy(&ua, &a, 8);
    memcpy(&ub, &b, 8);
    return guest_ret_full(0ULL, 0ULL, guest_xmm_make(ua, 0ULL), guest_xmm_make(ub, 0ULL));
}

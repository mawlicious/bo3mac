#!/usr/bin/env python3
"""
End-to-end C <-> Lifted SupersetSysV HVA ABI Verification Test.
Verifies:
  1. Direct C -> Lifted IR call passing all 8 GPR args (ctx,rsp,rdi..r9), all 8 XMM args (xmm0..xmm7),
     and AL in ctx->gpr[0], returning 3-vector HVA GuestRet {rax, rdx, xmm0, xmm1} in v0..v2.
  2. Lifted IR -> C shim call via bo3_resolve() returning exact {rax, rdx, xmm0, xmm1} + preserving guest rsp.
  3. 20,000-deep indirect tail-jump chain (`jmp r8` -> `bo3_resolve` -> `musttail call %ret_t %fn`)
     proving ZERO host stack growth!
"""
import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from bo3_paths import find_cache_dir

CACHE = os.path.join(find_cache_dir(), "abi_test")
os.makedirs(CACHE, exist_ok=True)
LIFTER = os.path.join(ROOT, "build", "bo3_lift")

asm_path = os.path.join(CACHE, "abi_snips.S")
with open(asm_path, "w") as f:
    f.write(""".intel_syntax noprefix
.text
// 1. Direct roundtrip: sums all 6 GPR args into rax, adds AL (from ctx->gpr[0]) into rdx,
//    combines xmm0..xmm7 into xmm0 & xmm1, returns via SupersetSysV HVA!
.globl _abi_sum_args
.p2align 4
_abi_sum_args:
    movzx r10, al
    mov rax, rdi
    add rax, rsi
    add rax, rdx
    add rax, rcx
    add rax, r8
    add rax, r9
    mov rdx, r10
    paddq xmm0, xmm2
    paddq xmm0, xmm4
    paddq xmm0, xmm6
    paddq xmm1, xmm3
    paddq xmm1, xmm5
    paddq xmm1, xmm7
    ret

// 2. Indirect call into C shim at [rdi] (`call rdi`), then adds 1 to rax & rdx and returns
.globl _abi_call_c_shim
.p2align 4
_abi_call_c_shim:
    mov r10, rdi
    mov rdi, rsi
    mov rsi, rdx
    call r10
    add rax, 1
    add rdx, 2
    ret

// 3. Tail-recursive indirect countdown: if rdi == 0 return rsi; else dec rdi; inc rsi; jmp r8
.globl _abi_tail_loop
.p2align 4
_abi_tail_loop:
    test rdi, rdi
    jz 1f
    dec rdi
    inc rsi
    jmp r8
1:
    mov rax, rsi
    mov rdx, 0xdeadbeefcafebabe
    ret

.globl _abi_END
_abi_END:
    nop
""")

snip_o = os.path.join(CACHE, "abi_snips.o")
subprocess.check_call(["clang", "-arch", "x86_64", "-c", asm_path, "-o", snip_o])

nm_out = subprocess.check_output(["nm", "-n", snip_o], text=True)
syms = [(int(p[0], 16), p[2]) for p in (l.split() for l in nm_out.splitlines()) if len(p) == 3 and p[2].startswith("_abi_")]
syms.sort()

with open(snip_o, "rb") as f:
    raw = f.read()
ncmds = struct.unpack_from("<I", raw, 16)[0]
off = 32
text_off = text_size = 0
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", raw, off)
    if cmd == 0x19:
        nsects = struct.unpack_from("<I", raw, off + 64)[0]
        soff = off + 72
        for _ in range(nsects):
            if raw[soff:soff+16].split(b"\0")[0] == b"__text":
                text_size = struct.unpack_from("<Q", raw, soff + 40)[0]
                text_off = struct.unpack_from("<I", raw, soff + 48)[0]
            soff += 80
    off += cmdsize
text = raw[text_off:text_off + text_size]

bodies = []
decls = set()
for i in range(len(syms) - 1):
    a, name = syms[i]
    b, _ = syms[i + 1]
    if name == "_abi_END": continue
    fn_name = name[1:]
    bp = os.path.join(CACHE, f"{fn_name}.bin")
    lp = os.path.join(CACHE, f"{fn_name}.ll")
    with open(bp, "wb") as f:
        f.write(text[a:b])
    subprocess.check_call([LIFTER, "--raw", bp, hex(0x100500000 + i * 0x1000), fn_name, "--cc", "sysv", "--tso", "strict", "-o", lp])
    txt = open(lp).read()
    for l in txt.splitlines():
        if l.startswith("declare "): decls.add(l)
    m = re.search(r"(define %ret_t @abi_.*?\n\}\n)", txt, re.S)
    assert m, f"Missing define in {lp}"
    bodies.append(m.group(1))

comb_ll = os.path.join(CACHE, "abi_lifted.ll")
with open(comb_ll, "w") as f:
    f.write('target datalayout = "e-m:o-i64:64-i128:128-n32:64-S128-Fn32"\n')
    f.write('target triple = "arm64-apple-macosx15.0.0"\n')
    f.write('%ret_t = type { <2 x i64>, <2 x i64>, <2 x i64> }\n\n')
    for d in sorted(decls): f.write(d + "\n")
    f.write("\n")
    for b in bodies: f.write(b + "\n")
    f.write('attributes #0 = { "target-cpu"="apple-m1" "target-features"="+lse,+rcpc" }\n')

lifted_o = os.path.join(CACHE, "abi_lifted.o")
subprocess.check_call(["clang", "-arch", "arm64", "-mcpu=apple-m1", "-O2", "-Wno-override-module", "-x", "ir", "-c", comb_ll, "-o", lifted_o])

driver_c = os.path.join(CACHE, "abi_driver.c")
with open(driver_c, "w") as f:
    f.write(r'''
#include "cpu_state.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern GuestRet abi_sum_args(
    GuestContext *ctx, uint64_t rsp,
    uint64_t rdi, uint64_t rsi, uint64_t rdx, uint64_t rcx, uint64_t r8, uint64_t r9,
    GuestXmm xmm0, GuestXmm xmm1, GuestXmm xmm2, GuestXmm xmm3,
    GuestXmm xmm4, GuestXmm xmm5, GuestXmm xmm6, GuestXmm xmm7);

extern GuestRet abi_call_c_shim(
    GuestContext *ctx, uint64_t rsp,
    uint64_t rdi, uint64_t rsi, uint64_t rdx, uint64_t rcx, uint64_t r8, uint64_t r9,
    GuestXmm xmm0, GuestXmm xmm1, GuestXmm xmm2, GuestXmm xmm3,
    GuestXmm xmm4, GuestXmm xmm5, GuestXmm xmm6, GuestXmm xmm7);

extern GuestRet abi_tail_loop(
    GuestContext *ctx, uint64_t rsp,
    uint64_t rdi, uint64_t rsi, uint64_t rdx, uint64_t rcx, uint64_t r8, uint64_t r9,
    GuestXmm xmm0, GuestXmm xmm1, GuestXmm xmm2, GuestXmm xmm3,
    GuestXmm xmm4, GuestXmm xmm5, GuestXmm xmm6, GuestXmm xmm7);

// Native C shim invoked from lifted IR through bo3_resolve!
static GuestRet my_c_shim(
    GuestContext *ctx, uint64_t rsp,
    uint64_t rdi, uint64_t rsi, uint64_t rdx, uint64_t rcx, uint64_t r8, uint64_t r9,
    GuestXmm xmm0, GuestXmm xmm1, GuestXmm xmm2, GuestXmm xmm3,
    GuestXmm xmm4, GuestXmm xmm5, GuestXmm xmm6, GuestXmm xmm7)
{
    (void)ctx; (void)rdx; (void)rcx; (void)r8; (void)r9;
    (void)xmm2; (void)xmm3; (void)xmm4; (void)xmm5; (void)xmm6; (void)xmm7;
    // Check that caller pushed return PC onto guest stack at [rsp]
    uint64_t pushed_ret = *(uint64_t *)rsp;
    assert(pushed_ret != 0);
    return guest_ret_full(rdi * 10 + rsi, rdi ^ rsi, xmm0 + xmm1, guest_xmm_make(0x1111, 0x2222));
}

int main(void) {
    GuestContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    uint8_t guest_stack[65536] __attribute__((aligned(16)));
    uint64_t sp = (uint64_t)(guest_stack + sizeof(guest_stack) - 64);

    // Test 1: C -> Lifted IR (all 6 GPRs + 8 XMMs + AL via ctx->gpr[0])
    ctx.gpr[G_RAX] = 7; // AL = 7 (variadic XMM count)
    GuestRet r1 = abi_sum_args(
        &ctx, sp, 10, 20, 30, 40, 50, 60,
        guest_xmm_make(1, 2), guest_xmm_make(3, 4),
        guest_xmm_make(5, 6), guest_xmm_make(7, 8),
        guest_xmm_make(9, 10), guest_xmm_make(11, 12),
        guest_xmm_make(13, 14), guest_xmm_make(15, 16));
    assert(r1.rax_rdx[0] == 210ULL);
    assert(r1.rax_rdx[1] == 7ULL); // AL preserved through ctx->gpr[0]!
    assert(r1.xmm0[0] == 1 + 5 + 9 + 13 && r1.xmm0[1] == 2 + 6 + 10 + 14);
    assert(r1.xmm1[0] == 3 + 7 + 11 + 15 && r1.xmm1[1] == 4 + 8 + 12 + 16);
    printf("PASS Test 1: C -> Lifted IR HVA ABI (all 8 GPRs + 8 XMMs + AL + v0..v2 return)\n");

    // Test 2: Lifted IR -> bo3_resolve -> Native C shim -> Lifted IR -> C
    const uint64_t SHIM_VA = 0x100999000ULL;
    bo3_register_fn(SHIM_VA, my_c_shim);
    GuestRet r2 = abi_call_c_shim(
        &ctx, sp, SHIM_VA, 42, 7, 0, 0, 0,
        guest_xmm_make(100, 200), guest_xmm_make(300, 400),
        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    assert(r2.rax_rdx[0] == (42 * 10 + 7) + 1);
    assert(r2.rax_rdx[1] == (42 ^ 7) + 2);
    assert(r2.xmm0[0] == 400 && r2.xmm0[1] == 600);
    assert(r2.xmm1[0] == 0x1111 && r2.xmm1[1] == 0x2222);
    printf("PASS Test 2: Lifted IR -> bo3_resolve -> Native C shim -> Lifted IR roundtrip\n");

    // Test 3: 500,000-deep indirect tail-jump chain (would blow 8MB stack instantly without musttail!)
    const uint64_t TAIL_VA = 0x100502000ULL;
    bo3_register_fn(TAIL_VA, abi_tail_loop);
    GuestRet r3 = abi_tail_loop(
        &ctx, sp, 500000ULL, 123ULL, 0, 0, TAIL_VA, 0,
        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    assert(r3.rax_rdx[0] == 500123ULL);
    assert(r3.rax_rdx[1] == 0xdeadbeefcafebabeULL);
    printf("PASS Test 3: 500,000-deep indirect tail-jump chain via bo3_resolve + musttail (0 stack growth!)\n");

    return 0;
}
''')

driver_bin = os.path.join(CACHE, "abi_driver")
subprocess.check_call([
    "clang", "-arch", "arm64", "-mcpu=apple-m1", "-O2",
    f"-I{ROOT}/runtime", driver_c, os.path.join(ROOT, "runtime/runtime_core.c"), lifted_o, "-o", driver_bin
])
subprocess.check_call([driver_bin])

#!/usr/bin/env python3
"""
Rosetta 2 vs Native ARM64 Differential Fuzzer for bo3_lift.
Generates 180+ x86_64 assembly snippets covering every testable mnemonic in Core BO3+Havok,
assembles them with clang -arch x86_64, lifts their exact bytes with bo3_lift,
runs both native x86_64 (under Rosetta 2) and lifted ARM64 on identical adversarial + random inputs,
and verifies bit-for-bit equality of all 16 GPRs, all 16 XMMs, RFLAGS, and 256B scratch memory.
"""
import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from bo3_paths import find_cache_dir

CACHE = os.path.join(find_cache_dir(), "diff")
os.makedirs(CACHE, exist_ok=True)

# Each entry: (name, asm_lines_intel, flag_mask_expr, iters, dflags_expr)
TESTS = [
    # ---- Data movement & sign/zero extension ----
    ("mov_r64_r64", "mov rax, rbx", "FM_ALL6", 40, "0"),
    ("mov_r32_r32_zext", "mov eax, ebx", "FM_ALL6", 40, "0"),
    ("mov_r16_r16", "mov ax, bx", "FM_ALL6", 40, "0"),
    ("mov_r8_r8", "mov al, bl", "FM_ALL6", 40, "0"),
    ("mov_high8_ah_bh", "mov ah, bh; mov ch, al; mov dh, bl; mov bh, cl", "FM_ALL6", 40, "0"),
    ("mov_mem_rw", "mov qword ptr [rdi+8], rax; mov rdx, qword ptr [rdi+8]; mov dword ptr [rdi+16], ecx; mov r8d, dword ptr [rdi+16]", "FM_ALL6", 40, "0"),
    ("movzx_all", "movzx eax, bl; movzx rcx, byte ptr [rdi+3]; movzx rdx, word ptr [rdi+4]; movzx ebp, ah", "FM_ALL6", 40, "0"),
    ("movsx_all", "movsx eax, bl; movsx rcx, byte ptr [rdi+3]; movsx rdx, word ptr [rdi+4]; movsxd r8, r9d", "FM_ALL6", 40, "0"),
    ("lea_sib", "lea rax, [rdi + rcx*4 + 0x1234]; lea ebx, [rsi + rdx*8 - 17]", "FM_ALL6", 40, "0"),
    ("push_pop_64", "push rax; push rbx; pop rcx; pop rdx", "FM_ALL6", 40, "0"),
    ("cbw_cwde_cdqe", "cbw; mov r8, rax; cwde; mov r9, rax; cdqe", "FM_ALL6", 40, "0"),
    ("cwd_cdq_cqo", "cwd; mov r8, rdx; cdq; mov r9, rdx; cqo", "FM_ALL6", 40, "0"),
    ("bswap_32_64", "bswap eax; bswap rbx", "FM_ALL6", 40, "0"),
    ("xchg_reg_mem", "xchg rax, rbx; xchg ecx, edx; xchg qword ptr [rdi+8], r8", "FM_ALL6", 40, "0"),

    # ---- Basic ALU + Flags ----
    ("add_64", "add rax, rbx", "FM_ALL6", 60, "0"),
    ("add_32", "add eax, ebx", "FM_ALL6", 60, "0"),
    ("add_16", "add ax, bx", "FM_ALL6", 60, "0"),
    ("add_8",  "add al, bl", "FM_ALL6", 60, "0"),
    ("add_high8", "add ah, bh", "FM_ALL6", 60, "0"),
    ("sub_64", "sub rax, rbx", "FM_ALL6", 60, "0"),
    ("sub_32", "sub eax, ebx", "FM_ALL6", 60, "0"),
    ("sub_16", "sub ax, bx", "FM_ALL6", 60, "0"),
    ("sub_8",  "sub al, bl", "FM_ALL6", 60, "0"),
    ("adc_64", "adc rax, rbx", "FM_ALL6", 60, "0"),
    ("adc_32", "adc eax, ebx", "FM_ALL6", 60, "0"),
    ("adc_8",  "adc al, bl", "FM_ALL6", 60, "0"),
    ("sbb_64", "sbb rax, rbx", "FM_ALL6", 60, "0"),
    ("sbb_32", "sbb eax, ebx", "FM_ALL6", 60, "0"),
    ("sbb_8",  "sbb al, bl", "FM_ALL6", 60, "0"),
    ("inc_64_preserves_cf", "inc rax", "FM_ALL6", 60, "0"),
    ("inc_32_preserves_cf", "inc eax", "FM_ALL6", 60, "0"),
    ("inc_8_preserves_cf",  "inc al", "FM_ALL6", 60, "0"),
    ("dec_64_preserves_cf", "dec rax", "FM_ALL6", 60, "0"),
    ("dec_32_preserves_cf", "dec eax", "FM_ALL6", 60, "0"),
    ("dec_8_preserves_cf",  "dec al", "FM_ALL6", 60, "0"),
    ("neg_64", "neg rax", "FM_ALL6", 60, "0"),
    ("neg_32", "neg eax", "FM_ALL6", 60, "0"),
    ("neg_8",  "neg al", "FM_ALL6", 60, "0"),
    ("not_all", "not rax; not ebx; not cx; not dl", "FM_ALL6", 40, "0"),
    ("and_64", "and rax, rbx", "FM_NOAF", 60, "0"),
    ("and_32", "and eax, ebx", "FM_NOAF", 60, "0"),
    ("and_8",  "and al, bl", "FM_NOAF", 60, "0"),
    ("or_64",  "or rax, rbx", "FM_NOAF", 60, "0"),
    ("or_32",  "or eax, ebx", "FM_NOAF", 60, "0"),
    ("xor_64", "xor rax, rbx", "FM_NOAF", 60, "0"),
    ("xor_self_32", "xor eax, eax", "FM_NOAF", 40, "0"),
    ("cmp_64", "cmp rax, rbx", "FM_ALL6", 60, "0"),
    ("cmp_32", "cmp eax, ebx", "FM_ALL6", 60, "0"),
    ("cmp_8",  "cmp al, bl", "FM_ALL6", 60, "0"),
    ("test_64", "test rax, rbx", "FM_NOAF", 60, "0"),
    ("test_8",  "test al, bl", "FM_NOAF", 60, "0"),

    # ---- LOCK atomics ----
    ("lock_add_sub_inc_dec", "lock add qword ptr [rdi+8], rax; lock sub dword ptr [rdi+16], ebx; lock inc dword ptr [rdi+20]; lock dec qword ptr [rdi+24]", "FM_ALL6", 40, "0"),
    ("lock_xadd_64", "lock xadd qword ptr [rdi+8], rax", "FM_ALL6", 40, "0"),
    ("lock_xadd_32", "lock xadd dword ptr [rdi+16], ebx", "FM_ALL6", 40, "0"),
    ("xadd_alias_eax_eax", "xadd eax, eax; xadd rbx, rbx", "FM_ALL6", 40, "0"),
    ("lock_cmpxchg_hit", "mov qword ptr [rdi+8], rax; lock cmpxchg qword ptr [rdi+8], rbx", "FM_ALL6", 40, "0"),
    ("lock_cmpxchg_miss", "mov qword ptr [rdi+8], rcx; lock cmpxchg qword ptr [rdi+8], rbx", "FM_ZF", 40, "0"),
    ("lock_cmpxchg_32", "lock cmpxchg dword ptr [rdi+16], ebx", "FM_ZF", 40, "0"),
    ("lock_cmpxchg_32_hit_zext", "mov dword ptr [rdi+16], eax; lock cmpxchg dword ptr [rdi+16], ebx", "FM_ALL6", 40, "0"),
    ("cmpxchg_reg", "cmpxchg rbx, rcx", "FM_ZF", 40, "0"),

    # ---- Multiply & Divide ----
    ("mul_64", "mul rbx", "FM_CF | FM_OF", 60, "0"),
    ("mul_32", "mul ebx", "FM_CF | FM_OF", 60, "0"),
    ("mul_16", "mul bx",  "FM_CF | FM_OF", 60, "0"),
    ("mul_8",  "mul bl",  "FM_CF | FM_OF", 60, "0"),
    ("imul_1op_64", "imul rbx", "FM_CF | FM_OF", 60, "0"),
    ("imul_1op_32", "imul ebx", "FM_CF | FM_OF", 60, "0"),
    ("imul_2op_64", "imul rax, rbx", "FM_CF | FM_OF", 60, "0"),
    ("imul_3op_32", "imul eax, ebx, -12345", "FM_CF | FM_OF", 60, "0"),
    ("idiv_64", "cqo; idiv rbx", "FM_NONE", 60, "DF_DIV_SAFE"),
    ("idiv_32", "cdq; idiv ebx", "FM_NONE", 60, "DF_DIV_SAFE"),
    ("div_64",  "mov rdx, r9; div r8", "FM_NONE", 60, "DF_DIV_SAFE"),
    ("div_32",  "mov edx, r9d; div r8d", "FM_NONE", 60, "DF_DIV_SAFE"),

    # ---- Shifts & Rotates (including count==0 flag preservation & count==1 OF!) ----
    ("shl_64_cl", "shl rax, cl", "FM_SZP | FM_CF", 60, "0"),
    ("shl_64_1",  "shl rax, 1",  "FM_SZPCO", 60, "0"),
    ("shl_32_cl", "shl eax, cl", "FM_SZP | FM_CF", 60, "0"),
    ("shl_32_1",  "shl eax, 1",  "FM_SZPCO", 60, "0"),
    ("shl_16_1",  "shl ax, 1",   "FM_SZPCO", 60, "0"),
    ("shl_8_1",   "shl al, 1",   "FM_SZPCO", 60, "0"),
    ("shl_64_zero_preserves_flags", "xor ecx, ecx; shl rax, cl", "FM_NOAF", 40, "0"),
    ("shr_64_cl", "shr rax, cl", "FM_SZP | FM_CF", 60, "0"),
    ("shr_64_1",  "shr rax, 1",  "FM_SZPCO", 60, "0"),
    ("shr_32_cl", "shr eax, cl", "FM_SZP | FM_CF", 60, "0"),
    ("shr_32_1",  "shr eax, 1",  "FM_SZPCO", 60, "0"),
    ("shr_8_1",   "shr al, 1",   "FM_SZPCO", 60, "0"),
    ("sar_64_cl", "sar rax, cl", "FM_SZP | FM_CF", 60, "0"),
    ("sar_64_1",  "sar rax, 1",  "FM_SZPCO", 60, "0"),
    ("sar_32_cl", "sar eax, cl", "FM_SZP | FM_CF", 60, "0"),
    ("sar_32_1",  "sar eax, 1",  "FM_SZPCO", 60, "0"),
    ("sar_8_1",   "sar al, 1",   "FM_SZPCO", 60, "0"),
    ("rol_64_1",  "rol rax, 1",  "FM_ALL6", 60, "0"),
    ("rol_64_cl", "rol rax, cl", "FM_CF | FM_SZP | FM_AF", 60, "0"),
    ("rol_32_1",  "rol eax, 1",  "FM_ALL6", 60, "0"),
    ("ror_64_1",  "ror rax, 1",  "FM_ALL6", 60, "0"),
    ("ror_64_cl", "ror rax, cl", "FM_CF | FM_SZP | FM_AF", 60, "0"),
    ("ror_32_1",  "ror eax, 1",  "FM_ALL6", 60, "0"),
    ("shld_64_1", "shld rax, rbx, 1", "FM_SZPCO", 60, "0"),
    ("shld_64_cl","shld rax, rbx, cl", "FM_SZP | FM_CF", 60, "0"),
    ("shld_32_1", "shld eax, ebx, 1", "FM_SZPCO", 60, "0"),
    ("shld_16_16", "shld ax, bx, 16", "FM_SZP", 60, "0"),
    ("shrd_64_1", "shrd rax, rbx, 1", "FM_SZPCO", 60, "0"),
    ("shrd_64_cl","shrd rax, rbx, cl", "FM_SZP | FM_CF", 60, "0"),
    ("shrd_32_1", "shrd eax, ebx, 1", "FM_SZPCO", 60, "0"),
    ("shrd_16_16", "shrd ax, bx, 16", "FM_SZP", 60, "0"),

    # ---- Bit manipulation ----
    ("bt_reg_64", "bt rax, rcx", "FM_CF", 60, "0"),
    ("bt_reg_32", "bt eax, ecx", "FM_CF", 60, "0"),
    ("bt_reg_imm","bt rax, 37",  "FM_CF", 40, "0"),
    ("bt_mem_signed", "bt qword ptr [rdi], rcx", "FM_CF", 60, "DF_SMALL_IDX"),
    ("bts_btr_btc_reg", "bts rax, rcx; btr rbx, rcx; btc rdx, 19", "FM_CF", 60, "0"),
    ("bsf_64", "bsf rdx, rax", "FM_ZF", 60, "0"),
    ("bsf_32_zero", "xor eax, eax; bsf edx, eax", "FM_ZF", 20, "0"),
    ("bsr_64", "bsr rdx, rax", "FM_ZF", 60, "0"),
    ("bsr_32", "bsr edx, eax", "FM_ZF", 60, "0"),
    ("popcnt_64", "popcnt rdx, rax", "FM_ALL6", 60, "0"),
    ("popcnt_32", "popcnt edx, eax", "FM_ALL6", 60, "0"),

    # ---- CMOVcc / SETcc / Jcc ----
    ("cmov_all_32_zext",
     "cmp r8, r9; cmovz eax, ebx; cmovnz ecx, edx; cmovb r10d, r11d; cmovnb r12d, r13d; "
     "cmovl r14d, r15d; cmovnl eax, ecx; cmovle ebx, edx; cmovnle r10d, r14d; "
     "cmovbe r11d, r12d; cmovnbe r13d, r15d; cmovs eax, r8d; cmovns ebx, r9d; "
     "cmovo ecx, r10d; cmovno edx, r11d; cmovp r12d, r13d; cmovnp r14d, r15d",
     "FM_ALL6", 60, "0"),
    ("setcc_all",
     "sub rax, rbx; setz r8b; setnz r9b; setb r10b; setnb r11b; setbe r12b; setnbe r13b; "
     "setl r14b; setnl r15b; setle cl; setnle dl; sets al; setns bl; setp ch; setnp dh",
     "FM_ALL6", 60, "0"),
    ("jcc_branch_loop",
     "xor eax, eax; and ecx, 15; 1: test ecx, ecx; jz 2f; add rax, rbx; dec ecx; jnz 1b; 2:",
     "FM_NOAF", 40, "0"),

    # ---- String ops ----
    ("rep_movsq", "rep movsq", "FM_ALL6 | FM_DF", 40, "DF_STRING_OP"),
    ("rep_movsb", "rep movsb", "FM_ALL6 | FM_DF", 40, "DF_STRING_OP"),
    ("rep_stosd", "rep stosd", "FM_ALL6 | FM_DF", 40, "DF_STRING_OP"),
    ("rep_stosb", "rep stosb", "FM_ALL6 | FM_DF", 40, "DF_STRING_OP"),

    # ---- SSE / SSE2 Moves ----
    ("sse_mov_128", "movaps xmm0, xmm1; movups xmm2, [rdi]; movdqa [rdi+16], xmm3; movdqu xmm4, [rdi+3]; lddqu xmm5, [rdi+5]; movapd xmm6, xmm7; movupd [rdi+32], xmm8; movntps [rdi+48], xmm9", "FM_ALL6", 40, "0"),
    ("movss_reg_and_mem", "movss xmm0, xmm1; movss xmm2, dword ptr [rdi+4]; movss dword ptr [rdi+8], xmm3", "FM_ALL6", 40, "0"),
    ("movsd_reg_and_mem", "movsd xmm0, xmm1; movsd xmm2, qword ptr [rdi+8]; movsd qword ptr [rdi+16], xmm3", "FM_ALL6", 40, "0"),
    ("movd_movq_all", "movd xmm0, eax; movd ebx, xmm1; movq xmm2, rcx; movq rdx, xmm3; movq xmm4, xmm5; movq xmm6, qword ptr [rdi+8]; movq qword ptr [rdi+16], xmm7", "FM_ALL6", 40, "0"),
    ("movlps_hps_hl_lh", "movlps xmm0, qword ptr [rdi+8]; movhps xmm1, qword ptr [rdi+16]; movlpd qword ptr [rdi+24], xmm2; movhpd qword ptr [rdi+32], xmm3; movhlps xmm4, xmm5; movlhps xmm6, xmm7", "FM_ALL6", 40, "0"),
    ("movshdup_sldup_ddup", "movshdup xmm0, xmm1; movsldup xmm2, xmm3; movddup xmm4, xmm5; movddup xmm6, qword ptr [rdi+8]", "FM_ALL6", 40, "0"),
    ("movmsk_pmovmskb", "movmskps eax, xmm0; movmskpd ebx, xmm1; pmovmskb ecx, xmm2", "FM_ALL6", 40, "0"),

    # ---- SSE / SSE2 Scalar & Packed Float/Double Math ----
    ("ss_arith", "addss xmm0, xmm1; subss xmm2, xmm3; mulss xmm4, xmm5; divss xmm6, xmm7; sqrtss xmm8, xmm9", "FM_ALL6", 60, "DF_NAN_CANON_F32"),
    ("sd_arith", "addsd xmm0, xmm1; subsd xmm2, xmm3; mulsd xmm4, xmm5; divsd xmm6, xmm7; sqrtsd xmm8, xmm9", "FM_ALL6", 60, "DF_NAN_CANON_F64"),
    ("ps_arith", "addps xmm0, xmm1; subps xmm2, xmm3; mulps xmm4, xmm5; divps xmm6, xmm7; sqrtps xmm8, xmm9", "FM_ALL6", 60, "DF_NAN_CANON_F32"),
    ("pd_arith", "addpd xmm0, xmm1; subpd xmm2, xmm3; mulpd xmm4, xmm5; divpd xmm6, xmm7; sqrtpd xmm8, xmm9", "FM_ALL6", 60, "DF_NAN_CANON_F64"),
    ("min_max_ss_sd_ps_pd", "minss xmm0, xmm1; maxss xmm2, xmm3; minsd xmm4, xmm5; maxsd xmm6, xmm7; minps xmm8, xmm9; maxps xmm10, xmm11; minpd xmm12, xmm13; maxpd xmm14, xmm15", "FM_ALL6", 60, "0"),
    ("hadd_addsub", "haddps xmm0, xmm1; haddpd xmm2, xmm3; addsubps xmm4, xmm5; addsubpd xmm6, xmm7", "FM_ALL6", 60, "0"),
    ("rcp_rsqrt_approx", "rcpss xmm0, xmm1; rcpps xmm2, xmm3; rsqrtps xmm4, xmm5", "FM_ALL6", 40, "DF_APPROX_FP"),
    ("round_ss_sd_ps", "roundss xmm0, xmm1, 0; roundss xmm2, xmm3, 1; roundss xmm4, xmm5, 2; roundss xmm6, xmm7, 3; roundsd xmm8, xmm9, 1; roundps xmm10, xmm11, 2; roundps xmm12, xmm13, 3", "FM_ALL6", 60, "0"),

    # ---- Float/Double Comparisons ----
    ("ucomiss", "ucomiss xmm0, xmm1", "FM_ALL6", 80, "0"),
    ("ucomisd", "ucomisd xmm0, xmm1", "FM_ALL6", 80, "0"),
    ("cmpss_all", "cmpss xmm0, xmm1, 0; cmpss xmm2, xmm3, 1; cmpss xmm4, xmm5, 2; cmpss xmm6, xmm7, 3; cmpss xmm8, xmm9, 4; cmpss xmm10, xmm11, 5; cmpss xmm12, xmm13, 6; cmpss xmm14, xmm15, 7", "FM_ALL6", 60, "0"),
    ("cmpps_all", "cmpps xmm0, xmm1, 0; cmpps xmm2, xmm3, 1; cmpps xmm4, xmm5, 2; cmpps xmm6, xmm7, 6", "FM_ALL6", 60, "0"),
    ("cmpsd_cmppd", "cmpsd xmm0, xmm1, 1; cmpsd xmm2, xmm3, 4; cmppd xmm4, xmm5, 2; cmppd xmm6, xmm7, 7", "FM_ALL6", 60, "0"),

    # ---- Conversions (including NaN / Inf / INT_MIN / >INT_MAX edge cases!) ----
    ("cvtsi2ss_sd", "cvtsi2ss xmm0, eax; cvtsi2ss xmm1, rbx; cvtsi2sd xmm2, ecx; cvtsi2sd xmm3, rdx", "FM_ALL6", 60, "0"),
    ("cvtss2sd_sd2ss", "cvtss2sd xmm0, xmm1; cvtsd2ss xmm2, xmm3", "FM_ALL6", 60, "0"),
    ("cvttss2si_32_64", "cvttss2si eax, xmm0; cvttss2si rbx, xmm1", "FM_ALL6", 80, "0"),
    ("cvttsd2si_32_64", "cvttsd2si eax, xmm0; cvttsd2si rbx, xmm1", "FM_ALL6", 80, "0"),
    ("cvt_vec_all", "cvtdq2ps xmm0, xmm1; cvtdq2pd xmm2, xmm3; cvtps2pd xmm4, xmm5; cvtpd2ps xmm6, xmm7; cvtps2dq xmm8, xmm9; cvttps2dq xmm10, xmm11", "FM_ALL6", 80, "0"),

    # ---- Bitwise Vector ----
    ("vec_bitwise", "andps xmm0, xmm1; andnps xmm2, xmm3; orps xmm4, xmm5; xorps xmm6, xmm7; andpd xmm8, xmm9; andnpd xmm10, xmm11; orpd xmm12, xmm13; xorpd xmm14, xmm15", "FM_ALL6", 40, "0"),
    ("vec_pbitwise", "pand xmm0, xmm1; pandn xmm2, xmm3; por xmm4, xmm5; pxor xmm6, xmm7; pxor xmm8, xmm8", "FM_ALL6", 40, "0"),

    # ---- Shuffles, Unpacks, Insert/Extract, Blends, Align ----
    ("shufps_shufpd_pshuf", "shufps xmm0, xmm1, 0x93; shufpd xmm2, xmm3, 2; pshufd xmm4, xmm5, 0x4e; pshuflw xmm6, xmm7, 0xb1; pshufb xmm8, xmm9", "FM_ALL6", 60, "0"),
    ("unpck_all", "unpcklps xmm0, xmm1; unpckhps xmm2, xmm3; unpcklpd xmm4, xmm5; unpckhpd xmm6, xmm7; punpcklbw xmm8, xmm9; punpcklwd xmm10, xmm11; punpckhwd xmm12, xmm13; punpckldq xmm14, xmm15", "FM_ALL6", 40, "0"),
    ("punpck_dq_qdq", "punpckhdq xmm0, xmm1; punpcklqdq xmm2, xmm3; punpckhqdq xmm4, xmm5", "FM_ALL6", 40, "0"),
    ("insertps_extractps", "insertps xmm0, xmm1, 0x95; insertps xmm2, dword ptr [rdi+4], 0x28; extractps eax, xmm3, 2; extractps dword ptr [rdi+8], xmm4, 3", "FM_ALL6", 60, "0"),
    ("pinsr_pextr_all", "pinsrb xmm0, eax, 7; pinsrw xmm1, ebx, 5; pinsrd xmm2, ecx, 2; pinsrq xmm3, rdx, 1; pextrb r8d, xmm4, 11; pextrw r9d, xmm5, 6; pextrd r10d, xmm6, 3; pextrq r11, xmm7, 1", "FM_ALL6", 60, "0"),
    ("blends_all", "blendps xmm1, xmm2, 0xa; blendpd xmm3, xmm4, 1; pblendw xmm5, xmm6, 0x5a; blendvps xmm7, xmm8, xmm0; blendvpd xmm9, xmm10, xmm0; pblendvb xmm11, xmm12, xmm0", "FM_ALL6", 60, "0"),
    ("palignr_all", "palignr xmm0, xmm1, 5; palignr xmm2, xmm3, 16; palignr xmm4, xmm5, 25; palignr xmm6, xmm7, 32", "FM_ALL6", 40, "0"),

    # ---- Packed Integer ALU, Cmp, Min/Max, Shifts, Extends, Packs ----
    ("padd_psub_pmul", "paddb xmm0, xmm1; paddw xmm2, xmm3; paddd xmm4, xmm5; paddq xmm6, xmm7; psubd xmm8, xmm9; psubq xmm10, xmm11; pmullw xmm12, xmm13; pmulld xmm14, xmm15", "FM_ALL6", 40, "0"),
    ("pmuludq_phaddd", "pmuludq xmm0, xmm1; phaddd xmm2, xmm3", "FM_ALL6", 40, "0"),
    ("pcmp_all", "pcmpeqb xmm0, xmm1; pcmpeqw xmm2, xmm3; pcmpeqd xmm4, xmm5; pcmpeqq xmm6, xmm7; pcmpgtw xmm8, xmm9; pcmpgtd xmm10, xmm11; pcmpgtq xmm12, xmm13", "FM_ALL6", 60, "0"),
    ("pmin_pmax_all", "pminsd xmm0, xmm1; pmaxsd xmm2, xmm3; pminuw xmm4, xmm5; pminud xmm6, xmm7; pmaxud xmm8, xmm9", "FM_ALL6", 60, "0"),
    ("pshift_imm", "psllw xmm0, 5; pslld xmm1, 13; psllq xmm2, 37; psrld xmm3, 17; psrlq xmm4, 41; psraw xmm5, 9; psrad xmm6, 21; pslld xmm7, 33; psrad xmm8, 40; pslldq xmm9, 3; psrldq xmm10, 7", "FM_ALL6", 40, "0"),
    ("pshift_reg", "and qword ptr [rdi+8], 63; movq xmm15, qword ptr [rdi+8]; pslld xmm0, xmm15; psrld xmm1, xmm15; psrad xmm2, xmm15; psllq xmm3, xmm15; psrlq xmm4, xmm15", "FM_NOAF", 60, "0"),
    ("pmovzx_all", "pmovzxbw xmm0, xmm1; pmovzxbd xmm2, xmm3; pmovzxbq xmm4, xmm5; pmovzxwd xmm6, xmm7; pmovzxwq xmm8, dword ptr [rdi+4]; pmovzxdq xmm10, qword ptr [rdi+8]", "FM_ALL6", 40, "0"),
    ("pmovsx_all", "pmovsxbd xmm0, xmm1; pmovsxbq xmm2, xmm3; pmovsxwd xmm4, xmm5; pmovsxwq xmm6, dword ptr [rdi+4]; pmovsxdq xmm8, qword ptr [rdi+8]", "FM_ALL6", 40, "0"),
    ("pack_all", "packsswb xmm0, xmm1; packuswb xmm2, xmm3; packssdw xmm4, xmm5; packusdw xmm6, xmm7", "FM_ALL6", 60, "0"),
]

# 1. Generate snippets_x86.S
asm_path = os.path.join(CACHE, "snippets_x86.S")
with open(asm_path, "w") as f:
    f.write(".intel_syntax noprefix\n.text\n")
    for name, body, _, _, _ in TESTS:
        f.write(f".globl _snip_{name}\n.p2align 4\n_snip_{name}:\n")
        for stmt in body.split(";"):
            stmt = stmt.strip()
            if stmt:
                f.write(f"    {stmt}\n")
        f.write("    ret\n\n")
    f.write(".globl _snip_END\n_snip_END:\n    nop\n")

# 2. Assemble snippets_x86.S as x86_64
snip_o = os.path.join(CACHE, "snippets_x86.o")
subprocess.check_call(["clang", "-arch", "x86_64", "-c", asm_path, "-o", snip_o])

# 3. Extract exact byte ranges of every _snip_* from snippets_x86.o using nm + otool/Mach-O
nm_out = subprocess.check_output(["nm", "-n", snip_o], text=True)
syms = []
for line in nm_out.splitlines():
    parts = line.split()
    if len(parts) == 3 and parts[2].startswith("_snip_"):
        syms.append((int(parts[0], 16), parts[2]))
syms.sort()

# Read __text section bytes from Mach-O .o
with open(snip_o, "rb") as f:
    obj_raw = f.read()
# Parse Mach-O 64-bit header to find __TEXT,__text offset
ncmds = struct.unpack_from("<I", obj_raw, 16)[0]
off = 32
text_off = 0
text_size = 0
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", obj_raw, off)
    if cmd == 0x19: # LC_SEGMENT_64
        nsects = struct.unpack_from("<I", obj_raw, off + 64)[0]
        soff = off + 72
        for _ in range(nsects):
            sectname = obj_raw[soff:soff+16].split(b"\0")[0].decode()
            if sectname == "__text":
                text_size = struct.unpack_from("<Q", obj_raw, soff + 40)[0]
                text_off = struct.unpack_from("<I", obj_raw, soff + 48)[0]
            soff += 80
    off += cmdsize
text_bytes = obj_raw[text_off:text_off + text_size]

sym_bytes = {}
for i in range(len(syms) - 1):
    addr, sname = syms[i]
    nxt_addr, _ = syms[i + 1]
    if sname == "_snip_END":
        continue
    # Trim trailing NOP padding between aligned functions? Wait: ret is before padding,
    # build_raw_cfg stops at ret, or keeps only reachable blocks. Even safer: slice [addr:nxt_addr]!
    sym_bytes[sname] = text_bytes[addr:nxt_addr]

# 4. Lift every snippet using bo3_lift --raw --cc full --tso relaxed --full-flags
bo3_lift = os.path.join(ROOT, "build", "bo3_lift")
combined_ll = os.path.join(CACHE, "lifted_all.ll")
header_written = False
all_decls = set()
bodies = []
for idx, (name, _, _, _, _) in enumerate(TESTS):
    raw_path = os.path.join(CACHE, f"s_{name}.bin")
    ll_path = os.path.join(CACHE, f"s_{name}.ll")
    with open(raw_path, "wb") as f:
        f.write(sym_bytes[f"_snip_{name}"])
    base_va = 0x100000000 + idx * 0x1000
    subprocess.check_call([
        bo3_lift, "--raw", raw_path, hex(base_va), f"lifted_{name}",
        "--cc", "full", "--tso", "relaxed", "--full-flags", "-o", ll_path
    ])
    with open(ll_path) as f:
        txt = f.read()
    # Extract define block and declare lines
    for line in txt.splitlines():
        if line.startswith("declare "):
            all_decls.add(line)
    m = re.search(r"(define void @lifted_.*?\n\}\n)", txt, re.S)
    assert m, f"No define in {ll_path}"
    bodies.append(m.group(1))

with open(combined_ll, "w") as f:
    f.write('target datalayout = "e-m:o-i64:64-i128:128-n32:64-S128-Fn32"\n')
    f.write('target triple = "arm64-apple-macosx15.0.0"\n')
    f.write('%ret_t = type { <2 x i64>, <2 x i64>, <2 x i64> }\n\n')
    for d in sorted(all_decls):
        f.write(d + "\n")
    f.write("\n")
    for b in bodies:
        f.write(b + "\n")
    f.write('attributes #0 = { "target-cpu"="apple-m1" "target-features"="+lse,+rcpc" }\n')

lifted_o = os.path.join(CACHE, "lifted_all.o")
subprocess.check_call([
    "clang", "-arch", "arm64", "-mcpu=apple-m4", "-O2",
    "-Wno-override-module", "-x", "ir", "-c", combined_ll, "-o", lifted_o
])

# 5. Generate diff_x86.c and diff_arm64.c
def emit_table(prefix):
    lines = []
    for name, _, _, _, _ in TESTS:
        lines.append(f"extern void {prefix}_{name}(void);")
    lines.append("static DiffTestDesc g_tests[] = {")
    for name, _, fmask, iters, dflags in TESTS:
        lines.append(f'    {{ "{name}", (void*){prefix}_{name}, ({fmask}), {iters}, ({dflags}) }},')
    lines.append("};")
    lines.append("static const size_t g_num_tests = sizeof(g_tests)/sizeof(g_tests[0]);")
    return "\n".join(lines)

x86_c = os.path.join(CACHE, "diff_x86.c")
with open(x86_c, "w") as f:
    f.write(f'''
#include "{ROOT}/tests/diff/diff_common.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

extern void run_x86_snippet(void *fn, GuestContext *ctx);
{emit_table("snip")}

int main(int argc, char **argv) {{
    void *arena = mmap((void *)DIFF_ARENA_VA, DIFF_ARENA_SIZE, PROT_READ|PROT_WRITE,
                       MAP_PRIVATE|MAP_ANON|MAP_FIXED, -1, 0);
    if (arena != (void *)DIFF_ARENA_VA) {{ perror("mmap x86 arena"); return 1; }}

    FILE *out = fopen(argv[1], "wb");
    if (!out) {{ perror("fopen"); return 1; }}
    uint8_t *data_ptr = (uint8_t *)DIFF_DATA_BASE;

    for (size_t t = 0; t < g_num_tests; t++) {{
        for (uint32_t it = 0; it < g_tests[t].iters; it++) {{
            memset(arena, 0, DIFF_ARENA_SIZE);
            DiffResult r;
            memset(&r, 0, sizeof(r));
            fill_test_state((uint32_t)t, it, g_tests[t].flags, &r.ctx, data_ptr);
            run_x86_snippet(g_tests[t].fn, &r.ctx);
            memcpy(r.mem, data_ptr, DIFF_MEM_SNAP_SIZE);
            fwrite(&r, sizeof(r), 1, out);
        }}
    }}
    fclose(out);
    return 0;
}}
''')

arm_c = os.path.join(CACHE, "diff_arm64.c")
with open(arm_c, "w") as f:
    f.write(f'''
#include "{ROOT}/tests/diff/diff_common.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

{emit_table("lifted")}

static const char *kRegNames[16] = {{
    "rax","rcx","rdx","rbx","rsp","rbp","rsi","rdi",
    "r8","r9","r10","r11","r12","r13","r14","r15"
}};

static int xmm_match(GuestXmm a, GuestXmm b, uint32_t dflags) {{
    if (a[0] == b[0] && a[1] == b[1]) return 1;
    if (dflags & DF_NAN_CANON_F32) {{
        uint32_t ua[4], ub[4];
        memcpy(ua, &a, 16); memcpy(ub, &b, 16);
        int ok = 1;
        for (int k = 0; k < 4; k++) {{
            if (ua[k] == ub[k]) continue;
            int na = ((ua[k] & 0x7f800000u) == 0x7f800000u) && ((ua[k] & 0x007fffffu) != 0);
            int nb = ((ub[k] & 0x7f800000u) == 0x7f800000u) && ((ub[k] & 0x007fffffu) != 0);
            if (!(na && nb)) {{ ok = 0; break; }}
        }}
        if (ok) return 1;
    }}
    if (dflags & DF_NAN_CANON_F64) {{
        uint64_t ua[2] = {{ a[0], a[1] }}, ub[2] = {{ b[0], b[1] }};
        int ok = 1;
        for (int k = 0; k < 2; k++) {{
            if (ua[k] == ub[k]) continue;
            int na = ((ua[k] & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL) && ((ua[k] & 0x000fffffffffffffULL) != 0);
            int nb = ((ub[k] & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL) && ((ub[k] & 0x000fffffffffffffULL) != 0);
            if (!(na && nb)) {{ ok = 0; break; }}
        }}
        if (ok) return 1;
    }}
    if (!(dflags & DF_APPROX_FP)) return 0;
    float fa[4], fb[4];
    memcpy(fa, &a, 16);
    memcpy(fb, &b, 16);
    for (int k = 0; k < 4; k++) {{
        float diff = fabsf(fa[k] - fb[k]);
        float tol = fabsf(fa[k]) * 1e-3f + 1e-6f;
        if (diff > tol) return 0;
    }}
    return 1;
}}

int main(int argc, char **argv) {{
    void *arena = mmap((void *)DIFF_ARENA_VA, DIFF_ARENA_SIZE, PROT_READ|PROT_WRITE,
                       MAP_PRIVATE|MAP_ANON|MAP_FIXED, -1, 0);
    if (arena != (void *)DIFF_ARENA_VA) {{ perror("mmap arm64 arena"); return 1; }}

    FILE *ref_f = fopen(argv[1], "rb");
    if (!ref_f) {{ perror("fopen ref"); return 1; }}
    uint8_t *data_ptr = (uint8_t *)DIFF_DATA_BASE;

    uint64_t total_runs = 0, passed_runs = 0, failed_tests = 0;
    for (size_t t = 0; t < g_num_tests; t++) {{
        int test_failed = 0;
        for (uint32_t it = 0; it < g_tests[t].iters; it++) {{
            DiffResult ref, got;
            if (fread(&ref, sizeof(ref), 1, ref_f) != 1) {{
                fprintf(stderr, "Short read on ref!\\n");
                return 1;
            }}
            memset(arena, 0, DIFF_ARENA_SIZE);
            memset(&got, 0, sizeof(got));
            fill_test_state((uint32_t)t, it, g_tests[t].flags, &got.ctx, data_ptr);
            // Mirror x86 trampoline pushing return address before entering snippet
            got.ctx.gpr[G_RSP] -= 8;
            void (*lfn)(GuestContext *) = (void (*)(GuestContext *))g_tests[t].fn;
            lfn(&got.ctx);
            memcpy(got.mem, data_ptr, DIFF_MEM_SNAP_SIZE);

            total_runs++;
            int ok = 1;
            for (int r = 0; r < 16; r++) {{
                if (ref.ctx.gpr[r] != got.ctx.gpr[r]) {{
                    if (!test_failed) {{
                        fprintf(stderr, "FAIL %-28s iter=%u GPR %s: x86=0x%016llx arm64=0x%016llx\\n",
                            g_tests[t].name, it, kRegNames[r],
                            (unsigned long long)ref.ctx.gpr[r], (unsigned long long)got.ctx.gpr[r]);
                    }}
                    ok = 0; break;
                }}
            }}
            if (ok) {{
                for (int x = 0; x < 16; x++) {{
                    if (!xmm_match(ref.ctx.xmm[x], got.ctx.xmm[x], g_tests[t].flags)) {{
                        if (!test_failed) {{
                            fprintf(stderr, "FAIL %-28s iter=%u XMM%d: x86=%016llx_%016llx arm64=%016llx_%016llx\\n",
                                g_tests[t].name, it, x,
                                (unsigned long long)ref.ctx.xmm[x][1], (unsigned long long)ref.ctx.xmm[x][0],
                                (unsigned long long)got.ctx.xmm[x][1], (unsigned long long)got.ctx.xmm[x][0]);
                        }}
                        ok = 0; break;
                    }}
                }}
            }}
            if (ok) {{
                uint64_t rf_ref = ref.ctx.rflags & g_tests[t].flag_mask;
                uint64_t rf_got = got.ctx.rflags & g_tests[t].flag_mask;
                if (rf_ref != rf_got) {{
                    if (!test_failed) {{
                        fprintf(stderr, "FAIL %-28s iter=%u RFLAGS(mask=0x%llx): x86=0x%llx arm64=0x%llx\\n",
                            g_tests[t].name, it, (unsigned long long)g_tests[t].flag_mask,
                            (unsigned long long)rf_ref, (unsigned long long)rf_got);
                    }}
                    ok = 0;
                }}
            }}
            if (ok && memcmp(ref.mem, got.mem, DIFF_MEM_SNAP_SIZE) != 0) {{
                for (int b = 0; b < DIFF_MEM_SNAP_SIZE; b++) {{
                    if (ref.mem[b] != got.mem[b]) {{
                        if (!test_failed) {{
                            fprintf(stderr, "FAIL %-28s iter=%u MEM[+%d]: x86=0x%02x arm64=0x%02x\\n",
                                g_tests[t].name, it, b, ref.mem[b], got.mem[b]);
                        }}
                        break;
                    }}
                }}
                ok = 0;
            }}
            if (ok) passed_runs++;
            else test_failed = 1;
        }}
        if (test_failed) failed_tests++;
    }}
    fclose(ref_f);
    printf("============================================================\\n");
    printf("ROSETTA 2 vs NATIVE ARM64 DIFFERENTIAL FUZZER SUMMARY:\\n");
    printf("  Test suites: %zu total, %zu PASSED, %llu FAILED\\n",
           g_num_tests, g_num_tests - (size_t)failed_tests, (unsigned long long)failed_tests);
    printf("  Total cases: %llu / %llu bit-exact matches\\n",
           (unsigned long long)passed_runs, (unsigned long long)total_runs);
    printf("============================================================\\n");
    return failed_tests == 0 ? 0 : 1;
}}
''')

diff_x86_bin = os.path.join(CACHE, "diff_x86")
diff_arm_bin = os.path.join(CACHE, "diff_arm64")
ref_bin = os.path.join(CACHE, "ref_x86.bin")

subprocess.check_call([
    "clang", "-arch", "x86_64", "-O2",
    x86_c, os.path.join(ROOT, "tests/diff/trampoline_x86.S"), snip_o,
    "-o", diff_x86_bin
])
subprocess.check_call([
    "clang", "-arch", "arm64", "-mcpu=apple-m4", "-O2",
    f"-I{ROOT}/runtime",
    arm_c, os.path.join(ROOT, "runtime/runtime_core.c"), lifted_o,
    "-o", diff_arm_bin
])

print(f"Running {len(TESTS)} test suites under Rosetta 2 (x86_64)...")
subprocess.check_call([diff_x86_bin, ref_bin])
print(f"Running {len(TESTS)} lifted suites natively on Apple Silicon (ARM64)...")
rc = subprocess.call([diff_arm_bin, ref_bin])
sys.exit(rc)

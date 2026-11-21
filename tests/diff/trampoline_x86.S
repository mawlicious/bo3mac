// x86_64 trampoline: void run_x86_snippet(void *fn, GuestContext *ctx)
// Loads ALL 16 GPRs, ALL 16 XMMs, RFLAGS, calls fn via synthetic return address on guest stack,
// captures ALL 16 GPRs, ALL 16 XMMs, RFLAGS back into ctx, and restores host state.
.text
.globl _run_x86_snippet
.p2align 4
_run_x86_snippet:
    // Save host callee-saved registers & ctx/fn pointers into static scratch
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq  %rsp, _g_host_rsp(%rip)
    movq  %rsi, _g_ctx_ptr(%rip)
    movq  %rdi, _g_fn_ptr(%rip)

    // %r15 temporarily holds ctx
    movq  %rsi, %r15

    // Push return target onto guest stack (guest rsp - 8)
    movq  32(%r15), %rax      // ctx->gpr[G_RSP]
    subq  $8, %rax
    leaq  L_after_snippet(%rip), %rcx
    movq  %rcx, (%rax)
    movq  %rax, _g_guest_rsp(%rip)

    // Load XMM0..XMM15 from ctx + 0x80
    movdqa 0x80(%r15), %xmm0
    movdqa 0x90(%r15), %xmm1
    movdqa 0xa0(%r15), %xmm2
    movdqa 0xb0(%r15), %xmm3
    movdqa 0xc0(%r15), %xmm4
    movdqa 0xd0(%r15), %xmm5
    movdqa 0xe0(%r15), %xmm6
    movdqa 0xf0(%r15), %xmm7
    movdqa 0x100(%r15), %xmm8
    movdqa 0x110(%r15), %xmm9
    movdqa 0x120(%r15), %xmm10
    movdqa 0x130(%r15), %xmm11
    movdqa 0x140(%r15), %xmm12
    movdqa 0x150(%r15), %xmm13
    movdqa 0x160(%r15), %xmm14
    movdqa 0x170(%r15), %xmm15

    // Load RFLAGS via host stack before switching to guest rsp
    movq  0x180(%r15), %rax
    pushq %rax
    popfq

    // Load GPRs (keep r15 until last!)
    movq  0(%r15),   %rax
    movq  8(%r15),   %rcx
    movq  16(%r15),  %rdx
    movq  24(%r15),  %rbx
    movq  40(%r15),  %rbp
    movq  48(%r15),  %rsi
    movq  56(%r15),  %rdi
    movq  64(%r15),  %r8
    movq  72(%r15),  %r9
    movq  80(%r15),  %r10
    movq  88(%r15),  %r11
    movq  96(%r15),  %r12
    movq  104(%r15), %r13
    movq  112(%r15), %r14
    movq  120(%r15), %r15

    movq  _g_guest_rsp(%rip), %rsp
    jmp   *_g_fn_ptr(%rip)

L_after_snippet:
    // Save guest rsp & r15 immediately without touching flags!
    movq  %rsp, _g_out_rsp(%rip)
    movq  %r15, _g_out_r15(%rip)
    movq  _g_host_rsp(%rip), %rsp
    pushfq
    cld
    movq  _g_ctx_ptr(%rip), %r15
    popq  0x180(%r15)

    // Store all GPRs
    movq  %rax,  0(%r15)
    movq  %rcx,  8(%r15)
    movq  %rdx,  16(%r15)
    movq  %rbx,  24(%r15)
    movq  _g_out_rsp(%rip), %rax
    movq  %rax,  32(%r15)
    movq  %rbp,  40(%r15)
    movq  %rsi,  48(%r15)
    movq  %rdi,  56(%r15)
    movq  %r8,   64(%r15)
    movq  %r9,   72(%r15)
    movq  %r10,  80(%r15)
    movq  %r11,  88(%r15)
    movq  %r12,  96(%r15)
    movq  %r13,  104(%r15)
    movq  %r14,  112(%r15)
    movq  _g_out_r15(%rip), %rax
    movq  %rax,  120(%r15)

    // Store XMM0..XMM15
    movdqa %xmm0,  0x80(%r15)
    movdqa %xmm1,  0x90(%r15)
    movdqa %xmm2,  0xa0(%r15)
    movdqa %xmm3,  0xb0(%r15)
    movdqa %xmm4,  0xc0(%r15)
    movdqa %xmm5,  0xd0(%r15)
    movdqa %xmm6,  0xe0(%r15)
    movdqa %xmm7,  0xf0(%r15)
    movdqa %xmm8,  0x100(%r15)
    movdqa %xmm9,  0x110(%r15)
    movdqa %xmm10, 0x120(%r15)
    movdqa %xmm11, 0x130(%r15)
    movdqa %xmm12, 0x140(%r15)
    movdqa %xmm13, 0x150(%r15)
    movdqa %xmm14, 0x160(%r15)
    movdqa %xmm15, 0x170(%r15)

    // Restore host callee-saved regs
    popq  %r15
    popq  %r14
    popq  %r13
    popq  %r12
    popq  %rbx
    popq  %rbp
    ret

.data
.p2align 3
_g_host_rsp:  .quad 0
_g_ctx_ptr:   .quad 0
_g_fn_ptr:    .quad 0
_g_guest_rsp: .quad 0
_g_out_rsp:   .quad 0
_g_out_r15:   .quad 0

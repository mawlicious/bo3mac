// Native ARM64 per-thread exact-key side-table setjmp/longjmp for Superset-SysV HVA lifted code.
// x86_64 jmp_buf is 148 bytes vs ARM64 192 bytes, so we NEVER write native state into guest jmp_buf;
// instead we look up a per-thread 64-entry exact-key slot via _bo3_jmpbuf_slot(guest_jmpbuf_ptr, create)
// and save/restore the lifted caller's ARM64 callee-saved registers (x19..x28, x29, x30, sp, d8..d15)
// plus guest rsp (x1). Returns GuestRet in v0 (rax = 0 on setjmp, val?val:1 on longjmp).

.text
.p2align 4
.globl _shim__setjmp
.globl _shim___setjmp
_shim__setjmp:
_shim___setjmp:
    // x0 = ctx, x1 = guest_rsp, x2 = guest_jmpbuf_ptr
    // Save caller's original x29/x30/x1/x2 on stack briefly while calling _bo3_jmpbuf_slot
    stp  x29, x30, [sp, #-32]!
    stp  x1,  x2,  [sp, #16]
    mov  x0, x2
    mov  w1, #1
    bl   _bo3_jmpbuf_slot
    mov  x9, x0            // x9 = Bo3JmpSlot*
    ldp  x1,  x2,  [sp, #16]
    ldp  x29, x30, [sp], #32 // restore original caller sp, x29, x30 BEFORE saving!

    str  x2,  [x9, #0]    // key = guest_jmpbuf_ptr
    str  x1,  [x9, #8]    // saved guest_rsp
    stp  x19, x20, [x9, #16]
    stp  x21, x22, [x9, #32]
    stp  x23, x24, [x9, #48]
    stp  x25, x26, [x9, #64]
    stp  x27, x28, [x9, #80]
    stp  x29, x30, [x9, #96]
    mov  x11, sp
    str  x11, [x9, #112]
    stp  d8,  d9,  [x9, #128]
    stp  d10, d11, [x9, #144]
    stp  d12, d13, [x9, #160]
    stp  d14, d15, [x9, #176]

    // Return GuestRet { {0, 0}, {0, 0}, {0, 0} } in v0, v1, v2
    movi v0.2d, #0
    movi v1.2d, #0
    movi v2.2d, #0
    ret

.p2align 4
.globl _shim__longjmp
.globl _shim___longjmp
_shim__longjmp:
_shim___longjmp:
    // x0 = ctx, x1 = guest_rsp, x2 = guest_jmpbuf_ptr, x3 = val (int)
    stp  x29, x30, [sp, #-32]!
    str  x3, [sp, #16]
    mov  x0, x2
    mov  w1, #0
    bl   _bo3_jmpbuf_slot
    mov  x9, x0            // x9 = Bo3JmpSlot*
    ldr  x3, [sp, #16]
    add  sp, sp, #32       // (will overwrite sp below anyway)

    // Return value: (int)x3 == 0 ? 1 : (int)x3
    sxtw x12, w3
    cmp  w3, #0
    csinc x12, x12, xzr, ne

    ldp  x19, x20, [x9, #16]
    ldp  x21, x22, [x9, #32]
    ldp  x23, x24, [x9, #48]
    ldp  x25, x26, [x9, #64]
    ldp  x27, x28, [x9, #80]
    ldp  x29, x30, [x9, #96]
    ldr  x11, [x9, #112]
    mov  sp, x11
    ldp  d8,  d9,  [x9, #128]
    ldp  d10, d11, [x9, #144]
    ldp  d12, d13, [x9, #160]
    ldp  d14, d15, [x9, #176]

    // Return GuestRet { {val, 0}, {0, 0}, {0, 0} } in v0, v1, v2
    movi v0.2d, #0
    fmov d0, x12
    movi v1.2d, #0
    movi v2.2d, #0
    ret

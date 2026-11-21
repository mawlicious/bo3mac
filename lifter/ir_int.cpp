#include "ir_emitter.h"
#include <algorithm>

namespace bo3 {

static int op_width(const DecodedInsn &di, int idx = 0) {
    if (idx < di.ins.operand_count && di.ops[idx].size > 0) {
        return di.ops[idx].size;
    }
    return di.ins.operand_width ? di.ins.operand_width : 64;
}

bool IREmitter::lift_int_insn(const DecodedInsn &di, const FunctionCFG &cfg, bool &terminated) {
    const ZydisMnemonic mn = di.ins.mnemonic;
    const uint32_t live = di.live_flags_out;
    const bool has_lock = (di.ins.attributes & ZYDIS_ATTRIB_HAS_LOCK) != 0;

    // Disambiguate string ops (movsd/cmpsd) from SSE2 ops
    if (di.ins.meta.category == ZYDIS_CATEGORY_STRINGOP) {
        int stride = 1;
        bool is_movs = false, is_stos = false, is_cmps = false, is_scas = false;
        switch (mn) {
            case ZYDIS_MNEMONIC_MOVSB: is_movs = true; stride = 1; break;
            case ZYDIS_MNEMONIC_MOVSW: is_movs = true; stride = 2; break;
            case ZYDIS_MNEMONIC_MOVSD: is_movs = true; stride = 4; break;
            case ZYDIS_MNEMONIC_MOVSQ: is_movs = true; stride = 8; break;
            case ZYDIS_MNEMONIC_STOSB: is_stos = true; stride = 1; break;
            case ZYDIS_MNEMONIC_STOSW: is_stos = true; stride = 2; break;
            case ZYDIS_MNEMONIC_STOSD: is_stos = true; stride = 4; break;
            case ZYDIS_MNEMONIC_STOSQ: is_stos = true; stride = 8; break;
            case ZYDIS_MNEMONIC_CMPSB: is_cmps = true; stride = 1; break;
            case ZYDIS_MNEMONIC_CMPSW: is_cmps = true; stride = 2; break;
            case ZYDIS_MNEMONIC_CMPSD: is_cmps = true; stride = 4; break;
            case ZYDIS_MNEMONIC_CMPSQ: is_cmps = true; stride = 8; break;
            case ZYDIS_MNEMONIC_SCASB: is_scas = true; stride = 1; break;
            case ZYDIS_MNEMONIC_SCASW: is_scas = true; stride = 2; break;
            case ZYDIS_MNEMONIC_SCASD: is_scas = true; stride = 4; break;
            case ZYDIS_MNEMONIC_SCASQ: is_scas = true; stride = 8; break;
            default: return false;
        }
        int bits = stride * 8;
        bool has_rep = (di.ins.attributes & (ZYDIS_ATTRIB_HAS_REP | ZYDIS_ATTRIB_HAS_REPE | ZYDIS_ATTRIB_HAS_REPNE)) != 0;
        bool rep_z = (di.ins.attributes & ZYDIS_ATTRIB_HAS_REPE) != 0;
        bool rep_nz = (di.ins.attributes & ZYDIS_ATTRIB_HAS_REPNE) != 0;

        std::string df = load_flag("df");
        std::string step = tmp();
        out_ << "  " << step << " = select i1 " << df << ", i64 -" << stride << ", i64 " << stride << "\n";

        if (has_rep) {
            std::string lid = std::to_string(next_id_++);
            out_ << "  br label %rep_hdr_" << lid << "\n";
            out_ << "rep_hdr_" << lid << ":\n";
            std::string cnt = load_gpr64(1);
            std::string done = tmp();
            out_ << "  " << done << " = icmp eq i64 " << cnt << ", 0\n";
            out_ << "  br i1 " << done << ", label %rep_end_" << lid << ", label %rep_body_" << lid << "\n";
            out_ << "rep_body_" << lid << ":\n";

            if (is_movs) {
                std::string si = load_gpr64(6), di_r = load_gpr64(7);
                std::string v = emit_mem_load(si, bits, false, false, false);
                emit_mem_store(di_r, bits, v, false, false);
                std::string nsi = tmp(), ndi = tmp();
                out_ << "  " << nsi << " = add i64 " << si << ", " << step << "\n";
                out_ << "  " << ndi << " = add i64 " << di_r << ", " << step << "\n";
                store_gpr64(6, nsi);
                store_gpr64(7, ndi);
            } else if (is_stos) {
                std::string di_r = load_gpr64(7);
                std::string av = read_reg(bits == 8 ? ZYDIS_REGISTER_AL : bits == 16 ? ZYDIS_REGISTER_AX :
                                          bits == 32 ? ZYDIS_REGISTER_EAX : ZYDIS_REGISTER_RAX, bits);
                emit_mem_store(di_r, bits, av, false, false);
                std::string ndi = tmp();
                out_ << "  " << ndi << " = add i64 " << di_r << ", " << step << "\n";
                store_gpr64(7, ndi);
            } else if (is_cmps || is_scas) {
                std::string di_r = load_gpr64(7);
                std::string a, b;
                if (is_cmps) {
                    std::string si = load_gpr64(6);
                    a = emit_mem_load(si, bits, false, false, false);
                    b = emit_mem_load(di_r, bits, false, false, false);
                    std::string nsi = tmp();
                    out_ << "  " << nsi << " = add i64 " << si << ", " << step << "\n";
                    store_gpr64(6, nsi);
                } else {
                    a = read_reg(bits == 8 ? ZYDIS_REGISTER_AL : bits == 16 ? ZYDIS_REGISTER_AX :
                                 bits == 32 ? ZYDIS_REGISTER_EAX : ZYDIS_REGISTER_RAX, bits);
                    b = emit_mem_load(di_r, bits, false, false, false);
                }
                std::string ndi = tmp();
                out_ << "  " << ndi << " = add i64 " << di_r << ", " << step << "\n";
                store_gpr64(7, ndi);
                std::string diff = tmp();
                out_ << "  " << diff << " = sub " << int_ty(bits) << " " << a << ", " << b << "\n";
                emit_sub_flags(a, b, diff, bits, live | FL_ZF);
            }

            std::string ncnt = tmp();
            out_ << "  " << ncnt << " = sub i64 " << cnt << ", 1\n";
            store_gpr64(1, ncnt);

            if ((is_cmps || is_scas) && (rep_z || rep_nz)) {
                std::string zf = load_flag("zf");
                std::string cont = zf;
                if (rep_nz) {
                    cont = tmp();
                    out_ << "  " << cont << " = xor i1 " << zf << ", true\n";
                }
                out_ << "  br i1 " << cont << ", label %rep_hdr_" << lid << ", label %rep_end_" << lid << "\n";
            } else {
                out_ << "  br label %rep_hdr_" << lid << "\n";
            }
            out_ << "rep_end_" << lid << ":\n";
        } else {
            if (is_movs) {
                std::string si = load_gpr64(6), di_r = load_gpr64(7);
                std::string v = emit_mem_load(si, bits, false, false, false);
                emit_mem_store(di_r, bits, v, false, false);
                std::string nsi = tmp(), ndi = tmp();
                out_ << "  " << nsi << " = add i64 " << si << ", " << step << "\n";
                out_ << "  " << ndi << " = add i64 " << di_r << ", " << step << "\n";
                store_gpr64(6, nsi); store_gpr64(7, ndi);
            } else if (is_stos) {
                std::string di_r = load_gpr64(7);
                std::string av = read_reg(bits == 8 ? ZYDIS_REGISTER_AL : bits == 16 ? ZYDIS_REGISTER_AX :
                                          bits == 32 ? ZYDIS_REGISTER_EAX : ZYDIS_REGISTER_RAX, bits);
                emit_mem_store(di_r, bits, av, false, false);
                std::string ndi = tmp();
                out_ << "  " << ndi << " = add i64 " << di_r << ", " << step << "\n";
                store_gpr64(7, ndi);
            } else if (is_cmps || is_scas) {
                std::string di_r = load_gpr64(7);
                std::string a, b;
                if (is_cmps) {
                    std::string si = load_gpr64(6);
                    a = emit_mem_load(si, bits, false, false, false);
                    b = emit_mem_load(di_r, bits, false, false, false);
                    std::string nsi = tmp();
                    out_ << "  " << nsi << " = add i64 " << si << ", " << step << "\n";
                    store_gpr64(6, nsi);
                } else {
                    a = read_reg(bits == 8 ? ZYDIS_REGISTER_AL : bits == 16 ? ZYDIS_REGISTER_AX :
                                 bits == 32 ? ZYDIS_REGISTER_EAX : ZYDIS_REGISTER_RAX, bits);
                    b = emit_mem_load(di_r, bits, false, false, false);
                }
                std::string ndi = tmp();
                out_ << "  " << ndi << " = add i64 " << di_r << ", " << step << "\n";
                store_gpr64(7, ndi);
                std::string diff = tmp();
                out_ << "  " << diff << " = sub " << int_ty(bits) << " " << a << ", " << b << "\n";
                emit_sub_flags(a, b, diff, bits, live);
            }
        }
        return true;
    }

    // Helper for binary ALU (with optional LOCK atomicrmw)
    auto emit_lock_rmw = [&](const char *rmw_op, int bits, const std::string &rhs) -> std::string {
        bool is_stack = false, is_ro = false;
        std::string ea = calc_mem_addr(di, di.ops[0], is_stack, is_ro);
        std::string p = tmp(), old = tmp();
        out_ << "  " << p << " = inttoptr i64 " << ea << " to ptr\n";
        out_ << "  " << old << " = atomicrmw " << rmw_op << " ptr " << p << ", " << int_ty(bits)
             << " " << rhs << " seq_cst, align " << (bits / 8) << "\n";
        return old;
    };

    switch (mn) {
    // ---- NOP / Hints / Barriers / System ----
    case ZYDIS_MNEMONIC_NOP:
    case ZYDIS_MNEMONIC_PREFETCHT0:
    case ZYDIS_MNEMONIC_PREFETCHT1:
    case ZYDIS_MNEMONIC_PREFETCHT2:
    case ZYDIS_MNEMONIC_PREFETCHNTA:
    case ZYDIS_MNEMONIC_PREFETCHW:
    case ZYDIS_MNEMONIC_ENDBR64:
        return true;

    case ZYDIS_MNEMONIC_PAUSE:
        need_intrinsic("declare void @llvm.aarch64.hint(i32)");
        out_ << "  call void @llvm.aarch64.hint(i32 1)\n";
        return true;

    case ZYDIS_MNEMONIC_MFENCE:
        out_ << "  fence seq_cst\n";
        return true;
    case ZYDIS_MNEMONIC_SFENCE:
        out_ << "  fence release\n";
        return true;
    case ZYDIS_MNEMONIC_LFENCE:
        out_ << "  fence acquire\n";
        return true;

    case ZYDIS_MNEMONIC_CLD: store_flag("df", "false"); return true;
    case ZYDIS_MNEMONIC_STD: store_flag("df", "true");  return true;
    case ZYDIS_MNEMONIC_CLC: store_flag("cf", "false"); return true;
    case ZYDIS_MNEMONIC_STC: store_flag("cf", "true");  return true;
    case ZYDIS_MNEMONIC_CMC: {
        std::string cf = load_flag("cf"), n = tmp();
        out_ << "  " << n << " = xor i1 " << cf << ", true\n";
        store_flag("cf", n);
        return true;
    }

    case ZYDIS_MNEMONIC_UD2:
    case ZYDIS_MNEMONIC_INT3:
    case ZYDIS_MNEMONIC_HLT:
    case ZYDIS_MNEMONIC_OUT:
    case ZYDIS_MNEMONIC_STI:
    case ZYDIS_MNEMONIC_CLI:
        out_ << "  call void @bo3_trap(i64 " << di.va << ", i64 3, ptr %ctx)\n";
        out_ << "  unreachable\n";
        terminated = true;
        return true;

    case ZYDIS_MNEMONIC_CPUID: {
        std::string eax_in = read_reg(ZYDIS_REGISTER_EAX, 32);
        std::string ecx_in = read_reg(ZYDIS_REGISTER_ECX, 32);
        out_ << "  call void @bo3_cpuid(i32 " << eax_in << ", i32 " << ecx_in
             << ", ptr %cpuid_a, ptr %cpuid_b, ptr %cpuid_c, ptr %cpuid_d)\n";
        std::string va = tmp(), vb = tmp(), vc = tmp(), vd = tmp();
        out_ << "  " << va << " = load i32, ptr %cpuid_a\n";
        out_ << "  " << vb << " = load i32, ptr %cpuid_b\n";
        out_ << "  " << vc << " = load i32, ptr %cpuid_c\n";
        out_ << "  " << vd << " = load i32, ptr %cpuid_d\n";
        write_reg(ZYDIS_REGISTER_EAX, 32, va);
        write_reg(ZYDIS_REGISTER_EBX, 32, vb);
        write_reg(ZYDIS_REGISTER_ECX, 32, vc);
        write_reg(ZYDIS_REGISTER_EDX, 32, vd);
        return true;
    }

    case ZYDIS_MNEMONIC_RDTSC: {
        std::string t = tmp(), lo = tmp(), sh = tmp(), hi = tmp();
        out_ << "  " << t << " = call i64 @bo3_rdtsc()\n";
        out_ << "  " << lo << " = trunc i64 " << t << " to i32\n";
        out_ << "  " << sh << " = lshr i64 " << t << ", 32\n";
        out_ << "  " << hi << " = trunc i64 " << sh << " to i32\n";
        write_reg(ZYDIS_REGISTER_EAX, 32, lo);
        write_reg(ZYDIS_REGISTER_EDX, 32, hi);
        return true;
    }

    case ZYDIS_MNEMONIC_XGETBV: {
        // Report XCR0 = 0x3 (x87 + SSE only, no AVX) so runtime feature checks pick SSE4.2
        write_reg(ZYDIS_REGISTER_EAX, 32, "3");
        write_reg(ZYDIS_REGISTER_EDX, 32, "0");
        return true;
    }

    // ---- Data Movement ----
    case ZYDIS_MNEMONIC_MOV: {
        int bits = op_width(di, 0);
        std::string val = read_op(di, 1, bits);
        write_op(di, 0, bits, val);
        return true;
    }

    case ZYDIS_MNEMONIC_MOVZX: {
        int db = op_width(di, 0), sb = op_width(di, 1);
        std::string src = read_op(di, 1, sb);
        std::string res = src;
        if (db > sb) {
            res = tmp();
            out_ << "  " << res << " = zext " << int_ty(sb) << " " << src << " to " << int_ty(db) << "\n";
        }
        write_op(di, 0, db, res);
        return true;
    }

    case ZYDIS_MNEMONIC_MOVSX:
    case ZYDIS_MNEMONIC_MOVSXD: {
        int db = op_width(di, 0), sb = op_width(di, 1);
        std::string src = read_op(di, 1, sb);
        std::string res = src;
        if (db > sb) {
            res = tmp();
            out_ << "  " << res << " = sext " << int_ty(sb) << " " << src << " to " << int_ty(db) << "\n";
        }
        write_op(di, 0, db, res);
        return true;
    }

    case ZYDIS_MNEMONIC_LEA: {
        int db = op_width(di, 0);
        bool is_stack = false, is_ro = false;
        std::string ea = calc_mem_addr(di, di.ops[1], is_stack, is_ro);
        std::string val = ea;
        if (db < 64) {
            val = tmp();
            out_ << "  " << val << " = trunc i64 " << ea << " to " << int_ty(db) << "\n";
        }
        write_op(di, 0, db, val);
        return true;
    }

    case ZYDIS_MNEMONIC_PUSH: {
        int bits = op_width(di, 0);
        // An explicit memory source uses the original RSP and normal TSO classification.
        std::string v = read_op(di, 0, bits);
        if (bits < 64) {
            std::string s = tmp();
            out_ << "  " << s << " = sext " << int_ty(bits) << " " << v << " to i64\n";
            v = s;
        }
        emit_push64(v);
        return true;
    }

    case ZYDIS_MNEMONIC_POP: {
        int bits = op_width(di, 0);
        std::string v = emit_pop64();
        if (bits < 64) {
            std::string t = tmp();
            out_ << "  " << t << " = trunc i64 " << v << " to " << int_ty(bits) << "\n";
            v = t;
        }
        // An explicit memory destination uses the updated RSP and normal TSO classification.
        write_op(di, 0, bits, v);
        return true;
    }

    case ZYDIS_MNEMONIC_LEAVE: {
        std::string bp = load_gpr64(5);
        store_gpr64(4, bp);
        std::string nbp = emit_pop64(/*require_fp=*/true);
        store_gpr64(5, nbp);
        return true;
    }

    case ZYDIS_MNEMONIC_CBW: {
        std::string al = read_reg(ZYDIS_REGISTER_AL, 8), ax = tmp();
        out_ << "  " << ax << " = sext i8 " << al << " to i16\n";
        write_reg(ZYDIS_REGISTER_AX, 16, ax);
        return true;
    }
    case ZYDIS_MNEMONIC_CWDE: {
        std::string ax = read_reg(ZYDIS_REGISTER_AX, 16), eax = tmp();
        out_ << "  " << eax << " = sext i16 " << ax << " to i32\n";
        write_reg(ZYDIS_REGISTER_EAX, 32, eax);
        return true;
    }
    case ZYDIS_MNEMONIC_CDQE: {
        std::string eax = read_reg(ZYDIS_REGISTER_EAX, 32), rax = tmp();
        out_ << "  " << rax << " = sext i32 " << eax << " to i64\n";
        write_reg(ZYDIS_REGISTER_RAX, 64, rax);
        return true;
    }
    case ZYDIS_MNEMONIC_CWD: {
        std::string ax = read_reg(ZYDIS_REGISTER_AX, 16), dx = tmp();
        out_ << "  " << dx << " = ashr i16 " << ax << ", 15\n";
        write_reg(ZYDIS_REGISTER_DX, 16, dx);
        return true;
    }
    case ZYDIS_MNEMONIC_CDQ: {
        std::string eax = read_reg(ZYDIS_REGISTER_EAX, 32), edx = tmp();
        out_ << "  " << edx << " = ashr i32 " << eax << ", 31\n";
        write_reg(ZYDIS_REGISTER_EDX, 32, edx);
        return true;
    }
    case ZYDIS_MNEMONIC_CQO: {
        std::string rax = load_gpr64(0), rdx = tmp();
        out_ << "  " << rdx << " = ashr i64 " << rax << ", 63\n";
        store_gpr64(2, rdx);
        return true;
    }

    case ZYDIS_MNEMONIC_BSWAP: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        need_intrinsic("declare " + ty + " @llvm.bswap." + ty + "(" + ty + ")");
        std::string a = read_op(di, 0, bits), r = tmp();
        out_ << "  " << r << " = call " << ty << " @llvm.bswap." << ty << "(" << ty << " " << a << ")\n";
        write_op(di, 0, bits, r);
        return true;
    }

    case ZYDIS_MNEMONIC_XCHG: {
        int bits = op_width(di, 0);
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY || di.ops[1].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            int mem_i = (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) ? 0 : 1;
            int reg_i = 1 - mem_i;
            bool is_stack = false, is_ro = false;
            std::string ea = calc_mem_addr(di, di.ops[mem_i], is_stack, is_ro);
            std::string rv = read_op(di, reg_i, bits);
            std::string p = tmp(), old = tmp();
            out_ << "  " << p << " = inttoptr i64 " << ea << " to ptr\n";
            out_ << "  " << old << " = atomicrmw xchg ptr " << p << ", " << int_ty(bits)
                 << " " << rv << " seq_cst, align " << (bits / 8) << "\n";
            write_op(di, reg_i, bits, old);
        } else {
            std::string a = read_op(di, 0, bits);
            std::string b = read_op(di, 1, bits);
            write_op(di, 0, bits, b);
            write_op(di, 1, bits, a);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_XADD: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string b = read_op(di, 1, bits);
        std::string a, res = tmp();
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            if (has_lock) {
                a = emit_lock_rmw("add", bits, b);
                out_ << "  " << res << " = add " << ty << " " << a << ", " << b << "\n";
                write_op(di, 1, bits, a);
            } else {
                bool is_stack = false, is_ro = false;
                std::string ea = calc_mem_addr(di, di.ops[0], is_stack, is_ro, bits / 8);
                a = emit_mem_load(ea, bits, is_stack, is_ro, false);
                out_ << "  " << res << " = add " << ty << " " << a << ", " << b << "\n";
                write_op(di, 1, bits, a);
                emit_mem_store(ea, bits, res, is_stack, false);
            }
        } else {
            // Alias-safe order: write old value to op1 FIRST, sum to op0 SECOND (so xadd eax, eax doubles eax!)
            a = read_op(di, 0, bits);
            out_ << "  " << res << " = add " << ty << " " << a << ", " << b << "\n";
            write_op(di, 1, bits, a);
            write_op(di, 0, bits, res);
        }
        emit_add_flags(a, b, res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_CMPXCHG: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        ZydisRegister acc_reg = (bits == 8) ? ZYDIS_REGISTER_AL : (bits == 16) ? ZYDIS_REGISTER_AX :
                                (bits == 32) ? ZYDIS_REGISTER_EAX : ZYDIS_REGISTER_RAX;
        std::string acc = read_reg(acc_reg, bits);
        std::string src = read_op(di, 1, bits);

        if (has_lock && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            bool is_stack = false, is_ro = false;
            std::string ea = calc_mem_addr(di, di.ops[0], is_stack, is_ro, bits / 8);
            std::string p = tmp(), cx = tmp(), old = tmp(), ok = tmp();
            out_ << "  " << p << " = inttoptr i64 " << ea << " to ptr\n";
            out_ << "  " << cx << " = cmpxchg ptr " << p << ", " << ty << " " << acc
                 << ", " << ty << " " << src << " seq_cst seq_cst, align " << (bits / 8) << "\n";
            out_ << "  " << old << " = extractvalue { " << ty << ", i1 } " << cx << ", 0\n";
            out_ << "  " << ok  << " = extractvalue { " << ty << ", i1 } " << cx << ", 1\n";
            std::string lid = std::to_string(next_id_++);
            out_ << "  br i1 " << ok << ", label %cx_eq_" << lid << ", label %cx_ne_" << lid << "\n";
            out_ << "cx_ne_" << lid << ":\n";
            write_reg(acc_reg, bits, old);
            out_ << "  br label %cx_done_" << lid << "\n";
            out_ << "cx_eq_" << lid << ":\n";
            // On x86_64, 32-bit CMPXCHG leaves RAX upper 32 bits zeroed on both hit and miss
            if (bits == 32) write_reg(acc_reg, 32, acc);
            out_ << "  br label %cx_done_" << lid << "\n";
            out_ << "cx_done_" << lid << ":\n";
            std::string diff = tmp();
            out_ << "  " << diff << " = sub " << ty << " " << acc << ", " << old << "\n";
            emit_sub_flags(acc, old, diff, bits, live);
        } else {
            bool is_stack = false, is_ro = false;
            std::string ea;
            std::string old;
            if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
                ea = calc_mem_addr(di, di.ops[0], is_stack, is_ro, bits / 8);
                old = emit_mem_load(ea, bits, is_stack, is_ro, false);
            } else {
                old = read_op(di, 0, bits);
            }
            std::string eq = tmp(), diff = tmp();
            out_ << "  " << eq << " = icmp eq " << ty << " " << acc << ", " << old << "\n";
            out_ << "  " << diff << " = sub " << ty << " " << acc << ", " << old << "\n";
            std::string lid = std::to_string(next_id_++);
            out_ << "  br i1 " << eq << ", label %cx_eq_" << lid << ", label %cx_ne_" << lid << "\n";
            out_ << "cx_eq_" << lid << ":\n";
            if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) emit_mem_store(ea, bits, src, is_stack, false);
            else write_op(di, 0, bits, src);
            if (bits == 32) write_reg(acc_reg, 32, acc);
            out_ << "  br label %cx_done_" << lid << "\n";
            out_ << "cx_ne_" << lid << ":\n";
            if (di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER && bits == 32) write_op(di, 0, 32, old);
            write_reg(acc_reg, bits, old);
            out_ << "  br label %cx_done_" << lid << "\n";
            out_ << "cx_done_" << lid << ":\n";
            emit_sub_flags(acc, old, diff, bits, live);
        }
        return true;
    }

    // ---- Basic Arithmetic & Logic ----
    case ZYDIS_MNEMONIC_ADD: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string b = read_op(di, 1, bits);
        std::string a, res = tmp();
        if (has_lock && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            a = emit_lock_rmw("add", bits, b);
            out_ << "  " << res << " = add " << ty << " " << a << ", " << b << "\n";
        } else {
            a = read_op(di, 0, bits);
            out_ << "  " << res << " = add " << ty << " " << a << ", " << b << "\n";
            write_op(di, 0, bits, res);
        }
        emit_add_flags(a, b, res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_SUB: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string b = read_op(di, 1, bits);
        std::string a, res = tmp();
        if (has_lock && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            a = emit_lock_rmw("sub", bits, b);
            out_ << "  " << res << " = sub " << ty << " " << a << ", " << b << "\n";
        } else {
            a = read_op(di, 0, bits);
            out_ << "  " << res << " = sub " << ty << " " << a << ", " << b << "\n";
            write_op(di, 0, bits, res);
        }
        emit_sub_flags(a, b, res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_ADC: {
        if (has_lock) { out_ << "  call void @bo3_trap(i64 " << di.va << ", i64 6, ptr %ctx)\n  unreachable\n"; terminated = true; return true; }
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string a = read_op(di, 0, bits);
        std::string b = read_op(di, 1, bits);
        std::string cf = load_flag("cf");
        std::string cext = tmp(), s1 = tmp(), res = tmp();
        out_ << "  " << cext << " = zext i1 " << cf << " to " << ty << "\n";
        out_ << "  " << s1 << " = add " << ty << " " << a << ", " << b << "\n";
        out_ << "  " << res << " = add " << ty << " " << s1 << ", " << cext << "\n";
        write_op(di, 0, bits, res);
        emit_adc_flags(a, b, cf, res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_SBB: {
        if (has_lock) { out_ << "  call void @bo3_trap(i64 " << di.va << ", i64 6, ptr %ctx)\n  unreachable\n"; terminated = true; return true; }
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string a = read_op(di, 0, bits);
        std::string b = read_op(di, 1, bits);
        std::string cf = load_flag("cf");
        std::string cext = tmp(), s1 = tmp(), res = tmp();
        out_ << "  " << cext << " = zext i1 " << cf << " to " << ty << "\n";
        out_ << "  " << s1 << " = sub " << ty << " " << a << ", " << b << "\n";
        out_ << "  " << res << " = sub " << ty << " " << s1 << ", " << cext << "\n";
        write_op(di, 0, bits, res);
        emit_sbb_flags(a, b, cf, res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_INC: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string a, res = tmp();
        if (has_lock && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            a = emit_lock_rmw("add", bits, "1");
            out_ << "  " << res << " = add " << ty << " " << a << ", 1\n";
        } else {
            a = read_op(di, 0, bits);
            out_ << "  " << res << " = add " << ty << " " << a << ", 1\n";
            write_op(di, 0, bits, res);
        }
        emit_add_flags(a, "1", res, bits, live & ~FL_CF); // INC preserves CF!
        return true;
    }

    case ZYDIS_MNEMONIC_DEC: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string a, res = tmp();
        if (has_lock && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            a = emit_lock_rmw("sub", bits, "1");
            out_ << "  " << res << " = sub " << ty << " " << a << ", 1\n";
        } else {
            a = read_op(di, 0, bits);
            out_ << "  " << res << " = sub " << ty << " " << a << ", 1\n";
            write_op(di, 0, bits, res);
        }
        emit_sub_flags(a, "1", res, bits, live & ~FL_CF); // DEC preserves CF!
        return true;
    }

    case ZYDIS_MNEMONIC_NEG: {
        if (has_lock) { out_ << "  call void @bo3_trap(i64 " << di.va << ", i64 6, ptr %ctx)\n  unreachable\n"; terminated = true; return true; }
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string a = read_op(di, 0, bits), res = tmp();
        out_ << "  " << res << " = sub " << ty << " 0, " << a << "\n";
        write_op(di, 0, bits, res);
        emit_sub_flags("0", a, res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_NOT: {
        if (has_lock) { out_ << "  call void @bo3_trap(i64 " << di.va << ", i64 6, ptr %ctx)\n  unreachable\n"; terminated = true; return true; }
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string a = read_op(di, 0, bits), res = tmp();
        out_ << "  " << res << " = xor " << ty << " " << a << ", -1\n";
        write_op(di, 0, bits, res);
        return true; // NOT modifies no flags
    }

    case ZYDIS_MNEMONIC_AND: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string b = read_op(di, 1, bits);
        std::string a, res = tmp();
        if (has_lock && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            a = emit_lock_rmw("and", bits, b);
            out_ << "  " << res << " = and " << ty << " " << a << ", " << b << "\n";
        } else {
            a = read_op(di, 0, bits);
            out_ << "  " << res << " = and " << ty << " " << a << ", " << b << "\n";
            write_op(di, 0, bits, res);
        }
        emit_logic_flags(res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_OR: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string b = read_op(di, 1, bits);
        std::string a, res = tmp();
        if (has_lock && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            a = emit_lock_rmw("or", bits, b);
            out_ << "  " << res << " = or " << ty << " " << a << ", " << b << "\n";
        } else {
            a = read_op(di, 0, bits);
            out_ << "  " << res << " = or " << ty << " " << a << ", " << b << "\n";
            write_op(di, 0, bits, res);
        }
        emit_logic_flags(res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_XOR: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        // Fast idiom: xor reg, reg -> 0 (still zero-extends 32-bit reg!)
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
            di.ops[1].type == ZYDIS_OPERAND_TYPE_REGISTER &&
            di.ops[0].reg.value == di.ops[1].reg.value) {
            write_op(di, 0, bits, "0");
            emit_logic_flags("0", bits, live);
            return true;
        }
        std::string b = read_op(di, 1, bits);
        std::string a, res = tmp();
        if (has_lock && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            a = emit_lock_rmw("xor", bits, b);
            out_ << "  " << res << " = xor " << ty << " " << a << ", " << b << "\n";
        } else {
            a = read_op(di, 0, bits);
            out_ << "  " << res << " = xor " << ty << " " << a << ", " << b << "\n";
            write_op(di, 0, bits, res);
        }
        emit_logic_flags(res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_CMP: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string a = read_op(di, 0, bits);
        std::string b = read_op(di, 1, bits);
        std::string res = tmp();
        out_ << "  " << res << " = sub " << ty << " " << a << ", " << b << "\n";
        emit_sub_flags(a, b, res, bits, live);
        return true;
    }

    case ZYDIS_MNEMONIC_TEST: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string a = read_op(di, 0, bits);
        std::string b = read_op(di, 1, bits);
        std::string res = tmp();
        out_ << "  " << res << " = and " << ty << " " << a << ", " << b << "\n";
        emit_logic_flags(res, bits, live);
        return true;
    }

    // ---- Multiply & Divide ----
    case ZYDIS_MNEMONIC_MUL: {
        int bits = op_width(di, 0);
        int wbits = bits * 2;
        std::string ty = int_ty(bits), wty = int_ty(wbits);
        ZydisRegister areg = (bits == 8) ? ZYDIS_REGISTER_AL : (bits == 16) ? ZYDIS_REGISTER_AX :
                             (bits == 32) ? ZYDIS_REGISTER_EAX : ZYDIS_REGISTER_RAX;
        std::string a = read_reg(areg, bits);
        std::string b = read_op(di, 0, bits);
        std::string za = tmp(), zb = tmp(), prod = tmp(), lo = tmp(), hi_sh = tmp(), hi = tmp();
        out_ << "  " << za << " = zext " << ty << " " << a << " to " << wty << "\n";
        out_ << "  " << zb << " = zext " << ty << " " << b << " to " << wty << "\n";
        out_ << "  " << prod << " = mul " << wty << " " << za << ", " << zb << "\n";
        out_ << "  " << lo << " = trunc " << wty << " " << prod << " to " << ty << "\n";
        out_ << "  " << hi_sh << " = lshr " << wty << " " << prod << ", " << bits << "\n";
        out_ << "  " << hi << " = trunc " << wty << " " << hi_sh << " to " << ty << "\n";
        if (bits == 8) {
            write_reg(ZYDIS_REGISTER_AX, 16, prod);
        } else {
            write_reg(areg, bits, lo);
            ZydisRegister dreg = (bits == 16) ? ZYDIS_REGISTER_DX : (bits == 32) ? ZYDIS_REGISTER_EDX : ZYDIS_REGISTER_RDX;
            write_reg(dreg, bits, hi);
        }
        if (live & (FL_CF | FL_OF)) {
            std::string ov = tmp();
            out_ << "  " << ov << " = icmp ne " << ty << " " << hi << ", 0\n";
            if (live & FL_CF) store_flag("cf", ov);
            if (live & FL_OF) store_flag("of", ov);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_IMUL: {
        int vis = di.ins.operand_count_visible;
        int bits = op_width(di, 0);
        int wbits = bits * 2;
        std::string ty = int_ty(bits), wty = int_ty(wbits);
        std::string a, b;
        if (vis == 1) {
            ZydisRegister areg = (bits == 8) ? ZYDIS_REGISTER_AL : (bits == 16) ? ZYDIS_REGISTER_AX :
                                 (bits == 32) ? ZYDIS_REGISTER_EAX : ZYDIS_REGISTER_RAX;
            a = read_reg(areg, bits);
            b = read_op(di, 0, bits);
        } else if (vis == 2) {
            a = read_op(di, 0, bits);
            b = read_op(di, 1, bits);
        } else {
            a = read_op(di, 1, bits);
            b = read_op(di, 2, bits);
        }
        std::string sa = tmp(), sb = tmp(), prod = tmp(), lo = tmp(), hi_sh = tmp(), hi = tmp();
        out_ << "  " << sa << " = sext " << ty << " " << a << " to " << wty << "\n";
        out_ << "  " << sb << " = sext " << ty << " " << b << " to " << wty << "\n";
        out_ << "  " << prod << " = mul " << wty << " " << sa << ", " << sb << "\n";
        out_ << "  " << lo << " = trunc " << wty << " " << prod << " to " << ty << "\n";
        if (vis == 1) {
            out_ << "  " << hi_sh << " = lshr " << wty << " " << prod << ", " << bits << "\n";
            out_ << "  " << hi << " = trunc " << wty << " " << hi_sh << " to " << ty << "\n";
            if (bits == 8) {
                write_reg(ZYDIS_REGISTER_AX, 16, prod);
            } else {
                ZydisRegister areg = (bits == 16) ? ZYDIS_REGISTER_AX : (bits == 32) ? ZYDIS_REGISTER_EAX : ZYDIS_REGISTER_RAX;
                ZydisRegister dreg = (bits == 16) ? ZYDIS_REGISTER_DX : (bits == 32) ? ZYDIS_REGISTER_EDX : ZYDIS_REGISTER_RDX;
                write_reg(areg, bits, lo);
                write_reg(dreg, bits, hi);
            }
        } else {
            write_op(di, 0, bits, lo);
        }
        if (live & (FL_CF | FL_OF)) {
            std::string slo = tmp(), ov = tmp();
            out_ << "  " << slo << " = sext " << ty << " " << lo << " to " << wty << "\n";
            out_ << "  " << ov << " = icmp ne " << wty << " " << prod << ", " << slo << "\n";
            if (live & FL_CF) store_flag("cf", ov);
            if (live & FL_OF) store_flag("of", ov);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_DIV:
    case ZYDIS_MNEMONIC_IDIV: {
        bool is_signed = (mn == ZYDIS_MNEMONIC_IDIV);
        int bits = op_width(di, 0);
        int wbits = bits * 2;
        std::string ty = int_ty(bits), wty = int_ty(wbits);
        std::string den_raw = read_op(di, 0, bits);

        // Guard #DE divide-by-zero cleanly
        std::string dz = tmp(), lid = std::to_string(next_id_++);
        out_ << "  " << dz << " = icmp eq " << ty << " " << den_raw << ", 0\n";
        out_ << "  br i1 " << dz << ", label %div_trap_" << lid << ", label %div_ok_" << lid << "\n";
        out_ << "div_trap_" << lid << ":\n";
        out_ << "  call void @bo3_trap(i64 " << di.va << ", i64 7, ptr %ctx)\n";
        out_ << "  unreachable\n";
        out_ << "div_ok_" << lid << ":\n";

        if (bits == 64) {
            // Fast path: 99% of 64-bit divisions have hi == 0 (div) or hi == sign(lo) (idiv),
            // compiling directly to native ARM64 udiv/sdiv without __divti3/__modti3!
            std::string lo = load_gpr64(0), hi = load_gpr64(2);
            std::string fast_cond = tmp();
            if (is_signed) {
                std::string sgn = tmp(), no_ov_lo = tmp(), no_ov_d = tmp(), not_ov = tmp(), hi_ok = tmp();
                out_ << "  " << sgn << " = ashr i64 " << lo << ", 63\n";
                out_ << "  " << hi_ok << " = icmp eq i64 " << hi << ", " << sgn << "\n";
                out_ << "  " << no_ov_lo << " = icmp ne i64 " << lo << ", -9223372036854775808\n";
                out_ << "  " << no_ov_d << " = icmp ne i64 " << den_raw << ", -1\n";
                out_ << "  " << not_ov << " = or i1 " << no_ov_lo << ", " << no_ov_d << "\n";
                out_ << "  " << fast_cond << " = and i1 " << hi_ok << ", " << not_ov << "\n";
            } else {
                out_ << "  " << fast_cond << " = icmp eq i64 " << hi << ", 0\n";
            }
            out_ << "  br i1 " << fast_cond << ", label %div_fast_" << lid << ", label %div_wide_" << lid << "\n";
            out_ << "div_fast_" << lid << ":\n";
            std::string fq = tmp(), fp = tmp(), fr = tmp();
            out_ << "  " << fq << " = " << (is_signed ? "sdiv " : "udiv ") << "i64 " << lo << ", " << den_raw << "\n";
            out_ << "  " << fp << " = mul i64 " << fq << ", " << den_raw << "\n";
            out_ << "  " << fr << " = sub i64 " << lo << ", " << fp << "\n";
            store_gpr64(0, fq);
            store_gpr64(2, fr);
            out_ << "  br label %div_done_" << lid << "\n";
            out_ << "div_wide_" << lid << ":\n";
            std::string zlo = tmp(), zhi = tmp(), sh = tmp(), num = tmp(), den = tmp();
            out_ << "  " << zlo << " = zext i64 " << lo << " to i128\n";
            out_ << "  " << zhi << " = zext i64 " << hi << " to i128\n";
            out_ << "  " << sh << " = shl i128 " << zhi << ", 64\n";
            out_ << "  " << num << " = or i128 " << sh << ", " << zlo << "\n";
            out_ << "  " << den << " = " << (is_signed ? "sext " : "zext ") << "i64 " << den_raw << " to i128\n";
            std::string wq = tmp(), wp = tmp(), wr = tmp(), qt = tmp(), rt = tmp();
            out_ << "  " << wq << " = " << (is_signed ? "sdiv " : "udiv ") << "i128 " << num << ", " << den << "\n";
            out_ << "  " << wp << " = mul i128 " << wq << ", " << den << "\n";
            out_ << "  " << wr << " = sub i128 " << num << ", " << wp << "\n";
            out_ << "  " << qt << " = trunc i128 " << wq << " to i64\n";
            out_ << "  " << rt << " = trunc i128 " << wr << " to i64\n";
            store_gpr64(0, qt);
            store_gpr64(2, rt);
            out_ << "  br label %div_done_" << lid << "\n";
            out_ << "div_done_" << lid << ":\n";
            return true;
        }

        std::string num;
        if (bits == 8) {
            num = read_reg(ZYDIS_REGISTER_AX, 16);
        } else {
            ZydisRegister areg = (bits == 16) ? ZYDIS_REGISTER_AX : ZYDIS_REGISTER_EAX;
            ZydisRegister dreg = (bits == 16) ? ZYDIS_REGISTER_DX : ZYDIS_REGISTER_EDX;
            std::string lo = read_reg(areg, bits), hi = read_reg(dreg, bits);
            std::string zlo = tmp(), zhi = tmp(), sh = tmp();
            num = tmp();
            out_ << "  " << zlo << " = zext " << ty << " " << lo << " to " << wty << "\n";
            out_ << "  " << zhi << " = zext " << ty << " " << hi << " to " << wty << "\n";
            out_ << "  " << sh << " = shl " << wty << " " << zhi << ", " << bits << "\n";
            out_ << "  " << num << " = or " << wty << " " << sh << ", " << zlo << "\n";
        }
        std::string den = tmp();
        out_ << "  " << den << " = " << (is_signed ? "sext " : "zext ") << ty << " " << den_raw << " to " << wty << "\n";
        std::string q = tmp(), p = tmp(), r = tmp(), qt = tmp(), rt = tmp();
        out_ << "  " << q << " = " << (is_signed ? "sdiv " : "udiv ") << wty << " " << num << ", " << den << "\n";
        out_ << "  " << p << " = mul " << wty << " " << q << ", " << den << "\n";
        out_ << "  " << r << " = sub " << wty << " " << num << ", " << p << "\n";
        out_ << "  " << qt << " = trunc " << wty << " " << q << " to " << ty << "\n";
        out_ << "  " << rt << " = trunc " << wty << " " << r << " to " << ty << "\n";
        if (bits == 8) {
            write_reg(ZYDIS_REGISTER_AL, 8, qt);
            write_reg(ZYDIS_REGISTER_AH, 8, rt);
        } else {
            ZydisRegister areg = (bits == 16) ? ZYDIS_REGISTER_AX : ZYDIS_REGISTER_EAX;
            ZydisRegister dreg = (bits == 16) ? ZYDIS_REGISTER_DX : ZYDIS_REGISTER_EDX;
            write_reg(areg, bits, qt);
            write_reg(dreg, bits, rt);
        }
        return true;
    }

    // ---- Shifts & Rotates ----
    case ZYDIS_MNEMONIC_SHL:
    case ZYDIS_MNEMONIC_SHR:
    case ZYDIS_MNEMONIC_SAR: {
        int bits = op_width(di, 0);
        int wbits = std::max(bits, 32); // widen 8/16 to 32 so counts 0..31 never poison
        std::string ty = int_ty(bits), wty = int_ty(wbits);
        int mask = (bits == 64) ? 63 : 31;

        std::string a = read_op(di, 0, bits);
        std::string raw_c = read_op(di, 1, 8);
        std::string c_w = tmp(), c = tmp();
        out_ << "  " << c_w << " = zext i8 " << raw_c << " to " << wty << "\n";
        out_ << "  " << c << " = and " << wty << " " << c_w << ", " << mask << "\n";

        std::string aw = a;
        if (wbits > bits) {
            aw = tmp();
            out_ << "  " << aw << " = " << (mn == ZYDIS_MNEMONIC_SAR ? "sext " : "zext ")
                 << ty << " " << a << " to " << wty << "\n";
        }

        std::string res_w = tmp();
        const char *opname = (mn == ZYDIS_MNEMONIC_SHL) ? "shl" : (mn == ZYDIS_MNEMONIC_SHR) ? "lshr" : "ashr";
        out_ << "  " << res_w << " = " << opname << " " << wty << " " << aw << ", " << c << "\n";

        std::string res = res_w;
        if (wbits > bits) {
            res = tmp();
            out_ << "  " << res << " = trunc " << wty << " " << res_w << " to " << ty << "\n";
        }
        write_op(di, 0, bits, res);

        if (live & FL_ALL6) {
            std::string is_zero = tmp();
            out_ << "  " << is_zero << " = icmp eq " << wty << " " << c << ", 0\n";

            auto cond_store = [&](const char *fl_name, const std::string &new_v) {
                std::string old_v = load_flag(fl_name), sel = tmp();
                out_ << "  " << sel << " = select i1 " << is_zero << ", i1 " << old_v << ", i1 " << new_v << "\n";
                store_flag(fl_name, sel);
            };

            if (live & FL_ZF) {
                std::string z = tmp();
                out_ << "  " << z << " = icmp eq " << ty << " " << res << ", 0\n";
                cond_store("zf", z);
            }
            if (live & FL_SF) {
                std::string s = tmp();
                out_ << "  " << s << " = icmp slt " << ty << " " << res << ", 0\n";
                cond_store("sf", s);
            }
            if (live & FL_PF) {
                need_intrinsic("declare i8 @llvm.ctpop.i8(i8)");
                std::string b8 = res;
                if (bits > 8) { b8 = tmp(); out_ << "  " << b8 << " = trunc " << ty << " " << res << " to i8\n"; }
                std::string pc = tmp(), lb = tmp(), pf = tmp();
                out_ << "  " << pc << " = call i8 @llvm.ctpop.i8(i8 " << b8 << ")\n";
                out_ << "  " << lb << " = and i8 " << pc << ", 1\n";
                out_ << "  " << pf << " = icmp eq i8 " << lb << ", 0\n";
                cond_store("pf", pf);
            }
            if (live & (FL_CF | FL_OF)) {
                std::string cm1 = tmp(), safe_cm1 = tmp(), new_cf = tmp();
                out_ << "  " << cm1 << " = sub " << wty << " " << c << ", 1\n";
                out_ << "  " << safe_cm1 << " = and " << wty << " " << cm1 << ", " << mask << "\n";
                if (mn == ZYDIS_MNEMONIC_SHL) {
                    // CF = bit (bits - c) of a = bit (bits - 1) of (a << (c - 1))
                    std::string pre = tmp(), shb = tmp();
                    out_ << "  " << pre << " = shl " << wty << " " << aw << ", " << safe_cm1 << "\n";
                    out_ << "  " << shb << " = lshr " << wty << " " << pre << ", " << (bits - 1) << "\n";
                    out_ << "  " << new_cf << " = trunc " << wty << " " << shb << " to i1\n";
                } else {
                    // SHR/SAR: CF = bit (c - 1) of aw
                    std::string shb = tmp();
                    out_ << "  " << shb << " = " << (mn == ZYDIS_MNEMONIC_SAR ? "ashr " : "lshr ")
                         << wty << " " << aw << ", " << safe_cm1 << "\n";
                    out_ << "  " << new_cf << " = trunc " << wty << " " << shb << " to i1\n";
                }
                if (live & FL_CF) cond_store("cf", new_cf);
                if (live & FL_OF) {
                    std::string new_of;
                    if (mn == ZYDIS_MNEMONIC_SHL) {
                        std::string msb = tmp();
                        new_of = tmp();
                        out_ << "  " << msb << " = icmp slt " << ty << " " << res << ", 0\n";
                        out_ << "  " << new_of << " = xor i1 " << msb << ", " << new_cf << "\n";
                    } else if (mn == ZYDIS_MNEMONIC_SHR) {
                        new_of = tmp();
                        out_ << "  " << new_of << " = icmp slt " << ty << " " << a << ", 0\n";
                    } else {
                        new_of = "false";
                    }
                    // OF is only defined for count==1 (x86 preserves or leaves undefined otherwise;
                    // Rosetta/Intel sets OF as above for count==1)
                    cond_store("of", new_of);
                }
            }
        }
        return true;
    }

    case ZYDIS_MNEMONIC_ROL:
    case ZYDIS_MNEMONIC_ROR: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        int mask = (bits == 64) ? 63 : 31;
        const char *fn = (mn == ZYDIS_MNEMONIC_ROL) ? "fshl" : "fshr";
        need_intrinsic("declare " + ty + " @llvm." + fn + "." + ty + "(" + ty + ", " + ty + ", " + ty + ")");

        std::string a = read_op(di, 0, bits);
        std::string raw_c = read_op(di, 1, 8);
        std::string c8 = tmp(), c_ty = tmp();
        out_ << "  " << c8 << " = and i8 " << raw_c << ", " << mask << "\n";
        if (bits == 8) {
            c_ty = c8;
        } else {
            out_ << "  " << c_ty << " = zext i8 " << c8 << " to " << ty << "\n";
        }
        std::string res = tmp();
        out_ << "  " << res << " = call " << ty << " @llvm." << fn << "." << ty
             << "(" << ty << " " << a << ", " << ty << " " << a << ", " << ty << " " << c_ty << ")\n";
        write_op(di, 0, bits, res);

        if (live & (FL_CF | FL_OF)) {
            std::string is_zero = tmp();
            out_ << "  " << is_zero << " = icmp eq i8 " << c8 << ", 0\n";
            std::string new_cf;
            if (mn == ZYDIS_MNEMONIC_ROL) {
                new_cf = tmp();
                out_ << "  " << new_cf << " = trunc " << ty << " " << res << " to i1\n";
            } else {
                new_cf = tmp();
                out_ << "  " << new_cf << " = icmp slt " << ty << " " << res << ", 0\n";
            }
            if (live & FL_CF) {
                std::string old_cf = load_flag("cf"), sel = tmp();
                out_ << "  " << sel << " = select i1 " << is_zero << ", i1 " << old_cf << ", i1 " << new_cf << "\n";
                store_flag("cf", sel);
            }
            if (live & FL_OF) {
                std::string new_of = tmp();
                if (mn == ZYDIS_MNEMONIC_ROL) {
                    std::string msb = tmp();
                    out_ << "  " << msb << " = icmp slt " << ty << " " << res << ", 0\n";
                    out_ << "  " << new_of << " = xor i1 " << msb << ", " << new_cf << "\n";
                } else {
                    std::string b1 = tmp(), b2s = tmp(), b2 = tmp();
                    out_ << "  " << b1 << " = icmp slt " << ty << " " << res << ", 0\n";
                    out_ << "  " << b2s << " = lshr " << ty << " " << res << ", " << (bits - 2) << "\n";
                    out_ << "  " << b2 << " = trunc " << ty << " " << b2s << " to i1\n";
                    out_ << "  " << new_of << " = xor i1 " << b1 << ", " << b2 << "\n";
                }
                std::string old_of = load_flag("of"), sel = tmp();
                out_ << "  " << sel << " = select i1 " << is_zero << ", i1 " << old_of << ", i1 " << new_of << "\n";
                store_flag("of", sel);
            }
        }
        return true;
    }

    case ZYDIS_MNEMONIC_SHLD:
    case ZYDIS_MNEMONIC_SHRD: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        int mask = (bits == 64) ? 63 : 31;
        std::string dst = read_op(di, 0, bits);
        std::string src = read_op(di, 1, bits);
        std::string raw_c = read_op(di, 2, 8);
        std::string c8 = tmp(), is_zero = tmp();
        out_ << "  " << c8 << " = and i8 " << raw_c << ", " << mask << "\n";
        out_ << "  " << is_zero << " = icmp eq i8 " << c8 << ", 0\n";

        std::string c_ty = tmp();
        out_ << "  " << c_ty << " = zext i8 " << c8 << " to " << ty << "\n";

        std::string res = tmp();
        if (bits == 16) {
            // Exact 16-bit SHLD/SHRD for counts 0..31 (fixes count == 16 where fshl.i16 wraps mod 16!)
            std::string zd = tmp(), zs = tmp(), c32 = tmp(), hi = tmp(), cat = tmp(), sh = tmp();
            out_ << "  " << zd << " = zext i16 " << dst << " to i32\n";
            out_ << "  " << zs << " = zext i16 " << src << " to i32\n";
            out_ << "  " << c32 << " = zext i8 " << c8 << " to i32\n";
            if (mn == ZYDIS_MNEMONIC_SHLD) {
                std::string top = tmp();
                out_ << "  " << hi << " = shl i32 " << zd << ", 16\n";
                out_ << "  " << cat << " = or i32 " << hi << ", " << zs << "\n";
                out_ << "  " << sh << " = shl i32 " << cat << ", " << c32 << "\n";
                out_ << "  " << top << " = lshr i32 " << sh << ", 16\n";
                out_ << "  " << res << " = trunc i32 " << top << " to i16\n";
            } else {
                out_ << "  " << hi << " = shl i32 " << zs << ", 16\n";
                out_ << "  " << cat << " = or i32 " << hi << ", " << zd << "\n";
                out_ << "  " << sh << " = lshr i32 " << cat << ", " << c32 << "\n";
                out_ << "  " << res << " = trunc i32 " << sh << " to i16\n";
            }
        } else if (mn == ZYDIS_MNEMONIC_SHLD) {
            need_intrinsic("declare " + ty + " @llvm.fshl." + ty + "(" + ty + ", " + ty + ", " + ty + ")");
            out_ << "  " << res << " = call " << ty << " @llvm.fshl." << ty
                 << "(" << ty << " " << dst << ", " << ty << " " << src << ", " << ty << " " << c_ty << ")\n";
        } else {
            need_intrinsic("declare " + ty + " @llvm.fshr." + ty + "(" + ty + ", " + ty + ", " + ty + ")");
            out_ << "  " << res << " = call " << ty << " @llvm.fshr." << ty
                 << "(" << ty << " " << src << ", " << ty << " " << dst << ", " << ty << " " << c_ty << ")\n";
        }
        write_op(di, 0, bits, res);

        if (live & FL_ALL6) {
            auto cond_store = [&](const char *fl_name, const std::string &new_v) {
                std::string old_v = load_flag(fl_name), sel = tmp();
                out_ << "  " << sel << " = select i1 " << is_zero << ", i1 " << old_v << ", i1 " << new_v << "\n";
                store_flag(fl_name, sel);
            };
            if (live & FL_ZF) {
                std::string z = tmp();
                out_ << "  " << z << " = icmp eq " << ty << " " << res << ", 0\n";
                cond_store("zf", z);
            }
            if (live & FL_SF) {
                std::string s = tmp();
                out_ << "  " << s << " = icmp slt " << ty << " " << res << ", 0\n";
                cond_store("sf", s);
            }
            if (live & FL_PF) {
                need_intrinsic("declare i8 @llvm.ctpop.i8(i8)");
                std::string b8 = tmp(), pc = tmp(), lb = tmp(), pf = tmp();
                out_ << "  " << b8 << " = trunc " << ty << " " << res << " to i8\n";
                out_ << "  " << pc << " = call i8 @llvm.ctpop.i8(i8 " << b8 << ")\n";
                out_ << "  " << lb << " = and i8 " << pc << ", 1\n";
                out_ << "  " << pf << " = icmp eq i8 " << lb << ", 0\n";
                cond_store("pf", pf);
            }
            if (live & FL_CF) {
                std::string cm1 = tmp(), safe_cm1 = tmp(), sh = tmp(), cf = tmp();
                out_ << "  " << cm1 << " = sub " << ty << " " << c_ty << ", 1\n";
                out_ << "  " << safe_cm1 << " = and " << ty << " " << cm1 << ", " << (bits - 1) << "\n";
                if (mn == ZYDIS_MNEMONIC_SHLD) {
                    std::string pre = tmp();
                    out_ << "  " << pre << " = shl " << ty << " " << dst << ", " << safe_cm1 << "\n";
                    out_ << "  " << sh << " = lshr " << ty << " " << pre << ", " << (bits - 1) << "\n";
                } else {
                    out_ << "  " << sh << " = lshr " << ty << " " << dst << ", " << safe_cm1 << "\n";
                }
                out_ << "  " << cf << " = trunc " << ty << " " << sh << " to i1\n";
                cond_store("cf", cf);
            }
            if (live & FL_OF) {
                std::string m1 = tmp(), m2 = tmp(), of = tmp();
                out_ << "  " << m1 << " = icmp slt " << ty << " " << dst << ", 0\n";
                out_ << "  " << m2 << " = icmp slt " << ty << " " << res << ", 0\n";
                out_ << "  " << of << " = xor i1 " << m1 << ", " << m2 << "\n";
                cond_store("of", of);
            }
        }
        return true;
    }

    // ---- Bit Manipulation ----
    case ZYDIS_MNEMONIC_BT:
    case ZYDIS_MNEMONIC_BTS:
    case ZYDIS_MNEMONIC_BTR:
    case ZYDIS_MNEMONIC_BTC: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER) {
            std::string a = read_op(di, 0, bits);
            std::string raw_i = read_op(di, 1, (di.ops[1].type == ZYDIS_OPERAND_TYPE_IMMEDIATE) ? 8 : bits);
            std::string idx = raw_i;
            if (di.ops[1].type == ZYDIS_OPERAND_TYPE_IMMEDIATE && bits > 8) {
                idx = tmp();
                out_ << "  " << idx << " = zext i8 " << raw_i << " to " << ty << "\n";
            }
            std::string m_idx = tmp(), sh = tmp(), bit = tmp();
            out_ << "  " << m_idx << " = and " << ty << " " << idx << ", " << (bits - 1) << "\n";
            out_ << "  " << sh << " = lshr " << ty << " " << a << ", " << m_idx << "\n";
            out_ << "  " << bit << " = trunc " << ty << " " << sh << " to i1\n";
            if (live & FL_CF) store_flag("cf", bit);
            if (mn != ZYDIS_MNEMONIC_BT) {
                std::string mask = tmp(), nv = tmp();
                out_ << "  " << mask << " = shl " << ty << " 1, " << m_idx << "\n";
                if (mn == ZYDIS_MNEMONIC_BTS) {
                    out_ << "  " << nv << " = or " << ty << " " << a << ", " << mask << "\n";
                } else if (mn == ZYDIS_MNEMONIC_BTR) {
                    std::string nmask = tmp();
                    out_ << "  " << nmask << " = xor " << ty << " " << mask << ", -1\n";
                    out_ << "  " << nv << " = and " << ty << " " << a << ", " << nmask << "\n";
                } else {
                    out_ << "  " << nv << " = xor " << ty << " " << a << ", " << mask << "\n";
                }
                write_op(di, 0, bits, nv);
            }
        } else {
            // Memory operand: if op1 is register, bit offset is SIGNED across bytes!
            bool is_stack = false, is_ro = false;
            std::string base_ea = calc_mem_addr(di, di.ops[0], is_stack, is_ro);
            std::string byte_ea = base_ea, bit_in_byte;
            if (di.ops[1].type == ZYDIS_OPERAND_TYPE_IMMEDIATE) {
                uint64_t imm = di.ops[1].imm.value.u & (uint64_t)(bits - 1);
                if (imm >= 8) {
                    byte_ea = tmp();
                    out_ << "  " << byte_ea << " = add i64 " << base_ea << ", " << (imm >> 3) << "\n";
                }
                bit_in_byte = std::to_string(imm & 7);
            } else {
                std::string raw_i = read_op(di, 1, bits);
                std::string i64 = raw_i;
                if (bits < 64) {
                    i64 = tmp();
                    out_ << "  " << i64 << " = sext " << ty << " " << raw_i << " to i64\n";
                }
                std::string boff = tmp(), bmod = tmp();
                byte_ea = tmp();
                bit_in_byte = tmp();
                out_ << "  " << boff << " = ashr i64 " << i64 << ", 3\n";
                out_ << "  " << byte_ea << " = add i64 " << base_ea << ", " << boff << "\n";
                out_ << "  " << bmod << " = and i64 " << i64 << ", 7\n";
                out_ << "  " << bit_in_byte << " = trunc i64 " << bmod << " to i8\n";
            }
            if (mn == ZYDIS_MNEMONIC_BT) {
                std::string bv = emit_mem_load(byte_ea, 8, is_stack, is_ro, false);
                std::string sh = tmp(), bit = tmp();
                out_ << "  " << sh << " = lshr i8 " << bv << ", " << bit_in_byte << "\n";
                out_ << "  " << bit << " = trunc i8 " << sh << " to i1\n";
                if (live & FL_CF) store_flag("cf", bit);
            } else {
                std::string mask = tmp(), p = tmp();
                out_ << "  " << mask << " = shl i8 1, " << bit_in_byte << "\n";
                out_ << "  " << p << " = inttoptr i64 " << byte_ea << " to ptr\n";
                std::string old;
                if (has_lock) {
                    old = tmp();
                    if (mn == ZYDIS_MNEMONIC_BTS) {
                        out_ << "  " << old << " = atomicrmw or ptr " << p << ", i8 " << mask << " seq_cst, align 1\n";
                    } else if (mn == ZYDIS_MNEMONIC_BTR) {
                        std::string nmask = tmp();
                        out_ << "  " << nmask << " = xor i8 " << mask << ", -1\n";
                        out_ << "  " << old << " = atomicrmw and ptr " << p << ", i8 " << nmask << " seq_cst, align 1\n";
                    } else {
                        out_ << "  " << old << " = atomicrmw xor ptr " << p << ", i8 " << mask << " seq_cst, align 1\n";
                    }
                } else {
                    old = emit_mem_load(byte_ea, 8, is_stack, is_ro, false);
                    std::string nv = tmp();
                    if (mn == ZYDIS_MNEMONIC_BTS) out_ << "  " << nv << " = or i8 " << old << ", " << mask << "\n";
                    else if (mn == ZYDIS_MNEMONIC_BTR) {
                        std::string nmask = tmp();
                        out_ << "  " << nmask << " = xor i8 " << mask << ", -1\n";
                        out_ << "  " << nv << " = and i8 " << old << ", " << nmask << "\n";
                    } else out_ << "  " << nv << " = xor i8 " << old << ", " << mask << "\n";
                    emit_mem_store(byte_ea, 8, nv, is_stack, false);
                }
                if (live & FL_CF) {
                    std::string sh = tmp(), bit = tmp();
                    out_ << "  " << sh << " = lshr i8 " << old << ", " << bit_in_byte << "\n";
                    out_ << "  " << bit << " = trunc i8 " << sh << " to i1\n";
                    store_flag("cf", bit);
                }
            }
        }
        return true;
    }

    case ZYDIS_MNEMONIC_BSF:
    case ZYDIS_MNEMONIC_BSR: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string src = read_op(di, 1, bits);
        std::string is_zero = tmp();
        out_ << "  " << is_zero << " = icmp eq " << ty << " " << src << ", 0\n";
        if (live & FL_ZF) store_flag("zf", is_zero);

        std::string res = tmp();
        if (mn == ZYDIS_MNEMONIC_BSF) {
            need_intrinsic("declare " + ty + " @llvm.cttz." + ty + "(" + ty + ", i1)");
            out_ << "  " << res << " = call " << ty << " @llvm.cttz." << ty << "(" << ty << " " << src << ", i1 false)\n";
        } else {
            need_intrinsic("declare " + ty + " @llvm.ctlz." + ty + "(" + ty + ", i1)");
            std::string lz = tmp();
            out_ << "  " << lz << " = call " << ty << " @llvm.ctlz." << ty << "(" << ty << " " << src << ", i1 false)\n";
            out_ << "  " << res << " = sub " << ty << " " << (bits - 1) << ", " << lz << "\n";
        }
        // Only write destination if src != 0 (preserves full 64-bit reg on zero!)
        std::string lid = std::to_string(next_id_++);
        out_ << "  br i1 " << is_zero << ", label %bs_z_" << lid << ", label %bs_nz_" << lid << "\n";
        out_ << "bs_nz_" << lid << ":\n";
        write_op(di, 0, bits, res);
        out_ << "  br label %bs_z_" << lid << "\n";
        out_ << "bs_z_" << lid << ":\n";
        return true;
    }

    case ZYDIS_MNEMONIC_POPCNT: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        need_intrinsic("declare " + ty + " @llvm.ctpop." + ty + "(" + ty + ")");
        std::string src = read_op(di, 1, bits), res = tmp();
        out_ << "  " << res << " = call " << ty << " @llvm.ctpop." << ty << "(" << ty << " " << src << ")\n";
        write_op(di, 0, bits, res);
        if (live & FL_ZF) {
            std::string z = tmp();
            out_ << "  " << z << " = icmp eq " << ty << " " << src << ", 0\n";
            store_flag("zf", z);
        }
        if (live & FL_CF) store_flag("cf", "false");
        if (live & FL_OF) store_flag("of", "false");
        if (live & FL_SF) store_flag("sf", "false");
        if (live & FL_AF) store_flag("af", "false");
        if (live & FL_PF) store_flag("pf", "false");
        return true;
    }

    // ---- Conditional Move & Set ----
    case ZYDIS_MNEMONIC_CMOVZ:  case ZYDIS_MNEMONIC_CMOVNZ:
    case ZYDIS_MNEMONIC_CMOVB:  case ZYDIS_MNEMONIC_CMOVNB:
    case ZYDIS_MNEMONIC_CMOVBE: case ZYDIS_MNEMONIC_CMOVNBE:
    case ZYDIS_MNEMONIC_CMOVS:  case ZYDIS_MNEMONIC_CMOVNS:
    case ZYDIS_MNEMONIC_CMOVO:  case ZYDIS_MNEMONIC_CMOVNO:
    case ZYDIS_MNEMONIC_CMOVP:  case ZYDIS_MNEMONIC_CMOVNP:
    case ZYDIS_MNEMONIC_CMOVL:  case ZYDIS_MNEMONIC_CMOVNL:
    case ZYDIS_MNEMONIC_CMOVLE: case ZYDIS_MNEMONIC_CMOVNLE: {
        int bits = op_width(di, 0);
        std::string ty = int_ty(bits);
        std::string cond = eval_cc(mn);
        std::string old_d = read_op(di, 0, bits);
        std::string src = read_op(di, 1, bits);
        std::string sel = tmp();
        out_ << "  " << sel << " = select i1 " << cond << ", " << ty << " " << src << ", " << ty << " " << old_d << "\n";
        write_op(di, 0, bits, sel); // Automatically zero-extends 32-bit even when cond is false (x86_64 rule!)
        return true;
    }

    case ZYDIS_MNEMONIC_SETZ:  case ZYDIS_MNEMONIC_SETNZ:
    case ZYDIS_MNEMONIC_SETB:  case ZYDIS_MNEMONIC_SETNB:
    case ZYDIS_MNEMONIC_SETBE: case ZYDIS_MNEMONIC_SETNBE:
    case ZYDIS_MNEMONIC_SETS:  case ZYDIS_MNEMONIC_SETNS:
    case ZYDIS_MNEMONIC_SETO:  case ZYDIS_MNEMONIC_SETNO:
    case ZYDIS_MNEMONIC_SETP:  case ZYDIS_MNEMONIC_SETNP:
    case ZYDIS_MNEMONIC_SETL:  case ZYDIS_MNEMONIC_SETNL:
    case ZYDIS_MNEMONIC_SETLE: case ZYDIS_MNEMONIC_SETNLE: {
        std::string cond = eval_cc(mn), v = tmp();
        out_ << "  " << v << " = zext i1 " << cond << " to i8\n";
        write_op(di, 0, 8, v);
        return true;
    }

    // ---- Control Flow ----
    case ZYDIS_MNEMONIC_JCXZ: case ZYDIS_MNEMONIC_JECXZ: case ZYDIS_MNEMONIC_JRCXZ:
    case ZYDIS_MNEMONIC_JZ:  case ZYDIS_MNEMONIC_JNZ:
    case ZYDIS_MNEMONIC_JB:  case ZYDIS_MNEMONIC_JNB:
    case ZYDIS_MNEMONIC_JBE: case ZYDIS_MNEMONIC_JNBE:
    case ZYDIS_MNEMONIC_JS:  case ZYDIS_MNEMONIC_JNS:
    case ZYDIS_MNEMONIC_JO:  case ZYDIS_MNEMONIC_JNO:
    case ZYDIS_MNEMONIC_JP:  case ZYDIS_MNEMONIC_JNP:
    case ZYDIS_MNEMONIC_JL:  case ZYDIS_MNEMONIC_JNL:
    case ZYDIS_MNEMONIC_JLE: case ZYDIS_MNEMONIC_JNLE: {
        uint64_t target = di.va + di.ins.length + (uint64_t)(int64_t)di.ops[0].imm.value.s;
        uint64_t fall = di.va + di.ins.length;
        std::string cond;
        if (mn == ZYDIS_MNEMONIC_JCXZ || mn == ZYDIS_MNEMONIC_JECXZ || mn == ZYDIS_MNEMONIC_JRCXZ) {
            int cb = (mn == ZYDIS_MNEMONIC_JCXZ) ? 16 : (mn == ZYDIS_MNEMONIC_JECXZ) ? 32 : 64;
            ZydisRegister cr = (cb == 16) ? ZYDIS_REGISTER_CX : (cb == 32) ? ZYDIS_REGISTER_ECX : ZYDIS_REGISTER_RCX;
            std::string cv = read_reg(cr, cb);
            cond = tmp();
            out_ << "  " << cond << " = icmp eq " << int_ty(cb) << " " << cv << ", 0\n";
        } else {
            cond = eval_cc(mn);
        }
        bool in_t = cfg.blocks.count(target) != 0;
        bool in_f = cfg.blocks.count(fall) != 0;
        if (in_t && in_f) {
            out_ << "  br i1 " << cond << ", label %bb_" << fmt_va(target) << ", label %bb_" << fmt_va(fall) << "\n";
        } else {
            std::string lid = std::to_string(next_id_++);
            std::string t_lbl = in_t ? ("bb_" + fmt_va(target)) : ("jcc_ext_" + lid);
            std::string f_lbl = in_f ? ("bb_" + fmt_va(fall)) : ("jcc_fall_" + lid);
            out_ << "  br i1 " << cond << ", label %" << t_lbl << ", label %" << f_lbl << "\n";
            if (!in_t) {
                out_ << t_lbl << ":\n";
                if (img_ && img_->stub_to_internal_va.count(target)) {
                    uint64_t iva = img_->stub_to_internal_va.at(target);
                    std::string sym = func_symbol(iva);
                    if (iva != cur_func_va_) extern_guest_funcs_.insert(sym);
                    emit_guest_call(sym, 0, true);
                } else if (img_ && img_->stub_to_sym.count(target)) {
                    const std::string &raw_sym = img_->stub_to_sym.at(target);
                    std::string sym = stub_symbol(raw_sym);
                    bool rt = is_returns_twice_sym(raw_sym);
                    extern_stubs_.insert(sym);
                    if (rt) returns_twice_stubs_.insert(sym);
                    emit_guest_call(sym, 0, true, rt);
                } else if (!img_ || img_->func_start_set.count(target)) {
                    std::string sym = func_symbol(target);
                    if (target != cur_func_va_) extern_guest_funcs_.insert(sym);
                    emit_guest_call(sym, 0, true);
                } else {
                    emit_indirect_call(std::to_string(target), 0, true);
                }
            }
            if (!in_f) {
                out_ << f_lbl << ":\n";
                out_ << "  call void @bo3_trap(i64 " << fall << ", i64 4, ptr %ctx)\n";
                out_ << "  unreachable\n";
            }
        }
        terminated = true;
        return true;
    }

    case ZYDIS_MNEMONIC_JMP: {
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_IMMEDIATE) {
            uint64_t target = di.va + di.ins.length + (uint64_t)(int64_t)di.ops[0].imm.value.s;
            if (cfg.blocks.count(target)) {
                out_ << "  br label %bb_" << fmt_va(target) << "\n";
            } else if (img_ && img_->stub_to_internal_va.count(target)) {
                uint64_t iva = img_->stub_to_internal_va.at(target);
                std::string sym = func_symbol(iva);
                if (iva != cur_func_va_) extern_guest_funcs_.insert(sym);
                emit_guest_call(sym, 0, true);
            } else if (img_ && img_->stub_to_sym.count(target)) {
                const std::string &raw_sym = img_->stub_to_sym.at(target);
                std::string sym = stub_symbol(raw_sym);
                bool rt = is_returns_twice_sym(raw_sym);
                extern_stubs_.insert(sym);
                if (rt) returns_twice_stubs_.insert(sym);
                emit_guest_call(sym, 0, true, rt);
            } else if (!img_ || img_->func_start_set.count(target)) {
                std::string sym = func_symbol(target);
                if (target != cur_func_va_) extern_guest_funcs_.insert(sym);
                emit_guest_call(sym, 0, true);
            } else {
                emit_indirect_call(std::to_string(target), 0, true);
            }
        } else {
            if (img_ && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY && di.ops[0].mem.base == ZYDIS_REGISTER_RIP) {
                uint64_t ea = di.va + di.ins.length + (uint64_t)(int64_t)di.ops[0].mem.disp.value;
                auto iit = img_->got_to_internal_va.find(ea);
                if (iit != img_->got_to_internal_va.end()) {
                    std::string sym = func_symbol(iit->second);
                    if (iit->second != cur_func_va_) extern_guest_funcs_.insert(sym);
                    emit_guest_call(sym, 0, true);
                    terminated = true;
                    return true;
                }
                auto it = img_->got_to_sym.find(ea);
                if (it != img_->got_to_sym.end()) {
                    std::string sym = stub_symbol(it->second);
                    bool rt = is_returns_twice_sym(it->second);
                    extern_stubs_.insert(sym);
                    if (rt) returns_twice_stubs_.insert(sym);
                    emit_guest_call(sym, 0, true, rt);
                    terminated = true;
                    return true;
                }
            }
            std::string target_va = read_op(di, 0, 64);
            if (di.is_switch_jmp && !di.switch_targets.empty()) {
                std::string lid = std::to_string(next_id_++);
                std::unordered_set<uint64_t> seen_tv;
                out_ << "  switch i64 " << target_va << ", label %sw_def_" << lid << " [\n";
                for (uint64_t tv : di.switch_targets) {
                    if (cfg.blocks.count(tv) && seen_tv.insert(tv).second) {
                        out_ << "    i64 " << tv << ", label %bb_" << fmt_va(tv) << "\n";
                    }
                }
                out_ << "  ]\n";
                out_ << "sw_def_" << lid << ":\n";
                emit_indirect_call(target_va, 0, true);
            } else {
                emit_indirect_call(target_va, 0, true);
            }
        }
        terminated = true;
        return true;
    }

    case ZYDIS_MNEMONIC_CALL: {
        uint64_t ret_va = di.va + di.ins.length;
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_IMMEDIATE) {
            uint64_t target = ret_va + (uint64_t)(int64_t)di.ops[0].imm.value.s;
            if (img_ && img_->stub_to_internal_va.count(target)) {
                uint64_t iva = img_->stub_to_internal_va.at(target);
                std::string sym = func_symbol(iva);
                if (iva != cur_func_va_) extern_guest_funcs_.insert(sym);
                emit_guest_call(sym, ret_va, false);
            } else if (img_ && img_->stub_to_sym.count(target)) {
                const std::string &raw_sym = img_->stub_to_sym.at(target);
                // Darwin ___chkstk_darwin probes stack guard pages and MUST preserve RAX (and all regs)!
                // Our guest stack is pre-committed 8 MiB mmap, so ___chkstk_darwin is a safe no-op.
                if (raw_sym == "____chkstk_darwin" || raw_sym == "___chkstk_darwin") {
                    return true;
                }
                std::string sym = stub_symbol(raw_sym);
                bool rt = is_returns_twice_sym(raw_sym);
                extern_stubs_.insert(sym);
                if (rt) returns_twice_stubs_.insert(sym);
                emit_guest_call(sym, ret_va, false, rt);
            } else if (!img_ || img_->func_start_set.count(target)) {
                std::string sym = func_symbol(target);
                if (target != cur_func_va_) extern_guest_funcs_.insert(sym);
                emit_guest_call(sym, ret_va, false);
            } else {
                emit_indirect_call(std::to_string(target), ret_va, false);
            }
        } else {
            // Check RIP-relative GOT call
            if (img_ && di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY && di.ops[0].mem.base == ZYDIS_REGISTER_RIP) {
                uint64_t ea = ret_va + (uint64_t)(int64_t)di.ops[0].mem.disp.value;
                auto iit = img_->got_to_internal_va.find(ea);
                if (iit != img_->got_to_internal_va.end()) {
                    std::string sym = func_symbol(iit->second);
                    if (iit->second != cur_func_va_) extern_guest_funcs_.insert(sym);
                    emit_guest_call(sym, ret_va, false);
                    return true;
                }
                auto it = img_->got_to_sym.find(ea);
                if (it != img_->got_to_sym.end()) {
                    if (it->second == "____chkstk_darwin" || it->second == "___chkstk_darwin") {
                        return true;
                    }
                    std::string sym = stub_symbol(it->second);
                    bool rt = is_returns_twice_sym(it->second);
                    extern_stubs_.insert(sym);
                    if (rt) returns_twice_stubs_.insert(sym);
                    emit_guest_call(sym, ret_va, false, rt);
                    return true;
                }
            }
            // Darwin Mach-O TLV thunk: `call qword ptr [rdi]` where rdi is in __DATA,__thread_vars.
            // CSR_64_TLS_Darwin preserves rcx, rdx, rsi, rdi, r8..r11, xmm0..xmm7 and writes ONLY rax!
            if (img_ && img_->tlv_size > 0 &&
                di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY &&
                di.ops[0].mem.base == ZYDIS_REGISTER_RDI &&
                di.ops[0].mem.index == ZYDIS_REGISTER_NONE &&
                (!di.ops[0].mem.disp.has_displacement || di.ops[0].mem.disp.value == 0)) {
                std::string rdi_v = load_gpr64(7);
                std::string ge = tmp(), lt = tmp(), is_tlv = tmp();
                std::string lid = std::to_string(next_id_++);
                out_ << "  " << ge << " = icmp uge i64 " << rdi_v << ", " << img_->tlv_va << "\n";
                out_ << "  " << lt << " = icmp ult i64 " << rdi_v << ", " << (img_->tlv_va + img_->tlv_size) << "\n";
                out_ << "  " << is_tlv << " = and i1 " << ge << ", " << lt << "\n";
                out_ << "  br i1 " << is_tlv << ", label %tlv_hit_" << lid << ", label %tlv_miss_" << lid << "\n";
                out_ << "tlv_hit_" << lid << ":\n";
                std::string dp = tmp(), tp = tmp(), ta = tmp();
                out_ << "  " << dp << " = inttoptr i64 " << rdi_v << " to ptr\n";
                out_ << "  " << tp << " = call ptr @bo3_tlv_get_addr(ptr %ctx, ptr " << dp << ")\n";
                out_ << "  " << ta << " = ptrtoint ptr " << tp << " to i64\n";
                store_gpr64(0, ta); // ONLY write rax; all other regs survive intact!
                out_ << "  br label %tlv_done_" << lid << "\n";
                out_ << "tlv_miss_" << lid << ":\n";
                std::string target_va = read_op(di, 0, 64);
                emit_indirect_call(target_va, ret_va, false);
                out_ << "  br label %tlv_done_" << lid << "\n";
                out_ << "tlv_done_" << lid << ":\n";
                return true;
            }
            std::string target_va = read_op(di, 0, 64);
            emit_indirect_call(target_va, ret_va, false);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_RET: {
        if (opts_.cc == CallConv::SupersetSysV) {
            std::string rax = load_gpr64(0), rdx = load_gpr64(2);
            std::string x0 = load_xmm(0), x1 = load_xmm(1);
            std::string rr0 = tmp(), rr1 = tmp(), r0 = tmp(), r1 = tmp(), r2 = tmp();
            out_ << "  " << rr0 << " = insertelement <2 x i64> poison, i64 " << rax << ", i32 0\n";
            out_ << "  " << rr1 << " = insertelement <2 x i64> " << rr0 << ", i64 " << rdx << ", i32 1\n";
            out_ << "  " << r0  << " = insertvalue %ret_t poison, <2 x i64> " << rr1 << ", 0\n";
            out_ << "  " << r1  << " = insertvalue %ret_t " << r0 << ", <2 x i64> " << x0 << ", 1\n";
            out_ << "  " << r2  << " = insertvalue %ret_t " << r1 << ", <2 x i64> " << x1 << ", 2\n";
            out_ << "  ret %ret_t " << r2 << "\n";
        } else {
            // FullState: mirror x86 `ret` popping 8-byte return address from rsp
            std::string sp = load_gpr64(4), nsp = tmp();
            out_ << "  " << nsp << " = add i64 " << sp << ", 8\n";
            store_gpr64(4, nsp);
            emit_spill_fullstate();
            out_ << "  ret void\n";
        }
        terminated = true;
        return true;
    }

    default:
        return false;
    }
}

} // namespace bo3

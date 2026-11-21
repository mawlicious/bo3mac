#include "ir_emitter.h"
#include <cstdio>
#include <iomanip>

namespace bo3 {

static const char *kGprNames[16] = {
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15"
};

IREmitter::IREmitter(const MachOImage *img, const LiftOptions &opts)
    : img_(img), opts_(opts) {}

std::string IREmitter::tmp() {
    return "%t" + std::to_string(next_id_++);
}

std::string IREmitter::fmt_va(uint64_t va) const {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%llx", (unsigned long long)va);
    return std::string(buf);
}

std::string IREmitter::func_symbol(uint64_t va) const {
    return "@g_" + fmt_va(va);
}

std::string IREmitter::stub_symbol(const std::string &macho_sym) const {
    std::string out = "@shim_";
    for (char c : macho_sym) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_') {
            out.push_back(c);
        } else {
            char hex[8];
            std::snprintf(hex, sizeof(hex), "_%02x_", (unsigned char)c);
            out += hex;
        }
    }
    return out;
}

bool IREmitter::is_returns_twice_sym(const std::string &sym) {
    return sym == "_setjmp" || sym == "__setjmp" || sym == "setjmp" ||
           sym == "_sigsetjmp" || sym == "__sigsetjmp" || sym == "sigsetjmp";
}

const char *IREmitter::gpr_slot_name(int idx) {
    return kGprNames[idx & 15];
}

std::string IREmitter::int_ty(int bits) {
    return "i" + std::to_string(bits);
}

int IREmitter::zydis_gpr_index(ZydisRegister reg, int &bits, bool &high8) {
    high8 = false;
    switch (reg) {
        case ZYDIS_REGISTER_RAX: bits = 64; return 0;
        case ZYDIS_REGISTER_RCX: bits = 64; return 1;
        case ZYDIS_REGISTER_RDX: bits = 64; return 2;
        case ZYDIS_REGISTER_RBX: bits = 64; return 3;
        case ZYDIS_REGISTER_RSP: bits = 64; return 4;
        case ZYDIS_REGISTER_RBP: bits = 64; return 5;
        case ZYDIS_REGISTER_RSI: bits = 64; return 6;
        case ZYDIS_REGISTER_RDI: bits = 64; return 7;
        case ZYDIS_REGISTER_R8:  bits = 64; return 8;
        case ZYDIS_REGISTER_R9:  bits = 64; return 9;
        case ZYDIS_REGISTER_R10: bits = 64; return 10;
        case ZYDIS_REGISTER_R11: bits = 64; return 11;
        case ZYDIS_REGISTER_R12: bits = 64; return 12;
        case ZYDIS_REGISTER_R13: bits = 64; return 13;
        case ZYDIS_REGISTER_R14: bits = 64; return 14;
        case ZYDIS_REGISTER_R15: bits = 64; return 15;

        case ZYDIS_REGISTER_EAX:  bits = 32; return 0;
        case ZYDIS_REGISTER_ECX:  bits = 32; return 1;
        case ZYDIS_REGISTER_EDX:  bits = 32; return 2;
        case ZYDIS_REGISTER_EBX:  bits = 32; return 3;
        case ZYDIS_REGISTER_ESP:  bits = 32; return 4;
        case ZYDIS_REGISTER_EBP:  bits = 32; return 5;
        case ZYDIS_REGISTER_ESI:  bits = 32; return 6;
        case ZYDIS_REGISTER_EDI:  bits = 32; return 7;
        case ZYDIS_REGISTER_R8D:  bits = 32; return 8;
        case ZYDIS_REGISTER_R9D:  bits = 32; return 9;
        case ZYDIS_REGISTER_R10D: bits = 32; return 10;
        case ZYDIS_REGISTER_R11D: bits = 32; return 11;
        case ZYDIS_REGISTER_R12D: bits = 32; return 12;
        case ZYDIS_REGISTER_R13D: bits = 32; return 13;
        case ZYDIS_REGISTER_R14D: bits = 32; return 14;
        case ZYDIS_REGISTER_R15D: bits = 32; return 15;

        case ZYDIS_REGISTER_AX:   bits = 16; return 0;
        case ZYDIS_REGISTER_CX:   bits = 16; return 1;
        case ZYDIS_REGISTER_DX:   bits = 16; return 2;
        case ZYDIS_REGISTER_BX:   bits = 16; return 3;
        case ZYDIS_REGISTER_SP:   bits = 16; return 4;
        case ZYDIS_REGISTER_BP:   bits = 16; return 5;
        case ZYDIS_REGISTER_SI:   bits = 16; return 6;
        case ZYDIS_REGISTER_DI:   bits = 16; return 7;
        case ZYDIS_REGISTER_R8W:  bits = 16; return 8;
        case ZYDIS_REGISTER_R9W:  bits = 16; return 9;
        case ZYDIS_REGISTER_R10W: bits = 16; return 10;
        case ZYDIS_REGISTER_R11W: bits = 16; return 11;
        case ZYDIS_REGISTER_R12W: bits = 16; return 12;
        case ZYDIS_REGISTER_R13W: bits = 16; return 13;
        case ZYDIS_REGISTER_R14W: bits = 16; return 14;
        case ZYDIS_REGISTER_R15W: bits = 16; return 15;

        case ZYDIS_REGISTER_AL:   bits = 8; return 0;
        case ZYDIS_REGISTER_CL:   bits = 8; return 1;
        case ZYDIS_REGISTER_DL:   bits = 8; return 2;
        case ZYDIS_REGISTER_BL:   bits = 8; return 3;
        case ZYDIS_REGISTER_SPL:  bits = 8; return 4;
        case ZYDIS_REGISTER_BPL:  bits = 8; return 5;
        case ZYDIS_REGISTER_SIL:  bits = 8; return 6;
        case ZYDIS_REGISTER_DIL:  bits = 8; return 7;
        case ZYDIS_REGISTER_R8B:  bits = 8; return 8;
        case ZYDIS_REGISTER_R9B:  bits = 8; return 9;
        case ZYDIS_REGISTER_R10B: bits = 8; return 10;
        case ZYDIS_REGISTER_R11B: bits = 8; return 11;
        case ZYDIS_REGISTER_R12B: bits = 8; return 12;
        case ZYDIS_REGISTER_R13B: bits = 8; return 13;
        case ZYDIS_REGISTER_R14B: bits = 8; return 14;
        case ZYDIS_REGISTER_R15B: bits = 8; return 15;

        case ZYDIS_REGISTER_AH: bits = 8; high8 = true; return 0;
        case ZYDIS_REGISTER_CH: bits = 8; high8 = true; return 1;
        case ZYDIS_REGISTER_DH: bits = 8; high8 = true; return 2;
        case ZYDIS_REGISTER_BH: bits = 8; high8 = true; return 3;
        default: bits = 0; return -1;
    }
}

int IREmitter::zydis_xmm_index(ZydisRegister reg) {
    if (reg >= ZYDIS_REGISTER_XMM0 && reg <= ZYDIS_REGISTER_XMM15) {
        return (int)(reg - ZYDIS_REGISTER_XMM0);
    }
    return -1;
}

void IREmitter::emit_module_header(std::ostream &os) {
    os << "; Generated by bo3_lift (x86_64 -> Apple Silicon ARM64 LLVM IR)\n";
    os << "target datalayout = \"e-m:o-i64:64-i128:128-n32:64-S128-Fn32\"\n";
    os << "target triple = \"arm64-apple-macosx15.0.0\"\n\n";
    // 3-vector HVA: matches C `struct GuestRet { GuestXmm rax_rdx; GuestXmm xmm0; GuestXmm xmm1; }`
    // Returns directly in ARM64 v0, v1, v2 with ZERO sret!
    os << "%ret_t = type { <2 x i64>, <2 x i64>, <2 x i64> }\n\n";
    os << "declare ptr @bo3_resolve(i64, ptr)\n";
    os << "declare void @bo3_cpuid(i32, i32, ptr, ptr, ptr, ptr)\n";
    os << "declare i64 @bo3_rdtsc()\n";
    os << "declare void @bo3_trap(i64, i64, ptr) noreturn\n";
    os << "declare ptr @bo3_tlv_get_addr(ptr, ptr)\n\n";
}

void IREmitter::emit_module_decls(std::ostream &os) {
    os << "\n; External declarations\n";
    for (const auto &sym : extern_guest_funcs_) {
        if (opts_.cc == CallConv::SupersetSysV) {
            os << "declare %ret_t " << sym << "(ptr, i64, i64, i64, i64, i64, i64, i64, "
                  "<2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>)\n";
        } else {
            os << "declare void " << sym << "(ptr)\n";
        }
    }
    for (const auto &sym : extern_stubs_) {
        const char *rt_attr = returns_twice_stubs_.count(sym) ? " returns_twice" : "";
        if (opts_.cc == CallConv::SupersetSysV) {
            os << "declare %ret_t " << sym << "(ptr, i64, i64, i64, i64, i64, i64, i64, "
                  "<2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>, <2 x i64>)"
               << rt_attr << "\n";
        } else {
            os << "declare void " << sym << "(ptr)" << rt_attr << "\n";
        }
    }
    for (const auto &decl : intrinsics_) {
        os << decl << "\n";
    }
    // Guarantee LSE + RCPC (+lse,+rcpc) regardless of driver flags; target_cpu defaults to apple-m4
    // (override with --mcpu apple-m1 / BO3ARM_MCPU=apple-m1 for M1-M3 portability).
    os << "\nattributes #0 = { \"target-cpu\"=\"" << opts_.target_cpu
       << "\" \"target-features\"=\"+lse,+rcpc\" }\n";
}

std::string IREmitter::load_gpr64(int idx) {
    std::string r = tmp();
    out_ << "  " << r << " = load i64, ptr %r_" << kGprNames[idx] << "\n";
    return r;
}

void IREmitter::store_gpr64(int idx, const std::string &val64) {
    out_ << "  store i64 " << val64 << ", ptr %r_" << kGprNames[idx] << "\n";
}

std::string IREmitter::read_reg(ZydisRegister reg, int bits, uint64_t next_va) {
    int rbits = 0; bool high8 = false;
    int idx = zydis_gpr_index(reg, rbits, high8);
    if (idx < 0) {
        if (reg == ZYDIS_REGISTER_RIP) return std::to_string(next_va ? next_va : cur_func_va_);
        return "0";
    }
    std::string v64 = load_gpr64(idx);
    if (bits == 64) return v64;
    if (high8) {
        std::string sh = tmp(), tr = tmp();
        out_ << "  " << sh << " = lshr i64 " << v64 << ", 8\n";
        out_ << "  " << tr << " = trunc i64 " << sh << " to i8\n";
        return tr;
    }
    std::string tr = tmp();
    out_ << "  " << tr << " = trunc i64 " << v64 << " to " << int_ty(bits) << "\n";
    return tr;
}

void IREmitter::write_reg(ZydisRegister reg, int bits, const std::string &val) {
    int rbits = 0; bool high8 = false;
    int idx = zydis_gpr_index(reg, rbits, high8);
    if (idx < 0) return;
    if (bits == 64) {
        store_gpr64(idx, val);
    } else if (bits == 32) {
        // x86_64 rule: 32-bit GPR write ALWAYS zero-extends to 64 bits
        std::string z = tmp();
        out_ << "  " << z << " = zext i32 " << val << " to i64\n";
        store_gpr64(idx, z);
    } else if (bits == 16) {
        std::string old = load_gpr64(idx);
        std::string m = tmp(), z = tmp(), o = tmp();
        out_ << "  " << m << " = and i64 " << old << ", -65536\n";
        out_ << "  " << z << " = zext i16 " << val << " to i64\n";
        out_ << "  " << o << " = or i64 " << m << ", " << z << "\n";
        store_gpr64(idx, o);
    } else if (bits == 8) {
        std::string old = load_gpr64(idx);
        if (high8) {
            std::string m = tmp(), z = tmp(), sh = tmp(), o = tmp();
            out_ << "  " << m << " = and i64 " << old << ", -65281\n";
            out_ << "  " << z << " = zext i8 " << val << " to i64\n";
            out_ << "  " << sh << " = shl i64 " << z << ", 8\n";
            out_ << "  " << o << " = or i64 " << m << ", " << sh << "\n";
            store_gpr64(idx, o);
        } else {
            std::string m = tmp(), z = tmp(), o = tmp();
            out_ << "  " << m << " = and i64 " << old << ", -256\n";
            out_ << "  " << z << " = zext i8 " << val << " to i64\n";
            out_ << "  " << o << " = or i64 " << m << ", " << z << "\n";
            store_gpr64(idx, o);
        }
    }
}

std::string IREmitter::load_xmm(int idx) {
    std::string r = tmp();
    out_ << "  " << r << " = load <2 x i64>, ptr %r_xmm" << idx << "\n";
    return r;
}

void IREmitter::store_xmm(int idx, const std::string &v2i64) {
    out_ << "  store <2 x i64> " << v2i64 << ", ptr %r_xmm" << idx << "\n";
}

std::string IREmitter::calc_mem_addr(const DecodedInsn &di, const ZydisDecodedOperand &op, bool &is_stack, bool &is_ro, int access_bytes) {
    is_stack = false;
    is_ro = false;
    const auto &m = op.mem;

    // Trap explicitly on unsupported FS/GS segment overrides
    if (m.segment == ZYDIS_REGISTER_FS || m.segment == ZYDIS_REGISTER_GS) {
        out_ << "  call void @bo3_trap(i64 " << di.va << ", i64 5, ptr %ctx)\n";
    }

    if (m.base == ZYDIS_REGISTER_RIP || m.base == ZYDIS_REGISTER_EIP) {
        uint64_t ea = di.va + di.ins.length + (uint64_t)(int64_t)m.disp.value;
        if (di.ins.address_width == 32) ea &= 0xffffffffULL;
        is_ro = (img_ && img_->is_ro_range(ea, (uint64_t)access_bytes));
        return std::to_string(ea);
    }

    std::string acc = "0";
    bool has_acc = false;

    if (m.base != ZYDIS_REGISTER_NONE) {
        int b = 0; bool h8 = false;
        int bi = zydis_gpr_index(m.base, b, h8);
        // Only treat stack accesses as thread-private when stack does NOT escape this function
        // AND for rbp, ONLY when prologue actually sets up push rbp; mov rbp, rsp!
        if (cur_cfg_ && !cur_cfg_->stack_escapes) {
            if (bi == 4) is_stack = true;
            else if (bi == 5 && cur_cfg_->has_frame_pointer) is_stack = true;
        }
        if (b == 64) {
            acc = load_gpr64(bi);
        } else {
            std::string v32 = read_reg(m.base, 32);
            acc = tmp();
            out_ << "  " << acc << " = zext i32 " << v32 << " to i64\n";
        }
        has_acc = true;
    }

    if (m.index != ZYDIS_REGISTER_NONE) {
        int b = 0; bool h8 = false;
        int ii = zydis_gpr_index(m.index, b, h8);
        std::string iv;
        if (b == 64) {
            iv = load_gpr64(ii);
        } else {
            std::string v32 = read_reg(m.index, 32);
            iv = tmp();
            out_ << "  " << iv << " = zext i32 " << v32 << " to i64\n";
        }
        if (m.scale > 1) {
            int sh = (m.scale == 2) ? 1 : (m.scale == 4) ? 2 : 3;
            std::string s = tmp();
            out_ << "  " << s << " = shl i64 " << iv << ", " << sh << "\n";
            iv = s;
        }
        if (has_acc) {
            std::string s = tmp();
            out_ << "  " << s << " = add i64 " << acc << ", " << iv << "\n";
            acc = s;
        } else {
            acc = iv;
            has_acc = true;
        }
    }

    if (m.disp.has_displacement && m.disp.value != 0) {
        if (has_acc) {
            std::string s = tmp();
            out_ << "  " << s << " = add i64 " << acc << ", " << (int64_t)m.disp.value << "\n";
            acc = s;
        } else {
            acc = std::to_string((uint64_t)(int64_t)m.disp.value);
            has_acc = true;
        }
    }

    // Honor 0x67 32-bit address-size override
    if (di.ins.address_width == 32) {
        std::string w = tmp();
        out_ << "  " << w << " = and i64 " << acc << ", 4294967295\n";
        acc = w;
    }
    return acc;
}

std::string IREmitter::emit_mem_load(const std::string &addr64, int bits, bool is_stack, bool is_ro, bool is_vec) {
    std::string p = tmp(), v = tmp();
    out_ << "  " << p << " = inttoptr i64 " << addr64 << " to ptr\n";
    if (opts_.tso == TsoMode::Strict && !is_stack && !is_ro && !is_vec) {
        if (bits == 8) {
            out_ << "  " << v << " = load atomic i8, ptr " << p << " acquire, align 1\n";
        } else {
            out_ << "  " << v << " = load volatile " << int_ty(bits) << ", ptr " << p << ", align 1\n";
            out_ << "  fence acquire\n";
        }
    } else {
        out_ << "  " << v << " = load " << int_ty(bits) << ", ptr " << p << ", align 1\n";
    }
    return v;
}

void IREmitter::emit_mem_store(const std::string &addr64, int bits, const std::string &val, bool is_stack, bool is_vec) {
    std::string p = tmp();
    out_ << "  " << p << " = inttoptr i64 " << addr64 << " to ptr\n";
    if (opts_.tso == TsoMode::Strict && !is_stack && !is_vec) {
        if (bits == 8) {
            out_ << "  store atomic i8 " << val << ", ptr " << p << " release, align 1\n";
        } else {
            out_ << "  fence release\n";
            out_ << "  store volatile " << int_ty(bits) << " " << val << ", ptr " << p << ", align 1\n";
        }
    } else {
        out_ << "  store " << int_ty(bits) << " " << val << ", ptr " << p << ", align 1\n";
    }
}

std::string IREmitter::emit_mem_load_vec128(const std::string &addr64) {
    std::string p = tmp(), v = tmp();
    out_ << "  " << p << " = inttoptr i64 " << addr64 << " to ptr\n";
    out_ << "  " << v << " = load <2 x i64>, ptr " << p << ", align 1\n";
    return v;
}

void IREmitter::emit_mem_store_vec128(const std::string &addr64, const std::string &v2i64) {
    std::string p = tmp();
    out_ << "  " << p << " = inttoptr i64 " << addr64 << " to ptr\n";
    out_ << "  store <2 x i64> " << v2i64 << ", ptr " << p << ", align 1\n";
}

std::string IREmitter::read_op(const DecodedInsn &di, int op_idx, int bits) {
    const auto &op = di.ops[op_idx];
    if (op.type == ZYDIS_OPERAND_TYPE_REGISTER) {
        return read_reg(op.reg.value, bits, di.va + di.ins.length);
    } else if (op.type == ZYDIS_OPERAND_TYPE_IMMEDIATE) {
        int64_t val = op.imm.is_signed ? op.imm.value.s : (int64_t)op.imm.value.u;
        uint64_t mask = (bits == 64) ? ~0ULL : ((1ULL << bits) - 1ULL);
        return std::to_string((int64_t)(val & mask));
    } else if (op.type == ZYDIS_OPERAND_TYPE_MEMORY) {
        bool is_stack = false, is_ro = false;
        std::string ea = calc_mem_addr(di, op, is_stack, is_ro, bits / 8);
        return emit_mem_load(ea, bits, is_stack, is_ro, false);
    }
    return "0";
}

void IREmitter::write_op(const DecodedInsn &di, int op_idx, int bits, const std::string &val) {
    const auto &op = di.ops[op_idx];
    if (op.type == ZYDIS_OPERAND_TYPE_REGISTER) {
        write_reg(op.reg.value, bits, val);
    } else if (op.type == ZYDIS_OPERAND_TYPE_MEMORY) {
        bool is_stack = false, is_ro = false;
        std::string ea = calc_mem_addr(di, op, is_stack, is_ro, bits / 8);
        emit_mem_store(ea, bits, val, is_stack, false);
    }
}

std::string IREmitter::read_xmm_op(const DecodedInsn &di, int op_idx, int mem_bits) {
    const auto &op = di.ops[op_idx];
    if (op.type == ZYDIS_OPERAND_TYPE_REGISTER) {
        int xi = zydis_xmm_index(op.reg.value);
        if (xi >= 0) return load_xmm(xi);
        std::string g = read_reg(op.reg.value, mem_bits);
        std::string z = (mem_bits == 64) ? g : tmp();
        if (mem_bits != 64) out_ << "  " << z << " = zext " << int_ty(mem_bits) << " " << g << " to i64\n";
        std::string v = tmp();
        out_ << "  " << v << " = insertelement <2 x i64> zeroinitializer, i64 " << z << ", i32 0\n";
        return v;
    } else if (op.type == ZYDIS_OPERAND_TYPE_MEMORY) {
        bool is_stack = false, is_ro = false;
        std::string ea = calc_mem_addr(di, op, is_stack, is_ro, mem_bits / 8);
        if (mem_bits == 128) {
            return emit_mem_load_vec128(ea);
        } else if (mem_bits == 64) {
            // Scalar 64-bit SSE load (movsd/movq): obey TSO (is_vec = false) so atomic<double> is ordered!
            std::string lo = emit_mem_load(ea, 64, is_stack, is_ro, false);
            std::string v = tmp();
            out_ << "  " << v << " = insertelement <2 x i64> zeroinitializer, i64 " << lo << ", i32 0\n";
            return v;
        } else if (mem_bits == 32) {
            // Scalar 32-bit SSE load (movss/movd): obey TSO (is_vec = false) so atomic<float> is ordered!
            std::string lo32 = emit_mem_load(ea, 32, is_stack, is_ro, false);
            std::string lo64 = tmp(), v = tmp();
            out_ << "  " << lo64 << " = zext i32 " << lo32 << " to i64\n";
            out_ << "  " << v << " = insertelement <2 x i64> zeroinitializer, i64 " << lo64 << ", i32 0\n";
            return v;
        } else if (mem_bits == 16) {
            std::string lo16 = emit_mem_load(ea, 16, is_stack, is_ro, false);
            std::string lo64 = tmp(), v = tmp();
            out_ << "  " << lo64 << " = zext i16 " << lo16 << " to i64\n";
            out_ << "  " << v << " = insertelement <2 x i64> zeroinitializer, i64 " << lo64 << ", i32 0\n";
            return v;
        }
    }
    return "zeroinitializer";
}

void IREmitter::write_xmm_op(const DecodedInsn &di, int op_idx, const std::string &v2i64, int mem_bits) {
    const auto &op = di.ops[op_idx];
    if (op.type == ZYDIS_OPERAND_TYPE_REGISTER) {
        int xi = zydis_xmm_index(op.reg.value);
        if (xi >= 0) {
            store_xmm(xi, v2i64);
        } else {
            std::string lo = tmp();
            out_ << "  " << lo << " = extractelement <2 x i64> " << v2i64 << ", i32 0\n";
            if (mem_bits == 64) {
                write_reg(op.reg.value, 64, lo);
            } else {
                std::string tr = tmp();
                out_ << "  " << tr << " = trunc i64 " << lo << " to " << int_ty(mem_bits) << "\n";
                write_reg(op.reg.value, mem_bits, tr);
            }
        }
    } else if (op.type == ZYDIS_OPERAND_TYPE_MEMORY) {
        bool is_stack = false, is_ro = false;
        std::string ea = calc_mem_addr(di, op, is_stack, is_ro, mem_bits / 8);
        if (mem_bits == 128) {
            emit_mem_store_vec128(ea, v2i64);
        } else if (mem_bits == 64) {
            std::string lo = tmp();
            out_ << "  " << lo << " = extractelement <2 x i64> " << v2i64 << ", i32 0\n";
            emit_mem_store(ea, 64, lo, is_stack, false);
        } else if (mem_bits == 32) {
            std::string lo = tmp(), tr = tmp();
            out_ << "  " << lo << " = extractelement <2 x i64> " << v2i64 << ", i32 0\n";
            out_ << "  " << tr << " = trunc i64 " << lo << " to i32\n";
            emit_mem_store(ea, 32, tr, is_stack, false);
        }
    }
}

std::string IREmitter::load_flag(const char *name) {
    std::string r = tmp();
    out_ << "  " << r << " = load i1, ptr %fl_" << name << "\n";
    return r;
}

void IREmitter::store_flag(const char *name, const std::string &i1_val) {
    out_ << "  store i1 " << i1_val << ", ptr %fl_" << name << "\n";
}

void IREmitter::emit_szp_flags(const std::string &res, int bits, uint32_t live) {
    std::string ty = int_ty(bits);
    if (live & FL_ZF) {
        std::string z = tmp();
        out_ << "  " << z << " = icmp eq " << ty << " " << res << ", 0\n";
        store_flag("zf", z);
    }
    if (live & FL_SF) {
        std::string s = tmp();
        out_ << "  " << s << " = icmp slt " << ty << " " << res << ", 0\n";
        store_flag("sf", s);
    }
    if (live & FL_PF) {
        need_intrinsic("declare i8 @llvm.ctpop.i8(i8)");
        std::string b = res;
        if (bits > 8) {
            b = tmp();
            out_ << "  " << b << " = trunc " << ty << " " << res << " to i8\n";
        }
        std::string pc = tmp(), lb = tmp(), pf = tmp();
        out_ << "  " << pc << " = call i8 @llvm.ctpop.i8(i8 " << b << ")\n";
        out_ << "  " << lb << " = and i8 " << pc << ", 1\n";
        out_ << "  " << pf << " = icmp eq i8 " << lb << ", 0\n";
        store_flag("pf", pf);
    }
}

void IREmitter::emit_add_flags(const std::string &a, const std::string &b, const std::string &res, int bits, uint32_t live) {
    std::string ty = int_ty(bits);
    emit_szp_flags(res, bits, live);
    if (live & FL_CF) {
        std::string cf = tmp();
        out_ << "  " << cf << " = icmp ult " << ty << " " << res << ", " << a << "\n";
        store_flag("cf", cf);
    }
    if (live & FL_OF) {
        std::string x1 = tmp(), x2 = tmp(), a1 = tmp(), of = tmp();
        out_ << "  " << x1 << " = xor " << ty << " " << res << ", " << a << "\n";
        out_ << "  " << x2 << " = xor " << ty << " " << res << ", " << b << "\n";
        out_ << "  " << a1 << " = and " << ty << " " << x1 << ", " << x2 << "\n";
        out_ << "  " << of << " = icmp slt " << ty << " " << a1 << ", 0\n";
        store_flag("of", of);
    }
    if (live & FL_AF) {
        std::string x1 = tmp(), x2 = tmp(), m = tmp(), af = tmp();
        out_ << "  " << x1 << " = xor " << ty << " " << a << ", " << b << "\n";
        out_ << "  " << x2 << " = xor " << ty << " " << x1 << ", " << res << "\n";
        out_ << "  " << m << " = and " << ty << " " << x2 << ", 16\n";
        out_ << "  " << af << " = icmp ne " << ty << " " << m << ", 0\n";
        store_flag("af", af);
    }
}

void IREmitter::emit_sub_flags(const std::string &a, const std::string &b, const std::string &res, int bits, uint32_t live) {
    std::string ty = int_ty(bits);
    emit_szp_flags(res, bits, live);
    if (live & FL_CF) {
        std::string cf = tmp();
        out_ << "  " << cf << " = icmp ult " << ty << " " << a << ", " << b << "\n";
        store_flag("cf", cf);
    }
    if (live & FL_OF) {
        std::string x1 = tmp(), x2 = tmp(), a1 = tmp(), of = tmp();
        out_ << "  " << x1 << " = xor " << ty << " " << a << ", " << b << "\n";
        out_ << "  " << x2 << " = xor " << ty << " " << a << ", " << res << "\n";
        out_ << "  " << a1 << " = and " << ty << " " << x1 << ", " << x2 << "\n";
        out_ << "  " << of << " = icmp slt " << ty << " " << a1 << ", 0\n";
        store_flag("of", of);
    }
    if (live & FL_AF) {
        std::string x1 = tmp(), x2 = tmp(), m = tmp(), af = tmp();
        out_ << "  " << x1 << " = xor " << ty << " " << a << ", " << b << "\n";
        out_ << "  " << x2 << " = xor " << ty << " " << x1 << ", " << res << "\n";
        out_ << "  " << m << " = and " << ty << " " << x2 << ", 16\n";
        out_ << "  " << af << " = icmp ne " << ty << " " << m << ", 0\n";
        store_flag("af", af);
    }
}

void IREmitter::emit_adc_flags(const std::string &a, const std::string &b, const std::string &cin_i1, const std::string &res, int bits, uint32_t live) {
    std::string ty = int_ty(bits);
    emit_szp_flags(res, bits, live);
    if (live & FL_CF) {
        std::string wty = int_ty(bits + 8);
        std::string za = tmp(), zb = tmp(), zc = tmp(), s1 = tmp(), s2 = tmp(), sh = tmp(), cf = tmp();
        out_ << "  " << za << " = zext " << ty << " " << a << " to " << wty << "\n";
        out_ << "  " << zb << " = zext " << ty << " " << b << " to " << wty << "\n";
        out_ << "  " << zc << " = zext i1 " << cin_i1 << " to " << wty << "\n";
        out_ << "  " << s1 << " = add " << wty << " " << za << ", " << zb << "\n";
        out_ << "  " << s2 << " = add " << wty << " " << s1 << ", " << zc << "\n";
        out_ << "  " << sh << " = lshr " << wty << " " << s2 << ", " << bits << "\n";
        out_ << "  " << cf << " = icmp ne " << wty << " " << sh << ", 0\n";
        store_flag("cf", cf);
    }
    if (live & FL_OF) {
        std::string x1 = tmp(), x2 = tmp(), a1 = tmp(), of = tmp();
        out_ << "  " << x1 << " = xor " << ty << " " << res << ", " << a << "\n";
        out_ << "  " << x2 << " = xor " << ty << " " << res << ", " << b << "\n";
        out_ << "  " << a1 << " = and " << ty << " " << x1 << ", " << x2 << "\n";
        out_ << "  " << of << " = icmp slt " << ty << " " << a1 << ", 0\n";
        store_flag("of", of);
    }
    if (live & FL_AF) {
        std::string x1 = tmp(), x2 = tmp(), m = tmp(), af = tmp();
        out_ << "  " << x1 << " = xor " << ty << " " << a << ", " << b << "\n";
        out_ << "  " << x2 << " = xor " << ty << " " << x1 << ", " << res << "\n";
        out_ << "  " << m << " = and " << ty << " " << x2 << ", 16\n";
        out_ << "  " << af << " = icmp ne " << ty << " " << m << ", 0\n";
        store_flag("af", af);
    }
}

void IREmitter::emit_sbb_flags(const std::string &a, const std::string &b, const std::string &cin_i1, const std::string &res, int bits, uint32_t live) {
    std::string ty = int_ty(bits);
    emit_szp_flags(res, bits, live);
    if (live & FL_CF) {
        std::string wty = int_ty(bits + 8);
        std::string za = tmp(), zb = tmp(), zc = tmp(), sb = tmp(), cf = tmp();
        out_ << "  " << za << " = zext " << ty << " " << a << " to " << wty << "\n";
        out_ << "  " << zb << " = zext " << ty << " " << b << " to " << wty << "\n";
        out_ << "  " << zc << " = zext i1 " << cin_i1 << " to " << wty << "\n";
        out_ << "  " << sb << " = add " << wty << " " << zb << ", " << zc << "\n";
        out_ << "  " << cf << " = icmp ult " << wty << " " << za << ", " << sb << "\n";
        store_flag("cf", cf);
    }
    if (live & FL_OF) {
        std::string x1 = tmp(), x2 = tmp(), a1 = tmp(), of = tmp();
        out_ << "  " << x1 << " = xor " << ty << " " << a << ", " << b << "\n";
        out_ << "  " << x2 << " = xor " << ty << " " << a << ", " << res << "\n";
        out_ << "  " << a1 << " = and " << ty << " " << x1 << ", " << x2 << "\n";
        out_ << "  " << of << " = icmp slt " << ty << " " << a1 << ", 0\n";
        store_flag("of", of);
    }
    if (live & FL_AF) {
        std::string x1 = tmp(), x2 = tmp(), m = tmp(), af = tmp();
        out_ << "  " << x1 << " = xor " << ty << " " << a << ", " << b << "\n";
        out_ << "  " << x2 << " = xor " << ty << " " << x1 << ", " << res << "\n";
        out_ << "  " << m << " = and " << ty << " " << x2 << ", 16\n";
        out_ << "  " << af << " = icmp ne " << ty << " " << m << ", 0\n";
        store_flag("af", af);
    }
}

void IREmitter::emit_logic_flags(const std::string &res, int bits, uint32_t live) {
    emit_szp_flags(res, bits, live);
    if (live & FL_CF) store_flag("cf", "false");
    if (live & FL_OF) store_flag("of", "false");
}

std::string IREmitter::eval_cc(ZydisMnemonic mn) {
    auto neg = [&](const std::string &c) {
        std::string r = tmp();
        out_ << "  " << r << " = xor i1 " << c << ", true\n";
        return r;
    };
    switch (mn) {
        case ZYDIS_MNEMONIC_JZ:  case ZYDIS_MNEMONIC_CMOVZ:  case ZYDIS_MNEMONIC_SETZ:
            return load_flag("zf");
        case ZYDIS_MNEMONIC_JNZ: case ZYDIS_MNEMONIC_CMOVNZ: case ZYDIS_MNEMONIC_SETNZ:
            return neg(load_flag("zf"));
        case ZYDIS_MNEMONIC_JB:  case ZYDIS_MNEMONIC_CMOVB:  case ZYDIS_MNEMONIC_SETB:
            return load_flag("cf");
        case ZYDIS_MNEMONIC_JNB: case ZYDIS_MNEMONIC_CMOVNB: case ZYDIS_MNEMONIC_SETNB:
            return neg(load_flag("cf"));
        case ZYDIS_MNEMONIC_JBE: case ZYDIS_MNEMONIC_CMOVBE: case ZYDIS_MNEMONIC_SETBE: {
            std::string cf = load_flag("cf"), zf = load_flag("zf"), r = tmp();
            out_ << "  " << r << " = or i1 " << cf << ", " << zf << "\n";
            return r;
        }
        case ZYDIS_MNEMONIC_JNBE: case ZYDIS_MNEMONIC_CMOVNBE: case ZYDIS_MNEMONIC_SETNBE: {
            std::string cf = load_flag("cf"), zf = load_flag("zf"), o = tmp();
            out_ << "  " << o << " = or i1 " << cf << ", " << zf << "\n";
            return neg(o);
        }
        case ZYDIS_MNEMONIC_JS:  case ZYDIS_MNEMONIC_CMOVS:  case ZYDIS_MNEMONIC_SETS:
            return load_flag("sf");
        case ZYDIS_MNEMONIC_JNS: case ZYDIS_MNEMONIC_CMOVNS: case ZYDIS_MNEMONIC_SETNS:
            return neg(load_flag("sf"));
        case ZYDIS_MNEMONIC_JO:  case ZYDIS_MNEMONIC_CMOVO:  case ZYDIS_MNEMONIC_SETO:
            return load_flag("of");
        case ZYDIS_MNEMONIC_JNO: case ZYDIS_MNEMONIC_CMOVNO: case ZYDIS_MNEMONIC_SETNO:
            return neg(load_flag("of"));
        case ZYDIS_MNEMONIC_JP:  case ZYDIS_MNEMONIC_CMOVP:  case ZYDIS_MNEMONIC_SETP:
            return load_flag("pf");
        case ZYDIS_MNEMONIC_JNP: case ZYDIS_MNEMONIC_CMOVNP: case ZYDIS_MNEMONIC_SETNP:
            return neg(load_flag("pf"));
        case ZYDIS_MNEMONIC_JL:  case ZYDIS_MNEMONIC_CMOVL:  case ZYDIS_MNEMONIC_SETL: {
            std::string sf = load_flag("sf"), of = load_flag("of"), r = tmp();
            out_ << "  " << r << " = xor i1 " << sf << ", " << of << "\n";
            return r;
        }
        case ZYDIS_MNEMONIC_JNL: case ZYDIS_MNEMONIC_CMOVNL: case ZYDIS_MNEMONIC_SETNL: {
            std::string sf = load_flag("sf"), of = load_flag("of"), r = tmp();
            out_ << "  " << r << " = icmp eq i1 " << sf << ", " << of << "\n";
            return r;
        }
        case ZYDIS_MNEMONIC_JLE: case ZYDIS_MNEMONIC_CMOVLE: case ZYDIS_MNEMONIC_SETLE: {
            std::string zf = load_flag("zf"), sf = load_flag("sf"), of = load_flag("of");
            std::string x = tmp(), r = tmp();
            out_ << "  " << x << " = xor i1 " << sf << ", " << of << "\n";
            out_ << "  " << r << " = or i1 " << zf << ", " << x << "\n";
            return r;
        }
        case ZYDIS_MNEMONIC_JNLE: case ZYDIS_MNEMONIC_CMOVNLE: case ZYDIS_MNEMONIC_SETNLE: {
            std::string zf = load_flag("zf"), sf = load_flag("sf"), of = load_flag("of");
            std::string x = tmp(), o = tmp();
            out_ << "  " << x << " = xor i1 " << sf << ", " << of << "\n";
            out_ << "  " << o << " = or i1 " << zf << ", " << x << "\n";
            return neg(o);
        }
        default:
            return "false";
    }
}

bool IREmitter::implicit_stack_private(bool require_fp) const {
    if (!cur_cfg_ || cur_cfg_->stack_escapes) return false;
    if (require_fp && !cur_cfg_->has_frame_pointer) return false;
    return true;
}

void IREmitter::emit_push64(const std::string &val64) {
    std::string sp = load_gpr64(4);
    std::string nsp = tmp();
    out_ << "  " << nsp << " = sub i64 " << sp << ", 8\n";
    store_gpr64(4, nsp);
    // Treat the implicit stack slot as thread-private only when the function's stack does not
    // escape and RSP provenance is preserved; otherwise retain strict TSO ordering.
    emit_mem_store(nsp, 64, val64, implicit_stack_private(false), false);
}

std::string IREmitter::emit_pop64(bool require_fp) {
    std::string sp = load_gpr64(4);
    std::string v = emit_mem_load(sp, 64, implicit_stack_private(require_fp), false, false);
    std::string nsp = tmp();
    out_ << "  " << nsp << " = add i64 " << sp << ", 8\n";
    store_gpr64(4, nsp);
    return v;
}

void IREmitter::emit_spill_fullstate() {
    for (int i = 0; i < 16; i++) {
        std::string gp = tmp(), v = load_gpr64(i);
        out_ << "  " << gp << " = getelementptr inbounds i64, ptr %ctx, i64 " << i << "\n";
        out_ << "  store i64 " << v << ", ptr " << gp << "\n";
    }
    for (int i = 0; i < 16; i++) {
        std::string xp = tmp(), v = load_xmm(i);
        out_ << "  " << xp << " = getelementptr inbounds i8, ptr %ctx, i64 " << (0x80 + i * 16) << "\n";
        out_ << "  store <2 x i64> " << v << ", ptr " << xp << "\n";
    }
    auto pack_bit = [&](const std::string &acc, const char *name, int bit) {
        std::string b = load_flag(name), z = tmp(), sh = tmp(), o = tmp();
        out_ << "  " << z << " = zext i1 " << b << " to i64\n";
        out_ << "  " << sh << " = shl i64 " << z << ", " << bit << "\n";
        out_ << "  " << o << " = or i64 " << acc << ", " << sh << "\n";
        return o;
    };
    std::string rf = "2";
    rf = pack_bit(rf, "cf", 0);
    rf = pack_bit(rf, "pf", 2);
    rf = pack_bit(rf, "af", 4);
    rf = pack_bit(rf, "zf", 6);
    rf = pack_bit(rf, "sf", 7);
    rf = pack_bit(rf, "df", 10);
    rf = pack_bit(rf, "of", 11);
    std::string fp = tmp();
    out_ << "  " << fp << " = getelementptr inbounds i8, ptr %ctx, i64 384\n";
    out_ << "  store i64 " << rf << ", ptr " << fp << "\n";
}

void IREmitter::emit_reload_fullstate() {
    for (int i = 0; i < 16; i++) {
        std::string gp = tmp(), gv = tmp();
        out_ << "  " << gp << " = getelementptr inbounds i64, ptr %ctx, i64 " << i << "\n";
        out_ << "  " << gv << " = load i64, ptr " << gp << "\n";
        store_gpr64(i, gv);
    }
    for (int i = 0; i < 16; i++) {
        std::string xp = tmp(), xv = tmp();
        out_ << "  " << xp << " = getelementptr inbounds i8, ptr %ctx, i64 " << (0x80 + i * 16) << "\n";
        out_ << "  " << xv << " = load <2 x i64>, ptr " << xp << "\n";
        store_xmm(i, xv);
    }
    std::string fp = tmp(), rf = tmp();
    out_ << "  " << fp << " = getelementptr inbounds i8, ptr %ctx, i64 384\n";
    out_ << "  " << rf << " = load i64, ptr " << fp << "\n";
    auto load_fl_bit = [&](const char *name, int bit) {
        std::string sh = tmp(), b = tmp();
        out_ << "  " << sh << " = lshr i64 " << rf << ", " << bit << "\n";
        out_ << "  " << b << " = trunc i64 " << sh << " to i1\n";
        store_flag(name, b);
    };
    load_fl_bit("cf", 0); load_fl_bit("pf", 2); load_fl_bit("af", 4);
    load_fl_bit("zf", 6); load_fl_bit("sf", 7); load_fl_bit("df", 10); load_fl_bit("of", 11);
}

void IREmitter::emit_guest_call(const std::string &callee_sym, uint64_t ret_va, bool is_tail, bool returns_twice) {
    if (!is_tail) {
        emit_push64(std::to_string(ret_va));
    }

    if (opts_.cc == CallConv::FullState) {
        emit_spill_fullstate();
        if (is_tail) {
            out_ << "  musttail call void " << callee_sym << "(ptr %ctx)\n";
            out_ << "  ret void\n";
            return;
        }
        out_ << "  call void " << callee_sym << "(ptr %ctx)" << (returns_twice ? " returns_twice" : "") << "\n";
        emit_reload_fullstate();
        return;
    }

    // Preserve RAX (AL = XMM arg count for SysV variadic functions) in ctx->gpr[0]
    std::string rax_out = load_gpr64(0);
    out_ << "  store i64 " << rax_out << ", ptr %ctx\n";

    std::string rsp = load_gpr64(4);
    std::string rdi = load_gpr64(7), rsi = load_gpr64(6), rdx = load_gpr64(2);
    std::string rcx = load_gpr64(1), r8  = load_gpr64(8), r9  = load_gpr64(9);
    std::string x[8];
    for (int i = 0; i < 8; i++) x[i] = load_xmm(i);

    std::string res = tmp();
    if (is_tail && !returns_twice) {
        out_ << "  " << res << " = musttail call %ret_t " << callee_sym
             << "(ptr %ctx, i64 " << rsp << ", i64 " << rdi << ", i64 " << rsi
             << ", i64 " << rdx << ", i64 " << rcx << ", i64 " << r8 << ", i64 " << r9;
        for (int i = 0; i < 8; i++) out_ << ", <2 x i64> " << x[i];
        out_ << ")\n";
        out_ << "  ret %ret_t " << res << "\n";
        return;
    }

    out_ << "  " << res << " = call %ret_t " << callee_sym
         << "(ptr %ctx, i64 " << rsp << ", i64 " << rdi << ", i64 " << rsi
         << ", i64 " << rdx << ", i64 " << rcx << ", i64 " << r8 << ", i64 " << r9;
    for (int i = 0; i < 8; i++) out_ << ", <2 x i64> " << x[i];
    out_ << ")" << (returns_twice ? " returns_twice" : "") << "\n";

    if (is_tail) {
        out_ << "  ret %ret_t " << res << "\n";
        return;
    }

    // Callee's `ret` popped the return PC (8 bytes) on x86_64
    std::string rsp_after = tmp();
    out_ << "  " << rsp_after << " = add i64 " << rsp << ", 8\n";
    store_gpr64(4, rsp_after);

    // Unpack 3-vector HVA: { <2 x i64> rax_rdx, <2 x i64> xmm0, <2 x i64> xmm1 }
    std::string rr = tmp(), rax_v = tmp(), rdx_v = tmp(), x0_v = tmp(), x1_v = tmp();
    out_ << "  " << rr    << " = extractvalue %ret_t " << res << ", 0\n";
    out_ << "  " << rax_v << " = extractelement <2 x i64> " << rr << ", i32 0\n";
    out_ << "  " << rdx_v << " = extractelement <2 x i64> " << rr << ", i32 1\n";
    out_ << "  " << x0_v  << " = extractvalue %ret_t " << res << ", 1\n";
    out_ << "  " << x1_v  << " = extractvalue %ret_t " << res << ", 2\n";
    store_gpr64(0, rax_v);
    store_gpr64(2, rdx_v);
    store_xmm(0, x0_v);
    store_xmm(1, x1_v);
}

void IREmitter::emit_indirect_call(const std::string &target_va_val, uint64_t ret_va, bool is_tail) {
    if (!is_tail) {
        emit_push64(std::to_string(ret_va));
    }

    // Resolve guest VA -> lifted GuestFn ptr; enables true `musttail` on indirect tail jumps (0 stack growth!)
    std::string fn_ptr = tmp();
    out_ << "  " << fn_ptr << " = call ptr @bo3_resolve(i64 " << target_va_val << ", ptr %ctx)\n";

    if (opts_.cc == CallConv::FullState) {
        emit_spill_fullstate();
        if (is_tail) {
            out_ << "  musttail call void " << fn_ptr << "(ptr %ctx)\n";
            out_ << "  ret void\n";
            return;
        }
        out_ << "  call void " << fn_ptr << "(ptr %ctx)\n";
        emit_reload_fullstate();
        return;
    }

    std::string rax_out = load_gpr64(0);
    out_ << "  store i64 " << rax_out << ", ptr %ctx\n";

    std::string rsp = load_gpr64(4);
    std::string rdi = load_gpr64(7), rsi = load_gpr64(6), rdx = load_gpr64(2);
    std::string rcx = load_gpr64(1), r8  = load_gpr64(8), r9  = load_gpr64(9);
    std::string x[8];
    for (int i = 0; i < 8; i++) x[i] = load_xmm(i);

    std::string res = tmp();
    if (is_tail) {
        out_ << "  " << res << " = musttail call %ret_t " << fn_ptr
             << "(ptr %ctx, i64 " << rsp << ", i64 " << rdi << ", i64 " << rsi
             << ", i64 " << rdx << ", i64 " << rcx << ", i64 " << r8 << ", i64 " << r9;
        for (int i = 0; i < 8; i++) out_ << ", <2 x i64> " << x[i];
        out_ << ")\n";
        out_ << "  ret %ret_t " << res << "\n";
        return;
    }

    out_ << "  " << res << " = call %ret_t " << fn_ptr
         << "(ptr %ctx, i64 " << rsp << ", i64 " << rdi << ", i64 " << rsi
         << ", i64 " << rdx << ", i64 " << rcx << ", i64 " << r8 << ", i64 " << r9;
    for (int i = 0; i < 8; i++) out_ << ", <2 x i64> " << x[i];
    out_ << ")\n";

    std::string rsp_after = tmp();
    out_ << "  " << rsp_after << " = add i64 " << rsp << ", 8\n";
    store_gpr64(4, rsp_after);

    std::string rr = tmp(), rax_v = tmp(), rdx_v = tmp(), x0_v = tmp(), x1_v = tmp();
    out_ << "  " << rr    << " = extractvalue %ret_t " << res << ", 0\n";
    out_ << "  " << rax_v << " = extractelement <2 x i64> " << rr << ", i32 0\n";
    out_ << "  " << rdx_v << " = extractelement <2 x i64> " << rr << ", i32 1\n";
    out_ << "  " << x0_v  << " = extractvalue %ret_t " << res << ", 1\n";
    out_ << "  " << x1_v  << " = extractvalue %ret_t " << res << ", 2\n";
    store_gpr64(0, rax_v);
    store_gpr64(2, rdx_v);
    store_xmm(0, x0_v);
    store_xmm(1, x1_v);
}

bool IREmitter::emit_function(const FunctionCFG &cfg, std::ostream &os, const std::string &override_name) {
    out_.str("");
    out_.clear();
    next_id_ = 1;
    cur_func_va_ = cfg.start_va;
    cur_cfg_ = &cfg;

    std::string fname = override_name.empty() ? func_symbol(cfg.start_va) : ("@" + override_name);
    if (opts_.cc == CallConv::SupersetSysV) {
        out_ << "define %ret_t " << fname
             << "(ptr %ctx, i64 %rsp_in, i64 %rdi_in, i64 %rsi_in, i64 %rdx_in, i64 %rcx_in, i64 %r8_in, i64 %r9_in, "
                "<2 x i64> %xmm0_in, <2 x i64> %xmm1_in, <2 x i64> %xmm2_in, <2 x i64> %xmm3_in, "
                "<2 x i64> %xmm4_in, <2 x i64> %xmm5_in, <2 x i64> %xmm6_in, <2 x i64> %xmm7_in) #0 {\n";
    } else {
        out_ << "define void " << fname << "(ptr %ctx) #0 {\n";
    }

    out_ << "entry:\n";
    for (int i = 0; i < 16; i++) out_ << "  %r_" << kGprNames[i] << " = alloca i64\n";
    for (int i = 0; i < 16; i++) out_ << "  %r_xmm" << i << " = alloca <2 x i64>\n";
    for (const char *fl : {"cf", "pf", "af", "zf", "sf", "of", "df"}) {
        out_ << "  %fl_" << fl << " = alloca i1\n";
    }
    // Hoisted CPUID scratch allocas (prevents host stack growth if CPUID runs in a loop)
    out_ << "  %cpuid_a = alloca i32\n";
    out_ << "  %cpuid_b = alloca i32\n";
    out_ << "  %cpuid_c = alloca i32\n";
    out_ << "  %cpuid_d = alloca i32\n";

    if (opts_.cc == CallConv::SupersetSysV) {
        store_gpr64(4, "%rsp_in");
        store_gpr64(7, "%rdi_in");
        store_gpr64(6, "%rsi_in");
        store_gpr64(2, "%rdx_in");
        store_gpr64(1, "%rcx_in");
        store_gpr64(8, "%r8_in");
        store_gpr64(9, "%r9_in");
        std::string rax_in = tmp();
        out_ << "  " << rax_in << " = load i64, ptr %ctx\n";
        store_gpr64(0, rax_in);
        for (int idx : {3, 5, 10, 11, 12, 13, 14, 15}) store_gpr64(idx, "0");
        for (int i = 0; i < 8; i++) store_xmm(i, "%xmm" + std::to_string(i) + "_in");
        for (int i = 8; i < 16; i++) store_xmm(i, "zeroinitializer");
        for (const char *fl : {"cf", "pf", "af", "zf", "sf", "of", "df"}) store_flag(fl, "false");
    } else {
        emit_reload_fullstate();
    }

    out_ << "  br label %bb_" << fmt_va(cfg.start_va) << "\n";

    for (auto it = cfg.blocks.begin(); it != cfg.blocks.end(); ++it) {
        const auto &bb = it->second;
        out_ << "bb_" << fmt_va(bb.start_va) << ":\n";
        bool terminated = false;
        for (const auto &di : bb.insns) {
            if (opts_.emit_pc_comments) {
                out_ << "  ; 0x" << fmt_va(di.va) << " " << ZydisMnemonicGetString(di.ins.mnemonic) << "\n";
            }
            if (!lift_insn(di, cfg, terminated)) {
                stats_.insns_unsupported++;
                stats_.unsupported_mnemonics[ZydisMnemonicGetString(di.ins.mnemonic)]++;
                out_ << "  call void @bo3_trap(i64 " << di.va << ", i64 1, ptr %ctx)\n";
                out_ << "  unreachable\n";
                terminated = true;
                break;
            } else {
                stats_.insns_lifted++;
            }
            if (terminated) break;
        }
        if (!terminated) {
            uint64_t fall = bb.end_va;
            if (cfg.blocks.count(fall)) {
                out_ << "  br label %bb_" << fmt_va(fall) << "\n";
            } else if (img_ && img_->func_start_set.count(fall)) {
                // Fallthrough directly into the start of the next function -> tail call
                std::string sym = func_symbol(fall);
                if (fall != cur_func_va_) extern_guest_funcs_.insert(sym);
                emit_guest_call(sym, 0, true);
            } else {
                out_ << "  call void @bo3_trap(i64 " << fall << ", i64 2, ptr %ctx)\n";
                out_ << "  unreachable\n";
            }
        }
    }

    out_ << "}\n\n";
    cur_cfg_ = nullptr;
    os << out_.str();
    return true;
}

bool IREmitter::lift_insn(const DecodedInsn &di, const FunctionCFG &cfg, bool &terminated) {
    if (lift_int_insn(di, cfg, terminated)) return true;
    if (lift_sse_insn(di, cfg)) return true;
    return false;
}

} // namespace bo3

#include "ir_emitter.h"
#include <algorithm>
#include <sstream>

namespace bo3 {

bool IREmitter::lift_sse_insn(const DecodedInsn &di, const FunctionCFG & /*cfg*/) {
    const ZydisMnemonic mn = di.ins.mnemonic;

    auto bitcast = [&](const std::string &val, const char *from_ty, const char *to_ty) -> std::string {
        std::string r = tmp();
        out_ << "  " << r << " = bitcast " << from_ty << " " << val << " to " << to_ty << "\n";
        return r;
    };

    auto splat_vec = [&](const char *elem_ty, int n, const std::string &scalar) -> std::string {
        std::string vty = "<" + std::to_string(n) + " x " + elem_ty + ">";
        std::string ins = tmp(), sh = tmp();
        out_ << "  " << ins << " = insertelement " << vty << " poison, " << elem_ty << " " << scalar << ", i32 0\n";
        out_ << "  " << sh << " = shufflevector " << vty << " " << ins << ", " << vty << " poison, <" << n << " x i32> zeroinitializer\n";
        return sh;
    };

    auto emit_fp_to_int_exact = [&](const std::string &fp_val, bool is_double, int int_bits, bool do_trunc) -> std::string {
        const char *fty = is_double ? "double" : "float";
        std::string ity = int_ty(int_bits);
        std::string rounded = tmp();
        if (do_trunc) {
            need_intrinsic(std::string("declare ") + fty + " @llvm.trunc." + (is_double ? "f64" : "f32") + "(" + fty + ")");
            out_ << "  " << rounded << " = call " << fty << " @llvm.trunc." << (is_double ? "f64" : "f32")
                 << "(" << fty << " " << fp_val << ")\n";
        } else {
            need_intrinsic(std::string("declare ") + fty + " @llvm.roundeven." + (is_double ? "f64" : "f32") + "(" + fty + ")");
            out_ << "  " << rounded << " = call " << fty << " @llvm.roundeven." << (is_double ? "f64" : "f32")
                 << "(" << fty << " " << fp_val << ")\n";
        }
        // Exact powers-of-2 bounds (representable exactly in both float and double)
        const char *lo_bound = (int_bits == 32) ? "-2147483648.0" : "-9223372036854775808.0";
        const char *hi_bound = (int_bits == 32) ? "2147483648.0"  : "9223372036854775808.0";
        const char *indef    = (int_bits == 32) ? "-2147483648"   : "-9223372036854775808";
        std::string ge = tmp(), lt = tmp(), ok = tmp(), safe = tmp(), cvt = tmp(), res = tmp();
        out_ << "  " << ge << " = fcmp oge " << fty << " " << rounded << ", " << lo_bound << "\n";
        out_ << "  " << lt << " = fcmp olt " << fty << " " << rounded << ", " << hi_bound << "\n";
        out_ << "  " << ok << " = and i1 " << ge << ", " << lt << "\n";
        out_ << "  " << safe << " = select i1 " << ok << ", " << fty << " " << rounded << ", " << fty << " 0.0\n";
        out_ << "  " << cvt << " = fptosi " << fty << " " << safe << " to " << ity << "\n";
        out_ << "  " << res << " = select i1 " << ok << ", " << ity << " " << cvt << ", " << ity << " " << indef << "\n";
        return res;
    };

    auto emit_fp_vec_to_i32_exact = [&](const std::string &fp_vec, int lanes, bool is_double, bool do_trunc) -> std::string {
        const char *fty = is_double ? "double" : "float";
        std::string vfty = "<" + std::to_string(lanes) + " x " + fty + ">";
        std::string vity = "<" + std::to_string(lanes) + " x i32>";
        std::string v1ty = "<" + std::to_string(lanes) + " x i1>";
        std::string suffix = "v" + std::to_string(lanes) + (is_double ? "f64" : "f32");
        std::string rounded = tmp();
        if (do_trunc) {
            need_intrinsic("declare " + vfty + " @llvm.trunc." + suffix + "(" + vfty + ")");
            out_ << "  " << rounded << " = call " << vfty << " @llvm.trunc." + suffix + "(" << vfty << " " << fp_vec << ")\n";
        } else {
            need_intrinsic("declare " + vfty + " @llvm.roundeven." + suffix + "(" + vfty + ")");
            out_ << "  " << rounded << " = call " << vfty << " @llvm.roundeven." + suffix + "(" << vfty << " " << fp_vec << ")\n";
        }
        std::string lo_v = splat_vec(fty, lanes, "-2147483648.0");
        std::string hi_v = splat_vec(fty, lanes, "2147483648.0");
        std::string indef_v = splat_vec("i32", lanes, "-2147483648");
        std::string ge = tmp(), lt = tmp(), ok = tmp(), safe = tmp(), cvt = tmp(), res = tmp();
        out_ << "  " << ge << " = fcmp oge " << vfty << " " << rounded << ", " << lo_v << "\n";
        out_ << "  " << lt << " = fcmp olt " << vfty << " " << rounded << ", " << hi_v << "\n";
        out_ << "  " << ok << " = and " << v1ty << " " << ge << ", " << lt << "\n";
        out_ << "  " << safe << " = select " << v1ty << " " << ok << ", " << vfty << " " << rounded << ", " << vfty << " zeroinitializer\n";
        out_ << "  " << cvt << " = fptosi " << vfty << " " << safe << " to " << vity << "\n";
        out_ << "  " << res << " = select " << v1ty << " " << ok << ", " << vity << " " << cvt << ", " << vity << " " << indef_v << "\n";
        return res;
    };

    auto cmp_pred_str = [](uint8_t imm) -> const char * {
        switch (imm & 7) {
            case 0: return "oeq";
            case 1: return "olt";
            case 2: return "ole";
            case 3: return "uno";
            case 4: return "une";
            case 5: return "uge";
            case 6: return "ugt";
            case 7: return "ord";
        }
        return "oeq";
    };

    switch (mn) {
    // ---- 128-bit Moves ----
    case ZYDIS_MNEMONIC_MOVAPS:
    case ZYDIS_MNEMONIC_MOVUPS:
    case ZYDIS_MNEMONIC_MOVAPD:
    case ZYDIS_MNEMONIC_MOVUPD:
    case ZYDIS_MNEMONIC_MOVDQA:
    case ZYDIS_MNEMONIC_MOVDQU:
    case ZYDIS_MNEMONIC_LDDQU:
    case ZYDIS_MNEMONIC_MOVNTPS:
    case ZYDIS_MNEMONIC_MOVNTPD:
    case ZYDIS_MNEMONIC_MOVNTDQ: {
        std::string v = read_xmm_op(di, 1, 128);
        write_xmm_op(di, 0, v, 128);
        return true;
    }

    case ZYDIS_MNEMONIC_MOVSS: {
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            std::string s = read_xmm_op(di, 1, 128);
            write_xmm_op(di, 0, s, 32);
        } else if (di.ops[1].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            std::string s = read_xmm_op(di, 1, 32); // zeroes upper 96 bits!
            write_xmm_op(di, 0, s, 128);
        } else {
            // reg -> reg: preserve upper 96 bits of dst!
            std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x i32>");
            std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>");
            std::string m = tmp();
            out_ << "  " << m << " = shufflevector <4 x i32> " << s << ", <4 x i32> " << d
                 << ", <4 x i32> <i32 0, i32 5, i32 6, i32 7>\n";
            write_xmm_op(di, 0, bitcast(m, "<4 x i32>", "<2 x i64>"), 128);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_MOVSD: {
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            std::string s = read_xmm_op(di, 1, 128);
            write_xmm_op(di, 0, s, 64);
        } else if (di.ops[1].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            std::string s = read_xmm_op(di, 1, 64); // zeroes upper 64 bits!
            write_xmm_op(di, 0, s, 128);
        } else {
            // reg -> reg: preserve upper 64 bits of dst!
            std::string d = read_xmm_op(di, 0, 128);
            std::string s = read_xmm_op(di, 1, 128);
            std::string m = tmp();
            out_ << "  " << m << " = shufflevector <2 x i64> " << s << ", <2 x i64> " << d
                 << ", <2 x i32> <i32 0, i32 3>\n";
            write_xmm_op(di, 0, m, 128);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_MOVD: {
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER && zydis_xmm_index(di.ops[0].reg.value) >= 0) {
            std::string s = read_xmm_op(di, 1, 32); // zeroes upper 96 bits
            write_xmm_op(di, 0, s, 128);
        } else {
            std::string s = read_xmm_op(di, 1, 128);
            write_xmm_op(di, 0, s, 32);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_MOVQ: {
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER && zydis_xmm_index(di.ops[0].reg.value) >= 0) {
            if (di.ops[1].type == ZYDIS_OPERAND_TYPE_REGISTER && zydis_xmm_index(di.ops[1].reg.value) >= 0) {
                // movq xmm, xmm ALWAYS zeroes upper 64 bits!
                std::string s = read_xmm_op(di, 1, 128), lo = tmp(), v = tmp();
                out_ << "  " << lo << " = extractelement <2 x i64> " << s << ", i32 0\n";
                out_ << "  " << v << " = insertelement <2 x i64> zeroinitializer, i64 " << lo << ", i32 0\n";
                write_xmm_op(di, 0, v, 128);
            } else {
                std::string s = read_xmm_op(di, 1, 64);
                write_xmm_op(di, 0, s, 128);
            }
        } else {
            std::string s = read_xmm_op(di, 1, 128);
            write_xmm_op(di, 0, s, 64);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_MOVLPS:
    case ZYDIS_MNEMONIC_MOVLPD: {
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            std::string s = read_xmm_op(di, 1, 128);
            write_xmm_op(di, 0, s, 64);
        } else {
            std::string d = read_xmm_op(di, 0, 128);
            bool is_stack = false, is_ro = false;
            std::string ea = calc_mem_addr(di, di.ops[1], is_stack, is_ro);
            std::string lo = emit_mem_load(ea, 64, is_stack, is_ro, true);
            std::string v = tmp();
            out_ << "  " << v << " = insertelement <2 x i64> " << d << ", i64 " << lo << ", i32 0\n";
            write_xmm_op(di, 0, v, 128);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_MOVHPS:
    case ZYDIS_MNEMONIC_MOVHPD: {
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            std::string s = read_xmm_op(di, 1, 128), hi = tmp();
            out_ << "  " << hi << " = extractelement <2 x i64> " << s << ", i32 1\n";
            bool is_stack = false, is_ro = false;
            std::string ea = calc_mem_addr(di, di.ops[0], is_stack, is_ro);
            emit_mem_store(ea, 64, hi, is_stack, true);
        } else {
            std::string d = read_xmm_op(di, 0, 128);
            bool is_stack = false, is_ro = false;
            std::string ea = calc_mem_addr(di, di.ops[1], is_stack, is_ro);
            std::string hi = emit_mem_load(ea, 64, is_stack, is_ro, true);
            std::string v = tmp();
            out_ << "  " << v << " = insertelement <2 x i64> " << d << ", i64 " << hi << ", i32 1\n";
            write_xmm_op(di, 0, v, 128);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_MOVHLPS: {
        std::string d = read_xmm_op(di, 0, 128), s = read_xmm_op(di, 1, 128), r = tmp();
        out_ << "  " << r << " = shufflevector <2 x i64> " << d << ", <2 x i64> " << s << ", <2 x i32> <i32 3, i32 1>\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_MOVLHPS: {
        std::string d = read_xmm_op(di, 0, 128), s = read_xmm_op(di, 1, 128), r = tmp();
        out_ << "  " << r << " = shufflevector <2 x i64> " << d << ", <2 x i64> " << s << ", <2 x i32> <i32 0, i32 2>\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_MOVSHDUP: {
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>"), r = tmp();
        out_ << "  " << r << " = shufflevector <4 x i32> " << s << ", <4 x i32> poison, <4 x i32> <i32 1, i32 1, i32 3, i32 3>\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_MOVSLDUP: {
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>"), r = tmp();
        out_ << "  " << r << " = shufflevector <4 x i32> " << s << ", <4 x i32> poison, <4 x i32> <i32 0, i32 0, i32 2, i32 2>\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_MOVDDUP: {
        std::string s = read_xmm_op(di, 1, 64), r = tmp();
        out_ << "  " << r << " = shufflevector <2 x i64> " << s << ", <2 x i64> poison, <2 x i32> zeroinitializer\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }

    case ZYDIS_MNEMONIC_MOVMSKPS: {
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>");
        std::string cmp = tmp(), bc = tmp(), z = tmp();
        out_ << "  " << cmp << " = icmp slt <4 x i32> " << s << ", zeroinitializer\n";
        out_ << "  " << bc << " = bitcast <4 x i1> " << cmp << " to i4\n";
        int db = di.ops[0].size ? di.ops[0].size : 32;
        out_ << "  " << z << " = zext i4 " << bc << " to " << int_ty(db) << "\n";
        write_op(di, 0, db, z);
        return true;
    }
    case ZYDIS_MNEMONIC_MOVMSKPD: {
        std::string s = read_xmm_op(di, 1, 128);
        std::string cmp = tmp(), bc = tmp(), z = tmp();
        out_ << "  " << cmp << " = icmp slt <2 x i64> " << s << ", zeroinitializer\n";
        out_ << "  " << bc << " = bitcast <2 x i1> " << cmp << " to i2\n";
        int db = di.ops[0].size ? di.ops[0].size : 32;
        out_ << "  " << z << " = zext i2 " << bc << " to " << int_ty(db) << "\n";
        write_op(di, 0, db, z);
        return true;
    }
    case ZYDIS_MNEMONIC_PMOVMSKB: {
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<16 x i8>");
        std::string cmp = tmp(), bc = tmp(), z = tmp();
        out_ << "  " << cmp << " = icmp slt <16 x i8> " << s << ", zeroinitializer\n";
        out_ << "  " << bc << " = bitcast <16 x i1> " << cmp << " to i16\n";
        int db = di.ops[0].size ? di.ops[0].size : 32;
        out_ << "  " << z << " = zext i16 " << bc << " to " << int_ty(db) << "\n";
        write_op(di, 0, db, z);
        return true;
    }

    case ZYDIS_MNEMONIC_STMXCSR: {
        std::string mp = tmp(), mv = tmp();
        out_ << "  " << mp << " = getelementptr inbounds i8, ptr %ctx, i64 392\n"; // offsetof(GuestContext, mxcsr)
        out_ << "  " << mv << " = load i32, ptr " << mp << "\n";
        write_op(di, 0, 32, mv);
        return true;
    }
    case ZYDIS_MNEMONIC_LDMXCSR: {
        std::string mv = read_op(di, 0, 32), mp = tmp();
        out_ << "  " << mp << " = getelementptr inbounds i8, ptr %ctx, i64 392\n";
        out_ << "  store i32 " << mv << ", ptr " << mp << "\n";
        return true;
    }

    // ---- Scalar Float Ops (preserve upper 3 lanes of dst!) ----
    case ZYDIS_MNEMONIC_ADDSS: case ZYDIS_MNEMONIC_SUBSS:
    case ZYDIS_MNEMONIC_MULSS: case ZYDIS_MNEMONIC_DIVSS:
    case ZYDIS_MNEMONIC_MINSS: case ZYDIS_MNEMONIC_MAXSS:
    case ZYDIS_MNEMONIC_SQRTSS: case ZYDIS_MNEMONIC_RCPSS:
    case ZYDIS_MNEMONIC_RSQRTSS: {
        std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x float>");
        std::string s = bitcast(read_xmm_op(di, 1, 32), "<2 x i64>", "<4 x float>");
        std::string a = tmp(), b = tmp(), r = tmp();
        out_ << "  " << a << " = extractelement <4 x float> " << d << ", i32 0\n";
        out_ << "  " << b << " = extractelement <4 x float> " << s << ", i32 0\n";
        if (mn == ZYDIS_MNEMONIC_ADDSS) out_ << "  " << r << " = fadd float " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_SUBSS) out_ << "  " << r << " = fsub float " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_MULSS) out_ << "  " << r << " = fmul float " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_DIVSS) out_ << "  " << r << " = fdiv float " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_MINSS) {
            std::string c = tmp();
            out_ << "  " << c << " = fcmp olt float " << a << ", " << b << "\n";
            out_ << "  " << r << " = select i1 " << c << ", float " << a << ", float " << b << "\n";
        } else if (mn == ZYDIS_MNEMONIC_MAXSS) {
            std::string c = tmp();
            out_ << "  " << c << " = fcmp ogt float " << a << ", " << b << "\n";
            out_ << "  " << r << " = select i1 " << c << ", float " << a << ", float " << b << "\n";
        } else if (mn == ZYDIS_MNEMONIC_SQRTSS) {
            need_intrinsic("declare float @llvm.sqrt.f32(float)");
            out_ << "  " << r << " = call float @llvm.sqrt.f32(float " << b << ")\n";
        } else if (mn == ZYDIS_MNEMONIC_RCPSS) {
            out_ << "  " << r << " = fdiv float 1.0, " << b << "\n";
        } else {
            need_intrinsic("declare float @llvm.sqrt.f32(float)");
            std::string sq = tmp();
            out_ << "  " << sq << " = call float @llvm.sqrt.f32(float " << b << ")\n";
            out_ << "  " << r << " = fdiv float 1.0, " << sq << "\n";
        }
        std::string res = tmp();
        out_ << "  " << res << " = insertelement <4 x float> " << d << ", float " << r << ", i32 0\n";
        write_xmm_op(di, 0, bitcast(res, "<4 x float>", "<2 x i64>"), 128);
        return true;
    }

    // ---- Scalar Double Ops (preserve upper lane of dst!) ----
    case ZYDIS_MNEMONIC_ADDSD: case ZYDIS_MNEMONIC_SUBSD:
    case ZYDIS_MNEMONIC_MULSD: case ZYDIS_MNEMONIC_DIVSD:
    case ZYDIS_MNEMONIC_MINSD: case ZYDIS_MNEMONIC_MAXSD:
    case ZYDIS_MNEMONIC_SQRTSD: {
        std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<2 x double>");
        std::string s = bitcast(read_xmm_op(di, 1, 64), "<2 x i64>", "<2 x double>");
        std::string a = tmp(), b = tmp(), r = tmp();
        out_ << "  " << a << " = extractelement <2 x double> " << d << ", i32 0\n";
        out_ << "  " << b << " = extractelement <2 x double> " << s << ", i32 0\n";
        if (mn == ZYDIS_MNEMONIC_ADDSD) out_ << "  " << r << " = fadd double " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_SUBSD) out_ << "  " << r << " = fsub double " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_MULSD) out_ << "  " << r << " = fmul double " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_DIVSD) out_ << "  " << r << " = fdiv double " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_MINSD) {
            std::string c = tmp();
            out_ << "  " << c << " = fcmp olt double " << a << ", " << b << "\n";
            out_ << "  " << r << " = select i1 " << c << ", double " << a << ", double " << b << "\n";
        } else if (mn == ZYDIS_MNEMONIC_MAXSD) {
            std::string c = tmp();
            out_ << "  " << c << " = fcmp ogt double " << a << ", " << b << "\n";
            out_ << "  " << r << " = select i1 " << c << ", double " << a << ", double " << b << "\n";
        } else {
            need_intrinsic("declare double @llvm.sqrt.f64(double)");
            out_ << "  " << r << " = call double @llvm.sqrt.f64(double " << b << ")\n";
        }
        std::string res = tmp();
        out_ << "  " << res << " = insertelement <2 x double> " << d << ", double " << r << ", i32 0\n";
        write_xmm_op(di, 0, bitcast(res, "<2 x double>", "<2 x i64>"), 128);
        return true;
    }

    // ---- Packed Float Ops ----
    case ZYDIS_MNEMONIC_ADDPS: case ZYDIS_MNEMONIC_SUBPS:
    case ZYDIS_MNEMONIC_MULPS: case ZYDIS_MNEMONIC_DIVPS:
    case ZYDIS_MNEMONIC_MINPS: case ZYDIS_MNEMONIC_MAXPS:
    case ZYDIS_MNEMONIC_SQRTPS: case ZYDIS_MNEMONIC_RCPPS:
    case ZYDIS_MNEMONIC_RSQRTPS: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x float>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x float>");
        std::string r = tmp();
        if (mn == ZYDIS_MNEMONIC_ADDPS) out_ << "  " << r << " = fadd <4 x float> " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_SUBPS) out_ << "  " << r << " = fsub <4 x float> " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_MULPS) out_ << "  " << r << " = fmul <4 x float> " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_DIVPS) out_ << "  " << r << " = fdiv <4 x float> " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_MINPS) {
            std::string c = tmp();
            out_ << "  " << c << " = fcmp olt <4 x float> " << a << ", " << b << "\n";
            out_ << "  " << r << " = select <4 x i1> " << c << ", <4 x float> " << a << ", <4 x float> " << b << "\n";
        } else if (mn == ZYDIS_MNEMONIC_MAXPS) {
            std::string c = tmp();
            out_ << "  " << c << " = fcmp ogt <4 x float> " << a << ", " << b << "\n";
            out_ << "  " << r << " = select <4 x i1> " << c << ", <4 x float> " << a << ", <4 x float> " << b << "\n";
        } else if (mn == ZYDIS_MNEMONIC_SQRTPS) {
            need_intrinsic("declare <4 x float> @llvm.sqrt.v4f32(<4 x float>)");
            out_ << "  " << r << " = call <4 x float> @llvm.sqrt.v4f32(<4 x float> " << b << ")\n";
        } else if (mn == ZYDIS_MNEMONIC_RCPPS) {
            std::string ones = splat_vec("float", 4, "1.0");
            out_ << "  " << r << " = fdiv <4 x float> " << ones << ", " << b << "\n";
        } else {
            need_intrinsic("declare <4 x float> @llvm.sqrt.v4f32(<4 x float>)");
            std::string ones = splat_vec("float", 4, "1.0"), sq = tmp();
            out_ << "  " << sq << " = call <4 x float> @llvm.sqrt.v4f32(<4 x float> " << b << ")\n";
            out_ << "  " << r << " = fdiv <4 x float> " << ones << ", " << sq << "\n";
        }
        write_xmm_op(di, 0, bitcast(r, "<4 x float>", "<2 x i64>"), 128);
        return true;
    }

    // ---- Packed Double Ops ----
    case ZYDIS_MNEMONIC_ADDPD: case ZYDIS_MNEMONIC_SUBPD:
    case ZYDIS_MNEMONIC_MULPD: case ZYDIS_MNEMONIC_DIVPD:
    case ZYDIS_MNEMONIC_MINPD: case ZYDIS_MNEMONIC_MAXPD:
    case ZYDIS_MNEMONIC_SQRTPD: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<2 x double>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<2 x double>");
        std::string r = tmp();
        if (mn == ZYDIS_MNEMONIC_ADDPD) out_ << "  " << r << " = fadd <2 x double> " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_SUBPD) out_ << "  " << r << " = fsub <2 x double> " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_MULPD) out_ << "  " << r << " = fmul <2 x double> " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_DIVPD) out_ << "  " << r << " = fdiv <2 x double> " << a << ", " << b << "\n";
        else if (mn == ZYDIS_MNEMONIC_MINPD) {
            std::string c = tmp();
            out_ << "  " << c << " = fcmp olt <2 x double> " << a << ", " << b << "\n";
            out_ << "  " << r << " = select <2 x i1> " << c << ", <2 x double> " << a << ", <2 x double> " << b << "\n";
        } else if (mn == ZYDIS_MNEMONIC_MAXPD) {
            std::string c = tmp();
            out_ << "  " << c << " = fcmp ogt <2 x double> " << a << ", " << b << "\n";
            out_ << "  " << r << " = select <2 x i1> " << c << ", <2 x double> " << a << ", <2 x double> " << b << "\n";
        } else {
            need_intrinsic("declare <2 x double> @llvm.sqrt.v2f64(<2 x double>)");
            out_ << "  " << r << " = call <2 x double> @llvm.sqrt.v2f64(<2 x double> " << b << ")\n";
        }
        write_xmm_op(di, 0, bitcast(r, "<2 x double>", "<2 x i64>"), 128);
        return true;
    }

    case ZYDIS_MNEMONIC_HADDPS: case ZYDIS_MNEMONIC_HSUBPS: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x float>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x float>");
        std::string even = tmp(), odd = tmp(), r = tmp();
        out_ << "  " << even << " = shufflevector <4 x float> " << a << ", <4 x float> " << b << ", <4 x i32> <i32 0, i32 2, i32 4, i32 6>\n";
        out_ << "  " << odd  << " = shufflevector <4 x float> " << a << ", <4 x float> " << b << ", <4 x i32> <i32 1, i32 3, i32 5, i32 7>\n";
        out_ << "  " << r << " = " << (mn == ZYDIS_MNEMONIC_HADDPS ? "fadd" : "fsub") << " <4 x float> " << even << ", " << odd << "\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x float>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_HADDPD: case ZYDIS_MNEMONIC_HSUBPD: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<2 x double>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<2 x double>");
        std::string even = tmp(), odd = tmp(), r = tmp();
        out_ << "  " << even << " = shufflevector <2 x double> " << a << ", <2 x double> " << b << ", <2 x i32> <i32 0, i32 2>\n";
        out_ << "  " << odd  << " = shufflevector <2 x double> " << a << ", <2 x double> " << b << ", <2 x i32> <i32 1, i32 3>\n";
        out_ << "  " << r << " = " << (mn == ZYDIS_MNEMONIC_HADDPD ? "fadd" : "fsub") << " <2 x double> " << even << ", " << odd << "\n";
        write_xmm_op(di, 0, bitcast(r, "<2 x double>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_ADDSUBPS: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x float>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x float>");
        std::string sub = tmp(), add = tmp(), r = tmp();
        out_ << "  " << sub << " = fsub <4 x float> " << a << ", " << b << "\n";
        out_ << "  " << add << " = fadd <4 x float> " << a << ", " << b << "\n";
        out_ << "  " << r << " = shufflevector <4 x float> " << sub << ", <4 x float> " << add << ", <4 x i32> <i32 0, i32 5, i32 2, i32 7>\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x float>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_ADDSUBPD: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<2 x double>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<2 x double>");
        std::string sub = tmp(), add = tmp(), r = tmp();
        out_ << "  " << sub << " = fsub <2 x double> " << a << ", " << b << "\n";
        out_ << "  " << add << " = fadd <2 x double> " << a << ", " << b << "\n";
        out_ << "  " << r << " = shufflevector <2 x double> " << sub << ", <2 x double> " << add << ", <2 x i32> <i32 0, i32 3>\n";
        write_xmm_op(di, 0, bitcast(r, "<2 x double>", "<2 x i64>"), 128);
        return true;
    }

    // ---- Rounding (SSE4.1) ----
    case ZYDIS_MNEMONIC_ROUNDSS: case ZYDIS_MNEMONIC_ROUNDSD:
    case ZYDIS_MNEMONIC_ROUNDPS: case ZYDIS_MNEMONIC_ROUNDPD: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        uint8_t mode = (imm & 4) ? 0 : (imm & 3); // bit 2 = use MXCSR (default nearest-even)
        const char *rfn = (mode == 0) ? "roundeven" : (mode == 1) ? "floor" : (mode == 2) ? "ceil" : "trunc";
        if (mn == ZYDIS_MNEMONIC_ROUNDSS) {
            need_intrinsic(std::string("declare float @llvm.") + rfn + ".f32(float)");
            std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x float>");
            std::string s = bitcast(read_xmm_op(di, 1, 32), "<2 x i64>", "<4 x float>");
            std::string b = tmp(), r = tmp(), res = tmp();
            out_ << "  " << b << " = extractelement <4 x float> " << s << ", i32 0\n";
            out_ << "  " << r << " = call float @llvm." << rfn << ".f32(float " << b << ")\n";
            out_ << "  " << res << " = insertelement <4 x float> " << d << ", float " << r << ", i32 0\n";
            write_xmm_op(di, 0, bitcast(res, "<4 x float>", "<2 x i64>"), 128);
        } else if (mn == ZYDIS_MNEMONIC_ROUNDSD) {
            need_intrinsic(std::string("declare double @llvm.") + rfn + ".f64(double)");
            std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<2 x double>");
            std::string s = bitcast(read_xmm_op(di, 1, 64), "<2 x i64>", "<2 x double>");
            std::string b = tmp(), r = tmp(), res = tmp();
            out_ << "  " << b << " = extractelement <2 x double> " << s << ", i32 0\n";
            out_ << "  " << r << " = call double @llvm." << rfn << ".f64(double " << b << ")\n";
            out_ << "  " << res << " = insertelement <2 x double> " << d << ", double " << r << ", i32 0\n";
            write_xmm_op(di, 0, bitcast(res, "<2 x double>", "<2 x i64>"), 128);
        } else if (mn == ZYDIS_MNEMONIC_ROUNDPS) {
            need_intrinsic(std::string("declare <4 x float> @llvm.") + rfn + ".v4f32(<4 x float>)");
            std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x float>"), r = tmp();
            out_ << "  " << r << " = call <4 x float> @llvm." << rfn << ".v4f32(<4 x float> " << s << ")\n";
            write_xmm_op(di, 0, bitcast(r, "<4 x float>", "<2 x i64>"), 128);
        } else {
            need_intrinsic(std::string("declare <2 x double> @llvm.") + rfn + ".v2f64(<2 x double>)");
            std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<2 x double>"), r = tmp();
            out_ << "  " << r << " = call <2 x double> @llvm." << rfn << ".v2f64(<2 x double> " << s << ")\n";
            write_xmm_op(di, 0, bitcast(r, "<2 x double>", "<2 x i64>"), 128);
        }
        return true;
    }

    // ---- Float/Double Comparisons ----
    case ZYDIS_MNEMONIC_UCOMISS: case ZYDIS_MNEMONIC_COMISS:
    case ZYDIS_MNEMONIC_UCOMISD: case ZYDIS_MNEMONIC_COMISD: {
        bool is_d = (mn == ZYDIS_MNEMONIC_UCOMISD || mn == ZYDIS_MNEMONIC_COMISD);
        const char *fty = is_d ? "double" : "float";
        const char *vty = is_d ? "<2 x double>" : "<4 x float>";
        std::string va = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", vty);
        std::string vb = bitcast(read_xmm_op(di, 1, is_d ? 64 : 32), "<2 x i64>", vty);
        std::string a = tmp(), b = tmp();
        out_ << "  " << a << " = extractelement " << vty << " " << va << ", i32 0\n";
        out_ << "  " << b << " = extractelement " << vty << " " << vb << ", i32 0\n";
        uint32_t live = di.live_flags_out;
        if (live & FL_ZF) { std::string z = tmp(); out_ << "  " << z << " = fcmp ueq " << fty << " " << a << ", " << b << "\n"; store_flag("zf", z); }
        if (live & FL_PF) { std::string p = tmp(); out_ << "  " << p << " = fcmp uno " << fty << " " << a << ", " << b << "\n"; store_flag("pf", p); }
        if (live & FL_CF) { std::string c = tmp(); out_ << "  " << c << " = fcmp ult " << fty << " " << a << ", " << b << "\n"; store_flag("cf", c); }
        if (live & FL_OF) store_flag("of", "false");
        if (live & FL_SF) store_flag("sf", "false");
        if (live & FL_AF) store_flag("af", "false");
        return true;
    }

    case ZYDIS_MNEMONIC_CMPSS: {
        const char *pred = cmp_pred_str((uint8_t)di.ops[2].imm.value.u);
        std::string d_i = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x i32>");
        std::string d_f = bitcast(d_i, "<4 x i32>", "<4 x float>");
        std::string s_f = bitcast(read_xmm_op(di, 1, 32), "<2 x i64>", "<4 x float>");
        std::string a = tmp(), b = tmp(), c = tmp(), m = tmp(), res = tmp();
        out_ << "  " << a << " = extractelement <4 x float> " << d_f << ", i32 0\n";
        out_ << "  " << b << " = extractelement <4 x float> " << s_f << ", i32 0\n";
        out_ << "  " << c << " = fcmp " << pred << " float " << a << ", " << b << "\n";
        out_ << "  " << m << " = sext i1 " << c << " to i32\n";
        out_ << "  " << res << " = insertelement <4 x i32> " << d_i << ", i32 " << m << ", i32 0\n";
        write_xmm_op(di, 0, bitcast(res, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CMPSD: {
        const char *pred = cmp_pred_str((uint8_t)di.ops[2].imm.value.u);
        std::string d_i = read_xmm_op(di, 0, 128);
        std::string d_f = bitcast(d_i, "<2 x i64>", "<2 x double>");
        std::string s_f = bitcast(read_xmm_op(di, 1, 64), "<2 x i64>", "<2 x double>");
        std::string a = tmp(), b = tmp(), c = tmp(), m = tmp(), res = tmp();
        out_ << "  " << a << " = extractelement <2 x double> " << d_f << ", i32 0\n";
        out_ << "  " << b << " = extractelement <2 x double> " << s_f << ", i32 0\n";
        out_ << "  " << c << " = fcmp " << pred << " double " << a << ", " << b << "\n";
        out_ << "  " << m << " = sext i1 " << c << " to i64\n";
        out_ << "  " << res << " = insertelement <2 x i64> " << d_i << ", i64 " << m << ", i32 0\n";
        write_xmm_op(di, 0, res, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CMPPS: {
        const char *pred = cmp_pred_str((uint8_t)di.ops[2].imm.value.u);
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x float>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x float>");
        std::string c = tmp(), m = tmp();
        out_ << "  " << c << " = fcmp " << pred << " <4 x float> " << a << ", " << b << "\n";
        out_ << "  " << m << " = sext <4 x i1> " << c << " to <4 x i32>\n";
        write_xmm_op(di, 0, bitcast(m, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CMPPD: {
        const char *pred = cmp_pred_str((uint8_t)di.ops[2].imm.value.u);
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<2 x double>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<2 x double>");
        std::string c = tmp(), m = tmp();
        out_ << "  " << c << " = fcmp " << pred << " <2 x double> " << a << ", " << b << "\n";
        out_ << "  " << m << " = sext <2 x i1> " << c << " to <2 x i64>\n";
        write_xmm_op(di, 0, m, 128);
        return true;
    }

    // ---- Conversions ----
    case ZYDIS_MNEMONIC_CVTSI2SS: {
        int sb = di.ops[1].size ? di.ops[1].size : 32;
        std::string iv = read_op(di, 1, sb), fv = tmp(), res = tmp();
        std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x float>");
        out_ << "  " << fv << " = sitofp " << int_ty(sb) << " " << iv << " to float\n";
        out_ << "  " << res << " = insertelement <4 x float> " << d << ", float " << fv << ", i32 0\n";
        write_xmm_op(di, 0, bitcast(res, "<4 x float>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTSI2SD: {
        int sb = di.ops[1].size ? di.ops[1].size : 32;
        std::string iv = read_op(di, 1, sb), fv = tmp(), res = tmp();
        std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<2 x double>");
        out_ << "  " << fv << " = sitofp " << int_ty(sb) << " " << iv << " to double\n";
        out_ << "  " << res << " = insertelement <2 x double> " << d << ", double " << fv << ", i32 0\n";
        write_xmm_op(di, 0, bitcast(res, "<2 x double>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTSS2SD: {
        std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<2 x double>");
        std::string s = bitcast(read_xmm_op(di, 1, 32), "<2 x i64>", "<4 x float>");
        std::string f = tmp(), dd = tmp(), res = tmp();
        out_ << "  " << f << " = extractelement <4 x float> " << s << ", i32 0\n";
        out_ << "  " << dd << " = fpext float " << f << " to double\n";
        out_ << "  " << res << " = insertelement <2 x double> " << d << ", double " << dd << ", i32 0\n";
        write_xmm_op(di, 0, bitcast(res, "<2 x double>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTSD2SS: {
        std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x float>");
        std::string s = bitcast(read_xmm_op(di, 1, 64), "<2 x i64>", "<2 x double>");
        std::string dd = tmp(), f = tmp(), res = tmp();
        out_ << "  " << dd << " = extractelement <2 x double> " << s << ", i32 0\n";
        out_ << "  " << f << " = fptrunc double " << dd << " to float\n";
        out_ << "  " << res << " = insertelement <4 x float> " << d << ", float " << f << ", i32 0\n";
        write_xmm_op(di, 0, bitcast(res, "<4 x float>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTTSS2SI: case ZYDIS_MNEMONIC_CVTSS2SI:
    case ZYDIS_MNEMONIC_CVTTSD2SI: case ZYDIS_MNEMONIC_CVTSD2SI: {
        bool is_d = (mn == ZYDIS_MNEMONIC_CVTTSD2SI || mn == ZYDIS_MNEMONIC_CVTSD2SI);
        bool do_trunc = (mn == ZYDIS_MNEMONIC_CVTTSS2SI || mn == ZYDIS_MNEMONIC_CVTTSD2SI);
        int db = di.ops[0].size ? di.ops[0].size : 32;
        std::string s = bitcast(read_xmm_op(di, 1, is_d ? 64 : 32), "<2 x i64>", is_d ? "<2 x double>" : "<4 x float>");
        std::string fp = tmp();
        out_ << "  " << fp << " = extractelement " << (is_d ? "<2 x double>" : "<4 x float>") << " " << s << ", i32 0\n";
        std::string iv = emit_fp_to_int_exact(fp, is_d, db, do_trunc);
        write_op(di, 0, db, iv);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTDQ2PS: {
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>"), r = tmp();
        out_ << "  " << r << " = sitofp <4 x i32> " << s << " to <4 x float>\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x float>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTDQ2PD: {
        std::string s = bitcast(read_xmm_op(di, 1, 64), "<2 x i64>", "<4 x i32>");
        std::string lo = tmp(), r = tmp();
        out_ << "  " << lo << " = shufflevector <4 x i32> " << s << ", <4 x i32> poison, <2 x i32> <i32 0, i32 1>\n";
        out_ << "  " << r << " = sitofp <2 x i32> " << lo << " to <2 x double>\n";
        write_xmm_op(di, 0, bitcast(r, "<2 x double>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTPS2PD: {
        std::string s = bitcast(read_xmm_op(di, 1, 64), "<2 x i64>", "<4 x float>");
        std::string lo = tmp(), r = tmp();
        out_ << "  " << lo << " = shufflevector <4 x float> " << s << ", <4 x float> poison, <2 x i32> <i32 0, i32 1>\n";
        out_ << "  " << r << " = fpext <2 x float> " << lo << " to <2 x double>\n";
        write_xmm_op(di, 0, bitcast(r, "<2 x double>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTPD2PS: {
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<2 x double>");
        std::string lo = tmp(), r = tmp();
        out_ << "  " << lo << " = fptrunc <2 x double> " << s << " to <2 x float>\n";
        out_ << "  " << r << " = shufflevector <2 x float> " << lo << ", <2 x float> zeroinitializer, <4 x i32> <i32 0, i32 1, i32 2, i32 3>\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x float>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTPS2DQ:
    case ZYDIS_MNEMONIC_CVTTPS2DQ: {
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x float>");
        std::string r = emit_fp_vec_to_i32_exact(s, 4, false, mn == ZYDIS_MNEMONIC_CVTTPS2DQ);
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_CVTPD2DQ:
    case ZYDIS_MNEMONIC_CVTTPD2DQ: {
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<2 x double>");
        std::string lo = emit_fp_vec_to_i32_exact(s, 2, true, mn == ZYDIS_MNEMONIC_CVTTPD2DQ);
        std::string r = tmp();
        out_ << "  " << r << " = shufflevector <2 x i32> " << lo << ", <2 x i32> zeroinitializer, <4 x i32> <i32 0, i32 1, i32 2, i32 3>\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }

    // ---- Bitwise Vector Ops ----
    case ZYDIS_MNEMONIC_ANDPS: case ZYDIS_MNEMONIC_ANDPD: case ZYDIS_MNEMONIC_PAND: {
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128), r = tmp();
        out_ << "  " << r << " = and <2 x i64> " << a << ", " << b << "\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_ANDNPS: case ZYDIS_MNEMONIC_ANDNPD: case ZYDIS_MNEMONIC_PANDN: {
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128);
        std::string na = tmp(), r = tmp();
        out_ << "  " << na << " = xor <2 x i64> " << a << ", <i64 -1, i64 -1>\n";
        out_ << "  " << r << " = and <2 x i64> " << na << ", " << b << "\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_ORPS: case ZYDIS_MNEMONIC_ORPD: case ZYDIS_MNEMONIC_POR: {
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128), r = tmp();
        out_ << "  " << r << " = or <2 x i64> " << a << ", " << b << "\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_XORPS: case ZYDIS_MNEMONIC_XORPD: case ZYDIS_MNEMONIC_PXOR: {
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
            di.ops[1].type == ZYDIS_OPERAND_TYPE_REGISTER &&
            di.ops[0].reg.value == di.ops[1].reg.value) {
            write_xmm_op(di, 0, "zeroinitializer", 128);
            return true;
        }
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128), r = tmp();
        out_ << "  " << r << " = xor <2 x i64> " << a << ", " << b << "\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }

    // ---- Shuffles / Unpacks / Blends / Insert / Extract ----
    case ZYDIS_MNEMONIC_SHUFPS: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x i32>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>");
        std::string r = tmp();
        out_ << "  " << r << " = shufflevector <4 x i32> " << a << ", <4 x i32> " << b
             << ", <4 x i32> <i32 " << (imm & 3) << ", i32 " << ((imm >> 2) & 3)
             << ", i32 " << (4 + ((imm >> 4) & 3)) << ", i32 " << (4 + ((imm >> 6) & 3)) << ">\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_SHUFPD: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128), r = tmp();
        out_ << "  " << r << " = shufflevector <2 x i64> " << a << ", <2 x i64> " << b
             << ", <2 x i32> <i32 " << (imm & 1) << ", i32 " << (2 + ((imm >> 1) & 1)) << ">\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PSHUFD: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>"), r = tmp();
        out_ << "  " << r << " = shufflevector <4 x i32> " << s << ", <4 x i32> poison"
             << ", <4 x i32> <i32 " << (imm & 3) << ", i32 " << ((imm >> 2) & 3)
             << ", i32 " << ((imm >> 4) & 3) << ", i32 " << ((imm >> 6) & 3) << ">\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PSHUFLW: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<8 x i16>"), r = tmp();
        out_ << "  " << r << " = shufflevector <8 x i16> " << s << ", <8 x i16> poison"
             << ", <8 x i32> <i32 " << (imm & 3) << ", i32 " << ((imm >> 2) & 3)
             << ", i32 " << ((imm >> 4) & 3) << ", i32 " << ((imm >> 6) & 3)
             << ", i32 4, i32 5, i32 6, i32 7>\n";
        write_xmm_op(di, 0, bitcast(r, "<8 x i16>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PSHUFHW: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<8 x i16>"), r = tmp();
        out_ << "  " << r << " = shufflevector <8 x i16> " << s << ", <8 x i16> poison"
             << ", <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 " << (4 + (imm & 3))
             << ", i32 " << (4 + ((imm >> 2) & 3)) << ", i32 " << (4 + ((imm >> 4) & 3))
             << ", i32 " << (4 + ((imm >> 6) & 3)) << ">\n";
        write_xmm_op(di, 0, bitcast(r, "<8 x i16>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PSHUFB: {
        need_intrinsic("declare <16 x i8> @llvm.aarch64.neon.tbl1.v16i8(<16 x i8>, <16 x i8>)");
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<16 x i8>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<16 x i8>");
        // Mask with 0x8f: if bit7==0 -> 0..15; if bit7==1 -> 128..143 (>= 16 -> tbl1 outputs 0!)
        std::string mask = splat_vec("i8", 16, "-113"); // 0x8f == -113 signed i8
        std::string idx = tmp(), r = tmp();
        out_ << "  " << idx << " = and <16 x i8> " << b << ", " << mask << "\n";
        out_ << "  " << r << " = call <16 x i8> @llvm.aarch64.neon.tbl1.v16i8(<16 x i8> " << a << ", <16 x i8> " << idx << ")\n";
        write_xmm_op(di, 0, bitcast(r, "<16 x i8>", "<2 x i64>"), 128);
        return true;
    }

    case ZYDIS_MNEMONIC_UNPCKLPS: case ZYDIS_MNEMONIC_PUNPCKLDQ: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x i32>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>"), r = tmp();
        out_ << "  " << r << " = shufflevector <4 x i32> " << a << ", <4 x i32> " << b << ", <4 x i32> <i32 0, i32 4, i32 1, i32 5>\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_UNPCKHPS: case ZYDIS_MNEMONIC_PUNPCKHDQ: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x i32>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>"), r = tmp();
        out_ << "  " << r << " = shufflevector <4 x i32> " << a << ", <4 x i32> " << b << ", <4 x i32> <i32 2, i32 6, i32 3, i32 7>\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_UNPCKLPD: case ZYDIS_MNEMONIC_PUNPCKLQDQ: {
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128), r = tmp();
        out_ << "  " << r << " = shufflevector <2 x i64> " << a << ", <2 x i64> " << b << ", <2 x i32> <i32 0, i32 2>\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_UNPCKHPD: case ZYDIS_MNEMONIC_PUNPCKHQDQ: {
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128), r = tmp();
        out_ << "  " << r << " = shufflevector <2 x i64> " << a << ", <2 x i64> " << b << ", <2 x i32> <i32 1, i32 3>\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PUNPCKLBW: case ZYDIS_MNEMONIC_PUNPCKHBW: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<16 x i8>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<16 x i8>"), r = tmp();
        int base = (mn == ZYDIS_MNEMONIC_PUNPCKLBW) ? 0 : 8;
        out_ << "  " << r << " = shufflevector <16 x i8> " << a << ", <16 x i8> " << b << ", <16 x i32> <";
        for (int i = 0; i < 8; i++) {
            if (i) out_ << ", ";
            out_ << "i32 " << (base + i) << ", i32 " << (16 + base + i);
        }
        out_ << ">\n";
        write_xmm_op(di, 0, bitcast(r, "<16 x i8>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PUNPCKLWD: case ZYDIS_MNEMONIC_PUNPCKHWD: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<8 x i16>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<8 x i16>"), r = tmp();
        int base = (mn == ZYDIS_MNEMONIC_PUNPCKLWD) ? 0 : 4;
        out_ << "  " << r << " = shufflevector <8 x i16> " << a << ", <8 x i16> " << b << ", <8 x i32> <";
        for (int i = 0; i < 4; i++) {
            if (i) out_ << ", ";
            out_ << "i32 " << (base + i) << ", i32 " << (8 + base + i);
        }
        out_ << ">\n";
        write_xmm_op(di, 0, bitcast(r, "<8 x i16>", "<2 x i64>"), 128);
        return true;
    }

    case ZYDIS_MNEMONIC_INSERTPS: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        int src_lane = (di.ops[1].type == ZYDIS_OPERAND_TYPE_MEMORY) ? 0 : ((imm >> 6) & 3);
        int dst_lane = (imm >> 4) & 3;
        std::string d = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x i32>");
        std::string s = bitcast(read_xmm_op(di, 1, 32), "<2 x i64>", "<4 x i32>");
        std::string el = tmp(), cur = tmp();
        out_ << "  " << el << " = extractelement <4 x i32> " << s << ", i32 " << src_lane << "\n";
        out_ << "  " << cur << " = insertelement <4 x i32> " << d << ", i32 " << el << ", i32 " << dst_lane << "\n";
        for (int k = 0; k < 4; k++) {
            if ((imm >> k) & 1) {
                std::string nxt = tmp();
                out_ << "  " << nxt << " = insertelement <4 x i32> " << cur << ", i32 0, i32 " << k << "\n";
                cur = nxt;
            }
        }
        write_xmm_op(di, 0, bitcast(cur, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_EXTRACTPS: {
        uint8_t lane = (uint8_t)di.ops[2].imm.value.u & 3;
        std::string s = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>"), el = tmp();
        out_ << "  " << el << " = extractelement <4 x i32> " << s << ", i32 " << (int)lane << "\n";
        int db = di.ops[0].size ? di.ops[0].size : 32;
        if (db == 64 && di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER) {
            std::string z = tmp();
            out_ << "  " << z << " = zext i32 " << el << " to i64\n";
            write_op(di, 0, 64, z);
        } else {
            write_op(di, 0, 32, el);
        }
        return true;
    }
    case ZYDIS_MNEMONIC_PINSRB: case ZYDIS_MNEMONIC_PINSRW:
    case ZYDIS_MNEMONIC_PINSRD: case ZYDIS_MNEMONIC_PINSRQ: {
        int ebits = (mn == ZYDIS_MNEMONIC_PINSRB) ? 8 : (mn == ZYDIS_MNEMONIC_PINSRW) ? 16 :
                    (mn == ZYDIS_MNEMONIC_PINSRD) ? 32 : 64;
        int lanes = 128 / ebits;
        int lane = (int)(di.ops[2].imm.value.u & (lanes - 1));
        std::string vty = "<" + std::to_string(lanes) + " x " + int_ty(ebits) + ">";
        std::string d = (ebits == 64) ? read_xmm_op(di, 0, 128) : bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", vty.c_str());
        std::string val;
        if (di.ops[1].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            val = read_op(di, 1, ebits);
        } else {
            int rbits = di.ops[1].size ? di.ops[1].size : 32;
            std::string g = read_op(di, 1, rbits);
            if (rbits > ebits) {
                val = tmp();
                out_ << "  " << val << " = trunc " << int_ty(rbits) << " " << g << " to " << int_ty(ebits) << "\n";
            } else {
                val = g;
            }
        }
        std::string r = tmp();
        out_ << "  " << r << " = insertelement " << vty << " " << d << ", " << int_ty(ebits) << " " << val << ", i32 " << lane << "\n";
        write_xmm_op(di, 0, (ebits == 64) ? r : bitcast(r, vty.c_str(), "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PEXTRB: case ZYDIS_MNEMONIC_PEXTRW:
    case ZYDIS_MNEMONIC_PEXTRD: case ZYDIS_MNEMONIC_PEXTRQ: {
        int ebits = (mn == ZYDIS_MNEMONIC_PEXTRB) ? 8 : (mn == ZYDIS_MNEMONIC_PEXTRW) ? 16 :
                    (mn == ZYDIS_MNEMONIC_PEXTRD) ? 32 : 64;
        int lanes = 128 / ebits;
        int lane = (int)(di.ops[2].imm.value.u & (lanes - 1));
        std::string vty = "<" + std::to_string(lanes) + " x " + int_ty(ebits) + ">";
        std::string s = (ebits == 64) ? read_xmm_op(di, 1, 128) : bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", vty.c_str());
        std::string el = tmp();
        out_ << "  " << el << " = extractelement " << vty << " " << s << ", i32 " << lane << "\n";
        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            write_op(di, 0, ebits, el);
        } else {
            int db = di.ops[0].size ? di.ops[0].size : 32;
            std::string out_v = el;
            if (db > ebits) {
                out_v = tmp();
                out_ << "  " << out_v << " = zext " << int_ty(ebits) << " " << el << " to " << int_ty(db) << "\n";
            }
            write_op(di, 0, db, out_v);
        }
        return true;
    }

    case ZYDIS_MNEMONIC_BLENDPS: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x i32>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>"), r = tmp();
        out_ << "  " << r << " = shufflevector <4 x i32> " << a << ", <4 x i32> " << b << ", <4 x i32> <";
        for (int i = 0; i < 4; i++) out_ << (i ? ", " : "") << "i32 " << (((imm >> i) & 1) ? (4 + i) : i);
        out_ << ">\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_BLENDPD: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128), r = tmp();
        out_ << "  " << r << " = shufflevector <2 x i64> " << a << ", <2 x i64> " << b
             << ", <2 x i32> <i32 " << ((imm & 1) ? 2 : 0) << ", i32 " << (((imm >> 1) & 1) ? 3 : 1) << ">\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PBLENDW: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<8 x i16>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<8 x i16>"), r = tmp();
        out_ << "  " << r << " = shufflevector <8 x i16> " << a << ", <8 x i16> " << b << ", <8 x i32> <";
        for (int i = 0; i < 8; i++) out_ << (i ? ", " : "") << "i32 " << (((imm >> i) & 1) ? (8 + i) : i);
        out_ << ">\n";
        write_xmm_op(di, 0, bitcast(r, "<8 x i16>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_BLENDVPS: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x i32>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>");
        std::string m = bitcast(load_xmm(0), "<2 x i64>", "<4 x i32>");
        std::string c = tmp(), r = tmp();
        out_ << "  " << c << " = icmp slt <4 x i32> " << m << ", zeroinitializer\n";
        out_ << "  " << r << " = select <4 x i1> " << c << ", <4 x i32> " << b << ", <4 x i32> " << a << "\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }
    case ZYDIS_MNEMONIC_BLENDVPD: {
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128), m = load_xmm(0);
        std::string c = tmp(), r = tmp();
        out_ << "  " << c << " = icmp slt <2 x i64> " << m << ", zeroinitializer\n";
        out_ << "  " << r << " = select <2 x i1> " << c << ", <2 x i64> " << b << ", <2 x i64> " << a << "\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PBLENDVB: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<16 x i8>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<16 x i8>");
        std::string m = bitcast(load_xmm(0), "<2 x i64>", "<16 x i8>");
        std::string c = tmp(), r = tmp();
        out_ << "  " << c << " = icmp slt <16 x i8> " << m << ", zeroinitializer\n";
        out_ << "  " << r << " = select <16 x i1> " << c << ", <16 x i8> " << b << ", <16 x i8> " << a << "\n";
        write_xmm_op(di, 0, bitcast(r, "<16 x i8>", "<2 x i64>"), 128);
        return true;
    }

    case ZYDIS_MNEMONIC_PALIGNR: {
        uint8_t imm = (uint8_t)di.ops[2].imm.value.u;
        if (imm >= 32) {
            write_xmm_op(di, 0, "zeroinitializer", 128);
        } else {
            std::string hi = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<16 x i8>");
            std::string lo = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<16 x i8>");
            std::string cat = tmp(), r = tmp();
            out_ << "  " << cat << " = shufflevector <16 x i8> " << lo << ", <16 x i8> " << hi
                 << ", <32 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7, "
                    "i32 8, i32 9, i32 10, i32 11, i32 12, i32 13, i32 14, i32 15, "
                    "i32 16, i32 17, i32 18, i32 19, i32 20, i32 21, i32 22, i32 23, "
                    "i32 24, i32 25, i32 26, i32 27, i32 28, i32 29, i32 30, i32 31>\n";
            out_ << "  " << r << " = shufflevector <32 x i8> " << cat << ", <32 x i8> zeroinitializer, <16 x i32> <";
            for (int i = 0; i < 16; i++) {
                int idx = imm + i;
                out_ << (i ? ", " : "") << "i32 " << (idx < 32 ? idx : 32);
            }
            out_ << ">\n";
            write_xmm_op(di, 0, bitcast(r, "<16 x i8>", "<2 x i64>"), 128);
        }
        return true;
    }

    // ---- Packed Integer Add / Sub / Mul / HAdd ----
    case ZYDIS_MNEMONIC_PADDB: case ZYDIS_MNEMONIC_PADDW: case ZYDIS_MNEMONIC_PADDD: case ZYDIS_MNEMONIC_PADDQ:
    case ZYDIS_MNEMONIC_PSUBB: case ZYDIS_MNEMONIC_PSUBW: case ZYDIS_MNEMONIC_PSUBD: case ZYDIS_MNEMONIC_PSUBQ:
    case ZYDIS_MNEMONIC_PMULLW: case ZYDIS_MNEMONIC_PMULLD: {
        int ebits = (mn == ZYDIS_MNEMONIC_PADDB || mn == ZYDIS_MNEMONIC_PSUBB) ? 8 :
                    (mn == ZYDIS_MNEMONIC_PADDW || mn == ZYDIS_MNEMONIC_PSUBW || mn == ZYDIS_MNEMONIC_PMULLW) ? 16 :
                    (mn == ZYDIS_MNEMONIC_PADDD || mn == ZYDIS_MNEMONIC_PSUBD || mn == ZYDIS_MNEMONIC_PMULLD) ? 32 : 64;
        const char *op = (mn == ZYDIS_MNEMONIC_PMULLW || mn == ZYDIS_MNEMONIC_PMULLD) ? "mul" :
                         (mn == ZYDIS_MNEMONIC_PADDB || mn == ZYDIS_MNEMONIC_PADDW || mn == ZYDIS_MNEMONIC_PADDD || mn == ZYDIS_MNEMONIC_PADDQ) ? "add" : "sub";
        std::string vty = "<" + std::to_string(128 / ebits) + " x " + int_ty(ebits) + ">";
        std::string a = (ebits == 64) ? read_xmm_op(di, 0, 128) : bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", vty.c_str());
        std::string b = (ebits == 64) ? read_xmm_op(di, 1, 128) : bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", vty.c_str());
        std::string r = tmp();
        out_ << "  " << r << " = " << op << " " << vty << " " << a << ", " << b << "\n";
        write_xmm_op(di, 0, (ebits == 64) ? r : bitcast(r, vty.c_str(), "<2 x i64>"), 128);
        return true;
    }

    case ZYDIS_MNEMONIC_PMULUDQ: {
        std::string a = read_xmm_op(di, 0, 128), b = read_xmm_op(di, 1, 128);
        std::string ma = tmp(), mb = tmp(), r = tmp();
        out_ << "  " << ma << " = and <2 x i64> " << a << ", <i64 4294967295, i64 4294967295>\n";
        out_ << "  " << mb << " = and <2 x i64> " << b << ", <i64 4294967295, i64 4294967295>\n";
        out_ << "  " << r << " = mul <2 x i64> " << ma << ", " << mb << "\n";
        write_xmm_op(di, 0, r, 128);
        return true;
    }
    case ZYDIS_MNEMONIC_PHADDD: {
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<4 x i32>");
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", "<4 x i32>");
        std::string ev = tmp(), od = tmp(), r = tmp();
        out_ << "  " << ev << " = shufflevector <4 x i32> " << a << ", <4 x i32> " << b << ", <4 x i32> <i32 0, i32 2, i32 4, i32 6>\n";
        out_ << "  " << od << " = shufflevector <4 x i32> " << a << ", <4 x i32> " << b << ", <4 x i32> <i32 1, i32 3, i32 5, i32 7>\n";
        out_ << "  " << r << " = add <4 x i32> " << ev << ", " << od << "\n";
        write_xmm_op(di, 0, bitcast(r, "<4 x i32>", "<2 x i64>"), 128);
        return true;
    }

    // ---- Packed Integer Comparisons & Min/Max ----
    case ZYDIS_MNEMONIC_PCMPEQB: case ZYDIS_MNEMONIC_PCMPEQW: case ZYDIS_MNEMONIC_PCMPEQD: case ZYDIS_MNEMONIC_PCMPEQQ:
    case ZYDIS_MNEMONIC_PCMPGTB: case ZYDIS_MNEMONIC_PCMPGTW: case ZYDIS_MNEMONIC_PCMPGTD: case ZYDIS_MNEMONIC_PCMPGTQ: {
        int ebits = (mn == ZYDIS_MNEMONIC_PCMPEQB || mn == ZYDIS_MNEMONIC_PCMPGTB) ? 8 :
                    (mn == ZYDIS_MNEMONIC_PCMPEQW || mn == ZYDIS_MNEMONIC_PCMPGTW) ? 16 :
                    (mn == ZYDIS_MNEMONIC_PCMPEQD || mn == ZYDIS_MNEMONIC_PCMPGTD) ? 32 : 64;
        const char *pred = (mn == ZYDIS_MNEMONIC_PCMPEQB || mn == ZYDIS_MNEMONIC_PCMPEQW ||
                            mn == ZYDIS_MNEMONIC_PCMPEQD || mn == ZYDIS_MNEMONIC_PCMPEQQ) ? "eq" : "sgt";
        int lanes = 128 / ebits;
        std::string vty = "<" + std::to_string(lanes) + " x " + int_ty(ebits) + ">";
        std::string v1ty = "<" + std::to_string(lanes) + " x i1>";
        std::string a = (ebits == 64) ? read_xmm_op(di, 0, 128) : bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", vty.c_str());
        std::string b = (ebits == 64) ? read_xmm_op(di, 1, 128) : bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", vty.c_str());
        std::string c = tmp(), r = tmp();
        out_ << "  " << c << " = icmp " << pred << " " << vty << " " << a << ", " << b << "\n";
        out_ << "  " << r << " = sext " << v1ty << " " << c << " to " << vty << "\n";
        write_xmm_op(di, 0, (ebits == 64) ? r : bitcast(r, vty.c_str(), "<2 x i64>"), 128);
        return true;
    }

    case ZYDIS_MNEMONIC_PMINSB: case ZYDIS_MNEMONIC_PMINSW: case ZYDIS_MNEMONIC_PMINSD:
    case ZYDIS_MNEMONIC_PMAXSB: case ZYDIS_MNEMONIC_PMAXSW: case ZYDIS_MNEMONIC_PMAXSD:
    case ZYDIS_MNEMONIC_PMINUB: case ZYDIS_MNEMONIC_PMINUW: case ZYDIS_MNEMONIC_PMINUD:
    case ZYDIS_MNEMONIC_PMAXUB: case ZYDIS_MNEMONIC_PMAXUW: case ZYDIS_MNEMONIC_PMAXUD: {
        int ebits = (mn == ZYDIS_MNEMONIC_PMINSB || mn == ZYDIS_MNEMONIC_PMAXSB || mn == ZYDIS_MNEMONIC_PMINUB || mn == ZYDIS_MNEMONIC_PMAXUB) ? 8 :
                    (mn == ZYDIS_MNEMONIC_PMINSW || mn == ZYDIS_MNEMONIC_PMAXSW || mn == ZYDIS_MNEMONIC_PMINUW || mn == ZYDIS_MNEMONIC_PMAXUW) ? 16 : 32;
        bool is_signed = (mn == ZYDIS_MNEMONIC_PMINSB || mn == ZYDIS_MNEMONIC_PMINSW || mn == ZYDIS_MNEMONIC_PMINSD ||
                          mn == ZYDIS_MNEMONIC_PMAXSB || mn == ZYDIS_MNEMONIC_PMAXSW || mn == ZYDIS_MNEMONIC_PMAXSD);
        bool is_min = (mn == ZYDIS_MNEMONIC_PMINSB || mn == ZYDIS_MNEMONIC_PMINSW || mn == ZYDIS_MNEMONIC_PMINSD ||
                       mn == ZYDIS_MNEMONIC_PMINUB || mn == ZYDIS_MNEMONIC_PMINUW || mn == ZYDIS_MNEMONIC_PMINUD);
        const char *pred = is_signed ? (is_min ? "slt" : "sgt") : (is_min ? "ult" : "ugt");
        int lanes = 128 / ebits;
        std::string vty = "<" + std::to_string(lanes) + " x " + int_ty(ebits) + ">";
        std::string v1ty = "<" + std::to_string(lanes) + " x i1>";
        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", vty.c_str());
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", vty.c_str());
        std::string c = tmp(), r = tmp();
        out_ << "  " << c << " = icmp " << pred << " " << vty << " " << a << ", " << b << "\n";
        out_ << "  " << r << " = select " << v1ty << " " << c << ", " << vty << " " << a << ", " << vty << " " << b << "\n";
        write_xmm_op(di, 0, bitcast(r, vty.c_str(), "<2 x i64>"), 128);
        return true;
    }

    // ---- Packed Shifts ----
    case ZYDIS_MNEMONIC_PSLLW: case ZYDIS_MNEMONIC_PSLLD: case ZYDIS_MNEMONIC_PSLLQ:
    case ZYDIS_MNEMONIC_PSRLW: case ZYDIS_MNEMONIC_PSRLD: case ZYDIS_MNEMONIC_PSRLQ:
    case ZYDIS_MNEMONIC_PSRAW: case ZYDIS_MNEMONIC_PSRAD: {
        int ebits = (mn == ZYDIS_MNEMONIC_PSLLW || mn == ZYDIS_MNEMONIC_PSRLW || mn == ZYDIS_MNEMONIC_PSRAW) ? 16 :
                    (mn == ZYDIS_MNEMONIC_PSLLD || mn == ZYDIS_MNEMONIC_PSRLD || mn == ZYDIS_MNEMONIC_PSRAD) ? 32 : 64;
        bool is_arith = (mn == ZYDIS_MNEMONIC_PSRAW || mn == ZYDIS_MNEMONIC_PSRAD);
        const char *op = (mn == ZYDIS_MNEMONIC_PSLLW || mn == ZYDIS_MNEMONIC_PSLLD || mn == ZYDIS_MNEMONIC_PSLLQ) ? "shl" :
                         is_arith ? "ashr" : "lshr";
        int lanes = 128 / ebits;
        std::string ty = int_ty(ebits);
        std::string vty = "<" + std::to_string(lanes) + " x " + ty + ">";
        std::string a = (ebits == 64) ? read_xmm_op(di, 0, 128) : bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", vty.c_str());

        std::string cnt64;
        if (di.ops[1].type == ZYDIS_OPERAND_TYPE_IMMEDIATE) {
            cnt64 = std::to_string(di.ops[1].imm.value.u);
        } else {
            std::string cv = read_xmm_op(di, 1, 128);
            cnt64 = tmp();
            out_ << "  " << cnt64 << " = extractelement <2 x i64> " << cv << ", i32 0\n";
        }
        std::string oob = tmp(), clamped64 = tmp();
        out_ << "  " << oob << " = icmp uge i64 " << cnt64 << ", " << ebits << "\n";
        out_ << "  " << clamped64 << " = select i1 " << oob << ", i64 " << (ebits - 1) << ", i64 " << cnt64 << "\n";
        std::string clamped = clamped64;
        if (ebits < 64) {
            clamped = tmp();
            out_ << "  " << clamped << " = trunc i64 " << clamped64 << " to " << ty << "\n";
        }
        std::string sc_vec = splat_vec(ty.c_str(), lanes, clamped);
        std::string sh = tmp();
        out_ << "  " << sh << " = " << op << " " << vty << " " << a << ", " << sc_vec << "\n";
        std::string res = sh;
        if (!is_arith) {
            res = tmp();
            out_ << "  " << res << " = select i1 " << oob << ", " << vty << " zeroinitializer, " << vty << " " << sh << "\n";
        }
        write_xmm_op(di, 0, (ebits == 64) ? res : bitcast(res, vty.c_str(), "<2 x i64>"), 128);
        return true;
    }

    case ZYDIS_MNEMONIC_PSLLDQ:
    case ZYDIS_MNEMONIC_PSRLDQ: {
        uint8_t imm = (uint8_t)di.ops[1].imm.value.u;
        if (imm >= 16) {
            write_xmm_op(di, 0, "zeroinitializer", 128);
        } else {
            std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", "<16 x i8>"), r = tmp();
            out_ << "  " << r << " = shufflevector <16 x i8> " << a << ", <16 x i8> zeroinitializer, <16 x i32> <";
            for (int i = 0; i < 16; i++) {
                int idx = (mn == ZYDIS_MNEMONIC_PSLLDQ) ? (i - (int)imm) : (i + (int)imm);
                if (idx < 0 || idx >= 16) idx = 16; // zeroinitializer
                out_ << (i ? ", " : "") << "i32 " << idx;
            }
            out_ << ">\n";
            write_xmm_op(di, 0, bitcast(r, "<16 x i8>", "<2 x i64>"), 128);
        }
        return true;
    }

    // ---- SSE4.1 Zero/Sign Extend ----
    case ZYDIS_MNEMONIC_PMOVZXBW: case ZYDIS_MNEMONIC_PMOVZXBD: case ZYDIS_MNEMONIC_PMOVZXBQ:
    case ZYDIS_MNEMONIC_PMOVZXWD: case ZYDIS_MNEMONIC_PMOVZXWQ: case ZYDIS_MNEMONIC_PMOVZXDQ:
    case ZYDIS_MNEMONIC_PMOVSXBW: case ZYDIS_MNEMONIC_PMOVSXBD: case ZYDIS_MNEMONIC_PMOVSXBQ:
    case ZYDIS_MNEMONIC_PMOVSXWD: case ZYDIS_MNEMONIC_PMOVSXWQ: case ZYDIS_MNEMONIC_PMOVSXDQ: {
        bool is_sext = (mn == ZYDIS_MNEMONIC_PMOVSXBW || mn == ZYDIS_MNEMONIC_PMOVSXBD || mn == ZYDIS_MNEMONIC_PMOVSXBQ ||
                        mn == ZYDIS_MNEMONIC_PMOVSXWD || mn == ZYDIS_MNEMONIC_PMOVSXWQ || mn == ZYDIS_MNEMONIC_PMOVSXDQ);
        int sb = (mn == ZYDIS_MNEMONIC_PMOVZXBW || mn == ZYDIS_MNEMONIC_PMOVZXBD || mn == ZYDIS_MNEMONIC_PMOVZXBQ ||
                  mn == ZYDIS_MNEMONIC_PMOVSXBW || mn == ZYDIS_MNEMONIC_PMOVSXBD || mn == ZYDIS_MNEMONIC_PMOVSXBQ) ? 8 :
                 (mn == ZYDIS_MNEMONIC_PMOVZXWD || mn == ZYDIS_MNEMONIC_PMOVZXWQ ||
                  mn == ZYDIS_MNEMONIC_PMOVSXWD || mn == ZYDIS_MNEMONIC_PMOVSXWQ) ? 16 : 32;
        int db = (mn == ZYDIS_MNEMONIC_PMOVZXBW || mn == ZYDIS_MNEMONIC_PMOVSXBW) ? 16 :
                 (mn == ZYDIS_MNEMONIC_PMOVZXBD || mn == ZYDIS_MNEMONIC_PMOVZXWD ||
                  mn == ZYDIS_MNEMONIC_PMOVSXBD || mn == ZYDIS_MNEMONIC_PMOVSXWD) ? 32 : 64;
        int lanes = 128 / db;
        int mem_bits = lanes * sb; // exact memory width (16, 32, or 64)
        std::string full_svty = "<" + std::to_string(128 / sb) + " x " + int_ty(sb) + ">";
        std::string sub_svty  = "<" + std::to_string(lanes) + " x " + int_ty(sb) + ">";
        std::string dvty      = "<" + std::to_string(lanes) + " x " + int_ty(db) + ">";
        std::string s = bitcast(read_xmm_op(di, 1, mem_bits), "<2 x i64>", full_svty.c_str());
        std::string sub = tmp(), r = tmp();
        out_ << "  " << sub << " = shufflevector " << full_svty << " " << s << ", " << full_svty << " poison, <" << lanes << " x i32> <";
        for (int i = 0; i < lanes; i++) out_ << (i ? ", " : "") << "i32 " << i;
        out_ << ">\n";
        out_ << "  " << r << " = " << (is_sext ? "sext " : "zext ") << sub_svty << " " << sub << " to " << dvty << "\n";
        write_xmm_op(di, 0, (db == 64) ? r : bitcast(r, dvty.c_str(), "<2 x i64>"), 128);
        return true;
    }

    // ---- Saturating Packs ----
    case ZYDIS_MNEMONIC_PACKSSWB: case ZYDIS_MNEMONIC_PACKUSWB:
    case ZYDIS_MNEMONIC_PACKSSDW: case ZYDIS_MNEMONIC_PACKUSDW: {
        bool is_dw = (mn == ZYDIS_MNEMONIC_PACKSSDW || mn == ZYDIS_MNEMONIC_PACKUSDW);
        bool is_us = (mn == ZYDIS_MNEMONIC_PACKUSWB || mn == ZYDIS_MNEMONIC_PACKUSDW);
        int sb = is_dw ? 32 : 16;
        int db = is_dw ? 16 : 8;
        int in_lanes = 128 / sb;
        int out_lanes = 128 / db;
        std::string sty = int_ty(sb), dty = int_ty(db);
        std::string svty = "<" + std::to_string(in_lanes) + " x " + sty + ">";
        std::string cat_ty = "<" + std::to_string(out_lanes) + " x " + sty + ">";
        std::string dvty = "<" + std::to_string(out_lanes) + " x " + dty + ">";
        std::string v1ty = "<" + std::to_string(out_lanes) + " x i1>";

        std::string a = bitcast(read_xmm_op(di, 0, 128), "<2 x i64>", svty.c_str());
        std::string b = bitcast(read_xmm_op(di, 1, 128), "<2 x i64>", svty.c_str());
        std::string cat = tmp();
        out_ << "  " << cat << " = shufflevector " << svty << " " << a << ", " << svty << " " << b << ", <" << out_lanes << " x i32> <";
        for (int i = 0; i < out_lanes; i++) out_ << (i ? ", " : "") << "i32 " << i;
        out_ << ">\n";

        int64_t lo_c = is_us ? 0 : (is_dw ? -32768 : -128);
        int64_t hi_c = is_us ? (is_dw ? 65535 : 255) : (is_dw ? 32767 : 127);
        std::string lo_v = splat_vec(sty.c_str(), out_lanes, std::to_string(lo_c));
        std::string hi_v = splat_vec(sty.c_str(), out_lanes, std::to_string(hi_c));
        std::string c1 = tmp(), m1 = tmp(), c2 = tmp(), m2 = tmp(), r = tmp();
        out_ << "  " << c1 << " = icmp slt " << cat_ty << " " << cat << ", " << lo_v << "\n";
        out_ << "  " << m1 << " = select " << v1ty << " " << c1 << ", " << cat_ty << " " << lo_v << ", " << cat_ty << " " << cat << "\n";
        out_ << "  " << c2 << " = icmp sgt " << cat_ty << " " << m1 << ", " << hi_v << "\n";
        out_ << "  " << m2 << " = select " << v1ty << " " << c2 << ", " << cat_ty << " " << hi_v << ", " << cat_ty << " " << m1 << "\n";
        out_ << "  " << r << " = trunc " << cat_ty << " " << m2 << " to " << dvty << "\n";
        write_xmm_op(di, 0, bitcast(r, dvty.c_str(), "<2 x i64>"), 128);
        return true;
    }

    default:
        return false;
    }
}

} // namespace bo3

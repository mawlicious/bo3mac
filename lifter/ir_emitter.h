#pragma once
#include "cfg.h"
#include <cstdint>
#include <ostream>
#include <sstream>
#include <string>
#include <unordered_set>

namespace bo3 {

enum class CallConv {
    SupersetSysV, // Production BO3 mode: x0..x7 + v0..v7, return 3-vector HVA { <2 x i64>, <2 x i64>, <2 x i64> } in v0..v2
    FullState,    // Diff harness / full-state mode: void @fn(ptr %ctx)
};

enum class TsoMode {
    Relaxed, // Plain loads/stores (only LOCK/XCHG atomic)
    Strict,  // Acquire/release ordering on non-RO, potentially-shared scalar loads/stores
};

struct LiftOptions {
    CallConv cc = CallConv::SupersetSysV;
    TsoMode tso = TsoMode::Strict;
    bool full_flags_at_ret = false;
    bool emit_pc_comments = false;
    std::string target_cpu = "apple-m1"; // universal Apple Silicon baseline; build scripts pass host chip via --mcpu
};

struct LiftStats {
    uint64_t insns_lifted = 0;
    uint64_t insns_unsupported = 0;
    std::unordered_map<std::string, uint64_t> unsupported_mnemonics;
};

class IREmitter {
public:
    IREmitter(const MachOImage *img, const LiftOptions &opts);

    void emit_module_header(std::ostream &os);
    bool emit_function(const FunctionCFG &cfg, std::ostream &os, const std::string &override_name = "");
    void emit_module_decls(std::ostream &os);

    const LiftStats &stats() const { return stats_; }

    // Internal helpers shared between ir_emitter.cpp, ir_int.cpp, ir_sse.cpp
    std::string tmp();
    std::string fmt_va(uint64_t va) const;
    std::string func_symbol(uint64_t va) const;
    std::string stub_symbol(const std::string &macho_sym) const;
    static bool is_returns_twice_sym(const std::string &sym);

    // Register access (handles 64/32/16/8-low/8-high GPRs and 128-bit XMMs)
    static int zydis_gpr_index(ZydisRegister reg, int &bits, bool &high8);
    static int zydis_xmm_index(ZydisRegister reg);
    static const char *gpr_slot_name(int idx);
    static std::string int_ty(int bits);

    std::string load_gpr64(int idx);
    void store_gpr64(int idx, const std::string &val64);
    std::string read_reg(ZydisRegister reg, int bits, uint64_t next_va = 0);
    void write_reg(ZydisRegister reg, int bits, const std::string &val);

    std::string load_xmm(int idx);
    void store_xmm(int idx, const std::string &v2i64);

    // Effective address & memory access
    std::string calc_mem_addr(const DecodedInsn &di, const ZydisDecodedOperand &op, bool &is_stack, bool &is_ro, int access_bytes = 1);
    std::string emit_mem_load(const std::string &addr64, int bits, bool is_stack, bool is_ro, bool is_vec);
    void emit_mem_store(const std::string &addr64, int bits, const std::string &val, bool is_stack, bool is_vec);
    std::string emit_mem_load_vec128(const std::string &addr64);
    void emit_mem_store_vec128(const std::string &addr64, const std::string &v2i64);

    // Generic operand read/write
    std::string read_op(const DecodedInsn &di, int op_idx, int bits);
    void write_op(const DecodedInsn &di, int op_idx, int bits, const std::string &val);
    std::string read_xmm_op(const DecodedInsn &di, int op_idx, int mem_bits = 128);
    void write_xmm_op(const DecodedInsn &di, int op_idx, const std::string &v2i64, int mem_bits = 128);

    // Flags
    std::string load_flag(const char *name);
    void store_flag(const char *name, const std::string &i1_val);
    void emit_szp_flags(const std::string &res, int bits, uint32_t live);
    void emit_add_flags(const std::string &a, const std::string &b, const std::string &res, int bits, uint32_t live);
    void emit_sub_flags(const std::string &a, const std::string &b, const std::string &res, int bits, uint32_t live);
    void emit_adc_flags(const std::string &a, const std::string &b, const std::string &cin_i1, const std::string &res, int bits, uint32_t live);
    void emit_sbb_flags(const std::string &a, const std::string &b, const std::string &cin_i1, const std::string &res, int bits, uint32_t live);
    void emit_logic_flags(const std::string &res, int bits, uint32_t live);
    std::string eval_cc(ZydisMnemonic mn);

    // Stack push/pop
    bool implicit_stack_private(bool require_fp) const;
    void emit_push64(const std::string &val64);
    std::string emit_pop64(bool require_fp = false);

    // Instruction dispatchers (implemented in ir_int.cpp and ir_sse.cpp)
    bool lift_insn(const DecodedInsn &di, const FunctionCFG &cfg, bool &terminated);
    bool lift_int_insn(const DecodedInsn &di, const FunctionCFG &cfg, bool &terminated);
    bool lift_sse_insn(const DecodedInsn &di, const FunctionCFG &cfg);

    // Call & FullState spill/reload helpers
    void emit_spill_fullstate();
    void emit_reload_fullstate();
    void emit_guest_call(const std::string &callee_sym, uint64_t ret_va, bool is_tail, bool returns_twice = false);
    void emit_indirect_call(const std::string &target_va_val, uint64_t ret_va, bool is_tail);

    std::ostringstream out_;
    const MachOImage *img_ = nullptr;
    const FunctionCFG *cur_cfg_ = nullptr;
    LiftOptions opts_;
    LiftStats stats_;
    uint64_t next_id_ = 1;
    uint64_t cur_func_va_ = 0;

    std::unordered_set<std::string> extern_guest_funcs_;
    std::unordered_set<std::string> extern_stubs_;
    std::unordered_set<std::string> returns_twice_stubs_;
    std::unordered_set<std::string> intrinsics_;
    void need_intrinsic(const std::string &decl) { intrinsics_.insert(decl); }
};

} // namespace bo3

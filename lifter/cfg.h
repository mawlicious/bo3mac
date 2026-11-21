#pragma once
#include "macho_loader.h"
#include <Zydis.h>
#include <cstdint>
#include <map>
#include <unordered_map>
#include <vector>

namespace bo3 {

// Flag bitmask matching x86_64 RFLAGS positions we track
enum FlagBits : uint32_t {
    FL_NONE = 0,
    FL_CF   = 1u << 0,
    FL_PF   = 1u << 2,
    FL_AF   = 1u << 4,
    FL_ZF   = 1u << 6,
    FL_SF   = 1u << 7,
    FL_DF   = 1u << 10,
    FL_OF   = 1u << 11,
    FL_ALL6 = FL_CF | FL_PF | FL_AF | FL_ZF | FL_SF | FL_OF,
};

struct DecodedInsn {
    uint64_t va = 0;
    ZydisDecodedInstruction ins;
    ZydisDecodedOperand ops[ZYDIS_MAX_OPERAND_COUNT];
    uint32_t live_flags_out = FL_ALL6; // flags live AFTER this instruction
    bool is_switch_jmp = false;
    std::vector<uint64_t> switch_targets;
};

struct BasicBlock {
    uint64_t start_va = 0;
    uint64_t end_va = 0;
    std::vector<DecodedInsn> insns;
    std::vector<uint64_t> succs; // intra-function successor block VAs
    uint32_t live_flags_in = 0;
    uint32_t live_flags_out = 0;
};

struct FunctionCFG {
    uint64_t start_va = 0;
    uint64_t end_va = 0;
    std::map<uint64_t, BasicBlock> blocks;
    std::vector<uint64_t> direct_callees;
    std::vector<std::string> stub_callees;
    bool has_decode_error = false;
    bool uses_indirect_call = false;
    bool uses_indirect_jmp = false;
    bool has_frame_pointer = false; // true only if prologue does push rbp; mov rbp, rsp
    bool stack_escapes = false;     // true if any lea/mov takes an rsp/rbp address
};

// Decode & build CFG for a function from a MachOImage (or raw bytes for unit/diff tests)
bool build_function_cfg(const MachOImage &img, uint64_t func_va, FunctionCFG &out, bool full_flags_at_ret = false);
bool build_raw_cfg(const uint8_t *bytes, size_t len, uint64_t base_va, FunctionCFG &out, bool full_flags_at_ret = false);

// Helper: extract Zydis flag read/write bitmasks
void zydis_flag_rw(const ZydisDecodedInstruction &ins, uint32_t &read_mask, uint32_t &write_mask);

} // namespace bo3

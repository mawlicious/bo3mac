#include "cfg.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <queue>
#include <set>
#include <unordered_set>

namespace bo3 {

static uint32_t map_zydis_flags(ZydisAccessedFlagsMask zf) {
    uint32_t m = 0;
    if (zf & ZYDIS_CPUFLAG_CF) m |= FL_CF;
    if (zf & ZYDIS_CPUFLAG_PF) m |= FL_PF;
    if (zf & ZYDIS_CPUFLAG_AF) m |= FL_AF;
    if (zf & ZYDIS_CPUFLAG_ZF) m |= FL_ZF;
    if (zf & ZYDIS_CPUFLAG_SF) m |= FL_SF;
    if (zf & ZYDIS_CPUFLAG_DF) m |= FL_DF;
    if (zf & ZYDIS_CPUFLAG_OF) m |= FL_OF;
    return m;
}

void zydis_flag_rw(const ZydisDecodedInstruction &ins, uint32_t &read_mask, uint32_t &write_mask) {
    read_mask = 0;
    write_mask = 0;
    if (!ins.cpu_flags) return;
    read_mask = map_zydis_flags(ins.cpu_flags->tested);
    ZydisAccessedFlagsMask w = ins.cpu_flags->modified | ins.cpu_flags->set_0 |
                               ins.cpu_flags->set_1 | ins.cpu_flags->undefined;
    write_mask = map_zydis_flags(w);

    switch (ins.mnemonic) {
        case ZYDIS_MNEMONIC_SHL: case ZYDIS_MNEMONIC_SHR: case ZYDIS_MNEMONIC_SAR:
        case ZYDIS_MNEMONIC_ROL: case ZYDIS_MNEMONIC_ROR:
        case ZYDIS_MNEMONIC_RCL: case ZYDIS_MNEMONIC_RCR:
        case ZYDIS_MNEMONIC_SHLD: case ZYDIS_MNEMONIC_SHRD:
            write_mask = 0;
            break;
        default:
            break;
    }

    if (ins.meta.category == ZYDIS_CATEGORY_STRINGOP &&
        (ins.attributes & (ZYDIS_ATTRIB_HAS_REP | ZYDIS_ATTRIB_HAS_REPE | ZYDIS_ATTRIB_HAS_REPNE))) {
        write_mask = 0;
    }
}

static bool is_cond_branch(ZydisMnemonic m) {
    switch (m) {
        case ZYDIS_MNEMONIC_JB: case ZYDIS_MNEMONIC_JBE: case ZYDIS_MNEMONIC_JCXZ:
        case ZYDIS_MNEMONIC_JECXZ: case ZYDIS_MNEMONIC_JRCXZ: case ZYDIS_MNEMONIC_JL:
        case ZYDIS_MNEMONIC_JLE: case ZYDIS_MNEMONIC_JNB: case ZYDIS_MNEMONIC_JNBE:
        case ZYDIS_MNEMONIC_JNL: case ZYDIS_MNEMONIC_JNLE: case ZYDIS_MNEMONIC_JNO:
        case ZYDIS_MNEMONIC_JNP: case ZYDIS_MNEMONIC_JNS: case ZYDIS_MNEMONIC_JNZ:
        case ZYDIS_MNEMONIC_JO: case ZYDIS_MNEMONIC_JP: case ZYDIS_MNEMONIC_JS:
        case ZYDIS_MNEMONIC_JZ:
        case ZYDIS_MNEMONIC_LOOP: case ZYDIS_MNEMONIC_LOOPE: case ZYDIS_MNEMONIC_LOOPNE:
            return true;
        default:
            return false;
    }
}

static bool is_block_terminator(const DecodedInsn &di) {
    ZydisMnemonic m = di.ins.mnemonic;
    if (m == ZYDIS_MNEMONIC_RET || m == ZYDIS_MNEMONIC_JMP ||
        m == ZYDIS_MNEMONIC_UD2 || m == ZYDIS_MNEMONIC_INT3 ||
        m == ZYDIS_MNEMONIC_HLT || m == ZYDIS_MNEMONIC_OUT ||
        m == ZYDIS_MNEMONIC_STI || m == ZYDIS_MNEMONIC_CLI) {
        return true;
    }
    return is_cond_branch(m);
}

static bool compute_direct_branch_target(const DecodedInsn &di, uint64_t &target_out) {
    if (di.ins.operand_count_visible < 1) return false;
    if (di.ops[0].type != ZYDIS_OPERAND_TYPE_IMMEDIATE) return false;
    ZyanU64 abs_addr = 0;
    if (ZYAN_SUCCESS(ZydisCalcAbsoluteAddress(&di.ins, &di.ops[0], di.va, &abs_addr))) {
        target_out = (uint64_t)abs_addr;
        return true;
    }
    return false;
}

static int canon_gpr64(ZydisRegister r) {
    switch (r) {
        case ZYDIS_REGISTER_RAX: case ZYDIS_REGISTER_EAX: return 0;
        case ZYDIS_REGISTER_RCX: case ZYDIS_REGISTER_ECX: return 1;
        case ZYDIS_REGISTER_RDX: case ZYDIS_REGISTER_EDX: return 2;
        case ZYDIS_REGISTER_RBX: case ZYDIS_REGISTER_EBX: return 3;
        case ZYDIS_REGISTER_RSP: case ZYDIS_REGISTER_ESP: return 4;
        case ZYDIS_REGISTER_RBP: case ZYDIS_REGISTER_EBP: return 5;
        case ZYDIS_REGISTER_RSI: case ZYDIS_REGISTER_ESI: return 6;
        case ZYDIS_REGISTER_RDI: case ZYDIS_REGISTER_EDI: return 7;
        case ZYDIS_REGISTER_R8:  case ZYDIS_REGISTER_R8D: return 8;
        case ZYDIS_REGISTER_R9:  case ZYDIS_REGISTER_R9D: return 9;
        case ZYDIS_REGISTER_R10: case ZYDIS_REGISTER_R10D: return 10;
        case ZYDIS_REGISTER_R11: case ZYDIS_REGISTER_R11D: return 11;
        case ZYDIS_REGISTER_R12: case ZYDIS_REGISTER_R12D: return 12;
        case ZYDIS_REGISTER_R13: case ZYDIS_REGISTER_R13D: return 13;
        case ZYDIS_REGISTER_R14: case ZYDIS_REGISTER_R14D: return 14;
        case ZYDIS_REGISTER_R15: case ZYDIS_REGISTER_R15D: return 15;
        default: return -1;
    }
}

static bool is_uncond_terminator(ZydisMnemonic m) {
    return m == ZYDIS_MNEMONIC_JMP || m == ZYDIS_MNEMONIC_RET ||
           m == ZYDIS_MNEMONIC_UD2 || m == ZYDIS_MNEMONIC_INT3 ||
           m == ZYDIS_MNEMONIC_HLT;
}

static bool is_sysv_caller_saved(int reg) {
    // rax=0, rcx=1, rdx=2, rsi=6, rdi=7, r8=8, r9=9, r10=10, r11=11
    return reg == 0 || reg == 1 || reg == 2 || reg == 6 || reg == 7 ||
           reg == 8 || reg == 9 || reg == 10 || reg == 11;
}

// Sound reaching-definition trace for Clang/LLVM jump-table indirect jumps:
//   lea rT, [rip + tbl_va]           (may precede cmp/ja bounds check!)
//   movsxd rX, dword ptr [rT + idx*4]
//   add rX, rT
//   jmp rX
static bool trace_switch_table_va(const std::vector<DecodedInsn> &insns, size_t jmp_idx,
                                  uint64_t func_start, uint64_t func_end,
                                  const std::unordered_map<uint64_t, DiceEntry> &dice_by_va,
                                  uint64_t &tbl_va_out) {
    const auto &jmp = insns[jmp_idx];
    if (jmp.ins.mnemonic != ZYDIS_MNEMONIC_JMP || jmp.ops[0].type != ZYDIS_OPERAND_TYPE_REGISTER) {
        return false;
    }
    int jmp_reg = canon_gpr64(jmp.ops[0].reg.value);
    if (jmp_reg < 0) return false;

    int tbl_reg = -1;
    int orig_tbl_reg = -1;
    size_t min_i = (jmp_idx > 64) ? (jmp_idx - 64) : 0;
    for (size_t i = jmp_idx; i-- > min_i; ) {
        const auto &di = insns[i];
        if (is_uncond_terminator(di.ins.mnemonic)) {
            break; // never trace backward across an unrelated basic block boundary!
        }
        if (di.ins.mnemonic == ZYDIS_MNEMONIC_CALL) {
            int tracked = (tbl_reg >= 0) ? tbl_reg : jmp_reg;
            if (is_sysv_caller_saved(tracked)) break;
            continue;
        }
        if (tbl_reg < 0) {
            if (di.ins.mnemonic == ZYDIS_MNEMONIC_ADD &&
                di.ins.operand_count_visible >= 2 &&
                di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                di.ops[1].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                canon_gpr64(di.ops[0].reg.value) == jmp_reg) {
                int r1 = canon_gpr64(di.ops[1].reg.value);
                size_t min_j = (i > 8) ? (i - 8) : 0;
                for (size_t j = i; j-- > min_j; ) {
                    const auto &mj = insns[j];
                    if (is_uncond_terminator(mj.ins.mnemonic)) {
                        break;
                    }
                    if (mj.ins.mnemonic == ZYDIS_MNEMONIC_MOVSXD &&
                        mj.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                        mj.ops[1].type == ZYDIS_OPERAND_TYPE_MEMORY &&
                        mj.ops[1].mem.scale == 4) {
                        int mdst = canon_gpr64(mj.ops[0].reg.value);
                        int mbase = canon_gpr64(mj.ops[1].mem.base);
                        if ((mdst == jmp_reg && mbase == r1) || (mdst == r1 && mbase == jmp_reg)) {
                            tbl_reg = mbase;
                            orig_tbl_reg = mbase;
                            break;
                        }
                    }
                    if (mj.ins.operand_count_visible >= 1 &&
                        mj.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                        (mj.ops[0].actions & ZYDIS_OPERAND_ACTION_WRITE) &&
                        canon_gpr64(mj.ops[0].reg.value) == jmp_reg &&
                        mj.ins.mnemonic != ZYDIS_MNEMONIC_MOVSXD) {
                        break;
                    }
                }
                if (tbl_reg < 0) return false;
            } else if (di.ins.mnemonic == ZYDIS_MNEMONIC_MOV &&
                       di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                       di.ops[1].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                       canon_gpr64(di.ops[0].reg.value) == jmp_reg) {
                jmp_reg = canon_gpr64(di.ops[1].reg.value);
            } else if (di.ins.operand_count_visible >= 1 &&
                       di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                       (di.ops[0].actions & ZYDIS_OPERAND_ACTION_WRITE) &&
                       canon_gpr64(di.ops[0].reg.value) == jmp_reg) {
                return false;
            }
        } else {
            if (di.ins.mnemonic == ZYDIS_MNEMONIC_LEA &&
                di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                canon_gpr64(di.ops[0].reg.value) == tbl_reg &&
                di.ops[1].type == ZYDIS_OPERAND_TYPE_MEMORY &&
                di.ops[1].mem.base == ZYDIS_REGISTER_RIP) {
                ZyanU64 va = 0;
                if (ZYAN_SUCCESS(ZydisCalcAbsoluteAddress(&di.ins, &di.ops[1], di.va, &va))) {
                    tbl_va_out = (uint64_t)va;
                    return true;
                }
                return false;
            }
            if (di.ins.mnemonic == ZYDIS_MNEMONIC_MOV &&
                di.ins.operand_count_visible >= 2 &&
                di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                di.ops[1].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                canon_gpr64(di.ops[0].reg.value) == tbl_reg) {
                tbl_reg = canon_gpr64(di.ops[1].reg.value);
                continue;
            }
            if (di.ins.operand_count_visible >= 1 &&
                di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                (di.ops[0].actions & ZYDIS_OPERAND_ACTION_WRITE) &&
                canon_gpr64(di.ops[0].reg.value) == tbl_reg) {
                break; // fall through to LICM hoisted-LEA scan below!
            }
        }
    }

    // Fallback for LICM-hoisted jump-table base registers (e.g., `lea r13, [rip + tbl]` hoisted before loop):
    // Keep any same-block `mov` rename (`tbl_reg`), preferring a unique match or the closest preceding LEA
    // (`di.va < jmp.va`) when a function has multiple switches reusing the same base register!
    if (tbl_reg >= 0 || orig_tbl_reg >= 0) {
        int search_reg = (tbl_reg >= 0) ? tbl_reg : orig_tbl_reg;
        uint64_t candidate = 0;
        int cand_count = 0;
        uint64_t best_prev_va = 0;
        uint64_t best_prev_tbl = 0;
        for (size_t i = 0; i < insns.size(); i++) {
            const auto &di = insns[i];
            if (di.ins.mnemonic == ZYDIS_MNEMONIC_LEA &&
                di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                canon_gpr64(di.ops[0].reg.value) == search_reg &&
                di.ops[1].type == ZYDIS_OPERAND_TYPE_MEMORY &&
                di.ops[1].mem.base == ZYDIS_REGISTER_RIP) {
                ZyanU64 va = 0;
                if (ZYAN_SUCCESS(ZydisCalcAbsoluteAddress(&di.ins, &di.ops[1], di.va, &va))) {
                    uint64_t v = (uint64_t)va;
                    if (dice_by_va.count(v) || (v > func_start && v < func_end)) {
                        if (v != candidate) { candidate = v; cand_count++; }
                        if (di.va < jmp.va && di.va >= best_prev_va) {
                            best_prev_va = di.va;
                            best_prev_tbl = v;
                        }
                    }
                }
            }
        }
        if (cand_count == 1) {
            tbl_va_out = candidate;
            return true;
        }
        if (cand_count > 1 && best_prev_tbl != 0) {
            tbl_va_out = best_prev_tbl;
            return true;
        }
        // If there is a unique DICE table in this function, match it
        if (cand_count == 0 && dice_by_va.size() == 1) {
            tbl_va_out = dice_by_va.begin()->first;
            return true;
        }
    }
    return false;
}

static bool decode_and_build(
    const uint8_t *code_base,
    size_t code_len,
    uint64_t func_start,
    uint64_t func_end,
    const MachOImage *img,
    FunctionCFG &out,
    bool full_flags_at_ret
) {
    out = FunctionCFG{};
    out.start_va = func_start;
    out.end_va = func_end;
    uint64_t max_va = func_start + code_len;
    if (func_end > max_va) func_end = max_va;
    if (func_start >= func_end) return false;

    ZydisDecoder dec;
    ZydisDecoderInit(&dec, ZYDIS_MACHINE_MODE_LONG_64, ZYDIS_STACK_WIDTH_64);

    // 1. Collect local DICE jump tables
    std::unordered_map<uint64_t, DiceEntry> dice_by_va;
    if (img) {
        for (const auto &de : img->dice_entries) {
            if (de.va >= func_start && de.va < func_end && de.kind == 4) {
                dice_by_va[de.va] = de;
            }
        }
    }

    // 2. Linear decode of non-DICE segments to establish exact valid instruction boundaries
    //    (also tracks earliest inline non-DICE jump table VA so table bytes are trimmed!)
    std::vector<DecodedInsn> all_insns;
    std::unordered_map<uint64_t, size_t> va_to_idx;
    std::set<uint64_t> inline_table_starts;
    bool saw_linear_decode_err = false;
    uint64_t decode_err_va = 0;

    uint64_t addr = func_start;
    while (addr < func_end) {
        if (img && img->is_dice(addr)) { addr++; continue; }
        uint64_t seg_end = addr;
        while (seg_end < func_end && !(img && img->is_dice(seg_end))) seg_end++;
        while (addr < seg_end) {
            size_t off = (size_t)(addr - func_start);
            if (off >= code_len) break;
            DecodedInsn di{};
            di.va = addr;
            ZyanStatus st = ZydisDecoderDecodeFull(&dec, code_base + off, (size_t)(seg_end - addr), &di.ins, di.ops);
            if (!ZYAN_SUCCESS(st)) {
                saw_linear_decode_err = true;
                decode_err_va = addr;
                break;
            }
            va_to_idx[addr] = all_insns.size();
            all_insns.push_back(di);
            addr += di.ins.length;
        }
        addr = seg_end;
    }

    if (all_insns.empty()) return false;

    // 3. Resolve switch jump tables (BOTH DICE kind-4 and non-DICE inline/__const tables!)
    //    using sound reaching-definition trace + exact instruction boundary validation!
    std::set<uint64_t> leaders;
    leaders.insert(func_start);
    std::vector<std::pair<uint64_t, uint64_t>> inline_table_ranges;

    if (img) {
        for (size_t i = 0; i < all_insns.size(); i++) {
            const auto &di = all_insns[i];
            if (di.ins.mnemonic == ZYDIS_MNEMONIC_JMP &&
                di.ins.operand_count_visible >= 1 &&
                di.ops[0].type != ZYDIS_OPERAND_TYPE_IMMEDIATE) {
                uint64_t tbl_va = 0;
                if (!trace_switch_table_va(all_insns, i, func_start, func_end, dice_by_va, tbl_va)) continue;

                std::vector<uint64_t> tgts;
                auto dit = dice_by_va.find(tbl_va);
                if (dit != dice_by_va.end()) {
                    size_t avail = 0;
                    const uint8_t *tptr = img->ptr_for_va(tbl_va, &avail);
                    if (tptr && avail >= dit->second.len) {
                        size_t n = dit->second.len / 4;
                        for (size_t k = 0; k < n; k++) {
                            int32_t rel = 0;
                            std::memcpy(&rel, tptr + k * 4, 4);
                            uint64_t tgt = tbl_va + (int64_t)rel;
                            if (va_to_idx.count(tgt)) tgts.push_back(tgt);
                        }
                    }
                } else if (tbl_va > func_start && tbl_va < func_end) {
                    // Non-DICE inline jump table at end of function (like 0x1004bf19c / 0x1004dde24!)
                    // Validate every target against exact instruction starts (`va_to_idx`) and `< tbl_va`!
                    size_t avail = 0;
                    const uint8_t *tptr = img->ptr_for_va(tbl_va, &avail);
                    uint64_t max_bytes = std::min<uint64_t>(avail, func_end - tbl_va);
                    size_t max_n = std::min<size_t>((size_t)(max_bytes / 4), 2048);
                    for (size_t k = 0; k < max_n; k++) {
                        int32_t rel = 0;
                        std::memcpy(&rel, tptr + k * 4, 4);
                        uint64_t tgt = tbl_va + (int64_t)rel;
                        if (tgt >= func_start && tgt < tbl_va && va_to_idx.count(tgt)) {
                            tgts.push_back(tgt);
                        } else {
                            break;
                        }
                    }
                    if (tgts.size() >= 2) {
                        inline_table_ranges.push_back({tbl_va, func_end});
                    } else {
                        tgts.clear();
                    }
                } else if (img->is_ro_va(tbl_va)) {
                    // Jump table in __TEXT,__const
                    size_t avail = 0;
                    const uint8_t *tptr = img->ptr_for_va(tbl_va, &avail);
                    size_t max_n = std::min<size_t>(avail / 4, 2048);
                    for (size_t k = 0; k < max_n; k++) {
                        int32_t rel = 0;
                        std::memcpy(&rel, tptr + k * 4, 4);
                        uint64_t tgt = tbl_va + (int64_t)rel;
                        if (va_to_idx.count(tgt)) tgts.push_back(tgt);
                        else break;
                    }
                    if (tgts.size() < 2) tgts.clear();
                }

                if (!tgts.empty()) {
                    all_insns[i].is_switch_jmp = true;
                    all_insns[i].switch_targets = tgts;
                    for (uint64_t t : tgts) leaders.insert(t);
                }
            }
        }
    }

    auto is_inline_table_va = [&](uint64_t va) -> bool {
        for (const auto &r : inline_table_ranges) {
            if (va >= r.first && va < r.second) return true;
        }
        return false;
    };

    // Trim any instructions mistakenly decoded inside discovered non-DICE inline jump tables!
    if (!inline_table_ranges.empty()) {
        std::vector<DecodedInsn> filtered;
        filtered.reserve(all_insns.size());
        va_to_idx.clear();
        for (auto &di : all_insns) {
            if (!is_inline_table_va(di.va)) {
                va_to_idx[di.va] = filtered.size();
                filtered.push_back(std::move(di));
            }
        }
        all_insns = std::move(filtered);
    }

    // Only flag decode error if it was NOT inside a discovered inline jump table!
    if (saw_linear_decode_err && !is_inline_table_va(decode_err_va)) {
        out.has_decode_error = true;
    }

    // 4. Identify all basic-block leaders, frame pointer, stack escape, & callees
    if (!all_insns.empty() &&
        all_insns[0].ins.mnemonic == ZYDIS_MNEMONIC_PUSH &&
        all_insns[0].ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
        all_insns[0].ops[0].reg.value == ZYDIS_REGISTER_RBP &&
        all_insns.size() >= 2 &&
        all_insns[1].ins.mnemonic == ZYDIS_MNEMONIC_MOV &&
        all_insns[1].ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
        all_insns[1].ops[0].reg.value == ZYDIS_REGISTER_RBP &&
        all_insns[1].ops[1].type == ZYDIS_OPERAND_TYPE_REGISTER &&
        all_insns[1].ops[1].reg.value == ZYDIS_REGISTER_RSP) {
        out.has_frame_pointer = true;
    }

    auto is_sp_reg = [](ZydisRegister r) {
        return r == ZYDIS_REGISTER_RSP || r == ZYDIS_REGISTER_ESP ||
               r == ZYDIS_REGISTER_SP  || r == ZYDIS_REGISTER_SPL;
    };
    auto is_bp_reg = [](ZydisRegister r) {
        return r == ZYDIS_REGISTER_RBP || r == ZYDIS_REGISTER_EBP ||
               r == ZYDIS_REGISTER_BP  || r == ZYDIS_REGISTER_BPL;
    };

    auto is_epilogue_tail = [&](size_t idx) -> bool {
        // Only allow a straight-line epilogue tail (POP non-SP/BP, ADD RSP imm, VZEROUPPER)
        // ending in RET or an EXTERNAL tail-call JMP (never an internal branch to another BB).
        for (size_t j = idx + 1; j < all_insns.size(); j++) {
            const auto &dj = all_insns[j];
            const ZydisMnemonic mj = dj.ins.mnemonic;
            if (mj == ZYDIS_MNEMONIC_RET) return true;
            if (mj == ZYDIS_MNEMONIC_JMP) {
                uint64_t tgt = 0;
                if (compute_direct_branch_target(dj, tgt) && va_to_idx.count(tgt)) return false;
                return true;
            }
            if (mj == ZYDIS_MNEMONIC_VZEROUPPER) continue;
            if (mj == ZYDIS_MNEMONIC_POP && dj.ins.operand_count_visible >= 1 &&
                dj.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                !is_sp_reg(dj.ops[0].reg.value) && !is_bp_reg(dj.ops[0].reg.value)) {
                continue;
            }
            if (mj == ZYDIS_MNEMONIC_ADD && dj.ins.operand_count_visible >= 2 &&
                dj.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                dj.ops[0].reg.value == ZYDIS_REGISTER_RSP &&
                dj.ops[1].type == ZYDIS_OPERAND_TYPE_IMMEDIATE) {
                continue;
            }
            return false;
        }
        return false;
    };

    for (size_t i = 0; i < all_insns.size(); i++) {
        const auto &di = all_insns[i];
        uint64_t next_va = di.va + di.ins.length;

        // Stack escape & unproven RSP/RBP modification check (strict TSO safety)
        const ZydisMnemonic mn = di.ins.mnemonic;
        if (mn == ZYDIS_MNEMONIC_LEA && di.ins.operand_count_visible >= 2 &&
            di.ops[1].type == ZYDIS_OPERAND_TYPE_MEMORY) {
            ZydisRegister b = di.ops[1].mem.base;
            ZydisRegister idx = di.ops[1].mem.index;
            ZydisRegister d = (di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER) ? di.ops[0].reg.value : ZYDIS_REGISTER_NONE;
            const bool reads_sp = is_sp_reg(b) || is_sp_reg(idx);
            const bool reads_fp = out.has_frame_pointer && (is_bp_reg(b) || is_bp_reg(idx));
            if ((reads_sp || reads_fp) && d != ZYDIS_REGISTER_RSP) {
                out.stack_escapes = true;
            }
            if (is_sp_reg(d)) {
                // Only `lea rsp, [rsp + disp]` or (with proven FP) `lea rsp, [rbp + disp]` preserves provenance.
                const bool safe_sp_lea = (d == ZYDIS_REGISTER_RSP) && (idx == ZYDIS_REGISTER_NONE) &&
                                         (b == ZYDIS_REGISTER_RSP || (out.has_frame_pointer && b == ZYDIS_REGISTER_RBP));
                if (!safe_sp_lea) out.stack_escapes = true;
            }
            if (out.has_frame_pointer && is_bp_reg(d)) {
                out.has_frame_pointer = false;
                out.stack_escapes = true;
            }
        } else if (mn == ZYDIS_MNEMONIC_MOV && di.ins.operand_count_visible >= 2) {
            ZydisRegister d = (di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER) ? di.ops[0].reg.value : ZYDIS_REGISTER_NONE;
            ZydisRegister s = (di.ops[1].type == ZYDIS_OPERAND_TYPE_REGISTER) ? di.ops[1].reg.value : ZYDIS_REGISTER_NONE;
            const bool is_prologue_fp = (out.has_frame_pointer && i == 1 &&
                                         d == ZYDIS_REGISTER_RBP && s == ZYDIS_REGISTER_RSP);
            if (is_sp_reg(s) && d != ZYDIS_REGISTER_RSP && !is_prologue_fp) out.stack_escapes = true;
            if (out.has_frame_pointer && is_bp_reg(s) && d != ZYDIS_REGISTER_RSP && d != ZYDIS_REGISTER_RBP) out.stack_escapes = true;
            if (is_sp_reg(d)) {
                const bool safe_sp_mov = (d == ZYDIS_REGISTER_RSP) &&
                                         (s == ZYDIS_REGISTER_RSP || (out.has_frame_pointer && s == ZYDIS_REGISTER_RBP));
                if (!safe_sp_mov) out.stack_escapes = true;
            }
            if (out.has_frame_pointer && is_bp_reg(d) && !is_prologue_fp) {
                out.has_frame_pointer = false;
                out.stack_escapes = true;
            }
        } else if (mn == ZYDIS_MNEMONIC_PUSH && di.ins.operand_count_visible >= 1 &&
                   di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER) {
            ZydisRegister s = di.ops[0].reg.value;
            if (is_sp_reg(s) || (out.has_frame_pointer && i > 0 && is_bp_reg(s))) out.stack_escapes = true;
        } else if (mn == ZYDIS_MNEMONIC_POP && di.ins.operand_count_visible >= 1 &&
                   di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER) {
            ZydisRegister d = di.ops[0].reg.value;
            if (is_sp_reg(d)) out.stack_escapes = true;
            if (out.has_frame_pointer && is_bp_reg(d)) {
                if (d != ZYDIS_REGISTER_RBP || !is_epilogue_tail(i)) {
                    out.has_frame_pointer = false;
                    out.stack_escapes = true;
                }
            }
        } else if (mn == ZYDIS_MNEMONIC_LEAVE) {
            // LEAVE assigns RSP = RBP and pops RBP; without a proven frame pointer OR if execution
            // continues past LEAVE (not an epilogue tail), RBP/RSP provenance is no longer guaranteed.
            if (!out.has_frame_pointer || !is_epilogue_tail(i)) {
                out.has_frame_pointer = false;
                out.stack_escapes = true;
            }
        } else {
            // Any other instruction modifying RSP (outside standard SUB/ADD/AND imm, PUSH, POP, CALL, RET),
            // modifying RBP, or reading RSP/RBP as a register operand (e.g. CMOV/XCHG/ADD reg, rsp)
            // invalidates stack provenance.
            const bool is_sp_imm_adj = (mn == ZYDIS_MNEMONIC_SUB || mn == ZYDIS_MNEMONIC_ADD || mn == ZYDIS_MNEMONIC_AND) &&
                                       di.ins.operand_count_visible >= 2 &&
                                       di.ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                                       di.ops[0].reg.value == ZYDIS_REGISTER_RSP &&
                                       di.ops[1].type == ZYDIS_OPERAND_TYPE_IMMEDIATE;
            const bool is_std_stack_op = (mn == ZYDIS_MNEMONIC_PUSH || mn == ZYDIS_MNEMONIC_POP ||
                                          mn == ZYDIS_MNEMONIC_CALL || mn == ZYDIS_MNEMONIC_RET);
            const bool is_flags_only = (mn == ZYDIS_MNEMONIC_CMP || mn == ZYDIS_MNEMONIC_TEST);
            for (int oi = 0; oi < di.ins.operand_count_visible; oi++) {
                const auto &op = di.ops[oi];
                if (op.type != ZYDIS_OPERAND_TYPE_REGISTER) continue;
                const bool writes = (op.actions & ZYDIS_OPERAND_ACTION_MASK_WRITE) != 0;
                const bool reads  = (op.actions & ZYDIS_OPERAND_ACTION_MASK_READ) != 0;
                ZydisRegister r = op.reg.value;
                if (writes && is_sp_reg(r)) {
                    if (!is_sp_imm_adj && !(is_std_stack_op && mn != ZYDIS_MNEMONIC_POP)) {
                        out.stack_escapes = true;
                    }
                }
                if (writes && out.has_frame_pointer && is_bp_reg(r)) {
                    out.has_frame_pointer = false;
                    out.stack_escapes = true;
                }
                if (reads && !is_sp_imm_adj && !is_std_stack_op && !is_flags_only &&
                    (is_sp_reg(r) || (out.has_frame_pointer && is_bp_reg(r)))) {
                    out.stack_escapes = true;
                }
            }
        }

        if (di.ins.mnemonic == ZYDIS_MNEMONIC_CALL) {
            uint64_t tgt = 0;
            if (compute_direct_branch_target(di, tgt)) {
                if (img && img->stub_to_internal_va.count(tgt)) out.direct_callees.push_back(img->stub_to_internal_va.at(tgt));
                else if (img && img->stub_to_sym.count(tgt)) out.stub_callees.push_back(img->stub_to_sym.at(tgt));
                else out.direct_callees.push_back(tgt);
            } else {
                out.uses_indirect_call = true;
            }
        } else if (is_cond_branch(di.ins.mnemonic)) {
            uint64_t tgt = 0;
            if (compute_direct_branch_target(di, tgt) && va_to_idx.count(tgt)) leaders.insert(tgt);
            if (va_to_idx.count(next_va)) leaders.insert(next_va);
        } else if (di.ins.mnemonic == ZYDIS_MNEMONIC_JMP) {
            uint64_t tgt = 0;
            if (compute_direct_branch_target(di, tgt)) {
                if (va_to_idx.count(tgt)) leaders.insert(tgt);
                else if (img && img->stub_to_internal_va.count(tgt)) out.direct_callees.push_back(img->stub_to_internal_va.at(tgt));
                else if (img && img->stub_to_sym.count(tgt)) out.stub_callees.push_back(img->stub_to_sym.at(tgt));
                else out.direct_callees.push_back(tgt);
            } else if (!di.is_switch_jmp) {
                out.uses_indirect_jmp = true;
            }
            if (va_to_idx.count(next_va)) leaders.insert(next_va);
        } else if (is_block_terminator(di)) {
            if (va_to_idx.count(next_va)) leaders.insert(next_va);
        }
    }

    // 5. Partition into basic blocks
    for (size_t i = 0; i < all_insns.size(); ) {
        uint64_t bb_start = all_insns[i].va;
        BasicBlock bb;
        bb.start_va = bb_start;
        while (i < all_insns.size()) {
            const auto &di = all_insns[i];
            if (di.va != bb_start && leaders.count(di.va)) break;
            bb.insns.push_back(di);
            bb.end_va = di.va + di.ins.length;
            i++;
            if (is_block_terminator(di)) break;
            if (i < all_insns.size() && all_insns[i].va != bb.end_va) break;
        }
        if (!bb.insns.empty()) {
            const auto &last = bb.insns.back();
            uint64_t fall = last.va + last.ins.length;
            if (is_cond_branch(last.ins.mnemonic)) {
                uint64_t tgt = 0;
                if (compute_direct_branch_target(last, tgt) && leaders.count(tgt)) bb.succs.push_back(tgt);
                if (leaders.count(fall)) bb.succs.push_back(fall);
            } else if (last.ins.mnemonic == ZYDIS_MNEMONIC_JMP) {
                if (last.is_switch_jmp) {
                    std::set<uint64_t> uniq(last.switch_targets.begin(), last.switch_targets.end());
                    for (uint64_t t : uniq) if (leaders.count(t)) bb.succs.push_back(t);
                } else {
                    uint64_t tgt = 0;
                    if (compute_direct_branch_target(last, tgt) && leaders.count(tgt)) bb.succs.push_back(tgt);
                }
            } else if (!is_block_terminator(last)) {
                if (leaders.count(fall)) bb.succs.push_back(fall);
            }
        }
        out.blocks[bb.start_va] = std::move(bb);
    }

    // 6. Monotone backward flag-liveness to TRUE fixed-point convergence
    std::unordered_map<uint64_t, uint32_t> bb_use, bb_def;
    for (const auto &[va, bb] : out.blocks) {
        uint32_t use = 0, def = 0;
        for (const auto &di : bb.insns) {
            uint32_t r = 0, w = 0;
            zydis_flag_rw(di.ins, r, w);
            use |= (r & ~def);
            def |= w;
        }
        bb_use[va] = use;
        bb_def[va] = def;
    }

    bool changed = true;
    while (changed) {
        changed = false;
        for (auto it = out.blocks.rbegin(); it != out.blocks.rend(); ++it) {
            auto &bb = it->second;
            uint32_t live_out = 0;
            if (!bb.insns.empty()) {
                const auto &last = bb.insns.back();
                if (full_flags_at_ret && last.ins.mnemonic == ZYDIS_MNEMONIC_RET) {
                    live_out = FL_ALL6;
                }
                if (last.ins.mnemonic == ZYDIS_MNEMONIC_JMP &&
                    last.ops[0].type != ZYDIS_OPERAND_TYPE_IMMEDIATE && !last.is_switch_jmp) {
                    live_out = FL_ALL6;
                }
            }
            for (uint64_t s : bb.succs) {
                auto sit = out.blocks.find(s);
                if (sit != out.blocks.end()) live_out |= sit->second.live_flags_in;
            }
            uint32_t live_in = bb_use[bb.start_va] | (live_out & ~bb_def[bb.start_va]);
            if (live_out != bb.live_flags_out || live_in != bb.live_flags_in) {
                bb.live_flags_out = live_out;
                bb.live_flags_in = live_in;
                changed = true;
            }
        }
    }

    for (auto &[va, bb] : out.blocks) {
        uint32_t live = bb.live_flags_out;
        for (auto it = bb.insns.rbegin(); it != bb.insns.rend(); ++it) {
            it->live_flags_out = live;
            uint32_t r = 0, w = 0;
            zydis_flag_rw(it->ins, r, w);
            live = r | (live & ~w);
        }
    }

    return true;
}

bool build_function_cfg(const MachOImage &img, uint64_t func_va, FunctionCFG &out, bool full_flags_at_ret) {
    uint64_t s = 0, e = 0;
    if (!img.find_func_bounds(func_va, s, e)) return false;
    size_t avail = 0;
    const uint8_t *ptr = img.ptr_for_va(s, &avail);
    if (!ptr) return false;
    return decode_and_build(ptr, std::min(avail, (size_t)(e - s)), s, e, &img, out, full_flags_at_ret);
}

bool build_raw_cfg(const uint8_t *bytes, size_t len, uint64_t base_va, FunctionCFG &out, bool full_flags_at_ret) {
    return decode_and_build(bytes, len, base_va, base_va + len, nullptr, out, full_flags_at_ret);
}

} // namespace bo3

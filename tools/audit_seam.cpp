#include "macho_loader.h"
#include "cfg.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 4) {
        std::fprintf(stderr, "Usage: %s <macho> <min_va> <max_va>\n", argv[0]);
        return 1;
    }
    bo3::MachOImage img;
    if (!img.load(argv[1])) return 1;
    uint64_t min_va = std::strtoull(argv[2], nullptr, 0);
    uint64_t max_va = std::strtoull(argv[3], nullptr, 0);

    std::map<std::string, uint64_t> stubs;
    std::map<uint64_t, uint64_t> below_min;
    std::map<uint64_t, uint64_t> non_func_start_in_range;
    uint64_t indirect_calls = 0, indirect_jmps = 0, switch_jmps = 0;

    for (uint64_t fva : img.func_starts) {
        if (fva < min_va || fva >= max_va) continue;
        bo3::FunctionCFG cfg;
        if (!bo3::build_function_cfg(img, fva, cfg, false)) continue;
        for (const auto &kv : cfg.blocks) {
            for (const auto &di : kv.second.insns) {
                auto mn = di.ins.mnemonic;
                if (mn == ZYDIS_MNEMONIC_CALL || mn == ZYDIS_MNEMONIC_JMP ||
                    di.ins.meta.branch_type == ZYDIS_BRANCH_TYPE_SHORT ||
                    di.ins.meta.branch_type == ZYDIS_BRANCH_TYPE_NEAR) {
                    if (mn == ZYDIS_MNEMONIC_RET) continue;
                    if (di.ops[0].type == ZYDIS_OPERAND_TYPE_IMMEDIATE) {
                        uint64_t tgt = di.va + di.ins.length + (uint64_t)(int64_t)di.ops[0].imm.value.s;
                        if (cfg.blocks.count(tgt) && mn != ZYDIS_MNEMONIC_CALL) continue;
                        if (img.stub_to_sym.count(tgt)) {
                            stubs[img.stub_to_sym.at(tgt)]++;
                        } else if (tgt < min_va || tgt >= max_va) {
                            below_min[tgt]++;
                        } else if (!img.func_start_set.count(tgt)) {
                            non_func_start_in_range[tgt]++;
                        }
                    } else if (mn == ZYDIS_MNEMONIC_CALL) {
                        if (di.ops[0].type == ZYDIS_OPERAND_TYPE_MEMORY && di.ops[0].mem.base == ZYDIS_REGISTER_RIP) {
                            uint64_t ea = di.va + di.ins.length + (uint64_t)(int64_t)di.ops[0].mem.disp.value;
                            if (img.got_to_sym.count(ea)) { stubs[img.got_to_sym.at(ea)]++; continue; }
                        }
                        indirect_calls++;
                    } else if (mn == ZYDIS_MNEMONIC_JMP) {
                        if (di.is_switch_jmp) switch_jmps++;
                        else indirect_jmps++;
                    }
                }
            }
        }
    }

    std::printf("=== CORE BO3 SEAM AUDIT [0x%llx, 0x%llx) ===\n", (unsigned long long)min_va, (unsigned long long)max_va);
    std::printf("External stubs: %zu unique\n", stubs.size());
    std::printf("Targets outside range (<0x%llx): %zu unique\n", (unsigned long long)min_va, below_min.size());
    std::printf("Non-func-start cross-function targets IN range: %zu unique\n", non_func_start_in_range.size());
    std::printf("Indirect calls: %llu, Switch jmps: %llu, Non-switch indirect jmps: %llu\n",
           (unsigned long long)indirect_calls, (unsigned long long)switch_jmps, (unsigned long long)indirect_jmps);

    if (!non_func_start_in_range.empty()) {
        std::printf("\n--- NON-FUNC-START TARGETS IN RANGE (first 25) ---\n");
        int c = 0;
        for (const auto &kv : non_func_start_in_range) {
            std::printf("  0x%llx : %llu\n", (unsigned long long)kv.first, (unsigned long long)kv.second);
            if (++c >= 25) break;
        }
    }

    std::vector<std::pair<uint64_t, uint64_t>> bv;
    for (const auto &kv : below_min) bv.push_back({kv.second, kv.first});
    std::sort(bv.begin(), bv.end(), [](auto &a, auto &b){ return a.first > b.first; });
    std::printf("\n--- TOP 40 BELOW-CORE TARGETS (< 0x%llx) ---\n", (unsigned long long)min_va);
    for (size_t i = 0; i < bv.size() && i < 40; i++) {
        std::printf("  0x%llx : %llu\n", (unsigned long long)bv[i].second, (unsigned long long)bv[i].first);
    }

    std::vector<std::pair<uint64_t, std::string>> sv;
    for (const auto &kv : stubs) sv.push_back({kv.second, kv.first});
    std::sort(sv.begin(), sv.end(), [](auto &a, auto &b){ return a.first > b.first; });
    std::printf("\n--- ALL EXTERNAL STUBS (%zu) ---\n", sv.size());
    for (size_t i = 0; i < sv.size() && i < 60; i++) {
        std::printf("  %-58s : %llu\n", sv[i].second.c_str(), (unsigned long long)sv[i].first);
    }
    return 0;
}

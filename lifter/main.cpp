#include "macho_loader.h"
#include "cfg.h"
#include "ir_emitter.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

static void usage(const char *argv0) {
    std::fprintf(stderr,
        "Usage:\n"
        "  %s --coverage <macho> [--min-va 0x...] [--max-va 0x...]\n"
        "  %s --func <macho> <va_hex> [-o out.ll] [--cc sysv|full] [--tso strict|relaxed] [--mcpu <cpu>] [--full-flags] [--comments]\n"
        "  %s --raw <bin_file> <base_va_hex> <func_name> [-o out.ll] [--cc sysv|full] [--tso strict|relaxed] [--mcpu <cpu>] [--full-flags]\n"
        "  %s --shard <macho> <min_va_hex> <max_va_hex> <shard_idx> <num_shards> -o <out.ll> [--tso strict|relaxed] [--mcpu <cpu>]\n"
        "  --mcpu defaults to apple-m4.\n",
        argv0, argv0, argv0, argv0);
}

static uint64_t parse_hex(const char *s) {
    return std::strtoull(s, nullptr, 0);
}

int main(int argc, char **argv) {
    if (argc < 3) { usage(argv[0]); return 1; }

    std::string mode = argv[1];
    bo3::LiftOptions opts;
    std::string out_path;
    uint64_t min_va = 0x1004a0000ULL;
    uint64_t max_va = 0x1016263d8ULL;
    std::unordered_set<uint64_t> wrap_vas;

    auto parse_flags = [&](int start) -> bool {
        for (int i = start; i < argc; i++) {
            std::string a = argv[i];
            if (a == "-o" && i + 1 < argc) out_path = argv[++i];
            else if (a == "--min-va" && i + 1 < argc) min_va = parse_hex(argv[++i]);
            else if (a == "--max-va" && i + 1 < argc) max_va = parse_hex(argv[++i]);
            else if (a == "--wrap-va" && i + 1 < argc) wrap_vas.insert(parse_hex(argv[++i]));
            else if (a == "--cc" && i + 1 < argc) {
                std::string c = argv[++i];
                opts.cc = (c == "full") ? bo3::CallConv::FullState : bo3::CallConv::SupersetSysV;
            } else if (a == "--tso" && i + 1 < argc) {
                std::string t = argv[++i];
                opts.tso = (t == "relaxed") ? bo3::TsoMode::Relaxed : bo3::TsoMode::Strict;
            } else if (a == "--mcpu") {
                constexpr char cpu_chars[] = "abcdefghijklmnopqrstuvwxyz0123456789-_.";
                const std::string cpu = i + 1 < argc ? argv[++i] : "";
                // LLVM function attributes require a literal, lowercase CPU name.
                if (cpu.empty() || cpu == "native" || cpu.find_first_of("-_.") == 0 ||
                    cpu.find_first_not_of(cpu_chars) != std::string::npos) {
                    std::fprintf(stderr, "--mcpu requires a lowercase CPU name such as apple-m4\n");
                    return false;
                }
                opts.target_cpu = cpu;
            } else if (a == "--full-flags") {
                opts.full_flags_at_ret = true;
            } else if (a == "--comments") {
                opts.emit_pc_comments = true;
            }
        }
        return true;
    };

    if (mode == "--raw") {
        if (argc < 5) { usage(argv[0]); return 1; }
        std::string bin_path = argv[2];
        uint64_t base_va = parse_hex(argv[3]);
        std::string fn_name = argv[4];
        if (!parse_flags(5)) return 1;

        std::ifstream f(bin_path, std::ios::binary | std::ios::ate);
        if (!f) { std::fprintf(stderr, "Cannot open %s\n", bin_path.c_str()); return 1; }
        size_t sz = (size_t)f.tellg();
        f.seekg(0);
        std::vector<uint8_t> buf(sz);
        f.read((char *)buf.data(), (std::streamsize)sz);

        bo3::FunctionCFG cfg;
        if (!bo3::build_raw_cfg(buf.data(), buf.size(), base_va, cfg, opts.full_flags_at_ret)) {
            std::fprintf(stderr, "Failed to build CFG for raw bytes\n");
            return 1;
        }
        bo3::IREmitter em(nullptr, opts);
        std::ostringstream ss;
        em.emit_module_header(ss);
        em.emit_function(cfg, ss, fn_name);
        em.emit_module_decls(ss);

        if (em.stats().insns_unsupported > 0) {
            std::fprintf(stderr, "WARNING: %llu unsupported insns\n", (unsigned long long)em.stats().insns_unsupported);
            for (const auto &kv : em.stats().unsupported_mnemonics) {
                std::fprintf(stderr, "  %s: %llu\n", kv.first.c_str(), (unsigned long long)kv.second);
            }
        }
        if (out_path.empty()) {
            std::cout << ss.str();
        } else {
            std::ofstream of(out_path);
            of << ss.str();
        }
        return em.stats().insns_unsupported == 0 ? 0 : 2;
    }

    if (mode == "--func") {
        if (argc < 4) { usage(argv[0]); return 1; }
        std::string macho_path = argv[2];
        uint64_t va = parse_hex(argv[3]);
        if (!parse_flags(4)) return 1;

        bo3::MachOImage img;
        if (!img.load(macho_path)) { std::fprintf(stderr, "Failed to load %s\n", macho_path.c_str()); return 1; }

        bo3::FunctionCFG cfg;
        if (!bo3::build_function_cfg(img, va, cfg, opts.full_flags_at_ret)) {
            std::fprintf(stderr, "Failed to build CFG for 0x%llx\n", (unsigned long long)va);
            return 1;
        }
        bo3::IREmitter em(&img, opts);
        std::ostringstream ss;
        em.emit_module_header(ss);
        em.emit_function(cfg, ss);
        em.emit_module_decls(ss);

        if (out_path.empty()) {
            std::cout << ss.str();
        } else {
            std::ofstream of(out_path);
            of << ss.str();
        }
        std::fprintf(stderr, "Lifted 0x%llx: %zu blocks, %llu insns lifted, %llu unsupported\n",
            (unsigned long long)va, cfg.blocks.size(),
            (unsigned long long)em.stats().insns_lifted,
            (unsigned long long)em.stats().insns_unsupported);
        return em.stats().insns_unsupported == 0 ? 0 : 2;
    }

    if (mode == "--coverage") {
        std::string macho_path = argv[2];
        if (!parse_flags(3)) return 1;

        bo3::MachOImage img;
        if (!img.load(macho_path)) { std::fprintf(stderr, "Failed to load %s\n", macho_path.c_str()); return 1; }

        bo3::IREmitter em(&img, opts);
        std::ostringstream sink;
        uint64_t n_funcs = 0, n_cfg_err = 0, n_decode_err = 0;
        for (uint64_t fva : img.func_starts) {
            if (fva < min_va || fva >= max_va) continue;
            n_funcs++;
            bo3::FunctionCFG cfg;
            if (!bo3::build_function_cfg(img, fva, cfg, false)) {
                n_cfg_err++;
                continue;
            }
            if (cfg.has_decode_error) n_decode_err++;
            sink.str("");
            sink.clear();
            em.emit_function(cfg, sink);
        }
        const auto &st = em.stats();
        std::printf("Range [0x%llx, 0x%llx):\n", (unsigned long long)min_va, (unsigned long long)max_va);
        std::printf("  Functions:   %llu (cfg_err=%llu, decode_err=%llu)\n",
            (unsigned long long)n_funcs, (unsigned long long)n_cfg_err, (unsigned long long)n_decode_err);
        std::printf("  Lifted:      %llu instructions\n", (unsigned long long)st.insns_lifted);
        std::printf("  Unsupported: %llu instructions (%.6f%% coverage)\n",
            (unsigned long long)st.insns_unsupported,
            100.0 * (double)st.insns_lifted / (double)(st.insns_lifted + st.insns_unsupported + (st.insns_lifted + st.insns_unsupported == 0)));
        if (!st.unsupported_mnemonics.empty()) {
            std::vector<std::pair<uint64_t, std::string>> v;
            for (const auto &kv : st.unsupported_mnemonics) v.push_back({kv.second, kv.first});
            std::sort(v.begin(), v.end(), [](auto &a, auto &b) { return a.first > b.first; });
            std::printf("  Unsupported mnemonics (%zu):\n", v.size());
            for (const auto &p : v) {
                std::printf("    %-14s : %llu\n", p.second.c_str(), (unsigned long long)p.first);
            }
        }
        return (st.insns_unsupported == 0 && n_decode_err == 0 && n_cfg_err == 0) ? 0 : 2;
    }

    if (mode == "--shard") {
        if (argc < 7) { usage(argv[0]); return 1; }
        std::string macho_path = argv[2];
        min_va = parse_hex(argv[3]);
        max_va = parse_hex(argv[4]);
        int shard_idx = std::atoi(argv[5]);
        int num_shards = std::atoi(argv[6]);
        if (!parse_flags(7)) return 1;
        if (out_path.empty() || num_shards <= 0 || shard_idx < 0 || shard_idx >= num_shards) {
            usage(argv[0]);
            return 1;
        }

        bo3::MachOImage img;
        if (!img.load(macho_path)) { std::fprintf(stderr, "Failed to load %s\n", macho_path.c_str()); return 1; }

        // Balance shards by function code byte size (LPT greedy assignment) so no giant function stalls a shard!
        struct FuncWeight { uint64_t va; uint64_t bytes; };
        std::vector<FuncWeight> weighted;
        for (uint64_t fva : img.func_starts) {
            if (fva < min_va || fva >= max_va) continue;
            uint64_t s = 0, e = 0;
            uint64_t b = img.find_func_bounds(fva, s, e) ? (e - s) : 16;
            weighted.push_back({fva, b});
        }
        std::sort(weighted.begin(), weighted.end(), [](const FuncWeight &a, const FuncWeight &b) {
            return a.bytes > b.bytes;
        });
        std::vector<uint64_t> shard_load((size_t)num_shards, 0);
        std::vector<uint64_t> my_funcs;
        for (const auto &fw : weighted) {
            int best = 0;
            for (int k = 1; k < num_shards; k++) {
                if (shard_load[(size_t)k] < shard_load[(size_t)best]) best = k;
            }
            shard_load[(size_t)best] += fw.bytes;
            if (best == shard_idx) my_funcs.push_back(fw.va);
        }
        std::sort(my_funcs.begin(), my_funcs.end());

        bo3::IREmitter em(&img, opts);
        std::ostringstream body;
        std::unordered_set<std::string> defined_syms;
        for (uint64_t fva : my_funcs) {
            bo3::FunctionCFG cfg;
            if (!bo3::build_function_cfg(img, fva, cfg, false)) continue;
            if (wrap_vas.count(fva)) {
                std::string orig_name = "orig_g_" + em.fmt_va(fva);
                defined_syms.insert("@" + orig_name);
                em.emit_function(cfg, body, orig_name);
            } else {
                defined_syms.insert(em.func_symbol(fva));
                em.emit_function(cfg, body);
            }
        }
        for (const auto &ds : defined_syms) em.extern_guest_funcs_.erase(ds);

        std::ofstream of(out_path);
        if (!of) { std::fprintf(stderr, "Cannot write %s\n", out_path.c_str()); return 1; }
        em.emit_module_header(of);
        of << body.str();
        em.emit_module_decls(of);
        std::fprintf(stderr, "Shard %d/%d: %zu funcs (%llu bytes), %llu lifted, %llu unsupported -> %s\n",
            shard_idx, num_shards, my_funcs.size(),
            (unsigned long long)shard_load[(size_t)shard_idx],
            (unsigned long long)em.stats().insns_lifted,
            (unsigned long long)em.stats().insns_unsupported,
            out_path.c_str());
        return 0;
    }

    usage(argv[0]);
    return 1;
}

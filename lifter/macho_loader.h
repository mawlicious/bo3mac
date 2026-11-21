#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace bo3 {

struct MachOSection {
    std::string segname;
    std::string sectname;
    uint64_t addr = 0;
    uint64_t size = 0;
    uint32_t offset = 0;
    uint32_t flags = 0;
    uint32_t reserved2 = 0;
    bool is_zerofill = false;
};

struct DiceEntry {
    uint64_t va = 0;
    uint16_t len = 0;
    uint16_t kind = 0;
};

struct MachOImage {
    std::vector<uint8_t> raw;
    uint64_t image_base = 0; // __TEXT segment vmaddr (derived from LC_SEGMENT_64)
    uint64_t text_va = 0;
    uint64_t text_size = 0;
    uint32_t text_off = 0;

    uint64_t stubs_va = 0;
    uint64_t stubs_size = 0;
    uint64_t got_va = 0;
    uint64_t got_size = 0;
    uint64_t la_va = 0;
    uint64_t la_size = 0;
    uint64_t tlv_va = 0;
    uint64_t tlv_size = 0;
    uint64_t entry_va = 0;

    std::vector<MachOSection> sections;
    std::vector<std::pair<uint64_t, uint64_t>> ro_ranges; // derived from non-writable LC_SEGMENT_64s
    std::vector<uint64_t> func_starts;
    std::unordered_set<uint64_t> func_start_set;
    std::vector<DiceEntry> dice_entries;
    std::vector<uint8_t> is_dice_byte; // indexed by va - text_va

    // External indirect symbol resolution: stub VA or GOT VA -> external symbol name
    std::unordered_map<uint64_t, std::string> stub_to_sym;
    std::unordered_map<uint64_t, std::string> got_to_sym;
    // Internal weak/coalesced symbols defined inside __text (e.g. 203 Havok hkMapBase templates)
    std::unordered_map<uint64_t, uint64_t> stub_to_internal_va;
    std::unordered_map<uint64_t, uint64_t> got_to_internal_va;

    bool load(const std::string &path);

    bool is_in_text(uint64_t va) const {
        return va >= text_va && va < text_va + text_size;
    }
    bool is_dice(uint64_t va) const {
        if (!is_in_text(va)) return false;
        return is_dice_byte[va - text_va] != 0;
    }
    const uint8_t *ptr_for_va(uint64_t va, size_t *avail_out = nullptr) const;
    bool find_func_bounds(uint64_t va, uint64_t &start_out, uint64_t &end_out) const;
    bool is_ro_range(uint64_t va, uint64_t size) const {
        if (size == 0 || va + size < va) return false;
        for (const auto &r : ro_ranges) {
            if (va >= r.first && va + size <= r.second) return true;
        }
        return false;
    }
    bool is_ro_va(uint64_t va) const { return is_ro_range(va, 1); }
};

} // namespace bo3

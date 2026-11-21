#include "macho_loader.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

namespace bo3 {

static bool checked_range(size_t off, size_t len, size_t total) {
    return off <= total && len <= total - off;
}

static bool read_uleb128(const uint8_t *buf, size_t len, size_t &pos, uint64_t &out) {
    uint64_t val = 0;
    unsigned shift = 0;
    while (pos < len) {
        uint8_t b = buf[pos++];
        if (shift >= 64) return false;
        if (shift == 63 && (b & 0x7e)) return false;
        val |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) {
            out = val;
            return true;
        }
        shift += 7;
    }
    return false;
}

bool MachOImage::load(const std::string &path) {
    std::ifstream ifs(path, std::ios::binary | std::ios::ate);
    if (!ifs) {
        std::fprintf(stderr, "[macho] failed to open %s\n", path.c_str());
        return false;
    }
    std::streamoff sz_off = ifs.tellg();
    if (sz_off <= 0) return false;
    size_t fsz = (size_t)sz_off;
    raw.resize(fsz);
    ifs.seekg(0);
    ifs.read(reinterpret_cast<char *>(raw.data()), (std::streamsize)fsz);
    if (!ifs) return false;

    if (fsz < sizeof(mach_header_64)) return false;
    const auto *mh = reinterpret_cast<const mach_header_64 *>(raw.data());
    if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_X86_64) {
        std::fprintf(stderr, "[macho] unexpected magic/cputype\n");
        return false;
    }
    if (!checked_range(sizeof(mach_header_64), mh->sizeofcmds, fsz)) return false;

    uint32_t fs_off = 0, fs_sz = 0;
    uint32_t dice_off = 0, dice_sz = 0;
    uint32_t sym_off = 0, nsyms = 0, str_off = 0, str_sz = 0;
    uint32_t ind_off = 0, nind = 0;
    uint64_t entry_off = 0;
    bool has_entry = false;

    size_t off = sizeof(mach_header_64);
    size_t cmds_end = sizeof(mach_header_64) + mh->sizeofcmds;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (!checked_range(off, sizeof(load_command), cmds_end)) return false;
        const auto *lc = reinterpret_cast<const load_command *>(raw.data() + off);
        if (lc->cmdsize < sizeof(load_command) || !checked_range(off, lc->cmdsize, cmds_end)) return false;

        if (lc->cmd == LC_SEGMENT_64) {
            if (lc->cmdsize < sizeof(segment_command_64)) return false;
            const auto *seg = reinterpret_cast<const segment_command_64 *>(lc);
            size_t sects_bytes = (size_t)seg->nsects * sizeof(section_64);
            if (seg->nsects > (lc->cmdsize - sizeof(segment_command_64)) / sizeof(section_64)) return false;
            if (!checked_range(off + sizeof(segment_command_64), sects_bytes, cmds_end)) return false;

            std::string segname(seg->segname, strnlen(seg->segname, 16));
            if (segname == "__TEXT") {
                image_base = seg->vmaddr;
            }
            if ((seg->initprot & VM_PROT_READ) && !(seg->initprot & VM_PROT_WRITE) && seg->vmsize > 0) {
                ro_ranges.push_back({seg->vmaddr, seg->vmaddr + seg->vmsize});
            }

            const auto *sect = reinterpret_cast<const section_64 *>(
                raw.data() + off + sizeof(segment_command_64));
            for (uint32_t s = 0; s < seg->nsects; s++) {
                MachOSection ms;
                ms.segname = std::string(sect[s].segname, strnlen(sect[s].segname, 16));
                ms.sectname = std::string(sect[s].sectname, strnlen(sect[s].sectname, 16));
                ms.addr = sect[s].addr;
                ms.size = sect[s].size;
                ms.offset = sect[s].offset;
                ms.flags = sect[s].flags;
                ms.reserved2 = sect[s].reserved2;
                uint32_t stype = ms.flags & SECTION_TYPE;
                ms.is_zerofill = (stype == S_ZEROFILL || stype == S_GB_ZEROFILL || stype == S_THREAD_LOCAL_ZEROFILL);
                sections.push_back(ms);

                if (ms.segname == "__TEXT" && ms.sectname == "__text") {
                    text_va = ms.addr; text_size = ms.size; text_off = ms.offset;
                } else if (ms.segname == "__TEXT" && ms.sectname == "__stubs") {
                    stubs_va = ms.addr; stubs_size = ms.size;
                } else if (ms.segname == "__DATA" && ms.sectname == "__got") {
                    got_va = ms.addr; got_size = ms.size;
                } else if (ms.segname == "__DATA" && ms.sectname == "__la_symbol_ptr") {
                    la_va = ms.addr; la_size = ms.size;
                } else if (ms.segname == "__DATA" && ms.sectname == "__thread_vars") {
                    tlv_va = ms.addr; tlv_size = ms.size;
                }
            }
        } else if (lc->cmd == LC_FUNCTION_STARTS) {
            if (lc->cmdsize < sizeof(linkedit_data_command)) return false;
            const auto *ld = reinterpret_cast<const linkedit_data_command *>(lc);
            fs_off = ld->dataoff; fs_sz = ld->datasize;
        } else if (lc->cmd == LC_DATA_IN_CODE) {
            if (lc->cmdsize < sizeof(linkedit_data_command)) return false;
            const auto *ld = reinterpret_cast<const linkedit_data_command *>(lc);
            dice_off = ld->dataoff; dice_sz = ld->datasize;
        } else if (lc->cmd == LC_SYMTAB) {
            if (lc->cmdsize < sizeof(symtab_command)) return false;
            const auto *st = reinterpret_cast<const symtab_command *>(lc);
            sym_off = st->symoff; nsyms = st->nsyms;
            str_off = st->stroff; str_sz = st->strsize;
        } else if (lc->cmd == LC_DYSYMTAB) {
            if (lc->cmdsize < sizeof(dysymtab_command)) return false;
            const auto *ds = reinterpret_cast<const dysymtab_command *>(lc);
            ind_off = ds->indirectsymoff; nind = ds->nindirectsyms;
        } else if (lc->cmd == LC_MAIN) {
            if (lc->cmdsize < sizeof(entry_point_command)) return false;
            const auto *ep = reinterpret_cast<const entry_point_command *>(lc);
            entry_off = ep->entryoff;
            has_entry = true;
        }
        off += lc->cmdsize;
    }

    if (image_base == 0) image_base = 0x100000000ULL;
    if (has_entry) entry_va = image_base + entry_off;

    // Parse LC_FUNCTION_STARTS
    if (fs_off && fs_sz && checked_range(fs_off, fs_sz, fsz)) {
        size_t pos = 0;
        uint64_t cur = image_base;
        const uint8_t *buf = raw.data() + fs_off;
        while (pos < fs_sz) {
            uint64_t delta = 0;
            if (!read_uleb128(buf, fs_sz, pos, delta)) break;
            if (delta == 0) break;
            cur += delta;
            func_starts.push_back(cur);
            func_start_set.insert(cur);
        }
    }

    // Parse LC_DATA_IN_CODE
    is_dice_byte.assign(text_size, 0);
    if (dice_off && dice_sz && checked_range(dice_off, dice_sz, fsz)) {
        size_t nd = dice_sz / sizeof(data_in_code_entry);
        const auto *entries = reinterpret_cast<const data_in_code_entry *>(raw.data() + dice_off);
        dice_entries.reserve(nd);
        for (size_t i = 0; i < nd; i++) {
            DiceEntry de;
            de.va = image_base + entries[i].offset;
            de.len = entries[i].length;
            de.kind = entries[i].kind;
            dice_entries.push_back(de);
            if (de.va >= text_va && de.va + de.len <= text_va + text_size) {
                std::memset(is_dice_byte.data() + (de.va - text_va), 1, de.len);
            }
        }
    }

    // Resolve indirect symbols for __stubs and __got using LC_SYMTAB + LC_DYSYMTAB
    if (sym_off && ind_off && str_off &&
        checked_range(sym_off, (size_t)nsyms * sizeof(struct nlist_64), fsz) &&
        checked_range(ind_off, (size_t)nind * sizeof(uint32_t), fsz) &&
        checked_range(str_off, str_sz, fsz)) {
        const auto *syms = reinterpret_cast<const struct nlist_64 *>(raw.data() + sym_off);
        const auto *inds = reinterpret_cast<const uint32_t *>(raw.data() + ind_off);
        const char *strtab = reinterpret_cast<const char *>(raw.data() + str_off);

        auto get_sym_name = [&](uint32_t strx) -> std::string {
            if (strx >= str_sz) return "";
            size_t max_len = str_sz - strx;
            return std::string(strtab + strx, strnlen(strtab + strx, max_len));
        };

        off = sizeof(mach_header_64);
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            const auto *lc = reinterpret_cast<const load_command *>(raw.data() + off);
            if (lc->cmd == LC_SEGMENT_64) {
                const auto *seg = reinterpret_cast<const segment_command_64 *>(lc);
                const auto *sect = reinterpret_cast<const section_64 *>(
                    raw.data() + off + sizeof(segment_command_64));
                for (uint32_t s = 0; s < seg->nsects; s++) {
                    uint32_t stype = sect[s].flags & SECTION_TYPE;
                    uint32_t ind_idx = sect[s].reserved1;
                    if (stype == S_SYMBOL_STUBS && sect[s].reserved2 > 0) {
                        uint64_t stride = sect[s].reserved2;
                        uint64_t count = sect[s].size / stride;
                        for (uint64_t k = 0; k < count && ind_idx + k < nind; k++) {
                            uint32_t si = inds[ind_idx + k];
                            if (si < nsyms) {
                                uint64_t sva = sect[s].addr + k * stride;
                                // If symbol is defined inside our own __text (weak external C++ template like hkMapBase!),
                                // resolve directly to its internal VA instead of an external shim!
                                if ((syms[si].n_type & N_TYPE) == N_SECT &&
                                    syms[si].n_sect != NO_SECT &&
                                    is_in_text(syms[si].n_value) &&
                                    func_start_set.count(syms[si].n_value)) {
                                    stub_to_internal_va[sva] = syms[si].n_value;
                                } else {
                                    std::string name = get_sym_name(syms[si].n_un.n_strx);
                                    if (!name.empty()) stub_to_sym[sva] = std::move(name);
                                }
                            }
                        }
                    } else if (stype == S_NON_LAZY_SYMBOL_POINTERS || stype == S_LAZY_SYMBOL_POINTERS) {
                        uint64_t count = sect[s].size / 8;
                        for (uint64_t k = 0; k < count && ind_idx + k < nind; k++) {
                            uint32_t si = inds[ind_idx + k];
                            if (si < nsyms) {
                                uint64_t gva = sect[s].addr + k * 8;
                                if ((syms[si].n_type & N_TYPE) == N_SECT &&
                                    syms[si].n_sect != NO_SECT &&
                                    is_in_text(syms[si].n_value) &&
                                    func_start_set.count(syms[si].n_value)) {
                                    got_to_internal_va[gva] = syms[si].n_value;
                                } else {
                                    std::string name = get_sym_name(syms[si].n_un.n_strx);
                                    if (!name.empty()) got_to_sym[gva] = std::move(name);
                                }
                            }
                        }
                    }
                }
            }
            off += lc->cmdsize;
        }
    }

    return true;
}

const uint8_t *MachOImage::ptr_for_va(uint64_t va, size_t *avail_out) const {
    for (const auto &s : sections) {
        if (!s.is_zerofill && s.offset != 0 && va >= s.addr && va < s.addr + s.size) {
            uint64_t delta = va - s.addr;
            uint64_t file_off = (uint64_t)s.offset + delta;
            if (file_off >= raw.size()) break;
            size_t file_avail = raw.size() - (size_t)file_off;
            size_t sect_avail = (size_t)(s.size - delta);
            if (avail_out) *avail_out = std::min(file_avail, sect_avail);
            return raw.data() + file_off;
        }
    }
    if (avail_out) *avail_out = 0;
    return nullptr;
}

bool MachOImage::find_func_bounds(uint64_t va, uint64_t &start_out, uint64_t &end_out) const {
    auto it = std::upper_bound(func_starts.begin(), func_starts.end(), va);
    if (it == func_starts.begin()) return false;
    --it;
    start_out = *it;
    auto next_it = it + 1;
    end_out = (next_it != func_starts.end()) ? *next_it : (text_va + text_size);
    if (end_out > text_va + text_size) end_out = text_va + text_size;
    return va >= start_out && va < end_out;
}

} // namespace bo3

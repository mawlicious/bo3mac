// M0 Tool: Exact Zydis x86_64 mnemonic census of BO3 Engine (>= 0x100250000)
// Skips LC_DATA_IN_CODE (DICE_KIND_JUMP_TABLE32) and verifies clean CFG decoding.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <Zydis.h>

static uint64_t mn_counts[ZYDIS_MNEMONIC_MAX_VALUE + 1];
static uint64_t mn_counts_no_ffmpeg[ZYDIS_MNEMONIC_MAX_VALUE + 1];

typedef struct { ZydisMnemonic mn; uint64_t count; } Pair;
static int cmp_pair(const void *a, const void *b) {
    const Pair *x = (const Pair *)a, *y = (const Pair *)b;
    return (y->count > x->count) - (y->count < x->count);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s /path/to/CoDBlkOps3_Exe\n", argv[0]);
        return 1;
    }
    const char *path = argv[1];
    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen"); return 1; }
    fseek(f, 0, SEEK_END); size_t fsz = ftell(f);
    uint8_t *buf = malloc(fsz);
    fseek(f, 0, SEEK_SET); fread(buf, 1, fsz, f); fclose(f);

    // Parse LC_FUNCTION_STARTS
    size_t fs_off = 36959480, fs_sz = 86008;
    uint64_t *funcs = malloc(70000 * sizeof(uint64_t)); size_t nfuncs = 0;
    uint64_t cur = 0x100000000ULL; size_t i = fs_off;
    while (i < fs_off + fs_sz) {
        uint64_t val = 0; int shift = 0;
        while (i < fs_off + fs_sz) {
            uint8_t b = buf[i++];
            val |= (uint64_t)(b & 0x7f) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (val == 0) break;
        cur += val; funcs[nfuncs++] = cur;
    }

    // Parse LC_DATA_IN_CODE
    uint64_t text_va = 0x100002100ULL, text_sz = 0x016242d8ULL;
    uint64_t text_end = text_va + text_sz;
    size_t text_off = 8448;
    uint8_t *is_dice = calloc(text_sz, 1);
    size_t dice_off = 37045488, ndice = 8120 / 8;
    for (size_t d = 0; d < ndice; d++) {
        uint32_t doff = *(uint32_t*)(buf + dice_off + d*8);
        uint16_t dlen = *(uint16_t*)(buf + dice_off + d*8 + 4);
        uint64_t dva = 0x100000000ULL + doff;
        if (dva >= text_va && dva + dlen <= text_end)
            memset(is_dice + (dva - text_va), 1, dlen);
    }

    ZydisDecoder dec;
    ZydisDecoderInit(&dec, ZYDIS_MACHINE_MODE_LONG_64, ZYDIS_STACK_WIDTH_64);

    uint64_t total = 0, total_no_ff = 0, decode_err = 0;
    uint64_t split = 0x100250000ULL;
    uint64_t ffmpeg_end = 0x1004a0000ULL;

    for (size_t fi = 0; fi < nfuncs; fi++) {
        uint64_t s = funcs[fi];
        if (s < split || s >= text_end) continue;
        uint64_t e = (fi + 1 < nfuncs) ? funcs[fi + 1] : text_end;
        if (e > text_end) e = text_end;

        uint64_t addr = s;
        while (addr < e) {
            if (is_dice[addr - text_va]) { addr++; continue; }
            uint64_t seg_end = addr;
            while (seg_end < e && !is_dice[seg_end - text_va]) seg_end++;
            while (addr < seg_end) {
                ZydisDecodedInstruction ins;
                const uint8_t *p = buf + text_off + (addr - text_va);
                ZyanStatus st = ZydisDecoderDecodeInstruction(&dec, NULL, p, seg_end - addr, &ins);
                if (!ZYAN_SUCCESS(st)) {
                    decode_err++;
                    break; // likely inline non-DICE jump table in ffmpeg
                }
                mn_counts[ins.mnemonic]++;
                total++;
                if (addr >= ffmpeg_end) {
                    mn_counts_no_ffmpeg[ins.mnemonic]++;
                    total_no_ff++;
                }
                addr += ins.length;
            }
            addr = seg_end;
        }
    }

    Pair pairs[ZYDIS_MNEMONIC_MAX_VALUE + 1];
    int n_all = 0, n_noff = 0;
    for (int m = 0; m <= ZYDIS_MNEMONIC_MAX_VALUE; m++) {
        if (mn_counts[m]) pairs[n_all++] = (Pair){ (ZydisMnemonic)m, mn_counts[m] };
        if (mn_counts_no_ffmpeg[m]) n_noff++;
    }
    qsort(pairs, n_all, sizeof(Pair), cmp_pair);

    printf("Engine (>= +0x250000): %llu insns, %d unique Zydis mnemonics (decode stops: %llu)\n",
           total, n_all, decode_err);
    printf("Core BO3+Havok (>= +0x4a0000): %llu insns, %d unique Zydis mnemonics\n",
           total_no_ff, n_noff);

    // Dump all mnemonics in Core BO3+Havok (>= +0x4a0000) sorted by count!
    Pair pairs2[ZYDIS_MNEMONIC_MAX_VALUE + 1];
    int k2 = 0;
    for (int m = 0; m <= ZYDIS_MNEMONIC_MAX_VALUE; m++) {
        if (mn_counts_no_ffmpeg[m]) pairs2[k2++] = (Pair){ (ZydisMnemonic)m, mn_counts_no_ffmpeg[m] };
    }
    qsort(pairs2, k2, sizeof(Pair), cmp_pair);
    printf("\n=== ALL %d UNIQUE MNEMONICS IN CORE BO3+HAVOK (>= +0x4a0000) ===\n", k2);
    for (int k = 0; k < k2; k++) {
        printf("%s:%llu%s", ZydisMnemonicGetString(pairs2[k].mn), pairs2[k].count,
               ((k + 1) % 6 == 0 || k + 1 == k2) ? "\n" : "  ");
    }

    free(is_dice); free(funcs); free(buf);
    return 0;
}

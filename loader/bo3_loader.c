#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <spawn.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <CommonCrypto/CommonDigest.h>

#ifndef _POSIX_SPAWN_DISABLE_ASLR
#define _POSIX_SPAWN_DISABLE_ASLR 0x0100
#endif

extern char **environ;

// Reserve [0x100008000, 0x11a608000) in zerofill __DATA,__bss (0 bytes on disk!)
#define GUEST_WINDOW_BASE 0x100000000ULL
#define GUEST_WINDOW_END  0x11a600000ULL
#define GUEST_ARENA_SIZE  0x1a600000ULL

static uint8_t g_guest_arena[GUEST_ARENA_SIZE] __attribute__((aligned(16384)));

static void sha256_hex(const uint8_t *buf, size_t len, char out[65]) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(buf, (CC_LONG)len, digest);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        sprintf(out + i * 2, "%02x", digest[i]);
    }
    out[64] = '\0';
}

int main(int argc, char **argv) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    if (slide != 0) {
        if (getenv("BO3ARM_NO_REEXEC")) {
            fprintf(stderr, "[bo3_loader] FATAL: slide=0x%lx after re-exec!\n", (long)slide);
            return 2;
        }
        char self_path[4096];
        uint32_t sz = sizeof(self_path);
        if (_NSGetExecutablePath(self_path, &sz) != 0) {
            fprintf(stderr, "[bo3_loader] _NSGetExecutablePath failed\n");
            return 3;
        }
        setenv("BO3ARM_NO_REEXEC", "1", 1);
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC | _POSIX_SPAWN_DISABLE_ASLR);
        int rc = posix_spawn(NULL, self_path, NULL, &attr, argv, environ);
        fprintf(stderr, "[bo3_loader] posix_spawn SETEXEC failed: %d (%s)\n", rc, strerror(rc));
        return 4;
    }

    uintptr_t hdr = (uintptr_t)_dyld_get_image_header(0);
    uintptr_t arena_lo = (uintptr_t)g_guest_arena;
    uintptr_t arena_hi = arena_lo + sizeof(g_guest_arena);

    int translated = -1;
    size_t tsz = sizeof(translated);
    sysctlbyname("sysctl.proc_translated", &translated, &tsz, NULL, 0);

    printf("[bo3_loader] native arm64 (proc_translated=%d) header=0x%lx slide=0x%lx\n",
           translated, (unsigned long)hdr, (unsigned long)slide);
    printf("[bo3_loader] arena=[0x%lx, 0x%lx) (%.1f MiB)\n",
           (unsigned long)arena_lo, (unsigned long)arena_hi,
           (double)sizeof(g_guest_arena) / (1024.0 * 1024.0));

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <CoDBlkOps3_Exe> [dylib_path]\n", argv[0]);
        return 1;
    }

    const char *exe_path = argv[1];
    int fd = open(exe_path, O_RDONLY);
    if (fd < 0) { perror("open guest exe"); return 5; }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        fprintf(stderr, "[bo3_loader] invalid guest executable file\n");
        return 6;
    }
    const size_t file_sz = (size_t)st.st_size;
    uint8_t *filebuf = mmap(NULL, file_sz, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (filebuf == MAP_FAILED) { perror("mmap guest exe"); return 6; }

    // Parse Mach-O 64 segments
    const struct mach_header_64 *mh = (const struct mach_header_64 *)filebuf;
    if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_X86_64) {
        fprintf(stderr, "[bo3_loader] unexpected Mach-O magic/cpu\n");
        return 7;
    }
    if ((uint64_t)sizeof(struct mach_header_64) + (uint64_t)mh->sizeofcmds > (uint64_t)file_sz) {
        fprintf(stderr, "[bo3_loader] Mach-O load commands exceed file size\n");
        return 7;
    }

    const uint8_t *lc_ptr = filebuf + sizeof(struct mach_header_64);
    const uint8_t *lc_end = lc_ptr + mh->sizeofcmds;
    uintptr_t text_copy_lo = 0, text_copy_hi = 0;
    uint64_t text_file_off = 0;

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if ((size_t)(lc_end - lc_ptr) < sizeof(struct load_command)) {
            fprintf(stderr, "[bo3_loader] truncated Mach-O load command\n");
            return 7;
        }
        const struct load_command *lc = (const struct load_command *)lc_ptr;
        if (lc->cmdsize < sizeof(struct load_command) || (size_t)(lc_end - lc_ptr) < lc->cmdsize) {
            fprintf(stderr, "[bo3_loader] invalid Mach-O load command size\n");
            return 7;
        }
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__TEXT") == 0 || strcmp(seg->segname, "__DATA") == 0 ||
                strcmp(seg->segname, "__LINKEDIT") == 0) {
                if (seg->fileoff > (uint64_t)file_sz || seg->filesize > (uint64_t)file_sz - seg->fileoff) {
                    fprintf(stderr, "[bo3_loader] %s file range exceeds executable size\n", seg->segname);
                    return 8;
                }
                uintptr_t dst_start = (uintptr_t)seg->vmaddr;
                uint64_t src_off = seg->fileoff;
                uint64_t copy_len = seg->filesize;
                if (dst_start < arena_lo) {
                    uint64_t skip = arena_lo - dst_start;
                    printf("[bo3_loader] %s: skipping first 0x%llx bytes [0x%lx..0x%lx) occupied by loader\n",
                           seg->segname, skip, (unsigned long)dst_start, (unsigned long)arena_lo);
                    dst_start += skip;
                    src_off += skip;
                    copy_len = (copy_len > skip) ? (copy_len - skip) : 0;
                }
                if (dst_start < arena_lo || dst_start > arena_hi || copy_len > (uint64_t)(arena_hi - dst_start)) {
                    fprintf(stderr, "[bo3_loader] %s overflows arena!\n", seg->segname);
                    return 8;
                }
                if (copy_len > 0) {
                    memcpy((void *)dst_start, filebuf + src_off, (size_t)copy_len);
                }
                printf("[bo3_loader] mapped %-10s [0x%lx, 0x%lx) file_copied=0x%llx vmsize=0x%llx\n",
                       seg->segname, (unsigned long)dst_start, (unsigned long)(seg->vmaddr + seg->vmsize),
                       copy_len, seg->vmsize);
                if (strcmp(seg->segname, "__TEXT") == 0) {
                    text_copy_lo = dst_start;
                    text_copy_hi = (uintptr_t)(seg->vmaddr + seg->filesize);
                    text_file_off = src_off;
                }
            }
        }
        lc_ptr += lc->cmdsize;
    }
    if (text_copy_lo == 0 || text_copy_hi <= text_copy_lo) {
        fprintf(stderr, "[bo3_loader] missing valid __TEXT segment\n");
        return 7;
    }

    // Verify SHA-256 of loaded __TEXT [arena_lo, 0x101964000) against file
    // Note: 0x101965000 is not 16KB aligned (0x101964000..0x101968000 straddles __TEXT tail and __DATA start)
    uintptr_t ro_end = text_copy_hi & ~(uintptr_t)0x3fff; // 16KB floor = 0x101964000
    char h_mem[65], h_file[65];
    sha256_hex((const uint8_t *)text_copy_lo, ro_end - text_copy_lo, h_mem);
    sha256_hex(filebuf + text_file_off, ro_end - text_copy_lo, h_file);
    printf("[bo3_loader] __TEXT [0x%lx, 0x%lx) SHA256 match=%s (%s)\n",
           (unsigned long)text_copy_lo, (unsigned long)ro_end,
           strcmp(h_mem, h_file) == 0 ? "PASS" : "FAIL", h_mem);
    if (strcmp(h_mem, h_file) != 0) return 9;

    // Windows v100 cross-play: update the 6 FFOTD TU identifier strings ("tu30" -> "tu32") in
    // mapped __TEXT,__cstring before mprotect(..., PROT_READ). Validate all 6 before mutating any.
    // Also set SteamAppId / SteamGameId once while single-threaded (avoids concurrent setenv/getenv UB).
    const char *env_off = getenv("BO3ARM_OFFLINE");
    const char *env_xp  = getenv("BO3ARM_CROSSPLAY");
    bool is_offline = false;
    if (env_off && env_off[0]) {
        is_offline = (strcmp(env_off, "0") != 0);
    } else {
        // Respect offline=1 saved in ~/Library/Application Support/bo3mac/settings.ini (whitespace-trimmed)
        const char *home = getenv("HOME");
        if (home && home[0]) {
            char spath[1024];
            if (snprintf(spath, sizeof(spath), "%s/Library/Application Support/bo3mac/settings.ini", home) < (int)sizeof(spath)) {
                FILE *sf = fopen(spath, "r");
                if (sf) {
                    char line[512];
                    while (fgets(line, sizeof(line), sf)) {
                        char *p = line;
                        while (*p == ' ' || *p == '\t') p++;
                        if (*p == '\0' || *p == '#' || *p == '\n' || *p == '\r') continue;
                        char *eq = strchr(p, '=');
                        if (!eq) continue;
                        *eq = '\0';
                        char *ke = eq;
                        while (ke > p && (ke[-1] == ' ' || ke[-1] == '\t')) *--ke = '\0';
                        if (strcmp(p, "offline") != 0) continue;
                        char *v = eq + 1;
                        while (*v == ' ' || *v == '\t') v++;
                        size_t vl = strlen(v);
                        while (vl > 0 && (v[vl - 1] == '\n' || v[vl - 1] == '\r' || v[vl - 1] == ' ' || v[vl - 1] == '\t')) v[--vl] = '\0';
                        if (v[0]) is_offline = (strcmp(v, "0") != 0);
                    }
                    fclose(sf);
                }
            }
        }
    }
    // Check if the built dylib was compiled with --no-crossplay (.build_stamp alongside dylib)
    bool build_disables_xp = false;
    if (argc >= 3 && (!env_xp || !env_xp[0])) {
        const char *slash = strrchr(argv[2], '/');
        if (slash && (size_t)(slash - argv[2]) < 960) {
            char stamp_path[1024];
            snprintf(stamp_path, sizeof(stamp_path), "%.*s/.build_stamp", (int)(slash - argv[2]), argv[2]);
            FILE *bf = fopen(stamp_path, "r");
            if (bf) {
                char buf[256] = {0};
                if (fgets(buf, sizeof(buf), bf) && strstr(buf, "crossplay=0") != NULL) {
                    build_disables_xp = true;
                }
                fclose(bf);
            }
        }
        if (build_disables_xp) setenv("BO3ARM_CROSSPLAY", "0", 0);
    }
    if (!is_offline) {
        setenv("SteamAppId", "311210", 0);
        setenv("SteamGameId", "311210", 0);
    }
    bool enable_xp = !is_offline && !build_disables_xp && !(env_xp && strcmp(env_xp, "0") == 0);
    if (enable_xp) {
        static const uintptr_t kTu30Addrs[6] = {
            0x1016aa51cULL, // "ui.ffotd_tu30"
            0x1017251fcULL, // "_tu30"
            0x10172520eULL, // "%s%s_tu30_593.ff"
            0x10172529fULL, // "%s_tu30_593.ff"
            0x1017252aeULL, // "%s_tu30_593"
            0x1017252bcULL, // "%s%s_tu30_593"
        };
        size_t matched_tu = 0;
        for (size_t i = 0; i < sizeof(kTu30Addrs) / sizeof(kTu30Addrs[0]); i++) {
            uintptr_t va = kTu30Addrs[i];
            if (va >= text_copy_lo && va + 4 <= ro_end &&
                memcmp((const void *)va, "tu30", 4) == 0) {
                matched_tu++;
            }
        }
        if (matched_tu == sizeof(kTu30Addrs) / sizeof(kTu30Addrs[0])) {
            for (size_t i = 0; i < matched_tu; i++) {
                ((char *)kTu30Addrs[i])[3] = '2';
            }
            printf("[bo3_loader] Windows v100 cross-play FFOTD strings patched: %zu/6 (tu30 -> tu32)\n",
                   matched_tu);
        } else {
            fprintf(stderr, "[bo3_loader] WARNING: expected 6/6 tu30 strings, found %zu/6 — skipping TU32 patch\n",
                    matched_tu);
        }
    }

    // Protect __TEXT [arena_lo, ro_end) as PROT_READ (non-writable, NON-EXECUTABLE!)
    if (mprotect((void *)text_copy_lo, ro_end - text_copy_lo, PROT_READ) != 0) {
        perror("mprotect __TEXT RO");
        return 10;
    }
    printf("[bo3_loader] mprotect [0x%lx, 0x%lx) PROT_READ (NX) OK\n",
           (unsigned long)text_copy_lo, (unsigned long)ro_end);

    munmap(filebuf, (size_t)st.st_size);

    // Gate check: 10,000 mmap(NULL) and malloc() calls must NEVER overlap [0x100000000, 0x11a600000)
    int overlaps = 0;
    void *ptrs[256];
    for (int i = 0; i < 10000; i++) {
        void *p = mmap(NULL, 16384, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
        uintptr_t a = (uintptr_t)p;
        if (a < GUEST_WINDOW_END && a + 16384 > GUEST_WINDOW_BASE) overlaps++;
        munmap(p, 16384);
        if (i < 256) {
            ptrs[i] = malloc(4096);
            uintptr_t m = (uintptr_t)ptrs[i];
            if (m < GUEST_WINDOW_END && m + 4096 > GUEST_WINDOW_BASE) overlaps++;
        }
    }
    for (int i = 0; i < 256; i++) free(ptrs[i]);
    printf("[bo3_loader] 10,000 mmap + 256 malloc disjointness test: overlaps=%d (%s)\n",
           overlaps, overlaps == 0 ? "PASS" : "FAIL");
    if (overlaps != 0) return 11;

    // Load and execute libbo3_recomp.dylib (above the guest arena!)
    if (argc >= 3) {
        void *dl = dlopen(argv[2], RTLD_NOW);
        if (!dl) {
            fprintf(stderr, "[bo3_loader] dlopen failed: %s\n", dlerror());
            return 12;
        }
        typedef int (*entry_fn)(int, char **);
        entry_fn entry = (entry_fn)dlsym(dl, "bo3_recomp_entry");
        if (entry) {
            printf("[bo3_loader] dlopen %s OK: bo3_recomp_entry @ 0x%lx (above arena: %s)\n",
                   argv[2], (unsigned long)(uintptr_t)entry,
                   (uintptr_t)entry >= arena_hi ? "PASS" : "FAIL");
            if ((uintptr_t)entry < arena_hi) return 14;
            fflush(stdout);
            return entry(argc - 2, argv + 2);
        }
        typedef uintptr_t (*probe_fn)(void);
        probe_fn fn = (probe_fn)dlsym(dl, "bo3_recomp_probe");
        if (!fn) { fprintf(stderr, "[bo3_loader] dlsym failed\n"); return 13; }
        uintptr_t fn_addr = fn();
        printf("[bo3_loader] dlopen %s OK: bo3_recomp_probe @ 0x%lx (above arena: %s)\n",
               argv[2], (unsigned long)fn_addr, fn_addr >= arena_hi ? "PASS" : "FAIL");
        if (fn_addr < arena_hi) return 14;
    }
    return 0;
}

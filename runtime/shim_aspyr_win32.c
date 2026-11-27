// Aspyr Win32 OS Layer Shims: Virtual Memory, Handles (File/Event/Thread),
// File I/O & Enumeration, Modules, Winsock, Headless Windowing/Display/Input,
// and WinMM/COM Helpers.
// Strong definitions here override weak tracing stubs in gen_aspyr_weak.c.

#include "shim_helpers.h"
#include "../metal/window_mac.h"
#include "../metal/settings_mac.h"
#include "media_avf.h"
#include "audio_coreaudio.h"
#include "gamepad_mac.h"

extern uint64_t bo3_com_register_thunk(GuestFn fn, const char *name);
#include <ctype.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

extern void *bo3_alloc_thread_tlv(void);
extern void bo3_free_thread_tlv(void *tlv);
extern uint32_t *bo3_last_error_ptr(GuestContext *ctx);
extern void bo3_set_last_error(GuestContext *ctx, uint32_t err);
extern uint32_t bo3_alloc_tid(void);
extern uint32_t bo3_init_thread_tid(GuestContext *ctx, uint32_t forced_tid);

// =========================================================================
// 1. Path Normalization (Windows '\' -> POSIX '/', case-insensitive lookup)
// =========================================================================

extern int bo3_workshop_physics_dir(char *out, size_t out_sz);

// Returns 1 if the FIRST path component of `p` is `mods` or `usermaps` (case-insensitive).
static int bo3_is_usermod_path(const char *p) {
    if (!p || !p[0]) return 0;
    const char *s = p;
    while (*s == '/' || *s == '\\') s++;
    if (!*s) return 0;
    const char *end = s;
    while (*end && *end != '/' && *end != '\\') end++;
    size_t len = (size_t)(end - s);
    return (len == 4 && strncasecmp(s, "mods", 4) == 0) ||
           (len == 8 && strncasecmp(s, "usermaps", 8) == 0);
}

// Returns 1 if `p` starts with "C:\Emu\AppAssets" (case-insensitive, either slash).
static int bo3_has_appassets_prefix(const char *p) {
    if (!p) return 0;
    if ((p[0] != 'C' && p[0] != 'c') || p[1] != ':') return 0;
    if (p[2] != '\\' && p[2] != '/') return 0;
    if (strncasecmp(p + 3, "Emu", 3) != 0) return 0;
    if (p[6] != '\\' && p[6] != '/') return 0;
    if (strncasecmp(p + 7, "AppAssets", 9) != 0) return 0;
    char next = p[16];
    return next == '\0' || next == '/' || next == '\\';
}

static void bo3_normalize_path(const char *in, char *out, size_t out_sz) {
    if (!in || out_sz == 0) { if (out_sz) out[0] = 0; return; }
    // Skip leading "\\?\" if present
    if (in[0] == '\\' && in[1] == '\\' && in[2] == '?' && in[3] == '\\') in += 4;
    size_t j = 0;

    // Aspyr's C:\Emu\AppAssets (with either slash) represents the read-only Assets CWD.
    // External mods and custom maps (mods/, usermaps/) live in the Steam BO3 root (../../../).
    int handled_prefix = 0;
    if (bo3_has_appassets_prefix(in)) {
        in += 16;
        while (*in == '/' || *in == '\\') in++;
        if (bo3_is_usermod_path(in)) {
            j = strlcpy(out, "../../../", out_sz);
            if (j >= out_sz) j = out_sz - 1;
        } else if (*in == '\0') {
            strlcpy(out, ".", out_sz);
            return;
        }
        handled_prefix = 1;
    }

    // Also redirect <CWD>/mods and <CWD>/usermaps to the Steam BO3 game root (../../../).
    if (!handled_prefix && in[0] == '/') {
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd))) {
            size_t clen = strlen(cwd);
            if (clen > 1 && strncmp(in, cwd, clen) == 0 &&
                (in[clen] == '/' || in[clen] == '\\')) {
                const char *rest = in + clen;
                while (*rest == '/' || *rest == '\\') rest++;
                if (bo3_is_usermod_path(rest)) {
                    j = strlcpy(out, "../../../", out_sz);
                    if (j >= out_sz) j = out_sz - 1;
                    in = rest;
                    handled_prefix = 1;
                }
            }
        }
    }

    // Relative mods/... or usermaps/... (and Windows-rooted \mods\... / \usermaps\...)
    // resolve from the Steam BO3 game root (../../../).
    if (!handled_prefix && in[0] != '/' && in[0] != '.' &&
        !(isalpha((unsigned char)in[0]) && in[1] == ':') &&
        bo3_is_usermod_path(in)) {
        while (*in == '\\') in++;
        j = strlcpy(out, "../../../", out_sz);
        if (j >= out_sz) j = out_sz - 1;
        handled_prefix = 1;
    }

    // Other Windows drive prefixes (e.g. "C:\Emu\AppData\...") map to ~/Library/Application Support/Call of Duty Black Ops III/
    if (!handled_prefix && isalpha((unsigned char)in[0]) && in[1] == ':' &&
        (in[2] == '\\' || in[2] == '/' || in[2] == 0)) {
        const char *home = getenv("HOME");
        if (!home) home = "/tmp";
        char base[PATH_MAX];
        snprintf(base, sizeof(base), "%s/Library/Application Support/Call of Duty Black Ops III", home);
        mkdir(base, 0755);
        j = strlcpy(out, base, out_sz);
        if (j >= out_sz) j = out_sz - 1;
        in += 2;
        if (*in && *in != '\\' && *in != '/' && j + 1 < out_sz) out[j++] = '/';
    }
    for (size_t i = 0; in[i] && j + 1 < out_sz; i++) {
        char c = in[i];
        if (c == '\\') c = '/';
        // Collapse duplicate slashes except leading
        if (c == '/' && j > 0 && out[j - 1] == '/') continue;
        out[j++] = c;
    }
    out[j] = 0;
    // Strip trailing slash unless root "/"
    while (j > 1 && out[j - 1] == '/') out[--j] = 0;
}

// Redirect read-only Physics/<map>_navmesh.hkt and _navvolume.hkt lookups to our
// native Havok navigation cache (~/Library/Application Support/bo3mac/Physics/)
// when no stock macOS nav file exists (all custom maps) or for cp_mi_cairo_infection2.
// Called AFTER case-insensitive stock path resolution so existing stock files are never shadowed.
static int bo3_maybe_overlay_physics_path(char *out, size_t out_sz) {
    const char *p = out;
    if (p[0] == '.' && p[1] == '/') p += 2;

    const char *phys = NULL;
    if (strncasecmp(p, "Physics/", 8) == 0) {
        phys = p + 8;
    } else {
        const char *hit = strcasestr(p, "/Physics/");
        if (hit) phys = hit + 9;
    }
    if (!phys || !phys[0] || strchr(phys, '/') != NULL) return 0;

    size_t flen = strlen(phys);
    int is_nav = (flen > 12 && strcasecmp(phys + flen - 12, "_navmesh.hkt") == 0) ||
                 (flen > 14 && strcasecmp(phys + flen - 14, "_navvolume.hkt") == 0);
    if (!is_nav) return 0;

    int force_override = (strncasecmp(phys, "cp_mi_cairo_infection2_", 23) == 0);
    struct stat orig_st;
    if (!force_override && stat(out, &orig_st) == 0) return 0;

    char pdir_raw[PATH_MAX], pdir[PATH_MAX];
    if (!bo3_workshop_physics_dir(pdir_raw, sizeof(pdir_raw))) return 0;
    if (!realpath(pdir_raw, pdir)) return 0;
    char cand[PATH_MAX];
    int n = snprintf(cand, sizeof(cand), "%s/%s", pdir, phys);
    if (n <= 0 || (size_t)n >= sizeof(cand) || (size_t)n >= out_sz) return 0;
    struct stat st;
    if (lstat(cand, &st) != 0 || S_ISLNK(st.st_mode) || !S_ISREG(st.st_mode)) return 0;

    memcpy(out, cand, (size_t)n + 1);
    return 1;
}

// Optional Windows v100 cross-play zone fastfile overlay (core_patch.ff, mp_patch.ff, zm_patch.ff).
// Reads from $BO3MAC_ZONE_OVERLAY_DIR, $BO3ARM_ZONE_OVERLAY_DIR, or
// ~/Library/Application Support/bo3mac/zone (resolved to an absolute path once at startup so CWD
// changes cannot break it). Applied ONLY to read-only opens and metadata queries — NEVER to writes.
static pthread_once_t g_overlay_once = PTHREAD_ONCE_INIT;
static int            g_overlay_enabled = 0;
static char           g_overlay_dir[PATH_MAX];
static int            g_overlay_logged_mask = 0;

static void bo3_init_overlay_cfg(void) {
    bo3_settings_load_early();
    const char *env_xp = getenv("BO3ARM_CROSSPLAY");
    if (bo3_settings_offline_mode() || (env_xp && strcmp(env_xp, "0") == 0)) {
        g_overlay_enabled = 0;
        return;
    }
    const char *ov_dir = getenv("BO3MAC_ZONE_OVERLAY_DIR");
    if (!ov_dir || !ov_dir[0]) ov_dir = getenv("BO3ARM_ZONE_OVERLAY_DIR");
    char default_dir[PATH_MAX];
    if (!ov_dir || !ov_dir[0]) {
        const char *home = getenv("HOME");
        if (home && home[0]) {
            snprintf(default_dir, sizeof(default_dir), "%s/Library/Application Support/bo3mac/zone", home);
            ov_dir = default_dir;
        }
    }
    char resolved[PATH_MAX];
    if (ov_dir && ov_dir[0] && realpath(ov_dir, resolved)) {
        strlcpy(g_overlay_dir, resolved, sizeof(g_overlay_dir));
        g_overlay_enabled = 1;
    } else {
        g_overlay_enabled = 0;
    }
}

static int bo3_maybe_overlay_zone_path(char *out, size_t out_sz) {
    static const char *const kOverlayFiles[] = {
        "core_patch.ff",
        "mp_patch.ff",
        "zm_patch.ff",
    };
    pthread_once(&g_overlay_once, bo3_init_overlay_cfg);
    if (!g_overlay_enabled || !g_overlay_dir[0]) return 0;

    const char *p = out;
    if (p[0] == '.' && p[1] == '/') p += 2;
    const char *matched_name = NULL;
    for (size_t i = 0; i < sizeof(kOverlayFiles) / sizeof(kOverlayFiles[0]); i++) {
        char rel[64];
        snprintf(rel, sizeof(rel), "zone/%s", kOverlayFiles[i]);
        size_t rlen = strlen(rel);
        size_t plen = strlen(p);
        if (strcasecmp(p, rel) == 0 ||
            (plen > rlen && p[plen - rlen - 1] == '/' && strcasecmp(p + plen - rlen, rel) == 0)) {
            matched_name = kOverlayFiles[i];
            break;
        }
    }
    if (!matched_name) return 0;

    char cand[PATH_MAX];
    int n = snprintf(cand, sizeof(cand), "%s/%s", g_overlay_dir, matched_name);
    if (n <= 0 || (size_t)n >= sizeof(cand) || (size_t)n >= out_sz) return 0;
    struct stat st;
    if (lstat(cand, &st) != 0 || S_ISLNK(st.st_mode) || !S_ISREG(st.st_mode)) return 0;

    int bit = (matched_name[0] == 'c') ? 1 : ((matched_name[0] == 'm') ? 2 : 4);
    if (!(__atomic_fetch_or(&g_overlay_logged_mask, bit, __ATOMIC_RELAXED) & bit)) {
        fprintf(stderr, "[crossplay] Zone overlay: %s -> %s (%lld bytes)\n",
                matched_name, cand, (long long)st.st_size);
        fflush(stderr);
    }
    memcpy(out, cand, (size_t)n + 1);
    return 1;
}

static inline int bo3_fopen_mode_is_readonly(const char *mode) {
    return mode && mode[0] == 'r' && strchr(mode, '+') == NULL;
}

// Open a resolved path safely; when `overlaid` is non-zero (read-only overlay),
// use O_RDONLY | O_NOFOLLOW to close any check-to-open symlink race.
static FILE *bo3_fopen_safe(const char *path, const char *mode, int overlaid) {
    if (!overlaid) return fopen(path, mode);
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return NULL;
    FILE *fp = fdopen(fd, mode);
    if (!fp) close(fd);
    return fp;
}

// Resolve existing path case-insensitively segment by segment if exact stat fails.
// allow_overlay must be 1 ONLY for read-only opens and metadata queries.
static int bo3_resolve_path_ex(const char *win_path, char *out, size_t out_sz, int allow_overlay) {
    bo3_normalize_path(win_path, out, out_sz);
    if (!out[0]) return 0;
    if (allow_overlay && bo3_maybe_overlay_zone_path(out, out_sz)) return 1;
    struct stat st;
    if (stat(out, &st) == 0) {
        if (allow_overlay && bo3_maybe_overlay_physics_path(out, out_sz)) return 1;
        return 0;
    }

    // Walk segments for case-insensitive match
    char work[PATH_MAX];
    strlcpy(work, out, sizeof(work));
    char built[PATH_MAX];
    built[0] = 0;
    char *p = work;
    if (*p == '/') {
        strlcpy(built, "/", sizeof(built));
        p++;
    }
    while (*p) {
        char *slash = strchr(p, '/');
        if (slash) *slash = 0;
        char candidate[PATH_MAX];
        if (built[0] == 0) snprintf(candidate, sizeof(candidate), "%s", p);
        else if (strcmp(built, "/") == 0) snprintf(candidate, sizeof(candidate), "/%s", p);
        else snprintf(candidate, sizeof(candidate), "%s/%s", built, p);

        if (stat(candidate, &st) == 0) {
            strlcpy(built, candidate, sizeof(built));
        } else {
            const char *dir_to_open = built[0] ? built : ".";
            DIR *d = opendir(dir_to_open);
            int matched = 0;
            if (d) {
                struct dirent *de;
                while ((de = readdir(d)) != NULL) {
                    if (strcasecmp(de->d_name, p) == 0) {
                        if (built[0] == 0) snprintf(built, sizeof(built), "%s", de->d_name);
                        else if (strcmp(built, "/") == 0) snprintf(built, sizeof(built), "/%s", de->d_name);
                        else {
                            size_t bl = strlen(built);
                            snprintf(built + bl, sizeof(built) - bl, "/%s", de->d_name);
                        }
                        matched = 1;
                        break;
                    }
                }
                closedir(d);
            }
            if (!matched) {
                // Append remaining original path (for newly created files)
                strlcpy(built, candidate, sizeof(built));
                if (slash) {
                    size_t bl = strlen(built);
                    snprintf(built + bl, sizeof(built) - bl, "/%s", slash + 1);
                }
                break;
            }
        }
        if (!slash) break;
        p = slash + 1;
    }
    strlcpy(out, built, out_sz);
    if (allow_overlay && bo3_maybe_overlay_physics_path(out, out_sz)) return 1;
    return 0;
}

static void bo3_resolve_path(const char *win_path, char *out, size_t out_sz) {
    bo3_resolve_path_ex(win_path, out, out_sz, 0);
}

static uint64_t unix_to_filetime(time_t t) {
    return ((uint64_t)t + 11644473600ULL) * 10000000ULL;
}

// =========================================================================
// 2. Aspyr Path-Normalized CRT Wrappers (0x1000ec* - 0x1000ed*, 0x1000fb50b)
// =========================================================================

// Parse ANSI C fopen mode string into POSIX open(2) flags. Returns -1 if invalid.
static int bo3_fopen_mode_to_oflags(const char *mode) {
    if (!mode || !mode[0]) return -1;
    int plus = (strchr(mode, '+') != NULL);
    int excl = (strchr(mode, 'x') != NULL);
    int flags = 0;
    switch (mode[0]) {
        case 'r': flags = plus ? O_RDWR : O_RDONLY; break;
        case 'w': flags = (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC; break;
        case 'a': flags = (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND; break;
        default: return -1;
    }
    if (excl) flags |= O_EXCL;
    return flags;
}

// Find a case-insensitive entry matching `seg` inside directory `dirfd`.
// Returns 1 and writes matched name to `matched` on hit, else 0.
static int bo3_dirfd_find_ci(int dirfd, const char *seg, char *matched, size_t matched_sz) {
    int dupfd = dup(dirfd);
    if (dupfd < 0) return 0;
    DIR *d = fdopendir(dupfd);
    if (!d) { close(dupfd); return 0; }
    int found = 0;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strcasecmp(de->d_name, seg) == 0) {
            if (strlcpy(matched, de->d_name, matched_sz) < matched_sz) found = 1;
            break;
        }
    }
    closedir(d);
    return found;
}

// 0x1000fb503: hksf_fopen_internal(const char *filename, const char *opentype, int unknown)
// Aspyr's stock Mac build stubs this out to return NULL, breaking Lua io.open in Workshop mods.
// Sandboxed strictly to the Steam BO3 game root (../../../) via openat(..., O_NOFOLLOW) per
// path component: rejects absolute paths, drive letters, "..", oversized paths, dangling or
// in-tree symlink escapes, TOCTOU races, and writes into CoDBlkOps3.app.
FILE *bo3_hksf_fopen(const char *filename, const char *opentype) {
    if (!filename || !filename[0] || !opentype || !opentype[0]) return NULL;
    int oflags = bo3_fopen_mode_to_oflags(opentype);
    if (oflags < 0) return NULL;
    if (filename[0] == '/' || filename[0] == '\\' ||
        (isalpha((unsigned char)filename[0]) && filename[1] == ':')) {
        return NULL;
    }

    char rel[PATH_MAX];
    size_t j = 0;
    for (size_t i = 0; filename[i]; i++) {
        char c = (filename[i] == '\\') ? '/' : filename[i];
        if (c == '/' && j > 0 && rel[j - 1] == '/') continue;
        if (j + 1 >= sizeof(rel)) return NULL; // Reject instead of silently truncating
        rel[j++] = c;
    }
    while (j > 0 && rel[j - 1] == '/') j--;
    rel[j] = '\0';
    if (j == 0) return NULL;

    // Validate segments: reject ".." traversal and writes into CoDBlkOps3.app.
    int is_write = !bo3_fopen_mode_is_readonly(opentype);
    int seg_idx = 0;
    for (const char *s = rel; *s; ) {
        while (*s == '/') s++;
        if (!*s) break;
        const char *end = s;
        while (*end && *end != '/') end++;
        size_t slen = (size_t)(end - s);
        if (slen == 2 && s[0] == '.' && s[1] == '.') return NULL;
        if (!(slen == 1 && s[0] == '.')) {
            if (is_write && seg_idx == 0 && slen == 14 && strncasecmp(s, "CoDBlkOps3.app", 14) == 0) {
                return NULL;
            }
            seg_idx++;
        }
        s = end;
    }
    if (seg_idx == 0) return NULL;

    int dirfd = open("../../../", O_RDONLY | O_DIRECTORY);
    if (dirfd < 0) return NULL;

    char *p = rel;
    while (*p == '/') p++;
    for (;;) {
        char *slash = strchr(p, '/');
        if (slash) {
            *slash = '\0';
            if (strcmp(p, ".") != 0) {
                int nextfd = openat(dirfd, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
                if (nextfd < 0 && errno == ENOENT) {
                    char ci_name[NAME_MAX + 1];
                    if (bo3_dirfd_find_ci(dirfd, p, ci_name, sizeof(ci_name))) {
                        nextfd = openat(dirfd, ci_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
                    }
                }
                close(dirfd);
                if (nextfd < 0) return NULL;
                dirfd = nextfd;
            }
            p = slash + 1;
            while (*p == '/') p++;
            if (!*p) { close(dirfd); return NULL; }
        } else {
            if (strcmp(p, ".") == 0) { close(dirfd); return NULL; }
            const char *leaf = p;
            char ci_name[NAME_MAX + 1];
            struct stat lst;
            if (fstatat(dirfd, leaf, &lst, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT) {
                if (bo3_dirfd_find_ci(dirfd, leaf, ci_name, sizeof(ci_name))) {
                    leaf = ci_name;
                }
            }
            int fd = openat(dirfd, leaf, oflags | O_NOFOLLOW, 0666);
            close(dirfd);
            if (fd < 0) return NULL;
            FILE *fp = fdopen(fd, opentype);
            if (!fp) close(fd);
            return fp;
        }
    }
}

// 0x1000eceaf: fopen(path, mode)
SHIM_DEF(g_1000eceaf) {
    SHIM_UNUSED_ALL();
    const char *mode = (const char *)rsi;
    char path[PATH_MAX];
    int overlaid = bo3_resolve_path_ex((const char *)rdi, path, sizeof(path), bo3_fopen_mode_is_readonly(mode));
    return ret_ptr(bo3_fopen_safe(path, mode, overlaid));
}
// 0x1000fb50b: fopen_s(FILE **out, const char *path, const char *mode)
SHIM_DEF(g_1000fb50b) {
    SHIM_UNUSED_ALL();
    const char *mode = (const char *)rdx;
    char path[PATH_MAX];
    int overlaid = bo3_resolve_path_ex((const char *)rsi, path, sizeof(path), bo3_fopen_mode_is_readonly(mode));
    FILE *fp = bo3_fopen_safe(path, mode, overlaid);
    if (rdi) *(FILE **)rdi = fp;
    return ret_i64(fp ? 0 : (errno ? errno : ENOENT));
}
// 0x1000ecf7c: mkdir(path, mode)
SHIM_DEF(g_1000ecf7c) {
    SHIM_UNUSED_ALL();
    char path[PATH_MAX];
    bo3_resolve_path((const char *)rdi, path, sizeof(path));
    return ret_i64(mkdir(path, (mode_t)rsi));
}
// 0x1000ecfe5: open(path, flags, mode)
SHIM_DEF(g_1000ecfe5) {
    SHIM_UNUSED_ALL();
    int flags = (int)rsi;
    int ro = ((flags & O_ACCMODE) == O_RDONLY) && ((flags & (O_CREAT | O_TRUNC | O_APPEND)) == 0);
    char path[PATH_MAX];
    int overlaid = bo3_resolve_path_ex((const char *)rdi, path, sizeof(path), ro);
    if (overlaid) flags |= O_NOFOLLOW;
    return ret_i64(open(path, flags, (mode_t)rdx));
}
// 0x1000ed191: remove(path)
SHIM_DEF(g_1000ed191) {
    SHIM_UNUSED_ALL();
    char path[PATH_MAX];
    bo3_resolve_path((const char *)rdi, path, sizeof(path));
    return ret_i64(remove(path));
}
// 0x1000ed1f1: rename(old, new)
SHIM_DEF(g_1000ed1f1) {
    SHIM_UNUSED_ALL();
    char p1[PATH_MAX], p2[PATH_MAX];
    bo3_resolve_path((const char *)rdi, p1, sizeof(p1));
    bo3_resolve_path((const char *)rsi, p2, sizeof(p2));
    return ret_i64(rename(p1, p2));
}
// 0x1000ed28e: stat(path, struct stat *st)
SHIM_DEF(g_1000ed28e) {
    SHIM_UNUSED_ALL();
    char path[PATH_MAX];
    bo3_resolve_path_ex((const char *)rdi, path, sizeof(path), 1);
    return ret_i64(stat(path, (struct stat *)rsi));
}
// 0x1000ed2f9: fgets with CR -> LF translation
SHIM_DEF(g_1000ed2f9) {
    SHIM_UNUSED_ALL();
    char *buf = (char *)rdi;
    int n = (int)rsi;
    FILE *fp = (FILE *)rdx;
    if (!buf || !fp || n < 1) return ret_u64(0);
    if (n == 1) { buf[0] = 0; return ret_ptr(buf); }
    flockfile(fp);
    int i = 0;
    while (i < n - 1) {
        int c = getc_unlocked(fp);
        if (c == EOF) {
            if (i == 0) { funlockfile(fp); return ret_u64(0); }
            break;
        }
        if (c == '\r') {
            int next = getc_unlocked(fp);
            if (next != '\n' && next != EOF) ungetc(next, fp);
            buf[i++] = '\n';
            break;
        }
        buf[i++] = (char)c;
        if (c == '\n') break;
    }
    buf[i] = 0;
    funlockfile(fp);
    return ret_ptr(buf);
}
// 0x1000ed46e: adler32(uLong adler, const Bytef *buf, uInt len)
SHIM_DEF(g_1000ed46e) {
    SHIM_UNUSED_ALL();
    return ret_u64((uint32_t)adler32((uLong)(uint32_t)rdi, (const Bytef *)rsi, (uInt)(uint32_t)rdx));
}

// =========================================================================
// 3. Win32 Virtual Memory (Apple Silicon 16 KiB safe VirtualAlloc/VirtualFree)
// =========================================================================

typedef struct VmRegion {
    uintptr_t base;
    size_t    size;
    int       used;
} VmRegion;

#define MAX_VM_REGIONS 4096
static pthread_mutex_t g_vm_lock = PTHREAD_MUTEX_INITIALIZER;
static VmRegion g_vm_regions[MAX_VM_REGIONS];

static size_t align_up_16k(size_t sz) {
    return (sz + 0x3fffULL) & ~0x3fffULL;
}

// 0x10010a3d7: VirtualAlloc(lpAddr, dwSize, flAllocType, flProtect)
SHIM_DEF(g_10010a3d7) {
    SHIM_UNUSED_ALL();
    uintptr_t addr = (uintptr_t)rdi;
    size_t size = (size_t)rsi;
    uint32_t alloc_type = (uint32_t)rdx;
    uint32_t protect = (uint32_t)rcx;
    (void)protect;

    if (size == 0) {
        bo3_set_last_error(ctx, 0x57);
        return ret_u64(0);
    }

    pthread_mutex_lock(&g_vm_lock);
    // Check if addr falls inside an existing reserved region
    VmRegion *found = NULL;
    if (addr != 0) {
        for (int i = 0; i < MAX_VM_REGIONS; i++) {
            if (g_vm_regions[i].used &&
                addr >= g_vm_regions[i].base &&
                addr < g_vm_regions[i].base + g_vm_regions[i].size) {
                found = &g_vm_regions[i];
                break;
            }
        }
    }

    if (found) {
        // MEM_COMMIT within an already-reserved region (already RW mmap'd lazily)
        if ((alloc_type & 0x2000u) != 0) {
            pthread_mutex_unlock(&g_vm_lock);
            bo3_set_last_error(ctx, 0x57);
            return ret_u64(0);
        }
        uintptr_t aligned = addr & ~0xfffULL;
        if (aligned + ((size + (addr - aligned) + 0xfffULL) & ~0xfffULL) > found->base + found->size) {
            pthread_mutex_unlock(&g_vm_lock);
            bo3_set_last_error(ctx, 0x57);
            return ret_u64(0);
        }
        pthread_mutex_unlock(&g_vm_lock);
        return ret_u64((uint64_t)aligned);
    }

    // Reserve (or Reserve+Commit) a fresh anonymous mapping
    int slot = -1;
    for (int i = 0; i < MAX_VM_REGIONS; i++) {
        if (!g_vm_regions[i].used) { slot = i; break; }
    }
    if (slot < 0) {
        pthread_mutex_unlock(&g_vm_lock);
        bo3_set_last_error(ctx, 8); // ERROR_NOT_ENOUGH_MEMORY (metadata table full)
        return ret_u64(0);
    }
    size_t map_sz = align_up_16k(size);
    void *p = mmap((void *)(addr & ~0x3fffULL), map_sz, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        pthread_mutex_unlock(&g_vm_lock);
        bo3_set_last_error(ctx, 8); // ERROR_NOT_ENOUGH_MEMORY
        return ret_u64(0);
    }
    g_vm_regions[slot].base = (uintptr_t)p;
    g_vm_regions[slot].size = map_sz;
    g_vm_regions[slot].used = 1;
    pthread_mutex_unlock(&g_vm_lock);
    return ret_ptr(p);
}

// 0x10010a6bb: VirtualFree(lpAddr, dwSize, dwFreeType)
SHIM_DEF(g_10010a6bb) {
    SHIM_UNUSED_ALL();
    uintptr_t addr = (uintptr_t)rdi;
    size_t size = (size_t)rsi;
    uint32_t free_type = (uint32_t)rdx;
    if (addr == 0) { bo3_set_last_error(ctx, 0x57); return ret_u64(0); }

    pthread_mutex_lock(&g_vm_lock);
    VmRegion *found = NULL;
    for (int i = 0; i < MAX_VM_REGIONS; i++) {
        if (g_vm_regions[i].used &&
            addr >= g_vm_regions[i].base &&
            addr < g_vm_regions[i].base + g_vm_regions[i].size) {
            found = &g_vm_regions[i];
            break;
        }
    }
    if (!found) {
        pthread_mutex_unlock(&g_vm_lock);
        bo3_set_last_error(ctx, 0x57);
        return ret_u64(0);
    }

    if (free_type == 0x8000u) { // MEM_RELEASE: Windows requires exact base and dwSize == 0
        if (addr != found->base || size != 0) {
            pthread_mutex_unlock(&g_vm_lock);
            bo3_set_last_error(ctx, 0x57);
            return ret_u64(0);
        }
        uintptr_t base = found->base;
        size_t msz = found->size;
        int rc = munmap((void *)base, msz);
        if (rc == 0) found->used = 0;
        pthread_mutex_unlock(&g_vm_lock);
        if (rc != 0) { bo3_set_last_error(ctx, 0x57); return ret_u64(0); }
        return ret_u64(1);
    }
    if (free_type == 0x4000u) { // MEM_DECOMMIT: serialize under g_vm_lock so recommit/release can't race!
        uintptr_t start = addr & ~0xfffULL;
        size_t len = (size == 0) ? (found->base + found->size - start)
                                 : ((size + (addr - start) + 0xfffULL) & ~0xfffULL);
        if (start + len > found->base + found->size) len = found->base + found->size - start;
        memset((void *)start, 0, len);
        uintptr_t a16 = (start + 0x3fffULL) & ~0x3fffULL;
        uintptr_t e16 = (start + len) & ~0x3fffULL;
        if (e16 > a16) madvise((void *)a16, e16 - a16, MADV_FREE);
        pthread_mutex_unlock(&g_vm_lock);
        return ret_u64(1);
    }
    pthread_mutex_unlock(&g_vm_lock);
    bo3_set_last_error(ctx, 0x57);
    return ret_u64(0);
}

// =========================================================================
// 4. Unified Win32 Handles: EVENT, THREAD, FILE
// =========================================================================

#define BO3_HANDLE_MAGIC 0x424F3348574E444CULL

typedef enum Bo3HandleKind {
    H_EVENT  = 1,
    H_THREAD = 2,
    H_FILE   = 3,
} Bo3HandleKind;

typedef struct Bo3Handle {
    uint64_t        magic;
    uint64_t        token;
    Bo3HandleKind   kind;
    int             guest_refs;    // decremented only by CloseHandle
    int             internal_refs; // thread trampoline + WASAPI event retain/release
    int             pins;          // in-flight operations (Wait/Set/Reset/Read/Write/AudioSignal)
    // Waitable state (EVENT + THREAD)
    pthread_mutex_t mtx;
    pthread_cond_t  cond;
    int             manual_reset;
    int             signaled;
    char            name[128];
    // THREAD fields
    pthread_t       pth;
    int             started;
    int             suspended;
    int             detached;
    uint32_t        tid;
    uint64_t        start_va;
    uint64_t        param;
    size_t          stack_size;
    // FILE fields
    FILE           *fp;
    int             fd;
    uint32_t        file_flags;
} Bo3Handle;

#define BO3_HANDLE_TABLE_SIZE 16384u
typedef struct Bo3HandleSlot {
    uint32_t   gen;
    Bo3Handle *obj;
} Bo3HandleSlot;

static pthread_mutex_t g_handle_lock = PTHREAD_MUTEX_INITIALIZER;
static Bo3HandleSlot   g_handle_table[BO3_HANDLE_TABLE_SIZE];
static uint32_t        g_handle_next_slot = 1;
static Bo3Handle      *g_named_events[256];
static size_t          g_named_event_count = 0;

static Bo3Handle *bo3_handle_lookup_locked(uint64_t raw) {
    if (raw == 0 || raw == 0xffffffffffffffffULL) return NULL;
    uint32_t slot = (uint32_t)(raw & 0xFFFFu);
    uint64_t gen  = raw >> 16;
    if (slot == 0 || slot >= BO3_HANDLE_TABLE_SIZE || gen == 0 || gen > 0xFFFFFFFFULL) return NULL;
    Bo3HandleSlot *s = &g_handle_table[slot];
    if (!s->obj || s->gen != (uint32_t)gen) return NULL;
    return s->obj;
}

static void bo3_handle_destroy_unlocked(Bo3Handle *h) {
    if (h->kind == H_FILE && h->fp) {
        fclose(h->fp);
        h->fp = NULL;
    }
    pthread_cond_destroy(&h->cond);
    pthread_mutex_destroy(&h->mtx);
    free(h);
}

static int bo3_handle_maybe_reclaim_locked(Bo3Handle *h) {
    if (h->guest_refs > 0 || h->internal_refs > 0 || h->pins > 0) return 0;
    uint32_t slot = (uint32_t)(h->token & 0xFFFFu);
    if (slot > 0 && slot < BO3_HANDLE_TABLE_SIZE && g_handle_table[slot].obj == h) {
        g_handle_table[slot].obj = NULL;
        g_handle_table[slot].gen++;
        if (g_handle_table[slot].gen == 0) g_handle_table[slot].gen = 1;
    }
    if (h->kind == H_EVENT && h->name[0]) {
        for (size_t i = 0; i < g_named_event_count; i++) {
            if (g_named_events[i] == h) {
                g_named_events[i] = g_named_events[--g_named_event_count];
                break;
            }
        }
    }
    h->magic = 0;
    return 1;
}

static Bo3Handle *bo3_handle_alloc_locked(Bo3HandleKind kind) {
    uint32_t chosen = 0;
    for (uint32_t i = 0; i < BO3_HANDLE_TABLE_SIZE - 1; i++) {
        uint32_t idx = g_handle_next_slot;
        g_handle_next_slot = (idx + 1 >= BO3_HANDLE_TABLE_SIZE) ? 1 : idx + 1;
        if (g_handle_table[idx].obj == NULL) {
            chosen = idx;
            break;
        }
    }
    if (chosen == 0) abort();
    Bo3Handle *h = (Bo3Handle *)calloc(1, sizeof(Bo3Handle));
    if (!h) abort();
    if (g_handle_table[chosen].gen == 0) g_handle_table[chosen].gen = 1;
    uint32_t gen = g_handle_table[chosen].gen;
    h->magic = BO3_HANDLE_MAGIC;
    h->token = ((uint64_t)gen << 16) | (uint64_t)chosen;
    h->kind = kind;
    h->guest_refs = 1;
    h->internal_refs = 0;
    h->pins = 0;
    pthread_mutex_init(&h->mtx, NULL);
    pthread_cond_init(&h->cond, NULL);
    g_handle_table[chosen].obj = h;
    return h;
}

static Bo3Handle *bo3_handle_alloc(Bo3HandleKind kind) {
    pthread_mutex_lock(&g_handle_lock);
    Bo3Handle *h = bo3_handle_alloc_locked(kind);
    pthread_mutex_unlock(&g_handle_lock);
    return h;
}

static Bo3Handle *bo3_handle_pin(uint64_t raw, Bo3HandleKind expected_kind) {
    pthread_mutex_lock(&g_handle_lock);
    Bo3Handle *h = bo3_handle_lookup_locked(raw);
    if (!h || h->guest_refs <= 0 || (expected_kind != 0 && h->kind != expected_kind)) {
        pthread_mutex_unlock(&g_handle_lock);
        return NULL;
    }
    h->pins++;
    pthread_mutex_unlock(&g_handle_lock);
    return h;
}

static void bo3_handle_release(Bo3Handle *h) {
    if (!h) return;
    pthread_mutex_lock(&g_handle_lock);
    if (h->magic != BO3_HANDLE_MAGIC || h->pins <= 0) {
        pthread_mutex_unlock(&g_handle_lock);
        return;
    }
    h->pins--;
    int dead = bo3_handle_maybe_reclaim_locked(h);
    pthread_mutex_unlock(&g_handle_lock);
    if (dead) bo3_handle_destroy_unlocked(h);
}

static void bo3_handle_release_internal(Bo3Handle *h) {
    if (!h) return;
    pthread_mutex_lock(&g_handle_lock);
    if (h->magic != BO3_HANDLE_MAGIC || h->internal_refs <= 0) {
        pthread_mutex_unlock(&g_handle_lock);
        return;
    }
    h->internal_refs--;
    int dead = bo3_handle_maybe_reclaim_locked(h);
    pthread_mutex_unlock(&g_handle_lock);
    if (dead) bo3_handle_destroy_unlocked(h);
}

static int bo3_wait_handle(Bo3Handle *h, uint32_t timeout_ms) {
    if (!h) return -1; // WAIT_FAILED
    if (h->kind == H_FILE) return 0;
    if (h->kind != H_EVENT && h->kind != H_THREAD) return -1;
    pthread_mutex_lock(&h->mtx);
    int res = 0; // WAIT_OBJECT_0
    if (h->signaled || timeout_ms == 0) {
        if (!h->signaled) res = 0x102; // WAIT_TIMEOUT
    } else if (timeout_ms == 0xffffffffu) {
        while (!h->signaled) {
            if (pthread_cond_wait(&h->cond, &h->mtx) != 0) { res = -1; break; }
        }
    } else {
        struct timespec now, end;
        clock_gettime(CLOCK_MONOTONIC, &now);
        uint64_t add_ns = (uint64_t)timeout_ms * 1000000ULL;
        uint64_t tot_ns = (uint64_t)now.tv_nsec + add_ns;
        end.tv_sec  = now.tv_sec + (time_t)(tot_ns / 1000000000ULL);
        end.tv_nsec = (long)(tot_ns % 1000000000ULL);
        while (!h->signaled) {
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec > end.tv_sec || (now.tv_sec == end.tv_sec && now.tv_nsec >= end.tv_nsec)) {
                res = 0x102; // WAIT_TIMEOUT
                break;
            }
            struct timespec rel;
            rel.tv_sec = end.tv_sec - now.tv_sec;
            rel.tv_nsec = end.tv_nsec - now.tv_nsec;
            if (rel.tv_nsec < 0) { rel.tv_sec--; rel.tv_nsec += 1000000000L; }
            int rc = pthread_cond_timedwait_relative_np(&h->cond, &h->mtx, &rel);
            if (rc == ETIMEDOUT) {
                if (!h->signaled) res = 0x102;
                break;
            }
            if (rc != 0 && rc != EINTR) { res = -1; break; }
        }
    }
    if (res == 0 && !h->manual_reset) h->signaled = 0;
    pthread_mutex_unlock(&h->mtx);
    return res;
}

// 0x100109bbf: CloseHandle(HANDLE h)
SHIM_DEF(g_100109bbf) {
    SHIM_UNUSED_ALL();
    if (rdi == 0 || rdi == 0xffffffffffffffffULL) return ret_u64(1);
    pthread_mutex_lock(&g_handle_lock);
    Bo3Handle *h = bo3_handle_lookup_locked(rdi);
    if (!h || h->guest_refs <= 0) {
        pthread_mutex_unlock(&g_handle_lock);
        bo3_set_last_error(ctx, 6);
        return ret_u64(0);
    }
    h->guest_refs--;
    int do_detach = 0;
    pthread_t pth_to_detach = 0;
    if (h->guest_refs == 0 && h->kind == H_THREAD &&
        __atomic_exchange_n(&h->detached, 1, __ATOMIC_ACQ_REL) == 0) {
        do_detach = 1;
        pth_to_detach = h->pth;
    }
    if (h->guest_refs == 0 && h->kind == H_EVENT && h->name[0]) {
        for (size_t i = 0; i < g_named_event_count; i++) {
            if (g_named_events[i] == h) {
                g_named_events[i] = g_named_events[--g_named_event_count];
                break;
            }
        }
    }
    int dead = bo3_handle_maybe_reclaim_locked(h);
    pthread_mutex_unlock(&g_handle_lock);
    if (do_detach) pthread_detach(pth_to_detach);
    if (dead) bo3_handle_destroy_unlocked(h);
    return ret_u64(1);
}

// 0x100109bde: WaitForSingleObject(HANDLE h, DWORD ms)
SHIM_DEF(g_100109bde) {
    SHIM_UNUSED_ALL();
    Bo3Handle *h = bo3_handle_pin(rdi, 0);
    if (!h) { bo3_set_last_error(ctx, 6); return ret_u64(0xffffffffULL); }
    int res = bo3_wait_handle(h, (uint32_t)rsi);
    bo3_handle_release(h);
    if (res < 0) { bo3_set_last_error(ctx, 6); return ret_u64(0xffffffffULL); }
    return ret_u64((uint32_t)res);
}

// 0x1001117e1: CreateEventA(sec, bManualReset, bInitialState, lpName)
SHIM_DEF(g_1001117e1) {
    SHIM_UNUSED_ALL();
    int bManual = ((uint32_t)rsi != 0);
    int bInit = ((uint32_t)rdx != 0);
    const char *name = (const char *)rcx;
    if (name && name[0]) {
        pthread_mutex_lock(&g_handle_lock);
        for (size_t i = 0; i < g_named_event_count; i++) {
            if (strcmp(g_named_events[i]->name, name) == 0 && g_named_events[i]->guest_refs > 0) {
                Bo3Handle *ex = g_named_events[i];
                ex->guest_refs++;
                uint64_t tok = ex->token;
                pthread_mutex_unlock(&g_handle_lock);
                bo3_set_last_error(ctx, 183); // ERROR_ALREADY_EXISTS
                return ret_u64(tok);
            }
        }
        Bo3Handle *h = bo3_handle_alloc_locked(H_EVENT);
        h->manual_reset = bManual;
        h->signaled = bInit;
        strlcpy(h->name, name, sizeof(h->name));
        uint64_t tok = h->token;
        if (g_named_event_count < 256) g_named_events[g_named_event_count++] = h;
        pthread_mutex_unlock(&g_handle_lock);
        bo3_set_last_error(ctx, 0);
        return ret_u64(tok);
    }
    Bo3Handle *h = bo3_handle_alloc(H_EVENT);
    h->manual_reset = bManual;
    h->signaled = bInit;
    bo3_set_last_error(ctx, 0);
    return ret_u64(h->token);
}

// 0x10011199f: SetEvent(HANDLE h)
SHIM_DEF(g_10011199f) {
    SHIM_UNUSED_ALL();
    Bo3Handle *h = bo3_handle_pin(rdi, H_EVENT);
    if (!h) { bo3_set_last_error(ctx, 6); return ret_u64(0); }
    pthread_mutex_lock(&h->mtx);
    h->signaled = 1;
    if (h->manual_reset) pthread_cond_broadcast(&h->cond);
    else pthread_cond_signal(&h->cond);
    pthread_mutex_unlock(&h->mtx);
    bo3_handle_release(h);
    bo3_set_last_error(ctx, 0);
    return ret_u64(1);
}

// 0x1001119cd: ResetEvent(HANDLE h)
SHIM_DEF(g_1001119cd) {
    SHIM_UNUSED_ALL();
    Bo3Handle *h = bo3_handle_pin(rdi, H_EVENT);
    if (!h) { bo3_set_last_error(ctx, 6); return ret_u64(0); }
    pthread_mutex_lock(&h->mtx);
    h->signaled = 0;
    pthread_mutex_unlock(&h->mtx);
    bo3_handle_release(h);
    bo3_set_last_error(ctx, 0);
    return ret_u64(1);
}

// Win32 CreateThread trampoline (uses unified TID allocator + Aspyr TLV 0x102104e20!)
static void *bo3_win32_thread_trampoline(void *arg) {
    Bo3Handle *h = (Bo3Handle *)arg;
    // Wait if CREATE_SUSPENDED
    pthread_mutex_lock(&h->mtx);
    while (h->suspended) pthread_cond_wait(&h->cond, &h->mtx);
    pthread_mutex_unlock(&h->mtx);

    size_t stk_sz = h->stack_size;
    if (stk_sz < 2 * 1024 * 1024) stk_sz = 8 * 1024 * 1024;
    stk_sz = align_up_16k(stk_sz);
    void *stk = mmap(NULL, stk_sz + 16384, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stk == MAP_FAILED) abort();
    if (mprotect(stk, 16384, PROT_NONE) != 0) abort();

    GuestContext tctx;
    memset(&tctx, 0, sizeof(tctx));
    tctx.mxcsr = 0x1f80;
    tctx.stack_base = (uint64_t)(uintptr_t)stk + 16384;
    tctx.stack_size = stk_sz;
    tctx.tlv_block = bo3_alloc_thread_tlv();
    bo3_init_thread_tid(&tctx, h->tid);

    uint64_t sp = (tctx.stack_base + stk_sz - 256) & ~15ULL;
    sp -= 8;
    *(uint64_t *)sp = 0;

    GuestFn fn = bo3_resolve(h->start_va, &tctx);
    tctx.last_pc = h->start_va;
    fn(&tctx, sp, h->param, 0, 0, 0, 0, 0,
       guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
       guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());

    bo3_free_thread_tlv(tctx.tlv_block);
    munmap(stk, stk_sz + 16384);

    // Signal thread handle on exit (manual-reset event semantics)
    pthread_mutex_lock(&h->mtx);
    h->signaled = 1;
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->mtx);
    bo3_handle_release_internal(h);
    return NULL;
}

// 0x1001115e8: CreateThread(sec, stackSz, startVa, param, flags, lpThreadId)
SHIM_DEF(g_1001115e8) {
    SHIM_UNUSED_ALL();
    size_t stack_sz = (size_t)rsi;
    uint64_t start_va = rdx;
    uint64_t param = rcx;
    uint32_t flags = (uint32_t)r8;
    uint32_t *ptid = (uint32_t *)r9;

    pthread_mutex_lock(&g_handle_lock);
    Bo3Handle *h = bo3_handle_alloc_locked(H_THREAD);
    h->manual_reset = 1;
    h->signaled = 0;
    h->suspended = ((flags & 4u) != 0);
    h->start_va = start_va;
    h->param = param;
    h->stack_size = stack_sz;
    h->tid = bo3_alloc_tid();
    h->internal_refs = 1; // owned by running thread trampoline
    uint64_t tok = h->token;
    pthread_mutex_unlock(&g_handle_lock);

    pthread_attr_t pattr;
    pthread_attr_init(&pattr);
    size_t host_stk = stack_sz > (16u << 20) ? align_up_16k(stack_sz) : (16u << 20);
    pthread_attr_setstacksize(&pattr, host_stk);
    int pc_rc = pthread_create(&h->pth, &pattr, bo3_win32_thread_trampoline, h);
    pthread_attr_destroy(&pattr);
    if (pc_rc != 0) {
        pthread_mutex_lock(&g_handle_lock);
        h->guest_refs = 0;
        h->internal_refs = 0;
        int dead = bo3_handle_maybe_reclaim_locked(h);
        pthread_mutex_unlock(&g_handle_lock);
        if (dead) bo3_handle_destroy_unlocked(h);
        if (ptid) *ptid = 0;
        return ret_u64(0);
    }
    h->started = 1;
    if (ptid) *ptid = h->tid;
    return ret_u64(tok);
}

// 0x100111718: ResumeThread(HANDLE h)
SHIM_DEF(g_100111718) {
    SHIM_UNUSED_ALL();
    Bo3Handle *h = bo3_handle_pin(rdi, H_THREAD);
    if (!h) return ret_u64(0xffffffffULL);
    pthread_mutex_lock(&h->mtx);
    uint32_t prev = (uint32_t)h->suspended;
    h->suspended = 0;
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->mtx);
    bo3_handle_release(h);
    return ret_u64(prev);
}

// =========================================================================
// 5. Win32 File I/O & Directory Enumeration (0x10010bbf4 .. 0x10010d47d)
// =========================================================================

static pthread_once_t g_trace_files_once = PTHREAD_ONCE_INIT;
static int g_trace_files = 0;
static void bo3_init_trace_files(void) {
    g_trace_files = (getenv("BO3ARM_TRACE_FILES") != NULL);
}

// 0x10010bbf4: CreateFileA(path, access, share, sec, disp, flags, tmpl)
SHIM_DEF(g_10010bbf4) {
    SHIM_UNUSED_ALL();
    const char *raw_path = (const char *)rdi;
    uint32_t access = (uint32_t)rsi;
    uint32_t disp = (uint32_t)r8;
    uint32_t flags = (uint32_t)r9;
    if (!raw_path) { bo3_set_last_error(ctx, 0x57); return ret_u64(0xffffffffffffffffULL); }

    int want_read  = ((access & 0x80000081u) != 0);
    int want_write = ((access & 0x40000102u) != 0) || (access == 4);
    int allow_overlay = (!want_write && disp == 3 /* OPEN_EXISTING */);

    char path[PATH_MAX];
    int overlaid = bo3_resolve_path_ex(raw_path, path, sizeof(path), allow_overlay);

    pthread_once(&g_trace_files_once, bo3_init_trace_files);

    struct stat st;
    int exists = (stat(path, &st) == 0);
    if (g_trace_files) {
        int saved_errno = errno;
        fprintf(stderr, "[file] CreateFileA('%s' -> '%s', disp=%u) exists=%d\n",
                raw_path, path, disp, exists);
        fflush(stderr);
        errno = saved_errno;
    }
    if (exists && S_ISDIR(st.st_mode)) {
        bo3_set_last_error(ctx, 0x57);
        return ret_u64(0xffffffffffffffffULL);
    }

    int oflags = 0;
    const char *fmode = "rb";
    if (access == 4) {
        oflags = O_WRONLY | O_APPEND;
        fmode = "ab";
    } else if (want_read && want_write) {
        oflags = O_RDWR;
        fmode = "r+b";
    } else if (want_write) {
        oflags = O_WRONLY;
        fmode = "wb";
    } else {
        oflags = O_RDONLY | (overlaid ? O_NOFOLLOW : 0);
        fmode = "rb";
    }

    switch (disp) {
        case 1: // CREATE_NEW
            if (exists) { bo3_set_last_error(ctx, 80); return ret_u64(0xffffffffffffffffULL); }
            oflags |= O_CREAT | O_EXCL;
            break;
        case 2: // CREATE_ALWAYS
            oflags |= O_CREAT | O_TRUNC;
            break;
        case 3: // OPEN_EXISTING
            if (!exists) { bo3_set_last_error(ctx, 2); return ret_u64(0xffffffffffffffffULL); }
            break;
        case 4: // OPEN_ALWAYS
            oflags |= O_CREAT;
            break;
        case 5: // TRUNCATE_EXISTING
            if (!exists) { bo3_set_last_error(ctx, 2); return ret_u64(0xffffffffffffffffULL); }
            oflags |= O_TRUNC;
            break;
        default:
            bo3_set_last_error(ctx, 0x57);
            return ret_u64(0xffffffffffffffffULL);
    }

    int fd = open(path, oflags, 0666);
    if (fd < 0) {
        bo3_set_last_error(ctx, errno == EACCES ? 5 : (errno == ENOENT ? 2 : 3));
        return ret_u64(0xffffffffffffffffULL);
    }
    FILE *fp = fdopen(fd, fmode);
    if (!fp) {
        close(fd);
        bo3_set_last_error(ctx, 3);
        return ret_u64(0xffffffffffffffffULL);
    }

    Bo3Handle *h = bo3_handle_alloc(H_FILE);
    h->fp = fp;
    h->fd = fd;
    h->file_flags = flags;

    if ((disp == 2 || disp == 4) && exists) bo3_set_last_error(ctx, 183);
    else bo3_set_last_error(ctx, 0);
    return ret_u64(h->token);
}

static void bo3_signal_overlapped_event(uint8_t *ov) {
    if (!ov) return;
    uint64_t hev = 0;
    memcpy(&hev, ov + 0x18, 8);
    Bo3Handle *ev = bo3_handle_pin(hev, H_EVENT);
    if (!ev) return;
    pthread_mutex_lock(&ev->mtx);
    ev->signaled = 1;
    if (ev->manual_reset) pthread_cond_broadcast(&ev->cond);
    else pthread_cond_signal(&ev->cond);
    pthread_mutex_unlock(&ev->mtx);
    bo3_handle_release(ev);
}

// 0x10010c163: ReadFile(h, buf, len, pBytesRead, lpOverlapped)
SHIM_DEF(g_10010c163) {
    SHIM_UNUSED_ALL();
    uint32_t *p_read = (uint32_t *)rcx;
    uint8_t *ov = (uint8_t *)r8;
    if (p_read) *p_read = 0;
    if (!rsi) { bo3_set_last_error(ctx, 0x57); return ret_u64(0); }
    Bo3Handle *h = bo3_handle_pin(rdi, H_FILE);
    if (!h || !h->fp) {
        if (h) bo3_handle_release(h);
        bo3_set_last_error(ctx, 6);
        return ret_u64(0);
    }
    size_t want = (size_t)(uint32_t)rdx;
    size_t got = 0;
    int io_err = 0;
    if (ov) {
        // Atomic positional pread() so concurrent FastFile worker threads never corrupt shared cursor!
        uint64_t off = 0;
        memcpy(&off, ov + 0x10, 8);
        uint8_t *dst = (uint8_t *)rsi;
        while (got < want) {
            ssize_t r = pread(h->fd, dst + got, want - got, (off_t)(off + got));
            if (r < 0) {
                if (errno == EINTR) continue;
                io_err = 1;
                break;
            }
            if (r == 0) break; // EOF
            got += (size_t)r;
        }
        if (!io_err) {
            uint64_t zero = 0, xfer = (uint64_t)got, new_off = off + got;
            memcpy(ov + 0x00, &zero, 8);
            memcpy(ov + 0x08, &xfer, 8);
            memcpy(ov + 0x10, &new_off, 8);
            bo3_signal_overlapped_event(ov);
        }
    } else {
        pthread_mutex_lock(&h->mtx);
        got = fread((void *)rsi, 1, want, h->fp);
        if (got < want && ferror(h->fp)) { io_err = 1; clearerr(h->fp); }
        pthread_mutex_unlock(&h->mtx);
    }
    bo3_handle_release(h);
    if (p_read) *p_read = (uint32_t)got;
    if (io_err) { bo3_set_last_error(ctx, 0x1e); return ret_u64(0); }
    bo3_set_last_error(ctx, 0);
    return ret_u64(1);
}

// 0x10010c3b6: WriteFile(h, buf, len, pBytesWritten, lpOverlapped)
SHIM_DEF(g_10010c3b6) {
    SHIM_UNUSED_ALL();
    uint32_t *p_wr = (uint32_t *)rcx;
    uint8_t *ov = (uint8_t *)r8;
    if (p_wr) *p_wr = 0;
    if (!rsi) { bo3_set_last_error(ctx, 0x57); return ret_u64(0); }
    Bo3Handle *h = bo3_handle_pin(rdi, H_FILE);
    if (!h || !h->fp) {
        if (h) bo3_handle_release(h);
        bo3_set_last_error(ctx, 6);
        return ret_u64(0);
    }
    size_t want = (size_t)(uint32_t)rdx;
    size_t written = 0;
    int io_err = 0;
    if (ov) {
        uint32_t lo = 0, hi = 0;
        memcpy(&lo, ov + 0x10, 4);
        memcpy(&hi, ov + 0x14, 4);
        pthread_mutex_lock(&h->mtx);
        fflush(h->fp);
        off_t off;
        if ((lo & hi) == 0xffffffffu) {
            struct stat st;
            off = (fstat(h->fd, &st) == 0) ? st.st_size : 0;
        } else {
            off = (off_t)(((uint64_t)hi << 32) | lo);
        }
        const uint8_t *src = (const uint8_t *)rsi;
        while (written < want) {
            ssize_t r = pwrite(h->fd, src + written, want - written, off + (off_t)written);
            if (r < 0) {
                if (errno == EINTR) continue;
                io_err = 1;
                break;
            }
            if (r == 0) { io_err = 1; break; }
            written += (size_t)r;
        }
        pthread_mutex_unlock(&h->mtx);
        if (!io_err) {
            uint64_t zero = 0, xfer = (uint64_t)written, new_off = (uint64_t)(off + (off_t)written);
            memcpy(ov + 0x00, &zero, 8);
            memcpy(ov + 0x08, &xfer, 8);
            memcpy(ov + 0x10, &new_off, 8);
            bo3_signal_overlapped_event(ov);
        }
    } else {
        pthread_mutex_lock(&h->mtx);
        written = fwrite((const void *)rsi, 1, want, h->fp);
        if (written < want || ferror(h->fp)) { io_err = 1; clearerr(h->fp); }
        pthread_mutex_unlock(&h->mtx);
    }
    bo3_handle_release(h);
    if (p_wr) *p_wr = (uint32_t)written;
    if (io_err) { bo3_set_last_error(ctx, 0x1d); return ret_u64(0); }
    bo3_set_last_error(ctx, 0);
    return ret_u64(1);
}

// 0x10010c551: SetFilePointerEx(h, dist, pNewPos, moveMethod)
SHIM_DEF(g_10010c551) {
    SHIM_UNUSED_ALL();
    uint64_t *p_new = (uint64_t *)rdx;
    uint32_t method = (uint32_t)rcx;
    if (p_new) *p_new = 0;
    if (method > 2) { bo3_set_last_error(ctx, 0x57); return ret_u64(0); }
    Bo3Handle *h = bo3_handle_pin(rdi, H_FILE);
    if (!h || !h->fp) {
        if (h) bo3_handle_release(h);
        bo3_set_last_error(ctx, 6);
        return ret_u64(0);
    }
    int whence = (method == 0) ? SEEK_SET : (method == 1 ? SEEK_CUR : SEEK_END);
    pthread_mutex_lock(&h->mtx);
    int rc = fseeko(h->fp, (off_t)(int64_t)rsi, whence);
    off_t pos = (rc == 0) ? ftello(h->fp) : -1;
    pthread_mutex_unlock(&h->mtx);
    bo3_handle_release(h);
    if (rc != 0) { bo3_set_last_error(ctx, 0x83); return ret_u64(0); }
    if (p_new) *p_new = (uint64_t)pos;
    bo3_set_last_error(ctx, 0);
    return ret_u64(1);
}

// 0x10010c4ec: SetFilePointer(h, distLo, pDistHi, moveMethod)
SHIM_DEF(g_10010c4ec) {
    SHIM_UNUSED_ALL();
    int32_t lo = (int32_t)rsi;
    int32_t *p_hi = (int32_t *)rdx;
    uint32_t method = (uint32_t)rcx;
    int64_t dist = p_hi ? (((int64_t)*p_hi << 32) | (uint32_t)lo) : (int64_t)lo;
    if (method > 2) { bo3_set_last_error(ctx, 0x57); return ret_u64(0xffffffffULL); }
    Bo3Handle *h = bo3_handle_pin(rdi, H_FILE);
    if (!h || !h->fp) {
        if (h) bo3_handle_release(h);
        bo3_set_last_error(ctx, 6);
        return ret_u64(0xffffffffULL);
    }
    int whence = (method == 0) ? SEEK_SET : (method == 1 ? SEEK_CUR : SEEK_END);
    pthread_mutex_lock(&h->mtx);
    int rc = fseeko(h->fp, (off_t)dist, whence);
    uint64_t pos = (rc == 0) ? (uint64_t)ftello(h->fp) : 0;
    pthread_mutex_unlock(&h->mtx);
    bo3_handle_release(h);
    if (rc != 0) { bo3_set_last_error(ctx, 0x83); return ret_u64(0xffffffffULL); }
    if (p_hi) *p_hi = (int32_t)(pos >> 32);
    else if (pos >> 32) { bo3_set_last_error(ctx, 0x19); return ret_u64(0xffffffffULL); }
    bo3_set_last_error(ctx, 0);
    return ret_u64((uint32_t)pos);
}

// 0x10010c5f1: GetFileSize(h, pHigh)
SHIM_DEF(g_10010c5f1) {
    SHIM_UNUSED_ALL();
    uint32_t *p_hi = (uint32_t *)rsi;
    if (p_hi) *p_hi = 0;
    Bo3Handle *h = bo3_handle_pin(rdi, H_FILE);
    if (!h || !h->fp) {
        if (h) bo3_handle_release(h);
        bo3_set_last_error(ctx, 6);
        return ret_u64(0xffffffffULL);
    }
    struct stat st;
    int rc = fstat(h->fd, &st);
    bo3_handle_release(h);
    if (rc != 0) { bo3_set_last_error(ctx, 0x1e); return ret_u64(0xffffffffULL); }
    uint64_t sz = (uint64_t)st.st_size;
    if (p_hi) *p_hi = (uint32_t)(sz >> 32);
    bo3_set_last_error(ctx, 0);
    return ret_u64((uint32_t)sz);
}

// 0x10010c6ac: DeleteFileA(path)
SHIM_DEF(g_10010c6ac) {
    SHIM_UNUSED_ALL();
    if (!rdi) return ret_u64(0);
    char path[PATH_MAX];
    bo3_resolve_path((const char *)rdi, path, sizeof(path));
    if (unlink(path) == 0) { bo3_set_last_error(ctx, 0); return ret_u64(1); }
    bo3_set_last_error(ctx, errno == ENOENT ? 2 : 5);
    return ret_u64(0);
}

// 0x10010c70b: GetFileAttributesA(path)
SHIM_DEF(g_10010c70b) {
    SHIM_UNUSED_ALL();
    if (!rdi) { bo3_set_last_error(ctx, 2); return ret_u64(0xffffffffULL); }
    char path[PATH_MAX];
    bo3_resolve_path_ex((const char *)rdi, path, sizeof(path), 1);
    struct stat st;
    if (stat(path, &st) != 0) {
        bo3_set_last_error(ctx, 2);
        return ret_u64(0xffffffffULL);
    }
    bo3_set_last_error(ctx, 0);
    return ret_u64(S_ISDIR(st.st_mode) ? 0x10ULL : 0x80ULL);
}

// 0x10010c760: GetCurrentDirectoryA(bufLen, buf)
SHIM_DEF(g_10010c760) {
    SHIM_UNUSED_ALL();
    uint32_t buflen = (uint32_t)rdi;
    char *buf = (char *)rsi;
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) { bo3_set_last_error(ctx, 0x57); return ret_u64(0); }
    bo3_set_last_error(ctx, 0);
    size_t len = strlen(cwd);
    if (len + 1 <= buflen && buf) {
        memcpy(buf, cwd, len + 1);
        return ret_u64((uint32_t)len);
    }
    return ret_u64((uint32_t)(len + 1));
}

// FindFirstFileA / FindNextFileA / FindClose (and _findfirst/_findnext/_findclose)
typedef struct Bo3FindEntry {
    char     name[260];
    uint32_t attrs;
    uint64_t size;
    time_t   ctime;
    time_t   atime;
    time_t   mtime;
} Bo3FindEntry;

typedef struct Bo3FindHandle {
    uint64_t      magic;
    Bo3FindEntry *entries;
    size_t        count;
    size_t        idx;
} Bo3FindHandle;

#define BO3_FIND_MAGIC 0x424F3346494E4448ULL

static Bo3FindHandle *bo3_find_build(const char *raw_pat) {
    char pat[PATH_MAX];
    bo3_normalize_path(raw_pat, pat, sizeof(pat));
    if (!pat[0]) return NULL;
    char dir_part[PATH_MAX], mask_part[260];
    char *slash = strrchr(pat, '/');
    if (slash) {
        size_t dl = (size_t)(slash - pat);
        if (dl == 0) { dir_part[0] = '/'; dir_part[1] = 0; }
        else { memcpy(dir_part, pat, dl); dir_part[dl] = 0; }
        strlcpy(mask_part, slash + 1, sizeof(mask_part));
    } else {
        strlcpy(dir_part, ".", sizeof(dir_part));
        strlcpy(mask_part, pat, sizeof(mask_part));
    }
    char resolved_dir[PATH_MAX];
    bo3_resolve_path(dir_part, resolved_dir, sizeof(resolved_dir));
    DIR *d = opendir(resolved_dir);
    if (!d) return NULL;

    Bo3FindHandle *fh = (Bo3FindHandle *)calloc(1, sizeof(Bo3FindHandle));
    if (!fh) { closedir(d); return NULL; }
    fh->magic = BO3_FIND_MAGIC;
    size_t cap = 32;
    fh->entries = (Bo3FindEntry *)calloc(cap, sizeof(Bo3FindEntry));
    if (!fh->entries) { free(fh); closedir(d); return NULL; }

    // Windows "*.*" matches everything
    int match_all = (strcmp(mask_part, "*") == 0 || strcmp(mask_part, "*.*") == 0);
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (!match_all && fnmatch(mask_part, de->d_name, FNM_CASEFOLD) != 0) continue;
        char full[PATH_MAX];
        snprintf(full, sizeof(full), "%s/%s", resolved_dir, de->d_name);
        bo3_maybe_overlay_zone_path(full, sizeof(full));
        struct stat st;
        if (stat(full, &st) != 0) continue;
        if (fh->count == cap) {
            cap *= 2;
            Bo3FindEntry *grown = (Bo3FindEntry *)realloc(fh->entries, cap * sizeof(Bo3FindEntry));
            if (!grown) break;
            fh->entries = grown;
        }
        Bo3FindEntry *e = &fh->entries[fh->count++];
        strlcpy(e->name, de->d_name, sizeof(e->name));
        e->attrs = S_ISDIR(st.st_mode) ? 0x10u : 0x80u;
        e->size  = S_ISDIR(st.st_mode) ? 0 : (uint64_t)st.st_size;
        e->ctime = st.st_birthtimespec.tv_sec ? st.st_birthtimespec.tv_sec : st.st_ctime;
        e->atime = st.st_atime;
        e->mtime = st.st_mtime;
    }
    closedir(d);
    if (fh->count == 0) {
        free(fh->entries);
        free(fh);
        return NULL;
    }
    return fh;
}

static void bo3_fill_win32_find_data(uint8_t *dst, const Bo3FindEntry *e) {
    memset(dst, 0, 0x140);
    uint64_t ft_c = unix_to_filetime(e->ctime);
    uint64_t ft_a = unix_to_filetime(e->atime);
    uint64_t ft_m = unix_to_filetime(e->mtime);
    uint32_t sz_hi = (uint32_t)(e->size >> 32);
    uint32_t sz_lo = (uint32_t)(e->size & 0xffffffffu);
    memcpy(dst + 0x00, &e->attrs, 4);
    memcpy(dst + 0x04, &ft_c, 8); // unaligned +4
    memcpy(dst + 0x0c, &ft_a, 8); // unaligned +12
    memcpy(dst + 0x14, &ft_m, 8); // unaligned +20
    memcpy(dst + 0x1c, &sz_hi, 4);
    memcpy(dst + 0x20, &sz_lo, 4);
    strlcpy((char *)(dst + 0x2c), e->name, 260);
}

static void bo3_fill_crt_find_data(uint8_t *dst, const Bo3FindEntry *e) {
    memset(dst, 0, 0x130);
    *(uint32_t *)(dst + 0x00) = e->attrs;
    *(uint64_t *)(dst + 0x08) = (uint64_t)e->ctime;
    *(uint64_t *)(dst + 0x10) = (uint64_t)e->atime;
    *(uint64_t *)(dst + 0x18) = (uint64_t)e->mtime;
    *(uint64_t *)(dst + 0x20) = e->size;
    strlcpy((char *)(dst + 0x28), e->name, 260);
}

// 0x10010c872: _findfirst64(pat, _finddata64_t*)
SHIM_DEF(g_10010c872) {
    SHIM_UNUSED_ALL();
    if (!rdi || !rsi) { bo3_set_last_error(ctx, 0x57); return ret_u64(0xffffffffffffffffULL); }
    Bo3FindHandle *fh = bo3_find_build((const char *)rdi);
    if (!fh) { bo3_set_last_error(ctx, 2); return ret_u64(0xffffffffffffffffULL); }
    bo3_fill_crt_find_data((uint8_t *)rsi, &fh->entries[0]);
    fh->idx = 1;
    bo3_set_last_error(ctx, 0);
    return ret_ptr(fh);
}
// 0x10010d148: _findnext64(h, _finddata64_t*)
SHIM_DEF(g_10010d148) {
    SHIM_UNUSED_ALL();
    if (rdi == 0 || rdi == 0xffffffffffffffffULL || !rsi) { bo3_set_last_error(ctx, 2); return ret_u64(0xffffffffULL); }
    Bo3FindHandle *fh = (Bo3FindHandle *)rdi;
    if (fh->magic != BO3_FIND_MAGIC || fh->idx >= fh->count) { bo3_set_last_error(ctx, 18); return ret_u64(0xffffffffULL); }
    bo3_fill_crt_find_data((uint8_t *)rsi, &fh->entries[fh->idx++]);
    bo3_set_last_error(ctx, 0);
    return ret_u64(0);
}
// 0x10010d1f1: _findclose(h)
SHIM_DEF(g_10010d1f1) {
    SHIM_UNUSED_ALL();
    if (rdi == 0 || rdi == 0xffffffffffffffffULL) return ret_u64(0xffffffffULL);
    Bo3FindHandle *fh = (Bo3FindHandle *)rdi;
    if (fh->magic == BO3_FIND_MAGIC) {
        fh->magic = 0;
        free(fh->entries);
        free(fh);
        return ret_u64(0);
    }
    return ret_u64(0);
}
// 0x10010d259: FindFirstFileA(pat, WIN32_FIND_DATAA*)
SHIM_DEF(g_10010d259) {
    SHIM_UNUSED_ALL();
    if (!rdi || !rsi) { bo3_set_last_error(ctx, 0x57); return ret_u64(0xffffffffffffffffULL); }
    Bo3FindHandle *fh = bo3_find_build((const char *)rdi);
    if (!fh) { bo3_set_last_error(ctx, 2); return ret_u64(0xffffffffffffffffULL); }
    bo3_fill_win32_find_data((uint8_t *)rsi, &fh->entries[0]);
    fh->idx = 1;
    bo3_set_last_error(ctx, 0);
    return ret_ptr(fh);
}
// 0x10010d366: FindNextFileA(h, WIN32_FIND_DATAA*)
SHIM_DEF(g_10010d366) {
    SHIM_UNUSED_ALL();
    if (rdi == 0 || rdi == 0xffffffffffffffffULL || !rsi) { bo3_set_last_error(ctx, 6); return ret_u64(0); }
    Bo3FindHandle *fh = (Bo3FindHandle *)rdi;
    if (fh->magic != BO3_FIND_MAGIC || fh->idx >= fh->count) { bo3_set_last_error(ctx, 18); return ret_u64(0); }
    bo3_fill_win32_find_data((uint8_t *)rsi, &fh->entries[fh->idx++]);
    bo3_set_last_error(ctx, 0);
    return ret_u64(1);
}
// 0x10010d47d: FindClose(h)
SHIM_DEF(g_10010d47d) {
    SHIM_UNUSED_ALL();
    if (rdi == 0 || rdi == 0xffffffffffffffffULL) { bo3_set_last_error(ctx, 6); return ret_u64(0); }
    Bo3FindHandle *fh = (Bo3FindHandle *)rdi;
    if (fh->magic == BO3_FIND_MAGIC) {
        fh->magic = 0;
        free(fh->entries);
        free(fh);
        return ret_u64(1);
    }
    return ret_u64(1);
}

// =========================================================================
// 6. Modules, ComputerName, Winsock, Assert
// =========================================================================

// 0x10010ab50: LoadLibraryA(name)
SHIM_DEF(g_10010ab50) {
    SHIM_UNUSED_ALL();
    const char *name = (const char *)rdi;
    if (!name) return ret_u64(0);
    if (strcasestr(name, ".dll")) return ret_u64(1);
    void *h = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    return ret_ptr(h);
}
// 0x10010b113: GetModuleHandleA(name)
SHIM_DEF(g_10010b113) {
    SHIM_UNUSED_ALL();
    const char *name = (const char *)rdi;
    if (!name || strcasestr(name, ".dll")) return ret_u64(1);
    return ret_u64(0);
}
// 0x10010b20c: GetComputerNameExA(nameType, buf, pSize)
SHIM_DEF(g_10010b20c) {
    SHIM_UNUSED_ALL();
    char *buf = (char *)rsi;
    uint32_t *psz = (uint32_t *)rdx;
    if (!psz) return ret_u64(0);
    char host[256] = "mac-arm64";
    gethostname(host, sizeof(host) - 1);
    host[sizeof(host) - 1] = 0;
    size_t len = strlen(host);
    if (!buf || *psz < len + 1) {
        *psz = (uint32_t)(len + 1);
        bo3_set_last_error(ctx, 234); // ERROR_MORE_DATA
        return ret_u64(0);
    }
    memcpy(buf, host, len + 1);
    *psz = (uint32_t)len;
    return ret_u64(1);
}
// 0x10010b1bc: GetComputerNameA(buf, pSize)
SHIM_DEF(g_10010b1bc) {
    SHIM_UNUSED_ALL();
    char *buf = (char *)rdi;
    uint32_t *psz = (uint32_t *)rsi;
    if (!buf || !psz || *psz == 0) return ret_u64(0);
    char host[256] = "mac-arm64";
    gethostname(host, sizeof(host) - 1);
    host[sizeof(host) - 1] = 0;
    size_t len = strlen(host);
    if (*psz < len + 1) {
        *psz = (uint32_t)(len + 1);
        bo3_set_last_error(ctx, 111); // ERROR_BUFFER_OVERFLOW
        return ret_u64(0);
    }
    memcpy(buf, host, len + 1);
    *psz = (uint32_t)len;
    return ret_u64(1);
}
// Winsock extras
SHIM_DEF(g_10011028a) { SHIM_UNUSED_ALL(); close((int)rdi); return ret_u64(0); } // closesocket
SHIM_DEF(g_10011030e) { SHIM_UNUSED_ALL(); return ret_i64(ioctl((int)rdi, (unsigned long)rsi, (void *)rdx)); } // ioctlsocket
SHIM_DEF(g_1001104b2) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1001104ba) { SHIM_UNUSED_ALL(); return ret_u64(0); }

// 0x1001062cc: Aspyr assert printer
SHIM_DEF(g_1001062cc) {
    SHIM_UNUSED_ALL();
    fprintf(stderr, "[aspyr-assert] %s:%u: failed assertion '%s' in func %s\n",
            rsi ? (const char *)rsi : "?", (unsigned)(uint32_t)rdx,
            rcx ? (const char *)rcx : "?", rdi ? (const char *)rdi : "?");
    fflush(stderr);
    return ret_void();
}

// =========================================================================
// 7. Native macOS AppKit Windowing, Message Queue, RawInput, Display, GDI (M3)
// =========================================================================

// 0x10011675d: SetProcessDPIAware
SHIM_DEF(g_10011675d) { SHIM_UNUSED_ALL(); return ret_u64(1); }
// 0x1001148fd / 0x100114988: RegisterClassA / RegisterClassExA
// Both WNDCLASSA and WNDCLASSEXA have lpfnWndProc at +0x08 and lpszClassName at +0x40 on x86_64!
SHIM_DEF(g_1001148fd) {
    SHIM_UNUSED_ALL();
    if (rdi) {
        uint64_t wndproc = *(const uint64_t *)(rdi + 0x08);
        const char *cls = *(const char *const *)(rdi + 0x40);
        bo3_win_register_class(cls, wndproc);
    }
    return ret_u64(0xc001);
}
SHIM_DEF(g_100114988) {
    SHIM_UNUSED_ALL();
    if (rdi) {
        uint64_t wndproc = *(const uint64_t *)(rdi + 0x08);
        const char *cls = *(const char *const *)(rdi + 0x40);
        bo3_win_register_class(cls, wndproc);
    }
    return ret_u64(0xc001);
}
// 0x100114b44: CreateWindowExA(exStyle=rdi, className=rsi, windowName=rdx, style=ecx, x=r8d, y=r9d, w=[rsp+8], h=[rsp+16], parent=[rsp+24], ...)
SHIM_DEF(g_100114b44) {
    SHIM_UNUSED_ALL();
    int32_t sw = (int32_t)shim_stack_u64(rsp, 0);
    int32_t sh = (int32_t)shim_stack_u64(rsp, 1);
    uint64_t parent = shim_stack_u64(rsp, 2);
    uint64_t hwnd = bo3_win_create(ctx, rsp, (uint32_t)rdi, (const char *)rsi, (const char *)rdx,
                                   (uint32_t)rcx, (int32_t)r8, (int32_t)r9, sw, sh, parent);
    return ret_u64(hwnd);
}
SHIM_DEF(g_1001142b0) { SHIM_UNUSED_ALL(); bo3_win_destroy(rdi); return ret_u64(1); } // DestroyWindow
SHIM_DEF(g_1001143ca) { SHIM_UNUSED_ALL(); bo3_win_show(rdi, (int)rsi); return ret_u64(1); } // ShowWindow
SHIM_DEF(g_100115236) { SHIM_UNUSED_ALL(); return ret_u64(1); } // UpdateWindow
SHIM_DEF(g_100115241) {
    // MoveWindow(hwnd, x, y, w, h, repaint)
    SHIM_UNUSED_ALL();
    bo3_win_move(rdi, (int32_t)rsi, (int32_t)rdx, (int32_t)rcx, (int32_t)r8);
    return ret_u64(1);
}
SHIM_DEF(g_1001152a1) {
    // SetWindowPos(hwnd, after, x, y, cx, cy, flags)
    SHIM_UNUSED_ALL();
    uint32_t flags = (uint32_t)shim_stack_u64(rsp, 0);
    bo3_win_set_pos(rdi, (int32_t)rdx, (int32_t)rcx, (int32_t)r8, (int32_t)r9, flags);
    return ret_u64(1);
}
SHIM_DEF(g_100115366) { SHIM_UNUSED_ALL(); return ret_u64(bo3_win_get_main_hwnd()); } // SetFocus
SHIM_DEF(g_100113f88) { SHIM_UNUSED_ALL(); return ret_u64(bo3_win_get_main_hwnd()); } // GetForegroundWindow
SHIM_DEF(g_100115603) { SHIM_UNUSED_ALL(); return ret_u64(bo3_win_get_main_hwnd()); } // GetActiveWindow
SHIM_DEF(g_100115881) { SHIM_UNUSED_ALL(); return ret_u64(bo3_win_get_main_hwnd()); } // GetDesktopWindow
SHIM_DEF(g_1001145ae) { SHIM_UNUSED_ALL(); return ret_u64(bo3_win_set_long(rdi, (int32_t)rsi, rdx)); }
SHIM_DEF(g_1001145fb) { SHIM_UNUSED_ALL(); return ret_u64(bo3_win_set_long(rdi, (int32_t)rsi, rdx)); }
SHIM_DEF(g_1001146a4) { SHIM_UNUSED_ALL(); return ret_u64(bo3_win_get_long(rdi, (int32_t)rsi)); }
SHIM_DEF(g_100115630) { SHIM_UNUSED_ALL(); bo3_win_set_title(rdi, (const char *)rsi); return ret_u64(1); }
SHIM_DEF(g_1001156fe) {
    SHIM_UNUSED_ALL();
    if (!rsi || (int32_t)rdx <= 0) return ret_u64(0);
    return ret_u64(bo3_win_get_title(rdi, (char *)rsi, (size_t)(int32_t)rdx));
}
SHIM_DEF(g_1001158c8) { SHIM_UNUSED_ALL(); return ret_u64(bo3_win_get_client_rect(rdi, (int32_t *)rsi) ? 1 : 0); }
SHIM_DEF(g_10011592f) { SHIM_UNUSED_ALL(); return ret_u64(bo3_win_get_window_rect(rdi, (int32_t *)rsi) ? 1 : 0); }
SHIM_DEF(g_1001153c3) {
    // GetSystemMetrics(int idx)
    SHIM_UNUSED_ALL();
    int32_t sw = 1920, sh = 1080;
    bo3_win_get_screen_size(&sw, &sh);
    switch ((int32_t)rdi) {
        case 0: case 16: case 78: return ret_u64((uint32_t)sw);
        case 1: case 17: case 79: return ret_u64((uint32_t)sh);
        case 76: case 77: return ret_u64(0);
        case 80: return ret_u64(1); // SM_CMONITORS
        case 19: case 75: return ret_u64(1);
        case 36: case 37: return ret_u64(4);
        case 43: return ret_u64(3);
        case 68: case 69: return ret_u64(2);
        case 2: case 3: case 13: case 14: case 20: case 21: case 49: case 50: return ret_u64(16);
        default: return ret_u64(0);
    }
}
SHIM_DEF(g_1001155de) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1001155e6) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1001155f1) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1001159d6) { SHIM_UNUSED_ALL(); return ret_u64(1); } // AdjustWindowRect
SHIM_DEF(g_1001159e1) { SHIM_UNUSED_ALL(); return ret_u64(1); }
SHIM_DEF(g_1001159f9) { SHIM_UNUSED_ALL(); return ret_u64(0x1001); } // LoadCursorA
// Aspyr keeps ShowCursor display count (TLS 0x102104e38) and current HCURSOR (TLS 0x102104e68)
// per thread. Only ShowCursor drives relative FPS mouse capture; SetCursor preserves per-thread
// handle semantics without accidentally capturing the pointer if a guest ever passes NULL.
static _Thread_local int32_t  tl_cursor_count = 0;
static _Thread_local uint64_t tl_current_cursor = 0x1001; // default IDC_ARROW
SHIM_DEF(g_1001144ab) { // SetCursor(HCURSOR hCursor)
    SHIM_UNUSED_ALL();
    uint64_t prev = tl_current_cursor;
    tl_current_cursor = rdi;
    return ret_u64(prev);
}
SHIM_DEF(g_100115c95) { // ShowCursor(BOOL bShow)
    SHIM_UNUSED_ALL();
    int32_t c = ((int32_t)rdi) ? (++tl_cursor_count) : (--tl_cursor_count);
    bo3_win_show_cursor(c >= 0);
    return ret_i64(c);
}
SHIM_DEF(g_100115da9) { SHIM_UNUSED_ALL(); bo3_win_set_cursor_pos((int32_t)rdi, (int32_t)rsi); return ret_u64(1); }
SHIM_DEF(g_100115dda) {
    SHIM_UNUSED_ALL();
    if (!rdi) return ret_u64(0);
    bo3_win_get_cursor_pos((int32_t *)rdi);
    return ret_u64(1);
}
SHIM_DEF(g_100115ea3) { SHIM_UNUSED_ALL(); return ret_u64(0x1002); }
SHIM_DEF(g_100115ed3) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_100115ee2) {
    SHIM_UNUSED_ALL();
    if (!rdi || !rsi) return ret_u64(0);
    bo3_win_screen_to_client(rdi, (int32_t *)rsi);
    return ret_u64(1);
}
SHIM_DEF(g_100115f8b) { SHIM_UNUSED_ALL(); return ret_u64(0); } // MapVirtualKeyA
SHIM_DEF(g_10011603f) {
    // MessageBoxA(hwnd, text, caption, type)
    SHIM_UNUSED_ALL();
    fprintf(stderr, "[win32-MessageBoxA] [%s] %s\n",
            rdx ? (const char *)rdx : "Error",
            rsi ? (const char *)rsi : "");
    fflush(stderr);
    return ret_u64(1); // IDOK
}
SHIM_DEF(g_10011676e) { SHIM_UNUSED_ALL(); return ret_u64(0); } // ChangeDisplaySettingsA (DISP_CHANGE_SUCCESSFUL)
SHIM_DEF(g_100116839) {
    // EnumDisplaySettingsA(devName, modeNum, DEVMODEA*)
    SHIM_UNUSED_ALL();
    uint32_t mode = (uint32_t)rsi;
    uint8_t *dm = (uint8_t *)rdx;
    if (!dm) return ret_u64(0);
    if (mode != 0xffffffffu && mode != 0xfffffffeu && mode > 0) return ret_u64(0);
    int32_t sw = 1920, sh = 1080;
    bo3_win_get_screen_size(&sw, &sh);
    memset(dm, 0, 156);
    *(uint16_t *)(dm + 36) = 156;
    *(uint32_t *)(dm + 40) = 0x1c0000;
    *(uint32_t *)(dm + 104) = 32;
    *(uint32_t *)(dm + 108) = (uint32_t)sw;
    *(uint32_t *)(dm + 112) = (uint32_t)sh;
    *(uint32_t *)(dm + 120) = 60;
    return ret_u64(1);
}
SHIM_DEF(g_100116a3a) { SHIM_UNUSED_ALL(); return ret_u64(1); } // MonitorFromWindow -> HMONITOR 1
SHIM_DEF(g_1001169b3) {
    // GetMonitorInfoA(hMon, MONITORINFO*)
    SHIM_UNUSED_ALL();
    int32_t *mi = (int32_t *)rsi;
    if (!mi) return ret_u64(0);
    int32_t sw = 1920, sh = 1080;
    bo3_win_get_screen_size(&sw, &sh);
    mi[1] = 0; mi[2] = 0; mi[3] = sw; mi[4] = sh;
    mi[5] = 0; mi[6] = 0; mi[7] = sw; mi[8] = sh;
    mi[9] = 1;
    if (mi[0] == 0x48) strlcpy((char *)(mi + 10), "\\\\.\\DISPLAY1", 32);
    return ret_u64(1);
}
static volatile uint32_t g_next_wm_id = 0xc000;
SHIM_DEF(g_100116bc1) {
    SHIM_UNUSED_ALL();
    return ret_u64(__atomic_fetch_add(&g_next_wm_id, 1, __ATOMIC_RELAXED));
}
// Real Win32 Message Loop & SendMessageA (drives 0x8042 CreateSwapChain / 0x8043 Present / 0x8044 Fullscreen!)
SHIM_DEF(g_1001137f2) {
    SHIM_UNUSED_ALL();
    return ret_i64(bo3_win_peek_message((uint8_t *)rdi, rsi, (uint32_t)rdx, (uint32_t)rcx, (uint32_t)r8));
}
SHIM_DEF(g_10011382d) {
    SHIM_UNUSED_ALL();
    return ret_i64(bo3_win_get_message((uint8_t *)rdi, rsi, (uint32_t)rdx, (uint32_t)rcx));
}
SHIM_DEF(g_100113877) { SHIM_UNUSED_ALL(); return ret_u64(1); } // TranslateMessage (WM_CHAR already queued on keyDown)
SHIM_DEF(g_1001138cd) {
    SHIM_UNUSED_ALL();
    return ret_i64(bo3_win_post_message(rdi, (uint32_t)rsi, rdx, rcx));
}
SHIM_DEF(g_1001138ea) {
    SHIM_UNUSED_ALL();
    return ret_u64(bo3_win_dispatch_message(ctx, rsp, (const uint8_t *)rdi));
}
SHIM_DEF(g_10011399c) {
    SHIM_UNUSED_ALL();
    return ret_u64(bo3_win_call_wndproc(ctx, rsp, rdi, rsi, (uint32_t)rdx, rcx, r8));
}
SHIM_DEF(g_100113c03) {
    SHIM_UNUSED_ALL();
    return ret_u64(bo3_win_send_message(ctx, rsp, rdi, (uint32_t)rsi, rdx, rcx));
}
SHIM_DEF(g_100113e46) {
    SHIM_UNUSED_ALL();
    bo3_win_post_message(0, 0x0012 /* WM_QUIT */, rdi, 0);
    return ret_void();
}
SHIM_DEF(g_100113e6a) {
    // RegisterRawInputDevices(pRawInputDevices, uiNumDevices, cbSize)
    SHIM_UNUSED_ALL();
    if (rdi && rsi > 0) {
        // RAWINPUTDEVICE: usUsagePage(2), usUsage(2), dwFlags(4), hwndTarget(8) -> +8
        uint64_t target = *(const uint64_t *)(rdi + 8);
        if (target) bo3_win_register_raw_input(target);
    }
    return ret_u64(1);
}
SHIM_DEF(g_100113fa0) {
    // GetRawInputBuffer(pData, pcbSize, cbSizeHeader) — called by BO3's input thread at 0x100fc4e1a
    SHIM_UNUSED_ALL();
    return ret_u64(bo3_win_get_raw_input_buffer((void *)rdi, (uint32_t *)rsi, (uint32_t)rdx));
}
SHIM_DEF(g_10011408a) { SHIM_UNUSED_ALL(); return ret_u64(0); } // DefWindowProcA

// GDI stubs (0x10010eccb .. 0x10010ef93)
static uint64_t g_dummy_dc[8] = {0};
SHIM_DEF(g_10010eccb) { SHIM_UNUSED_ALL(); return ret_ptr(g_dummy_dc); } // GetDC
SHIM_DEF(g_10010ed86) { SHIM_UNUSED_ALL(); return ret_u64(1); }          // ReleaseDC
SHIM_DEF(g_10010edb7) {
    // GetDeviceCaps(hdc, idx)
    SHIM_UNUSED_ALL();
    switch ((int32_t)rsi) {
        case 8: return ret_u64(1920);   // HORZRES
        case 10: return ret_u64(1080);  // VERTRES
        case 12: return ret_u64(32);    // BITSPIXEL
        case 88: case 90: return ret_u64(96); // LOGPIXELSX/Y
        case 116: return ret_u64(60);   // VREFRESH
        default: return ret_u64(0);
    }
}
SHIM_DEF(g_10010ee9d) { SHIM_UNUSED_ALL(); return ret_u64(0); } // GetDeviceGammaRamp
SHIM_DEF(g_10010ef2b) { SHIM_UNUSED_ALL(); return ret_ptr(g_dummy_dc); } // GetStockObject
SHIM_DEF(g_10010ef93) { SHIM_UNUSED_ALL(); return ret_u64(0); }

// WinMM / Mixer / Audio stubs (0x1000f5*)
SHIM_DEF(g_1000f550a) { SHIM_UNUSED_ALL(); return ret_u64(0); } // mixerGetNumDevs
SHIM_DEF(g_1000f5976) { SHIM_UNUSED_ALL(); return ret_u64(2); } // MMSYSERR_BADDEVICEID
SHIM_DEF(g_1000f59c2) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1000f59d3) { SHIM_UNUSED_ALL(); return ret_u64(1); }
SHIM_DEF(g_1000f5a14) { SHIM_UNUSED_ALL(); return ret_u64(1); }
SHIM_DEF(g_1000f5ab0) { SHIM_UNUSED_ALL(); return ret_u64(1); }
SHIM_DEF(g_1000f5bd0) { SHIM_UNUSED_ALL(); return ret_u64(1); }
SHIM_DEF(g_1000f5cb7) { SHIM_UNUSED_ALL(); return ret_u64(2); }
SHIM_DEF(g_1000f5d1f) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1000f5d46) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1000f5d4e) { SHIM_UNUSED_ALL(); return ret_u64(0); }

// Media Foundation / VideoToolbox hardware H.264 cinematic shims (runtime/media_avf.mm)
SHIM_DEF(g_1000ef820) { return bo3_mf_startup(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7); }
SHIM_DEF(g_1000ef9f0) { return bo3_mf_shutdown(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7); }
SHIM_DEF(g_1000ef82d) { return bo3_mf_create_aligned_memory_buffer(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7); }
SHIM_DEF(g_1000ef8b8) { return bo3_mf_create_media_type(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7); }
SHIM_DEF(g_1000ef94c) { return bo3_mf_create_sample(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7); }
SHIM_DEF(g_100004551) { SHIM_UNUSED_ALL(); return ret_u64(0); } // Aspyr language/region enum (0 = English)
SHIM_DEF(g_100105ae0) { SHIM_UNUSED_ALL(); return ret_u64(0); } // Aspyr command-line check
SHIM_DEF(g_100129ed3) { SHIM_UNUSED_ALL(); return ret_u64(0); } // Aspyr input query
SHIM_DEF(g_10012ba30) { BO3_SHIM_FORWARD(bo3_shim_SDL_QueueAudio); }
SHIM_DEF(g_10012d270) { BO3_SHIM_FORWARD(bo3_shim_SDL_OpenAudioDevice); }
SHIM_DEF(g_10012d280) { BO3_SHIM_FORWARD(bo3_shim_SDL_PauseAudioDevice); }
SHIM_DEF(g_10012d2e0) { BO3_SHIM_FORWARD(bo3_shim_SDL_CloseAudioDevice); }
SHIM_DEF(g_1000eedbe) { SHIM_UNUSED_ALL(); return ret_u64(111); } // GetAdaptersInfo -> ERROR_BUFFER_OVERFLOW / no adapters
SHIM_DEF(g_100012c17) {
    // Aspyr GetProfileString / config lookup: write default (rcx) to dst (rdi, size rsi)
    SHIM_UNUSED_ALL();
    char *dst = (char *)rdi;
    size_t sz = (size_t)rsi;
    const char *def = (const char *)rcx;
    if (!dst || sz == 0) return ret_u64(0);
    if (!def) { dst[0] = 0; return ret_u64(0); }
    size_t n = strlcpy(dst, def, sz);
    return ret_u64(n < sz ? n : sz - 1);
}
SHIM_DEF(g_1001040c6) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1001294a8) { BO3_GAMEPAD_FORWARD(bo3_shim_XInputGetState); }
SHIM_DEF(g_1001295ac) { BO3_GAMEPAD_FORWARD(bo3_shim_XInputSetState); }

// Win32 Event hooks for native CoreAudio WASAPI event-driven streaming (audio_coreaudio.mm).
// Validated strictly via the generation-tagged g_handle_table; never dereferences raw guest values
// and keeps WASAPI's internal_refs isolated from guest CloseHandle().
static void bo3_audio_event_signal(uint64_t guest_handle) {
    pthread_mutex_lock(&g_handle_lock);
    Bo3Handle *h = bo3_handle_lookup_locked(guest_handle);
    if (!h || h->kind != H_EVENT || h->internal_refs <= 0) {
        pthread_mutex_unlock(&g_handle_lock);
        return;
    }
    h->pins++;
    pthread_mutex_unlock(&g_handle_lock);

    pthread_mutex_lock(&h->mtx);
    h->signaled = 1;
    if (h->manual_reset) pthread_cond_broadcast(&h->cond);
    else pthread_cond_signal(&h->cond);
    pthread_mutex_unlock(&h->mtx);
    bo3_handle_release(h);
}
static int bo3_audio_event_retain(uint64_t guest_handle) {
    pthread_mutex_lock(&g_handle_lock);
    Bo3Handle *h = bo3_handle_lookup_locked(guest_handle);
    if (!h || h->kind != H_EVENT || h->guest_refs <= 0) {
        pthread_mutex_unlock(&g_handle_lock);
        return 0;
    }
    h->internal_refs++;
    pthread_mutex_unlock(&g_handle_lock);
    return 1;
}
static void bo3_audio_event_release(uint64_t guest_handle) {
    pthread_mutex_lock(&g_handle_lock);
    Bo3Handle *h = bo3_handle_lookup_locked(guest_handle);
    if (!h || h->kind != H_EVENT || h->internal_refs <= 0) {
        pthread_mutex_unlock(&g_handle_lock);
        return;
    }
    h->internal_refs--;
    int dead = bo3_handle_maybe_reclaim_locked(h);
    pthread_mutex_unlock(&g_handle_lock);
    if (dead) bo3_handle_destroy_unlocked(h);
}

// Override Aspyr's Mac-only .mov AVPlayer open (0x100fb9eb7, only used for video/AspyrLogo.mov
// after BO3_Global_Logo_LogoSequence.mkv). The guest method calls ObjC AVURLAsset async loading
// via stubbed objc_msgSend and blocks forever; returning NULL cleanly triggers BO3's built-in
// fallback (0x1012efdc8) and transitions straight to the 3D Main Menu.
static GuestRet aspyr_mov_open_skip(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    const char *path = (const char *)rdi;
    fprintf(stderr, "[media_avf] Skipping Mac-only Aspyr .mov backend (0x100fb9eb7, path='%s') -> NULL\n",
            path ? path : "");
    fflush(stderr);
    return ret_u64(0);
}

void bo3_init_win32_mocks(void) {
    static int inited = 0;
    if (inited) return;
    bo3_register_fn(0x100fb9eb7ULL, aspyr_mov_open_skip);

    bo3_media_avf_init();
    bo3_audio_set_event_hooks(bo3_audio_event_signal, bo3_audio_event_retain, bo3_audio_event_release);
    bo3_audio_init_guest_vtables();
    bo3_gamepad_init();
    inited = 1;
}

SHIM_DEF(g_1000fbcb0) {
    SHIM_UNUSED_ALL();
    if (!r8) return ret_u64(0x80004003ULL); // E_POINTER
    *(uint64_t *)r8 = 0;
    if (rsi != 0) return ret_u64(0x80040110ULL); // CLASS_E_NOAGGREGATION
    const uint32_t *g = (const uint32_t *)rdi;
    if (g) {
        fprintf(stderr, "[win32] CoCreateInstance({%08x-%04x-%04x-...})\n",
                g[0], g[1] & 0xffff, g[1] >> 16);
        fflush(stderr);
        void *mf_obj = NULL;
        uint32_t mf_hr = 0;
        if (bo3_media_avf_try_cocreate((const void *)rdi, (const void *)rcx, &mf_obj, &mf_hr)) {
            *(uint64_t *)r8 = (uint64_t)(uintptr_t)mf_obj;
            return ret_u64(mf_hr);
        }
        // Aspyr passes IID_IMMDeviceEnumerator or CLSID_MMDeviceEnumerator in rclsid;
        // verify requested riid is IUnknown or IMMDeviceEnumerator (or NULL).
        static const uint8_t kIUnknown[16] = {
            0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xc0,0x00,0x00,0x00,0x00,0x00,0x00,0x46
        };
        if (bo3_wasapi_is_enumerator_guid((const void *)rdi)) {
            if (rcx && !bo3_wasapi_is_enumerator_guid((const void *)rcx) &&
                memcmp((const void *)rcx, kIUnknown, 16) != 0) {
                return ret_u64(0x80004002ULL); // E_NOINTERFACE
            }
            return ret_u64(bo3_wasapi_create_enumerator((uint64_t *)r8));
        }
    }
    // Unknown COM class: return REGDB_E_CLASSNOTREG (0x80040154) with *ppv = NULL so callers
    // take their standard error path instead of dereferencing NULL out-params from a dummy stub.
    return ret_u64(0x80040154ULL);
}

// =========================================================================
// 8. libc++ std::__tree<std::string> COMDAT helpers (0x1000dc338, 0x100100600, 0x1000c9fa8)
// =========================================================================

typedef struct LibcxxRbNode {
    struct LibcxxRbNode *left;
    struct LibcxxRbNode *right;
    struct LibcxxRbNode *parent;
    uint8_t is_black;
    uint8_t _pad[7];
    uint64_t str_words[3]; // 24-byte libc++ SSO std::string
} LibcxxRbNode;

static void rb_left_rotate(LibcxxRbNode *x) {
    LibcxxRbNode *y = x->right;
    x->right = y->left;
    if (x->right) x->right->parent = x;
    y->parent = x->parent;
    if (x == x->parent->left) x->parent->left = y;
    else x->parent->right = y;
    y->left = x;
    x->parent = y;
}

static void rb_right_rotate(LibcxxRbNode *x) {
    LibcxxRbNode *y = x->left;
    x->left = y->right;
    if (x->left) x->left->parent = x;
    y->parent = x->parent;
    if (x == x->parent->left) x->parent->left = y;
    else x->parent->right = y;
    y->right = x;
    x->parent = y;
}

static void rb_balance_after_insert(LibcxxRbNode *root, LibcxxRbNode *x) {
    x->is_black = (x == root) ? 1 : 0;
    while (x != root && !x->parent->is_black) {
        if (x->parent == x->parent->parent->left) {
            LibcxxRbNode *y = x->parent->parent->right;
            if (y && !y->is_black) {
                x = x->parent; x->is_black = 1;
                x = x->parent; x->is_black = (x == root) ? 1 : 0;
                y->is_black = 1;
            } else {
                if (x != x->parent->left) { x = x->parent; rb_left_rotate(x); }
                x = x->parent; x->is_black = 1;
                x = x->parent; x->is_black = 0;
                rb_right_rotate(x);
                break;
            }
        } else {
            LibcxxRbNode *y = x->parent->parent->left;
            if (y && !y->is_black) {
                x = x->parent; x->is_black = 1;
                x = x->parent; x->is_black = (x == root) ? 1 : 0;
                y->is_black = 1;
            } else {
                if (x == x->parent->left) { x = x->parent; rb_right_rotate(x); }
                x = x->parent; x->is_black = 1;
                x = x->parent; x->is_black = 0;
                rb_left_rotate(x);
                break;
            }
        }
    }
}

static void sso_str_view(const uint64_t *w, const char **data, size_t *len) {
    const uint8_t *b = (const uint8_t *)w;
    if (b[0] & 1) {
        *len = (size_t)w[1];
        *data = (const char *)w[2];
    } else {
        *len = (size_t)(b[0] >> 1);
        *data = (const char *)(b + 1);
    }
}

static int sso_str_cmp(const uint64_t *a, const uint64_t *b) {
    const char *da, *db; size_t la, lb;
    sso_str_view(a, &da, &la);
    sso_str_view(b, &db, &lb);
    size_t m = la < lb ? la : lb;
    int c = m ? memcmp(da, db, m) : 0;
    if (c != 0) return c;
    return (la < lb) ? -1 : (la > lb ? 1 : 0);
}

static void rb_destroy_string_tree(LibcxxRbNode *n) {
    if (!n) return;
    rb_destroy_string_tree(n->left);
    rb_destroy_string_tree(n->right);
    if (((uint8_t *)n->str_words)[0] & 1) free((void *)n->str_words[2]);
    free(n);
}

// 0x1000dc338: std::__tree<std::string>::destroy(node)
SHIM_DEF(g_1000dc338) {
    SHIM_UNUSED_ALL();
    rb_destroy_string_tree((LibcxxRbNode *)rsi);
    return ret_void();
}

// 0x100100600: std::__tree_balance_after_insert(root, x)
SHIM_DEF(g_100100600) {
    SHIM_UNUSED_ALL();
    rb_balance_after_insert((LibcxxRbNode *)rdi, (LibcxxRbNode *)rsi);
    return ret_void();
}

// 0x1000c9fa8: std::__tree<std::string>::__emplace_unique_key_args(tree, key, moved_val)
SHIM_DEF(g_1000c9fa8) {
    SHIM_UNUSED_ALL();
    uint64_t *tree = (uint64_t *)rdi; // [0]=begin_node, [1]=end_node.left (root), [2]=size
    const uint64_t *key = (const uint64_t *)rsi;
    uint64_t *val = (uint64_t *)rdx;
    LibcxxRbNode *end_node = (LibcxxRbNode *)&tree[1];
    LibcxxRbNode *parent = end_node;
    LibcxxRbNode **child = &end_node->left;
    LibcxxRbNode *cur = end_node->left;
    while (cur) {
        int c = sso_str_cmp(key, cur->str_words);
        if (c < 0) {
            parent = cur; child = &cur->left; cur = cur->left;
        } else if (c > 0) {
            parent = cur; child = &cur->right; cur = cur->right;
        } else {
            return ret_pair((uint64_t)(uintptr_t)cur, 0);
        }
    }
    LibcxxRbNode *nd = (LibcxxRbNode *)calloc(1, sizeof(LibcxxRbNode));
    nd->str_words[0] = val[0]; nd->str_words[1] = val[1]; nd->str_words[2] = val[2];
    val[0] = val[1] = val[2] = 0;
    nd->parent = parent;
    *child = nd;
    if (((LibcxxRbNode *)tree[0])->left != NULL) tree[0] = (uint64_t)(uintptr_t)((LibcxxRbNode *)tree[0])->left;
    rb_balance_after_insert(end_node->left, nd);
    tree[2]++;
    return ret_pair((uint64_t)(uintptr_t)nd, 1);
}

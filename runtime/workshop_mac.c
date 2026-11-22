// Native ARM64 Steam Workshop, Custom Maps & Mod Compatibility Layer for bo3mac.
//
// Engine hook targets, patch offsets, and the "Mac!" build-int probe follow
// upstream BO3MacFix (InvoxiPlayGames, LGPL-2.1); the clean-room native Havok
// navigation converter and Roulette callback fix are shared with BO3MacFix-mawlicious.
//
// Wraps three lifted Core BO3 functions (emitted as orig_g_* via bo3_lift --wrap-va):
//   1. g_100e09aa9 (HKAI_InitMapData): converts Windows x64 Havok navigation packfiles
//      (NavMeshData / NavVolumeData) natively in-process into macOS .hkt files cached in
//      ~/Library/Application Support/bo3mac/Physics/ whenever a custom map (or the broken
//      cp_mi_cairo_infection2 stock map) lacks valid macOS Physics/*.hkt data.
//   2. g_101345b12 (DB_FindXAssetHeader): applies the exact-hash Roulette V2 optional
//      event-flag callback repair when loading ScriptParseTree (asset type 54).
//   3. g_100f16d9a (Com_GetBuildIntField): responds to the Mac compatibility probe
//      0x4D616321 ("Mac!") with 0x00000102 so Workshop mods detect native Mac support.

#include "shim_helpers.h"
#include "codhavoktypes.h"
#include "nav_convert.h"
#include "script_fixes.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Verify LP64 ARM64 struct layouts match the x86_64 guest binary layouts exactly.
_Static_assert(sizeof(NavMeshData) == 104, "NavMeshData size must match x86_64 guest");
_Static_assert(offsetof(NavMeshData, navMeshSettingsBufferSize) == 8, "NavMeshData layout");
_Static_assert(offsetof(NavMeshData, navMeshSettingsBuffer) == 16, "NavMeshData layout");
_Static_assert(offsetof(NavMeshData, mediatorBuffer) == 64, "NavMeshData layout");
_Static_assert(sizeof(NavVolumeData) == 72, "NavVolumeData size must match x86_64 guest");
_Static_assert(offsetof(NavVolumeData, smallNavVolumeSettingsBuffer) == 16, "NavVolumeData layout");

typedef struct Bo3ScriptParseTree {
    const char *name;
    int32_t     length;
    int32_t     padding;
    void       *buffer;
} Bo3ScriptParseTree;

_Static_assert(sizeof(Bo3ScriptParseTree) == 24 &&
               offsetof(Bo3ScriptParseTree, length) == 8 &&
               offsetof(Bo3ScriptParseTree, buffer) == 16,
               "ScriptParseTree layout must match x86_64 guest");

// Original lifted Core BO3 functions emitted as @orig_g_* by bo3_lift --wrap-va.
extern GuestRet orig_g_100e09aa9(SHIM_PARAMS); // HKAI_InitMapData
extern GuestRet orig_g_101345b12(SHIM_PARAMS); // DB_FindXAssetHeader
extern GuestRet orig_g_100f16d9a(SHIM_PARAMS); // Com_GetBuildIntField
extern GuestRet g_100e71e51(SHIM_PARAMS);      // Com_Error

// Guest global: sSessionModeState at 0x106939a14 (low 4 bits = game mode).
#define BO3_VA_SESSION_MODE_STATE 0x106939a14ULL

static const char *bo3_gamemode_string(void) {
    uint32_t bits = *(const volatile uint32_t *)(uintptr_t)BO3_VA_SESSION_MODE_STATE;
    switch (bits & 0xFu) {
        case 0: return "zm";
        case 1: return "mp";
        case 2: return "cp";
        default: return "core";
    }
}

int bo3_workshop_physics_dir(char *out, size_t out_sz) {
    if (!out || out_sz == 0) return 0;
    const char *override = getenv("BO3MAC_PHYSICS_DIR");
    int n = 0;
    if (override && override[0]) {
        n = snprintf(out, out_sz, "%s", override);
    } else {
        const char *home = getenv("HOME");
        if (!home || !home[0]) home = "/tmp";
        n = snprintf(out, out_sz, "%s/Library/Application Support/bo3mac/Physics", home);
    }
    return (n > 0 && (size_t)n < out_sz) ? 1 : 0;
}

static int bo3_mkdir_p_physics(const char *dir) {
    if (!dir || !dir[0]) return 0;
    char tmp[PATH_MAX];
    if (strlcpy(tmp, dir, sizeof(tmp)) >= sizeof(tmp)) return 0;
    size_t len = strlen(tmp);
    while (len > 1 && tmp[len - 1] == '/') tmp[--len] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return 0;
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return 0;
    return 1;
}

static void bo3_call_com_error(GuestContext *ctx, uint64_t rsp, int line, const char *msg) {
    uint64_t call_sp = ((rsp - 128) & ~15ULL) - 8;
    *(uint64_t *)(uintptr_t)call_sp = 0;
    static const char kFile[] = "workshop_mac.c";
    static const char kFmt[] = "%s";
    ctx->gpr[0] = 0; // SysV ABI: AL = 0 vector arguments for variadic Com_Error
    (void)g_100e71e51(ctx, call_sp,
                      (uint64_t)(uintptr_t)kFile, (uint64_t)(uint32_t)line, 2ULL,
                      (uint64_t)(uintptr_t)kFmt, (uint64_t)(uintptr_t)msg, 0ULL,
                      guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
                      guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
}

static void *bo3_find_xasset_header(GuestContext *ctx, uint64_t rsp, int type, const char *name,
                                    int error_if_missing, int wait_time) {
    uint64_t call_sp = ((rsp - 128) & ~15ULL) - 8;
    *(uint64_t *)(uintptr_t)call_sp = 0;
    GuestRet r = orig_g_101345b12(
        ctx, call_sp,
        (uint64_t)(uint32_t)type,
        (uint64_t)(uintptr_t)name,
        (uint64_t)(uint32_t)(error_if_missing ? 1 : 0),
        (uint64_t)(uint32_t)wait_time,
        0ULL, 0ULL,
        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    return (void *)(uintptr_t)r.rax_rdx[0];
}

// 0x100e09aa9: HKAI_InitMapData(const char *mapname, char restart)
SHIM_DEF(g_100e09aa9) {
    const char *mapname = (const char *)(uintptr_t)rdi;
    if (!mapname || !mapname[0] || strlen(mapname) > 128 ||
        strspn(mapname, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != strlen(mapname)) {
        bo3_call_com_error(ctx, rsp, __LINE__, "^7[^6bo3mac^7] Invalid navigation map name.");
        return ret_void();
    }

    char stock_path[512];
    if (snprintf(stock_path, sizeof(stock_path), "Physics/%s_navmesh.hkt", mapname) >= (int)sizeof(stock_path)) {
        bo3_call_com_error(ctx, rsp, __LINE__, "^7[^6bo3mac^7] Navigation path is too long.");
        return ret_void();
    }

    bool force_convert = (strcmp(mapname, "cp_mi_cairo_infection2") == 0);
    if (access(stock_path, F_OK) != 0 || force_convert) {
        const char *mode_str = bo3_gamemode_string();
        char asset_path[512];
        snprintf(asset_path, sizeof(asset_path), "maps/%s/%s_navmesh", mode_str, mapname);
        NavMeshData *mesh = (NavMeshData *)bo3_find_xasset_header(ctx, rsp, ASSET_TYPE_NAVMESH, asset_path, 1, -1);
        if (!mesh) {
            char err_msg[512];
            snprintf(err_msg, sizeof(err_msg),
                     "^7[^6bo3mac^7] Failed to load navigation data for '^2%s^7'.", mapname);
            bo3_call_com_error(ctx, rsp, __LINE__, err_msg);
            return ret_void();
        }
        snprintf(asset_path, sizeof(asset_path), "maps/%s/%s_navvolume", mode_str, mapname);
        NavVolumeData *volume = (NavVolumeData *)bo3_find_xasset_header(ctx, rsp, ASSET_TYPE_NAVVOLUME, asset_path, 0, -1);

        char physics_dir[PATH_MAX];
        char output_prefix[PATH_MAX];
        char conv_err[256];
        if (!bo3_workshop_physics_dir(physics_dir, sizeof(physics_dir)) ||
            snprintf(output_prefix, sizeof(output_prefix), "%s/%s", physics_dir, mapname) >= (int)sizeof(output_prefix)) {
            bo3_call_com_error(ctx, rsp, __LINE__, "^7[^6bo3mac^7] Navigation cache path is too long.");
            return ret_void();
        }

        if (!bo3_nav_cache_valid(output_prefix, mesh, volume)) {
            if (!bo3_mkdir_p_physics(physics_dir)) {
                char err_msg[512];
                snprintf(err_msg, sizeof(err_msg),
                         "^7[^6bo3mac^7] Could not create navigation cache: %s", strerror(errno));
                bo3_call_com_error(ctx, rsp, __LINE__, err_msg);
                return ret_void();
            }
            fprintf(stderr, "[workshop] Converting Havok navigation data for '%s' (native ARM64)...\n", mapname);
            fflush(stderr);
            if (!bo3_convert_nav(mesh, volume, output_prefix, conv_err, sizeof(conv_err))) {
                fprintf(stderr, "[workshop] Havok nav conversion failed for '%s': %s\n", mapname, conv_err);
                fflush(stderr);
                char err_msg[512];
                snprintf(err_msg, sizeof(err_msg),
                         "^7[^6bo3mac^7] Native navigation conversion failed for '^2%s^7': %s", mapname, conv_err);
                bo3_call_com_error(ctx, rsp, __LINE__, err_msg);
                return ret_void();
            }
            fprintf(stderr, "[workshop] Native Havok navigation conversion complete for '%s'\n", mapname);
            fflush(stderr);
        }
    }

    return orig_g_100e09aa9(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9,
                            xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7);
}

// 0x101345b12: DB_FindXAssetHeader(int type, char *name, bool errorIfMissing, int waitTime)
SHIM_DEF(g_101345b12) {
    GuestRet ret = orig_g_101345b12(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9,
                                    xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7);
    if ((int32_t)rdi == 54 && ret.rax_rdx[0] != 0) {
        static pthread_mutex_t s_script_fix_mtx = PTHREAD_MUTEX_INITIALIZER;
        static int s_warned = 0;
        Bo3ScriptParseTree *script = (Bo3ScriptParseTree *)(uintptr_t)ret.rax_rdx[0];
        pthread_mutex_lock(&s_script_fix_mtx);
        int res = fix_roulette_callbacks(script->name, script->buffer,
                                         script->length > 0 ? (size_t)script->length : 0);
        if (res > 0) {
            fprintf(stderr, "[workshop] Patched One Barrier Roulette V2 optional event-flag checks\n");
            fflush(stderr);
        } else if (res < 0 && !s_warned) {
            fprintf(stderr, "[workshop] Roulette script revision unrecognized; callback fix skipped\n");
            fflush(stderr);
            s_warned = 1;
        }
        pthread_mutex_unlock(&s_script_fix_mtx);
    }
    return ret;
}

// 0x100f16d9a: Com_GetBuildIntField(int field)
SHIM_DEF(g_100f16d9a) {
    if ((uint32_t)rdi == 0x4D616321u) {
        SHIM_UNUSED_ALL();
        return ret_u64(0x00000102ULL);
    }
    return orig_g_100f16d9a(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9,
                            xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7);
}

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include "settings_mac.h"
#include "window_mac.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <mutex>
#include <string>

// =========================================================================
// Persistent Settings Store + Apple Silicon Tier Auto-Tuner
// =========================================================================

// Live runtime atomics (may include session-only CLI/env overrides).
static std::atomic<bool>     g_metalfx{true};
static std::atomic<uint32_t> g_render_scale{100};
static std::atomic<uint32_t> g_startup_render_scale{100};
static std::atomic<bool>     g_startup_scale_frozen{false};
static std::atomic<bool>     g_lossy_supported{false};
static std::atomic<bool>     g_lossy_rt{false};
static std::atomic<uint32_t> g_max_frame_latency{2}; // 0 = game default, 1..3 = override
static std::atomic<uint32_t> g_hud_mode{0};          // 0 = Off, 1 = FPS, 2 = Detailed
static std::atomic<bool>     g_friends_only{true};
static std::atomic<bool>     g_offline_mode{false};

// Persisted values (never polluted by one-shot session CLI/env overrides unless edited in UI).
struct Bo3PersistedValues {
    bool     metalfx = true;
    uint32_t render_scale = 100;
    bool     lossy_rt = false;
    uint32_t max_frame_latency = 2;
    uint32_t hud_mode = 0;
    bool     friends_only = true;
    bool     offline = false;
};

[[clang::no_destroy]] static std::mutex         g_cfg_mtx;
static std::atomic<bool>                        g_loaded_early_fast{false};
static bool                                     g_loaded_early = false;
static bool                                     g_device_inited = false;
static bool                                     g_had_graphics_keys = false;
static bool                                     g_metalfx_supported = true;
static Bo3PersistedValues                       g_persisted;
[[clang::no_destroy]] static std::string        g_gpu_name = "Apple Silicon";
[[clang::no_destroy]] static std::string        g_profile_label = "Apple Silicon";
[[clang::no_destroy]] static std::string        g_settings_dir;
[[clang::no_destroy]] static std::string        g_settings_path;
static int32_t                                  g_phys_w = 1920, g_phys_h = 1080;

struct Bo3RecommendedProfile {
    bool        metalfx;
    uint32_t    render_scale;
    bool        lossy_rt;
    uint32_t    max_frame_latency;
    std::string label;
};

// Match exact Apple Silicon generation token (e.g. "M1" won't match "M10").
static bool gpu_has_apple_gen(const std::string &gpu, int gen) {
    std::string tok = "M" + std::to_string(gen);
    size_t pos = 0;
    while ((pos = gpu.find(tok, pos)) != std::string::npos) {
        bool left_ok = (pos == 0 || !isalnum((unsigned char)gpu[pos - 1]));
        size_t end = pos + tok.size();
        bool right_ok = (end == gpu.size() || !isdigit((unsigned char)gpu[end]));
        if (left_ok && right_ok) return true;
        pos = end;
    }
    return false;
}

static Bo3RecommendedProfile compute_recommended_profile(const std::string &gpu, bool apple8_plus,
                                                         bool metalfx_ok, int32_t phys_w, int32_t phys_h) {
    Bo3RecommendedProfile p = {};
    p.metalfx = metalfx_ok;
    p.max_frame_latency = 2;

    const bool is_ultra = (gpu.find("Ultra") != std::string::npos);
    const bool is_max   = (gpu.find("Max") != std::string::npos);
    const bool is_pro   = (gpu.find("Pro") != std::string::npos);
    const bool is_m1    = gpu_has_apple_gen(gpu, 1);
    const bool is_m2    = gpu_has_apple_gen(gpu, 2);
    const bool is_m3    = gpu_has_apple_gen(gpu, 3);
    const bool is_m4    = gpu_has_apple_gen(gpu, 4);
    const bool is_hi_res = (phys_w > 2560 || phys_h > 1440);
    const bool is_1440p  = (phys_w > 1920 || phys_h > 1080);

    if (is_ultra || is_max) {
        p.render_scale = 100;
        p.lossy_rt = false;
        p.label = gpu + " (Native Lossless)";
    } else if (is_pro) {
        p.render_scale = (metalfx_ok && is_hi_res) ? 85u : 100u;
        p.lossy_rt = apple8_plus;
        p.label = gpu + (p.render_scale < 100 ? " (MetalFX 85%)" : " (Native)");
    } else if (is_m1) {
        p.render_scale = metalfx_ok ? (is_1440p ? 67u : 75u) : 100u;
        p.lossy_rt = false;
        p.label = gpu + (p.render_scale < 100 ? (" (MetalFX " + std::to_string(p.render_scale) + "%)") : " (Native)");
    } else if (is_m2 || is_m3 || is_m4) {
        p.render_scale = metalfx_ok ? (is_hi_res ? 70u : (is_1440p ? 75u : 80u)) : 100u;
        p.lossy_rt = apple8_plus;
        p.label = gpu + (p.render_scale < 100
            ? (" (MetalFX " + std::to_string(p.render_scale) + "% + Lossy RT)")
            : " (Native + Lossy RT)");
    } else {
        // Future Apple Silicon (M5 / M6+ base)
        p.render_scale = (metalfx_ok && is_hi_res) ? 85u : 100u;
        p.lossy_rt = apple8_plus;
        p.label = gpu + (p.render_scale < 100 ? " (MetalFX 85%)" : " (Native)");
    }
    return p;
}

static bool parse_u32_strict(const char *s, uint32_t *out) {
    if (!s || !s[0]) return false;
    for (const char *p = s; *p; p++) {
        if (*p < '0' || *p > '9') return false;
    }
    char *end = nullptr;
    errno = 0;
    unsigned long v = strtoul(s, &end, 10);
    if (errno != 0 || end == s || *end != '\0' || v > 1000000UL) return false;
    *out = (uint32_t)v;
    return true;
}

static std::string resolve_home_dir() {
    const char *home = getenv("HOME");
    if (home && home[0]) return std::string(home);
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir && pw->pw_dir[0]) return std::string(pw->pw_dir);
    return std::string();
}

static void ensure_settings_paths_locked() {
    if (!g_settings_path.empty()) return;
    std::string home = resolve_home_dir();
    if (home.empty()) return;
    std::string lib = home + "/Library";
    mkdir(lib.c_str(), 0755);
    std::string base = lib + "/Application Support";
    mkdir(base.c_str(), 0755);
    g_settings_dir = base + "/bo3mac";
    mkdir(g_settings_dir.c_str(), 0755);
    g_settings_path = g_settings_dir + "/settings.ini";
}

// Read settings.ini into `vals` (overlaying only keys present on disk).
// Returns true iff at least one graphics tuning key was present in the file.
static bool read_settings_file_into(const std::string &path, Bo3PersistedValues *vals,
                                    std::string *out_game_dir, std::string *out_cache_dir) {
    if (path.empty()) return false;
    FILE *fp = fopen(path.c_str(), "r");
    if (!fp) return false;
    bool saw_gfx_key = false;
    char line[2048];
    while (fgets(line, sizeof(line), fp)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '#' || *p == '\n' || *p == '\r') continue;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = '\0';
        char *val = eq + 1;
        char *ke = eq;
        while (ke > p && (ke[-1] == ' ' || ke[-1] == '\t')) *--ke = '\0';
        while (*val == ' ' || *val == '\t') val++;
        size_t vl = strlen(val);
        while (vl > 0 && (val[vl - 1] == '\n' || val[vl - 1] == '\r' || val[vl - 1] == ' ' || val[vl - 1] == '\t')) {
            val[--vl] = '\0';
        }
        if (strcmp(p, "game_dir") == 0) {
            if (out_game_dir) *out_game_dir = val;
            continue;
        }
        if (strcmp(p, "cache_dir") == 0) {
            if (out_cache_dir) *out_cache_dir = val;
            continue;
        }
        uint32_t num = 0;
        if (!parse_u32_strict(val, &num)) continue;
        if (strcmp(p, "metalfx") == 0) {
            if (vals) vals->metalfx = (num != 0);
            saw_gfx_key = true;
        } else if (strcmp(p, "render_scale") == 0 && num >= 50 && num <= 100) {
            if (vals) vals->render_scale = num;
            saw_gfx_key = true;
        } else if (strcmp(p, "lossy_rt") == 0) {
            if (vals) vals->lossy_rt = (num != 0);
            saw_gfx_key = true;
        } else if (strcmp(p, "max_frame_latency") == 0 && num <= 3) {
            if (vals) vals->max_frame_latency = num;
            saw_gfx_key = true;
        } else if (strcmp(p, "hud_mode") == 0 && num <= 2) {
            if (vals) vals->hud_mode = num;
        } else if (strcmp(p, "friends_only") == 0) {
            if (vals) vals->friends_only = (num != 0);
        } else if (strcmp(p, "offline") == 0) {
            if (vals) vals->offline = (num != 0);
        }
    }
    fclose(fp);
    return saw_gfx_key;
}

static void push_persisted_to_live_locked() {
    g_metalfx.store(g_persisted.metalfx && g_metalfx_supported, std::memory_order_release);
    g_render_scale.store(g_persisted.render_scale, std::memory_order_release);
    g_lossy_rt.store(g_persisted.lossy_rt && g_lossy_supported.load(std::memory_order_acquire), std::memory_order_release);
    g_max_frame_latency.store(g_persisted.max_frame_latency, std::memory_order_release);
    g_hud_mode.store(g_persisted.hud_mode, std::memory_order_release);
    g_friends_only.store(g_persisted.friends_only, std::memory_order_release);
    g_offline_mode.store(g_persisted.offline, std::memory_order_release);
}

static void apply_env_overrides_locked() {
    if (const char *e = getenv("BO3ARM_METALFX")) {
        if (e[0]) g_metalfx.store(strcmp(e, "0") != 0 && g_metalfx_supported, std::memory_order_release);
    }
    if (const char *e = getenv("BO3ARM_RENDER_SCALE")) {
        uint32_t v = 0;
        if (parse_u32_strict(e, &v) && v >= 50 && v <= 100) {
            g_render_scale.store(v, std::memory_order_release);
        } else if (e[0]) {
            fprintf(stderr, "[metalfx] BO3ARM_RENDER_SCALE=%s ignored (valid: 50..100)\n", e);
            fflush(stderr);
        }
    }
    if (const char *e = getenv("BO3ARM_LOSSY_RT")) {
        if (e[0]) {
            g_lossy_rt.store(strcmp(e, "0") != 0 && g_lossy_supported.load(std::memory_order_acquire),
                             std::memory_order_release);
        }
    }
    if (const char *e = getenv("BO3ARM_MAX_FRAME_LATENCY")) {
        uint32_t v = 0;
        if (parse_u32_strict(e, &v) && v <= 3) {
            g_max_frame_latency.store(v, std::memory_order_release);
        } else if (e[0]) {
            fprintf(stderr, "[metal-dxgi] BO3ARM_MAX_FRAME_LATENCY=%s ignored (valid: 0..3)\n", e);
            fflush(stderr);
        }
    }
    if (const char *e = getenv("BO3ARM_HUD")) {
        uint32_t v = 0;
        if (parse_u32_strict(e, &v) && v <= 2) {
            g_hud_mode.store(v, std::memory_order_release);
        }
    }
    if (const char *e = getenv("BO3ARM_FRIENDS_ONLY")) {
        if (e[0]) g_friends_only.store(strcmp(e, "0") != 0, std::memory_order_release);
    }
    if (const char *e = getenv("BO3ARM_OFFLINE")) {
        if (e[0]) g_offline_mode.store(strcmp(e, "0") != 0, std::memory_order_release);
    }
}

// Locked atomic read-modify-write preserving any newer game_dir / cache_dir written by install.sh or BO3 Mac.app.
static void save_settings_file_locked() {
    ensure_settings_paths_locked();
    if (g_settings_path.empty()) return;

    std::string lock_path = g_settings_dir + "/.settings.lock";
    int lfd = open(lock_path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (lfd >= 0) flock(lfd, LOCK_EX);

    std::string latest_game_dir, latest_cache_dir;
    read_settings_file_into(g_settings_path, nullptr, &latest_game_dir, &latest_cache_dir);

    std::string tmp = g_settings_path + ".tmp." + std::to_string((long)getpid());
    unlink(tmp.c_str());
    int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd >= 0) {
        FILE *fp = fdopen(fd, "w");
        if (fp) {
            fprintf(fp, "# bo3mac settings (editable live in-game via F10 / Cmd+, or BO3 Mac.app)\n");
            fprintf(fp, "metalfx=%u\n", g_persisted.metalfx ? 1u : 0u);
            fprintf(fp, "render_scale=%u\n", g_persisted.render_scale);
            fprintf(fp, "lossy_rt=%u\n", g_persisted.lossy_rt ? 1u : 0u);
            fprintf(fp, "max_frame_latency=%u\n", g_persisted.max_frame_latency);
            fprintf(fp, "hud_mode=%u\n", g_persisted.hud_mode);
            fprintf(fp, "friends_only=%u\n", g_persisted.friends_only ? 1u : 0u);
            fprintf(fp, "offline=%u\n", g_persisted.offline ? 1u : 0u);
            if (!latest_game_dir.empty())  fprintf(fp, "game_dir=%s\n", latest_game_dir.c_str());
            if (!latest_cache_dir.empty()) fprintf(fp, "cache_dir=%s\n", latest_cache_dir.c_str());
            bool ok = (ferror(fp) == 0 && fflush(fp) == 0);
            if (ok) fsync(fileno(fp));
            if (fclose(fp) != 0) ok = false;
            if (!ok || rename(tmp.c_str(), g_settings_path.c_str()) != 0) {
                unlink(tmp.c_str());
            }
        } else {
            close(fd);
            unlink(tmp.c_str());
        }
    }
    if (lfd >= 0) {
        flock(lfd, LOCK_UN);
        close(lfd);
    }
}

void bo3_settings_load_early(void) {
    if (g_loaded_early_fast.load(std::memory_order_acquire)) return;
    int32_t pw = 0, ph = 0;
    bo3_win_get_physical_screen_size(&pw, &ph);
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    if (g_loaded_early) return;
    if (pw > 0 && ph > 0) { g_phys_w = pw; g_phys_h = ph; }
    g_loaded_early = true;

    // Step 1: Probe Metal capabilities and compute hardware-tuned baseline defaults first.
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (dev) {
            g_gpu_name = dev.name ? dev.name.UTF8String : "Apple Silicon";
            bool a8 = [dev supportsFamily:MTLGPUFamilyApple8];
            g_lossy_supported.store(a8, std::memory_order_release);
            g_metalfx_supported = [MTLFXSpatialScalerDescriptor supportsDevice:dev];
            auto rec = compute_recommended_profile(g_gpu_name, a8, g_metalfx_supported, g_phys_w, g_phys_h);
            g_profile_label = rec.label;
            g_persisted.metalfx = rec.metalfx;
            g_persisted.render_scale = rec.render_scale;
            g_persisted.lossy_rt = rec.lossy_rt;
            g_persisted.max_frame_latency = rec.max_frame_latency;
        }
    }

    // Step 2: Overlay any saved keys from settings.ini (paths-only file from install.sh keeps auto-tuned defaults!).
    ensure_settings_paths_locked();
    g_had_graphics_keys = read_settings_file_into(g_settings_path, &g_persisted, nullptr, nullptr);
    if (!g_lossy_supported.load(std::memory_order_acquire)) g_persisted.lossy_rt = false;
    if (!g_metalfx_supported) g_persisted.metalfx = false;

    // Step 3: Publish persisted settings to live atomics, then overlay session-only env vars.
    push_persisted_to_live_locked();
    apply_env_overrides_locked();
    g_loaded_early_fast.store(true, std::memory_order_release);
}

void bo3_settings_init_for_device(const char *gpu_name, bool apple8_plus, int32_t phys_w, int32_t phys_h) {
    bo3_settings_load_early();
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    if (g_device_inited) return;
    g_device_inited = true;
    if (gpu_name && gpu_name[0]) g_gpu_name = gpu_name;
    g_lossy_supported.store(apple8_plus, std::memory_order_release);
    if (phys_w > 0 && phys_h > 0) { g_phys_w = phys_w; g_phys_h = phys_h; }

    auto rec = compute_recommended_profile(g_gpu_name, apple8_plus, g_metalfx_supported, g_phys_w, g_phys_h);
    g_profile_label = rec.label;
    if (!g_had_graphics_keys) {
        g_persisted.metalfx = rec.metalfx;
        g_persisted.render_scale = rec.render_scale;
        g_persisted.lossy_rt = rec.lossy_rt;
        g_persisted.max_frame_latency = rec.max_frame_latency;
        // Persist clean recommended baseline (without session-only CLI env overrides!)
        save_settings_file_locked();
        g_had_graphics_keys = true;
        push_persisted_to_live_locked();
        apply_env_overrides_locked();
    }
    if (!apple8_plus) {
        g_persisted.lossy_rt = false;
        g_lossy_rt.store(false, std::memory_order_release);
    }
    fprintf(stderr, "[bo3mac] Profile: %s | metalfx=%d scale=%u%% lossy_rt=%d latency=%u hud=%u friends_only=%d\n",
            g_profile_label.c_str(),
            g_metalfx.load(std::memory_order_relaxed) ? 1 : 0,
            g_render_scale.load(std::memory_order_relaxed),
            g_lossy_rt.load(std::memory_order_relaxed) ? 1 : 0,
            g_max_frame_latency.load(std::memory_order_relaxed),
            g_hud_mode.load(std::memory_order_relaxed),
            g_friends_only.load(std::memory_order_relaxed) ? 1 : 0);
    fflush(stderr);
}

void bo3_settings_save(void) {
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    save_settings_file_locked();
}

void bo3_settings_reset_recommended(void) {
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    bool a8 = g_lossy_supported.load(std::memory_order_acquire);
    auto rec = compute_recommended_profile(g_gpu_name, a8, g_metalfx_supported, g_phys_w, g_phys_h);
    g_profile_label = rec.label;
    g_persisted.metalfx = rec.metalfx;
    g_persisted.render_scale = rec.render_scale;
    g_persisted.lossy_rt = rec.lossy_rt;
    g_persisted.max_frame_latency = rec.max_frame_latency;
    g_persisted.hud_mode = 0;
    g_persisted.friends_only = true;
    // Preserve session-only offline override so Reset Recommended never opens networking mid-session
    bool was_offline = g_offline_mode.load(std::memory_order_acquire);
    push_persisted_to_live_locked();
    if (was_offline) g_offline_mode.store(true, std::memory_order_release);
    save_settings_file_locked();
}

bool bo3_settings_metalfx_enabled(void) {
    bo3_settings_load_early();
    return g_metalfx.load(std::memory_order_acquire);
}
void bo3_settings_set_metalfx(bool on) {
    bo3_settings_load_early();
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    bool eff = on && g_metalfx_supported;
    g_persisted.metalfx = eff;
    g_metalfx.store(eff, std::memory_order_release);
}

uint32_t bo3_settings_render_scale(void) {
    bo3_settings_load_early();
    return g_render_scale.load(std::memory_order_acquire);
}
uint32_t bo3_settings_startup_render_scale(void) {
    bo3_settings_load_early();
    if (!g_startup_scale_frozen.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lk(g_cfg_mtx);
        if (!g_startup_scale_frozen.load(std::memory_order_relaxed)) {
            uint32_t sc = (g_metalfx_supported && g_metalfx.load(std::memory_order_acquire))
                          ? g_render_scale.load(std::memory_order_acquire) : 100u;
            g_startup_render_scale.store(sc, std::memory_order_release);
            g_startup_scale_frozen.store(true, std::memory_order_release);
        }
    }
    return g_startup_render_scale.load(std::memory_order_acquire);
}
void bo3_settings_set_render_scale(uint32_t pct) {
    bo3_settings_load_early();
    uint32_t clamped = std::clamp(pct, 50u, 100u);
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    g_persisted.render_scale = clamped;
    g_render_scale.store(clamped, std::memory_order_release);
}

bool bo3_settings_lossy_rt_supported(void) {
    bo3_settings_load_early();
    return g_lossy_supported.load(std::memory_order_acquire);
}
bool bo3_settings_lossy_rt_enabled(void) {
    bo3_settings_load_early();
    return g_lossy_supported.load(std::memory_order_acquire) && g_lossy_rt.load(std::memory_order_acquire);
}
void bo3_settings_set_lossy_rt(bool on) {
    bo3_settings_load_early();
    bool eff = on && g_lossy_supported.load(std::memory_order_acquire);
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    g_persisted.lossy_rt = eff;
    g_lossy_rt.store(eff, std::memory_order_release);
}

uint32_t bo3_settings_max_frame_latency(void) {
    bo3_settings_load_early();
    return g_max_frame_latency.load(std::memory_order_acquire);
}
void bo3_settings_set_max_frame_latency(uint32_t lat) {
    bo3_settings_load_early();
    uint32_t clamped = std::min(lat, 3u);
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    g_persisted.max_frame_latency = clamped;
    g_max_frame_latency.store(clamped, std::memory_order_release);
}

uint32_t bo3_settings_hud_mode(void) {
    bo3_settings_load_early();
    return g_hud_mode.load(std::memory_order_acquire);
}
void bo3_settings_set_hud_mode(uint32_t mode) {
    bo3_settings_load_early();
    uint32_t clamped = std::min(mode, 2u);
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    g_persisted.hud_mode = clamped;
    g_hud_mode.store(clamped, std::memory_order_release);
}

bool bo3_settings_friends_only(void) {
    bo3_settings_load_early();
    return g_friends_only.load(std::memory_order_acquire);
}
void bo3_settings_set_friends_only(bool on) {
    bo3_settings_load_early();
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    g_persisted.friends_only = on;
    g_friends_only.store(on, std::memory_order_release);
}

bool bo3_settings_offline_mode(void) {
    bo3_settings_load_early();
    return g_offline_mode.load(std::memory_order_acquire);
}
void bo3_settings_set_offline_mode(bool on) {
    bo3_settings_load_early();
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    g_persisted.offline = on;
    g_offline_mode.store(on, std::memory_order_release);
}

void bo3_settings_copy_gpu_profile_label(char *buf, size_t cap) {
    if (!buf || cap == 0) return;
    bo3_settings_load_early();
    std::lock_guard<std::mutex> lk(g_cfg_mtx);
    strlcpy(buf, g_profile_label.c_str(), cap);
}

// =========================================================================
// Native Frosted-Glass In-Game Settings Overlay (F10 / Cmd+,) + Corner HUD
// =========================================================================

static std::atomic<bool> g_panel_open{false};
static void (*g_panel_vis_cb)(bool) = nullptr;

@interface Bo3SettingsPanel : NSPanel
@end
@implementation Bo3SettingsPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)cancelOperation:(id)sender {
    (void)sender;
    bo3_ui_close_settings_panel();
}
- (void)keyDown:(NSEvent *)event {
    // F10 (0x6D) or Cmd+, (0x2B) or Escape (0x35) closes the panel (ignore key repeat)
    if (event.keyCode == 0x6D || event.keyCode == 0x35 ||
        ((event.modifierFlags & NSEventModifierFlagCommand) && event.keyCode == 0x2B)) {
        if (!event.isARepeat) bo3_ui_close_settings_panel();
        return;
    }
    [super keyDown:event];
}
@end

@interface Bo3OverlayController : NSObject <NSWindowDelegate>
@property (nonatomic, weak)   NSWindow           *gameWindow;
@property (nonatomic, strong) Bo3SettingsPanel   *panel;
@property (nonatomic, strong) NSPanel            *hudWin;
@property (nonatomic, strong) NSTextField        *hudLabel;
@property (nonatomic, strong) NSSwitch           *metalfxSwitch;
@property (nonatomic, strong) NSSwitch           *lossySwitch;
@property (nonatomic, strong) NSSwitch           *friendsSwitch;
@property (nonatomic, strong) NSSegmentedControl *latencySeg;
@property (nonatomic, strong) NSSegmentedControl *hudSeg;
@property (nonatomic, strong) NSSlider           *scaleSlider;
@property (nonatomic, strong) NSTextField        *scaleValueLabel;
@property (nonatomic, strong) NSTextField        *profileLabel;
@property (nonatomic, strong) NSTextField        *lossyNote;
@end

static Bo3OverlayController *g_ui = nil;

@implementation Bo3OverlayController

- (void)ensureHudWindow {
    if (_hudWin) return;
    NSPanel *hw = [[NSPanel alloc] initWithContentRect:NSMakeRect(20, 20, 420, 28)
                                             styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    hw.releasedWhenClosed = NO;
    hw.opaque = NO;
    hw.backgroundColor = [NSColor clearColor];
    hw.hasShadow = NO;
    hw.ignoresMouseEvents = YES;
    hw.level = NSNormalWindowLevel;

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:hw.contentView.bounds];
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    bg.material = NSVisualEffectMaterialHUDWindow;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 7.0;
    bg.layer.masksToBounds = YES;
    bg.layer.borderWidth = 0.5;
    bg.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.18].CGColor;
    [hw.contentView addSubview:bg];

    NSTextField *lbl = [NSTextField labelWithString:@"BO3 Mac"];
    lbl.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightSemibold];
    lbl.textColor = [NSColor colorWithRed:0.96 green:0.97 blue:0.99 alpha:0.96];
    lbl.frame = NSMakeRect(10, 5, 400, 18);
    lbl.autoresizingMask = NSViewWidthSizable;
    [bg addSubview:lbl];

    _hudWin = hw;
    _hudLabel = lbl;
}

- (void)positionHud {
    if (!_hudWin || !_gameWindow) return;
    NSRect gf = _gameWindow.frame;
    CGFloat h = _hudWin.frame.size.height;
    CGFloat x = gf.origin.x + 14.0;
    CGFloat y = gf.origin.y + gf.size.height - h - (_gameWindow.styleMask == NSWindowStyleMaskBorderless ? 14.0 : 42.0);
    [_hudWin setFrameOrigin:NSMakePoint(x, y)];
}

- (void)refreshHudVisibility {
    uint32_t mode = bo3_settings_hud_mode();
    if (mode == 0 || !_gameWindow) {
        if (_hudWin) {
            if (_hudWin.parentWindow) [_hudWin.parentWindow removeChildWindow:_hudWin];
            [_hudWin orderOut:nil];
        }
        return;
    }
    [self ensureHudWindow];
    if (_hudWin.parentWindow != _gameWindow) {
        if (_hudWin.parentWindow) [_hudWin.parentWindow removeChildWindow:_hudWin];
        [_gameWindow addChildWindow:_hudWin ordered:NSWindowAbove];
    }
    [self positionHud];
    if ([NSApp isActive]) {
        [_hudWin orderFront:nil];
    }
}

- (NSTextField *)makeLabel:(NSString *)text font:(NSFont *)font color:(NSColor *)color frame:(NSRect)r {
    NSTextField *t = [NSTextField labelWithString:text];
    t.font = font;
    t.textColor = color;
    t.frame = r;
    return t;
}

- (void)ensurePanel {
    if (_panel) return;
    const CGFloat W = 490.0, H = 470.0;
    Bo3SettingsPanel *p = [[Bo3SettingsPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                                              styleMask:(NSWindowStyleMaskTitled |
                                                                         NSWindowStyleMaskClosable |
                                                                         NSWindowStyleMaskFullSizeContentView)
                                                                backing:NSBackingStoreBuffered
                                                                  defer:NO];
    p.releasedWhenClosed = NO;
    p.title = @"BO3 Mac — Apple Silicon Settings";
    p.titlebarAppearsTransparent = YES;
    p.movableByWindowBackground = YES;
    p.level = NSFloatingWindowLevel;
    p.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    p.delegate = self;

    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    root.material = NSVisualEffectMaterialHUDWindow;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    root.state = NSVisualEffectStateActive;
    p.contentView = root;

    NSFont *titleFont = [NSFont systemFontOfSize:17 weight:NSFontWeightBold];
    NSFont *labelFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSFont *subFont   = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    NSColor *hiColor  = [NSColor colorWithWhite:0.96 alpha:1.0];
    NSColor *dimColor = [NSColor colorWithWhite:0.72 alpha:1.0];

    CGFloat y = H - 52;
    [root addSubview:[self makeLabel:@"Apple Silicon Graphics & Performance" font:titleFont color:hiColor frame:NSMakeRect(24, y, W - 48, 24)]];
    y -= 20;
    _profileLabel = [self makeLabel:@"Detected: Apple Silicon" font:subFont color:dimColor frame:NSMakeRect(24, y, W - 48, 16)];
    [root addSubview:_profileLabel];

    // Row 1: MetalFX Spatial Upscaling (Live)
    y -= 44;
    [root addSubview:[self makeLabel:@"MetalFX Spatial Upscaling" font:labelFont color:hiColor frame:NSMakeRect(24, y + 6, 260, 18)]];
    [root addSubview:[self makeLabel:@"Live — Apple GPU upscaling when rendering below display size" font:subFont color:dimColor frame:NSMakeRect(24, y - 10, 360, 15)]];
    _metalfxSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(W - 68, y + 2, 44, 24)];
    _metalfxSwitch.target = self;
    _metalfxSwitch.action = @selector(onMetalfxChanged:);
    [root addSubview:_metalfxSwitch];

    // Row 2: Max Frame Latency (Live)
    y -= 54;
    [root addSubview:[self makeLabel:@"Max Frame Latency" font:labelFont color:hiColor frame:NSMakeRect(24, y + 8, 200, 18)]];
    [root addSubview:[self makeLabel:@"Live — 2 (Balanced) prevents stutter; 1 = lowest input lag" font:subFont color:dimColor frame:NSMakeRect(24, y - 8, 350, 15)]];
    _latencySeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Auto", @"1", @"2", @"3"]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:self
                                                          action:@selector(onLatencyChanged:)];
    _latencySeg.frame = NSMakeRect(W - 214, y + 4, 190, 24);
    [root addSubview:_latencySeg];

    // Row 3: Performance HUD (Live)
    y -= 54;
    [root addSubview:[self makeLabel:@"On-Screen Performance HUD" font:labelFont color:hiColor frame:NSMakeRect(24, y + 8, 220, 18)]];
    [root addSubview:[self makeLabel:@"Live — top-left FPS, GPU ms & MetalFX status" font:subFont color:dimColor frame:NSMakeRect(24, y - 8, 320, 15)]];
    _hudSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Off", @"FPS", @"Detailed"]
                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                      target:self
                                                      action:@selector(onHudChanged:)];
    _hudSeg.frame = NSMakeRect(W - 214, y + 4, 190, 24);
    [root addSubview:_hudSeg];

    // Row 4: Apple8+ Lossy RT Compression (Live on new RTs)
    y -= 54;
    [root addSubview:[self makeLabel:@"Lossy Render-Target Compression" font:labelFont color:hiColor frame:NSMakeRect(24, y + 6, 280, 18)]];
    _lossyNote = [self makeLabel:@"M2/M3/M4+ — cuts GPU bandwidth & heat (applies on map/res change)" font:subFont color:dimColor frame:NSMakeRect(24, y - 10, 380, 15)];
    [root addSubview:_lossyNote];
    _lossySwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(W - 68, y + 2, 44, 24)];
    _lossySwitch.target = self;
    _lossySwitch.action = @selector(onLossyChanged:);
    [root addSubview:_lossySwitch];

    // Row 5: Online Friends-Only Protection (Live)
    y -= 54;
    [root addSubview:[self makeLabel:@"Friends-Only Online Protection" font:labelFont color:hiColor frame:NSMakeRect(24, y + 6, 280, 18)]];
    [root addSubview:[self makeLabel:@"Live — blocks non-friend P2P/IM packets & keeps new lobbies Friends-Only" font:subFont color:dimColor frame:NSMakeRect(24, y - 10, 380, 15)]];
    _friendsSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(W - 68, y + 2, 44, 24)];
    _friendsSwitch.target = self;
    _friendsSwitch.action = @selector(onFriendsChanged:);
    [root addSubview:_friendsSwitch];

    // Row 6: Startup Virtual Render Scale slider
    y -= 58;
    [root addSubview:[self makeLabel:@"Startup MetalFX Scale" font:labelFont color:hiColor frame:NSMakeRect(24, y + 12, 220, 18)]];
    _scaleValueLabel = [self makeLabel:@"100%" font:[NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightBold]
                                 color:hiColor frame:NSMakeRect(W - 76, y + 12, 52, 18)];
    _scaleValueLabel.alignment = NSTextAlignmentRight;
    [root addSubview:_scaleValueLabel];
    _scaleSlider = [NSSlider sliderWithValue:100 minValue:50 maxValue:100 target:self action:@selector(onScaleChanged:)];
    _scaleSlider.frame = NSMakeRect(24, y - 10, W - 48, 22);
    _scaleSlider.numberOfTickMarks = 11;
    _scaleSlider.allowsTickMarkValuesOnly = NO;
    _scaleSlider.continuous = YES;
    [root addSubview:_scaleSlider];

    y -= 36;
    NSTextField *tip = [self makeLabel:@"Tip: For instant live scaling, pick 1536×864 / 1440×810 / 1600×900 in BO3's Graphics menu (with MetalFX On), or use BO3's Render Resolution slider to keep 2D menus razor-sharp."
                                  font:subFont color:dimColor frame:NSMakeRect(24, y, W - 48, 30)];
    tip.lineBreakMode = NSLineBreakByWordWrapping;
    tip.maximumNumberOfLines = 2;
    [root addSubview:tip];

    NSButton *resetBtn = [NSButton buttonWithTitle:@"Reset Recommended" target:self action:@selector(onReset:)];
    resetBtn.bezelStyle = NSBezelStyleRounded;
    resetBtn.frame = NSMakeRect(24, 16, 156, 30);
    [root addSubview:resetBtn];

    NSButton *doneBtn = [NSButton buttonWithTitle:@"Done (F10)" target:self action:@selector(onDone:)];
    doneBtn.bezelStyle = NSBezelStyleRounded;
    doneBtn.keyEquivalent = @"\r";
    doneBtn.frame = NSMakeRect(W - 134, 16, 110, 30);
    [root addSubview:doneBtn];

    _panel = p;
}

- (void)syncControlsFromSettings {
    if (!_panel) return;
    char pbuf[192];
    bo3_settings_copy_gpu_profile_label(pbuf, sizeof(pbuf));
    _profileLabel.stringValue = [NSString stringWithFormat:@"Detected: %s  •  Press F10 (fn+F10) or ⌘, anytime", pbuf];
    _metalfxSwitch.state = bo3_settings_metalfx_enabled() ? NSControlStateValueOn : NSControlStateValueOff;
    bool lossy_ok = bo3_settings_lossy_rt_supported();
    _lossySwitch.enabled = lossy_ok;
    _lossySwitch.state = bo3_settings_lossy_rt_enabled() ? NSControlStateValueOn : NSControlStateValueOff;
    if (!lossy_ok) {
        _lossyNote.stringValue = @"Requires Apple M2 or newer GPU (Apple8+)";
    }
    _friendsSwitch.state = bo3_settings_friends_only() ? NSControlStateValueOn : NSControlStateValueOff;
    _latencySeg.selectedSegment = (NSInteger)bo3_settings_max_frame_latency();
    _hudSeg.selectedSegment = (NSInteger)bo3_settings_hud_mode();
    uint32_t sc = bo3_settings_render_scale();
    _scaleSlider.doubleValue = (double)sc;
    uint32_t boot_sc = bo3_settings_startup_render_scale();
    _scaleValueLabel.stringValue = (sc == boot_sc)
        ? [NSString stringWithFormat:@"%u%%", sc]
        : [NSString stringWithFormat:@"%u%%*", sc];
}

- (void)onMetalfxChanged:(NSSwitch *)s {
    bo3_settings_set_metalfx(s.state == NSControlStateValueOn);
    bo3_settings_save();
}
- (void)onLatencyChanged:(NSSegmentedControl *)s {
    bo3_settings_set_max_frame_latency((uint32_t)s.selectedSegment);
    bo3_settings_save();
}
- (void)onHudChanged:(NSSegmentedControl *)s {
    bo3_settings_set_hud_mode((uint32_t)s.selectedSegment);
    bo3_settings_save();
    [self refreshHudVisibility];
}
- (void)onLossyChanged:(NSSwitch *)s {
    bo3_settings_set_lossy_rt(s.state == NSControlStateValueOn);
    bo3_settings_save();
}
- (void)onFriendsChanged:(NSSwitch *)s {
    bo3_settings_set_friends_only(s.state == NSControlStateValueOn);
    bo3_settings_save();
}
- (void)onScaleChanged:(NSSlider *)s {
    uint32_t pct = (uint32_t)llround(s.doubleValue);
    pct = std::clamp(pct, 50u, 100u);
    uint32_t boot_sc = bo3_settings_startup_render_scale();
    _scaleValueLabel.stringValue = (pct == boot_sc)
        ? [NSString stringWithFormat:@"%u%%", pct]
        : [NSString stringWithFormat:@"%u%%*", pct];
    NSEvent *cur = [NSApp currentEvent];
    // Avoid disk write spam while dragging; persist on mouse-up / keyboard step.
    if (!cur || cur.type != NSEventTypeLeftMouseDragged) {
        bo3_settings_set_render_scale(pct);
        bo3_settings_save();
    }
}
- (void)onReset:(id)sender {
    (void)sender;
    bo3_settings_reset_recommended();
    [self syncControlsFromSettings];
    [self refreshHudVisibility];
}
- (void)onDone:(id)sender {
    (void)sender;
    bo3_ui_close_settings_panel();
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    if (_panel && _panel.parentWindow) {
        [_panel.parentWindow removeChildWindow:_panel];
    }
    if (g_panel_open.exchange(false, std::memory_order_acq_rel)) {
        if (g_panel_vis_cb) g_panel_vis_cb(false);
        if (_gameWindow) [_gameWindow makeKeyAndOrderFront:nil];
    }
}
@end

static void ensure_ui_main_thread(void) {
    if (!g_ui) g_ui = [[Bo3OverlayController alloc] init];
}

void bo3_ui_set_panel_visibility_callback(void (*cb)(bool open)) {
    g_panel_vis_cb = cb;
}

void bo3_ui_attach_game_window(void *ns_window_ptr) {
    NSWindow *w = (__bridge NSWindow *)ns_window_ptr;
    auto work = ^{
        ensure_ui_main_thread();
        g_ui.gameWindow = w;
        [g_ui refreshHudVisibility];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

void bo3_ui_sync_layout(void) {
    auto work = ^{
        if (!g_ui) return;
        [g_ui positionHud];
        if (g_panel_open.load(std::memory_order_acquire) && g_ui.panel && g_ui.gameWindow) {
            NSRect gf = g_ui.gameWindow.frame;
            NSRect pf = g_ui.panel.frame;
            [g_ui.panel setFrameOrigin:NSMakePoint(gf.origin.x + floor((gf.size.width - pf.size.width) * 0.5),
                                                   gf.origin.y + floor((gf.size.height - pf.size.height) * 0.5))];
        }
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

void bo3_ui_toggle_settings_panel(void) {
    auto work = ^{
        if (g_panel_open.load(std::memory_order_acquire)) {
            bo3_ui_close_settings_panel();
            return;
        }
        ensure_ui_main_thread();
        [g_ui ensurePanel];
        [g_ui syncControlsFromSettings];
        if (g_ui.gameWindow) {
            if (g_ui.panel.parentWindow != g_ui.gameWindow) {
                [g_ui.gameWindow addChildWindow:g_ui.panel ordered:NSWindowAbove];
            }
            NSRect gf = g_ui.gameWindow.frame;
            NSRect pf = g_ui.panel.frame;
            [g_ui.panel setFrameOrigin:NSMakePoint(gf.origin.x + floor((gf.size.width - pf.size.width) * 0.5),
                                                   gf.origin.y + floor((gf.size.height - pf.size.height) * 0.5))];
        } else {
            [g_ui.panel center];
        }
        g_panel_open.store(true, std::memory_order_release);
        if (g_panel_vis_cb) g_panel_vis_cb(true);
        [g_ui.panel makeKeyAndOrderFront:nil];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

void bo3_ui_close_settings_panel(void) {
    auto work = ^{
        if (!g_ui || !g_ui.panel) {
            g_panel_open.store(false, std::memory_order_release);
            return;
        }
        if (g_ui.panel.parentWindow) {
            [g_ui.panel.parentWindow removeChildWindow:g_ui.panel];
        }
        [g_ui.panel orderOut:nil];
        if (g_panel_open.exchange(false, std::memory_order_acq_rel)) {
            if (g_panel_vis_cb) g_panel_vis_cb(false);
        }
        if (g_ui.gameWindow) [g_ui.gameWindow makeKeyAndOrderFront:nil];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

bool bo3_ui_settings_panel_open(void) {
    return g_panel_open.load(std::memory_order_acquire);
}

void bo3_ui_update_hud_stats(double fps, double gpu_ms, double cpu_ms,
                             uint32_t render_w, uint32_t render_h,
                             uint32_t draw_w, uint32_t draw_h,
                             bool metalfx_active, bool lossy_rt_active,
                             double load_mb, double store_mb) {
    const uint32_t mode = bo3_settings_hud_mode();
    if (mode == 0) return;
    char buf[256];
    if (mode == 1) {
        if (metalfx_active) {
            snprintf(buf, sizeof(buf), "%.0f FPS  •  %ux%u → %ux%u MetalFX",
                     fps, render_w, render_h, draw_w, draw_h);
        } else {
            snprintf(buf, sizeof(buf), "%.0f FPS  •  %ux%u Native", fps, render_w, render_h);
        }
    } else {
        snprintf(buf, sizeof(buf), "%.0f FPS | GPU %.1fms CPU %.1fms | %ux%u%s | TBDR %.0f/%.0fMB%s",
                 fps, gpu_ms, cpu_ms, render_w, render_h,
                 metalfx_active ? "→MetalFX" : "",
                 load_mb, store_mb,
                 lossy_rt_active ? " [Lossy pref]" : "");
    }
    NSString *text = [NSString stringWithUTF8String:buf];
    dispatch_async(dispatch_get_main_queue(), ^{
        ensure_ui_main_thread();
        if (bo3_settings_hud_mode() == 0 || !g_ui.gameWindow) {
            if (g_ui.hudWin) [g_ui.hudWin orderOut:nil];
            return;
        }
        [g_ui ensureHudWindow];
        g_ui.hudLabel.stringValue = text;
        NSSize sz = [text sizeWithAttributes:@{NSFontAttributeName: g_ui.hudLabel.font}];
        CGFloat needW = std::clamp((double)ceil(sz.width) + 22.0, 140.0, 680.0);
        NSRect f = g_ui.hudWin.frame;
        if (fabs(f.size.width - needW) > 6.0) {
            f.size.width = needW;
            [g_ui.hudWin setFrame:f display:NO];
        }
        [g_ui refreshHudVisibility];
    });
}

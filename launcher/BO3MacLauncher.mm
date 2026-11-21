#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
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
#include <string>
#include <vector>

// =========================================================================
// BO3 Mac.app — Native Apple Silicon GUI Launcher
// Reads/writes the exact same ~/Library/Application Support/bo3mac/settings.ini
// as the in-game F10 / Cmd+, settings overlay, auto-tunes for M1-M6+ (Base/Pro/Max/Ultra),
// locates Steam BO3 + libbo3_recomp.dylib, and launches bo3_loader with zero dev overhead.
// =========================================================================

struct LauncherConfig {
    bool        metalfx = true;
    uint32_t    render_scale = 100;
    bool        lossy_rt = false;
    uint32_t    max_frame_latency = 2;
    uint32_t    hud_mode = 0;
    bool        friends_only = true;
    bool        offline = false;
    std::string game_dir;
    std::string cache_dir;
};

struct HardwareInfo {
    std::string gpu_name = "Apple Silicon";
    std::string profile_label = "Apple Silicon";
    bool        apple8_plus = false;
    bool        metalfx_supported = true;
    int32_t     phys_w = 1920;
    int32_t     phys_h = 1080;
    bool        rec_metalfx = true;
    uint32_t    rec_scale = 100;
    bool        rec_lossy = false;
    uint32_t    rec_latency = 2;
};

static std::string home_dir() {
    const char *h = getenv("HOME");
    if (h && h[0]) return std::string(h);
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir && pw->pw_dir[0]) return std::string(pw->pw_dir);
    return std::string("/tmp");
}

static std::string settings_dir_path() {
    std::string lib = home_dir() + "/Library";
    mkdir(lib.c_str(), 0755);
    std::string base = lib + "/Application Support";
    mkdir(base.c_str(), 0755);
    std::string dir = base + "/bo3mac";
    mkdir(dir.c_str(), 0755);
    return dir;
}

static std::string settings_file_path() {
    return settings_dir_path() + "/settings.ini";
}

static std::string log_file_path() {
    std::string lib = home_dir() + "/Library";
    mkdir(lib.c_str(), 0755);
    std::string dir = lib + "/Logs";
    mkdir(dir.c_str(), 0755);
    return dir + "/bo3mac.log";
}

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

static bool file_exists(const std::string &p) {
    struct stat st;
    return !p.empty() && stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

static bool is_valid_bo3_dir(const std::string &dir) {
    if (dir.empty()) return false;
    return file_exists(dir + "/CoDBlkOps3.app/Contents/MacOS/CoDBlkOps3_Exe");
}

static HardwareInfo probe_hardware() {
    HardwareInfo hw;
    NSScreen *scr = [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
    if (scr) {
        hw.phys_w = std::max<int32_t>(800, (int32_t)scr.frame.size.width);
        hw.phys_h = std::max<int32_t>(600, (int32_t)scr.frame.size.height);
    }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev) {
        hw.gpu_name = dev.name ? dev.name.UTF8String : "Apple Silicon";
        hw.apple8_plus = [dev supportsFamily:MTLGPUFamilyApple8];
        hw.metalfx_supported = [MTLFXSpatialScalerDescriptor supportsDevice:dev];
    }

    const std::string &gpu = hw.gpu_name;
    const bool is_ultra = (gpu.find("Ultra") != std::string::npos);
    const bool is_max   = (gpu.find("Max") != std::string::npos);
    const bool is_pro   = (gpu.find("Pro") != std::string::npos);
    const bool is_m1    = gpu_has_apple_gen(gpu, 1);
    const bool is_m2    = gpu_has_apple_gen(gpu, 2);
    const bool is_m3    = gpu_has_apple_gen(gpu, 3);
    const bool is_m4    = gpu_has_apple_gen(gpu, 4);
    const bool is_hi_res = (hw.phys_w > 2560 || hw.phys_h > 1440);
    const bool is_1440p  = (hw.phys_w > 1920 || hw.phys_h > 1080);

    hw.rec_metalfx = hw.metalfx_supported;
    hw.rec_latency = 2;
    if (is_ultra || is_max) {
        hw.rec_scale = 100;
        hw.rec_lossy = false;
        hw.profile_label = gpu + " — Native Lossless";
    } else if (is_pro) {
        hw.rec_scale = is_hi_res ? 85u : 100u;
        hw.rec_lossy = hw.apple8_plus;
        hw.profile_label = gpu + (hw.rec_scale < 100 ? " — MetalFX 85%" : " — Native");
    } else if (is_m1) {
        hw.rec_scale = is_1440p ? 67u : 75u;
        hw.rec_lossy = false;
        hw.profile_label = gpu + " — MetalFX " + std::to_string(hw.rec_scale) + "%";
    } else if (is_m2 || is_m3 || is_m4) {
        hw.rec_scale = is_hi_res ? 70u : (is_1440p ? 75u : 80u);
        hw.rec_lossy = hw.apple8_plus;
        hw.profile_label = gpu + " — MetalFX " + std::to_string(hw.rec_scale) + "% + Lossy RT";
    } else {
        hw.rec_scale = is_hi_res ? 85u : 100u;
        hw.rec_lossy = hw.apple8_plus;
        hw.profile_label = gpu + (hw.rec_scale < 100 ? " — MetalFX 85%" : " — Native");
    }
    if (!hw.metalfx_supported) hw.rec_scale = 100;
    return hw;
}

static std::vector<std::string> parse_steam_libraries(const std::string &vdf_path) {
    std::vector<std::string> libs;
    FILE *fp = fopen(vdf_path.c_str(), "r");
    if (!fp) return libs;
    char line[1024];
    while (fgets(line, sizeof(line), fp)) {
        const char *key = strstr(line, "\"path\"");
        if (!key) continue;
        const char *q1 = strchr(key + 6, '"');
        if (!q1) continue;
        const char *q2 = strchr(q1 + 1, '"');
        if (!q2 || q2 <= q1 + 1) continue;
        std::string raw(q1 + 1, (size_t)(q2 - q1 - 1));
        // Unescape double backslashes if any
        std::string clean;
        for (size_t i = 0; i < raw.size(); i++) {
            if (raw[i] == '\\' && i + 1 < raw.size() && raw[i + 1] == '\\') {
                clean.push_back('\\');
                i++;
            } else {
                clean.push_back(raw[i]);
            }
        }
        if (!clean.empty()) libs.push_back(clean);
    }
    fclose(fp);
    return libs;
}

static std::string autodetect_game_dir(const std::string &saved_dir) {
    if (is_valid_bo3_dir(saved_dir)) return saved_dir;
    if (const char *env = getenv("BO3_GAME_DIR"); env && is_valid_bo3_dir(env)) return env;

    std::string steam_root = home_dir() + "/Library/Application Support/Steam";
    std::vector<std::string> roots;
    roots.push_back(steam_root);
    auto vdf_libs = parse_steam_libraries(steam_root + "/steamapps/libraryfolders.vdf");
    roots.insert(roots.end(), vdf_libs.begin(), vdf_libs.end());

    // Scan /Volumes/* for external Steam libraries
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *vols = [fm contentsOfDirectoryAtPath:@"/Volumes" error:nil];
    for (NSString *v in vols) {
        std::string base = std::string("/Volumes/") + v.UTF8String;
        roots.push_back(base + "/SteamLibrary");
        roots.push_back(base + "/Steam");
        roots.push_back(base + "/Games/SteamLibrary");
    }

    for (const auto &r : roots) {
        std::string cand = r + "/steamapps/common/Call of Duty Black Ops III";
        if (is_valid_bo3_dir(cand)) return cand;
    }
    return "";
}

static std::string autodetect_cache_dir(const std::string &saved_cache) {
    if (!saved_cache.empty() && file_exists(saved_cache + "/libbo3_recomp.dylib")) return saved_cache;
    for (const char *var : { "BO3MAC_CACHE_DIR", "BO3ARM_CACHE_DIR" }) {
        if (const char *e = getenv(var); e && e[0] && file_exists(std::string(e) + "/libbo3_recomp.dylib")) {
            return e;
        }
    }
    std::string def = home_dir() + "/Library/Caches/bo3mac";
    if (file_exists(def + "/libbo3_recomp.dylib")) return def;
    NSString *res_dir = [[NSBundle mainBundle] resourcePath];
    if (res_dir) {
        std::string rd = res_dir.UTF8String;
        if (file_exists(rd + "/libbo3_recomp.dylib")) return rd;
    }
    return !saved_cache.empty() ? saved_cache : def;
}

static bool parse_u32(const char *s, uint32_t *out) {
    if (!s || !s[0]) return false;
    for (const char *p = s; *p; p++) if (*p < '0' || *p > '9') return false;
    char *end = nullptr;
    errno = 0;
    unsigned long v = strtoul(s, &end, 10);
    if (errno != 0 || end == s || *end != '\0' || v > 1000000UL) return false;
    *out = (uint32_t)v;
    return true;
}

static LauncherConfig load_config(const HardwareInfo &hw) {
    LauncherConfig cfg;
    cfg.metalfx = hw.rec_metalfx;
    cfg.render_scale = hw.rec_scale;
    cfg.lossy_rt = hw.rec_lossy;
    cfg.max_frame_latency = hw.rec_latency;
    cfg.hud_mode = 0;
    cfg.friends_only = true;
    cfg.offline = false;

    FILE *fp = fopen(settings_file_path().c_str(), "r");
    if (!fp) return cfg;
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
            cfg.game_dir = val;
            continue;
        }
        if (strcmp(p, "cache_dir") == 0) {
            cfg.cache_dir = val;
            continue;
        }
        uint32_t num = 0;
        if (!parse_u32(val, &num)) continue;
        if (strcmp(p, "metalfx") == 0) cfg.metalfx = (num != 0);
        else if (strcmp(p, "render_scale") == 0 && num >= 50 && num <= 100) cfg.render_scale = num;
        else if (strcmp(p, "lossy_rt") == 0) cfg.lossy_rt = (num != 0) && hw.apple8_plus;
        else if (strcmp(p, "max_frame_latency") == 0 && num <= 3) cfg.max_frame_latency = num;
        else if (strcmp(p, "hud_mode") == 0 && num <= 2) cfg.hud_mode = num;
        else if (strcmp(p, "friends_only") == 0) cfg.friends_only = (num != 0);
        else if (strcmp(p, "offline") == 0) cfg.offline = (num != 0);
    }
    fclose(fp);
    return cfg;
}

static void save_config(const LauncherConfig &cfg) {
    std::string dir = settings_dir_path();
    std::string path = dir + "/settings.ini";
    std::string lock_path = dir + "/.settings.lock";
    int lfd = open(lock_path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (lfd >= 0) flock(lfd, LOCK_EX);

    std::string tmp = path + ".tmp." + std::to_string((long)getpid());
    unlink(tmp.c_str());
    int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd >= 0) {
        FILE *fp = fdopen(fd, "w");
        if (fp) {
            fprintf(fp, "# bo3mac settings (shared between BO3 Mac.app and in-game F10 / Cmd+, overlay)\n");
            fprintf(fp, "metalfx=%u\n", cfg.metalfx ? 1u : 0u);
            fprintf(fp, "render_scale=%u\n", cfg.render_scale);
            fprintf(fp, "lossy_rt=%u\n", cfg.lossy_rt ? 1u : 0u);
            fprintf(fp, "max_frame_latency=%u\n", cfg.max_frame_latency);
            fprintf(fp, "hud_mode=%u\n", cfg.hud_mode);
            fprintf(fp, "friends_only=%u\n", cfg.friends_only ? 1u : 0u);
            fprintf(fp, "offline=%u\n", cfg.offline ? 1u : 0u);
            if (!cfg.game_dir.empty())  fprintf(fp, "game_dir=%s\n", cfg.game_dir.c_str());
            if (!cfg.cache_dir.empty()) fprintf(fp, "cache_dir=%s\n", cfg.cache_dir.c_str());
            bool ok = (ferror(fp) == 0 && fflush(fp) == 0);
            if (ok) fsync(fileno(fp));
            if (fclose(fp) != 0) ok = false;
            if (!ok || rename(tmp.c_str(), path.c_str()) != 0) {
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

static bool is_steam_running() {
    NSArray<NSRunningApplication *> *apps =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.valvesoftware.steam"];
    return apps.count > 0;
}

@interface BO3LauncherDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate> {
    HardwareInfo   _hw;
    LauncherConfig _cfg;
    NSWindow      *_win;
    NSTextField   *_statusLabel;
    NSTextField   *_gamePathLabel;
    NSButton      *_metalfxBtn;
    NSSlider      *_scaleSlider;
    NSTextField   *_scaleLabel;
    NSButton      *_lossyBtn;
    NSSegmentedControl *_latencySeg;
    NSSegmentedControl *_hudSeg;
    NSButton      *_friendsBtn;
    NSButton      *_offlineBtn;
    NSButton      *_playBtn;
    NSTask        *_gameTask;
    NSTimer       *_steamTimer;
}
@end

@implementation BO3LauncherDelegate

- (NSTextField *)makeLabel:(NSString *)text font:(NSFont *)font color:(NSColor *)color frame:(NSRect)frame {
    NSTextField *tf = [NSTextField labelWithString:text];
    tf.font = font;
    tf.textColor = color;
    tf.frame = frame;
    tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return tf;
}

- (void)refreshStatus {
    bool has_game = is_valid_bo3_dir(_cfg.game_dir);
    std::string dylib = _cfg.cache_dir + "/libbo3_recomp.dylib";
    bool has_dylib = file_exists(dylib);
    bool steam_up = is_steam_running();

    if (!has_game) {
        _statusLabel.stringValue = @"Steam Black Ops III not found — click \"Locate Game…\"";
        _statusLabel.textColor = [NSColor systemOrangeColor];
        _gamePathLabel.stringValue = @"Install Call of Duty: Black Ops III via Steam first.";
        _playBtn.enabled = NO;
    } else if (!has_dylib) {
        _statusLabel.stringValue = @"Native ARM64 build not found — run ./install.sh first";
        _statusLabel.textColor = [NSColor systemOrangeColor];
        _gamePathLabel.stringValue = [NSString stringWithFormat:@"Expected: %s", dylib.c_str()];
        _playBtn.enabled = NO;
    } else if (_gameTask && _gameTask.isRunning) {
        _statusLabel.stringValue = @"Black Ops III is running — press F10 or ⌘, in-game for live settings";
        _statusLabel.textColor = [NSColor systemGreenColor];
        _gamePathLabel.stringValue = [NSString stringWithUTF8String:_cfg.game_dir.c_str()];
        _playBtn.enabled = NO;
        _playBtn.title = @"Running…";
    } else {
        if (_cfg.offline) {
            _statusLabel.stringValue = @"Ready — Offline Mode (Solo Zombies / Campaign)";
            _statusLabel.textColor = [NSColor systemTealColor];
        } else if (steam_up) {
            _statusLabel.stringValue = @"Ready — Steam Online Connected (Cross-Play Enabled)";
            _statusLabel.textColor = [NSColor systemGreenColor];
        } else {
            _statusLabel.stringValue = @"Ready — Open Steam for Online Co-op, or enable Offline Mode";
            _statusLabel.textColor = [NSColor systemYellowColor];
        }
        _gamePathLabel.stringValue = [NSString stringWithUTF8String:_cfg.game_dir.c_str()];
        _playBtn.enabled = YES;
        _playBtn.title = @"Play Black Ops III";
    }
}

- (void)syncControlsFromConfig {
    _metalfxBtn.state = _cfg.metalfx ? NSControlStateValueOn : NSControlStateValueOff;
    _scaleSlider.integerValue = (NSInteger)_cfg.render_scale;
    _scaleSlider.enabled = _cfg.metalfx && _hw.metalfx_supported;
    _scaleLabel.stringValue = [NSString stringWithFormat:@"%u%%", _cfg.render_scale];
    _lossyBtn.enabled = _hw.apple8_plus;
    _lossyBtn.state = (_hw.apple8_plus && _cfg.lossy_rt) ? NSControlStateValueOn : NSControlStateValueOff;
    _latencySeg.selectedSegment = (NSInteger)std::min<uint32_t>(_cfg.max_frame_latency, 3u);
    _hudSeg.selectedSegment = (NSInteger)std::min<uint32_t>(_cfg.hud_mode, 2u);
    _friendsBtn.state = _cfg.friends_only ? NSControlStateValueOn : NSControlStateValueOff;
    _offlineBtn.state = _cfg.offline ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshStatus];
}

- (void)onChanged:(id)sender {
    _cfg.metalfx = (_metalfxBtn.state == NSControlStateValueOn);
    if (sender == _scaleSlider) {
        uint32_t sc = (uint32_t)std::clamp<NSInteger>(_scaleSlider.integerValue, 50, 100);
        sc = ((sc + 2u) / 5u) * 5u;
        if (sc < 50) sc = 50;
        if (sc > 100) sc = 100;
        _cfg.render_scale = sc;
        _scaleSlider.integerValue = (NSInteger)sc;
        _scaleLabel.stringValue = [NSString stringWithFormat:@"%u%%", sc];
    }
    _scaleSlider.enabled = _cfg.metalfx && _hw.metalfx_supported;
    _cfg.lossy_rt = _hw.apple8_plus && (_lossyBtn.state == NSControlStateValueOn);
    _cfg.max_frame_latency = (uint32_t)std::max<NSInteger>(0, _latencySeg.selectedSegment);
    _cfg.hud_mode = (uint32_t)std::max<NSInteger>(0, _hudSeg.selectedSegment);
    _cfg.friends_only = (_friendsBtn.state == NSControlStateValueOn);
    _cfg.offline = (_offlineBtn.state == NSControlStateValueOn);
    NSEvent *cur = [NSApp currentEvent];
    if (sender != _scaleSlider || !cur || cur.type != NSEventTypeLeftMouseDragged) {
        save_config(_cfg);
    }
    [self refreshStatus];
}

- (void)onReset:(id)sender {
    (void)sender;
    _cfg.metalfx = _hw.rec_metalfx;
    _cfg.render_scale = _hw.rec_scale;
    _cfg.lossy_rt = _hw.rec_lossy;
    _cfg.max_frame_latency = _hw.rec_latency;
    _cfg.hud_mode = 0;
    _cfg.friends_only = true;
    save_config(_cfg);
    [self syncControlsFromConfig];
}

- (void)onLocateGame:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.title = @"Locate \"Call of Duty Black Ops III\" Steam Folder";
    panel.prompt = @"Select Folder";
    if ([panel runModal] == NSModalResponseOK && panel.URL) {
        std::string chosen = panel.URL.path.UTF8String;
        if (is_valid_bo3_dir(chosen)) {
            _cfg.game_dir = chosen;
            save_config(_cfg);
            [self refreshStatus];
        } else {
            NSAlert *al = [[NSAlert alloc] init];
            al.messageText = @"Black Ops III Not Found in Selected Folder";
            al.informativeText = @"Please select the \"Call of Duty Black Ops III\" folder inside your Steam library (the folder containing CoDBlkOps3.app).";
            [al runModal];
        }
    }
}

- (void)onOpenLogs:(id)sender {
    (void)sender;
    std::string lp = log_file_path();
    if (!file_exists(lp)) {
        FILE *fp = fopen(lp.c_str(), "a");
        if (fp) fclose(fp);
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:lp.c_str()]]];
}

- (void)onPlay:(id)sender {
    (void)sender;
    save_config(_cfg);

    NSString *bundleMacOS = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    NSString *loaderPath = [bundleMacOS stringByAppendingPathComponent:@"bo3_loader"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:loaderPath]) {
        NSAlert *al = [[NSAlert alloc] init];
        al.messageText = @"Missing bo3_loader Binary";
        al.informativeText = @"bo3_loader was not found inside BO3 Mac.app. Re-run ./install.sh to rebuild the app bundle.";
        [al runModal];
        return;
    }

    std::string dylib = _cfg.cache_dir + "/libbo3_recomp.dylib";
    std::string assets = _cfg.game_dir + "/CoDBlkOps3.app/Contents/Assets";
    std::string metallib = _cfg.game_dir + "/CoDBlkOps3.app/Contents/Resources/Generic.metallib";

    std::string lp = log_file_path();
    [[NSFileManager defaultManager] createFileAtPath:[NSString stringWithUTF8String:lp.c_str()]
                                            contents:[NSData data]
                                          attributes:nil];
    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:[NSString stringWithUTF8String:lp.c_str()]];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:loaderPath];
    task.arguments = @[ @"../MacOS/CoDBlkOps3_Exe", [NSString stringWithUTF8String:dylib.c_str()] ];
    task.currentDirectoryURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:assets.c_str()]];

    NSMutableDictionary<NSString *, NSString *> *env =
        [NSMutableDictionary dictionaryWithDictionary:[NSProcessInfo processInfo].environment];
    env[@"BO3MAC_CACHE_DIR"] = [NSString stringWithUTF8String:_cfg.cache_dir.c_str()];
    env[@"BO3_GAME_DIR"] = [NSString stringWithUTF8String:_cfg.game_dir.c_str()];
    if (file_exists(metallib)) {
        env[@"BO3MAC_METALLIB"] = [NSString stringWithUTF8String:metallib.c_str()];
    }
    // Release mode: strip any developer/validation env vars for minimal overhead
    [env removeObjectForKey:@"MTL_DEBUG_LAYER"];
    [env removeObjectForKey:@"BO3ARM_PERF_STATS"];
    [env removeObjectForKey:@"BO3ARM_VERBOSE"];
    [env removeObjectForKey:@"BO3ARM_METALFX"];
    [env removeObjectForKey:@"BO3ARM_RENDER_SCALE"];
    [env removeObjectForKey:@"BO3ARM_LOSSY_RT"];
    [env removeObjectForKey:@"BO3ARM_MAX_FRAME_LATENCY"];
    [env removeObjectForKey:@"BO3ARM_HUD"];
    [env removeObjectForKey:@"BO3ARM_FRIENDS_ONLY"];
    if (_cfg.offline) {
        env[@"BO3ARM_OFFLINE"] = @"1";
    } else {
        [env removeObjectForKey:@"BO3ARM_OFFLINE"];
    }
    task.environment = env;

    if (logHandle) {
        task.standardOutput = logHandle;
        task.standardError = logHandle;
    }

    __weak BO3LauncherDelegate *weakSelf = self;
    task.terminationHandler = ^(NSTask *t) {
        int code = t.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            BO3LauncherDelegate *s = weakSelf;
            if (!s) return;
            s->_gameTask = nil;
            // Reload settings.ini in case user tweaked settings live via F10 / Cmd+, in-game!
            s->_cfg = load_config(s->_hw);
            s->_cfg.game_dir = autodetect_game_dir(s->_cfg.game_dir);
            s->_cfg.cache_dir = autodetect_cache_dir(s->_cfg.cache_dir);
            [s syncControlsFromConfig];
            [s->_win makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            if (code != 0) {
                NSAlert *al = [[NSAlert alloc] init];
                al.messageText = [NSString stringWithFormat:@"Black Ops III Exited (Code %d)", code];
                al.informativeText = @"Check ~/Library/Logs/bo3mac.log for details.";
                [al addButtonWithTitle:@"OK"];
                [al addButtonWithTitle:@"Open Log"];
                if ([al runModal] == NSAlertSecondButtonReturn) {
                    [s onOpenLogs:nil];
                }
            }
        });
    };

    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        NSAlert *al = [[NSAlert alloc] init];
        al.messageText = @"Failed to Launch Black Ops III";
        al.informativeText = err ? err.localizedDescription : @"Unknown launch error.";
        [al runModal];
        return;
    }
    _gameTask = task;
    [self refreshStatus];
    [_win orderOut:nil];
}

- (void)buildUI {
    const CGFloat W = 500.0, H = 515.0;
    _win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                       styleMask:(NSWindowStyleMaskTitled |
                                                  NSWindowStyleMaskClosable |
                                                  NSWindowStyleMaskMiniaturizable)
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    _win.title = @"BO3 Mac — Native Apple Silicon";
    _win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    _win.titlebarAppearsTransparent = YES;
    _win.backgroundColor = [NSColor colorWithWhite:0.08 alpha:1.0];
    _win.delegate = self;
    [_win center];

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    bg.material = NSVisualEffectMaterialUnderWindowBackground;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    _win.contentView = bg;

    CGFloat y = H - 52;
    [bg addSubview:[self makeLabel:@"Call of Duty: Black Ops III"
                              font:[NSFont systemFontOfSize:20 weight:NSFontWeightBold]
                             color:[NSColor labelColor]
                             frame:NSMakeRect(22, y, W - 44, 28)]];
    y -= 20;
    NSString *hwText = [NSString stringWithFormat:@"Native ARM64 + Direct Metal  •  %s  (%dx%d)",
                        _hw.profile_label.c_str(), _hw.phys_w, _hw.phys_h];
    [bg addSubview:[self makeLabel:hwText
                              font:[NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium]
                             color:[NSColor secondaryLabelColor]
                             frame:NSMakeRect(22, y, W - 44, 18)]];

    // Status box
    y -= 52;
    NSBox *statusBox = [[NSBox alloc] initWithFrame:NSMakeRect(22, y, W - 44, 44)];
    statusBox.boxType = NSBoxCustom;
    statusBox.fillColor = [NSColor colorWithWhite:1.0 alpha:0.05];
    statusBox.borderColor = [NSColor colorWithWhite:1.0 alpha:0.10];
    statusBox.cornerRadius = 8.0;
    _statusLabel = [self makeLabel:@"" font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
                             color:[NSColor systemGreenColor] frame:NSMakeRect(12, 20, W - 70, 18)];
    _gamePathLabel = [self makeLabel:@"" font:[NSFont systemFontOfSize:10.5]
                               color:[NSColor tertiaryLabelColor] frame:NSMakeRect(12, 4, W - 70, 15)];
    [statusBox.contentView addSubview:_statusLabel];
    [statusBox.contentView addSubview:_gamePathLabel];
    [bg addSubview:statusBox];

    // Graphics & Performance section
    y -= 28;
    [bg addSubview:[self makeLabel:@"GRAPHICS & APPLE SILICON PERFORMANCE"
                              font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightBold]
                             color:[NSColor tertiaryLabelColor]
                             frame:NSMakeRect(22, y, W - 44, 16)]];

    y -= 28;
    _metalfxBtn = [NSButton checkboxWithTitle:@"MetalFX Spatial Upscaling (Apple Silicon GPU)"
                                       target:self action:@selector(onChanged:)];
    _metalfxBtn.frame = NSMakeRect(22, y, W - 44, 22);
    _metalfxBtn.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    [bg addSubview:_metalfxBtn];

    y -= 30;
    [bg addSubview:[self makeLabel:@"Startup Display Scale:"
                              font:[NSFont systemFontOfSize:12.5]
                             color:[NSColor labelColor]
                             frame:NSMakeRect(22, y + 2, 150, 20)]];
    _scaleSlider = [NSSlider sliderWithValue:100 minValue:50 maxValue:100 target:self action:@selector(onChanged:)];
    _scaleSlider.frame = NSMakeRect(174, y, 250, 22);
    _scaleSlider.continuous = YES;
    [bg addSubview:_scaleSlider];
    _scaleLabel = [self makeLabel:@"100%" font:[NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightSemibold]
                            color:[NSColor labelColor] frame:NSMakeRect(432, y + 2, 48, 20)];
    _scaleLabel.alignment = NSTextAlignmentRight;
    [bg addSubview:_scaleLabel];

    y -= 20;
    [bg addSubview:[self makeLabel:@"Tip: Press F10 or ⌘, anytime in-game to edit settings live without restarting."
                              font:[NSFont systemFontOfSize:10.5]
                             color:[NSColor tertiaryLabelColor]
                             frame:NSMakeRect(22, y, W - 44, 16)]];

    y -= 30;
    NSString *lossyTitle = _hw.apple8_plus
        ? @"Lossy Render-Target Compression (M2/M3/M4+ Bandwidth Saver)"
        : @"Lossy Render-Target Compression (Requires M2 / Apple8+ GPU)";
    _lossyBtn = [NSButton checkboxWithTitle:lossyTitle target:self action:@selector(onChanged:)];
    _lossyBtn.frame = NSMakeRect(22, y, W - 44, 22);
    _lossyBtn.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    [bg addSubview:_lossyBtn];

    y -= 36;
    [bg addSubview:[self makeLabel:@"Max Frame Latency:"
                              font:[NSFont systemFontOfSize:12.5]
                             color:[NSColor labelColor]
                             frame:NSMakeRect(22, y + 4, 150, 20)]];
    _latencySeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Auto", @"1", @"2", @"3"]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:self action:@selector(onChanged:)];
    _latencySeg.frame = NSMakeRect(174, y, 304, 26);
    [bg addSubview:_latencySeg];

    y -= 36;
    [bg addSubview:[self makeLabel:@"Performance HUD:"
                              font:[NSFont systemFontOfSize:12.5]
                             color:[NSColor labelColor]
                             frame:NSMakeRect(22, y + 4, 150, 20)]];
    _hudSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Off", @"FPS", @"Detailed"]
                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                      target:self action:@selector(onChanged:)];
    _hudSeg.frame = NSMakeRect(174, y, 304, 26);
    [bg addSubview:_hudSeg];

    // Online & Safety section
    y -= 30;
    [bg addSubview:[self makeLabel:@"ONLINE & SAFETY"
                              font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightBold]
                             color:[NSColor tertiaryLabelColor]
                             frame:NSMakeRect(22, y, W - 44, 16)]];

    y -= 28;
    _friendsBtn = [NSButton checkboxWithTitle:@"Friends-Only Lobby & P2P Guard (Recommended)"
                                       target:self action:@selector(onChanged:)];
    _friendsBtn.frame = NSMakeRect(22, y, W - 44, 22);
    _friendsBtn.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    [bg addSubview:_friendsBtn];

    y -= 26;
    _offlineBtn = [NSButton checkboxWithTitle:@"Offline Mode (Solo Zombies / Campaign without Steam)"
                                       target:self action:@selector(onChanged:)];
    _offlineBtn.frame = NSMakeRect(22, y, W - 44, 22);
    _offlineBtn.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    [bg addSubview:_offlineBtn];

    // Secondary buttons row
    y -= 42;
    NSButton *resetBtn = [NSButton buttonWithTitle:@"Reset Recommended" target:self action:@selector(onReset:)];
    resetBtn.bezelStyle = NSBezelStyleRounded;
    resetBtn.frame = NSMakeRect(22, y, 154, 28);
    [bg addSubview:resetBtn];

    NSButton *locateBtn = [NSButton buttonWithTitle:@"Locate Game…" target:self action:@selector(onLocateGame:)];
    locateBtn.bezelStyle = NSBezelStyleRounded;
    locateBtn.frame = NSMakeRect(184, y, 134, 28);
    [bg addSubview:locateBtn];

    NSButton *logsBtn = [NSButton buttonWithTitle:@"Open Logs" target:self action:@selector(onOpenLogs:)];
    logsBtn.bezelStyle = NSBezelStyleRounded;
    logsBtn.frame = NSMakeRect(326, y, 152, 28);
    [bg addSubview:logsBtn];

    // Big Play button
    y -= 48;
    _playBtn = [NSButton buttonWithTitle:@"Play Black Ops III" target:self action:@selector(onPlay:)];
    _playBtn.bezelStyle = NSBezelStyleRounded;
    _playBtn.keyEquivalent = @"\r";
    _playBtn.font = [NSFont systemFontOfSize:14.5 weight:NSFontWeightBold];
    _playBtn.frame = NSMakeRect(22, y, W - 44, 38);
    [bg addSubview:_playBtn];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    _hw = probe_hardware();
    _cfg = load_config(_hw);
    _cfg.game_dir = autodetect_game_dir(_cfg.game_dir);
    _cfg.cache_dir = autodetect_cache_dir(_cfg.cache_dir);
    save_config(_cfg);

    // Menu bar with Cmd+Q
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [bar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"BO3 Mac"];
    [appMenu addItemWithTitle:@"Quit BO3 Mac" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [NSApp setMainMenu:bar];

    [self buildUI];
    [self syncControlsFromConfig];
    [_win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    _steamTimer = [NSTimer scheduledTimerWithTimeInterval:2.5 repeats:YES block:^(NSTimer * _Nonnull) {
        [self refreshStatus];
    }];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    if (!flag && (!_gameTask || !_gameTask.isRunning)) {
        [_win makeKeyAndOrderFront:nil];
    }
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return (_gameTask == nil || !_gameTask.isRunning);
}

@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        BO3LauncherDelegate *del = [[BO3LauncherDelegate alloc] init];
        app.delegate = del;
        [app run];
    }
    return 0;
}

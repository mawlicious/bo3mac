#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "window_mac.h"
#include "settings_mac.h"
#include "shim_helpers.h"
#include <atomic>
#include <cmath>
#include <deque>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <os/lock.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <unordered_map>
#include <mach/mach_time.h>

// Win32 MSG struct (x86_64 layout = 48 bytes):
//   +0x00: HWND   hwnd (8)
//   +0x08: UINT   message (4) + pad (4)
//   +0x10: WPARAM wParam (8)
//   +0x18: LPARAM lParam (8)
//   +0x20: DWORD  time (4)
//   +0x24: POINT  pt (8: x, y)
//   +0x2c: pad (4) -> total 48 bytes
struct Win32Msg {
    uint64_t hwnd;
    uint32_t message;
    uint32_t _pad0;
    uint64_t wparam;
    uint64_t lparam;
    uint32_t time;
    int32_t  pt_x;
    int32_t  pt_y;
    uint32_t _pad1;
};
static_assert(sizeof(Win32Msg) == 48, "Win32 MSG must be 48 bytes");

// Exact x64 Win32 RAWINPUT for mouse (48 bytes total: 24B RAWINPUTHEADER + 24B RAWMOUSE)
struct Win32RawInputHeader {
    uint32_t dwType;     // 0 = RIM_TYPEMOUSE, 1 = RIM_TYPEKEYBOARD
    uint32_t dwSize;
    uint64_t hDevice;
    uint64_t wParam;
};
struct Win32RawMouse {
    uint16_t usFlags;
    uint16_t _pad;
    uint16_t usButtonFlags;
    uint16_t usButtonData;
    uint32_t ulRawButtons;
    int32_t  lLastX;
    int32_t  lLastY;
    uint32_t ulExtraInformation;
};
struct Win32RawInputMouse {
    Win32RawInputHeader header;
    Win32RawMouse       mouse;
};
static_assert(sizeof(Win32RawInputHeader) == 24, "RAWINPUTHEADER must be 24 bytes");
static_assert(sizeof(Win32RawInputMouse) == 48, "RAWINPUT mouse must be 48 bytes");

#define BO3_MAC_HWND_MAGIC 0x424F334D574E4421ULL

// Custom Metal NSView receiving all Cocoa keyboard/mouse events
@interface Bo3MetalView : NSView <NSWindowDelegate>
@property (nonatomic, assign) uint64_t bo3Hwnd;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@end

// Custom NSWindow subclass: borderless windows return NO from canBecomeKeyWindow/MainWindow by
// default, and constrainFrameRect:toScreen: pushes normal-level windows below the menu bar.
@interface Bo3MacNSWindow : NSWindow
@property (nonatomic, assign) BOOL bo3FullscreenFrame;
@property (nonatomic, assign) BOOL bo3InModeTransition;
@end

@implementation Bo3MacNSWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen {
    if (_bo3FullscreenFrame) return frameRect;
    return [super constrainFrameRect:frameRect toScreen:screen];
}
@end

static inline bool style_is_borderless(uint32_t style) {
    // Win32 WS_CAPTION = 0x00C00000. BO3 uses 0x10000000 (WS_VISIBLE, no caption) for
    // Fullscreen & Windowed (Fullscreen), and 0x10CC0000 for Windowed.
    return (style != 0) && ((style & 0x00C00000u) == 0);
}

struct Bo3MacWindow {
    uint64_t magic = BO3_MAC_HWND_MAGIC;
    uint64_t wndproc_va = 0;
    int32_t  x = 100, y = 100, w = 1280, h = 720;
    int32_t  windowed_w = 1280, windowed_h = 720;
    int32_t  render_w = 0, render_h = 0;     // Guest-visible SwapChain backbuffer dimensions (may be scaled)
    int32_t  drawable_w = 0, drawable_h = 0; // Native CAMetalLayer drawable dimensions (unscaled for MetalFX)
    const void *size_owner = nullptr;        // Active swap chain owning render_w/drawable_w (prevents stale clear)
    uint32_t style = 0;
    uint32_t exstyle = 0;
    uint64_t userdata = 0;
    bool     is_message_only = false;
    bool     is_fullscreen = false; // DXGI SetFullscreenState(TRUE) / CreateSwapChain(Windowed=0)
    bool     is_borderless = false; // GWL_STYLE without WS_CAPTION (Windowed Fullscreen / Fullscreen)
    char     title[256] = {0};
    Bo3MacNSWindow *ns_window = nil;
    Bo3MetalView   *metal_view = nil;
    CAMetalLayer   *metal_layer = nil;
};

// Global state (no_destroy prevents C++ static destructor crashes during exit() while AppKit Thread 0 is live)
[[clang::no_destroy]] static std::mutex g_win_mtx;
static os_unfair_lock g_metal_layer_lock = OS_UNFAIR_LOCK_INIT; // pure leaf lock guarding CAMetalLayer mutations & nextDrawable
[[clang::no_destroy]] static std::unordered_map<std::string, uint64_t> g_class_wndprocs;
[[clang::no_destroy]] static std::unordered_map<uint64_t, std::shared_ptr<Bo3MacWindow>> g_live_windows;
static uint64_t g_last_registered_wndproc = 0;
[[clang::no_destroy]] static std::shared_ptr<Bo3MacWindow> g_main_window;
static std::atomic<int32_t> g_screen_w{0};
static std::atomic<int32_t> g_screen_h{0};
static std::atomic<uint64_t> g_raw_input_hwnd{0};
static bool g_cursor_hidden = false;      // main-thread only: logical capture active state
static bool g_want_cursor_hidden = false; // main-thread only: requested by game via ShowCursor
static bool g_mouse_dissociated = false;  // main-thread only: CGAssociateMouseAndMouseCursorPosition(false) succeeded
static int  g_cursor_hide_depth = 0;      // main-thread only: balanced [NSCursor hide/unhide] depth (0 or 1)
static bool g_capture_park_valid = false; // main-thread only: parked global Cocoa screen point for drift detection
static NSPoint g_capture_park_global = {0, 0};
static uint32_t g_last_recapture_ms = 0;
static uint32_t g_recapture_burst_start_ms = 0;
static uint32_t g_recapture_burst_count = 0;
static bool     g_drift_recovery_paused = false; // backs off for direct-positioning devices (Universal Control / Sidecar / Parsec)
static std::atomic<int> g_last_show_req{-1}; // dedup 1000Hz ShowCursor loops in BO3
static std::atomic<bool> g_show_update_pending{false}; // coalesce queued main-thread visibility updates
static double g_mouse_accum_x = 0.0;      // main-thread only: fractional delta accumulator
static double g_mouse_accum_y = 0.0;
static bool    g_last_os_valid = false;   // main-thread only: last raw OS pointer client pos (never mutated by SetCursorPos)
static int32_t g_last_os_x = 0;
static int32_t g_last_os_y = 0;
static uint32_t g_capture_grace_until_ms = 0; // suppress bogus post-warp delta spike on capture transition

static std::shared_ptr<Bo3MacWindow> get_main_win() {
    std::lock_guard<std::mutex> lk(g_win_mtx);
    return g_main_window;
}

static uint32_t monotonic_ms() {
    static mach_timebase_info_data_t tb = {0, 0};
    static std::once_flag once;
    std::call_once(once, []() { mach_timebase_info(&tb); });
    return (uint32_t)(((mach_absolute_time() * (uint64_t)tb.numer) / (uint64_t)tb.denom) / 1000000ULL);
}

// Message queue (protected by mutex + condvar; no_destroy avoids exit() races with Thread 0)
[[clang::no_destroy]] static std::mutex g_msg_mtx;
[[clang::no_destroy]] static std::condition_variable g_msg_cv;
[[clang::no_destroy]] static std::deque<Win32Msg> g_msg_queue;

// Sequence-tagged 2048-entry raw input mouse ring buffer
struct RawRingSlot {
    uint64_t           seq;
    Win32RawInputMouse data;
};
[[clang::no_destroy]] static std::mutex g_raw_mtx;
static constexpr size_t RAW_RING_SZ = 2048;
static RawRingSlot g_raw_ring[RAW_RING_SZ];

// Key & mouse state table (Win32 VK 0..255)
static std::atomic<uint8_t> g_vk_down[256];
static std::atomic<int32_t> g_mouse_x{640};      // client-space X in [0, coord_w - 1]
static std::atomic<int32_t> g_mouse_y{360};      // client-space Y in [0, coord_h - 1]
static std::atomic<int32_t> g_raw_dx{0};         // accumulated raw relative delta X for GetRawInputBuffer
static std::atomic<int32_t> g_raw_dy{0};         // accumulated raw relative delta Y for GetRawInputBuffer
static std::atomic<uint32_t> g_mouse_buttons{0}; // bit0=L, bit1=R, bit2=M, bit3=X1, bit4=X2

static void get_coord_origin_and_size(uint64_t hwnd, int32_t *ox, int32_t *oy, int32_t *cw, int32_t *ch) {
    std::lock_guard<std::mutex> lk(g_win_mtx);
    std::shared_ptr<Bo3MacWindow> bw;
    if (hwnd && hwnd != 0xfffffffffffffffdULL) {
        auto it = g_live_windows.find(hwnd);
        if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
    }
    if (!bw) bw = g_main_window;
    if (bw) {
        if (ox) *ox = bw->x;
        if (oy) *oy = bw->y;
        int32_t w = (bw->render_w > 0) ? bw->render_w : bw->w;
        int32_t h = (bw->render_h > 0) ? bw->render_h : bw->h;
        if (cw) *cw = (w > 0) ? w : 1280;
        if (ch) *ch = (h > 0) ? h : 720;
    } else {
        if (ox) *ox = 0;
        if (oy) *oy = 0;
        if (cw) *cw = 1280;
        if (ch) *ch = 720;
    }
}

static void clear_all_held_inputs() {
    g_mouse_buttons.store(0, std::memory_order_relaxed);
    for (int i = 0; i < 256; i++) g_vk_down[i].store(0, std::memory_order_relaxed);
    g_raw_dx.store(0, std::memory_order_relaxed);
    g_raw_dy.store(0, std::memory_order_relaxed);
    g_mouse_accum_x = 0.0;
    g_mouse_accum_y = 0.0;
    g_last_os_valid = false;
}

static NSCursor *blank_cursor_main_thread() {
    static NSCursor *s_blank = nil;
    if (!s_blank) {
        NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        s_blank = [[NSCursor alloc] initWithImage:img hotSpot:NSZeroPoint];
    }
    return s_blank;
}

static bool main_window_can_capture(NSWindow **out_win, NSView **out_view) {
    NSWindow *nsw = nil;
    NSView *nsv = nil;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        if (g_main_window) {
            nsw = g_main_window->ns_window;
            nsv = g_main_window->metal_view;
        }
    }
    if (out_win) *out_win = nsw;
    if (out_view) *out_view = nsv;
    return nsw != nil && [NSApp isActive] && [nsw isKeyWindow] && !bo3_ui_settings_panel_open();
}

static void apply_cursor_capture_main_thread(bool hide, bool force = false, bool rewarp = false) {
    NSWindow *main_nsw = nil;
    NSView *main_view = nil;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        if (g_main_window) {
            main_nsw = g_main_window->ns_window;
            main_view = g_main_window->metal_view;
        }
    }

    if (hide) {
        if (!main_nsw || ![NSApp isActive] || ![main_nsw isKeyWindow] || bo3_ui_settings_panel_open()) {
            return;
        }
        bool was_hidden = g_cursor_hidden;
        if (!force && was_hidden && g_mouse_dissociated && g_cursor_hide_depth > 0) return;

        bool do_warp = (!was_hidden || rewarp || !g_capture_park_valid);
        if (!was_hidden) {
            g_mouse_accum_x = 0.0;
            g_mouse_accum_y = 0.0;
            g_raw_dx.store(0, std::memory_order_relaxed);
            g_raw_dy.store(0, std::memory_order_relaxed);
            g_last_os_valid = false;
        }

        if (do_warp) {
            // Park OS cursor at the center of the visible intersection of the window's content rect
            // and its display so it never sits on the menu bar, Dock, or outside visible content.
            NSScreen *primary = [NSScreen screens].firstObject ?: [NSScreen mainScreen];
            NSScreen *win_scr = main_nsw.screen ?: primary;
            if (primary && win_scr) {
                NSRect content_r = [main_nsw contentRectForFrameRect:main_nsw.frame];
                NSRect vis_r = NSIntersectionRect(content_r, win_scr.frame);
                if (NSIsEmptyRect(vis_r)) vis_r = content_r;
                CGFloat cocoa_x = vis_r.origin.x + vis_r.size.width * 0.5;
                CGFloat cocoa_y = vis_r.origin.y + vis_r.size.height * 0.5;
                CGFloat cg_y = primary.frame.size.height - cocoa_y;
                if (CGWarpMouseCursorPosition(CGPointMake(cocoa_x, cg_y)) == kCGErrorSuccess) {
                    g_capture_park_global = [NSEvent mouseLocation];
                    g_capture_park_valid = true;
                } else {
                    g_capture_park_valid = false;
                }
            }
        }

        // Apply transparent cursor rect + active cursor so even if WindowServer independently
        // unhides the cursor while association holds, no pointer graphic is drawn over the game.
        [blank_cursor_main_thread() set];
        if (g_cursor_hide_depth == 0) {
            [NSCursor hide];
            g_cursor_hide_depth = 1;
        } else if (force) {
            [NSCursor unhide];
            [NSCursor hide];
        }

        CGError assoc_err = CGAssociateMouseAndMouseCursorPosition(false);
        if (assoc_err == kCGErrorSuccess) {
            g_mouse_dissociated = true;
            if (!g_capture_park_valid) {
                g_capture_park_global = [NSEvent mouseLocation];
                g_capture_park_valid = true;
            }
        }
        g_cursor_hidden = true;
        if (main_view) [main_nsw invalidateCursorRectsForView:main_view];

        uint32_t now = monotonic_ms();
        // Only arm the 80ms post-warp spike filter when we actually warped the cursor.
        if (do_warp) {
            g_capture_grace_until_ms = now + 80u;
        }
        g_last_recapture_ms = now;
    } else {
        if (!force && !g_cursor_hidden && !g_mouse_dissociated && g_cursor_hide_depth == 0) return;
        g_cursor_hidden = false;
        g_capture_park_valid = false;
        g_mouse_accum_x = 0.0;
        g_mouse_accum_y = 0.0;
        g_raw_dx.store(0, std::memory_order_relaxed);
        g_raw_dy.store(0, std::memory_order_relaxed);
        g_last_os_valid = false;
        if (CGAssociateMouseAndMouseCursorPosition(true) == kCGErrorSuccess) {
            g_mouse_dissociated = false;
        }
        while (g_cursor_hide_depth > 0) {
            [NSCursor unhide];
            g_cursor_hide_depth--;
        }
        [[NSCursor arrowCursor] set];
        if (main_nsw && main_view) [main_nsw invalidateCursorRectsForView:main_view];
    }
}

// Self-healing cursor capture check on input events: compares live global [NSEvent mouseLocation]
// against the actual parked global coordinate (independent of view event coordinates, window moves,
// or whether the cursor escaped window bounds). Backs off automatically for direct-positioning
// pointing devices (Universal Control, Sidecar, Parsec, tablets).
static void ensure_cursor_capture_on_event(NSWindow *win, NSEvent *ev, bool check_drift) {
    if (!g_want_cursor_hidden || bo3_ui_settings_panel_open()) return;
    if (!win || ![win isKeyWindow] || ![NSApp isActive]) return;
    if (!g_cursor_hidden || !g_mouse_dissociated) {
        apply_cursor_capture_main_thread(true, true, true);
        return;
    }
    if (!check_drift || g_drift_recovery_paused) return;
    if (ev && ev.CGEvent) {
        int64_t sub = CGEventGetIntegerValueField(ev.CGEvent, kCGMouseEventSubtype);
        if (sub == kCGEventMouseSubtypeTabletPoint) return;
    }
    uint32_t now = monotonic_ms();
    if (g_capture_grace_until_ms != 0 && (int32_t)(g_capture_grace_until_ms - now) > 0) {
        return;
    }
    if (!g_capture_park_valid) {
        g_capture_park_global = [NSEvent mouseLocation];
        g_capture_park_valid = true;
        return;
    }
    NSPoint cur = [NSEvent mouseLocation];
    double dx = fabs(cur.x - g_capture_park_global.x);
    double dy = fabs(cur.y - g_capture_park_global.y);
    if ((dx > 1.5 || dy > 1.5) && (uint32_t)(now - g_last_recapture_ms) >= 100u) {
        if (g_recapture_burst_start_ms == 0 || (uint32_t)(now - g_recapture_burst_start_ms) > 2000u) {
            g_recapture_burst_start_ms = now;
            g_recapture_burst_count = 0;
        }
        g_recapture_burst_count++;
        if (g_recapture_burst_count > 5u) {
            // Direct-positioning device keeps moving the global pointer; stop re-warping until
            // next focus/mode change (the blank NSCursor still keeps the pointer invisible).
            g_drift_recovery_paused = true;
            [blank_cursor_main_thread() set];
            return;
        }
        fprintf(stderr, "[win32-cursor] Self-healed cursor drift (dx=%.1f dy=%.1f)\n", dx, dy);
        fflush(stderr);
        apply_cursor_capture_main_thread(true, true, true);
    }
}

static void push_msg(uint64_t hwnd, uint32_t message, uint64_t wparam, uint64_t lparam) {
    if (!hwnd) {
        auto mw = get_main_win();
        if (mw) {
            hwnd = (uint64_t)(uintptr_t)mw.get();
        } else if (message != 0x0012 /* WM_QUIT */) {
            return;
        }
    }
    Win32Msg m;
    memset(&m, 0, sizeof(m));
    m.hwnd = hwnd;
    m.message = message;
    m.wparam = wparam;
    m.lparam = lparam;
    m.time = monotonic_ms();
    m.pt_x = g_mouse_x.load(std::memory_order_relaxed);
    m.pt_y = g_mouse_y.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lk(g_msg_mtx);
        if (g_msg_queue.size() < 4096 || message == 0x0012 /* WM_QUIT */) {
            g_msg_queue.push_back(m);
        }
    }
    g_msg_cv.notify_all();
}

static void push_raw_mouse(int32_t dx, int32_t dy, uint16_t btn_flags, uint16_t btn_data) {
    (void)btn_flags; (void)btn_data;
    if (dx != 0) g_raw_dx.fetch_add(dx, std::memory_order_acq_rel);
    if (dy != 0) g_raw_dy.fetch_add(dy, std::memory_order_acq_rel);
}

// macOS CGKeyCode -> Windows VK + AT scancode (for BO3 WndProc FUN_100fc4d60)
static uint16_t mac_keycode_to_vk(uint16_t kc, uint8_t *out_scancode) {
    uint16_t vk = 0; uint8_t sc = 0;
    switch (kc) {
        case 0x00: vk = 'A'; sc = 0x1E; break;
        case 0x0B: vk = 'B'; sc = 0x30; break;
        case 0x08: vk = 'C'; sc = 0x2E; break;
        case 0x02: vk = 'D'; sc = 0x20; break;
        case 0x0E: vk = 'E'; sc = 0x12; break;
        case 0x03: vk = 'F'; sc = 0x21; break;
        case 0x05: vk = 'G'; sc = 0x22; break;
        case 0x04: vk = 'H'; sc = 0x23; break;
        case 0x22: vk = 'I'; sc = 0x17; break;
        case 0x26: vk = 'J'; sc = 0x24; break;
        case 0x28: vk = 'K'; sc = 0x25; break;
        case 0x25: vk = 'L'; sc = 0x26; break;
        case 0x2E: vk = 'M'; sc = 0x32; break;
        case 0x2D: vk = 'N'; sc = 0x31; break;
        case 0x1F: vk = 'O'; sc = 0x18; break;
        case 0x23: vk = 'P'; sc = 0x19; break;
        case 0x0C: vk = 'Q'; sc = 0x10; break;
        case 0x0F: vk = 'R'; sc = 0x13; break;
        case 0x01: vk = 'S'; sc = 0x1F; break;
        case 0x11: vk = 'T'; sc = 0x14; break;
        case 0x20: vk = 'U'; sc = 0x16; break;
        case 0x09: vk = 'V'; sc = 0x2F; break;
        case 0x0D: vk = 'W'; sc = 0x11; break;
        case 0x07: vk = 'X'; sc = 0x2D; break;
        case 0x10: vk = 'Y'; sc = 0x15; break;
        case 0x06: vk = 'Z'; sc = 0x2C; break;
        case 0x1D: vk = '0'; sc = 0x0B; break;
        case 0x12: vk = '1'; sc = 0x02; break;
        case 0x13: vk = '2'; sc = 0x03; break;
        case 0x14: vk = '3'; sc = 0x04; break;
        case 0x15: vk = '4'; sc = 0x05; break;
        case 0x17: vk = '5'; sc = 0x06; break;
        case 0x16: vk = '6'; sc = 0x07; break;
        case 0x1A: vk = '7'; sc = 0x08; break;
        case 0x1C: vk = '8'; sc = 0x09; break;
        case 0x19: vk = '9'; sc = 0x0A; break;
        case 0x24: vk = 0x0D; sc = 0x1C; break; // Enter
        case 0x30: vk = 0x09; sc = 0x0F; break; // Tab
        case 0x31: vk = 0x20; sc = 0x39; break; // Space
        case 0x33: vk = 0x08; sc = 0x0E; break; // Backspace
        case 0x35: vk = 0x1B; sc = 0x01; break; // Escape
        case 0x32: vk = 0xC0; sc = 0x29; break; // `~
        case 0x1B: vk = 0xBD; sc = 0x0C; break; // -
        case 0x18: vk = 0xBB; sc = 0x0D; break; // =
        case 0x21: vk = 0xDB; sc = 0x1A; break; // [
        case 0x1E: vk = 0xDD; sc = 0x1B; break; // ]
        case 0x2A: vk = 0xDC; sc = 0x2B; break; // backslash
        case 0x29: vk = 0xBA; sc = 0x27; break; // ;
        case 0x27: vk = 0xDE; sc = 0x28; break; // '
        case 0x2B: vk = 0xBC; sc = 0x33; break; // ,
        case 0x2F: vk = 0xBE; sc = 0x34; break; // .
        case 0x2C: vk = 0xBF; sc = 0x35; break; // /
        case 0x7B: vk = 0x25; sc = 0x4B; break; // Left
        case 0x7C: vk = 0x27; sc = 0x4D; break; // Right
        case 0x7D: vk = 0x28; sc = 0x50; break; // Down
        case 0x7E: vk = 0x26; sc = 0x48; break; // Up
        case 0x7A: vk = 0x70; sc = 0x3B; break; // F1
        case 0x78: vk = 0x71; sc = 0x3C; break; // F2
        case 0x63: vk = 0x72; sc = 0x3D; break; // F3
        case 0x76: vk = 0x73; sc = 0x3E; break; // F4
        case 0x60: vk = 0x74; sc = 0x3F; break; // F5
        case 0x61: vk = 0x75; sc = 0x40; break; // F6
        case 0x62: vk = 0x76; sc = 0x41; break; // F7
        case 0x64: vk = 0x77; sc = 0x42; break; // F8
        case 0x65: vk = 0x78; sc = 0x43; break; // F9
        case 0x6D: vk = 0x79; sc = 0x44; break; // F10
        case 0x67: vk = 0x7A; sc = 0x57; break; // F11
        case 0x6F: vk = 0x7B; sc = 0x58; break; // F12
        case 0x38: case 0x3C: vk = 0x10; sc = 0x2A; break; // Shift
        case 0x3B: case 0x3E: vk = 0x11; sc = 0x1D; break; // Control
        case 0x3A: case 0x3D: vk = 0x12; sc = 0x38; break; // Option/Alt
        case 0x39: vk = 0x14; sc = 0x3A; break; // Caps Lock
        case 0x75: vk = 0x2E; sc = 0x53; break; // Forward Delete -> VK_DELETE
        case 0x73: vk = 0x24; sc = 0x47; break; // Home
        case 0x77: vk = 0x23; sc = 0x4F; break; // End
        case 0x74: vk = 0x21; sc = 0x49; break; // Page Up
        case 0x79: vk = 0x22; sc = 0x51; break; // Page Down
        case 0x72: vk = 0x2D; sc = 0x52; break; // Help/Insert -> VK_INSERT
        case 0x52: vk = 0x60; sc = 0x52; break; // Numpad 0
        case 0x53: vk = 0x61; sc = 0x4F; break; // Numpad 1
        case 0x54: vk = 0x62; sc = 0x50; break; // Numpad 2
        case 0x55: vk = 0x63; sc = 0x51; break; // Numpad 3
        case 0x56: vk = 0x64; sc = 0x4B; break; // Numpad 4
        case 0x57: vk = 0x65; sc = 0x4C; break; // Numpad 5
        case 0x58: vk = 0x66; sc = 0x4D; break; // Numpad 6
        case 0x59: vk = 0x67; sc = 0x47; break; // Numpad 7
        case 0x5B: vk = 0x68; sc = 0x48; break; // Numpad 8
        case 0x5C: vk = 0x69; sc = 0x49; break; // Numpad 9
        case 0x41: vk = 0x6E; sc = 0x53; break; // Numpad .
        case 0x43: vk = 0x6A; sc = 0x37; break; // Numpad *
        case 0x45: vk = 0x6B; sc = 0x4E; break; // Numpad +
        case 0x4E: vk = 0x6D; sc = 0x4A; break; // Numpad -
        case 0x4B: vk = 0x6F; sc = 0x35; break; // Numpad /
        case 0x4C: vk = 0x0D; sc = 0x1C; break; // Numpad Enter
        case 0x47: vk = 0x90; sc = 0x45; break; // Numpad Clear -> VK_NUMLOCK
        case 0x51: vk = 0xBB; sc = 0x0D; break; // Numpad = (map to VK_OEM_PLUS)
        default: break;
    }
    if (out_scancode) *out_scancode = sc;
    return vk;
}

static std::shared_ptr<Bo3MacWindow> as_win(uint64_t hwnd);

@implementation Bo3MetalView

- (instancetype)initWithFrame:(NSRect)frameRect bo3Hwnd:(uint64_t)hwnd {
    self = [super initWithFrame:frameRect];
    if (self) {
        _bo3Hwnd = hwnd;
        self.wantsLayer = YES;
        _metalLayer = [CAMetalLayer layer];
        _metalLayer.device = MTLCreateSystemDefaultDevice();
        _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        _metalLayer.framebufferOnly = NO;
        _metalLayer.opaque = YES;
        _metalLayer.maximumDrawableCount = 3;
        _metalLayer.displaySyncEnabled = NO;
        _metalLayer.drawableSize = CGSizeMake(frameRect.size.width, frameRect.size.height);
        _metalLayer.contentsScale = 1.0; // 1:1 with requested Win32 client pixel dimensions
        self.layer = _metalLayer;
        // Note: NSWindow already sets acceptsMouseMovedEvents=YES; adding an NSTrackingArea with
        // NSTrackingMouseMoved would deliver every mouseMoved: event TWICE (doubling sensitivity!).
    }
    return self;
}

- (CALayer *)makeBackingLayer {
    return _metalLayer ?: [CAMetalLayer layer];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }

- (uint64_t)hwndVal {
    return _bo3Hwnd;
}

- (uint64_t)mouseLParam:(NSEvent *)ev {
    int32_t cw = 1280, ch = 720;
    get_coord_origin_and_size(_bo3Hwnd, nullptr, nullptr, &cw, &ch);
    int32_t x, y;
    if (g_cursor_hidden) {
        // When CGAssociateMouseAndMouseCursorPosition(false) is active, ev.locationInWindow is frozen;
        // preserve our delta-tracked/recentered client position instead of clobbering it.
        x = g_mouse_x.load(std::memory_order_relaxed);
        y = g_mouse_y.load(std::memory_order_relaxed);
    } else {
        NSPoint p = [self convertPoint:ev.locationInWindow fromView:nil];
        double bw = self.bounds.size.width;
        double bh = self.bounds.size.height;
        double sx = (bw > 0.5) ? (p.x * (double)cw / bw) : p.x;
        double sy = (bh > 0.5) ? ((bh - p.y) * (double)ch / bh) : (bh - p.y);
        x = (int32_t)llround(sx);
        y = (int32_t)llround(sy);
        if (x < 0) x = 0;
        else if (x >= cw) x = cw - 1;
        if (y < 0) y = 0;
        else if (y >= ch) y = ch - 1;
        g_mouse_x.store(x, std::memory_order_relaxed);
        g_mouse_y.store(y, std::memory_order_relaxed);
    }
    return ((uint64_t)(uint16_t)y << 16) | (uint16_t)x;
}

- (uint64_t)mouseWParam {
    uint32_t b = g_mouse_buttons.load(std::memory_order_relaxed);
    uint64_t w = 0;
    if (b & 1)  w |= 0x0001; // MK_LBUTTON
    if (b & 2)  w |= 0x0002; // MK_RBUTTON
    if (b & 4)  w |= 0x0010; // MK_MBUTTON
    if (b & 8)  w |= 0x0020; // MK_XBUTTON1
    if (b & 16) w |= 0x0040; // MK_XBUTTON2
    return w;
}

static double mouse_scale_factor() {
    static double scale = 1.0;
    static std::once_flag once;
    std::call_once(once, []() {
        const char *env = getenv("BO3ARM_MOUSE_SCALE");
        if (env && env[0]) {
            double v = strtod(env, nullptr);
            if (v > 0.01 && v <= 10.0) scale = v;
        }
    });
    return scale;
}

- (void)mouseMoved:(NSEvent *)ev {
    if (bo3_ui_settings_panel_open()) return;
    if (![self.window isKeyWindow]) return;
    ensure_cursor_capture_on_event(self.window, ev, true);

    int32_t old_x = g_mouse_x.load(std::memory_order_relaxed);
    int32_t old_y = g_mouse_y.load(std::memory_order_relaxed);
    uint64_t lp = [self mouseLParam:ev];
    int32_t new_x = g_mouse_x.load(std::memory_order_relaxed);
    int32_t new_y = g_mouse_y.load(std::memory_order_relaxed);

    // Prefer raw integer CoreGraphics deltas (matches Windows RAWMOUSE / Aspyr IOHID counts without
    // macOS pointer acceleration); fall back to fractional ev.deltaX/Y for sub-pixel trackpads.
    double dx_d = (double)ev.deltaX;
    double dy_d = (double)ev.deltaY;
    CGEventRef cgev = ev.CGEvent;
    if (cgev) {
        int64_t cgx = CGEventGetIntegerValueField(cgev, kCGMouseEventDeltaX);
        int64_t cgy = CGEventGetIntegerValueField(cgev, kCGMouseEventDeltaY);
        if (cgx != 0 || cgy != 0) {
            dx_d = (double)cgx;
            dy_d = (double)cgy;
        }
    }

    // Drop any single-event synthetic warp jump right after entering cursor capture.
    if (g_cursor_hidden && g_capture_grace_until_ms != 0) {
        int32_t rem = (int32_t)(g_capture_grace_until_ms - monotonic_ms());
        if (rem > 0) {
            if (std::abs(dx_d) > 200.0 || std::abs(dy_d) > 200.0) {
                return;
            }
        } else {
            g_capture_grace_until_ms = 0;
        }
    }

    const double sc = mouse_scale_factor();
    g_mouse_accum_x += dx_d * sc;
    g_mouse_accum_y += dy_d * sc;
    int32_t idx = (int32_t)trunc(g_mouse_accum_x);
    int32_t idy = (int32_t)trunc(g_mouse_accum_y);
    if (idx != 0 || idy != 0) {
        g_mouse_accum_x -= (double)idx;
        g_mouse_accum_y -= (double)idy;
    } else if (!g_cursor_hidden) {
        // In visible-cursor menu mode only: if a synthetic/trackpad event moved the OS pointer
        // without reporting deltaX/Y, emit a safe +/-1 wake nudge using OS-only coords (never
        // diffed against SetCursorPos / IN_RecenterMouse coords!).
        if (g_last_os_valid && (new_x != g_last_os_x || new_y != g_last_os_y)) {
            if (new_x != g_last_os_x) idx = (new_x > g_last_os_x) ? 1 : -1;
            if (new_y != g_last_os_y) idy = (new_y > g_last_os_y) ? 1 : -1;
        }
    }
    if (!g_cursor_hidden) {
        g_last_os_x = new_x;
        g_last_os_y = new_y;
        g_last_os_valid = true;
    }

    if (idx != 0 || idy != 0) {
        if (g_cursor_hidden) {
            int32_t cw = 1280, ch = 720;
            get_coord_origin_and_size(_bo3Hwnd, nullptr, nullptr, &cw, &ch);
            int32_t nx = std::max(0, std::min(cw - 1, old_x + idx));
            int32_t ny = std::max(0, std::min(ch - 1, old_y + idy));
            g_mouse_x.store(nx, std::memory_order_relaxed);
            g_mouse_y.store(ny, std::memory_order_relaxed);
            lp = ((uint64_t)(uint16_t)ny << 16) | (uint16_t)nx;
        }
        push_raw_mouse(idx, idy, 0, 0);
    }
    push_msg([self hwndVal], 0x0200 /* WM_MOUSEMOVE */, [self mouseWParam], lp);
}
- (void)mouseDragged:(NSEvent *)ev { [self mouseMoved:ev]; }
- (void)rightMouseDragged:(NSEvent *)ev { [self mouseMoved:ev]; }
- (void)otherMouseDragged:(NSEvent *)ev { [self mouseMoved:ev]; }

- (void)resetCursorRects {
    [super resetCursorRects];
    if (g_cursor_hidden) {
        [self addCursorRect:self.bounds cursor:blank_cursor_main_thread()];
    }
}
- (void)cursorUpdate:(NSEvent *)ev {
    (void)ev;
    if (g_cursor_hidden && g_want_cursor_hidden && !bo3_ui_settings_panel_open()) {
        [blank_cursor_main_thread() set];
    } else {
        [[NSCursor arrowCursor] set];
    }
}

- (void)mouseDown:(NSEvent *)ev {
    if (bo3_ui_settings_panel_open()) return;
    ensure_cursor_capture_on_event(self.window, ev, true);
    g_mouse_buttons.fetch_or(1, std::memory_order_relaxed);
    g_vk_down[0x01].store(1, std::memory_order_relaxed);
    push_msg([self hwndVal], 0x0201 /* WM_LBUTTONDOWN */, [self mouseWParam], [self mouseLParam:ev]);
}
- (void)mouseUp:(NSEvent *)ev {
    if (bo3_ui_settings_panel_open()) return;
    g_mouse_buttons.fetch_and(~1u, std::memory_order_relaxed);
    g_vk_down[0x01].store(0, std::memory_order_relaxed);
    push_msg([self hwndVal], 0x0202 /* WM_LBUTTONUP */, [self mouseWParam], [self mouseLParam:ev]);
}
- (void)rightMouseDown:(NSEvent *)ev {
    if (bo3_ui_settings_panel_open()) return;
    ensure_cursor_capture_on_event(self.window, ev, true);
    g_mouse_buttons.fetch_or(2, std::memory_order_relaxed);
    g_vk_down[0x02].store(1, std::memory_order_relaxed);
    push_msg([self hwndVal], 0x0204 /* WM_RBUTTONDOWN */, [self mouseWParam], [self mouseLParam:ev]);
}
- (void)rightMouseUp:(NSEvent *)ev {
    if (bo3_ui_settings_panel_open()) return;
    g_mouse_buttons.fetch_and(~2u, std::memory_order_relaxed);
    g_vk_down[0x02].store(0, std::memory_order_relaxed);
    push_msg([self hwndVal], 0x0205 /* WM_RBUTTONUP */, [self mouseWParam], [self mouseLParam:ev]);
}
- (void)otherMouseDown:(NSEvent *)ev {
    if (bo3_ui_settings_panel_open()) return;
    ensure_cursor_capture_on_event(self.window, ev, true);
    NSInteger bn = ev.buttonNumber;
    uint64_t lp = [self mouseLParam:ev];
    if (bn == 2) {
        g_mouse_buttons.fetch_or(4, std::memory_order_relaxed);
        g_vk_down[0x04].store(1, std::memory_order_relaxed);
        push_msg([self hwndVal], 0x0207 /* WM_MBUTTONDOWN */, [self mouseWParam], lp);
    } else if (bn == 3) {
        g_mouse_buttons.fetch_or(8, std::memory_order_relaxed);
        g_vk_down[0x05].store(1, std::memory_order_relaxed);
        push_msg([self hwndVal], 0x020B /* WM_XBUTTONDOWN */, (1ULL << 16) | [self mouseWParam], lp);
    } else if (bn == 4) {
        g_mouse_buttons.fetch_or(16, std::memory_order_relaxed);
        g_vk_down[0x06].store(1, std::memory_order_relaxed);
        push_msg([self hwndVal], 0x020B /* WM_XBUTTONDOWN */, (2ULL << 16) | [self mouseWParam], lp);
    }
}
- (void)otherMouseUp:(NSEvent *)ev {
    NSInteger bn = ev.buttonNumber;
    uint64_t lp = [self mouseLParam:ev];
    if (bn == 2) {
        g_mouse_buttons.fetch_and(~4u, std::memory_order_relaxed);
        g_vk_down[0x04].store(0, std::memory_order_relaxed);
        push_msg([self hwndVal], 0x0208 /* WM_MBUTTONUP */, [self mouseWParam], lp);
    } else if (bn == 3) {
        g_mouse_buttons.fetch_and(~8u, std::memory_order_relaxed);
        g_vk_down[0x05].store(0, std::memory_order_relaxed);
        push_msg([self hwndVal], 0x020C /* WM_XBUTTONUP */, (1ULL << 16) | [self mouseWParam], lp);
    } else if (bn == 4) {
        g_mouse_buttons.fetch_and(~16u, std::memory_order_relaxed);
        g_vk_down[0x06].store(0, std::memory_order_relaxed);
        push_msg([self hwndVal], 0x020C /* WM_XBUTTONUP */, (2ULL << 16) | [self mouseWParam], lp);
    }
}
- (void)scrollWheel:(NSEvent *)ev {
    if (bo3_ui_settings_panel_open()) return;
    ensure_cursor_capture_on_event(self.window, ev, true);
    double raw = ev.hasPreciseScrollingDeltas ? (ev.scrollingDeltaY * 12.0) : (ev.scrollingDeltaY * 120.0);
    int32_t clamped = (int32_t)std::max(-32768.0, std::min(32767.0, raw));
    int16_t delta = (int16_t)clamped;
    if (delta != 0) {
        push_msg([self hwndVal], 0x020A /* WM_MOUSEWHEEL */, ((uint64_t)(uint16_t)delta << 16) | [self mouseWParam], [self mouseLParam:ev]);
        push_raw_mouse(0, 0, 0x0400 /* RI_MOUSE_WHEEL */, (uint16_t)delta);
    }
}

static inline bool is_extended_vk(uint16_t vk) {
    return vk == 0x21 || vk == 0x22 || vk == 0x23 || vk == 0x24 ||
           vk == 0x25 || vk == 0x26 || vk == 0x27 || vk == 0x28 ||
           vk == 0x2D || vk == 0x2E || vk == 0x6F;
}

static inline bool mac_keycode_is_extended(uint16_t keycode, uint16_t vk) {
    if (keycode == 0x4C || keycode == 0x4B || keycode == 0x3E || keycode == 0x3D) return true;
    return is_extended_vk(vk);
}

- (void)keyDown:(NSEvent *)ev {
    // Intercept F10 (0x6D) or Cmd+, (0x2B) to toggle the live in-game Apple Silicon settings overlay
    if (ev.keyCode == 0x6D ||
        ((ev.modifierFlags & NSEventModifierFlagCommand) && ev.keyCode == 0x2B)) {
        if (!ev.isARepeat) bo3_ui_toggle_settings_panel();
        return;
    }
    if (bo3_ui_settings_panel_open()) return;
    uint8_t sc = 0;
    uint16_t vk = mac_keycode_to_vk(ev.keyCode, &sc);
    if (vk < 256) g_vk_down[vk].store(1, std::memory_order_relaxed);
    uint64_t lp = 1ULL | ((uint64_t)sc << 16)
                | (mac_keycode_is_extended(ev.keyCode, vk) ? (1ULL << 24) : 0ULL)
                | (ev.isARepeat ? (1ULL << 30) : 0ULL);
    if (vk) push_msg([self hwndVal], 0x0100 /* WM_KEYDOWN */, vk, lp);
    NSString *chars = ev.characters;
    for (NSUInteger i = 0; i < chars.length; i++) {
        unichar ch = [chars characterAtIndex:i];
        if (ch >= 0x20 && ch < 0x7F) {
            push_msg([self hwndVal], 0x0102 /* WM_CHAR */, ch, lp);
        }
    }
}

- (void)keyUp:(NSEvent *)ev {
    if (ev.keyCode == 0x6D ||
        ((ev.modifierFlags & NSEventModifierFlagCommand) && ev.keyCode == 0x2B)) {
        return;
    }
    if (bo3_ui_settings_panel_open()) return;
    uint8_t sc = 0;
    uint16_t vk = mac_keycode_to_vk(ev.keyCode, &sc);
    if (vk < 256) g_vk_down[vk].store(0, std::memory_order_relaxed);
    uint64_t lp = 1ULL | ((uint64_t)sc << 16)
                | (mac_keycode_is_extended(ev.keyCode, vk) ? (1ULL << 24) : 0ULL)
                | (1ULL << 30) | (1ULL << 31);
    if (vk) push_msg([self hwndVal], 0x0101 /* WM_KEYUP */, vk, lp);
}

- (void)flagsChanged:(NSEvent *)ev {
    NSEventModifierFlags fl = ev.modifierFlags;
    auto sync_mod = [&](uint16_t vk, uint8_t sc, bool down) {
        uint8_t prev = g_vk_down[vk].exchange(down ? 1 : 0, std::memory_order_relaxed);
        if (prev != (down ? 1 : 0)) {
            uint64_t lp = 1ULL | ((uint64_t)sc << 16) | (down ? 0ULL : ((1ULL << 30) | (1ULL << 31)));
            push_msg([self hwndVal], down ? 0x0100 : 0x0101, vk, lp);
        }
    };
    sync_mod(0x10, 0x2A, (fl & NSEventModifierFlagShift) != 0);
    sync_mod(0x11, 0x1D, (fl & NSEventModifierFlagControl) != 0);
    sync_mod(0x12, 0x38, (fl & NSEventModifierFlagOption) != 0);
    // Caps Lock only arrives via flagsChanged on macOS (never keyDown/keyUp)
    if (ev.keyCode == 0x39) {
        sync_mod(0x14, 0x3A, (fl & NSEventModifierFlagCapsLock) != 0);
    }
}

static void update_presentation_options_main_thread(uint64_t hwnd, bool active) {
    bool want_fs = false;
    if (active) {
        auto bw = as_win(hwnd);
        if (bw) {
            std::lock_guard<std::mutex> lk(g_win_mtx);
            want_fs = (bw->is_fullscreen || bw->is_borderless);
        }
    }
    NSApplicationPresentationOptions opts = want_fs
        ? (NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar)
        : NSApplicationPresentationDefault;
    if ([NSApp presentationOptions] != opts) {
        [NSApp setPresentationOptions:opts];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    g_drift_recovery_paused = false;
    g_recapture_burst_count = 0;
    update_presentation_options_main_thread(_bo3Hwnd, true);
    if (g_want_cursor_hidden && main_window_can_capture(nullptr, nullptr)) {
        apply_cursor_capture_main_thread(true, true, !g_cursor_hidden);
    }
    push_msg([self hwndVal], 0x0006 /* WM_ACTIVATE */, 1, 0);
    push_msg([self hwndVal], 0x0007 /* WM_SETFOCUS */, 0, 0);
}
- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification;
    if (bo3_ui_settings_panel_open()) {
        // Keep game active and fullscreen menu bar/Dock hidden while our own F10 settings overlay has key.
        apply_cursor_capture_main_thread(false, true, false);
        clear_all_held_inputs();
        return;
    }
    apply_cursor_capture_main_thread(false, true, false);
    update_presentation_options_main_thread(_bo3Hwnd, false);
    clear_all_held_inputs();
    push_msg([self hwndVal], 0x0006 /* WM_ACTIVATE */, 0, 0);
    push_msg([self hwndVal], 0x0008 /* WM_KILLFOCUS */, 0, 0);
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    apply_cursor_capture_main_thread(false, true, false);
    update_presentation_options_main_thread(_bo3Hwnd, false);
    clear_all_held_inputs();
    push_msg([self hwndVal], 0x0010 /* WM_CLOSE */, 0, 0);
}
- (void)windowDidChangeScreen:(NSNotification *)notification {
    (void)notification;
    NSScreen *scr = self.window.screen;
    if (scr) {
        NSRect f = scr.frame;
        if (f.size.width >= 800 && f.size.height >= 600) {
            g_screen_w.store((int32_t)f.size.width, std::memory_order_relaxed);
            g_screen_h.store((int32_t)f.size.height, std::memory_order_relaxed);
        }
    }
}
- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    if ([self.window isKindOfClass:[Bo3MacNSWindow class]] &&
        ((Bo3MacNSWindow *)self.window).bo3InModeTransition) {
        return;
    }
    NSRect r = self.bounds;
    int32_t nw = (int32_t)r.size.width;
    int32_t nh = (int32_t)r.size.height;
    auto bw = as_win(_bo3Hwnd);
    if (bw && nw > 0 && nh > 0) {
        int32_t rw = 0, rh = 0;
        {
            std::lock_guard<std::mutex> lk(g_win_mtx);
            bw->w = nw;
            bw->h = nh;
            if (!bw->is_fullscreen && !bw->is_borderless) {
                bw->windowed_w = nw;
                bw->windowed_h = nh;
            }
            rw = bw->render_w;
            rh = bw->render_h;
            if (bw->drawable_w > 0 && bw->drawable_h > 0) {
                rw = bw->drawable_w;
                rh = bw->drawable_h;
            }
        }
        if (rw <= 0 || rh <= 0) {
            os_unfair_lock_lock(&g_metal_layer_lock);
            _metalLayer.drawableSize = CGSizeMake(nw, nh);
            os_unfair_lock_unlock(&g_metal_layer_lock);
        }
        push_msg([self hwndVal], 0x0005 /* WM_SIZE */, 0, ((uint64_t)(uint16_t)nh << 16) | (uint16_t)nw);
        bo3_ui_sync_layout();
    }
}
- (void)windowDidMove:(NSNotification *)notification {
    (void)notification;
    bo3_ui_sync_layout();
}
@end

void bo3_win_restore_desktop_sync(void) {
    auto restore = ^{
        @autoreleasepool {
            g_want_cursor_hidden = false;
            apply_cursor_capture_main_thread(false, true, false);
            if ([NSApp presentationOptions] != NSApplicationPresentationDefault) {
                [NSApp setPresentationOptions:NSApplicationPresentationDefault];
            }
        }
    };
    if ([NSThread isMainThread]) {
        restore();
    } else if (NSApp != nil) {
        dispatch_sync(dispatch_get_main_queue(), restore);
    }
}

// Thread 0 AppKit runner + guest-main pthread launcher
struct GuestLaunchArgs {
    int (*fn)(int, char **);
    int argc;
    char **argv;
};

static void *guest_main_pthread(void *arg) {
    GuestLaunchArgs *a = (GuestLaunchArgs *)arg;
    int rc = a->fn(a->argc, a->argv);
    fprintf(stderr, "[bo3_mac] guest main returned %d, terminating app\n", rc);
    fflush(stderr);
    bo3_win_restore_desktop_sync();
    exit(rc);
}

@interface Bo3MenuActions : NSObject
@end
@implementation Bo3MenuActions
- (void)openSettings:(id)sender { (void)sender; bo3_ui_toggle_settings_panel(); }
- (void)quitApp:(id)sender {
    (void)sender;
    bo3_win_restore_desktop_sync();
    exit(0);
}
- (void)appDidBecomeActive:(NSNotification *)n {
    (void)n;
    g_drift_recovery_paused = false;
    g_recapture_burst_count = 0;
    if (g_want_cursor_hidden && main_window_can_capture(nullptr, nullptr)) {
        apply_cursor_capture_main_thread(true, true, !g_cursor_hidden);
    }
    // Re-assert hide/association once more after Space/Cmd-Tab animation settles in WindowServer
    // (without re-warping if already captured, avoiding post-warp input stutter).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (g_want_cursor_hidden && main_window_can_capture(nullptr, nullptr)) {
            apply_cursor_capture_main_thread(true, true, false);
        }
    });
}
- (void)appWillResignActive:(NSNotification *)n {
    (void)n;
    // Release while still foreground so CGAssociateMouseAndMouseCursorPosition(true) always succeeds.
    apply_cursor_capture_main_thread(false, true, false);
    clear_all_held_inputs();
}
@end
static Bo3MenuActions *g_menu_actions = nil;

static void on_settings_panel_visibility(bool open) {
    // Runs on the AppKit main thread: release FPS mouse capture while overlay is open and
    // restore it seamlessly when dismissed (only if app is active and game window is key).
    if (open) {
        clear_all_held_inputs();
        apply_cursor_capture_main_thread(false, true, false);
    } else if (g_want_cursor_hidden && main_window_can_capture(nullptr, nullptr)) {
        g_drift_recovery_paused = false;
        g_recapture_burst_count = 0;
        apply_cursor_capture_main_thread(true, true, true);
    }
}

int bo3_mac_run_with_guest(int (*guest_fn)(int, char **), int argc, char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        g_menu_actions = [[Bo3MenuActions alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:g_menu_actions
                                                 selector:@selector(appDidBecomeActive:)
                                                     name:NSApplicationDidBecomeActiveNotification
                                                   object:app];
        [[NSNotificationCenter defaultCenter] addObserver:g_menu_actions
                                                 selector:@selector(appWillResignActive:)
                                                     name:NSApplicationWillResignActiveNotification
                                                   object:app];
        NSMenu *menubar = [[NSMenu alloc] init];
        NSMenuItem *appItem = [[NSMenuItem alloc] init];
        [menubar addItem:appItem];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"BO3 Mac"];
        NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:@"Settings… (F10)"
                                                           action:@selector(openSettings:)
                                                    keyEquivalent:@","];
        prefsItem.target = g_menu_actions;
        [appMenu addItem:prefsItem];
        [appMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Call of Duty: Black Ops III"
                                                          action:@selector(quitApp:)
                                                   keyEquivalent:@"q"];
        quitItem.target = g_menu_actions;
        [appMenu addItem:quitItem];
        appItem.submenu = appMenu;
        [app setMainMenu:menubar];
        bo3_ui_set_panel_visibility_callback(on_settings_panel_visibility);
        [app finishLaunching];

        // Seed physical screen geometry on the main thread BEFORE launching guest_main_pthread so
        // early settings/screen queries from guest threads never need dispatch_sync(main_queue).
        {
            NSScreen *scr = [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
            if (scr) {
                NSRect f = scr.frame;
                if (f.size.width >= 800 && f.size.height >= 600) {
                    g_screen_w.store((int32_t)f.size.width, std::memory_order_relaxed);
                    g_screen_h.store((int32_t)f.size.height, std::memory_order_relaxed);
                }
            }
        }

        // Launch guest engine on dedicated pthread with 16 MiB native stack
        GuestLaunchArgs *args = new GuestLaunchArgs{guest_fn, argc, argv};
        pthread_t th;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 16 * 1024 * 1024);
        if (pthread_create(&th, &attr, guest_main_pthread, args) != 0) {
            perror("pthread_create guest_main");
            return 1;
        }
        pthread_attr_destroy(&attr);
        pthread_detach(th);

        // Run AppKit event loop on thread 0
        [app run];
    }
    return 0;
}

static NSString *cstr_to_nsstring(const char *s, NSString *fallback) {
    if (!s || !s[0]) return fallback;
    NSString *ns = [NSString stringWithUTF8String:s];
    if (!ns) ns = [NSString stringWithCString:s encoding:NSWindowsCP1252StringEncoding];
    return ns ?: fallback;
}

static std::shared_ptr<Bo3MacWindow> as_win(uint64_t hwnd) {
    if (!hwnd || hwnd == 0xfffffffffffffffdULL) return nullptr;
    std::lock_guard<std::mutex> lk(g_win_mtx);
    auto it = g_live_windows.find(hwnd);
    if (it == g_live_windows.end()) return nullptr;
    auto &w = it->second;
    return (w && w->magic == BO3_MAC_HWND_MAGIC) ? w : nullptr;
}

void bo3_win_register_class(const char *class_name, uint64_t wndproc_va) {
    std::lock_guard<std::mutex> lk(g_win_mtx);
    g_last_registered_wndproc = wndproc_va;
    if (class_name && class_name[0]) {
        g_class_wndprocs[std::string(class_name)] = wndproc_va;
        fprintf(stderr, "[win32] RegisterClass('%s') -> wndproc=0x%llx\n",
                class_name, (unsigned long long)wndproc_va);
        fflush(stderr);
    }
}

uint64_t bo3_win_call_wndproc(GuestContext *ctx, uint64_t rsp,
                              uint64_t wndproc_va, uint64_t hwnd,
                              uint32_t msg, uint64_t wparam, uint64_t lparam) {
    if (!wndproc_va || !ctx) return 0;
    GuestFn fn = bo3_resolve(wndproc_va, ctx);
    // Respect x86_64 128-byte red zone and keep 16-byte alignment before pushed return PC
    uint64_t call_sp = ((rsp - 144ULL) & ~15ULL) - 8ULL;
    *(uint64_t *)call_sp = 0;
    uint64_t saved_pc = ctx->last_pc;
    ctx->last_pc = wndproc_va;
    GuestRet r = fn(ctx, call_sp, hwnd, (uint64_t)msg, wparam, lparam, 0, 0,
                    guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
                    guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    ctx->last_pc = saved_pc;
    return r.rax_rdx[0];
}

static constexpr NSWindowStyleMask kBo3WindowedStyleMask =
    NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

static void apply_window_mode_main_thread(uint64_t hwnd) {
    Bo3MacNSWindow *win = nil;
    Bo3MetalView *view = nil;
    CAMetalLayer *layer = nil;
    bool want_fs = false;
    int32_t win_w = 1280, win_h = 720;
    int32_t rw = 0, rh = 0;
    int32_t dw = 0, dh = 0;
    std::string tstr;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        auto it = g_live_windows.find(hwnd);
        if (it == g_live_windows.end() || !it->second || it->second->magic != BO3_MAC_HWND_MAGIC) return;
        auto &bw = it->second;
        win = bw->ns_window;
        view = bw->metal_view;
        layer = bw->metal_layer;
        want_fs = (bw->is_fullscreen || bw->is_borderless);
        win_w = (bw->windowed_w > 0 && bw->windowed_w < 16384) ? bw->windowed_w : 1280;
        win_h = (bw->windowed_h > 0 && bw->windowed_h < 16384) ? bw->windowed_h : 720;
        rw = bw->render_w;
        rh = bw->render_h;
        dw = (bw->drawable_w > 0 && bw->drawable_h > 0) ? bw->drawable_w : rw;
        dh = (bw->drawable_w > 0 && bw->drawable_h > 0) ? bw->drawable_h : rh;
        tstr = bw->title[0] ? bw->title : "Call of Duty: Black Ops III (ARM64 Native Metal)";
    }
    if (!win) return;

    @autoreleasepool {
        NSScreen *scr = win.screen ?: [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
        if (scr && scr.frame.size.width >= 800 && scr.frame.size.height >= 600) {
            g_screen_w.store((int32_t)scr.frame.size.width, std::memory_order_relaxed);
            g_screen_h.store((int32_t)scr.frame.size.height, std::memory_order_relaxed);
        }
        BOOL app_active = [NSApp isActive];
        win.bo3InModeTransition = YES;
        if (want_fs) {
            win.bo3FullscreenFrame = YES;
            if (app_active) {
                [NSApp setPresentationOptions:(NSApplicationPresentationAutoHideDock |
                                               NSApplicationPresentationAutoHideMenuBar)];
            }
            if (win.styleMask != NSWindowStyleMaskBorderless) {
                [win setStyleMask:NSWindowStyleMaskBorderless];
            }
            [win setLevel:NSNormalWindowLevel];
            [win setHasShadow:NO];
            [win setOpaque:YES];
            [win setBackgroundColor:[NSColor blackColor]];
            [win setAcceptsMouseMovedEvents:YES];
            if (scr) {
                [win setFrame:scr.frame display:YES];
            }
            if (view) {
                [win makeFirstResponder:view];
            }
            if (app_active) {
                [win makeKeyAndOrderFront:nil];
            }
            if (layer && dw > 0 && dh > 0) {
                os_unfair_lock_lock(&g_metal_layer_lock);
                layer.drawableSize = CGSizeMake(dw, dh);
                os_unfair_lock_unlock(&g_metal_layer_lock);
            }
            if (scr) {
                std::lock_guard<std::mutex> lk(g_win_mtx);
                auto it = g_live_windows.find(hwnd);
                if (it != g_live_windows.end() && it->second) {
                    it->second->x = 0;
                    it->second->y = 0;
                    it->second->w = (int32_t)scr.frame.size.width;
                    it->second->h = (int32_t)scr.frame.size.height;
                }
            }
            fprintf(stderr, "[win32] Applied fullscreen/borderless mode on screen %.0fx%.0f (render %dx%d drawable %dx%d)\n",
                    scr ? scr.frame.size.width : 0.0, scr ? scr.frame.size.height : 0.0, rw, rh, dw, dh);
            fflush(stderr);
        } else {
            win.bo3FullscreenFrame = NO;
            [NSApp setPresentationOptions:NSApplicationPresentationDefault];
            if (win.styleMask != kBo3WindowedStyleMask) {
                [win setStyleMask:kBo3WindowedStyleMask];
            }
            [win setLevel:NSNormalWindowLevel];
            [win setHasShadow:YES];
            [win setTitle:cstr_to_nsstring(tstr.c_str(), @"Call of Duty: Black Ops III")];
            [win setBackgroundColor:[NSColor blackColor]];
            [win setAcceptsMouseMovedEvents:YES];
            if (scr) {
                // Center explicitly on the window's current screen rather than [win center] (mainScreen).
                NSRect vf = scr.visibleFrame;
                NSRect frame = [win frameRectForContentRect:NSMakeRect(0, 0, win_w, win_h)];
                frame.origin.x = vf.origin.x + floor((vf.size.width - frame.size.width) * 0.5);
                frame.origin.y = vf.origin.y + floor((vf.size.height - frame.size.height) * 0.5);
                [win setFrame:frame display:YES];
            } else {
                [win setContentSize:NSMakeSize(win_w, win_h)];
                [win center];
            }
            if (view) {
                [win makeFirstResponder:view];
            }
            if (app_active) {
                [win makeKeyAndOrderFront:nil];
            }
            if (layer) {
                os_unfair_lock_lock(&g_metal_layer_lock);
                if (dw > 0 && dh > 0) layer.drawableSize = CGSizeMake(dw, dh);
                else layer.drawableSize = CGSizeMake(win_w, win_h);
                os_unfair_lock_unlock(&g_metal_layer_lock);
            }
            {
                std::lock_guard<std::mutex> lk(g_win_mtx);
                auto it = g_live_windows.find(hwnd);
                if (it != g_live_windows.end() && it->second) {
                    it->second->w = win_w;
                    it->second->h = win_h;
                }
            }
            fprintf(stderr, "[win32] Applied windowed mode %dx%d (render %dx%d drawable %dx%d)\n", win_w, win_h, rw, rh, dw, dh);
            fflush(stderr);
        }
        win.bo3InModeTransition = NO;
        bo3_ui_sync_layout();
        // Changing styleMask / presentationOptions / frame can make WindowServer unhide or
        // re-associate the OS cursor even while g_cursor_hidden is true; re-check live active state
        // and re-assert capture with fresh warp coordinates.
        if (g_want_cursor_hidden && [NSApp isActive] && [win isKeyWindow] && !bo3_ui_settings_panel_open()) {
            g_drift_recovery_paused = false;
            g_recapture_burst_count = 0;
            apply_cursor_capture_main_thread(true, true, true);
        }
    }
}

static void schedule_window_mode_update(uint64_t hwnd) {
    if ([NSThread isMainThread]) {
        apply_window_mode_main_thread(hwnd);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            apply_window_mode_main_thread(hwnd);
        });
    }
}

uint64_t bo3_win_create(GuestContext *ctx, uint64_t rsp,
                        uint32_t ex_style, const char *class_name, const char *title,
                        uint32_t style, int32_t x, int32_t y, int32_t w, int32_t h,
                        uint64_t parent_hwnd) {
    auto bw = std::make_shared<Bo3MacWindow>();
    bw->magic = BO3_MAC_HWND_MAGIC;
    bw->exstyle = ex_style;
    bw->style = style;
    bw->x = (x == (int32_t)0x80000000) ? 100 : x;
    bw->y = (y == (int32_t)0x80000000) ? 100 : y;
    bw->w = (w > 0 && w < 16384) ? w : 1280;
    bw->h = (h > 0 && h < 16384) ? h : 720;
    bw->is_borderless = style_is_borderless(style);
    bw->windowed_w = bw->is_borderless ? 1280 : bw->w;
    bw->windowed_h = bw->is_borderless ? 720 : bw->h;
    bw->is_message_only = (parent_hwnd == 0xfffffffffffffffdULL); // HWND_MESSAGE = (HWND)-3
    if (title) strlcpy(bw->title, title, sizeof(bw->title));

    uint64_t hwnd = (uint64_t)(uintptr_t)bw.get();
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        g_live_windows[hwnd] = bw;
        if (class_name && class_name[0]) {
            auto it = g_class_wndprocs.find(std::string(class_name));
            if (it != g_class_wndprocs.end()) bw->wndproc_va = it->second;
        }
        if (!bw->wndproc_va) bw->wndproc_va = g_last_registered_wndproc;
    }

    bool is_child_or_aux = bw->is_message_only ||
                           (parent_hwnd != 0) ||
                           ((style & 0x40000000u) != 0) || // WS_CHILD
                           (class_name && (strcasecmp(class_name, "edit") == 0 ||
                                           strcasecmp(class_name, "button") == 0 ||
                                           strcasecmp(class_name, "static") == 0 ||
                                           strstr(class_name, "WinConsole") != nullptr));

    if (!is_child_or_aux) {
        int32_t cw = bw->w, ch = bw->h;
        bool start_fs = bw->is_borderless;
        std::string tstr = bw->title[0] ? bw->title : "Call of Duty: Black Ops III (ARM64 Native Metal)";
        __block Bo3MacNSWindow *created_win = nil;
        __block Bo3MetalView *created_view = nil;
        __block CAMetalLayer *created_layer = nil;
        __block int32_t created_w = cw;
        __block int32_t created_h = ch;
        auto create_block = ^{
            @autoreleasepool {
                NSScreen *scr = [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
                if (scr && scr.frame.size.width >= 800 && scr.frame.size.height >= 600) {
                    g_screen_w.store((int32_t)scr.frame.size.width, std::memory_order_relaxed);
                    g_screen_h.store((int32_t)scr.frame.size.height, std::memory_order_relaxed);
                }
                NSRect rect = (start_fs && scr) ? scr.frame : NSMakeRect(120, 120, cw, ch);
                NSWindowStyleMask mask = start_fs ? NSWindowStyleMaskBorderless : kBo3WindowedStyleMask;
                Bo3MacNSWindow *win = [[Bo3MacNSWindow alloc] initWithContentRect:rect
                                                                        styleMask:mask
                                                                          backing:NSBackingStoreBuffered
                                                                            defer:NO];
                win.bo3FullscreenFrame = start_fs ? YES : NO;
                [win setReleasedWhenClosed:NO];
                [win setTitle:cstr_to_nsstring(tstr.c_str(), @"Call of Duty: Black Ops III")];
                [win setAcceptsMouseMovedEvents:YES];
                [win setBackgroundColor:[NSColor blackColor]];
                [win setHasShadow:start_fs ? NO : YES];
                [win setOpaque:YES];
                Bo3MetalView *view = [[Bo3MetalView alloc] initWithFrame:NSMakeRect(0, 0, rect.size.width, rect.size.height) bo3Hwnd:hwnd];
                [win setContentView:view];
                [win setDelegate:view];
                [win makeFirstResponder:view];
                if (start_fs && scr) {
                    [NSApp setPresentationOptions:(NSApplicationPresentationAutoHideDock |
                                                   NSApplicationPresentationAutoHideMenuBar)];
                    [win setFrame:scr.frame display:YES];
                    created_w = (int32_t)scr.frame.size.width;
                    created_h = (int32_t)scr.frame.size.height;
                } else {
                    [win center];
                }
                [win makeKeyAndOrderFront:nil];
                [NSApp activateIgnoringOtherApps:YES];

                created_win = win;
                created_view = view;
                created_layer = view.metalLayer;
                bo3_ui_attach_game_window((__bridge void *)win);
            }
        };
        if ([NSThread isMainThread]) create_block();
        else dispatch_sync(dispatch_get_main_queue(), create_block);

        {
            std::lock_guard<std::mutex> lk(g_win_mtx);
            bw->ns_window = created_win;
            bw->metal_view = created_view;
            bw->metal_layer = created_layer;
            if (start_fs) {
                bw->x = 0;
                bw->y = 0;
                bw->w = created_w;
                bw->h = created_h;
            }
            g_main_window = bw;
        }
    }

    fprintf(stderr, "[win32] CreateWindowExA(class='%s', title='%s', %dx%d, msgOnly=%d) -> hwnd=%p wndproc=0x%llx\n",
            class_name ? class_name : "", bw->title, bw->w, bw->h,
            (int)bw->is_message_only, (void *)bw.get(), (unsigned long long)bw->wndproc_va);
    fflush(stderr);

    // Send synchronous WM_CREATE (0x0001) so BO3's WndProc sets DAT_1125dfc10 = hwnd!
    if (bw->wndproc_va) {
        bo3_win_call_wndproc(ctx, rsp, bw->wndproc_va, hwnd, 0x0001 /* WM_CREATE */, 0, 0);
    }
    if (!is_child_or_aux) {
        // Queue initial WM_ACTIVATE so engine knows window is active
        push_msg(hwnd, 0x0006 /* WM_ACTIVATE */, 1, 0);
    }
    return hwnd;
}

void bo3_win_destroy(uint64_t hwnd) {
    std::shared_ptr<Bo3MacWindow> bw;
    NSWindow *nsw = nil;
    Bo3MetalView *nsv = nil;
    bool was_main = false;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        auto it = g_live_windows.find(hwnd);
        if (it == g_live_windows.end()) return;
        bw = std::move(it->second);
        g_live_windows.erase(it);
        if (g_main_window == bw) {
            g_main_window.reset();
            was_main = true;
        }
        nsw = bw->ns_window;
        nsv = bw->metal_view;
        bw->ns_window = nil;
        bw->metal_view = nil;
        bw->metal_layer = nil;
        bw->magic = 0;
    }
    if (was_main) {
        g_last_show_req.store(-1, std::memory_order_release);
    }
    if (nsw || nsv || was_main) {
        auto teardown = ^{
            @autoreleasepool {
                if (was_main) {
                    // Clear g_want_cursor_hidden and detach gameWindow BEFORE closing the settings
                    // panel so its close handler never re-orders or recaptures a dying window.
                    g_want_cursor_hidden = false;
                    bo3_ui_attach_game_window(nullptr);
                    bo3_ui_close_settings_panel();
                    apply_cursor_capture_main_thread(false, true, false);
                    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
                    clear_all_held_inputs();
                }
                if (nsv) {
                    nsv.bo3Hwnd = 0;
                }
                if (nsw) {
                    [nsw setDelegate:nil];
                    [nsw orderOut:nil];
                    [nsw close];
                }
            }
        };
        if ([NSThread isMainThread]) teardown();
        else dispatch_async(dispatch_get_main_queue(), teardown);
    }
}

void bo3_win_show(uint64_t hwnd, int cmd_show) {
    NSWindow *win = nil;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        auto it = g_live_windows.find(hwnd);
        if (it == g_live_windows.end() || !it->second) return;
        win = it->second->ns_window;
    }
    if (!win) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (cmd_show == 0) [win orderOut:nil];
            else [win makeKeyAndOrderFront:nil];
        }
    });
}

void bo3_win_set_title(uint64_t hwnd, const char *title) {
    if (!title) return;
    NSWindow *win = nil;
    std::string t;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        auto it = g_live_windows.find(hwnd);
        if (it == g_live_windows.end() || !it->second) return;
        strlcpy(it->second->title, title, sizeof(it->second->title));
        t = it->second->title;
        win = it->second->ns_window;
    }
    if (win) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                [win setTitle:cstr_to_nsstring(t.c_str(), @"Call of Duty: Black Ops III")];
            }
        });
    }
}

size_t bo3_win_get_title(uint64_t hwnd, char *dst, size_t max_len) {
    if (!dst || max_len == 0) return 0;
    std::lock_guard<std::mutex> lk(g_win_mtx);
    auto it = g_live_windows.find(hwnd);
    if (it == g_live_windows.end() || !it->second) return 0;
    size_t n = strlcpy(dst, it->second->title, max_len);
    return n < max_len ? n : max_len - 1;
}

void bo3_win_move(uint64_t hwnd, int32_t x, int32_t y, int32_t w, int32_t h) {
    Bo3MacNSWindow *win = nil;
    CAMetalLayer *layer = nil;
    int32_t nw = 0, nh = 0;
    bool in_fs = false;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        auto it = g_live_windows.find(hwnd);
        if (it == g_live_windows.end() || !it->second) return;
        auto &bw = it->second;
        in_fs = (bw->is_fullscreen || bw->is_borderless);
        if (in_fs) {
            bw->x = 0;
            bw->y = 0;
            // Preserve requested windowed dimensions if ResizeTarget/SetWindowPos arrives
            // right before SetWindowLongA clears WS_CAPTION -> windowed transition.
            int32_t sw = g_screen_w.load(std::memory_order_relaxed);
            int32_t sh = g_screen_h.load(std::memory_order_relaxed);
            if (!bw->is_fullscreen && w > 0 && h > 0 && w < 16384 && h < 16384 &&
                (sw <= 0 || w < sw || h < sh)) {
                bw->windowed_w = w;
                bw->windowed_h = h;
            }
            return; // Keep fullscreen/borderless NSWindow filling screen.frame
        }
        bw->x = x; bw->y = y;
        if (w > 0 && w < 16384) { bw->w = w; bw->windowed_w = w; }
        if (h > 0 && h < 16384) { bw->h = h; bw->windowed_h = h; }
        if (bw->ns_window && w > 0 && h > 0) {
            win = bw->ns_window;
            layer = bw->metal_layer;
            nw = bw->w;
            nh = bw->h;
        }
    }
    if (win && nw > 0 && nh > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                if (win.bo3FullscreenFrame) return;
                [win setContentSize:NSMakeSize(nw, nh)];
                if (layer) {
                    bool has_override = false;
                    {
                        std::lock_guard<std::mutex> lk(g_win_mtx);
                        auto it = g_live_windows.find(hwnd);
                        if (it != g_live_windows.end() && it->second) {
                            auto &b = it->second;
                            has_override = (b->drawable_w > 0 && b->drawable_h > 0) ||
                                           (b->render_w > 0 && b->render_h > 0);
                        }
                    }
                    if (!has_override) {
                        os_unfair_lock_lock(&g_metal_layer_lock);
                        layer.drawableSize = CGSizeMake(nw, nh);
                        os_unfair_lock_unlock(&g_metal_layer_lock);
                    }
                }
            }
        });
    }
}

void bo3_win_set_pos(uint64_t hwnd, int32_t x, int32_t y, int32_t cx, int32_t cy, uint32_t flags) {
    int32_t cur_x = 0, cur_y = 0;
    bool in_fs = false;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        auto it = g_live_windows.find(hwnd);
        if (it == g_live_windows.end() || !it->second) return;
        in_fs = (it->second->is_fullscreen || it->second->is_borderless);
        if (!in_fs && !(flags & 2u)) { it->second->x = x; it->second->y = y; } // !SWP_NOMOVE
        cur_x = it->second->x;
        cur_y = it->second->y;
    }
    if (!in_fs && !(flags & 1u) && cx > 0 && cy > 0) { // !SWP_NOSIZE
        bo3_win_move(hwnd, cur_x, cur_y, cx, cy);
    }
}

void bo3_win_set_fullscreen(uint64_t hwnd, bool fullscreen) {
    uint64_t target_hwnd = 0;
    bool has_win = false;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        std::shared_ptr<Bo3MacWindow> bw;
        if (hwnd && hwnd != 0xfffffffffffffffdULL) {
            auto it = g_live_windows.find(hwnd);
            if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
        }
        if (!bw) bw = g_main_window;
        if (!bw) return;
        bw->is_fullscreen = fullscreen;
        // Synchronously update logical client bounds before the async AppKit transition finishes so
        // an immediate ResizeBuffers(0, 0) never reads stale fullscreen/windowed dimensions.
        if (bw->is_fullscreen || bw->is_borderless) {
            int32_t sw = g_screen_w.load(std::memory_order_relaxed);
            int32_t sh = g_screen_h.load(std::memory_order_relaxed);
            if (sw > 0 && sh > 0) { bw->w = sw; bw->h = sh; }
        } else if (bw->windowed_w > 0 && bw->windowed_h > 0) {
            bw->w = bw->windowed_w;
            bw->h = bw->windowed_h;
        }
        target_hwnd = (uint64_t)(uintptr_t)bw.get();
        has_win = (bw->ns_window != nil);
    }
    if (has_win && target_hwnd) {
        schedule_window_mode_update(target_hwnd);
    }
}

void bo3_win_set_render_size(uint64_t hwnd, int32_t w, int32_t h) {
    if (w < 0 || h < 0) return;
    std::lock_guard<std::mutex> lk(g_win_mtx);
    std::shared_ptr<Bo3MacWindow> bw;
    if (hwnd && hwnd != 0xfffffffffffffffdULL) {
        auto it = g_live_windows.find(hwnd);
        if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
    }
    if (!bw) bw = g_main_window;
    if (bw) {
        bw->render_w = w;
        bw->render_h = h;
    }
}

void bo3_win_set_drawable_size(uint64_t hwnd, int32_t w, int32_t h) {
    if (w < 0 || h < 0) return;
    std::lock_guard<std::mutex> lk(g_win_mtx);
    std::shared_ptr<Bo3MacWindow> bw;
    if (hwnd && hwnd != 0xfffffffffffffffdULL) {
        auto it = g_live_windows.find(hwnd);
        if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
    }
    if (!bw) bw = g_main_window;
    if (bw) {
        bw->drawable_w = w;
        bw->drawable_h = h;
    }
}

void bo3_win_set_swapchain_sizes(uint64_t hwnd, const void *owner, int32_t render_w, int32_t render_h,
                                 int32_t drawable_w, int32_t drawable_h) {
    if (render_w < 0 || render_h < 0 || drawable_w < 0 || drawable_h < 0) return;
    std::lock_guard<std::mutex> lk(g_win_mtx);
    std::shared_ptr<Bo3MacWindow> bw;
    if (hwnd && hwnd != 0xfffffffffffffffdULL) {
        auto it = g_live_windows.find(hwnd);
        if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
    }
    if (!bw) bw = g_main_window;
    if (bw) {
        bw->size_owner = owner;
        bw->render_w = render_w;
        bw->render_h = render_h;
        bw->drawable_w = drawable_w;
        bw->drawable_h = drawable_h;
    }
}

void bo3_win_update_swapchain_sizes(uint64_t hwnd, const void *owner, int32_t render_w, int32_t render_h,
                                    int32_t drawable_w, int32_t drawable_h) {
    if (render_w < 0 || render_h < 0 || drawable_w < 0 || drawable_h < 0) return;
    std::lock_guard<std::mutex> lk(g_win_mtx);
    std::shared_ptr<Bo3MacWindow> bw;
    if (hwnd && hwnd != 0xfffffffffffffffdULL) {
        auto it = g_live_windows.find(hwnd);
        if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
    }
    if (!bw) bw = g_main_window;
    if (bw && (bw->size_owner == owner || bw->size_owner == nullptr)) {
        bw->size_owner = owner;
        bw->render_w = render_w;
        bw->render_h = render_h;
        bw->drawable_w = drawable_w;
        bw->drawable_h = drawable_h;
    }
}

void bo3_win_clear_swapchain_sizes(uint64_t hwnd, const void *owner) {
    std::lock_guard<std::mutex> lk(g_win_mtx);
    std::shared_ptr<Bo3MacWindow> bw;
    if (hwnd && hwnd != 0xfffffffffffffffdULL) {
        auto it = g_live_windows.find(hwnd);
        if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
    }
    if (!bw) bw = g_main_window;
    if (bw && bw->size_owner == owner) {
        bw->size_owner = nullptr;
        bw->render_w = 0;
        bw->render_h = 0;
        bw->drawable_w = 0;
        bw->drawable_h = 0;
    }
}

bool bo3_win_get_drawable_size(uint64_t hwnd, int32_t *out_w, int32_t *out_h) {
    std::lock_guard<std::mutex> lk(g_win_mtx);
    std::shared_ptr<Bo3MacWindow> bw;
    if (hwnd && hwnd != 0xfffffffffffffffdULL) {
        auto it = g_live_windows.find(hwnd);
        if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
    }
    if (!bw) bw = g_main_window;
    if (!bw || bw->drawable_w <= 0 || bw->drawable_h <= 0) return false;
    if (out_w) *out_w = bw->drawable_w;
    if (out_h) *out_h = bw->drawable_h;
    return true;
}

bool bo3_win_get_native_client_size(uint64_t hwnd, int32_t *out_w, int32_t *out_h) {
    std::lock_guard<std::mutex> lk(g_win_mtx);
    std::shared_ptr<Bo3MacWindow> bw;
    if (hwnd && hwnd != 0xfffffffffffffffdULL) {
        auto it = g_live_windows.find(hwnd);
        if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
    }
    if (!bw) bw = g_main_window;
    if (!bw) return false;
    int32_t w = bw->w;
    int32_t h = bw->h;
    if (!bw->is_fullscreen && !bw->is_borderless && bw->windowed_w > 0 && bw->windowed_h > 0) {
        w = bw->windowed_w;
        h = bw->windowed_h;
    }
    if (out_w) *out_w = (w > 0) ? w : 1280;
    if (out_h) *out_h = (h > 0) ? h : 720;
    return true;
}

void bo3_win_lock_layer(uint64_t hwnd) {
    (void)hwnd;
    os_unfair_lock_lock(&g_metal_layer_lock);
}

bool bo3_win_trylock_layer(uint64_t hwnd) {
    (void)hwnd;
    return os_unfair_lock_trylock(&g_metal_layer_lock);
}

void bo3_win_unlock_layer(uint64_t hwnd) {
    (void)hwnd;
    os_unfair_lock_unlock(&g_metal_layer_lock);
}

bool bo3_win_get_client_rect(uint64_t hwnd, int32_t out_rect[4]) {
    if (!out_rect) return false;
    int32_t cw = 1280, ch = 720;
    get_coord_origin_and_size(hwnd, nullptr, nullptr, &cw, &ch);
    out_rect[0] = 0; out_rect[1] = 0;
    out_rect[2] = cw;
    out_rect[3] = ch;
    return true;
}

bool bo3_win_get_window_rect(uint64_t hwnd, int32_t out_rect[4]) {
    if (!out_rect) return false;
    int32_t ox = 0, oy = 0, cw = 1280, ch = 720;
    get_coord_origin_and_size(hwnd, &ox, &oy, &cw, &ch);
    out_rect[0] = ox; out_rect[1] = oy;
    out_rect[2] = ox + cw; out_rect[3] = oy + ch;
    return true;
}

uint64_t bo3_win_set_long(uint64_t hwnd, int32_t idx, uint64_t val) {
    uint64_t old_val = 0;
    bool trigger_mode = false;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        auto it = g_live_windows.find(hwnd);
        if (it == g_live_windows.end() || !it->second) return 0;
        auto &bw = it->second;
        if (idx == -4)       { old_val = bw->wndproc_va; bw->wndproc_va = val; }
        else if (idx == -16) {
            old_val = bw->style;
            bw->style = (uint32_t)val;
            bool new_borderless = style_is_borderless(bw->style);
            if (new_borderless != bw->is_borderless) {
                bw->is_borderless = new_borderless;
                if (bw->is_fullscreen || bw->is_borderless) {
                    int32_t sw = g_screen_w.load(std::memory_order_relaxed);
                    int32_t sh = g_screen_h.load(std::memory_order_relaxed);
                    if (sw > 0 && sh > 0) { bw->w = sw; bw->h = sh; }
                } else if (bw->windowed_w > 0 && bw->windowed_h > 0) {
                    bw->w = bw->windowed_w;
                    bw->h = bw->windowed_h;
                }
                trigger_mode = (bw->ns_window != nil);
            }
        }
        else if (idx == -20) { old_val = bw->exstyle;    bw->exstyle = (uint32_t)val; }
        else if (idx == -21) { old_val = bw->userdata;   bw->userdata = val; }
    }
    if (trigger_mode) {
        schedule_window_mode_update(hwnd);
    }
    return old_val;
}

uint64_t bo3_win_get_long(uint64_t hwnd, int32_t idx) {
    std::lock_guard<std::mutex> lk(g_win_mtx);
    auto it = g_live_windows.find(hwnd);
    if (it == g_live_windows.end() || !it->second) return 0;
    auto &bw = it->second;
    if (idx == -4)  return bw->wndproc_va;
    if (idx == -16) return bw->style;
    if (idx == -20) return bw->exstyle;
    if (idx == -21) return bw->userdata;
    return 0;
}

uint64_t bo3_win_get_main_hwnd(void) {
    auto bw = get_main_win();
    return bw ? (uint64_t)(uintptr_t)bw.get() : 0;
}

void bo3_win_get_cursor_pos(int32_t out_pt[2]) {
    if (!out_pt) return;
    int32_t ox = 0, oy = 0;
    get_coord_origin_and_size(0, &ox, &oy, nullptr, nullptr);
    out_pt[0] = ox + g_mouse_x.load(std::memory_order_relaxed);
    out_pt[1] = oy + g_mouse_y.load(std::memory_order_relaxed);
}

void bo3_win_set_cursor_pos(int32_t x, int32_t y) {
    int32_t ox = 0, oy = 0, cw = 1280, ch = 720;
    get_coord_origin_and_size(0, &ox, &oy, &cw, &ch);
    int32_t cx = std::max(0, std::min(cw - 1, x - ox));
    int32_t cy = std::max(0, std::min(ch - 1, y - oy));
    g_mouse_x.store(cx, std::memory_order_relaxed);
    g_mouse_y.store(cy, std::memory_order_relaxed);
}

void bo3_win_screen_to_client(uint64_t hwnd, int32_t pt[2]) {
    if (!pt) return;
    int32_t ox = 0, oy = 0;
    get_coord_origin_and_size(hwnd, &ox, &oy, nullptr, nullptr);
    pt[0] -= ox;
    pt[1] -= oy;
}

void bo3_win_show_cursor(bool show) {
    int want = show ? 1 : 0;
    if (g_last_show_req.exchange(want, std::memory_order_seq_cst) == want) return;
    // Coalesce queued main-thread visibility updates so rapid hide/show calls never pile up.
    if (g_show_update_pending.exchange(true, std::memory_order_seq_cst)) return;
    auto update = ^{
        g_show_update_pending.store(false, std::memory_order_seq_cst);
        int cur_want = g_last_show_req.load(std::memory_order_seq_cst);
        if (cur_want < 0) return;
        bool cur_show = (cur_want != 0);
        bool prev_want_hidden = g_want_cursor_hidden;
        g_want_cursor_hidden = !cur_show;
        if (!cur_show) {
            if (main_window_can_capture(nullptr, nullptr)) {
                if (!prev_want_hidden) {
                    g_drift_recovery_paused = false;
                    g_recapture_burst_count = 0;
                }
                apply_cursor_capture_main_thread(true, true, !g_cursor_hidden);
            }
        } else {
            apply_cursor_capture_main_thread(false, true, false);
        }
    };
    if ([NSThread isMainThread]) update();
    else dispatch_async(dispatch_get_main_queue(), update);
}

bool bo3_win_is_borderless_or_fullscreen(uint64_t hwnd) {
    std::lock_guard<std::mutex> lk(g_win_mtx);
    std::shared_ptr<Bo3MacWindow> bw;
    if (hwnd && hwnd != 0xfffffffffffffffdULL) {
        auto it = g_live_windows.find(hwnd);
        if (it != g_live_windows.end() && it->second && it->second->magic == BO3_MAC_HWND_MAGIC) bw = it->second;
    }
    if (!bw) bw = g_main_window;
    return bw && (bw->is_fullscreen || bw->is_borderless);
}

void bo3_win_get_physical_screen_size(int32_t *out_w, int32_t *out_h) {
    int32_t sw = g_screen_w.load(std::memory_order_relaxed);
    int32_t sh = g_screen_h.load(std::memory_order_relaxed);
    if (sw <= 0 || sh <= 0) {
        static std::once_flag once;
        std::call_once(once, []() {
            auto query = ^{
                NSScreen *scr = [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
                if (scr) {
                    NSRect f = scr.frame;
                    if (f.size.width >= 800 && f.size.height >= 600) {
                        g_screen_w.store((int32_t)f.size.width, std::memory_order_relaxed);
                        g_screen_h.store((int32_t)f.size.height, std::memory_order_relaxed);
                    }
                }
            };
            if ([NSThread isMainThread]) query();
            else dispatch_sync(dispatch_get_main_queue(), query);
        });
        sw = g_screen_w.load(std::memory_order_relaxed);
        sh = g_screen_h.load(std::memory_order_relaxed);
    }
    if (out_w) *out_w = (sw > 0) ? sw : 1920;
    if (out_h) *out_h = (sh > 0) ? sh : 1080;
}

extern "C" uint32_t bo3_metalfx_render_scale_pct(void);

void bo3_win_get_screen_size(int32_t *out_w, int32_t *out_h) {
    int32_t sw = 1920, sh = 1080;
    bo3_win_get_physical_screen_size(&sw, &sh);
    // When BO3ARM_METALFX=1 + BO3ARM_RENDER_SCALE=<50..99>, expose the scaled virtual monitor size
    // to the guest (GetSystemMetrics/GetMonitorInfo/EnumDisplaySettings/DXGIOutput) so BO3 sizes
    // its own swapchain, viewports, G-buffers, and HUD to match (zero clipping), while CAMetalLayer
    // stays at the physical monitor resolution and MetalFX Spatial upscales on Present.
    const uint32_t pct = bo3_metalfx_render_scale_pct();
    if (pct < 100) {
        sw = std::max<int32_t>(320, (int32_t)(((int64_t)sw * pct + 50) / 100) & ~1);
        sh = std::max<int32_t>(240, (int32_t)(((int64_t)sh * pct + 50) / 100) & ~1);
    }
    if (out_w) *out_w = sw;
    if (out_h) *out_h = sh;
}

int16_t bo3_win_get_key_state(int vk) {
    if (vk < 0 || vk >= 256) return 0;
    return g_vk_down[vk].load(std::memory_order_relaxed) ? (int16_t)0x8000 : 0;
}

int bo3_win_peek_message(uint8_t *msg_out, uint64_t hwnd, uint32_t min_msg, uint32_t max_msg, uint32_t remove_flags) {
    std::lock_guard<std::mutex> lk(g_msg_mtx);
    for (auto it = g_msg_queue.begin(); it != g_msg_queue.end(); ++it) {
        // Win32: WM_QUIT is always retrieved regardless of hwnd / message-range filters
        const bool is_quit = (it->message == 0x0012u /* WM_QUIT */);
        if (!is_quit && hwnd && it->hwnd != hwnd) continue;
        if (!is_quit && (min_msg || max_msg) && (it->message < min_msg || it->message > max_msg)) continue;
        if (msg_out) memcpy(msg_out, &(*it), sizeof(Win32Msg));
        if (remove_flags & 1u) g_msg_queue.erase(it); // PM_REMOVE
        return 1;
    }
    return 0;
}

int bo3_win_get_message(uint8_t *msg_out, uint64_t hwnd, uint32_t min_msg, uint32_t max_msg) {
    std::unique_lock<std::mutex> lk(g_msg_mtx);
    while (true) {
        for (auto it = g_msg_queue.begin(); it != g_msg_queue.end(); ++it) {
            const bool is_quit = (it->message == 0x0012u /* WM_QUIT */);
            if (!is_quit && hwnd && it->hwnd != hwnd) continue;
            if (!is_quit && (min_msg || max_msg) && (it->message < min_msg || it->message > max_msg)) continue;
            Win32Msg m = *it;
            g_msg_queue.erase(it);
            if (msg_out) memcpy(msg_out, &m, sizeof(Win32Msg));
            return (m.message == 0x0012 /* WM_QUIT */) ? 0 : 1;
        }
        g_msg_cv.wait(lk);
    }
}

int bo3_win_post_message(uint64_t hwnd, uint32_t msg, uint64_t wparam, uint64_t lparam) {
    push_msg(hwnd, msg, wparam, lparam);
    return 1;
}

uint64_t bo3_win_dispatch_message(GuestContext *ctx, uint64_t rsp, const uint8_t *msg_in) {
    if (!msg_in) return 0;
    Win32Msg m;
    memcpy(&m, msg_in, sizeof(Win32Msg));
    auto bw = as_win(m.hwnd);
    if (!bw) return 0;
    uint64_t wp = 0;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        wp = bw->wndproc_va;
    }
    if (!wp) return 0;
    return bo3_win_call_wndproc(ctx, rsp, wp, m.hwnd, m.message, m.wparam, m.lparam);
}

uint64_t bo3_win_send_message(GuestContext *ctx, uint64_t rsp,
                              uint64_t hwnd, uint32_t msg, uint64_t wparam, uint64_t lparam) {
    auto bw = as_win(hwnd);
    if (!bw) bw = get_main_win();
    if (!bw) return 0;
    uint64_t wp = 0;
    {
        std::lock_guard<std::mutex> lk(g_win_mtx);
        wp = bw->wndproc_va;
    }
    if (!wp) return 0;
    // Direct invocation on calling thread's GuestContext:
    // Matches BO3's 0x8042 (CreateSwapChain), 0x8043 (Present), 0x8044 (SetFullscreenState)
    // without cross-thread ping-pong or deadlock when render thread presents!
    return bo3_win_call_wndproc(ctx, rsp, wp, (uint64_t)(uintptr_t)bw.get(), msg, wparam, lparam);
}

uint32_t bo3_win_get_raw_input_buffer(void *data, uint32_t *pcb_size, uint32_t hdr_size) {
    if (!pcb_size || hdr_size != (uint32_t)sizeof(Win32RawInputHeader)) return 0xffffffffu;
    const uint32_t block_sz = (uint32_t)sizeof(Win32RawInputMouse); // 0x30 (48 bytes)
    if (!data) {
        *pcb_size = block_sz;
        return 0;
    }
    if (*pcb_size < block_sz) {
        *pcb_size = block_sz;
        return 0xffffffffu;
    }
    int32_t dx = g_raw_dx.exchange(0, std::memory_order_acq_rel);
    int32_t dy = g_raw_dy.exchange(0, std::memory_order_acq_rel);
    if (dx == 0 && dy == 0) return 0;

    Win32RawInputMouse rm;
    memset(&rm, 0, sizeof(rm));
    rm.header.dwType = 0; // RIM_TYPEMOUSE
    rm.header.dwSize = block_sz;
    rm.header.hDevice = 0x10001;
    rm.mouse.usFlags = 0; // MOUSE_MOVE_RELATIVE
    rm.mouse.lLastX = dx;
    rm.mouse.lLastY = dy;
    memcpy(data, &rm, block_sz);
    return 1; // 1 RAWINPUT block written (leave *pcb_size intact for loop re-entry)
}

uint32_t bo3_win_get_raw_input_data(uint64_t hrawinput, uint32_t cmd, void *data, uint32_t *pcb_size, uint32_t hdr_size) {
    (void)hdr_size;
    if (!pcb_size) return 0xffffffffu;
    uint32_t needed = (cmd == 0x10000005u /* RID_HEADER */) ? (uint32_t)sizeof(Win32RawInputHeader)
                                                            : (uint32_t)sizeof(Win32RawInputMouse);
    if (!data) {
        *pcb_size = needed;
        return 0;
    }
    if (*pcb_size < needed) {
        *pcb_size = needed;
        return 0xffffffffu;
    }
    std::lock_guard<std::mutex> lk(g_raw_mtx);
    const RawRingSlot &slot = g_raw_ring[hrawinput % RAW_RING_SZ];
    if (hrawinput == 0 || slot.seq != hrawinput) {
        return 0xffffffffu;
    }
    memcpy(data, &slot.data, needed);
    *pcb_size = needed;
    return needed;
}

void bo3_win_register_raw_input(uint64_t target_hwnd) {
    if (target_hwnd) g_raw_input_hwnd.store(target_hwnd, std::memory_order_release);
}

void bo3_win_inject_key(uint16_t vk, uint8_t sc, bool down) {
    if (vk == 0x01 /* VK_LBUTTON */) {
        if (down) g_mouse_buttons.fetch_or(1, std::memory_order_relaxed);
        else      g_mouse_buttons.fetch_and(~1u, std::memory_order_relaxed);
        g_vk_down[0x01].store(down ? 1 : 0, std::memory_order_relaxed);
        uint64_t lp = ((uint64_t)360 << 16) | 640;
        push_msg(0, down ? 0x0201 /* WM_LBUTTONDOWN */ : 0x0202 /* WM_LBUTTONUP */, down ? 1 : 0, lp);
        push_raw_mouse(0, 0, down ? 0x0001 : 0x0002, 0);
        return;
    }
    if (vk < 256) g_vk_down[vk].store(down ? 1 : 0, std::memory_order_relaxed);
    uint64_t lp = 1ULL | ((uint64_t)sc << 16) | (is_extended_vk(vk) ? (1ULL << 24) : 0ULL) | (down ? 0ULL : ((1ULL << 30) | (1ULL << 31)));
    push_msg(0, down ? 0x0100 /* WM_KEYDOWN */ : 0x0101 /* WM_KEYUP */, vk, lp);
    if (down && (vk == 0x0D || vk == 0x1B || vk == 0x20 || (vk >= 0x30 && vk <= 0x5A))) {
        push_msg(0, 0x0102 /* WM_CHAR */, vk, lp);
    }
}

void *bo3_win_get_metal_layer(uint64_t hwnd) {
    std::lock_guard<std::mutex> lk(g_win_mtx);
    CAMetalLayer *ml = nil;
    auto it = g_live_windows.find(hwnd);
    if (it != g_live_windows.end() && it->second && it->second->metal_layer) {
        ml = it->second->metal_layer;
    } else if (g_main_window && g_main_window->metal_layer) {
        ml = g_main_window->metal_layer;
    }
    return (__bridge void *)ml;
}

#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Persistent + live-editable runtime settings for bo3mac.
// Stored at ~/Library/Application Support/bo3mac/settings.ini (env vars override for the session).
// All getters are lock-free atomics safe to call on any thread (render, audio, Steam, UI).

void        bo3_settings_load_early(void); // safe before Metal device creation (reads settings.ini + env)
void        bo3_settings_init_for_device(const char *gpu_name, bool apple8_plus, int32_t phys_w, int32_t phys_h);
void        bo3_settings_save(void);
void        bo3_settings_reset_recommended(void);

// Live runtime settings
bool        bo3_settings_metalfx_enabled(void);
void        bo3_settings_set_metalfx(bool on);

uint32_t    bo3_settings_render_scale(void);         // 50..100 (persisted; editable live for next launch)
uint32_t    bo3_settings_startup_render_scale(void); // frozen at launch (virtual display scale for this session)
void        bo3_settings_set_render_scale(uint32_t pct);

bool        bo3_settings_lossy_rt_supported(void);
bool        bo3_settings_lossy_rt_enabled(void);
void        bo3_settings_set_lossy_rt(bool on);

uint32_t    bo3_settings_max_frame_latency(void);    // 0 = Auto (game setting), 1..3 = override
void        bo3_settings_set_max_frame_latency(uint32_t lat);

uint32_t    bo3_settings_hud_mode(void);             // 0 = Off, 1 = Compact FPS, 2 = Detailed GPU/CPU/TBDR
void        bo3_settings_set_hud_mode(uint32_t mode);

bool        bo3_settings_friends_only(void);
void        bo3_settings_set_friends_only(bool on);

bool        bo3_settings_offline_mode(void);
void        bo3_settings_set_offline_mode(bool on);

void        bo3_settings_copy_gpu_profile_label(char *buf, size_t cap);

// In-game native macOS settings overlay (F10 / Cmd+,) + click-through FPS/GPU corner HUD
void        bo3_ui_attach_game_window(void *ns_window_ptr);
void        bo3_ui_sync_layout(void);
void        bo3_ui_toggle_settings_panel(void);
void        bo3_ui_close_settings_panel(void);
bool        bo3_ui_settings_panel_open(void);
void        bo3_ui_set_panel_visibility_callback(void (*cb)(bool open));
void        bo3_ui_update_hud_stats(double fps, double gpu_ms, double cpu_ms,
                                    uint32_t render_w, uint32_t render_h,
                                    uint32_t draw_w, uint32_t draw_h,
                                    bool metalfx_active, bool lossy_rt_active,
                                    double load_mb, double store_mb);

#ifdef __cplusplus
}
#endif

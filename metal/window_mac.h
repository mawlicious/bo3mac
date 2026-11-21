#pragma once
#include "cpu_state.h"
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Launches NSApplication on thread 0 and runs `guest_fn(argc, argv)` on a dedicated
// guest-main pthread (with large native stack). Never returns until process exit.
int bo3_mac_run_with_guest(int (*guest_fn)(int, char **), int argc, char **argv);

// Window class & Win32 window management
void     bo3_win_register_class(const char *class_name, uint64_t wndproc_va);
uint64_t bo3_win_create(GuestContext *ctx, uint64_t rsp,
                        uint32_t ex_style, const char *class_name, const char *title,
                        uint32_t style, int32_t x, int32_t y, int32_t w, int32_t h,
                        uint64_t parent_hwnd);
void     bo3_win_destroy(uint64_t hwnd);
void     bo3_win_show(uint64_t hwnd, int cmd_show);
void     bo3_win_set_title(uint64_t hwnd, const char *title);
size_t   bo3_win_get_title(uint64_t hwnd, char *dst, size_t max_len);
void     bo3_win_move(uint64_t hwnd, int32_t x, int32_t y, int32_t w, int32_t h);
void     bo3_win_set_pos(uint64_t hwnd, int32_t x, int32_t y, int32_t cx, int32_t cy, uint32_t flags);
bool     bo3_win_get_client_rect(uint64_t hwnd, int32_t out_rect[4]);
bool     bo3_win_get_window_rect(uint64_t hwnd, int32_t out_rect[4]);
uint64_t bo3_win_set_long(uint64_t hwnd, int32_t idx, uint64_t val);
uint64_t bo3_win_get_long(uint64_t hwnd, int32_t idx);
uint64_t bo3_win_get_main_hwnd(void);
void     bo3_win_get_cursor_pos(int32_t out_pt[2]);
void     bo3_win_set_cursor_pos(int32_t x, int32_t y);
void     bo3_win_screen_to_client(uint64_t hwnd, int32_t pt[2]);
void     bo3_win_show_cursor(bool show);
void     bo3_win_get_screen_size(int32_t *out_w, int32_t *out_h);
void     bo3_win_get_physical_screen_size(int32_t *out_w, int32_t *out_h);
int16_t  bo3_win_get_key_state(int vk);

// Message queue & dispatch
int      bo3_win_peek_message(uint8_t *msg_out, uint64_t hwnd, uint32_t min_msg, uint32_t max_msg, uint32_t remove_flags);
int      bo3_win_get_message(uint8_t *msg_out, uint64_t hwnd, uint32_t min_msg, uint32_t max_msg);
int      bo3_win_post_message(uint64_t hwnd, uint32_t msg, uint64_t wparam, uint64_t lparam);
uint64_t bo3_win_dispatch_message(GuestContext *ctx, uint64_t rsp, const uint8_t *msg_in);
uint64_t bo3_win_send_message(GuestContext *ctx, uint64_t rsp, uint64_t hwnd, uint32_t msg, uint64_t wparam, uint64_t lparam);
uint64_t bo3_win_call_wndproc(GuestContext *ctx, uint64_t rsp, uint64_t wndproc_va, uint64_t hwnd, uint32_t msg, uint64_t wparam, uint64_t lparam);

// Raw input
uint32_t bo3_win_get_raw_input_buffer(void *data, uint32_t *pcb_size, uint32_t hdr_size);
uint32_t bo3_win_get_raw_input_data(uint64_t hrawinput, uint32_t cmd, void *data, uint32_t *pcb_size, uint32_t hdr_size);
void     bo3_win_register_raw_input(uint64_t target_hwnd);
void     bo3_win_set_render_size(uint64_t hwnd, int32_t w, int32_t h);
void     bo3_win_set_drawable_size(uint64_t hwnd, int32_t w, int32_t h);
void     bo3_win_set_swapchain_sizes(uint64_t hwnd, const void *owner, int32_t render_w, int32_t render_h,
                                     int32_t drawable_w, int32_t drawable_h);
void     bo3_win_update_swapchain_sizes(uint64_t hwnd, const void *owner, int32_t render_w, int32_t render_h,
                                        int32_t drawable_w, int32_t drawable_h);
void     bo3_win_clear_swapchain_sizes(uint64_t hwnd, const void *owner);
bool     bo3_win_get_drawable_size(uint64_t hwnd, int32_t *out_w, int32_t *out_h);
bool     bo3_win_get_native_client_size(uint64_t hwnd, int32_t *out_w, int32_t *out_h);
bool     bo3_win_is_borderless_or_fullscreen(uint64_t hwnd);
void     bo3_win_lock_layer(uint64_t hwnd);
bool     bo3_win_trylock_layer(uint64_t hwnd);
void     bo3_win_unlock_layer(uint64_t hwnd);
void     bo3_win_set_fullscreen(uint64_t hwnd, bool fullscreen);
void     bo3_win_restore_desktop_sync(void);

// Synthetic input injection for automated regression scripts (opt-in via BO3ARM_SCRIPT_KEYS)
void     bo3_win_inject_key(uint16_t vk, uint8_t sc, bool down);

// Metal integration (returns CAMetalLayer* cast to void*)
void    *bo3_win_get_metal_layer(uint64_t hwnd);

#ifdef __cplusplus
}
#endif

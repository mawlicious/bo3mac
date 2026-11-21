// gamepad_mac.h — GameController.framework / CoreHaptics backend for BO3's XInput calls.
//
// Verified in CoDBlkOps3_Exe (x86_64): the engine calls Aspyr's XInput emulation directly
// (Aspyr implemented it on SDL2 GameController + SDL haptic, dispatched to the main thread):
//
//   0x1001294a8  DWORD XInputGetState(DWORD dwUserIndex, XINPUT_STATE *pState)
//                callers: engine 0x10122f45f, 0x10122facd, 0x1012300aa
//   0x1001295ac  DWORD XInputSetState(DWORD dwUserIndex, XINPUT_VIBRATION *pVibration)
//                caller:  engine 0x101230122 (rumble / rumble-stop on pad reset)
//
// Buttons follow the XInput layout, with the Guide button at bit 0x0400. Sticks are
// up-positive, triggers use 0..255, and small inputs are filtered using XInput dead zones.
// A connected controller's packet number advances when its reported state changes.
#pragma once

#include <stdint.h>
#include <stddef.h>
#include "shim_helpers.h"

#ifdef __cplusplus
extern "C" {
#endif

#define BO3_XUSER_MAX_COUNT              4
#define BO3_ERROR_SUCCESS                0x000u
#define BO3_ERROR_BAD_ARGUMENTS          0x0A0u
#define BO3_ERROR_DEVICE_NOT_CONNECTED   0x48Fu

typedef struct Bo3XInputGamepad {
    uint16_t wButtons;
    uint8_t  bLeftTrigger;
    uint8_t  bRightTrigger;
    int16_t  sThumbLX;
    int16_t  sThumbLY;
    int16_t  sThumbRX;
    int16_t  sThumbRY;
} Bo3XInputGamepad;                // 12 bytes

typedef struct Bo3XInputState {
    uint32_t         dwPacketNumber;
    Bo3XInputGamepad Gamepad;
} Bo3XInputState;                  // 16 bytes == XINPUT_STATE

typedef struct Bo3XInputVibration {
    uint16_t wLeftMotorSpeed;      // low-frequency (heavy) motor
    uint16_t wRightMotorSpeed;     // high-frequency (light) motor
} Bo3XInputVibration;              // 4 bytes == XINPUT_VIBRATION

// The guest hands us raw x86_64 XINPUT_* blocks: pin the layout.
#ifdef __cplusplus
#define BO3_XINPUT_STATIC_ASSERT(c, m) static_assert(c, m)
#else
#define BO3_XINPUT_STATIC_ASSERT(c, m) _Static_assert(c, m)
#endif
BO3_XINPUT_STATIC_ASSERT(sizeof(Bo3XInputGamepad) == 12, "XINPUT_GAMEPAD ABI");
BO3_XINPUT_STATIC_ASSERT(offsetof(Bo3XInputGamepad, bLeftTrigger) == 2, "XINPUT_GAMEPAD ABI");
BO3_XINPUT_STATIC_ASSERT(offsetof(Bo3XInputGamepad, sThumbLX) == 4, "XINPUT_GAMEPAD ABI");
BO3_XINPUT_STATIC_ASSERT(offsetof(Bo3XInputGamepad, sThumbRY) == 10, "XINPUT_GAMEPAD ABI");
BO3_XINPUT_STATIC_ASSERT(sizeof(Bo3XInputState) == 16, "XINPUT_STATE ABI");
BO3_XINPUT_STATIC_ASSERT(offsetof(Bo3XInputState, Gamepad) == 4, "XINPUT_STATE ABI");
BO3_XINPUT_STATIC_ASSERT(sizeof(Bo3XInputVibration) == 4, "XINPUT_VIBRATION ABI");
BO3_XINPUT_STATIC_ASSERT(offsetof(Bo3XInputVibration, wRightMotorSpeed) == 2, "XINPUT_VIBRATION ABI");
#undef BO3_XINPUT_STATIC_ASSERT

// Installs GameController observers once and tracks connections on a serial queue.
// The shims also initialize observation lazily.
void     bo3_gamepad_init(void);
// Mirrors Aspyr's global "controller input enabled" flag (0x101b97300 bit0): when disabled,
// connected pads report an all-zero state (still ERROR_SUCCESS). Disabling also stops any active
// rumble asynchronously; while disabled, XInputSetState is accepted but produces no vibration.
void     bo3_gamepad_set_enabled(int enabled);
int      bo3_gamepad_connected_count(void);
uint32_t bo3_xinput_get_state(uint32_t user_index, Bo3XInputState *out);
uint32_t bo3_xinput_set_state(uint32_t user_index, const Bo3XInputVibration *vib);

// Guest shims (SysV x86_64): wire as SHIM_DEF(g_1001294a8) { BO3_GAMEPAD_FORWARD(bo3_shim_XInputGetState); }
GuestRet bo3_shim_XInputGetState(SHIM_PARAMS);   // 0x1001294a8
GuestRet bo3_shim_XInputSetState(SHIM_PARAMS);   // 0x1001295ac

#define BO3_GAMEPAD_FORWARD(fn) \
    return fn(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7)

#ifdef __cplusplus
}
#endif

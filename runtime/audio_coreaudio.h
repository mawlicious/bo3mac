// audio_coreaudio.h — native ARM64 CoreAudio backend for bo3arm (zero SDL2).
//
// Verified BO3 (CoDBlkOps3_Exe x86_64) audio paths that this module replaces:
//
//  (A) Engine main mix -> WASAPI COM (the hot path)
//      engine 0x100fec254: CoCreateInstance(IID_IMMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
//                                           IID_IMMDeviceEnumerator, &enum)        [shim 0x1000fbcb0]
//        enum->GetDefaultAudioEndpoint  (vt+0x20)  -> IMMDevice
//        dev ->Activate(IID_IAudioClient, 1, NULL, &client) (vt+0x18)
//        client->GetMixFormat (+0x40)   -> float32 WAVEFORMATEXTENSIBLE for the default output
//        client->Initialize   (+0x18)   shared mode, optional AUDCLNT_STREAMFLAGS_EVENTCALLBACK
//        client->SetEventHandle(+0x68), GetBufferSize(+0x20)
//        client->GetService   (+0x70)   IID_IAudioRenderClient, IID_IAudioSessionControl
//        client->Start (+0x50) / Stop (+0x58); render->GetBuffer (+0x18) / ReleaseBuffer (+0x20)
//      Aspyr implemented these objects in ASL [0x100108764..0x100109964] on top of SDL2's
//      queue API; that code is NOT lifted, so the runtime must hand the engine native objects.
//      This module provides them via bo3_wasapi_create_enumerator.
//
//  (B) Engine VoIP playback -> SDL2 queue API directly (engine 0x101377fb5 / 0x101377ec7 / 0x101378041)
//        0x10012d270 SDL_OpenAudioDevice(NULL, 0, {11025 Hz, AUDIO_S16LSB, 1 ch, 2048 samples, cb=NULL}, &obt, SDL_AUDIO_ALLOW_FORMAT_CHANGE)
//        0x10012d280 SDL_PauseAudioDevice(id, 0)
//        0x10012ba30 SDL_QueueAudio(id, pcm, len)
//        0x10012d2e0 SDL_CloseAudioDevice(id)
//      (The same four are also used by Aspyr's WASAPI client at 0x100108ea0 / 0x1001091b7 /
//       0x1001091fe / 0x100109609 / 0x100108c8a, together with 0x10012bb50 SDL_GetQueuedAudioSize,
//       0x10012c2d0 SDL_GetNumAudioDevices and 0x10012c450 SDL_GetAudioDeviceName.)
//
//  Neither path uses an SDL audio callback; both use the push/queue model. Formats seen:
//  48000/F32LSB/2ch (main) and 11025/S16LSB/1ch (VoIP). The backend accepts any SDL format
//  (U8/S8/U16/S16/U32/S32/F32, 1..8 channels). The render callback maps channels to the output
//  layout, and CoreAudio's DefaultOutput unit resamples from the guest sample rate.
//
// Real-time design: per-device SPSC ring buffer (producer = BO3 threads under a non-RT lock,
// consumer = CoreAudio render thread, lock-free / allocation-free). Underrun => silence.
// SDL_ClearQueuedAudio only *requests* a flush: the producer never reclaims flushed space until the
// render thread (or its paused drain) acknowledges the new read position with a release store.
#pragma once

#include <stdint.h>
#include <stddef.h>
#include "shim_helpers.h"

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// SDL2 ABI (x86_64 layout, exactly what BO3 passes in guest memory)
// ---------------------------------------------------------------------------
#define BO3_AUDIO_U8       0x0008u
#define BO3_AUDIO_S8       0x8008u
#define BO3_AUDIO_U16LSB   0x0010u
#define BO3_AUDIO_S16LSB   0x8010u
#define BO3_AUDIO_U32LSB   0x0020u    // unsigned 32-bit PCM backend extension
#define BO3_AUDIO_S32LSB   0x8020u
#define BO3_AUDIO_F32LSB   0x8120u
#define BO3_AUDIO_U16MSB   0x1010u
#define BO3_AUDIO_S16MSB   0x9010u
#define BO3_AUDIO_U32MSB   0x1020u
#define BO3_AUDIO_S32MSB   0x9020u
#define BO3_AUDIO_F32MSB   0x9120u

#define BO3_AUDIO_MAX_DEVICES 16   // simultaneous devices (SDL2 table at 0x102108e90)
// SDL2 reserves device id 1 for the legacy SDL_OpenAudio() API, so SDL_OpenAudioDevice() ids
// start at 2. bo3_audio_open() advances the ID independently of the slot used.
#define BO3_AUDIO_FIRST_DEVICE_ID 2u

typedef struct Bo3SdlAudioSpec {
    int32_t  freq;      // +0x00
    uint16_t format;    // +0x04 SDL_AudioFormat
    uint8_t  channels;  // +0x06
    uint8_t  silence;   // +0x07
    uint16_t samples;   // +0x08 (frames per "SDL buffer")
    uint16_t padding;   // +0x0a
    uint32_t size;      // +0x0c bytes per SDL buffer
    uint64_t callback;  // +0x10 guest fn ptr (must be 0: queue mode only)
    uint64_t userdata;  // +0x18
} Bo3SdlAudioSpec;      // sizeof == 32 == sizeof(SDL_AudioSpec) on x86_64

#ifdef __cplusplus
static_assert(sizeof(Bo3SdlAudioSpec) == 32, "SDL_AudioSpec ABI");
#else
_Static_assert(sizeof(Bo3SdlAudioSpec) == 32, "SDL_AudioSpec ABI");
#endif

typedef struct Bo3AudioStats {
    uint64_t render_calls;     // CoreAudio render callbacks
    uint64_t frames_rendered;  // frames delivered from the queue
    uint64_t underrun_frames;  // frames filled with silence while unpaused (queue empty)
    uint64_t dropped_bytes;    // bytes discarded because the ring was full
} Bo3AudioStats;

// Diagnostics snapshot (tests / logging). Ring positions are absolute byte counters.
typedef struct Bo3AudioDebugInfo {
    uint64_t wpos;             // producer position
    uint64_t rpos;             // consumer-acknowledged position (producer reclaims only up to here)
    uint64_t flush_to;         // last SDL_ClearQueuedAudio target
    uint64_t cap;              // ring bytes
    uint32_t channel_mask;     // WAVEFORMATEXTENSIBLE-style speaker mask used for the down-mix
    uint16_t format;           // SDL_AudioFormat
    uint8_t  channels;
    uint8_t  silence;          // SDL silence byte (0x80 for U8)
    uint8_t  paused;
    uint8_t  pad[3];
    float    gain;
    float    mix_l[8];         // per-input-channel stereo down-mix coefficients
    float    mix_r[8];
} Bo3AudioDebugInfo;

// ---------------------------------------------------------------------------
// Native C API (usable from any thread except the CoreAudio render thread)
// ---------------------------------------------------------------------------

// Open an output device in queue mode. Missing fields get SDL defaults (22050 Hz, S16, 2 ch,
// ~46 ms pow2 samples). `obtained` (optional) receives the effective spec (== desired: every
// SDL format is supported natively, so no format change is ever needed). Starts PAUSED, as SDL.
// Returns a device id >= 2 (SDL2 numbering, see BO3_AUDIO_FIRST_DEVICE_ID), or 0 on failure
// (see bo3_audio_last_error()). Multichannel input uses SDL2's channel order for the down-mix.
uint32_t    bo3_audio_open(const Bo3SdlAudioSpec *desired, Bo3SdlAudioSpec *obtained);
// Same, but the interleaved channels follow a WAVEFORMATEXTENSIBLE dwChannelMask (lowest set
// bit = first channel). A mask with fewer bits than channels falls back to the Windows default
// layout for that channel count; 0 selects the SDL2 layout (== bo3_audio_open).
uint32_t    bo3_audio_open_with_mask(const Bo3SdlAudioSpec *desired, Bo3SdlAudioSpec *obtained,
                                     uint32_t channel_mask);
// Queues the complete write or returns -1 on failure (including a full ring). Partial frames are
// carried over to the next call. The ring holds at least two seconds of audio.
int         bo3_audio_queue(uint32_t dev, const void *data, uint32_t len);
void        bo3_audio_pause(uint32_t dev, int pause_on);
void        bo3_audio_close(uint32_t dev);
uint32_t    bo3_audio_get_queued_bytes(uint32_t dev);   // SDL_GetQueuedAudioSize
void        bo3_audio_clear(uint32_t dev);              // SDL_ClearQueuedAudio
void        bo3_audio_set_gain(uint32_t dev, float gain);
int         bo3_audio_get_stats(uint32_t dev, Bo3AudioStats *out);
int         bo3_audio_debug_info(uint32_t dev, Bo3AudioDebugInfo *out);          // 0 / -1
// Copies `len` ring bytes starting at absolute position `pos` (must lie in [rpos, wpos)).
// Returns bytes copied.
uint32_t    bo3_audio_debug_peek(uint32_t dev, uint64_t pos, void *dst, uint32_t len);
int         bo3_audio_get_num_devices(int iscapture);   // system default output if available, no capture
const char *bo3_audio_get_device_name(int index, int iscapture); // stable UTF-8 or NULL
const char *bo3_audio_last_error(void);                 // thread-local

// ---------------------------------------------------------------------------
// Guest shims, SDL2 ABI (SysV x86_64 args in rdi/rsi/rdx/rcx/r8)
// Wire as:  SHIM_DEF(g_10012ba30) { BO3_SHIM_FORWARD(bo3_shim_SDL_QueueAudio); }
// ---------------------------------------------------------------------------
GuestRet bo3_shim_SDL_OpenAudioDevice(SHIM_PARAMS);    // 0x10012d270 (const char*, int, const SDL_AudioSpec*, SDL_AudioSpec*, int) -> u32
GuestRet bo3_shim_SDL_QueueAudio(SHIM_PARAMS);         // 0x10012ba30 (u32 dev, const void*, u32 len) -> int
GuestRet bo3_shim_SDL_PauseAudioDevice(SHIM_PARAMS);   // 0x10012d280 (u32 dev, int pause_on) -> void
GuestRet bo3_shim_SDL_CloseAudioDevice(SHIM_PARAMS);   // 0x10012d2e0 (u32 dev) -> void
GuestRet bo3_shim_SDL_GetQueuedAudioSize(SHIM_PARAMS); // 0x10012bb50 (u32 dev) -> u32   [ASL-internal only]
GuestRet bo3_shim_SDL_ClearQueuedAudio(SHIM_PARAMS);
GuestRet bo3_shim_SDL_LockAudioDevice(SHIM_PARAMS);    // queue mode has no guest callback to lock
GuestRet bo3_shim_SDL_UnlockAudioDevice(SHIM_PARAMS);
GuestRet bo3_shim_SDL_GetNumAudioDevices(SHIM_PARAMS); // 0x10012c2d0 (int iscapture) -> int [ASL-internal only]
GuestRet bo3_shim_SDL_GetAudioDeviceName(SHIM_PARAMS); // 0x10012c450 (int, int) -> const char* [ASL-internal only]

#define BO3_SHIM_FORWARD(fn) \
    return fn(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7)

// ---------------------------------------------------------------------------
// WASAPI COM emulation (engine path A)
// ---------------------------------------------------------------------------

// Every COM vtable slot is a synthetic guest VA handed out by bo3_com_register_thunk()
// (metal/com_thunks.h, reserved 0xF00000000000+ window, allocated under its lock), so the audio
// vtables can never collide with guest image VAs or the D3D11/DXGI thunks.
// Idempotent (std::call_once). Call it eagerly at single-threaded startup next to
// bo3_init_win32_mocks(); bo3_wasapi_create_enumerator() also calls it lazily.
void     bo3_audio_init_guest_vtables(void);
// 1 if `guid` (16 bytes) is IID_IMMDeviceEnumerator {A95664D2-9614-4F35-A746-DE8DB63617E6}
// or CLSID_MMDeviceEnumerator {BCDE0395-E52F-467C-8E3D-C4579291692E}.
int      bo3_wasapi_is_enumerator_guid(const void *guid);
// Creates an IMMDeviceEnumerator; writes the interface pointer to *ppv. Returns HRESULT.
uint32_t bo3_wasapi_create_enumerator(uint64_t *ppv);

// AUDCLNT_STREAMFLAGS_EVENTCALLBACK clients get their event signalled every 5 ms (500 us
// leeway) while queued frames < buffer frames. Aspyr used InstallEventLoopTimer(0.01); 5 ms keeps
// 10 ms engine buffers from underrunning under timer jitter.
// The runtime owns Win32 HANDLEs, so it must supply context-free hooks:
//   signal(h)  : SetEvent(h). Called on a private dispatch queue, never with audio locks held.
//   retain(h)  : take a reference on h (e.g. DuplicateHandle-style refcount); return nonzero on
//                success, 0 if h is not a valid event (SetEventHandle then fails E_INVALIDARG).
//   release(h) : drop the reference taken by retain(h).
// SetEventHandle requires all three hooks. It retains the new handle and drains any signal
// in flight before releasing the previous one. Final stream teardown drains the timer and
// releases the retained handle. Hooks must not call back into the audio client.
// Install the hooks at startup before exposing event-driven audio to the guest.
typedef void (*Bo3AudioSignalEventFn)(uint64_t guest_handle);
typedef int  (*Bo3AudioRetainEventFn)(uint64_t guest_handle);
typedef void (*Bo3AudioReleaseEventFn)(uint64_t guest_handle);
void     bo3_audio_set_event_hooks(Bo3AudioSignalEventFn signal_fn, Bo3AudioRetainEventFn retain_fn,
                                   Bo3AudioReleaseEventFn release_fn);
void     bo3_audio_set_event_signal_fn(Bo3AudioSignalEventFn fn);   // updates the signal hook only

#ifdef __cplusplus
}
#endif

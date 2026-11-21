// audio_coreaudio.mm — native CoreAudio (AudioToolbox DefaultOutput AudioUnit) backend for bo3arm.
// See audio_coreaudio.h for the verified BO3 call paths. Zero SDL2.
#include "audio_coreaudio.h"
#include "../metal/com_thunks.h"

#if !__has_feature(objc_arc)
#error "audio_coreaudio.mm must be compiled with -fobjc-arc (dispatch objects are ARC-managed)"
#endif

#import <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>
#include <os/lock.h>
#include <pthread.h>

#include <algorithm>
#include <atomic>
#include <bit>
#include <cstdarg>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <set>
#include <string>

// =========================================================================================
// 1. Device table + lock-free SPSC ring
// =========================================================================================

namespace {

constexpr uint32_t kMaxChannels = 8;

struct AudioDev {
    // --- immutable after open ---
    uint32_t        id = 0;
    Bo3SdlAudioSpec spec{};
    uint32_t        bpf = 0;          // bytes per frame
    uint32_t        bytes_per_sample = 0;
    uint64_t        cap = 0;          // ring bytes (multiple of bpf)
    uint8_t        *ring = nullptr;
    float           mix_l[kMaxChannels]{};
    float           mix_r[kMaxChannels]{};
    uint32_t        chmask = 0;       // speaker mask the down-mix was built from
    uint32_t        output_channels = 0;
    float           mix[kMaxChannels][kMaxChannels]{};
    bool            identity_mix = false;
    bool            running = false;
    AudioUnit       unit = nullptr;

    // --- producer side (guarded by g_api_lock) ---
    uint8_t         carry[kMaxChannels * 4]{};
    uint32_t        carry_len = 0;

    // --- shared ---
    std::atomic<uint64_t> wpos{0};    // producer-owned, frame aligned
    std::atomic<uint64_t> rpos{0};    // consumer-owned, frame aligned; the ONLY bound the producer
                                      // uses to reclaim space (acknowledged with release)
    std::atomic<uint64_t> flush_to{0};// producer request: consumer skips to here, then acks via rpos
    std::atomic<bool>     paused{true};
    std::atomic<float>    gain{1.0f};

    // --- stats ---
    std::atomic<uint64_t> st_calls{0}, st_frames{0}, st_underrun{0}, st_dropped{0};
};

os_unfair_lock g_api_lock = OS_UNFAIR_LOCK_INIT;   // never taken on the render thread
AudioDev *g_devs[BO3_AUDIO_MAX_DEVICES] = {};       // published (fully started) devices
bool      g_reserved[BO3_AUDIO_MAX_DEVICES] = {};   // slot claimed by an in-progress open
uint32_t  g_next_device_id = BO3_AUDIO_FIRST_DEVICE_ID;

thread_local char t_last_error[256];

void set_error(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void set_error(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(t_last_error, sizeof(t_last_error), fmt, ap);
    va_end(ap);
}

struct ApiLock {
    ApiLock() { os_unfair_lock_lock(&g_api_lock); }
    ~ApiLock() { os_unfair_lock_unlock(&g_api_lock); }
    ApiLock(const ApiLock &) = delete;
    ApiLock &operator=(const ApiLock &) = delete;
};

AudioDev **lookup_slot_locked(uint32_t id) {
    if (id >= BO3_AUDIO_FIRST_DEVICE_ID) {
        for (AudioDev *&d : g_devs)
            if (d && d->id == id) return &d;
    }
    return nullptr;
}

AudioDev *lookup_locked(uint32_t id) {
    AudioDev **slot = lookup_slot_locked(id);
    return slot ? *slot : nullptr;
}

uint32_t format_bytes(uint16_t fmt) {
    switch (fmt) {
        case BO3_AUDIO_U8: case BO3_AUDIO_S8: return 1;
        case BO3_AUDIO_U16LSB: case BO3_AUDIO_S16LSB:
        case BO3_AUDIO_U16MSB: case BO3_AUDIO_S16MSB: return 2;
        case BO3_AUDIO_U32LSB: case BO3_AUDIO_S32LSB: case BO3_AUDIO_F32LSB:
        case BO3_AUDIO_U32MSB: case BO3_AUDIO_S32MSB: case BO3_AUDIO_F32MSB: return 4;
        default: return 0;
    }
}

// ---- speaker layouts -------------------------------------------------------------------
// WAVEFORMATEXTENSIBLE speaker bits (ksmedia.h). Interleaved channel k maps to the k-th lowest set bit.
constexpr uint32_t kSpkFL = 0x1, kSpkFR = 0x2, kSpkFC = 0x4, kSpkLFE = 0x8, kSpkBL = 0x10, kSpkBR = 0x20,
                   kSpkBC = 0x100, kSpkSL = 0x200, kSpkSR = 0x400;
constexpr uint32_t kSpkKnownBits = 18;   // SPEAKER_FRONT_LEFT .. SPEAKER_TOP_BACK_RIGHT

// SDL2 channel orders, expressed as speaker masks:
//   1 mono | 2 FL FR | 3 FL FR LFE | 4 FL FR BL BR | 5 FL FR LFE BL BR | 6 FL FR FC LFE BL BR
//   7 FL FR FC LFE BC SL SR | 8 FL FR FC LFE BL BR SL SR
constexpr uint32_t kSdlMask[kMaxChannels + 1] = {
    0, kSpkFC, kSpkFL | kSpkFR, kSpkFL | kSpkFR | kSpkLFE, kSpkFL | kSpkFR | kSpkBL | kSpkBR,
    kSpkFL | kSpkFR | kSpkLFE | kSpkBL | kSpkBR, kSpkFL | kSpkFR | kSpkFC | kSpkLFE | kSpkBL | kSpkBR,
    kSpkFL | kSpkFR | kSpkFC | kSpkLFE | kSpkBC | kSpkSL | kSpkSR,
    kSpkFL | kSpkFR | kSpkFC | kSpkLFE | kSpkBL | kSpkBR | kSpkSL | kSpkSR,
};
// Windows default layouts (KSAUDIO_SPEAKER_*) used when dwChannelMask is absent/insufficient.
constexpr uint32_t kWinMask[kMaxChannels + 1] = {
    0, kSpkFC, kSpkFL | kSpkFR, kSpkFL | kSpkFR | kSpkFC, kSpkFL | kSpkFR | kSpkBL | kSpkBR,
    kSpkFL | kSpkFR | kSpkFC | kSpkBL | kSpkBR, kSpkFL | kSpkFR | kSpkFC | kSpkLFE | kSpkBL | kSpkBR,
    kSpkFL | kSpkFR | kSpkFC | kSpkLFE | kSpkBL | kSpkBR | kSpkBC,
    kSpkFL | kSpkFR | kSpkFC | kSpkLFE | kSpkBL | kSpkBR | kSpkSL | kSpkSR,
};

// Returns the mask actually used for `ch` interleaved channels.
uint32_t resolve_channel_mask(uint32_t ch, uint32_t mask) {
    if (ch == 0 || ch > kMaxChannels) return 0;
    if (mask == 0) return kSdlMask[ch];
    mask &= (1u << kSpkKnownBits) - 1u;
    uint32_t keep = 0, n = 0;
    for (uint32_t b = 0; b < kSpkKnownBits && n < ch; b++)
        if (mask & (1u << b)) { keep |= 1u << b; n++; }
    return n == ch ? keep : kWinMask[ch];   // fewer bits than channels -> Windows default layout
}

// Stereo fold-down gain of one speaker position (bit index).
void speaker_gain(uint32_t bit, float *l, float *r) {
    const float c = 0.70710678f;
    switch (bit) {
        case 0:  *l = 1.0f;    *r = 0.0f;    break;   // FL
        case 1:  *l = 0.0f;    *r = 1.0f;    break;   // FR
        case 2:  *l = c;       *r = c;       break;   // FC
        case 3:  *l = 0.0f;    *r = 0.0f;    break;   // LFE (dropped, as before)
        case 4:  *l = c;       *r = 0.0f;    break;   // BL
        case 5:  *l = 0.0f;    *r = c;       break;   // BR
        case 6:  *l = 0.9239f; *r = 0.3827f; break;   // FLC
        case 7:  *l = 0.3827f; *r = 0.9239f; break;   // FRC
        case 8:  *l = 0.5f;    *r = 0.5f;    break;   // BC
        case 9:  *l = c;       *r = 0.0f;    break;   // SL
        case 10: *l = 0.0f;    *r = c;       break;   // SR
        case 11: *l = 0.5f;    *r = 0.5f;    break;   // TC
        case 12: *l = c;       *r = 0.0f;    break;   // TFL
        case 13: *l = 0.5f;    *r = 0.5f;    break;   // TFC
        case 14: *l = 0.0f;    *r = c;       break;   // TFR
        case 15: *l = 0.5f;    *r = 0.0f;    break;   // TBL
        case 16: *l = 0.3536f; *r = 0.3536f; break;   // TBC
        default: *l = 0.0f;    *r = 0.5f;    break;   // TBR
    }
}

// Down-mix coefficients to stereo, honouring the speaker mask (SDL2 order when mask == 0).
void build_mix(AudioDev *d, uint32_t mask) {
    const uint32_t ch = d->spec.channels;
    float *L = d->mix_l, *R = d->mix_r;
    for (uint32_t i = 0; i < kMaxChannels; i++) L[i] = R[i] = 0.0f;
    d->chmask = resolve_channel_mask(ch, mask);
    if (ch == 1) {
        L[0] = R[0] = 1.0f;                                   // mono -> both, whatever the mask
    } else {
        uint32_t k = 0;
        for (uint32_t b = 0; b < kSpkKnownBits && k < ch; b++)
            if (d->chmask & (1u << b)) { speaker_gain(b, &L[k], &R[k]); k++; }
    }
    if (ch > 2) {   // normalise so a full-scale signal on every speaker cannot clip
        float sl = 0.0f, sr = 0.0f;
        for (uint32_t i = 0; i < ch; i++) { sl += L[i]; sr += R[i]; }
        const float m = sl > sr ? sl : sr;
        if (m > 0.0f) {
            const float n = 1.0f / m;
            for (uint32_t i = 0; i < ch; i++) { L[i] *= n; R[i] *= n; }
        }
    }
    const uint32_t outputs = d->output_channels;
    if (outputs <= 2) {
        for (uint32_t i = 0; i < ch; ++i) {
            d->mix[0][i] = outputs == 1 ? (L[i] + R[i]) * 0.5f : L[i];
            if (outputs == 2) d->mix[1][i] = R[i];
        }
    } else {
        const uint32_t output_mask = kWinMask[outputs];
        uint32_t input = 0;
        for (uint32_t bit = 0; bit < kSpkKnownBits; ++bit) {
            const uint32_t speaker = 1u << bit;
            if (!(d->chmask & speaker)) continue;
            uint32_t target = speaker;
            if (!(target & output_mask)) {
                switch (target) {
                    case kSpkSL: target = kSpkBL; break;
                    case kSpkSR: target = kSpkBR; break;
                    case kSpkBL: target = kSpkSL; break;
                    case kSpkBR: target = kSpkSR; break;
                }
            }
            if (target & output_mask) {
                const uint32_t output = std::popcount(output_mask & (target - 1));
                d->mix[output][input] = 1.0f;
            } else {
                d->mix[0][input] = L[input];
                d->mix[1][input] = R[input];
            }
            ++input;
        }
        for (uint32_t output = 0; output < outputs; ++output) {
            float sum = 0.0f;
            for (uint32_t i = 0; i < ch; ++i) sum += d->mix[output][i];
            if (sum > 1.0f)
                for (uint32_t i = 0; i < ch; ++i) d->mix[output][i] /= sum;
        }
    }
    d->identity_mix = ch == outputs;
    for (uint32_t i = 0; i < outputs; ++i)
        for (uint32_t j = 0; j < ch; ++j)
            d->identity_mix &= d->mix[i][j] == (i == j ? 1.0f : 0.0f);
}

inline float sample_to_f32(const uint8_t *p, uint16_t fmt) {
    const bool big_endian = fmt & 0x1000u;
    switch (fmt & ~0x1000u) {
        case BO3_AUDIO_U8: return (static_cast<int>(p[0]) - 128) / 128.0f;
        case BO3_AUDIO_S8: return std::bit_cast<int8_t>(p[0]) / 128.0f;
        case BO3_AUDIO_U16LSB: case BO3_AUDIO_S16LSB: {
            uint16_t v;
            memcpy(&v, p, sizeof(v));
            if (big_endian) v = __builtin_bswap16(v);
            if (fmt & 0x8000u) return std::bit_cast<int16_t>(v) / 32768.0f;
            return (static_cast<int>(v) - 32768) / 32768.0f;
        }
        default: {
            uint32_t v;
            memcpy(&v, p, sizeof(v));
            if (big_endian) v = __builtin_bswap32(v);
            if (fmt & 0x0100u) return std::bit_cast<float>(v);
            if (fmt & 0x8000u) return std::bit_cast<int32_t>(v) / 2147483648.0f;
            return static_cast<float>((static_cast<double>(v) - 2147483648.0) / 2147483648.0);
        }
    }
}

// CoreAudio real-time render callback: no locks, no allocation, no ObjC.
OSStatus render_cb(void *refcon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                   UInt32 bus, UInt32 nframes, AudioBufferList *io) {
    (void)ts; (void)bus;
    AudioDev *d = static_cast<AudioDev *>(refcon);
    d->st_calls.fetch_add(1, std::memory_order_relaxed);
    if (!io || io->mNumberBuffers < 1 || !io->mBuffers[0].mData) return noErr;

    const uint32_t outputs = d->output_channels;
    float *out = static_cast<float *>(io->mBuffers[0].mData);
    const uint32_t out_frames_cap = io->mBuffers[0].mDataByteSize / (outputs * sizeof(float));
    nframes = std::min(nframes, out_frames_cap);

    if (d->paused.load(std::memory_order_acquire)) {
        const uint64_t f = d->flush_to.load(std::memory_order_acquire);
        if (f > d->rpos.load(std::memory_order_relaxed)) d->rpos.store(f, std::memory_order_release);
        memset(out, 0, static_cast<size_t>(nframes) * outputs * sizeof(float));
        if (flags) *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    uint64_t r = d->rpos.load(std::memory_order_relaxed);
    const uint64_t flush = d->flush_to.load(std::memory_order_acquire);
    if (flush > r) r = flush;
    const uint64_t w = d->wpos.load(std::memory_order_acquire);
    const uint32_t bpf = d->bpf, bps = d->bytes_per_sample, ch = d->spec.channels;
    const uint16_t fmt = d->spec.format;
    const uint64_t cap = d->cap;
    const float g = d->gain.load(std::memory_order_relaxed);

    uint64_t avail = (w > r) ? (w - r) / bpf : 0;
    uint32_t n = (avail < nframes) ? (uint32_t)avail : nframes;
    uint32_t done = 0;
    while (done < n) {
        const uint64_t off = r % cap;
        uint32_t chunk = (uint32_t)((cap - off) / bpf);
        if (chunk > n - done) chunk = n - done;
        const uint8_t *src = d->ring + off;
        float *dst = out + static_cast<size_t>(done) * outputs;
        if (fmt == BO3_AUDIO_F32LSB && d->identity_mix) {
            const size_t bytes = static_cast<size_t>(chunk) * bpf;
            memcpy(dst, src, bytes);
            if (g != 1.0f)
                for (uint32_t i = 0; i < chunk * outputs; ++i) dst[i] *= g;
        } else {
            for (uint32_t i = 0; i < chunk; ++i) {
                const uint8_t *fr = src + static_cast<size_t>(i) * bpf;
                float samples[kMaxChannels];
                for (uint32_t c = 0; c < ch; ++c) samples[c] = sample_to_f32(fr + c * bps, fmt);
                for (uint32_t output = 0; output < outputs; ++output) {
                    float mixed = 0.0f;
                    for (uint32_t c = 0; c < ch; ++c) {
                        const float weight = d->mix[output][c];
                        if (weight != 0.0f) mixed += samples[c] * weight;
                    }
                    dst[i * outputs + output] = mixed * g;
                }
            }
        }
        r += (uint64_t)chunk * bpf;
        done += chunk;
    }
    // Acknowledge consumption (and any flush skip) only after every read of the ring is done.
    d->rpos.store(r, std::memory_order_release);
    if (n < nframes) {
        memset(out + (size_t)n * outputs, 0, (size_t)(nframes - n) * outputs * sizeof(float));
        d->st_underrun.fetch_add(nframes - n, std::memory_order_relaxed);
    }
    if (n == 0 && flags) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    d->st_frames.fetch_add(n, std::memory_order_relaxed);
    return noErr;
}

void destroy_dev(AudioDev *d) {
    if (!d) return;
    if (d->unit) {
        if (d->running) AudioOutputUnitStop(d->unit);
        AudioUnitUninitialize(d->unit);
        AudioComponentInstanceDispose(d->unit);
        d->unit = nullptr;
    }
    free(d->ring);
    delete d;
}

uint64_t queued_bytes(const AudioDev *d) {
    const uint64_t w = d->wpos.load(std::memory_order_acquire);
    uint64_t r = d->rpos.load(std::memory_order_acquire);
    const uint64_t f = d->flush_to.load(std::memory_order_relaxed);
    if (f > r) r = f;
    return (w > r ? w - r : 0) + d->carry_len;
}

// Producer push of whole frames; returns bytes accepted.
// Free space is bounded ONLY by the consumer-acknowledged rpos (acquire pairs with the render
// thread's release store): space covered by a not-yet-acknowledged flush may still be under the
// render callback's read cursor, so it is never reclaimed early.
uint64_t ring_push(AudioDev *d, const uint8_t *src, uint64_t len) {
    const uint64_t w = d->wpos.load(std::memory_order_relaxed);
    const uint64_t r = d->rpos.load(std::memory_order_acquire);
    const uint64_t free_b = d->cap - (w - r);
    uint64_t n = len < free_b ? len : free_b;
    n -= n % d->bpf;
    uint64_t off = w % d->cap, done = 0;
    while (done < n) {
        uint64_t chunk = d->cap - off;
        if (chunk > n - done) chunk = n - done;
        memcpy(d->ring + off, src + done, (size_t)chunk);
        done += chunk;
        off = 0;
    }
    d->wpos.store(w + n, std::memory_order_release);
    return n;
}

AudioDeviceID default_output_device() {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device) != noErr)
        return kAudioObjectUnknown;
    return device;
}

struct OutputFormat {
    uint32_t channels;
    uint32_t rate;
};

OutputFormat default_output_format() {
    const AudioDeviceID device = default_output_device();
    if (device == kAudioObjectUnknown) return {};
    AudioObjectPropertyAddress address = { kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &rate) != noErr ||
        !(rate >= 1 && rate <= 384000)) return {};

    address.mSelector = kAudioDevicePropertyStreamConfiguration;
    address.mScope = kAudioDevicePropertyScopeOutput;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr ||
        size < offsetof(AudioBufferList, mBuffers)) return {};
    std::unique_ptr<void, decltype(&free)> buffers(malloc(size), free);
    if (!buffers || AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, buffers.get()) != noErr)
        return {};
    const auto *list = static_cast<const AudioBufferList *>(buffers.get());
    const size_t header = offsetof(AudioBufferList, mBuffers);
    if (size < header || list->mNumberBuffers > (size - header) / sizeof(AudioBuffer)) return {};
    uint32_t channels = 0;
    const AudioBuffer *streams = list->mBuffers;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) channels += streams[i].mNumberChannels;
    return {channels > kMaxChannels ? 2u : channels, static_cast<uint32_t>(std::lround(rate))};
}

// Keep previously returned names valid across default-device changes.
std::mutex g_device_names_mutex;
std::set<std::string> g_device_names;

const char *query_default_output_name() {
    const AudioDeviceID dev = default_output_device();
    if (dev == kAudioObjectUnknown) return nullptr;
    AudioObjectPropertyAddress a = { kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    CFStringRef name = nullptr;
    sz = sizeof(name);
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &sz, &name) == noErr && name) {
        char utf8[256];
        const bool copied = CFStringGetCString(name, utf8, sizeof(utf8), kCFStringEncodingUTF8) && utf8[0];
        CFRelease(name);
        if (copied) {
            std::lock_guard<std::mutex> lock(g_device_names_mutex);
            try { return g_device_names.emplace(utf8).first->c_str(); }
            catch (const std::bad_alloc &) {}
        }
    }
    return "Default Output";
}

using AudioDevicePtr = std::unique_ptr<AudioDev, decltype(&destroy_dev)>;

AudioDev *open_device(const Bo3SdlAudioSpec *desired, uint32_t channel_mask) {
    if (!desired) { set_error("NULL desired spec"); return nullptr; }
    if (desired->callback) { set_error("callback mode not supported (BO3 uses queue mode)"); return nullptr; }

    Bo3SdlAudioSpec s = *desired;
    if (s.freq <= 0) s.freq = 22050;
    if (s.format == 0) s.format = BO3_AUDIO_S16LSB;
    if (s.channels == 0) s.channels = 2;
    const uint32_t bps = format_bytes(s.format);
    if (!bps) { set_error("unsupported SDL audio format 0x%04x", s.format); return nullptr; }
    if (s.channels > kMaxChannels) { set_error("unsupported channel count %u", s.channels); return nullptr; }
    if (s.freq > 384000) { set_error("unsupported sample rate %d", s.freq); return nullptr; }
    if (s.samples == 0) {   // SDL default: ~46 ms rounded to pow2
        uint32_t want = (uint32_t)s.freq / 1000u * 46u, p = 1;
        while (p < want && p < 32768u) p <<= 1;
        s.samples = (uint16_t)p;
    }
    s.silence = (s.format & 0x8000u) ? 0x00 : 0x80;
    s.padding = 0;
    s.size = (uint32_t)s.samples * s.channels * bps;

    AudioDevicePtr dev(new (std::nothrow) AudioDev(), destroy_dev);
    AudioDev *d = dev.get();
    if (!d) { set_error("device alloc failed"); return nullptr; }
    d->spec = s;
    d->bytes_per_sample = bps;
    d->bpf = bps * s.channels;
    uint64_t frames = (uint64_t)s.freq * 2u;              // >= 2 s of headroom
    if (frames < (uint64_t)s.samples * 16u) frames = (uint64_t)s.samples * 16u;
    d->cap = frames * d->bpf;
    d->ring = static_cast<uint8_t *>(calloc(1, (size_t)d->cap));
    if (!d->ring) { set_error("ring alloc failed"); return nullptr; }

    AudioComponentDescription desc = {};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
    OSStatus st = comp ? AudioComponentInstanceNew(comp, &d->unit) : (OSStatus)-1;
    if (st != noErr || !d->unit) {
        set_error("AudioComponentInstanceNew failed (%d)", (int)st);
        return nullptr;
    }

    AudioStreamBasicDescription hardware = {};
    UInt32 size = sizeof(hardware);
    st = AudioUnitGetProperty(d->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                              &hardware, &size);
    if (st != noErr || !hardware.mChannelsPerFrame || !(hardware.mSampleRate > 0)) {
        set_error("Output stream format unavailable (%d)", (int)st);
        return nullptr;
    }
    d->output_channels = hardware.mChannelsPerFrame > kMaxChannels ? 2 : hardware.mChannelsPerFrame;
    build_mix(d, channel_mask);

    // DefaultOutput resamples this client-side rate to the hardware rate and follows the default
    // device. Our callback's channel layout is fixed for the lifetime of this AudioUnit.
    AudioStreamBasicDescription asbd = {};
    asbd.mSampleRate = (Float64)s.freq;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;   // interleaved
    asbd.mChannelsPerFrame = d->output_channels;
    asbd.mBitsPerChannel = 32;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = d->output_channels * sizeof(float);
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    st = AudioUnitSetProperty(d->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                              &asbd, sizeof(asbd));
    if (st != noErr) { set_error("StreamFormat failed (%d)", (int)st); return nullptr; }

    if (d->output_channels > 2) {
        constexpr AudioChannelLayoutTag wave_layouts[] = {
            0, 0, 0, kAudioChannelLayoutTag_WAVE_3_0, kAudioChannelLayoutTag_WAVE_4_0_B,
            kAudioChannelLayoutTag_WAVE_5_0_B, kAudioChannelLayoutTag_WAVE_5_1_B,
            0, kAudioChannelLayoutTag_WAVE_7_1
        };
        AudioChannelLayout layout{};
        layout.mChannelLayoutTag = wave_layouts[d->output_channels];
        if (!layout.mChannelLayoutTag) {
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap;
            layout.mChannelBitmap = kWinMask[d->output_channels];
        }
        st = AudioUnitSetProperty(d->unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0,
                                  &layout, sizeof(layout));
        // Some devices expose multichannel PCM with an implicit positional layout.
        if (st != noErr && st != kAudioUnitErr_InvalidProperty && st != kAudioUnitErr_PropertyNotWritable) {
            set_error("AudioChannelLayout failed (%d)", (int)st);
            return nullptr;
        }
    }

    AURenderCallbackStruct cb = { render_cb, d };
    st = AudioUnitSetProperty(d->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                              &cb, sizeof(cb));
    if (st != noErr) { set_error("SetRenderCallback failed (%d)", (int)st); return nullptr; }

    st = AudioUnitInitialize(d->unit);
    if (st != noErr) { set_error("AudioUnitInitialize failed (%d)", (int)st); return nullptr; }

    AudioStreamBasicDescription negotiated = {};
    size = sizeof(negotiated);
    st = AudioUnitGetProperty(d->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                              &negotiated, &size);
    if (st != noErr || negotiated.mSampleRate != asbd.mSampleRate ||
        negotiated.mChannelsPerFrame != asbd.mChannelsPerFrame ||
        negotiated.mFormatID != asbd.mFormatID || negotiated.mBytesPerFrame != asbd.mBytesPerFrame ||
        !(negotiated.mFormatFlags & kAudioFormatFlagIsFloat) ||
        (negotiated.mFormatFlags & kAudioFormatFlagIsNonInterleaved)) {
        set_error("Incompatible AudioUnit input stream format (%d)", (int)st);
        return nullptr;
    }
    return dev.release();
}

OSStatus start_device(AudioDev *d) {
    d->paused.store(false, std::memory_order_release);
    const OSStatus status = AudioOutputUnitStart(d->unit);
    if (status == noErr) d->running = true;
    else d->paused.store(true, std::memory_order_release);
    return status;
}

OSStatus stop_device(AudioDev *d) {
    d->paused.store(true, std::memory_order_release);
    const OSStatus status = AudioOutputUnitStop(d->unit);
    if (status == noErr) d->running = false;
    else d->paused.store(false, std::memory_order_release);
    return status;
}

} // namespace

// =========================================================================================
// 2. Public C API
// =========================================================================================

extern "C" const char *bo3_audio_last_error(void) { return t_last_error; }

extern "C" uint32_t bo3_audio_open(const Bo3SdlAudioSpec *desired, Bo3SdlAudioSpec *obtained) {
    return bo3_audio_open_with_mask(desired, obtained, 0);
}

extern "C" uint32_t bo3_audio_open_with_mask(const Bo3SdlAudioSpec *desired, Bo3SdlAudioSpec *obtained,
                                             uint32_t channel_mask) {
    AudioDevicePtr dev(open_device(desired, channel_mask), destroy_dev);
    AudioDev *d = dev.get();
    if (!d) return 0;
    const Bo3SdlAudioSpec s = d->spec;
    const uint64_t capacity = d->cap;
    // Reserve a slot (invisible to lookups), start the unit, and only then publish the id, so no
    // other thread can ever reach a device whose AudioUnit failed to start.
    int slot = -1;
    {
        ApiLock lk;
        for (uint32_t i = 0; i < BO3_AUDIO_MAX_DEVICES; i++) {
            if (!g_devs[i] && !g_reserved[i]) { slot = (int)i; g_reserved[i] = true; break; }
        }
    }
    if (slot < 0) { set_error("too many audio devices"); return 0; }
    const OSStatus st = AudioOutputUnitStart(d->unit);       // runs continuously; paused => silence
    if (st != noErr) {
        set_error("AudioOutputUnitStart failed (%d)", (int)st);
        { ApiLock lk; g_reserved[slot] = false; }
        return 0;
    }
    uint32_t id;
    {
        ApiLock lk;
        do {
            id = g_next_device_id++;
            if (g_next_device_id < BO3_AUDIO_FIRST_DEVICE_ID) g_next_device_id = BO3_AUDIO_FIRST_DEVICE_ID;
        } while (lookup_locked(id));
        d->id = id;
        g_reserved[slot] = false;
        d->running = true;
        g_devs[slot] = dev.release();
    }
    if (obtained) *obtained = s;
    fprintf(stderr, "[audio] open dev=%u %d Hz fmt=0x%04x ch=%u samples=%u ring=%llu B\n",
            id, s.freq, s.format, s.channels, s.samples, (unsigned long long)capacity);
    return id;
}

extern "C" int bo3_audio_queue(uint32_t id, const void *data, uint32_t len) {
    ApiLock lk;
    AudioDev *d = lookup_locked(id);
    if (!d) { set_error("Invalid audio device ID"); return -1; }
    if (len == 0) return 0;
    if (!data) { set_error("NULL data"); return -1; }
    const uint8_t *p = static_cast<const uint8_t *>(data);
    const uint64_t w = d->wpos.load(std::memory_order_relaxed);
    const uint64_t r = d->rpos.load(std::memory_order_acquire);
    if (len > d->cap - (w - r) - d->carry_len) {
        d->st_dropped.fetch_add(len, std::memory_order_relaxed);
        set_error("Audio queue is full");
        return -1;
    }
    uint64_t left = len;

    if (d->carry_len) {                       // complete a partial frame first
        uint32_t need = d->bpf - d->carry_len;
        uint32_t take = left < need ? (uint32_t)left : need;
        memcpy(d->carry + d->carry_len, p, take);
        d->carry_len += take; p += take; left -= take;
        if (d->carry_len == d->bpf) {
            ring_push(d, d->carry, d->bpf);
            d->carry_len = 0;
        }
    }
    const uint64_t whole = left - left % d->bpf;
    if (whole) {
        ring_push(d, p, whole);
        p += whole; left -= whole;
    }
    if (left) { memcpy(d->carry, p, (size_t)left); d->carry_len = (uint32_t)left; }
    return 0;
}

extern "C" void bo3_audio_pause(uint32_t id, int pause_on) {
    ApiLock lk;
    AudioDev *d = lookup_locked(id);
    if (!d) { set_error("Invalid audio device ID"); return; }
    d->paused.store(pause_on != 0, std::memory_order_release);
}

extern "C" void bo3_audio_close(uint32_t id) {
    AudioDev *d = nullptr;
    {
        ApiLock lk;
        AudioDev **slot = lookup_slot_locked(id);
        if (!slot) { set_error("Invalid audio device ID"); return; }
        d = *slot;
        *slot = nullptr;
    }
    fprintf(stderr, "[audio] close dev=%u (rendered=%llu underrun=%llu dropped=%llu)\n", id,
            (unsigned long long)d->st_frames.load(), (unsigned long long)d->st_underrun.load(),
            (unsigned long long)d->st_dropped.load());
    destroy_dev(d);
}

extern "C" uint32_t bo3_audio_get_queued_bytes(uint32_t id) {
    ApiLock lk;
    AudioDev *d = lookup_locked(id);
    if (!d) return 0;
    const uint64_t q = queued_bytes(d);
    return q > 0xffffffffu ? 0xffffffffu : (uint32_t)q;
}

extern "C" void bo3_audio_clear(uint32_t id) {
    ApiLock lk;
    AudioDev *d = lookup_locked(id);
    if (!d) return;
    d->carry_len = 0;
    // Request only: queued_bytes() reports 0 immediately, but the producer keeps honouring the old
    // rpos until the render thread acknowledges the skip.
    d->flush_to.store(d->wpos.load(std::memory_order_relaxed), std::memory_order_release);
}

extern "C" void bo3_audio_set_gain(uint32_t id, float gain) {
    ApiLock lk;
    AudioDev *d = lookup_locked(id);
    if (!d) return;
    if (!std::isfinite(gain) || gain < 0.0f) gain = 0.0f;
    d->gain.store(gain, std::memory_order_relaxed);
}

extern "C" int bo3_audio_get_stats(uint32_t id, Bo3AudioStats *out) {
    ApiLock lk;
    AudioDev *d = lookup_locked(id);
    if (!d || !out) return -1;
    out->render_calls = d->st_calls.load(std::memory_order_relaxed);
    out->frames_rendered = d->st_frames.load(std::memory_order_relaxed);
    out->underrun_frames = d->st_underrun.load(std::memory_order_relaxed);
    out->dropped_bytes = d->st_dropped.load(std::memory_order_relaxed);
    return 0;
}

extern "C" int bo3_audio_debug_info(uint32_t id, Bo3AudioDebugInfo *out) {
    ApiLock lk;
    AudioDev *d = lookup_locked(id);
    if (!d || !out) return -1;
    memset(out, 0, sizeof(*out));
    out->wpos = d->wpos.load(std::memory_order_acquire);
    out->rpos = d->rpos.load(std::memory_order_acquire);
    out->flush_to = d->flush_to.load(std::memory_order_acquire);
    out->cap = d->cap;
    out->channel_mask = d->chmask;
    out->format = d->spec.format;
    out->channels = d->spec.channels;
    out->silence = d->spec.silence;
    out->paused = d->paused.load(std::memory_order_relaxed) ? 1 : 0;
    out->gain = d->gain.load(std::memory_order_relaxed);
    for (uint32_t i = 0; i < kMaxChannels; i++) { out->mix_l[i] = d->mix_l[i]; out->mix_r[i] = d->mix_r[i]; }
    return 0;
}

extern "C" uint32_t bo3_audio_debug_peek(uint32_t id, uint64_t pos, void *dst, uint32_t len) {
    ApiLock lk;   // producer excluded; the consumer only reads the ring
    AudioDev *d = lookup_locked(id);
    if (!d || !dst) return 0;
    const uint64_t w = d->wpos.load(std::memory_order_relaxed);
    const uint64_t r = d->rpos.load(std::memory_order_acquire);
    if (pos < r || pos >= w) return 0;
    if ((uint64_t)len > w - pos) len = (uint32_t)(w - pos);
    uint8_t *o = static_cast<uint8_t *>(dst);
    for (uint32_t i = 0; i < len; i++) o[i] = d->ring[(pos + i) % d->cap];
    return len;
}

extern "C" int bo3_audio_get_num_devices(int iscapture) {
    return !iscapture && default_output_device() != kAudioObjectUnknown ? 1 : 0;
}

extern "C" const char *bo3_audio_get_device_name(int index, int iscapture) {
    return !iscapture && index == 0 ? query_default_output_name() : nullptr;
}

// =========================================================================================
// 3. SDL2-ABI guest shims
// =========================================================================================

extern "C" GuestRet bo3_shim_SDL_OpenAudioDevice(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    // (const char *device, int iscapture, const SDL_AudioSpec *desired, SDL_AudioSpec *obtained, int allowed_changes)
    if ((int32_t)rsi != 0) {
        fprintf(stderr, "[audio] SDL_OpenAudioDevice: capture not supported\n");
        return ret_u64(0);
    }
    if (rdi) {
        const char *name = bo3_audio_get_device_name(0, 0);
        if (!name || strcmp(reinterpret_cast<const char *>(rdi), name) != 0) {
            set_error("Unknown audio device");
            return ret_u64(0);
        }
    }
    const Bo3SdlAudioSpec *desired = reinterpret_cast<const Bo3SdlAudioSpec *>(rdx);
    Bo3SdlAudioSpec *obtained = reinterpret_cast<Bo3SdlAudioSpec *>(rcx);
    Bo3SdlAudioSpec tmp{};
    const uint32_t id = bo3_audio_open(desired, &tmp);
    if (!id) {
        fprintf(stderr, "[audio] SDL_OpenAudioDevice failed: %s\n", bo3_audio_last_error());
        return ret_u64(0);
    }
    if (obtained) {
        tmp.callback = desired->callback;
        tmp.userdata = desired->userdata;
        *obtained = tmp;
    }
    return ret_u64(id);
}

extern "C" GuestRet bo3_shim_SDL_QueueAudio(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    const int rc = bo3_audio_queue((uint32_t)rdi, reinterpret_cast<const void *>(rsi), (uint32_t)rdx);
    return ret_i64(rc);                       // int -1 sign-extended into rax, as SDL2 returns it
}

extern "C" GuestRet bo3_shim_SDL_PauseAudioDevice(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    bo3_audio_pause((uint32_t)rdi, (int32_t)rsi);
    return ret_void();
}

extern "C" GuestRet bo3_shim_SDL_CloseAudioDevice(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    bo3_audio_close((uint32_t)rdi);
    return ret_void();
}

extern "C" GuestRet bo3_shim_SDL_GetQueuedAudioSize(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_u64(bo3_audio_get_queued_bytes((uint32_t)rdi));
}

extern "C" GuestRet bo3_shim_SDL_ClearQueuedAudio(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    bo3_audio_clear((uint32_t)rdi);
    return ret_void();
}

// SDL's device lock protects the application's callback. This backend only supports queue mode,
// and its CoreAudio callback never calls guest code or acquires a guest-thread lock.
extern "C" GuestRet bo3_shim_SDL_LockAudioDevice(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_void();
}

extern "C" GuestRet bo3_shim_SDL_UnlockAudioDevice(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_void();
}

extern "C" GuestRet bo3_shim_SDL_GetNumAudioDevices(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_i64(bo3_audio_get_num_devices((int32_t)rdi));
}

extern "C" GuestRet bo3_shim_SDL_GetAudioDeviceName(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_ptr(bo3_audio_get_device_name((int32_t)rdi, (int32_t)rsi));
}

// =========================================================================================
// 4. WASAPI COM emulation (mirrors Aspyr ASL 0x100108764..0x100109964)
// =========================================================================================

namespace {

// HRESULTs
constexpr uint32_t S_OK_                    = 0x00000000u;
constexpr uint32_t S_FALSE_                 = 0x00000001u;
constexpr uint32_t E_NOINTERFACE_           = 0x80004002u;
constexpr uint32_t E_POINTER_               = 0x80004003u;
constexpr uint32_t E_OUTOFMEMORY_          = 0x8007000Eu;
constexpr uint32_t E_INVALIDARG_            = 0x80070057u;
constexpr uint32_t E_NOTFOUND_              = 0x80070490u; // Aspyr's "not implemented" answer
constexpr uint32_t AUDCLNT_E_NOT_INITIALIZED      = 0x88890001u;
constexpr uint32_t AUDCLNT_E_ALREADY_INITIALIZED  = 0x88890002u;
constexpr uint32_t AUDCLNT_E_NOT_STOPPED          = 0x88890005u;
constexpr uint32_t AUDCLNT_E_BUFFER_TOO_LARGE     = 0x88890006u;
constexpr uint32_t AUDCLNT_E_OUT_OF_ORDER         = 0x88890007u;
constexpr uint32_t AUDCLNT_E_UNSUPPORTED_FORMAT   = 0x88890008u;
constexpr uint32_t AUDCLNT_E_INVALID_SIZE         = 0x88890009u;
constexpr uint32_t AUDCLNT_E_DEVICE_INVALIDATED   = 0x88890004u;
constexpr uint32_t AUDCLNT_E_BUFFER_OPERATION_PENDING = 0x8889000Bu;
constexpr uint32_t AUDCLNT_E_EVENTHANDLE_NOT_EXPECTED = 0x88890011u;
constexpr uint32_t AUDCLNT_E_EVENTHANDLE_NOT_SET  = 0x88890014u;

constexpr uint32_t AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x00040000u;
constexpr uint32_t AUDCLNT_BUFFERFLAGS_SILENT        = 0x2u;

struct Guid { uint32_t d1; uint16_t d2, d3; uint8_t d4[8]; };
static_assert(sizeof(Guid) == 16, "GUID");
constexpr Guid IID_IUnknown_              = {0x00000000, 0x0000, 0x0000, {0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};
constexpr Guid IID_IMMDeviceEnumerator_   = {0xA95664D2, 0x9614, 0x4F35, {0xA7,0x46,0xDE,0x8D,0xB6,0x36,0x17,0xE6}};
constexpr Guid CLSID_MMDeviceEnumerator_  = {0xBCDE0395, 0xE52F, 0x467C, {0x8E,0x3D,0xC4,0x57,0x92,0x91,0x69,0x2E}};
constexpr Guid IID_IMMDevice_             = {0xD666063F, 0x1587, 0x4E43, {0x81,0xF1,0xB9,0x48,0xE8,0x07,0x36,0x3F}};
// Aspyr's copy in BO3 (0x1017e2630) has a typo'd Data2 (0x0158); accept it too.
constexpr Guid IID_IMMDevice_aspyr_       = {0xD666063F, 0x0158, 0x4E43, {0x81,0xF1,0xB9,0x48,0xE8,0x07,0x36,0x3F}};
constexpr Guid IID_IAudioClient_          = {0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1,0x78,0xC2,0xF5,0x68,0xA7,0x03,0xB2}};
constexpr Guid IID_IAudioRenderClient_    = {0xF294ACFC, 0x3146, 0x4483, {0xA7,0xBF,0xAD,0xDC,0xA7,0xC2,0x60,0xE2}};
constexpr Guid IID_IAudioSessionControl_  = {0xF4B1A599, 0x7266, 0x4319, {0xA8,0xCA,0xE7,0x0A,0xCB,0x11,0xE8,0xCD}};
constexpr Guid KSDATAFORMAT_SUBTYPE_PCM_        = {0x00000001, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71}};
constexpr Guid KSDATAFORMAT_SUBTYPE_IEEE_FLOAT_ = {0x00000003, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71}};

inline bool guid_eq(const void *a, const Guid &b) { return a && memcmp(a, &b, 16) == 0; }

#pragma pack(push, 1)
struct WaveFormatEx {           // WAVEFORMATEXTENSIBLE (40 bytes)
    uint16_t wFormatTag;
    uint16_t nChannels;
    uint32_t nSamplesPerSec;
    uint32_t nAvgBytesPerSec;
    uint16_t nBlockAlign;
    uint16_t wBitsPerSample;
    uint16_t cbSize;
    uint16_t wValidBitsPerSample;
    uint32_t dwChannelMask;
    Guid     SubFormat;
};
#pragma pack(pop)
static_assert(sizeof(WaveFormatEx) == 40, "WAVEFORMATEXTENSIBLE");

// ---- vtable slots: synthetic guest VAs from bo3_com_register_thunk() ----
enum : uint32_t {
    VT_ENUM = 0,     // 8  IMMDeviceEnumerator
    VT_DEV  = 8,     // 7  IMMDevice
    VT_CLI  = 15,    // 15 IAudioClient
    VT_REN  = 30,    // 5  IAudioRenderClient
    VT_SES  = 35,    // 12 IAudioSessionControl
    VT_COUNT = 47,
};
uint64_t g_vt[VT_COUNT];

struct EventHooks {
    Bo3AudioSignalEventFn signal = nullptr;
    Bo3AudioRetainEventFn retain = nullptr;
    Bo3AudioReleaseEventFn release = nullptr;
};
std::mutex g_event_hooks_mutex;
EventHooks g_event_hooks;

struct EventRegistration {
    uint64_t handle;
    EventHooks hooks;
};

constexpr uint64_t kEventPeriodNs = 5 * NSEC_PER_MSEC;
constexpr uint64_t kEventLeewayNs = 500 * NSEC_PER_USEC;

struct ComObj { const uint64_t *vtbl; std::atomic<uint32_t> ref{1}; };
struct WRender;

// The last client or render reference owns teardown. Only the render callback consumes the ring
// while the unit is running. The core mutex serializes guest calls, including Start/Stop/Reset.
struct ClientCore {
    std::mutex mtx;
    AudioDevicePtr device{nullptr, destroy_dev};
    uint32_t flags = 0;
    uint32_t buffer_frames = 0;
    WRender *buffer_owner = nullptr;
    bool needs_reset = false;
    std::atomic<bool> started{false};
    std::atomic<EventRegistration *> event{nullptr};
    dispatch_source_t timer = nil;

    ~ClientCore();
};

struct WDevice;
struct WEnum : ComObj { std::mutex mtx; WDevice *dev = nullptr; uint64_t notify = 0; };
struct WDevice : ComObj {};
struct WClient : ComObj { std::shared_ptr<ClientCore> core; };
struct WRender : ComObj {
    std::shared_ptr<ClientCore> core;
    std::unique_ptr<uint8_t[]> buf;
    uint32_t pending = 0;
    bool zero_requested = false;
    pthread_t buffer_thread = nullptr;
};
struct WSession : ComObj { std::mutex mtx; uint64_t notify = 0; };

dispatch_queue_t timer_queue() {
    static dispatch_queue_t q = dispatch_queue_create("bo3.audio.wasapi.event", DISPATCH_QUEUE_SERIAL);
    return q;
}

inline GuestRet hr(uint32_t v) { return ret_u64(v); }
inline uint32_t addref(ComObj *o) { return o->ref.fetch_add(1, std::memory_order_relaxed) + 1; }
inline uint32_t drop_ref(ComObj *o) { return o->ref.fetch_sub(1, std::memory_order_acq_rel) - 1; }

void stop_timer(ClientCore *c) {
    if (!c->timer) return;
    dispatch_source_cancel(c->timer);
    c->timer = nil;
    dispatch_sync(timer_queue(), ^{});
}

void release_event(EventRegistration *event) {
    if (!event) return;
    event->hooks.release(event->handle);
    delete event;
}

ClientCore::~ClientCore() {
    started.store(false, std::memory_order_release);
    stop_timer(this);
    release_event(event.load(std::memory_order_relaxed));
}

uint32_t core_padding_frames(const ClientCore *c) {
    const AudioDev *d = c->device.get();
    const uint64_t w = d->wpos.load(std::memory_order_acquire);
    const uint64_t r = d->rpos.load(std::memory_order_acquire);
    return w > r ? static_cast<uint32_t>((w - r) / d->bpf) : 0;
}

uint16_t wave_sample_format(const WaveFormatEx &fmt) {
    if (!fmt.nChannels || fmt.nChannels > kMaxChannels ||
        fmt.nSamplesPerSec < 1000 || fmt.nSamplesPerSec > 384000) return 0;

    uint16_t tag = fmt.wFormatTag;
    if (tag == 0xFFFEu) {
        if (fmt.cbSize < 22 || fmt.wValidBitsPerSample != fmt.wBitsPerSample) return 0;
        const uint32_t mask = fmt.dwChannelMask;
        if (mask && (mask >> kSpkKnownBits || std::popcount(mask) != fmt.nChannels)) return 0;
        if (guid_eq(&fmt.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT_)) tag = 3;
        else if (guid_eq(&fmt.SubFormat, KSDATAFORMAT_SUBTYPE_PCM_)) tag = 1;
        else return 0;
    }
    uint16_t format = 0;
    if (tag == 3 && fmt.wBitsPerSample == 32) format = BO3_AUDIO_F32LSB;
    if (tag == 1) {
        switch (fmt.wBitsPerSample) {
            case 8: format = BO3_AUDIO_U8; break;
            case 16: format = BO3_AUDIO_S16LSB; break;
            case 32: format = BO3_AUDIO_S32LSB; break;
        }
    }
    const uint32_t align = format_bytes(format) * fmt.nChannels;
    if (!align || fmt.nBlockAlign != align || fmt.nAvgBytesPerSec != fmt.nSamplesPerSec * align)
        return 0;
    return format;
}

uint32_t allocate_mix_format(uint64_t *out) {
    *out = 0;
    const auto [channels, rate] = default_output_format();
    if (!channels) return AUDCLNT_E_DEVICE_INVALIDATED;
    auto *fmt = static_cast<WaveFormatEx *>(malloc(sizeof(WaveFormatEx)));
    if (!fmt) return E_OUTOFMEMORY_;
    *fmt = {0xFFFE, static_cast<uint16_t>(channels), rate, rate * channels * 4,
            static_cast<uint16_t>(channels * 4), 32, 22, 32, kWinMask[channels],
            KSDATAFORMAT_SUBTYPE_IEEE_FLOAT_};
    *out = reinterpret_cast<uint64_t>(fmt);
    return S_OK_;
}

// Calls guest COM method `slot` (no extra args) on guest object `obj` — used for the AddRef/Release
// of guest-implemented callback interfaces. Never call with a native lock held.
uint32_t guest_com_call0(GuestContext *ctx, uint64_t rsp, uint64_t obj, unsigned slot) {
    if (!ctx || !obj) return 0;
    const uint64_t vt = *reinterpret_cast<const uint64_t *>(obj);
    if (!vt) return 0;
    const uint64_t fn_va = reinterpret_cast<const uint64_t *>(vt)[slot];
    GuestFn fn = fn_va ? bo3_resolve(fn_va, ctx) : nullptr;
    if (!fn) return 0;
    uint64_t sp = ((rsp - 128ULL) & ~15ULL) - 8ULL;   // below our caller's frame, aligned, fake ret PC
    *reinterpret_cast<uint64_t *>(sp) = 0;
    const GuestRet r = fn(ctx, sp, obj, 0, 0, 0, 0, 0,
                          guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
                          guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    return (uint32_t)r.rax_rdx[0];
}
inline void guest_addref(GuestContext *ctx, uint64_t rsp, uint64_t obj) { guest_com_call0(ctx, rsp, obj, 1); }
inline void guest_release(GuestContext *ctx, uint64_t rsp, uint64_t obj) { guest_com_call0(ctx, rsp, obj, 2); }

// ------------------------------- IMMDeviceEnumerator -------------------------------------
GuestRet en_qi(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *self = reinterpret_cast<WEnum *>(rdi);
    uint64_t *ppv = reinterpret_cast<uint64_t *>(rdx);
    if (!ppv) return hr(E_POINTER_);
    *ppv = 0;
    if (!rsi) return hr(E_POINTER_);
    if (guid_eq((const void *)rsi, IID_IUnknown_) || guid_eq((const void *)rsi, IID_IMMDeviceEnumerator_)) {
        addref(self); *ppv = rdi; return hr(S_OK_);
    }
    return hr(E_NOINTERFACE_);
}
GuestRet en_addref(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_u64((uint32_t)addref(reinterpret_cast<ComObj *>(rdi))); }
GuestRet en_release(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *self = reinterpret_cast<WEnum *>(rdi);
    const uint32_t n = drop_ref(self);
    if (n == 0) {
        if (self->dev && drop_ref(self->dev) == 0) delete self->dev;
        delete self;
    }
    return ret_u64(n);
}
GuestRet en_enum_endpoints(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return hr(E_NOTFOUND_); }   // Aspyr 0x1001088fe
GuestRet en_get_default(SHIM_PARAMS) {   // (EDataFlow, ERole, IMMDevice **)  Aspyr 0x100108916
    SHIM_UNUSED_ALL();
    auto *self = reinterpret_cast<WEnum *>(rdi);
    uint64_t *pp = reinterpret_cast<uint64_t *>(rcx);
    if (!pp) return hr(E_POINTER_);
    *pp = 0;
    const uint32_t flow = static_cast<uint32_t>(rsi);
    if (flow > 1 || static_cast<uint32_t>(rdx) > 2) return hr(E_INVALIDARG_);
    if (flow == 1 || default_output_device() == kAudioObjectUnknown) return hr(E_NOTFOUND_);
    std::lock_guard<std::mutex> lk(self->mtx);          // serialise lazy creation
    if (!self->dev) {
        auto *d = new (std::nothrow) WDevice();
        if (!d) { *pp = 0; return hr(E_OUTOFMEMORY_); }
        d->vtbl = &g_vt[VT_DEV];
        self->dev = d;
    }
    addref(self->dev);
    *pp = (uint64_t)(uintptr_t)self->dev;
    return hr(S_OK_);
}
GuestRet en_get_device(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return hr(E_NOTFOUND_); }      // Aspyr 0x1001089c0
GuestRet en_register(SHIM_PARAMS) {    // Aspyr 0x1001089cc: stores, no AddRef
    SHIM_UNUSED_ALL();
    if (!rsi) return hr(E_POINTER_);                     // never clobber a registered client with NULL
    auto *self = reinterpret_cast<WEnum *>(rdi);
    std::lock_guard<std::mutex> lk(self->mtx);
    self->notify = rsi;
    return hr(S_OK_);
}
GuestRet en_unregister(SHIM_PARAMS) {  // Aspyr 0x1001089fc
    SHIM_UNUSED_ALL();
    auto *self = reinterpret_cast<WEnum *>(rdi);
    if (!rsi) return hr(E_POINTER_);
    std::lock_guard<std::mutex> lk(self->mtx);
    if (self->notify != rsi) return hr(E_NOTFOUND_);
    self->notify = 0;
    return hr(S_OK_);
}

// ------------------------------------ IMMDevice ------------------------------------------
GuestRet dv_qi(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    uint64_t *ppv = reinterpret_cast<uint64_t *>(rdx);
    if (!ppv) return hr(E_POINTER_);
    *ppv = 0;
    if (!rsi) return hr(E_POINTER_);
    if (guid_eq((const void *)rsi, IID_IUnknown_) || guid_eq((const void *)rsi, IID_IMMDevice_) ||
        guid_eq((const void *)rsi, IID_IMMDevice_aspyr_)) {
        addref(reinterpret_cast<ComObj *>(rdi)); *ppv = rdi; return hr(S_OK_);
    }
    return hr(E_NOINTERFACE_);
}
GuestRet dv_release(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *self = reinterpret_cast<WDevice *>(rdi);
    const uint32_t n = drop_ref(self);
    if (n == 0) delete self;
    return ret_u64(n);
}
GuestRet dv_activate(SHIM_PARAMS) {    // (REFIID, DWORD clsctx, PROPVARIANT *, void **)  Aspyr 0x100108b36
    SHIM_UNUSED_ALL();
    uint64_t *ppv = reinterpret_cast<uint64_t *>(r8);
    if (!ppv) return hr(E_POINTER_);
    *ppv = 0;
    if (!rsi) return hr(E_POINTER_);
    if (!guid_eq((const void *)rsi, IID_IAudioClient_)) return hr(E_NOINTERFACE_);
    auto *c = new (std::nothrow) WClient();
    if (c) {
        try { c->core = std::make_shared<ClientCore>(); } catch (...) { delete c; c = nullptr; }
    }
    if (!c) { *ppv = 0; return hr(E_OUTOFMEMORY_); }
    c->vtbl = &g_vt[VT_CLI];
    *ppv = (uint64_t)(uintptr_t)c;
    return hr(S_OK_);
}
GuestRet dv_notfound(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return hr(E_NOTFOUND_); }   // OpenPropertyStore/GetId/GetState

// ----------------------------------- IAudioClient ----------------------------------------
GuestRet cl_qi(SHIM_PARAMS) {          // Aspyr 0x100108cf2
    SHIM_UNUSED_ALL();
    uint64_t *ppv = reinterpret_cast<uint64_t *>(rdx);
    if (!ppv) return hr(E_POINTER_);
    *ppv = 0;
    if (!rsi) return hr(E_POINTER_);
    if (guid_eq((const void *)rsi, IID_IUnknown_) || guid_eq((const void *)rsi, IID_IAudioClient_)) {
        addref(reinterpret_cast<ComObj *>(rdi)); *ppv = rdi; return hr(S_OK_);
    }
    return hr(E_NOINTERFACE_);
}
GuestRet cl_release(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *c = reinterpret_cast<WClient *>(rdi);
    const uint32_t n = drop_ref(c);
    if (!n) delete c;
    return ret_u64(n);
}

// Initialize(AUDCLNT_SHAREMODE, DWORD flags, REFERENCE_TIME hnsBuf, REFERENCE_TIME hnsPeriod,
//            const WAVEFORMATEX *fmt, LPCGUID session /* [rsp+8] */)
GuestRet cl_initialize(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    ClientCore *c = reinterpret_cast<WClient *>(rdi)->core.get();
    const uint32_t share = static_cast<uint32_t>(rsi), flags = static_cast<uint32_t>(rdx);
    const int64_t hns_buf = static_cast<int64_t>(rcx);
    const auto *fmt = reinterpret_cast<const WaveFormatEx *>(r9);
    std::lock_guard<std::mutex> lk(c->mtx);
    if (c->device) return hr(AUDCLNT_E_ALREADY_INITIALIZED);
    if (!fmt) return hr(E_POINTER_);
    if (share != 0 || hns_buf < 0) return hr(E_INVALIDARG_);

    const uint16_t sample_format = wave_sample_format(*fmt);
    if (!sample_format) return hr(AUDCLNT_E_UNSUPPORTED_FORMAT);
    const uint32_t mask = fmt->wFormatTag == 0xFFFEu && fmt->dwChannelMask
                        ? fmt->dwChannelMask : kWinMask[fmt->nChannels];
    // Aspyr computes four power-of-two packets from the requested duration.
    const uint64_t duration = hns_buf ? std::min(hns_buf, INT64_MAX / fmt->nSamplesPerSec) : 100'000;
    const uint64_t quarter = fmt->nSamplesPerSec * duration / 40'000'000;
    uint32_t samples = 1;
    while (samples < quarter && samples < 16384u) samples <<= 1;

    Bo3SdlAudioSpec want{};
    want.freq = static_cast<int32_t>(fmt->nSamplesPerSec);
    want.format = sample_format;
    want.channels = static_cast<uint8_t>(fmt->nChannels);
    want.samples = static_cast<uint16_t>(samples);
    c->device.reset(open_device(&want, mask));
    if (!c->device) {
        fprintf(stderr, "[wasapi] Initialize: open failed: %s\n", bo3_audio_last_error());
        return hr(AUDCLNT_E_DEVICE_INVALIDATED);
    }
    c->flags = flags;
    c->buffer_frames = samples * 4;
    return hr(S_OK_);
}

GuestRet cl_get_buffer_size(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    if (!rsi) return hr(E_POINTER_);
    ClientCore *c = reinterpret_cast<WClient *>(rdi)->core.get();
    std::lock_guard<std::mutex> lk(c->mtx);
    if (!c->device) return hr(AUDCLNT_E_NOT_INITIALIZED);
    *reinterpret_cast<uint32_t *>(rsi) = c->buffer_frames;
    return hr(S_OK_);
}

GuestRet cl_notfound(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return hr(E_NOTFOUND_); }

GuestRet cl_get_padding(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    if (!rsi) return hr(E_POINTER_);
    ClientCore *c = reinterpret_cast<WClient *>(rdi)->core.get();
    std::lock_guard<std::mutex> lk(c->mtx);
    if (!c->device) return hr(AUDCLNT_E_NOT_INITIALIZED);
    *reinterpret_cast<uint32_t *>(rsi) = core_padding_frames(c);
    return hr(S_OK_);
}

GuestRet cl_is_format_supported(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *closest = reinterpret_cast<uint64_t *>(rcx);
    if (closest) *closest = 0;
    if (!rdx || (!static_cast<uint32_t>(rsi) && !closest)) return hr(E_POINTER_);
    if (static_cast<uint32_t>(rsi) > 1) return hr(E_INVALIDARG_);
    if (static_cast<uint32_t>(rsi) == 1) return hr(AUDCLNT_E_UNSUPPORTED_FORMAT);
    const auto *fmt = reinterpret_cast<const WaveFormatEx *>(rdx);
    if (wave_sample_format(*fmt))
        return hr(default_output_device() != kAudioObjectUnknown ? S_OK_ : AUDCLNT_E_DEVICE_INVALIDATED);
    const uint32_t status = allocate_mix_format(closest);
    return hr(status == S_OK_ ? S_FALSE_ : status);
}

GuestRet cl_get_mix_format(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *out = reinterpret_cast<uint64_t *>(rsi);
    return hr(out ? allocate_mix_format(out) : E_POINTER_);
}

GuestRet cl_start(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    ClientCore *c = reinterpret_cast<WClient *>(rdi)->core.get();
    std::lock_guard<std::mutex> lk(c->mtx);
    if (!c->device) return hr(AUDCLNT_E_NOT_INITIALIZED);
    if (c->started.load(std::memory_order_relaxed)) return hr(AUDCLNT_E_NOT_STOPPED);
    dispatch_source_t timer = nil;
    if (c->flags & AUDCLNT_STREAMFLAGS_EVENTCALLBACK) {
        if (!c->event.load(std::memory_order_relaxed)) return hr(AUDCLNT_E_EVENTHANDLE_NOT_SET);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, timer_queue());
        if (!timer) return hr(E_OUTOFMEMORY_);
        dispatch_source_set_event_handler(timer, ^{
            if (!c->started.load(std::memory_order_acquire)) return;
            const auto *event = c->event.load(std::memory_order_acquire);
            if (core_padding_frames(c) < c->buffer_frames) event->hooks.signal(event->handle);
        });
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), kEventPeriodNs, kEventLeewayNs);
    }
    if (start_device(c->device.get()) != noErr) {
        if (timer) { dispatch_source_cancel(timer); dispatch_resume(timer); }
        return hr(AUDCLNT_E_DEVICE_INVALIDATED);
    }
    c->started.store(true, std::memory_order_release);
    c->needs_reset = true;
    c->timer = timer;
    if (timer) dispatch_resume(timer);
    return hr(S_OK_);
}

GuestRet cl_stop(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    ClientCore *c = reinterpret_cast<WClient *>(rdi)->core.get();
    std::lock_guard<std::mutex> lk(c->mtx);
    if (!c->device) return hr(AUDCLNT_E_NOT_INITIALIZED);
    if (!c->started.load(std::memory_order_relaxed)) return hr(S_FALSE_);
    if (stop_device(c->device.get()) != noErr) return hr(AUDCLNT_E_DEVICE_INVALIDATED);
    c->started.store(false, std::memory_order_release);
    stop_timer(c);
    return hr(S_OK_);
}

GuestRet cl_reset(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    ClientCore *c = reinterpret_cast<WClient *>(rdi)->core.get();
    std::lock_guard<std::mutex> lk(c->mtx);
    AudioDev *d = c->device.get();
    if (!d) return hr(AUDCLNT_E_NOT_INITIALIZED);
    if (d->running) return hr(AUDCLNT_E_NOT_STOPPED);
    if (c->buffer_owner) return hr(AUDCLNT_E_BUFFER_OPERATION_PENDING);
    if (!c->needs_reset) return hr(S_FALSE_);
    if (AudioUnitReset(d->unit, kAudioUnitScope_Global, 0) != noErr)
        return hr(AUDCLNT_E_DEVICE_INVALIDATED);
    d->rpos.store(d->wpos.load(std::memory_order_relaxed), std::memory_order_release);
    c->needs_reset = false;
    return hr(S_OK_);
}

GuestRet cl_set_event(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    ClientCore *c = reinterpret_cast<WClient *>(rdi)->core.get();
    EventRegistration *old = nullptr;
    {
        std::lock_guard<std::mutex> lk(c->mtx);
        if (!c->device) return hr(AUDCLNT_E_NOT_INITIALIZED);
        if (!(c->flags & AUDCLNT_STREAMFLAGS_EVENTCALLBACK)) return hr(AUDCLNT_E_EVENTHANDLE_NOT_EXPECTED);
        if (!rsi) return hr(E_INVALIDARG_);
        EventHooks hooks;
        { std::lock_guard<std::mutex> lock(g_event_hooks_mutex); hooks = g_event_hooks; }
        if (!hooks.signal || !hooks.retain || !hooks.release) return hr(E_INVALIDARG_);
        auto *event = new (std::nothrow) EventRegistration{rsi, hooks};
        if (!event) return hr(E_OUTOFMEMORY_);
        if (!hooks.retain(rsi)) { delete event; return hr(E_INVALIDARG_); }
        old = c->event.exchange(event, std::memory_order_acq_rel);
        if (old && c->timer) dispatch_sync(timer_queue(), ^{});
    }
    release_event(old);
    return hr(S_OK_);
}

GuestRet cl_get_service(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *client = reinterpret_cast<WClient *>(rdi);
    ClientCore *c = client->core.get();
    auto *ppv = reinterpret_cast<uint64_t *>(rdx);
    if (!ppv) return hr(E_POINTER_);
    *ppv = 0;
    if (!rsi) return hr(E_POINTER_);
    std::lock_guard<std::mutex> lk(c->mtx);
    if (!c->device) return hr(AUDCLNT_E_NOT_INITIALIZED);
    if (guid_eq(reinterpret_cast<const void *>(rsi), IID_IAudioRenderClient_)) {
        auto render = std::unique_ptr<WRender>(new (std::nothrow) WRender());
        if (!render) return hr(E_OUTOFMEMORY_);
        render->buf.reset(new (std::nothrow) uint8_t[c->buffer_frames * c->device->bpf]);
        if (!render->buf) return hr(E_OUTOFMEMORY_);
        render->vtbl = &g_vt[VT_REN];
        render->core = client->core;
        *ppv = reinterpret_cast<uint64_t>(render.release());
        return hr(S_OK_);
    }
    if (guid_eq(reinterpret_cast<const void *>(rsi), IID_IAudioSessionControl_)) {
        auto *session = new (std::nothrow) WSession();
        if (!session) return hr(E_OUTOFMEMORY_);
        session->vtbl = &g_vt[VT_SES];
        *ppv = reinterpret_cast<uint64_t>(session);
        return hr(S_OK_);
    }
    return hr(E_NOINTERFACE_);
}

// -------------------------------- IAudioRenderClient -------------------------------------
GuestRet rn_qi(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    uint64_t *ppv = reinterpret_cast<uint64_t *>(rdx);
    if (!ppv) return hr(E_POINTER_);
    *ppv = 0;
    if (!rsi) return hr(E_POINTER_);
    if (guid_eq((const void *)rsi, IID_IUnknown_) || guid_eq((const void *)rsi, IID_IAudioRenderClient_)) {
        addref(reinterpret_cast<ComObj *>(rdi)); *ppv = rdi; return hr(S_OK_);
    }
    return hr(E_NOINTERFACE_);
}
GuestRet rn_release(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *r = reinterpret_cast<WRender *>(rdi);
    const uint32_t n = drop_ref(r);
    if (!n) {
        {
            std::lock_guard<std::mutex> lk(r->core->mtx);
            if (r->core->buffer_owner == r) r->core->buffer_owner = nullptr;
        }
        delete r;
    }
    return ret_u64(n);
}

GuestRet rn_get_buffer(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *r = reinterpret_cast<WRender *>(rdi);
    ClientCore *c = r->core.get();
    const uint32_t frames = static_cast<uint32_t>(rsi);
    auto *out = reinterpret_cast<uint64_t *>(rdx);
    if (!out) return hr(E_POINTER_);
    std::lock_guard<std::mutex> lk(c->mtx);
    if (c->buffer_owner) return hr(AUDCLNT_E_OUT_OF_ORDER);
    if (!frames) { r->zero_requested = true; return hr(S_OK_); }
    if (frames > c->buffer_frames - core_padding_frames(c)) return hr(AUDCLNT_E_BUFFER_TOO_LARGE);
    c->buffer_owner = r;
    r->zero_requested = false;
    r->pending = frames;
    r->buffer_thread = pthread_self();
    *out = reinterpret_cast<uint64_t>(r->buf.get());
    return hr(S_OK_);
}

GuestRet rn_release_buffer(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *r = reinterpret_cast<WRender *>(rdi);
    ClientCore *c = r->core.get();
    const uint32_t written = static_cast<uint32_t>(rsi), flags = static_cast<uint32_t>(rdx);
    std::lock_guard<std::mutex> lk(c->mtx);
    if (flags & ~AUDCLNT_BUFFERFLAGS_SILENT) return hr(E_INVALIDARG_);
    if (c->buffer_owner != r) {
        if (!written && r->zero_requested) {
            r->zero_requested = false;
            return hr(S_OK_);
        }
        return hr(AUDCLNT_E_OUT_OF_ORDER);
    }
    if (!pthread_equal(r->buffer_thread, pthread_self())) return hr(AUDCLNT_E_OUT_OF_ORDER);
    if (written > r->pending) return hr(AUDCLNT_E_INVALID_SIZE);

    c->buffer_owner = nullptr;
    r->pending = 0;
    if (written) {
        AudioDev *d = c->device.get();
        const uint32_t bytes = written * d->bpf;
        if (flags & AUDCLNT_BUFFERFLAGS_SILENT) memset(r->buf.get(), d->spec.silence, bytes);
        ring_push(d, r->buf.get(), bytes);
        c->needs_reset = true;
    }
    return hr(S_OK_);
}

// ------------------------------- IAudioSessionControl ------------------------------------
GuestRet ss_qi(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    uint64_t *ppv = reinterpret_cast<uint64_t *>(rdx);
    if (!ppv) return hr(E_POINTER_);
    *ppv = 0;
    if (!rsi) return hr(E_POINTER_);
    if (guid_eq((const void *)rsi, IID_IUnknown_) || guid_eq((const void *)rsi, IID_IAudioSessionControl_)) {
        addref(reinterpret_cast<ComObj *>(rdi)); *ppv = rdi; return hr(S_OK_);
    }
    return hr(E_NOINTERFACE_);
}
GuestRet ss_release(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<WSession *>(rdi);
    const uint32_t n = drop_ref(s);
    if (n == 0) {
        uint64_t notify;
        { std::lock_guard<std::mutex> lk(s->mtx); notify = s->notify; s->notify = 0; }
        if (notify) guest_release(ctx, rsp, notify);   // drop the ref taken at registration
        delete s;
    }
    return ret_u64(n);
}
GuestRet ss_notfound(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return hr(E_NOTFOUND_); }
// RegisterAudioSessionNotification(IAudioSessionEvents *): COM-correct AddRef (as Aspyr does); we
// never invoke the callbacks. A previously registered sink is released.
GuestRet ss_register(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    if (!rsi) return hr(E_POINTER_);
    auto *s = reinterpret_cast<WSession *>(rdi);
    guest_addref(ctx, rsp, rsi);                        // guest code: called with no native lock held
    uint64_t old;
    { std::lock_guard<std::mutex> lk(s->mtx); old = s->notify; s->notify = rsi; }
    if (old) guest_release(ctx, rsp, old);
    return hr(S_OK_);
}
GuestRet ss_unregister(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    if (!rsi) return hr(E_POINTER_);
    auto *s = reinterpret_cast<WSession *>(rdi);
    bool matched = false;
    { std::lock_guard<std::mutex> lk(s->mtx); if (s->notify == rsi) { s->notify = 0; matched = true; } }
    if (matched) guest_release(ctx, rsp, rsi);
    return hr(S_OK_);
}

struct VtEntry { uint32_t slot; GuestFn fn; };
const VtEntry kVtable[] = {
    // IMMDeviceEnumerator
    {VT_ENUM + 0, en_qi}, {VT_ENUM + 1, en_addref}, {VT_ENUM + 2, en_release},
    {VT_ENUM + 3, en_enum_endpoints}, {VT_ENUM + 4, en_get_default}, {VT_ENUM + 5, en_get_device},
    {VT_ENUM + 6, en_register}, {VT_ENUM + 7, en_unregister},
    // IMMDevice
    {VT_DEV + 0, dv_qi}, {VT_DEV + 1, en_addref}, {VT_DEV + 2, dv_release}, {VT_DEV + 3, dv_activate},
    {VT_DEV + 4, dv_notfound}, {VT_DEV + 5, dv_notfound}, {VT_DEV + 6, dv_notfound},
    // IAudioClient
    {VT_CLI + 0, cl_qi}, {VT_CLI + 1, en_addref}, {VT_CLI + 2, cl_release}, {VT_CLI + 3, cl_initialize},
    {VT_CLI + 4, cl_get_buffer_size}, {VT_CLI + 5, cl_notfound}, {VT_CLI + 6, cl_get_padding},
    {VT_CLI + 7, cl_is_format_supported}, {VT_CLI + 8, cl_get_mix_format}, {VT_CLI + 9, cl_notfound},
    {VT_CLI + 10, cl_start}, {VT_CLI + 11, cl_stop}, {VT_CLI + 12, cl_reset},
    {VT_CLI + 13, cl_set_event}, {VT_CLI + 14, cl_get_service},
    // IAudioRenderClient
    {VT_REN + 0, rn_qi}, {VT_REN + 1, en_addref}, {VT_REN + 2, rn_release},
    {VT_REN + 3, rn_get_buffer}, {VT_REN + 4, rn_release_buffer},
    // IAudioSessionControl
    {VT_SES + 0, ss_qi}, {VT_SES + 1, en_addref}, {VT_SES + 2, ss_release},
    {VT_SES + 3, ss_notfound}, {VT_SES + 4, ss_notfound}, {VT_SES + 5, ss_notfound},
    {VT_SES + 6, ss_notfound}, {VT_SES + 7, ss_notfound}, {VT_SES + 8, ss_notfound},
    {VT_SES + 9, ss_notfound}, {VT_SES + 10, ss_register}, {VT_SES + 11, ss_unregister},
};
static_assert(sizeof(kVtable) / sizeof(kVtable[0]) == VT_COUNT, "every slot registered");

std::once_flag g_vt_once;

} // namespace

extern "C" void bo3_audio_init_guest_vtables(void) {
    std::call_once(g_vt_once, [] {
        for (const VtEntry &e : kVtable) g_vt[e.slot] = bo3_com_register_thunk(e.fn);
    });
}

extern "C" int bo3_wasapi_is_enumerator_guid(const void *guid) {
    return guid_eq(guid, IID_IMMDeviceEnumerator_) || guid_eq(guid, CLSID_MMDeviceEnumerator_);
}

extern "C" uint32_t bo3_wasapi_create_enumerator(uint64_t *ppv) {
    if (!ppv) return E_POINTER_;
    bo3_audio_init_guest_vtables();
    auto *e = new (std::nothrow) WEnum();
    if (!e) { *ppv = 0; return E_OUTOFMEMORY_; }
    e->vtbl = &g_vt[VT_ENUM];
    *ppv = (uint64_t)(uintptr_t)e;
    fprintf(stderr, "[wasapi] CoCreateInstance(IMMDeviceEnumerator) -> native CoreAudio %p\n", (void *)e);
    return S_OK_;
}

extern "C" void bo3_audio_set_event_hooks(Bo3AudioSignalEventFn signal_fn, Bo3AudioRetainEventFn retain_fn,
                                          Bo3AudioReleaseEventFn release_fn) {
    std::lock_guard<std::mutex> lock(g_event_hooks_mutex);
    g_event_hooks = {signal_fn, retain_fn, release_fn};
}

extern "C" void bo3_audio_set_event_signal_fn(Bo3AudioSignalEventFn fn) {
    std::lock_guard<std::mutex> lock(g_event_hooks_mutex);
    g_event_hooks.signal = fn;
}

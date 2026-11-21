// gamepad_mac.mm — native GameController.framework + CoreHaptics backend for BO3's XInput API.
// See gamepad_mac.h for the guest entry points.
#include "gamepad_mac.h"

#if !__has_feature(objc_arc)
#error "gamepad_mac.mm must be compiled with -fobjc-arc (Slot holds strong ObjC references)"
#endif

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <dispatch/dispatch.h>
#include <os/lock.h>
#include <time.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace {

constexpr uint32_t kMaxHapticFailures = 5;                 // per connection; then haptics stay off
constexpr uint64_t kRetryBaseNs = 50 * NSEC_PER_MSEC;       // 50, 100, 200, 400 ms ...
constexpr uint64_t kRetryMaxNs  = 2 * NSEC_PER_SEC;
constexpr uint64_t kHealthyNs   = 5 * NSEC_PER_SEC;         // engine alive this long => failures forgiven

struct Slot {
    // Controller and haptics objects are accessed only on g_pad_queue.
    GCController *ctrl = nil;
    CHHapticEngine *eng_l = nil, *eng_r = nil;
    id<CHHapticPatternPlayer> pl_l = nil, pl_r = nil;
    uint64_t engine_l_gen = 0, engine_r_gen = 0;
    bool prefer_single = false;
    bool haptics_off = false;
    bool retry_scheduled = false;
    uint32_t failures = 0;
    uint64_t engine_born_ns = 0;

    // The lock publishes each connection, packet and rumble request as one coherent snapshot.
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    uint64_t gen = 0;
    bool connected = false;
    Bo3XInputState state{};
    Bo3XInputVibration rumble{};
    uint64_t rumble_gen = 0;
    std::atomic<bool> apply_pending{false};
};

Slot g_slots[BO3_XUSER_MAX_COUNT];
uint64_t g_gen_counter = 0;  // g_pad_queue only
std::atomic<bool> g_enabled{true};
os_unfair_lock g_enabled_lock = OS_UNFAIR_LOCK_INIT;
dispatch_queue_t g_pad_queue = nil;
dispatch_source_t g_reconcile_timer = nil;
dispatch_once_t g_init_once;

uint64_t next_gen() { return ++g_gen_counter; }
inline uint64_t now_ns() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

inline int to_s16(float v) {               // SDL-style axis: [-32768, 32767]
    if (!(v == v)) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    return v >= 0.0f ? (int)lrintf(v * 32767.0f) : (int)lrintf(v * 32768.0f);
}
void apply_stick_deadzone(int16_t &x, int16_t &y, int deadzone) {
    if (static_cast<int64_t>(x) * x + static_cast<int64_t>(y) * y <= deadzone * deadzone)
        x = y = 0;
}

uint8_t trigger_u8(float v) {
    const int axis = to_s16(v);
    const int trigger = axis > 0 ? axis * 255 / 32767 : 0;
    return trigger > 30 ? static_cast<uint8_t>(trigger) : 0;
}
inline bool pressed(GCControllerButtonInput *b) { return b != nil && b.pressed; }

Bo3XInputGamepad snapshot(GCExtendedGamepad *gp) {
    Bo3XInputGamepad s{};
    uint16_t b = 0;
    if (pressed(gp.buttonA)) b |= 0x1000;
    if (pressed(gp.buttonB)) b |= 0x2000;
    if (pressed(gp.buttonX)) b |= 0x4000;
    if (pressed(gp.buttonY)) b |= 0x8000;
    if (pressed(gp.buttonOptions)) b |= 0x0020;      // SDL BACK
    if (pressed(gp.buttonMenu)) b |= 0x0010;         // SDL START
    if (@available(macOS 11.0, *)) {
        if (pressed(gp.buttonHome)) b |= 0x0400;
    }
    if (pressed(gp.leftThumbstickButton)) b |= 0x0040;
    if (pressed(gp.rightThumbstickButton)) b |= 0x0080;
    if (pressed(gp.leftShoulder)) b |= 0x0100;
    if (pressed(gp.rightShoulder)) b |= 0x0200;
    if (pressed(gp.dpad.up)) b |= 0x0001;
    if (pressed(gp.dpad.down)) b |= 0x0002;
    if (pressed(gp.dpad.left)) b |= 0x0004;
    if (pressed(gp.dpad.right)) b |= 0x0008;
    s.wButtons = b;
    s.bLeftTrigger = trigger_u8(gp.leftTrigger.value);
    s.bRightTrigger = trigger_u8(gp.rightTrigger.value);
    // GameController and XInput both use up-positive Y.
    s.sThumbLX = static_cast<int16_t>(to_s16(gp.leftThumbstick.xAxis.value));
    s.sThumbLY = static_cast<int16_t>(to_s16(gp.leftThumbstick.yAxis.value));
    s.sThumbRX = static_cast<int16_t>(to_s16(gp.rightThumbstick.xAxis.value));
    s.sThumbRY = static_cast<int16_t>(to_s16(gp.rightThumbstick.yAxis.value));
    apply_stick_deadzone(s.sThumbLX, s.sThumbLY, 7849);
    apply_stick_deadzone(s.sThumbRX, s.sThumbRY, 8689);
    return s;
}

void store_snapshot(Slot &slot, uint64_t gen, const Bo3XInputGamepad &state) {
    os_unfair_lock_lock(&slot.lock);
    if (slot.connected && slot.gen == gen &&
        memcmp(&slot.state.Gamepad, &state, sizeof(state)) != 0) {
        slot.state.Gamepad = state;
        ++slot.state.dwPacketNumber;
    }
    os_unfair_lock_unlock(&slot.lock);
}

void apply_rumble(int i);

void request_apply(int i) {
    if (!g_slots[i].apply_pending.exchange(true, std::memory_order_acq_rel))
        dispatch_async(g_pad_queue, ^{ apply_rumble(i); });
}

// ------------------------------------ haptics -------------------------------------------
bool stop_player(id<CHHapticPatternPlayer> __strong &player) {
    if (!player) return true;
    const bool stopped = [player stopAtTime:CHHapticTimeImmediate error:nil];
    player = nil;
    return stopped;
}

// Tears down engines/players only; failure accounting is left to the caller.
void drop_haptics(Slot &s) {
    s.engine_l_gen = s.engine_r_gen = 0;
    stop_player(s.pl_l);
    stop_player(s.pl_r);
    [s.eng_l stopWithCompletionHandler:nil];
    [s.eng_r stopWithCompletionHandler:nil];
    s.eng_l = nil;
    s.eng_r = nil;
}

void schedule_retry(int i) {                             // on g_pad_queue
    Slot &s = g_slots[i];
    if (s.retry_scheduled) return;
    s.retry_scheduled = true;
    const uint32_t shift = s.failures ? s.failures - 1 : 0;
    uint64_t delay = kRetryBaseNs << (shift > 6 ? 6 : shift);
    if (delay > kRetryMaxNs) delay = kRetryMaxNs;
    const uint64_t g = s.gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay), g_pad_queue, ^{
        Slot &t = g_slots[i];
        if (!t.connected || t.gen != g) return;
        t.retry_scheduled = false;
        apply_rumble(i);
    });
}

// Bounded recovery: every reset/stop/start/player failure counts; backoff doubles; after
// kMaxHapticFailures the connection runs without haptics (no unbounded resetHandler loops).
void haptic_failure(int i, const char *why) {            // on g_pad_queue
    Slot &s = g_slots[i];
    if (s.eng_r) s.prefer_single = true;                 // dual engines misbehaved: fall back to one
    drop_haptics(s);
    s.failures++;
    if (s.failures >= kMaxHapticFailures) {
        if (!s.haptics_off) fprintf(stderr, "[gamepad] slot %d: haptics disabled after %u failures (%s)\n",
                                    i, s.failures, why);
        s.haptics_off = true;
        return;
    }
    schedule_retry(i);
}

void handle_engine_loss(int i, uint64_t connection, uint64_t engine, const char *why) {
    dispatch_async(g_pad_queue, ^{
        Slot &slot = g_slots[i];
        if (slot.gen == connection && (slot.engine_l_gen == engine || slot.engine_r_gen == engine))
            haptic_failure(i, why);
    });
}

CHHapticEngine *make_engine(int i, GCHapticsLocality locality, uint64_t &generation)
    API_AVAILABLE(macos(11.0)) {
    Slot &slot = g_slots[i];
    CHHapticEngine *e = [slot.ctrl.haptics createEngineWithLocality:locality];
    if (!e) return nil;
    e.playsHapticsOnly = YES;
    const uint64_t connection = slot.gen;
    const uint64_t engine = next_gen();
    e.resetHandler = ^{ handle_engine_loss(i, connection, engine, "engine reset"); };
    e.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        (void)reason;
        handle_engine_loss(i, connection, engine, "engine stopped");
    };
    NSError *err = nil;
    if (![e startAndReturnError:&err]) return nil;
    generation = engine;
    return e;
}

bool create_engines(int i) API_AVAILABLE(macos(11.0)) {  // on g_pad_queue
    Slot &s = g_slots[i];
    GCController *c = s.ctrl;
    NSSet<GCHapticsLocality> *locs = c.haptics.supportedLocalities;
    if (!s.prefer_single && [locs containsObject:GCHapticsLocalityLeftHandle] &&
        [locs containsObject:GCHapticsLocalityRightHandle]) {
        s.eng_l = make_engine(i, GCHapticsLocalityLeftHandle, s.engine_l_gen);
        s.eng_r = s.eng_l ? make_engine(i, GCHapticsLocalityRightHandle, s.engine_r_gen) : nil;
        if (!s.eng_l || !s.eng_r) { drop_haptics(s); s.prefer_single = true; }   // single-engine fallback
    }
    if (!s.eng_l) { s.eng_r = nil; s.eng_l = make_engine(i, GCHapticsLocalityDefault, s.engine_l_gen); }
    if (!s.eng_l) return false;
    s.engine_born_ns = now_ns();
    return true;
}

bool drive(CHHapticEngine *eng, id<CHHapticPatternPlayer> __strong &pl, float intensity, float sharpness)
    API_AVAILABLE(macos(11.0)) {
    if (!eng) return true;
    if (intensity == 0.0f) return stop_player(pl);
    NSError *err = nil;
    if (!pl) {
        // Base event intensity 1.0, scaled by an IntensityControl dynamic parameter that is part of
        // the pattern itself, so the player starts at the requested level (no 100% kick).
        CHHapticEventParameter *pi = [[CHHapticEventParameter alloc]
            initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0f];
        CHHapticEventParameter *ps = [[CHHapticEventParameter alloc]
            initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness];
        CHHapticEvent *ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                          parameters:@[pi, ps]
                                                        relativeTime:0
                                                            duration:GCHapticDurationInfinite];
        CHHapticDynamicParameter *init = [[CHHapticDynamicParameter alloc]
            initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:intensity relativeTime:0];
        CHHapticPattern *pat = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[init] error:&err];
        if (!pat) return false;
        id<CHHapticPatternPlayer> np = [eng createPlayerWithPattern:pat error:&err];
        if (!np) return false;
        if (![np startAtTime:CHHapticTimeImmediate error:&err]) return false;
        pl = np;
        return true;
    }
    CHHapticDynamicParameter *dp = [[CHHapticDynamicParameter alloc]
        initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:intensity relativeTime:0];
    if (![pl sendParameters:@[dp] atTime:CHHapticTimeImmediate error:&err]) return false;
    return true;
}

void apply_rumble(int i) {                               // on g_pad_queue
    Slot &s = g_slots[i];
    s.apply_pending.store(false, std::memory_order_release);
    os_unfair_lock_lock(&s.lock);
    const Bo3XInputVibration want = s.connected && s.rumble_gen == s.gen &&
        g_enabled.load(std::memory_order_acquire) ? s.rumble : Bo3XInputVibration{};
    os_unfair_lock_unlock(&s.lock);
    const float l = want.wLeftMotorSpeed / 65535.0f;
    const float r = want.wRightMotorSpeed / 65535.0f;
    if (!want.wLeftMotorSpeed && !want.wRightMotorSpeed) {
        const bool left_stopped = stop_player(s.pl_l);
        const bool right_stopped = stop_player(s.pl_r);
        if (!left_stopped || !right_stopped) drop_haptics(s);
        return;
    }
    if (@available(macOS 11.0, *)) {
        GCController *c = s.ctrl;
        if (!c || !c.haptics) return;
        if (!s.eng_l) {
            if (s.haptics_off || s.retry_scheduled) return;   // respect the backoff
            if (!create_engines(i)) { haptic_failure(i, "engine start"); return; }
        } else if (s.failures && now_ns() - s.engine_born_ns >= kHealthyNs) {
            s.failures = 0;                              // engine proved stable: forgive old failures
        }
        bool ok;
        if (s.eng_r) ok = drive(s.eng_l, s.pl_l, l, 0.25f) && drive(s.eng_r, s.pl_r, r, 0.85f);
        else         ok = drive(s.eng_l, s.pl_l, l > r ? l : r, 0.5f);
        if (!ok) haptic_failure(i, "player");
    }
}

// ------------------------------- connection tracking ------------------------------------
int slot_of(GCController *c) {
    for (int i = 0; i < BO3_XUSER_MAX_COUNT; i++) if (g_slots[i].ctrl == c) return i;
    return -1;
}

void attach(GCController *c) {                           // on g_pad_queue
    if (!c || !c.extendedGamepad || slot_of(c) >= 0) return;
    int i = -1;
    for (int k = 0; k < BO3_XUSER_MAX_COUNT; k++) if (!g_slots[k].ctrl) { i = k; break; }
    if (i < 0) return;
    Slot &s = g_slots[i];
    s.ctrl = c;
    s.prefer_single = false;
    s.haptics_off = false;
    s.retry_scheduled = false;
    s.failures = 0;

    const uint64_t gen = next_gen();
    c.handlerQueue = g_pad_queue;
    c.playerIndex = static_cast<GCControllerPlayerIndex>(i);
    GCExtendedGamepad *profile = c.extendedGamepad;
    profile.valueChangedHandler = ^(GCExtendedGamepad *gp, GCControllerElement *el) {
        (void)el;
        store_snapshot(g_slots[i], gen, snapshot(gp));
    };
    const Bo3XInputGamepad initial = snapshot(profile);
    os_unfair_lock_lock(&s.lock);
    s.gen = gen;
    s.connected = true;
    s.rumble = {};
    s.rumble_gen = gen;
    s.state.Gamepad = initial;
    ++s.state.dwPacketNumber;
    os_unfair_lock_unlock(&s.lock);
    fprintf(stderr, "[gamepad] connected slot %d: %s\n", i, c.vendorName ? c.vendorName.UTF8String : "?");
}

void detach(GCController *c) {                           // on g_pad_queue
    const int i = slot_of(c);
    if (i < 0) return;
    Slot &s = g_slots[i];
    os_unfair_lock_lock(&s.lock);
    s.connected = false;
    s.gen = next_gen();
    s.rumble = {};
    s.rumble_gen = 0;
    s.state.Gamepad = {};
    os_unfair_lock_unlock(&s.lock);
    if (c.extendedGamepad) c.extendedGamepad.valueChangedHandler = nil;
    drop_haptics(s);
    s.ctrl = nil;
    fprintf(stderr, "[gamepad] disconnected slot %d\n", i);
}

void reconcile() {                                       // on g_pad_queue
    NSArray<GCController *> *now = [GCController controllers];
    for (int i = 0; i < BO3_XUSER_MAX_COUNT; i++) {
        GCController *c = g_slots[i].ctrl;
        if (c && ![now containsObject:c]) detach(c);
    }
    for (GCController *c in now) attach(c);
}

} // namespace

extern "C" void bo3_gamepad_init(void) {
    dispatch_once(&g_init_once, ^{
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        g_pad_queue = dispatch_queue_create("bo3.gamepad", attr);
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) {
                        GCController *c = n.object;
                        dispatch_async(g_pad_queue, ^{ attach(c); });
                    }];
        [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) {
                        GCController *c = n.object;
                        dispatch_async(g_pad_queue, ^{ detach(c); });
                    }];
        // Safety net for missed notifications (e.g. main run loop not yet pumping).
        g_reconcile_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_pad_queue);
        dispatch_source_set_event_handler(g_reconcile_timer, ^{ reconcile(); });
        dispatch_source_set_timer(g_reconcile_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_resume(g_reconcile_timer);
    });
}

extern "C" void bo3_gamepad_set_enabled(int enabled) {
    bo3_gamepad_init();
    os_unfair_lock_lock(&g_enabled_lock);
    const bool changed = g_enabled.exchange(enabled != 0, std::memory_order_acq_rel) != (enabled != 0);
    if (changed) {
        for (int i = 0; i < BO3_XUSER_MAX_COUNT; ++i) {
            Slot &s = g_slots[i];
            os_unfair_lock_lock(&s.lock);
            if (s.connected) ++s.state.dwPacketNumber;
            if (!enabled) s.rumble = {};
            os_unfair_lock_unlock(&s.lock);
            if (!enabled) request_apply(i);
        }
    }
    os_unfair_lock_unlock(&g_enabled_lock);
}

extern "C" int bo3_gamepad_connected_count(void) {
    bo3_gamepad_init();
    int count = 0;
    for (Slot &s : g_slots) {
        os_unfair_lock_lock(&s.lock);
        count += s.connected;
        os_unfair_lock_unlock(&s.lock);
    }
    return count;
}

extern "C" uint32_t bo3_xinput_get_state(uint32_t idx, Bo3XInputState *out) {
    if (out) *out = {};
    if (idx >= BO3_XUSER_MAX_COUNT) return BO3_ERROR_DEVICE_NOT_CONNECTED;
    if (!out) return BO3_ERROR_BAD_ARGUMENTS;
    bo3_gamepad_init();

    Slot &s = g_slots[idx];
    os_unfair_lock_lock(&s.lock);
    const bool connected = s.connected;
    if (connected && g_enabled.load(std::memory_order_acquire)) *out = s.state;
    os_unfair_lock_unlock(&s.lock);
    return connected ? BO3_ERROR_SUCCESS : BO3_ERROR_DEVICE_NOT_CONNECTED;
}

extern "C" uint32_t bo3_xinput_set_state(uint32_t idx, const Bo3XInputVibration *vib) {
    if (idx >= BO3_XUSER_MAX_COUNT) return BO3_ERROR_DEVICE_NOT_CONNECTED;
    if (!vib) return BO3_ERROR_BAD_ARGUMENTS;
    bo3_gamepad_init();

    Slot &s = g_slots[idx];
    os_unfair_lock_lock(&s.lock);
    const bool connected = s.connected;
    if (connected) {
        s.rumble = g_enabled.load(std::memory_order_acquire) ? *vib : Bo3XInputVibration{};
        s.rumble_gen = s.gen;
    }
    os_unfair_lock_unlock(&s.lock);
    if (!connected) return BO3_ERROR_DEVICE_NOT_CONNECTED;
    request_apply(static_cast<int>(idx));
    return BO3_ERROR_SUCCESS;
}

extern "C" GuestRet bo3_shim_XInputGetState(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_u64(bo3_xinput_get_state((uint32_t)rdi, reinterpret_cast<Bo3XInputState *>(rsi)));
}

extern "C" GuestRet bo3_shim_XInputSetState(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_u64(bo3_xinput_set_state((uint32_t)rdi, reinterpret_cast<const Bo3XInputVibration *>(rsi)));
}

// Native ARM64 Steamworks bridge for BO3 (SteamClient017 / SDK 1.37 interface set).
//
// Online (default): loads the arm64 slice of the live Steam desktop client's steamclient.dylib,
// connects a global user, and hands the guest Bo3SteamProxy objects. A proxy has a guest vtable
// of synthetic thunk VAs; each thunk forwards to the same slot of the wrapped native interface.
// Per-slot metadata handles register argument extension and boolean returns. Typed
// overrides handle native stack arguments, guest function pointers, and response objects. libsteam_api's callback and call-result manager is reimplemented over
// Steam_BGetCallback / Steam_FreeLastCallback / Steam_GetAPICallResult.
//
// Offline (BO3ARM_OFFLINE=1, or when steamclient.dylib cannot connect to a running Steam client):
// the M5 mock below (local file-backed ISteamRemoteStorage, local ISteamGameServer with
// process-local auth tickets) serves every interface.
//
// Every slot number below was checked against the flat-API thunks in BO3's own
// libsteam_api.dylib (SteamAPI_ISteamXxx_Yyy -> jmp *off(%rax)).

#include "shim_helpers.h"
#include "../metal/settings_mac.h"
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

#define BO3_STEAM_APPID    311210ULL
#define BO3_STEAM_LOCALID  0x0110000100000001ULL
#define BO3_STEAM_SERVERID 0x0130000000000001ULL // public universe, game server, account 1

// ---- Bridge mode, shared by the offline mock and the native bridge ----
enum { STEAM_MODE_UNKNOWN = 0, STEAM_MODE_ONLINE = 1, STEAM_MODE_OFFLINE = 2 };
enum { STEAM_GS_NONE = 0, STEAM_GS_NATIVE = 1, STEAM_GS_MOCK = 2 };

static int g_steam_mode;              // STEAM_MODE_*
static int g_gs_mode;                 // STEAM_GS_*
static uint64_t g_steam_online_id;    // real SteamID once online

static inline int steam_mode(void) { return __atomic_load_n(&g_steam_mode, __ATOMIC_ACQUIRE); }
static inline int steam_online(void) { return steam_mode() == STEAM_MODE_ONLINE; }
static inline int steam_gs_mode(void) { return __atomic_load_n(&g_gs_mode, __ATOMIC_ACQUIRE); }

// The account that local auth tickets belong to.
static inline uint64_t steam_local_id(void) {
    uint64_t id = __atomic_load_n(&g_steam_online_id, __ATOMIC_ACQUIRE);
    return steam_online() && id ? id : BO3_STEAM_LOCALID;
}

// Callback pumps: one for the client pipe, one for the game server pipe. While a pump runs
// guest code for a callback it pins that object so unregistration on another thread waits.
enum { STEAM_PUMP_CLIENT = 0, STEAM_PUMP_GS = 1, STEAM_PUMP_COUNT = 2 };

// ===================== STEAM API (offline mock) =====================
// Every vtable slot holds a synthetic guest VA from bo3_com_register_thunk() (reserved window far
// above the guest image), never a hard-coded VA inside the guest's __TEXT.
extern uint64_t bo3_com_register_thunk(GuestFn fn, const char *name);

#define STEAM_VT_SLOTS 128
static uint64_t g_steam_client_vt[STEAM_VT_SLOTS];
static uint64_t g_steam_user_vt[STEAM_VT_SLOTS];
static uint64_t g_steam_apps_vt[STEAM_VT_SLOTS];
static uint64_t g_steam_friends_vt[STEAM_VT_SLOTS];
static uint64_t g_steam_utils_vt[STEAM_VT_SLOTS];
static uint64_t g_steam_rs_vt[STEAM_VT_SLOTS];
static uint64_t g_steam_mm_vt[STEAM_VT_SLOTS];
static uint64_t g_steam_gs_vt[STEAM_VT_SLOTS];
static uint64_t g_steam_sub_vt[STEAM_VT_SLOTS];

static uint64_t g_steam_client_obj  = 0;
static uint64_t g_steam_user_obj    = 0;
static uint64_t g_steam_apps_obj    = 0;
static uint64_t g_steam_friends_obj = 0;
static uint64_t g_steam_utils_obj   = 0;
static uint64_t g_steam_rs_obj      = 0;
static uint64_t g_steam_mm_obj      = 0;
static uint64_t g_steam_gs_obj      = 0;
static uint64_t g_steam_sub_obj     = 0;

static GuestRet steam_ret0(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_u64(0); }
static GuestRet steam_ret1(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_u64(1); }
static GuestRet steam_ret_appid(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_u64(BO3_STEAM_APPID); }
static GuestRet steam_ret_steamid(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_u64(BO3_STEAM_LOCALID); }
static GuestRet steam_ret_english(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_ptr("english"); }
static GuestRet steam_ret_player(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_ptr("Player"); }
static GuestRet steam_ret_us(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_ptr("US"); }
static GuestRet steam_ret_empty_str(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_ptr(""); }
static GuestRet steam_ret_battery_ac(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_u64(255); }
static GuestRet steam_ret_time(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_u64((uint64_t)(uint32_t)time(NULL)); }
static GuestRet steam_mock_create_local(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    if (rsi) *(int32_t *)(uintptr_t)rsi = 1;
    return ret_u64(1);
}

// ---- ISteamClient017::GetISteam*(...) ----
#define STEAM_VERSION_CAP 128

// Copy through Mach so an unmapped guest address fails without a native load.
// Read one page at a time to accept strings ending at a mapping boundary.
static const char *steam_read_version(uint64_t addr, char ver[STEAM_VERSION_CAP]) {
    if (addr < 0x100000000ULL || addr > UINT64_MAX - STEAM_VERSION_CAP) return NULL;
    size_t offset = 0;
    while (offset < STEAM_VERSION_CAP) {
        size_t len = vm_page_size - (addr + offset) % vm_page_size;
        if (len > STEAM_VERSION_CAP - offset) len = STEAM_VERSION_CAP - offset;
        mach_vm_size_t copied = 0;
        kern_return_t rc = mach_vm_read_overwrite(mach_task_self(), addr + offset, len,
                                                 (mach_vm_address_t)(uintptr_t)(ver + offset), &copied);
        if (rc != KERN_SUCCESS || copied != len) return NULL;
        if (memchr(ver + offset, '\0', len)) return ver;
        offset += len;
    }
    return NULL;
}

static uint64_t *steam_iface_for_version(const char *ver) {
    if (!ver) return &g_steam_sub_obj;
    if (strncmp(ver, "SteamUser0", 10) == 0)          return &g_steam_user_obj;
    if (strncmp(ver, "SteamGameServer0", 16) == 0)   return &g_steam_gs_obj;
    if (strncmp(ver, "STEAMAPPS_", 10) == 0)          return &g_steam_apps_obj;
    if (strncmp(ver, "SteamFriends", 12) == 0)        return &g_steam_friends_obj;
    if (strncmp(ver, "SteamUtils", 10) == 0)          return &g_steam_utils_obj;
    if (strncmp(ver, "SteamMatchMaking0", 17) == 0)    return &g_steam_mm_obj;
    if (strncmp(ver, "STEAMREMOTESTORAGE_", 19) == 0) return &g_steam_rs_obj;
    return &g_steam_sub_obj;
}

// GetISteamXxx(HSteamUser, HSteamPipe, const char *ver)
static GuestRet steam_client_get_iface(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    char ver[STEAM_VERSION_CAP];
    return ret_ptr(steam_iface_for_version(steam_read_version(rcx, ver)));
}
// GetISteamUtils(HSteamPipe, const char *ver)
static GuestRet steam_client_get_utils(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    char ver[STEAM_VERSION_CAP];
    return ret_ptr(steam_iface_for_version(steam_read_version(rdx, ver)));
}

// ---- Offline ISteamGameServer012 and CCallbackBase ----
enum {
    STEAM_CALLBACK_REGISTERED = 1,
    STEAM_CALLBACK_GAME_SERVER = 2,
    STEAM_CALLBACK_CAP = 512,
    STEAM_GS_CONNECTED = 101,
    STEAM_GS_POLICY_RESPONSE = 115,
    STEAM_GS_VALIDATE_TICKET = 143,
    STEAM_AUTH_CAP = 16,
    STEAM_AUTH_TOKEN_SIZE = 16,
    STEAM_AUTH_BEGIN_OK = 0,
    STEAM_AUTH_BEGIN_INVALID = 1,
    STEAM_AUTH_BEGIN_DUPLICATE = 2,
    STEAM_AUTH_RESPONSE_OK = 0,
    STEAM_AUTH_RESPONSE_CANCELED = 6,
};

// The guest destructor stores this vtable at 0x100f6af33 before unregistering.
// Its Run slot binds to __cxa_pure_virtual (zero in the unbound Mach-O data).
#define BO3_STEAM_CALLBACK_BASE_VTABLE 0x10208f9a0ULL

typedef struct SteamCallback {
    const uint64_t *vtable;
    uint8_t flags;
    int32_t id;
} SteamCallback;

_Static_assert(offsetof(SteamCallback, flags) == 0x08 &&
               offsetof(SteamCallback, id) == 0x0c, "CCallbackBase layout");

typedef struct SteamCallbackRegistration {
    SteamCallback *callback;
    uint64_t serial;
} SteamCallbackRegistration;

// The guest's callback size method returns 20 bytes for callback 143.
#pragma pack(push, 4)
typedef struct SteamValidateAuthTicketResponse {
    uint64_t steam_id;
    int32_t response;
    uint64_t owner_steam_id;
} SteamValidateAuthTicketResponse;
#pragma pack(pop)

_Static_assert(offsetof(SteamValidateAuthTicketResponse, response) == 8 &&
               offsetof(SteamValidateAuthTicketResponse, owner_steam_id) == 12 &&
               sizeof(SteamValidateAuthTicketResponse) == 20, "ValidateAuthTicketResponse_t layout");

typedef struct SteamAuthTicket {
    uint32_t handle;
    uint8_t token[STEAM_AUTH_TOKEN_SIZE];
    int active;
} SteamAuthTicket;

typedef struct SteamAuthSession {
    uint32_t handle; // Zero marks a free slot.
    uint64_t steam_id;
} SteamAuthSession;

typedef struct SteamAuthEvent {
    uint64_t serial;
    uint32_t handle;
    SteamValidateAuthTicketResponse payload;
} SteamAuthEvent;

static pthread_mutex_t g_steam_callback_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_steam_callback_idle = PTHREAD_COND_INITIALIZER;
static SteamCallbackRegistration g_steam_callbacks[STEAM_CALLBACK_CAP];
static uint64_t g_steam_callback_serial;
typedef struct SteamPump {
    unsigned in_flight;      // native calls using this pipe, including its callback pump
    int closing;             // 1 = requested, 2 = teardown claimed
    uint64_t close_serial;
    SteamCallback *running;  // callback object whose guest code is executing
} SteamPump;
static SteamPump g_steam_pumps[STEAM_PUMP_COUNT];
// Protected by the callback lock. Pumps and response callbacks share one guest dispatcher.
static bool g_steam_dispatch_active;
static pthread_t g_steam_dispatch_thread;
static _Thread_local unsigned g_steam_pipe_refs[STEAM_PUMP_COUNT];
static uint32_t g_gs_online_session_handle;
static int g_gs_logged_on;
static int g_gs_logon_pending;
static uint64_t g_gs_session;
static SteamAuthTicket g_steam_tickets[STEAM_AUTH_CAP];
static uint32_t g_steam_next_ticket_handle;
static SteamAuthSession g_gs_auth_sessions[STEAM_AUTH_CAP];
static SteamAuthEvent g_gs_auth_events[STEAM_AUTH_CAP];
static size_t g_gs_auth_event_count;
static uint64_t g_gs_auth_event_serial;

// Auth tickets, sessions and the event queue share the callback registry lock.
static void steam_gs_enqueue_auth(SteamAuthSession session, int32_t response) {
    if (g_gs_auth_event_count >= STEAM_AUTH_CAP) return;
    g_gs_auth_events[g_gs_auth_event_count++] = (SteamAuthEvent){
        .serial = ++g_gs_auth_event_serial,
        .handle = session.handle,
        .payload = {session.steam_id, response, steam_local_id()},
    };
}

static void steam_gs_remove_auth_event(size_t index) {
    --g_gs_auth_event_count;
    memmove(&g_gs_auth_events[index], &g_gs_auth_events[index + 1],
            (g_gs_auth_event_count - index) * sizeof(g_gs_auth_events[0]));
}

// BO3 can call GetAuthSessionTicket with BLoggedOn() false. Issue a
// process-local token bound to the synthetic local SteamID.
static GuestRet steam_user_get_auth_ticket(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    if (rcx) {
        uint32_t size = 0;
        memcpy((void *)(uintptr_t)rcx, &size, sizeof(size));
    }
    if (!rsi || !rcx || (int32_t)rdx < STEAM_AUTH_TOKEN_SIZE)
        return ret_u64(0);

    pthread_mutex_lock(&g_steam_callback_lock);
    uint32_t handle = 0;
    for (size_t i = 0; i < STEAM_AUTH_CAP && g_steam_next_ticket_handle < UINT32_MAX; ++i) {
        SteamAuthTicket *ticket = &g_steam_tickets[i];
        if (ticket->active) continue;

        handle = ++g_steam_next_ticket_handle;
        ticket->handle = handle;
        ticket->active = 1;
        // Include the handle so every token is unique, even across slot reuse.
        memcpy(ticket->token, &handle, sizeof(handle));
        arc4random_buf(ticket->token + sizeof(handle), sizeof(ticket->token) - sizeof(handle));
        uint32_t size = sizeof(ticket->token);
        memcpy((void *)(uintptr_t)rsi, ticket->token, size);
        memcpy((void *)(uintptr_t)rcx, &size, sizeof(size));
        break;
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_u64(handle);
}

static GuestRet steam_user_cancel_auth_ticket(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    uint32_t handle = (uint32_t)rsi;
    if (!handle) return ret_void();

    pthread_mutex_lock(&g_steam_callback_lock);
    for (size_t i = 0; i < STEAM_AUTH_CAP; ++i) {
        SteamAuthTicket *ticket = &g_steam_tickets[i];
        if (ticket->handle == handle) {
            ticket->active = 0;
            break;
        }
    }
    for (size_t i = 0; i < STEAM_AUTH_CAP; ++i) {
        SteamAuthSession *session = &g_gs_auth_sessions[i];
        if (session->handle != handle) continue;

        for (size_t j = 0; j < g_gs_auth_event_count; ++j) {
            if (g_gs_auth_events[j].handle == handle) {
                steam_gs_remove_auth_event(j);
                break;
            }
        }
        // Only the local ID can have an active session. A full queue must
        // contain that session's OK event, which was removed above.
        steam_gs_enqueue_auth(*session, STEAM_AUTH_RESPONSE_CANCELED);
        *session = (SteamAuthSession){0};
        break;
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_void();
}

static GuestRet steam_gs_logon_anonymous(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    pthread_mutex_lock(&g_steam_callback_lock);
    if (!g_gs_logged_on) {
        g_gs_logged_on = 1;
        g_gs_logon_pending = 1;
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_void();
}

static GuestRet steam_gs_logged_on(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    pthread_mutex_lock(&g_steam_callback_lock);
    int logged_on = g_gs_logged_on;
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_u64(logged_on);
}

static GuestRet steam_gs_logoff(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    pthread_mutex_lock(&g_steam_callback_lock);
    g_gs_logged_on = 0;
    g_gs_logon_pending = 0;
    memset(g_gs_auth_sessions, 0, sizeof(g_gs_auth_sessions));
    g_gs_auth_event_count = 0;
    ++g_gs_session;
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_void();
}

static GuestRet steam_gs_steamid(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_u64(BO3_STEAM_SERVERID);
}

// any_token: online with a fallback local server, the ticket is a real Steam ticket for the
// signed-in account (from the native ISteamUser), which this mock cannot verify.
static int steam_gs_begin_auth(const void *token, uint64_t steam_id, int any_token) {
    if (!g_gs_logged_on) return STEAM_AUTH_BEGIN_INVALID;

    SteamAuthSession *free_session = NULL;
    for (size_t i = 0; i < STEAM_AUTH_CAP; ++i) {
        SteamAuthSession *session = &g_gs_auth_sessions[i];
        if (session->handle && session->steam_id == steam_id) return STEAM_AUTH_BEGIN_DUPLICATE;
        if (!free_session && !session->handle) free_session = session;
    }
    if (!free_session || g_gs_auth_event_count == STEAM_AUTH_CAP) return STEAM_AUTH_BEGIN_INVALID;

    if (any_token) {
        uint32_t handle = 0x80000000u | (++g_gs_online_session_handle & 0x7fffffffu);
        *free_session = (SteamAuthSession){handle, steam_id};
        steam_gs_enqueue_auth(*free_session, STEAM_AUTH_RESPONSE_OK);
        return STEAM_AUTH_BEGIN_OK;
    }
    for (size_t i = 0; i < STEAM_AUTH_CAP; ++i) {
        const SteamAuthTicket *ticket = &g_steam_tickets[i];
        if (!ticket->active || memcmp(token, ticket->token, sizeof(ticket->token))) continue;

        *free_session = (SteamAuthSession){ticket->handle, steam_id};
        steam_gs_enqueue_auth(*free_session, STEAM_AUTH_RESPONSE_OK);
        return STEAM_AUTH_BEGIN_OK;
    }
    return STEAM_AUTH_BEGIN_INVALID;
}

static GuestRet steam_gs_begin_auth_session(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    const int online = steam_online();
    if (rcx != steam_local_id() || !rsi ||
        (online ? (int32_t)rdx <= 0 : (uint32_t)rdx != STEAM_AUTH_TOKEN_SIZE))
        return ret_u64(STEAM_AUTH_BEGIN_INVALID);

    pthread_mutex_lock(&g_steam_callback_lock);
    int result = steam_gs_begin_auth((const void *)(uintptr_t)rsi, rcx, online);
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_u64(result);
}

static GuestRet steam_gs_end_auth_session(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    pthread_mutex_lock(&g_steam_callback_lock);
    for (size_t i = 0; i < STEAM_AUTH_CAP; ++i) {
        if (g_gs_auth_sessions[i].steam_id == rsi) g_gs_auth_sessions[i] = (SteamAuthSession){0};
    }
    for (size_t i = g_gs_auth_event_count; i > 0; --i) {
        if (g_gs_auth_events[i - 1].payload.steam_id == rsi) steam_gs_remove_auth_event(i - 1);
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_void();
}

static GuestRet steam_gs_has_license(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_u64(rsi == steam_local_id() ? 0 : 2); // HasLicense or NoAuth
}

// Called with the registry locked. Pin each callback while guest code runs so
// unregister on another thread can wait for it before destroying the object.
static void steam_gs_dispatch(GuestContext *ctx, uint64_t rsp, int32_t id,
                              uint64_t session, uint64_t auth_serial) {
    uint64_t last_serial = g_steam_callback_serial;
    for (size_t i = 0; i < STEAM_CALLBACK_CAP && session == g_gs_session; ++i) {
        // EndAuthSession or CancelAuthTicket can remove this event while a
        // prior subscriber is running. Recheck before selecting a subscriber.
        if (auth_serial && (!g_gs_auth_event_count || g_gs_auth_events[0].serial != auth_serial))
            break;

        const SteamCallbackRegistration *registration = &g_steam_callbacks[i];
        SteamCallback *callback = registration->callback;
        if (!callback || registration->serial > last_serial || callback->id != id ||
            !(callback->flags & STEAM_CALLBACK_GAME_SERVER)) continue;

        // Guest teardown writes the vptr without the registry lock. Take a
        // single snapshot so the target always comes from the checked table.
        const uint64_t *vtable = __atomic_load_n(&callback->vtable, __ATOMIC_ACQUIRE);
        if (!vtable || (uintptr_t)vtable == BO3_STEAM_CALLBACK_BASE_VTABLE) continue;
        uint64_t run_va = vtable[0]; // Run(void *pvParam)
        if (!run_va) continue;

        // SteamServersConnected_t is empty. GSPolicyResponse_t has a single byte,
        // m_bSecure, which stays false on the offline server.
        uint8_t insecure = 0;
        SteamValidateAuthTicketResponse auth;
        void *payload = &insecure;
        if (auth_serial) {
            auth = g_gs_auth_events[0].payload;
            payload = &auth;
        }
        g_steam_pumps[STEAM_PUMP_GS].running = callback;
        pthread_mutex_unlock(&g_steam_callback_lock);

        uint64_t sp = ((rsp - 128) & ~15ULL) - 8;
        *(uint64_t *)(uintptr_t)sp = 0;
        GuestFn run = bo3_resolve(run_va, ctx);
        run(ctx, sp, (uint64_t)(uintptr_t)callback, (uint64_t)(uintptr_t)payload,
            0, 0, 0, 0,
            guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
            guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());

        pthread_mutex_lock(&g_steam_callback_lock);
        g_steam_pumps[STEAM_PUMP_GS].running = NULL;
        pthread_cond_broadcast(&g_steam_callback_idle);
    }
}

// ---- ISteamRemoteStorage013 (local, file-backed, atomic temp+rename writes) ----
static pthread_mutex_t g_rs_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t  g_rs_once = PTHREAD_ONCE_INIT;
#define RS_PATH_CAP 512
#define RS_DIR_FLAGS (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
static int g_rs_root_fd = -1;

static void rs_root_init(void) {
    char path[1024];
    int n;
    const char *override = getenv("BO3ARM_REMOTE_STORAGE_DIR");
    if (override && override[0]) {
        n = snprintf(path, sizeof(path), "%s", override);
    } else {
        const char *home = getenv("HOME");
        if (!home || !home[0]) home = "/tmp";
        char base[900];
        int len = snprintf(base, sizeof(base), "%s/Library/Application Support/Call of Duty Black Ops III", home);
        if (len < 0 || (size_t)len >= sizeof(base)) return;
        mkdir(base, 0755);
        n = snprintf(path, sizeof(path), "%s/bo3arm_remote_storage", base);
    }
    if (n <= 0 || (size_t)n >= sizeof(path)) return;
    while (n > 1 && path[n - 1] == '/') path[--n] = '\0';
    if (mkdir(path, 0755) != 0 && errno != EEXIST) return;
    g_rs_root_fd = open(path, RS_DIR_FLAGS);
}

static int rs_open_root(void) {
    pthread_once(&g_rs_once, rs_root_init);
    if (g_rs_root_fd < 0) { errno = EBADF; return -1; }
    // Give each traversal its own directory offset for fdopendir/readdir.
    return openat(g_rs_root_fd, ".", RS_DIR_FLAGS);
}

static int rs_path(const char *name, char rel[RS_PATH_CAP]) {
    if (!name || !name[0] || name[0] == '/' || name[0] == '\\') return -1;
    size_t n = strnlen(name, RS_PATH_CAP);
    if (n >= RS_PATH_CAP) return -1;
    for (size_t i = 0; i <= n; i++) rel[i] = name[i] == '\\' ? '/' : name[i];
    if (rel[n - 1] == '/' || strstr(rel, ".bo3tmp.")) return -1;
    for (const char *p = rel; *p;) {
        const char *e = strchr(p, '/');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len == 0 || (len == 1 && p[0] == '.') || (len == 2 && p[0] == '.' && p[1] == '.')) return -1;
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

// Traversal holds each parent open while resolving the next component.
static int rs_open_parent(char *path, char **leaf, int create_dirs) {
    int dir = rs_open_root();
    if (dir < 0) return -1;
    char *component = path;
    for (char *slash; (slash = strchr(component, '/')) != NULL;) {
        *slash = '\0';
        if (create_dirs && mkdirat(dir, component, 0755) != 0 && errno != EEXIST) {
            int err = errno;
            close(dir);
            errno = err;
            return -1;
        }
        int next = openat(dir, component, RS_DIR_FLAGS);
        int err = errno;
        close(dir);
        if (next < 0) { errno = err; return -1; }
        dir = next;
        component = slash + 1;
    }
    *leaf = component;
    return dir;
}

static int rs_open_regular(int dir, const char *leaf, struct stat *st) {
    int fd = openat(dir, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fstat(fd, st) != 0 || !S_ISREG(st->st_mode)) {
        close(fd);
        return -1;
    }
    return fd;
}

static int rs_open_file(const char *name, struct stat *st) {
    char path[RS_PATH_CAP], *leaf;
    if (rs_path(name, path) != 0) return -1;
    int dir = rs_open_parent(path, &leaf, 0);
    if (dir < 0) return -1;
    int fd = rs_open_regular(dir, leaf, st);
    close(dir);
    return fd;
}

static int rs_target_writable(int dir, const char *leaf) {
    struct stat st;
    if (fstatat(dir, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0) return S_ISREG(st.st_mode);
    return errno == ENOENT;
}

static int rs_write_atomic(const char *name, const void *data, size_t len) {
    char path[RS_PATH_CAP], *leaf;
    if ((len && !data) || rs_path(name, path) != 0) return 0;
    pthread_mutex_lock(&g_rs_lock);
    int dir = rs_open_parent(path, &leaf, 1);
    int ok = 0;
    if (dir >= 0 && rs_target_writable(dir, leaf)) {
        char tmp[48];
        int fd = -1;
        for (int attempt = 0; attempt < 8; attempt++) {
            unsigned long long nonce;
            arc4random_buf(&nonce, sizeof(nonce));
            snprintf(tmp, sizeof(tmp), ".bo3tmp.%016llx", nonce);
            fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
            if (fd >= 0 || errno != EEXIST) break;
        }
        if (fd >= 0) {
            const uint8_t *src = data;
            size_t left = len;
            while (left) {
                ssize_t w = write(fd, src, left);
                if (w < 0 && errno == EINTR) continue;
                if (w <= 0) break;
                src += w;
                left -= (size_t)w;
            }
            ok = left == 0 && fsync(fd) == 0;
            if (close(fd) != 0) ok = 0;
            if (ok) ok = renameat(dir, tmp, dir, leaf) == 0;
            if (!ok) unlinkat(dir, tmp, 0);
        }
    }
    if (dir >= 0) close(dir);
    pthread_mutex_unlock(&g_rs_lock);
    return ok;
}

static int rs_file_stat(const char *name, struct stat *st) {
    int fd = rs_open_file(name, st);
    if (fd < 0) return -1;
    close(fd);
    return 0;
}

static int64_t rs_file_size(const char *name) {
    struct stat st;
    return rs_file_stat(name, &st) == 0 ? (int64_t)st.st_size : -1;
}

// slot 0: bool FileWrite(const char *pchFile, const void *pvData, int32 cubData)
static GuestRet steam_rs_file_write(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    int32_t len = (int32_t)rcx;
    if (len < 0) return ret_u64(0);
    return ret_u64((uint64_t)rs_write_atomic((const char *)rsi, (const void *)rdx, (size_t)len));
}
// slot 1: int32 FileRead(const char *pchFile, void *pvData, int32 cubDataToRead)
static GuestRet steam_rs_file_read(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    int32_t want = (int32_t)rcx;
    if (want <= 0 || !rdx) return ret_u64(0);
    pthread_mutex_lock(&g_rs_lock);
    int32_t got = 0;
    struct stat st;
    int fd = rs_open_file((const char *)rsi, &st);
    if (fd >= 0) {
        uint8_t *dst = (uint8_t *)rdx;
        while (got < want) {
            ssize_t r = read(fd, dst + got, (size_t)(want - got));
            if (r < 0) { if (errno == EINTR) continue; break; }
            if (r == 0) break;
            got += (int32_t)r;
        }
        close(fd);
    }
    pthread_mutex_unlock(&g_rs_lock);
    return ret_u64((uint64_t)(uint32_t)got);
}
// slot 5: FileForget / slot 6: bool FileDelete(const char *pchFile)
static GuestRet steam_rs_file_delete(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    char path[RS_PATH_CAP], *leaf;
    if (rs_path((const char *)rsi, path) != 0) return ret_u64(0);
    pthread_mutex_lock(&g_rs_lock);
    int dir = rs_open_parent(path, &leaf, 0);
    struct stat st;
    int ok = dir >= 0 && fstatat(dir, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0 &&
             S_ISREG(st.st_mode) && unlinkat(dir, leaf, 0) == 0;
    if (dir >= 0) close(dir);
    pthread_mutex_unlock(&g_rs_lock);
    return ret_u64((uint64_t)ok);
}

// slots 9..12: buffered write streams, committed atomically on close
#define RS_MAX_STREAMS 16
#define RS_STREAM_INDEX_BITS 16
typedef struct RsStream {
    int used;
    uint64_t generation;
    char name[RS_PATH_CAP];
    uint8_t *buf;
    size_t len, cap;
} RsStream;
static RsStream g_rs_streams[RS_MAX_STREAMS];

static GuestRet steam_rs_stream_open(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    char path[RS_PATH_CAP], *leaf;
    const char *name = (const char *)rsi;
    if (rs_path(name, path) != 0) return ret_u64(UINT64_MAX);
    pthread_mutex_lock(&g_rs_lock);
    int dir = rs_open_parent(path, &leaf, 0);
    int valid = dir < 0 ? errno == ENOENT : rs_target_writable(dir, leaf);
    if (dir >= 0) close(dir);
    uint64_t handle = UINT64_MAX;
    for (int i = 0; valid && i < RS_MAX_STREAMS; i++) {
        RsStream *s = &g_rs_streams[i];
        if (s->used || s->generation == (UINT64_MAX >> RS_STREAM_INDEX_BITS)) continue;
        s->used = 1;
        s->generation++;
        strlcpy(s->name, name, sizeof(s->name));
        handle = (s->generation << RS_STREAM_INDEX_BITS) | (uint64_t)(i + 1);
        break;
    }
    pthread_mutex_unlock(&g_rs_lock);
    return ret_u64(handle);
}

static RsStream *rs_stream_get(uint64_t h) {
    uint16_t index = (uint16_t)h;
    if (!index || index > RS_MAX_STREAMS) return NULL;
    RsStream *s = &g_rs_streams[index - 1];
    return s->used && s->generation == h >> RS_STREAM_INDEX_BITS ? s : NULL;
}
static GuestRet steam_rs_stream_write(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    int32_t len = (int32_t)rcx;
    pthread_mutex_lock(&g_rs_lock);
    RsStream *s = rs_stream_get(rsi);
    int ok = 0;
    if (s && len >= 0 && (len == 0 || rdx) && (size_t)len <= SIZE_MAX - s->len) {
        size_t need = s->len + (size_t)len;
        if (need > s->cap) {
            size_t cap = s->cap ? s->cap : 4096;
            while (cap < need) cap = cap > SIZE_MAX / 2 ? need : cap * 2;
            uint8_t *nb = (uint8_t *)realloc(s->buf, cap);
            if (nb) { s->buf = nb; s->cap = cap; }
        }
        if (need <= s->cap) {
            if (len) memcpy(s->buf + s->len, (const void *)rdx, (size_t)len);
            s->len = need;
            ok = 1;
        }
    }
    pthread_mutex_unlock(&g_rs_lock);
    return ret_u64((uint64_t)ok);
}
static int rs_stream_finish(uint64_t h, int commit) {
    pthread_mutex_lock(&g_rs_lock);
    RsStream *s = rs_stream_get(h);
    if (!s) { pthread_mutex_unlock(&g_rs_lock); return 0; }
    RsStream local = *s;
    *s = (RsStream){.generation = local.generation};
    pthread_mutex_unlock(&g_rs_lock);
    int ok = commit ? rs_write_atomic(local.name, local.buf, local.len) : 1;
    free(local.buf);
    return ok;
}
static GuestRet steam_rs_stream_close(SHIM_PARAMS)  { SHIM_UNUSED_ALL(); return ret_u64((uint64_t)rs_stream_finish(rsi, 1)); }
static GuestRet steam_rs_stream_cancel(SHIM_PARAMS) { SHIM_UNUSED_ALL(); return ret_u64((uint64_t)rs_stream_finish(rsi, 0)); }

// slot 13: FileExists / slot 14: FilePersisted
static GuestRet steam_rs_file_exists(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_u64(rs_file_size((const char *)rsi) >= 0 ? 1 : 0);
}
// slot 15: int32 GetFileSize(const char *pchFile)
static GuestRet steam_rs_get_file_size(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    int64_t sz = rs_file_size((const char *)rsi);
    if (sz < 0) sz = 0;
    if (sz > INT32_MAX) sz = INT32_MAX;
    return ret_u64((uint64_t)(uint32_t)(int32_t)sz);
}
// slot 16: int64 GetFileTimestamp(const char *pchFile)
static GuestRet steam_rs_get_file_timestamp(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    struct stat st;
    if (rs_file_stat((const char *)rsi, &st) != 0) return ret_u64(0);
    return ret_i64((int64_t)st.st_mtimespec.tv_sec);
}

// Slots 18/19: iterate a snapshot and return each name in thread-local storage.
typedef struct RsEntry { char *name; int32_t size; } RsEntry;
static RsEntry *g_rs_list = NULL;
static int32_t  g_rs_list_n = 0, g_rs_list_cap = 0;

static void rs_list_clear(void) {
    for (int32_t i = 0; i < g_rs_list_n; i++) free(g_rs_list[i].name);
    g_rs_list_n = 0;
}
static void rs_list_add(const char *rel, int64_t size) {
    if (g_rs_list_n == g_rs_list_cap) {
        if (g_rs_list_cap > INT32_MAX / 2) return;
        int32_t cap = g_rs_list_cap ? g_rs_list_cap * 2 : 32;
        RsEntry *nl = (RsEntry *)realloc(g_rs_list, (size_t)cap * sizeof(RsEntry));
        if (!nl) return;
        g_rs_list = nl; g_rs_list_cap = cap;
    }
    char *dup = strdup(rel);
    if (!dup) return;
    g_rs_list[g_rs_list_n].name = dup;
    g_rs_list[g_rs_list_n].size = size > INT32_MAX ? INT32_MAX : (int32_t)size;
    g_rs_list_n++;
}
static void rs_list_scan(int dir, const char *prefix, int depth) {
    if (dir < 0) return;
    DIR *d = fdopendir(dir);
    if (!d) { close(dir); return; }
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        const char *name = de->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0 ||
            strstr(name, ".bo3tmp.") || strchr(name, '\\')) continue;
        char rel[RS_PATH_CAP];
        int n = snprintf(rel, sizeof(rel), "%s%s%s", prefix, *prefix ? "/" : "", name);
        if (n <= 0 || (size_t)n >= sizeof(rel)) continue;
        struct stat st;
        if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) != 0) continue;
        if (S_ISDIR(st.st_mode) && depth < 8) {
            rs_list_scan(openat(dir, name, RS_DIR_FLAGS), rel, depth + 1);
        } else if (S_ISREG(st.st_mode)) {
            rs_list_add(rel, (int64_t)st.st_size);
        }
    }
    closedir(d);
}
static GuestRet steam_rs_get_file_count(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    pthread_mutex_lock(&g_rs_lock);
    rs_list_clear();
    rs_list_scan(rs_open_root(), "", 0);
    int32_t n = g_rs_list_n;
    pthread_mutex_unlock(&g_rs_lock);
    return ret_u64((uint64_t)(uint32_t)n);
}
// const char *GetFileNameAndSize(int iFile, int32 *pnFileSizeInBytes)
static GuestRet steam_rs_get_file_name_and_size(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    int32_t idx = (int32_t)rsi;
    int32_t *out_sz = (int32_t *)rdx;
    pthread_mutex_lock(&g_rs_lock);
    if (g_rs_list_n == 0) rs_list_scan(rs_open_root(), "", 0);
    static __thread char tls_name[RS_PATH_CAP];
    tls_name[0] = '\0';
    int32_t sz = 0;
    if (idx >= 0 && idx < g_rs_list_n) {
        strlcpy(tls_name, g_rs_list[idx].name, sizeof(tls_name));
        sz = g_rs_list[idx].size;
    }
    pthread_mutex_unlock(&g_rs_lock);
    if (out_sz) *out_sz = sz;
    return ret_ptr(tls_name);
}
// slot 20: bool GetQuota(int32 *pnTotalBytes, int32 *puAvailableBytes)
static GuestRet steam_rs_get_quota(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    if (rsi) *(int32_t *)rsi = 100 * 1024 * 1024;
    if (rdx) *(int32_t *)rdx = 100 * 1024 * 1024;
    return ret_u64(1);
}

static void steam_fill_vt(uint64_t *vt, uint64_t va) {
    for (int i = 0; i < STEAM_VT_SLOTS; i++) vt[i] = va;
}

static pthread_once_t g_steam_once = PTHREAD_ONCE_INIT;

static void steam_init_mocks(void) {
    const uint64_t T_IFACE   = bo3_com_register_thunk(steam_client_get_iface, "ISteamClient::GetISteam*");
    const uint64_t T_UTILSIF = bo3_com_register_thunk(steam_client_get_utils, "ISteamClient::GetISteamUtils");
    const uint64_t T_RET0    = bo3_com_register_thunk(steam_ret0,            "Steam::ret0");
    const uint64_t T_RET1    = bo3_com_register_thunk(steam_ret1,            "Steam::ret1");
    const uint64_t T_APPID   = bo3_com_register_thunk(steam_ret_appid,       "Steam::AppID");
    const uint64_t T_STEAMID = bo3_com_register_thunk(steam_ret_steamid,     "Steam::SteamID");
    const uint64_t T_ENGLISH = bo3_com_register_thunk(steam_ret_english,     "Steam::english");
    const uint64_t T_PLAYER  = bo3_com_register_thunk(steam_ret_player,      "Steam::Player");
    const uint64_t T_US      = bo3_com_register_thunk(steam_ret_us,          "Steam::US");
    const uint64_t T_EMPTY   = bo3_com_register_thunk(steam_ret_empty_str,   "Steam::empty_str");
    const uint64_t T_BATTERY = bo3_com_register_thunk(steam_ret_battery_ac,  "Steam::battery");
    const uint64_t T_TIME    = bo3_com_register_thunk(steam_ret_time,        "Steam::server_time");

    // ---- ISteamClient017 ----
    steam_fill_vt(g_steam_client_vt, T_RET0);
    g_steam_client_vt[0] = T_RET1;                   // CreateSteamPipe
    g_steam_client_vt[1] = T_RET1;                   // BReleaseSteamPipe
    g_steam_client_vt[2] = T_RET1;                   // ConnectToGlobalUser
    g_steam_client_vt[3] = bo3_com_register_thunk(steam_mock_create_local, "SteamClient::mock_CreateLocalUser");
    const unsigned iface_slots[] = {
        5, 6, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        23, 24, 25, 26, 27, 28, 29, 30, 34, 35
    };
    for (size_t i = 0; i < sizeof(iface_slots) / sizeof(iface_slots[0]); i++) {
        g_steam_client_vt[iface_slots[i]] = T_IFACE;
    }
    g_steam_client_vt[9] = T_UTILSIF;                // GetISteamUtils(pipe, ver)
    g_steam_client_obj = (uint64_t)(uintptr_t)g_steam_client_vt;

    // ---- ISteamUser019 (offline: BLoggedOn=false so BO3 takes its native offline path) ----
    steam_fill_vt(g_steam_user_vt, T_RET0);
    g_steam_user_vt[0] = T_RET1;                     // GetHSteamUser
    g_steam_user_vt[1] = T_RET0;                     // BLoggedOn -> false (no RequestEncryptedAppTicket waits)
    g_steam_user_vt[2] = T_STEAMID;                  // GetSteamID -> local id (profile/saves)
    g_steam_user_vt[13] = bo3_com_register_thunk(steam_user_get_auth_ticket,    "SteamUser::GetAuthSessionTicket");
    g_steam_user_vt[16] = bo3_com_register_thunk(steam_user_cancel_auth_ticket, "SteamUser::CancelAuthTicket");
    g_steam_user_obj = (uint64_t)(uintptr_t)g_steam_user_vt;

    // ---- ISteamGameServer012 ----
    steam_fill_vt(g_steam_gs_vt, T_RET0);
    g_steam_gs_vt[6]  = bo3_com_register_thunk(steam_gs_logon_anonymous, "GameServer::LogOnAnonymous");
    g_steam_gs_vt[7]  = bo3_com_register_thunk(steam_gs_logoff,          "GameServer::LogOff");
    g_steam_gs_vt[8]  = bo3_com_register_thunk(steam_gs_logged_on,       "GameServer::BLoggedOn");
    g_steam_gs_vt[9]  = T_RET0;                     // BSecure -> false
    g_steam_gs_vt[10] = bo3_com_register_thunk(steam_gs_steamid,         "GameServer::GetSteamID");
    g_steam_gs_vt[29] = bo3_com_register_thunk(steam_gs_begin_auth_session, "GameServer::BeginAuthSession");
    g_steam_gs_vt[30] = bo3_com_register_thunk(steam_gs_end_auth_session,   "GameServer::EndAuthSession");
    g_steam_gs_vt[32] = bo3_com_register_thunk(steam_gs_has_license,        "GameServer::UserHasLicenseForApp");
    g_steam_gs_obj = (uint64_t)(uintptr_t)g_steam_gs_vt;

    // ---- ISteamApps008 ----
    steam_fill_vt(g_steam_apps_vt, T_RET0);
    g_steam_apps_vt[0]  = T_RET1;                    // BIsSubscribed
    g_steam_apps_vt[4]  = T_ENGLISH;                 // GetCurrentGameLanguage
    g_steam_apps_vt[5]  = T_ENGLISH;                 // GetAvailableGameLanguages
    g_steam_apps_vt[6]  = T_RET1;                    // BIsSubscribedApp
    g_steam_apps_vt[7]  = T_RET1;                    // BIsDlcInstalled
    g_steam_apps_vt[10] = T_RET0;                    // GetDLCCount
    g_steam_apps_vt[11] = T_RET0;                    // BGetDLCDataByIndex
    g_steam_apps_vt[12] = T_RET0;                    // InstallDLC (void)
    g_steam_apps_vt[15] = T_RET0;                    // GetCurrentBetaName -> false
    g_steam_apps_vt[19] = T_RET1;                    // BIsAppInstalled
    g_steam_apps_vt[20] = T_STEAMID;                 // GetAppOwner
    g_steam_apps_vt[21] = T_EMPTY;                   // GetLaunchQueryParam
    g_steam_apps_obj = (uint64_t)(uintptr_t)g_steam_apps_vt;

    // ---- ISteamFriends015: every const char* slot returns a valid string ----
    steam_fill_vt(g_steam_friends_vt, T_RET0);
    g_steam_friends_vt[0]  = T_PLAYER;               // GetPersonaName
    g_steam_friends_vt[7]  = T_PLAYER;               // GetFriendPersonaName
    g_steam_friends_vt[9]  = T_EMPTY;                // GetFriendPersonaNameHistory
    g_steam_friends_vt[11] = T_EMPTY;                // GetPlayerNickname
    g_steam_friends_vt[14] = T_EMPTY;                // GetFriendsGroupName
    g_steam_friends_vt[20] = T_EMPTY;                // GetClanName
    g_steam_friends_vt[21] = T_EMPTY;                // GetClanTag
    g_steam_friends_vt[45] = T_EMPTY;                // GetFriendRichPresence
    g_steam_friends_vt[47] = T_EMPTY;                // GetFriendRichPresenceKeyByIndex
    g_steam_friends_obj = (uint64_t)(uintptr_t)g_steam_friends_vt;

    // ---- ISteamUtils008 ----
    steam_fill_vt(g_steam_utils_vt, T_RET0);
    g_steam_utils_vt[2]  = T_RET1;                   // GetConnectedUniverse -> k_EUniversePublic
    g_steam_utils_vt[3]  = T_TIME;                   // GetServerRealTime
    g_steam_utils_vt[4]  = T_US;                     // GetIPCountry
    g_steam_utils_vt[5]  = T_RET0;                   // GetImageSize -> false
    g_steam_utils_vt[6]  = T_RET0;                   // GetImageRGBA -> false
    g_steam_utils_vt[7]  = T_RET0;                   // GetCSERIPPort -> false
    g_steam_utils_vt[8]  = T_BATTERY;                // GetCurrentBatteryPower -> 255 (AC)
    g_steam_utils_vt[9]  = T_APPID;                  // GetAppID
    g_steam_utils_vt[23] = T_ENGLISH;                // GetSteamUILanguage
    g_steam_utils_obj = (uint64_t)(uintptr_t)g_steam_utils_vt;

    steam_fill_vt(g_steam_mm_vt, T_RET0);
    g_steam_mm_vt[19] = T_EMPTY;                    // GetLobbyData
    g_steam_mm_vt[24] = T_EMPTY;                    // GetLobbyMemberData
    g_steam_mm_obj = (uint64_t)(uintptr_t)g_steam_mm_vt;

    // ---- ISteamRemoteStorage013 (local save storage) ----
    steam_fill_vt(g_steam_rs_vt, T_RET0);
    g_steam_rs_vt[0]  = bo3_com_register_thunk(steam_rs_file_write,          "RemoteStorage::FileWrite");
    g_steam_rs_vt[1]  = bo3_com_register_thunk(steam_rs_file_read,           "RemoteStorage::FileRead");
    g_steam_rs_vt[2]  = T_RET0;                      // FileWriteAsync -> unsupported offline
    g_steam_rs_vt[3]  = T_RET0;                      // FileReadAsync -> k_uAPICallInvalid
    g_steam_rs_vt[4]  = T_RET0;                      // FileReadAsyncComplete
    g_steam_rs_vt[5]  = T_RET1;                      // FileForget (keep local copy)
    g_steam_rs_vt[6]  = bo3_com_register_thunk(steam_rs_file_delete,         "RemoteStorage::FileDelete");
    g_steam_rs_vt[7]  = T_RET0;                      // FileShare
    g_steam_rs_vt[8]  = T_RET1;                      // SetSyncPlatforms
    g_steam_rs_vt[9]  = bo3_com_register_thunk(steam_rs_stream_open,         "RemoteStorage::FileWriteStreamOpen");
    g_steam_rs_vt[10] = bo3_com_register_thunk(steam_rs_stream_write,        "RemoteStorage::FileWriteStreamWriteChunk");
    g_steam_rs_vt[11] = bo3_com_register_thunk(steam_rs_stream_close,        "RemoteStorage::FileWriteStreamClose");
    g_steam_rs_vt[12] = bo3_com_register_thunk(steam_rs_stream_cancel,       "RemoteStorage::FileWriteStreamCancel");
    g_steam_rs_vt[13] = bo3_com_register_thunk(steam_rs_file_exists,         "RemoteStorage::FileExists");
    g_steam_rs_vt[14] = g_steam_rs_vt[13];           // FilePersisted
    g_steam_rs_vt[15] = bo3_com_register_thunk(steam_rs_get_file_size,       "RemoteStorage::GetFileSize");
    g_steam_rs_vt[16] = bo3_com_register_thunk(steam_rs_get_file_timestamp,  "RemoteStorage::GetFileTimestamp");
    g_steam_rs_vt[17] = T_RET0;                      // GetSyncPlatforms -> k_ERemoteStoragePlatformNone
    g_steam_rs_vt[18] = bo3_com_register_thunk(steam_rs_get_file_count,      "RemoteStorage::GetFileCount");
    g_steam_rs_vt[19] = bo3_com_register_thunk(steam_rs_get_file_name_and_size, "RemoteStorage::GetFileNameAndSize");
    g_steam_rs_vt[20] = bo3_com_register_thunk(steam_rs_get_quota,           "RemoteStorage::GetQuota");
    g_steam_rs_vt[21] = T_RET1;                      // IsCloudEnabledForAccount
    g_steam_rs_vt[22] = T_RET1;                      // IsCloudEnabledForApp
    g_steam_rs_vt[23] = T_RET0;                      // SetCloudEnabledForApp (void)
    g_steam_rs_obj = (uint64_t)(uintptr_t)g_steam_rs_vt;

    // ---- every other interface (UserStats, Matchmaking, HTTP, UGC, ...): inert zeros ----
    steam_fill_vt(g_steam_sub_vt, T_RET0);
    g_steam_sub_obj = (uint64_t)(uintptr_t)g_steam_sub_vt;
}


void bo3_init_steam_mocks(void) {
    pthread_once(&g_steam_once, steam_init_mocks);
}

// ===================== Native steamclient.dylib bridge =====================

static int steam_env_is_1(const char *name) {
    const char *v = getenv(name);
    return v && strcmp(v, "1") == 0;
}
#define STEAM_LOG(...) do { fprintf(stderr, "[steam] " __VA_ARGS__); fputc('\n', stderr); fflush(stderr); } while (0)

static pthread_once_t g_steam_env_once = PTHREAD_ONCE_INIT;
static int g_steam_trace;

static void steam_cache_env(void) {
    bo3_settings_load_early();
    g_steam_trace = steam_env_is_1("BO3ARM_STEAM_TRACE");
    if (bo3_settings_friends_only())
        STEAM_LOG("Security: friends-only lobby/IM protection enabled (toggle via F10 / Cmd+, or BO3ARM_FRIENDS_ONLY=0)");
    else
        STEAM_LOG("Security: friends-only lobby/IM protection disabled");
}

static int steam_offline_mode(void) {
    pthread_once(&g_steam_env_once, steam_cache_env);
    return bo3_settings_offline_mode() ? 1 : 0;
}
static int steam_friends_only(void) {
    pthread_once(&g_steam_env_once, steam_cache_env);
    return bo3_settings_friends_only() ? 1 : 0;
}
static int steam_trace(void) {
    pthread_once(&g_steam_env_once, steam_cache_env);
    return g_steam_trace;
}

// ---- libsteam_api <-> steamclient ABI ----
#pragma pack(push, 4)
typedef struct SteamCallbackMsg {
    int32_t hSteamUser;
    int32_t iCallback;
    uint8_t *pubParam;
    int32_t cubParam;
} SteamCallbackMsg;

typedef struct SteamAPICallCompleted {
    uint64_t hAsyncCall;
    int32_t iCallback;
    uint32_t cubParam;
} SteamAPICallCompleted;
#pragma pack(pop)

_Static_assert(offsetof(SteamCallbackMsg, iCallback) == 4 && offsetof(SteamCallbackMsg, pubParam) == 8 &&
               offsetof(SteamCallbackMsg, cubParam) == 16 && sizeof(SteamCallbackMsg) == 20, "CallbackMsg_t layout");
_Static_assert(offsetof(SteamAPICallCompleted, iCallback) == 8 && offsetof(SteamAPICallCompleted, cubParam) == 12 &&
               sizeof(SteamAPICallCompleted) == 16, "SteamAPICallCompleted_t layout");

enum {
    STEAM_CB_API_CALL_COMPLETED = 703,
    STEAM_CB_ENCRYPTED_APP_TICKET = 154,
    STEAM_ACCOUNT_TYPE_GAME_SERVER = 3,
    STEAM_SERVER_MODE_NO_AUTH = 1,
    STEAM_SERVER_MODE_AUTH_SECURE = 3,
    STEAM_SERVER_FLAG_SECURE = 0x02,
    STEAM_SERVER_FLAG_PRIVATE = 0x20,
    STEAM_FRIEND_FLAG_IMMEDIATE = 0x04,
    STEAM_LOBBY_FRIENDS_ONLY = 1,
    STEAM_CHAT_ENTRY_CHAT_MSG = 1,
    STEAM_CALL_RESULT_CAP = 256,
    STEAM_CALL_RESULT_MAX_BYTES = 1048576,
    STEAM_CALLBACK_MAX_BYTES = 65536,
    STEAM_PUMP_MAX_MESSAGES = 4096,
};

// Separate from the mock's pipe 2 so it never aliases a native pipe handle.
#define STEAM_GS_MOCK_PIPE_ONLINE 0x7fff0002

typedef void *(*SteamCreateInterfaceFn)(const char *version, int32_t *return_code);
typedef bool (*SteamBGetCallbackFn)(int32_t pipe, SteamCallbackMsg *msg);
typedef void (*SteamFreeLastCallbackFn)(int32_t pipe);
typedef bool (*SteamGetAPICallResultFn)(int32_t pipe, uint64_t call, void *data, int32_t size,
                                        int32_t expected_callback, bool *failed);

static pthread_mutex_t g_native_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_native_load_state;                // 0 untried, 1 loaded, -1 unavailable
static void *g_native_dylib;
static SteamCreateInterfaceFn n_CreateInterface;
static SteamBGetCallbackFn n_BGetCallback;
static SteamFreeLastCallbackFn n_FreeLastCallback;
static SteamGetAPICallResultFn n_GetAPICallResult;

static void *g_native_client;                  // ISteamClient017*
static int32_t g_client_pipe, g_client_user;
static void *g_native_user;                    // ISteamUser019*
static void *g_native_friends;                 // ISteamFriends015*
static void *g_native_utils;                   // ISteamUtils008*
static void *g_native_controller;              // ISteamController003* (optional)
static int32_t g_gs_pipe, g_gs_user;
static void *g_native_gs;                      // ISteamGameServer012*

// Native virtual call: slot N of the object's arm64 vtable, cast to the exact prototype.
#define STEAM_VFN(obj, slot, type) ((type)((*(void *const *const *)(obj))[(slot)]))

static int32_t steam_client_pipe(void) { return __atomic_load_n(&g_client_pipe, __ATOMIC_ACQUIRE); }
static int32_t steam_gs_pipe(void) { return __atomic_load_n(&g_gs_pipe, __ATOMIC_ACQUIRE); }

static void steam_finish_close(int owner);

// The caller holds the callback lock. Teardown begins only after the last
// holder has stopped using the native interface or freed its last message.
static int steam_pin_pipe(int owner) {
    SteamPump *pump = &g_steam_pumps[owner];
    if (pump->closing || !(owner == STEAM_PUMP_CLIENT ? steam_client_pipe() : steam_gs_pipe()))
        return 0;
    ++pump->in_flight;
    ++g_steam_pipe_refs[owner];
    return 1;
}

static int steam_claim_close(SteamPump *pump) {
    if (pump->in_flight || pump->closing != 1) return 0;
    pump->closing = 2;
    return 1;
}

static void steam_unpin_pipe(int owner) {
    SteamPump *pump = &g_steam_pumps[owner];
    pthread_mutex_lock(&g_steam_callback_lock);
    --g_steam_pipe_refs[owner];
    --pump->in_flight;
    int finish = steam_claim_close(pump);
    pthread_mutex_unlock(&g_steam_callback_lock);
    if (finish) steam_finish_close(owner);
}

static int steam_native_load(void) {
    int offline = steam_offline_mode();
    pthread_mutex_lock(&g_native_lock);
    if (g_native_load_state == 0) {
        g_native_load_state = -1;
        if (offline) {
            STEAM_LOG("BO3ARM_OFFLINE=1: native steamclient disabled, using the offline mock");
        } else {
            char def[1024] = "";
            const char *home = getenv("HOME");
            if (home && home[0])
                snprintf(def, sizeof(def),
                         "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib",
                         home);
            const char *candidates[2] = { getenv("BO3ARM_STEAMCLIENT_DYLIB"), def };
            for (size_t i = 0; i < 2 && !g_native_dylib; ++i) {
                const char *path = candidates[i];
                if (!path || !path[0]) continue;
                g_native_dylib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
                if (g_native_dylib) STEAM_LOG("dlopen(%s) ok", path);
                else STEAM_LOG("dlopen(%s) failed: %s", path, dlerror());
            }
            if (g_native_dylib) {
                n_CreateInterface = (SteamCreateInterfaceFn)dlsym(g_native_dylib, "CreateInterface");
                n_BGetCallback = (SteamBGetCallbackFn)dlsym(g_native_dylib, "Steam_BGetCallback");
                n_FreeLastCallback = (SteamFreeLastCallbackFn)dlsym(g_native_dylib, "Steam_FreeLastCallback");
                n_GetAPICallResult = (SteamGetAPICallResultFn)dlsym(g_native_dylib, "Steam_GetAPICallResult");
                if (!n_CreateInterface || !n_BGetCallback || !n_FreeLastCallback || !n_GetAPICallResult) {
                    STEAM_LOG("steamclient.dylib lacks CreateInterface/Steam_BGetCallback/"
                              "Steam_FreeLastCallback/Steam_GetAPICallResult");
                } else {
                    int32_t rc = 0;
                    g_native_client = n_CreateInterface("SteamClient017", &rc);
                    if (g_native_client) {
                        g_native_load_state = 1;
                        STEAM_LOG("CreateInterface(SteamClient017) -> native ISteamClient017 %p", g_native_client);
                    } else {
                        STEAM_LOG("CreateInterface(SteamClient017) failed (rc=%d)", rc);
                    }
                }
            }
        }
    }
    int ok = g_native_load_state == 1;
    pthread_mutex_unlock(&g_native_lock);
    return ok;
}

// ---- Per-thread guest context for native -> guest re-entry ----
// Every proxy call scopes the caller's (ctx, rsp). Native code that calls back into a guest
// object during that call (ISteamMatchmakingServers responses) runs the guest on the stack
// below the innermost scope.
static __thread GuestContext *g_steam_ctx = NULL;
static __thread uint64_t g_steam_rsp = 0;

typedef struct SteamScope { GuestContext *ctx; uint64_t rsp; } SteamScope;
static inline SteamScope steam_scope_enter(GuestContext *ctx, uint64_t rsp) {
    SteamScope saved = { g_steam_ctx, g_steam_rsp };
    g_steam_ctx = ctx;
    g_steam_rsp = rsp;
    return saved;
}
static inline void steam_scope_leave(SteamScope saved) {
    g_steam_ctx = saved.ctx;
    g_steam_rsp = saved.rsp;
}

static inline GuestXmm f32_to_xmm(float f) {
    uint32_t u = 0;
    memcpy(&u, &f, sizeof(u));
    return guest_xmm_make((uint64_t)u, 0ULL);
}
static inline double steam_xmm_f64(GuestXmm x) {
    uint64_t u = x[0];
    double d;
    memcpy(&d, &u, sizeof(d));
    return d;
}

static GuestRet steam_guest_call(GuestContext *ctx, uint64_t rsp, uint64_t va,
                                 uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, GuestXmm x0) {
    GuestFn fn = bo3_resolve(va, ctx);
    uint64_t sp = ((rsp - 128) & ~15ULL) - 8;
    *(uint64_t *)(uintptr_t)sp = 0;
    return fn(ctx, sp, a0, a1, a2, a3, 0, 0,
              x0, guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
              guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
}

// ---- Bo3SteamProxy ----
enum {
    STEAM_KIND_GENERIC = 0,
    STEAM_KIND_CLIENT,
    STEAM_KIND_USER,
    STEAM_KIND_FRIENDS,
    STEAM_KIND_UTILS,
    STEAM_KIND_MATCHMAKING,
    STEAM_KIND_MMSERVERS,
    STEAM_KIND_NETWORKING,
    STEAM_KIND_APPS,
    STEAM_KIND_UGC,
    STEAM_KIND_GAMESERVER,
    STEAM_KIND_MUSIC,
    STEAM_KIND_CONTROLLER,
    STEAM_KIND_USERSTATS,
    STEAM_KIND_REMOTESTORAGE,
    STEAM_KIND_HTTP,
    STEAM_KIND_SCREENSHOTS,
    STEAM_KIND_GSSTATS,
    STEAM_KIND_APPLIST,
    STEAM_KIND_MUSICREMOTE,
    STEAM_KIND_HTMLSURFACE,
    STEAM_KIND_INVENTORY,
    STEAM_KIND_VIDEO,
    STEAM_KIND_UNIFIEDMSG,
    STEAM_KIND_COUNT,
};

static const struct { const char *version; const char *name; } k_steam_kinds[STEAM_KIND_COUNT] = {
    [STEAM_KIND_GENERIC]       = { NULL,                                   "generic" },
    [STEAM_KIND_CLIENT]        = { "SteamClient017",                       "ISteamClient017" },
    [STEAM_KIND_USER]          = { "SteamUser019",                         "ISteamUser019" },
    [STEAM_KIND_FRIENDS]       = { "SteamFriends015",                      "ISteamFriends015" },
    [STEAM_KIND_UTILS]         = { "SteamUtils008",                        "ISteamUtils008" },
    [STEAM_KIND_MATCHMAKING]   = { "SteamMatchMaking009",                  "ISteamMatchmaking009" },
    [STEAM_KIND_MMSERVERS]     = { "SteamMatchMakingServers002",           "ISteamMatchmakingServers002" },
    [STEAM_KIND_NETWORKING]    = { "SteamNetworking005",                   "ISteamNetworking005" },
    [STEAM_KIND_APPS]          = { "STEAMAPPS_INTERFACE_VERSION008",       "ISteamApps008" },
    [STEAM_KIND_UGC]           = { "STEAMUGC_INTERFACE_VERSION008",        "ISteamUGC008" },
    [STEAM_KIND_GAMESERVER]    = { "SteamGameServer012",                   "ISteamGameServer012" },
    [STEAM_KIND_MUSIC]         = { "STEAMMUSIC_INTERFACE_VERSION001",      "ISteamMusic001" },
    [STEAM_KIND_CONTROLLER]    = { "SteamController003",                   "ISteamController003" },
    [STEAM_KIND_USERSTATS]     = { "STEAMUSERSTATS_INTERFACE_VERSION011",  "ISteamUserStats011" },
    [STEAM_KIND_REMOTESTORAGE] = { "STEAMREMOTESTORAGE_INTERFACE_VERSION013", "ISteamRemoteStorage013" },
    [STEAM_KIND_HTTP]          = { "STEAMHTTP_INTERFACE_VERSION002",       "ISteamHTTP002" },
    [STEAM_KIND_SCREENSHOTS]   = { "STEAMSCREENSHOTS_INTERFACE_VERSION002", "ISteamScreenshots002" },
    [STEAM_KIND_GSSTATS]       = { "SteamGameServerStats001",              "ISteamGameServerStats001" },
    [STEAM_KIND_APPLIST]       = { "STEAMAPPLIST_INTERFACE_VERSION001",    "ISteamAppList001" },
    [STEAM_KIND_MUSICREMOTE]   = { "STEAMMUSICREMOTE_INTERFACE_VERSION001", "ISteamMusicRemote001" },
    [STEAM_KIND_HTMLSURFACE]   = { "STEAMHTMLSURFACE_INTERFACE_VERSION_003", "ISteamHTMLSurface003" },
    [STEAM_KIND_INVENTORY]     = { "STEAMINVENTORY_INTERFACE_V001",        "ISteamInventory001" },
    [STEAM_KIND_VIDEO]         = { "STEAMVIDEO_INTERFACE_V001",            "ISteamVideo001" },
    [STEAM_KIND_UNIFIEDMSG]    = { "STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001", "ISteamUnifiedMessages001" },
};

// Typed overrides are only valid for the exact versions BO3 was built against; any other
// version string gets the plain forwarding vtable.
static int steam_kind_for_version(const char *ver) {
    if (!ver) return STEAM_KIND_GENERIC;
    for (int k = 1; k < STEAM_KIND_COUNT; ++k) {
        if (strcmp(ver, k_steam_kinds[k].version) == 0) return k;
    }
    return STEAM_KIND_GENERIC;
}

#define STEAM_PROXY_SLOTS 80

typedef struct Bo3SteamProxy {
    uint64_t *guest_vt;     // guest vtable of synthetic thunk VAs (must stay first)
    void *native_obj;       // native arm64 interface object
    int kind;
    int owner;             // client or game server lifetime
    int32_t pipe;
} Bo3SteamProxy;

static uint64_t g_proxy_vt[STEAM_KIND_COUNT][STEAM_PROXY_SLOTS];
static pthread_once_t g_proxy_once = PTHREAD_ONCE_INIT;
static void steam_proxy_tables_init(void);

static pthread_mutex_t g_proxy_lock = PTHREAD_MUTEX_INITIALIZER;
static Bo3SteamProxy **g_proxies;
static size_t g_proxy_count, g_proxy_cap;
static Bo3SteamProxy g_client_facade = { .guest_vt = g_proxy_vt[STEAM_KIND_CLIENT], .kind = STEAM_KIND_CLIENT };

// Stable guest pointer per live (native object, kind, pipe). Invalidated proxies
// retain their guest vtable so stale guest references fail safely.
static Bo3SteamProxy *steam_wrap(void *native, int kind, int owner, int32_t pipe) {
    if (!native) return NULL;
    pthread_once(&g_proxy_once, steam_proxy_tables_init);
    pthread_mutex_lock(&g_proxy_lock);
    Bo3SteamProxy *proxy = NULL;
    for (size_t i = 0; i < g_proxy_count; ++i) {
        if (g_proxies[i]->native_obj == native && g_proxies[i]->kind == kind &&
            g_proxies[i]->owner == owner && g_proxies[i]->pipe == pipe) {
            proxy = g_proxies[i];
            break;
        }
    }
    int created = 0;
    if (!proxy) {
        if (g_proxy_count == g_proxy_cap) {
            size_t cap = g_proxy_cap ? g_proxy_cap * 2 : 32;
            Bo3SteamProxy **grown = (Bo3SteamProxy **)realloc(g_proxies, cap * sizeof(*grown));
            if (grown) { g_proxies = grown; g_proxy_cap = cap; }
        }
        if (g_proxy_count < g_proxy_cap && (proxy = (Bo3SteamProxy *)calloc(1, sizeof(*proxy))) != NULL) {
            proxy->guest_vt = g_proxy_vt[kind];
            proxy->native_obj = native;
            proxy->kind = kind;
            proxy->owner = owner;
            proxy->pipe = pipe;
            g_proxies[g_proxy_count++] = proxy;
            created = 1;
        }
    }
    pthread_mutex_unlock(&g_proxy_lock);
    if (created) STEAM_LOG("proxy %s: native %p -> guest %p", k_steam_kinds[kind].name, native, (void *)proxy);
    return proxy;
}

static void steam_invalidate_proxies(int owner, int32_t pipe) {
    pthread_mutex_lock(&g_proxy_lock);
    for (size_t i = 0; i < g_proxy_count; ++i) {
        Bo3SteamProxy *proxy = g_proxies[i];
        if (proxy->owner == owner && (!pipe || proxy->pipe == pipe))
            __atomic_store_n(&proxy->native_obj, NULL, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&g_proxy_lock);
}

typedef struct SteamGuestPipe {
    struct SteamGuestPipe *next;
    int32_t pipe;
    unsigned in_flight;
    bool closing;
} SteamGuestPipe;
static SteamGuestPipe *g_guest_pipes; // protected by g_steam_callback_lock

typedef struct SteamPipeLease {
    int owner;
    SteamGuestPipe *guest_pipe;
    struct SteamPipeLease *prev_guest;
} SteamPipeLease;
static _Thread_local SteamPipeLease *g_guest_pipe_leases;

static void steam_detach_responses(int owner, int32_t pipe);

static void steam_release_lease(SteamPipeLease *lease) {
    if (lease->guest_pipe) {
        pthread_mutex_lock(&g_steam_callback_lock);
        g_guest_pipe_leases = lease->prev_guest;
        if (!--lease->guest_pipe->in_flight && lease->guest_pipe->closing)
            pthread_cond_broadcast(&g_steam_callback_idle);
        pthread_mutex_unlock(&g_steam_callback_lock);
    }
    if (lease->owner >= 0) steam_unpin_pipe(lease->owner);
}

#define STEAM_LEASE(name) SteamPipeLease name __attribute__((cleanup(steam_release_lease))) = { .owner = -1 }

static int steam_acquire_lease(SteamPipeLease *lease, int owner) {
    pthread_mutex_lock(&g_steam_callback_lock);
    int ok = steam_pin_pipe(owner);
    if (ok) lease->owner = owner;
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ok;
}

static SteamGuestPipe *steam_find_guest_pipe(int32_t pipe) {
    for (SteamGuestPipe *p = g_guest_pipes; p; p = p->next)
        if (p->pipe == pipe) return p;
    return NULL;
}

// Resolve and pin the handle under the same lock used to begin teardown.
static int steam_acquire_interface_lease(SteamPipeLease *lease, int32_t pipe) {
    if (!pipe) return 0;
    pthread_mutex_lock(&g_steam_callback_lock);
    int owner = -1;
    SteamGuestPipe *guest_pipe = NULL;
    if (pipe == steam_gs_pipe()) owner = STEAM_PUMP_GS;
    else if (steam_online()) {
        if (pipe == steam_client_pipe()) owner = STEAM_PUMP_CLIENT;
        else if ((guest_pipe = steam_find_guest_pipe(pipe)) && !guest_pipe->closing)
            owner = STEAM_PUMP_CLIENT;
    }
    if (owner >= 0 && steam_pin_pipe(owner)) {
        lease->owner = owner;
        if (guest_pipe) {
            ++guest_pipe->in_flight;
            lease->guest_pipe = guest_pipe;
            lease->prev_guest = g_guest_pipe_leases;
            g_guest_pipe_leases = lease;
        }
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    return lease->owner >= 0;
}

static void *steam_proxy_acquire(uint64_t rdi, SteamPipeLease *lease) {
    const Bo3SteamProxy *proxy = (const Bo3SteamProxy *)(uintptr_t)rdi;
    if (!proxy) return NULL;
    if (proxy == &g_client_facade)
        return steam_online() && steam_acquire_lease(lease, STEAM_PUMP_CLIENT) ? g_native_client : NULL;
    if (!steam_acquire_interface_lease(lease, proxy->pipe) || lease->owner != proxy->owner) return NULL;
    return __atomic_load_n(&proxy->native_obj, __ATOMIC_ACQUIRE);
}

static uint8_t g_steam_trace_seen[STEAM_KIND_COUNT][STEAM_PROXY_SLOTS];
static void steam_trace_slot(uint64_t rdi, unsigned slot) {
    if (!steam_trace() || !rdi || slot >= STEAM_PROXY_SLOTS) return;
    int kind = ((const Bo3SteamProxy *)(uintptr_t)rdi)->kind;
    if (kind < 0 || kind >= STEAM_KIND_COUNT) return;
    if (!__atomic_exchange_n(&g_steam_trace_seen[kind][slot], 1, __ATOMIC_RELAXED))
        STEAM_LOG("trace: first call %s slot %u", k_steam_kinds[kind].name, slot);
}

// x86-64 SysV and AAPCS64 allocate integer and floating point arguments
// independently. The two guest stack words become x6/x7 on AAPCS64. Methods
// passing further arguments or returning a scalar float use typed overrides.
typedef struct SteamR2 { uint64_t x0, x1; } SteamR2;
typedef SteamR2 (*SteamGenericFn)(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
                                  uint64_t, uint64_t, double, double, double, double);
enum { FWD_RET_BOOL = 1u << 0, FWD_RET_U8 = 1u << 1 };
// Integer arguments after self: 1..5 are in guest registers, 6..7 on the guest stack.
#define FWD_ARG_BOOL(n) (1u << (1 + (n)))
#define FWD_ARG_U16(n)  (1u << (8 + (n)))
typedef struct SteamSlotABI {
    uint16_t flags;
    uint8_t stack_args;
} SteamSlotABI;
static SteamSlotABI g_slot_abi[STEAM_KIND_COUNT][STEAM_PROXY_SLOTS];

static GuestRet steam_forward(GuestContext *ctx, uint64_t rsp, uint64_t rdi,
                              uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5,
                              GuestXmm f0, GuestXmm f1, GuestXmm f2, GuestXmm f3, unsigned slot) {
    STEAM_LEASE(lease);
    void *self = steam_proxy_acquire(rdi, &lease);
    if (!self) return ret_u64(0);
    steam_trace_slot(rdi, slot);
    int kind = ((const Bo3SteamProxy *)(uintptr_t)rdi)->kind;
    SteamSlotABI abi = g_slot_abi[kind][slot];
    uint64_t a[8] = { 0, a1, a2, a3, a4, a5, 0, 0 };
    for (unsigned n = 0; n < abi.stack_args; ++n)
        a[6 + n] = shim_stack_u64(rsp, n);
    for (unsigned n = 1; n <= 7; ++n) {
        if (abi.flags & FWD_ARG_BOOL(n)) a[n] = (a[n] & 0xffu) != 0;
        if (abi.flags & FWD_ARG_U16(n)) a[n] = (uint16_t)a[n];
    }
    const SteamScope scope = steam_scope_enter(ctx, rsp);
    SteamR2 r = STEAM_VFN(self, slot, SteamGenericFn)(self, a[1], a[2], a[3], a[4], a[5], a[6], a[7],
        steam_xmm_f64(f0), steam_xmm_f64(f1), steam_xmm_f64(f2), steam_xmm_f64(f3));
    steam_scope_leave(scope);
    if (abi.flags & FWD_RET_BOOL) return ret_u64(r.x0 & 1);
    if (abi.flags & FWD_RET_U8) return ret_u64(r.x0 & 0xff);
    return ret_pair(r.x0, r.x1);
}

#define STEAM_X10(M, t) M(t##0) M(t##1) M(t##2) M(t##3) M(t##4) M(t##5) M(t##6) M(t##7) M(t##8) M(t##9)
#define STEAM_X80(M) M(0) M(1) M(2) M(3) M(4) M(5) M(6) M(7) M(8) M(9) \
    STEAM_X10(M, 1) STEAM_X10(M, 2) STEAM_X10(M, 3) STEAM_X10(M, 4) \
    STEAM_X10(M, 5) STEAM_X10(M, 6) STEAM_X10(M, 7)

#define STEAM_FWD_SLOT(N) \
    static GuestRet steam_fwd_##N(SHIM_PARAMS) { \
        SHIM_UNUSED_ALL(); \
        return steam_forward(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9, xmm0, xmm1, xmm2, xmm3, N); \
    }
STEAM_X80(STEAM_FWD_SLOT)

#define STEAM_FWD_PTR(N) steam_fwd_##N,
static const GuestFn k_steam_fwd[STEAM_PROXY_SLOTS] = { STEAM_X80(STEAM_FWD_PTR) };

// Typed overrides open with the native interface, its pipe pin and the guest scope.
#define STEAM_SELF(slot) \
    SHIM_UNUSED_ALL(); \
    STEAM_LEASE(lease); \
    void *self = steam_proxy_acquire(rdi, &lease); \
    if (!self) return ret_u64(0); \
    steam_trace_slot(rdi, (slot)); \
    const SteamScope scope = steam_scope_enter(ctx, rsp)

#define GB(x) (((x) & 0xffu) != 0)

// Guest-supplied function pointers are guest VAs; never hand them to native code.
static GuestRet steam_ignore_guest_fnptr(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return ret_u64(0);
}

// ---- ISteamClient017 ----
static void steam_track_guest_pipe(SteamGuestPipe *entry, int32_t pipe) {
    pthread_mutex_lock(&g_steam_callback_lock);
    if (pipe && pipe != steam_client_pipe() && pipe != steam_gs_pipe() && !steam_find_guest_pipe(pipe)) {
        *entry = (SteamGuestPipe){ .next = g_guest_pipes, .pipe = pipe };
        g_guest_pipes = entry;
        entry = NULL;
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    free(entry);
}

static SteamGuestPipe *steam_begin_guest_pipe_release(int32_t pipe) {
    for (SteamPipeLease *lease = g_guest_pipe_leases; lease; lease = lease->prev_guest)
        if (lease->guest_pipe->pipe == pipe) return NULL;

    pthread_mutex_lock(&g_steam_callback_lock);
    SteamGuestPipe *entry = steam_find_guest_pipe(pipe);
    if (!entry || entry->closing ||
        (entry->in_flight && g_steam_dispatch_active && pthread_equal(g_steam_dispatch_thread, pthread_self()))) {
        pthread_mutex_unlock(&g_steam_callback_lock);
        return NULL;
    }
    entry->closing = true;
    while (entry->in_flight) pthread_cond_wait(&g_steam_callback_idle, &g_steam_callback_lock);
    pthread_mutex_unlock(&g_steam_callback_lock);
    return entry;
}

static void steam_end_guest_pipe_release(SteamGuestPipe *entry, bool released) {
    if (released) {
        steam_detach_responses(STEAM_PUMP_CLIENT, entry->pipe);
        steam_invalidate_proxies(STEAM_PUMP_CLIENT, entry->pipe);
    }
    pthread_mutex_lock(&g_steam_callback_lock);
    if (released) {
        SteamGuestPipe **link = &g_guest_pipes;
        while (*link != entry) link = &(*link)->next;
        *link = entry->next;
        free(entry);
    } else {
        entry->closing = false;
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
}

#define STEAM_CLIENT_SELF(slot, fallback) \
    SHIM_UNUSED_ALL(); \
    STEAM_LEASE(lease); \
    void *self = steam_online() ? steam_proxy_acquire(rdi, &lease) : NULL; \
    if (!self) return (fallback); \
    steam_trace_slot(rdi, (slot)); \
    const SteamScope scope = steam_scope_enter(ctx, rsp)

static GuestRet steam_client_create_pipe(SHIM_PARAMS) {
    STEAM_CLIENT_SELF(0, ret_u64(1));
    SteamGuestPipe *entry = malloc(sizeof(*entry));
    if (!entry) { steam_scope_leave(scope); return ret_u64(0); }
    pthread_mutex_lock(&g_native_lock);
    int32_t r = STEAM_VFN(self, 0, int32_t (*)(void *))(self);
    steam_track_guest_pipe(entry, r);
    pthread_mutex_unlock(&g_native_lock);
    steam_scope_leave(scope);
    return ret_u64((uint32_t)r);
}
static GuestRet steam_client_release_pipe(SHIM_PARAMS) {
    STEAM_CLIENT_SELF(1, ret_u64(1));
    SteamGuestPipe *entry = steam_begin_guest_pipe_release((int32_t)rsi);
    if (!entry) { steam_scope_leave(scope); return ret_u64(0); }
    pthread_mutex_lock(&g_native_lock);
    bool r = STEAM_VFN(self, 1, bool (*)(void *, int32_t))(self, entry->pipe) & 1;
    steam_end_guest_pipe_release(entry, r);
    pthread_mutex_unlock(&g_native_lock);
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}
static GuestRet steam_client_connect_global(SHIM_PARAMS) {
    STEAM_CLIENT_SELF(2, ret_u64(1));
    STEAM_LEASE(target);
    int32_t r = steam_acquire_interface_lease(&target, (int32_t)rsi)
        ? STEAM_VFN(self, 2, int32_t (*)(void *, int32_t))(self, (int32_t)rsi) : 0;
    steam_scope_leave(scope);
    return ret_u64((uint32_t)r);
}
static GuestRet steam_client_create_local(SHIM_PARAMS) {
    STEAM_CLIENT_SELF(3, steam_mock_create_local(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9,
                                               xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7));
    int32_t *pipe = (int32_t *)(uintptr_t)rsi;
    if (!pipe) { steam_scope_leave(scope); return ret_u64(0); }
    SteamGuestPipe *entry = malloc(sizeof(*entry));
    if (!entry) { steam_scope_leave(scope); return ret_u64(0); }
    int32_t local_pipe = 0;
    pthread_mutex_lock(&g_native_lock);
    int32_t r = STEAM_VFN(self, 3, int32_t (*)(void *, int32_t *, int32_t))(
        self, &local_pipe, (int32_t)rdx);
    steam_track_guest_pipe(entry, local_pipe);
    pthread_mutex_unlock(&g_native_lock);
    *pipe = local_pipe;
    steam_scope_leave(scope);
    return ret_u64((uint32_t)r);
}
static GuestRet steam_client_release_user(SHIM_PARAMS) {
    STEAM_CLIENT_SELF(4, ret_void());
    int32_t pipe = (int32_t)rsi;
    int32_t user = (int32_t)rdx;
    // The API shutdown paths release the bridge's own user/pipe pairs.
    if ((pipe != steam_client_pipe() || user != __atomic_load_n(&g_client_user, __ATOMIC_ACQUIRE)) &&
        (pipe != steam_gs_pipe() || user != __atomic_load_n(&g_gs_user, __ATOMIC_ACQUIRE))) {
        STEAM_LEASE(target);
        if (steam_acquire_interface_lease(&target, pipe))
            STEAM_VFN(self, 4, void (*)(void *, int32_t, int32_t))(self, pipe, user);
    }
    steam_scope_leave(scope);
    return ret_void();
}
static GuestRet steam_client_set_ip_binding(SHIM_PARAMS) {
    STEAM_CLIENT_SELF(7, ret_void());
    STEAM_VFN(self, 7, void (*)(void *, uint32_t, uint16_t))(self, (uint32_t)rsi, (uint16_t)rdx);
    steam_scope_leave(scope);
    return ret_void();
}
static GuestRet steam_client_run_frame(SHIM_PARAMS) {
    STEAM_CLIENT_SELF(19, ret_void());
    STEAM_VFN(self, 19, void (*)(void *))(self);
    steam_scope_leave(scope);
    return ret_void();
}
static GuestRet steam_client_ipc_count(SHIM_PARAMS) {
    STEAM_CLIENT_SELF(20, ret_u64(0));
    uint32_t r = STEAM_VFN(self, 20, uint32_t (*)(void *))(self);
    steam_scope_leave(scope);
    return ret_u64(r);
}
static GuestRet steam_client_shutdown_if_closed(SHIM_PARAMS) {
    STEAM_CLIENT_SELF(22, ret_u64(0));
    bool r = STEAM_VFN(self, 22, bool (*)(void *))(self);
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}

// GetISteamXxx: a native pipe gets the native interface, anything else (offline fallback, the
// mock game server pipe) the offline mock for that version.
static GuestRet steam_client_iface_common(GuestContext *ctx, uint64_t rsp, uint64_t rdi, unsigned slot,
                                          int32_t user, int32_t pipe, uint64_t ver_va, int has_user) {
    char buf[STEAM_VERSION_CAP];
    const char *ver = steam_read_version(ver_va, buf);
    STEAM_LEASE(lease);
    if (!steam_online() || !steam_acquire_interface_lease(&lease, pipe)) {
        bo3_init_steam_mocks();
        return ret_ptr(steam_iface_for_version(ver));
    }
    void *self = g_native_client;
    if (!self || !ver) return ret_u64(0);
    steam_trace_slot(rdi, slot);
    const SteamScope scope = steam_scope_enter(ctx, rsp);
    void *native = has_user
        ? STEAM_VFN(self, slot, void *(*)(void *, int32_t, int32_t, const char *))(self, user, pipe, ver)
        : STEAM_VFN(self, slot, void *(*)(void *, int32_t, const char *))(self, pipe, ver);
    steam_scope_leave(scope);
    if (!native) {
        STEAM_LOG("ISteamClient017 slot %u (%s, pipe %d) -> NULL", slot, ver, pipe);
        return ret_u64(0);
    }
    return ret_ptr(steam_wrap(native, steam_kind_for_version(ver), lease.owner, pipe));
}

#define STEAM_CLIENT_IFACE(N) \
    static GuestRet steam_client_iface_##N(SHIM_PARAMS) { \
        SHIM_UNUSED_ALL(); \
        return steam_client_iface_common(ctx, rsp, rdi, N, (int32_t)rsi, (int32_t)rdx, rcx, 1); \
    }
STEAM_CLIENT_IFACE(5)  STEAM_CLIENT_IFACE(6)  STEAM_CLIENT_IFACE(8)  STEAM_CLIENT_IFACE(10)
STEAM_CLIENT_IFACE(11) STEAM_CLIENT_IFACE(12) STEAM_CLIENT_IFACE(13) STEAM_CLIENT_IFACE(14)
STEAM_CLIENT_IFACE(15) STEAM_CLIENT_IFACE(16) STEAM_CLIENT_IFACE(17) STEAM_CLIENT_IFACE(18)
STEAM_CLIENT_IFACE(23) STEAM_CLIENT_IFACE(24) STEAM_CLIENT_IFACE(25) STEAM_CLIENT_IFACE(26)
STEAM_CLIENT_IFACE(27) STEAM_CLIENT_IFACE(28) STEAM_CLIENT_IFACE(29) STEAM_CLIENT_IFACE(30)
STEAM_CLIENT_IFACE(34) STEAM_CLIENT_IFACE(35)

// GetISteamUtils(HSteamPipe, const char *)
static GuestRet steam_client_iface_9(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return steam_client_iface_common(ctx, rsp, rdi, 9, 0, (int32_t)rsi, rdx, 0);
}

// ---- ISteamUser019 ----
// int InitiateGameConnection(void *pAuthBlob, int cbMaxAuthBlob, CSteamID steamIDGameServer,
//                            uint32 unIPServer, uint16 usPortServer, bool bSecure)
static GuestRet steam_user_initiate_connection(SHIM_PARAMS) {
    STEAM_SELF(3);
    int32_t r = STEAM_VFN(self, 3, int32_t (*)(void *, void *, int32_t, uint64_t, uint32_t, uint16_t, bool))(
        self, (void *)(uintptr_t)rsi, (int32_t)rdx, rcx, (uint32_t)r8, (uint16_t)r9, GB(shim_stack_u64(rsp, 0)));
    steam_scope_leave(scope);
    return ret_u64((uint32_t)r);
}
// EVoiceResult GetVoice(bool bWantCompressed, void *pDestBuffer, uint32 cbDestBufferSize,
//   uint32 *nBytesWritten, bool bWantUncompressed, void *pUncompressedDestBuffer,
//   uint32 cbUncompressedDestBufferSize, uint32 *nUncompressBytesWritten, uint32 nSampleRate)
static GuestRet steam_user_get_voice(SHIM_PARAMS) {
    STEAM_SELF(10);
    int32_t r = STEAM_VFN(self, 10, int32_t (*)(void *, bool, void *, uint32_t, uint32_t *, bool, void *, uint32_t,
                                                 uint32_t *, uint32_t))(
        self, GB(rsi), (void *)(uintptr_t)rdx, (uint32_t)rcx, (uint32_t *)(uintptr_t)r8, GB(r9),
        (void *)(uintptr_t)shim_stack_u64(rsp, 0), (uint32_t)shim_stack_u64(rsp, 1),
        (uint32_t *)(uintptr_t)shim_stack_u64(rsp, 2), (uint32_t)shim_stack_u64(rsp, 3));
    steam_scope_leave(scope);
    return ret_u64((uint32_t)r);
}
// EVoiceResult DecompressVoice(const void *pCompressed, uint32 cbCompressed, void *pDestBuffer,
//   uint32 cbDestBufferSize, uint32 *nBytesWritten, uint32 nDesiredSampleRate)
static GuestRet steam_user_decompress_voice(SHIM_PARAMS) {
    STEAM_SELF(11);
    int32_t r = STEAM_VFN(self, 11, int32_t (*)(void *, const void *, uint32_t, void *, uint32_t, uint32_t *,
                                                 uint32_t))(
        self, (const void *)(uintptr_t)rsi, (uint32_t)rdx, (void *)(uintptr_t)rcx, (uint32_t)r8,
        (uint32_t *)(uintptr_t)r9, (uint32_t)shim_stack_u64(rsp, 0));
    steam_scope_leave(scope);
    return ret_u64((uint32_t)r);
}
// HAuthTicket GetAuthSessionTicket(void *pTicket, int cbMaxTicket, uint32 *pcbTicket)
static GuestRet steam_user_get_auth_ticket_native(SHIM_PARAMS) {
    STEAM_SELF(13);
    uint32_t r = STEAM_VFN(self, 13, uint32_t (*)(void *, void *, int32_t, uint32_t *))(
        self, (void *)(uintptr_t)rsi, (int32_t)rdx, (uint32_t *)(uintptr_t)rcx);
    steam_scope_leave(scope);
    if (steam_trace()) STEAM_LOG("ISteamUser::GetAuthSessionTicket -> handle %u, %u bytes", r,
                                 rcx ? *(const uint32_t *)(uintptr_t)rcx : 0);
    return ret_u64(r);
}
// EBeginAuthSessionResult BeginAuthSession(const void *pAuthTicket, int cbAuthTicket, CSteamID steamID)
static GuestRet steam_user_begin_auth(SHIM_PARAMS) {
    STEAM_SELF(14);
    int32_t r = STEAM_VFN(self, 14, int32_t (*)(void *, const void *, int32_t, uint64_t))(
        self, (const void *)(uintptr_t)rsi, (int32_t)rdx, rcx);
    steam_scope_leave(scope);
    return ret_u64((uint32_t)r);
}
// void EndAuthSession(CSteamID steamID)
static GuestRet steam_user_end_auth(SHIM_PARAMS) {
    STEAM_SELF(15);
    STEAM_VFN(self, 15, void (*)(void *, uint64_t))(self, rsi);
    steam_scope_leave(scope);
    return ret_void();
}
// void CancelAuthTicket(HAuthTicket hAuthTicket)
static GuestRet steam_user_cancel_auth_native(SHIM_PARAMS) {
    STEAM_SELF(16);
    STEAM_VFN(self, 16, void (*)(void *, uint32_t))(self, (uint32_t)rsi);
    steam_scope_leave(scope);
    return ret_void();
}
// SteamAPICall_t RequestEncryptedAppTicket(void *pDataToInclude, int cbDataToInclude)
static GuestRet steam_user_request_app_ticket(SHIM_PARAMS) {
    STEAM_SELF(20);
    uint64_t r = STEAM_VFN(self, 20, uint64_t (*)(void *, void *, int32_t))(
        self, (void *)(uintptr_t)rsi, (int32_t)rdx);
    steam_scope_leave(scope);
    STEAM_LOG("ISteamUser::RequestEncryptedAppTicket(%d bytes) -> SteamAPICall_t 0x%llx",
              (int32_t)rdx, (unsigned long long)r);
    return ret_u64(r);
}
// bool GetEncryptedAppTicket(void *pTicket, int cbMaxTicket, uint32 *pcbTicket)
static GuestRet steam_user_get_app_ticket(SHIM_PARAMS) {
    STEAM_SELF(21);
    bool r = STEAM_VFN(self, 21, bool (*)(void *, void *, int32_t, uint32_t *))(
        self, (void *)(uintptr_t)rsi, (int32_t)rdx, (uint32_t *)(uintptr_t)rcx);
    steam_scope_leave(scope);
    STEAM_LOG("ISteamUser::GetEncryptedAppTicket -> %s, %u bytes", (r & 1) ? "true" : "false",
              ((r & 1) && rcx) ? *(const uint32_t *)(uintptr_t)rcx : 0);
    return ret_u64(r & 1);
}

// ---- ISteamFriends015 ----
// int GetClanChatMessage(CSteamID steamIDClanChat, int iMessage, void *prgchText, int cchTextMax,
//                        EChatEntryType *peChatEntryType, CSteamID *psteamidChatter)
static GuestRet steam_friends_clan_chat_message(SHIM_PARAMS) {
    STEAM_SELF(59);
    int32_t r = STEAM_VFN(self, 59, int32_t (*)(void *, uint64_t, int32_t, void *, int32_t, int32_t *, uint64_t *))(
        self, rsi, (int32_t)rdx, (void *)(uintptr_t)rcx, (int32_t)r8, (int32_t *)(uintptr_t)r9,
        (uint64_t *)(uintptr_t)shim_stack_u64(rsp, 0));
    steam_scope_leave(scope);
    return ret_u64((uint32_t)r);
}

static int steam_native_has_friend(uint64_t steam_id) {
    STEAM_LEASE(lease);
    if (steam_id && steam_id == __atomic_load_n(&g_steam_online_id, __ATOMIC_ACQUIRE)) return 1;
    if (!steam_acquire_lease(&lease, STEAM_PUMP_CLIENT)) return 0;
    void *friends = __atomic_load_n(&g_native_friends, __ATOMIC_ACQUIRE);
    if (!friends) return 0;
    // bool HasFriend(CSteamID steamIDFriend, int iFriendFlags): slot 17
    return STEAM_VFN(friends, 17, bool (*)(void *, uint64_t, int32_t))(friends, steam_id,
                                                                      STEAM_FRIEND_FLAG_IMMEDIATE) & 1;
}

// ---- ISteamNetworking005 (client and game server) ----
// bool SendP2PPacket(CSteamID steamIDRemote, const void *pubData, uint32 cubData, EP2PSend eP2PSendType, int nChannel)
static GuestRet steam_net_send_p2p(SHIM_PARAMS) {
    STEAM_SELF(0);
    bool r = STEAM_VFN(self, 0, bool (*)(void *, uint64_t, const void *, uint32_t, int32_t, int32_t))(
        self, rsi, (const void *)(uintptr_t)rdx, (uint32_t)rcx, (int32_t)r8, (int32_t)r9);
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}
// bool IsP2PPacketAvailable(uint32 *pcubMsgSize, int nChannel)
static GuestRet steam_net_p2p_available(SHIM_PARAMS) {
    STEAM_SELF(1);
    bool r = STEAM_VFN(self, 1, bool (*)(void *, uint32_t *, int32_t))(self, (uint32_t *)(uintptr_t)rsi, (int32_t)rdx);
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}

static unsigned g_p2p_drop_logs;
static void steam_p2p_drop(const char *why, uint64_t remote, uint8_t type) {
    if (__atomic_fetch_add(&g_p2p_drop_logs, 1, __ATOMIC_RELAXED) < 32)
        STEAM_LOG("dropped P2P packet from %016llx (type '%c'): %s", (unsigned long long)remote,
                  (type >= 32 && type < 127) ? type : '?', why);
}

// BO3's channel-0 reader (0x101054d1b) dispatches on the first LE32. The
// instant-message handler (0x101435f72) consumes a fixed-size envelope:
// LE32 selector, 1024 bytes of message storage, then the LE32 message length.
enum {
    BO3_P2P_IM = 0x28,
    BO3_P2P_IM_HEADER = 4,
    BO3_P2P_IM_CAP = 1024,
    BO3_P2P_IM_LENGTH_OFFSET = BO3_P2P_IM_HEADER + BO3_P2P_IM_CAP,
    BO3_P2P_IM_FRAME = BO3_P2P_IM_LENGTH_OFFSET + 4,
    BO3_P2P_AUTH_TICKET = 0x15,
    BO3_P2P_AUTH_REQUEST = 0x16,
    BO3_P2P_AUTH_TICKET_CAP = 1024,
    BO3_P2P_AUTH_TICKET_FRAME = 8 + BO3_P2P_AUTH_TICKET_CAP + 8,
    BO3_P2P_AUTH_REQUEST_FRAME = 16,
    STEAM_P2P_READ_CAP = 64,
};

static int steam_p2p_channel_zero_ok(const uint8_t *packet, uint32_t size, uint64_t sender) {
    uint32_t selector;
    if (size < sizeof(selector)) return 0;
    memcpy(&selector, packet, sizeof(selector));
    // The auth receiver (0x100f32bf6) also reads fixed-size envelopes.
    if (selector == BO3_P2P_AUTH_REQUEST) return size == BO3_P2P_AUTH_REQUEST_FRAME;
    if (selector == BO3_P2P_AUTH_TICKET) {
        uint32_t length;
        if (size != BO3_P2P_AUTH_TICKET_FRAME) return 0;
        memcpy(&length, packet + sizeof(selector), sizeof(length));
        return length <= BO3_P2P_AUTH_TICKET_CAP;
    }
    if (selector != BO3_P2P_IM) return 1;

    uint32_t length;
    if (size != BO3_P2P_IM_FRAME) {
        steam_p2p_drop("invalid instant-message envelope size", sender, 0);
        return 0;
    }
    memcpy(&length, packet + BO3_P2P_IM_LENGTH_OFFSET, sizeof(length));
    if (length < 2 || length > BO3_P2P_IM_CAP || packet[BO3_P2P_IM_HEADER] != '1') {
        steam_p2p_drop("invalid instant-message header or length", sender, 0);
        return 0;
    }
    uint8_t type = packet[BO3_P2P_IM_HEADER + 1];
    if (type == 'e' || type == 'm' || type == 'f') {
        steam_p2p_drop("blocked message type", sender, type);
        return 0;
    }
    if (type == 'h' && steam_friends_only() && !steam_native_has_friend(sender)) {
        steam_p2p_drop("BO3ARM_FRIENDS_ONLY: sender is not a friend", sender, type);
        return 0;
    }
    return 1;
}

static GuestRet steam_net_read_p2p(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    uint8_t *dest = (uint8_t *)(uintptr_t)rsi;
    uint32_t cap = (uint32_t)rdx;
    uint32_t *size = (uint32_t *)(uintptr_t)rcx;
    uint64_t *remote = (uint64_t *)(uintptr_t)r8;
    int32_t channel = (int32_t)r9;
    if (size) *size = 0;
    if (!dest || !cap || !size || !remote) return ret_u64(0);
    STEAM_LEASE(lease);
    void *self = steam_proxy_acquire(rdi, &lease);
    if (!self) return ret_u64(0);
    steam_trace_slot(rdi, 2);
    typedef bool (*ReadPacket)(void *, void *, uint32_t, uint32_t *, uint64_t *, int32_t);
    ReadPacket read_packet = STEAM_VFN(self, 2, ReadPacket);
    const SteamScope scope = steam_scope_enter(ctx, rsp);
    for (unsigned n = 0; n < STEAM_P2P_READ_CAP; ++n) {
        uint32_t received = 0;
        uint64_t sender = 0;
        if (!(read_packet(self, dest, cap, &received, &sender, channel) & 1)) break;
        if (received > cap || (!channel && !steam_p2p_channel_zero_ok(dest, received, sender))) continue;
        if (!channel) memset(dest + received, 0, cap - received);
        *size = received;
        *remote = sender;
        steam_scope_leave(scope);
        return ret_u64(1);
    }
    steam_scope_leave(scope);
    return ret_u64(0);
}
// bool AcceptP2PSessionWithUser(CSteamID) / bool CloseP2PSessionWithUser(CSteamID)
static GuestRet steam_net_accept_session(SHIM_PARAMS) {
    STEAM_SELF(3);
    if (steam_friends_only() && !steam_native_has_friend(rsi)) {
        steam_scope_leave(scope);
        return ret_u64(0);
    }
    bool r = STEAM_VFN(self, 3, bool (*)(void *, uint64_t))(self, rsi);
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}
static GuestRet steam_net_close_session(SHIM_PARAMS) {
    STEAM_SELF(4);
    bool r = STEAM_VFN(self, 4, bool (*)(void *, uint64_t))(self, rsi);
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}
// bool CloseP2PChannelWithUser(CSteamID, int nChannel)
static GuestRet steam_net_close_channel(SHIM_PARAMS) {
    STEAM_SELF(5);
    bool r = STEAM_VFN(self, 5, bool (*)(void *, uint64_t, int32_t))(self, rsi, (int32_t)rdx);
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}
// bool GetP2PSessionState(CSteamID, P2PSessionState_t *)
static GuestRet steam_net_session_state(SHIM_PARAMS) {
    STEAM_SELF(6);
    bool r = STEAM_VFN(self, 6, bool (*)(void *, uint64_t, void *))(self, rsi, (void *)(uintptr_t)rdx);
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}
// bool AllowP2PPacketRelay(bool bAllow)
static GuestRet steam_net_allow_relay(SHIM_PARAMS) {
    STEAM_SELF(7);
    bool r = STEAM_VFN(self, 7, bool (*)(void *, bool))(self, GB(rsi));
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}

// ---- ISteamMatchmaking009 ----
// bool GetFavoriteGame(int iGame, AppId_t *pnAppID, uint32 *pnIP, uint16 *pnConnPort,
//                      uint16 *pnQueryPort, uint32 *punFlags, uint32 *pRTime32LastPlayedOnServer)
static GuestRet steam_mm_get_favorite(SHIM_PARAMS) {
    STEAM_SELF(1);
    bool r = STEAM_VFN(self, 1, bool (*)(void *, int32_t, uint32_t *, uint32_t *, uint16_t *, uint16_t *,
                                          uint32_t *, uint32_t *))(
        self, (int32_t)rsi, (uint32_t *)(uintptr_t)rdx, (uint32_t *)(uintptr_t)rcx, (uint16_t *)(uintptr_t)r8,
        (uint16_t *)(uintptr_t)r9, (uint32_t *)(uintptr_t)shim_stack_u64(rsp, 0),
        (uint32_t *)(uintptr_t)shim_stack_u64(rsp, 1));
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}
// int AddFavoriteGame(AppId_t nAppID, uint32 nIP, uint16 nConnPort, uint16 nQueryPort, uint32 unFlags,
//                     uint32 rTime32LastPlayedOnServer)
static GuestRet steam_mm_add_favorite(SHIM_PARAMS) {
    STEAM_SELF(2);
    int32_t r = STEAM_VFN(self, 2, int32_t (*)(void *, uint32_t, uint32_t, uint16_t, uint16_t, uint32_t, uint32_t))(
        self, (uint32_t)rsi, (uint32_t)rdx, (uint16_t)rcx, (uint16_t)r8, (uint32_t)r9,
        (uint32_t)shim_stack_u64(rsp, 0));
    steam_scope_leave(scope);
    return ret_u64((uint32_t)r);
}
// SteamAPICall_t CreateLobby(ELobbyType eLobbyType, int cMaxMembers)
static GuestRet steam_mm_create_lobby(SHIM_PARAMS) {
    STEAM_SELF(13);
    int32_t type = (int32_t)rsi;
    if (steam_friends_only()) type = STEAM_LOBBY_FRIENDS_ONLY;
    uint64_t r = STEAM_VFN(self, 13, uint64_t (*)(void *, int32_t, int32_t))(self, type, (int32_t)rdx);
    steam_scope_leave(scope);
    STEAM_LOG("ISteamMatchmaking::CreateLobby(type %d%s, max %d) -> SteamAPICall_t 0x%llx", type,
              type != (int32_t)rsi ? " forced by BO3ARM_FRIENDS_ONLY" : "", (int32_t)rdx, (unsigned long long)r);
    return ret_u64(r);
}
// bool GetLobbyDataByIndex(CSteamID, int iLobbyData, char *pchKey, int cchKeyBufferSize,
//                          char *pchValue, int cchValueBufferSize)
static GuestRet steam_mm_lobby_data_by_index(SHIM_PARAMS) {
    STEAM_SELF(22);
    bool r = STEAM_VFN(self, 22, bool (*)(void *, uint64_t, int32_t, char *, int32_t, char *, int32_t))(
        self, rsi, (int32_t)rdx, (char *)(uintptr_t)rcx, (int32_t)r8, (char *)(uintptr_t)r9,
        (int32_t)shim_stack_u64(rsp, 0));
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}

// Same filter as BO3MacFix: chat text is printed through the engine's console and UI
// formatters, which treat these characters and sequences as control codes.
static void steam_sanitize_chat(char *text, size_t len) {
    for (size_t i = 0; i + 1 < len; ++i) {
        if ((text[i] == '$' && text[i + 1] == '(') || (text[i] == '[' && text[i + 1] == '{'))
            text[i] = text[i + 1] = '.';
    }
    for (size_t i = 0; i < len; ++i) {
        uint8_t c = (uint8_t)text[i];
        if (c == '^' || c == '%' || c < 32 || c > 126) text[i] = '.';
    }
}

// int GetLobbyChatEntry(CSteamID steamIDLobby, int iChatID, CSteamID *pSteamIDUser, void *pvData,
//                       int cubData, EChatEntryType *peChatEntryType)
static GuestRet steam_mm_lobby_chat_entry(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    char *data = (char *)(uintptr_t)r8;
    int32_t cap = (int32_t)r9;
    if (!data || cap <= 0) return ret_u64(0);
    STEAM_LEASE(lease);
    void *self = steam_proxy_acquire(rdi, &lease);
    if (!self) { data[0] = '\0'; return ret_u64(0); }
    steam_trace_slot(rdi, 27);
    const SteamScope scope = steam_scope_enter(ctx, rsp);
    uint64_t sender = 0;
    int32_t local_type = 0;
    int32_t n = STEAM_VFN(self, 27, int32_t (*)(void *, uint64_t, int32_t, uint64_t *, void *, int32_t, int32_t *))(
        self, rsi, (int32_t)rdx, &sender, data, cap, &local_type);
    steam_scope_leave(scope);
    if (n <= 0 || n > cap || (steam_friends_only() && !steam_native_has_friend(sender))) {
        data[0] = '\0';
        return ret_u64(0);
    }
    if (local_type == STEAM_CHAT_ENTRY_CHAT_MSG) {
        const char *nul = memchr(data, '\0', (size_t)n);
        if (!nul) { data[0] = '\0'; return ret_u64(0); }
        steam_sanitize_chat(data, (size_t)(nul - data));
    }
    if (rcx) *(uint64_t *)(uintptr_t)rcx = sender;
    int32_t *type = (int32_t *)(uintptr_t)shim_stack_u64(rsp, 0);
    if (type) *type = local_type;
    return ret_u64((uint32_t)n);
}
// bool SetLobbyType(CSteamID steamIDLobby, ELobbyType eLobbyType)
static GuestRet steam_mm_set_lobby_type(SHIM_PARAMS) {
    STEAM_SELF(33);
    int32_t type = steam_friends_only() ? STEAM_LOBBY_FRIENDS_ONLY : (int32_t)rdx;
    bool r = STEAM_VFN(self, 33, bool (*)(void *, uint64_t, int32_t))(self, rsi, type);
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}

// ---- ISteamUGC008 ----
// UGCQueryHandle_t CreateQueryUserUGCRequest(AccountID_t, EUserUGCList, EUGCMatchingUGCType,
//   EUserUGCListSortOrder, AppId_t nCreatorAppID, AppId_t nConsumerAppID, uint32 unPage)
static GuestRet steam_ugc_query_user(SHIM_PARAMS) {
    STEAM_SELF(0);
    uint64_t r = STEAM_VFN(self, 0, uint64_t (*)(void *, uint32_t, int32_t, int32_t, int32_t, uint32_t, uint32_t,
                                                  uint32_t))(
        self, (uint32_t)rsi, (int32_t)rdx, (int32_t)rcx, (int32_t)r8, (uint32_t)r9,
        (uint32_t)shim_stack_u64(rsp, 0), (uint32_t)shim_stack_u64(rsp, 1));
    steam_scope_leave(scope);
    return ret_u64(r);
}
// bool GetQueryUGCAdditionalPreview(UGCQueryHandle_t, uint32 index, uint32 previewIndex,
//   char *pchURLOrVideoID, uint32 cchURLSize, char *pchOriginalFileName, uint32 cchOriginalFileNameSize,
//   EItemPreviewType *pPreviewType)
static GuestRet steam_ugc_additional_preview(SHIM_PARAMS) {
    STEAM_SELF(10);
    bool r = STEAM_VFN(self, 10, bool (*)(void *, uint64_t, uint32_t, uint32_t, char *, uint32_t, char *, uint32_t,
                                           int32_t *))(
        self, rsi, (uint32_t)rdx, (uint32_t)rcx, (char *)(uintptr_t)r8, (uint32_t)r9,
        (char *)(uintptr_t)shim_stack_u64(rsp, 0), (uint32_t)shim_stack_u64(rsp, 1),
        (int32_t *)(uintptr_t)shim_stack_u64(rsp, 2));
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}
// bool GetQueryUGCKeyValueTag(UGCQueryHandle_t, uint32 index, uint32 keyValueTagIndex,
//   char *pchKey, uint32 cchKeySize, char *pchValue, uint32 cchValueSize)
static GuestRet steam_ugc_kv_tag(SHIM_PARAMS) {
    STEAM_SELF(12);
    bool r = STEAM_VFN(self, 12, bool (*)(void *, uint64_t, uint32_t, uint32_t, char *, uint32_t, char *, uint32_t))(
        self, rsi, (uint32_t)rdx, (uint32_t)rcx, (char *)(uintptr_t)r8, (uint32_t)r9,
        (char *)(uintptr_t)shim_stack_u64(rsp, 0), (uint32_t)shim_stack_u64(rsp, 1));
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}

// ---- ISteamGameServer012 ----
// bool InitGameServer(uint32 unIP, uint16 usGamePort, uint16 usQueryPort, uint32 unFlags,
//                     AppId_t nGameAppId, const char *pchVersionString)
static GuestRet steam_gs_init_game_server(SHIM_PARAMS) {
    STEAM_SELF(0);
    bool r = STEAM_VFN(self, 0, bool (*)(void *, uint32_t, uint16_t, uint16_t, uint32_t, uint32_t, const char *))(
        self, (uint32_t)rsi, (uint16_t)rdx, (uint16_t)rcx, (uint32_t)r8, (uint32_t)r9,
        (const char *)(uintptr_t)shim_stack_u64(rsp, 0));
    steam_scope_leave(scope);
    return ret_u64(r & 1);
}

struct SteamParamStringArray;

static GuestRet steam_rs_publish_workshop_file(SHIM_PARAMS) {
    STEAM_SELF(30);
    typedef uint64_t (*Publish)(void *, const char *, const char *, uint32_t,
                                const char *, const char *, int32_t, struct SteamParamStringArray *, int32_t);
    uint64_t call = STEAM_VFN(self, 30, Publish)(
        self, (const char *)(uintptr_t)rsi, (const char *)(uintptr_t)rdx, (uint32_t)rcx,
        (const char *)(uintptr_t)r8, (const char *)(uintptr_t)r9, (int32_t)shim_stack_u64(rsp, 0),
        (struct SteamParamStringArray *)(uintptr_t)shim_stack_u64(rsp, 1), (int32_t)shim_stack_u64(rsp, 2));
    steam_scope_leave(scope);
    return ret_u64(call);
}

static GuestRet steam_rs_publish_video(SHIM_PARAMS) {
    STEAM_SELF(50);
    typedef uint64_t (*Publish)(void *, int32_t, const char *, const char *, const char *, uint32_t,
                                const char *, const char *, int32_t, struct SteamParamStringArray *);
    uint64_t call = STEAM_VFN(self, 50, Publish)(
        self, (int32_t)rsi, (const char *)(uintptr_t)rdx, (const char *)(uintptr_t)rcx,
        (const char *)(uintptr_t)r8, (uint32_t)r9, (const char *)(uintptr_t)shim_stack_u64(rsp, 0),
        (const char *)(uintptr_t)shim_stack_u64(rsp, 1), (int32_t)shim_stack_u64(rsp, 2),
        (struct SteamParamStringArray *)(uintptr_t)shim_stack_u64(rsp, 3));
    steam_scope_leave(scope);
    return ret_u64(call);
}

static GuestRet steam_html_set_cookie(SHIM_PARAMS) {
    STEAM_SELF(31);
    typedef void (*SetCookie)(void *, const char *, const char *, const char *, const char *, uint32_t, bool, bool);
    STEAM_VFN(self, 31, SetCookie)(self, (const char *)(uintptr_t)rsi, (const char *)(uintptr_t)rdx,
                                  (const char *)(uintptr_t)rcx, (const char *)(uintptr_t)r8, (uint32_t)r9,
                                  GB(shim_stack_u64(rsp, 0)), GB(shim_stack_u64(rsp, 1)));
    steam_scope_leave(scope);
    return ret_void();
}

static GuestRet steam_inventory_trade_items(SHIM_PARAMS) {
    STEAM_SELF(18);
    typedef bool (*Trade)(void *, int32_t *, uint64_t, const uint64_t *, const uint32_t *, uint32_t,
                          const uint64_t *, const uint32_t *, uint32_t);
    bool traded = STEAM_VFN(self, 18, Trade)(
        self, (int32_t *)(uintptr_t)rsi, rdx, (const uint64_t *)(uintptr_t)rcx,
        (const uint32_t *)(uintptr_t)r8, (uint32_t)r9, (const uint64_t *)(uintptr_t)shim_stack_u64(rsp, 0),
        (const uint32_t *)(uintptr_t)shim_stack_u64(rsp, 1), (uint32_t)shim_stack_u64(rsp, 2));
    steam_scope_leave(scope);
    return ret_u64(traded & 1);
}

// ---- ISteamMusic001 ----
// float GetVolume(): the only float return in BO3's interface set.
static GuestRet steam_music_get_volume(SHIM_PARAMS) {
    STEAM_SELF(8);
    float r = STEAM_VFN(self, 8, float (*)(void *))(self);
    steam_scope_leave(scope);
    return ret_f32(r);
}

// ---- ISteamMatchmakingServers002: native proxies for guest response objects ----
enum { STEAM_RESP_SERVER_LIST = 0, STEAM_RESP_PING, STEAM_RESP_PLAYERS, STEAM_RESP_RULES, STEAM_RESP_KIND_COUNT };

typedef struct Bo3NativeResponse {
    void *const *vtable;   // native arm64 vtable (must stay first)
    const Bo3SteamProxy *interface;
    uint64_t guest_obj;
    uint64_t handle;
    int kind;
    bool bound;
    bool retire_when_idle;
    unsigned running;
    pthread_t thread;
    struct Bo3NativeResponse *next;
} Bo3NativeResponse;

// The callback lock also protects the response registry and each response's in-flight state.
static Bo3NativeResponse *g_responses;
static Bo3NativeResponse *g_retired_responses;
static unsigned g_resp_drop_logs;

static int steam_read_guest_u64(uint64_t address, uint64_t *value) {
    mach_vm_size_t copied = 0;
    return address >= 0x100000000ULL &&
        mach_vm_read_overwrite(mach_task_self(), address, sizeof(*value),
                               (mach_vm_address_t)(uintptr_t)value, &copied) == KERN_SUCCESS &&
        copied == sizeof(*value);
}

static int steam_response_target(uint64_t guest, unsigned slot, uint64_t *target) {
    uint64_t vtable;
    return steam_read_guest_u64(guest, &vtable) && vtable != BO3_STEAM_CALLBACK_BASE_VTABLE &&
        vtable >= 0x100000000ULL && vtable <= UINT64_MAX - sizeof(*target) * slot &&
        steam_read_guest_u64(vtable + sizeof(*target) * slot, target) && *target >= 0x100000000ULL;
}

// Keep retired native vptrs valid for responses already queued in Steam.
static void steam_retire_response(Bo3NativeResponse **link) {
    Bo3NativeResponse *resp = *link;
    resp->guest_obj = 0;
    *link = resp->next;
    resp->next = g_retired_responses;
    g_retired_responses = resp;
}

static void steam_retire_matching_response(Bo3NativeResponse *resp) {
    for (Bo3NativeResponse **link = &g_responses; *link; link = &(*link)->next) {
        if (*link == resp) { steam_retire_response(link); break; }
    }
}

static void steam_detach_responses(int owner, int32_t pipe) {
    pthread_mutex_lock(&g_steam_callback_lock);
    for (Bo3NativeResponse **link = &g_responses; *link;) {
        const Bo3SteamProxy *interface = (*link)->interface;
        if (interface->owner == owner && (!pipe || interface->pipe == pipe)) steam_retire_response(link);
        else link = &(*link)->next;
    }
    pthread_cond_broadcast(&g_steam_callback_idle);
    pthread_mutex_unlock(&g_steam_callback_lock);
}

static void steam_resp_invoke(void *self, unsigned slot, uint64_t a1, uint64_t a2, uint64_t a3, GuestXmm x0) {
    Bo3NativeResponse *resp = self;
    GuestContext *ctx = g_steam_ctx;
    if (!resp) return;
    if (!ctx) {
        if (__atomic_fetch_add(&g_resp_drop_logs, 1, __ATOMIC_RELAXED) < 8)
            STEAM_LOG("matchmaking response slot %u dropped: no guest context on this thread", slot);
        return;
    }

    STEAM_LEASE(lease);
    if (!steam_proxy_acquire((uint64_t)(uintptr_t)resp->interface, &lease)) return;
    pthread_t thread = pthread_self();
    pthread_mutex_lock(&g_steam_callback_lock);
    SteamPump *pipe = &g_steam_pumps[lease.owner];
    while (resp->guest_obj && !pipe->closing && g_steam_dispatch_active &&
           !pthread_equal(g_steam_dispatch_thread, thread))
        pthread_cond_wait(&g_steam_callback_idle, &g_steam_callback_lock);
    uint64_t guest = pipe->closing ? 0 : resp->guest_obj;
    if (resp->kind == STEAM_RESP_SERVER_LIST && guest && !resp->bound) {
        // Even a synchronous list response carries the request handle.
        resp->handle = a1;
        resp->bound = true;
    }
    uint64_t run_va;
    bool end = resp->kind != STEAM_RESP_SERVER_LIST && (resp->kind == STEAM_RESP_PING || slot != 0);
    if (guest && steam_response_target(guest, slot, &run_va)) {
        bool outermost = !g_steam_dispatch_active;
        if (outermost) {
            g_steam_dispatch_active = true;
            g_steam_dispatch_thread = thread;
        }
        resp->thread = thread;
        ++resp->running;
        pthread_mutex_unlock(&g_steam_callback_lock);
        steam_guest_call(ctx, g_steam_rsp, run_va, guest, a1, a2, a3, x0);
        pthread_mutex_lock(&g_steam_callback_lock);
        --resp->running;
        if (outermost) g_steam_dispatch_active = false;
    }
    if ((end || resp->retire_when_idle) && !resp->running) steam_retire_matching_response(resp);
    pthread_cond_broadcast(&g_steam_callback_idle);
    pthread_mutex_unlock(&g_steam_callback_lock);
}

// ISteamMatchmakingServerListResponse
static void resp_list_responded(void *self, void *req, int32_t server) {
    steam_resp_invoke(self, 0, (uint64_t)(uintptr_t)req, (uint64_t)(uint32_t)server, 0, guest_xmm_zero());
}
static void resp_list_failed(void *self, void *req, int32_t server) {
    steam_resp_invoke(self, 1, (uint64_t)(uintptr_t)req, (uint64_t)(uint32_t)server, 0, guest_xmm_zero());
}
static void resp_list_complete(void *self, void *req, int32_t response) {
    steam_resp_invoke(self, 2, (uint64_t)(uintptr_t)req, (uint64_t)(uint32_t)response, 0, guest_xmm_zero());
}
// ISteamMatchmakingPingResponse
static void resp_ping_responded(void *self, void *server) {
    steam_resp_invoke(self, 0, (uint64_t)(uintptr_t)server, 0, 0, guest_xmm_zero());
}
static void resp_ping_failed(void *self) { steam_resp_invoke(self, 1, 0, 0, 0, guest_xmm_zero()); }
// ISteamMatchmakingPlayersResponse
static void resp_players_add(void *self, const char *name, int32_t score, float time_played) {
    steam_resp_invoke(self, 0, (uint64_t)(uintptr_t)name, (uint64_t)(uint32_t)score, 0, f32_to_xmm(time_played));
}
static void resp_players_failed(void *self) { steam_resp_invoke(self, 1, 0, 0, 0, guest_xmm_zero()); }
static void resp_players_complete(void *self) { steam_resp_invoke(self, 2, 0, 0, 0, guest_xmm_zero()); }
// ISteamMatchmakingRulesResponse
static void resp_rules_responded(void *self, const char *rule, const char *value) {
    steam_resp_invoke(self, 0, (uint64_t)(uintptr_t)rule, (uint64_t)(uintptr_t)value, 0, guest_xmm_zero());
}
static void resp_rules_failed(void *self) { steam_resp_invoke(self, 1, 0, 0, 0, guest_xmm_zero()); }
static void resp_rules_complete(void *self) { steam_resp_invoke(self, 2, 0, 0, 0, guest_xmm_zero()); }

static void *const k_resp_vt_list[] = { (void *)resp_list_responded, (void *)resp_list_failed, (void *)resp_list_complete };
static void *const k_resp_vt_ping[] = { (void *)resp_ping_responded, (void *)resp_ping_failed };
static void *const k_resp_vt_players[] = { (void *)resp_players_add, (void *)resp_players_failed,
                                           (void *)resp_players_complete };
static void *const k_resp_vt_rules[] = { (void *)resp_rules_responded, (void *)resp_rules_failed,
                                         (void *)resp_rules_complete };
static void *const *const k_resp_vts[STEAM_RESP_KIND_COUNT] = {
    k_resp_vt_list, k_resp_vt_ping, k_resp_vt_players, k_resp_vt_rules,
};

// One native proxy per (guest response object, kind), never freed: BO3 keeps long-lived
// browser/query objects, and Steam may still call back after CancelQuery/ReleaseRequest.
static Bo3NativeResponse *steam_resp_wrap(uint64_t interface, uint64_t guest, int kind) {
    uint64_t target;
    if (!steam_response_target(guest, 0, &target)) return NULL;
    Bo3NativeResponse *resp = calloc(1, sizeof(*resp));
    if (!resp) return NULL;
    resp->vtable = k_resp_vts[kind];
    resp->interface = (const Bo3SteamProxy *)(uintptr_t)interface;
    resp->guest_obj = guest;
    resp->kind = kind;
    pthread_mutex_lock(&g_steam_callback_lock);
    resp->next = g_responses;
    g_responses = resp;
    pthread_mutex_unlock(&g_steam_callback_lock);
    return resp;
}

static void steam_resp_bind(Bo3NativeResponse *resp, uint64_t handle, bool valid) {
    if (!resp) return;
    pthread_mutex_lock(&g_steam_callback_lock);
    if (valid) {
        resp->handle = handle;
        resp->bound = true;
    } else {
        resp->guest_obj = 0;
        pthread_cond_broadcast(&g_steam_callback_idle);
        while (resp->running && !pthread_equal(resp->thread, pthread_self()))
            pthread_cond_wait(&g_steam_callback_idle, &g_steam_callback_lock);
        steam_retire_matching_response(resp);
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
}

static void steam_resp_cancel(uint64_t interface, uint64_t handle, bool list, bool release) {
    pthread_mutex_lock(&g_steam_callback_lock);
    Bo3NativeResponse *resp = g_responses;
    while (resp && (!resp->bound || resp->handle != handle ||
                    resp->interface != (const Bo3SteamProxy *)(uintptr_t)interface ||
                    (resp->kind == STEAM_RESP_SERVER_LIST) != list))
        resp = resp->next;
    if (resp) {
        resp->guest_obj = 0;
        resp->retire_when_idle |= release;
        pthread_cond_broadcast(&g_steam_callback_idle);
        while (resp->running && !pthread_equal(resp->thread, pthread_self()))
            pthread_cond_wait(&g_steam_callback_idle, &g_steam_callback_lock);
        // A re-entrant release keeps the mapping until its invocation returns.
        if (resp->retire_when_idle && !resp->running) steam_retire_matching_response(resp);
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
}

// HServerListRequest RequestXxxServerList(AppId_t iApp, MatchMakingKeyValuePair_t **ppchFilters,
//                                         uint32 nFilters, ISteamMatchmakingServerListResponse *)
static GuestRet steam_mms_request_filtered(GuestContext *ctx, uint64_t rsp, uint64_t rdi, unsigned slot,
                                           uint64_t app, uint64_t filters, uint64_t count, uint64_t guest_resp) {
    STEAM_LEASE(lease);
    void *self = steam_proxy_acquire(rdi, &lease);
    if (!self) return ret_u64(0);
    steam_trace_slot(rdi, slot);
    Bo3NativeResponse *resp = steam_resp_wrap(rdi, guest_resp, STEAM_RESP_SERVER_LIST);
    if (guest_resp && !resp) return ret_u64(0);
    const SteamScope scope = steam_scope_enter(ctx, rsp);
    void *r = STEAM_VFN(self, slot, void *(*)(void *, uint32_t, void *, uint32_t, void *))(
        self, (uint32_t)app, (void *)(uintptr_t)filters, (uint32_t)count, resp);
    steam_scope_leave(scope);
    steam_resp_bind(resp, (uint64_t)(uintptr_t)r, r != NULL);
    return ret_ptr(r);
}
#define STEAM_MMS_FILTERED(N) \
    static GuestRet steam_mms_request_##N(SHIM_PARAMS) { \
        SHIM_UNUSED_ALL(); \
        return steam_mms_request_filtered(ctx, rsp, rdi, N, rsi, rdx, rcx, r8); \
    }
STEAM_MMS_FILTERED(0) STEAM_MMS_FILTERED(2) STEAM_MMS_FILTERED(3) STEAM_MMS_FILTERED(4) STEAM_MMS_FILTERED(5)

// HServerListRequest RequestLANServerList(AppId_t iApp, ISteamMatchmakingServerListResponse *)
static GuestRet steam_mms_request_lan(SHIM_PARAMS) {
    STEAM_SELF(1);
    Bo3NativeResponse *resp = steam_resp_wrap(rdi, rdx, STEAM_RESP_SERVER_LIST);
    void *r = (rdx && !resp) ? NULL
        : STEAM_VFN(self, 1, void *(*)(void *, uint32_t, void *))(self, (uint32_t)rsi, resp);
    steam_scope_leave(scope);
    steam_resp_bind(resp, (uint64_t)(uintptr_t)r, r != NULL);
    return ret_ptr(r);
}

// HServerQuery PingServer/PlayerDetails/ServerRules(uint32 unIP, uint16 usPort, ISteamMatchmaking*Response *)
static GuestRet steam_mms_server_query(GuestContext *ctx, uint64_t rsp, uint64_t rdi, unsigned slot, int kind,
                                       uint64_t ip, uint64_t port, uint64_t guest_resp) {
    STEAM_LEASE(lease);
    void *self = steam_proxy_acquire(rdi, &lease);
    if (!self) return ret_i64(-1);
    steam_trace_slot(rdi, slot);
    Bo3NativeResponse *resp = steam_resp_wrap(rdi, guest_resp, kind);
    if (guest_resp && !resp) return ret_i64(-1);
    const SteamScope scope = steam_scope_enter(ctx, rsp);
    int32_t r = STEAM_VFN(self, slot, int32_t (*)(void *, uint32_t, uint16_t, void *))(
        self, (uint32_t)ip, (uint16_t)port, resp);
    steam_scope_leave(scope);
    steam_resp_bind(resp, (uint32_t)r, r != -1);
    return ret_u64((uint32_t)r);
}
static GuestRet steam_mms_ping_server(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return steam_mms_server_query(ctx, rsp, rdi, 13, STEAM_RESP_PING, rsi, rdx, rcx);
}
static GuestRet steam_mms_player_details(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return steam_mms_server_query(ctx, rsp, rdi, 14, STEAM_RESP_PLAYERS, rsi, rdx, rcx);
}
static GuestRet steam_mms_server_rules(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return steam_mms_server_query(ctx, rsp, rdi, 15, STEAM_RESP_RULES, rsi, rdx, rcx);
}

static GuestRet steam_mms_end_list(GuestContext *ctx, uint64_t rsp, uint64_t interface,
                                   uint64_t handle, unsigned slot) {
    STEAM_LEASE(lease);
    void *self = steam_proxy_acquire(interface, &lease);
    if (!self) return ret_void();
    steam_trace_slot(interface, slot);
    steam_resp_cancel(interface, handle, true, slot == 6);
    const SteamScope scope = steam_scope_enter(ctx, rsp);
    STEAM_VFN(self, slot, void (*)(void *, void *))(self, (void *)(uintptr_t)handle);
    steam_scope_leave(scope);
    return ret_void();
}

static GuestRet steam_mms_release_request(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return steam_mms_end_list(ctx, rsp, rdi, rsi, 6);
}

static GuestRet steam_mms_cancel_query(SHIM_PARAMS) {
    SHIM_UNUSED_ALL();
    return steam_mms_end_list(ctx, rsp, rdi, rsi, 8);
}

static GuestRet steam_mms_cancel_server_query(SHIM_PARAMS) {
    STEAM_SELF(16);
    steam_resp_cancel(rdi, (uint32_t)rsi, false, true);
    STEAM_VFN(self, 16, void (*)(void *, int32_t))(self, (int32_t)rsi);
    steam_scope_leave(scope);
    return ret_void();
}

// ---- Guest vtables per kind ----
static void steam_set(int kind, unsigned slot, GuestFn fn, const char *name) {
    g_proxy_vt[kind][slot] = bo3_com_register_thunk(fn, name);
}
static void steam_set_bools(int kind, const unsigned *slots, size_t n) {
    for (size_t i = 0; i < n; ++i) g_slot_abi[kind][slots[i]].flags |= FWD_RET_BOOL;
}
#define STEAM_BOOLS(kind, ...) do { \
        static const unsigned slots_[] = { __VA_ARGS__ }; \
        steam_set_bools((kind), slots_, sizeof(slots_) / sizeof(slots_[0])); \
    } while (0)

static void steam_proxy_tables_init(void) {
    uint64_t fwd[STEAM_PROXY_SLOTS];
    for (unsigned i = 0; i < STEAM_PROXY_SLOTS; ++i) fwd[i] = bo3_com_register_thunk(k_steam_fwd[i], "Steam::fwd");
    for (int k = 0; k < STEAM_KIND_COUNT; ++k) memcpy(g_proxy_vt[k], fwd, sizeof(fwd));

    // ISteamClient017
    const int C = STEAM_KIND_CLIENT;
    STEAM_BOOLS(C, 1, 22);
    steam_set(C, 0, steam_client_create_pipe, "SteamClient::CreateSteamPipe");
    steam_set(C, 1, steam_client_release_pipe, "SteamClient::BReleaseSteamPipe");
    steam_set(C, 2, steam_client_connect_global, "SteamClient::ConnectToGlobalUser");
    steam_set(C, 3, steam_client_create_local, "SteamClient::CreateLocalUser");
    steam_set(C, 4, steam_client_release_user, "SteamClient::ReleaseUser");
    steam_set(C, 7, steam_client_set_ip_binding, "SteamClient::SetLocalIPBinding");
    steam_set(C, 19, steam_client_run_frame, "SteamClient::RunFrame");
    steam_set(C, 20, steam_client_ipc_count, "SteamClient::GetIPCCallCount");
    steam_set(C, 22, steam_client_shutdown_if_closed, "SteamClient::BShutdownIfAllPipesClosed");
    steam_set(C, 9, steam_client_iface_9, "SteamClient::GetISteamUtils");
#define SET_IFACE(N) steam_set(C, N, steam_client_iface_##N, "SteamClient::GetISteam*")
    SET_IFACE(5);  SET_IFACE(6);  SET_IFACE(8);  SET_IFACE(10); SET_IFACE(11); SET_IFACE(12);
    SET_IFACE(13); SET_IFACE(14); SET_IFACE(15); SET_IFACE(16); SET_IFACE(17); SET_IFACE(18);
    SET_IFACE(23); SET_IFACE(24); SET_IFACE(25); SET_IFACE(26); SET_IFACE(27); SET_IFACE(28);
    SET_IFACE(29); SET_IFACE(30); SET_IFACE(34); SET_IFACE(35);
#undef SET_IFACE
    steam_set(C, 36, steam_ret0, "SteamClient::unused");
    // SetWarningMessageHook, DEPRECATED_Set/Remove_SteamAPI_CPostAPIResultInProcess,
    // Set_SteamAPI_CCheckCallbackRegisteredInProcess: all take guest function pointers.
    steam_set(C, 21, steam_ignore_guest_fnptr, "SteamClient::SetWarningMessageHook");
    steam_set(C, 31, steam_ignore_guest_fnptr, "SteamClient::Set_CPostAPIResultInProcess");
    steam_set(C, 32, steam_ignore_guest_fnptr, "SteamClient::Remove_CPostAPIResultInProcess");
    steam_set(C, 33, steam_ignore_guest_fnptr, "SteamClient::Set_CCheckCallbackRegisteredInProcess");

    // ISteamUser019
    const int U = STEAM_KIND_USER;
    STEAM_BOOLS(U, 1, 6, 18, 21, 25, 26);
    steam_set(U, 3, steam_user_initiate_connection, "SteamUser::InitiateGameConnection");
    steam_set(U, 10, steam_user_get_voice, "SteamUser::GetVoice");
    steam_set(U, 11, steam_user_decompress_voice, "SteamUser::DecompressVoice");
    steam_set(U, 13, steam_user_get_auth_ticket_native, "SteamUser::GetAuthSessionTicket");
    steam_set(U, 14, steam_user_begin_auth, "SteamUser::BeginAuthSession");
    steam_set(U, 15, steam_user_end_auth, "SteamUser::EndAuthSession");
    steam_set(U, 16, steam_user_cancel_auth_native, "SteamUser::CancelAuthTicket");
    steam_set(U, 20, steam_user_request_app_ticket, "SteamUser::RequestEncryptedAppTicket");
    steam_set(U, 21, steam_user_get_app_ticket, "SteamUser::GetEncryptedAppTicket");

    // ISteamFriends015
    const int F = STEAM_KIND_FRIENDS;
    STEAM_BOOLS(F, 8, 17, 22, 26, 37, 43, 49, 55, 58, 60, 61, 62, 63, 64, 65);
    steam_set(F, 59, steam_friends_clan_chat_message, "SteamFriends::GetClanChatMessage");

    // ISteamUtils008
    const int UT = STEAM_KIND_UTILS;
    STEAM_BOOLS(UT, 5, 6, 7, 11, 13, 17, 18, 20, 22, 24, 26);
    steam_set(UT, 16, steam_ignore_guest_fnptr, "SteamUtils::SetWarningMessageHook");

    // ISteamApps008
    const int A = STEAM_KIND_APPS;
    STEAM_BOOLS(A, 0, 1, 2, 3, 6, 7, 9, 11, 15, 16, 19, 22);

    // ISteamNetworking005
    const int N = STEAM_KIND_NETWORKING;
    STEAM_BOOLS(N, 0, 1, 2, 3, 4, 5, 6, 7, 11, 12, 13, 14, 15, 16, 17, 18, 19);
    steam_set(N, 0, steam_net_send_p2p, "SteamNetworking::SendP2PPacket");
    steam_set(N, 1, steam_net_p2p_available, "SteamNetworking::IsP2PPacketAvailable");
    steam_set(N, 2, steam_net_read_p2p, "SteamNetworking::ReadP2PPacket");
    steam_set(N, 3, steam_net_accept_session, "SteamNetworking::AcceptP2PSessionWithUser");
    steam_set(N, 4, steam_net_close_session, "SteamNetworking::CloseP2PSessionWithUser");
    steam_set(N, 5, steam_net_close_channel, "SteamNetworking::CloseP2PChannelWithUser");
    steam_set(N, 6, steam_net_session_state, "SteamNetworking::GetP2PSessionState");
    steam_set(N, 7, steam_net_allow_relay, "SteamNetworking::AllowP2PPacketRelay");

    // ISteamMatchmaking009
    const int M = STEAM_KIND_MATCHMAKING;
    STEAM_BOOLS(M, 1, 3, 16, 20, 22, 23, 26, 28, 30, 31, 33, 34, 36, 37);
    steam_set(M, 1, steam_mm_get_favorite, "SteamMatchmaking::GetFavoriteGame");
    steam_set(M, 2, steam_mm_add_favorite, "SteamMatchmaking::AddFavoriteGame");
    steam_set(M, 13, steam_mm_create_lobby, "SteamMatchmaking::CreateLobby");
    steam_set(M, 22, steam_mm_lobby_data_by_index, "SteamMatchmaking::GetLobbyDataByIndex");
    steam_set(M, 27, steam_mm_lobby_chat_entry, "SteamMatchmaking::GetLobbyChatEntry");
    steam_set(M, 33, steam_mm_set_lobby_type, "SteamMatchmaking::SetLobbyType");

    // ISteamMatchmakingServers002
    const int MS = STEAM_KIND_MMSERVERS;
    STEAM_BOOLS(MS, 10);
    steam_set(MS, 0, steam_mms_request_0, "SteamMatchmakingServers::RequestInternetServerList");
    steam_set(MS, 1, steam_mms_request_lan, "SteamMatchmakingServers::RequestLANServerList");
    steam_set(MS, 2, steam_mms_request_2, "SteamMatchmakingServers::RequestFriendsServerList");
    steam_set(MS, 3, steam_mms_request_3, "SteamMatchmakingServers::RequestFavoritesServerList");
    steam_set(MS, 4, steam_mms_request_4, "SteamMatchmakingServers::RequestHistoryServerList");
    steam_set(MS, 5, steam_mms_request_5, "SteamMatchmakingServers::RequestSpectatorServerList");
    steam_set(MS, 6, steam_mms_release_request, "SteamMatchmakingServers::ReleaseRequest");
    steam_set(MS, 8, steam_mms_cancel_query, "SteamMatchmakingServers::CancelQuery");
    steam_set(MS, 16, steam_mms_cancel_server_query, "SteamMatchmakingServers::CancelServerQuery");
    steam_set(MS, 13, steam_mms_ping_server, "SteamMatchmakingServers::PingServer");
    steam_set(MS, 14, steam_mms_player_details, "SteamMatchmakingServers::PlayerDetails");
    steam_set(MS, 15, steam_mms_server_rules, "SteamMatchmakingServers::ServerRules");

    // ISteamUGC008
    const int G = STEAM_KIND_UGC;
    STEAM_BOOLS(G, 4, 5, 6, 7, 8, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
                32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 58, 59, 60, 61);
    steam_set(G, 0, steam_ugc_query_user, "SteamUGC::CreateQueryUserUGCRequest");
    steam_set(G, 10, steam_ugc_additional_preview, "SteamUGC::GetQueryUGCAdditionalPreview");
    steam_set(G, 12, steam_ugc_kv_tag, "SteamUGC::GetQueryUGCKeyValueTag");

    // ISteamGameServer012
    const int S = STEAM_KIND_GAMESERVER;
    STEAM_BOOLS(S, 0, 8, 9, 11, 24, 27, 33, 37);
    steam_set(S, 0, steam_gs_init_game_server, "SteamGameServer::InitGameServer");

    // ISteamMusic001
    STEAM_BOOLS(STEAM_KIND_MUSIC, 0, 1);
    steam_set(STEAM_KIND_MUSIC, 8, steam_music_get_volume, "SteamMusic::GetVolume");

    STEAM_BOOLS(STEAM_KIND_REMOTESTORAGE, 0, 4, 5, 6, 8, 10, 11, 12, 13, 14, 20, 21, 22, 25, 26,
                32, 33, 34, 35, 36, 37, 45);
    STEAM_BOOLS(STEAM_KIND_USERSTATS, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 17, 18, 19, 20, 21, 30, 37, 39, 40);
    STEAM_BOOLS(STEAM_KIND_GSSTATS, 1, 2, 3, 4, 5, 6, 7, 8);
    STEAM_BOOLS(STEAM_KIND_HTTP, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 23, 24);
    STEAM_BOOLS(STEAM_KIND_CONTROLLER, 0, 1, 4);
    STEAM_BOOLS(STEAM_KIND_SCREENSHOTS, 4, 5, 6);
    STEAM_BOOLS(STEAM_KIND_INVENTORY, 1, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21);
    STEAM_BOOLS(STEAM_KIND_UNIFIEDMSG, 1, 2, 3, 4);
    STEAM_BOOLS(STEAM_KIND_HTMLSURFACE, 2, 3);
    STEAM_BOOLS(STEAM_KIND_MUSICREMOTE, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31);
    STEAM_BOOLS(STEAM_KIND_VIDEO, 1);
    // ISteamAppList001 returns only 32-bit integers, with no narrow or stack arguments.

    steam_set(STEAM_KIND_REMOTESTORAGE, 30, steam_rs_publish_workshop_file, "RemoteStorage::PublishWorkshopFile");
    steam_set(STEAM_KIND_REMOTESTORAGE, 50, steam_rs_publish_video, "RemoteStorage::PublishVideo");
    steam_set(STEAM_KIND_HTMLSURFACE, 0, steam_ret0, "HTMLSurface::~HTMLSurface");
    steam_set(STEAM_KIND_HTMLSURFACE, 1, steam_ret0, "HTMLSurface::~HTMLSurface");
    steam_set(STEAM_KIND_HTMLSURFACE, 31, steam_html_set_cookie, "HTMLSurface::SetCookie");
    steam_set(STEAM_KIND_INVENTORY, 18, steam_inventory_trade_items, "Inventory::TradeItems");

#define SLOT_ARGS(kind, slot, mask) (g_slot_abi[(kind)][(slot)].flags |= (mask))
    SLOT_ARGS(U, 4, FWD_ARG_U16(2));                        // TerminateGameConnection
    SLOT_ARGS(U, 19, FWD_ARG_U16(3));                       // AdvertiseGame
    SLOT_ARGS(U, 22, FWD_ARG_BOOL(2));                      // GetGameBadgeLevel
    SLOT_ARGS(F, 27, FWD_ARG_BOOL(2));                      // SetInGameVoiceSpeaking
    SLOT_ARGS(F, 37, FWD_ARG_BOOL(2));                      // RequestUserInformation
    SLOT_ARGS(F, 64, FWD_ARG_BOOL(1));                      // SetListenForFriendsMessages
    SLOT_ARGS(UT, 8, FWD_RET_U8);                           // GetCurrentBatteryPower
    SLOT_ARGS(A, 16, FWD_ARG_BOOL(1));                      // MarkContentCorrupt
    SLOT_ARGS(M, 3, FWD_ARG_U16(3) | FWD_ARG_U16(4));        // RemoveFavoriteGame
    SLOT_ARGS(M, 29, FWD_ARG_U16(3));                       // SetLobbyGameServer
    SLOT_ARGS(M, 34, FWD_ARG_BOOL(2));                      // SetLobbyJoinable
    SLOT_ARGS(N, 8, FWD_ARG_U16(3) | FWD_ARG_BOOL(4));        // CreateListenSocket
    SLOT_ARGS(N, 9, FWD_ARG_BOOL(4));                       // CreateP2PConnectionSocket
    SLOT_ARGS(N, 10, FWD_ARG_U16(2));                       // CreateConnectionSocket
    SLOT_ARGS(N, 11, FWD_ARG_BOOL(2));                      // DestroySocket
    SLOT_ARGS(N, 12, FWD_ARG_BOOL(2));                      // DestroyListenSocket
    SLOT_ARGS(N, 13, FWD_ARG_BOOL(4));                      // SendDataOnSocket
    SLOT_ARGS(G, 49, FWD_ARG_BOOL(2));                      // SetUserItemVote
    for (unsigned slot = 16; slot <= 21; ++slot) SLOT_ARGS(G, slot, FWD_ARG_BOOL(2));
    SLOT_ARGS(G, 25, FWD_ARG_BOOL(2));                      // SetMatchAnyTag
    SLOT_ARGS(G, 60, FWD_ARG_BOOL(2));                      // DownloadItem
    SLOT_ARGS(G, 62, FWD_ARG_BOOL(1));                      // SuspendDownloads
    SLOT_ARGS(S, 4, FWD_ARG_BOOL(1));                       // SetDedicatedServer
    SLOT_ARGS(S, 16, FWD_ARG_BOOL(1));                      // SetPasswordProtected
    SLOT_ARGS(S, 17, FWD_ARG_U16(1));                       // SetSpectatorPort
    SLOT_ARGS(S, 37, FWD_ARG_U16(4));                       // HandleIncomingPacket
    SLOT_ARGS(S, 39, FWD_ARG_BOOL(1));                      // EnableHeartbeats

    SLOT_ARGS(STEAM_KIND_REMOTESTORAGE, 23, FWD_ARG_BOOL(1)); // SetCloudEnabledForApp
    SLOT_ARGS(STEAM_KIND_REMOTESTORAGE, 47, FWD_ARG_BOOL(2)); // UpdateUserPublishedItemVote
    SLOT_ARGS(STEAM_KIND_USERSTATS, 21, FWD_ARG_BOOL(1));     // ResetAllStats
    SLOT_ARGS(STEAM_KIND_HTTP, 17, FWD_ARG_BOOL(1));          // CreateCookieContainer
    SLOT_ARGS(STEAM_KIND_HTTP, 22, FWD_ARG_BOOL(2));          // SetHTTPRequestRequiresVerifiedCertificate
    SLOT_ARGS(STEAM_KIND_CONTROLLER, 15, FWD_ARG_U16(3));    // TriggerHapticPulse
    SLOT_ARGS(STEAM_KIND_CONTROLLER, 16, FWD_ARG_U16(3) | FWD_ARG_U16(4) | FWD_ARG_U16(5));
    SLOT_ARGS(STEAM_KIND_SCREENSHOTS, 3, FWD_ARG_BOOL(1));    // HookScreenshots
    SLOT_ARGS(STEAM_KIND_INVENTORY, 8, FWD_ARG_BOOL(4));      // DeserializeResult
    SLOT_ARGS(STEAM_KIND_UNIFIEDMSG, 2, FWD_ARG_BOOL(4));     // GetMethodResponseData
    SLOT_ARGS(STEAM_KIND_HTMLSURFACE, 24, FWD_ARG_BOOL(2));   // SetKeyFocus
    SLOT_ARGS(STEAM_KIND_HTMLSURFACE, 28, FWD_ARG_BOOL(3) | FWD_ARG_BOOL(4)); // Find
    SLOT_ARGS(STEAM_KIND_HTMLSURFACE, 33, FWD_ARG_BOOL(2));   // SetBackgroundMode
    SLOT_ARGS(STEAM_KIND_HTMLSURFACE, 34, FWD_ARG_BOOL(2));   // AllowStartRequest
    SLOT_ARGS(STEAM_KIND_HTMLSURFACE, 35, FWD_ARG_BOOL(2));   // JSDialogResponse
    const unsigned music_remote_bools[] = { 3, 6, 7, 8, 9, 10, 11, 13, 14, 17 };
    for (size_t i = 0; i < sizeof(music_remote_bools) / sizeof(music_remote_bools[0]); ++i)
        SLOT_ARGS(STEAM_KIND_MUSICREMOTE, music_remote_bools[i], FWD_ARG_BOOL(1));
#undef SLOT_ARGS

    g_slot_abi[STEAM_KIND_REMOTESTORAGE][53].stack_args = 1; // EnumeratePublishedWorkshopFiles
    g_slot_abi[STEAM_KIND_CONTROLLER][16].stack_args = 1;    // TriggerRepeatedHapticPulse
    g_slot_abi[STEAM_KIND_INVENTORY][14].stack_args = 2;     // ExchangeItems

}

// ---- Callback and call-result manager ----
typedef struct SteamCallResultReg {
    SteamCallback *callback;
    uint64_t call;
} SteamCallResultReg;

static SteamCallResultReg g_steam_call_results[STEAM_CALL_RESULT_CAP];

// Passed to steamclient as SteamAPI_CheckCallbackRegistered_t.
uint32_t bo3_steam_check_cb_registered(int iCallback);
uint32_t bo3_steam_check_cb_registered(int iCallback) {
    uint32_t count = 0;
    pthread_mutex_lock(&g_steam_callback_lock);
    for (size_t i = 0; i < STEAM_CALLBACK_CAP; ++i) {
        const SteamCallback *cb = g_steam_callbacks[i].callback;
        if (cb && cb->id == iCallback) ++count;
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    return count;
}

static int steam_vtable_ok(const uint64_t *vtable) {
    return vtable && (uintptr_t)vtable != BO3_STEAM_CALLBACK_BASE_VTABLE;
}

// Registered callbacks for one message, with the registry locked between guest calls.
static void steam_dispatch_native(GuestContext *ctx, uint64_t rsp, SteamPump *pump,
                                  int32_t id, int is_gs, void *payload) {
    pthread_mutex_lock(&g_steam_callback_lock);
    uint64_t last_serial = g_steam_callback_serial;
    for (size_t i = 0; i < STEAM_CALLBACK_CAP; ++i) {
        const SteamCallbackRegistration *registration = &g_steam_callbacks[i];
        SteamCallback *callback = registration->callback;
        if (!callback || registration->serial > last_serial || callback->id != id ||
            ((callback->flags >> 1) & 1) != (is_gs ? 1 : 0)) continue;

        const uint64_t *vtable = __atomic_load_n(&callback->vtable, __ATOMIC_ACQUIRE);
        if (!steam_vtable_ok(vtable)) continue;
        uint64_t run_va = vtable[0]; // Run(void *pvParam)
        if (!run_va) continue;

        pump->running = callback;
        pthread_mutex_unlock(&g_steam_callback_lock);
        steam_guest_call(ctx, rsp, run_va, (uint64_t)(uintptr_t)callback, (uint64_t)(uintptr_t)payload,
                         0, 0, guest_xmm_zero());
        pthread_mutex_lock(&g_steam_callback_lock);
        pump->running = NULL;
        pthread_cond_broadcast(&g_steam_callback_idle);
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
}

// Unregister can withdraw listeners that have been snapshotted but have not run.
static SteamCallResultReg g_pending_call_results[STEAM_CALL_RESULT_CAP];

static void steam_dispatch_call_results(GuestContext *ctx, uint64_t rsp, SteamPump *pump,
                                        int32_t pipe, SteamAPICallCompleted completion) {
    uint64_t call = completion.hAsyncCall;
    size_t count = 0;
    pthread_mutex_lock(&g_steam_callback_lock);
    for (size_t i = 0; i < STEAM_CALL_RESULT_CAP; ++i) {
        SteamCallResultReg *entry = &g_steam_call_results[i];
        if (entry->callback && entry->call == call) {
            g_pending_call_results[count++] = *entry;
            *entry = (SteamCallResultReg){0};
        }
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    if (!count) return;

    uint32_t size = completion.cubParam;
    void *payload = size <= STEAM_CALL_RESULT_MAX_BYTES ? calloc(1, size ? size : 1) : NULL;
    bool failed = false;
    bool ok = payload && (n_GetAPICallResult(pipe, call, payload, (int32_t)size,
                                             completion.iCallback, &failed) & 1);
    bool io_failure = !ok || (failed & 1);
    if (completion.iCallback == STEAM_CB_ENCRYPTED_APP_TICKET) {
        int32_t result = -1;
        if (payload && size >= sizeof(result)) memcpy(&result, payload, sizeof(result));
        STEAM_LOG("EncryptedAppTicketResponse_t (call 0x%llx): eResult=%d%s", (unsigned long long)call,
                  result, io_failure ? " (IO failure)" : "");
    } else if (steam_trace()) {
        STEAM_LOG("call result 0x%llx -> callback %d (%u bytes)%s", (unsigned long long)call,
                  completion.iCallback, size, io_failure ? " (IO failure)" : "");
    }

    pthread_mutex_lock(&g_steam_callback_lock);
    for (size_t i = 0; i < count; ++i) {
        SteamCallback *callback = g_pending_call_results[i].callback;
        g_pending_call_results[i] = (SteamCallResultReg){0};
        if (!callback) continue;
        const uint64_t *vtable = __atomic_load_n(&callback->vtable, __ATOMIC_ACQUIRE);
        if (!steam_vtable_ok(vtable) || !vtable[1]) continue;
        uint64_t run_va = vtable[1]; // Run(void *, bool, SteamAPICall_t)
        uint64_t size_va = vtable[2]; // GetCallbackSizeBytes()
        bool matching = callback->id == completion.iCallback && size_va;
        pump->running = callback;
        pthread_mutex_unlock(&g_steam_callback_lock);
        if (matching) {
            GuestRet expected = steam_guest_call(ctx, rsp, size_va, (uint64_t)(uintptr_t)callback,
                                                 0, 0, 0, guest_xmm_zero());
            matching = (uint32_t)expected.rax_rdx[0] == size;
        }
        static const uint8_t zero_fallback[1024] = {0};
        uint64_t param_ptr = (matching && payload)
            ? (uint64_t)(uintptr_t)payload
            : (uint64_t)(uintptr_t)zero_fallback;
        steam_guest_call(ctx, rsp, run_va, (uint64_t)(uintptr_t)callback,
                         param_ptr, io_failure || !matching || !payload,
                         call, guest_xmm_zero());
        pthread_mutex_lock(&g_steam_callback_lock);
        pump->running = NULL;
        pthread_cond_broadcast(&g_steam_callback_idle);
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    free(payload);
}

static int steam_pump_is_closing(SteamPump *pump) {
    pthread_mutex_lock(&g_steam_callback_lock);
    int closing = pump->closing;
    pthread_mutex_unlock(&g_steam_callback_lock);
    return closing;
}

static void Steam_RunCallbacks_Impl(GuestContext *ctx, uint64_t rsp, int is_gs) {
    int owner = is_gs ? STEAM_PUMP_GS : STEAM_PUMP_CLIENT;
    SteamPump *pump = &g_steam_pumps[owner];
    pthread_mutex_lock(&g_steam_callback_lock);
    int32_t pipe = 0;
    if (!g_steam_dispatch_active && (is_gs ? steam_gs_mode() == STEAM_GS_NATIVE : steam_online()) &&
        steam_pin_pipe(owner)) {
        pipe = is_gs ? steam_gs_pipe() : steam_client_pipe();
        g_steam_dispatch_active = true;
        g_steam_dispatch_thread = pthread_self();
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    if (!pipe) return;

    const SteamScope scope = steam_scope_enter(ctx, rsp);
    if (!is_gs) {
        void *utils = __atomic_load_n(&g_native_utils, __ATOMIC_ACQUIRE);
        void *controller = __atomic_load_n(&g_native_controller, __ATOMIC_ACQUIRE);
        if (utils) STEAM_VFN(utils, 14, void (*)(void *))(utils);                  // ISteamUtils::RunFrame
        if (controller && !steam_pump_is_closing(pump))
            STEAM_VFN(controller, 2, void (*)(void *))(controller);              // ISteamController::RunFrame
    }

    union { SteamCallbackMsg msg; uint8_t pad[32]; } u;
    _Alignas(16) uint8_t payload[STEAM_CALLBACK_MAX_BYTES];
    for (int n = 0; n < STEAM_PUMP_MAX_MESSAGES && !steam_pump_is_closing(pump); ++n) {
        memset(&u, 0, sizeof(u));
        if (!(n_BGetCallback(pipe, &u.msg) & 1)) break;
        if (u.msg.cubParam >= 0 && u.msg.cubParam <= STEAM_CALLBACK_MAX_BYTES &&
            (u.msg.cubParam == 0 || u.msg.pubParam)) {
            size_t size = (size_t)u.msg.cubParam;
            if (size) memcpy(payload, u.msg.pubParam, size);
            else payload[0] = 0;
            if (u.msg.iCallback == STEAM_CB_API_CALL_COMPLETED) {
                SteamAPICallCompleted completion;
                if (size >= sizeof(completion)) {
                    memcpy(&completion, payload, sizeof(completion));
                    steam_dispatch_call_results(ctx, rsp, pump, pipe, completion);
                    steam_dispatch_native(ctx, rsp, pump, u.msg.iCallback, is_gs, payload);
                }
            } else {
                steam_dispatch_native(ctx, rsp, pump, u.msg.iCallback, is_gs, payload);
            }
        }
        n_FreeLastCallback(pipe);
    }
    steam_scope_leave(scope);

    pthread_mutex_lock(&g_steam_callback_lock);
    g_steam_dispatch_active = false;
    pthread_cond_broadcast(&g_steam_callback_idle);
    pthread_mutex_unlock(&g_steam_callback_lock);
    steam_unpin_pipe(owner);
}

// ---- SteamAPI_Init / Shutdown ----
static void steam_go_offline(const char *why) {
    int expected = STEAM_MODE_UNKNOWN;
    if (__atomic_compare_exchange_n(&g_steam_mode, &expected, STEAM_MODE_OFFLINE, false,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
        STEAM_LOG("SteamAPI_Init() -> true (offline mock: %s)", why);
}

static int steam_native_init_client(void) {
    void *client = g_native_client;
    int32_t pipe = STEAM_VFN(client, 0, int32_t (*)(void *))(client);   // CreateSteamPipe
    if (!pipe) {
        STEAM_LOG("CreateSteamPipe() failed: the Steam desktop app is not running or not signed in");
        return 0;
    }
    int32_t user = STEAM_VFN(client, 2, int32_t (*)(void *, int32_t))(client, pipe);   // ConnectToGlobalUser
    if (!user) {
        STEAM_LOG("ConnectToGlobalUser(pipe %d) failed", pipe);
        STEAM_VFN(client, 1, bool (*)(void *, int32_t))(client, pipe);
        return 0;
    }
    void *utils = STEAM_VFN(client, 9, void *(*)(void *, int32_t, const char *))(client, pipe, "SteamUtils008");
    uint32_t app_id = utils ? STEAM_VFN(utils, 9, uint32_t (*)(void *))(utils) : 0;
    typedef void *(*GetIface)(void *, int32_t, int32_t, const char *);
    void *controller = STEAM_VFN(client, 25, GetIface)(client, user, pipe, "SteamController003");
    void *steam_user = STEAM_VFN(client, 5, GetIface)(client, user, pipe, "SteamUser019");
    void *friends = STEAM_VFN(client, 8, GetIface)(client, user, pipe, "SteamFriends015");
    if (app_id != BO3_STEAM_APPID || !steam_user || !friends) {
        STEAM_LOG("native client init rejected (AppID %u, user %p, friends %p)", app_id, steam_user, friends);
        STEAM_VFN(client, 4, void (*)(void *, int32_t, int32_t))(client, pipe, user);
        STEAM_VFN(client, 1, bool (*)(void *, int32_t))(client, pipe);
        STEAM_VFN(client, 22, bool (*)(void *))(client);
        return 0;
    }
    // Set_SteamAPI_CCheckCallbackRegisteredInProcess (native function pointer)
    STEAM_VFN(client, 33, void (*)(void *, uint32_t (*)(int)))(client, bo3_steam_check_cb_registered);

    __atomic_store_n(&g_native_utils, utils, __ATOMIC_RELEASE);
    __atomic_store_n(&g_native_controller, controller, __ATOMIC_RELEASE);
    __atomic_store_n(&g_native_user, steam_user, __ATOMIC_RELEASE);
    __atomic_store_n(&g_native_friends, friends, __ATOMIC_RELEASE);
    __atomic_store_n(&g_client_user, user, __ATOMIC_RELEASE);
    bool logged_on = STEAM_VFN(steam_user, 1, bool (*)(void *))(steam_user) & 1;
    uint64_t steam_id = STEAM_VFN(steam_user, 2, uint64_t (*)(void *))(steam_user);
    const char *persona = STEAM_VFN(friends, 0, const char *(*)(void *))(friends);
    pthread_mutex_lock(&g_steam_callback_lock);
    __atomic_store_n(&g_client_pipe, pipe, __ATOMIC_RELEASE);
    __atomic_store_n(&g_steam_online_id, steam_id, __ATOMIC_RELEASE);
    __atomic_store_n(&g_steam_mode, STEAM_MODE_ONLINE, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g_steam_callback_lock);

    STEAM_LOG("SteamAPI_Init() -> true (native steamclient: pipe %d, user %d, AppID %u)", pipe, user, app_id);
    STEAM_LOG("Steam user: BLoggedOn=%s SteamID=%llu (0x%016llx) persona=\"%s\"",
              logged_on ? "true" : "false", (unsigned long long)steam_id, (unsigned long long)steam_id,
              persona ? persona : "?");
    if (!controller) STEAM_LOG("ISteamController003 unavailable (optional)");
    return 1;
}

// ---- Exported libsteam_api entry points ----
SHIM_DEF(shim__SteamAPI_RestartAppIfNecessary) { SHIM_UNUSED_ALL(); return ret_u64(0); }

SHIM_DEF(shim__SteamAPI_Init) {
    SHIM_UNUSED_ALL();
    bo3_init_steam_mocks();
    steam_offline_mode();
    int mode = steam_mode();
    if (mode == STEAM_MODE_OFFLINE) return ret_u64(1);
    if (mode == STEAM_MODE_ONLINE)
        return ret_u64(!steam_pump_is_closing(&g_steam_pumps[STEAM_PUMP_CLIENT]));
    if (!steam_native_load()) {
        steam_go_offline(steam_offline_mode() ? "BO3ARM_OFFLINE=1" : "native steamclient.dylib unavailable");
        return ret_u64(1);
    }
    pthread_mutex_lock(&g_native_lock);
    int ok = steam_mode() == STEAM_MODE_ONLINE;
    if (!ok && steam_mode() == STEAM_MODE_UNKNOWN) {
        const SteamScope scope = steam_scope_enter(ctx, rsp);
        ok = steam_native_init_client();
        steam_scope_leave(scope);
    }
    if (!ok) steam_go_offline("could not connect to the Steam desktop app");
    pthread_mutex_unlock(&g_native_lock);
    return ret_u64(1);
}

static void steam_finish_close(int owner) {
    pthread_mutex_lock(&g_native_lock);
    int is_gs = owner == STEAM_PUMP_GS;
    int32_t pipe = is_gs ? steam_gs_pipe() : steam_client_pipe();
    int32_t user = is_gs ? __atomic_load_n(&g_gs_user, __ATOMIC_ACQUIRE)
                         : __atomic_load_n(&g_client_user, __ATOMIC_ACQUIRE);
    steam_detach_responses(owner, 0);
    steam_invalidate_proxies(owner, 0);
    if (is_gs) {
        __atomic_store_n(&g_gs_pipe, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_gs_user, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_native_gs, NULL, __ATOMIC_RELEASE);
    } else {
        __atomic_store_n(&g_client_pipe, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_client_user, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_native_utils, NULL, __ATOMIC_RELEASE);
        __atomic_store_n(&g_native_controller, NULL, __ATOMIC_RELEASE);
        __atomic_store_n(&g_native_user, NULL, __ATOMIC_RELEASE);
        __atomic_store_n(&g_native_friends, NULL, __ATOMIC_RELEASE);
        __atomic_store_n(&g_steam_online_id, 0, __ATOMIC_RELEASE);
    }

    void *client = g_native_client;
    if (user) STEAM_VFN(client, 4, void (*)(void *, int32_t, int32_t))(client, pipe, user);
    if (pipe) STEAM_VFN(client, 1, bool (*)(void *, int32_t))(client, pipe);
    STEAM_VFN(client, 22, bool (*)(void *))(client);
    STEAM_LOG("%s shutdown: released pipe %d", is_gs ? "Game server" : "Client", pipe);

    pthread_mutex_lock(&g_steam_callback_lock);
    SteamPump *pump = &g_steam_pumps[owner];
    pump->closing = 0;
    ++pump->close_serial;
    if (is_gs) __atomic_store_n(&g_gs_mode, STEAM_GS_NONE, __ATOMIC_RELEASE);
    else __atomic_store_n(&g_steam_mode, STEAM_MODE_UNKNOWN, __ATOMIC_RELEASE);
    pthread_cond_broadcast(&g_steam_callback_idle);
    pthread_mutex_unlock(&g_steam_callback_lock);
    pthread_mutex_unlock(&g_native_lock);
}

static void steam_close_pipe(int owner) {
    SteamPump *pump = &g_steam_pumps[owner];
    pthread_mutex_lock(&g_steam_callback_lock);
    int32_t pipe = owner == STEAM_PUMP_GS ? steam_gs_pipe() : steam_client_pipe();
    if (!pipe && !pump->closing) {
        pthread_mutex_unlock(&g_steam_callback_lock);
        return;
    }
    if (!pump->closing) {
        pump->closing = 1;
        pthread_cond_broadcast(&g_steam_callback_idle);
    }
    if (steam_claim_close(pump)) {
        pthread_mutex_unlock(&g_steam_callback_lock);
        steam_finish_close(owner);
        return;
    }
    // A guest callback can shut down its own pipe. Its last pin performs
    // teardown after native code returns and the pump releases its message.
    if (!g_steam_pipe_refs[owner] &&
        !(g_steam_dispatch_active && pthread_equal(g_steam_dispatch_thread, pthread_self()))) {
        uint64_t serial = pump->close_serial;
        while (serial == pump->close_serial)
            pthread_cond_wait(&g_steam_callback_idle, &g_steam_callback_lock);
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
}

SHIM_DEF(shim__SteamAPI_Shutdown) {
    SHIM_UNUSED_ALL();
    if (steam_online()) steam_close_pipe(STEAM_PUMP_CLIENT);
    else {
        int offline = STEAM_MODE_OFFLINE;
        __atomic_compare_exchange_n(&g_steam_mode, &offline, STEAM_MODE_UNKNOWN, false,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    }
    return ret_void();
}

SHIM_DEF(shim__SteamAPI_RunCallbacks) {
    SHIM_UNUSED_ALL();
    if (steam_online()) Steam_RunCallbacks_Impl(ctx, rsp, 0);
    return ret_void();
}

SHIM_DEF(shim__SteamAPI_GetHSteamPipe) {
    SHIM_UNUSED_ALL();
    return ret_i64(steam_online() ? steam_client_pipe() : 1);
}
SHIM_DEF(shim__SteamAPI_GetHSteamUser) {
    SHIM_UNUSED_ALL();
    return ret_i64(steam_online() ? __atomic_load_n(&g_client_user, __ATOMIC_ACQUIRE) : 1);
}

SHIM_DEF(shim__SteamAPI_RegisterCallback) {
    SHIM_UNUSED_ALL();
    SteamCallback *callback = (SteamCallback *)(uintptr_t)rdi;
    if (!callback) return ret_void();

    pthread_mutex_lock(&g_steam_callback_lock);
    SteamCallbackRegistration *entry = NULL;
    for (size_t i = 0; i < STEAM_CALLBACK_CAP; ++i) {
        SteamCallbackRegistration *candidate = &g_steam_callbacks[i];
        if (candidate->callback == callback) {
            entry = candidate;
            break;
        }
        if (!entry && !candidate->callback) entry = candidate;
    }
    if (entry) {
        if (entry->callback != callback || callback->id != (int32_t)rsi) {
            *entry = (SteamCallbackRegistration){callback, ++g_steam_callback_serial};
        }
        callback->id = (int32_t)rsi;
        callback->flags |= STEAM_CALLBACK_REGISTERED;
    } else {
        fprintf(stderr, "[steam] callback registry is full\n");
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_void();
}

// Called with the registry locked: wait until no other thread runs guest code for callback.
static void steam_wait_not_running(const SteamCallback *callback) {
    for (;;) {
        int busy = 0;
        for (int p = 0; p < STEAM_PUMP_COUNT; ++p) {
            if (g_steam_pumps[p].running == callback && !pthread_equal(g_steam_dispatch_thread, pthread_self()))
                busy = 1;
        }
        if (!busy) return;
        pthread_cond_wait(&g_steam_callback_idle, &g_steam_callback_lock);
    }
}

SHIM_DEF(shim__SteamAPI_UnregisterCallback) {
    SHIM_UNUSED_ALL();
    SteamCallback *callback = (SteamCallback *)(uintptr_t)rdi;
    if (!callback) return ret_void();

    pthread_mutex_lock(&g_steam_callback_lock);
    for (size_t i = 0; i < STEAM_CALLBACK_CAP; ++i) {
        if (g_steam_callbacks[i].callback == callback) {
            g_steam_callbacks[i].callback = NULL;
            callback->flags &= ~STEAM_CALLBACK_REGISTERED;
            break;
        }
    }
    steam_wait_not_running(callback);
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_void();
}

// void SteamAPI_RegisterCallResult(CCallbackBase *pCallback, SteamAPICall_t hAPICall)
SHIM_DEF(shim__SteamAPI_RegisterCallResult) {
    SHIM_UNUSED_ALL();
    SteamCallback *callback = (SteamCallback *)(uintptr_t)rdi;
    uint64_t call = rsi;
    if (!callback || !call) return ret_void();

    pthread_mutex_lock(&g_steam_callback_lock);
    SteamCallResultReg *slot = NULL;
    int present = 0;
    for (size_t i = 0; i < STEAM_CALL_RESULT_CAP && !present; ++i) {
        SteamCallResultReg *entry = &g_steam_call_results[i];
        present = entry->callback == callback && entry->call == call;
        if (!slot && !entry->callback) slot = entry;
    }
    if (!present) {
        if (slot) *slot = (SteamCallResultReg){callback, call};
        else fprintf(stderr, "[steam] call result registry is full\n");
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_void();
}

// void SteamAPI_UnregisterCallResult(CCallbackBase *pCallback, SteamAPICall_t hAPICall)
SHIM_DEF(shim__SteamAPI_UnregisterCallResult) {
    SHIM_UNUSED_ALL();
    SteamCallback *callback = (SteamCallback *)(uintptr_t)rdi;
    if (!callback) return ret_void();

    pthread_mutex_lock(&g_steam_callback_lock);
    for (size_t i = 0; i < STEAM_CALL_RESULT_CAP; ++i) {
        SteamCallResultReg *entry = &g_steam_call_results[i];
        if (entry->callback == callback && (!rsi || entry->call == rsi)) *entry = (SteamCallResultReg){0};
        entry = &g_pending_call_results[i];
        if (entry->callback == callback && (!rsi || entry->call == rsi)) *entry = (SteamCallResultReg){0};
    }
    steam_wait_not_running(callback);
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_void();
}

// void *SteamInternal_CreateInterface(const char *ver)
SHIM_DEF(shim__SteamInternal_CreateInterface) {
    SHIM_UNUSED_ALL();
    bo3_init_steam_mocks();
    char buf[STEAM_VERSION_CAP];
    const char *ver = steam_read_version(rdi, buf);
    int kind = steam_kind_for_version(ver);
    if (kind == STEAM_KIND_CLIENT) {
        pthread_once(&g_proxy_once, steam_proxy_tables_init);
        return ret_ptr(&g_client_facade);
    }
    if (ver && strncmp(ver, "SteamClient", 11) == 0)
        return ret_ptr(&g_steam_client_obj);

    STEAM_LEASE(lease);
    if (ver && steam_online() && steam_acquire_lease(&lease, STEAM_PUMP_CLIENT)) {
        void *native = n_CreateInterface(ver, NULL);
        if (native) return ret_ptr(steam_wrap(native, kind, STEAM_PUMP_CLIENT, steam_client_pipe()));
    }
    return ret_ptr(steam_iface_for_version(ver));
}

// ---- Game server ----
static int32_t steam_gs_mock_pipe(void) { return steam_online() ? STEAM_GS_MOCK_PIPE_ONLINE : 2; }

static int32_t steam_gs_fallback_handle(int mode) {
    return mode == STEAM_GS_MOCK || !steam_online() ? steam_gs_mock_pipe() : 0;
}

// libsteam_api's SteamInternal_GameServer_Init over the native client.
static int steam_native_init_gs(uint32_t ip, uint16_t steam_port, uint16_t game_port, uint16_t query_port,
                                int32_t server_mode, const char *version) {
    void *client = g_native_client;
    STEAM_VFN(client, 7, void (*)(void *, uint32_t, uint16_t))(client, ip, steam_port);   // SetLocalIPBinding
    int32_t pipe = 0;
    int32_t user = STEAM_VFN(client, 3, int32_t (*)(void *, int32_t *, int32_t))(
        client, &pipe, STEAM_ACCOUNT_TYPE_GAME_SERVER);                                     // CreateLocalUser
    if (!user || !pipe) {
        STEAM_LOG("CreateLocalUser(k_EAccountTypeGameServer) failed (user %d, pipe %d)", user, pipe);
        if (pipe) STEAM_VFN(client, 1, bool (*)(void *, int32_t))(client, pipe);
        return 0;
    }
    void *gs = STEAM_VFN(client, 6, void *(*)(void *, int32_t, int32_t, const char *))(
        client, user, pipe, "SteamGameServer012");
    void *utils = STEAM_VFN(client, 9, void *(*)(void *, int32_t, const char *))(client, pipe, "SteamUtils008");
    uint32_t app_id = utils ? STEAM_VFN(utils, 9, uint32_t (*)(void *))(utils) : 0;
    uint32_t flags = (server_mode == STEAM_SERVER_MODE_AUTH_SECURE ? STEAM_SERVER_FLAG_SECURE : 0) |
                     (server_mode == STEAM_SERVER_MODE_NO_AUTH ? STEAM_SERVER_FLAG_PRIVATE : 0);
    bool ok = gs && app_id &&
              (STEAM_VFN(gs, 0, bool (*)(void *, uint32_t, uint16_t, uint16_t, uint32_t, uint32_t, const char *))(
                   gs, ip, game_port, query_port, flags, app_id, version) & 1);
    if (!ok) {
        STEAM_LOG("native game server init failed (gs %p, utils %p, AppID %u)", gs, utils, app_id);
        STEAM_VFN(client, 4, void (*)(void *, int32_t, int32_t))(client, pipe, user);
        STEAM_VFN(client, 1, bool (*)(void *, int32_t))(client, pipe);
        return 0;
    }
    __atomic_store_n(&g_native_gs, gs, __ATOMIC_RELEASE);
    __atomic_store_n(&g_gs_user, user, __ATOMIC_RELEASE);
    pthread_mutex_lock(&g_steam_callback_lock);
    __atomic_store_n(&g_gs_pipe, pipe, __ATOMIC_RELEASE);
    __atomic_store_n(&g_gs_mode, STEAM_GS_NATIVE, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g_steam_callback_lock);
    STEAM_LOG("SteamInternal_GameServer_Init() -> true (native: pipe %d, user %d, ports %u/%u, flags 0x%x, \"%s\")",
              pipe, user, game_port, query_port, flags, version);
    return 1;
}

// bool SteamInternal_GameServer_Init(uint32 unIP, uint16 usPort, uint16 usGamePort, uint16 usQueryPort,
//                                    EServerMode eServerMode, const char *pchVersionString)
SHIM_DEF(shim__SteamInternal_GameServer_Init) {
    SHIM_UNUSED_ALL();
    bo3_init_steam_mocks();
    pthread_mutex_lock(&g_native_lock);
    if (steam_gs_mode() == STEAM_GS_NATIVE) {
        int ok = !steam_pump_is_closing(&g_steam_pumps[STEAM_PUMP_GS]);
        pthread_mutex_unlock(&g_native_lock);
        return ret_u64(ok);
    }
    // A native game server needs the native client: the offline client's auth tickets
    // would never validate against it.
    if (steam_online()) {
        if (steam_pump_is_closing(&g_steam_pumps[STEAM_PUMP_CLIENT])) {
            pthread_mutex_unlock(&g_native_lock);
            return ret_u64(0);
        }
        char buf[STEAM_VERSION_CAP];
        const char *version = steam_read_version(r9, buf);
        const SteamScope scope = steam_scope_enter(ctx, rsp);
        int ok = steam_native_init_gs((uint32_t)rdi, (uint16_t)rsi, (uint16_t)rdx, (uint16_t)rcx, (int32_t)r8,
                                      version ? version : "");
        steam_scope_leave(scope);
        pthread_mutex_unlock(&g_native_lock);
        return ret_u64(ok);
    }
    __atomic_store_n(&g_gs_mode, STEAM_GS_MOCK, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g_native_lock);
    STEAM_LOG("SteamInternal_GameServer_Init() -> true (offline local server)");
    return ret_u64(1);
}

SHIM_DEF(shim__SteamGameServer_Shutdown) {
    if (steam_gs_mode() == STEAM_GS_NATIVE) {
        steam_close_pipe(STEAM_PUMP_GS);
        return ret_void();
    }
    return steam_gs_logoff(ctx, rsp, rdi, rsi, rdx, rcx, r8, r9,
                           xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7);
}

SHIM_DEF(shim__SteamGameServer_RunCallbacks) {
    SHIM_UNUSED_ALL();
    if (steam_gs_mode() == STEAM_GS_NATIVE) {
        Steam_RunCallbacks_Impl(ctx, rsp, 1);
        return ret_void();
    }
    pthread_mutex_lock(&g_steam_callback_lock);
    if ((g_gs_logon_pending || g_gs_auth_event_count) && !g_steam_dispatch_active &&
        steam_gs_mode() != STEAM_GS_NATIVE) {
        g_steam_dispatch_active = true;
        g_steam_dispatch_thread = pthread_self();
        uint64_t session = g_gs_session;
        int logon_pending = g_gs_logon_pending;
        uint64_t last_auth_serial = g_gs_auth_event_serial;
        g_gs_logon_pending = 0;
        if (logon_pending) {
            // BO3 enters state 4 on 101 and state 5 on 115. The latter can
            // request authorization even for a local loopback player.
            steam_gs_dispatch(ctx, rsp, STEAM_GS_CONNECTED, session, 0);
            steam_gs_dispatch(ctx, rsp, STEAM_GS_POLICY_RESPONSE, session, 0);
        }
        // Leave the entry queued during dispatch so cancellation and session
        // teardown can withdraw it. New events have serials past this pump.
        while (session == g_gs_session && g_gs_auth_event_count &&
               g_gs_auth_events[0].serial <= last_auth_serial) {
            uint64_t serial = g_gs_auth_events[0].serial;
            steam_gs_dispatch(ctx, rsp, STEAM_GS_VALIDATE_TICKET, session, serial);
            if (g_gs_auth_event_count && g_gs_auth_events[0].serial == serial)
                steam_gs_remove_auth_event(0);
        }
        g_steam_dispatch_active = false;
        pthread_cond_broadcast(&g_steam_callback_idle);
    }
    pthread_mutex_unlock(&g_steam_callback_lock);
    return ret_void();
}

SHIM_DEF(shim__SteamGameServer_GetHSteamPipe) {
    SHIM_UNUSED_ALL();
    int mode = steam_gs_mode();
    return ret_i64(mode == STEAM_GS_NATIVE ? steam_gs_pipe() : steam_gs_fallback_handle(mode));
}
SHIM_DEF(shim__SteamGameServer_GetHSteamUser) {
    SHIM_UNUSED_ALL();
    int mode = steam_gs_mode();
    return ret_i64(mode == STEAM_GS_NATIVE ? __atomic_load_n(&g_gs_user, __ATOMIC_ACQUIRE)
                                         : steam_gs_fallback_handle(mode));
}

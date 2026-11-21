// Native ARM64 shims for zlib (10 syms with host-owned z_stream + guest zalloc/zfree trampolines),
// libcurl (16 syms, hard-offline: native callbacks + deterministic CURLE_COULDNT_CONNECT),
// (SteamAPI moved to steam_bridge.c: native steamclient bridge + offline mock),
// and ObjC/CoreVideo/CoreMedia cutscene hooks (stubs, replaced by native AVFoundation in M4).

#include "shim_helpers.h"
#include "../metal/settings_mac.h"
#include <curl/curl.h>
#include <zlib.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>

// ===================== ZLIB (10 syms -> host-owned z_stream + guest allocator trampolines) =====================
// BO3 installs guest x86_64 zalloc/zfree VAs (e.g. 0x1012e8969 / 0x1012e8920) inside guest z_stream.
// Passing guest z_stream directly to native zlib would jump into NX __TEXT!
// Instead we keep a host-owned z_stream per active guest z_stream*, wrap custom guest zalloc/zfree
// via native trampolines calling bo3_resolve(), and synchronize all guest-visible fields across calls.

typedef struct Bo3ZlibEntry {
    z_streamp guest;
    z_stream  host;
    uint64_t  guest_zalloc_va;
    uint64_t  guest_zfree_va;
    voidpf    guest_opaque;
    int       in_use;
} Bo3ZlibEntry;

#define BO3_MAX_ZSTREAMS 256
static pthread_mutex_t g_zlib_lock = PTHREAD_MUTEX_INITIALIZER;
static Bo3ZlibEntry g_zlib_entries[BO3_MAX_ZSTREAMS];

static __thread GuestContext *g_zlib_ctx = NULL;
static __thread uint64_t      g_zlib_rsp = 0;

// Per-invocation callback context: a guest zalloc/zfree may itself re-enter zlib (nested
// inflate/deflate), so every shim saves the outer (ctx, rsp) on its own stack frame and restores
// it on exit instead of clobbering it with NULL.
typedef struct Bo3ZlibScope { GuestContext *ctx; uint64_t rsp; } Bo3ZlibScope;
static inline Bo3ZlibScope zlib_scope_enter(GuestContext *ctx, uint64_t rsp) {
    Bo3ZlibScope saved = { g_zlib_ctx, g_zlib_rsp };
    g_zlib_ctx = ctx;
    g_zlib_rsp = rsp;
    return saved;
}
static inline void zlib_scope_leave(Bo3ZlibScope saved) {
    g_zlib_ctx = saved.ctx;
    g_zlib_rsp = saved.rsp;
}

static voidpf bo3_zlib_alloc_trampoline(voidpf opaque, uInt items, uInt size) {
    Bo3ZlibEntry *e = (Bo3ZlibEntry *)opaque;
    if (e && e->guest_zalloc_va && g_zlib_ctx) {
        GuestFn fn = bo3_resolve(e->guest_zalloc_va, g_zlib_ctx);
        uint64_t sp = (g_zlib_rsp - 128) & ~15ULL;
        sp -= 8; *(uint64_t *)sp = 0;
        GuestRet r = fn(g_zlib_ctx, sp,
                        (uint64_t)(uintptr_t)e->guest_opaque, (uint64_t)items, (uint64_t)size,
                        0, 0, 0,
                        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
                        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
        return (voidpf)(uintptr_t)r.rax_rdx[0];
    }
    return calloc(items, size);
}

static void bo3_zlib_free_trampoline(voidpf opaque, voidpf address) {
    Bo3ZlibEntry *e = (Bo3ZlibEntry *)opaque;
    if (e && e->guest_zfree_va && g_zlib_ctx) {
        GuestFn fn = bo3_resolve(e->guest_zfree_va, g_zlib_ctx);
        uint64_t sp = (g_zlib_rsp - 128) & ~15ULL;
        sp -= 8; *(uint64_t *)sp = 0;
        fn(g_zlib_ctx, sp,
           (uint64_t)(uintptr_t)e->guest_opaque, (uint64_t)(uintptr_t)address,
           0, 0, 0, 0,
           guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
           guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
        return;
    }
    free(address);
}

static Bo3ZlibEntry *zlib_find(z_streamp guest) {
    pthread_mutex_lock(&g_zlib_lock);
    for (int i = 0; i < BO3_MAX_ZSTREAMS; i++) {
        if (g_zlib_entries[i].in_use && g_zlib_entries[i].guest == guest) {
            pthread_mutex_unlock(&g_zlib_lock);
            return &g_zlib_entries[i];
        }
    }
    pthread_mutex_unlock(&g_zlib_lock);
    return NULL;
}

static Bo3ZlibEntry *zlib_alloc_entry(z_streamp guest) {
    pthread_mutex_lock(&g_zlib_lock);
    Bo3ZlibEntry *reuse = NULL;
    for (int i = 0; i < BO3_MAX_ZSTREAMS; i++) {
        if (g_zlib_entries[i].in_use && g_zlib_entries[i].guest == guest) {
            reuse = &g_zlib_entries[i];
            break;
        }
        if (!g_zlib_entries[i].in_use && !reuse) reuse = &g_zlib_entries[i];
    }
    if (!reuse) {
        pthread_mutex_unlock(&g_zlib_lock);
        fprintf(stderr, "[zlib] active z_stream table full!\n");
        return NULL;
    }
    memset(reuse, 0, sizeof(*reuse));
    reuse->in_use = 1;
    reuse->guest = guest;
    reuse->guest_zalloc_va = (uint64_t)(uintptr_t)guest->zalloc;
    reuse->guest_zfree_va  = (uint64_t)(uintptr_t)guest->zfree;
    reuse->guest_opaque    = guest->opaque;
    if (reuse->guest_zalloc_va || reuse->guest_zfree_va) {
        reuse->host.zalloc = bo3_zlib_alloc_trampoline;
        reuse->host.zfree  = bo3_zlib_free_trampoline;
        reuse->host.opaque = (voidpf)reuse;
    } else {
        reuse->host.zalloc = Z_NULL;
        reuse->host.zfree  = Z_NULL;
        reuse->host.opaque = Z_NULL;
    }
    pthread_mutex_unlock(&g_zlib_lock);
    return reuse;
}

static void zlib_release_entry(Bo3ZlibEntry *e) {
    if (!e) return;
    pthread_mutex_lock(&g_zlib_lock);
    e->in_use = 0;
    e->guest = NULL;
    pthread_mutex_unlock(&g_zlib_lock);
}

static void zlib_sync_in(Bo3ZlibEntry *e) {
    e->host.next_in   = e->guest->next_in;
    e->host.avail_in  = e->guest->avail_in;
    e->host.total_in  = e->guest->total_in;
    e->host.next_out  = e->guest->next_out;
    e->host.avail_out = e->guest->avail_out;
    e->host.total_out = e->guest->total_out;
    e->host.data_type = e->guest->data_type;
    e->host.adler     = e->guest->adler;
}

static void zlib_sync_out(Bo3ZlibEntry *e) {
    e->guest->next_in   = e->host.next_in;
    e->guest->avail_in  = e->host.avail_in;
    e->guest->total_in  = e->host.total_in;
    e->guest->next_out  = e->host.next_out;
    e->guest->avail_out = e->host.avail_out;
    e->guest->total_out = e->host.total_out;
    e->guest->msg       = e->host.msg;
    e->guest->state     = e->host.state;
    e->guest->data_type = e->host.data_type;
    e->guest->adler     = e->host.adler;
}

SHIM_DEF(shim__inflateInit2_) {
    SHIM_UNUSED_ALL();
    z_streamp g = (z_streamp)rdi;
    if (!g) return ret_i64(Z_STREAM_ERROR);
    Bo3ZlibEntry *e = zlib_alloc_entry(g);
    if (!e) return ret_i64(Z_MEM_ERROR);
    zlib_sync_in(e);
    Bo3ZlibScope zs = zlib_scope_enter(ctx, rsp);
    int rc = inflateInit2_(&e->host, (int)rsi, (const char *)rdx, (int)rcx);
    zlib_scope_leave(zs);
    zlib_sync_out(e);
    if (rc != Z_OK) zlib_release_entry(e);
    return ret_i64(rc);
}
SHIM_DEF(shim__inflate) {
    SHIM_UNUSED_ALL();
    Bo3ZlibEntry *e = zlib_find((z_streamp)rdi);
    if (!e) return ret_i64(Z_STREAM_ERROR);
    zlib_sync_in(e);
    Bo3ZlibScope zs = zlib_scope_enter(ctx, rsp);
    int rc = inflate(&e->host, (int)rsi);
    zlib_scope_leave(zs);
    zlib_sync_out(e);
    return ret_i64(rc);
}
SHIM_DEF(shim__inflateEnd) {
    SHIM_UNUSED_ALL();
    Bo3ZlibEntry *e = zlib_find((z_streamp)rdi);
    if (!e) return ret_i64(Z_STREAM_ERROR);
    zlib_sync_in(e);
    Bo3ZlibScope zs = zlib_scope_enter(ctx, rsp);
    int rc = inflateEnd(&e->host);
    zlib_scope_leave(zs);
    zlib_sync_out(e);
    zlib_release_entry(e);
    return ret_i64(rc);
}
SHIM_DEF(shim__deflateInit2_) {
    SHIM_UNUSED_ALL();
    z_streamp g = (z_streamp)rdi;
    if (!g) return ret_i64(Z_STREAM_ERROR);
    Bo3ZlibEntry *e = zlib_alloc_entry(g);
    if (!e) return ret_i64(Z_MEM_ERROR);
    zlib_sync_in(e);
    const char *ver = (const char *)shim_stack_u64(rsp, 0);
    int stream_sz = (int)shim_stack_u64(rsp, 1);
    Bo3ZlibScope zs = zlib_scope_enter(ctx, rsp);
    int rc = deflateInit2_(&e->host, (int)rsi, (int)rdx, (int)rcx, (int)r8, (int)r9, ver, stream_sz);
    zlib_scope_leave(zs);
    zlib_sync_out(e);
    if (rc != Z_OK) zlib_release_entry(e);
    return ret_i64(rc);
}
SHIM_DEF(shim__deflate) {
    SHIM_UNUSED_ALL();
    Bo3ZlibEntry *e = zlib_find((z_streamp)rdi);
    if (!e) return ret_i64(Z_STREAM_ERROR);
    zlib_sync_in(e);
    Bo3ZlibScope zs = zlib_scope_enter(ctx, rsp);
    int rc = deflate(&e->host, (int)rsi);
    zlib_scope_leave(zs);
    zlib_sync_out(e);
    return ret_i64(rc);
}
SHIM_DEF(shim__deflateEnd) {
    SHIM_UNUSED_ALL();
    Bo3ZlibEntry *e = zlib_find((z_streamp)rdi);
    if (!e) return ret_i64(Z_STREAM_ERROR);
    zlib_sync_in(e);
    Bo3ZlibScope zs = zlib_scope_enter(ctx, rsp);
    int rc = deflateEnd(&e->host);
    zlib_scope_leave(zs);
    zlib_sync_out(e);
    zlib_release_entry(e);
    return ret_i64(rc);
}
SHIM_DEF(shim__deflateReset) {
    SHIM_UNUSED_ALL();
    Bo3ZlibEntry *e = zlib_find((z_streamp)rdi);
    if (!e) return ret_i64(Z_STREAM_ERROR);
    zlib_sync_in(e);
    Bo3ZlibScope zs = zlib_scope_enter(ctx, rsp);
    int rc = deflateReset(&e->host);
    zlib_scope_leave(zs);
    zlib_sync_out(e);
    return ret_i64(rc);
}
SHIM_DEF(shim__deflateBound) {
    SHIM_UNUSED_ALL();
    Bo3ZlibEntry *e = zlib_find((z_streamp)rdi);
    return ret_u64(deflateBound(e ? &e->host : NULL, (uLong)rsi));
}
SHIM_DEF(shim__compressBound) { SHIM_UNUSED_ALL(); return ret_u64(compressBound((uLong)rdi)); }
SHIM_DEF(shim__uncompress)    { SHIM_UNUSED_ALL(); return ret_i64(uncompress((Bytef *)rdi, (uLongf *)rsi, (const Bytef *)rdx, (uLong)rcx)); }

// ===================== LIBCURL (16 syms -> native ARM64 -lcurl, online or BO3ARM_OFFLINE=1) =====================
// Default (online): real HTTPS via native ARM64 libcurl with per-handle guest READ/WRITE callback
// trampolines, MacFix Demonware Content-Length framing fix at return PC 0x101593461, and exact
// 4-byte CURLINFO_RESPONSE_CODE narrowing.
// When BO3ARM_OFFLINE=1: hard-offline mode (loopback URL + refused sockets -> CURLE_COULDNT_CONNECT).
#define BO3_CURL_OFFLINE_URL "http://127.0.0.1:9/"

static int bo3_offline_mode(void) {
    return bo3_settings_offline_mode() ? 1 : 0;
}

typedef struct Bo3CurlEntry {
    CURL    *easy;
    uint64_t write_fn_va;
    uint64_t write_data;
    uint64_t read_fn_va;
    uint64_t read_data;
    int      in_use;
} Bo3CurlEntry;

#define BO3_MAX_CURL_HANDLES 128
static pthread_mutex_t g_curl_lock = PTHREAD_MUTEX_INITIALIZER;
static Bo3CurlEntry    g_curl_entries[BO3_MAX_CURL_HANDLES];

static __thread GuestContext *g_curl_ctx = NULL;
static __thread uint64_t      g_curl_rsp = 0;

typedef struct Bo3CurlScope { GuestContext *ctx; uint64_t rsp; } Bo3CurlScope;
static inline Bo3CurlScope curl_scope_enter(GuestContext *ctx, uint64_t rsp) {
    Bo3CurlScope saved = { g_curl_ctx, g_curl_rsp };
    g_curl_ctx = ctx;
    g_curl_rsp = rsp;
    return saved;
}
static inline void curl_scope_leave(Bo3CurlScope saved) {
    g_curl_ctx = saved.ctx;
    g_curl_rsp = saved.rsp;
}

static Bo3CurlEntry *curl_alloc_entry(CURL *c) {
    if (!c) return NULL;
    pthread_mutex_lock(&g_curl_lock);
    Bo3CurlEntry *slot = NULL;
    for (int i = 0; i < BO3_MAX_CURL_HANDLES; i++) {
        if (g_curl_entries[i].in_use && g_curl_entries[i].easy == c) {
            slot = &g_curl_entries[i];
            break;
        }
        if (!g_curl_entries[i].in_use && !slot) slot = &g_curl_entries[i];
    }
    if (slot) {
        memset(slot, 0, sizeof(*slot));
        slot->in_use = 1;
        slot->easy = c;
    } else {
        fprintf(stderr, "[curl] active handle table full!\n");
    }
    pthread_mutex_unlock(&g_curl_lock);
    return slot;
}

// Detach the entry from lookup BEFORE curl_easy_cleanup() so another thread reusing the freed
// CURL* address cannot collide with this entry, while keeping in_use=1 until cleanup finishes.
static Bo3CurlEntry *curl_detach_entry(CURL *c) {
    if (!c) return NULL;
    pthread_mutex_lock(&g_curl_lock);
    Bo3CurlEntry *found = NULL;
    for (int i = 0; i < BO3_MAX_CURL_HANDLES; i++) {
        if (g_curl_entries[i].in_use && g_curl_entries[i].easy == c) {
            g_curl_entries[i].easy = NULL;
            found = &g_curl_entries[i];
            break;
        }
    }
    pthread_mutex_unlock(&g_curl_lock);
    return found;
}

static void curl_free_detached_entry(Bo3CurlEntry *e) {
    if (!e) return;
    pthread_mutex_lock(&g_curl_lock);
    memset(e, 0, sizeof(*e));
    pthread_mutex_unlock(&g_curl_lock);
}

static void curl_set_entry_field(CURL *c, int opt, uint64_t val) {
    if (!c) return;
    pthread_mutex_lock(&g_curl_lock);
    for (int i = 0; i < BO3_MAX_CURL_HANDLES; i++) {
        Bo3CurlEntry *e = &g_curl_entries[i];
        if (e->in_use && e->easy == c) {
            if (opt == CURLOPT_WRITEFUNCTION)     e->write_fn_va = val;
            else if (opt == CURLOPT_WRITEDATA)    e->write_data  = val;
            else if (opt == CURLOPT_READFUNCTION) e->read_fn_va  = val;
            else if (opt == CURLOPT_READDATA)     e->read_data   = val;
            break;
        }
    }
    pthread_mutex_unlock(&g_curl_lock);
}

static size_t bo3_curl_write_trampoline(char *ptr, size_t sz, size_t nmemb, void *userdata) {
    Bo3CurlEntry *e = (Bo3CurlEntry *)userdata;
    uint64_t fn_va = 0, opaque = 0;
    if (e) {
        pthread_mutex_lock(&g_curl_lock);
        if (e->in_use) {
            fn_va = e->write_fn_va;
            opaque = e->write_data;
        }
        pthread_mutex_unlock(&g_curl_lock);
    }
    if (!fn_va || !g_curl_ctx) return sz * nmemb;
    GuestFn fn = bo3_resolve(fn_va, g_curl_ctx);
    uint64_t sp = ((g_curl_rsp - 128) & ~15ULL) - 8;
    *(uint64_t *)(uintptr_t)sp = 0;
    GuestRet r = fn(g_curl_ctx, sp,
                    (uint64_t)(uintptr_t)ptr, (uint64_t)sz, (uint64_t)nmemb, opaque,
                    0, 0,
                    guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
                    guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    return (size_t)r.rax_rdx[0];
}

static size_t bo3_curl_read_trampoline(char *buf, size_t sz, size_t nmemb, void *userdata) {
    Bo3CurlEntry *e = (Bo3CurlEntry *)userdata;
    uint64_t fn_va = 0, opaque = 0;
    if (e) {
        pthread_mutex_lock(&g_curl_lock);
        if (e->in_use) {
            fn_va = e->read_fn_va;
            opaque = e->read_data;
        }
        pthread_mutex_unlock(&g_curl_lock);
    }
    if (!fn_va || !g_curl_ctx) return 0;
    GuestFn fn = bo3_resolve(fn_va, g_curl_ctx);
    uint64_t sp = ((g_curl_rsp - 128) & ~15ULL) - 8;
    *(uint64_t *)(uintptr_t)sp = 0;
    GuestRet r = fn(g_curl_ctx, sp,
                    (uint64_t)(uintptr_t)buf, (uint64_t)sz, (uint64_t)nmemb, opaque,
                    0, 0,
                    guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
                    guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    return (size_t)r.rax_rdx[0];
}

static size_t curl_offline_sink(void *ptr, size_t sz, size_t nmemb, void *userdata) {
    (void)ptr; (void)userdata;
    return sz * nmemb; // discard, report everything consumed
}
static size_t curl_offline_read(char *buf, size_t sz, size_t nmemb, void *userdata) {
    (void)buf; (void)sz; (void)nmemb; (void)userdata;
    return 0; // empty upload body: EOF immediately (never stdin)
}
static curl_socket_t curl_offline_opensocket(void *clientp, curlsocktype purpose, struct curl_sockaddr *addr) {
    (void)clientp; (void)purpose; (void)addr;
    return CURL_SOCKET_BAD; // -> CURLE_COULDNT_CONNECT, no socket is ever created
}

static void curl_install_offline_defaults(CURL *c) {
    if (!c) return;
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, curl_offline_sink);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, NULL);
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, curl_offline_sink);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, NULL);
    curl_easy_setopt(c, CURLOPT_READFUNCTION, curl_offline_read);
    curl_easy_setopt(c, CURLOPT_READDATA, NULL);
    curl_easy_setopt(c, CURLOPT_OPENSOCKETFUNCTION, curl_offline_opensocket);
    curl_easy_setopt(c, CURLOPT_OPENSOCKETDATA, NULL);
    curl_easy_setopt(c, CURLOPT_NOPROGRESS, 1L);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_PROXY, "");
    curl_easy_setopt(c, CURLOPT_NOPROXY, "*");
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT_MS, 250L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT_MS, 1000L);
    curl_easy_setopt(c, CURLOPT_URL, BO3_CURL_OFFLINE_URL);
}

static void curl_install_online_defaults(CURL *c, Bo3CurlEntry *e) {
    if (!c) return;
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, bo3_curl_write_trampoline);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, e);
    curl_easy_setopt(c, CURLOPT_READFUNCTION, bo3_curl_read_trampoline);
    curl_easy_setopt(c, CURLOPT_READDATA, e);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
}

SHIM_DEF(shim__curl_global_init_mem) {
    SHIM_UNUSED_ALL();
    // Guest malloc/free/realloc/strdup/calloc callbacks are guest VAs: never hand them to libcurl.
    return ret_i64(curl_global_init((long)rdi));
}
SHIM_DEF(shim__curl_global_cleanup) { SHIM_UNUSED_ALL(); curl_global_cleanup(); return ret_void(); }
SHIM_DEF(shim__curl_version_info)   { SHIM_UNUSED_ALL(); return ret_ptr(curl_version_info((CURLversion)rdi)); }
SHIM_DEF(shim__curl_easy_init) {
    SHIM_UNUSED_ALL();
    CURL *c = curl_easy_init();
    if (!c) return ret_ptr(NULL);
    if (bo3_offline_mode()) {
        curl_install_offline_defaults(c);
    } else {
        Bo3CurlEntry *e = curl_alloc_entry(c);
        if (!e) {
            curl_easy_cleanup(c);
            return ret_ptr(NULL);
        }
        curl_install_online_defaults(c, e);
    }
    return ret_ptr(c);
}
SHIM_DEF(shim__curl_easy_cleanup) {
    SHIM_UNUSED_ALL();
    CURL *c = (CURL *)(uintptr_t)rdi;
    Bo3CurlEntry *detached = bo3_offline_mode() ? NULL : curl_detach_entry(c);
    Bo3CurlScope cs = curl_scope_enter(ctx, rsp);
    curl_easy_cleanup(c);
    curl_scope_leave(cs);
    if (detached) curl_free_detached_entry(detached);
    return ret_void();
}
SHIM_DEF(shim__curl_easy_strerror)  { SHIM_UNUSED_ALL(); return ret_ptr(curl_easy_strerror((CURLcode)rdi)); }
SHIM_DEF(shim__curl_slist_append) {
    SHIM_UNUSED_ALL();
    struct curl_slist *list = (struct curl_slist *)(uintptr_t)rdi;
    const char *hdr = (const char *)(uintptr_t)rsi;
    if (!bo3_offline_mode() && hdr && rsp) {
        // MacFix parity: in g_101593310 (return PC 0x101593461) and its sibling g_101592df0
        // (return PC 0x1015931d1), BO3 appends a manual "Content-Length: %d" to a callback POST
        // that modern macOS libcurl frames as Transfer-Encoding: chunked, breaking Demonware.
        uint64_t ret_pc = *(const uint64_t *)(uintptr_t)rsp;
        if ((ret_pc == 0x101593461ULL || ret_pc == 0x1015931d1ULL) &&
            strncasecmp(hdr, "Content-Length:", 15) == 0) {
            return ret_ptr(list);
        }
    }
    return ret_ptr(curl_slist_append(list, hdr));
}
SHIM_DEF(shim__curl_slist_free_all) { SHIM_UNUSED_ALL(); curl_slist_free_all((struct curl_slist *)rdi); return ret_void(); }

SHIM_DEF(shim__curl_easy_setopt) {
    SHIM_UNUSED_ALL();
    CURL *c = (CURL *)(uintptr_t)rdi;
    int opt = (int)rsi;
    if (bo3_offline_mode()) {
        // Hard-offline mode: rewrite URL to loopback and allow only safe metadata options.
        switch (opt) {
            case CURLOPT_URL:
                return ret_i64(curl_easy_setopt(c, CURLOPT_URL, BO3_CURL_OFFLINE_URL));
            case CURLOPT_HTTPHEADER:
                return ret_i64(curl_easy_setopt(c, CURLOPT_HTTPHEADER, (struct curl_slist *)(uintptr_t)rdx));
            case CURLOPT_CUSTOMREQUEST:
            case CURLOPT_USERAGENT:
            case CURLOPT_REFERER:
            case CURLOPT_ACCEPT_ENCODING:
            case CURLOPT_POSTFIELDS:
            case CURLOPT_COPYPOSTFIELDS:
                return ret_i64(curl_easy_setopt(c, (CURLoption)opt, (const char *)(uintptr_t)rdx));
            case CURLOPT_POSTFIELDSIZE_LARGE:
            case CURLOPT_INFILESIZE_LARGE:
                return ret_i64(curl_easy_setopt(c, (CURLoption)opt, (curl_off_t)rdx));
            case CURLOPT_POSTFIELDSIZE:
            case CURLOPT_INFILESIZE:
                return ret_i64(curl_easy_setopt(c, (CURLoption)opt, (long)(int32_t)rdx));
            case CURLOPT_HTTPGET:
            case CURLOPT_POST:
            case CURLOPT_UPLOAD:
            case CURLOPT_NOBODY:
            case CURLOPT_HEADER:
            case CURLOPT_FAILONERROR:
            case CURLOPT_HTTP_VERSION:
                return ret_i64(curl_easy_setopt(c, (CURLoption)opt, (long)rdx));
            default:
                return ret_i64(CURLE_OK);
        }
    }

    // Online mode: full ABI-checked forwarding for all observed BO3 options + guest callback wrappers.
    switch (opt) {
        case CURLOPT_WRITEFUNCTION:
        case CURLOPT_WRITEDATA:
        case CURLOPT_READFUNCTION:
        case CURLOPT_READDATA:
            curl_set_entry_field(c, opt, rdx);
            return ret_i64(CURLE_OK);
        case CURLOPT_URL:
        case CURLOPT_CUSTOMREQUEST:
        case CURLOPT_USERAGENT:
        case CURLOPT_REFERER:
        case CURLOPT_ACCEPT_ENCODING:
        case CURLOPT_POSTFIELDS:
        case CURLOPT_COPYPOSTFIELDS:
            return ret_i64(curl_easy_setopt(c, (CURLoption)opt, (const char *)(uintptr_t)rdx));
        case CURLOPT_ERRORBUFFER:
            return ret_i64(curl_easy_setopt(c, CURLOPT_ERRORBUFFER, (char *)(uintptr_t)rdx));
        case CURLOPT_HTTPHEADER:
            return ret_i64(curl_easy_setopt(c, CURLOPT_HTTPHEADER, (struct curl_slist *)(uintptr_t)rdx));
        case CURLOPT_INFILESIZE_LARGE:
        case CURLOPT_POSTFIELDSIZE_LARGE:
            return ret_i64(curl_easy_setopt(c, (CURLoption)opt, (curl_off_t)rdx));
        case CURLOPT_DNS_CACHE_TIMEOUT:
        case CURLOPT_POSTFIELDSIZE:
        case CURLOPT_INFILESIZE:
        case CURLOPT_CONNECTTIMEOUT:
        case CURLOPT_CONNECTTIMEOUT_MS:
        case CURLOPT_TIMEOUT:
        case CURLOPT_TIMEOUT_MS:
            // Guest passes 32-bit signed ints (e.g. -1 in edx, zero-extended in rdx); sign-extend to long.
            return ret_i64(curl_easy_setopt(c, (CURLoption)opt, (long)(int32_t)rdx));
        case 54: // CURLOPT_PUT (deprecated constant name; raw value avoids -Wdeprecated-declarations)
            return ret_i64(curl_easy_setopt(c, CURLOPT_UPLOAD, (long)rdx));
        case CURLOPT_VERBOSE:
        case CURLOPT_HEADER:
        case CURLOPT_NOPROGRESS:
        case CURLOPT_NOBODY:
        case CURLOPT_FAILONERROR:
        case CURLOPT_UPLOAD:
        case CURLOPT_POST:
        case CURLOPT_FOLLOWLOCATION:
        case CURLOPT_SSL_VERIFYPEER:
        case CURLOPT_SSL_VERIFYHOST:
        case CURLOPT_HTTPGET:
        case CURLOPT_HTTP_VERSION:
        case CURLOPT_NOSIGNAL:
            return ret_i64(curl_easy_setopt(c, (CURLoption)opt, (long)rdx));
        default:
            fprintf(stderr, "[curl] unhandled setopt=%d val=0x%llx\n", opt, (unsigned long long)rdx);
            return ret_i64(CURLE_OK);
    }
}
SHIM_DEF(shim__curl_easy_getinfo) {
    SHIM_UNUSED_ALL();
    CURL *c = (CURL *)(uintptr_t)rdi;
    int info = (int)rsi;
    if (info == (int)CURLINFO_RESPONSE_CODE) {
        // Guest stores response code into an int32_t ([rbp-0x44]); native libcurl writes 8-byte long.
        long code = 0;
        CURLcode rc = curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
        if (rc == CURLE_OK && rdx) {
            int32_t code32 = (int32_t)code;
            memcpy((void *)(uintptr_t)rdx, &code32, sizeof(code32));
        }
        return ret_i64(rc);
    }
    if (info == 0x30000f /* CURLINFO_CONTENT_LENGTH_DOWNLOAD */) {
        double d = 0.0;
        CURLcode rc = curl_easy_getinfo(c, (CURLINFO)info, &d);
        if (rc == CURLE_OK && rdx) {
            memcpy((void *)(uintptr_t)rdx, &d, sizeof(d));
        }
        return ret_i64(rc);
    }
    return ret_i64(curl_easy_getinfo(c, (CURLINFO)info, (void *)(uintptr_t)rdx));
}
SHIM_DEF(shim__curl_multi_init)          { SHIM_UNUSED_ALL(); return ret_ptr(curl_multi_init()); }
SHIM_DEF(shim__curl_multi_cleanup) {
    SHIM_UNUSED_ALL();
    Bo3CurlScope cs = curl_scope_enter(ctx, rsp);
    CURLMcode rc = curl_multi_cleanup((CURLM *)(uintptr_t)rdi);
    curl_scope_leave(cs);
    return ret_i64(rc);
}
SHIM_DEF(shim__curl_multi_add_handle)    { SHIM_UNUSED_ALL(); return ret_i64(curl_multi_add_handle((CURLM *)rdi, (CURL *)rsi)); }
SHIM_DEF(shim__curl_multi_remove_handle) {
    SHIM_UNUSED_ALL();
    Bo3CurlScope cs = curl_scope_enter(ctx, rsp);
    CURLMcode rc = curl_multi_remove_handle((CURLM *)(uintptr_t)rdi, (CURL *)(uintptr_t)rsi);
    curl_scope_leave(cs);
    return ret_i64(rc);
}
SHIM_DEF(shim__curl_multi_perform) {
    SHIM_UNUSED_ALL();
    Bo3CurlScope cs = curl_scope_enter(ctx, rsp);
    CURLMcode rc = curl_multi_perform((CURLM *)(uintptr_t)rdi, (int *)(uintptr_t)rsi);
    curl_scope_leave(cs);
    return ret_i64(rc);
}
// CURLMsg { CURLMSG msg; CURL *easy_handle; union { void *whatever; CURLcode result; } } is ABI-identical.
SHIM_DEF(shim__curl_multi_info_read)     { SHIM_UNUSED_ALL(); return ret_ptr(curl_multi_info_read((CURLM *)rdi, (int *)rsi)); }

// ===================== ObjC / CoreVideo / CoreMedia / Blocks (cutscene stubs) =====================
SHIM_DEF(shim__objc_msgSend)                   { SHIM_UNUSED_ALL(); return ret_u64(0); }

// x86_64 objc_msgSend_stret(void *sret, id self, SEL op, ...): the struct is returned through the
// hidden sret pointer in rdi, and rax must hold that pointer. The struct size is not passed, so
// it is derived from the selector name (guest SELs are pointers to their C-string names):
// CGRect-returning selectors get 32 bytes; everything else (CMTime/CMTimeRange-sized) gets 24.
static size_t objc_stret_size_for_sel(uint64_t sel) {
    if (sel < 0x100000000ULL) return 24;
    const char *name = (const char *)(uintptr_t)sel;
    static const char *const rect_sels[] = {
        "frame", "bounds", "visibleFrame", "contentLayoutRect", "rectValue",
        "contentRectForFrameRect:", "frameRectForContentRect:", "convertRectToBacking:",
        "convertRectFromBacking:", "convertRectToScreen:", "convertRectFromScreen:",
        "convertRect:toView:", "convertRect:fromView:", "videoRect", "cropRectangle",
    };
    for (size_t i = 0; i < sizeof(rect_sels) / sizeof(rect_sels[0]); i++) {
        if (strcmp(name, rect_sels[i]) == 0) return 32;
    }
    if (strcmp(name, "timeRange") == 0) return 48; // CMTimeRange
    return 24;
}
SHIM_DEF(shim__objc_msgSend_stret) {
    SHIM_UNUSED_ALL();
    if (rdi) memset((void *)rdi, 0, objc_stret_size_for_sel(rdx));
    return ret_u64(rdi);
}
SHIM_DEF(shim__objc_enumerationMutation)       { SHIM_UNUSED_ALL(); return ret_void(); }
SHIM_DEF(shim__NSLog)                          { SHIM_UNUSED_ALL(); return ret_void(); }
SHIM_DEF(shim___Block_object_assign)           { SHIM_UNUSED_ALL(); return ret_void(); }
SHIM_DEF(shim___Block_object_dispose)          { SHIM_UNUSED_ALL(); return ret_void(); }

// dispatch_sync(queue, block): run the guest block inline on the calling thread (synchronous
// semantics preserved). Guest Block_layout: { isa @0, flags @8, reserved @12, invoke @0x10 }.
SHIM_DEF(shim__dispatch_sync) {
    SHIM_UNUSED_ALL();
    uint64_t blk = rsi;
    if (!blk) return ret_void();
    uint64_t invoke_va = *(const uint64_t *)(uintptr_t)(blk + 0x10);
    if (!invoke_va) return ret_void();
    GuestFn fn = bo3_resolve(invoke_va, ctx);
    uint64_t sp = (rsp - 128) & ~15ULL; // stay below the caller's red zone
    sp -= 8; *(uint64_t *)(uintptr_t)sp = 0;
    fn(ctx, sp, blk, 0, 0, 0, 0, 0,
       guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
       guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    return ret_void();
}
static pthread_once_t g_ca_time_once = PTHREAD_ONCE_INIT;
static mach_timebase_info_data_t g_ca_timebase = {1, 1};

static void ca_time_init(void) {
    mach_timebase_info_data_t tb;
    if (mach_timebase_info(&tb) == KERN_SUCCESS && tb.numer && tb.denom) g_ca_timebase = tb;
}

SHIM_DEF(shim__CACurrentMediaTime) {
    SHIM_UNUSED_ALL();
    pthread_once(&g_ca_time_once, ca_time_init);
    double sec = (double)mach_absolute_time() * g_ca_timebase.numer / g_ca_timebase.denom * 1e-9;
    return ret_f64(sec);
}

// CMTime { int64 value @0; int32 timescale @8; uint32 flags @12; int64 epoch @16 } (24 bytes)
typedef struct Bo3CMTime { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } Bo3CMTime;
_Static_assert(sizeof(Bo3CMTime) == 24, "CMTime must be 24 bytes");
#define BO3_CMTIME_VALID      1u
#define BO3_CMTIME_POS_INF    4u
#define BO3_CMTIME_NEG_INF    8u
#define BO3_CMTIME_INDEFINITE 16u

// Float64 CMTimeGetSeconds(CMTime t): 24-byte struct is passed in memory on the x86_64 stack.
SHIM_DEF(shim__CMTimeGetSeconds) {
    SHIM_UNUSED_ALL();
    Bo3CMTime t;
    memcpy(&t, (const void *)(uintptr_t)(rsp + 8ULL), sizeof(t));
    if (!(t.flags & BO3_CMTIME_VALID) || (t.flags & BO3_CMTIME_INDEFINITE)) return ret_f64(NAN);
    if (t.flags & BO3_CMTIME_POS_INF) return ret_f64(INFINITY);
    if (t.flags & BO3_CMTIME_NEG_INF) return ret_f64(-INFINITY);
    if (t.timescale <= 0) return ret_f64(NAN);
    return ret_f64((double)t.value / (double)t.timescale);
}
// CMTime CMTimeMakeWithSeconds(Float64 seconds, int32_t preferredTimescale):
// hidden sret pointer in rdi, seconds in xmm0, timescale in esi; returns rax = rdi.
SHIM_DEF(shim__CMTimeMakeWithSeconds) {
    SHIM_UNUSED_ALL();
    Bo3CMTime t = {0, 0, 0, 0}; // kCMTimeInvalid
    double secs = xmm_to_f64(xmm0);
    int32_t ts = (int32_t)rsi;
    if (ts > 0 && !isnan(secs)) {
        if (isinf(secs)) {
            t.flags = BO3_CMTIME_VALID | (secs > 0 ? BO3_CMTIME_POS_INF : BO3_CMTIME_NEG_INF);
        } else {
            double v = round(secs * (double)ts);
            if (v >= 9.2233720368547758e18) t.flags = BO3_CMTIME_VALID | BO3_CMTIME_POS_INF;
            else if (v <= -9.2233720368547758e18) t.flags = BO3_CMTIME_VALID | BO3_CMTIME_NEG_INF;
            else { t.value = (int64_t)v; t.timescale = ts; t.flags = BO3_CMTIME_VALID; }
        }
    }
    if (rdi) memcpy((void *)(uintptr_t)rdi, &t, sizeof(t));
    return ret_u64(rdi);
}
SHIM_DEF(shim__CVPixelBufferLockBaseAddress)   { SHIM_UNUSED_ALL(); return ret_i64(0); }
SHIM_DEF(shim__CVPixelBufferUnlockBaseAddress) { SHIM_UNUSED_ALL(); return ret_i64(0); }
SHIM_DEF(shim__CVPixelBufferGetBaseAddressOfPlane)   { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(shim__CVPixelBufferGetBytesPerRowOfPlane)   { SHIM_UNUSED_ALL(); return ret_u64(0); }

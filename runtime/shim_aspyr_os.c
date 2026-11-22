// Core Aspyr Win32/OS shims + M2 bootstrap entry point (bo3_recomp_main).
// Strong definitions here override the weak tracing stubs in gen_aspyr_weak.c!

#include "shim_helpers.h"
#include <errno.h>
#include <execinfo.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

extern void bo3_register_all_functions(void);
extern void bo3_register_extra_shards(void);
extern void bo3_apply_data_binds(void);
extern void bo3_init_steam_mocks(void);
extern void bo3_init_win32_mocks(void);
extern void bo3_metal_init_all(void);
extern void bo3_metal_set_debug_marker(const char *name);
extern void bo3_metal_set_shader_name(const char *name);
extern int  bo3_mac_run_with_guest(int (*guest_fn)(int, char **), int argc, char **argv);
extern const uint64_t g_bo3_engine_init_funcs[];
extern const size_t g_bo3_engine_init_count;

// Unified atomic Win32/POSIX thread ID allocator (stored in Aspyr TLV 0x102104e20)
static volatile uint32_t g_unified_next_tid = 2;
uint32_t bo3_alloc_tid(void) {
    return __atomic_fetch_add(&g_unified_next_tid, 1, __ATOMIC_RELAXED);
}
uint32_t bo3_init_thread_tid(GuestContext *ctx, uint32_t forced_tid) {
    uint32_t *slot = (uint32_t *)bo3_tlv_get_addr(ctx, (void *)0x102104e20ULL);
    uint32_t tid = forced_tid ? forced_tid : bo3_alloc_tid();
    *slot = tid;
    return tid;
}

// Current thread's unified TID, lazily allocated if this host thread never got one
// (e.g. a host/AppKit thread or a thread whose TLV was set up without bo3_init_thread_tid).
uint32_t bo3_current_tid(GuestContext *ctx) {
    uint32_t *slot = (uint32_t *)bo3_tlv_get_addr(ctx, (void *)0x102104e20ULL);
    uint32_t tid = __atomic_load_n(slot, __ATOMIC_RELAXED);
    if (tid == 0) {
        tid = bo3_alloc_tid();
        __atomic_store_n(slot, tid, __ATOMIC_RELAXED);
    }
    return tid;
}

// Thread-local Win32 LastError (stored in exact Mach-O TLV slot 0x102104df0)
uint32_t *bo3_last_error_ptr(GuestContext *ctx) {
    return (uint32_t *)bo3_tlv_get_addr(ctx, (void *)0x102104df0ULL);
}
void bo3_set_last_error(GuestContext *ctx, uint32_t err) {
    *bo3_last_error_ptr(ctx) = err;
}

// From shim_libsystem.c
typedef struct X86VaCursor {
    int      from_valist;
    uint64_t gp_regs[6];
    double   fp_regs[8];
    int      gp_idx;
    int      fp_idx;
    const uint64_t *overflow;
    uint32_t gp_off;
    uint32_t fp_off;
    const uint8_t *ov_ptr;
    const uint8_t *rs_ptr;
} X86VaCursor;
extern int bo3_x86_vsnprintf(char *dst, size_t dst_sz, const char *fmt, X86VaCursor *va);
extern int bo3_x86_vsnprintf_unterminated(char *dst, size_t dst_sz, const char *fmt, X86VaCursor *va);

// ===================== Mach-O TLV Block Allocator =====================
void *bo3_alloc_thread_tlv(void) {
    uint8_t *blk = (uint8_t *)calloc(1, 2048);
    if (!blk) abort();
    memcpy(blk, (const void *)0x102105080ULL, 9);
    return blk;
}
void bo3_free_thread_tlv(void *tlv) {
    free(tlv);
}

// ===================== Core Aspyr Win32/OS Shims =====================

// 0x1000039d0: ___clang_call_terminate
SHIM_DEF(g_1000039d0) {
    SHIM_UNUSED_ALL();
    fprintf(stderr, "[aspyr] ___clang_call_terminate (0x1000039d0)\n");
    abort();
}

// 0x100044c36 / 0x1000fbca2: dummy return 0
SHIM_DEF(g_100044c36) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1000fbca2) { SHIM_UNUSED_ALL(); return ret_u64(0); }

// 0x1000d9590 / 0x1000d95db: debug marker / shader name setters
SHIM_DEF(g_1000d9590) {
    SHIM_UNUSED_ALL();
    char *dst = (char *)0x1021058c0ULL;
    if (rdi) {
        strncpy(dst, (const char *)rdi, 0x400);
        dst[0x3ff] = 0;
        bo3_metal_set_debug_marker(dst);
    } else {
        dst[0] = 0;
        bo3_metal_set_debug_marker("");
    }
    return ret_void();
}
SHIM_DEF(g_1000d95db) {
    SHIM_UNUSED_ALL();
    char *dst = (char *)0x102105cc0ULL;
    if (rdi) {
        strncpy(dst, (const char *)rdi, 0x400);
        dst[0x3ff] = 0;
        for (size_t i = 0; dst[i]; i++) if (dst[i] == '/') dst[i] = '_';
        bo3_metal_set_shader_name(dst);
    } else {
        dst[0] = 0;
        bo3_metal_set_shader_name("");
    }
    return ret_void();
}

// ---- Atomics & BitScans (0x100109*) ----
SHIM_DEF(g_100109a36) { SHIM_UNUSED_ALL(); return ret_u64((uint32_t)__atomic_sub_fetch((volatile int32_t *)rdi, 1, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_100109ac0) { SHIM_UNUSED_ALL(); return ret_u64((uint32_t)__atomic_add_fetch((volatile int32_t *)rdi, 1, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_100109a4d) { SHIM_UNUSED_ALL(); return ret_u64((uint32_t)__atomic_exchange_n((volatile int32_t *)rdi, (int32_t)rsi, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_100109a63) { SHIM_UNUSED_ALL(); return ret_u64(__atomic_exchange_n((volatile uint64_t *)rdi, rsi, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_100109a93) { SHIM_UNUSED_ALL(); return ret_u64((uint32_t)__atomic_fetch_add((volatile int32_t *)rdi, (int32_t)rsi, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_100109aad) { SHIM_UNUSED_ALL(); return ret_i64(__atomic_fetch_add((volatile int64_t *)rdi, (int64_t)rsi, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_1001099fa) {
    SHIM_UNUSED_ALL();
    int32_t expected = (int32_t)rdx;
    __atomic_compare_exchange_n((volatile int32_t *)rdi, &expected, (int32_t)rsi, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return ret_u64((uint32_t)expected);
}
SHIM_DEF(g_100109a0b) {
    SHIM_UNUSED_ALL();
    int64_t expected = (int64_t)rdx;
    __atomic_compare_exchange_n((volatile int64_t *)rdi, &expected, (int64_t)rsi, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return ret_i64(expected);
}
SHIM_DEF(g_100109a1f) {
    SHIM_UNUSED_ALL();
    int64_t expected = (int64_t)rdx;
    __atomic_compare_exchange_n((volatile int64_t *)rdi, &expected, (int64_t)rsi, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return ret_i64(expected);
}
SHIM_DEF(g_100109aef) { SHIM_UNUSED_ALL(); return ret_u64(__atomic_fetch_or((volatile uint32_t *)rdi, (uint32_t)rsi, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_100109b07) { SHIM_UNUSED_ALL(); return ret_u64(__atomic_fetch_or((volatile uint64_t *)rdi, rsi, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_1001099c9) { SHIM_UNUSED_ALL(); return ret_u64(__atomic_fetch_and((volatile uint32_t *)rdi, (uint32_t)rsi, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_1001099e1) { SHIM_UNUSED_ALL(); return ret_u64(__atomic_fetch_and((volatile uint64_t *)rdi, rsi, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_100109a7b) { SHIM_UNUSED_ALL(); return ret_u64(__atomic_exchange_n((volatile uint64_t *)rdi, rsi, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_100109ad4) { SHIM_UNUSED_ALL(); return ret_i64(__atomic_add_fetch((volatile int64_t *)rdi, 1, __ATOMIC_SEQ_CST)); }
SHIM_DEF(g_100109b25) { SHIM_UNUSED_ALL(); __atomic_thread_fence(__ATOMIC_SEQ_CST); return ret_void(); }

// 0x100109b5b: _BitScanReverse(uint32_t *idx, uint32_t mask)
SHIM_DEF(g_100109b5b) {
    SHIM_UNUSED_ALL();
    uint32_t v = (uint32_t)rsi;
    if (v == 0) return ret_u64(0);
    if (rdi) *(uint32_t *)rdi = (uint32_t)(31 - __builtin_clz(v));
    return ret_u64(1);
}
// 0x100109b73: _BitScanReverse64(uint32_t *idx, uint64_t mask)
SHIM_DEF(g_100109b73) {
    SHIM_UNUSED_ALL();
    if (rsi == 0) return ret_u64(0);
    if (rdi) *(uint32_t *)rdi = (uint32_t)(63 - __builtin_clzll(rsi));
    return ret_u64(1);
}
// 0x100110014: _BitScanForward(uint32_t *idx, uint32_t mask)
SHIM_DEF(g_100110014) {
    SHIM_UNUSED_ALL();
    uint32_t v = (uint32_t)rsi;
    if (v == 0) return ret_u64(0);
    if (rdi) *(uint32_t *)rdi = (uint32_t)__builtin_ctz(v);
    return ret_u64(1);
}

// 0x100109b96 / 0x100109b9f / 0x100109bab / 0x10010a430 / 0x10010a8ff / 0x1001116fd
SHIM_DEF(g_100109b96) { SHIM_UNUSED_ALL(); return ret_u64(rdi); }
SHIM_DEF(g_100109b9f) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_100109bab) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_10010a430) { SHIM_UNUSED_ALL(); return ret_u64(0xffffffffffffffffULL); } // GetCurrentProcess()
SHIM_DEF(g_10010a8ff) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_1001116fd) { SHIM_UNUSED_ALL(); return ret_u64(0); } // IsDebuggerPresent()

// 0x100109c20: MulDiv(int a, int b, int c)
SHIM_DEF(g_100109c20) {
    SHIM_UNUSED_ALL();
    int32_t a = (int32_t)rdi, b = (int32_t)rsi, c = (int32_t)rdx;
    if (c == 0) return ret_u64(0xffffffffULL);
    return ret_i64(((int64_t)a * (int64_t)b) / (int64_t)c);
}

// 0x100109ca9: GetSystemTimeAsFileTime(uint64_t *ft)
SHIM_DEF(g_100109ca9) {
    SHIM_UNUSED_ALL();
    if (rdi) {
        struct timeval tv;
        if (gettimeofday(&tv, NULL) == 0) {
            uint64_t ft = ((uint64_t)tv.tv_sec + 11644473600ULL) * 10000000ULL
                        + (uint64_t)tv.tv_usec * 10ULL;
            memcpy((void *)rdi, &ft, sizeof(ft));
        }
    }
    return ret_void();
}

// 0x10010a71a: SetPriorityClass(HANDLE hProc, DWORD dwPriorityClass)
SHIM_DEF(g_10010a71a) {
    SHIM_UNUSED_ALL();
    if ((int64_t)rdi != -1) return ret_u64(0);
    int prio = 0;
    if ((uint32_t)rsi == 0x40) prio = 16;
    else if ((uint32_t)rsi == 0x4000) prio = 6;
    return ret_u64(setpriority(PRIO_PROCESS, 0, prio) == 0 ? 1 : 0);
}

// 0x10010a758: ExitProcess(UINT code)
SHIM_DEF(g_10010a758) {
    SHIM_UNUSED_ALL();
    fprintf(stderr, "[aspyr] ExitProcess(%u)\n", (uint32_t)rdi);
    fflush(stderr);
    exit((int)rdi);
}

// 0x10010a773: GlobalMemoryStatusEx(LPMEMORYSTATUSEX ms)
SHIM_DEF(g_10010a773) {
    SHIM_UNUSED_ALL();
    uint32_t *ms = (uint32_t *)rdi;
    if (!ms || ms[0] != 0x40) {
        bo3_set_last_error(ctx, 0x57);
        return ret_u64(0);
    }
    uint64_t total_mem = 0;
    size_t len = sizeof(total_mem);
    int mib[2] = { CTL_HW, HW_MEMSIZE };
    sysctl(mib, 2, &total_mem, &len, NULL, 0);
    if (total_mem == 0) total_mem = 16ULL * 1024 * 1024 * 1024;
    vm_size_t page_sz = 16384;
    host_page_size(mach_host_self(), &page_sz);
    vm_statistics64_data_t vmstat;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    uint64_t avail_phys = total_mem / 2;
    uint64_t avail_pf = total_mem / 2;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmstat, &count) == KERN_SUCCESS) {
        avail_phys = (uint64_t)vmstat.free_count * (uint64_t)page_sz;
        avail_pf = ((uint64_t)vmstat.free_count + (uint64_t)vmstat.inactive_count) * (uint64_t)page_sz;
        if (avail_phys < total_mem / 4) avail_phys = avail_pf; // Apple Silicon unified memory keeps most RAM in file cache
    }
    if (avail_pf > total_mem) avail_pf = total_mem;
    if (avail_phys > total_mem) avail_phys = total_mem;
    const uint64_t sizes[] = {total_mem, avail_phys, total_mem, avail_pf, total_mem, avail_pf};
    memcpy(ms + 2, sizes, sizeof(sizes));
    ms[1] = (uint32_t)(((total_mem - avail_phys) * 100ULL) / total_mem);
    ms[14] = 0;
    ms[15] = 0;
    return ret_u64(1);
}

// 0x10010b0f3: GetProcAddress(HMODULE h, const char *name)
SHIM_DEF(g_10010b0f3) {
    SHIM_UNUSED_ALL();
    // GetProcAddress requires a guest thunk VA for each exported symbol.
    return ret_u64(0);
}

// 0x10010b385: GetLastError()
SHIM_DEF(g_10010b385) {
    SHIM_UNUSED_ALL();
    return ret_u64(*bo3_last_error_ptr(ctx));
}

// 0x10010b396: GetVersionExA(OSVERSIONINFOA *info)
SHIM_DEF(g_10010b396) {
    SHIM_UNUSED_ALL();
    uint32_t *v = (uint32_t *)rdi;
    if (!v || v[0] < 20) return ret_u64(0);
    uint32_t sz = v[0];
    memset(v, 0, sz);
    v[0] = sz;
    v[1] = 6; // Major: Windows 8
    v[2] = 2; // Minor
    v[4] = 2; // VER_PLATFORM_WIN32_NT
    return ret_u64(1);
}

// ---- Timing & SystemInfo ----
// The first tick count or frequency query establishes the epoch.
static mach_timebase_info_data_t g_tick_tb;
static uint64_t g_tick_t0;
static uint64_t g_ticks_per_ms;
static bool g_tick_ready;
static pthread_once_t g_tick_once = PTHREAD_ONCE_INIT;
static void bo3_ticks_init(void) {
    mach_timebase_info_data_t tb = {0, 0};
    if (mach_timebase_info(&tb) != KERN_SUCCESS || tb.denom == 0 || tb.numer == 0) { tb.numer = 1; tb.denom = 1; }
    g_tick_tb = tb;
    g_tick_t0 = mach_absolute_time();
    uint64_t ms_scale = 1000000ULL * tb.denom;
    if (ms_scale % tb.numer == 0) g_ticks_per_ms = ms_scale / tb.numer;
    __atomic_store_n(&g_tick_ready, true, __ATOMIC_RELEASE);
}
static void bo3_ticks_ensure_initialized(void) {
    if (!__atomic_load_n(&g_tick_ready, __ATOMIC_ACQUIRE))
        pthread_once(&g_tick_once, bo3_ticks_init);
}
static uint64_t bo3_ticks_ms(void) {
    bo3_ticks_ensure_initialized();
    uint64_t dt = mach_absolute_time() - g_tick_t0;
    if (g_ticks_per_ms != 0) return dt / g_ticks_per_ms;
    // Combining the two denominators preserves truncation to whole milliseconds.
    return (uint64_t)((unsigned __int128)dt * g_tick_tb.numer /
                      (1000000ULL * g_tick_tb.denom));
}
SHIM_DEF(g_100109c09) { SHIM_UNUSED_ALL(); return ret_u64(bo3_ticks_ms()); }
SHIM_DEF(g_100109bf6) { SHIM_UNUSED_ALL(); return ret_u64(bo3_ticks_ms()); }

// 0x10010b3d3: QueryPerformanceCounter(LARGE_INTEGER *p)
SHIM_DEF(g_10010b3d3) {
    SHIM_UNUSED_ALL();
    if (rdi) *(uint64_t *)rdi = mach_absolute_time();
    return ret_u64(1);
}
// 0x10010b3f0: QueryPerformanceFrequency(LARGE_INTEGER *p)
SHIM_DEF(g_10010b3f0) {
    SHIM_UNUSED_ALL();
    bo3_ticks_ensure_initialized();
    uint64_t freq = 1000000000ULL * g_tick_tb.denom / g_tick_tb.numer;
    if (rdi) *(uint64_t *)rdi = freq;
    return ret_u64(1);
}
// 0x10010b40e: FormatMessageA
SHIM_DEF(g_10010b40e) {
    SHIM_UNUSED_ALL();
    uint32_t flags = (uint32_t)rdi;
    uint32_t msg_id = (uint32_t)rdx;
    char tmp[1024];
    if (flags & 0x1000u) snprintf(tmp, sizeof(tmp), "Win32 error #%u", msg_id);
    else tmp[0] = 0;
    char *dst = (char *)r8;
    if (flags & 0x100u) {
        if (dst) *(char **)dst = strdup(tmp);
    } else if (dst && (uint32_t)r9 > 0) {
        strlcpy(dst, tmp, (size_t)(uint32_t)r9);
    }
    return ret_u64(0);
}
// 0x10010b4be: SetErrorMode
SHIM_DEF(g_10010b4be) {
    SHIM_UNUSED_ALL();
    uint32_t *slot = (uint32_t *)0x102108190ULL;
    uint32_t old = *slot;
    *slot = (uint32_t)rdi;
    return ret_u64(old);
}
// 0x10010b4d5: SetUnhandledExceptionFilter
SHIM_DEF(g_10010b4d5) {
    SHIM_UNUSED_ALL();
    uint64_t *slot = (uint64_t *)0x1104c9c20ULL;
    uint64_t old = *slot;
    *slot = rdi;
    return ret_u64(old);
}
SHIM_DEF(g_100109c43) {
    // GetSystemInfo(LPSYSTEM_INFO)
    SHIM_UNUSED_ALL();
    uint32_t *si = (uint32_t *)rdi;
    if (si) {
        memset(si, 0, 48);
        si[0] = 9;                        // wProcessorArchitecture = PROCESSOR_ARCHITECTURE_AMD64 (wReserved = 0)
        si[1] = 0x1000;
        *(uint64_t *)(si + 2) = 0x10000ULL;
        *(uint64_t *)(si + 4) = 0x7ffffffeffffULL;
        *(uint64_t *)(si + 6) = 0xffULL; // active processor mask (8 cores)
        si[8] = 8;                        // dwNumberOfProcessors
        si[9] = 586;                      // dwProcessorType
        si[10] = 0x1000;                  // dwAllocationGranularity
        si[11] = 0x08030006u;
    }
    return ret_void();
}

// ---- Critical Sections (exact Aspyr 40-byte CRITICAL_SECTION layout!) ----
// [0..7]=DebugInfo, [8..11]=LockCount, [12..15]=RecursionCount, [16..23]=OwningThread,
// [24..31]=pthread_mutex_t* (recursive), [32..39]=SpinCount
static pthread_mutex_t g_cs_init_lock = PTHREAD_MUTEX_INITIALIZER;

static pthread_mutex_t *bo3_cs_ensure_mutex(uint8_t *cs) {
    pthread_mutex_t **slot = (pthread_mutex_t **)(cs + 0x18);
    pthread_mutex_t *mtx = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (mtx) return mtx;
    pthread_mutex_lock(&g_cs_init_lock);
    mtx = __atomic_load_n(slot, __ATOMIC_RELAXED);
    if (!mtx) {
        mtx = malloc(sizeof(*mtx));
        if (!mtx) abort();
        pthread_mutexattr_t attr;
        if (pthread_mutexattr_init(&attr) != 0 ||
            pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE) != 0 ||
            pthread_mutex_init(mtx, &attr) != 0) abort();
        pthread_mutexattr_destroy(&attr);
        *(int32_t *)(cs + 8) = -1;
        __atomic_store_n(slot, mtx, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&g_cs_init_lock);
    return mtx;
}

SHIM_DEF(g_10011142e) {
    SHIM_UNUSED_ALL();
    uint64_t *cs = (uint64_t *)rdi;
    if (!cs) return ret_void();
    memset(cs, 0, 40);
    cs[4] = 0x96;
    bo3_cs_ensure_mutex((uint8_t *)cs);
    return ret_void();
}
SHIM_DEF(g_100111504) {
    SHIM_UNUSED_ALL();
    uint8_t *cs = (uint8_t *)rdi;
    if (!cs) return ret_void();
    pthread_mutex_t *mtx = bo3_cs_ensure_mutex(cs);
    __atomic_add_fetch((volatile int32_t *)(cs + 8), 1, __ATOMIC_SEQ_CST);
    if (pthread_mutex_lock(mtx) != 0) abort();
    int32_t *rc = (int32_t *)(cs + 0x0c);
    if ((*rc)++ == 0) {
        *(uint64_t *)(cs + 0x10) = (uint64_t)bo3_current_tid(ctx);
    }
    return ret_void();
}
SHIM_DEF(g_10011155b) {
    SHIM_UNUSED_ALL();
    uint8_t *cs = (uint8_t *)rdi;
    if (!cs) return ret_void();
    pthread_mutex_t *mtx = __atomic_load_n((pthread_mutex_t **)(cs + 0x18), __ATOMIC_ACQUIRE);
    int32_t *rc = (int32_t *)(cs + 0x0c);
    if (--(*rc) == 0) *(uint64_t *)(cs + 0x10) = 0;
    __atomic_sub_fetch((volatile int32_t *)(cs + 8), 1, __ATOMIC_SEQ_CST);
    if (mtx) pthread_mutex_unlock(mtx);
    return ret_void();
}
// 0x1001114ca: DeleteCriticalSection
SHIM_DEF(g_1001114ca) {
    SHIM_UNUSED_ALL();
    uint8_t *cs = (uint8_t *)rdi;
    if (!cs) return ret_void();
    pthread_mutex_t *mtx = __atomic_exchange_n((pthread_mutex_t **)(cs + 0x18), NULL, __ATOMIC_ACQ_REL);
    if (mtx) {
        pthread_mutex_destroy(mtx);
        free(mtx);
    }
    memset(cs, 0, 40);
    return ret_void();
}
// 0x100111589: TryEnterCriticalSection
SHIM_DEF(g_100111589) {
    SHIM_UNUSED_ALL();
    uint8_t *cs = (uint8_t *)rdi;
    if (!cs) return ret_u64(0);
    pthread_mutex_t *mtx = bo3_cs_ensure_mutex(cs);
    __atomic_add_fetch((volatile int32_t *)(cs + 8), 1, __ATOMIC_SEQ_CST);
    if (pthread_mutex_trylock(mtx) == 0) {
        int32_t *rc = (int32_t *)(cs + 0x0c);
        if ((*rc)++ == 0) {
            *(uint64_t *)(cs + 0x10) = (uint64_t)bo3_current_tid(ctx);
        }
        return ret_u64(1);
    }
    __atomic_sub_fetch((volatile int32_t *)(cs + 8), 1, __ATOMIC_SEQ_CST);
    return ret_u64(0);
}
SHIM_DEF(g_100111705) { SHIM_UNUSED_ALL(); return ret_u64(1); }

// ---- Threads & Sleep ----
SHIM_DEF(g_1001116c0) {
    SHIM_UNUSED_ALL();
    return ret_u64(bo3_current_tid(ctx));
}
// Win32 Sleep semantics: 0 = yield, INFINITE (0xFFFFFFFF) = never return, otherwise ms with
// 64-bit math (usleep(ms * 1000u) overflowed 32 bits above ~71.5 minutes and rejects >= 1 s).
#define BO3_WIN32_INFINITE 0xFFFFFFFFu
static void bo3_sleep_ms(uint32_t ms) {
    if (ms == 0) { sched_yield(); return; }
    if (ms == BO3_WIN32_INFINITE) {
        for (;;) pause();
    }
    struct timespec req, rem;
    req.tv_sec  = (time_t)(ms / 1000u);
    req.tv_nsec = (long)((uint64_t)(ms % 1000u) * 1000000ULL);
    while (nanosleep(&req, &rem) != 0 && errno == EINTR) req = rem;
}
SHIM_DEF(g_100110e84) {
    SHIM_UNUSED_ALL();
    int saved = errno;
    bo3_sleep_ms((uint32_t)rdi);
    errno = saved;
    return ret_void();
}
SHIM_DEF(g_100111752) {
    SHIM_UNUSED_ALL();
    int saved = errno;
    bo3_sleep_ms((uint32_t)rdi);
    errno = saved;
    return ret_u64(0);
}

// ---- Winsock Shims ----
// 0x10011034d: WSAGetLastError() -- exact port of Aspyr's errno->WSA mapping:
//   idx = errno - 9; (unsigned)idx < 0x5e ? table[idx] : WSAEWOULDBLOCK (0x2733)
// Table is a verbatim copy of the 94 x uint32 at guest VA 0x1017e27b0 (__TEXT,__const) of
// CoDBlkOps3_Exe, embedded so the mapping does not depend on the guest image being mapped.
// Deviation: errno == 0 returns 0 (no error) instead of the original's WSAEWOULDBLOCK.
static const uint32_t k_bo3_errno_to_wsa[0x5e] = {
    10009, 10035, 10035, 10035, 10013, 10014, 10035, 10035,  // errno   9..16
    10035, 10035, 10035, 10035, 10035, 10022, 10035, 10035,  // errno  17..24
    10035, 10035, 10035, 10035, 10035, 10035, 10035,   230,  // errno  25..32
    10035, 10035, 10035, 10036, 10037, 10038, 10039, 10040,  // errno  33..40 (35 EAGAIN -> 10035)
    10041, 10042, 10043, 10044, 10035, 10046, 10047, 10048,  // errno  41..48
    10049, 10050, 10051, 10052, 10053, 10054, 10055, 10056,  // errno  49..56
    10057, 10058, 10059, 10060, 10061, 10062, 10063, 10064,  // errno  57..64
    10065, 10066, 10067, 10068, 10069, 10070, 10071, 10035,  // errno  65..72
    10035, 10035, 10035, 10035, 10035, 10035, 10035, 10035,  // errno  73..80
    10035, 10035, 10035, 10035, 10035, 10035, 10035, 10035,  // errno  81..88
    10035, 10035, 10035, 10035, 10035, 10035, 10035, 10035,  // errno  89..96
    10035, 10035, 10035, 10035, 10035, 10045,                // errno  97..102
};
uint32_t bo3_errno_to_wsa(int e) {
    if (e == 0) return 0;
    uint32_t idx = (uint32_t)e - 9u;
    return idx < 0x5eu ? k_bo3_errno_to_wsa[idx] : 0x2733u;
}
SHIM_DEF(g_10011034d) { SHIM_UNUSED_ALL(); return ret_u64(bo3_errno_to_wsa(errno)); }
SHIM_DEF(g_100110375) {
    SHIM_UNUSED_ALL();
    uint16_t *wsa = (uint16_t *)rsi;
    if (wsa) {
        memset(wsa, 0, 408);
        wsa[0] = (uint16_t)rdi;
        wsa[1] = (uint16_t)rdi;
        strcpy((char *)(wsa + 8), "MacOS X Sockets");
        *(uint32_t *)(wsa + 2) = 0xff00ffu;
    }
    return ret_u64(0);
}

// ---- MSVC Safe CRT (0x1000fa* - 0x1000fb*) ----
// 0x1000facea: _aligned_malloc(size, align)
SHIM_DEF(g_1000facea) {
    SHIM_UNUSED_ALL();
    size_t sz = (size_t)rdi, al = (size_t)rsi;
    if (al < 8) al = 8;
    void *raw = malloc(sz + 0x16 + al);
    if (!raw) return ret_u64(0);
    uintptr_t u = ((uintptr_t)raw + al + 0x16) & ~(al - 1);
    uint64_t *hdr = (uint64_t *)((u - 0x10) & ~7ULL);
    hdr[0] = (uint64_t)(uintptr_t)raw;
    hdr[1] = (uint64_t)sz;
    return ret_u64((uint64_t)u);
}
// 0x1000fad24: _aligned_free(ptr)
SHIM_DEF(g_1000fad24) {
    SHIM_UNUSED_ALL();
    if (rdi) free(*(void **)((rdi - 0x10ULL) & ~7ULL));
    return ret_void();
}
// 0x1000fad40: strnlen(s, maxlen)
SHIM_DEF(g_1000fad40) {
    SHIM_UNUSED_ALL();
    return ret_u64(strnlen((const char *)rdi, (size_t)rsi));
}
// 0x1000fad8d: _itoa(int val, char *buf, int radix)
SHIM_DEF(g_1000fad8d) {
    SHIM_UNUSED_ALL();
    int32_t v = (int32_t)rdi; char *buf = (char *)rsi; uint32_t base = (uint32_t)rdx;
    if (!buf || base < 2 || base > 36) return ret_ptr(buf);
    char *p = buf;
    uint32_t uv;
    if (v < 0 && base == 10) { *p++ = '-'; uv = (uint32_t)(-(int64_t)v); }
    else uv = (uint32_t)v;
    char *start = p;
    do {
        uint32_t d = uv % base;
        *p++ = (char)(d < 10 ? ('0' + d) : ('a' + d - 10));
        uv /= base;
    } while (uv);
    *p = 0;
    for (char *a = start, *b = p - 1; a < b; a++, b--) { char t = *a; *a = *b; *b = t; }
    return ret_ptr(buf);
}
// 0x1000fae9e: _ui64toa(uint64_t val, char *buf, int radix)
SHIM_DEF(g_1000fae9e) {
    SHIM_UNUSED_ALL();
    uint64_t uv = rdi; char *buf = (char *)rsi; uint32_t base = (uint32_t)rdx;
    if (!buf || base < 2 || base > 36) return ret_ptr(buf);
    char *p = buf;
    do {
        uint32_t d = (uint32_t)(uv % base);
        *p++ = (char)(d < 10 ? ('0' + d) : ('a' + d - 10));
        uv /= base;
    } while (uv);
    *p = 0;
    for (char *a = buf, *b = p - 1; a < b; a++, b--) { char t = *a; *a = *b; *b = t; }
    return ret_ptr(buf);
}
SHIM_DEF(g_1000faf10) { SHIM_UNUSED_ALL(); return ret_i64(strtoll((const char *)rdi, (char **)rsi, (int)rdx)); }
SHIM_DEF(g_1000faf1a) { SHIM_UNUSED_ALL(); return ret_u64(strtoull((const char *)rdi, (char **)rsi, (int)rdx)); }
SHIM_DEF(g_1000faf24) { SHIM_UNUSED_ALL(); if (!rdi) return ret_u64(0); return ret_u64(strtoull((const char *)rdi, NULL, 10)); }
SHIM_DEF(g_1000faf35) {
    SHIM_UNUSED_ALL();
    uint32_t *slot = (uint32_t *)0x102106388ULL;
    uint32_t old = *slot; *slot = (uint32_t)rdi;
    return ret_u64(old);
}
SHIM_DEF(g_1000faf48) { SHIM_UNUSED_ALL(); return ret_u64(0xffffffffULL); }
SHIM_DEF(g_1000faf54) {
    // memcpy_s(dst, dstsz, src, cnt)
    SHIM_UNUSED_ALL();
    void *dst = (void *)rdi; size_t dsz = (size_t)rsi; const void *src = (const void *)rdx; size_t cnt = (size_t)rcx;
    if (!dst) { errno = EINVAL; return ret_i64(EINVAL); }
    if (!src) { memset(dst, 0, dsz); errno = EINVAL; return ret_i64(EINVAL); }
    if (dsz < cnt) { memset(dst, 0, dsz); errno = ERANGE; return ret_i64(ERANGE); }
    memcpy(dst, src, cnt);
    return ret_i64(0);
}
SHIM_DEF(g_1000fb00d) {
    SHIM_UNUSED_ALL();
    uint32_t *seed = (uint32_t *)bo3_tlv_get_addr(ctx, (void *)0x102104dd8ULL);
    uint32_t s = *seed * 214013u + 2531011u;
    *seed = s;
    return ret_u64((s >> 16) & 0x7fffu);
}
SHIM_DEF(g_1000fb035) {
    SHIM_UNUSED_ALL();
    uint32_t *seed = (uint32_t *)bo3_tlv_get_addr(ctx, (void *)0x102104dd8ULL);
    *seed = (uint32_t)rdi;
    return ret_void();
}
SHIM_DEF(g_1000fb048) {
    SHIM_UNUSED_ALL();
    char *dst = (char *)rdi; size_t dsz = (size_t)rsi; const char *src = (const char *)rdx;
    if (!dst || !src || dsz == 0) { errno = EINVAL; return ret_i64(EINVAL); }
    size_t n = strlcpy(dst, src, dsz);
    if (n < dsz) return ret_i64(0);
    errno = EINVAL;
    return ret_i64(EINVAL);
}
SHIM_DEF(g_1000fb0c9) {
    // strcat_s(dst, dstsz, src)
    SHIM_UNUSED_ALL();
    char *dst = (char *)rdi; size_t dsz = (size_t)rsi; const char *src = (const char *)rdx;
    if (!dst || !src || dsz == 0) { errno = EINVAL; return ret_i64(EINVAL); }
    size_t n = strlcat(dst, src, dsz);
    if (n < dsz) return ret_i64(0);
    errno = EINVAL;
    return ret_i64(EINVAL);
}
SHIM_DEF(g_1000fb17e) {
    // strerror_s(buf, bufsz, errnum)
    SHIM_UNUSED_ALL();
    return ret_i64(strerror_r((int)rdx, (char *)rdi, (size_t)rsi));
}
SHIM_DEF(g_1000fb197) {
    SHIM_UNUSED_ALL();
    char *dst = (char *)rdi; size_t dsz = (size_t)rsi; const char *src = (const char *)rdx; size_t cnt = (size_t)rcx;
    if (!dst || dsz == 0) { errno = EINVAL; return ret_i64(EINVAL); }
    if (!src) { dst[0] = 0; errno = EINVAL; return ret_i64(EINVAL); }
    if (cnt == ~(size_t)0) {
        size_t n = strlcpy(dst, src, dsz);
        return ret_i64(n >= dsz ? 80 : 0);
    }
    size_t lim = (cnt + 1 < dsz) ? (cnt + 1) : dsz;
    size_t n = strlcpy(dst, src, lim);
    if (n > cnt) n = cnt;
    if (n < dsz) return ret_i64(0);
    dst[0] = 0; errno = ERANGE; return ret_i64(ERANGE);
}
SHIM_DEF(g_1000fb2af) {
    // _vsnprintf_s(buf, bufsz, count, fmt, va_list) -- exact port of the original at 0x1000fb2af
    SHIM_UNUSED_ALL();
    char *dst = (char *)rdi; size_t dsz = (size_t)rsi; size_t cnt = (size_t)rdx;
    const char *fmt = (const char *)rcx;
    const size_t TRUNC = ~(size_t)0;
    if (!dst || !fmt || !(cnt == TRUNC || (int)cnt > 0)) { errno = EINVAL; return ret_i64(-1); }
    size_t lim = dsz;
    if (cnt != TRUNC && cnt + 1 < dsz) lim = cnt + 1;
    X86VaCursor va; memset(&va, 0, sizeof(va)); va.from_valist = 1;
    if (r8) {
        const uint32_t *u32 = (const uint32_t *)r8;
        const uint8_t *const *ptrs = (const uint8_t *const *)((const uint8_t *)r8 + 8);
        va.gp_off = u32[0]; va.fp_off = u32[1]; va.ov_ptr = ptrs[0]; va.rs_ptr = ptrs[1];
    }
    int n = bo3_x86_vsnprintf(dst, lim, fmt, &va);
    if (n < 0) { errno = EINVAL; return ret_i64(-1); }
    if (cnt == TRUNC) return ret_i64((size_t)n >= dsz ? -1 : n);   // truncated to buffer -> -1
    if (dsz <= cnt && (size_t)n >= dsz) {                          // count doesn't fit buffer
        if (dsz) dst[0] = 0;
        errno = ERANGE;
        return ret_i64(-1);
    }
    return ret_i64(n);
}
SHIM_DEF(g_1000fb3c5) {
    // sprintf_s(buf, bufsz, fmt, ...)
    char *dst = (char *)rdi;
    size_t dsz = (size_t)rsi;
    const char *fmt = (const char *)rdx;
    if (!dst || !fmt) { errno = EINVAL; return ret_i64(-1); }
    X86VaCursor va; memset(&va, 0, sizeof(va));
    va.gp_regs[0] = rdi; va.gp_regs[1] = rsi; va.gp_regs[2] = rdx;
    va.gp_regs[3] = rcx; va.gp_regs[4] = r8;  va.gp_regs[5] = r9;
    va.fp_regs[0] = xmm_to_f64(xmm0); va.fp_regs[1] = xmm_to_f64(xmm1);
    va.fp_regs[2] = xmm_to_f64(xmm2); va.fp_regs[3] = xmm_to_f64(xmm3);
    va.fp_regs[4] = xmm_to_f64(xmm4); va.fp_regs[5] = xmm_to_f64(xmm5);
    va.fp_regs[6] = xmm_to_f64(xmm6); va.fp_regs[7] = xmm_to_f64(xmm7);
    va.gp_idx = 3; va.fp_idx = 0; va.overflow = (const uint64_t *)(rsp + 8ULL);
    (void)ctx;
    int n = bo3_x86_vsnprintf(dst, dsz, fmt, &va);
    if (n < 0 || (size_t)n >= dsz) {
        if (dsz) dst[0] = '\0';
        errno = EINVAL;
        return ret_i64(-1);
    }
    return ret_i64(n);
}
extern FILE *bo3_hksf_fopen(const char *filename, const char *opentype);
SHIM_DEF(g_1000fb503) { SHIM_UNUSED_ALL(); return ret_ptr(bo3_hksf_fopen((const char *)rdi, (const char *)rsi)); }
SHIM_DEF(g_1000fb53a) { SHIM_UNUSED_ALL(); return ret_ptr(getcwd((char *)rdi, (size_t)(int32_t)rsi)); }
SHIM_DEF(g_1000fb548) {
    // gmtime_s(struct tm *out, const time_t *t)
    SHIM_UNUSED_ALL();
    if (rdi && rsi) { time_t tv = *(const time_t *)rsi; memset((void *)rdi, 0, sizeof(struct tm)); gmtime_r(&tv, (struct tm *)rdi); }
    return ret_u64(0);
}
SHIM_DEF(g_1000fb598) {
    // localtime_s(struct tm *out, const time_t *t)
    SHIM_UNUSED_ALL();
    if (rdi && rsi) { time_t tv = *(const time_t *)rsi; memset((void *)rdi, 0, sizeof(struct tm)); localtime_r(&tv, (struct tm *)rdi); }
    return ret_u64(0);
}
SHIM_DEF(g_1000fbcaa) { SHIM_UNUSED_ALL(); return ret_void(); }
SHIM_DEF(g_1000fbe32) { SHIM_UNUSED_ALL(); free((void *)rdi); return ret_void(); }
SHIM_DEF(g_1000fb5e9) {
    // __cpuid(int info[4], int leaf)
    SHIM_UNUSED_ALL();
    uint32_t *info = (uint32_t *)rdi;
    if (info) bo3_cpuid((uint32_t)rsi, 0, &info[0], &info[1], &info[2], &info[3]);
    return ret_void();
}
// MSVC _[v]snprintf uses the full buffer for output and terminates only when
// there is room for an extra byte.
static int bo3_msvc_vsnprintf(char *dst, size_t dsz, const char *fmt, X86VaCursor *va) {
    int n = bo3_x86_vsnprintf_unterminated(dst, dsz, fmt, va);
    return n >= 0 && (size_t)n > dsz ? -1 : n;
}

static pthread_once_t g_trace_con_once = PTHREAD_ONCE_INIT;
static int g_trace_con = 0;
static void bo3_init_trace_con(void) {
    g_trace_con = (getenv("BO3ARM_TRACE_CONSOLE") != NULL);
}

SHIM_DEF(g_1000fb607) {
    SHIM_UNUSED_ALL();
    char *dst = (char *)rdi; size_t dsz = (size_t)rsi; const char *fmt = (const char *)rdx;
    X86VaCursor va;
    memset(&va, 0, sizeof(va));
    va.from_valist = 1;
    if (rcx) {
        const uint32_t *u32 = (const uint32_t *)rcx;
        const uint8_t *const *ptrs = (const uint8_t *const *)((const uint8_t *)rcx + 8);
        va.gp_off = u32[0]; va.fp_off = u32[1]; va.ov_ptr = ptrs[0]; va.rs_ptr = ptrs[1];
    }
    int res = bo3_msvc_vsnprintf(dst, dsz, fmt, &va);
    pthread_once(&g_trace_con_once, bo3_init_trace_con);
    if (g_trace_con && dst && dsz >= 512 && res != 0) {
        int saved_errno = errno;
        size_t cap = dsz < 4096 ? dsz : 4096;
        size_t len = (res > 0 && (size_t)res < cap) ? (size_t)res : strnlen(dst, cap);
        if (len > 0) {
            fprintf(stderr, "[con] %.*s%s", (int)len, dst, (dst[len - 1] == '\n') ? "" : "\n");
            fflush(stderr);
        }
        errno = saved_errno;
    }
    return ret_i64(res);
}
SHIM_DEF(g_1000fb6d6) {
    // _snprintf(buf, size, fmt, ...)
    X86VaCursor va;
    memset(&va, 0, sizeof(va));
    va.gp_regs[0] = rdi; va.gp_regs[1] = rsi; va.gp_regs[2] = rdx;
    va.gp_regs[3] = rcx; va.gp_regs[4] = r8;  va.gp_regs[5] = r9;
    va.fp_regs[0] = xmm_to_f64(xmm0); va.fp_regs[1] = xmm_to_f64(xmm1);
    va.fp_regs[2] = xmm_to_f64(xmm2); va.fp_regs[3] = xmm_to_f64(xmm3);
    va.fp_regs[4] = xmm_to_f64(xmm4); va.fp_regs[5] = xmm_to_f64(xmm5);
    va.fp_regs[6] = xmm_to_f64(xmm6); va.fp_regs[7] = xmm_to_f64(xmm7);
    va.gp_idx = 3; va.fp_idx = 0; va.overflow = (const uint64_t *)(rsp + 8ULL);
    (void)ctx;
    return ret_i64(bo3_msvc_vsnprintf((char *)rdi, (size_t)rsi, (const char *)rdx, &va));
}

// 0x1001414f0: SDL_memset
SHIM_DEF(g_1001414f0) { SHIM_UNUSED_ALL(); return ret_ptr(memset((void *)rdi, (int)rsi, (size_t)rdx)); }
// 0x100129c86..0x100129db0: Misc CRT/OS helpers
SHIM_DEF(g_100129c86) {
    SHIM_UNUSED_ALL();
    uint64_t *p1 = (uint64_t *)rdi, *p2 = (uint64_t *)rsi;
    void *s = (void *)p1[0];
    int64_t n = (int64_t)(p1[1] - p1[0]);
    void *d = (void *)(p2[1] - (uint64_t)n);
    p2[1] = (uint64_t)(uintptr_t)d;
    if (n > 0) { memcpy(d, s, (size_t)n); d = (void *)p2[1]; }
    uint64_t t = p1[0]; p1[0] = (uint64_t)(uintptr_t)d; p2[1] = t;
    t = p1[1]; p1[1] = p2[2]; p2[2] = t;
    t = p1[2]; p1[2] = p2[3]; p2[3] = t;
    p2[0] = p2[1];
    return ret_void();
}
SHIM_DEF(g_100129cec) { SHIM_UNUSED_ALL(); return ret_i64(fseek((FILE *)rdi, (long)rsi, (int)rdx)); }
SHIM_DEF(g_100129cf6) { SHIM_UNUSED_ALL(); return ret_i64(ftell((FILE *)rdi)); }
SHIM_DEF(g_100129d00) { SHIM_UNUSED_ALL(); return ret_ptr(popen((const char *)rdi, (const char *)rsi)); }
SHIM_DEF(g_100129d0a) { SHIM_UNUSED_ALL(); return ret_i64(pclose((FILE *)rdi)); }
SHIM_DEF(g_100129d14) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_100129d1c) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_100129d24) {
    SHIM_UNUSED_ALL();
    wchar_t *dst = (wchar_t *)rsi;
    size_t size = (size_t)rdx;
    if (!rcx || (dst && !size)) return ret_u64(EINVAL);
    size_t lim = size > 0 && (size_t)r8 >= size ? size - 1 : (size_t)r8;
    size_t n = mbstowcs(dst, (const char *)rcx, lim);
    if (rdi) *(size_t *)rdi = n;
    if (n == (size_t)-1) return ret_u64(EILSEQ);
    if (dst) dst[n] = L'\0';
    return ret_u64(n ? 0 : EINVAL);
}
SHIM_DEF(g_100129d52) {
    SHIM_UNUSED_ALL();
    char *dst = (char *)rdi;
    if (!dst) return ret_u64(0x16);
    static volatile uint32_t seq = 0;
    snprintf(dst, 256, "/tmp/bo3_tmp_%d_%u", (int)getpid(), __atomic_fetch_add(&seq, 1, __ATOMIC_RELAXED));
    return ret_u64(0);
}
SHIM_DEF(g_100129d6a) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_100129d72) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_100129d7a) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_100129d82) { SHIM_UNUSED_ALL(); return ret_u64(1); }
SHIM_DEF(g_100129d8d) { SHIM_UNUSED_ALL(); return ret_u64(1); }
SHIM_DEF(g_100129d98) { SHIM_UNUSED_ALL(); return ret_u64(0); }
SHIM_DEF(g_100129da0) { SHIM_UNUSED_ALL(); return ret_void(); }
SHIM_DEF(g_100129db0) {
    // Get ~/Library/Application Support/Call of Duty Black Ops III/<subpath>
    SHIM_UNUSED_ALL();
    char *dst = (char *)rdi;
    const char *sub = rsi ? ((const char *)rsi + 0xb) : "";
    const char *home = getenv("HOME");
    if (!home) home = "/tmp";
    char dir[512];
    snprintf(dir, sizeof(dir), "%s/Library/Application Support/Call of Duty Black Ops III", home);
    mkdir(dir, 0755);
    if (dst) {
        snprintf(dst, 256, "%s/%s", dir, sub);
    }
    return ret_void();
}

// D3D11CreateDevice (0x10006ff10) and CreateDXGIFactory1 (0x1000de240) are now provided by
// metal/d3d11_device.mm and metal/dxgi_metal.mm!

// ===================== Async-Signal-Safe Crash Handler =====================
static void bo3_write_str(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    (void)write(STDERR_FILENO, s, n);
}
static void bo3_write_hex(uint64_t v) {
    char buf[18];
    buf[0] = '0'; buf[1] = 'x';
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 16; i++) buf[2 + i] = hex[(v >> (60 - i * 4)) & 0xf];
    (void)write(STDERR_FILENO, buf, 18);
}

static void bo3_crash_handler(int sig, siginfo_t *info, void *uctx) {
    uint64_t pc = 0, lr = 0;
#if defined(__aarch64__) && defined(__APPLE__)
    if (uctx) {
        ucontext_t *uc = (ucontext_t *)uctx;
        pc = (uint64_t)uc->uc_mcontext->__ss.__pc;
        lr = (uint64_t)uc->uc_mcontext->__ss.__lr;
    }
#else
    (void)uctx;
#endif
    bo3_write_str("\n[BO3 CRASH] sig=");
    bo3_write_hex((uint64_t)(uint32_t)sig);
    bo3_write_str(" fault_addr=");
    bo3_write_hex(info ? (uint64_t)(uintptr_t)info->si_addr : 0ULL);
    bo3_write_str(" pc=");
    bo3_write_hex(pc);
    bo3_write_str(" lr=");
    bo3_write_hex(lr);
    bo3_write_str("\n");
    _exit(128 + sig);
}

// ===================== M3 Recompiled Engine Entrypoint =====================
static int bo3_recomp_guest_main(int argc, char **argv) {
    (void)argc; (void)argv;
    fprintf(stderr, "[bo3_recomp] Initializing native ARM64 BO3 engine (Direct Metal M3)...\n");
    bo3_register_all_functions();
    bo3_register_extra_shards();
    bo3_init_steam_mocks();
    bo3_init_win32_mocks();
    bo3_metal_init_all();
    bo3_apply_data_binds();
    fprintf(stderr, "[bo3_recomp] Registered all functions + Direct Metal COM vtables + __DATA binds.\n");

    const size_t STACK_SZ = 8 * 1024 * 1024;
    void *stk = mmap(NULL, STACK_SZ + 16384, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stk == MAP_FAILED) { perror("mmap guest stack"); return 1; }
    if (mprotect(stk, 16384, PROT_NONE) != 0) { perror("mprotect guard"); return 1; }

    GuestContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.mxcsr = 0x1f80;
    ctx.stack_base = (uint64_t)(uintptr_t)stk + 16384;
    ctx.stack_size = STACK_SZ;
    ctx.tlv_block = bo3_alloc_thread_tlv();
    bo3_init_thread_tid(&ctx, 1);

    uint64_t sp = (ctx.stack_base + STACK_SZ - 256) & ~15ULL;

    fprintf(stderr, "[bo3_recomp] Running %zu Core BO3 __mod_init_func constructors...\n", g_bo3_engine_init_count);
    fflush(stderr);
    for (size_t i = 0; i < g_bo3_engine_init_count; i++) {
        uint64_t ctor_va = g_bo3_engine_init_funcs[i];
        GuestFn fn = bo3_resolve(ctor_va, &ctx);
        uint64_t call_sp = sp - 8;
        *(uint64_t *)call_sp = 0;
        ctx.last_pc = ctor_va;
        fn(&ctx, call_sp, 0, 0, 0, 0, 0, 0,
           guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
           guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
        if ((i + 1) % 100 == 0 || i + 1 == g_bo3_engine_init_count) {
            fprintf(stderr, "[bo3_recomp]   constructors: %zu / %zu OK (last=0x%llx)\n",
                    i + 1, g_bo3_engine_init_count, (unsigned long long)ctor_va);
            fflush(stderr);
        }
    }

    static char cmdline_buf[256] = "";
    fprintf(stderr, "[bo3_recomp] All %zu constructors PASSED! Entering BO3 WinMain (0x100d634b3)...\n", g_bo3_engine_init_count);
    fflush(stderr);
    GuestFn winmain = bo3_resolve(0x100d634b3ULL, &ctx);
    uint64_t call_sp = sp - 8;
    *(uint64_t *)call_sp = 0;
    ctx.last_pc = 0x100d634b3ULL;
    GuestRet r = winmain(&ctx, call_sp,
        0x100000000ULL, 0ULL, (uint64_t)(uintptr_t)cmdline_buf, 1ULL, 0ULL, 0ULL,
        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(),
        guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero(), guest_xmm_zero());
    fprintf(stderr, "[bo3_recomp] WinMain returned %lld\n", (long long)r.rax_rdx[0]);
    return (int)r.rax_rdx[0];
}

int bo3_recomp_entry(int argc, char **argv) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = bo3_crash_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);

    // Thread 0 owns AppKit NSApplication; guest engine runs on dedicated guest_main pthread!
    return bo3_mac_run_with_guest(bo3_recomp_guest_main, argc, argv);
}

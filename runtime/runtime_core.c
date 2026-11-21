#include "cpu_state.h"
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include <pthread.h>

// Exact-VA dispatch table: open-addressed hash table (power-of-2 capacity) for arbitrary 1-byte-aligned VAs
#define DISPATCH_BITS 18
#define DISPATCH_CAP  (1u << DISPATCH_BITS)
#define DISPATCH_MASK (DISPATCH_CAP - 1u)

typedef struct DispatchEntry {
    uint64_t va;   // published LAST with release semantics (0 = empty)
    GuestFn  fn;   // written BEFORE va is published
} DispatchEntry;

static DispatchEntry g_dispatch[DISPATCH_CAP];
// Writers (startup registration + runtime COM/Steam thunk allocation) are serialized so two
// concurrent registrations can never claim the same empty slot; readers stay lock-free.
static pthread_mutex_t g_dispatch_wlock = PTHREAD_MUTEX_INITIALIZER;

static inline uint32_t hash_va(uint64_t va) {
    va ^= va >> 33;
    va *= 0xff51afd7ed558ccdULL;
    va ^= va >> 33;
    return (uint32_t)va & DISPATCH_MASK;
}

void bo3_register_fn(uint64_t guest_va, GuestFn fn) {
    if (!guest_va || !fn) return;
    pthread_mutex_lock(&g_dispatch_wlock);
    uint32_t idx = hash_va(guest_va);
    for (uint32_t probe = 0; probe < DISPATCH_CAP; probe++) {
        DispatchEntry *e = &g_dispatch[(idx + probe) & DISPATCH_MASK];
        uint64_t k = __atomic_load_n(&e->va, __ATOMIC_RELAXED);
        if (k == guest_va) {
            // Re-registration: va already published, just swap the target atomically.
            __atomic_store_n(&e->fn, fn, __ATOMIC_RELEASE);
            pthread_mutex_unlock(&g_dispatch_wlock);
            return;
        }
        if (k == 0) {
            __atomic_store_n(&e->fn, fn, __ATOMIC_RELAXED);
            __atomic_store_n(&e->va, guest_va, __ATOMIC_RELEASE); // publish AFTER fn is visible
            pthread_mutex_unlock(&g_dispatch_wlock);
            return;
        }
    }
    pthread_mutex_unlock(&g_dispatch_wlock);
    fprintf(stderr, "[bo3_register_fn] dispatch table full!\n");
    abort();
}

// Non-trapping lookup: returns NULL if `target_va` was never registered.
// Probes the whole table (same bound as bo3_register_fn), stopping at the first empty slot.
GuestFn bo3_lookup_fn(uint64_t target_va) {
    if (!target_va) return NULL;
    uint32_t idx = hash_va(target_va);
    for (uint32_t probe = 0; probe < DISPATCH_CAP; probe++) {
        const DispatchEntry *e = &g_dispatch[(idx + probe) & DISPATCH_MASK];
        uint64_t k = __atomic_load_n(&e->va, __ATOMIC_ACQUIRE);
        if (k == target_va) return __atomic_load_n(&e->fn, __ATOMIC_ACQUIRE);
        if (k == 0) break;
    }
    return NULL;
}

GuestFn bo3_resolve(uint64_t target_va, GuestContext *ctx) {
    GuestFn fn = bo3_lookup_fn(target_va);
    if (fn) return fn;
    fprintf(stderr, "[bo3_resolve] unresolved indirect target_va=0x%llx\n", (unsigned long long)target_va);
    bo3_trap(target_va, 99, ctx);
}

// C-linkage synthetic-VA thunk allocator for C shims (shim_curl_zlib_steam.c, shim_aspyr_win32.c).
// metal/com_thunks.mm exports only a C++-mangled bo3_com_register_thunk(GuestFn) backed by the
// [0xF00000000000, 0xF00000100000) pool, so this weak C definition uses the disjoint
// [0xF00000200000, 0xF00000300000) pool: never overlaps guest __TEXT/__DATA or the Metal/audio thunks.
// Weak so a future strong extern "C" definition takes over without a duplicate-symbol error.
#define BO3_C_THUNK_BASE 0xF00000200000ULL
#define BO3_C_THUNK_END  0xF00000300000ULL
static uint64_t g_next_c_thunk_va = BO3_C_THUNK_BASE;

__attribute__((weak))
uint64_t bo3_com_register_thunk(GuestFn fn, const char *name) {
    (void)name;
    uint64_t va = __atomic_fetch_add(&g_next_c_thunk_va, 8ULL, __ATOMIC_RELAXED);
    if (va >= BO3_C_THUNK_END) {
        fprintf(stderr, "[bo3_com_register_thunk] FATAL: C synthetic VA pool exhausted (%s)\n",
                name ? name : "?");
        abort();
    }
    bo3_register_fn(va, fn);
    return va;
}

void bo3_cpuid(uint32_t leaf, uint32_t subleaf, uint32_t *eax, uint32_t *ebx, uint32_t *ecx, uint32_t *edx) {
    (void)subleaf;
    *eax = *ebx = *ecx = *edx = 0;
    if (leaf == 0) {
        *eax = 7;
        // "GenuineIntel"
        *ebx = 0x756e6547u;
        *edx = 0x49656e69u;
        *ecx = 0x6c65746eu;
    } else if (leaf == 1) {
        *eax = 0x000306c3u;
        *ebx = 0x00080800u; // 8 logical CPUs, 64B cache line
        // ECX: advertise ONLY lifted extensions: SSE3(0), SSSE3(9), SSE4.1(19), POPCNT(23)
        // Deliberately omit CMPXCHG16B(13), SSE4.2(20), AVX(28), FMA(12)
        *ecx = (1u << 0) | (1u << 9) | (1u << 19) | (1u << 23);
        // EDX: FPU(0), TSC(4), CX8(8), CMOV(15), CLFSH(19), FXSR(24), SSE(25), SSE2(26) (omit MMX(23))
        *edx = (1u << 0) | (1u << 4) | (1u << 8) | (1u << 15) | (1u << 19) | (1u << 24) | (1u << 25) | (1u << 26);
    } else if (leaf == 7) {
        *eax = *ebx = *ecx = *edx = 0; // No AVX2/BMI
    } else if (leaf == 0x80000000u) {
        *eax = 0x80000008u;
    } else if (leaf == 0x80000001u) {
        *edx = (1u << 29) | (1u << 20); // LM + NX
    }
}

uint64_t bo3_rdtsc(void) {
#if defined(__aarch64__)
    uint64_t cnt;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(cnt));
    return cnt * 100ULL;
#else
    return mach_absolute_time();
#endif
}

void bo3_trap(uint64_t pc, uint64_t reason, GuestContext *ctx) {
    fprintf(stderr, "[bo3_trap] pc=0x%llx reason=%llu last_pc=0x%llx\n",
            (unsigned long long)pc, (unsigned long long)reason,
            ctx ? (unsigned long long)ctx->last_pc : 0ULL);
    abort();
}

void *bo3_tlv_get_addr(GuestContext *ctx, void *descriptor) {
    if (!ctx || !ctx->tlv_block || !descriptor) {
        fprintf(stderr, "[bo3_tlv_get_addr] uninitialized tlv_block or null descriptor\n");
        abort();
    }
    // Mach-O tlv_descriptor: { void *thunk; unsigned long key; unsigned long offset; }
    uint64_t offset = ((const uint64_t *)descriptor)[2];
    return (uint8_t *)ctx->tlv_block + offset;
}

// Native state is stored out of line because the guest jmp_buf has a different ABI.
#define BO3_JMPBUF_INITIAL_CAP 64
#define BO3_JMPBUF_SP_WORD 13
typedef struct Bo3JmpSlot {
    uint64_t key;
    uint64_t words[31];
} Bo3JmpSlot;
_Static_assert(sizeof(Bo3JmpSlot) == 256, "Bo3JmpSlot must match setjmp_arm64.S layout");
_Static_assert(offsetof(Bo3JmpSlot, words[BO3_JMPBUF_SP_WORD]) == 112,
               "Saved SP must match setjmp_arm64.S layout");

typedef struct Bo3JmpTable {
    Bo3JmpSlot *slots;
    size_t cap;
} Bo3JmpTable;

static pthread_key_t g_jmpbuf_key;
static pthread_once_t g_jmpbuf_once = PTHREAD_ONCE_INIT;

static void bo3_jmpbuf_destroy(void *ptr) {
    Bo3JmpTable *table = ptr;
    free(table->slots);
    free(table);
}

static void bo3_jmpbuf_init(void) {
    if (pthread_key_create(&g_jmpbuf_key, bo3_jmpbuf_destroy) != 0) abort();
}

void *bo3_jmpbuf_slot(uint64_t guest_jmpbuf_ptr, int create) {
    if (!guest_jmpbuf_ptr) {
        fprintf(stderr, "[bo3_jmpbuf_slot] null guest jmp_buf!\n");
        abort();
    }
    pthread_once(&g_jmpbuf_once, bo3_jmpbuf_init);
    Bo3JmpTable *table = pthread_getspecific(g_jmpbuf_key);
    Bo3JmpSlot *empty = NULL, *dead = NULL;
    uintptr_t here = (uintptr_t)__builtin_frame_address(0);
    if (table) {
        for (size_t i = 0; i < table->cap; i++) {
            Bo3JmpSlot *slot = &table->slots[i];
            if (slot->key == guest_jmpbuf_ptr) return slot;
            if (!empty && slot->key == 0) empty = slot;
            uint64_t saved_sp = slot->words[BO3_JMPBUF_SP_WORD];
            // The native stack grows down. A saved SP below this frame has unwound.
            if (!dead && saved_sp != 0 && saved_sp < here) dead = slot;
        }
    }
    if (!create) {
        fprintf(stderr, "[bo3_longjmp] unknown guest jmp_buf=0x%llx on this thread!\n",
                (unsigned long long)guest_jmpbuf_ptr);
        abort();
    }
    if (!table) {
        table = calloc(1, sizeof(*table));
        if (!table) abort();
        if (pthread_setspecific(g_jmpbuf_key, table) != 0) {
            free(table);
            abort();
        }
    }
    Bo3JmpSlot *slot = empty ? empty : dead;
    if (!slot) {
        if (table->cap > SIZE_MAX / sizeof(*slot) / 2) abort();
        size_t cap = table->cap ? table->cap * 2 : BO3_JMPBUF_INITIAL_CAP;
        Bo3JmpSlot *slots = realloc(table->slots, cap * sizeof(*slot));
        if (!slots) abort();
        slot = &slots[table->cap];
        memset(slot, 0, (cap - table->cap) * sizeof(*slot));
        table->slots = slots;
        table->cap = cap;
    } else {
        memset(slot, 0, sizeof(*slot));
    }
    slot->key = guest_jmpbuf_ptr;
    return slot;
}

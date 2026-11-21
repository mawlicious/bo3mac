// x86_64-ABI-exact libc++ shims for Core BO3+Havok on Apple Silicon ARM64.
// CRITICAL: macOS arm64 libc++ uses _LIBCPP_ABI_ALTERNATE_STRING_LAYOUT (short len at byte 23),
// whereas x86_64 CoDBlkOps3_Exe uses default libc++ layout (short len<<1 at byte 0, data at +1)!
// All 13 std::string / std::wstring methods called by BO3 operate directly on x86_64 layout.

#include "shim_helpers.h"
#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <new>

// ---- Exact x86_64 libc++ basic_string<CharT> (24 bytes) ----
template <typename CharT>
struct X86BasicString {
    static constexpr size_t kMinCap = (sizeof(CharT) == 1) ? 23 : 5;
    union {
        struct {
            uint64_t cap;  // bit 0 == 1 means long mode; actual alloc bytes = (cap & ~1ULL) * sizeof(CharT)
            uint64_t size;
            CharT   *data;
        } l;
        struct {
            uint8_t size_tag; // bit 0 == 0; length = size_tag >> 1
            CharT   data[kMinCap];
        } s;
        uint8_t raw[24];
    };

    bool is_long() const { return (raw[0] & 1) != 0; }
    size_t size() const { return is_long() ? (size_t)l.size : (size_t)(raw[0] >> 1); }
    size_t capacity() const { return is_long() ? (size_t)((l.cap & ~1ULL) - 1) : (kMinCap - 1); }
    CharT *data() { return is_long() ? l.data : (CharT *)(raw + sizeof(CharT)); }
    const CharT *data() const { return is_long() ? l.data : (const CharT *)(raw + sizeof(CharT)); }

    // Note: for wchar_t (4 bytes), alignment of short data is +4, size_tag is at byte 0!
    // Wait: verify x86_64 libc++ __short<wchar_t>:
    //   struct __short { union { unsigned char __size_; wchar_t __lx; }; wchar_t __data_[5]; };
    //   sizeof(union) == 4, so __data_ starts at offset 4, max short len = 4 (plus NUL at [4])!
    static constexpr size_t short_data_off() { return sizeof(CharT) == 1 ? 1 : 4; }
    static constexpr size_t max_short_len()  { return sizeof(CharT) == 1 ? 22 : 4; }

    CharT *short_ptr() { return reinterpret_cast<CharT *>(raw + short_data_off()); }
    const CharT *short_ptr() const { return reinterpret_cast<const CharT *>(raw + short_data_off()); }
    CharT *buf() { return is_long() ? l.data : short_ptr(); }
    const CharT *buf() const { return is_long() ? l.data : short_ptr(); }

    void set_short_size(size_t n) {
        raw[0] = (uint8_t)(n << 1);
        short_ptr()[n] = 0;
    }

    void grow_to(size_t needed) {
        if (needed <= max_short_len() && !is_long()) return;
        if (is_long() && needed < (l.cap & ~1ULL)) return;
        size_t alloc_elems = ((needed + 1) + 15) & ~size_t(15);
        if (alloc_elems < 32) alloc_elems = 32;
        if (is_long() && alloc_elems < (l.cap & ~1ULL) * 2) alloc_elems = (l.cap & ~1ULL) * 2;
        // Ensure cap is even so (alloc_elems | 1) sets long bit cleanly
        if (alloc_elems & 1) alloc_elems++;
        CharT *nb = static_cast<CharT *>(::operator new(alloc_elems * sizeof(CharT)));
        size_t cur_sz = size();
        if (cur_sz > 0) std::memcpy(nb, buf(), cur_sz * sizeof(CharT));
        nb[cur_sz] = 0;
        if (is_long()) ::operator delete(l.data);
        l.cap = alloc_elems | 1ULL;
        l.size = cur_sz;
        l.data = nb;
    }

    void init_from(const CharT *src, size_t n) {
        std::memset(raw, 0, 24);
        if (n <= max_short_len()) {
            if (n > 0) std::memcpy(short_ptr(), src, n * sizeof(CharT));
            set_short_size(n);
        } else {
            size_t alloc_elems = ((n + 1) + 15) & ~size_t(15);
            if (alloc_elems & 1) alloc_elems++;
            CharT *nb = static_cast<CharT *>(::operator new(alloc_elems * sizeof(CharT)));
            std::memcpy(nb, src, n * sizeof(CharT));
            nb[n] = 0;
            l.cap = alloc_elems | 1ULL;
            l.size = n;
            l.data = nb;
        }
    }

    void assign_from(const CharT *src, size_t n) {
        if (src == buf() && n == size()) return;
        // Handle potential aliasing with temporary if needed
        if (n <= max_short_len() && !is_long()) {
            if (n > 0) std::memmove(short_ptr(), src, n * sizeof(CharT));
            set_short_size(n);
        } else {
            // Check overlap before grow
            const CharT *b = buf();
            size_t old_sz = size();
            if (src >= b && src < b + old_sz) {
                CharT *tmp_b = static_cast<CharT *>(::operator new((n + 1) * sizeof(CharT)));
                std::memcpy(tmp_b, src, n * sizeof(CharT));
                grow_to(n);
                std::memcpy(buf(), tmp_b, n * sizeof(CharT));
                buf()[n] = 0;
                if (is_long()) l.size = n; else set_short_size(n);
                ::operator delete(tmp_b);
                return;
            }
            grow_to(n);
            if (n > 0) std::memcpy(buf(), src, n * sizeof(CharT));
            buf()[n] = 0;
            if (is_long()) l.size = n; else set_short_size(n);
        }
    }

    void append_chars(const CharT *src, size_t n) {
        if (n == 0) return;
        size_t old_sz = size();
        size_t new_sz = old_sz + n;
        const CharT *b = buf();
        if (src >= b && src < b + old_sz) {
            CharT *tmp_b = static_cast<CharT *>(::operator new(n * sizeof(CharT)));
            std::memcpy(tmp_b, src, n * sizeof(CharT));
            grow_to(new_sz);
            std::memcpy(buf() + old_sz, tmp_b, n * sizeof(CharT));
            buf()[new_sz] = 0;
            if (is_long()) l.size = new_sz; else set_short_size(new_sz);
            ::operator delete(tmp_b);
            return;
        }
        grow_to(new_sz);
        std::memcpy(buf() + old_sz, src, n * sizeof(CharT));
        buf()[new_sz] = 0;
        if (is_long()) l.size = new_sz; else set_short_size(new_sz);
    }

    void append_fill(size_t n, CharT ch) {
        if (n == 0) return;
        size_t old_sz = size();
        size_t new_sz = old_sz + n;
        grow_to(new_sz);
        CharT *d = buf() + old_sz;
        for (size_t i = 0; i < n; i++) d[i] = ch;
        buf()[new_sz] = 0;
        if (is_long()) l.size = new_sz; else set_short_size(new_sz);
    }

    void erase_range(size_t pos, size_t count) {
        size_t cur_sz = size();
        if (pos >= cur_sz) return;
        size_t n = (count > cur_sz - pos) ? (cur_sz - pos) : count;
        size_t tail = cur_sz - (pos + n);
        CharT *d = buf();
        if (tail > 0) std::memmove(d + pos, d + pos + n, tail * sizeof(CharT));
        size_t new_sz = cur_sz - n;
        d[new_sz] = 0;
        if (is_long()) l.size = new_sz; else set_short_size(new_sz);
    }
};

using X86String  = X86BasicString<char>;
using X86WString = X86BasicString<wchar_t>;

static_assert(sizeof(X86String) == 24, "X86String must be 24 bytes");
static_assert(sizeof(X86WString) == 24, "X86WString must be 24 bytes");

// ---- C++ ABI Guards (non-deadlocking Itanium ABI per-guard state!) ----
// Guard word byte 0 = initialized (1), byte 1 = initialization-in-progress (1).
static std::mutex g_guard_mtx;
static std::condition_variable g_guard_cv;

extern "C" {

// __cxa_guard_acquire(int64_t *guard): returns 1 if caller should initialize, 0 if already done
SHIM_DEF(shim____cxa_guard_acquire) {
    SHIM_UNUSED_ALL();
    auto *g = reinterpret_cast<volatile uint8_t *>(rdi);
    if (__atomic_load_n(&g[0], __ATOMIC_ACQUIRE) != 0) return ret_u64(0);
    std::unique_lock<std::mutex> lk(g_guard_mtx);
    while (__atomic_load_n(&g[0], __ATOMIC_RELAXED) == 0 && g[1] != 0) {
        g_guard_cv.wait(lk);
    }
    if (__atomic_load_n(&g[0], __ATOMIC_RELAXED) != 0) {
        return ret_u64(0);
    }
    g[1] = 1; // mark in-progress and UNLOCK so nested static initializers never deadlock!
    return ret_u64(1);
}

SHIM_DEF(shim____cxa_guard_release) {
    SHIM_UNUSED_ALL();
    auto *g = reinterpret_cast<volatile uint8_t *>(rdi);
    {
        std::lock_guard<std::mutex> lk(g_guard_mtx);
        g[1] = 0;
        __atomic_store_n(&g[0], (uint8_t)1, __ATOMIC_RELEASE);
    }
    g_guard_cv.notify_all();
    return ret_void();
}

SHIM_DEF(shim____cxa_guard_abort) {
    SHIM_UNUSED_ALL();
    auto *g = reinterpret_cast<volatile uint8_t *>(rdi);
    {
        std::lock_guard<std::mutex> lk(g_guard_mtx);
        g[1] = 0;
    }
    g_guard_cv.notify_all();
    return ret_void();
}

// ---- operator new / delete ----
SHIM_DEF(shim___Znwm)  { SHIM_UNUSED_ALL(); return ret_ptr(::operator new((size_t)rdi)); }
SHIM_DEF(shim___Znam)  { SHIM_UNUSED_ALL(); return ret_ptr(::operator new[]((size_t)rdi)); }
SHIM_DEF(shim___ZdlPv) { SHIM_UNUSED_ALL(); ::operator delete(reinterpret_cast<void *>(rdi)); return ret_void(); }
SHIM_DEF(shim___ZdaPv) { SHIM_UNUSED_ALL(); ::operator delete[](reinterpret_cast<void *>(rdi)); return ret_void(); }

// ---- std::string (char) x86_64 layout shims ----
SHIM_DEF(shim___ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEC1ERKS5_) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86String *>(rdi);
    const auto *src = reinterpret_cast<const X86String *>(rsi);
    dst->init_from(src->buf(), src->size());
    return ret_ptr(dst);
}
SHIM_DEF(shim___ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEaSERKS5_) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86String *>(rdi);
    const auto *src = reinterpret_cast<const X86String *>(rsi);
    dst->assign_from(src->buf(), src->size());
    return ret_ptr(dst);
}
SHIM_DEF(shim___ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6assignEPKc) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86String *>(rdi);
    const char *s = reinterpret_cast<const char *>(rsi);
    dst->assign_from(s ? s : "", s ? std::strlen(s) : 0);
    return ret_ptr(dst);
}
SHIM_DEF(shim___ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendEPKc) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86String *>(rdi);
    const char *s = reinterpret_cast<const char *>(rsi);
    if (s) dst->append_chars(s, std::strlen(s));
    return ret_ptr(dst);
}
SHIM_DEF(shim___ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendEmc) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86String *>(rdi);
    dst->append_fill((size_t)rsi, (char)rdx);
    return ret_ptr(dst);
}
SHIM_DEF(shim___ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE9push_backEc) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86String *>(rdi);
    dst->append_fill(1, (char)rsi);
    return ret_void();
}
SHIM_DEF(shim___ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE5eraseEmm) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86String *>(rdi);
    dst->erase_range((size_t)rsi, (size_t)rdx);
    return ret_ptr(dst);
}
SHIM_DEF(shim___ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE7reserveEm) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86String *>(rdi);
    if (rsi > 0) dst->grow_to((size_t)rsi);
    return ret_void();
}

// ---- std::wstring (wchar_t) x86_64 layout shims ----
SHIM_DEF(shim___ZNSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEE6__initEPKwm) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86WString *>(rdi);
    const wchar_t *s = reinterpret_cast<const wchar_t *>(rsi);
    dst->init_from(s ? s : L"", (size_t)rdx);
    return ret_void();
}
SHIM_DEF(shim___ZNSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEE6appendEmw) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86WString *>(rdi);
    dst->append_fill((size_t)rsi, (wchar_t)rdx);
    return ret_ptr(dst);
}
SHIM_DEF(shim___ZNSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEE9push_backEw) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86WString *>(rdi);
    dst->append_fill(1, (wchar_t)rsi);
    return ret_void();
}
SHIM_DEF(shim___ZNSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEE7reserveEm) {
    SHIM_UNUSED_ALL();
    auto *dst = reinterpret_cast<X86WString *>(rdi);
    if (rsi > 0) dst->grow_to((size_t)rsi);
    return ret_void();
}
SHIM_DEF(shim___ZNKSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEE4findEwm) {
    SHIM_UNUSED_ALL();
    const auto *s = reinterpret_cast<const X86WString *>(rdi);
    wchar_t ch = (wchar_t)rsi;
    size_t pos = (size_t)rdx;
    size_t sz = s->size();
    const wchar_t *b = s->buf();
    for (size_t i = pos; i < sz; i++) {
        if (b[i] == ch) return ret_u64(i);
    }
    return ret_u64(~0ULL);
}

// ---- std::__1::__sort instantiations ----
SHIM_DEF(shim___ZNSt3__16__sortIRNS_6__lessImmEEPmEEvT0_S5_T_) {
    SHIM_UNUSED_ALL();
    std::sort(reinterpret_cast<uint64_t *>(rdi), reinterpret_cast<uint64_t *>(rsi));
    return ret_void();
}
SHIM_DEF(shim___ZNSt3__16__sortIRNS_6__lessIjjEEPjEEvT0_S5_T_) {
    SHIM_UNUSED_ALL();
    std::sort(reinterpret_cast<uint32_t *>(rdi), reinterpret_cast<uint32_t *>(rsi));
    return ret_void();
}

// ---- std::random_device (__rs_default / __rs_get) ----
static uint64_t g_rs_dummy = 0;
SHIM_DEF(shim___ZNSt3__18__rs_getEv) { SHIM_UNUSED_ALL(); return ret_ptr(&g_rs_dummy); }
SHIM_DEF(shim___ZNSt3__112__rs_defaultclEv) { SHIM_UNUSED_ALL(); return ret_u64(arc4random()); }
SHIM_DEF(shim___ZNSt3__112__rs_defaultD1Ev) { SHIM_UNUSED_ALL(); return ret_void(); }

// ---- Exception & Terminate stubs ----
SHIM_DEF(shim___ZNKSt3__121__basic_string_commonILb1EE20__throw_length_errorEv) {
    SHIM_UNUSED_ALL(); std::fprintf(stderr, "[bo3_cxx] std::string length_error\n"); std::abort();
}
SHIM_DEF(shim___ZNKSt3__120__vector_base_commonILb1EE20__throw_length_errorEv) {
    SHIM_UNUSED_ALL(); std::fprintf(stderr, "[bo3_cxx] std::vector length_error\n"); std::abort();
}
SHIM_DEF(shim___ZNSt11logic_errorC2EPKc) { SHIM_UNUSED_ALL(); return ret_ptr((void *)rdi); }
SHIM_DEF(shim___ZNSt9exceptionD2Ev) { SHIM_UNUSED_ALL(); return ret_void(); }
SHIM_DEF(shim____cxa_allocate_exception) { SHIM_UNUSED_ALL(); return ret_ptr(std::calloc(1, (size_t)rdi + 128)); }
SHIM_DEF(shim____cxa_free_exception) { SHIM_UNUSED_ALL(); std::free(reinterpret_cast<void *>(rdi)); return ret_void(); }
SHIM_DEF(shim____cxa_throw) {
    SHIM_UNUSED_ALL();
    std::fprintf(stderr, "[bo3_cxx] __cxa_throw obj=0x%llx tinfo=0x%llx\n", (unsigned long long)rdi, (unsigned long long)rsi);
    std::abort();
}
SHIM_DEF(shim____cxa_begin_catch) { SHIM_UNUSED_ALL(); return ret_ptr(reinterpret_cast<void *>(rdi)); }
SHIM_DEF(shim____cxa_end_catch) { SHIM_UNUSED_ALL(); return ret_void(); }
SHIM_DEF(shim____cxa_call_unexpected) { SHIM_UNUSED_ALL(); std::abort(); }
SHIM_DEF(shim___Unwind_Resume) { SHIM_UNUSED_ALL(); std::fprintf(stderr, "[bo3_cxx] _Unwind_Resume\n"); std::abort(); }
SHIM_DEF(shim___ZSt9terminatev) { SHIM_UNUSED_ALL(); std::fprintf(stderr, "[bo3_cxx] std::terminate\n"); std::abort(); }

} // extern "C"

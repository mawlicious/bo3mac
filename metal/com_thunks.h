#pragma once
#include "shim_helpers.h"
#include "d3d11_abi.h"
#include <atomic>
#include <stddef.h>
#include <stdint.h>

// COM Guest Vtable & Synthetic VA Thunk Allocator.
// CRITICAL ABI INVARIANT: offset 0 of every COM object MUST be `uint64_t *vtable;`
// (no C++ virtual functions on Bo3ComBase, so no compiler vptr precedes `vtable`).
// Each vtable slot stores a synthetic guest VA in [0xF00000000000, 0xF00000100000) registered
// with bo3_register_fn() so lifted x86_64 indirect calls `callq *offset(%rax)` dispatch
// straight into native ARM64 methods.

struct Bo3ComBase;
typedef uint32_t (*Bo3ComQueryFn)(Bo3ComBase *self, const Bo3GUID *riid, void **ppv);
typedef void     (*Bo3ComDestroyFn)(Bo3ComBase *self);

struct Bo3ComBase {
    uint64_t            *vtable;       // offset 0x00: guest COM vtable pointer
    std::atomic<int32_t> refcount;
    const char          *debug_name;
    Bo3ComQueryFn        qi_fn;
    Bo3ComDestroyFn      destroy_fn;

    void init_com(uint64_t *vt, const char *name, Bo3ComQueryFn qi, Bo3ComDestroyFn dtor) {
        vtable = vt;
        refcount.store(1, std::memory_order_relaxed);
        debug_name = name;
        qi_fn = qi;
        destroy_fn = dtor;
    }

    int32_t add_ref() {
        return refcount.fetch_add(1, std::memory_order_relaxed) + 1;
    }

    // AddRef only if the object is still alive (refcount > 0); never resurrects a dying object.
    bool try_add_ref() {
        int32_t cur = refcount.load(std::memory_order_acquire);
        while (cur > 0) {
            if (refcount.compare_exchange_weak(cur, cur + 1, std::memory_order_acq_rel)) return true;
        }
        return false;
    }

    int32_t release() {
        int32_t r = refcount.fetch_sub(1, std::memory_order_acq_rel) - 1;
        if (r == 0 && destroy_fn) {
            destroy_fn(this);
        }
        return r;
    }

    uint32_t query_interface(const Bo3GUID *riid, void **ppv) {
        if (qi_fn) return qi_fn(this, riid, ppv);
        if (ppv) *ppv = nullptr;
        return BO3_E_NOINTERFACE;
    }
};

static_assert(offsetof(Bo3ComBase, vtable) == 0, "Bo3ComBase::vtable MUST be at offset 0!");

// Allocate a unique synthetic guest VA in [0xF00000000000, 0xF00000100000) and register `fn`.
uint64_t bo3_com_register_thunk(GuestFn fn);

// Build a vtable of `num_slots` entries initialized with tracing stubs (logs first call per slot),
// with IUnknown slots 0..2 wired to Bo3ComBase::query_interface / add_ref / release.
void bo3_com_init_vtable(uint64_t *vtable, int num_slots, const char *iface_name);

// Override one vtable slot with a concrete GuestFn implementation.
static inline void bo3_com_set_slot(uint64_t *vtable, int slot, GuestFn fn) {
    vtable[slot] = bo3_com_register_thunk(fn);
}

bool bo3_guid_eq(const Bo3GUID *a, const Bo3GUID *b);

// Well-known DXGI / D3D11 IIDs
extern const Bo3GUID BO3_IID_IUnknown;
extern const Bo3GUID BO3_IID_IDXGIObject;
extern const Bo3GUID BO3_IID_IDXGIDeviceSubObject;
extern const Bo3GUID BO3_IID_IDXGIResource;
extern const Bo3GUID BO3_IID_IDXGISurface;
extern const Bo3GUID BO3_IID_IDXGIAdapter;
extern const Bo3GUID BO3_IID_IDXGIAdapter1;
extern const Bo3GUID BO3_IID_IDXGIOutput;
extern const Bo3GUID BO3_IID_IDXGISwapChain;
extern const Bo3GUID BO3_IID_IDXGIFactory;
extern const Bo3GUID BO3_IID_IDXGIFactory1;
extern const Bo3GUID BO3_IID_IDXGIDevice;
extern const Bo3GUID BO3_IID_IDXGIDevice1;
extern const Bo3GUID BO3_IID_IDXGIDevice2;
extern const Bo3GUID BO3_IID_ID3D11Device;
extern const Bo3GUID BO3_IID_ID3D11DeviceContext;
extern const Bo3GUID BO3_IID_ID3D11Resource;
extern const Bo3GUID BO3_IID_ID3D11Buffer;
extern const Bo3GUID BO3_IID_ID3D11Texture2D;
extern const Bo3GUID BO3_IID_ID3D11Texture3D;

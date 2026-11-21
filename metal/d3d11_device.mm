#import <Metal/Metal.h>
#include "d3d11_metal.h"
#include "settings_mac.h"
#include "window_mac.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <vector>

// =========================================================================
// Vtables for ID3D11Device and all child resource/view/state COM objects
// =========================================================================

static uint64_t g_vt_device[48];
static uint64_t g_vt_buffer[16];
static uint64_t g_vt_tex1d[16];
static uint64_t g_vt_tex2d[16];
static uint64_t g_vt_tex3d[16];
static uint64_t g_vt_srv[16];
static uint64_t g_vt_rtv[16];
static uint64_t g_vt_dsv[16];
static uint64_t g_vt_uav[16];
static uint64_t g_vt_shader[12];
static uint64_t g_vt_input_layout[12];
static uint64_t g_vt_blend_state[12];
static uint64_t g_vt_ds_state[12];
static uint64_t g_vt_rs_state[12];
static uint64_t g_vt_sampler_state[12];
static uint64_t g_vt_query[12];

uint64_t *bo3_vtable_buffer(void)        { return g_vt_buffer; }
uint64_t *bo3_vtable_texture2d(void)     { return g_vt_tex2d; }
uint64_t *bo3_vtable_texture3d(void)     { return g_vt_tex3d; }
uint64_t *bo3_vtable_srv(void)           { return g_vt_srv; }
uint64_t *bo3_vtable_rtv(void)           { return g_vt_rtv; }
uint64_t *bo3_vtable_dsv(void)           { return g_vt_dsv; }
uint64_t *bo3_vtable_uav(void)           { return g_vt_uav; }
uint64_t *bo3_vtable_shader(void)        { return g_vt_shader; }
uint64_t *bo3_vtable_input_layout(void)  { return g_vt_input_layout; }
uint64_t *bo3_vtable_blend_state(void)   { return g_vt_blend_state; }
uint64_t *bo3_vtable_ds_state(void)      { return g_vt_ds_state; }
uint64_t *bo3_vtable_rs_state(void)      { return g_vt_rs_state; }
uint64_t *bo3_vtable_sampler_state(void) { return g_vt_sampler_state; }
uint64_t *bo3_vtable_query(void)         { return g_vt_query; }

// =========================================================================
// Texture helpers & View Adapter Cache
// =========================================================================

id<MTLTexture> Bo3MetalTexture::current_mtl_texture() {
    if (is_backbuffer) {
        // Shared state outlives the swap chain -> never dereferences a destroyed Bo3MetalSwapChain
        return sc_state ? sc_state->acquire() : nil;
    }
    return mtl_tex;
}

uint32_t Bo3MetalTexture::d3d_mip_levels() const {
    if (is_backbuffer) return 1u;
    if (res.dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D) return std::max(1u, desc3d.MipLevels);
    if (res.dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE1D) return std::max(1u, desc1d.MipLevels);
    return std::max(1u, desc2d.MipLevels);
}

id<MTLTexture> Bo3MetalTexture::get_or_create_view(MTLPixelFormat fmt, MTLTextureType type,
                                                   uint32_t mip_start, uint32_t mip_len,
                                                   uint32_t slice_start, uint32_t slice_len,
                                                   uint32_t swizzle) {
    id<MTLTexture> base = current_mtl_texture();
    if (!base) return nil;
    if (fmt == MTLPixelFormatInvalid) fmt = base.pixelFormat;
    // M5: fully typed color textures no longer carry MTLTextureUsagePixelFormatView (lossless
    // compression). A reinterpreting view request that Metal would reject degrades to the base
    // format (identical to D3D11 semantics for every legal non-typeless view) instead of asserting.
    if (!bo3_mtl_can_view_as(base.pixelFormat, base.usage, fmt)) {
        static std::atomic<int> warn{0};
        if (warn.fetch_add(1, std::memory_order_relaxed) < 8) {
            fprintf(stderr, "[metal-dev] view fmt %lu on base fmt %lu without PixelFormatView -> using base format\n",
                    (unsigned long)fmt, (unsigned long)base.pixelFormat);
            fflush(stderr);
        }
        fmt = base.pixelFormat;
    }
    uint64_t total_mips = (uint64_t)base.mipmapLevelCount;
    if (mip_start >= total_mips) mip_start = 0;
    if (mip_len == 0 || (uint64_t)mip_start + (uint64_t)mip_len > total_mips) {
        mip_len = (uint32_t)(total_mips - mip_start);
    }
    uint64_t max_slices = (uint64_t)base.arrayLength;
    if (base.textureType == MTLTextureTypeCube) max_slices = 6;
    else if (base.textureType == MTLTextureTypeCubeArray) max_slices *= 6;
    if (slice_start >= max_slices) slice_start = 0;
    if (slice_len == 0 || (uint64_t)slice_start + (uint64_t)slice_len > max_slices) {
        slice_len = (uint32_t)(max_slices - slice_start);
    }

    // Fast path: matches base texture identically
    if (fmt == base.pixelFormat && type == base.textureType &&
        mip_start == 0 && mip_len == total_mips &&
        slice_start == 0 && slice_len == max_slices && swizzle == BO3_SWIZZLE_IDENTITY) {
        return base;
    }

    Bo3TexViewKey key{fmt, type, (uint16_t)mip_start, (uint16_t)mip_len,
                      (uint16_t)slice_start, (uint16_t)slice_len, swizzle};
    os_unfair_lock_lock(&view_lock);
    auto it = view_cache.find(key);
    if (it != view_cache.end()) {
        id<MTLTexture> cached = it->second;
        os_unfair_lock_unlock(&view_lock);
        return cached;
    }
    id<MTLTexture> v = nil;
    if (swizzle != BO3_SWIZZLE_IDENTITY) {
        MTLTextureSwizzleChannels sw = MTLTextureSwizzleChannelsMake(
            (MTLTextureSwizzle)(swizzle & 0xffu), (MTLTextureSwizzle)((swizzle >> 8) & 0xffu),
            (MTLTextureSwizzle)((swizzle >> 16) & 0xffu), (MTLTextureSwizzle)((swizzle >> 24) & 0xffu));
        v = [base newTextureViewWithPixelFormat:fmt
                                    textureType:type
                                         levels:NSMakeRange(mip_start, mip_len)
                                         slices:NSMakeRange(slice_start, slice_len)
                                        swizzle:sw];
    }
    if (!v) {
        v = [base newTextureViewWithPixelFormat:fmt
                                    textureType:type
                                         levels:NSMakeRange(mip_start, mip_len)
                                         slices:NSMakeRange(slice_start, slice_len)];
    }
    if (!v) v = base; // graceful fallback
    view_cache[key] = v;
    os_unfair_lock_unlock(&view_lock);
    return v;
}

// =========================================================================
// Device Internal Refcounting & Resource/View Type-Specific COM Boilerplate
// =========================================================================

void Bo3MetalDevice::add_internal_ref() {
    internal_refs.fetch_add(1, std::memory_order_relaxed);
}

void Bo3MetalDevice::release_internal_ref() {
    if (internal_refs.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        bo3_shader_cache_flush_sync(); // M5: persist PSO archive + reflection cache on device teardown
        if (dxgi_adapter) {
            ((Bo3ComBase *)dxgi_adapter)->release();
            dxgi_adapter = nullptr;
        }
        delete this;
    }
}

void Bo3MetalDevice::add_external_ref() {
    int32_t prev = com.refcount.fetch_add(1, std::memory_order_acq_rel);
    if (prev == 0) {
        // Resurrected via a surviving child (e.g. ctx->GetDevice): re-take the internal ref and,
        // if the immediate context is still alive, re-attach the device's owning ref on it so
        // GetImmediateContext keeps working and the next device_dtor stays balanced.
        add_internal_ref();
        os_unfair_lock_lock(&ctx_lock);
        if (immediate_ctx && !holds_ctx_ref && ((Bo3ComBase *)immediate_ctx)->try_add_ref()) {
            holds_ctx_ref = true;
        }
        os_unfair_lock_unlock(&ctx_lock);
    }
}

static uint32_t match_qi_2(Bo3ComBase *self, const Bo3GUID *riid, void **ppv,
                           const Bo3GUID &a, const Bo3GUID &b) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_ID3D11DeviceChild) ||
        bo3_guid_eq(riid, &a) || bo3_guid_eq(riid, &b)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static uint32_t buffer_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_ID3D11DeviceChild) ||
        bo3_guid_eq(riid, &BO3_IID_ID3D11Resource) || bo3_guid_eq(riid, &BO3_IID_ID3D11Buffer)) {
        self->add_ref(); *ppv = self; return BO3_S_OK;
    }
    *ppv = nullptr; return BO3_E_NOINTERFACE;
}
static uint32_t tex1d_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_ID3D11DeviceChild) ||
        bo3_guid_eq(riid, &BO3_IID_ID3D11Resource) || bo3_guid_eq(riid, &BO3_IID_ID3D11Texture1D)) {
        self->add_ref(); *ppv = self; return BO3_S_OK;
    }
    *ppv = nullptr; return BO3_E_NOINTERFACE;
}
static uint32_t tex2d_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_ID3D11DeviceChild) ||
        bo3_guid_eq(riid, &BO3_IID_ID3D11Resource) || bo3_guid_eq(riid, &BO3_IID_ID3D11Texture2D)) {
        self->add_ref(); *ppv = self; return BO3_S_OK;
    }
    *ppv = nullptr; return BO3_E_NOINTERFACE;
}
static uint32_t tex3d_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_ID3D11DeviceChild) ||
        bo3_guid_eq(riid, &BO3_IID_ID3D11Resource) || bo3_guid_eq(riid, &BO3_IID_ID3D11Texture3D)) {
        self->add_ref(); *ppv = self; return BO3_S_OK;
    }
    *ppv = nullptr; return BO3_E_NOINTERFACE;
}
// NOTE: IDXGIResource / IDXGISurface(1) / IDXGIResource1 are intentionally NOT returned by the
// resource QIs above: handing back the raw ID3D11 vtable for a DXGI interface would route e.g.
// IDXGISurface::Map (slot 10) into ID3D11Texture2D::GetDesc and return S_OK with an
// uninitialized DXGI_MAPPED_RECT. E_NOINTERFACE is the correct, safe answer until a dedicated
// DXGI surface wrapper vtable exists.
static uint32_t srv_qi(Bo3ComBase *s, const Bo3GUID *r, void **p) { return match_qi_2(s, r, p, BO3_IID_ID3D11View, BO3_IID_ID3D11ShaderResourceView); }
static uint32_t rtv_qi(Bo3ComBase *s, const Bo3GUID *r, void **p) { return match_qi_2(s, r, p, BO3_IID_ID3D11View, BO3_IID_ID3D11RenderTargetView); }
static uint32_t dsv_qi(Bo3ComBase *s, const Bo3GUID *r, void **p) { return match_qi_2(s, r, p, BO3_IID_ID3D11View, BO3_IID_ID3D11DepthStencilView); }
static uint32_t uav_qi(Bo3ComBase *s, const Bo3GUID *r, void **p) { return match_qi_2(s, r, p, BO3_IID_ID3D11View, BO3_IID_ID3D11UnorderedAccessView); }
static uint32_t il_qi(Bo3ComBase *s, const Bo3GUID *r, void **p)  { return match_qi_2(s, r, p, BO3_IID_ID3D11InputLayout, BO3_IID_ID3D11InputLayout); }
static uint32_t bs_qi(Bo3ComBase *s, const Bo3GUID *r, void **p)  { return match_qi_2(s, r, p, BO3_IID_ID3D11BlendState, BO3_IID_ID3D11BlendState); }
static uint32_t ds_qi(Bo3ComBase *s, const Bo3GUID *r, void **p)  { return match_qi_2(s, r, p, BO3_IID_ID3D11DepthStencilState, BO3_IID_ID3D11DepthStencilState); }
static uint32_t rs_qi(Bo3ComBase *s, const Bo3GUID *r, void **p)  { return match_qi_2(s, r, p, BO3_IID_ID3D11RasterizerState, BO3_IID_ID3D11RasterizerState); }
static uint32_t smp_qi(Bo3ComBase *s, const Bo3GUID *r, void **p) { return match_qi_2(s, r, p, BO3_IID_ID3D11SamplerState, BO3_IID_ID3D11SamplerState); }
static uint32_t qry_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_ID3D11DeviceChild) ||
        bo3_guid_eq(riid, &BO3_IID_ID3D11Asynchronous) || bo3_guid_eq(riid, &BO3_IID_ID3D11Query) ||
        bo3_guid_eq(riid, &BO3_IID_ID3D11Predicate)) {
        self->add_ref(); *ppv = self; return BO3_S_OK;
    }
    *ppv = nullptr; return BO3_E_NOINTERFACE;
}

static void buffer_dtor(Bo3ComBase *self) {
    Bo3MetalBuffer *b = (Bo3MetalBuffer *)self;
    Bo3MetalDevice *dev = b->res.device;
    delete b;
    if (dev) dev->release_internal_ref();
}
static void tex_dtor(Bo3ComBase *self) {
    Bo3MetalTexture *t = (Bo3MetalTexture *)self;
    Bo3MetalDevice *dev = t->res.device;
    delete t;
    if (dev) dev->release_internal_ref();
}
static void srv_dtor(Bo3ComBase *self) {
    Bo3MetalSRV *v = (Bo3MetalSRV *)self;
    Bo3MetalDevice *dev = v->device;
    if (v->resource) v->resource->com.release();
    delete v;
    if (dev) dev->release_internal_ref();
}
static void rtv_dtor(Bo3ComBase *self) {
    Bo3MetalRTV *v = (Bo3MetalRTV *)self;
    Bo3MetalDevice *dev = v->device;
    if (v->resource) v->resource->com.release();
    delete v;
    if (dev) dev->release_internal_ref();
}
static void dsv_dtor(Bo3ComBase *self) {
    Bo3MetalDSV *v = (Bo3MetalDSV *)self;
    Bo3MetalDevice *dev = v->device;
    if (v->resource) v->resource->com.release();
    delete v;
    if (dev) dev->release_internal_ref();
}
static void uav_dtor(Bo3ComBase *self) {
    Bo3MetalUAV *v = (Bo3MetalUAV *)self;
    Bo3MetalDevice *dev = v->device;
    if (v->resource) v->resource->com.release();
    delete v;
    if (dev) dev->release_internal_ref();
}
static void il_dtor(Bo3ComBase *self) {
    auto *o = (Bo3MetalInputLayout *)self; Bo3MetalDevice *d = o->device; delete o; if (d) d->release_internal_ref();
}
static void bs_dtor(Bo3ComBase *self) {
    auto *o = (Bo3MetalBlendState *)self; Bo3MetalDevice *d = o->device; delete o; if (d) d->release_internal_ref();
}
static void ds_dtor(Bo3ComBase *self) {
    auto *o = (Bo3MetalDepthStencilState *)self; Bo3MetalDevice *d = o->device; delete o; if (d) d->release_internal_ref();
}
static void rs_dtor(Bo3ComBase *self) {
    auto *o = (Bo3MetalRasterizerState *)self; Bo3MetalDevice *d = o->device; delete o; if (d) d->release_internal_ref();
}
static void smp_dtor(Bo3ComBase *self) {
    auto *o = (Bo3MetalSamplerState *)self; Bo3MetalDevice *d = o->device; delete o; if (d) d->release_internal_ref();
}
static void qry_dtor(Bo3ComBase *self) {
    auto *o = (Bo3MetalQuery *)self; Bo3MetalDevice *d = o->device; delete o; if (d) d->release_internal_ref();
}

// ID3D11DeviceChild::GetDevice (slot 3) for resources & all non-resource children
static SHIM_DEF(res_get_device) {
    SHIM_UNUSED_ALL();
    Bo3MetalResource *r = (Bo3MetalResource *)rdi;
    if (rsi) {
        if (r && r->device) r->device->add_external_ref();
        *(void **)rsi = r ? r->device : nullptr;
    }
    return ret_void();
}

struct Bo3ChildPrefix {
    Bo3ComBase      com;
    Bo3MetalDevice *device;
};
static_assert(offsetof(Bo3MetalSRV, device) == offsetof(Bo3ChildPrefix, device), "SRV device offset");
static_assert(offsetof(Bo3MetalRTV, device) == offsetof(Bo3ChildPrefix, device), "RTV device offset");
static_assert(offsetof(Bo3MetalDSV, device) == offsetof(Bo3ChildPrefix, device), "DSV device offset");
static_assert(offsetof(Bo3MetalUAV, device) == offsetof(Bo3ChildPrefix, device), "UAV device offset");
static_assert(offsetof(Bo3MetalShader, device) == offsetof(Bo3ChildPrefix, device), "Shader device offset");
static_assert(offsetof(Bo3MetalInputLayout, device) == offsetof(Bo3ChildPrefix, device), "IL device offset");
static_assert(offsetof(Bo3MetalBlendState, device) == offsetof(Bo3ChildPrefix, device), "BS device offset");
static_assert(offsetof(Bo3MetalDepthStencilState, device) == offsetof(Bo3ChildPrefix, device), "DS device offset");
static_assert(offsetof(Bo3MetalRasterizerState, device) == offsetof(Bo3ChildPrefix, device), "RS device offset");
static_assert(offsetof(Bo3MetalSamplerState, device) == offsetof(Bo3ChildPrefix, device), "SMP device offset");
static_assert(offsetof(Bo3MetalQuery, device) == offsetof(Bo3ChildPrefix, device), "Query device offset");

static SHIM_DEF(child_get_device) {
    SHIM_UNUSED_ALL();
    Bo3ChildPrefix *ch = (Bo3ChildPrefix *)rdi;
    if (rsi) {
        if (ch && ch->device) ch->device->add_external_ref();
        *(void **)rsi = ch ? ch->device : nullptr;
    }
    return ret_void();
}
// ID3D11Resource::GetType (slot 7)
static SHIM_DEF(res_get_type) {
    SHIM_UNUSED_ALL();
    Bo3MetalResource *r = (Bo3MetalResource *)rdi;
    if (rsi) *(uint32_t *)rsi = r->dimension;
    return ret_void();
}
// ID3D11Buffer::GetDesc (slot 10)
static SHIM_DEF(buf_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalBuffer *b = (Bo3MetalBuffer *)rdi;
    if (rsi) memcpy((void *)rsi, &b->desc, sizeof(b->desc));
    return ret_void();
}
// ID3D11Texture1D::GetDesc (slot 10) — exact 32-byte D3D11_TEXTURE1D_DESC!
static SHIM_DEF(tex1d_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalTexture *t = (Bo3MetalTexture *)rdi;
    if (rsi) memcpy((void *)rsi, &t->desc1d, sizeof(t->desc1d));
    return ret_void();
}
// ID3D11Texture2D::GetDesc (slot 10)
static SHIM_DEF(tex2d_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalTexture *t = (Bo3MetalTexture *)rdi;
    if (rsi) memcpy((void *)rsi, &t->desc2d, sizeof(t->desc2d));
    return ret_void();
}
// ID3D11Texture3D::GetDesc (slot 10)
static SHIM_DEF(tex3d_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalTexture *t = (Bo3MetalTexture *)rdi;
    if (rsi) memcpy((void *)rsi, &t->desc3d, sizeof(t->desc3d));
    return ret_void();
}
// ID3D11Asynchronous::GetDataSize (slot 7)
static SHIM_DEF(qry_get_data_size) {
    SHIM_UNUSED_ALL();
    Bo3MetalQuery *q = (Bo3MetalQuery *)rdi;
    if (!q) return ret_u64(4);
    switch (q->desc.Query) {
        case BO3_D3D11_QUERY_EVENT:               return ret_u64(4);
        case BO3_D3D11_QUERY_OCCLUSION:           return ret_u64(8);
        case BO3_D3D11_QUERY_OCCLUSION_PREDICATE: return ret_u64(4);
        case BO3_D3D11_QUERY_TIMESTAMP:           return ret_u64(8);
        case BO3_D3D11_QUERY_TIMESTAMP_DISJOINT:  return ret_u64(sizeof(Bo3D3D11_QUERY_DATA_TIMESTAMP_DISJOINT));
        case BO3_D3D11_QUERY_PIPELINE_STATISTICS: return ret_u64(88);
        default:                                  return ret_u64(8);
    }
}
// ID3D11Query::GetDesc (slot 8)
static SHIM_DEF(qry_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalQuery *q = (Bo3MetalQuery *)rdi;
    if (rsi && q) memcpy((void *)rsi, &q->desc, sizeof(q->desc));
    return ret_void();
}
// ID3D11{Blend,DepthStencil,Rasterizer,Sampler}State::GetDesc (slot 7)
static SHIM_DEF(bs_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalBlendState *o = (Bo3MetalBlendState *)rdi;
    if (rsi && o) memcpy((void *)rsi, &o->desc, sizeof(o->desc));
    return ret_void();
}
static SHIM_DEF(ds_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalDepthStencilState *o = (Bo3MetalDepthStencilState *)rdi;
    if (rsi && o) memcpy((void *)rsi, &o->desc, sizeof(o->desc));
    return ret_void();
}
static SHIM_DEF(rs_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalRasterizerState *o = (Bo3MetalRasterizerState *)rdi;
    if (rsi && o) memcpy((void *)rsi, &o->desc, sizeof(o->desc));
    return ret_void();
}
static SHIM_DEF(smp_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalSamplerState *o = (Bo3MetalSamplerState *)rdi;
    if (rsi && o) memcpy((void *)rsi, &o->desc, sizeof(o->desc));
    return ret_void();
}
// ID3D11DeviceChild::GetPrivateData (slot 4) / ID3D11Device::GetPrivateData (slot 34):
// (guid, pDataSize, pData) -> no private data is ever stored.
static SHIM_DEF(any_get_private_data) {
    SHIM_UNUSED_ALL();
    uint32_t *p_size = (uint32_t *)rdx;
    if (p_size) *p_size = 0;
    return ret_u64(BO3_DXGI_ERROR_NOT_FOUND);
}
// SetPrivateData / SetPrivateDataInterface (slots 5/6, device 35/36): accept & ignore
static SHIM_DEF(any_set_private_data) {
    SHIM_UNUSED_ALL();
    return ret_u64(BO3_S_OK);
}
// ID3D11Resource::SetEvictionPriority (slot 8) / GetEvictionPriority (slot 9)
static SHIM_DEF(res_set_eviction) { SHIM_UNUSED_ALL(); return ret_void(); }
static SHIM_DEF(res_get_eviction) { SHIM_UNUSED_ALL(); return ret_u64(0x78000000u); /* DXGI_RESOURCE_PRIORITY_NORMAL */ }

// ID3D11View::GetResource (slot 7)
static SHIM_DEF(view_srv_get_res) {
    SHIM_UNUSED_ALL();
    Bo3MetalSRV *v = (Bo3MetalSRV *)rdi;
    if (rsi) { if (v->resource) v->resource->com.add_ref(); *(void **)rsi = v->resource; }
    return ret_void();
}
static SHIM_DEF(view_rtv_get_res) {
    SHIM_UNUSED_ALL();
    Bo3MetalRTV *v = (Bo3MetalRTV *)rdi;
    if (rsi) { if (v->resource) v->resource->com.add_ref(); *(void **)rsi = v->resource; }
    return ret_void();
}
static SHIM_DEF(view_dsv_get_res) {
    SHIM_UNUSED_ALL();
    Bo3MetalDSV *v = (Bo3MetalDSV *)rdi;
    if (rsi) { if (v->resource) v->resource->com.add_ref(); *(void **)rsi = v->resource; }
    return ret_void();
}
static SHIM_DEF(view_uav_get_res) {
    SHIM_UNUSED_ALL();
    Bo3MetalUAV *v = (Bo3MetalUAV *)rdi;
    if (rsi) { if (v->resource) v->resource->com.add_ref(); *(void **)rsi = v->resource; }
    return ret_void();
}
static SHIM_DEF(srv_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalSRV *v = (Bo3MetalSRV *)rdi;
    if (rsi) memcpy((void *)rsi, &v->desc, sizeof(v->desc));
    return ret_void();
}
static SHIM_DEF(rtv_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalRTV *v = (Bo3MetalRTV *)rdi;
    if (rsi) memcpy((void *)rsi, &v->desc, sizeof(v->desc));
    return ret_void();
}
static SHIM_DEF(dsv_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalDSV *v = (Bo3MetalDSV *)rdi;
    if (rsi) memcpy((void *)rsi, &v->desc, sizeof(v->desc));
    return ret_void();
}
static SHIM_DEF(uav_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalUAV *v = (Bo3MetalUAV *)rdi;
    if (rsi) memcpy((void *)rsi, &v->desc, sizeof(v->desc));
    return ret_void();
}

Bo3MetalTexture *bo3_d3d11_create_backbuffer_proxy(Bo3MetalDevice *dev, Bo3MetalSwapChain *sc) {
    Bo3MetalTexture *t = new Bo3MetalTexture();
    t->res.com.init_com(g_vt_tex2d, "ID3D11Texture2D(BackBuffer)", tex2d_qi, tex_dtor);
    t->res.dimension = BO3_D3D11_RESOURCE_DIMENSION_TEXTURE2D;
    t->res.device = dev;
    if (dev) dev->add_internal_ref();
    memset(&t->desc2d, 0, sizeof(t->desc2d));
    t->desc2d.Width = sc->desc.BufferDesc.Width;
    t->desc2d.Height = sc->desc.BufferDesc.Height;
    t->desc2d.MipLevels = 1;
    t->desc2d.ArraySize = 1;
    t->desc2d.Format = sc->desc.BufferDesc.Format;
    t->desc2d.SampleDesc.Count = 1;
    t->desc2d.BindFlags = BO3_D3D11_BIND_RENDER_TARGET | BO3_D3D11_BIND_SHADER_RESOURCE;
    t->dxgi_format = t->desc2d.Format;
    Bo3FormatInfo fi = bo3_dxgi_to_metal_format(t->dxgi_format, false, false);
    t->mtl_format = fi.pixel_format != MTLPixelFormatInvalid ? fi.pixel_format : MTLPixelFormatRGBA8Unorm;
    t->mtl_type = MTLTextureType2D;
    t->is_backbuffer = true;
    t->sc_state = sc->bb_state;
    t->view_lock = OS_UNFAIR_LOCK_INIT;
    return t;
}

// =========================================================================
// ID3D11Device Methods (slots 3..42)
// =========================================================================

static bool mtl_format_supports_atomic(MTLPixelFormat pf) {
    // Metal only permits MTLTextureUsageShaderAtomic on R32Uint, R32Sint, RG32Uint
    return pf == MTLPixelFormatR32Uint || pf == MTLPixelFormatR32Sint ||
           pf == MTLPixelFormatRG32Uint;
}

// Helper: upload Depth32Float_Stencil8 subresource using MTLBlitOptionDepthFromDepthStencil
// and MTLBlitOptionStencilFromDepthStencil (converting D24S8 24-bit unorm -> float32 if needed).
// Returns aspect bitmask written (0=none/failed, 1=depth, 2=stencil, 3=both).
uint8_t bo3_encode_depth_stencil_upload(id<MTLDevice> mdev, id<MTLBlitCommandEncoder> blit,
                                        id<MTLTexture> dst_tex, uint32_t dxgi_fmt,
                                        uint32_t slice, uint32_t mip,
                                        uint32_t ox, uint32_t oy, uint32_t w, uint32_t h,
                                        const uint8_t *src_base, uint32_t src_rp) {
    if (!mdev || !blit || !dst_tex || !src_base || w == 0 || h == 0) return 0;
    const bool is_d24s8 = (dxgi_fmt == 44 || dxgi_fmt == 45 || dxgi_fmt == 46);
    const bool is_d32s8 = (dxgi_fmt == 19 || dxgi_fmt == 20 || dxgi_fmt == 21);
    const bool is_stencil_only = (dxgi_fmt == 22 || dxgi_fmt == 47);

    if (is_d24s8 || is_d32s8) {
        size_t depth_rp = (size_t)w * 4;
        size_t depth_sz = depth_rp * h;
        size_t stenc_rp = (size_t)w;
        size_t stenc_sz = stenc_rp * h;
        id<MTLBuffer> dbuf = [mdev newBufferWithLength:depth_sz options:MTLResourceStorageModeShared];
        id<MTLBuffer> sbuf = [mdev newBufferWithLength:stenc_sz options:MTLResourceStorageModeShared];
        if (!dbuf || !sbuf) return 0;
        float *dp = (float *)dbuf.contents;
        uint8_t *sp = (uint8_t *)sbuf.contents;
        for (uint32_t r = 0; r < h; r++) {
            const uint8_t *row = src_base + (size_t)r * src_rp;
            for (uint32_t x = 0; x < w; x++) {
                if (is_d24s8) {
                    uint32_t v = 0;
                    memcpy(&v, row + (size_t)x * 4, 4);
                    dp[(size_t)r * w + x] = (float)(v & 0x00FFFFFFu) / 16777215.0f;
                    sp[(size_t)r * w + x] = (uint8_t)((v >> 24) & 0xFFu);
                } else {
                    float f = 0.0f;
                    memcpy(&f, row + (size_t)x * 8, 4);
                    dp[(size_t)r * w + x] = f;
                    sp[(size_t)r * w + x] = row[(size_t)x * 8 + 4];
                }
            }
        }
        [blit copyFromBuffer:dbuf sourceOffset:0 sourceBytesPerRow:depth_rp sourceBytesPerImage:depth_sz
                  sourceSize:MTLSizeMake(w, h, 1) toTexture:dst_tex
            destinationSlice:slice destinationLevel:mip destinationOrigin:MTLOriginMake(ox, oy, 0)
                     options:MTLBlitOptionDepthFromDepthStencil];
        [blit copyFromBuffer:sbuf sourceOffset:0 sourceBytesPerRow:stenc_rp sourceBytesPerImage:stenc_sz
                  sourceSize:MTLSizeMake(w, h, 1) toTexture:dst_tex
            destinationSlice:slice destinationLevel:mip destinationOrigin:MTLOriginMake(ox, oy, 0)
                     options:MTLBlitOptionStencilFromDepthStencil];
        return 3u;
    } else if (is_stencil_only) {
        size_t stenc_rp = (size_t)w;
        size_t stenc_sz = stenc_rp * h;
        id<MTLBuffer> sbuf = [mdev newBufferWithLength:stenc_sz options:MTLResourceStorageModeShared];
        if (!sbuf) return 0;
        uint8_t *sp = (uint8_t *)sbuf.contents;
        uint32_t px_stride = (dxgi_fmt == 22) ? 8u : 4u;
        uint32_t byte_off  = (dxgi_fmt == 22) ? 4u : 3u;
        for (uint32_t r = 0; r < h; r++) {
            const uint8_t *row = src_base + (size_t)r * src_rp;
            for (uint32_t x = 0; x < w; x++) {
                sp[(size_t)r * w + x] = row[(size_t)x * px_stride + byte_off];
            }
        }
        [blit copyFromBuffer:sbuf sourceOffset:0 sourceBytesPerRow:stenc_rp sourceBytesPerImage:stenc_sz
                  sourceSize:MTLSizeMake(w, h, 1) toTexture:dst_tex
            destinationSlice:slice destinationLevel:mip destinationOrigin:MTLOriginMake(ox, oy, 0)
                     options:MTLBlitOptionStencilFromDepthStencil];
        return 2u;
    }
    return 0;
}

// Helper: upload initial texture subresources via blit encoder (row-by-row tight packing, 1D/2D/3D safe!)
// `d3d_mips` is the D3D11 MipLevels used to index pInitialData (slice * d3d_mips + mip); only the
// first min(d3d_mips, tex.mipmapLevelCount) mips are uploaded (Metal 1D textures are single-mip).
static void upload_initial_texture_data(Bo3MetalDevice *dev, id<MTLTexture> tex,
                                        uint32_t dxgi_fmt, uint32_t width, uint32_t height, uint32_t depth,
                                        uint32_t d3d_mips, uint32_t array_slices,
                                        const Bo3D3D11_SUBRESOURCE_DATA *init_data) {
    if (!init_data || !tex || d3d_mips == 0) return;
    const bool is_1d = (tex.textureType == MTLTextureType1D || tex.textureType == MTLTextureType1DArray);
    const bool is_3d = (tex.textureType == MTLTextureType3D);
    const bool is_ds = (tex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8);
    const bool is_rgb32 = bo3_format_is_rgb32(dxgi_fmt);
    const uint32_t upload_mips = std::min<uint32_t>(d3d_mips, (uint32_t)tex.mipmapLevelCount);
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [dev->mtl_queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];

        for (uint32_t slice = 0; slice < array_slices; slice++) {
            for (uint32_t mip = 0; mip < upload_mips; mip++) {
                const Bo3D3D11_SUBRESOURCE_DATA &sd = init_data[(size_t)slice * d3d_mips + mip];
                if (!sd.pSysMem) continue;
                uint32_t mw = std::max(1u, width  >> mip);
                uint32_t mh = std::max(1u, height >> mip);
                uint32_t md = is_3d ? std::max(1u, depth >> mip) : 1u;
                uint32_t calc_row = 0, calc_slice = 0, rows = 0;
                bo3_format_calc_pitch(dxgi_fmt, mw, mh, &calc_row, &calc_slice, &rows);
                if (calc_row == 0 || rows == 0) continue;

                // In D3D11, SysMemSlicePitch is ignored for 1D/2D and only calc_row bytes are guaranteed on the last row.
                uint32_t src_rp = (!is_1d && sd.SysMemPitch >= calc_row) ? sd.SysMemPitch : calc_row;
                if (is_ds) {
                    bo3_encode_depth_stencil_upload(dev->mtl_dev, blit, tex, dxgi_fmt, slice, mip,
                                                    0, 0, mw, mh, (const uint8_t *)sd.pSysMem, src_rp);
                    continue;
                }
                uint32_t src_sp = (is_3d && sd.SysMemSlicePitch >= src_rp * rows) ? sd.SysMemSlicePitch : (src_rp * rows);
                // RGB32: guest rows hold 12-byte texels, Metal RGBA32 rows need 16-byte texels
                uint32_t dst_rp = is_rgb32 ? mw * 16u : calc_row;
                uint32_t dst_sp = dst_rp * rows;
                size_t total = (size_t)dst_sp * md;
                if (total == 0) continue;

                id<MTLBuffer> stg = [dev->mtl_dev newBufferWithLength:total options:MTLResourceStorageModeShared];
                if (!stg) continue;
                uint8_t *dst_p = (uint8_t *)stg.contents;
                const uint8_t *src_base = (const uint8_t *)sd.pSysMem;
                for (uint32_t z = 0; z < md; z++) {
                    const uint8_t *src_sl = src_base + (size_t)z * src_sp;
                    uint8_t *dst_sl = dst_p + (size_t)z * dst_sp;
                    for (uint32_t r = 0; r < rows; r++) {
                        if (is_rgb32) {
                            bo3_rgb32_expand_row(dst_sl + (size_t)r * dst_rp, src_sl + (size_t)r * src_rp, mw, dxgi_fmt);
                        } else {
                            memcpy(dst_sl + (size_t)r * dst_rp, src_sl + (size_t)r * src_rp, calc_row);
                        }
                    }
                }
                [blit copyFromBuffer:stg
                        sourceOffset:0
                   sourceBytesPerRow:(is_1d ? 0u : dst_rp)
                 sourceBytesPerImage:(is_1d ? 0u : dst_sp)
                          sourceSize:MTLSizeMake(mw, mh, md)
                           toTexture:tex
                    destinationSlice:slice
                    destinationLevel:mip
                   destinationOrigin:MTLOriginMake(0, 0, 0)];
            }
        }
        [blit endEncoding];
        [cb commit];
    }
}

// slot 3 (+0x18): CreateBuffer(pDesc, pInitialData, ppBuffer)
static SHIM_DEF(dev_create_buffer) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_BUFFER_DESC *desc = (const Bo3D3D11_BUFFER_DESC *)rsi;
    const Bo3D3D11_SUBRESOURCE_DATA *init = (const Bo3D3D11_SUBRESOURCE_DATA *)rdx;
    void **pp = (void **)rcx;
    if (!desc || !pp) return ret_u64(BO3_E_INVALIDARG);

    size_t sz = std::max<size_t>(desc->ByteWidth, 256);
    sz = (sz + 15) & ~15ULL;
    id<MTLBuffer> mbuf = [dev->mtl_dev newBufferWithLength:sz options:MTLResourceStorageModeShared];
    if (!mbuf) {
        *pp = nullptr;
        return ret_u64(BO3_E_OUTOFMEMORY);
    }

    Bo3MetalBuffer *b = new Bo3MetalBuffer();
    b->res.com.init_com(g_vt_buffer, "ID3D11Buffer", buffer_qi, buffer_dtor);
    b->res.dimension = BO3_D3D11_RESOURCE_DIMENSION_BUFFER;
    b->res.device = dev;
    dev->add_internal_ref();
    b->desc = *desc;
    b->mtl_buf = mbuf;
    b->mtl_len = (uint64_t)sz;
    b->clear_dyn();
    b->dyn_stride = (desc->ByteWidth + 255u) & ~255u;
    b->dyn_epoch = 0;
    b->mapped_ptr = nullptr;
    b->is_dynamic = (desc->Usage == BO3_D3D11_USAGE_DYNAMIC);
    b->is_staging = (desc->Usage == BO3_D3D11_USAGE_STAGING);

    if (init && init->pSysMem && desc->ByteWidth > 0) {
        memcpy(b->mtl_buf.contents, init->pSysMem, desc->ByteWidth);
    } else {
        memset(b->mtl_buf.contents, 0, sz);
    }
    *pp = b;
    return ret_u64(BO3_S_OK);
}

// slot 4 (+0x20): CreateTexture1D
static SHIM_DEF(dev_create_tex1d) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_TEXTURE1D_DESC *d1 = (const Bo3D3D11_TEXTURE1D_DESC *)rsi;
    const Bo3D3D11_SUBRESOURCE_DATA *init = (const Bo3D3D11_SUBRESOURCE_DATA *)rdx;
    void **pp = (void **)rcx;
    if (!d1 || !pp) return ret_u64(BO3_E_INVALIDARG);
    Bo3D3D11_TEXTURE2D_DESC d2 = {};
    d2.Width = d1->Width; d2.Height = 1; d2.MipLevels = d1->MipLevels;
    d2.ArraySize = d1->ArraySize ? d1->ArraySize : 1;
    d2.Format = d1->Format; d2.SampleDesc.Count = 1;
    d2.Usage = d1->Usage; d2.BindFlags = d1->BindFlags;
    d2.CPUAccessFlags = d1->CPUAccessFlags; d2.MiscFlags = d1->MiscFlags;

    // D3D11 mip count (MipLevels == 0 -> full chain) is kept for GetDesc + subresource indexing,
    // but Metal MTLTextureType1D/1DArray REQUIRES mipmapLevelCount == 1 (debug layer asserts and
    // MSL texture1d has no LOD). Back every 1D texture with a single Metal mip; writes/uploads to
    // D3D mips > 0 are dropped and SRV mip ranges clamp to mip 0.
    uint32_t mips = d2.MipLevels;
    if (mips == 0) { uint32_t s = std::max(1u, d2.Width); mips = 1; while (s > 1) { s >>= 1; mips++; } }
    if (mips > 1) {
        static std::atomic<int> warn_cnt{0};
        if (warn_cnt.fetch_add(1, std::memory_order_relaxed) < 8) {
            fprintf(stderr, "[metal-dev] WARNING: CreateTexture1D w=%u MipLevels=%u -> Metal 1D textures are single-mip; "
                            "backing with 1 Metal mip (D3D mips > 0 ignored)\n", d2.Width, d1->MipLevels);
            fflush(stderr);
        }
    }
    const uint32_t mtl_mips = 1;
    bool is_dsv = (d2.BindFlags & BO3_D3D11_BIND_DEPTH_STENCIL) != 0;
    bool is_uav = (d2.BindFlags & BO3_D3D11_BIND_UNORDERED_ACCESS) != 0;
    Bo3FormatInfo fi = bo3_dxgi_to_metal_format(d2.Format, is_dsv, false);
    MTLPixelFormat pf = fi.pixel_format != MTLPixelFormatInvalid ? fi.pixel_format : MTLPixelFormatRGBA8Unorm;
    if (d2.Format == 39u /* R32_TYPELESS */ && is_uav && !is_dsv) {
        pf = MTLPixelFormatR32Uint;
    }

    MTLTextureUsage usage = 0;
    if (d2.BindFlags & BO3_D3D11_BIND_SHADER_RESOURCE) usage |= MTLTextureUsageShaderRead;
    if (d2.BindFlags & BO3_D3D11_BIND_RENDER_TARGET)   usage |= MTLTextureUsageRenderTarget;
    if (is_dsv)                                        usage |= MTLTextureUsageRenderTarget;
    if (is_uav) {
        usage |= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
#if defined(__MAC_14_0)
        if (@available(macOS 14.0, *)) {
            if (mtl_format_supports_atomic(pf)) usage |= MTLTextureUsageShaderAtomic;
        }
#endif
    }
    if (usage == 0) usage = MTLTextureUsageShaderRead;
    // M5: PixelFormatView ONLY when a mismatched-format view is legal (keeps lossless compression)
    if (bo3_texture_needs_pixel_format_view(d2.Format, &fi, is_dsv, is_uav, pf)) {
        usage |= MTLTextureUsagePixelFormatView;
    }

    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = (d2.ArraySize > 1) ? MTLTextureType1DArray : MTLTextureType1D;
    td.pixelFormat = pf;
    td.width = std::max(1u, d2.Width);
    td.height = 1;
    td.mipmapLevelCount = mtl_mips;
    td.arrayLength = d2.ArraySize;
    td.storageMode = (d2.Usage == BO3_D3D11_USAGE_STAGING) ? MTLStorageModeShared : MTLStorageModePrivate;
    td.usage = usage;

    Bo3MetalTexture *t = new Bo3MetalTexture();
    t->res.com.init_com(g_vt_tex1d, "ID3D11Texture1D", tex1d_qi, tex_dtor);
    t->res.dimension = BO3_D3D11_RESOURCE_DIMENSION_TEXTURE1D;
    t->res.device = dev;
    t->desc1d = *d1;
    t->desc1d.MipLevels = mips;
    t->desc1d.ArraySize = d2.ArraySize;
    t->desc2d = d2;
    t->desc2d.MipLevels = mips;
    t->dxgi_format = d2.Format;
    t->mtl_format = pf;
    t->mtl_type = td.textureType;
    t->is_backbuffer = false;
    t->view_lock = OS_UNFAIR_LOCK_INIT;
    t->mtl_tex = [dev->mtl_dev newTextureWithDescriptor:td];
    if (!t->mtl_tex) {
        fprintf(stderr, "[metal-dev] FAILED CreateTexture1D w=%u fmt=%u(mtl=%lu) arr=%u mips=%u\n",
                d2.Width, d2.Format, (unsigned long)pf, d2.ArraySize, mips);
        fflush(stderr);
        delete t;
        *pp = nullptr;
        return ret_u64(BO3_E_OUTOFMEMORY);
    }
    dev->add_internal_ref();
    if (init) upload_initial_texture_data(dev, t->mtl_tex, d2.Format, std::max(1u, d2.Width), 1, 1, mips, d2.ArraySize, init);
    *pp = t;
    return ret_u64(BO3_S_OK);
}

// slot 5 (+0x28): CreateTexture2D(pDesc, pInitialData, ppTex)
static SHIM_DEF(dev_create_tex2d) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_TEXTURE2D_DESC *desc = (const Bo3D3D11_TEXTURE2D_DESC *)rsi;
    const Bo3D3D11_SUBRESOURCE_DATA *init = (const Bo3D3D11_SUBRESOURCE_DATA *)rdx;
    void **pp = (void **)rcx;
    if (!desc || !pp) return ret_u64(BO3_E_INVALIDARG);

    bool is_dsv = (desc->BindFlags & BO3_D3D11_BIND_DEPTH_STENCIL) != 0;
    bool is_uav = (desc->BindFlags & BO3_D3D11_BIND_UNORDERED_ACCESS) != 0;
    Bo3FormatInfo fi = bo3_dxgi_to_metal_format(desc->Format, is_dsv, false);
    MTLPixelFormat pf = fi.pixel_format;
    if (pf == MTLPixelFormatInvalid) {
        fprintf(stderr, "[metal-dev] WARNING: unknown DXGI_FORMAT %u in CreateTexture2D, falling back to RGBA8\n", desc->Format);
        pf = MTLPixelFormatRGBA8Unorm;
    }
    if (desc->Format == 39u /* R32_TYPELESS */ && is_uav && !is_dsv) {
        pf = MTLPixelFormatR32Uint;
    }

    uint32_t w = std::max(1u, desc->Width);
    uint32_t h = std::max(1u, desc->Height);
    uint32_t arr = std::max(1u, desc->ArraySize);
    uint32_t mips = desc->MipLevels;
    if (mips == 0) {
        uint32_t s = std::max(w, h);
        mips = 1;
        while (s > 1) { s >>= 1; mips++; }
    }
    uint32_t samples = desc->SampleDesc.Count;
    if (samples < 1) samples = 1;
    if (samples > 4) samples = 4; // M4 MSAA max is 4x

    bool is_cube = (desc->MiscFlags & BO3_D3D11_RESOURCE_MISC_TEXTURECUBE) != 0 && arr >= 6;
    MTLTextureType mtype = MTLTextureType2D;
    uint32_t mtl_arr = arr;
    if (samples > 1) {
        mtype = (arr > 1) ? MTLTextureType2DMultisampleArray : MTLTextureType2DMultisample;
        mips = 1;
    } else if (is_cube) {
        if (arr > 6) { mtype = MTLTextureTypeCubeArray; mtl_arr = arr / 6; }
        else         { mtype = MTLTextureTypeCube;      mtl_arr = 1; }
    } else if (arr > 1) {
        mtype = MTLTextureType2DArray;
    }

    MTLTextureUsage usage = 0;
    if (desc->BindFlags & BO3_D3D11_BIND_SHADER_RESOURCE)  usage |= MTLTextureUsageShaderRead;
    if (desc->BindFlags & BO3_D3D11_BIND_RENDER_TARGET)    usage |= MTLTextureUsageRenderTarget;
    if (is_dsv)                                            usage |= MTLTextureUsageRenderTarget;
    if (is_uav) {
        usage |= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
#if defined(__MAC_14_0)
        if (@available(macOS 14.0, *)) {
            if (mtl_format_supports_atomic(pf)) usage |= MTLTextureUsageShaderAtomic;
        }
#endif
    }
    if (usage == 0) usage = MTLTextureUsageShaderRead;
    // MSAA RT/DS textures: ShaderRead (no lossless-compression cost on Apple GPUs) lets a concrete
    // same-family MSAA CopyResource read the source per sample (blits cannot reinterpret MSAA).
    // Non-RT MSAA textures (cannot be render targets) and concrete SNORM MSAA textures (where a
    // normalized shader read maps -128 and -127 identically) keep PixelFormatView for bit-exact blits.
    if (samples > 1) {
        usage |= MTLTextureUsageShaderRead;
        bool is_snorm = (pf == MTLPixelFormatR8Snorm || pf == MTLPixelFormatRG8Snorm ||
                         pf == MTLPixelFormatRGBA8Snorm || pf == MTLPixelFormatR16Snorm ||
                         pf == MTLPixelFormatRG16Snorm || pf == MTLPixelFormatRGBA16Snorm);
        if (!(usage & MTLTextureUsageRenderTarget) || is_snorm) {
            usage |= MTLTextureUsagePixelFormatView;
        }
    }
    // M5: PixelFormatView ONLY for typeless / depth-stencil / raw-clear UAV textures. Fully typed
    // color RTV/SRV textures stay compressible on Apple GPUs (same-format subset views, swizzle
    // views and sRGB<->linear twin views are all legal without it, verified with MTL_DEBUG_LAYER).
    if (bo3_texture_needs_pixel_format_view(desc->Format, &fi, is_dsv, is_uav, pf)) {
        usage |= MTLTextureUsagePixelFormatView;
    }

    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = mtype;
    td.pixelFormat = pf;
    td.width = w;
    td.height = h;
    td.mipmapLevelCount = mips;
    td.arrayLength = mtl_arr;
    td.sampleCount = samples;
    td.storageMode = (desc->Usage == BO3_D3D11_USAGE_STAGING) ? MTLStorageModeShared : MTLStorageModePrivate;
    td.usage = usage;
    // B3 (Apple8+): lossy compression for large plain 2D color render targets (editable live via F10/Cmd+,).
    // Excludes UAV / depth-stencil / staging / CPU-accessible / MSAA / array / reinterpretable
    // (PixelFormatView) textures and formats unsupported by Apple8+ lossy compression (e.g. RG11B10Float).
    MTLTextureUsage no_lossy_mask = MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView;
#if defined(__MAC_14_0)
    if (@available(macOS 14.0, *)) { no_lossy_mask |= MTLTextureUsageShaderAtomic; }
#endif
    if (bo3_settings_lossy_rt_enabled() && mtype == MTLTextureType2D && samples == 1 && w >= 256 && h >= 256 &&
        (usage & MTLTextureUsageRenderTarget) && !is_dsv && !is_uav &&
        !(usage & no_lossy_mask) &&
        desc->Usage != BO3_D3D11_USAGE_STAGING && desc->CPUAccessFlags == 0 &&
        td.storageMode == MTLStorageModePrivate) {
        switch (pf) {
            case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
            case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
            case MTLPixelFormatRGBA16Float:
            case MTLPixelFormatRGB10A2Unorm:
                td.compressionType = MTLTextureCompressionTypeLossy;
                break;
            default: break;
        }
    }

    Bo3MetalTexture *t = new Bo3MetalTexture();
    t->res.com.init_com(g_vt_tex2d, "ID3D11Texture2D", tex2d_qi, tex_dtor);
    t->res.dimension = BO3_D3D11_RESOURCE_DIMENSION_TEXTURE2D;
    t->res.device = dev;
    t->desc2d = *desc;
    t->desc2d.MipLevels = mips;
    t->desc2d.ArraySize = arr;
    t->desc2d.SampleDesc.Count = samples;
    t->dxgi_format = desc->Format;
    t->mtl_format = pf;
    t->mtl_type = mtype;
    t->is_backbuffer = false;
    t->view_lock = OS_UNFAIR_LOCK_INIT;
    t->mtl_tex = [dev->mtl_dev newTextureWithDescriptor:td];
    if (!t->mtl_tex && td.compressionType == MTLTextureCompressionTypeLossy) {
        td.compressionType = MTLTextureCompressionTypeLossless;
        t->mtl_tex = [dev->mtl_dev newTextureWithDescriptor:td];
    }

    if (!t->mtl_tex) {
        fprintf(stderr, "[metal-dev] FAILED CreateTexture2D %ux%u fmt=%u(mtl=%lu) arr=%u mips=%u samples=%u\n",
                w, h, desc->Format, (unsigned long)pf, arr, mips, samples);
        fflush(stderr);
        delete t;
        *pp = nullptr;
        return ret_u64(BO3_E_OUTOFMEMORY);
    }
    dev->add_internal_ref();

    if (init) {
        upload_initial_texture_data(dev, t->mtl_tex, desc->Format, w, h, 1, mips, arr, init);
    }
    *pp = t;
    return ret_u64(BO3_S_OK);
}

// slot 6 (+0x30): CreateTexture3D(pDesc, pInitialData, ppTex)
static SHIM_DEF(dev_create_tex3d) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_TEXTURE3D_DESC *desc = (const Bo3D3D11_TEXTURE3D_DESC *)rsi;
    const Bo3D3D11_SUBRESOURCE_DATA *init = (const Bo3D3D11_SUBRESOURCE_DATA *)rdx;
    void **pp = (void **)rcx;
    if (!desc || !pp) return ret_u64(BO3_E_INVALIDARG);

    bool is_uav = (desc->BindFlags & BO3_D3D11_BIND_UNORDERED_ACCESS) != 0;
    Bo3FormatInfo fi = bo3_dxgi_to_metal_format(desc->Format, false, false);
    MTLPixelFormat pf = fi.pixel_format != MTLPixelFormatInvalid ? fi.pixel_format : MTLPixelFormatRGBA8Unorm;
    if (desc->Format == 39u /* R32_TYPELESS */ && is_uav) {
        pf = MTLPixelFormatR32Uint;
    }
    uint32_t w = std::max(1u, desc->Width);
    uint32_t h = std::max(1u, desc->Height);
    uint32_t d = std::max(1u, desc->Depth);
    uint32_t mips = desc->MipLevels;
    if (mips == 0) {
        uint32_t s = std::max(w, std::max(h, d));
        mips = 1;
        while (s > 1) { s >>= 1; mips++; }
    }

    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType3D;
    td.pixelFormat = pf;
    td.width = w; td.height = h; td.depth = d;
    td.mipmapLevelCount = mips;
    td.storageMode = (desc->Usage == BO3_D3D11_USAGE_STAGING) ? MTLStorageModeShared : MTLStorageModePrivate;
    MTLTextureUsage usage = MTLTextureUsageShaderRead;
    if (desc->BindFlags & BO3_D3D11_BIND_RENDER_TARGET) usage |= MTLTextureUsageRenderTarget;
    if (is_uav) {
        usage |= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
#if defined(__MAC_14_0)
        if (@available(macOS 14.0, *)) {
            if (mtl_format_supports_atomic(pf)) usage |= MTLTextureUsageShaderAtomic;
        }
#endif
    }
    if (bo3_texture_needs_pixel_format_view(desc->Format, &fi, false, is_uav, pf)) {
        usage |= MTLTextureUsagePixelFormatView;
    }
    td.usage = usage;

    Bo3MetalTexture *t = new Bo3MetalTexture();
    t->res.com.init_com(g_vt_tex3d, "ID3D11Texture3D", tex3d_qi, tex_dtor);
    t->res.dimension = BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D;
    t->res.device = dev;
    t->desc3d = *desc;
    t->desc3d.MipLevels = mips;
    t->dxgi_format = desc->Format;
    t->mtl_format = pf;
    t->mtl_type = MTLTextureType3D;
    t->is_backbuffer = false;
    t->view_lock = OS_UNFAIR_LOCK_INIT;
    t->mtl_tex = [dev->mtl_dev newTextureWithDescriptor:td];
    if (!t->mtl_tex) {
        fprintf(stderr, "[metal-dev] FAILED CreateTexture3D %ux%ux%u fmt=%u(mtl=%lu) mips=%u\n",
                w, h, d, desc->Format, (unsigned long)pf, mips);
        fflush(stderr);
        delete t;
        *pp = nullptr;
        return ret_u64(BO3_E_OUTOFMEMORY);
    }
    dev->add_internal_ref();
    if (init) upload_initial_texture_data(dev, t->mtl_tex, desc->Format, w, h, d, mips, 1, init);
    *pp = t;
    return ret_u64(BO3_S_OK);
}

// slot 7 (+0x38): CreateShaderResourceView(pRes, pDesc, ppSRV)
static SHIM_DEF(dev_create_srv) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    Bo3MetalResource *res = (Bo3MetalResource *)rsi;
    const Bo3D3D11_SHADER_RESOURCE_VIEW_DESC *desc = (const Bo3D3D11_SHADER_RESOURCE_VIEW_DESC *)rdx;
    void **pp = (void **)rcx;
    if (!res || !pp) return ret_u64(BO3_E_INVALIDARG);

    Bo3MetalSRV *v = new Bo3MetalSRV();
    v->com.init_com(g_vt_srv, "ID3D11ShaderResourceView", srv_qi, srv_dtor);
    v->device = dev;
    dev->add_internal_ref();
    v->resource = res;
    res->com.add_ref();
    memset(&v->desc, 0, sizeof(v->desc));
    if (desc) v->desc = *desc;
    v->mtl_tex = nil;
    v->mtl_buf = nil;
    v->buf_offset = 0;
    v->buf_size = 0;
    v->buf_num_elements = 0;
    v->buf_stride = 0;
    v->is_buffer = (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER);
    v->mip0 = 0; v->mip_cnt = 1; v->slice0 = 0; v->slice_cnt = 1;
    v->aspect = 1;

    if (v->is_buffer) {
        Bo3MetalBuffer *b = (Bo3MetalBuffer *)res;
        v->mtl_buf = b->mtl_buf;
        // D3D11_BUFFEREX_SRV_FLAG_RAW (0x1): ByteAddressBuffer view -> 4-byte elements, even when
        // the underlying buffer is structured (StructureByteStride != 0)!
        const bool is_raw = desc && desc->ViewDimension == BO3_D3D11_SRV_DIMENSION_BUFFEREX &&
                            (desc->BufferEx.Flags & 0x1u) != 0;
        uint32_t stride = is_raw ? 4u : b->desc.StructureByteStride;
        if (stride == 0) {
            if (desc && desc->Format) {
                Bo3FormatInfo fi = bo3_dxgi_to_metal_format(desc->Format, false, true);
                stride = fi.bytes_per_block ? fi.bytes_per_block : 4u;
            } else stride = 4;
        }
        uint32_t first = desc ? desc->Buffer.FirstElement : 0;
        uint32_t count = desc ? desc->Buffer.NumElements : (b->desc.ByteWidth / std::max(1u, stride));
        v->buf_stride = stride;
        v->buf_offset = (uint64_t)first * stride;
        v->buf_num_elements = count;
        v->buf_size = (uint64_t)count * stride;
    } else {
        Bo3MetalTexture *t = (Bo3MetalTexture *)res;
        uint32_t fmt = (desc && desc->Format) ? desc->Format : t->dxgi_format;
        bool is_depth_tex = (t->mtl_format == MTLPixelFormatDepth32Float ||
                             t->mtl_format == MTLPixelFormatDepth32Float_Stencil8 ||
                             t->mtl_format == MTLPixelFormatDepth16Unorm);
        MTLPixelFormat mpf = is_depth_tex ? t->mtl_format
                                          : bo3_dxgi_to_metal_format(fmt, false, true).pixel_format;
        if (mpf == MTLPixelFormatInvalid) mpf = t->mtl_format;
        // Stencil view (X24_TYPELESS_G8_UINT or X32_TYPELESS_G8X24_UINT): D3D11 returns stencil in .g
        uint32_t swz = BO3_SWIZZLE_IDENTITY;
        if (fmt == 47 || fmt == 22) {
            mpf = MTLPixelFormatX32_Stencil8;
            swz = bo3_pack_swizzle(MTLTextureSwizzleZero, MTLTextureSwizzleRed, MTLTextureSwizzleZero, MTLTextureSwizzleOne);
            v->aspect = 2;
        } else if (fmt == 88 || fmt == 92 || fmt == 93) {
            // B8G8R8X8_*: X channel is undefined in memory -> force alpha = 1
            swz = bo3_pack_swizzle(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleOne);
        }

        MTLTextureType mtype = t->mtl_type;
        uint32_t mip0 = 0, mip_cnt = 0, sl0 = 0, sl_cnt = 0;
        if (desc) {
            switch (desc->ViewDimension) {
                case BO3_D3D11_SRV_DIMENSION_TEXTURE1D:
                    mtype = MTLTextureType1D; mip0 = desc->Texture1D.MostDetailedMip; mip_cnt = desc->Texture1D.MipLevels; sl_cnt = 1; break;
                case BO3_D3D11_SRV_DIMENSION_TEXTURE1DARRAY:
                    mtype = MTLTextureType1DArray; mip0 = desc->Texture1DArray.MostDetailedMip; mip_cnt = desc->Texture1DArray.MipLevels;
                    sl0 = desc->Texture1DArray.FirstArraySlice; sl_cnt = desc->Texture1DArray.ArraySize; break;
                case BO3_D3D11_SRV_DIMENSION_TEXTURE2D:
                    mtype = MTLTextureType2D; mip0 = desc->Texture2D.MostDetailedMip; mip_cnt = desc->Texture2D.MipLevels; sl_cnt = 1; break;
                case BO3_D3D11_SRV_DIMENSION_TEXTURE2DARRAY:
                    mtype = MTLTextureType2DArray; mip0 = desc->Texture2DArray.MostDetailedMip; mip_cnt = desc->Texture2DArray.MipLevels;
                    sl0 = desc->Texture2DArray.FirstArraySlice; sl_cnt = desc->Texture2DArray.ArraySize; break;
                case BO3_D3D11_SRV_DIMENSION_TEXTURE2DMS:
                    mtype = MTLTextureType2DMultisample; sl_cnt = 1; break;
                case BO3_D3D11_SRV_DIMENSION_TEXTURE2DMSARRAY:
                    mtype = MTLTextureType2DMultisampleArray;
                    sl0 = desc->Texture2DMSArray.FirstArraySlice; sl_cnt = desc->Texture2DMSArray.ArraySize; break;
                case BO3_D3D11_SRV_DIMENSION_TEXTURE3D:
                    mtype = MTLTextureType3D; mip0 = desc->Texture3D.MostDetailedMip; mip_cnt = desc->Texture3D.MipLevels; break;
                case BO3_D3D11_SRV_DIMENSION_TEXTURECUBE:
                    mtype = MTLTextureTypeCube; mip0 = desc->TextureCube.MostDetailedMip; mip_cnt = desc->TextureCube.MipLevels; sl_cnt = 6; break;
                case BO3_D3D11_SRV_DIMENSION_TEXTURECUBEARRAY:
                    mtype = MTLTextureTypeCubeArray; mip0 = desc->TextureCubeArray.MostDetailedMip; mip_cnt = desc->TextureCubeArray.MipLevels;
                    sl0 = desc->TextureCubeArray.First2DArrayFace;
                    sl_cnt = (desc->TextureCubeArray.NumCubes == 0xffffffffu) ? 0u : (desc->TextureCubeArray.NumCubes * 6u);
                    break;
                default: break;
            }
            if (mip_cnt == 0xffffffffu) mip_cnt = 0;
            if (sl_cnt == 0xffffffffu)  sl_cnt = 0;
        }
        v->mtl_tex = t->get_or_create_view(mpf, mtype, mip0, mip_cnt, sl0, sl_cnt, swz);
        // Resolve absolute D3D subresource range for hazard tracking
        uint32_t d3d_mips = t->d3d_mip_levels();
        uint32_t d3d_slices = (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D) ? 1u
                            : (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE1D) ? std::max(1u, t->desc1d.ArraySize)
                            : std::max(1u, t->desc2d.ArraySize);
        v->mip0 = std::min(mip0, d3d_mips - 1);
        v->mip_cnt = (mip_cnt == 0 || v->mip0 + mip_cnt > d3d_mips) ? (d3d_mips - v->mip0) : mip_cnt;
        v->slice0 = std::min(sl0, d3d_slices - 1);
        v->slice_cnt = (sl_cnt == 0 || v->slice0 + sl_cnt > d3d_slices) ? (d3d_slices - v->slice0) : sl_cnt;
        if (desc && (desc->ViewDimension == BO3_D3D11_SRV_DIMENSION_TEXTURE1D ||
                     desc->ViewDimension == BO3_D3D11_SRV_DIMENSION_TEXTURE2D ||
                     desc->ViewDimension == BO3_D3D11_SRV_DIMENSION_TEXTURE2DMS ||
                     desc->ViewDimension == BO3_D3D11_SRV_DIMENSION_TEXTURE3D)) {
            v->slice0 = 0;
            v->slice_cnt = 1;
        }
    }
    *pp = v;
    return ret_u64(BO3_S_OK);
}

// slot 8 (+0x40): CreateUnorderedAccessView(pRes, pDesc, ppUAV)
static SHIM_DEF(dev_create_uav) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    Bo3MetalResource *res = (Bo3MetalResource *)rsi;
    const Bo3D3D11_UNORDERED_ACCESS_VIEW_DESC *desc = (const Bo3D3D11_UNORDERED_ACCESS_VIEW_DESC *)rdx;
    void **pp = (void **)rcx;
    if (!res || !pp) return ret_u64(BO3_E_INVALIDARG);

    Bo3MetalUAV *v = new Bo3MetalUAV();
    v->com.init_com(g_vt_uav, "ID3D11UnorderedAccessView", uav_qi, uav_dtor);
    v->device = dev;
    dev->add_internal_ref();
    v->resource = res;
    res->com.add_ref();
    memset(&v->desc, 0, sizeof(v->desc));
    if (desc) v->desc = *desc;
    v->mtl_tex = nil;
    v->mtl_buf = nil;
    v->counter_buf = nil;
    v->is_buffer = (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER);
    v->is_raw = false;
    v->elem_size = 4;
    v->mip0 = 0; v->slice0 = 0; v->slice_cnt = 1;

    if (v->is_buffer) {
        Bo3MetalBuffer *b = (Bo3MetalBuffer *)res;
        v->mtl_buf = b->mtl_buf;
        // D3D11_BUFFER_UAV_FLAG_RAW (0x1): RWByteAddressBuffer -> 4-byte elements even on structured buffers
        v->is_raw = desc && (desc->Buffer.Flags & 0x1u) != 0;
        uint32_t stride = v->is_raw ? 4u : b->desc.StructureByteStride;
        if (stride == 0) {
            if (desc && desc->Format) {
                Bo3FormatInfo fi = bo3_dxgi_to_metal_format(desc->Format, false, false);
                stride = fi.bytes_per_block ? fi.bytes_per_block : 4;
            } else {
                stride = 4;
            }
        }
        v->elem_size = stride;
        uint32_t first = desc ? desc->Buffer.FirstElement : 0;
        uint32_t count = desc ? desc->Buffer.NumElements : (b->desc.ByteWidth / std::max(1u, stride));
        v->buf_offset = (uint64_t)first * stride;
        v->buf_num_elements = count;
        v->buf_stride = stride;
        v->buf_size = (uint64_t)count * stride;
        if (desc && (desc->Buffer.Flags & 0x6u)) { // APPEND or COUNTER
            v->counter_buf = [dev->mtl_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
            if (v->counter_buf) memset(v->counter_buf.contents, 0, 16);
        }
    } else {
        Bo3MetalTexture *t = (Bo3MetalTexture *)res;
        uint32_t fmt = (desc && desc->Format) ? desc->Format : t->dxgi_format;
        MTLPixelFormat mpf = bo3_dxgi_to_metal_format(fmt, false, false).pixel_format;
        if (mpf == MTLPixelFormatInvalid) mpf = t->mtl_format;
        MTLTextureType mtype = t->mtl_type;
        uint32_t mip = 0, sl0 = 0, sl_cnt = 0;
        if (desc) {
            switch (desc->ViewDimension) {
                case BO3_D3D11_UAV_DIMENSION_TEXTURE1D:
                    mtype = MTLTextureType1D; mip = desc->Texture1D.MipSlice; sl_cnt = 1; break;
                case BO3_D3D11_UAV_DIMENSION_TEXTURE1DARRAY:
                    mtype = MTLTextureType1DArray; mip = desc->Texture1DArray.MipSlice;
                    sl0 = desc->Texture1DArray.FirstArraySlice; sl_cnt = desc->Texture1DArray.ArraySize; break;
                case BO3_D3D11_UAV_DIMENSION_TEXTURE2D:
                    mtype = MTLTextureType2D; mip = desc->Texture2D.MipSlice; sl_cnt = 1; break;
                case BO3_D3D11_UAV_DIMENSION_TEXTURE2DARRAY:
                    mtype = MTLTextureType2DArray; mip = desc->Texture2DArray.MipSlice;
                    sl0 = desc->Texture2DArray.FirstArraySlice; sl_cnt = desc->Texture2DArray.ArraySize; break;
                case BO3_D3D11_UAV_DIMENSION_TEXTURE3D:
                    mtype = MTLTextureType3D; mip = desc->Texture3D.MipSlice; break;
                default: break;
            }
            if (sl_cnt == 0xffffffffu) sl_cnt = 0;
        }
        v->mtl_tex = t->get_or_create_view(mpf, mtype, mip, 1, sl0, sl_cnt);
        uint32_t d3d_slices = (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D) ? 1u
                            : (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE1D) ? std::max(1u, t->desc1d.ArraySize)
                            : std::max(1u, t->desc2d.ArraySize);
        v->mip0 = mip;
        v->slice0 = std::min(sl0, d3d_slices - 1);
        v->slice_cnt = (sl_cnt == 0 || v->slice0 + sl_cnt > d3d_slices) ? (d3d_slices - v->slice0) : sl_cnt;
        if (desc && (desc->ViewDimension == BO3_D3D11_UAV_DIMENSION_TEXTURE1D ||
                     desc->ViewDimension == BO3_D3D11_UAV_DIMENSION_TEXTURE2D ||
                     desc->ViewDimension == BO3_D3D11_UAV_DIMENSION_TEXTURE3D)) {
            v->slice0 = 0; v->slice_cnt = 1;
        }
    }
    *pp = v;
    return ret_u64(BO3_S_OK);
}

// slot 9 (+0x48): CreateRenderTargetView(pRes, pDesc, ppRTV)
static SHIM_DEF(dev_create_rtv) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    Bo3MetalResource *res = (Bo3MetalResource *)rsi;
    const Bo3D3D11_RENDER_TARGET_VIEW_DESC *desc = (const Bo3D3D11_RENDER_TARGET_VIEW_DESC *)rdx;
    void **pp = (void **)rcx;
    if (!res || !pp) return ret_u64(BO3_E_INVALIDARG);

    Bo3MetalRTV *v = new Bo3MetalRTV();
    v->com.init_com(g_vt_rtv, "ID3D11RenderTargetView", rtv_qi, rtv_dtor);
    v->device = dev;
    dev->add_internal_ref();
    v->resource = res;
    res->com.add_ref();
    memset(&v->desc, 0, sizeof(v->desc));
    if (desc) v->desc = *desc;
    v->mip_slice = 0;
    v->array_slice = 0;
    v->array_size = 1;

    if (res->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalTexture *t = (Bo3MetalTexture *)res;
        uint32_t fmt = (desc && desc->Format) ? desc->Format : t->dxgi_format;
        MTLPixelFormat mpf = bo3_dxgi_to_metal_format(fmt, false, false).pixel_format;
        v->mtl_format = (mpf != MTLPixelFormatInvalid) ? mpf : t->mtl_format;
        uint32_t max_slices = 1;
        if (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D) {
            max_slices = std::max(1u, t->desc3d.Depth);
        } else {
            max_slices = std::max(1u, t->desc2d.ArraySize);
        }
        if (desc) {
            switch (desc->ViewDimension) {
                case BO3_D3D11_RTV_DIMENSION_TEXTURE1D:
                    v->mip_slice = desc->Texture1D.MipSlice;
                    v->array_size = 1;
                    break;
                case BO3_D3D11_RTV_DIMENSION_TEXTURE1DARRAY:
                    v->mip_slice = desc->Texture1DArray.MipSlice;
                    v->array_slice = desc->Texture1DArray.FirstArraySlice;
                    v->array_size = desc->Texture1DArray.ArraySize;
                    break;
                case BO3_D3D11_RTV_DIMENSION_TEXTURE2D:
                    v->mip_slice = desc->Texture2D.MipSlice;
                    v->array_size = 1;
                    break;
                case BO3_D3D11_RTV_DIMENSION_TEXTURE2DARRAY:
                    v->mip_slice = desc->Texture2DArray.MipSlice;
                    v->array_slice = desc->Texture2DArray.FirstArraySlice;
                    v->array_size = desc->Texture2DArray.ArraySize;
                    break;
                case BO3_D3D11_RTV_DIMENSION_TEXTURE2DMS:
                    v->array_size = 1;
                    break;
                case BO3_D3D11_RTV_DIMENSION_TEXTURE2DMSARRAY:
                    v->array_slice = desc->Texture2DMSArray.FirstArraySlice;
                    v->array_size = desc->Texture2DMSArray.ArraySize;
                    break;
                case BO3_D3D11_RTV_DIMENSION_TEXTURE3D:
                    v->mip_slice = desc->Texture3D.MipSlice;
                    v->array_slice = desc->Texture3D.FirstWSlice;
                    v->array_size = desc->Texture3D.WSize;
                    max_slices = std::max(1u, t->desc3d.Depth >> v->mip_slice);
                    break;
                default:
                    v->array_size = max_slices;
                    break;
            }
        } else {
            v->array_size = max_slices;
        }
        if (v->array_slice >= max_slices) v->array_slice = 0;
        uint32_t rem = max_slices - v->array_slice;
        if (v->array_size == 0 || v->array_size == 0xffffffffu || v->array_size > rem) {
            v->array_size = rem;
        }
        if (v->array_size == 0) v->array_size = 1;
    } else {
        v->mtl_format = MTLPixelFormatRGBA8Unorm;
    }
    *pp = v;
    return ret_u64(BO3_S_OK);
}

// slot 10 (+0x50): CreateDepthStencilView(pRes, pDesc, ppDSV)
static SHIM_DEF(dev_create_dsv) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    Bo3MetalResource *res = (Bo3MetalResource *)rsi;
    const Bo3D3D11_DEPTH_STENCIL_VIEW_DESC *desc = (const Bo3D3D11_DEPTH_STENCIL_VIEW_DESC *)rdx;
    void **pp = (void **)rcx;
    if (!res || !pp) return ret_u64(BO3_E_INVALIDARG);

    Bo3MetalDSV *v = new Bo3MetalDSV();
    v->com.init_com(g_vt_dsv, "ID3D11DepthStencilView", dsv_qi, dsv_dtor);
    v->device = dev;
    dev->add_internal_ref();
    v->resource = res;
    res->com.add_ref();
    memset(&v->desc, 0, sizeof(v->desc));
    if (desc) v->desc = *desc;
    v->mip_slice = 0;
    v->array_slice = 0;
    v->array_size = 1;

    Bo3MetalTexture *t = (Bo3MetalTexture *)res;
    uint32_t fmt = (desc && desc->Format) ? desc->Format : t->dxgi_format;
    Bo3FormatInfo fi = bo3_dxgi_to_metal_format(fmt, true, false);
    v->mtl_format = (fi.pixel_format != MTLPixelFormatInvalid) ? fi.pixel_format : t->mtl_format;
    v->has_stencil = (v->mtl_format == MTLPixelFormatDepth32Float_Stencil8);
    uint32_t max_slices = std::max(1u, t->desc2d.ArraySize);
    if (desc) {
        switch (desc->ViewDimension) {
            case BO3_D3D11_DSV_DIMENSION_TEXTURE1D:
                v->mip_slice = desc->Texture1D.MipSlice;
                v->array_size = 1;
                break;
            case BO3_D3D11_DSV_DIMENSION_TEXTURE1DARRAY:
                v->mip_slice = desc->Texture1DArray.MipSlice;
                v->array_slice = desc->Texture1DArray.FirstArraySlice;
                v->array_size = desc->Texture1DArray.ArraySize;
                break;
            case BO3_D3D11_DSV_DIMENSION_TEXTURE2D:
                v->mip_slice = desc->Texture2D.MipSlice;
                v->array_size = 1;
                break;
            case BO3_D3D11_DSV_DIMENSION_TEXTURE2DARRAY:
                v->mip_slice = desc->Texture2DArray.MipSlice;
                v->array_slice = desc->Texture2DArray.FirstArraySlice;
                v->array_size = desc->Texture2DArray.ArraySize;
                break;
            case BO3_D3D11_DSV_DIMENSION_TEXTURE2DMS:
                v->array_size = 1;
                break;
            case BO3_D3D11_DSV_DIMENSION_TEXTURE2DMSARRAY:
                v->array_slice = desc->Texture2DMSArray.FirstArraySlice;
                v->array_size = desc->Texture2DMSArray.ArraySize;
                break;
            default:
                v->array_size = max_slices;
                break;
        }
    } else {
        v->array_size = max_slices;
    }
    if (v->array_slice >= max_slices) v->array_slice = 0;
    uint32_t rem = max_slices - v->array_slice;
    if (v->array_size == 0 || v->array_size == 0xffffffffu || v->array_size > rem) {
        v->array_size = rem;
    }
    if (v->array_size == 0) v->array_size = 1;
    *pp = v;
    return ret_u64(BO3_S_OK);
}

// slot 11 (+0x58): CreateInputLayout(pDescs, NumElements, pBytecode, BytecodeLen, ppInputLayout)
static SHIM_DEF(dev_create_input_layout) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_INPUT_ELEMENT_DESC *elems = (const Bo3D3D11_INPUT_ELEMENT_DESC *)rsi;
    uint32_t num = (uint32_t)rdx;
    const uint8_t *dxbc = (const uint8_t *)rcx;
    size_t dxbc_len = (size_t)r8;
    void **pp = (void **)r9;
    if (!elems || !pp) return ret_u64(BO3_E_INVALIDARG);

    std::vector<Bo3DxbcInputElem> isgn;
    bo3_dxbc_extract_isgn(dxbc, dxbc_len, &isgn);

    static std::atomic<uint64_t> g_next_il_uid{1};
    Bo3MetalInputLayout *il = new Bo3MetalInputLayout();
    il->com.init_com(g_vt_input_layout, "ID3D11InputLayout", il_qi, il_dtor);
    il->device = dev;
    dev->add_internal_ref();
    il->unique_id = g_next_il_uid.fetch_add(1, std::memory_order_relaxed);

    uint32_t slot_cursor[32] = {0};
    uint64_t hash = 14695981039346656037ULL;
    for (uint32_t i = 0; i < num; i++) {
        Bo3InputElemResolved r = {};
        if (elems[i].SemanticName) strlcpy(r.semantic, elems[i].SemanticName, sizeof(r.semantic));
        r.semantic_index = elems[i].SemanticIndex;
        r.dxgi_format = elems[i].Format;
        uint32_t bsz = 0;
        r.mtl_format = bo3_dxgi_to_vertex_format(elems[i].Format, &bsz);
        r.input_slot = elems[i].InputSlot < 32 ? elems[i].InputSlot : 0;
        r.byte_offset = (elems[i].AlignedByteOffset == 0xffffffffu) ? slot_cursor[r.input_slot]
                                                                    : elems[i].AlignedByteOffset;
        slot_cursor[r.input_slot] = r.byte_offset + bsz;
        r.input_slot_class = elems[i].InputSlotClass;
        r.step_rate = elems[i].InstanceDataStepRate;

        // Match semantic name + index against DXBC ISGN register_idx -> [[attribute(register_idx)]]
        // When ISGN is present, unmatched elements MUST be ignored (-1) so they never clobber real attributes!
        r.attr_index = isgn.empty() ? (int32_t)i : -1;
        for (const auto &s : isgn) {
            if (strcasecmp(s.semantic, r.semantic) == 0 && s.semantic_index == r.semantic_index) {
                r.attr_index = (int32_t)s.register_idx;
                break;
            }
        }
        il->elements.push_back(r);
        hash ^= ((uint64_t)r.attr_index | ((uint64_t)r.mtl_format << 8) |
                 ((uint64_t)r.input_slot << 16) | ((uint64_t)r.byte_offset << 24) |
                 ((uint64_t)r.input_slot_class << 48));
        hash *= 1099511628211ULL;
    }
    il->layout_hash = hash;
    *pp = il;
    return ret_u64(BO3_S_OK);
}

// Shaders: VS (slot 12), GS (slot 13), PS (slot 15), CS (slot 18)
static SHIM_DEF(dev_create_vs) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    void **pp = (void **)r8;
    if (!pp) return ret_u64(BO3_E_INVALIDARG);
    *pp = bo3_shader_cache_create(dev, BO3_STAGE_VS, (const uint8_t *)rsi, (size_t)rdx, bo3_metal_get_shader_name());
    bo3_metal_set_shader_name(nullptr); // consume the TLS name: never leak it into the next Create*Shader
    return ret_u64(*pp ? BO3_S_OK : BO3_E_OUTOFMEMORY);
}
static SHIM_DEF(dev_create_gs) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    void **pp = (void **)r8;
    if (!pp) return ret_u64(BO3_E_INVALIDARG);
    *pp = bo3_shader_cache_create(dev, BO3_STAGE_GS, (const uint8_t *)rsi, (size_t)rdx, bo3_metal_get_shader_name());
    bo3_metal_set_shader_name(nullptr); // consume the TLS name: never leak it into the next Create*Shader
    return ret_u64(*pp ? BO3_S_OK : BO3_E_OUTOFMEMORY);
}
static SHIM_DEF(dev_create_ps) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    void **pp = (void **)r8;
    if (!pp) return ret_u64(BO3_E_INVALIDARG);
    *pp = bo3_shader_cache_create(dev, BO3_STAGE_PS, (const uint8_t *)rsi, (size_t)rdx, bo3_metal_get_shader_name());
    bo3_metal_set_shader_name(nullptr); // consume the TLS name: never leak it into the next Create*Shader
    return ret_u64(*pp ? BO3_S_OK : BO3_E_OUTOFMEMORY);
}
static SHIM_DEF(dev_create_hs_ds_unsupported) {
    SHIM_UNUSED_ALL();
    if (r8) *(void **)r8 = nullptr;
    return ret_u64(BO3_E_NOTIMPL);
}
static SHIM_DEF(dev_create_cs) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    void **pp = (void **)r8;
    if (!pp) return ret_u64(BO3_E_INVALIDARG);
    *pp = bo3_shader_cache_create(dev, BO3_STAGE_CS, (const uint8_t *)rsi, (size_t)rdx, bo3_metal_get_shader_name());
    bo3_metal_set_shader_name(nullptr); // consume the TLS name: never leak it into the next Create*Shader
    return ret_u64(*pp ? BO3_S_OK : BO3_E_OUTOFMEMORY);
}

// Helper conversions for DepthStencil / Sampler states
static MTLCompareFunction d3d_cmp_to_mtl(uint32_t c) {
    switch (c) {
        case 1: return MTLCompareFunctionNever;
        case 2: return MTLCompareFunctionLess;
        case 3: return MTLCompareFunctionEqual;
        case 4: return MTLCompareFunctionLessEqual;
        case 5: return MTLCompareFunctionGreater;
        case 6: return MTLCompareFunctionNotEqual;
        case 7: return MTLCompareFunctionGreaterEqual;
        case 8: return MTLCompareFunctionAlways;
        default: return MTLCompareFunctionLess;
    }
}
static MTLStencilOperation d3d_stencil_to_mtl(uint32_t s) {
    switch (s) {
        case 1: return MTLStencilOperationKeep;
        case 2: return MTLStencilOperationZero;
        case 3: return MTLStencilOperationReplace;
        case 4: return MTLStencilOperationIncrementClamp;
        case 5: return MTLStencilOperationDecrementClamp;
        case 6: return MTLStencilOperationInvert;
        case 7: return MTLStencilOperationIncrementWrap;
        case 8: return MTLStencilOperationDecrementWrap;
        default: return MTLStencilOperationKeep;
    }
}
static MTLSamplerAddressMode d3d_addr_to_mtl(uint32_t a) {
    switch (a) {
        case 1: return MTLSamplerAddressModeRepeat;
        case 2: return MTLSamplerAddressModeMirrorRepeat;
        case 3: return MTLSamplerAddressModeClampToEdge;
        case 4: return MTLSamplerAddressModeClampToBorderColor;
        case 5: return MTLSamplerAddressModeMirrorClampToEdge;
        default: return MTLSamplerAddressModeClampToEdge;
    }
}

// slot 20 (+0xa0): CreateBlendState
static SHIM_DEF(dev_create_blend_state) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_BLEND_DESC *desc = (const Bo3D3D11_BLEND_DESC *)rsi;
    void **pp = (void **)rdx;
    if (!desc || !pp) return ret_u64(BO3_E_INVALIDARG);
    Bo3MetalBlendState *bs = new Bo3MetalBlendState();
    bs->com.init_com(g_vt_blend_state, "ID3D11BlendState", bs_qi, bs_dtor);
    bs->device = dev;
    dev->add_internal_ref();
    memset(&bs->desc, 0, sizeof(bs->desc));
    bs->desc.AlphaToCoverageEnable = desc->AlphaToCoverageEnable ? 1 : 0;
    bs->desc.IndependentBlendEnable = desc->IndependentBlendEnable ? 1 : 0;
    int nrt = bs->desc.IndependentBlendEnable ? 8 : 1;
    for (int i = 0; i < nrt; i++) {
        bs->desc.RenderTarget[i] = desc->RenderTarget[i];
        bs->desc.RenderTarget[i]._pad[0] = bs->desc.RenderTarget[i]._pad[1] = bs->desc.RenderTarget[i]._pad[2] = 0;
    }
    uint64_t h = 14695981039346656037ULL;
    const uint8_t *raw = (const uint8_t *)&bs->desc;
    for (size_t i = 0; i < sizeof(bs->desc); i++) { h ^= raw[i]; h *= 1099511628211ULL; }
    bs->state_hash = h;
    *pp = bs;
    return ret_u64(BO3_S_OK);
}

// slot 21 (+0xa8): CreateDepthStencilState
static SHIM_DEF(dev_create_ds_state) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_DEPTH_STENCIL_DESC *desc = (const Bo3D3D11_DEPTH_STENCIL_DESC *)rsi;
    void **pp = (void **)rdx;
    if (!desc || !pp) return ret_u64(BO3_E_INVALIDARG);

    Bo3MetalDepthStencilState *ds = new Bo3MetalDepthStencilState();
    ds->com.init_com(g_vt_ds_state, "ID3D11DepthStencilState", ds_qi, ds_dtor);
    ds->device = dev;
    dev->add_internal_ref();
    ds->desc = *desc;

    auto build_dss = [&](bool ro_depth, bool ro_stencil, bool with_stencil = true) -> id<MTLDepthStencilState> {
        MTLDepthStencilDescriptor *md = [MTLDepthStencilDescriptor new];
        md.depthCompareFunction = desc->DepthEnable ? d3d_cmp_to_mtl(desc->DepthFunc) : MTLCompareFunctionAlways;
        md.depthWriteEnabled = (!ro_depth && desc->DepthEnable && desc->DepthWriteMask != 0) ? YES : NO;
        if (desc->StencilEnable && with_stencil) {
            auto make_st = [&](const Bo3D3D11_DEPTH_STENCILOP_DESC &op) {
                MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
                sd.stencilFailureOperation = d3d_stencil_to_mtl(op.StencilFailOp);
                sd.depthFailureOperation = d3d_stencil_to_mtl(op.StencilDepthFailOp);
                sd.depthStencilPassOperation = d3d_stencil_to_mtl(op.StencilPassOp);
                sd.stencilCompareFunction = d3d_cmp_to_mtl(op.StencilFunc);
                sd.readMask = desc->StencilReadMask;
                sd.writeMask = ro_stencil ? 0u : desc->StencilWriteMask;
                return sd;
            };
            md.frontFaceStencil = make_st(desc->FrontFace);
            md.backFaceStencil  = make_st(desc->BackFace);
        }
        return [dev->mtl_dev newDepthStencilStateWithDescriptor:md];
    };

    ds->mtl_dss            = build_dss(false, false);
    ds->mtl_dss_ro_depth   = build_dss(true,  false);
    ds->mtl_dss_ro_stencil = build_dss(false, true);
    ds->mtl_dss_ro_both    = build_dss(true,  true);
    // Depth-only DSV twins: frontFaceStencil/backFaceStencil = nil (no stencil attachment bound)
    ds->mtl_dss_nostencil         = build_dss(false, false, false);
    ds->mtl_dss_nostencil_ro_depth = build_dss(true,  false, false);

    MTLDepthStencilDescriptor *nd = [MTLDepthStencilDescriptor new];
    nd.depthCompareFunction = MTLCompareFunctionAlways;
    nd.depthWriteEnabled = NO;
    ds->mtl_dss_nodepth = [dev->mtl_dev newDepthStencilStateWithDescriptor:nd];

    *pp = ds;
    return ret_u64(BO3_S_OK);
}

// slot 22 (+0xb0): CreateRasterizerState
static SHIM_DEF(dev_create_rs_state) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_RASTERIZER_DESC *desc = (const Bo3D3D11_RASTERIZER_DESC *)rsi;
    void **pp = (void **)rdx;
    if (!desc || !pp) return ret_u64(BO3_E_INVALIDARG);
    Bo3MetalRasterizerState *rs = new Bo3MetalRasterizerState();
    rs->com.init_com(g_vt_rs_state, "ID3D11RasterizerState", rs_qi, rs_dtor);
    rs->device = dev;
    dev->add_internal_ref();
    rs->desc = *desc;
    *pp = rs;
    return ret_u64(BO3_S_OK);
}

// slot 23 (+0xb8): CreateSamplerState (plus clamp-to-edge cube twin for sNcube!)
static SHIM_DEF(dev_create_sampler_state) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_SAMPLER_DESC *desc = (const Bo3D3D11_SAMPLER_DESC *)rsi;
    void **pp = (void **)rdx;
    if (!desc || !pp) return ret_u64(BO3_E_INVALIDARG);

    Bo3MetalSamplerState *sm = new Bo3MetalSamplerState();
    sm->com.init_com(g_vt_sampler_state, "ID3D11SamplerState", smp_qi, smp_dtor);
    sm->device = dev;
    dev->add_internal_ref();
    sm->desc = *desc;

    auto build_smp = [&](bool force_clamp) -> id<MTLSamplerState> {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        uint32_t f = desc->Filter;
        // D3D11 filter reduction type lives in bits 7..8: 0 = standard, 1 = COMPARISON,
        // 2 = MINIMUM, 3 = MAXIMUM. Only COMPARISON filters may set a compare function!
        const uint32_t reduction = (f >> 7) & 0x3u;
        bool is_cmp = (reduction == 1u);
        bool is_aniso = (f & 0x40u) != 0;
        sd.minFilter = (is_aniso || (f & 0x10u)) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.magFilter = (is_aniso || (f & 0x04u)) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.mipFilter = (is_aniso || (f & 0x01u)) ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
        sd.maxAnisotropy = is_aniso ? std::clamp(desc->MaxAnisotropy, 1u, 16u) : 1u;
        sd.sAddressMode = force_clamp ? MTLSamplerAddressModeClampToEdge : d3d_addr_to_mtl(desc->AddressU);
        sd.tAddressMode = force_clamp ? MTLSamplerAddressModeClampToEdge : d3d_addr_to_mtl(desc->AddressV);
        sd.rAddressMode = force_clamp ? MTLSamplerAddressModeClampToEdge : d3d_addr_to_mtl(desc->AddressW);
        sd.lodMinClamp = std::max(0.0f, desc->MinLOD);
        sd.lodMaxClamp = std::max(sd.lodMinClamp, desc->MaxLOD);
        if (is_cmp) sd.compareFunction = d3d_cmp_to_mtl(desc->ComparisonFunc);
        // Border color approximation
        if (desc->BorderColor[0] > 0.5f && desc->BorderColor[3] > 0.5f)
            sd.borderColor = MTLSamplerBorderColorOpaqueWhite;
        else if (desc->BorderColor[3] > 0.5f)
            sd.borderColor = MTLSamplerBorderColorOpaqueBlack;
        else
            sd.borderColor = MTLSamplerBorderColorTransparentBlack;
        return [dev->mtl_dev newSamplerStateWithDescriptor:sd];
    };

    sm->mtl_smp = build_smp(false);
    sm->mtl_smp_cube = build_smp(true);
    *pp = sm;
    return ret_u64(BO3_S_OK);
}

// slot 24 (+0xc0): CreateQuery
static SHIM_DEF(dev_create_query) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    const Bo3D3D11_QUERY_DESC *desc = (const Bo3D3D11_QUERY_DESC *)rsi;
    void **pp = (void **)rdx;
    if (!desc || !pp) return ret_u64(BO3_E_INVALIDARG);
    Bo3MetalQuery *q = new Bo3MetalQuery();
    q->com.init_com(g_vt_query, "ID3D11Query", qry_qi, qry_dtor);
    q->device = dev;
    dev->add_internal_ref();
    q->desc = *desc;
    q->target_fence.store(0, std::memory_order_relaxed);
    q->timestamp_ns.store(0, std::memory_order_relaxed);
    q->occlusion_val.store(1, std::memory_order_relaxed);
    q->ended.store(false, std::memory_order_relaxed);
    *pp = q;
    return ret_u64(BO3_S_OK);
}

// slot 27 (+0xd8): CreateDeferredContext -> not needed (BO3 falls back to immediate context!)
static SHIM_DEF(dev_create_deferred_ctx) {
    SHIM_UNUSED_ALL();
    if (rdx) *(void **)rdx = nullptr;
    return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);
}

static bool dev_is_integer_mtl_format(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint:
        case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
        case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint:
        case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint:
        case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint:
        case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint:
        case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint:
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint:
        case MTLPixelFormatRGB10A2Uint:
            return true;
        default:
            return false;
    }
}

// D3D11_FORMAT_SUPPORT flags for `fmt` (false when the format is unsupported)
static bool compute_format_support(uint32_t fmt, uint32_t *out) {
    Bo3FormatInfo fi = bo3_dxgi_to_metal_format(fmt, false, false);
    if (fi.pixel_format == MTLPixelFormatInvalid) {
        *out = 0;
        return false;
    }
    // Exact public D3D11_FORMAT_SUPPORT_* bitmasks
    constexpr uint32_t F_BUFFER                  = 0x00000001u;
    constexpr uint32_t F_IA_VERTEX_BUFFER        = 0x00000002u;
    constexpr uint32_t F_IA_INDEX_BUFFER         = 0x00000004u;
    constexpr uint32_t F_TEXTURE1D               = 0x00000010u;
    constexpr uint32_t F_TEXTURE2D               = 0x00000020u;
    constexpr uint32_t F_TEXTURE3D               = 0x00000040u;
    constexpr uint32_t F_TEXTURECUBE             = 0x00000080u;
    constexpr uint32_t F_SHADER_LOAD             = 0x00000100u;
    constexpr uint32_t F_SHADER_SAMPLE           = 0x00000200u;
    constexpr uint32_t F_SHADER_SAMPLE_CMP       = 0x00000400u;
    constexpr uint32_t F_MIP                     = 0x00001000u;
    constexpr uint32_t F_MIP_AUTOGEN             = 0x00002000u;
    constexpr uint32_t F_RENDER_TARGET           = 0x00004000u;
    constexpr uint32_t F_BLENDABLE               = 0x00008000u;
    constexpr uint32_t F_DEPTH_STENCIL           = 0x00010000u;
    constexpr uint32_t F_MULTISAMPLE_RESOLVE     = 0x00040000u;
    constexpr uint32_t F_DISPLAY                 = 0x00080000u;
    constexpr uint32_t F_CAST_WITHIN_BIT_LAYOUT  = 0x00100000u;
    constexpr uint32_t F_MULTISAMPLE_RT          = 0x00200000u;
    constexpr uint32_t F_MULTISAMPLE_LOAD        = 0x00400000u;
    constexpr uint32_t F_SHADER_GATHER           = 0x00800000u;
    constexpr uint32_t F_BACK_BUFFER_CAST        = 0x01000000u;
    constexpr uint32_t F_TYPED_UAV               = 0x02000000u;
    constexpr uint32_t F_SHADER_GATHER_CMP       = 0x04000000u;

    uint32_t flags = 0;
    if (fi.is_depth || fi.has_stencil) {
        flags = F_TEXTURE2D | F_TEXTURECUBE | F_MIP | F_DEPTH_STENCIL |
                F_SHADER_LOAD | F_SHADER_SAMPLE | F_SHADER_SAMPLE_CMP |
                F_SHADER_GATHER | F_SHADER_GATHER_CMP |
                F_MULTISAMPLE_RT | F_MULTISAMPLE_LOAD | F_CAST_WITHIN_BIT_LAYOUT;
    } else if (fi.block_dim > 1) {
        flags = F_TEXTURE2D | F_TEXTURE3D | F_TEXTURECUBE | F_MIP |
                F_SHADER_LOAD | F_SHADER_SAMPLE | F_SHADER_GATHER |
                F_CAST_WITHIN_BIT_LAYOUT;
    } else if (dev_is_integer_mtl_format(fi.pixel_format)) {
        flags = F_BUFFER | F_IA_VERTEX_BUFFER |
                F_TEXTURE1D | F_TEXTURE2D | F_TEXTURE3D | F_TEXTURECUBE | F_MIP |
                F_SHADER_LOAD | F_RENDER_TARGET | F_MULTISAMPLE_RT | F_MULTISAMPLE_LOAD |
                F_CAST_WITHIN_BIT_LAYOUT | F_TYPED_UAV;
        if (fmt == 57u /* R16_UINT */ || fmt == 42u /* R32_UINT */) {
            flags |= F_IA_INDEX_BUFFER;
        }
    } else {
        flags = F_BUFFER | F_IA_VERTEX_BUFFER |
                F_TEXTURE1D | F_TEXTURE2D | F_TEXTURE3D | F_TEXTURECUBE |
                F_MIP | F_MIP_AUTOGEN | F_SHADER_LOAD | F_SHADER_SAMPLE |
                F_SHADER_SAMPLE_CMP | F_SHADER_GATHER | F_SHADER_GATHER_CMP |
                F_RENDER_TARGET | F_BLENDABLE | F_MULTISAMPLE_RESOLVE |
                F_MULTISAMPLE_RT | F_MULTISAMPLE_LOAD | F_CAST_WITHIN_BIT_LAYOUT | F_TYPED_UAV;
        if (fmt == 28u || fmt == 29u || fmt == 87u || fmt == 91u || fmt == 24u || fmt == 10u) {
            flags |= F_DISPLAY | F_BACK_BUFFER_CAST;
        }
        if (fmt == 39u /* R32_TYPELESS */ || fmt == 53u /* R16_TYPELESS */) {
            flags |= F_DEPTH_STENCIL;
        }
    }
    *out = flags;
    return true;
}

// slot 29 (+0xe8): CheckFormatSupport(Format, pFormatSupport)
static SHIM_DEF(dev_check_format_support) {
    SHIM_UNUSED_ALL();
    uint32_t fmt = (uint32_t)rsi;
    uint32_t *out = (uint32_t *)rdx;
    if (!out) return ret_u64(BO3_E_INVALIDARG);
    return ret_u64(compute_format_support(fmt, out) ? BO3_S_OK : BO3_E_FAIL);
}

// slot 30 (+0xf0): CheckMultisampleQualityLevels(Format, SampleCount, pNumQualityLevels)
static SHIM_DEF(dev_check_msaa_levels) {
    SHIM_UNUSED_ALL();
    uint32_t samples = (uint32_t)rdx;
    uint32_t *out = (uint32_t *)rcx;
    if (!out) return ret_u64(BO3_E_INVALIDARG);
    *out = (samples == 1 || samples == 2 || samples == 4) ? 1u : 0u;
    return ret_u64(BO3_S_OK);
}

// slot 14: CreateGeometryShaderWithStreamOutput(pBytecode, Len, pSODecl, NumEntries, pStrides,
//          NumStrides, RasterizedStream, pClassLinkage, ppGS) -> ppGS is the 10th integer arg
static SHIM_DEF(dev_create_gs_so) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    void **pp = (void **)shim_stack_u64(rsp, 3);
    if (!pp) return ret_u64(BO3_S_FALSE); // validation-only call
    *pp = bo3_shader_cache_create(dev, BO3_STAGE_GS, (const uint8_t *)rsi, (size_t)rdx, bo3_metal_get_shader_name());
    bo3_metal_set_shader_name(nullptr);
    return ret_u64(*pp ? BO3_S_OK : BO3_E_OUTOFMEMORY);
}
// slot 19: CreateClassLinkage(ppLinkage) / slot 26: CreateCounter(pDesc, ppCounter)
static SHIM_DEF(dev_create_class_linkage) {
    SHIM_UNUSED_ALL();
    if (rsi) *(void **)rsi = nullptr;
    return ret_u64(BO3_E_NOTIMPL);
}
static SHIM_DEF(dev_create_counter) {
    SHIM_UNUSED_ALL();
    if (rdx) *(void **)rdx = nullptr;
    return ret_u64(BO3_DXGI_ERROR_UNSUPPORTED);
}
// slot 28: OpenSharedResource(hResource, riid, ppResource)
static SHIM_DEF(dev_open_shared_resource) {
    SHIM_UNUSED_ALL();
    if (rcx) *(void **)rcx = nullptr;
    return ret_u64(BO3_E_NOTIMPL);
}
// slot 31: CheckCounterInfo(pCounterInfo) -> no device-dependent counters
static SHIM_DEF(dev_check_counter_info) {
    SHIM_UNUSED_ALL();
    if (rsi) memset((void *)rsi, 0, 12); // D3D11_COUNTER_INFO { LastDeviceDependentCounter, NumSimultaneousCounters, NumDetectableParallelUnits }
    return ret_void();
}
// slot 32: CheckCounter(pDesc, pType, pActiveCounters, szName, pNameLength, szUnits, pUnitsLength, szDesc, pDescLength)
static SHIM_DEF(dev_check_counter) {
    SHIM_UNUSED_ALL();
    if (rdx) *(uint32_t *)rdx = 0;
    if (rcx) *(uint32_t *)rcx = 0;
    if (r9)  *(uint32_t *)r9 = 0;
    return ret_u64(BO3_E_INVALIDARG);
}
// slot 33: CheckFeatureSupport(Feature, pFeatureSupportData, FeatureSupportDataSize)
static SHIM_DEF(dev_check_feature_support) {
    SHIM_UNUSED_ALL();
    uint32_t feature = (uint32_t)rsi;
    uint8_t *data = (uint8_t *)rdx;
    uint32_t size = (uint32_t)rcx;
    if (!data || size == 0) return ret_u64(BO3_E_INVALIDARG);
    // FORMAT_SUPPORT / FORMAT_SUPPORT2 carry an input DXGI_FORMAT in the first DWORD: read it first
    uint32_t in_fmt = 0;
    if (size >= 4) memcpy(&in_fmt, data, 4);
    memset(data, 0, size);
    auto set_u32 = [&](uint32_t off, uint32_t v) { if (off + 4 <= size) memcpy(data + off, &v, 4); };
    switch (feature) {
        case 0: // D3D11_FEATURE_THREADING { BOOL DriverConcurrentCreates; BOOL DriverCommandLists; }
            if (size < 8) return ret_u64(BO3_E_INVALIDARG);
            set_u32(0, 0); // runtime-emulated concurrent creates
            set_u32(4, 0); // no deferred contexts / command lists
            return ret_u64(BO3_S_OK);
        case 1: // D3D11_FEATURE_DOUBLES { BOOL DoublePrecisionFloatShaderOps; } -> Metal has no fp64
            if (size < 4) return ret_u64(BO3_E_INVALIDARG);
            return ret_u64(BO3_S_OK);
        case 2: { // D3D11_FEATURE_FORMAT_SUPPORT { DXGI_FORMAT InFormat; UINT OutFormatSupport; }
            if (size < 8) return ret_u64(BO3_E_INVALIDARG);
            uint32_t flags = 0;
            bool ok = compute_format_support(in_fmt, &flags);
            set_u32(0, in_fmt);
            set_u32(4, flags);
            return ret_u64(ok ? BO3_S_OK : BO3_E_FAIL);
        }
        case 3: // D3D11_FEATURE_FORMAT_SUPPORT2 -> no UAV typed load/atomic extras advertised
            if (size < 8) return ret_u64(BO3_E_INVALIDARG);
            set_u32(0, in_fmt);
            return ret_u64(BO3_S_OK);
        case 4: // D3D11_FEATURE_D3D10_X_HARDWARE_OPTIONS { BOOL CS4x_RawAndStructuredBuffers; }
            if (size < 4) return ret_u64(BO3_E_INVALIDARG);
            set_u32(0, 1);
            return ret_u64(BO3_S_OK);
        case 5: // D3D11_FEATURE_D3D11_OPTIONS (14 BOOLs) -> all FALSE (11.0 baseline)
            if (size < 56) return ret_u64(BO3_E_INVALIDARG);
            return ret_u64(BO3_S_OK);
        case 6: // D3D11_FEATURE_ARCHITECTURE_INFO { BOOL TileBasedDeferredRenderer; }
            if (size < 4) return ret_u64(BO3_E_INVALIDARG);
            set_u32(0, 1); // Apple GPUs are TBDR
            return ret_u64(BO3_S_OK);
        case 7: // D3D11_FEATURE_D3D9_OPTIONS
        case 8: // D3D11_FEATURE_SHADER_MIN_PRECISION_SUPPORT
        case 9: // D3D11_FEATURE_D3D9_SHADOW_SUPPORT
            return ret_u64(BO3_S_OK);
        default:
            return ret_u64(BO3_E_INVALIDARG);
    }
}

// slot 37 (+0x128): GetFeatureLevel
static SHIM_DEF(dev_get_feature_level) {
    SHIM_UNUSED_ALL();
    return ret_u64(0xb000u); // D3D_FEATURE_LEVEL_11_0
}

// slot 38 (+0x130): GetCreationFlags
static SHIM_DEF(dev_get_creation_flags) {
    SHIM_UNUSED_ALL();
    return ret_u64(0);
}

// slot 39 (+0x138): GetDeviceRemovedReason
static SHIM_DEF(dev_get_device_removed_reason) {
    SHIM_UNUSED_ALL();
    return ret_u64(BO3_S_OK);
}

// slot 40 (+0x140): GetImmediateContext
static SHIM_DEF(dev_get_immediate_context) {
    SHIM_UNUSED_ALL();
    Bo3MetalDevice *dev = (Bo3MetalDevice *)rdi;
    void **pp = (void **)rsi;
    if (!pp) return ret_void();
    *pp = nullptr;
    if (!dev) return ret_void();
    os_unfair_lock_lock(&dev->ctx_lock);
    Bo3MetalContext *ictx = dev->immediate_ctx;
    if (ictx && ((Bo3ComBase *)ictx)->try_add_ref()) *pp = ictx;
    os_unfair_lock_unlock(&dev->ctx_lock);
    return ret_void();
}

static uint32_t device_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    Bo3MetalDevice *dev = (Bo3MetalDevice *)self;
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_ID3D11Device)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    if (bo3_guid_eq(riid, &BO3_IID_IDXGIDevice) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIDevice1) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIDevice2)) {
        *ppv = bo3_dxgi_create_device_wrapper(dev);
        return BO3_S_OK;
    }
    if (riid) {
        fprintf(stderr, "[metal-dev] device_qi UNMATCHED IID {%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}\n",
                riid->Data1, riid->Data2, riid->Data3,
                riid->Data4[0], riid->Data4[1], riid->Data4[2], riid->Data4[3],
                riid->Data4[4], riid->Data4[5], riid->Data4[6], riid->Data4[7]);
        fflush(stderr);
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

// Last EXTERNAL device ref released. The immediate context is NOT detached: if the app still
// holds it, it stays attached (dev->immediate_ctx valid) so ctx->GetDevice() can resurrect the
// device consistently. ctx_dtor clears dev->immediate_ctx when the context itself dies.
static void device_dtor(Bo3ComBase *self) {
    Bo3MetalDevice *dev = (Bo3MetalDevice *)self;
    Bo3MetalContext *ctx = nullptr;
    os_unfair_lock_lock(&dev->ctx_lock);
    if (dev->holds_ctx_ref) {
        dev->holds_ctx_ref = false;
        ctx = dev->immediate_ctx;
    }
    os_unfair_lock_unlock(&dev->ctx_lock);
    if (ctx) {
        bo3_context_flush_now(ctx, true);
        ((Bo3ComBase *)ctx)->release(); // may run ctx_dtor (which clears dev->immediate_ctx)
    }
    dev->release_internal_ref();
}

Bo3MetalDevice *bo3_d3d11_create_device_obj(void *dxgi_adapter) {
    id<MTLDevice> mdev = MTLCreateSystemDefaultDevice();
    if (!mdev) {
        fprintf(stderr, "[metal-dev] FATAL: MTLCreateSystemDefaultDevice returned nil!\n");
        return nullptr;
    }
    bo3_shader_cache_init(mdev);

    Bo3MetalDevice *dev = new Bo3MetalDevice();
    dev->com.init_com(g_vt_device, "ID3D11Device", device_qi, device_dtor);
    dev->internal_refs.store(1, std::memory_order_relaxed);
    dev->mtl_dev = mdev;
    dev->mtl_queue = [mdev newCommandQueue];
    dev->zero_buffer = [mdev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    memset(dev->zero_buffer.contents, 0, 65536);
    dev->dummy_uav_buf = [mdev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    memset(dev->dummy_uav_buf.contents, 0, 65536);

    // Fallback dummy textures & sampler (covers every Bo3TexExpect x Bo3TexNumericType + writable UAV dummies!)
    auto make_dummy = [&](MTLTextureType tt, MTLPixelFormat pf, MTLTextureUsage usage, uint32_t samples = 1) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = tt;
        td.pixelFormat = pf;
        td.width = 1;
        td.height = 1;
        td.depth = 1;
        td.arrayLength = 1;
        td.sampleCount = samples;
        td.storageMode = MTLStorageModePrivate;
        td.usage = usage;
        return [mdev newTextureWithDescriptor:td];
    };
    const MTLPixelFormat num_pf[3] = {
        MTLPixelFormatRGBA8Unorm, // BO3_TEX_NUM_FLOAT
        MTLPixelFormatR32Uint,    // BO3_TEX_NUM_UINT
        MTLPixelFormatR32Sint,    // BO3_TEX_NUM_SINT
    };
    for (int nt = 0; nt < 3; nt++) {
        MTLPixelFormat pf = num_pf[nt];
        dev->dummy_tex_1d[nt]        = make_dummy(MTLTextureType1D,                 pf, MTLTextureUsageShaderRead);
        dev->dummy_tex_1d_arr[nt]    = make_dummy(MTLTextureType1DArray,            pf, MTLTextureUsageShaderRead);
        dev->dummy_tex_2d[nt]        = make_dummy(MTLTextureType2D,                 pf, MTLTextureUsageShaderRead);
        dev->dummy_tex_2d_arr[nt]    = make_dummy(MTLTextureType2DArray,            pf, MTLTextureUsageShaderRead);
        dev->dummy_tex_2d_ms[nt]     = make_dummy(MTLTextureType2DMultisample,      pf, MTLTextureUsageShaderRead, 2);
        dev->dummy_tex_2d_ms_arr[nt] = make_dummy(MTLTextureType2DMultisampleArray, pf, MTLTextureUsageShaderRead, 2);
        dev->dummy_tex_cube[nt]      = make_dummy(MTLTextureTypeCube,               pf, MTLTextureUsageShaderRead);
        dev->dummy_tex_cube_arr[nt]  = make_dummy(MTLTextureTypeCubeArray,          pf, MTLTextureUsageShaderRead);
        dev->dummy_tex_3d[nt]        = make_dummy(MTLTextureType3D,                 pf, MTLTextureUsageShaderRead);

        MTLTextureUsage uav_use = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
#if defined(__MAC_14_0)
        if (@available(macOS 14.0, *)) {
            if (mtl_format_supports_atomic(pf)) uav_use |= MTLTextureUsageShaderAtomic;
        }
#endif
        dev->dummy_uav_1d[nt]        = make_dummy(MTLTextureType1D,      pf, uav_use);
        dev->dummy_uav_1d_arr[nt]    = make_dummy(MTLTextureType1DArray, pf, uav_use);
        dev->dummy_uav_2d[nt]        = make_dummy(MTLTextureType2D,      pf, uav_use);
        dev->dummy_uav_2d_arr[nt]    = make_dummy(MTLTextureType2DArray, pf, uav_use);
        dev->dummy_uav_3d[nt]        = make_dummy(MTLTextureType3D,      pf, uav_use);
    }
    dev->dummy_tex_depth          = make_dummy(MTLTextureType2D,        MTLPixelFormatDepth32Float, MTLTextureUsageShaderRead);
    dev->dummy_tex_depth_arr      = make_dummy(MTLTextureType2DArray,   MTLPixelFormatDepth32Float, MTLTextureUsageShaderRead);
    dev->dummy_tex_depth_cube     = make_dummy(MTLTextureTypeCube,      MTLPixelFormatDepth32Float, MTLTextureUsageShaderRead);
    dev->dummy_tex_depth_cube_arr = make_dummy(MTLTextureTypeCubeArray, MTLPixelFormatDepth32Float, MTLTextureUsageShaderRead);

    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.mipFilter = MTLSamplerMipFilterLinear;
    dev->dummy_sampler = [mdev newSamplerStateWithDescriptor:sd];

    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled = YES;
    dev->default_dss = [mdev newDepthStencilStateWithDescriptor:dd];
    MTLDepthStencilDescriptor *dro = [MTLDepthStencilDescriptor new];
    dro.depthCompareFunction = MTLCompareFunctionLess;
    dro.depthWriteEnabled = NO;
    dev->default_dss_ro_depth = [mdev newDepthStencilStateWithDescriptor:dro];
    MTLDepthStencilDescriptor *nd = [MTLDepthStencilDescriptor new];
    nd.depthCompareFunction = MTLCompareFunctionAlways;
    nd.depthWriteEnabled = NO;
    dev->default_dss_nodepth = [mdev newDepthStencilStateWithDescriptor:nd];

    if (dxgi_adapter) {
        dev->dxgi_adapter = dxgi_adapter;
        ((Bo3ComBase *)dxgi_adapter)->add_ref();
    } else {
        dev->dxgi_adapter = bo3_dxgi_create_default_adapter();
    }
    dev->max_frame_latency.store(3, std::memory_order_relaxed);
    {
        // Auto-tune Apple Silicon settings for this GPU + display (honors settings.ini + env overrides)
        const bool apple8_plus = [mdev supportsFamily:MTLGPUFamilyApple8];
        int32_t phys_w = 0, phys_h = 0;
        bo3_win_get_physical_screen_size(&phys_w, &phys_h);
        bo3_settings_init_for_device(mdev.name ? mdev.name.UTF8String : "Apple Silicon",
                                     apple8_plus, phys_w, phys_h);
    }
    dev->ctx_lock = OS_UNFAIR_LOCK_INIT;
    dev->immediate_ctx = bo3_d3d11_create_context_obj(dev);
    dev->holds_ctx_ref = (dev->immediate_ctx != nullptr);

    fprintf(stderr, "[metal-dev] Created Direct Metal ID3D11Device on '%s' (device=%p, ctx=%p)\n",
            mdev.name.UTF8String, (void *)dev, (void *)dev->immediate_ctx);
    fflush(stderr);
    return dev;
}

void bo3_d3d11_init_vtables() {
    bo3_com_init_vtable(g_vt_device, 48, "ID3D11Device");
    bo3_com_set_slot(g_vt_device, 3,  dev_create_buffer);
    bo3_com_set_slot(g_vt_device, 4,  dev_create_tex1d);
    bo3_com_set_slot(g_vt_device, 5,  dev_create_tex2d);
    bo3_com_set_slot(g_vt_device, 6,  dev_create_tex3d);
    bo3_com_set_slot(g_vt_device, 7,  dev_create_srv);
    bo3_com_set_slot(g_vt_device, 8,  dev_create_uav);
    bo3_com_set_slot(g_vt_device, 9,  dev_create_rtv);
    bo3_com_set_slot(g_vt_device, 10, dev_create_dsv);
    bo3_com_set_slot(g_vt_device, 11, dev_create_input_layout);
    bo3_com_set_slot(g_vt_device, 12, dev_create_vs);
    bo3_com_set_slot(g_vt_device, 13, dev_create_gs);
    bo3_com_set_slot(g_vt_device, 14, dev_create_gs_so);
    bo3_com_set_slot(g_vt_device, 15, dev_create_ps);
    bo3_com_set_slot(g_vt_device, 16, dev_create_hs_ds_unsupported);
    bo3_com_set_slot(g_vt_device, 17, dev_create_hs_ds_unsupported);
    bo3_com_set_slot(g_vt_device, 18, dev_create_cs);
    bo3_com_set_slot(g_vt_device, 19, dev_create_class_linkage);
    bo3_com_set_slot(g_vt_device, 20, dev_create_blend_state);
    bo3_com_set_slot(g_vt_device, 21, dev_create_ds_state);
    bo3_com_set_slot(g_vt_device, 22, dev_create_rs_state);
    bo3_com_set_slot(g_vt_device, 23, dev_create_sampler_state);
    bo3_com_set_slot(g_vt_device, 24, dev_create_query);
    bo3_com_set_slot(g_vt_device, 25, dev_create_query); // CreatePredicate
    bo3_com_set_slot(g_vt_device, 26, dev_create_counter);
    bo3_com_set_slot(g_vt_device, 27, dev_create_deferred_ctx);
    bo3_com_set_slot(g_vt_device, 28, dev_open_shared_resource);
    bo3_com_set_slot(g_vt_device, 29, dev_check_format_support);
    bo3_com_set_slot(g_vt_device, 30, dev_check_msaa_levels);
    bo3_com_set_slot(g_vt_device, 31, dev_check_counter_info);
    bo3_com_set_slot(g_vt_device, 32, dev_check_counter);
    bo3_com_set_slot(g_vt_device, 33, dev_check_feature_support);
    bo3_com_set_slot(g_vt_device, 34, any_get_private_data);
    bo3_com_set_slot(g_vt_device, 35, any_set_private_data);
    bo3_com_set_slot(g_vt_device, 36, any_set_private_data);
    bo3_com_set_slot(g_vt_device, 37, dev_get_feature_level);
    bo3_com_set_slot(g_vt_device, 38, dev_get_creation_flags);
    bo3_com_set_slot(g_vt_device, 39, dev_get_device_removed_reason);
    bo3_com_set_slot(g_vt_device, 40, dev_get_immediate_context);

    auto set_child_common = [](uint64_t *vt) {
        bo3_com_set_slot(vt, 4, any_get_private_data);
        bo3_com_set_slot(vt, 5, any_set_private_data);
        bo3_com_set_slot(vt, 6, any_set_private_data);
    };
    auto set_resource_common = [&](uint64_t *vt) {
        set_child_common(vt);
        bo3_com_set_slot(vt, 3, res_get_device);
        bo3_com_set_slot(vt, 7, res_get_type);
        bo3_com_set_slot(vt, 8, res_set_eviction);
        bo3_com_set_slot(vt, 9, res_get_eviction);
    };

    bo3_com_init_vtable(g_vt_buffer, 16, "ID3D11Buffer");
    set_resource_common(g_vt_buffer);
    bo3_com_set_slot(g_vt_buffer, 10, buf_get_desc);

    bo3_com_init_vtable(g_vt_tex1d, 16, "ID3D11Texture1D");
    set_resource_common(g_vt_tex1d);
    bo3_com_set_slot(g_vt_tex1d, 10, tex1d_get_desc);

    bo3_com_init_vtable(g_vt_tex2d, 16, "ID3D11Texture2D");
    set_resource_common(g_vt_tex2d);
    bo3_com_set_slot(g_vt_tex2d, 10, tex2d_get_desc);

    bo3_com_init_vtable(g_vt_tex3d, 16, "ID3D11Texture3D");
    set_resource_common(g_vt_tex3d);
    bo3_com_set_slot(g_vt_tex3d, 10, tex3d_get_desc);

    bo3_com_init_vtable(g_vt_srv, 16, "ID3D11ShaderResourceView");
    set_child_common(g_vt_srv);
    bo3_com_set_slot(g_vt_srv, 3, child_get_device);
    bo3_com_set_slot(g_vt_srv, 7, view_srv_get_res);
    bo3_com_set_slot(g_vt_srv, 8, srv_get_desc);

    bo3_com_init_vtable(g_vt_rtv, 16, "ID3D11RenderTargetView");
    set_child_common(g_vt_rtv);
    bo3_com_set_slot(g_vt_rtv, 3, child_get_device);
    bo3_com_set_slot(g_vt_rtv, 7, view_rtv_get_res);
    bo3_com_set_slot(g_vt_rtv, 8, rtv_get_desc);

    bo3_com_init_vtable(g_vt_dsv, 16, "ID3D11DepthStencilView");
    set_child_common(g_vt_dsv);
    bo3_com_set_slot(g_vt_dsv, 3, child_get_device);
    bo3_com_set_slot(g_vt_dsv, 7, view_dsv_get_res);
    bo3_com_set_slot(g_vt_dsv, 8, dsv_get_desc);

    bo3_com_init_vtable(g_vt_uav, 16, "ID3D11UnorderedAccessView");
    set_child_common(g_vt_uav);
    bo3_com_set_slot(g_vt_uav, 3, child_get_device);
    bo3_com_set_slot(g_vt_uav, 7, view_uav_get_res);
    bo3_com_set_slot(g_vt_uav, 8, uav_get_desc);

    bo3_com_init_vtable(g_vt_shader,        12, "ID3D11Shader");
    set_child_common(g_vt_shader);
    bo3_com_set_slot(g_vt_shader, 3, child_get_device);
    bo3_com_init_vtable(g_vt_input_layout,  12, "ID3D11InputLayout");
    set_child_common(g_vt_input_layout);
    bo3_com_set_slot(g_vt_input_layout, 3, child_get_device);
    bo3_com_init_vtable(g_vt_blend_state,   12, "ID3D11BlendState");
    set_child_common(g_vt_blend_state);
    bo3_com_set_slot(g_vt_blend_state, 3, child_get_device);
    bo3_com_set_slot(g_vt_blend_state, 7, bs_get_desc);
    bo3_com_init_vtable(g_vt_ds_state,      12, "ID3D11DepthStencilState");
    set_child_common(g_vt_ds_state);
    bo3_com_set_slot(g_vt_ds_state, 3, child_get_device);
    bo3_com_set_slot(g_vt_ds_state, 7, ds_get_desc);
    bo3_com_init_vtable(g_vt_rs_state,      12, "ID3D11RasterizerState");
    set_child_common(g_vt_rs_state);
    bo3_com_set_slot(g_vt_rs_state, 3, child_get_device);
    bo3_com_set_slot(g_vt_rs_state, 7, rs_get_desc);
    bo3_com_init_vtable(g_vt_sampler_state, 12, "ID3D11SamplerState");
    set_child_common(g_vt_sampler_state);
    bo3_com_set_slot(g_vt_sampler_state, 3, child_get_device);
    bo3_com_set_slot(g_vt_sampler_state, 7, smp_get_desc);
    bo3_com_init_vtable(g_vt_query,         12, "ID3D11Query");
    set_child_common(g_vt_query);
    bo3_com_set_slot(g_vt_query, 3, child_get_device);
    bo3_com_set_slot(g_vt_query, 7, qry_get_data_size);
    bo3_com_set_slot(g_vt_query, 8, qry_get_desc);
}

// 0x10006ff10: D3D11CreateDevice(pAdapter, DriverType, Software, Flags, pFeatureLevels, FeatureLevels, SDKVersion, ppDevice, pFeatureLevel, ppImmediateContext)
extern "C" SHIM_DEF(g_10006ff10) {
    SHIM_UNUSED_ALL();
    void *p_adapter    = (void *)rdi;
    void **pp_dev      = (void **)shim_stack_u64(rsp, 1);
    uint32_t *p_fl     = (uint32_t *)shim_stack_u64(rsp, 2);
    void **pp_ctx      = (void **)shim_stack_u64(rsp, 3);

    Bo3MetalDevice *dev = bo3_d3d11_create_device_obj(p_adapter);
    if (!dev) return ret_u64(BO3_E_FAIL);
    if (p_fl) *p_fl = 0xb000u; // D3D_FEATURE_LEVEL_11_0
    if (pp_ctx) {
        ((Bo3ComBase *)dev->immediate_ctx)->add_ref();
        *pp_ctx = dev->immediate_ctx;
    }
    if (pp_dev) {
        *pp_dev = dev;
    } else {
        dev->com.release();
    }
    return ret_u64(BO3_S_OK);
}

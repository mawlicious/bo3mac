#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#include "d3d11_metal.h"
#include "settings_mac.h"
#include "window_mac.h"
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <vector>

// =========================================================================
// DXGI COM Objects: IDXGIFactory1, IDXGIAdapter1, IDXGIOutput, IDXGIDevice2, IDXGISwapChain
// =========================================================================

struct Bo3DXGIFactory1 {
    Bo3ComBase com;
    uint64_t   assoc_hwnd;
};

struct Bo3DXGIAdapter1 {
    Bo3ComBase       com;
    Bo3DXGIFactory1 *factory;
};

struct Bo3DXGIOutput {
    Bo3ComBase com;
    int32_t    width;
    int32_t    height;
};

struct Bo3DXGIDevice2 {
    Bo3ComBase      com;
    Bo3MetalDevice *device;
};

static uint64_t g_vt_dxgi_factory[16];
static uint64_t g_vt_dxgi_adapter[16];
static uint64_t g_vt_dxgi_output[20];
static uint64_t g_vt_dxgi_device[20];
static uint64_t g_vt_dxgi_swapchain[20];

static Bo3DXGIOutput *g_default_output = nullptr;

// Helper: copy ASCII string into 32-bit wchar_t array (macOS Aspyr ABI)
static void copy_ascii_to_wchar32(uint32_t *dst, size_t max_chars, const char *src) {
    size_t i = 0;
    for (; src[i] && i + 1 < max_chars; i++) dst[i] = (uint32_t)(unsigned char)src[i];
    dst[i] = 0;
}

static uint64_t monotonic_ns() {
    static mach_timebase_info_data_t tb = {0, 0};
    if (!tb.denom) mach_timebase_info(&tb);
    return (mach_absolute_time() * (uint64_t)tb.numer) / (uint64_t)tb.denom;
}

// =========================================================================
// IDXGIOutput
// =========================================================================

static uint32_t dxgi_output_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIObject) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIOutput)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static void dxgi_output_dtor(Bo3ComBase *self) {
    delete (Bo3DXGIOutput *)self;
}

static Bo3DXGIOutput *create_dxgi_output() {
    Bo3DXGIOutput *o = new Bo3DXGIOutput();
    o->com.init_com(g_vt_dxgi_output, "IDXGIOutput", dxgi_output_qi, dxgi_output_dtor);
    bo3_win_get_screen_size(&o->width, &o->height);
    if (o->width < 640) o->width = 1920;
    if (o->height < 360) o->height = 1080;
    return o;
}

void *bo3_dxgi_get_default_output(void) {
    static std::once_flag out_once;
    std::call_once(out_once, []() {
        g_default_output = create_dxgi_output();
    });
    g_default_output->com.add_ref();
    return g_default_output;
}

// slot 7 (+0x38): IDXGIOutput::GetDesc(DXGI_OUTPUT_DESC*)
static SHIM_DEF(dxgi_output_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3DXGIOutput *self = (Bo3DXGIOutput *)rdi;
    Bo3DXGI_OUTPUT_DESC *d = (Bo3DXGI_OUTPUT_DESC *)rsi;
    if (!d) return ret_u64(BO3_E_INVALIDARG);
    memset(d, 0, sizeof(*d));
    copy_ascii_to_wchar32(d->DeviceName, 32, "\\\\.\\DISPLAY1");
    d->DesktopCoordinates.left = 0;
    d->DesktopCoordinates.top = 0;
    d->DesktopCoordinates.right = self->width;
    d->DesktopCoordinates.bottom = self->height;
    d->AttachedToDesktop = 1;
    d->Rotation = 1; // DXGI_MODE_ROTATION_IDENTITY
    d->Monitor = 1;  // HMONITOR 1 (matches MonitorFromWindow / GetMonitorInfoA)
    return ret_u64(BO3_S_OK);
}

// slot 8 (+0x40): IDXGIOutput::GetDisplayModeList(EnumFormat, Flags, pNumModes, pDesc)
static SHIM_DEF(dxgi_output_get_display_mode_list) {
    SHIM_UNUSED_ALL();
    Bo3DXGIOutput *self = (Bo3DXGIOutput *)rdi;
    uint32_t fmt = (uint32_t)rsi;
    uint32_t *p_num = (uint32_t *)rcx;
    Bo3DXGI_MODE_DESC *p_desc = (Bo3DXGI_MODE_DESC *)r8;
    if (!p_num) return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);

    static const struct { uint32_t w, h, hz; } kModes[] = {
        { 1280,  720,  60 },
        { 1280,  800,  60 },
        { 1440,  900,  60 },
        { 1600,  900,  60 },
        { 1920, 1080,  60 },
        { 1920, 1080, 120 },
        { 2560, 1440,  60 },
        { 2560, 1440, 120 },
        { 3840, 2160,  60 },
        { 3840, 2160, 120 },
    };
    std::vector<Bo3DXGI_MODE_DESC> modes;
    auto push_mode = [&](uint32_t w, uint32_t h, uint32_t hz) {
        if (w < 640 || h < 360 || (int32_t)w > self->width || (int32_t)h > self->height) return;
        for (const auto &ex : modes) {
            if (ex.Width == w && ex.Height == h && ex.RefreshRate.Numerator == hz * 1000u) return;
        }
        Bo3DXGI_MODE_DESC md = {};
        md.Width = w;
        md.Height = h;
        md.RefreshRate.Numerator = hz * 1000u;
        md.RefreshRate.Denominator = 1000u;
        md.Format = fmt ? fmt : 28u; // R8G8B8A8_UNORM
        md.ScanlineOrdering = 1;     // PROGRESSIVE
        md.Scaling = 0;              // UNSPECIFIED
        modes.push_back(md);
    };
    for (auto &m : kModes) push_mode(m.w, m.h, m.hz);
    // Expose native-aspect 75% and 80% MetalFX-friendly resolutions directly in BO3's own
    // Graphics -> Display Resolution menu when running at native startup scale (skip when startup
    // virtual display is already scaled so we never double-scale).
    if (bo3_metalfx_render_scale_pct() == 100 && self->width >= 1280 && self->height >= 720) {
        for (uint32_t pct : { 75u, 80u }) {
            uint32_t sw = std::max<uint32_t>(640u, (uint32_t)(((uint64_t)self->width * pct + 50) / 100) & ~7u);
            uint32_t sh = std::max<uint32_t>(360u, (uint32_t)(((uint64_t)self->height * pct + 50) / 100) & ~1u);
            push_mode(sw, sh, 60u);
            push_mode(sw, sh, 120u);
        }
    }
    // Always include desktop/virtual screen size
    if (self->width >= 640 && self->height >= 360) {
        push_mode((uint32_t)self->width, (uint32_t)self->height, 60u);
        push_mode((uint32_t)self->width, (uint32_t)self->height, 120u);
    }
    std::sort(modes.begin(), modes.end(), [](const Bo3DXGI_MODE_DESC &a, const Bo3DXGI_MODE_DESC &b) {
        if (a.Width != b.Width) return a.Width < b.Width;
        if (a.Height != b.Height) return a.Height < b.Height;
        return a.RefreshRate.Numerator < b.RefreshRate.Numerator;
    });

    if (!p_desc) {
        *p_num = (uint32_t)modes.size();
        return ret_u64(BO3_S_OK);
    }
    uint32_t cap = *p_num;
    uint32_t n = std::min(cap, (uint32_t)modes.size());
    memcpy(p_desc, modes.data(), n * sizeof(Bo3DXGI_MODE_DESC));
    *p_num = n;
    return ret_u64(cap < modes.size() ? BO3_DXGI_ERROR_MORE_DATA : BO3_S_OK);
}

// slot 9 (+0x48): IDXGIOutput::FindClosestMatchingMode
static SHIM_DEF(dxgi_output_find_closest_mode) {
    SHIM_UNUSED_ALL();
    Bo3DXGIOutput *self = (Bo3DXGIOutput *)rdi;
    const Bo3DXGI_MODE_DESC *req = (const Bo3DXGI_MODE_DESC *)rsi;
    Bo3DXGI_MODE_DESC *out = (Bo3DXGI_MODE_DESC *)rdx;
    if (!req || !out) return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);
    *out = *req;
    if (out->Width < 640) out->Width = (self && self->width >= 640) ? (uint32_t)self->width : 1280u;
    if (out->Height < 360) out->Height = (self && self->height >= 360) ? (uint32_t)self->height : 720u;
    if (self && self->width >= 640 && self->height >= 360 &&
        ((int32_t)out->Width > self->width || (int32_t)out->Height > self->height)) {
        out->Width = (uint32_t)self->width;
        out->Height = (uint32_t)self->height;
    }
    if (out->RefreshRate.Numerator == 0 || out->RefreshRate.Denominator == 0) {
        out->RefreshRate.Numerator = 60000;
        out->RefreshRate.Denominator = 1000;
    }
    if (out->Format == 0) out->Format = 28u;
    out->ScanlineOrdering = 1;
    return ret_u64(BO3_S_OK);
}

// =========================================================================
// IDXGIAdapter1
// =========================================================================

static uint32_t dxgi_adapter_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIObject) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIAdapter) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIAdapter1)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    if (riid) {
        fprintf(stderr, "[metal-dxgi] adapter_qi UNMATCHED IID {%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}\n",
                riid->Data1, riid->Data2, riid->Data3,
                riid->Data4[0], riid->Data4[1], riid->Data4[2], riid->Data4[3],
                riid->Data4[4], riid->Data4[5], riid->Data4[6], riid->Data4[7]);
        fflush(stderr);
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static void dxgi_adapter_dtor(Bo3ComBase *self) {
    Bo3DXGIAdapter1 *a = (Bo3DXGIAdapter1 *)self;
    if (a->factory) a->factory->com.release();
    delete a;
}

// slot 6 (+0x30): IDXGIObject::GetParent(riid, ppParent) -> IDXGIFactory1
static SHIM_DEF(dxgi_adapter_get_parent) {
    SHIM_UNUSED_ALL();
    Bo3DXGIAdapter1 *self = (Bo3DXGIAdapter1 *)rdi;
    const Bo3GUID *riid = (const Bo3GUID *)rsi;
    void **ppv = (void **)rdx;
    if (!ppv || !self->factory) return ret_u64(BO3_E_POINTER);
    return ret_u64(self->factory->com.query_interface(riid, ppv));
}

// slot 7 (+0x38): IDXGIAdapter::EnumOutputs(idx, ppOutput)
static SHIM_DEF(dxgi_adapter_enum_outputs) {
    SHIM_UNUSED_ALL();
    uint32_t idx = (uint32_t)rsi;
    void **pp_out = (void **)rdx;
    if (!pp_out) return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);
    if (idx > 0) {
        *pp_out = nullptr;
        return ret_u64(BO3_DXGI_ERROR_NOT_FOUND);
    }
    *pp_out = bo3_dxgi_get_default_output();
    return ret_u64(BO3_S_OK);
}

// slot 8 (+0x40) GetDesc (0x230 bytes, NO Flags field!)
static void fill_adapter_desc_common(Bo3DXGI_ADAPTER_DESC1 *d, size_t struct_sz) {
    memset(d, 0, struct_sz);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    const char *gpu_name = dev ? dev.name.UTF8String : "Apple Silicon Native Metal";
    copy_ascii_to_wchar32(d->Description, 128, gpu_name);
    d->VendorId = 0x106Bu; // Apple (sets DAT_1113c0b98 = 0, avoids NV/AMD driver hacks)
    d->DeviceId = 0x0001u;
    uint64_t max_mem = dev ? dev.recommendedMaxWorkingSetSize : (8ULL << 30);
    if (max_mem < (4ULL << 30)) max_mem = 4ULL << 30;
    d->DedicatedVideoMemory = max_mem;
    d->SharedSystemMemory   = max_mem;
    d->AdapterLuidLow = 1;
}

static SHIM_DEF(dxgi_adapter_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3DXGI_ADAPTER_DESC1 *d = (Bo3DXGI_ADAPTER_DESC1 *)rsi;
    if (!d) return ret_u64(BO3_E_INVALIDARG);
    fill_adapter_desc_common(d, 0x230); // Exact DXGI_ADAPTER_DESC size (do NOT clobber +0x230!)
    return ret_u64(BO3_S_OK);
}

// slot 10 (+0x50) GetDesc1 (0x238 bytes)
static SHIM_DEF(dxgi_adapter_get_desc1) {
    SHIM_UNUSED_ALL();
    Bo3DXGI_ADAPTER_DESC1 *d = (Bo3DXGI_ADAPTER_DESC1 *)rsi;
    if (!d) return ret_u64(BO3_E_INVALIDARG);
    fill_adapter_desc_common(d, sizeof(Bo3DXGI_ADAPTER_DESC1));
    return ret_u64(BO3_S_OK);
}

// =========================================================================
// IDXGIFactory1
// =========================================================================

static uint32_t dxgi_factory_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIObject) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIFactory) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIFactory1)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    if (riid) {
        fprintf(stderr, "[metal-dxgi] factory_qi UNMATCHED IID {%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}\n",
                riid->Data1, riid->Data2, riid->Data3,
                riid->Data4[0], riid->Data4[1], riid->Data4[2], riid->Data4[3],
                riid->Data4[4], riid->Data4[5], riid->Data4[6], riid->Data4[7]);
        fflush(stderr);
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static void dxgi_factory_dtor(Bo3ComBase *self) {
    delete (Bo3DXGIFactory1 *)self;
}

static Bo3DXGIFactory1 *create_dxgi_factory() {
    Bo3DXGIFactory1 *f = new Bo3DXGIFactory1();
    f->com.init_com(g_vt_dxgi_factory, "IDXGIFactory1", dxgi_factory_qi, dxgi_factory_dtor);
    f->assoc_hwnd = 0;
    return f;
}

void *bo3_dxgi_create_default_adapter(void) {
    Bo3DXGIFactory1 *f = create_dxgi_factory();
    Bo3DXGIAdapter1 *a = new Bo3DXGIAdapter1();
    a->com.init_com(g_vt_dxgi_adapter, "IDXGIAdapter1", dxgi_adapter_qi, dxgi_adapter_dtor);
    a->factory = f; // transfers initial ref from create_dxgi_factory()
    return a;
}

// slot 7 (+0x38) EnumAdapters / slot 12 (+0x60) EnumAdapters1
static SHIM_DEF(dxgi_factory_enum_adapters1) {
    SHIM_UNUSED_ALL();
    Bo3DXGIFactory1 *self = (Bo3DXGIFactory1 *)rdi;
    uint32_t idx = (uint32_t)rsi;
    void **pp_adapter = (void **)rdx;
    if (!pp_adapter) return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);
    if (idx > 0) {
        *pp_adapter = nullptr;
        return ret_u64(BO3_DXGI_ERROR_NOT_FOUND);
    }
    Bo3DXGIAdapter1 *a = new Bo3DXGIAdapter1();
    a->com.init_com(g_vt_dxgi_adapter, "IDXGIAdapter1", dxgi_adapter_qi, dxgi_adapter_dtor);
    a->factory = self;
    self->com.add_ref();
    *pp_adapter = a;
    return ret_u64(BO3_S_OK);
}

// slot 8 (+0x40): MakeWindowAssociation
static SHIM_DEF(dxgi_factory_make_window_assoc) {
    SHIM_UNUSED_ALL();
    Bo3DXGIFactory1 *self = (Bo3DXGIFactory1 *)rdi;
    self->assoc_hwnd = rsi;
    return ret_u64(BO3_S_OK);
}

// slot 9 (+0x48): GetWindowAssociation
static SHIM_DEF(dxgi_factory_get_window_assoc) {
    SHIM_UNUSED_ALL();
    Bo3DXGIFactory1 *self = (Bo3DXGIFactory1 *)rdi;
    if (rsi) *(uint64_t *)rsi = self->assoc_hwnd;
    return ret_u64(BO3_S_OK);
}

// slot 10 (+0x50): IDXGIFactory::CreateSwapChain(pDevice, pDesc, ppSwapChain)
static SHIM_DEF(dxgi_factory_create_swapchain) {
    SHIM_UNUSED_ALL();
    Bo3ComBase *unk = (Bo3ComBase *)rsi;
    const Bo3DXGI_SWAP_CHAIN_DESC *desc = (const Bo3DXGI_SWAP_CHAIN_DESC *)rdx;
    void **pp_sc = (void **)rcx;
    if (!unk || !desc || !pp_sc) return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);
    Bo3MetalDevice *dev = nullptr;
    if (unk->query_interface(&BO3_IID_ID3D11Device, (void **)&dev) != BO3_S_OK || !dev) {
        *pp_sc = nullptr;
        return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);
    }
    Bo3MetalSwapChain *sc = bo3_dxgi_create_swapchain_obj(dev, desc);
    dev->com.release();
    if (!sc) {
        *pp_sc = nullptr;
        return ret_u64(BO3_E_FAIL);
    }
    *pp_sc = sc;
    return ret_u64(BO3_S_OK);
}

// slot 13 (+0x68): IDXGIFactory1::IsCurrent
static SHIM_DEF(dxgi_factory_is_current) {
    SHIM_UNUSED_ALL();
    return ret_u64(1);
}

// =========================================================================
// IDXGIDevice2 (QI wrapper around Bo3MetalDevice)
// =========================================================================

static uint32_t dxgi_device_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    Bo3DXGIDevice2 *d = (Bo3DXGIDevice2 *)self;
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIObject) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIDevice) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIDevice1) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIDevice2)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    return d->device->com.query_interface(riid, ppv);
}

static void dxgi_device_dtor(Bo3ComBase *self) {
    Bo3DXGIDevice2 *d = (Bo3DXGIDevice2 *)self;
    if (d->device) d->device->com.release();
    delete d;
}

void *bo3_dxgi_create_device_wrapper(Bo3MetalDevice *dev) {
    Bo3DXGIDevice2 *w = new Bo3DXGIDevice2();
    w->com.init_com(g_vt_dxgi_device, "IDXGIDevice2", dxgi_device_qi, dxgi_device_dtor);
    w->device = dev;
    dev->com.add_ref();
    return w;
}

// slot 6 (+0x30): GetParent(riid, ppParent) -> IDXGIAdapter1
static SHIM_DEF(dxgi_device_get_parent) {
    SHIM_UNUSED_ALL();
    Bo3DXGIDevice2 *self = (Bo3DXGIDevice2 *)rdi;
    const Bo3GUID *riid = (const Bo3GUID *)rsi;
    void **ppv = (void **)rdx;
    if (!ppv || !self->device) return ret_u64(BO3_E_POINTER);
    Bo3ComBase *adapter = (Bo3ComBase *)self->device->dxgi_adapter;
    if (!adapter) return ret_u64(BO3_E_FAIL);
    return ret_u64(adapter->query_interface(riid, ppv));
}

// slot 7 (+0x38): GetAdapter(ppAdapter)
static SHIM_DEF(dxgi_device_get_adapter) {
    SHIM_UNUSED_ALL();
    Bo3DXGIDevice2 *self = (Bo3DXGIDevice2 *)rdi;
    void **ppv = (void **)rsi;
    if (!ppv || !self->device || !self->device->dxgi_adapter) return ret_u64(BO3_E_POINTER);
    Bo3ComBase *adapter = (Bo3ComBase *)self->device->dxgi_adapter;
    adapter->add_ref();
    *ppv = adapter;
    return ret_u64(BO3_S_OK);
}

// slot 12 (+0x60): IDXGIDevice1::SetMaximumFrameLatency(MaxLatency)
// D3D11: 0 = default (3), valid 1..16. Stored as requested; every swap chain applies it on its next
// Present (frame_sem permits + CAMetalLayer.maximumDrawableCount), clamped to 1..3 frames in flight.
static SHIM_DEF(dxgi_device_set_max_latency) {
    SHIM_UNUSED_ALL();
    Bo3DXGIDevice2 *self = (Bo3DXGIDevice2 *)rdi;
    uint32_t lat = (uint32_t)rsi;
    if (lat > 16) return ret_u64(BO3_E_INVALIDARG);
    if (lat == 0) lat = 3;
    if (self->device) self->device->max_frame_latency.store(lat, std::memory_order_release);
    return ret_u64(BO3_S_OK);
}

// Live max frame latency (editable in-game via F10/Cmd+, or BO3ARM_MAX_FRAME_LATENCY=1..3; 0 = game default)
uint32_t bo3_dxgi_effective_frame_latency(Bo3MetalDevice *dev) {
    uint32_t pref = bo3_settings_max_frame_latency();
    if (pref >= 1 && pref <= 3) return pref;
    uint32_t lat = dev ? dev->max_frame_latency.load(std::memory_order_acquire) : 3u;
    if (lat == 0) lat = 3;
    return std::clamp(lat, 1u, 3u);
}

bool bo3_metalfx_enabled(void) {
    return bo3_settings_metalfx_enabled();
}

// Startup virtual display scale (50..100; frozen at launch so virtual display geometry stays stable,
// while live switching in-game uses BO3's own Display Resolution menu + live MetalFX toggle).
static uint32_t render_scale_pct_impl(id<MTLDevice> dev) {
    (void)dev;
    return bo3_settings_startup_render_scale();
}

extern "C" uint32_t bo3_metalfx_render_scale_pct(void) {
    return bo3_settings_startup_render_scale();
}

// Compute the CAMetalLayer drawable dimensions for a game-requested backbuffer (bb_w x bb_h):
// - Without MetalFX: 1:1 with the backbuffer.
// - With MetalFX: when the backbuffer is smaller than the physical monitor (either via --scale or
//   by choosing a lower in-game resolution in fullscreen), keep drawableSize at the physical monitor
//   resolution so MTLFXSpatialScaler upscales cleanly to the full display.
void bo3_dxgi_compute_drawable_size(uint64_t hwnd, uint32_t bb_w, uint32_t bb_h,
                                    uint32_t scale_pct, bool fullscreen,
                                    uint32_t *out_dw, uint32_t *out_dh) {
    uint32_t dw = bb_w, dh = bb_h;
    if (bo3_metalfx_enabled()) {
        int32_t pw = 0, ph = 0;
        bo3_win_get_physical_screen_size(&pw, &ph);
        if (pw > 0 && ph > 0) {
            if (fullscreen || scale_pct < 100 || bo3_win_is_borderless_or_fullscreen(hwnd)) {
                if (bb_w <= (uint32_t)pw && bb_h <= (uint32_t)ph &&
                    (bb_w < (uint32_t)pw || bb_h < (uint32_t)ph)) {
                    dw = (uint32_t)pw;
                    dh = (uint32_t)ph;
                }
            }
        }
    }
    *out_dw = dw;
    *out_dh = dh;
}

// slot 13 (+0x68): IDXGIDevice1::GetMaximumFrameLatency(pMaxLatency)
static SHIM_DEF(dxgi_device_get_max_latency) {
    SHIM_UNUSED_ALL();
    Bo3DXGIDevice2 *self = (Bo3DXGIDevice2 *)rdi;
    if (rsi && self->device) *(uint32_t *)rsi = self->device->max_frame_latency.load(std::memory_order_acquire);
    return ret_u64(BO3_S_OK);
}

// =========================================================================
// IDXGISwapChain
// =========================================================================

static uint32_t dxgi_swapchain_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIObject) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGIDeviceSubObject) ||
        bo3_guid_eq(riid, &BO3_IID_IDXGISwapChain)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static void dxgi_swapchain_dtor(Bo3ComBase *self) {
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)self;
    if (sc->device && sc->device->immediate_ctx) {
        bo3_context_flush_now(sc->device->immediate_ctx, true);
    }
    // Mark the shared backbuffer state dead FIRST: any surviving backbuffer proxy (still
    // referenced by the app or by bound RTVs/SRVs) only ever touches the shared_ptr state,
    // never this Bo3MetalSwapChain, so there is no use-after-free window.
    if (sc->bb_state) sc->bb_state->kill();
    Bo3MetalTexture *bb_tex = sc->backbuffer_tex;
    sc->backbuffer_tex = nullptr;
    sc->current_drawable = nil;
    if (bb_tex) {
        os_unfair_lock_lock(&bb_tex->view_lock);
        bb_tex->view_cache.clear();
        os_unfair_lock_unlock(&bb_tex->view_lock);
        bb_tex->res.com.release();
    }
    sc->bb_state.reset();
    bo3_win_clear_swapchain_sizes(sc->desc.OutputWindow, sc);
    if (sc->device) sc->device->com.release();
    delete sc;
}

// slot 6 (+0x30): IDXGIObject::GetParent(riid, ppParent) -> IDXGIFactory1
static SHIM_DEF(dxgi_swapchain_get_parent) {
    SHIM_UNUSED_ALL();
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)rdi;
    const Bo3GUID *riid = (const Bo3GUID *)rsi;
    void **ppv = (void **)rdx;
    if (!ppv) return ret_u64(BO3_E_POINTER);
    if (!sc || !sc->device || !sc->device->dxgi_adapter) {
        *ppv = nullptr;
        return ret_u64(BO3_E_FAIL);
    }
    Bo3DXGIAdapter1 *adapter = (Bo3DXGIAdapter1 *)sc->device->dxgi_adapter;
    if (adapter->factory) {
        return ret_u64(adapter->factory->com.query_interface(riid, ppv));
    }
    return ret_u64(adapter->com.query_interface(riid, ppv));
}

// slot 7 (+0x38): IDXGIDeviceSubObject::GetDevice(riid, ppDevice)
static SHIM_DEF(dxgi_swapchain_get_device) {
    SHIM_UNUSED_ALL();
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)rdi;
    const Bo3GUID *riid = (const Bo3GUID *)rsi;
    void **ppv = (void **)rdx;
    if (!ppv) return ret_u64(BO3_E_POINTER);
    if (!sc || !sc->device) {
        *ppv = nullptr;
        return ret_u64(BO3_E_FAIL);
    }
    return ret_u64(sc->device->com.query_interface(riid, ppv));
}

static void save_mtl_texture_png(id<MTLTexture> tex, id<MTLCommandQueue> queue, const char *path) {
    if (!tex || !path) return;
    NSUInteger w = tex.width, h = tex.height;
    if (w == 0 || h == 0) return;
    if (tex.pixelFormat != MTLPixelFormatRGBA8Unorm &&
        tex.pixelFormat != MTLPixelFormatRGBA8Unorm_sRGB &&
        tex.pixelFormat != MTLPixelFormatBGRA8Unorm &&
        tex.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) {
        fprintf(stderr, "[metal] save_mtl_texture_png: unsupported pixelFormat %lu\n", (unsigned long)tex.pixelFormat);
        return;
    }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:tex.pixelFormat
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> staging = [tex.device newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1)
                toTexture:staging destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    std::vector<uint8_t> pixels(w * h * 4);
    [staging getBytes:pixels.data() bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];

    // If BGRA, swizzle B and R for CGImage RGBA
    bool is_bgra = (tex.pixelFormat == MTLPixelFormatBGRA8Unorm || tex.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB);
    if (is_bgra) {
        for (size_t i = 0; i < w * h; i++) {
            std::swap(pixels[i * 4 + 0], pixels[i * 4 + 2]);
            pixels[i * 4 + 3] = 255;
        }
    } else {
        for (size_t i = 0; i < w * h; i++) pixels[i * 4 + 3] = 255;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(pixels.data(), w, h, 8, w * 4, cs,
                                            (uint32_t)kCGImageAlphaPremultipliedLast | (uint32_t)kCGBitmapByteOrder32Big);
    CGImageRef img = CGBitmapContextCreateImage(cg);
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (dst && img) {
        CGImageDestinationAddImage(dst, img, NULL);
        CGImageDestinationFinalize(dst);
        fprintf(stderr, "[metal] Saved frame capture (%lux%lu) -> %s\n",
                (unsigned long)w, (unsigned long)h, path);
        fflush(stderr);
    }
    if (dst) CFRelease(dst);
    if (img) CGImageRelease(img);
    if (cg) CGContextRelease(cg);
    CGColorSpaceRelease(cs);
}

id<MTLTexture> Bo3SwapChainState::acquire() {
    os_unfair_lock_lock(&lock);
    if (!alive || !mtl_dev) {
        os_unfair_lock_unlock(&lock);
        return nil;
    }
    if (!current_tex) {
        uint32_t w = width ? width : 1280;
        uint32_t h = height ? height : 720;
        Bo3FormatInfo fi = bo3_dxgi_to_metal_format(format ? format : 28u, false, false);
        MTLPixelFormat pf = (fi.pixel_format != MTLPixelFormatInvalid) ? fi.pixel_format : MTLPixelFormatRGBA8Unorm;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                                                      width:w
                                                                                     height:h
                                                                                  mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        // M5: no PixelFormatView on the backbuffer -> Apple lossless framebuffer compression stays on.
        // Flip-model _SRGB RTVs and the present-time linear view are sRGB twins (legal without it).
        MTLTextureUsage bb_usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        if (bo3_texture_needs_pixel_format_view(format ? format : 28u, &fi, false, false, pf)) {
            bb_usage |= MTLTextureUsagePixelFormatView;
        }
        td.usage = bb_usage;
        current_tex = [mtl_dev newTextureWithDescriptor:td];
        current_tex.label = @"BO3_BackBuffer";
    }
    id<MTLTexture> ret = current_tex;
    os_unfair_lock_unlock(&lock);
    return ret;
}

id<MTLTexture> Bo3SwapChainState::peek() {
    os_unfair_lock_lock(&lock);
    id<MTLTexture> ret = alive ? current_tex : nil;
    os_unfair_lock_unlock(&lock);
    return ret;
}

void Bo3SwapChainState::resize(uint32_t w, uint32_t h, uint32_t fmt) {
    os_unfair_lock_lock(&lock);
    if (w) width = w;
    if (h) height = h;
    if (fmt) format = fmt;
    current_tex = nil; // recreated lazily at the new size (ARC keeps in-flight textures alive)
    os_unfair_lock_unlock(&lock);
}

void Bo3SwapChainState::kill() {
    os_unfair_lock_lock(&lock);
    alive = false;
    current_tex = nil;
    os_unfair_lock_unlock(&lock);
}

id<MTLTexture> Bo3MetalSwapChain::acquire_backbuffer_texture() {
    return bb_state ? bb_state->acquire() : nil;
}

Bo3MetalSwapChain *bo3_dxgi_create_swapchain_obj(Bo3MetalDevice *dev, const Bo3DXGI_SWAP_CHAIN_DESC *desc) {
    Bo3MetalSwapChain *sc = new Bo3MetalSwapChain();
    sc->com.init_com(g_vt_dxgi_swapchain, "IDXGISwapChain", dxgi_swapchain_qi, dxgi_swapchain_dtor);
    sc->device = dev;
    dev->com.add_ref();
    sc->desc = *desc;
    if (sc->desc.BufferDesc.Width == 0 || sc->desc.BufferDesc.Height == 0) {
        int32_t cw = 1280, ch = 720;
        bo3_win_get_native_client_size(desc->OutputWindow, &cw, &ch);
        if (sc->desc.BufferDesc.Width == 0)  sc->desc.BufferDesc.Width  = (cw > 0) ? (uint32_t)cw : 1280u;
        if (sc->desc.BufferDesc.Height == 0) sc->desc.BufferDesc.Height = (ch > 0) ? (uint32_t)ch : 720u;
    }
    if (sc->desc.BufferDesc.Format == 0) sc->desc.BufferDesc.Format = 28u; // RGBA8_UNORM
    sc->render_scale = render_scale_pct_impl(dev->mtl_dev);
    sc->fullscreen = (desc->Windowed == 0);
    // Honor the EXACT backbuffer dimensions requested by the game (never shrink behind BO3's back,
    // which would clip viewports/HUD). Drawable stays at physical monitor size for MetalFX upscaling.
    bo3_dxgi_compute_drawable_size(desc->OutputWindow, sc->desc.BufferDesc.Width, sc->desc.BufferDesc.Height,
                                   sc->render_scale, sc->fullscreen, &sc->native_w, &sc->native_h);
    sc->target_w = sc->desc.BufferDesc.Width;
    sc->target_h = sc->desc.BufferDesc.Height;
    sc->has_pending_target = false;
    sc->bb_state = std::make_shared<Bo3SwapChainState>();
    sc->bb_state->mtl_dev = dev->mtl_dev;
    sc->bb_state->width = sc->desc.BufferDesc.Width;
    sc->bb_state->height = sc->desc.BufferDesc.Height;
    sc->bb_state->format = sc->desc.BufferDesc.Format;
    sc->present_lock = OS_UNFAIR_LOCK_INIT;
    sc->last_sync_interval.store(0xffffffffu, std::memory_order_relaxed);
    // Value 0 + N signals (never 3 directly): permits can later be withdrawn for a lower latency
    // without ever deallocating the semaphore below its creation value.
    sc->frame_sem = dispatch_semaphore_create(0);
    sc->sem_permits = bo3_dxgi_effective_frame_latency(dev);
    for (uint32_t i = 0; i < sc->sem_permits; i++) dispatch_semaphore_signal(sc->frame_sem);
    const uint32_t init_dc = std::clamp(sc->sem_permits, 2u, 3u);
    sc->drawable_count.store(init_dc, std::memory_order_relaxed);
    sc->drawables_in_flight = std::make_shared<std::atomic<uint32_t>>(0);
    sc->frame_index.store(0, std::memory_order_relaxed);
    sc->last_fps_ns = monotonic_ns();
    sc->last_fps_frames = 0;
    sc->last_hud_ns = sc->last_fps_ns;
    sc->last_hud_frames = 0;

    void *ml_raw = bo3_win_get_metal_layer(desc->OutputWindow);
    sc->layer = (__bridge CAMetalLayer *)ml_raw;
    if (sc->layer) {
        uint32_t w = sc->native_w;  // drawable stays native (MetalFX upscales a scaled backbuffer)
        uint32_t h = sc->native_h;
        CAMetalLayer *layer = sc->layer;
        id<MTLDevice> mdev = dev->mtl_dev;
        const NSUInteger dcount = init_dc;
        const uint64_t hwnd = desc->OutputWindow;
        auto cfg = ^{
            bo3_win_lock_layer(hwnd);
            layer.device = mdev;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize = CGSizeMake(w, h);
            layer.maximumDrawableCount = dcount;
            layer.framebufferOnly = NO;  // present blits / MetalFX write the drawable texture
            layer.opaque = YES;          // A3: no compositor alpha blend -> direct-to-display scanout
            bo3_win_unlock_layer(hwnd);
        };
        if ([NSThread isMainThread]) cfg();
        else dispatch_sync(dispatch_get_main_queue(), cfg);
    }

    sc->backbuffer_tex = bo3_d3d11_create_backbuffer_proxy(dev, sc);
    bo3_win_set_swapchain_sizes(desc->OutputWindow, sc,
                                (int32_t)sc->desc.BufferDesc.Width, (int32_t)sc->desc.BufferDesc.Height,
                                (int32_t)sc->native_w, (int32_t)sc->native_h);
    if (sc->fullscreen) {
        bo3_win_set_fullscreen(desc->OutputWindow, true);
    }
    fprintf(stderr, "[metal-dxgi] CreateSwapChain %ux%u fmt=%u windowed=%d layer=%p -> %p "
                    "(latency=%u drawables=%u drawable=%ux%u)\n",
            sc->desc.BufferDesc.Width, sc->desc.BufferDesc.Height,
            sc->desc.BufferDesc.Format, sc->desc.Windowed,
            (__bridge void *)sc->layer, (void *)sc, sc->sem_permits,
            sc->drawable_count.load(std::memory_order_relaxed),
            sc->native_w, sc->native_h);
    fflush(stderr);
    return sc;
}

// slot 8 (+0x40): IDXGISwapChain::Present(SyncInterval, Flags)
static SHIM_DEF(dxgi_swapchain_present) {
    SHIM_UNUSED_ALL();
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)rdi;
    uint32_t sync_interval = (uint32_t)rsi;
    uint32_t flags = (uint32_t)rdx;
    if (flags & 1u) return ret_u64(BO3_S_OK); // DXGI_PRESENT_TEST

    uint32_t hr = BO3_S_OK;
    @autoreleasepool {
        // Optional frame capture, scripted key injection & automated exit hooks
        struct ScriptKeyEv { uint64_t frame; uint16_t vk; uint8_t sc; bool down; };
        static uint64_t capture_frame = 0;
        static uint64_t exit_after = 0;
        static const char *capture_path = nullptr;
        static std::vector<uint64_t> capture_frames;
        static std::vector<ScriptKeyEv> script_keys;
        static std::once_flag env_once;
        std::call_once(env_once, []() {
            auto parse_u64_strict = [](const char *tok, size_t len, uint64_t *out) -> bool {
                if (!tok || len == 0 || len > 20) return false;
                char tmp[24];
                memcpy(tmp, tok, len);
                tmp[len] = '\0';
                char *end = nullptr;
                errno = 0;
                unsigned long long v = strtoull(tmp, &end, 10);
                if (errno != 0 || end != tmp + len) return false;
                *out = (uint64_t)v;
                return true;
            };
            if (const char *s = getenv("BO3ARM_CAPTURE_FRAME")) {
                uint64_t v = 0;
                if (parse_u64_strict(s, strlen(s), &v)) capture_frame = v;
            }
            if (const char *s = getenv("BO3ARM_EXIT_AFTER_FRAMES")) {
                uint64_t v = 0;
                if (parse_u64_strict(s, strlen(s), &v)) exit_after = v;
            }
            capture_path = getenv("BO3ARM_CAPTURE_PATH");
            if (!capture_path) capture_path = "/tmp/bo3mac_frame_capture.png";
            if (const char *s = getenv("BO3ARM_CAPTURE_FRAMES")) {
                const char *p = s;
                while (*p) {
                    const char *comma = strchr(p, ',');
                    size_t tlen = comma ? (size_t)(comma - p) : strlen(p);
                    uint64_t f = 0;
                    if (parse_u64_strict(p, tlen, &f) && f > 0) capture_frames.push_back(f);
                    if (!comma) break;
                    p = comma + 1;
                }
            }
            if (const char *s = getenv("BO3ARM_SCRIPT_KEYS")) {
                // Format: "1520:RETURN,1700:DOWN,1740:RETURN" (each press held for 4 frames)
                const char *p = s;
                while (*p) {
                    const char *comma = strchr(p, ',');
                    size_t tok_len = comma ? (size_t)(comma - p) : strlen(p);
                    const char *colon = (const char *)memchr(p, ':', tok_len);
                    uint64_t f = 0;
                    if (colon && parse_u64_strict(p, (size_t)(colon - p), &f) && f > 0 && f <= UINT64_MAX - 4) {
                        const char *k = colon + 1;
                        size_t klen = tok_len - (size_t)(k - p);
                        uint16_t vk = 0; uint8_t sc = 0;
                        if (klen == 6 && strncmp(k, "RETURN", 6) == 0)      { vk = 0x0D; sc = 0x1C; }
                        else if (klen == 5 && strncmp(k, "ENTER", 5) == 0)  { vk = 0x0D; sc = 0x1C; }
                        else if (klen == 5 && strncmp(k, "SPACE", 5) == 0)  { vk = 0x20; sc = 0x39; }
                        else if (klen == 3 && strncmp(k, "ESC", 3) == 0)    { vk = 0x1B; sc = 0x01; }
                        else if (klen == 2 && strncmp(k, "UP", 2) == 0)     { vk = 0x26; sc = 0x48; }
                        else if (klen == 4 && strncmp(k, "DOWN", 4) == 0)   { vk = 0x28; sc = 0x50; }
                        else if (klen == 4 && strncmp(k, "LEFT", 4) == 0)   { vk = 0x25; sc = 0x4B; }
                        else if (klen == 5 && strncmp(k, "RIGHT", 5) == 0)  { vk = 0x27; sc = 0x4D; }
                        else if (klen == 3 && strncmp(k, "TAB", 3) == 0)    { vk = 0x09; sc = 0x0F; }
                        else if (klen == 3 && strncmp(k, "LMB", 3) == 0)    { vk = 0x01; sc = 0x00; }
                        else if (klen == 1 && k[0] >= 'A' && k[0] <= 'Z')   { vk = (uint16_t)k[0]; sc = 0x1E; }
                        if (vk != 0) {
                            script_keys.push_back({f, vk, sc, true});
                            script_keys.push_back({f + 4, vk, sc, false});
                        }
                    }
                    if (!comma) break;
                    p = comma + 1;
                }
            }
        });

        Bo3MetalContext *ictx = nullptr;
        if (sc->device) {
            os_unfair_lock_lock(&sc->device->ctx_lock);
            ictx = sc->device->immediate_ctx;
            os_unfair_lock_unlock(&sc->device->ctx_lock);
        }
        if (!ictx) return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);
        hr = bo3_context_present_flush(ictx, sc, sync_interval, flags);
        if (hr != BO3_S_OK) {
            return ret_u64(hr);
        }
        const uint64_t cur_frame = sc->frame_index.fetch_add(1, std::memory_order_acq_rel) + 1;
        // Enable GPU/TBDR telemetry ONLY when --perf or Detailed HUD is active (zero overhead otherwise!)
        const bool perf_cli = bo3_perf_enabled();
        const uint32_t hud_mode = bo3_settings_hud_mode();
        bo3_context_set_perf_active(ictx, perf_cli || hud_mode == 2);
        if (perf_cli) bo3_context_perf_on_present(ictx, cur_frame);
        bo3_shader_cache_on_present();

        for (const auto &ev : script_keys) {
            if (cur_frame == ev.frame) {
                bo3_win_inject_key(ev.vk, ev.sc, ev.down);
                fprintf(stderr, "[script-key] frame=%llu vk=0x%02x %s\n",
                        (unsigned long long)cur_frame, ev.vk, ev.down ? "DOWN" : "UP");
                fflush(stderr);
            }
        }

        id<MTLTexture> cap_bb = nil;
        std::string cap_out_path;
        if (capture_frame > 0 && cur_frame == capture_frame) {
            cap_bb = sc->bb_state ? sc->bb_state->peek() : nil;
            cap_out_path = capture_path;
        } else if (!capture_frames.empty()) {
            for (uint64_t cf : capture_frames) {
                if (cur_frame == cf) {
                    cap_bb = sc->bb_state ? sc->bb_state->peek() : nil;
                    cap_out_path = std::string(capture_path) + "_f" + std::to_string(cf) + ".png";
                    break;
                }
            }
        }
        if (cap_bb) {
            save_mtl_texture_png(cap_bb, sc->device->mtl_queue, cap_out_path.c_str());
        }

        uint64_t now = 0;
        const bool do_not_wait = (flags & BO3_DXGI_PRESENT_DO_NOT_WAIT) != 0;
        if (!do_not_wait) {
            if (hud_mode > 0) {
                now = monotonic_ns();
                bool emit_hud = false;
                double hud_fps = 0.0;
                uint32_t hud_rw = 0, hud_rh = 0, hud_dw = 0, hud_dh = 0;
                os_unfair_lock_lock(&sc->present_lock);
                if (sc->last_hud_ns == 0) {
                    sc->last_hud_ns = now;
                    sc->last_hud_frames = 0;
                } else {
                    sc->last_hud_frames++;
                    if (now >= sc->last_hud_ns && (now - sc->last_hud_ns) >= 500000000ULL) {
                        double dt = (double)(now - sc->last_hud_ns) / 1e9;
                        hud_fps = (dt > 0.001) ? ((double)sc->last_hud_frames / dt) : 0.0;
                        hud_rw = sc->desc.BufferDesc.Width;
                        hud_rh = sc->desc.BufferDesc.Height;
                        hud_dw = sc->native_w;
                        hud_dh = sc->native_h;
                        sc->last_hud_ns = now;
                        sc->last_hud_frames = 0;
                        emit_hud = true;
                    }
                }
                os_unfair_lock_unlock(&sc->present_lock);
                if (emit_hud) {
                    Bo3PerfSnapshot snap = {};
                    if (hud_mode == 2) {
                        if (perf_cli) bo3_context_perf_last(ictx, &snap);
                        else          bo3_context_perf_sample_hud(ictx, &snap);
                    }
                    bo3_ui_update_hud_stats(hud_fps, snap.gpu_ms, snap.cpu_encode_ms,
                                            hud_rw, hud_rh, hud_dw, hud_dh,
                                            sc->last_metalfx_active.load(std::memory_order_acquire),
                                            bo3_settings_lossy_rt_enabled(),
                                            snap.tbdr_load_mb, snap.tbdr_store_mb);
                }
            } else {
                os_unfair_lock_lock(&sc->present_lock);
                sc->last_hud_ns = 0;
                sc->last_hud_frames = 0;
                os_unfair_lock_unlock(&sc->present_lock);
            }
        }

        // Release mode: zero periodic stderr logging unless --perf (BO3ARM_PERF_STATS=1) or BO3ARM_VERBOSE=1
        static const bool verbose_present = (getenv("BO3ARM_VERBOSE") != nullptr &&
                                             strcmp(getenv("BO3ARM_VERBOSE"), "0") != 0);
        if (perf_cli || verbose_present) {
            sc->last_fps_frames++;
            if (!now) now = monotonic_ns();
            if (cur_frame <= 5 || (now - sc->last_fps_ns) >= 2000000000ULL) {
                double dt = (double)(now - sc->last_fps_ns) / 1e9;
                double fps = (dt > 0.001) ? ((double)sc->last_fps_frames / dt) : 0.0;
                fprintf(stderr, "[metal-present] frame=%llu fps=%.1f (%ux%u sync=%u)\n",
                        (unsigned long long)cur_frame, fps,
                        sc->desc.BufferDesc.Width, sc->desc.BufferDesc.Height, sync_interval);
                fflush(stderr);
                sc->last_fps_ns = now;
                sc->last_fps_frames = 0;
            }
        }

        if (exit_after > 0 && cur_frame >= exit_after) {
            fprintf(stderr, "[metal-present] Reached BO3ARM_EXIT_AFTER_FRAMES=%llu -> clean exit(0)\n",
                    (unsigned long long)exit_after);
            fflush(stderr);
            bo3_win_restore_desktop_sync();
            exit(0);
        }
    }
    return ret_u64(hr);
}

// slot 9 (+0x48): IDXGISwapChain::GetBuffer(Buffer, riid, ppSurface)
static SHIM_DEF(dxgi_swapchain_get_buffer) {
    SHIM_UNUSED_ALL();
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)rdi;
    void **pp_surf = (void **)rcx;
    if (!pp_surf || !sc->backbuffer_tex) return ret_u64(BO3_E_POINTER);
    sc->backbuffer_tex->res.com.add_ref();
    *pp_surf = sc->backbuffer_tex;
    return ret_u64(BO3_S_OK);
}

// slot 10 (+0x50): SetFullscreenState(Fullscreen, pTarget)
static SHIM_DEF(dxgi_swapchain_set_fullscreen) {
    SHIM_UNUSED_ALL();
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)rdi;
    bool fs = ((uint32_t)rsi != 0);
    os_unfair_lock_lock(&sc->present_lock);
    const bool changed = (sc->fullscreen != fs);
    sc->fullscreen = fs;
    sc->desc.Windowed = fs ? 0 : 1;
    if (changed) sc->has_pending_target = false;
    // bo3_win_set_fullscreen only updates logical bounds under g_win_mtx and dispatches async to
    // main queue, so keeping it inside present_lock keeps fullscreen state and client bounds atomic.
    bo3_win_set_fullscreen(sc->desc.OutputWindow, fs);
    os_unfair_lock_unlock(&sc->present_lock);
    fprintf(stderr, "[metal-dxgi] SetFullscreenState(%d)\n", fs ? 1 : 0);
    fflush(stderr);
    return ret_u64(BO3_S_OK);
}

// slot 11 (+0x58): GetFullscreenState(pFullscreen, ppTarget)
static SHIM_DEF(dxgi_swapchain_get_fullscreen) {
    SHIM_UNUSED_ALL();
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)rdi;
    if (rsi) *(int32_t *)rsi = sc->fullscreen ? 1 : 0;
    if (rdx) *(void **)rdx = sc->fullscreen ? bo3_dxgi_get_default_output() : nullptr;
    return ret_u64(BO3_S_OK);
}

// slot 12 (+0x60): GetDesc(pDesc)
static SHIM_DEF(dxgi_swapchain_get_desc) {
    SHIM_UNUSED_ALL();
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)rdi;
    if (!rsi) return ret_u64(BO3_E_INVALIDARG);
    memcpy((void *)rsi, &sc->desc, sizeof(sc->desc));
    return ret_u64(BO3_S_OK);
}

// slot 13 (+0x68): ResizeBuffers(BufferCount, Width, Height, NewFormat, Flags)
static SHIM_DEF(dxgi_swapchain_resize_buffers) {
    SHIM_UNUSED_ALL();
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)rdi;
    const uint32_t raw_w = (uint32_t)rdx;
    const uint32_t raw_h = (uint32_t)rcx;
    uint32_t fmt = (uint32_t)r8;

    os_unfair_lock_lock(&sc->present_lock);
    bo3_context_flush_now(sc->device->immediate_ctx, true);

    int32_t client_w = 0, client_h = 0;
    const bool have_client = bo3_win_get_native_client_size(sc->desc.OutputWindow, &client_w, &client_h);

    uint32_t w = raw_w;
    uint32_t h = raw_h;
    if (w == 0 || h == 0) {
        if (sc->fullscreen && sc->has_pending_target) {
            if (w == 0) w = sc->target_w;
            if (h == 0) h = sc->target_h;
        }
        if (w == 0 || h == 0) {
            if (sc->fullscreen) {
                int32_t sw = 0, sh = 0;
                bo3_win_get_screen_size(&sw, &sh);
                if (w == 0 && sw > 0) w = (uint32_t)sw;
                if (h == 0 && sh > 0) h = (uint32_t)sh;
            } else if (have_client) {
                if (w == 0 && client_w > 0) w = (uint32_t)client_w;
                if (h == 0 && client_h > 0) h = (uint32_t)client_h;
            }
            if (w == 0) w = sc->desc.BufferDesc.Width;
            if (h == 0) h = sc->desc.BufferDesc.Height;
        }
    }

    if (w > 0) sc->desc.BufferDesc.Width = w;
    if (h > 0) sc->desc.BufferDesc.Height = h;
    sc->target_w = sc->desc.BufferDesc.Width;
    sc->target_h = sc->desc.BufferDesc.Height;
    sc->has_pending_target = false;
    bo3_dxgi_compute_drawable_size(sc->desc.OutputWindow, sc->desc.BufferDesc.Width, sc->desc.BufferDesc.Height,
                                   sc->render_scale, sc->fullscreen, &sc->native_w, &sc->native_h);
    if (fmt > 0) sc->desc.BufferDesc.Format = fmt;
    const uint32_t nw = sc->desc.BufferDesc.Width;
    const uint32_t nh = sc->desc.BufferDesc.Height;
    const uint32_t dw = sc->native_w, dh = sc->native_h;
    if (sc->bb_state) sc->bb_state->resize(nw, nh, sc->desc.BufferDesc.Format);
    if (sc->backbuffer_tex) {
        os_unfair_lock_lock(&sc->backbuffer_tex->view_lock);
        sc->backbuffer_tex->view_cache.clear();
        sc->backbuffer_tex->desc2d.Width = nw;
        sc->backbuffer_tex->desc2d.Height = nh;
        sc->backbuffer_tex->desc2d.Format = sc->desc.BufferDesc.Format;
        sc->backbuffer_tex->dxgi_format = sc->desc.BufferDesc.Format;
        Bo3FormatInfo fi = bo3_dxgi_to_metal_format(sc->desc.BufferDesc.Format, false, false);
        sc->backbuffer_tex->mtl_format = (fi.pixel_format != MTLPixelFormatInvalid) ? fi.pixel_format : MTLPixelFormatRGBA8Unorm;
        sc->backbuffer_tex->mtl_tex = nil;
        os_unfair_lock_unlock(&sc->backbuffer_tex->view_lock);
    }
    bo3_win_update_swapchain_sizes(sc->desc.OutputWindow, sc, (int32_t)nw, (int32_t)nh, (int32_t)dw, (int32_t)dh);
    CAMetalLayer *layer = sc->layer;
    const uint64_t hwnd = sc->desc.OutputWindow;
    const uint32_t log_fmt = sc->desc.BufferDesc.Format;
    // Release present_lock BEFORE dispatch_sync(main_queue) so a main-thread Present/ResizeBuffers
    // can never deadlock waiting on present_lock while we wait for the main queue.
    os_unfair_lock_unlock(&sc->present_lock);
    if (layer) {
        auto upd = ^{
            int32_t ldw = (int32_t)dw, ldh = (int32_t)dh;
            bo3_win_get_drawable_size(hwnd, &ldw, &ldh);
            bo3_win_lock_layer(hwnd);
            layer.drawableSize = CGSizeMake(ldw, ldh);
            bo3_win_unlock_layer(hwnd);
        };
        if ([NSThread isMainThread]) upd();
        else dispatch_sync(dispatch_get_main_queue(), upd);
    }
    fprintf(stderr, "[metal-dxgi] ResizeBuffers %ux%u fmt=%u (drawable %ux%u)\n",
            nw, nh, log_fmt, dw, dh);
    fflush(stderr);
    return ret_u64(BO3_S_OK);
}

// slot 14 (+0x70): ResizeTarget(pNewTargetParameters)
static SHIM_DEF(dxgi_swapchain_resize_target) {
    SHIM_UNUSED_ALL();
    Bo3MetalSwapChain *sc = (Bo3MetalSwapChain *)rdi;
    const Bo3DXGI_MODE_DESC *md = (const Bo3DXGI_MODE_DESC *)rsi;
    if (md && md->Width >= 320 && md->Height >= 240) {
        bool fs = false;
        os_unfair_lock_lock(&sc->present_lock);
        // Record pending target mode only; GetDesc / backbuffer / input mapping update on ResizeBuffers.
        sc->target_w = md->Width;
        sc->target_h = md->Height;
        sc->has_pending_target = true;
        fs = sc->fullscreen;
        os_unfair_lock_unlock(&sc->present_lock);
        if (!fs) {
            bo3_win_move(sc->desc.OutputWindow, 100, 100, (int32_t)md->Width, (int32_t)md->Height);
        }
    }
    return ret_u64(BO3_S_OK);
}

// slot 15 (+0x78): GetContainingOutput(ppOutput)
static SHIM_DEF(dxgi_swapchain_get_containing_output) {
    SHIM_UNUSED_ALL();
    void **pp_out = (void **)rsi;
    if (!pp_out) return ret_u64(BO3_E_INVALIDARG);
    *pp_out = bo3_dxgi_get_default_output();
    return ret_u64(BO3_S_OK);
}

// =========================================================================
// Public DXGI Init & CreateDXGIFactory1 (0x1000de240)
// =========================================================================

void bo3_dxgi_init_vtables() {
    bo3_com_init_vtable(g_vt_dxgi_factory, 16, "IDXGIFactory1");
    bo3_com_set_slot(g_vt_dxgi_factory, 7,  dxgi_factory_enum_adapters1);
    bo3_com_set_slot(g_vt_dxgi_factory, 8,  dxgi_factory_make_window_assoc);
    bo3_com_set_slot(g_vt_dxgi_factory, 9,  dxgi_factory_get_window_assoc);
    bo3_com_set_slot(g_vt_dxgi_factory, 10, dxgi_factory_create_swapchain);
    bo3_com_set_slot(g_vt_dxgi_factory, 12, dxgi_factory_enum_adapters1);
    bo3_com_set_slot(g_vt_dxgi_factory, 13, dxgi_factory_is_current);

    bo3_com_init_vtable(g_vt_dxgi_adapter, 16, "IDXGIAdapter1");
    bo3_com_set_slot(g_vt_dxgi_adapter, 6,  dxgi_adapter_get_parent);
    bo3_com_set_slot(g_vt_dxgi_adapter, 7,  dxgi_adapter_enum_outputs);
    bo3_com_set_slot(g_vt_dxgi_adapter, 8,  dxgi_adapter_get_desc);
    bo3_com_set_slot(g_vt_dxgi_adapter, 10, dxgi_adapter_get_desc1);

    bo3_com_init_vtable(g_vt_dxgi_output, 20, "IDXGIOutput");
    bo3_com_set_slot(g_vt_dxgi_output, 7, dxgi_output_get_desc);
    bo3_com_set_slot(g_vt_dxgi_output, 8, dxgi_output_get_display_mode_list);
    bo3_com_set_slot(g_vt_dxgi_output, 9, dxgi_output_find_closest_mode);

    bo3_com_init_vtable(g_vt_dxgi_device, 20, "IDXGIDevice2");
    bo3_com_set_slot(g_vt_dxgi_device, 6,  dxgi_device_get_parent);
    bo3_com_set_slot(g_vt_dxgi_device, 7,  dxgi_device_get_adapter);
    bo3_com_set_slot(g_vt_dxgi_device, 12, dxgi_device_set_max_latency);
    bo3_com_set_slot(g_vt_dxgi_device, 13, dxgi_device_get_max_latency);

    bo3_com_init_vtable(g_vt_dxgi_swapchain, 20, "IDXGISwapChain");
    bo3_com_set_slot(g_vt_dxgi_swapchain, 6,  dxgi_swapchain_get_parent);
    bo3_com_set_slot(g_vt_dxgi_swapchain, 7,  dxgi_swapchain_get_device);
    bo3_com_set_slot(g_vt_dxgi_swapchain, 8,  dxgi_swapchain_present);
    bo3_com_set_slot(g_vt_dxgi_swapchain, 9,  dxgi_swapchain_get_buffer);
    bo3_com_set_slot(g_vt_dxgi_swapchain, 10, dxgi_swapchain_set_fullscreen);
    bo3_com_set_slot(g_vt_dxgi_swapchain, 11, dxgi_swapchain_get_fullscreen);
    bo3_com_set_slot(g_vt_dxgi_swapchain, 12, dxgi_swapchain_get_desc);
    bo3_com_set_slot(g_vt_dxgi_swapchain, 13, dxgi_swapchain_resize_buffers);
    bo3_com_set_slot(g_vt_dxgi_swapchain, 14, dxgi_swapchain_resize_target);
    bo3_com_set_slot(g_vt_dxgi_swapchain, 15, dxgi_swapchain_get_containing_output);
}

// 0x1000de240: CreateDXGIFactory1(riid, ppFactory)
extern "C" SHIM_DEF(g_1000de240) {
    SHIM_UNUSED_ALL();
    void **pp = (void **)rsi;
    if (!pp) return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);
    *pp = create_dxgi_factory();
    fprintf(stderr, "[metal-dxgi] CreateDXGIFactory1 -> %p\n", *pp);
    fflush(stderr);
    return ret_u64(BO3_S_OK);
}

#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "com_thunks.h"
#include "binding_map.h"
#include "formats.h"
#include <os/lock.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

struct Bo3MetalDevice;
struct Bo3MetalContext;
struct Bo3MetalSwapChain;

// Additional D3D11 / DXGI constants & IIDs (com_thunks.h/d3d11_abi.h kept untouched)
#define BO3_DXGI_ERROR_WAS_STILL_DRAWING 0x887A000Au
#define BO3_D3D11_MAP_FLAG_DO_NOT_WAIT   0x00100000u
#define BO3_D3D11_DSV_READ_ONLY_DEPTH    0x1u
#define BO3_D3D11_DSV_READ_ONLY_STENCIL  0x2u
#define BO3_DXGI_PRESENT_DO_NOT_WAIT     0x8u

extern const Bo3GUID BO3_IID_ID3D11Texture1D;
extern const Bo3GUID BO3_IID_ID3D11DeviceChild;
extern const Bo3GUID BO3_IID_ID3D11View;
extern const Bo3GUID BO3_IID_ID3D11ShaderResourceView;
extern const Bo3GUID BO3_IID_ID3D11RenderTargetView;
extern const Bo3GUID BO3_IID_ID3D11DepthStencilView;
extern const Bo3GUID BO3_IID_ID3D11UnorderedAccessView;
extern const Bo3GUID BO3_IID_ID3D11VertexShader;
extern const Bo3GUID BO3_IID_ID3D11GeometryShader;
extern const Bo3GUID BO3_IID_ID3D11PixelShader;
extern const Bo3GUID BO3_IID_ID3D11ComputeShader;
extern const Bo3GUID BO3_IID_ID3D11InputLayout;
extern const Bo3GUID BO3_IID_ID3D11BlendState;
extern const Bo3GUID BO3_IID_ID3D11DepthStencilState;
extern const Bo3GUID BO3_IID_ID3D11RasterizerState;
extern const Bo3GUID BO3_IID_ID3D11SamplerState;
extern const Bo3GUID BO3_IID_ID3D11Asynchronous;
extern const Bo3GUID BO3_IID_ID3D11Query;
extern const Bo3GUID BO3_IID_ID3D11Predicate;

// =========================================================================
// Resource & View COM Objects (offset 0 MUST remain Bo3ComBase::vtable!)
// =========================================================================

struct Bo3MetalResource {
    Bo3ComBase      com;
    uint32_t        dimension; // BO3_D3D11_RESOURCE_DIMENSION_*
    Bo3MetalDevice *device;
    // Highest context fence of any encoded GPU access (copy/bind/draw) touching this resource.
    // CPU Map() only waits when this fence has not completed yet (no whole-GPU stalls!).
    // Includes uploads hoisted into the context's per-frame upload command buffer.
    std::atomic<uint64_t> last_gpu_fence{0};
    // Highest context fence of any access encoded into the MAIN command buffer (cmd_buf). An
    // upload may be hoisted ahead of the open render pass (into upload_cmd_buf, committed first)
    // only while this is below the pending fence, i.e. nothing in cmd_buf references the resource.
    std::atomic<uint64_t> last_cmd_fence{0};
};

// Swap-chain backbuffer backing state shared (via shared_ptr) between the swap chain and its
// backbuffer proxy texture, so the proxy never dereferences a destroyed Bo3MetalSwapChain.
struct Bo3SwapChainState {
    os_unfair_lock  lock = OS_UNFAIR_LOCK_INIT;
    id<MTLDevice>   mtl_dev = nil;
    id<MTLTexture>  current_tex = nil; // offscreen backbuffer (lazily created)
    uint32_t        width = 0;
    uint32_t        height = 0;
    uint32_t        format = 0;        // DXGI_FORMAT
    bool            alive = true;

    id<MTLTexture> acquire();          // nil once !alive
    id<MTLTexture> peek();             // current texture without creating one
    void           resize(uint32_t w, uint32_t h, uint32_t fmt);
    void           kill();
};

struct Bo3MetalBuffer {
    Bo3MetalResource res;
    Bo3D3D11_BUFFER_DESC desc;
    id<MTLBuffer>    mtl_buf;
    uint64_t         mtl_len;    // cached mtl_buf.length (no per-draw ObjC message send)
    // Dynamic WRITE_DISCARD ring allocation state
    id<MTLBuffer>    dyn_buf;
    uint64_t         dyn_len;    // cached dyn_buf.length (valid while dyn_buf != nil)
    uint64_t         dyn_offset;
    uint64_t         dyn_stride; // aligned allocation size per write
    uint64_t         dyn_epoch;  // upload_ring epoch when allocated from ring (0 = owned/dedicated)
    void            *mapped_ptr;
    bool             is_dynamic;
    bool             is_staging;

    id<MTLBuffer> cur_buf() const { return dyn_buf ? dyn_buf : mtl_buf; }
    uint64_t      cur_base() const { return dyn_buf ? dyn_offset : 0; }
    uint64_t      cur_len() const { return dyn_buf ? dyn_len : mtl_len; }
    void set_dyn(id<MTLBuffer> b, uint64_t off, uint64_t len) { dyn_buf = b; dyn_offset = off; dyn_len = b ? len : 0; }
    void clear_dyn() { dyn_buf = nil; dyn_offset = 0; dyn_len = 0; dyn_epoch = 0; }
};

struct Bo3TexViewKey {
    MTLPixelFormat fmt;
    MTLTextureType type;
    uint16_t       mip_start;
    uint16_t       mip_len;
    uint16_t       slice_start;
    uint16_t       slice_len;
    uint32_t       swizzle; // packed MTLTextureSwizzleChannels (0x05040302 = identity)
    bool operator==(const Bo3TexViewKey &o) const {
        return fmt == o.fmt && type == o.type && mip_start == o.mip_start &&
               mip_len == o.mip_len && slice_start == o.slice_start && slice_len == o.slice_len &&
               swizzle == o.swizzle;
    }
};

struct Bo3TexViewKeyHash {
    size_t operator()(const Bo3TexViewKey &k) const {
        uint64_t h = (uint64_t)k.fmt | ((uint64_t)k.type << 16) |
                     ((uint64_t)k.mip_start << 24) | ((uint64_t)k.mip_len << 36) |
                     ((uint64_t)k.slice_start << 44) | ((uint64_t)k.slice_len << 54);
        h ^= (uint64_t)k.swizzle * 0x9E3779B97F4A7C15ULL;
        return std::hash<uint64_t>{}(h);
    }
};

struct Bo3MappedSubres {
    std::vector<uint8_t> data;
    uint32_t             map_type = 0;
    uint32_t             row_pitch = 0;
    uint32_t             slice_pitch = 0;
    uint32_t             w = 1, h = 1, d = 1;
};

// A1b: deferred (not yet encoded) ClearRenderTargetView / ClearDepthStencilView of ONE texture
// subresource. Folded into the next render pass that attaches that subresource
// (MTLLoadActionClear), or materialized as a minimal clear pass right before anything else
// reads/partially writes it. Protected by the immediate context lock.
struct Bo3TexPendingClear {
    uint32_t       mip;
    uint32_t       slice;     // D3D array slice / cube face, or W (depth) plane of a 3D texture
    uint8_t        aspects;   // 1 = color or depth, 2 = stencil
    bool           is_color;
    MTLPixelFormat fmt;       // color: RTV view format the clear value is encoded with
    float          color[4];
    float          depth;
    uint8_t        stencil;
};

struct Bo3MetalTexture {
    Bo3MetalResource res;
    Bo3D3D11_TEXTURE1D_DESC desc1d;
    Bo3D3D11_TEXTURE2D_DESC desc2d;
    Bo3D3D11_TEXTURE3D_DESC desc3d;
    uint32_t         dxgi_format;
    MTLPixelFormat   mtl_format;
    MTLTextureType   mtl_type;
    bool             is_backbuffer;
    std::shared_ptr<Bo3SwapChainState> sc_state; // non-null iff is_backbuffer
    id<MTLTexture>   mtl_tex;
    // Per-subresource CPU staging buffers for Map/Unmap (supports 1D/2D/3D and concurrent subres maps)
    std::unordered_map<uint32_t, Bo3MappedSubres> mapped_subres;
    // View adapter cache (fixes depth/color, 2D/2DArray, typeless/sRGB mismatches)
    os_unfair_lock   view_lock;
    std::unordered_map<Bo3TexViewKey, id<MTLTexture>, Bo3TexViewKeyHash> view_cache;
    // A1b deferred clears (context lock). While non-empty the context holds one COM ref on the
    // texture (listed in Bo3MetalContext::pending_clear_texs), so it can never be destroyed with
    // an unmaterialized clear.
    std::vector<Bo3TexPendingClear> pending_clears;
    bool             in_clear_list = false;

    id<MTLTexture> current_mtl_texture();
    id<MTLTexture> get_or_create_view(MTLPixelFormat fmt, MTLTextureType type,
                                      uint32_t mip_start, uint32_t mip_len,
                                      uint32_t slice_start, uint32_t slice_len,
                                      uint32_t swizzle = 0x05040302u);
    uint32_t d3d_mip_levels() const; // D3D11 MipLevels used for subresource index decoding
};

static constexpr uint32_t BO3_SWIZZLE_IDENTITY = 0x05040302u; // R,G,B,A
static inline uint32_t bo3_pack_swizzle(MTLTextureSwizzle r, MTLTextureSwizzle g,
                                        MTLTextureSwizzle b, MTLTextureSwizzle a) {
    return (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)b << 16) | ((uint32_t)a << 24);
}

struct Bo3MetalSRV {
    Bo3ComBase       com;
    Bo3MetalDevice  *device;   // internal ref
    Bo3MetalResource *resource; // addref'd
    Bo3D3D11_SHADER_RESOURCE_VIEW_DESC desc;
    id<MTLTexture>   mtl_tex;   // cached default view (or nil if buffer SRV)
    id<MTLBuffer>    mtl_buf;   // non-nil if buffer SRV
    uint64_t         buf_offset;
    uint64_t         buf_size;
    uint32_t         buf_num_elements;
    uint32_t         buf_stride;
    bool             is_buffer;
    // Subresource range (textures) for D3D11 hazard tracking
    uint32_t         mip0, mip_cnt, slice0, slice_cnt;
    uint8_t          aspect; // bit0 = depth/color, bit1 = stencil
};

struct Bo3MetalRTV {
    Bo3ComBase       com;
    Bo3MetalDevice  *device;   // internal ref
    Bo3MetalResource *resource; // addref'd
    Bo3D3D11_RENDER_TARGET_VIEW_DESC desc;
    MTLPixelFormat   mtl_format;
    uint32_t         mip_slice;
    uint32_t         array_slice;
    uint32_t         array_size;
};

struct Bo3MetalDSV {
    Bo3ComBase       com;
    Bo3MetalDevice  *device;   // internal ref
    Bo3MetalResource *resource; // addref'd
    Bo3D3D11_DEPTH_STENCIL_VIEW_DESC desc;
    MTLPixelFormat   mtl_format;
    bool             has_stencil;
    uint32_t         mip_slice;
    uint32_t         array_slice;
    uint32_t         array_size;
};

struct Bo3MetalUAV {
    Bo3ComBase       com;
    Bo3MetalDevice  *device;   // internal ref
    Bo3MetalResource *resource; // addref'd
    Bo3D3D11_UNORDERED_ACCESS_VIEW_DESC desc;
    id<MTLTexture>   mtl_tex;
    id<MTLBuffer>    mtl_buf;
    id<MTLBuffer>    counter_buf;
    uint64_t         buf_offset;
    uint64_t         buf_size;
    uint32_t         buf_num_elements;
    uint32_t         buf_stride;
    uint32_t         elem_size;   // bytes per element for typed buffer UAVs (1/2/4/8/16)
    bool             is_buffer;
    bool             is_raw;
    // Subresource range (textures) for D3D11 hazard tracking
    uint32_t         mip0, slice0, slice_cnt;
};

// =========================================================================
// Shaders & State Objects
// =========================================================================

enum Bo3ShaderStage {
    BO3_STAGE_VS = 0,
    BO3_STAGE_PS = 1,
    BO3_STAGE_CS = 2,
    BO3_STAGE_GS = 3,
};

// Lazily compiled secondary shader variant (stable unique_id, never mutates the primary!)
struct Bo3ShaderVariant {
    id<MTLFunction> mtl_fn = nil;
    Bo3BindingMap  bindings;
    uint64_t       unique_id = 0;
    uint32_t       vs_input_mask = 0;          // active [[attribute(N)]] bitmask (VS only)
    MTLVertexFormat vs_input_fmt[31] = {};     // matching vertex format per active attribute
    bool           valid = false;
    bool           attempted = false;
};

struct Bo3MetalShader {
    Bo3ComBase     com;
    Bo3MetalDevice *device; // internal ref
    uint64_t       unique_id;
    Bo3ShaderStage stage;
    std::string    name;
    uint32_t       hash;
    id<MTLFunction> mtl_fn;
    id<MTLComputePipelineState> cs_pso; // lazily built for CS
    id<MTLBuffer>  icb_mtl_buf;         // extracted DCL_IMMEDIATE_CONSTANT_BUFFER
    Bo3BindingMap  bindings;
    std::vector<uint8_t> dxbc_bytes;    // retained raw DXBC for lazy compile & PSO fallback
    std::string    pending_generic_name; // non-empty when matched in Generic.metallib (lazy reflect on first use)
    std::mutex     compile_mtx;
    std::atomic<bool> compiled{false};
    bool           from_generic_metallib = false;
    bool           valid = false;
    // Cached VS input reflection (queried once at compile time, never per draw)
    uint32_t       vs_input_mask = 0;
    MTLVertexFormat vs_input_fmt[31] = {};
    // PSO-fallback variants: [0] = plain DXBC->MSL translation (Generic.metallib partner mismatch),
    //                        [1] = DXBC->MSL with force_float4_varyings
    Bo3ShaderVariant fallback_var[2];
};

struct Bo3InputElemResolved {
    char            semantic[32];
    uint32_t        semantic_index;
    uint32_t        dxgi_format;
    MTLVertexFormat mtl_format;
    uint32_t        input_slot;
    uint32_t        byte_offset;
    uint32_t        input_slot_class; // 0=per-vertex, 1=per-instance
    uint32_t        step_rate;
    int32_t         attr_index;       // resolved [[attribute(N)]] from VS ISGN (-1 if unmatched)
};

struct Bo3MetalInputLayout {
    Bo3ComBase com;
    Bo3MetalDevice *device;
    uint64_t   unique_id;
    std::vector<Bo3InputElemResolved> elements;
    uint64_t   layout_hash;
};

struct Bo3MetalBlendState {
    Bo3ComBase com;
    Bo3MetalDevice *device;
    Bo3D3D11_BLEND_DESC desc;
    uint64_t   state_hash;
};

struct Bo3MetalDepthStencilState {
    Bo3ComBase com;
    Bo3MetalDevice *device;
    Bo3D3D11_DEPTH_STENCIL_DESC desc;
    id<MTLDepthStencilState> mtl_dss;
    id<MTLDepthStencilState> mtl_dss_ro_depth;
    id<MTLDepthStencilState> mtl_dss_ro_stencil;
    id<MTLDepthStencilState> mtl_dss_ro_both;
    id<MTLDepthStencilState> mtl_dss_nodepth; // fallback when no DSV bound
    // Stencil-less twins for depth-only DSVs (Depth32Float / Depth16Unorm have no stencil attachment)
    id<MTLDepthStencilState> mtl_dss_nostencil;
    id<MTLDepthStencilState> mtl_dss_nostencil_ro_depth;
};

struct Bo3MetalRasterizerState {
    Bo3ComBase com;
    Bo3MetalDevice *device;
    Bo3D3D11_RASTERIZER_DESC desc;
};

struct Bo3MetalSamplerState {
    Bo3ComBase com;
    Bo3MetalDevice *device;
    Bo3D3D11_SAMPLER_DESC desc;
    id<MTLSamplerState> mtl_smp;
    id<MTLSamplerState> mtl_smp_cube; // clamp-to-edge twin for sNcube
};

struct Bo3MetalQuery {
    Bo3ComBase com;
    Bo3MetalDevice *device;
    Bo3D3D11_QUERY_DESC desc;
    std::atomic<uint64_t> target_fence{0};
    std::atomic<uint64_t> timestamp_ns{0};
    std::atomic<uint64_t> occlusion_val{1};
    std::atomic<bool>     ended{false};
};

// =========================================================================
// Quad-Buffered Dynamic Upload Ring (fence-tracked -> zero GPU/CPU race!)
// =========================================================================

struct Bo3UploadRing {
    static constexpr int FRAMES = 4;
    static constexpr size_t CHUNK_SIZE = 32 * 1024 * 1024; // 32 MiB per frame slot
    id<MTLBuffer> buffers[FRAMES];
    uint8_t      *ptrs[FRAMES];
    size_t        offsets[FRAMES];
    uint64_t      slot_epochs[FRAMES];
    uint64_t      slot_fence[FRAMES];
    std::vector<Bo3MetalBuffer *> slot_users[FRAMES]; // add_ref'd dynamic buffers for cross-frame preservation
    int           cur_frame = 0;
    uint64_t      epoch = 1;

    void init(id<MTLDevice> dev);
    bool alloc(size_t bytes, size_t align, uint64_t pending_fence,
               id<MTLBuffer> *out_buf, uint64_t *out_off, void **out_ptr);
    void track_dynamic_user(Bo3MetalBuffer *b);
    void mark_buffer_used(Bo3MetalBuffer *b, uint64_t pending_fence);
    // `wait_gpu_idle` is invoked (OOM path only) to block until every committed command buffer
    // has completed, so GPU-live ring memory is NEVER reused or clobbered.
    void advance_frame(id<MTLDevice> dev, uint64_t completed_fence, void (^wait_gpu_idle)(void));
    void release_all();
};

// =========================================================================
// Main Device, Context & SwapChain Objects
// =========================================================================

struct Bo3MetalDevice {
    Bo3ComBase      com;
    std::atomic<int32_t> internal_refs{1};
    id<MTLDevice>   mtl_dev;
    id<MTLCommandQueue> mtl_queue;
    id<MTLBuffer>   zero_buffer;      // 64 KiB read-only zero fallback (CB/SRV/VB/ICB)
    id<MTLBuffer>   dummy_uav_buf;    // 64 KiB writable scratch fallback for unbound UAV/counter slots
    // SRV dummy textures indexed by Bo3TexNumericType [0=float, 1=uint, 2=sint]
    id<MTLTexture>  dummy_tex_1d[3];
    id<MTLTexture>  dummy_tex_1d_arr[3];
    id<MTLTexture>  dummy_tex_2d[3];
    id<MTLTexture>  dummy_tex_2d_arr[3];
    id<MTLTexture>  dummy_tex_2d_ms[3];
    id<MTLTexture>  dummy_tex_2d_ms_arr[3];
    id<MTLTexture>  dummy_tex_cube[3];
    id<MTLTexture>  dummy_tex_cube_arr[3];
    id<MTLTexture>  dummy_tex_3d[3];
    id<MTLTexture>  dummy_tex_depth;
    id<MTLTexture>  dummy_tex_depth_arr;
    id<MTLTexture>  dummy_tex_depth_cube;
    id<MTLTexture>  dummy_tex_depth_cube_arr;
    // Writable UAV dummy textures indexed by Bo3TexNumericType [0=float, 1=uint, 2=sint]
    id<MTLTexture>  dummy_uav_1d[3];
    id<MTLTexture>  dummy_uav_1d_arr[3];
    id<MTLTexture>  dummy_uav_2d[3];
    id<MTLTexture>  dummy_uav_2d_arr[3];
    id<MTLTexture>  dummy_uav_3d[3];
    id<MTLSamplerState> dummy_sampler;
    id<MTLDepthStencilState> default_dss;
    id<MTLDepthStencilState> default_dss_ro_depth;
    id<MTLDepthStencilState> default_dss_nodepth;
    Bo3MetalContext *immediate_ctx;   // guarded by ctx_lock; cleared by ctx_dtor
    os_unfair_lock   ctx_lock = OS_UNFAIR_LOCK_INIT;
    bool             holds_ctx_ref = false; // device owns one COM ref on immediate_ctx while externally alive
    void            *dxgi_adapter;  // Bo3DXGIAdapter1*
    std::atomic<uint32_t> max_frame_latency{3}; // IDXGIDevice1::SetMaximumFrameLatency (1..16, default 3)
    bool            lossy_rt = false;  // BO3ARM_LOSSY_RT=1 on an Apple8+ GPU (M2/M3/M4)

    void add_internal_ref();
    void release_internal_ref();
    void add_external_ref();
};

@protocol MTLFXSpatialScaler;

struct Bo3MetalSwapChain {
    Bo3ComBase      com;
    Bo3MetalDevice *device;
    CAMetalLayer   *layer;
    Bo3DXGI_SWAP_CHAIN_DESC desc;
    Bo3MetalTexture *backbuffer_tex;
    id<CAMetalDrawable> current_drawable;
    std::shared_ptr<Bo3SwapChainState> bb_state; // offscreen backbuffer, shared with backbuffer_tex
    os_unfair_lock  present_lock;      // serializes Present, latency permit updates, and ResizeBuffers (never held across dispatch_sync)
    std::atomic<uint32_t> last_sync_interval{0xffffffffu};
    bool            fullscreen;
    // Frame-latency semaphore: created with value 0 and topped up to `sem_permits` (so it can be
    // shrunk later without ever deallocating below its original value). Every successful wait in
    // Present is matched by exactly one signal (present command buffer completion).
    dispatch_semaphore_t frame_sem;
    uint32_t        sem_permits;       // permits currently in circulation (== applied frame latency)
    std::atomic<uint32_t> drawable_count{2}; // layer.maximumDrawableCount last applied
    std::shared_ptr<std::atomic<uint32_t>> drawables_in_flight; // queued drawables awaiting presentation
    std::atomic<uint64_t> frame_index{0};
    std::atomic<bool>     last_metalfx_active{false};
    uint64_t        last_fps_ns;
    uint64_t        last_fps_frames;
    uint64_t        last_hud_ns;
    uint64_t        last_hud_frames;
    // BO3ARM_RENDER_SCALE (with BO3ARM_METALFX=1): game-visible buffer = native * scale / 100,
    // CAMetalDrawable stays native and MetalFX spatially upscales on Present.
    uint32_t        native_w, native_h;
    uint32_t        target_w, target_h; // pending ResizeTarget mode dimensions (applied by ResizeBuffers)
    bool            has_pending_target; // true iff ResizeTarget set target_w/h since last ResizeBuffers/mode change
    uint32_t        render_scale;      // 100 = off
    // B1: cached MetalFX spatial scaler (BO3ARM_METALFX=1), recreated on size/format change
    id<MTLFXSpatialScaler> fx_scaler;
    id<MTLTexture>  fx_out_tex;        // intermediate output when the drawable lacks the scaler's usage
    uint32_t        fx_in_w, fx_in_h, fx_out_w, fx_out_h;
    MTLPixelFormat  fx_in_fmt, fx_out_fmt;
    bool            fx_direct;         // scaler writes straight into drawable.texture
    bool            fx_failed;         // creation failed for the current key -> plain blit

    id<MTLTexture> acquire_backbuffer_texture();
};

// Effective frame latency for a swap chain (BO3ARM_MAX_FRAME_LATENCY=1..3 overrides, else the
// device's SetMaximumFrameLatency value clamped to 1..3; default 3).
uint32_t bo3_dxgi_effective_frame_latency(Bo3MetalDevice *dev);
void     bo3_dxgi_compute_drawable_size(uint64_t hwnd, uint32_t bb_w, uint32_t bb_h,
                                        uint32_t scale_pct, bool fullscreen,
                                        uint32_t *out_dw, uint32_t *out_dh);
bool     bo3_metalfx_enabled(void);   // BO3ARM_METALFX=1 (evaluated once)
extern "C" uint32_t bo3_metalfx_render_scale_pct(void); // 50..99 when BO3ARM_METALFX=1 + BO3ARM_RENDER_SCALE set, else 100

// Global entrypoints & factory helpers
extern "C" {
void bo3_metal_init_all(void);
void bo3_metal_set_debug_marker(const char *name);
void bo3_metal_set_shader_name(const char *name);
const char *bo3_metal_get_shader_name(void);
}

// Shader cache (Generic.metallib + DXBC->MSL translator)
void bo3_shader_cache_init(id<MTLDevice> dev);
Bo3MetalShader *bo3_shader_cache_create(Bo3MetalDevice *dev, Bo3ShaderStage stage,
                                        const uint8_t *dxbc, size_t len, const char *name_hint);
bool bo3_shader_ensure_compiled(Bo3MetalShader *sh);
// Lazily compile (once) and return a stable fallback variant: which = 0 -> plain DXBC->MSL
// translation (only for Generic.metallib shaders), which = 1 -> force_float4_varyings.
// Returns nullptr when the variant is unavailable. NEVER mutates the primary shader state.
const Bo3ShaderVariant *bo3_shader_get_fallback(Bo3MetalShader *sh, int which);
// Populate vs_input_mask / vs_input_fmt from an MTLFunction's vertex attributes (once).
void bo3_shader_cache_vs_inputs(id<MTLFunction> fn, uint32_t *mask, MTLVertexFormat fmts[31]);

// =========================================================================
// M5: Persistent PSO cache (MTLBinaryArchive) + Generic.metallib reflection cache
// =========================================================================
// Cache dir: $BO3ARM_CACHE_DIR, else ~/Library/Caches/bo3arm/ (BO3ARM_NO_DISK_CACHE=1 disables).
// PSO creation entry points: try the persisted read-only archive segments first
// (MTLPipelineOptionFailOnBinaryArchiveMiss; never blocks on disk I/O or on the background queue),
// else compile and enqueue a background add into this session's fresh archive segment. Thread-safe.
// allow_archive = false (any stage from Aspyr's 2019 Generic.metallib, AIR 2.x) skips BOTH the
// archive lookup and the archive add: on Apple M4 / macOS 27 such functions make serializeToURL:
// fail ("missing 'vertex' stage") or emit a corrupt segment that is rejected on the next launch.
id<MTLRenderPipelineState>  bo3_pso_create_render(id<MTLDevice> dev, MTLRenderPipelineDescriptor *desc, NSError **err,
                                                  bool allow_archive = true);
id<MTLComputePipelineState> bo3_pso_create_compute(id<MTLDevice> dev, id<MTLFunction> fn, NSError **err,
                                                   bool allow_archive = true);
// Cheap per-Present check; schedules an async atomic flush (>= 25 new entries or 5 s quiet).
void bo3_shader_cache_on_present(void);
// Blocking flush of pending archive adds + archive/reflection files (atexit & device teardown).
void bo3_shader_cache_flush_sync(void);
// Reflected (Generic.metallib) binding map lookup (memory cache, pre-seeded from refl_cache_v1.bin).
bool bo3_refl_cache_lookup(const char *metal_fn_name, Bo3BindingMap *out);

struct Bo3PsoCacheStats {
    uint64_t pso_builds;          // PSOs actually compiled (archive miss / archive busy / disabled)
    uint64_t pso_archive_hits;    // PSOs served from the persistent MTLBinaryArchive
    uint64_t pso_archive_adds;    // descriptors added to the archive (background queue)
    uint64_t pso_archive_flushes; // successful atomic archive serializations
    uint64_t refl_reflected;      // reflect_generic_function() executions
    uint64_t refl_disk_hits;      // reflections skipped thanks to the (disk-seeded) cache
    uint64_t refl_loaded;         // entries loaded from refl_cache_v1.bin at startup
    uint64_t refl_flushes;        // successful atomic refl_cache_v1.bin writes
    uint32_t archive_segments;    // read-only archive segments loaded at init
    bool     archive_loaded;      // at least one existing archive segment was loaded at init
    bool     disk_cache_enabled;
};
void bo3_pso_cache_get_stats(Bo3PsoCacheStats *out);

// =========================================================================
// M5: Opt-in GPU / TBDR telemetry (BO3ARM_PERF_STATS=1, evaluated once; zero cost when unset)
// =========================================================================
bool bo3_perf_enabled(void);
// Called once per Present (after the frame is committed): prints one "[m5-perf]" line every
// 120 frames with per-frame averages over that window.
void bo3_context_perf_on_present(Bo3MetalContext *ctx, uint64_t frame_index);

struct Bo3PerfSnapshot {
    uint64_t frames;          // frames in the last completed report window
    double   gpu_ms;          // avg GPU execution time per frame (GPUEndTime - GPUStartTime)
    double   cpu_encode_ms;   // avg CPU time inside draw/dispatch/present per frame
    double   passes;          // avg render passes per frame
    double   draws;
    double   dispatches;
    double   tbdr_load_mb;    // avg attachment bytes loaded (MTLLoadActionLoad) per frame
    double   tbdr_store_mb;   // avg attachment bytes stored (Store / StoreAndMultisampleResolve)
    uint64_t pso_builds;      // PSO compiles during the window (total)
    uint64_t enc_state_skips; // redundant Metal bind calls skipped during the window (total)
    // Step 0: avg render passes ended per frame, by reason
    double   split_tgt;       // RT/DSV binding change
    double   split_clr;       // ClearRTV/DSV on an active attachment, or deferred-clear materialization
    double   split_blit;      // blit (upload / copy / unmap / resolve)
    double   split_cmp;       // compute dispatch / UAV clear
    double   split_uav;       // PS-UAV write ordering split
    double   split_pres;      // Present
    double   split_flush;     // Flush / CPU wait
    double   split_oth;       // anything else
    double   dontcare_saves;  // attachment stores skipped (DontCare) per frame
    double   ring_ovf;        // upload-ring overflows (dedicated staging buffers) per frame
    double   hoisted;         // uploads hoisted out of open render passes per frame
    double   clr_folded;      // deferred clears folded into a render-pass load action per frame
    double   clr_materialized;// deferred clears materialized as standalone clear passes per frame
};
// Last completed report window (all zero until the first report). For tests/tools/HUD.
void bo3_context_perf_last(Bo3MetalContext *ctx, Bo3PerfSnapshot *out);
void bo3_context_perf_sample_hud(Bo3MetalContext *ctx, Bo3PerfSnapshot *out);
void bo3_context_set_perf_active(Bo3MetalContext *ctx, bool active);

// DXBC lightweight ISGN parser (for CreateInputLayout)
struct Bo3DxbcInputElem {
    char     semantic[32];
    uint32_t semantic_index;
    uint32_t register_idx;
    uint8_t  component_type;
};
bool bo3_dxbc_extract_isgn(const uint8_t *dxbc, size_t len, std::vector<Bo3DxbcInputElem> *out);

// Vtable / object creators across translation units
Bo3MetalDevice   *bo3_d3d11_create_device_obj(void *dxgi_adapter);
Bo3MetalContext  *bo3_d3d11_create_context_obj(Bo3MetalDevice *dev);
Bo3MetalSwapChain *bo3_dxgi_create_swapchain_obj(Bo3MetalDevice *dev, const Bo3DXGI_SWAP_CHAIN_DESC *desc);
Bo3MetalTexture  *bo3_d3d11_create_backbuffer_proxy(Bo3MetalDevice *dev, Bo3MetalSwapChain *sc);
void             *bo3_dxgi_create_device_wrapper(Bo3MetalDevice *dev);
void             *bo3_dxgi_create_default_adapter(void);
void             *bo3_dxgi_get_default_output(void);
uint32_t          bo3_context_present_flush(Bo3MetalContext *ctx, Bo3MetalSwapChain *sc,
                                            uint32_t sync_interval, uint32_t flags);
void              bo3_context_flush_now(Bo3MetalContext *ctx, bool wait);
void              bo3_context_push_debug_marker(Bo3MetalContext *ctx, const char *name);

// Shared helper for Depth32Float_Stencil8 uploads; returns bitmask of uploaded aspects (0=failed, 1=depth, 2=stencil, 3=both).
uint8_t bo3_encode_depth_stencil_upload(id<MTLDevice> mdev, id<MTLBlitCommandEncoder> blit,
                                        id<MTLTexture> dst_tex, uint32_t dxgi_fmt,
                                        uint32_t slice, uint32_t mip,
                                        uint32_t ox, uint32_t oy, uint32_t w, uint32_t h,
                                        const uint8_t *src_base, uint32_t src_rp);

// Vtable accessors for sub-objects
uint64_t *bo3_vtable_buffer(void);
uint64_t *bo3_vtable_texture2d(void);
uint64_t *bo3_vtable_texture3d(void);
uint64_t *bo3_vtable_srv(void);
uint64_t *bo3_vtable_rtv(void);
uint64_t *bo3_vtable_dsv(void);
uint64_t *bo3_vtable_uav(void);
uint64_t *bo3_vtable_shader(void);
uint64_t *bo3_vtable_input_layout(void);
uint64_t *bo3_vtable_blend_state(void);
uint64_t *bo3_vtable_ds_state(void);
uint64_t *bo3_vtable_rs_state(void);
uint64_t *bo3_vtable_sampler_state(void);
uint64_t *bo3_vtable_query(void);

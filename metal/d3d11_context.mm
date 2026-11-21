#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#include "d3d11_metal.h"
#include "settings_mac.h"
#include "window_mac.h"
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <unordered_map>
#include <vector>

// =========================================================================
// Quad-Buffered Shared Upload Ring (fence-tracked -> zero GPU/CPU race!)
// =========================================================================

void Bo3UploadRing::init(id<MTLDevice> dev) {
    for (int i = 0; i < FRAMES; i++) {
        buffers[i] = [dev newBufferWithLength:CHUNK_SIZE options:MTLResourceStorageModeShared];
        ptrs[i] = (uint8_t *)buffers[i].contents;
        offsets[i] = 0;
        slot_epochs[i] = 0;
        slot_fence[i] = 0;
        slot_users[i].clear();
    }
    cur_frame = 0;
    epoch = 1;
    slot_epochs[0] = epoch;
}

bool Bo3UploadRing::alloc(size_t bytes, size_t align, uint64_t pending_fence,
                          id<MTLBuffer> *out_buf, uint64_t *out_off, void **out_ptr) {
    if (align < 16) align = 16;
    size_t cur = (offsets[cur_frame] + align - 1) & ~(align - 1);
    if (cur + bytes > CHUNK_SIZE) return false;
    offsets[cur_frame] = cur + bytes;
    if (pending_fence > slot_fence[cur_frame]) slot_fence[cur_frame] = pending_fence;
    *out_buf = buffers[cur_frame];
    *out_off = cur;
    *out_ptr = ptrs[cur_frame] + cur;
    return true;
}

void Bo3UploadRing::track_dynamic_user(Bo3MetalBuffer *b) {
    if (!b) return;
    if (b->dyn_epoch != epoch) {
        b->dyn_epoch = epoch;
        b->res.com.add_ref();
        slot_users[cur_frame].push_back(b);
    }
}

void Bo3UploadRing::mark_buffer_used(Bo3MetalBuffer *b, uint64_t pending_fence) {
    if (!b || b->dyn_epoch == 0) return;
    for (int i = 0; i < FRAMES; i++) {
        if (slot_epochs[i] == b->dyn_epoch) {
            if (pending_fence > slot_fence[i]) slot_fence[i] = pending_fence;
            break;
        }
    }
}

void Bo3UploadRing::advance_frame(id<MTLDevice> dev, uint64_t completed_fence, void (^wait_gpu_idle)(void)) {
    int next = (cur_frame + 1) % FRAMES;
    uint64_t expiring_epoch = slot_epochs[next];
    bool waited_idle = false;
    auto wait_idle = [&]() {
        if (!waited_idle && wait_gpu_idle) wait_gpu_idle();
        waited_idle = true;
    };
    // Preserve any persistent dynamic/renamed buffer still referencing the expiring ring slot
    // by allocating a FRESH shared MTLBuffer and swapping b->mtl_buf (ARC keeps the old
    // MTLBuffer alive for any in-flight GPU command buffers -> zero CPU/GPU race!).
    if (expiring_epoch != 0 && !slot_users[next].empty()) {
        for (Bo3MetalBuffer *b : slot_users[next]) {
            if (b->dyn_epoch == expiring_epoch && b->dyn_buf && b->desc.ByteWidth > 0) {
                size_t sz = std::max<size_t>(b->desc.ByteWidth, 256);
                sz = (sz + 15) & ~15ULL;
                const uint8_t *src = (const uint8_t *)b->dyn_buf.contents + b->dyn_offset;
                id<MTLBuffer> fresh = [dev newBufferWithLength:sz options:MTLResourceStorageModeShared];
                if (fresh) {
                    memcpy(fresh.contents, src, b->desc.ByteWidth);
                    if (sz > b->desc.ByteWidth) {
                        memset((uint8_t *)fresh.contents + b->desc.ByteWidth, 0, sz - b->desc.ByteWidth);
                    }
                    b->mtl_buf = fresh;
                    b->mtl_len = (uint64_t)sz;
                } else if (b->mtl_buf && b->mtl_buf.length >= b->desc.ByteWidth &&
                           b->mtl_buf.contents != (const void *)src) {
                    // OOM: never clobber a GPU-live buffer -> drain the GPU first, then the
                    // existing (now idle) mtl_buf can safely receive the latest contents.
                    wait_idle();
                    memcpy(b->mtl_buf.contents, src, b->desc.ByteWidth);
                } else {
                    // No safe destination at all: drain the GPU so the slot reset below can
                    // never race in-flight reads (contents fall back to the owned buffer).
                    wait_idle();
                }
                b->clear_dyn();
            }
            b->res.com.release();
        }
        slot_users[next].clear();
    }
    // Never reuse a ring slot whose last_used_fence has not yet completed on the GPU:
    // replace its backing MTLBuffer with a fresh chunk (ARC retains the old in-flight chunk).
    // If that allocation fails, WAIT for the GPU before resetting offset to 0.
    if (!waited_idle && completed_fence < slot_fence[next]) {
        id<MTLBuffer> fresh_chunk = [dev newBufferWithLength:CHUNK_SIZE options:MTLResourceStorageModeShared];
        if (fresh_chunk) {
            buffers[next] = fresh_chunk;
            ptrs[next] = (uint8_t *)fresh_chunk.contents;
        } else {
            wait_idle();
        }
    }
    slot_fence[next] = 0;
    cur_frame = next;
    epoch++;
    slot_epochs[cur_frame] = epoch;
    offsets[cur_frame] = 0;
}

void Bo3UploadRing::release_all() {
    for (int i = 0; i < FRAMES; i++) {
        for (Bo3MetalBuffer *b : slot_users[i]) {
            b->res.com.release();
        }
        slot_users[i].clear();
    }
}

// =========================================================================
// Render Pipeline State (PSO) Cache Key (monotonic unique_ids -> zero ABA!)
// =========================================================================

struct Bo3PsoKey {
    uint64_t vs_id;
    uint64_t ps_id;
    uint64_t il_id;
    uint64_t blend_hash;
    uint32_t rt_fmts[8];
    uint32_t ds_fmt;
    uint32_t sample_count;
    uint32_t vb_strides[16];

    bool operator==(const Bo3PsoKey &o) const {
        return memcmp(this, &o, sizeof(Bo3PsoKey)) == 0;
    }
};

struct Bo3PsoKeyHash {
    size_t operator()(const Bo3PsoKey &k) const {
        const uint8_t *p = (const uint8_t *)&k;
        uint64_t h = 14695981039346656037ULL;
        for (size_t i = 0; i < sizeof(k); i++) { h ^= p[i]; h *= 1099511628211ULL; }
        return (size_t)h;
    }
};

// Cached PSO plus the shader variant (-1 = primary, 0/1 = Bo3MetalShader::fallback_var[k])
// it was built with, so resource binding always uses the matching Bo3BindingMap.
struct Bo3PsoEntry {
    id<MTLRenderPipelineState> pso;
    int8_t vs_var;
    int8_t ps_var;
};

// Resolved per-stage shader selection (primary or stable fallback variant)
struct Bo3StageSel {
    id<MTLFunction>      fn = nil;
    const Bo3BindingMap *bindings = nullptr;
    id<MTLBuffer>        icb = nil;
    uint64_t             uid = 0;
    uint32_t             vs_input_mask = 0;
    const MTLVertexFormat *vs_input_fmt = nullptr;
    bool                 from_generic = false;
    bool                 valid = false;
};

static Bo3StageSel make_stage_sel(Bo3MetalShader *sh, int var) {
    Bo3StageSel s;
    if (!sh) return s;
    if (var >= 0 && var <= 1 && sh->fallback_var[var].valid) {
        const Bo3ShaderVariant &v = sh->fallback_var[var];
        s.fn = v.mtl_fn; s.bindings = &v.bindings; s.icb = nil; s.uid = v.unique_id;
        s.vs_input_mask = v.vs_input_mask; s.vs_input_fmt = v.vs_input_fmt;
        s.from_generic = false; s.valid = true;
        return s;
    }
    s.fn = sh->mtl_fn; s.bindings = &sh->bindings; s.icb = sh->icb_mtl_buf; s.uid = sh->unique_id;
    s.vs_input_mask = sh->vs_input_mask; s.vs_input_fmt = sh->vs_input_fmt;
    s.from_generic = sh->from_generic_metallib; s.valid = sh->valid;
    return s;
}

// =========================================================================
// Immediate Context State & TBDR Render Pass Builder
// =========================================================================

enum Bo3EncoderMode {
    ENC_NONE = 0,
    ENC_RENDER = 1,
    ENC_COMPUTE = 2,
    ENC_BLIT = 3,
};

// Step 0: why an open render pass was ended (BO3ARM_PERF_STATS=1 telemetry only)
enum Bo3SplitReason : uint8_t {
    SPLIT_TGT = 0,   // RT / DSV binding change
    SPLIT_CLR,       // ClearRTV/DSV on an active attachment or deferred-clear materialization
    SPLIT_BLIT,      // blit encoder (upload / copy / unmap / resolve / mips)
    SPLIT_CMP,       // compute encoder (dispatch / UAV clear / unaligned copy)
    SPLIT_UAV,       // PS-UAV write ordering split
    SPLIT_PRES,      // Present
    SPLIT_FLUSH,     // Flush / CPU wait
    SPLIT_OTH,
    SPLIT_COUNT
};

// Completion join for one fence covering several command buffers (upload_cmd_buf + cmd_buf):
// completed_fence only advances once EVERY command buffer of the batch has completed.
struct Bo3FenceJoin {
    std::atomic<int> remaining;
};

struct Bo3MetalContext {
    Bo3ComBase      com;
    Bo3MetalDevice *device;
    os_unfair_lock  lock;

    // Active command buffer & encoders
    id<MTLCommandBuffer>         cmd_buf;
    // A2: per-frame upload command buffer for uploads hoisted out of open render passes.
    // ALWAYS committed immediately before cmd_buf on the same serial queue.
    id<MTLCommandBuffer>         upload_cmd_buf;
    id<MTLBlitCommandEncoder>    upload_blit_enc;
    id<MTLCommandBuffer>         last_committed_cb;
    Bo3EncoderMode               enc_mode;
    id<MTLRenderCommandEncoder>  render_enc;
    id<MTLComputeCommandEncoder> compute_enc;
    id<MTLBlitCommandEncoder>    blit_enc;

    // Active render pass targets (compared by actual MTLTexture/level/slice/format -> zero ABA!)
    id<MTLTexture> active_rt_tex[8];
    uint32_t       active_rt_lvl[8];
    uint32_t       active_rt_sl[8];
    uint32_t       active_rt_arr_sz[8];
    MTLPixelFormat active_rt_fmt[8];
    uint32_t       active_rtv_count;
    id<MTLTexture> active_ds_tex;
    uint32_t       active_ds_lvl;
    uint32_t       active_ds_sl;
    uint32_t       active_ds_arr_sz;
    uint32_t       active_ds_flags;
    bool           active_dsv_has_stencil;
    // A1a: render passes open with MTLStoreActionUnknown; the final store action per attachment is
    // set right before endEncoding (DontCare when a full clear supersedes the attachment).
    uint32_t       active_layers;           // layers attached per (non-3D) attachment (renderTargetArrayLength or 1)
    MTLStoreAction active_rt_store[8];
    MTLStoreAction active_ds_store;
    MTLStoreAction active_st_store;
    Bo3MetalTexture *active_rt_res[8];      // owning texture per attachment (identity compare only)
    Bo3MetalTexture *active_ds_res;
    uint64_t       active_rt_bytes[8];      // perf: logical store bytes per attachment
    uint64_t       active_ds_bytes;
    uint64_t       active_st_bytes;
    bool           active_uav_only;
    bool           pass_has_frag_uav_write; // a draw in the open render pass wrote PS UAVs
    bool           frag_barrier_ok;         // GPU supports render-encoder fragment->* memory barriers
    uint32_t       pass_w;
    uint32_t       pass_h;

    // Bound OM state
    Bo3MetalRTV *rtvs[8];
    uint32_t     rtv_count;
    Bo3MetalDSV *dsv;
    Bo3MetalUAV *om_uavs[8];
    Bo3MetalBlendState *blend_state;
    float        blend_factor[4];
    uint32_t     sample_mask;
    Bo3MetalDepthStencilState *ds_state;
    uint32_t     stencil_ref;

    // A5: OM bindings / encoder changed since the open render pass was validated
    bool         om_dirty;

    // IA state
    Bo3MetalInputLayout *input_layout;
    Bo3MetalBuffer      *vbs[16];
    uint32_t             vb_strides[16];
    uint32_t             vb_offsets[16];
    Bo3MetalBuffer      *ib;
    MTLIndexType         ib_type;
    uint32_t             ib_offset;
    uint32_t             topology;

    // RS state
    Bo3MetalRasterizerState *rs_state;
    Bo3D3D11_VIEWPORT        viewports[16];
    uint32_t                 viewport_count;
    Bo3RECT                  scissors[16];
    uint32_t                 scissor_count;

    // Shader stages & D3D slot shadow tables
    Bo3MetalShader       *vs;
    Bo3MetalShader       *ps;
    Bo3MetalShader       *cs;
    Bo3MetalBuffer       *vs_cb[14], *ps_cb[14], *cs_cb[14];
    Bo3MetalSRV          *vs_srv[128], *ps_srv[128], *cs_srv[128];
    Bo3MetalSamplerState *vs_smp[16], *ps_smp[16], *cs_smp[16];
    Bo3MetalUAV          *cs_uav[64];

    // Upload ring & PSO cache
    Bo3UploadRing upload_ring;
    std::unordered_map<Bo3PsoKey, Bo3PsoEntry, Bo3PsoKeyHash> pso_cache;
    // MSAA same-family bitcast copy (per-sample fragment pass), keyed by (src fmt, dst fmt, samples, array)
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> msaa_copy_pso;
    id<MTLDepthStencilState> msaa_copy_dss = nil; // depth compare Always + write (depth destinations)
    int8_t cur_vs_var = -1;
    int8_t cur_ps_var = -1;
    id<MTLRenderPipelineState> blit_present_pso;
    // Generic.metallib aggregate uavCounters table (8 x uint32_t)
    id<MTLBuffer> uav_counter_table;
    // Lazily compiled compute PSOs for ClearUnorderedAccessViewUint/Float & unaligned byte copies
    bool clear_uav_psos_init = false;
    id<MTLComputePipelineState> clear_uav_buf_pso;
    id<MTLComputePipelineState> clear_uav_bytes_pso;
    id<MTLComputePipelineState> clear_uav_1d_pso[3];
    id<MTLComputePipelineState> clear_uav_1d_arr_pso[3];
    id<MTLComputePipelineState> clear_uav_2d_pso[3];
    id<MTLComputePipelineState> clear_uav_2d_arr_pso[3];
    id<MTLComputePipelineState> clear_uav_3d_pso[3];
    id<MTLComputePipelineState> byte_copy_pso;

    // Fence tracking for EVENT/TIMESTAMP/OCCLUSION queries & upload ring
    std::atomic<uint64_t> submitted_fence;
    std::atomic<uint64_t> completed_fence;

    // Diagnostics
    uint64_t draw_calls = 0;
    uint64_t dispatch_calls = 0;
    uint64_t pass_splits = 0;
    uint64_t cur_frame_no = 0;

    // M5: per-render-encoder bound-state cache. Strong refs, valid ONLY while render_enc is open:
    // reset_enc_state_cache() nils every entry when the render encoder is created and when it ends,
    // so ARC releases them and a freed/reused address is never compared against.
    id<MTLRenderPipelineState> enc_pso = nil;
    id<MTLDepthStencilState>   enc_dss = nil;
    uint32_t                   enc_stencil_ref = 0;
    bool                       enc_stencil_ref_valid = false;
    id<MTLBuffer>              enc_vs_buf[31];
    id<MTLBuffer>              enc_ps_buf[31];
    uint64_t                   enc_vs_off[31] = {};
    uint64_t                   enc_ps_off[31] = {};
    id<MTLTexture>             enc_vs_tex[32];
    id<MTLTexture>             enc_ps_tex[32];
    id<MTLSamplerState>        enc_vs_samp[16];
    id<MTLSamplerState>        enc_ps_samp[16];
    uint64_t                   enc_state_skips = 0;   // redundant Metal bind calls skipped (lifetime)

    // M5 telemetry (BO3ARM_PERF_STATS=1 or Detailed HUD); zero-barrier plain bool under c->lock,
    // plus relaxed atomic mirror ONLY for unlocked Bo3PerfScope entry.
    bool                  perf_on = false;
    std::atomic<bool>     perf_on_scope{false};
    std::atomic<uint64_t> perf_cpu_ticks{0};      // mach ticks inside draw/dispatch/present
    // (perf_gpu_ns, perf_gpu_frames) are updated/drained together under perf_gpu_lock so a CB
    // completion can never be split across two report windows.
    os_unfair_lock        perf_gpu_lock = OS_UNFAIR_LOCK_INIT;
    uint64_t              perf_gpu_ns = 0;        // summed GPUEndTime-GPUStartTime of completed CBs
    uint64_t              perf_gpu_frames = 0;    // completed Present command buffers
    struct Bo3FrameTiming {
        std::atomic<int>      remaining{1};       // 1 = frame open; +1 per committed CB in frame
        std::atomic<uint64_t> gpu_ns{0};
        bool                  counted_frame{false};
    };
    Bo3FrameTiming       *cur_frame_timing = nullptr; // guarded by lock; sealed at Present
    uint64_t              perf_load_bytes = 0;    // under lock
    uint64_t              perf_store_bytes = 0;   // under lock
    uint64_t              perf_win_frames = 0;
    uint64_t              perf_base_draws = 0, perf_base_dispatches = 0, perf_base_passes = 0;
    uint64_t              perf_base_skips = 0, perf_base_pso_builds = 0;
    Bo3PerfSnapshot       perf_last = {};
    uint64_t              perf_split[SPLIT_COUNT] = {};
    uint64_t              perf_dontcare_saves = 0;
    uint64_t              perf_ring_overflows = 0;
    uint64_t              perf_hoisted_uploads = 0;
    uint64_t              perf_clr_folded = 0;
    uint64_t              perf_clr_materialized = 0;

    // A1b: textures with deferred clears (each holds one COM ref while listed). Empty -> O(1) skip.
    std::vector<Bo3MetalTexture *> pending_clear_texs;

    // A5: 1-entry PSO fast path (skips key hashing + unordered_map lookup on unchanged draws)
    bool                       pso_dirty = true;
    bool                       last_pso_valid = false;
    Bo3PsoKey                  last_pso_key = {};
    id<MTLRenderPipelineState> last_pso = nil;
    int8_t                     last_vs_var = -1;
    int8_t                     last_ps_var = -1;
    // A5: per-encoder bufferInfo (setVertexBytes/setFragmentBytes) dedup; idx 0xff = invalid
    uint8_t                    enc_vs_bufinfo_idx = 0xff;
    uint8_t                    enc_ps_bufinfo_idx = 0xff;
    uint32_t                   enc_vs_bufinfo[64] = {};
    uint32_t                   enc_ps_bufinfo[64] = {};

    // Methods
    uint64_t pending_fence() const { return submitted_fence.load(std::memory_order_relaxed) + 1; }
    void ensure_cmd_buf();
    void end_active_encoder(Bo3SplitReason reason = SPLIT_OTH);
    // A2: hoisted uploads
    bool can_hoist(const Bo3MetalResource *r) const {
        return enc_mode == ENC_RENDER && render_enc &&
               r->last_cmd_fence.load(std::memory_order_relaxed) < pending_fence();
    }
    id<MTLBlitCommandEncoder> hoist_blit_encoder();
    void mark_hoisted(Bo3MetalResource *r) {
        uint64_t f = pending_fence();
        if (r->last_gpu_fence.load(std::memory_order_relaxed) < f) r->last_gpu_fence.store(f, std::memory_order_relaxed);
        if (perf_on) perf_hoisted_uploads++;
    }
    id<MTLCommandBuffer> commit_pending_locked(Bo3SplitReason reason, bool materialize_clears);
    // A1b: deferred clears
    void record_clear(Bo3MetalTexture *t, const Bo3TexPendingClear &pc);
    void unlist_if_clean(Bo3MetalTexture *t);
    bool has_clear_overlap(Bo3MetalTexture *t, const struct Bo3SubRange &r) const;
    void materialize_clears(Bo3MetalTexture *t, const struct Bo3SubRange *filter);
    void materialize_all_clears();
    void drop_clears(Bo3MetalTexture *t, const struct Bo3SubRange &r);
    void materialize_res(Bo3MetalResource *r, const struct Bo3SubRange &range);
    void materialize_srv_uav_reads(Bo3ShaderStage stage);
    void release_clear_list();
    // M5 render-encoder state dedup (render_enc must be open)
    void reset_enc_state_cache();
    void enc_set_pso(id<MTLRenderPipelineState> pso);
    void enc_set_dss(id<MTLDepthStencilState> dss, uint32_t ref);
    void enc_set_buffer(bool vs, uint32_t idx, id<MTLBuffer> buf, uint64_t off);
    void enc_set_bytes(bool vs, const void *bytes, size_t len, uint32_t idx);
    void enc_set_texture(bool vs, uint32_t idx, id<MTLTexture> tex);
    void enc_set_sampler(bool vs, uint32_t idx, id<MTLSamplerState> smp);
    void perf_account_pass(MTLRenderPassDescriptor *rpd);
    Bo3FrameTiming *ensure_frame_timing_locked();
    void perf_finish_cb_timing(Bo3FrameTiming *ft, id<MTLCommandBuffer> cb);
    void ensure_blit_encoder();
    void ensure_compute_encoder();
    void ensure_clear_uav_psos();
    bool ensure_render_pass();
    void apply_live_scissor();
    bool scissor_is_empty() const;
    id<MTLDepthStencilState> select_active_dss() const;
    bool srv_conflicts_with_outputs(const Bo3MetalSRV *v) const;
    void unbind_srvs_overlapping(const struct Bo3SubRange &out);
    void unbind_uavs_overlapping(const struct Bo3SubRange &out, bool include_om, bool include_cs);
    void unbind_om_overlapping(const struct Bo3SubRange &out);
    void encode_buffer_copy(id<MTLBuffer> sbuf, uint64_t soff, id<MTLBuffer> dbuf, uint64_t doff, uint64_t sz);
    void encode_ordered_u32_write(id<MTLBuffer> dst, uint64_t dst_off, uint32_t val);
    void clear_all_state();
    id<MTLRenderPipelineState> get_or_build_pso();
    void bind_stage_resources(Bo3ShaderStage stage, const Bo3StageSel &sel);
    void touch(Bo3MetalResource *r) {
        if (r) {
            uint64_t f = pending_fence();
            if (f > r->last_gpu_fence.load(std::memory_order_relaxed)) r->last_gpu_fence.store(f, std::memory_order_relaxed);
            if (f > r->last_cmd_fence.load(std::memory_order_relaxed)) r->last_cmd_fence.store(f, std::memory_order_relaxed);
        }
    }
    void touch_buf(Bo3MetalBuffer *b) {
        if (!b) return;
        upload_ring.mark_buffer_used(b, pending_fence());
        touch(&b->res);
    }
    void materialize_renamed(Bo3MetalBuffer *b);
    id<MTLTexture> resolve_srv_texture(Bo3MetalSRV *srv, uint8_t expect, uint8_t num_type);
    id<MTLTexture> resolve_uav_texture(Bo3MetalUAV *uav, uint8_t expect, uint8_t num_type);
};

static uint64_t g_vt_context[120];

// =========================================================================
// Blend & Primitive Conversions
// =========================================================================

static MTLBlendFactor d3d_blend_to_mtl(uint32_t b) {
    switch (b) {
        case 1:  return MTLBlendFactorZero;
        case 2:  return MTLBlendFactorOne;
        case 3:  return MTLBlendFactorSourceColor;
        case 4:  return MTLBlendFactorOneMinusSourceColor;
        case 5:  return MTLBlendFactorSourceAlpha;
        case 6:  return MTLBlendFactorOneMinusSourceAlpha;
        case 7:  return MTLBlendFactorDestinationAlpha;
        case 8:  return MTLBlendFactorOneMinusDestinationAlpha;
        case 9:  return MTLBlendFactorDestinationColor;
        case 10: return MTLBlendFactorOneMinusDestinationColor;
        case 11: return MTLBlendFactorSourceAlphaSaturated;
        case 14: return MTLBlendFactorBlendColor;
        case 15: return MTLBlendFactorOneMinusBlendColor;
        case 16: return MTLBlendFactorSource1Color;
        case 17: return MTLBlendFactorOneMinusSource1Color;
        case 18: return MTLBlendFactorSource1Alpha;
        case 19: return MTLBlendFactorOneMinusSource1Alpha;
        default: return MTLBlendFactorOne;
    }
}

static MTLBlendOperation d3d_blendop_to_mtl(uint32_t op) {
    switch (op) {
        case 1: return MTLBlendOperationAdd;
        case 2: return MTLBlendOperationSubtract;
        case 3: return MTLBlendOperationReverseSubtract;
        case 4: return MTLBlendOperationMin;
        case 5: return MTLBlendOperationMax;
        default: return MTLBlendOperationAdd;
    }
}

static MTLPrimitiveType d3d_topo_to_mtl(uint32_t topo) {
    switch (topo) {
        case BO3_D3D11_PRIMITIVE_TOPOLOGY_POINTLIST:     return MTLPrimitiveTypePoint;
        case BO3_D3D11_PRIMITIVE_TOPOLOGY_LINELIST:      return MTLPrimitiveTypeLine;
        case BO3_D3D11_PRIMITIVE_TOPOLOGY_LINESTRIP:     return MTLPrimitiveTypeLineStrip;
        case BO3_D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: return MTLPrimitiveTypeTriangleStrip;
        default:                                         return MTLPrimitiveTypeTriangle;
    }
}

static MTLColorWriteMask d3d_writemask_to_mtl(uint8_t m) {
    MTLColorWriteMask out = MTLColorWriteMaskNone;
    if (m & 1) out |= MTLColorWriteMaskRed;
    if (m & 2) out |= MTLColorWriteMaskGreen;
    if (m & 4) out |= MTLColorWriteMaskBlue;
    if (m & 8) out |= MTLColorWriteMaskAlpha;
    return out;
}

// =========================================================================
// Encoder Lifecycle & TBDR Render Pass Builder
// =========================================================================

static bool is_integer_mtl_format(MTLPixelFormat pf) {
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

static bool is_depth_mtl_format(MTLPixelFormat pf) {
    return pf == MTLPixelFormatDepth32Float ||
           pf == MTLPixelFormatDepth32Float_Stencil8 ||
           pf == MTLPixelFormatDepth16Unorm;
}

static bool is_compressed_mtl_format(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB:
        case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB:
        case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB:
        case MTLPixelFormatBC4_RUnorm: case MTLPixelFormatBC4_RSnorm:
        case MTLPixelFormatBC5_RGUnorm: case MTLPixelFormatBC5_RGSnorm:
        case MTLPixelFormatBC6H_RGBUfloat: case MTLPixelFormatBC6H_RGBFloat:
        case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB:
            return true;
        default:
            return false;
    }
}

static uint32_t vertex_format_byte_size(MTLVertexFormat vf) {
    switch (vf) {
        case MTLVertexFormatUChar: case MTLVertexFormatChar:
        case MTLVertexFormatUCharNormalized: case MTLVertexFormatCharNormalized:
            return 1;
        case MTLVertexFormatUChar2: case MTLVertexFormatChar2:
        case MTLVertexFormatUChar2Normalized: case MTLVertexFormatChar2Normalized:
        case MTLVertexFormatUShort: case MTLVertexFormatShort:
        case MTLVertexFormatUShortNormalized: case MTLVertexFormatShortNormalized:
        case MTLVertexFormatHalf:
            return 2;
        case MTLVertexFormatUChar3: case MTLVertexFormatChar3:
        case MTLVertexFormatUChar3Normalized: case MTLVertexFormatChar3Normalized:
            return 3;
        case MTLVertexFormatUChar4: case MTLVertexFormatChar4:
        case MTLVertexFormatUChar4Normalized: case MTLVertexFormatChar4Normalized:
        case MTLVertexFormatUChar4Normalized_BGRA:
        case MTLVertexFormatUShort2: case MTLVertexFormatShort2:
        case MTLVertexFormatUShort2Normalized: case MTLVertexFormatShort2Normalized:
        case MTLVertexFormatHalf2:
        case MTLVertexFormatFloat: case MTLVertexFormatInt: case MTLVertexFormatUInt:
        case MTLVertexFormatUInt1010102Normalized: case MTLVertexFormatInt1010102Normalized:
        case MTLVertexFormatFloatRG11B10: case MTLVertexFormatFloatRGB9E5:
            return 4;
        case MTLVertexFormatUShort3: case MTLVertexFormatShort3:
        case MTLVertexFormatUShort3Normalized: case MTLVertexFormatShort3Normalized:
        case MTLVertexFormatHalf3:
            return 6;
        case MTLVertexFormatUShort4: case MTLVertexFormatShort4:
        case MTLVertexFormatUShort4Normalized: case MTLVertexFormatShort4Normalized:
        case MTLVertexFormatHalf4:
        case MTLVertexFormatFloat2: case MTLVertexFormatInt2: case MTLVertexFormatUInt2:
            return 8;
        case MTLVertexFormatFloat3: case MTLVertexFormatInt3: case MTLVertexFormatUInt3:
            return 12;
        case MTLVertexFormatFloat4: case MTLVertexFormatInt4: case MTLVertexFormatUInt4:
        default:
            return 16;
    }
}

static uint8_t find_zero_vb_mbuf(const Bo3MetalInputLayout *il, const Bo3BindingMap *vs_map) {
    bool used[31] = {false};
    if (il) {
        for (const auto &el : il->elements) {
            if (el.attr_index >= 0 && el.attr_index < 31 && el.input_slot < 16) {
                used[30 - el.input_slot] = true;
            }
        }
    }
    uint8_t min_free = vs_map ? (uint8_t)(vs_map->max_buf_idx + 1) : 15;
    // Prefer high VB buffer indices starting from slot 15 (mbuf=15) up to 30
    for (int s = 15; s >= 0; s--) {
        uint8_t mb = (uint8_t)(30 - s);
        if (!used[mb] && mb >= min_free) return mb;
    }
    for (int s = 15; s >= 0; s--) {
        uint8_t mb = (uint8_t)(30 - s);
        if (!used[mb]) return mb;
    }
    return 15;
}

id<MTLDepthStencilState> Bo3MetalContext::select_active_dss() const {
    if (!active_ds_tex) {
        return ds_state ? ds_state->mtl_dss_nodepth : device->default_dss_nodepth;
    }
    bool ro_d = (active_ds_flags & BO3_D3D11_DSV_READ_ONLY_DEPTH) != 0;
    bool ro_s = (active_ds_flags & BO3_D3D11_DSV_READ_ONLY_STENCIL) != 0;
    if (!active_dsv_has_stencil) {
        // Depth-only attachment (no stencilAttachment.texture): a DSS carrying stencil
        // descriptors aborts under MTL_DEBUG_LAYER -> always use the stencil-less twins.
        if (ds_state) return ro_d ? ds_state->mtl_dss_nostencil_ro_depth : ds_state->mtl_dss_nostencil;
        return ro_d ? device->default_dss_ro_depth : device->default_dss;
    }
    if (ds_state) {
        if (ro_d && ro_s) return ds_state->mtl_dss_ro_both;
        if (ro_d)         return ds_state->mtl_dss_ro_depth;
        if (ro_s)         return ds_state->mtl_dss_ro_stencil;
        return ds_state->mtl_dss;
    }
    return ro_d ? device->default_dss_ro_depth : device->default_dss;
}

// =========================================================================
// D3D11 subresource-precise hazard tracking (mip / slice / buffer range / depth-vs-stencil aspect)
// =========================================================================

enum : uint8_t { BO3_ASPECT_COLOR_DEPTH = 1, BO3_ASPECT_STENCIL = 2, BO3_ASPECT_ALL = 3 };

struct Bo3SubRange {
    Bo3MetalResource *res = nullptr;
    uint32_t mip0 = 0, mip_cnt = 0xffffffffu;
    uint32_t sl0 = 0, sl_cnt = 0xffffffffu;
    uint64_t boff = 0, blen = 0; // buffers (blen == 0 -> whole buffer)
    uint8_t  aspect = BO3_ASPECT_ALL;
};

static bool views_overlap(const Bo3SubRange &a, const Bo3SubRange &b) {
    if (!a.res || a.res != b.res) return false;
    if (a.res->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        if (a.blen == 0 || b.blen == 0) return true;
        return a.boff < b.boff + b.blen && b.boff < a.boff + a.blen;
    }
    if ((a.aspect & b.aspect) == 0) return false;
    auto ov = [](uint64_t s0, uint64_t c0, uint64_t s1, uint64_t c1) {
        return s0 < s1 + c1 && s1 < s0 + c0;
    };
    if (!ov(a.mip0, a.mip_cnt, b.mip0, b.mip_cnt)) return false;
    if (a.res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D) return true; // W-slices alias whole mip
    return ov(a.sl0, a.sl_cnt, b.sl0, b.sl_cnt);
}

static Bo3SubRange range_of_srv(const Bo3MetalSRV *v) {
    Bo3SubRange r;
    if (!v) return r;
    r.res = v->resource;
    if (v->is_buffer) { r.boff = v->buf_offset; r.blen = v->buf_size; return r; }
    r.mip0 = v->mip0; r.mip_cnt = std::max(1u, v->mip_cnt);
    r.sl0 = v->slice0; r.sl_cnt = std::max(1u, v->slice_cnt);
    r.aspect = v->aspect ? v->aspect : BO3_ASPECT_ALL;
    return r;
}
static Bo3SubRange range_of_rtv(const Bo3MetalRTV *v) {
    Bo3SubRange r;
    if (!v) return r;
    r.res = v->resource;
    if (v->resource && v->resource->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER) return r;
    r.mip0 = v->mip_slice; r.mip_cnt = 1;
    r.sl0 = v->array_slice; r.sl_cnt = std::max(1u, v->array_size);
    r.aspect = BO3_ASPECT_COLOR_DEPTH;
    return r;
}
// write_only = true -> only the aspects this DSV can actually write (read-only aspects never conflict with SRVs)
static Bo3SubRange range_of_dsv(const Bo3MetalDSV *v, bool write_only) {
    Bo3SubRange r;
    if (!v) return r;
    r.res = v->resource;
    r.mip0 = v->mip_slice; r.mip_cnt = 1;
    r.sl0 = v->array_slice; r.sl_cnt = std::max(1u, v->array_size);
    uint8_t asp = BO3_ASPECT_COLOR_DEPTH | (v->has_stencil ? BO3_ASPECT_STENCIL : 0);
    if (write_only) {
        if (v->desc.Flags & BO3_D3D11_DSV_READ_ONLY_DEPTH)   asp &= (uint8_t)~BO3_ASPECT_COLOR_DEPTH;
        if (v->desc.Flags & BO3_D3D11_DSV_READ_ONLY_STENCIL) asp &= (uint8_t)~BO3_ASPECT_STENCIL;
    }
    r.aspect = asp;
    if (asp == 0) r.res = nullptr; // fully read-only DSV: never an output hazard
    return r;
}
static Bo3SubRange range_of_uav(const Bo3MetalUAV *v) {
    Bo3SubRange r;
    if (!v) return r;
    r.res = v->resource;
    if (v->is_buffer) { r.boff = v->buf_offset; r.blen = v->buf_size; return r; }
    r.mip0 = v->mip0; r.mip_cnt = 1;
    r.sl0 = v->slice0; r.sl_cnt = std::max(1u, v->slice_cnt);
    return r;
}

// D3D11 contract: an incoming SRV that overlaps a currently bound output (RTV, writable DSV aspect,
// OM UAV or CS UAV) is forced to NULL; the output binding is preserved.
bool Bo3MetalContext::srv_conflicts_with_outputs(const Bo3MetalSRV *v) const {
    if (!v || !v->resource) return false;
    Bo3SubRange sr = range_of_srv(v);
    for (uint32_t i = 0; i < 8; i++) {
        if (rtvs[i] && views_overlap(sr, range_of_rtv(rtvs[i]))) return true;
        if (om_uavs[i] && views_overlap(sr, range_of_uav(om_uavs[i]))) return true;
    }
    if (dsv && views_overlap(sr, range_of_dsv(dsv, true))) return true;
    for (uint32_t i = 0; i < 64; i++) {
        if (cs_uav[i] && views_overlap(sr, range_of_uav(cs_uav[i]))) return true;
    }
    return false;
}

void Bo3MetalContext::unbind_srvs_overlapping(const Bo3SubRange &out) {
    if (!out.res) return;
    auto clear_stage = [&](Bo3MetalSRV **arr) {
        for (int i = 0; i < 128; i++) {
            if (arr[i] && views_overlap(out, range_of_srv(arr[i]))) {
                arr[i]->com.release();
                arr[i] = nullptr;
            }
        }
    };
    clear_stage(vs_srv);
    clear_stage(ps_srv);
    clear_stage(cs_srv);
}

void Bo3MetalContext::unbind_uavs_overlapping(const Bo3SubRange &out, bool include_om, bool include_cs) {
    if (!out.res) return;
    if (include_om) {
        for (int i = 0; i < 8; i++) {
            if (om_uavs[i] && views_overlap(out, range_of_uav(om_uavs[i]))) {
                om_uavs[i]->com.release();
                om_uavs[i] = nullptr;
            }
        }
    }
    if (include_cs) {
        for (int i = 0; i < 64; i++) {
            if (cs_uav[i] && views_overlap(out, range_of_uav(cs_uav[i]))) {
                cs_uav[i]->com.release();
                cs_uav[i] = nullptr;
            }
        }
    }
}

void Bo3MetalContext::unbind_om_overlapping(const Bo3SubRange &out) {
    if (!out.res) return;
    // Deferred clears live on the texture (A1b), so unbinding never needs to materialize them.
    for (uint32_t i = 0; i < 8; i++) {
        if (rtvs[i] && views_overlap(out, range_of_rtv(rtvs[i]))) {
            rtvs[i]->com.release();
            rtvs[i] = nullptr;
        }
    }
    if (dsv && views_overlap(out, range_of_dsv(dsv, false))) {
        dsv->com.release();
        dsv = nullptr;
    }
    om_dirty = true;
}


// =========================================================================
// A1b: per-texture deferred clears
// =========================================================================

static uint64_t perf_attachment_bytes(id<MTLTexture> t, NSUInteger level, uint32_t layers, uint32_t bpp);

static Bo3SubRange clear_entry_range(Bo3MetalTexture *t, const Bo3TexPendingClear &e) {
    Bo3SubRange r;
    r.res = &t->res;
    r.mip0 = e.mip; r.mip_cnt = 1;
    r.sl0 = e.slice; r.sl_cnt = 1;
    r.aspect = e.is_color ? (uint8_t)BO3_ASPECT_COLOR_DEPTH : e.aspects;
    return r;
}

static int find_clear(const Bo3MetalTexture *t, uint32_t mip, uint32_t slice) {
    for (size_t i = 0; i < t->pending_clears.size(); i++) {
        if (t->pending_clears[i].mip == mip && t->pending_clears[i].slice == slice) return (int)i;
    }
    return -1;
}

void Bo3MetalContext::record_clear(Bo3MetalTexture *t, const Bo3TexPendingClear &pc) {
    int idx = find_clear(t, pc.mip, pc.slice);
    if (idx < 0) {
        t->pending_clears.push_back(pc);
    } else {
        // A newer clear of the same subresource fully supersedes the older one (per aspect)
        Bo3TexPendingClear &e = t->pending_clears[(size_t)idx];
        if (pc.is_color || e.is_color) {
            e = pc;
        } else {
            if (pc.aspects & BO3_ASPECT_COLOR_DEPTH) e.depth = pc.depth;
            if (pc.aspects & BO3_ASPECT_STENCIL) e.stencil = pc.stencil;
            e.aspects |= pc.aspects;
        }
    }
    if (!t->in_clear_list) {
        t->res.com.add_ref();
        t->in_clear_list = true;
        pending_clear_texs.push_back(t);
    }
}

// May release the list's COM ref (and destroy `t`): never touch `t` after calling this.
void Bo3MetalContext::unlist_if_clean(Bo3MetalTexture *t) {
    if (!t->in_clear_list || !t->pending_clears.empty()) return;
    for (size_t i = 0; i < pending_clear_texs.size(); i++) {
        if (pending_clear_texs[i] == t) {
            pending_clear_texs[i] = pending_clear_texs.back();
            pending_clear_texs.pop_back();
            break;
        }
    }
    t->in_clear_list = false;
    t->res.com.release();
}

bool Bo3MetalContext::has_clear_overlap(Bo3MetalTexture *t, const Bo3SubRange &r) const {
    for (const auto &e : t->pending_clears) {
        if (views_overlap(r, clear_entry_range(t, e))) return true;
    }
    return false;
}

// Encode a minimal clear pass for every deferred clear of `t` overlapping `filter` (all when null),
// in D3D11 order BEFORE whatever reads / partially writes the texture next.
void Bo3MetalContext::materialize_clears(Bo3MetalTexture *t, const Bo3SubRange *filter) {
    if (!t || t->pending_clears.empty()) return;
    std::vector<Bo3TexPendingClear> todo;
    for (size_t i = 0; i < t->pending_clears.size();) {
        if (!filter || views_overlap(*filter, clear_entry_range(t, t->pending_clears[i]))) {
            todo.push_back(t->pending_clears[i]);
            t->pending_clears[i] = t->pending_clears.back();
            t->pending_clears.pop_back();
        } else {
            i++;
        }
    }
    if (!todo.empty()) {
        id<MTLTexture> base = t->current_mtl_texture();
        if (base) {
            end_active_encoder(SPLIT_CLR);
            ensure_cmd_buf();
            const bool is3d = base.textureType == MTLTextureType3D;
            uint32_t total_sl = (uint32_t)base.arrayLength;
            if (base.textureType == MTLTextureTypeCube) total_sl = 6u;
            else if (base.textureType == MTLTextureTypeCubeArray) total_sl *= 6u;
            const bool has_st = base.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
            bool any_encoded = false;
            for (const auto &e : todo) {
                if (e.mip >= base.mipmapLevelCount) continue;
                const uint32_t max_sl = is3d ? std::max(1u, (uint32_t)base.depth >> e.mip) : total_sl;
                if (e.slice >= max_sl) continue;
                MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                if (e.is_color) {
                    id<MTLTexture> ct = base;
                    if (e.fmt != base.pixelFormat && bo3_mtl_can_view_as(base.pixelFormat, base.usage, e.fmt)) {
                        id<MTLTexture> v = t->get_or_create_view(e.fmt, base.textureType, 0, 0, 0, 0);
                        if (v) ct = v;
                    }
                    MTLRenderPassColorAttachmentDescriptor *ca = rpd.colorAttachments[0];
                    ca.texture = ct;
                    ca.level = e.mip;
                    if (is3d) { ca.slice = 0; ca.depthPlane = e.slice; }
                    else      { ca.slice = e.slice; }
                    ca.loadAction = MTLLoadActionClear;
                    ca.clearColor = MTLClearColorMake(e.color[0], e.color[1], e.color[2], e.color[3]);
                    ca.storeAction = MTLStoreActionStore;
                } else {
                    bool any = false;
                    if (e.aspects & BO3_ASPECT_COLOR_DEPTH) {
                        rpd.depthAttachment.texture = base;
                        rpd.depthAttachment.level = e.mip;
                        rpd.depthAttachment.slice = e.slice;
                        rpd.depthAttachment.loadAction = MTLLoadActionClear;
                        rpd.depthAttachment.clearDepth = e.depth;
                        rpd.depthAttachment.storeAction = MTLStoreActionStore;
                        any = true;
                    }
                    if ((e.aspects & BO3_ASPECT_STENCIL) && has_st) {
                        rpd.stencilAttachment.texture = base;
                        rpd.stencilAttachment.level = e.mip;
                        rpd.stencilAttachment.slice = e.slice;
                        rpd.stencilAttachment.loadAction = MTLLoadActionClear;
                        rpd.stencilAttachment.clearStencil = e.stencil;
                        rpd.stencilAttachment.storeAction = MTLStoreActionStore;
                        any = true;
                    }
                    if (!any) continue;
                }
                // Never requeue a failed clear behind subsequent reads/writes (would overwrite newer data).
                id<MTLRenderCommandEncoder> enc = cmd_buf ? [cmd_buf renderCommandEncoderWithDescriptor:rpd] : nil;
                if (!enc) continue;
                any_encoded = true;
                pass_splits++;
                if (perf_on) { perf_account_pass(rpd); perf_clr_materialized++; }
                [enc endEncoding];
            }
            if (any_encoded) touch(&t->res);
        }
    }
    unlist_if_clean(t);
}

void Bo3MetalContext::materialize_all_clears() {
    if (pending_clear_texs.empty()) return;
    std::vector<Bo3MetalTexture *> list = pending_clear_texs; // materialize_clears() edits the list
    for (Bo3MetalTexture *t : list) materialize_clears(t, nullptr);
}

// The range is about to be fully overwritten (copy / upload / resolve / UAV clear destination):
// overlapping deferred clears are superseded and simply dropped.
void Bo3MetalContext::drop_clears(Bo3MetalTexture *t, const Bo3SubRange &r) {
    if (!t || t->pending_clears.empty()) return;
    for (size_t i = 0; i < t->pending_clears.size();) {
        Bo3TexPendingClear &e = t->pending_clears[i];
        if (views_overlap(r, clear_entry_range(t, e))) {
            if (!e.is_color) e.aspects &= (uint8_t)~r.aspect;
            if (e.is_color || e.aspects == 0) {
                e = t->pending_clears.back();
                t->pending_clears.pop_back();
                continue;
            }
        }
        i++;
    }
    unlist_if_clean(t);
}

void Bo3MetalContext::materialize_res(Bo3MetalResource *r, const Bo3SubRange &range) {
    if (!r || pending_clear_texs.empty() || r->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER) return;
    Bo3MetalTexture *t = (Bo3MetalTexture *)r;
    if (!t->pending_clears.empty() && has_clear_overlap(t, range)) materialize_clears(t, &range);
}

static Bo3SubRange whole_range(Bo3MetalResource *r) {
    Bo3SubRange s;
    s.res = r;
    return s;
}

// Every SRV / UAV the next draw (VS+PS+OM UAVs) or dispatch (CS) actually reads: deferred clears
// on them must land first. Filtered by active shader binding masks so stale unused SRVs never
// trigger spurious clear materialization / pass splits. O(1) when no texture has a deferred clear.
void Bo3MetalContext::materialize_srv_uav_reads(Bo3ShaderStage stage) {
    if (pending_clear_texs.empty()) return;
    auto collect_masks = [](const Bo3MetalShader *sh, uint64_t &slo, uint64_t &shi, uint64_t &um) {
        slo = shi = um = 0;
        if (!sh || !sh->valid) return;
        slo |= sh->bindings.srv_mask_lo;
        shi |= sh->bindings.srv_mask_hi;
        um  |= sh->bindings.uav_mask;
        for (int v = 0; v < 2; v++) {
            if (sh->fallback_var[v].valid) {
                slo |= sh->fallback_var[v].bindings.srv_mask_lo;
                shi |= sh->fallback_var[v].bindings.srv_mask_hi;
                um  |= sh->fallback_var[v].bindings.uav_mask;
            }
        }
    };
    auto scan_srvs = [&](Bo3MetalSRV **arr, uint64_t lo, uint64_t hi) {
        for (uint64_t m = lo; m && !pending_clear_texs.empty(); m &= m - 1) {
            int i = __builtin_ctzll(m);
            Bo3MetalSRV *v = arr[i];
            if (v && !v->is_buffer && v->resource) materialize_res(v->resource, range_of_srv(v));
        }
        for (uint64_t m = hi; m && !pending_clear_texs.empty(); m &= m - 1) {
            int i = 64 + __builtin_ctzll(m);
            Bo3MetalSRV *v = arr[i];
            if (v && !v->is_buffer && v->resource) materialize_res(v->resource, range_of_srv(v));
        }
    };
    auto scan_uavs = [&](Bo3MetalUAV **arr, int cap, uint64_t mask) {
        for (uint64_t m = mask; m && !pending_clear_texs.empty(); m &= m - 1) {
            int i = __builtin_ctzll(m);
            if (i >= cap) break;
            Bo3MetalUAV *u = arr[i];
            if (u && !u->is_buffer && u->resource) materialize_res(u->resource, range_of_uav(u));
        }
    };
    if (stage == BO3_STAGE_CS) {
        uint64_t slo, shi, um;
        collect_masks(cs, slo, shi, um);
        scan_srvs(cs_srv, slo, shi);
        scan_uavs(cs_uav, 64, um);
    } else {
        uint64_t vslo, vshi, vum, pslo, pshi, pum;
        collect_masks(vs, vslo, vshi, vum);
        collect_masks(ps, pslo, pshi, pum);
        scan_srvs(vs_srv, vslo, vshi);
        scan_srvs(ps_srv, pslo, pshi);
        scan_uavs(om_uavs, 8, (vum | pum) & 0xffull);
    }
}

void Bo3MetalContext::release_clear_list() {
    std::vector<Bo3MetalTexture *> list;
    list.swap(pending_clear_texs);
    for (Bo3MetalTexture *t : list) {
        t->pending_clears.clear();
        t->in_clear_list = false;
        t->res.com.release();
    }
}

void Bo3MetalContext::ensure_clear_uav_psos() {
    if (clear_uav_psos_init) return;
    clear_uav_psos_init = true;
    @autoreleasepool {
        NSString *src = @R"(
#include <metal_stdlib>
using namespace metal;

// Buffer UAV clears: `pat` holds one packed element pattern (period bytes/dwords), written
// starting at an absolute DWORD (clear_uav_buf) or BYTE (clear_uav_bytes) offset.
struct ClearBufParams { uint4 pat; uint off; uint count; uint period; uint _pad; };
kernel void clear_uav_buf(device uint *dst [[buffer(0)]], constant ClearBufParams &p [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    if (gid >= p.count) return;
    dst[p.off + gid] = p.pat[gid % p.period];
}
kernel void clear_uav_bytes(device uchar *dst [[buffer(0)]], constant ClearBufParams &p [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    if (gid >= p.count) return;
    uint i = gid % p.period;
    dst[p.off + gid] = uchar((p.pat[i >> 2] >> ((i & 3u) * 8u)) & 0xffu);
}
struct CopyBytesParams { uint src_off; uint dst_off; uint size; uint _pad; };
kernel void copy_bytes_unaligned(device const uchar *src [[buffer(0)]], device uchar *dst [[buffer(1)]],
                                 constant CopyBytesParams &p [[buffer(2)]], uint gid [[thread_position_in_grid]]) {
    if (gid < p.size) dst[p.dst_off + gid] = src[p.src_off + gid];
}

kernel void clear_1d_f(texture1d<float, access::write> t [[texture(0)]], constant float4 &v [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    if (gid < t.get_width()) t.write(v, gid);
}
kernel void clear_1d_u(texture1d<uint, access::write> t [[texture(0)]], constant uint4 &v [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    if (gid < t.get_width()) t.write(v, gid);
}
kernel void clear_1d_i(texture1d<int, access::write> t [[texture(0)]], constant int4 &v [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    if (gid < t.get_width()) t.write(v, gid);
}

kernel void clear_1da_f(texture1d_array<float, access::write> t [[texture(0)]], constant float4 &v [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_array_size()) t.write(v, gid.x, gid.y);
}
kernel void clear_1da_u(texture1d_array<uint, access::write> t [[texture(0)]], constant uint4 &v [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_array_size()) t.write(v, gid.x, gid.y);
}
kernel void clear_1da_i(texture1d_array<int, access::write> t [[texture(0)]], constant int4 &v [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_array_size()) t.write(v, gid.x, gid.y);
}

kernel void clear_2d_f(texture2d<float, access::write> t [[texture(0)]], constant float4 &v [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height()) t.write(v, gid);
}
kernel void clear_2d_u(texture2d<uint, access::write> t [[texture(0)]], constant uint4 &v [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height()) t.write(v, gid);
}
kernel void clear_2d_i(texture2d<int, access::write> t [[texture(0)]], constant int4 &v [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height()) t.write(v, gid);
}

kernel void clear_2da_f(texture2d_array<float, access::write> t [[texture(0)]], constant float4 &v [[buffer(0)]], uint3 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height() && gid.z < t.get_array_size()) t.write(v, gid.xy, gid.z);
}
kernel void clear_2da_u(texture2d_array<uint, access::write> t [[texture(0)]], constant uint4 &v [[buffer(0)]], uint3 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height() && gid.z < t.get_array_size()) t.write(v, gid.xy, gid.z);
}
kernel void clear_2da_i(texture2d_array<int, access::write> t [[texture(0)]], constant int4 &v [[buffer(0)]], uint3 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height() && gid.z < t.get_array_size()) t.write(v, gid.xy, gid.z);
}

kernel void clear_3d_f(texture3d<float, access::write> t [[texture(0)]], constant float4 &v [[buffer(0)]], uint3 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height() && gid.z < t.get_depth()) t.write(v, gid);
}
kernel void clear_3d_u(texture3d<uint, access::write> t [[texture(0)]], constant uint4 &v [[buffer(0)]], uint3 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height() && gid.z < t.get_depth()) t.write(v, gid);
}
kernel void clear_3d_i(texture3d<int, access::write> t [[texture(0)]], constant int4 &v [[buffer(0)]], uint3 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height() && gid.z < t.get_depth()) t.write(v, gid);
}
)";
        NSError *err = nil;
        id<MTLLibrary> lib = [device->mtl_dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) return;
        auto mk = [&](NSString *fn_name) -> id<MTLComputePipelineState> {
            id<MTLFunction> fn = [lib newFunctionWithName:fn_name];
            return fn ? bo3_pso_create_compute(device->mtl_dev, fn, nil, true) : nil;
        };
        clear_uav_buf_pso      = mk(@"clear_uav_buf");
        clear_uav_bytes_pso    = mk(@"clear_uav_bytes");
        byte_copy_pso          = mk(@"copy_bytes_unaligned");
        clear_uav_1d_pso[0]    = mk(@"clear_1d_f");  clear_uav_1d_pso[1]    = mk(@"clear_1d_u");  clear_uav_1d_pso[2]    = mk(@"clear_1d_i");
        clear_uav_1d_arr_pso[0]= mk(@"clear_1da_f"); clear_uav_1d_arr_pso[1]= mk(@"clear_1da_u"); clear_uav_1d_arr_pso[2]= mk(@"clear_1da_i");
        clear_uav_2d_pso[0]    = mk(@"clear_2d_f");  clear_uav_2d_pso[1]    = mk(@"clear_2d_u");  clear_uav_2d_pso[2]    = mk(@"clear_2d_i");
        clear_uav_2d_arr_pso[0]= mk(@"clear_2da_f"); clear_uav_2d_arr_pso[1]= mk(@"clear_2da_u"); clear_uav_2d_arr_pso[2]= mk(@"clear_2da_i");
        clear_uav_3d_pso[0]    = mk(@"clear_3d_f");  clear_uav_3d_pso[1]    = mk(@"clear_3d_u");  clear_uav_3d_pso[2]    = mk(@"clear_3d_i");
    }
}

void Bo3MetalContext::encode_buffer_copy(id<MTLBuffer> sbuf, uint64_t soff,
                                         id<MTLBuffer> dbuf, uint64_t doff, uint64_t sz) {
    if (!sbuf || !dbuf || sz == 0) return;
    if (soff >= sbuf.length || doff >= dbuf.length) return;
    sz = std::min<uint64_t>(sz, std::min<uint64_t>(sbuf.length - soff, dbuf.length - doff));
    if (sz == 0) return;
    if (((soff | doff | sz) & 3ULL) == 0) {
        ensure_blit_encoder();
        [blit_enc copyFromBuffer:sbuf sourceOffset:soff toBuffer:dbuf destinationOffset:doff size:sz];
    } else {
        // Safe unaligned (<4B or non-4B-aligned) GPU-ordered copy via compute kernel
        ensure_clear_uav_psos();
        if (byte_copy_pso && soff <= 0xffffffffULL && doff <= 0xffffffffULL && sz <= 0xffffffffULL) {
            struct { uint32_t s, d, n, pad; } p = { (uint32_t)soff, (uint32_t)doff, (uint32_t)sz, 0 };
            ensure_compute_encoder();
            [compute_enc setComputePipelineState:byte_copy_pso];
            [compute_enc setBuffer:sbuf offset:0 atIndex:0];
            [compute_enc setBuffer:dbuf offset:0 atIndex:1];
            [compute_enc setBytes:&p length:sizeof(p) atIndex:2];
            [compute_enc dispatchThreads:MTLSizeMake((NSUInteger)sz, 1, 1)
                   threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>((NSUInteger)sz, 64), 1, 1)];
        } else {
            ensure_blit_encoder();
            [blit_enc copyFromBuffer:sbuf sourceOffset:soff toBuffer:dbuf destinationOffset:doff size:sz];
        }
    }
}

void Bo3MetalContext::encode_ordered_u32_write(id<MTLBuffer> dst, uint64_t dst_off, uint32_t val) {
    if (!dst) return;
    id<MTLBuffer> rbuf = nil;
    uint64_t roff = 0;
    void *rptr = nullptr;
    if (upload_ring.alloc(4, 16, pending_fence(), &rbuf, &roff, &rptr)) {
        *(uint32_t *)rptr = val;
        ensure_blit_encoder();
        [blit_enc copyFromBuffer:rbuf sourceOffset:roff toBuffer:dst destinationOffset:dst_off size:4];
    } else {
        // Ring overflow: allocate temporary shared staging buffer and encode ordered GPU blit!
        id<MTLBuffer> tmp = [device->mtl_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        if (tmp) {
            *(uint32_t *)tmp.contents = val;
            ensure_blit_encoder();
            [blit_enc copyFromBuffer:tmp sourceOffset:0 toBuffer:dst destinationOffset:dst_off size:4];
        }
    }
}

// A non-dynamic buffer renamed into the upload ring by a whole-buffer UpdateSubresource must be
// folded back (GPU-ordered blit) before any partial update / GPU write targets its owned mtl_buf.
void Bo3MetalContext::materialize_renamed(Bo3MetalBuffer *b) {
    if (!b || b->is_dynamic || !b->dyn_buf || b->dyn_buf == b->mtl_buf) return;
    id<MTLBuffer> src = b->dyn_buf;
    uint64_t soff = b->dyn_offset;
    touch_buf(b); // while dyn_epoch is still set: extends the ring slot fence over this blit read
    b->clear_dyn();
    encode_buffer_copy(src, soff, b->mtl_buf, 0, b->desc.ByteWidth);
}

void Bo3MetalContext::ensure_cmd_buf() {
    if (!cmd_buf) {
        cmd_buf = [device->mtl_queue commandBuffer];
        cmd_buf.label = @"BO3_Frame";
    }
}

void Bo3MetalContext::reset_enc_state_cache() {
    enc_pso = nil;
    enc_dss = nil;
    enc_stencil_ref = 0;
    enc_stencil_ref_valid = false;
    for (int i = 0; i < 31; i++) {
        enc_vs_buf[i] = nil; enc_ps_buf[i] = nil;
        enc_vs_off[i] = 0;   enc_ps_off[i] = 0;
    }
    for (int i = 0; i < 32; i++) { enc_vs_tex[i] = nil; enc_ps_tex[i] = nil; }
    for (int i = 0; i < 16; i++) { enc_vs_samp[i] = nil; enc_ps_samp[i] = nil; }
    enc_vs_bufinfo_idx = 0xff;
    enc_ps_bufinfo_idx = 0xff;
}

void Bo3MetalContext::enc_set_pso(id<MTLRenderPipelineState> pso) {
    if (pso == enc_pso) { if (perf_on) enc_state_skips++; return; }
    [render_enc setRenderPipelineState:pso];
    enc_pso = pso;
}

void Bo3MetalContext::enc_set_dss(id<MTLDepthStencilState> dss, uint32_t ref) {
    if (dss != enc_dss || !enc_stencil_ref_valid) { // fresh encoder: always (re)establish both
        [render_enc setDepthStencilState:dss];
        enc_dss = dss;
    } else if (perf_on) {
        enc_state_skips++;
    }
    if (!enc_stencil_ref_valid || ref != enc_stencil_ref) {
        [render_enc setStencilReferenceValue:ref];
        enc_stencil_ref = ref;
        enc_stencil_ref_valid = true;
    } else if (perf_on) {
        enc_state_skips++;
    }
}

// A fresh render encoder starts with every slot unbound (nil), which is exactly the reset cache
// state, so (nil, 0) compares are correct. Same buffer + new offset -> set*BufferOffset only.
void Bo3MetalContext::enc_set_buffer(bool vs, uint32_t idx, id<MTLBuffer> buf, uint64_t off) {
    uint8_t &bi = vs ? enc_vs_bufinfo_idx : enc_ps_bufinfo_idx;
    if (bi == idx) bi = 0xff; // a real buffer replaces the cached inline bufferInfo bytes
    if (idx < 31) {
        __strong id<MTLBuffer> &cb = vs ? enc_vs_buf[idx] : enc_ps_buf[idx];
        uint64_t &co = vs ? enc_vs_off[idx] : enc_ps_off[idx];
        if (cb == buf && co == off) { if (perf_on) enc_state_skips++; return; }
        if (cb == buf && buf != nil) {
            if (vs) [render_enc setVertexBufferOffset:off atIndex:idx];
            else    [render_enc setFragmentBufferOffset:off atIndex:idx];
            co = off;
            return;
        }
        cb = buf;
        co = off;
    }
    if (vs) [render_enc setVertexBuffer:buf offset:off atIndex:idx];
    else    [render_enc setFragmentBuffer:buf offset:off atIndex:idx];
}

void Bo3MetalContext::enc_set_bytes(bool vs, const void *bytes, size_t len, uint32_t idx) {
    if (vs) [render_enc setVertexBytes:bytes length:len atIndex:idx];
    else    [render_enc setFragmentBytes:bytes length:len atIndex:idx];
    uint8_t &bi = vs ? enc_vs_bufinfo_idx : enc_ps_bufinfo_idx;
    if (bi == idx) bi = 0xff;
    if (idx < 31) { // inline bytes replace the slot's buffer binding -> invalidate the cache entry
        (vs ? enc_vs_buf[idx] : enc_ps_buf[idx]) = nil;
        (vs ? enc_vs_off[idx] : enc_ps_off[idx]) = UINT64_MAX;
    }
}

void Bo3MetalContext::enc_set_texture(bool vs, uint32_t idx, id<MTLTexture> tex) {
    if (idx < 32) {
        __strong id<MTLTexture> &ct = vs ? enc_vs_tex[idx] : enc_ps_tex[idx];
        if (ct == tex) { if (perf_on) enc_state_skips++; return; }
        ct = tex;
    }
    if (vs) [render_enc setVertexTexture:tex atIndex:idx];
    else    [render_enc setFragmentTexture:tex atIndex:idx];
}

void Bo3MetalContext::enc_set_sampler(bool vs, uint32_t idx, id<MTLSamplerState> smp) {
    if (idx < 16) {
        __strong id<MTLSamplerState> &cs = vs ? enc_vs_samp[idx] : enc_ps_samp[idx];
        if (cs == smp) { if (perf_on) enc_state_skips++; return; }
        cs = smp;
    }
    if (vs) [render_enc setVertexSamplerState:smp atIndex:idx];
    else    [render_enc setFragmentSamplerState:smp atIndex:idx];
}

void Bo3MetalContext::end_active_encoder(Bo3SplitReason reason) {
    if (enc_mode == ENC_RENDER && render_enc) {
        // A1a: every ensure_render_pass() attachment was opened with MTLStoreActionUnknown
        for (uint32_t i = 0; i < 8; i++) {
            if (!active_rt_tex[i]) continue;
            [render_enc setColorStoreAction:active_rt_store[i] atIndex:i];
            if (perf_on && active_rt_store[i] == MTLStoreActionStore) perf_store_bytes += active_rt_bytes[i];
        }
        if (active_ds_tex) {
            [render_enc setDepthStoreAction:active_ds_store];
            if (perf_on && active_ds_store == MTLStoreActionStore) perf_store_bytes += active_ds_bytes;
            if (active_dsv_has_stencil) {
                [render_enc setStencilStoreAction:active_st_store];
                if (perf_on && active_st_store == MTLStoreActionStore) perf_store_bytes += active_st_bytes;
            }
        }
        [render_enc endEncoding];
        render_enc = nil;
        reset_enc_state_cache(); // ARC-release every cached binding; never compare across encoders
        for (uint32_t i = 0; i < 8; i++) {
            if (active_rt_res[i]) { active_rt_res[i]->res.com.release(); active_rt_res[i] = nullptr; }
        }
        if (active_ds_res) { active_ds_res->res.com.release(); active_ds_res = nullptr; }
        om_dirty = true;
        if (perf_on) perf_split[reason < SPLIT_COUNT ? reason : SPLIT_OTH]++;
    } else if (enc_mode == ENC_COMPUTE && compute_enc) {
        [compute_enc endEncoding];
        compute_enc = nil;
    } else if (enc_mode == ENC_BLIT && blit_enc) {
        [blit_enc endEncoding];
        blit_enc = nil;
    }
    enc_mode = ENC_NONE;
}

void Bo3MetalContext::ensure_blit_encoder() {
    if (enc_mode == ENC_BLIT && blit_enc) return;
    end_active_encoder(SPLIT_BLIT);
    ensure_cmd_buf();
    blit_enc = [cmd_buf blitCommandEncoder];
    enc_mode = ENC_BLIT;
}

void Bo3MetalContext::ensure_compute_encoder() {
    if (enc_mode == ENC_COMPUTE && compute_enc) return;
    end_active_encoder(SPLIT_CMP);
    ensure_cmd_buf();
    compute_enc = [cmd_buf computeCommandEncoder];
    enc_mode = ENC_COMPUTE;
}

// A2: blit encoder of the per-frame upload command buffer. Never touches the open render pass.
id<MTLBlitCommandEncoder> Bo3MetalContext::hoist_blit_encoder() {
    if (upload_blit_enc) return upload_blit_enc;
    if (!upload_cmd_buf) {
        upload_cmd_buf = [device->mtl_queue commandBuffer];
        if (!upload_cmd_buf) return nil;
        upload_cmd_buf.label = @"BO3_Uploads";
    }
    upload_blit_enc = [upload_cmd_buf blitCommandEncoder];
    return upload_blit_enc;
}

static id<MTLTexture> resolve_rtv_mtl_texture(Bo3MetalRTV *rtv) {
    if (!rtv || !rtv->resource || rtv->resource->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER) return nil;
    Bo3MetalTexture *tex = (Bo3MetalTexture *)rtv->resource;
    id<MTLTexture> mt = tex->current_mtl_texture();
    if (!mt) return nil;
    if (rtv->mtl_format != mt.pixelFormat && bo3_mtl_can_view_as(mt.pixelFormat, mt.usage, rtv->mtl_format)) {
        mt = tex->get_or_create_view(rtv->mtl_format, mt.textureType, 0, 0, 0, 0);
    }
    return mt;
}

static bool same_render_targets(Bo3MetalContext *c) {
    if (c->active_rtv_count != c->rtv_count) return false;
    bool has_att = false;
    for (uint32_t i = 0; i < c->rtv_count && i < 8; i++) {
        id<MTLTexture> want = resolve_rtv_mtl_texture(c->rtvs[i]);
        uint32_t wl = c->rtvs[i] ? c->rtvs[i]->mip_slice : 0;
        uint32_t ws = c->rtvs[i] ? c->rtvs[i]->array_slice : 0;
        uint32_t wa = c->rtvs[i] ? c->rtvs[i]->array_size : 0;
        if (c->active_rt_tex[i] != want || c->active_rt_lvl[i] != wl ||
            c->active_rt_sl[i] != ws || c->active_rt_arr_sz[i] != wa) return false;
        if (want) has_att = true;
    }
    id<MTLTexture> want_ds = nil;
    uint32_t wdl = 0, wds = 0, wda = 0, wdf = 0;
    if (c->dsv && c->dsv->resource && c->dsv->resource->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        want_ds = ((Bo3MetalTexture *)c->dsv->resource)->current_mtl_texture();
        wdl = c->dsv->mip_slice;
        wds = c->dsv->array_slice;
        wda = c->dsv->array_size;
        wdf = c->dsv->desc.Flags;
        if (want_ds) has_att = true;
    }
    if (c->active_ds_tex != want_ds || c->active_ds_lvl != wdl || c->active_ds_sl != wds ||
        c->active_ds_arr_sz != wda || c->active_ds_flags != wdf) return false;
    if (c->active_uav_only != (!has_att)) return false;
    return true;
}

bool Bo3MetalContext::scissor_is_empty() const {
    if (!rs_state || !rs_state->desc.ScissorEnable || scissor_count == 0 || pass_w == 0 || pass_h == 0) return false;
    int32_t x0 = std::clamp(scissors[0].left,   0, (int32_t)pass_w);
    int32_t y0 = std::clamp(scissors[0].top,    0, (int32_t)pass_h);
    int32_t x1 = std::clamp(scissors[0].right,  x0, (int32_t)pass_w);
    int32_t y1 = std::clamp(scissors[0].bottom, y0, (int32_t)pass_h);
    return (x1 <= x0 || y1 <= y0);
}

void Bo3MetalContext::apply_live_scissor() {
    if (enc_mode != ENC_RENDER || !render_enc || pass_w == 0 || pass_h == 0) return;
    if (rs_state && rs_state->desc.ScissorEnable && scissor_count > 0) {
        int32_t x0 = std::clamp(scissors[0].left,   0, (int32_t)pass_w);
        int32_t y0 = std::clamp(scissors[0].top,    0, (int32_t)pass_h);
        int32_t x1 = std::clamp(scissors[0].right,  x0, (int32_t)pass_w);
        int32_t y1 = std::clamp(scissors[0].bottom, y0, (int32_t)pass_h);
        if (x1 > x0 && y1 > y0) {
            MTLScissorRect sr = { (NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0) };
            [render_enc setScissorRect:sr];
        }
    } else {
        MTLScissorRect sr = { 0, 0, (NSUInteger)pass_w, (NSUInteger)pass_h };
        [render_enc setScissorRect:sr];
    }
}

// Deferred clear (A1b) on any currently ACTIVE attachment subresource of the open render pass?
static bool active_attachments_pending(const Bo3MetalContext *c) {
    if (c->pending_clear_texs.empty()) return false;
    for (uint32_t i = 0; i < 8; i++) {
        Bo3MetalTexture *t = c->active_rt_res[i];
        if (!t || t->pending_clears.empty()) continue;
        Bo3SubRange r;
        r.res = &t->res; r.mip0 = c->active_rt_lvl[i]; r.mip_cnt = 1;
        r.sl0 = c->active_rt_sl[i]; r.sl_cnt = std::max(1u, c->active_rt_arr_sz[i]);
        r.aspect = BO3_ASPECT_COLOR_DEPTH;
        if (c->has_clear_overlap(t, r)) return true;
    }
    if (Bo3MetalTexture *t = c->active_ds_res) {
        if (!t->pending_clears.empty()) {
            Bo3SubRange r;
            r.res = &t->res; r.mip0 = c->active_ds_lvl; r.mip_cnt = 1;
            r.sl0 = c->active_ds_sl; r.sl_cnt = std::max(1u, c->active_ds_arr_sz);
            if (c->has_clear_overlap(t, r)) return true;
        }
    }
    return false;
}

bool Bo3MetalContext::ensure_render_pass() {
    // TBDR optimization: keep the open render pass while the bound targets are unchanged.
    // A5: om_dirty == false means nothing touched the OM bindings since this pass was validated
    // (deferred clears on an active attachment always end the pass, see ClearRenderTargetView).
    if (enc_mode == ENC_RENDER && render_enc) {
        if (!om_dirty) return true;
        if (same_render_targets(this) && !active_attachments_pending(this)) {
            om_dirty = false;
            return true;
        }
    }

    end_active_encoder(SPLIT_TGT);
    ensure_cmd_buf();

    // Layered rendering: when any bound RTV/DSV spans > 1 array slice, expose the minimum common
    // layer count so SV_RenderTargetArrayIndex can address every slice (default layer stays 0).
    uint32_t min_layers = 0;
    bool any_layered = false;
    {
        for (uint32_t i = 0; i < rtv_count && i < 8; i++) {
            Bo3MetalRTV *rtv = rtvs[i];
            if (!rtv || !rtv->resource || rtv->resource->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER ||
                rtv->resource->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D) continue;
            uint32_t a = std::max(1u, rtv->array_size);
            if (a > 1) any_layered = true;
            min_layers = (min_layers == 0) ? a : std::min(min_layers, a);
        }
        if (dsv && dsv->resource && dsv->resource->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
            uint32_t a = std::max(1u, dsv->array_size);
            if (a > 1) any_layered = true;
            min_layers = (min_layers == 0) ? a : std::min(min_layers, a);
        }
    }

    // A1b: deferred clears on the subresources about to be attached either fold into the load action
    // below (exact single-layer subresource, same view format) or are materialized right now.
    if (!pending_clear_texs.empty()) {
        for (uint32_t i = 0; i < rtv_count && i < 8; i++) {
            Bo3MetalRTV *rtv = rtvs[i];
            if (!rtv || !rtv->resource || rtv->resource->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER) continue;
            Bo3MetalTexture *t = (Bo3MetalTexture *)rtv->resource;
            if (t->pending_clears.empty()) continue;
            const bool is3d = rtv->resource->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D;
            Bo3SubRange r;
            r.res = &t->res; r.mip0 = rtv->mip_slice; r.mip_cnt = 1;
            r.sl0 = rtv->array_slice;
            r.sl_cnt = (any_layered && !is3d) ? std::max(1u, min_layers) : 1u;
            r.aspect = BO3_ASPECT_COLOR_DEPTH;
            if (!has_clear_overlap(t, r)) continue;
            int idx = find_clear(t, rtv->mip_slice, rtv->array_slice);
            id<MTLTexture> mt = resolve_rtv_mtl_texture(rtv);
            const bool foldable = idx >= 0 && !any_layered && mt &&
                                  t->pending_clears[(size_t)idx].is_color &&
                                  t->pending_clears[(size_t)idx].fmt == mt.pixelFormat;
            if (!foldable) materialize_clears(t, &r);
        }
        if (dsv && dsv->resource && dsv->resource->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
            Bo3MetalTexture *t = (Bo3MetalTexture *)dsv->resource;
            if (!t->pending_clears.empty() && any_layered) {
                Bo3SubRange r;
                r.res = &t->res; r.mip0 = dsv->mip_slice; r.mip_cnt = 1;
                r.sl0 = dsv->array_slice; r.sl_cnt = std::max(1u, min_layers);
                materialize_clears(t, &r);
            }
        }
    }

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    uint32_t pw = 0, ph = 0;
    bool has_any_att = false;
    bool uav_only_pass = false;
    id<MTLTexture> new_rt_tex[8] = {nil};
    uint32_t new_rt_lvl[8] = {0}, new_rt_sl[8] = {0}, new_rt_arr_sz[8] = {0};
    MTLPixelFormat new_rt_fmt[8] = {MTLPixelFormatInvalid};
    Bo3MetalTexture *new_rt_res[8] = {nullptr};
    // Folded deferred clears, removed only once the encoder exists (never lose a clear)
    struct Fold { Bo3MetalTexture *t; uint32_t mip, slice; uint8_t aspects; };
    Fold folds[9];
    uint32_t n_folds = 0;
    const uint32_t layers = (any_layered && min_layers >= 1) ? min_layers : 1u;

    for (uint32_t i = 0; i < rtv_count && i < 8; i++) {
        Bo3MetalRTV *rtv = rtvs[i];
        id<MTLTexture> mt = resolve_rtv_mtl_texture(rtv);
        if (!mt) continue;
        Bo3MetalTexture *t = (Bo3MetalTexture *)rtv->resource;
        MTLRenderPassColorAttachmentDescriptor *ca = rpd.colorAttachments[i];
        ca.texture = mt;
        ca.level = rtv->mip_slice;
        if (mt.textureType == MTLTextureType3D) {
            ca.slice = 0;
            ca.depthPlane = rtv->array_slice;
        } else {
            ca.slice = rtv->array_slice;
        }
        int idx = t->pending_clears.empty() ? -1 : find_clear(t, rtv->mip_slice, rtv->array_slice);
        if (idx >= 0 && t->pending_clears[(size_t)idx].is_color) {
            const Bo3TexPendingClear &e = t->pending_clears[(size_t)idx];
            ca.loadAction = MTLLoadActionClear;
            ca.clearColor = MTLClearColorMake(e.color[0], e.color[1], e.color[2], e.color[3]);
            folds[n_folds++] = Fold{t, e.mip, e.slice, BO3_ASPECT_ALL};
        } else {
            ca.loadAction = MTLLoadActionLoad;
        }
        ca.storeAction = MTLStoreActionUnknown; // A1a: final action chosen at end_active_encoder()
        new_rt_tex[i] = mt;
        new_rt_lvl[i] = rtv->mip_slice;
        new_rt_sl[i]  = rtv->array_slice;
        new_rt_arr_sz[i] = rtv->array_size;
        new_rt_fmt[i] = mt.pixelFormat;
        new_rt_res[i] = t;
        uint32_t att_w = std::max(1u, (uint32_t)mt.width  >> rtv->mip_slice);
        uint32_t att_h = std::max(1u, (uint32_t)mt.height >> rtv->mip_slice);
        pw = (pw == 0) ? att_w : std::min(pw, att_w);
        ph = (ph == 0) ? att_h : std::min(ph, att_h);
        has_any_att = true;
    }

    id<MTLTexture> new_ds_tex = nil;
    Bo3MetalTexture *new_ds_res = nullptr;
    uint32_t new_ds_lvl = 0, new_ds_sl = 0, new_ds_arr_sz = 0, new_ds_flags = 0;
    if (dsv && dsv->resource && dsv->resource->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalTexture *dtex = (Bo3MetalTexture *)dsv->resource;
        id<MTLTexture> dt = dtex->current_mtl_texture();
        if (dt) {
            int idx = dtex->pending_clears.empty() ? -1 : find_clear(dtex, dsv->mip_slice, dsv->array_slice);
            const Bo3TexPendingClear *e = (idx >= 0 && !dtex->pending_clears[(size_t)idx].is_color)
                                          ? &dtex->pending_clears[(size_t)idx] : nullptr;
            uint8_t folded = 0;
            rpd.depthAttachment.texture = dt;
            rpd.depthAttachment.level = dsv->mip_slice;
            rpd.depthAttachment.slice = dsv->array_slice;
            if (e && (e->aspects & BO3_ASPECT_COLOR_DEPTH)) {
                rpd.depthAttachment.loadAction = MTLLoadActionClear;
                rpd.depthAttachment.clearDepth = e->depth;
                folded |= BO3_ASPECT_COLOR_DEPTH;
            } else {
                rpd.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            // Read-only DSVs still Store (never DontCare): writes are disabled by the read-only
            // MTLDepthStencilState variants, the attachment contents must survive.
            rpd.depthAttachment.storeAction = MTLStoreActionUnknown;

            if (dsv->has_stencil) {
                rpd.stencilAttachment.texture = dt;
                rpd.stencilAttachment.level = dsv->mip_slice;
                rpd.stencilAttachment.slice = dsv->array_slice;
                if (e && (e->aspects & BO3_ASPECT_STENCIL)) {
                    rpd.stencilAttachment.loadAction = MTLLoadActionClear;
                    rpd.stencilAttachment.clearStencil = e->stencil;
                    folded |= BO3_ASPECT_STENCIL;
                } else {
                    rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
                }
                rpd.stencilAttachment.storeAction = MTLStoreActionUnknown;
            }
            if (folded) folds[n_folds++] = Fold{dtex, dsv->mip_slice, dsv->array_slice, folded};
            new_ds_tex = dt;
            new_ds_res = dtex;
            new_ds_lvl = dsv->mip_slice;
            new_ds_sl  = dsv->array_slice;
            new_ds_arr_sz = dsv->array_size;
            new_ds_flags  = dsv->desc.Flags;
            uint32_t att_w = std::max(1u, (uint32_t)dt.width  >> dsv->mip_slice);
            uint32_t att_h = std::max(1u, (uint32_t)dt.height >> dsv->mip_slice);
            pw = (pw == 0) ? att_w : std::min(pw, att_w);
            ph = (ph == 0) ? att_h : std::min(ph, att_h);
            has_any_att = true;
        }
    }

    if (any_layered && min_layers >= 1) rpd.renderTargetArrayLength = min_layers;

    // Support attachmentless UAV-only render passes (0 RTVs, no DSV, >=1 OM UAV)
    if (!has_any_att) {
        bool has_om_uav = false;
        uint32_t uav_w = 0, uav_h = 0;
        for (int i = 0; i < 8; i++) {
            if (om_uavs[i]) {
                has_om_uav = true;
                if (!om_uavs[i]->is_buffer && om_uavs[i]->mtl_tex && uav_w == 0) {
                    uav_w = (uint32_t)om_uavs[i]->mtl_tex.width;
                    uav_h = (uint32_t)om_uavs[i]->mtl_tex.height;
                }
            }
        }
        if (!has_om_uav) return false;
        if (viewport_count > 0 && viewports[0].Width > 0 && viewports[0].Height > 0) {
            pw = std::max(1u, (uint32_t)(viewports[0].TopLeftX + viewports[0].Width));
            ph = std::max(1u, (uint32_t)(viewports[0].TopLeftY + viewports[0].Height));
        } else if (uav_w > 0 && uav_h > 0) {
            pw = uav_w;
            ph = uav_h;
        } else {
            pw = 1;
            ph = 1;
        }
        pw = std::clamp(pw, 1u, 16384u);
        ph = std::clamp(ph, 1u, 16384u);
        rpd.renderTargetWidth = pw;
        rpd.renderTargetHeight = ph;
        rpd.defaultRasterSampleCount = 1;
        uav_only_pass = true;
        has_any_att = true;
    }

    render_enc = [cmd_buf renderCommandEncoderWithDescriptor:rpd];
    if (!render_enc) return false;
    enc_mode = ENC_RENDER;
    reset_enc_state_cache();
    pass_splits++;
    if (perf_on) perf_account_pass(rpd); // loads only: stores are accounted at end_active_encoder()
    pass_w = pw;
    pass_h = ph;
    active_uav_only = uav_only_pass;

    // Folded deferred clears are now encoded as MTLLoadActionClear: drop them from the textures.
    // (Every folded texture is bound through an RTV/DSV that holds a ref, so it stays alive.)
    for (uint32_t k = 0; k < n_folds; k++) {
        Bo3MetalTexture *t = folds[k].t;
        int idx = find_clear(t, folds[k].mip, folds[k].slice);
        if (idx < 0) continue;
        Bo3TexPendingClear &e = t->pending_clears[(size_t)idx];
        if (!e.is_color) e.aspects &= (uint8_t)~folds[k].aspects;
        if (e.is_color || e.aspects == 0) {
            e = t->pending_clears.back();
            t->pending_clears.pop_back();
        }
        if (perf_on) perf_clr_folded++;
        unlist_if_clean(t);
    }

    active_rtv_count = rtv_count;
    for (uint32_t i = 0; i < 8; i++) {
        active_rt_tex[i]    = new_rt_tex[i];
        active_rt_lvl[i]    = new_rt_lvl[i];
        active_rt_sl[i]     = new_rt_sl[i];
        active_rt_arr_sz[i] = new_rt_arr_sz[i];
        active_rt_fmt[i]    = new_rt_fmt[i];
        active_rt_res[i]    = new_rt_res[i];
        if (active_rt_res[i]) active_rt_res[i]->res.com.add_ref();
        active_rt_store[i]  = MTLStoreActionStore;
        active_rt_bytes[i]  = 0;
        if (new_rt_tex[i]) {
            touch(&new_rt_res[i]->res);
            if (perf_on) {
                uint32_t bpp = bo3_mtl_color_bytes_per_pixel(new_rt_tex[i].pixelFormat);
                uint32_t ly = (new_rt_tex[i].textureType == MTLTextureType3D) ? 1u : layers;
                active_rt_bytes[i] = perf_attachment_bytes(new_rt_tex[i], new_rt_lvl[i], ly, bpp ? bpp : 4u);
            }
        }
    }
    active_ds_tex    = new_ds_tex;
    active_ds_res    = new_ds_res;
    if (active_ds_res) active_ds_res->res.com.add_ref();
    active_ds_lvl    = new_ds_lvl;
    active_ds_sl     = new_ds_sl;
    active_ds_arr_sz = new_ds_arr_sz;
    active_ds_flags  = new_ds_flags;
    active_dsv_has_stencil = (new_ds_tex != nil) && dsv && dsv->has_stencil;
    active_ds_store = MTLStoreActionStore;
    active_st_store = MTLStoreActionStore;
    active_ds_bytes = active_st_bytes = 0;
    if (new_ds_tex) {
        touch(&new_ds_res->res);
        if (perf_on) {
            active_ds_bytes = perf_attachment_bytes(new_ds_tex, new_ds_lvl, layers,
                                                    bo3_mtl_depth_bytes_per_pixel(new_ds_tex.pixelFormat));
            if (active_dsv_has_stencil) {
                active_st_bytes = perf_attachment_bytes(new_ds_tex, new_ds_lvl, layers,
                                                        bo3_mtl_stencil_bytes_per_pixel(new_ds_tex.pixelFormat));
            }
        }
    }
    active_layers = layers;
    pass_has_frag_uav_write = false;
    om_dirty = false;
    pso_dirty = true; // attachment formats / sample count may differ (cheap key memcmp re-validates)

    // Apply viewport, scissor, rasterizer, depth-stencil, blend factor to fresh encoder
    if (viewport_count > 0 && viewports[0].Width > 0 && viewports[0].Height > 0) {
        MTLViewport vp;
        vp.originX = viewports[0].TopLeftX;
        vp.originY = viewports[0].TopLeftY;
        vp.width   = viewports[0].Width;
        vp.height  = viewports[0].Height;
        vp.znear   = std::clamp(viewports[0].MinDepth, 0.0f, 1.0f);
        vp.zfar    = std::clamp(viewports[0].MaxDepth, 0.0f, 1.0f);
        [render_enc setViewport:vp];
    } else if (pass_w > 0 && pass_h > 0) {
        MTLViewport vp = { 0, 0, (double)pass_w, (double)pass_h, 0.0, 1.0 };
        [render_enc setViewport:vp];
    }

    apply_live_scissor();

    if (rs_state) {
        MTLCullMode cm = MTLCullModeNone;
        if (rs_state->desc.CullMode == 2) cm = MTLCullModeFront;
        else if (rs_state->desc.CullMode == 3) cm = MTLCullModeBack;
        [render_enc setCullMode:cm];
        [render_enc setFrontFacingWinding:rs_state->desc.FrontCounterClockwise ? MTLWindingCounterClockwise : MTLWindingClockwise];
        [render_enc setTriangleFillMode:(rs_state->desc.FillMode == 2) ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
        [render_enc setDepthClipMode:rs_state->desc.DepthClipEnable ? MTLDepthClipModeClip : MTLDepthClipModeClamp];
        [render_enc setDepthBias:(float)rs_state->desc.DepthBias
                      slopeScale:rs_state->desc.SlopeScaledDepthBias
                           clamp:rs_state->desc.DepthBiasClamp];
    } else {
        [render_enc setCullMode:MTLCullModeBack];
        [render_enc setFrontFacingWinding:MTLWindingClockwise];
        [render_enc setTriangleFillMode:MTLTriangleFillModeFill];
        [render_enc setDepthClipMode:MTLDepthClipModeClip];
        [render_enc setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    }

    enc_set_dss(select_active_dss(), ds_state ? stencil_ref : 0u);
    [render_enc setBlendColorRed:blend_factor[0] green:blend_factor[1] blue:blend_factor[2] alpha:blend_factor[3]];
    return true;
}

// =========================================================================
// PSO Cache & Resource Binding via Bo3BindingMap
// =========================================================================

static MTLVertexFormat reconcile_vertex_attr_format(MTLVertexFormat il_fmt, MTLVertexFormat vs_expected) {
    if (vs_expected == MTLVertexFormatUInt4) {
        switch (il_fmt) {
            case MTLVertexFormatChar:   return MTLVertexFormatUChar;
            case MTLVertexFormatChar2:  return MTLVertexFormatUChar2;
            case MTLVertexFormatChar3:  return MTLVertexFormatUChar3;
            case MTLVertexFormatChar4:  return MTLVertexFormatUChar4;
            case MTLVertexFormatShort:  return MTLVertexFormatUShort;
            case MTLVertexFormatShort2: return MTLVertexFormatUShort2;
            case MTLVertexFormatShort3: return MTLVertexFormatUShort3;
            case MTLVertexFormatShort4: return MTLVertexFormatUShort4;
            case MTLVertexFormatInt:    return MTLVertexFormatUInt;
            case MTLVertexFormatInt2:   return MTLVertexFormatUInt2;
            case MTLVertexFormatInt3:   return MTLVertexFormatUInt3;
            case MTLVertexFormatInt4:   return MTLVertexFormatUInt4;
            default: break;
        }
    } else if (vs_expected == MTLVertexFormatInt4) {
        switch (il_fmt) {
            case MTLVertexFormatUChar:   return MTLVertexFormatChar;
            case MTLVertexFormatUChar2:  return MTLVertexFormatChar2;
            case MTLVertexFormatUChar3:  return MTLVertexFormatChar3;
            case MTLVertexFormatUChar4:  return MTLVertexFormatChar4;
            case MTLVertexFormatUShort:  return MTLVertexFormatShort;
            case MTLVertexFormatUShort2: return MTLVertexFormatShort2;
            case MTLVertexFormatUShort3: return MTLVertexFormatShort3;
            case MTLVertexFormatUShort4: return MTLVertexFormatShort4;
            case MTLVertexFormatUInt:    return MTLVertexFormatInt;
            case MTLVertexFormatUInt2:   return MTLVertexFormatInt2;
            case MTLVertexFormatUInt3:   return MTLVertexFormatInt3;
            case MTLVertexFormatUInt4:   return MTLVertexFormatInt4;
            default: break;
        }
    }
    return il_fmt;
}

id<MTLRenderPipelineState> Bo3MetalContext::get_or_build_pso() {
    if (!vs || !bo3_shader_ensure_compiled(vs) || !vs->mtl_fn) return nil;
    if (ps && !bo3_shader_ensure_compiled(ps)) return nil;
    // A5 fast path: nothing feeding the PSO key changed since the last successful lookup
    // (pso_dirty is raised by VS/PS/IL/blend/VB-stride changes and by every new render pass).
    if (!pso_dirty && last_pso_valid) {
        cur_vs_var = last_vs_var;
        cur_ps_var = last_ps_var;
        return last_pso;
    }
    const bool use_ps = ps && ps->valid;

    // The cache key ALWAYS uses the primary (stable) shader unique_ids; the entry remembers which
    // variants actually linked, so other PSOs sharing these shaders never break or miss.
    Bo3PsoKey key = {};
    key.vs_id = vs->unique_id;
    key.ps_id = use_ps ? ps->unique_id : 0;
    key.il_id = input_layout ? input_layout->unique_id : 0;
    key.blend_hash = blend_state ? blend_state->state_hash : 0;
    key.sample_count = 1;
    for (uint32_t i = 0; i < rtv_count && i < 8; i++) {
        if (active_rt_tex[i]) {
            key.rt_fmts[i] = (uint32_t)active_rt_fmt[i];
            uint32_t sc = (uint32_t)active_rt_tex[i].sampleCount;
            if (sc > key.sample_count) key.sample_count = sc;
        }
    }
    if (active_ds_tex) {
        key.ds_fmt = (uint32_t)active_ds_tex.pixelFormat | (active_dsv_has_stencil ? 0x80000000u : 0u);
        uint32_t sc = (uint32_t)active_ds_tex.sampleCount;
        if (sc > key.sample_count) key.sample_count = sc;
    }
    // Only hash vb_strides for input slots actually referenced by input_layout (prevents PSO bloat!)
    if (input_layout) {
        for (const auto &el : input_layout->elements) {
            if (el.attr_index >= 0 && el.attr_index < 31 && el.input_slot < 16) {
                key.vb_strides[el.input_slot] = vb_strides[el.input_slot];
            }
        }
    }

    // Same key as the last draw (e.g. a new pass with identical formats): skip FNV + map lookup
    if (last_pso_valid && memcmp(&key, &last_pso_key, sizeof(key)) == 0) {
        pso_dirty = false;
        cur_vs_var = last_vs_var;
        cur_ps_var = last_ps_var;
        return last_pso;
    }
    auto remember = [&](id<MTLRenderPipelineState> p, int8_t v, int8_t pv) {
        last_pso_valid = (p != nil);
        last_pso = p;
        last_pso_key = key;
        last_vs_var = v;
        last_ps_var = pv;
        pso_dirty = false;
    };
    auto it = pso_cache.find(key);
    if (it != pso_cache.end()) {
        cur_vs_var = it->second.vs_var;
        cur_ps_var = it->second.ps_var;
        remember(it->second.pso, it->second.vs_var, it->second.ps_var);
        return it->second.pso;
    }

    @autoreleasepool {
        auto build_desc = [&](const Bo3StageSel &vsel, const Bo3StageSel *psel) -> MTLRenderPipelineDescriptor * {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = vsel.fn;
            d.fragmentFunction = psel ? psel->fn : nil;
            d.rasterSampleCount = key.sample_count;

            const bool has_active_va = (vsel.vs_input_mask != 0);

            // Vertex descriptor: IA slot i -> Metal buffer(30 - i)
            if (has_active_va || (input_layout && !input_layout->elements.empty())) {
                MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
                bool layout_used[31] = {false};
                bool layout_synthetic[31] = {false}; // constant-step / zero-buffer layouts (stride irrelevant)
                uint32_t layout_stride[31] = {0};
                uint32_t layout_min_stride[31] = {0};
                MTLVertexStepFunction layout_step_fn[31];
                uint32_t layout_step_rate[31] = {0};
                for (int k = 0; k < 31; k++) layout_step_fn[k] = MTLVertexStepFunctionPerVertex;

                if (input_layout) {
                    for (const auto &el : input_layout->elements) {
                        if (el.attr_index < 0 || el.attr_index >= 31) continue;
                        if (el.input_slot >= 16) continue;
                        uint32_t slot = el.input_slot;
                        uint32_t mbuf = 30 - slot;
                        MTLVertexFormat attr_fmt = el.mtl_format;
                        if (vsel.vs_input_fmt && (vsel.vs_input_mask & (1u << el.attr_index))) {
                            attr_fmt = reconcile_vertex_attr_format(attr_fmt, vsel.vs_input_fmt[el.attr_index]);
                        }
                        vd.attributes[el.attr_index].format = attr_fmt;
                        vd.attributes[el.attr_index].offset = el.byte_offset;
                        vd.attributes[el.attr_index].bufferIndex = mbuf;
                        uint32_t attr_end = el.byte_offset + vertex_format_byte_size(attr_fmt);
                        if (attr_end > layout_min_stride[mbuf]) layout_min_stride[mbuf] = attr_end;
                        if (!layout_used[mbuf]) {
                            layout_used[mbuf] = true;
                            uint32_t stride = vb_strides[slot];
                            layout_stride[mbuf] = stride;
                            if (stride == 0 || (el.input_slot_class && el.step_rate == 0)) {
                                layout_step_fn[mbuf] = MTLVertexStepFunctionConstant;
                                layout_step_rate[mbuf] = 0;
                                layout_synthetic[mbuf] = true;
                            } else {
                                layout_step_fn[mbuf] = el.input_slot_class ? MTLVertexStepFunctionPerInstance
                                                                           : MTLVertexStepFunctionPerVertex;
                                layout_step_rate[mbuf] = el.input_slot_class ? el.step_rate : 1u;
                            }
                        }
                    }
                }
                // Put missing active VS attributes on a dedicated zero-filled constant buffer slot
                // (never slot 0's real vertex buffer, and never stride == 0!)
                uint8_t zero_mbuf = find_zero_vb_mbuf(input_layout, vsel.bindings);
                bool used_zero_mbuf = false;
                for (uint32_t ai = 0; ai < 31; ai++) {
                    if (!(vsel.vs_input_mask & (1u << ai))) continue;
                    if (vd.attributes[ai].format == MTLVertexFormatInvalid) {
                        MTLVertexFormat vfmt = vsel.vs_input_fmt ? vsel.vs_input_fmt[ai] : MTLVertexFormatFloat4;
                        if (vfmt == MTLVertexFormatInvalid) vfmt = MTLVertexFormatFloat4;
                        vd.attributes[ai].format = vfmt;
                        vd.attributes[ai].offset = 0;
                        vd.attributes[ai].bufferIndex = zero_mbuf;
                        uint32_t bsz = vertex_format_byte_size(vfmt);
                        if (bsz > layout_min_stride[zero_mbuf]) layout_min_stride[zero_mbuf] = bsz;
                        used_zero_mbuf = true;
                    }
                }
                if (used_zero_mbuf && !layout_used[zero_mbuf]) {
                    layout_used[zero_mbuf] = true;
                    layout_stride[zero_mbuf] = 0;
                    layout_step_fn[zero_mbuf] = MTLVertexStepFunctionConstant;
                    layout_step_rate[zero_mbuf] = 0;
                    layout_synthetic[zero_mbuf] = true;
                }
                // Finalize every active buffer layout. Populated per-vertex / per-instance slots keep
                // the EXACT D3D stride (4/8/12/... are all legal in Metal as multiples of 4); only
                // constant-step / zero-buffer layouts get a synthetic stride.
                for (uint32_t mb = 0; mb < 31; mb++) {
                    if (!layout_used[mb]) continue;
                    uint32_t aligned_min = (layout_min_stride[mb] + 3u) & ~3u;
                    uint32_t stride = layout_stride[mb];
                    if (layout_synthetic[mb] || stride == 0) {
                        stride = std::max(aligned_min, 16u);
                    } else if ((stride & 3u) != 0 || stride < aligned_min) {
                        // Metal requires 4-byte-multiple strides covering every attribute. Such D3D
                        // layouts are pathological (unaligned or overlapping); round up and warn once.
                        static std::atomic<int> warn{0};
                        if (warn.fetch_add(1, std::memory_order_relaxed) < 5) {
                            fprintf(stderr, "[metal-pso] WARNING: VB stride %u (min %u) not Metal-legal for buffer %u -> using %u\n",
                                    stride, aligned_min, mb, std::max((stride + 3u) & ~3u, aligned_min));
                            fflush(stderr);
                        }
                        stride = std::max((stride + 3u) & ~3u, aligned_min);
                    }
                    vd.layouts[mb].stride = stride;
                    vd.layouts[mb].stepFunction = layout_step_fn[mb];
                    vd.layouts[mb].stepRate = layout_step_rate[mb];
                }
                d.vertexDescriptor = vd;
            }

            for (uint32_t i = 0; i < rtv_count && i < 8; i++) {
                if (!active_rt_tex[i]) continue;
                MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[i];
                ca.pixelFormat = active_rt_fmt[i];
                if (blend_state) {
                    const auto &rt = blend_state->desc.IndependentBlendEnable ? blend_state->desc.RenderTarget[i]
                                                                              : blend_state->desc.RenderTarget[0];
                    ca.blendingEnabled = (rt.BlendEnable && !is_integer_mtl_format(ca.pixelFormat)) ? YES : NO;
                    ca.sourceRGBBlendFactor        = d3d_blend_to_mtl(rt.SrcBlend);
                    ca.destinationRGBBlendFactor   = d3d_blend_to_mtl(rt.DestBlend);
                    ca.rgbBlendOperation           = d3d_blendop_to_mtl(rt.BlendOp);
                    ca.sourceAlphaBlendFactor      = d3d_blend_to_mtl(rt.SrcBlendAlpha);
                    ca.destinationAlphaBlendFactor = d3d_blend_to_mtl(rt.DestBlendAlpha);
                    ca.alphaBlendOperation         = d3d_blendop_to_mtl(rt.BlendOpAlpha);
                    ca.writeMask                   = d3d_writemask_to_mtl(rt.RenderTargetWriteMask);
                }
            }
            if (blend_state && blend_state->desc.AlphaToCoverageEnable) {
                d.alphaToCoverageEnabled = YES;
            }
            if (active_ds_tex) {
                d.depthAttachmentPixelFormat = active_ds_tex.pixelFormat;
                if (active_dsv_has_stencil) d.stencilAttachmentPixelFormat = active_ds_tex.pixelFormat;
            }
            return d;
        };

        // Candidate (vs_variant, ps_variant) pairs, tried in order. Variants are compiled lazily
        // ONCE with stable unique_ids and never mutate the primary shaders.
        struct Attempt { int8_t v, p; };
        Attempt attempts[4];
        int n_attempts = 0;
        attempts[n_attempts++] = {-1, -1};
        if (use_ps && vs->from_generic_metallib != ps->from_generic_metallib) {
            // Mixed Generic.metallib + translated VS/PS varying mismatch: translate the generic partner
            if (vs->from_generic_metallib) attempts[n_attempts++] = {0, -1};
            else                           attempts[n_attempts++] = {-1, 0};
        }
        NSError *err = nil;
        id<MTLRenderPipelineState> pso = nil;
        Attempt used = {-1, -1};
        bool float4_tried = false;
        for (int ai = 0; ai < n_attempts && !pso; ai++) {
            Attempt a = attempts[ai];
            if (a.v >= 0 && !bo3_shader_get_fallback(vs, a.v)) continue;
            if (a.p >= 0 && (!use_ps || !bo3_shader_get_fallback(ps, a.p))) continue;
            Bo3StageSel vsel = make_stage_sel(vs, a.v);
            Bo3StageSel psel = use_ps ? make_stage_sel(ps, a.p) : Bo3StageSel{};
            err = nil;
            // Aspyr's 2019 Generic.metallib (AIR 2.x) functions poison MTLBinaryArchive serialization on
            // Apple M4 / macOS 27 (serialize fails or writes a corrupt segment): only pipelines whose
            // SELECTED stages are runtime-compiled MSL 3.2 (translated primaries or fallbacks) persist.
            const bool allow_archive = !vsel.from_generic && !(use_ps && psel.from_generic);
            pso = bo3_pso_create_render(device->mtl_dev, build_desc(vsel, use_ps ? &psel : nullptr), &err,
                                        allow_archive);
            if (pso) { used = a; break; }
            // Rare DXBC VS/PS signature mismatch (e.g. VS outputs float4 while PS declares uint4 on
            // TEXCOORD0): append a force_float4_varyings attempt for both sides (once).
            if (!float4_tried && use_ps && err && [err.localizedDescription containsString:@"mismatching"] &&
                n_attempts < 4) {
                float4_tried = true;
                bool vf = bo3_shader_get_fallback(vs, 1) != nullptr;
                bool pf = bo3_shader_get_fallback(ps, 1) != nullptr;
                if (vf || pf) attempts[n_attempts++] = {(int8_t)(vf ? 1 : -1), (int8_t)(pf ? 1 : -1)};
            }
        }
        if (!pso) {
            static int pso_err_cnt = 0;
            if (pso_err_cnt++ < 25) {
                fprintf(stderr, "[metal-pso] Build FAILED vs=%s ps=%s: %s\n",
                        vs->name.c_str(), (ps ? ps->name.c_str() : "null"),
                        err ? err.localizedDescription.UTF8String : "?");
                fflush(stderr);
            }
            pso_cache[key] = Bo3PsoEntry{nil, -1, -1};
            last_pso_valid = false;
            return nil;
        }
        pso_cache[key] = Bo3PsoEntry{pso, used.v, used.p};
        cur_vs_var = used.v;
        cur_ps_var = used.p;
        remember(pso, used.v, used.p);
        return pso;
    }
}

static void extract_srv_subrange(const Bo3MetalSRV *srv, uint32_t &mip0, uint32_t &mip_cnt,
                                 uint32_t &sl0, uint32_t &sl_cnt) {
    mip0 = 0; mip_cnt = 0; sl0 = 0; sl_cnt = 0;
    if (!srv) return;
    const auto &d = srv->desc;
    switch (d.ViewDimension) {
        case BO3_D3D11_SRV_DIMENSION_TEXTURE1D:
            mip0 = d.Texture1D.MostDetailedMip; mip_cnt = d.Texture1D.MipLevels; sl_cnt = 1; break;
        case BO3_D3D11_SRV_DIMENSION_TEXTURE1DARRAY:
            mip0 = d.Texture1DArray.MostDetailedMip; mip_cnt = d.Texture1DArray.MipLevels;
            sl0 = d.Texture1DArray.FirstArraySlice; sl_cnt = d.Texture1DArray.ArraySize; break;
        case BO3_D3D11_SRV_DIMENSION_TEXTURE2D:
            mip0 = d.Texture2D.MostDetailedMip; mip_cnt = d.Texture2D.MipLevels; sl_cnt = 1; break;
        case BO3_D3D11_SRV_DIMENSION_TEXTURE2DARRAY:
            mip0 = d.Texture2DArray.MostDetailedMip; mip_cnt = d.Texture2DArray.MipLevels;
            sl0 = d.Texture2DArray.FirstArraySlice; sl_cnt = d.Texture2DArray.ArraySize; break;
        case BO3_D3D11_SRV_DIMENSION_TEXTURE2DMS:
            sl_cnt = 1; break;
        case BO3_D3D11_SRV_DIMENSION_TEXTURE2DMSARRAY:
            sl0 = d.Texture2DMSArray.FirstArraySlice; sl_cnt = d.Texture2DMSArray.ArraySize; break;
        case BO3_D3D11_SRV_DIMENSION_TEXTURE3D:
            mip0 = d.Texture3D.MostDetailedMip; mip_cnt = d.Texture3D.MipLevels; break;
        case BO3_D3D11_SRV_DIMENSION_TEXTURECUBE:
            mip0 = d.TextureCube.MostDetailedMip; mip_cnt = d.TextureCube.MipLevels; sl_cnt = 6; break;
        case BO3_D3D11_SRV_DIMENSION_TEXTURECUBEARRAY:
            mip0 = d.TextureCubeArray.MostDetailedMip; mip_cnt = d.TextureCubeArray.MipLevels;
            sl0 = d.TextureCubeArray.First2DArrayFace;
            sl_cnt = (d.TextureCubeArray.NumCubes == 0xffffffffu) ? 0u : (d.TextureCubeArray.NumCubes * 6u);
            break;
        default: break;
    }
    if (mip_cnt == 0xffffffffu) mip_cnt = 0;
    if (sl_cnt == 0xffffffffu)  sl_cnt = 0;
}

id<MTLTexture> Bo3MetalContext::resolve_srv_texture(Bo3MetalSRV *srv, uint8_t expect, uint8_t num_type) {
    if (num_type > BO3_TEX_NUM_SINT) num_type = BO3_TEX_NUM_FLOAT;
    id<MTLTexture> t = nil;
    uint32_t mip0 = 0, mip_cnt = 0, sl0 = 0, sl_cnt = 0;
    if (srv && !srv->is_buffer && srv->resource) {
        Bo3MetalTexture *bt = (Bo3MetalTexture *)srv->resource;
        extract_srv_subrange(srv, mip0, mip_cnt, sl0, sl_cnt);
        if (bt->is_backbuffer) {
            id<MTLTexture> bb = bt->current_mtl_texture();
            if (bb) {
                uint32_t fmt = srv->desc.Format ? srv->desc.Format : bt->dxgi_format;
                MTLPixelFormat mpf = bo3_dxgi_to_metal_format(fmt, false, true).pixel_format;
                if (mpf == MTLPixelFormatInvalid) mpf = bb.pixelFormat;
                t = bt->get_or_create_view(mpf, bb.textureType, mip0, mip_cnt, sl0, sl_cnt ? sl_cnt : 1u);
            }
        } else {
            t = srv->mtl_tex;
        }
    }
    const bool expect_depth = (expect == BO3_TEX_DEPTH_2D || expect == BO3_TEX_DEPTH_2D_ARRAY ||
                               expect == BO3_TEX_DEPTH_CUBE || expect == BO3_TEX_DEPTH_CUBE_ARRAY);
    if (t && expect_depth && !is_depth_mtl_format(t.pixelFormat)) {
        t = nil; // never bind a color texture to a depth2d/depthcube Metal slot
    }
    // View adapter: fix 1D<->1DArray, 2D<->2DArray, Cube<->CubeArray preserving SRV format/mips/slices!
    if (t && srv && !srv->is_buffer && srv->resource) {
        Bo3MetalTexture *bt = (Bo3MetalTexture *)srv->resource;
        if (expect == BO3_TEX_1D && t.textureType == MTLTextureType1DArray) {
            t = bt->get_or_create_view(t.pixelFormat, MTLTextureType1D, mip0, mip_cnt, sl0, 1);
        } else if (expect == BO3_TEX_1D_ARRAY && t.textureType == MTLTextureType1D) {
            t = bt->get_or_create_view(t.pixelFormat, MTLTextureType1DArray, mip0, mip_cnt, sl0, 1);
        } else if ((expect == BO3_TEX_2D || expect == BO3_TEX_DEPTH_2D) && t.textureType == MTLTextureType2DArray) {
            t = bt->get_or_create_view(t.pixelFormat, MTLTextureType2D, mip0, mip_cnt, sl0, 1);
        } else if ((expect == BO3_TEX_2D_ARRAY || expect == BO3_TEX_DEPTH_2D_ARRAY) && t.textureType == MTLTextureType2D) {
            t = bt->get_or_create_view(t.pixelFormat, MTLTextureType2DArray, mip0, mip_cnt, sl0, 1);
        } else if ((expect == BO3_TEX_CUBE || expect == BO3_TEX_DEPTH_CUBE) && t.textureType == MTLTextureTypeCubeArray) {
            t = bt->get_or_create_view(t.pixelFormat, MTLTextureTypeCube, mip0, mip_cnt, sl0, 6);
        } else if ((expect == BO3_TEX_CUBE_ARRAY || expect == BO3_TEX_DEPTH_CUBE_ARRAY) && t.textureType == MTLTextureTypeCube) {
            t = bt->get_or_create_view(t.pixelFormat, MTLTextureTypeCubeArray, mip0, mip_cnt, sl0, 6);
        }
    }
    if (t) return t;
    // Fallback dummy matching EVERY Bo3TexExpect x Bo3TexNumericType
    switch (expect) {
        case BO3_TEX_1D:               return device->dummy_tex_1d[num_type];
        case BO3_TEX_1D_ARRAY:         return device->dummy_tex_1d_arr[num_type];
        case BO3_TEX_2D_ARRAY:         return device->dummy_tex_2d_arr[num_type];
        case BO3_TEX_2D_MS:            return device->dummy_tex_2d_ms[num_type];
        case BO3_TEX_2D_MS_ARRAY:      return device->dummy_tex_2d_ms_arr[num_type];
        case BO3_TEX_CUBE:             return device->dummy_tex_cube[num_type];
        case BO3_TEX_CUBE_ARRAY:       return device->dummy_tex_cube_arr[num_type];
        case BO3_TEX_3D:               return device->dummy_tex_3d[num_type];
        case BO3_TEX_DEPTH_2D:         return device->dummy_tex_depth;
        case BO3_TEX_DEPTH_2D_ARRAY:   return device->dummy_tex_depth_arr;
        case BO3_TEX_DEPTH_CUBE:       return device->dummy_tex_depth_cube;
        case BO3_TEX_DEPTH_CUBE_ARRAY: return device->dummy_tex_depth_cube_arr;
        default:                       return device->dummy_tex_2d[num_type];
    }
}

id<MTLTexture> Bo3MetalContext::resolve_uav_texture(Bo3MetalUAV *u, uint8_t expect, uint8_t num_type) {
    if (num_type > BO3_TEX_NUM_SINT) num_type = BO3_TEX_NUM_FLOAT;
    if (u && !u->is_buffer && u->mtl_tex && (u->mtl_tex.usage & MTLTextureUsageShaderWrite)) {
        id<MTLTexture> t = u->mtl_tex;
        if (u->resource) {
            Bo3MetalTexture *bt = (Bo3MetalTexture *)u->resource;
            uint32_t mip = 0, sl0 = 0;
            switch (u->desc.ViewDimension) {
                case BO3_D3D11_UAV_DIMENSION_TEXTURE1D:      mip = u->desc.Texture1D.MipSlice; break;
                case BO3_D3D11_UAV_DIMENSION_TEXTURE1DARRAY: mip = u->desc.Texture1DArray.MipSlice; sl0 = u->desc.Texture1DArray.FirstArraySlice; break;
                case BO3_D3D11_UAV_DIMENSION_TEXTURE2D:      mip = u->desc.Texture2D.MipSlice; break;
                case BO3_D3D11_UAV_DIMENSION_TEXTURE2DARRAY: mip = u->desc.Texture2DArray.MipSlice; sl0 = u->desc.Texture2DArray.FirstArraySlice; break;
                case BO3_D3D11_UAV_DIMENSION_TEXTURE3D:      mip = u->desc.Texture3D.MipSlice; break;
                default: break;
            }
            if (expect == BO3_TEX_2D && t.textureType == MTLTextureType2DArray) {
                t = bt->get_or_create_view(t.pixelFormat, MTLTextureType2D, mip, 1, sl0, 1);
            } else if (expect == BO3_TEX_2D_ARRAY && t.textureType == MTLTextureType2D) {
                t = bt->get_or_create_view(t.pixelFormat, MTLTextureType2DArray, mip, 1, sl0, 1);
            } else if (expect == BO3_TEX_1D && t.textureType == MTLTextureType1DArray) {
                t = bt->get_or_create_view(t.pixelFormat, MTLTextureType1D, mip, 1, sl0, 1);
            } else if (expect == BO3_TEX_1D_ARRAY && t.textureType == MTLTextureType1D) {
                t = bt->get_or_create_view(t.pixelFormat, MTLTextureType1DArray, mip, 1, sl0, 1);
            }
        }
        return t;
    }
    switch (expect) {
        case BO3_TEX_1D:       return device->dummy_uav_1d[num_type];
        case BO3_TEX_1D_ARRAY: return device->dummy_uav_1d_arr[num_type];
        case BO3_TEX_2D_ARRAY: return device->dummy_uav_2d_arr[num_type];
        case BO3_TEX_3D:       return device->dummy_uav_3d[num_type];
        default:               return device->dummy_uav_2d[num_type];
    }
}

void Bo3MetalContext::bind_stage_resources(Bo3ShaderStage stage, const Bo3StageSel &sel) {
    if (!sel.bindings) return;
    const Bo3BindingMap &map = *sel.bindings;
    Bo3MetalBuffer       **cbs  = (stage == BO3_STAGE_VS) ? vs_cb  : (stage == BO3_STAGE_PS ? ps_cb  : cs_cb);
    Bo3MetalSRV          **srvs = (stage == BO3_STAGE_VS) ? vs_srv : (stage == BO3_STAGE_PS ? ps_srv : cs_srv);
    Bo3MetalSamplerState **smps = (stage == BO3_STAGE_VS) ? vs_smp : (stage == BO3_STAGE_PS ? ps_smp : cs_smp);

    // Render stages go through the per-encoder dedup cache; compute binds directly.
    auto bind_buf = [&](uint8_t idx, id<MTLBuffer> buf, uint64_t off) {
        if (!buf) { buf = device->zero_buffer; off = 0; }
        if (stage == BO3_STAGE_CS) [compute_enc setBuffer:buf offset:off atIndex:idx];
        else                       enc_set_buffer(stage == BO3_STAGE_VS, idx, buf, off);
    };
    auto bind_tex = [&](uint8_t idx, id<MTLTexture> tex) {
        if (stage == BO3_STAGE_CS) [compute_enc setTexture:tex atIndex:idx];
        else                       enc_set_texture(stage == BO3_STAGE_VS, idx, tex);
    };
    auto bind_smp = [&](uint8_t idx, id<MTLSamplerState> smp) {
        if (!smp) smp = device->dummy_sampler;
        if (stage == BO3_STAGE_CS) [compute_enc setSamplerState:smp atIndex:idx];
        else                       enc_set_sampler(stage == BO3_STAGE_VS, idx, smp);
    };

    // Constant buffers
    uint16_t cm = map.cb_mask;
    while (cm) {
        int s = __builtin_ctz(cm);
        cm &= (uint16_t)(cm - 1);
        uint8_t mi = map.cb[s];
        if (mi == BO3_BIND_UNUSED) continue;
        Bo3MetalBuffer *b = cbs[s];
        if (b) {
            touch_buf(b);
            id<MTLBuffer> mb = b->dyn_buf ? b->dyn_buf : b->mtl_buf;
            uint64_t off = b->dyn_buf ? b->dyn_offset : 0;
            bind_buf(mi, mb, off);
        } else {
            bind_buf(mi, device->zero_buffer, 0);
        }
    }

    // SRVs (textures + buffer SRVs)
    uint32_t buf_info[64] = {0};
    auto handle_srv_mask = [&](uint64_t mask, int base_slot) {
        while (mask) {
            int bit = __builtin_ctzll(mask);
            mask &= (mask - 1);
            int s = base_slot + bit;
            uint8_t enc = map.srv[s];
            if (enc == BO3_BIND_UNUSED) continue;
            Bo3MetalSRV *v = srvs[s];
            if (enc & BO3_BIND_IS_BUF) {
                uint8_t mi = enc & BO3_BIND_IDX_MASK;
                if (v && v->is_buffer && v->resource) {
                    Bo3MetalBuffer *b = (Bo3MetalBuffer *)v->resource;
                    touch_buf(b);
                    id<MTLBuffer> mb = b->dyn_buf ? b->dyn_buf : b->mtl_buf;
                    uint64_t off = (b->dyn_buf ? b->dyn_offset : 0) + v->buf_offset;
                    bind_buf(mi, mb, off);
                    if (sel.from_generic) {
                        if (mi < 64) buf_info[mi] = v->buf_num_elements;
                    } else if (mi < 32) {
                        buf_info[mi * 2 + 0] = v->buf_num_elements;
                        buf_info[mi * 2 + 1] = v->buf_stride;
                    }
                } else {
                    bind_buf(mi, device->zero_buffer, 0);
                }
            } else {
                if (v) touch(v->resource); // hazard/hoist tracking: this cmd_buf reads the texture
                bind_tex(enc, resolve_srv_texture(v, map.srv_expect[s], map.srv_num_type[s]));
            }
        }
    };
    handle_srv_mask(map.srv_mask_lo, 0);
    handle_srv_mask(map.srv_mask_hi, 64);

    // Samplers + cube-sampler twins
    uint16_t sm = map.smp_mask;
    while (sm) {
        int s = __builtin_ctz(sm);
        sm &= (uint16_t)(sm - 1);
        uint8_t mi = map.smp[s];
        if (mi != BO3_BIND_UNUSED) {
            bind_smp(mi, smps[s] ? smps[s]->mtl_smp : device->dummy_sampler);
        }
    }
    uint16_t scm = map.smp_cube_mask;
    while (scm) {
        int s = __builtin_ctz(scm);
        scm &= (uint16_t)(scm - 1);
        uint8_t mi = map.smp_cube[s];
        if (mi != BO3_BIND_UNUSED) {
            bind_smp(mi, smps[s] ? smps[s]->mtl_smp_cube : device->dummy_sampler);
        }
    }

    // UAVs (CS or OM-bound PS UAVs) — NEVER bind zero_buffer to writable UAVs!
    uint64_t um = map.uav_mask;
    Bo3MetalUAV **uavs = (stage == BO3_STAGE_CS) ? cs_uav : om_uavs;
    int max_uavs = (stage == BO3_STAGE_CS) ? 64 : 8;
    while (um) {
        int s = __builtin_ctzll(um);
        um &= (um - 1);
        if (s >= max_uavs) continue;
        uint8_t enc = map.uav[s];
        if (enc == BO3_BIND_UNUSED) continue;
        Bo3MetalUAV *u = uavs[s];
        if (enc & BO3_BIND_IS_BUF) {
            uint8_t mi = enc & BO3_BIND_IDX_MASK;
            if (u && u->is_buffer && u->resource) {
                Bo3MetalBuffer *b = (Bo3MetalBuffer *)u->resource;
                touch_buf(b);
                bind_buf(mi, b->mtl_buf ? b->mtl_buf : u->mtl_buf, u->buf_offset);
                if (sel.from_generic) {
                    if (mi < 64) buf_info[mi] = u->buf_num_elements;
                } else if (mi < 32) {
                    buf_info[mi * 2 + 0] = u->buf_num_elements;
                    buf_info[mi * 2 + 1] = u->buf_stride;
                }
            } else {
                bind_buf(mi, device->dummy_uav_buf, 0);
            }
        } else {
            if (u) touch(u->resource);
            bind_tex(enc, resolve_uav_texture(u, map.uav_expect[s], map.uav_num_type[s]));
        }
        // Per-UAV atomic counter buffer binding (when uav_counters_buf is unused)
        if (map.uav_counters_buf == BO3_BIND_UNUSED && map.uav_counter_idx[s] != BO3_BIND_UNUSED) {
            id<MTLBuffer> cbuf = (u && u->counter_buf) ? u->counter_buf : device->dummy_uav_buf;
            bind_buf(map.uav_counter_idx[s], cbuf, 0);
        }
    }

    // bufferInfo / uavCounters / icb buffers
    if (map.buffer_info_buf != BO3_BIND_UNUSED) {
        if (stage == BO3_STAGE_CS) {
            [compute_enc setBytes:buf_info length:sizeof(buf_info) atIndex:map.buffer_info_buf];
        } else {
            // A5: identical 256-byte bufferInfo already bound at this index in this encoder -> skip
            const bool vsb = (stage == BO3_STAGE_VS);
            uint32_t *cache = vsb ? enc_vs_bufinfo : enc_ps_bufinfo;
            uint8_t cached_idx = vsb ? enc_vs_bufinfo_idx : enc_ps_bufinfo_idx;
            if (cached_idx == map.buffer_info_buf && memcmp(cache, buf_info, sizeof(buf_info)) == 0) {
                if (perf_on) enc_state_skips++;
            } else {
                enc_set_bytes(vsb, buf_info, sizeof(buf_info), map.buffer_info_buf);
                memcpy(cache, buf_info, sizeof(buf_info));
                (vsb ? enc_vs_bufinfo_idx : enc_ps_bufinfo_idx) = map.buffer_info_buf;
            }
        }
    }
    if (map.uav_counters_buf != BO3_BIND_UNUSED) {
        bind_buf(map.uav_counters_buf, uav_counter_table ? uav_counter_table : device->dummy_uav_buf, 0);
    }
    if (map.icb_buf != BO3_BIND_UNUSED) {
        bind_buf(map.icb_buf, sel.icb ? sel.icb : device->zero_buffer, 0);
    }
}

static bool prepare_draw(Bo3MetalContext *c) {
    if (!c->vs || !bo3_shader_ensure_compiled(c->vs)) return false;
    if (c->ps && !bo3_shader_ensure_compiled(c->ps)) return false;
    // D3D11 guarantees UAV writes from one draw are visible to the next draw; Metal does not
    // within a render encoder. Before any later draw in the same pass that touches UAVs:
    //  - GPUs that support it: fragment -> vertex|fragment memory barrier
    //  - Apple-family GPUs (afterStages may NOT contain Fragment): split the render pass
    //    (store + reload), which orders all fragment writes before the next pass.
    const bool ps_uav_pre = c->ps && c->ps->valid && c->ps->bindings.uav_mask != 0;
    const bool vs_uav_pre = c->vs->bindings.uav_mask != 0;
    bool need_frag_barrier = false;
    if (c->enc_mode == ENC_RENDER && c->render_enc && c->pass_has_frag_uav_write && (ps_uav_pre || vs_uav_pre)) {
        if (c->frag_barrier_ok) need_frag_barrier = true;
        else c->end_active_encoder(SPLIT_UAV);
    }
    // A1b: deferred clears on anything this draw can read must land first (O(1) when none exist)
    c->materialize_srv_uav_reads(BO3_STAGE_PS);
    if (!c->ensure_render_pass()) return false;
    if (c->scissor_is_empty()) return false;
    id<MTLRenderPipelineState> pso = c->get_or_build_pso();
    if (!pso) return false;
    c->enc_set_pso(pso);
    const Bo3StageSel vsel = make_stage_sel(c->vs, c->cur_vs_var);
    const bool use_ps = c->ps && c->ps->valid;
    const Bo3StageSel psel = use_ps ? make_stage_sel(c->ps, c->cur_ps_var) : Bo3StageSel{};
    const bool ps_uav = use_ps && psel.bindings && psel.bindings->uav_mask != 0;
    if (need_frag_barrier && c->pass_has_frag_uav_write) {
        if (@available(macOS 10.14, *)) {
            [c->render_enc memoryBarrierWithScope:(MTLBarrierScopeBuffers | MTLBarrierScopeTextures)
                                      afterStages:MTLRenderStageFragment
                                     beforeStages:(MTLRenderStageVertex | MTLRenderStageFragment)];
        }
    }
    if (ps_uav) c->pass_has_frag_uav_write = true;

    // Bind vertex buffers at buffer(30 - slot)
    uint32_t bound_mask = 0;
    uint32_t covered_attr_mask = 0;
    if (c->input_layout) {
        for (const auto &el : c->input_layout->elements) {
            if (el.attr_index < 0 || el.attr_index >= 31 || el.input_slot >= 16) continue;
            covered_attr_mask |= (1u << el.attr_index);
            uint32_t slot = el.input_slot;
            if (bound_mask & (1u << slot)) continue;
            bound_mask |= (1u << slot);
            Bo3MetalBuffer *vb = c->vbs[slot];
            if (vb) {
                c->touch_buf(vb);
                id<MTLBuffer> mb = vb->cur_buf();
                uint64_t off = vb->cur_base() + c->vb_offsets[slot];
                if (mb && off < vb->cur_len()) {
                    c->enc_set_buffer(true, 30 - slot, mb, off);
                } else {
                    c->enc_set_buffer(true, 30 - slot, c->device->zero_buffer, 0);
                }
            } else {
                c->enc_set_buffer(true, 30 - slot, c->device->zero_buffer, 0);
            }
        }
    }
    // Bind dedicated zero constant vertex buffer whenever any active VS attribute was missing from
    // input_layout (cached vs_input_mask: no per-draw MTLFunction reflection queries!)
    if ((vsel.vs_input_mask & 0x7fffffffu) & ~covered_attr_mask) {
        uint8_t zero_mbuf = find_zero_vb_mbuf(c->input_layout, vsel.bindings);
        c->enc_set_buffer(true, zero_mbuf, c->device->zero_buffer, 0);
    }

    c->bind_stage_resources(BO3_STAGE_VS, vsel);
    if (use_ps) {
        c->bind_stage_resources(BO3_STAGE_PS, psel);
    }
    c->draw_calls++;
    static int trace_frame = -1;
    static bool trace_draws = false;
    static std::once_flag trace_once;
    std::call_once(trace_once, []() {
        trace_draws = (getenv("BO3ARM_TRACE_DRAWS") != nullptr);
        if (const char *s = getenv("BO3ARM_TRACE_FRAME")) trace_frame = atoi(s);
    });
    if ((trace_draws && c->draw_calls <= 30) || (trace_frame > 0 && (int)c->cur_frame_no == trace_frame)) {
        fprintf(stderr, "[draw f=%llu #%llu] vs=%s ps=%s rtvs=%u(%ux%u fmt0=%lu) dsv=%d\n",
                (unsigned long long)c->cur_frame_no, (unsigned long long)c->draw_calls,
                c->vs ? c->vs->name.c_str() : "null",
                c->ps ? c->ps->name.c_str() : "null",
                c->rtv_count, c->pass_w, c->pass_h, (unsigned long)c->active_rt_fmt[0],
                c->active_ds_tex ? 1 : 0);
        fflush(stderr);
    }
    return true;
}

// =========================================================================
// M5: Opt-in GPU / TBDR telemetry (BO3ARM_PERF_STATS=1)
// =========================================================================

bool bo3_perf_enabled(void) {
    static bool on = false;
    static std::once_flag once;
    std::call_once(once, [] {
        const char *e = getenv("BO3ARM_PERF_STATS");
        on = e && e[0] && strcmp(e, "0") != 0;
    });
    return on;
}

static double perf_ticks_to_ms(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    static std::once_flag once;
    std::call_once(once, [] { mach_timebase_info(&tb); });
    return (double)ticks * (double)tb.numer / (double)tb.denom / 1e6;
}

// CPU encode timer: a single relaxed load + predictable branch when telemetry is off.
struct Bo3PerfScope {
    Bo3MetalContext *c;
    uint64_t t0;
    explicit Bo3PerfScope(Bo3MetalContext *ctx) : c((ctx && ctx->perf_on_scope.load(std::memory_order_relaxed)) ? ctx : nullptr),
                                                   t0(c ? mach_absolute_time() : 0) {}
    ~Bo3PerfScope() {
        if (c) c->perf_cpu_ticks.fetch_add(mach_absolute_time() - t0, std::memory_order_relaxed);
    }
    Bo3PerfScope(const Bo3PerfScope &) = delete;
    Bo3PerfScope &operator=(const Bo3PerfScope &) = delete;
};

static uint64_t perf_attachment_bytes(id<MTLTexture> t, NSUInteger level, uint32_t layers, uint32_t bpp) {
    if (!t || bpp == 0) return 0;
    uint64_t w = std::max<uint64_t>(1, (uint64_t)t.width >> level);
    uint64_t h = std::max<uint64_t>(1, (uint64_t)t.height >> level);
    return w * h * (uint64_t)std::max(1u, layers) * (uint64_t)bpp * (uint64_t)std::max<NSUInteger>(1, t.sampleCount);
}

static bool perf_is_store(MTLStoreAction a) {
    return a == MTLStoreActionStore || a == MTLStoreActionStoreAndMultisampleResolve;
}
static bool perf_has_resolve(MTLStoreAction a) {
    return a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve;
}

// Logical (uncompressed) bytes moved between tile memory and DRAM by one render pass.
void Bo3MetalContext::perf_account_pass(MTLRenderPassDescriptor *rpd) {
    if (!rpd) return;
    const uint32_t layers = rpd.renderTargetArrayLength > 0 ? (uint32_t)rpd.renderTargetArrayLength : 1u;
    for (uint32_t i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *ca = rpd.colorAttachments[i];
        id<MTLTexture> t = ca.texture;
        if (!t) continue;
        uint32_t bpp = bo3_mtl_color_bytes_per_pixel(t.pixelFormat);
        if (bpp == 0) bpp = 4;
        uint32_t ly = (t.textureType == MTLTextureType3D) ? 1u : layers;
        uint64_t bytes = perf_attachment_bytes(t, ca.level, ly, bpp);
        if (ca.loadAction == MTLLoadActionLoad) perf_load_bytes += bytes;
        if (perf_is_store(ca.storeAction)) perf_store_bytes += bytes;
        if (perf_has_resolve(ca.storeAction) && ca.resolveTexture) {
            perf_store_bytes += perf_attachment_bytes(ca.resolveTexture, ca.resolveLevel, ly, bpp);
        }
    }
    MTLRenderPassDepthAttachmentDescriptor *da = rpd.depthAttachment;
    if (da.texture) {
        uint32_t bpp = bo3_mtl_depth_bytes_per_pixel(da.texture.pixelFormat);
        uint64_t bytes = perf_attachment_bytes(da.texture, da.level, layers, bpp);
        if (da.loadAction == MTLLoadActionLoad) perf_load_bytes += bytes;
        if (perf_is_store(da.storeAction)) perf_store_bytes += bytes;
        if (perf_has_resolve(da.storeAction) && da.resolveTexture) {
            perf_store_bytes += perf_attachment_bytes(da.resolveTexture, da.resolveLevel, layers, bpp);
        }
    }
    MTLRenderPassStencilAttachmentDescriptor *sa = rpd.stencilAttachment;
    if (sa.texture) {
        uint32_t bpp = bo3_mtl_stencil_bytes_per_pixel(sa.texture.pixelFormat);
        uint64_t bytes = perf_attachment_bytes(sa.texture, sa.level, layers, bpp);
        if (sa.loadAction == MTLLoadActionLoad) perf_load_bytes += bytes;
        if (perf_is_store(sa.storeAction)) perf_store_bytes += bytes;
    }
}

// Caller holds c->lock. Returns the open frame's timing accumulator (creating it if needed).
Bo3MetalContext::Bo3FrameTiming *Bo3MetalContext::ensure_frame_timing_locked() {
    if (!cur_frame_timing) cur_frame_timing = new Bo3FrameTiming();
    return cur_frame_timing;
}

// Completion-handler side (any thread): accumulate real GPU execution time per frame and publish
// (frame_gpu_ns, +1 frame) atomically once EVERY CB belonging to that frame has completed.
void Bo3MetalContext::perf_finish_cb_timing(Bo3FrameTiming *ft, id<MTLCommandBuffer> cb) {
    if (!ft) return;
    CFTimeInterval t0 = cb.GPUStartTime, t1 = cb.GPUEndTime;
    const uint64_t ns = (t1 > t0 && t0 > 0) ? (uint64_t)((t1 - t0) * 1e9) : 0;
    ft->gpu_ns.fetch_add(ns, std::memory_order_relaxed);
    if (ft->remaining.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        if (ft->counted_frame) {
            const uint64_t total_ns = ft->gpu_ns.load(std::memory_order_relaxed);
            os_unfair_lock_lock(&perf_gpu_lock);
            perf_gpu_ns += total_ns;
            perf_gpu_frames++;
            os_unfair_lock_unlock(&perf_gpu_lock);
        }
        delete ft;
    }
}

void bo3_context_set_perf_active(Bo3MetalContext *c, bool active) {
    if (!c) return;
    if (c->perf_on_scope.load(std::memory_order_relaxed) == active) return;
    os_unfair_lock_lock(&c->lock);
    if (c->perf_on != active) {
        if (active) {
            // Reset window baselines so the HUD/telemetry immediately reports clean live deltas.
            Bo3PsoCacheStats ps = {};
            bo3_pso_cache_get_stats(&ps);
            c->perf_win_frames = 0;
            c->perf_base_passes = c->pass_splits;
            c->perf_base_draws = c->draw_calls;
            c->perf_base_dispatches = c->dispatch_calls;
            c->perf_base_skips = c->enc_state_skips;
            c->perf_base_pso_builds = ps.pso_builds;
            c->perf_load_bytes = 0;
            c->perf_store_bytes = 0;
            c->perf_cpu_ticks.store(0, std::memory_order_relaxed);
            for (uint64_t &v : c->perf_split) v = 0;
            c->perf_dontcare_saves = c->perf_ring_overflows = c->perf_hoisted_uploads = 0;
            c->perf_clr_folded = c->perf_clr_materialized = 0;
            os_unfair_lock_lock(&c->perf_gpu_lock);
            c->perf_gpu_ns = 0;
            c->perf_gpu_frames = 0;
            os_unfair_lock_unlock(&c->perf_gpu_lock);
        } else if (c->cur_frame_timing) {
            // Drop any open unsealed frame timing so it never leaks or mixes into a later toggle.
            Bo3MetalContext::Bo3FrameTiming *ft = c->cur_frame_timing;
            c->cur_frame_timing = nullptr;
            if (ft->remaining.fetch_sub(1, std::memory_order_acq_rel) == 1) delete ft;
        }
        c->perf_on = active;
        c->perf_on_scope.store(active, std::memory_order_release);
    }
    os_unfair_lock_unlock(&c->lock);
}

static void perf_collect_window_locked(Bo3MetalContext *c, Bo3PerfSnapshot *out, Bo3PsoCacheStats *ps_out) {
    Bo3PsoCacheStats ps = {};
    bo3_pso_cache_get_stats(&ps);
    const double n = (double)std::max<uint64_t>(1, c->perf_win_frames);
    os_unfair_lock_lock(&c->perf_gpu_lock);
    uint64_t gpu_ns = c->perf_gpu_ns;
    uint64_t gpu_frames = c->perf_gpu_frames;
    c->perf_gpu_ns = 0;
    c->perf_gpu_frames = 0;
    os_unfair_lock_unlock(&c->perf_gpu_lock);
    Bo3PerfSnapshot snap = {};
    snap.frames = c->perf_win_frames;
    snap.gpu_ms = gpu_frames ? ((double)gpu_ns / 1e6 / (double)gpu_frames) : c->perf_last.gpu_ms;
    snap.cpu_encode_ms = perf_ticks_to_ms(c->perf_cpu_ticks.exchange(0, std::memory_order_relaxed)) / n;
    snap.passes = (double)(c->pass_splits - c->perf_base_passes) / n;
    snap.draws = (double)(c->draw_calls - c->perf_base_draws) / n;
    snap.dispatches = (double)(c->dispatch_calls - c->perf_base_dispatches) / n;
    snap.tbdr_load_mb = (double)c->perf_load_bytes / (1024.0 * 1024.0) / n;
    snap.tbdr_store_mb = (double)c->perf_store_bytes / (1024.0 * 1024.0) / n;
    snap.pso_builds = ps.pso_builds - c->perf_base_pso_builds;
    snap.enc_state_skips = c->enc_state_skips - c->perf_base_skips;
    snap.split_tgt   = (double)c->perf_split[SPLIT_TGT] / n;
    snap.split_clr   = (double)c->perf_split[SPLIT_CLR] / n;
    snap.split_blit  = (double)c->perf_split[SPLIT_BLIT] / n;
    snap.split_cmp   = (double)c->perf_split[SPLIT_CMP] / n;
    snap.split_uav   = (double)c->perf_split[SPLIT_UAV] / n;
    snap.split_pres  = (double)c->perf_split[SPLIT_PRES] / n;
    snap.split_flush = (double)c->perf_split[SPLIT_FLUSH] / n;
    snap.split_oth   = (double)c->perf_split[SPLIT_OTH] / n;
    snap.dontcare_saves = (double)c->perf_dontcare_saves / n;
    snap.ring_ovf    = (double)c->perf_ring_overflows / n;
    snap.hoisted     = (double)c->perf_hoisted_uploads / n;
    snap.clr_folded  = (double)c->perf_clr_folded / n;
    snap.clr_materialized = (double)c->perf_clr_materialized / n;
    for (uint64_t &v : c->perf_split) v = 0;
    c->perf_dontcare_saves = c->perf_ring_overflows = c->perf_hoisted_uploads = 0;
    c->perf_clr_folded = c->perf_clr_materialized = 0;
    c->perf_last = snap;
    c->perf_win_frames = 0;
    c->perf_base_passes = c->pass_splits;
    c->perf_base_draws = c->draw_calls;
    c->perf_base_dispatches = c->dispatch_calls;
    c->perf_base_skips = c->enc_state_skips;
    c->perf_base_pso_builds = ps.pso_builds;
    c->perf_load_bytes = 0;
    c->perf_store_bytes = 0;
    if (out) *out = snap;
    if (ps_out) *ps_out = ps;
}

void bo3_context_perf_on_present(Bo3MetalContext *c, uint64_t frame_index) {
    if (!c || !c->perf_on_scope.load(std::memory_order_relaxed)) return;
    os_unfair_lock_lock(&c->lock);
    if (!c->perf_on) { os_unfair_lock_unlock(&c->lock); return; }
    c->perf_win_frames++;
    if (frame_index == 0 || (frame_index % 120) != 0) {
        os_unfair_lock_unlock(&c->lock);
        return;
    }
    Bo3PerfSnapshot snap = {};
    Bo3PsoCacheStats ps = {};
    perf_collect_window_locked(c, &snap, &ps);
    os_unfair_lock_unlock(&c->lock);
    fprintf(stderr, "[m5-perf] frame=%llu avg/frame over %llu: gpu_ms=%.3f cpu_encode_ms=%.3f passes=%.1f draws=%.1f "
                    "dispatches=%.1f tbdr_load_mb=%.2f tbdr_store_mb=%.2f | window: pso_builds=%llu "
                    "enc_state_skips=%llu | archive_hits=%llu refl_disk_hits=%llu\n",
            (unsigned long long)frame_index, (unsigned long long)snap.frames, snap.gpu_ms, snap.cpu_encode_ms,
            snap.passes, snap.draws, snap.dispatches, snap.tbdr_load_mb, snap.tbdr_store_mb,
            (unsigned long long)snap.pso_builds, (unsigned long long)snap.enc_state_skips,
            (unsigned long long)ps.pso_archive_hits, (unsigned long long)ps.refl_disk_hits);
    fprintf(stderr, "[m5-perf] frame=%llu pass-ends/frame: tgt=%.1f clr=%.1f blit=%.1f cmp=%.1f uav=%.1f pres=%.1f "
                    "flush=%.1f oth=%.1f | per-frame: dontcare_saves=%.1f clr_folded=%.1f clr_materialized=%.1f "
                    "hoisted=%.1f ring_ovf=%.2f\n",
            (unsigned long long)frame_index, snap.split_tgt, snap.split_clr, snap.split_blit, snap.split_cmp,
            snap.split_uav, snap.split_pres, snap.split_flush, snap.split_oth, snap.dontcare_saves,
            snap.clr_folded, snap.clr_materialized, snap.hoisted, snap.ring_ovf);
    fflush(stderr);
}

void bo3_context_perf_sample_hud(Bo3MetalContext *c, Bo3PerfSnapshot *out) {
    if (!out) return;
    *out = Bo3PerfSnapshot{};
    if (!c || !c->perf_on_scope.load(std::memory_order_relaxed)) return;
    os_unfair_lock_lock(&c->lock);
    if (!c->perf_on) { os_unfair_lock_unlock(&c->lock); return; }
    if (c->perf_win_frames > 0) {
        perf_collect_window_locked(c, out, nullptr);
    } else {
        *out = c->perf_last;
    }
    os_unfair_lock_unlock(&c->lock);
}

void bo3_context_perf_last(Bo3MetalContext *c, Bo3PerfSnapshot *out) {
    if (!out) return;
    *out = Bo3PerfSnapshot{};
    if (!c) return;
    os_unfair_lock_lock(&c->lock);
    *out = c->perf_last;
    os_unfair_lock_unlock(&c->lock);
}

// =========================================================================
// Present & Flush (blits offscreen_bb -> CAMetalDrawable when formats differ)
// =========================================================================

static id<MTLRenderPipelineState> ensure_blit_present_pso(Bo3MetalContext *c) {
    if (c->blit_present_pso) return c->blit_present_pso;
    @autoreleasepool {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                         "struct VOut { float4 pos [[position]]; float2 uv; };\n"
                         "vertex VOut vs_blit(uint vid [[vertex_id]]) {\n"
                         "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
                         "  VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1);\n"
                         "  o.uv = float2(p.x, 1.0 - p.y); return o;\n"
                         "}\n"
                         "fragment float4 fs_blit(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
                         "  constexpr sampler s(filter::linear);\n"
                         "  return float4(tex.sample(s, in.uv).rgb, 1.0);\n"
                         "}\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [c->device->mtl_dev newLibraryWithSource:src options:nil error:&err];
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs_blit"];
        d.fragmentFunction = [lib newFunctionWithName:@"fs_blit"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        c->blit_present_pso = bo3_pso_create_render(c->device->mtl_dev, d, &err, true);
    }
    return c->blit_present_pso;
}

// Commit the pending batch: upload_cmd_buf (hoisted uploads, A2) FIRST, then cmd_buf, on the same
// serial queue, under ONE fence value whose completion requires every command buffer of the batch.
// Caller holds c->lock. Returns the last committed command buffer (nil when nothing was pending).
id<MTLCommandBuffer> Bo3MetalContext::commit_pending_locked(Bo3SplitReason reason, bool materialize) {
    if (materialize) materialize_all_clears();
    end_active_encoder(reason);
    if (upload_blit_enc) {
        [upload_blit_enc endEncoding];
        upload_blit_enc = nil;
    }
    id<MTLCommandBuffer> ub = upload_cmd_buf;
    id<MTLCommandBuffer> mb = cmd_buf;
    upload_cmd_buf = nil;
    cmd_buf = nil;
    const int n = (ub ? 1 : 0) + (mb ? 1 : 0);
    if (n == 0) return nil;
    const uint64_t fence_val = submitted_fence.fetch_add(1, std::memory_order_relaxed) + 1;
    Bo3FenceJoin *join = new Bo3FenceJoin();
    join->remaining.store(n, std::memory_order_relaxed);
    Bo3FrameTiming *ft = nullptr;
    if (perf_on) {
        ft = ensure_frame_timing_locked();
        ft->remaining.fetch_add(n, std::memory_order_relaxed);
    }
    com.add_ref(); // released by the last completion handler of the batch
    Bo3MetalContext *ctx_raw = this;
    void (^handler)(id<MTLCommandBuffer>) = ^(id<MTLCommandBuffer> _Nonnull done) {
        if (ft) ctx_raw->perf_finish_cb_timing(ft, done);
        if (join->remaining.fetch_sub(1, std::memory_order_acq_rel) == 1) {
            uint64_t cur = ctx_raw->completed_fence.load(std::memory_order_relaxed);
            while (cur < fence_val &&
                   !ctx_raw->completed_fence.compare_exchange_weak(cur, fence_val, std::memory_order_release)) {}
            delete join;
            ctx_raw->com.release();
        }
    };
    if (ub) {
        [ub addCompletedHandler:handler];
        [ub commit];
    }
    if (mb) {
        [mb addCompletedHandler:handler];
        [mb commit];
    }
    last_committed_cb = mb ? mb : ub;
    return last_committed_cb;
}

void bo3_context_flush_now(Bo3MetalContext *c, bool wait) {
    if (!c) return;
    @autoreleasepool {
    os_unfair_lock_lock(&c->lock);
    // Explicit Flush() submits every pending clear so Clear -> End(EVENT) -> Flush -> GetData
    // always sees the clear on the GPU and transient cleared textures never accumulate.
    id<MTLCommandBuffer> wait_cb = c->commit_pending_locked(SPLIT_FLUSH, true);
    if (!wait_cb && wait) {
        if (c->last_committed_cb) {
            wait_cb = c->last_committed_cb;
        } else if (c->completed_fence.load(std::memory_order_acquire) < c->submitted_fence.load(std::memory_order_acquire)) {
            // Commit an empty marker command buffer on the same serial queue so waitUntilCompleted drains all prior work
            id<MTLCommandBuffer> marker = [c->device->mtl_queue commandBuffer];
            if (marker) {
                [marker commit];
                c->last_committed_cb = marker;
                wait_cb = marker;
            }
        }
    }
    os_unfair_lock_unlock(&c->lock);
    if (wait && wait_cb) [wait_cb waitUntilCompleted];
    }
}

// Non-blocking kick flush helper for DO_NOT_WAIT busy returns (never blocks on c->lock).
static void try_kick_flush(Bo3MetalContext *c) {
    if (!c) return;
    if (!os_unfair_lock_trylock(&c->lock)) return;
    c->commit_pending_locked(SPLIT_FLUSH, true);
    os_unfair_lock_unlock(&c->lock);
}

// Frame latency (BO3ARM_MAX_FRAME_LATENCY / SetMaximumFrameLatency): adjust frame_sem permits
// under sc->present_lock (which is held continuously through pcb commit so concurrent Presents
// can never deadlock while shrinking permits, and never held across dispatch_sync(main_queue)).
// For do_not_wait, outputs `*out_shrink` so any later busy return can roll back all permits cleanly.
static bool prepare_frame_latency_locked(Bo3MetalSwapChain *sc, uint32_t want, bool do_not_wait,
                                         bool *out_have_permit, uint32_t *out_shrink) {
    *out_have_permit = false;
    *out_shrink = 0;
    if (do_not_wait) {
        const uint32_t dc = sc->drawable_count.load(std::memory_order_acquire);
        const uint32_t max_queued_drawables = (dc > 1u) ? (dc - 1u) : 1u;
        const bool drawable_busy = sc->layer && sc->frame_index.load(std::memory_order_acquire) > 0 &&
                                   sc->drawables_in_flight &&
                                   sc->drawables_in_flight->load(std::memory_order_acquire) >= max_queued_drawables;
        if (drawable_busy) return false;
        while (sc->sem_permits < want) {
            dispatch_semaphore_signal(sc->frame_sem);
            sc->sem_permits++;
        }
        const uint32_t shrink = (sc->sem_permits > want) ? (sc->sem_permits - want) : 0u;
        const uint32_t need = shrink + 1u;
        uint32_t got = 0;
        while (got < need) {
            if (dispatch_semaphore_wait(sc->frame_sem, DISPATCH_TIME_NOW) != 0) break;
            got++;
        }
        if (got < need) {
            for (uint32_t i = 0; i < got; i++) dispatch_semaphore_signal(sc->frame_sem);
            return false;
        }
        sc->sem_permits -= shrink;
        *out_shrink = shrink;
        *out_have_permit = true;
    } else {
        while (sc->sem_permits < want) {
            dispatch_semaphore_signal(sc->frame_sem);
            sc->sem_permits++;
        }
        while (sc->sem_permits > want) {
            dispatch_semaphore_wait(sc->frame_sem, DISPATCH_TIME_FOREVER);
            sc->sem_permits--;
        }
    }
    return true;
}

// B1: MetalFX spatial upscale of `src` into the drawable (bb smaller than the drawable). Returns
// false when MetalFX is unavailable for this configuration (caller falls back to the blit path).
static bool encode_metalfx_present(Bo3MetalContext *c, Bo3MetalSwapChain *sc, id<MTLCommandBuffer> cb,
                                   id<MTLTexture> src, id<MTLTexture> dst) {
    if (!bo3_metalfx_enabled()) return false;
    const uint32_t iw = (uint32_t)src.width, ih = (uint32_t)src.height;
    const uint32_t ow = (uint32_t)dst.width, oh = (uint32_t)dst.height;
    if (iw > ow || ih > oh || (iw == ow && ih == oh)) return false; // 1:1 or any-axis downscale: plain blit
    static bool supported = false;
    static std::once_flag once;
    std::call_once(once, [&] {
        supported = [MTLFXSpatialScalerDescriptor supportsDevice:c->device->mtl_dev];
        fprintf(stderr, "[metalfx] MTLFXSpatialScaler %s on this GPU\n", supported ? "supported" : "NOT supported");
        fflush(stderr);
    });
    if (!supported) return false;
    if (!sc->fx_scaler || sc->fx_in_w != iw || sc->fx_in_h != ih || sc->fx_out_w != ow || sc->fx_out_h != oh ||
        sc->fx_in_fmt != src.pixelFormat || sc->fx_out_fmt != dst.pixelFormat) {
        if (sc->fx_failed && sc->fx_in_w == iw && sc->fx_in_h == ih && sc->fx_out_w == ow && sc->fx_out_h == oh &&
            sc->fx_in_fmt == src.pixelFormat && sc->fx_out_fmt == dst.pixelFormat) {
            return false;
        }
        sc->fx_scaler = nil;
        sc->fx_out_tex = nil;
        sc->fx_in_w = iw; sc->fx_in_h = ih; sc->fx_out_w = ow; sc->fx_out_h = oh;
        sc->fx_in_fmt = src.pixelFormat; sc->fx_out_fmt = dst.pixelFormat;
        MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
        d.colorTextureFormat = src.pixelFormat;
        d.outputTextureFormat = dst.pixelFormat;
        d.inputWidth = iw;
        d.inputHeight = ih;
        d.outputWidth = ow;
        d.outputHeight = oh;
        d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual; // LDR / gamma-encoded
        sc->fx_scaler = [d newSpatialScalerWithDevice:c->device->mtl_dev];
        sc->fx_failed = (sc->fx_scaler == nil);
        if (sc->fx_scaler) {
            // MetalFXSpatialScaler requires MTLStorageModePrivate on both colorTexture and
            // outputTexture (CAMetalDrawable.texture is MTLStorageModeShared on Apple Silicon).
            const MTLTextureUsage need = sc->fx_scaler.outputTextureUsage;
            sc->fx_direct = (dst.storageMode == MTLStorageModePrivate) && ((dst.usage & need) == need);
            if (!sc->fx_direct) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:dst.pixelFormat
                                                                                              width:ow height:oh
                                                                                          mipmapped:NO];
                td.storageMode = MTLStorageModePrivate;
                td.usage = need | MTLTextureUsageShaderRead;
                sc->fx_out_tex = [c->device->mtl_dev newTextureWithDescriptor:td];
                if (!sc->fx_out_tex) { sc->fx_scaler = nil; sc->fx_failed = true; }
            }
        }
        fprintf(stderr, "[metalfx] spatial scaler %ux%u (fmt %lu) -> %ux%u (fmt %lu): %s%s\n", iw, ih,
                (unsigned long)src.pixelFormat, ow, oh, (unsigned long)dst.pixelFormat,
                sc->fx_scaler ? "OK" : "FAILED (falling back to blit)",
                sc->fx_scaler ? (sc->fx_direct ? " [direct to drawable]" : " [via intermediate]") : "");
        fflush(stderr);
        if (!sc->fx_scaler) return false;
    }
    if (src.storageMode != MTLStorageModePrivate ||
        (src.usage & sc->fx_scaler.colorTextureUsage) != sc->fx_scaler.colorTextureUsage) {
        return false;
    }
    sc->fx_scaler.colorTexture = src;
    sc->fx_scaler.inputContentWidth = iw;
    sc->fx_scaler.inputContentHeight = ih;
    sc->fx_scaler.outputTexture = sc->fx_direct ? dst : sc->fx_out_tex;
    [sc->fx_scaler encodeToCommandBuffer:cb];
    if (!sc->fx_direct) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:sc->fx_out_tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(ow, oh, 1)
                    toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
    }
    sc->fx_scaler.colorTexture = nil;  // never keep the backbuffer / drawable alive via the scaler
    sc->fx_scaler.outputTexture = nil;
    return true;
}

uint32_t bo3_context_present_flush(Bo3MetalContext *c, Bo3MetalSwapChain *sc,
                                   uint32_t sync_interval, uint32_t flags) {
    if (!c || !sc) return BO3_E_INVALIDARG;
    @autoreleasepool {
    const bool do_not_wait = (flags & BO3_DXGI_PRESENT_DO_NOT_WAIT) != 0;
    const uint32_t want = bo3_dxgi_effective_frame_latency(sc->device);
    const uint32_t want_dc = std::clamp(want, 2u, 3u);
    CAMetalLayer *layer = sc->layer;
    const uint64_t hwnd = sc->desc.OutputWindow;

    // Step 0 (NO locks held, blocking Present only): apply any CAMetalLayer main-queue updates
    // BEFORE taking present_lock, so present_lock is NEVER held across dispatch_sync(main_queue).
    // Also sync drawableSize live when the user toggles MetalFX ON/OFF mid-session!
    if (layer && !do_not_wait) {
        uint32_t bb_w = 0, bb_h = 0, cur_dw = 0, cur_dh = 0, rscale = 100;
        bool is_fs = false;
        os_unfair_lock_lock(&sc->present_lock);
        bb_w = sc->desc.BufferDesc.Width;
        bb_h = sc->desc.BufferDesc.Height;
        cur_dw = sc->native_w;
        cur_dh = sc->native_h;
        rscale = sc->render_scale;
        is_fs = sc->fullscreen;
        os_unfair_lock_unlock(&sc->present_lock);

        uint32_t want_dw = cur_dw, want_dh = cur_dh;
        if (bb_w > 0 && bb_h > 0) {
            bo3_dxgi_compute_drawable_size(hwnd, bb_w, bb_h, rscale, is_fs, &want_dw, &want_dh);
        }
        const bool need_size = (want_dw > 0 && want_dh > 0 && (want_dw != cur_dw || want_dh != cur_dh));
        const bool need_dc = (sc->drawable_count.load(std::memory_order_acquire) != want_dc);
        const bool need_sync = (sc->last_sync_interval.load(std::memory_order_acquire) != sync_interval);
        if (need_dc || need_sync || need_size) {
            if (need_size) {
                os_unfair_lock_lock(&sc->present_lock);
                sc->native_w = want_dw;
                sc->native_h = want_dh;
                bo3_win_update_swapchain_sizes(hwnd, sc, (int32_t)bb_w, (int32_t)bb_h, (int32_t)want_dw, (int32_t)want_dh);
                os_unfair_lock_unlock(&sc->present_lock);
            }
            BOOL want_sync = (sync_interval > 0) ? YES : NO;
            auto upd = ^{
                int32_t ldw = (int32_t)want_dw, ldh = (int32_t)want_dh;
                if (need_size) bo3_win_get_drawable_size(hwnd, &ldw, &ldh);
                bo3_win_lock_layer(hwnd);
                if (need_size && ldw > 0 && ldh > 0) {
                    layer.drawableSize = CGSizeMake(ldw, ldh);
                }
                if (need_dc) {
                    layer.maximumDrawableCount = want_dc;
                    sc->drawable_count.store(want_dc, std::memory_order_release);
                }
                if (need_sync) {
                    layer.displaySyncEnabled = want_sync;
                    sc->last_sync_interval.store(sync_interval, std::memory_order_release);
                }
                bo3_win_unlock_layer(hwnd);
            };
            if ([NSThread isMainThread]) upd();
            else dispatch_sync(dispatch_get_main_queue(), upd);
        }
    }

    // Hold present_lock continuously across latency permits, Step 1, Step 2, and Step 3 (pcb commit):
    // - No main-queue dispatch happens while held (zero main-thread deadlock)
    // - No concurrent presenter can hold a permit while waiting on present_lock (zero shrink deadlock)
    // - drawables_in_flight cannot miss a concurrent presenter in Step 2
    if (do_not_wait) {
        if (!os_unfair_lock_trylock(&sc->present_lock)) {
            try_kick_flush(c);
            return BO3_DXGI_ERROR_WAS_STILL_DRAWING;
        }
    } else {
        os_unfair_lock_lock(&sc->present_lock);
    }

    bool have_permit = false;
    uint32_t shrunk_permits = 0;
    if (!prepare_frame_latency_locked(sc, want, do_not_wait, &have_permit, &shrunk_permits)) {
        os_unfair_lock_unlock(&sc->present_lock);
        try_kick_flush(c);
        return BO3_DXGI_ERROR_WAS_STILL_DRAWING;
    }

    auto rollback_and_busy = [&]() -> uint32_t {
        if (shrunk_permits > 0) {
            sc->sem_permits += shrunk_permits;
            for (uint32_t i = 0; i < shrunk_permits; i++) dispatch_semaphore_signal(sc->frame_sem);
        }
        if (have_permit) dispatch_semaphore_signal(sc->frame_sem);
        os_unfair_lock_unlock(&sc->present_lock);
        return BO3_DXGI_ERROR_WAS_STILL_DRAWING;
    };

    // A3 step 1: commit the frame's GPU work FIRST so the GPU starts executing frame N right away,
    // without waiting on the frame-latency semaphore or on [layer nextDrawable].
    {
        Bo3PerfScope perf_scope(c);
        if (do_not_wait) {
            if (!os_unfair_lock_trylock(&c->lock)) return rollback_and_busy();
        } else {
            os_unfair_lock_lock(&c->lock);
        }
        c->commit_pending_locked(SPLIT_PRES, true); // materializes every deferred clear (incl. backbuffer)
        os_unfair_lock_unlock(&c->lock);
    }

    // Step 2: frame pacing + drawable acquisition (never under c->lock)
    if (!have_permit) {
        dispatch_semaphore_wait(sc->frame_sem, DISPATCH_TIME_FOREVER);
        have_permit = true;
    }
    id<CAMetalDrawable> drawable = nil;
    if (layer) {
        if (do_not_wait) {
            if (!bo3_win_trylock_layer(hwnd)) return rollback_and_busy();
        } else {
            bo3_win_lock_layer(hwnd);
        }
        drawable = [layer nextDrawable];
        bo3_win_unlock_layer(hwnd);
        if (do_not_wait && !drawable) return rollback_and_busy();
    }

    // Step 3: tiny present command buffer (present_lock -> c->lock)
    Bo3PerfScope perf_scope(c);
    if (do_not_wait) {
        if (!os_unfair_lock_trylock(&c->lock)) return rollback_and_busy();
    } else {
        os_unfair_lock_lock(&c->lock);
    }
    // If another thread opened GPU work during Step 2, commit it BEFORE pcb on the serial queue so
    // pcb sits strictly after all prior work and never races with upload_ring or resource fences.
    if (c->cmd_buf || c->upload_cmd_buf || !c->pending_clear_texs.empty()) {
        c->commit_pending_locked(SPLIT_PRES, true);
    }
    id<MTLCommandBuffer> pcb = [c->device->mtl_queue commandBuffer];
    if (!pcb) {
        os_unfair_lock_unlock(&c->lock);
        if (shrunk_permits > 0) {
            sc->sem_permits += shrunk_permits;
            for (uint32_t i = 0; i < shrunk_permits; i++) dispatch_semaphore_signal(sc->frame_sem);
        }
        os_unfair_lock_unlock(&sc->present_lock);
        dispatch_semaphore_signal(sc->frame_sem);
        return BO3_E_FAIL;
    }
    pcb.label = @"BO3_Present";

    std::shared_ptr<std::atomic<uint32_t>> drawable_dif;
    std::shared_ptr<std::atomic<bool>> drawable_rel;
    id<MTLTexture> bb = sc->acquire_backbuffer_texture();
    if (drawable && bb) {
        // Non-sRGB view of an _SRGB backbuffer so raw sRGB-encoded values reach the BGRA8 drawable
        // unchanged (sRGB twin views need no PixelFormatView).
        id<MTLTexture> src_bb = bb;
        if (bb.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB || bb.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB) {
            MTLPixelFormat linear_pf = (bb.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB)
                                       ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatBGRA8Unorm;
            if (bo3_mtl_can_view_as(bb.pixelFormat, bb.usage, linear_pf)) {
                id<MTLTexture> v = [bb newTextureViewWithPixelFormat:linear_pf];
                if (v) src_bb = v;
            }
        }
        id<MTLTexture> dtex = drawable.texture;
        bool used_fx = encode_metalfx_present(c, sc, pcb, src_bb, dtex);
        sc->last_metalfx_active.store(used_fx, std::memory_order_release);
        if (used_fx) {
            // upscaled by MetalFX
        } else if (bb.pixelFormat == dtex.pixelFormat && bb.width == dtex.width && bb.height == dtex.height) {
            id<MTLBlitCommandEncoder> blit = [pcb blitCommandEncoder];
            [blit copyFromTexture:bb sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(bb.width, bb.height, 1)
                        toTexture:dtex destinationSlice:0 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
        } else {
            // Format/scale-converting fullscreen triangle blit into CAMetalDrawable
            id<MTLRenderPipelineState> pso = ensure_blit_present_pso(c);
            if (pso) {
                MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                rpd.colorAttachments[0].texture = dtex;
                rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> enc = [pcb renderCommandEncoderWithDescriptor:rpd];
                if (enc) {
                    c->pass_splits++;
                    if (c->perf_on) c->perf_account_pass(rpd);
                    [enc setRenderPipelineState:pso];
                    [enc setFragmentTexture:src_bb atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    [enc endEncoding];
                }
            }
        }
        if (sc->drawables_in_flight) {
            drawable_dif = sc->drawables_in_flight;
            drawable_rel = std::make_shared<std::atomic<bool>>(false);
            drawable_dif->fetch_add(1, std::memory_order_relaxed);
            auto dif_cap = drawable_dif;
            auto rel_cap = drawable_rel;
            [drawable addPresentedHandler:^(id<MTLDrawable> _Nonnull) {
                if (!rel_cap->exchange(true, std::memory_order_acq_rel)) {
                    dif_cap->fetch_sub(1, std::memory_order_release);
                }
            }];
        }
        [pcb presentDrawable:drawable];
    }

    // Seal this frame's GPU timing accumulator (transfers the open-frame ref to pcb so the frame's
    // total GPU time and frame count publish atomically once all CBs of the frame complete).
    Bo3MetalContext::Bo3FrameTiming *ft = nullptr;
    if (c->perf_on) {
        ft = c->ensure_frame_timing_locked();
        ft->counted_frame = true;
        c->cur_frame_timing = nullptr;
        if (!bo3_perf_enabled()) c->perf_win_frames++;
    }
    // Note: pcb deliberately does NOT advance submitted_fence / completed_fence, which track
    // committed D3D11 batches exclusively (so pcb can never complete a fence tagged by an
    // uncommitted batch). last_committed_cb still tracks pcb for synchronous GPU drains.
    dispatch_semaphore_t sem = sc->frame_sem;
    c->com.add_ref();
    Bo3MetalContext *ctx_raw = c;
    [pcb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
        if (ft) ctx_raw->perf_finish_cb_timing(ft, done);
        if (drawable_rel && done.status == MTLCommandBufferStatusError) {
            if (!drawable_rel->exchange(true, std::memory_order_acq_rel)) {
                drawable_dif->fetch_sub(1, std::memory_order_release);
            }
        }
        dispatch_semaphore_signal(sem);
        ctx_raw->com.release();
    }];
    [pcb commit];
    c->last_committed_cb = pcb;
    c->upload_ring.advance_frame(c->device->mtl_dev, c->completed_fence.load(std::memory_order_acquire), ^{
        // OOM path only: the queue is serial, so the last committed buffer completing drains all GPU work
        [pcb waitUntilCompleted];
    });
    c->cur_frame_no = sc->frame_index.load(std::memory_order_relaxed) + 1;
    os_unfair_lock_unlock(&c->lock);
    os_unfair_lock_unlock(&sc->present_lock);
    return BO3_S_OK;
    }
}

void bo3_context_push_debug_marker(Bo3MetalContext *c, const char *name) {
    if (!c || !name || !name[0]) return;
    @autoreleasepool {
    os_unfair_lock_lock(&c->lock);
    if (c->enc_mode == ENC_RENDER && c->render_enc) {
        NSString *ns = [NSString stringWithUTF8String:name];
        if (ns) [c->render_enc insertDebugSignpost:ns];
    }
    os_unfair_lock_unlock(&c->lock);
    }
}

// =========================================================================
// ID3D11DeviceContext COM Methods (Windows exact vtable slots 7..114)
// =========================================================================

// Helper macro to replace array of COM pointers safely
template <typename T>
static void set_obj_array(T **dst, uint32_t start, uint32_t count, uint32_t cap, T *const *src) {
    if (start >= cap) return;
    uint32_t end = std::min(start + count, cap);
    for (uint32_t i = start; i < end; i++) {
        T *nw = src ? src[i - start] : nullptr;
        if (dst[i] == nw) continue; // A5: unchanged slot -> no AddRef/Release churn
        if (nw) ((Bo3ComBase *)nw)->add_ref();
        if (dst[i]) ((Bo3ComBase *)dst[i])->release();
        dst[i] = nw;
    }
}

// D3D11 *SetShaderResources contract: an incoming SRV whose subresource range overlaps a bound
// output (RTV, writable DSV aspect, OM/CS UAV) is forced to NULL; the output stays bound.
static void set_srvs_checked(Bo3MetalContext *c, Bo3MetalSRV **dst, uint32_t start, uint32_t count,
                             Bo3MetalSRV *const *srvs) {
    if (start >= 128) return;
    count = std::min(count, 128u - start);
    if (!srvs) {
        set_obj_array(dst, start, count, 128, srvs);
        return;
    }
    Bo3MetalSRV *filtered[128];
    for (uint32_t i = 0; i < count; i++) {
        Bo3MetalSRV *v = srvs[i];
        if (v && c->srv_conflicts_with_outputs(v)) {
            static std::atomic<int> warn{0};
            if (warn.fetch_add(1, std::memory_order_relaxed) < 10) {
                fprintf(stderr, "[metal-ctx] SRV slot %u still bound on output -> forcing NULL (D3D11 hazard rule)\n",
                        start + i);
                fflush(stderr);
            }
            v = nullptr;
        }
        filtered[i] = v;
    }
    set_obj_array(dst, start, count, 128, (Bo3MetalSRV *const *)filtered);
}

// slot 7: VSSetConstantBuffers
static SHIM_DEF(ctx_vs_set_cb) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    set_obj_array(c->vs_cb, (uint32_t)rsi, (uint32_t)rdx, 14, (Bo3MetalBuffer *const *)rcx);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 8: PSSetShaderResources
static SHIM_DEF(ctx_ps_set_srv) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    uint32_t start = (uint32_t)rsi, count = (uint32_t)rdx;
    Bo3MetalSRV *const *srvs = (Bo3MetalSRV *const *)rcx;
    os_unfair_lock_lock(&c->lock);
    set_srvs_checked(c, c->ps_srv, start, count, srvs);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 9: PSSetShader
static SHIM_DEF(ctx_ps_set_shader) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalShader *s = (Bo3MetalShader *)rsi;
    os_unfair_lock_lock(&c->lock);
    if (c->ps != s) {
        if (s) s->com.add_ref();
        if (c->ps) c->ps->com.release();
        c->ps = s;
        c->pso_dirty = true;
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 10: PSSetSamplers
static SHIM_DEF(ctx_ps_set_samplers) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    set_obj_array(c->ps_smp, (uint32_t)rsi, (uint32_t)rdx, 16, (Bo3MetalSamplerState *const *)rcx);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 11: VSSetShader
static SHIM_DEF(ctx_vs_set_shader) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalShader *s = (Bo3MetalShader *)rsi;
    os_unfair_lock_lock(&c->lock);
    if (c->vs != s) {
        if (s) s->com.add_ref();
        if (c->vs) c->vs->com.release();
        c->vs = s;
        c->pso_dirty = true;
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 12: DrawIndexed(IndexCount, StartIndexLocation, BaseVertexLocation)
static SHIM_DEF(ctx_draw_indexed) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3PerfScope perf_scope(c);
    uint32_t count = (uint32_t)rsi;
    uint32_t start = (uint32_t)rdx;
    int32_t  base_v = (int32_t)rcx;
    if (count == 0) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (c->ib && prepare_draw(c)) {
        c->touch_buf(c->ib);
        id<MTLBuffer> ibuf = c->ib->cur_buf();
        const uint64_t ilen = c->ib->cur_len();
        uint64_t ib_base = c->ib->cur_base();
        uint32_t idx_sz = (c->ib_type == MTLIndexTypeUInt32) ? 4 : 2;
        uint64_t off = ib_base + c->ib_offset + (uint64_t)start * idx_sz;
        uint64_t need = (uint64_t)count * idx_sz;
        if (ibuf && (off % idx_sz) == 0 && off <= ilen && need <= (ilen - off)) {
            [c->render_enc drawIndexedPrimitives:d3d_topo_to_mtl(c->topology)
                                      indexCount:count
                                       indexType:c->ib_type
                                     indexBuffer:ibuf
                               indexBufferOffset:off
                                   instanceCount:1
                                      baseVertex:base_v
                                    baseInstance:0];
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 13: Draw(VertexCount, StartVertexLocation)
static SHIM_DEF(ctx_draw) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3PerfScope perf_scope(c);
    uint32_t count = (uint32_t)rsi;
    uint32_t start = (uint32_t)rdx;
    if (count == 0) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (prepare_draw(c)) {
        [c->render_enc drawPrimitives:d3d_topo_to_mtl(c->topology) vertexStart:start vertexCount:count];
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// Wait (CPU) until every encoded GPU access to `res` has completed. Only stalls when the
// resource's own last_gpu_fence is still pending (never a blanket whole-GPU stall).
// Must be called WITHOUT c->lock held. Returns false when DO_NOT_WAIT and still busy.
static bool wait_resource_idle(Bo3MetalContext *c, Bo3MetalResource *res, bool do_not_wait) {
    uint64_t lf = res->last_gpu_fence.load(std::memory_order_acquire);
    if (lf == 0 || c->completed_fence.load(std::memory_order_acquire) >= lf) return true;
    const bool unsubmitted = lf > c->submitted_fence.load(std::memory_order_acquire);
    if (do_not_wait) {
        if (unsubmitted) bo3_context_flush_now(c, false); // D3D11 flushes so the work makes progress
        return false;
    }
    bo3_context_flush_now(c, true); // commits pending work (if any) and waits the serial queue tail
    return true;
}

// A2: staging memory for a texture upload. Upload ring when it fits (<= 1/4 ring slot), else a
// dedicated shared buffer (counted as a ring overflow). Caller holds c->lock.
static bool alloc_upload_staging(Bo3MetalContext *c, size_t bytes, id<MTLBuffer> __strong *buf, uint64_t *off,
                                 uint8_t **ptr) {
    if (bytes == 0) return false;
    if (bytes <= Bo3UploadRing::CHUNK_SIZE / 4) {
        void *p = nullptr;
        id<MTLBuffer> rb = nil;
        if (c->upload_ring.alloc(bytes, 256, c->pending_fence(), &rb, off, &p)) {
            *buf = rb;
            *ptr = (uint8_t *)p;
            return true;
        }
    }
    if (c->perf_on) c->perf_ring_overflows++;
    id<MTLBuffer> b = [c->device->mtl_dev newBufferWithLength:std::max<size_t>(bytes, 16)
                                                       options:MTLResourceStorageModeShared];
    if (!b) return false;
    *buf = b;
    *off = 0;
    *ptr = (uint8_t *)b.contents;
    return true;
}

// A2: blit encoder for an upload into `r`. While a render pass is open and nothing in cmd_buf has
// referenced `r` yet, the upload is hoisted into upload_cmd_buf (committed right before cmd_buf on the
// same serial queue -> D3D11 order preserved) and the render pass stays open. Otherwise the upload
// goes to the main command buffer exactly as before (ending the open pass).
static id<MTLBlitCommandEncoder> upload_encoder_for(Bo3MetalContext *c, Bo3MetalResource *r) {
    if (c->can_hoist(r)) {
        id<MTLBlitCommandEncoder> e = c->hoist_blit_encoder();
        if (e) {
            c->mark_hoisted(r);
            return e;
        }
    }
    c->touch(r);
    c->ensure_blit_encoder();
    return c->blit_enc;
}

static Bo3SubRange subres_range(Bo3MetalResource *r, uint32_t mip, uint32_t slice) {
    Bo3SubRange s;
    s.res = r;
    s.mip0 = mip; s.mip_cnt = 1;
    s.sl0 = slice; s.sl_cnt = 1;
    return s;
}

// slot 14: Map(pResource, Subresource, MapType, MapFlags, pMappedResource)
static SHIM_DEF(ctx_map) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalResource *res = (Bo3MetalResource *)rsi;
    uint32_t subres = (uint32_t)rdx;
    uint32_t map_type = (uint32_t)rcx;
    uint32_t map_flags = (uint32_t)r8;
    Bo3D3D11_MAPPED_SUBRESOURCE *out = (Bo3D3D11_MAPPED_SUBRESOURCE *)r9;
    if (!res || !out) return ret_u64(BO3_E_INVALIDARG);
    @autoreleasepool {
    const bool do_not_wait = (map_flags & BO3_D3D11_MAP_FLAG_DO_NOT_WAIT) != 0;
    const bool cpu_reads = (map_type == BO3_D3D11_MAP_READ || map_type == BO3_D3D11_MAP_READ_WRITE);

    if (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalBuffer *b = (Bo3MetalBuffer *)res;
        const bool discard_like = b->is_dynamic &&
            (map_type == BO3_D3D11_MAP_WRITE_DISCARD || map_type == BO3_D3D11_MAP_WRITE_NO_OVERWRITE);
        if (!discard_like) {
            // Non-discard READ / WRITE / READ_WRITE on mtl_buf (staging): per-resource fence wait
            if (!wait_resource_idle(c, res, do_not_wait)) {
                out->pData = nullptr;
                return ret_u64(BO3_DXGI_ERROR_WAS_STILL_DRAWING);
            }
        }
        os_unfair_lock_lock(&c->lock);
        if (b->is_dynamic && map_type == BO3_D3D11_MAP_WRITE_DISCARD) {
            id<MTLBuffer> rbuf = nil;
            uint64_t roff = 0;
            void *rptr = nullptr;
            if (c->upload_ring.alloc(b->desc.ByteWidth, 256, c->pending_fence(), &rbuf, &roff, &rptr)) {
                b->set_dyn(rbuf, roff, Bo3UploadRing::CHUNK_SIZE);
                b->mapped_ptr = rptr;
                c->upload_ring.track_dynamic_user(b);
            } else {
                // Overflow fallback: allocate dedicated shared buffer
                const size_t dsz = std::max<size_t>(b->desc.ByteWidth, 256);
                id<MTLBuffer> ded = [c->device->mtl_dev newBufferWithLength:dsz
                                                                    options:MTLResourceStorageModeShared];
                if (!ded) {
                    os_unfair_lock_unlock(&c->lock);
                    out->pData = nullptr;
                    return ret_u64(BO3_E_OUTOFMEMORY);
                }
                if (c->perf_on) c->perf_ring_overflows++;
                b->set_dyn(ded, 0, dsz);
                b->dyn_epoch = 0;
                b->mapped_ptr = ded.contents;
            }
        } else if (b->is_dynamic && map_type == BO3_D3D11_MAP_WRITE_NO_OVERWRITE) {
            if (!b->dyn_buf) {
                b->set_dyn(b->mtl_buf, 0, b->mtl_len);
                b->dyn_epoch = 0;
            }
            b->mapped_ptr = (uint8_t *)b->dyn_buf.contents + b->dyn_offset;
        } else {
            // Writing directly to mtl_buf: fold any renamed ring copy back first (CPU side, now idle)
            if (b->dyn_buf && b->dyn_buf != b->mtl_buf && b->desc.ByteWidth > 0) {
                memcpy(b->mtl_buf.contents, (const uint8_t *)b->dyn_buf.contents + b->dyn_offset,
                       std::min<size_t>(b->desc.ByteWidth, b->mtl_buf.length));
            }
            b->clear_dyn();
            b->mapped_ptr = b->mtl_buf.contents;
        }
        out->pData = b->mapped_ptr;
        out->RowPitch = b->desc.ByteWidth;
        out->DepthPitch = b->desc.ByteWidth;
        os_unfair_lock_unlock(&c->lock);
        return ret_u64(BO3_S_OK);
    }

    Bo3MetalTexture *t = (Bo3MetalTexture *)res;
    if (cpu_reads) {
        os_unfair_lock_lock(&c->lock);
        c->materialize_res(res, whole_range(res)); // a deferred clear must be visible to the CPU read
        os_unfair_lock_unlock(&c->lock);
    }
    if (cpu_reads && !wait_resource_idle(c, res, do_not_wait)) {
        out->pData = nullptr;
        return ret_u64(BO3_DXGI_ERROR_WAS_STILL_DRAWING);
    }
    os_unfair_lock_lock(&c->lock);
    const bool is_3d = (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D);
    const bool is_1d = (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE1D);
    uint32_t mips = t->d3d_mip_levels();
    uint32_t mip = subres % mips;
    uint32_t slice = is_3d ? 0u : (subres / mips);
    uint32_t base_w = is_3d ? t->desc3d.Width  : t->desc2d.Width;
    uint32_t base_h = is_3d ? t->desc3d.Height : t->desc2d.Height;
    uint32_t base_d = is_3d ? t->desc3d.Depth  : 1u;
    uint32_t mw = std::max(1u, base_w >> mip);
    uint32_t mh = std::max(1u, base_h >> mip);
    uint32_t md = is_3d ? std::max(1u, base_d >> mip) : 1u;
    uint32_t row_p = 0, slice_p = 0, rows = 0;
    bo3_format_calc_pitch(t->dxgi_format, mw, mh, &row_p, &slice_p, &rows);
    size_t total = (size_t)slice_p * md;
    Bo3MappedSubres &ms = t->mapped_subres[subres];
    ms.map_type = map_type;
    ms.row_pitch = row_p;
    ms.slice_pitch = slice_p;
    ms.w = mw; ms.h = mh; ms.d = md;
    ms.data.resize(std::max<size_t>(total, 64));
    if (cpu_reads) {
        id<MTLTexture> mt = t->current_mtl_texture();
        if (mt && mt.storageMode == MTLStorageModeShared && mip < mt.mipmapLevelCount) {
            MTLRegion reg = is_3d ? MTLRegionMake3D(0, 0, 0, mw, mh, md) : MTLRegionMake2D(0, 0, mw, mh);
            if (bo3_format_is_rgb32(t->dxgi_format)) {
                // Metal RGBA32 texels are 16 bytes; narrow to the 12-byte guest layout
                uint32_t mrp = mw * 16u;
                std::vector<uint8_t> tmp((size_t)mrp * mh * md);
                [mt getBytes:tmp.data() bytesPerRow:(is_1d ? 0u : mrp)
               bytesPerImage:(is_1d ? 0u : mrp * mh)
                  fromRegion:reg mipmapLevel:mip slice:slice];
                for (uint32_t z = 0; z < md; z++)
                    for (uint32_t r = 0; r < mh; r++)
                        bo3_rgb32_narrow_row(ms.data.data() + (size_t)z * slice_p + (size_t)r * row_p,
                                             tmp.data() + ((size_t)z * mh + r) * mrp, mw);
            } else {
                [mt getBytes:ms.data.data() bytesPerRow:(is_1d ? 0u : row_p)
               bytesPerImage:(is_1d ? 0u : slice_p)
                  fromRegion:reg mipmapLevel:mip slice:slice];
            }
        }
    }
    out->pData = ms.data.data();
    out->RowPitch = row_p;
    out->DepthPitch = slice_p;
    os_unfair_lock_unlock(&c->lock);
    return ret_u64(BO3_S_OK);
    }
}
// slot 15: Unmap(pResource, Subresource)
static SHIM_DEF(ctx_unmap) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalResource *res = (Bo3MetalResource *)rsi;
    uint32_t subres = (uint32_t)rdx;
    if (!res) return ret_void();
    if (res->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        @autoreleasepool {
        Bo3MetalTexture *t = (Bo3MetalTexture *)res;
        os_unfair_lock_lock(&c->lock);
        auto it = t->mapped_subres.find(subres);
        if (it != t->mapped_subres.end()) {
            const Bo3MappedSubres &ms = it->second;
            if (!ms.data.empty() && ms.map_type != BO3_D3D11_MAP_READ) {
                const bool is_3d = (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D);
                const bool is_1d = (res->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE1D);
                uint32_t mips = t->d3d_mip_levels();
                uint32_t mip = subres % mips;
                uint32_t slice = is_3d ? 0u : (subres / mips);
                size_t total = (size_t)ms.slice_pitch * ms.d;
                id<MTLTexture> mt = t->current_mtl_texture();
                if (mt && total > 0 && total <= ms.data.size() && mip < mt.mipmapLevelCount) {
                    uint8_t uploaded_aspects = 0;
                    if (mt.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
                        id<MTLBlitCommandEncoder> enc = upload_encoder_for(c, res);
                        uploaded_aspects = bo3_encode_depth_stencil_upload(c->device->mtl_dev, enc, mt, t->dxgi_format,
                                                                           slice, mip, 0, 0, ms.w, ms.h,
                                                                           ms.data.data(), ms.row_pitch);
                    } else {
                        const bool rgb32 = bo3_format_is_rgb32(t->dxgi_format);
                        uint32_t up_rp = rgb32 ? ms.w * 16u : ms.row_pitch;
                        uint32_t up_sp = rgb32 ? up_rp * ms.h : ms.slice_pitch;
                        id<MTLBuffer> stg = nil;
                        uint64_t soff = 0;
                        uint8_t *sp = nullptr;
                        const size_t bytes = rgb32 ? (size_t)up_sp * ms.d : total;
                        if (alloc_upload_staging(c, bytes, &stg, &soff, &sp)) {
                            if (rgb32) {
                                for (uint32_t z = 0; z < ms.d; z++)
                                    for (uint32_t r = 0; r < ms.h; r++)
                                        bo3_rgb32_expand_row(sp + (size_t)z * up_sp + (size_t)r * up_rp,
                                                             ms.data.data() + (size_t)z * ms.slice_pitch + (size_t)r * ms.row_pitch,
                                                             ms.w, t->dxgi_format);
                            } else {
                                memcpy(sp, ms.data.data(), total);
                            }
                            id<MTLBlitCommandEncoder> enc = upload_encoder_for(c, res);
                            if (enc) {
                                [enc copyFromBuffer:stg sourceOffset:soff
                                  sourceBytesPerRow:(is_1d ? 0u : up_rp)
                                sourceBytesPerImage:(is_1d ? 0u : up_sp)
                                         sourceSize:MTLSizeMake(ms.w, ms.h, ms.d)
                                          toTexture:mt destinationSlice:slice destinationLevel:mip
                                  destinationOrigin:MTLOriginMake(0, 0, 0)];
                                uploaded_aspects = BO3_ASPECT_ALL;
                            }
                        }
                    }
                    if (uploaded_aspects && !t->pending_clears.empty()) {
                        Bo3SubRange dr = subres_range(res, mip, slice);
                        dr.aspect = uploaded_aspects;
                        c->drop_clears(t, dr);
                    }
                }
            }
            t->mapped_subres.erase(it);
        }
        os_unfair_lock_unlock(&c->lock);
        }
    }
    return ret_void();
}
// slot 16: PSSetConstantBuffers
static SHIM_DEF(ctx_ps_set_cb) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    set_obj_array(c->ps_cb, (uint32_t)rsi, (uint32_t)rdx, 14, (Bo3MetalBuffer *const *)rcx);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 17: IASetInputLayout
static SHIM_DEF(ctx_ia_set_input_layout) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalInputLayout *il = (Bo3MetalInputLayout *)rsi;
    os_unfair_lock_lock(&c->lock);
    if (c->input_layout != il) {
        if (il) il->com.add_ref();
        if (c->input_layout) c->input_layout->com.release();
        c->input_layout = il;
        c->pso_dirty = true;
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 18: IASetVertexBuffers(StartSlot, NumBuffers, ppVBs, pStrides, pOffsets)
static SHIM_DEF(ctx_ia_set_vbs) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    uint32_t start = (uint32_t)rsi;
    uint32_t count = (uint32_t)rdx;
    Bo3MetalBuffer *const *vbs = (Bo3MetalBuffer *const *)rcx;
    const uint32_t *strides = (const uint32_t *)r8;
    const uint32_t *offsets = (const uint32_t *)r9;
    os_unfair_lock_lock(&c->lock);
    set_obj_array(c->vbs, start, count, 16, vbs);
    for (uint32_t i = 0; i < count && start + i < 16; i++) {
        const uint32_t st = strides ? strides[i] : 0;
        if (c->vb_strides[start + i] != st) c->pso_dirty = true; // strides are part of the PSO key
        c->vb_strides[start + i] = st;
        c->vb_offsets[start + i] = offsets ? offsets[i] : 0;
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 19: IASetIndexBuffer(pIndexBuffer, Format, Offset)
static SHIM_DEF(ctx_ia_set_ib) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalBuffer *ib = (Bo3MetalBuffer *)rsi;
    uint32_t fmt = (uint32_t)rdx;
    uint32_t off = (uint32_t)rcx;
    os_unfair_lock_lock(&c->lock);
    if (ib) ib->res.com.add_ref();
    if (c->ib) c->ib->res.com.release();
    c->ib = ib;
    c->ib_type = (fmt == 42u /* R32_UINT */) ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
    c->ib_offset = off;
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 20: DrawIndexedInstanced(IndexCountPerInst, InstCount, StartIndex, BaseVertex, StartInst)
static SHIM_DEF(ctx_draw_indexed_instanced) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3PerfScope perf_scope(c);
    uint32_t count = (uint32_t)rsi;
    uint32_t insts = (uint32_t)rdx;
    uint32_t start = (uint32_t)rcx;
    int32_t  base_v = (int32_t)r8;
    uint32_t base_i = (uint32_t)r9;
    if (count == 0 || insts == 0) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (c->ib && prepare_draw(c)) {
        c->touch_buf(c->ib);
        id<MTLBuffer> ibuf = c->ib->cur_buf();
        const uint64_t ilen = c->ib->cur_len();
        uint64_t ib_base = c->ib->cur_base();
        uint32_t idx_sz = (c->ib_type == MTLIndexTypeUInt32) ? 4 : 2;
        uint64_t off = ib_base + c->ib_offset + (uint64_t)start * idx_sz;
        uint64_t need = (uint64_t)count * idx_sz;
        if (ibuf && (off % idx_sz) == 0 && off <= ilen && need <= (ilen - off)) {
            [c->render_enc drawIndexedPrimitives:d3d_topo_to_mtl(c->topology)
                                      indexCount:count
                                       indexType:c->ib_type
                                     indexBuffer:ibuf
                               indexBufferOffset:off
                                   instanceCount:insts
                                      baseVertex:base_v
                                    baseInstance:base_i];
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 21: DrawInstanced(VertCountPerInst, InstCount, StartVert, StartInst)
static SHIM_DEF(ctx_draw_instanced) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3PerfScope perf_scope(c);
    uint32_t count = (uint32_t)rsi;
    uint32_t insts = (uint32_t)rdx;
    uint32_t start = (uint32_t)rcx;
    uint32_t base_i = (uint32_t)r8;
    if (count == 0 || insts == 0) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (prepare_draw(c)) {
        [c->render_enc drawPrimitives:d3d_topo_to_mtl(c->topology)
                          vertexStart:start vertexCount:count
                        instanceCount:insts baseInstance:base_i];
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 24: IASetPrimitiveTopology
static SHIM_DEF(ctx_ia_set_topology) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    c->topology = (uint32_t)rsi;
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 25: VSSetShaderResources
static SHIM_DEF(ctx_vs_set_srv) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    uint32_t start = (uint32_t)rsi, count = (uint32_t)rdx;
    Bo3MetalSRV *const *srvs = (Bo3MetalSRV *const *)rcx;
    os_unfair_lock_lock(&c->lock);
    set_srvs_checked(c, c->vs_srv, start, count, srvs);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 26: VSSetSamplers
static SHIM_DEF(ctx_vs_set_samplers) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    set_obj_array(c->vs_smp, (uint32_t)rsi, (uint32_t)rdx, 16, (Bo3MetalSamplerState *const *)rcx);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 27: Begin(pAsync)
static SHIM_DEF(ctx_begin_query) {
    SHIM_UNUSED_ALL();
    Bo3MetalQuery *q = (Bo3MetalQuery *)rsi;
    if (q) {
        q->ended.store(false, std::memory_order_release);
        q->occlusion_val.store(1, std::memory_order_relaxed);
    }
    return ret_void();
}
// slot 28: End(pAsync)
static SHIM_DEF(ctx_end_query) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalQuery *q = (Bo3MetalQuery *)rsi;
    if (!q) return ret_void();
    os_unfair_lock_lock(&c->lock);
    // Ensure any preceding deferred clears are encoded into cmd_buf before capturing target_fence
    // so End(EVENT) -> Flush -> GetData never reports completion before the clears reach the GPU.
    if (!c->pending_clear_texs.empty()) c->materialize_all_clears();
    uint64_t base = c->submitted_fence.load(std::memory_order_relaxed);
    uint64_t tf = (c->cmd_buf || c->upload_cmd_buf) ? (base + 1) : base;
    q->target_fence.store(tf, std::memory_order_release);
    q->ended.store(true, std::memory_order_release);
    os_unfair_lock_unlock(&c->lock);
    static mach_timebase_info_data_t tb = {0, 0};
    static std::once_flag tb_once;
    std::call_once(tb_once, []() { mach_timebase_info(&tb); });
    uint64_t ts = (mach_absolute_time() * (uint64_t)tb.numer) / (uint64_t)tb.denom;
    q->timestamp_ns.store(ts, std::memory_order_release);
    return ret_void();
    }
}
// slot 29: GetData(pAsync, pData, DataSize, GetDataFlags)
static SHIM_DEF(ctx_get_data) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalQuery *q = (Bo3MetalQuery *)rsi;
    void *data = (void *)rdx;
    uint32_t sz = (uint32_t)rcx;
    uint32_t flags = (uint32_t)r8;
    if (!q) return ret_u64(BO3_S_OK);

    auto wait_fence_ready = [&]() -> bool {
        uint64_t tf = q->target_fence.load(std::memory_order_acquire);
        if (c->completed_fence.load(std::memory_order_acquire) >= tf) return true;
        if (!(flags & 1u) /* !D3D11_ASYNC_GETDATA_DONOTFLUSH */) {
            bool need_flush = false;
            os_unfair_lock_lock(&c->lock);
            need_flush = (c->cmd_buf != nil || c->upload_cmd_buf != nil || !c->pending_clear_texs.empty());
            os_unfair_lock_unlock(&c->lock);
            if (need_flush) bo3_context_flush_now(c, false);
        }
        return c->completed_fence.load(std::memory_order_acquire) >= tf;
    };

    if (q->desc.Query == BO3_D3D11_QUERY_EVENT) {
        if (!wait_fence_ready()) return ret_u64(BO3_S_FALSE);
        if (data && sz >= 4) *(uint32_t *)data = 1;
        return ret_u64(BO3_S_OK);
    }
    if (q->desc.Query == BO3_D3D11_QUERY_TIMESTAMP) {
        if (!wait_fence_ready()) return ret_u64(BO3_S_FALSE);
        if (data && sz >= 8) *(uint64_t *)data = q->timestamp_ns.load(std::memory_order_acquire);
        return ret_u64(BO3_S_OK);
    }
    if (q->desc.Query == BO3_D3D11_QUERY_TIMESTAMP_DISJOINT) {
        if (!wait_fence_ready()) return ret_u64(BO3_S_FALSE);
        if (data && sz >= sizeof(Bo3D3D11_QUERY_DATA_TIMESTAMP_DISJOINT)) {
            auto *d = (Bo3D3D11_QUERY_DATA_TIMESTAMP_DISJOINT *)data;
            d->Frequency = 1000000000ULL;
            d->Disjoint = 0;
        }
        return ret_u64(BO3_S_OK);
    }
    if (q->desc.Query == BO3_D3D11_QUERY_OCCLUSION) {
        if (!wait_fence_ready()) return ret_u64(BO3_S_FALSE);
        if (data && sz >= 8) *(uint64_t *)data = q->occlusion_val.load(std::memory_order_acquire);
        return ret_u64(BO3_S_OK);
    }
    if (q->desc.Query == BO3_D3D11_QUERY_OCCLUSION_PREDICATE) {
        if (!wait_fence_ready()) return ret_u64(BO3_S_FALSE);
        if (data && sz >= 4) *(uint32_t *)data = 1u; // TRUE (4 bytes)
        return ret_u64(BO3_S_OK);
    }
    if (q->desc.Query == BO3_D3D11_QUERY_PIPELINE_STATISTICS) {
        if (!wait_fence_ready()) return ret_u64(BO3_S_FALSE);
        if (data && sz) memset(data, 0, std::min(sz, 88u));
        return ret_u64(BO3_S_OK);
    }
    if (data && sz) memset(data, 0, sz);
    return ret_u64(BO3_S_OK);
}
// Bind RTVs + DSV with D3D11 output-side hazard rules: only SRV / UAV bindings whose subresource
// range actually overlaps an incoming RTV or WRITABLE DSV aspect are unbound (read-only DSV aspects
// may stay bound as SRVs, other mips/slices of the same texture stay bound).
static void bind_om_targets(Bo3MetalContext *c, uint32_t n, Bo3MetalRTV *const *rtvs, Bo3MetalDSV *dsv) {
    c->rtv_count = n;
    for (uint32_t i = 0; i < 8; i++) {
        Bo3MetalRTV *nw = (i < n && rtvs) ? rtvs[i] : nullptr;
        if (nw) {
            nw->com.add_ref();
            if (nw->resource) {
                Bo3SubRange rr = range_of_rtv(nw);
                c->unbind_srvs_overlapping(rr);
                c->unbind_uavs_overlapping(rr, true, true);
            }
        }
        if (c->rtvs[i]) c->rtvs[i]->com.release();
        c->rtvs[i] = nw;
    }
    c->om_dirty = true;
    if (dsv) {
        dsv->com.add_ref();
        if (dsv->resource) {
            c->unbind_uavs_overlapping(range_of_dsv(dsv, false), true, true);
            c->unbind_srvs_overlapping(range_of_dsv(dsv, true));
        }
    }
    if (c->dsv) c->dsv->com.release();
    c->dsv = dsv;
}

// slot 33: OMSetRenderTargets(NumViews, ppRTVs, pDSV)
static SHIM_DEF(ctx_om_set_rts) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    uint32_t n = std::min((uint32_t)rsi, 8u);
    Bo3MetalRTV *const *rtvs = (Bo3MetalRTV *const *)rdx;
    Bo3MetalDSV *dsv = (Bo3MetalDSV *)rcx;
    os_unfair_lock_lock(&c->lock);
    // A1b: no clear flush here: deferred clears live on the textures and fold into the next pass
    // D3D11: OMSetRenderTargets clears all OM-bound UAVs
    for (int i = 0; i < 8; i++) {
        if (c->om_uavs[i]) { c->om_uavs[i]->com.release(); c->om_uavs[i] = nullptr; }
    }
    bind_om_targets(c, n, rtvs, dsv);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 34: OMSetRenderTargetsAndUnorderedAccessViews
static SHIM_DEF(ctx_om_set_rts_and_uavs) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    uint32_t n = (uint32_t)rsi;
    Bo3MetalRTV *const *rtvs = (Bo3MetalRTV *const *)rdx;
    Bo3MetalDSV *dsv = (Bo3MetalDSV *)rcx;
    uint32_t uav_start = (uint32_t)r8;
    uint32_t uav_count = (uint32_t)r9;
    Bo3MetalUAV *const *uavs = (Bo3MetalUAV *const *)shim_stack_u64(rsp, 0);
    const uint32_t *init_counts = (const uint32_t *)shim_stack_u64(rsp, 1);
    os_unfair_lock_lock(&c->lock);
    if (n != 0xffffffffu) { // D3D11_KEEP_RENDER_TARGETS_AND_DEPTH_STENCIL
        bind_om_targets(c, std::min(n, 8u), rtvs, dsv);
    }
    if (uav_count != 0xffffffffu) {
        // D3D11 clears unspecified OM UAV slots outside [uav_start, uav_start + uav_count)
        uint32_t uend = std::min(uav_start + uav_count, 8u);
        for (uint32_t i = 0; i < 8; i++) {
            if (i < uav_start || i >= uend) {
                if (c->om_uavs[i]) { c->om_uavs[i]->com.release(); c->om_uavs[i] = nullptr; }
            }
        }
        if (uavs) {
            for (uint32_t i = 0; i < uav_count && uav_start + i < 8; i++) {
                if (uavs[i] && uavs[i]->resource) {
                    Bo3SubRange ur = range_of_uav(uavs[i]);
                    c->unbind_srvs_overlapping(ur);
                    c->unbind_om_overlapping(ur);
                    c->unbind_uavs_overlapping(ur, false, true);
                }
            }
        }
        set_obj_array(c->om_uavs, uav_start, uav_count, 8, uavs);
        c->om_dirty = true; // OM UAVs size attachmentless passes
        if (init_counts && uavs) {
            for (uint32_t i = 0; i < uav_count && uav_start + i < 8; i++) {
                if (uavs[i] && uavs[i]->counter_buf && init_counts[i] != 0xffffffffu) {
                    c->encode_ordered_u32_write(uavs[i]->counter_buf, 0, init_counts[i]);
                }
            }
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 35: OMSetBlendState(pBlendState, BlendFactor[4], SampleMask)
static SHIM_DEF(ctx_om_set_blend) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalBlendState *bs = (Bo3MetalBlendState *)rsi;
    const float *bf = (const float *)rdx;
    uint32_t sm = (uint32_t)rcx;
    os_unfair_lock_lock(&c->lock);
    if (c->blend_state != bs) {
        if (bs) bs->com.add_ref();
        if (c->blend_state) c->blend_state->com.release();
        c->blend_state = bs;
        c->pso_dirty = true;
    }
    float nf[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    if (bf) memcpy(nf, bf, 16);
    const bool factor_changed = memcmp(nf, c->blend_factor, 16) != 0;
    if (factor_changed) memcpy(c->blend_factor, nf, 16);
    c->sample_mask = sm;
    // A5: only a changed blend factor needs a live encoder update (fresh passes apply it anyway)
    if (c->enc_mode == ENC_RENDER && c->render_enc) {
        if (factor_changed) {
            [c->render_enc setBlendColorRed:c->blend_factor[0] green:c->blend_factor[1]
                                       blue:c->blend_factor[2] alpha:c->blend_factor[3]];
        } else if (c->perf_on) {
            c->enc_state_skips++;
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 36: OMSetDepthStencilState(pDepthStencilState, StencilRef)
static SHIM_DEF(ctx_om_set_ds) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalDepthStencilState *ds = (Bo3MetalDepthStencilState *)rsi;
    uint32_t sref = (uint32_t)rdx;
    os_unfair_lock_lock(&c->lock);
    if (ds) ds->com.add_ref();
    if (c->ds_state) c->ds_state->com.release();
    c->ds_state = ds;
    c->stencil_ref = sref;
    if (c->enc_mode == ENC_RENDER && c->render_enc) {
        c->enc_set_dss(c->select_active_dss(), sref);
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 39: DrawIndexedInstancedIndirect(pBufferForArgs, AlignedByteOffsetForArgs)
static SHIM_DEF(ctx_draw_indexed_instanced_indirect) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3PerfScope perf_scope(c);
    Bo3MetalBuffer *args = (Bo3MetalBuffer *)rsi;
    uint32_t arg_off = (uint32_t)rdx;
    if (!args) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (c->ib && prepare_draw(c)) {
        c->touch_buf(c->ib);
        c->touch_buf(args);
        id<MTLBuffer> ibuf = c->ib->cur_buf();
        uint64_t ib_off = c->ib->cur_base() + c->ib_offset;
        id<MTLBuffer> abuf = args->cur_buf();
        uint64_t aoff = args->cur_base() + arg_off;
        uint32_t idx_sz = (c->ib_type == MTLIndexTypeUInt32) ? 4 : 2;
        if (ibuf && abuf && (ib_off % idx_sz) == 0 && ib_off <= c->ib->cur_len() && aoff + 20 <= args->cur_len()) {
            [c->render_enc drawIndexedPrimitives:d3d_topo_to_mtl(c->topology)
                                       indexType:c->ib_type
                                     indexBuffer:ibuf
                               indexBufferOffset:ib_off
                                  indirectBuffer:abuf
                            indirectBufferOffset:aoff];
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 40: DrawInstancedIndirect(pBufferForArgs, AlignedByteOffsetForArgs)
static SHIM_DEF(ctx_draw_instanced_indirect) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3PerfScope perf_scope(c);
    Bo3MetalBuffer *args = (Bo3MetalBuffer *)rsi;
    uint32_t arg_off = (uint32_t)rdx;
    if (!args) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (prepare_draw(c)) {
        c->touch_buf(args);
        id<MTLBuffer> abuf = args->cur_buf();
        uint64_t aoff = args->cur_base() + arg_off;
        if (abuf && aoff + 16 <= args->cur_len()) {
            [c->render_enc drawPrimitives:d3d_topo_to_mtl(c->topology)
                           indirectBuffer:abuf
                     indirectBufferOffset:aoff];
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// Helper: sync Generic.metallib aggregate uavCounters table <-> per-UAV counter_bufs around compute dispatch
static void sync_uav_counters_before_cs(Bo3MetalContext *c) {
    if (!c->cs || c->cs->bindings.uav_counters_buf == BO3_BIND_UNUSED || !c->uav_counter_table) return;
    c->ensure_blit_encoder();
    [c->blit_enc fillBuffer:c->uav_counter_table range:NSMakeRange(0, 32) value:0];
    for (uint32_t s = 0; s < 8; s++) {
        if (c->cs_uav[s] && c->cs_uav[s]->counter_buf) {
            [c->blit_enc copyFromBuffer:c->cs_uav[s]->counter_buf sourceOffset:0
                               toBuffer:c->uav_counter_table destinationOffset:(s * 4u) size:4];
        }
    }
}
static void sync_uav_counters_after_cs(Bo3MetalContext *c) {
    if (!c->cs || c->cs->bindings.uav_counters_buf == BO3_BIND_UNUSED || !c->uav_counter_table) return;
    bool any_cnt = false;
    for (uint32_t s = 0; s < 8; s++) {
        if (c->cs_uav[s] && c->cs_uav[s]->counter_buf) { any_cnt = true; break; }
    }
    if (!any_cnt) return;
    c->ensure_blit_encoder();
    for (uint32_t s = 0; s < 8; s++) {
        if (c->cs_uav[s] && c->cs_uav[s]->counter_buf) {
            [c->blit_enc copyFromBuffer:c->uav_counter_table sourceOffset:(s * 4u)
                               toBuffer:c->cs_uav[s]->counter_buf destinationOffset:0 size:4];
        }
    }
}
// slot 41: Dispatch(ThreadGroupCountX, Y, Z)
static SHIM_DEF(ctx_dispatch) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3PerfScope perf_scope(c);
    uint32_t gx = (uint32_t)rsi, gy = (uint32_t)rdx, gz = (uint32_t)rcx;
    if (gx == 0 || gy == 0 || gz == 0) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (c->cs && bo3_shader_ensure_compiled(c->cs) && c->cs->mtl_fn) {
        if (!c->cs->cs_pso) {
            NSError *err = nil;
            c->cs->cs_pso = bo3_pso_create_compute(c->device->mtl_dev, c->cs->mtl_fn, &err,
                                                   !c->cs->from_generic_metallib);
        }
        if (c->cs->cs_pso) {
            c->materialize_srv_uav_reads(BO3_STAGE_CS);
            sync_uav_counters_before_cs(c);
            c->ensure_compute_encoder();
            [c->compute_enc setComputePipelineState:c->cs->cs_pso];
            c->bind_stage_resources(BO3_STAGE_CS, make_stage_sel(c->cs, -1));
            uint32_t tx = std::max(1u, c->cs->bindings.cs_threads[0]);
            uint32_t ty = std::max(1u, c->cs->bindings.cs_threads[1]);
            uint32_t tz = std::max(1u, c->cs->bindings.cs_threads[2]);
            [c->compute_enc dispatchThreadgroups:MTLSizeMake(gx, gy, gz)
                           threadsPerThreadgroup:MTLSizeMake(tx, ty, tz)];
            sync_uav_counters_after_cs(c);
            c->dispatch_calls++;
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 42: DispatchIndirect(pBufferForArgs, AlignedByteOffsetForArgs)
static SHIM_DEF(ctx_dispatch_indirect) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3PerfScope perf_scope(c);
    Bo3MetalBuffer *b = (Bo3MetalBuffer *)rsi;
    uint32_t off = (uint32_t)rdx;
    if (!b) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (c->cs && bo3_shader_ensure_compiled(c->cs) && c->cs->mtl_fn) {
        if (!c->cs->cs_pso) {
            c->cs->cs_pso = bo3_pso_create_compute(c->device->mtl_dev, c->cs->mtl_fn, nil,
                                                   !c->cs->from_generic_metallib);
        }
        if (c->cs->cs_pso) {
            c->touch_buf(b);
            c->materialize_srv_uav_reads(BO3_STAGE_CS);
            sync_uav_counters_before_cs(c);
            c->ensure_compute_encoder();
            [c->compute_enc setComputePipelineState:c->cs->cs_pso];
            c->bind_stage_resources(BO3_STAGE_CS, make_stage_sel(c->cs, -1));
            uint32_t tx = std::max(1u, c->cs->bindings.cs_threads[0]);
            uint32_t ty = std::max(1u, c->cs->bindings.cs_threads[1]);
            uint32_t tz = std::max(1u, c->cs->bindings.cs_threads[2]);
            id<MTLBuffer> mb = b->cur_buf();
            uint64_t boff = b->cur_base() + off;
            if (mb && boff + 12 <= b->cur_len()) {
                [c->compute_enc dispatchThreadgroupsWithIndirectBuffer:mb
                                                  indirectBufferOffset:boff
                                                 threadsPerThreadgroup:MTLSizeMake(tx, ty, tz)];
            }
            sync_uav_counters_after_cs(c);
            c->dispatch_calls++;
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 43: RSSetState
static SHIM_DEF(ctx_rs_set_state) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalRasterizerState *rs = (Bo3MetalRasterizerState *)rsi;
    os_unfair_lock_lock(&c->lock);
    if (c->rs_state == rs) { // A5: identical state is already applied to the open encoder
        if (c->perf_on && c->enc_mode == ENC_RENDER && c->render_enc) c->enc_state_skips++;
        os_unfair_lock_unlock(&c->lock);
        return ret_void();
    }
    if (rs) rs->com.add_ref();
    if (c->rs_state) c->rs_state->com.release();
    c->rs_state = rs;
    if (c->enc_mode == ENC_RENDER && c->render_enc) {
        if (rs) {
            MTLCullMode cm = MTLCullModeNone;
            if (rs->desc.CullMode == 2) cm = MTLCullModeFront;
            else if (rs->desc.CullMode == 3) cm = MTLCullModeBack;
            [c->render_enc setCullMode:cm];
            [c->render_enc setFrontFacingWinding:rs->desc.FrontCounterClockwise ? MTLWindingCounterClockwise : MTLWindingClockwise];
            [c->render_enc setTriangleFillMode:(rs->desc.FillMode == 2) ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
            [c->render_enc setDepthClipMode:rs->desc.DepthClipEnable ? MTLDepthClipModeClip : MTLDepthClipModeClamp];
            [c->render_enc setDepthBias:(float)rs->desc.DepthBias
                             slopeScale:rs->desc.SlopeScaledDepthBias
                                  clamp:rs->desc.DepthBiasClamp];
        } else {
            [c->render_enc setCullMode:MTLCullModeBack];
            [c->render_enc setFrontFacingWinding:MTLWindingClockwise];
            [c->render_enc setTriangleFillMode:MTLTriangleFillModeFill];
            [c->render_enc setDepthClipMode:MTLDepthClipModeClip];
            [c->render_enc setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
        }
        c->apply_live_scissor();
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 44: RSSetViewports(NumViewports, pViewports)
static SHIM_DEF(ctx_rs_set_viewports) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    uint32_t n = std::min((uint32_t)rsi, 16u);
    const Bo3D3D11_VIEWPORT *vps = (const Bo3D3D11_VIEWPORT *)rdx;
    os_unfair_lock_lock(&c->lock);
    c->viewport_count = n;
    if (n && vps) {
        memcpy(c->viewports, vps, n * sizeof(Bo3D3D11_VIEWPORT));
        if (c->enc_mode == ENC_RENDER && c->render_enc && vps[0].Width > 0 && vps[0].Height > 0) {
            MTLViewport vp = {
                vps[0].TopLeftX, vps[0].TopLeftY, vps[0].Width, vps[0].Height,
                std::clamp(vps[0].MinDepth, 0.0f, 1.0f),
                std::clamp(vps[0].MaxDepth, 0.0f, 1.0f)
            };
            [c->render_enc setViewport:vp];
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// slot 45: RSSetScissorRects(NumRects, pRects)
static SHIM_DEF(ctx_rs_set_scissors) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    uint32_t n = std::min((uint32_t)rsi, 16u);
    const Bo3RECT *rs = (const Bo3RECT *)rdx;
    os_unfair_lock_lock(&c->lock);
    c->scissor_count = n;
    if (n && rs) memcpy(c->scissors, rs, n * sizeof(Bo3RECT));
    c->apply_live_scissor();
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
static uint32_t mtl_total_slices(id<MTLTexture> t) {
    if (!t) return 0;
    uint32_t s = (uint32_t)t.arrayLength;
    if (t.textureType == MTLTextureTypeCube) return 6u;
    if (t.textureType == MTLTextureTypeCubeArray) return s * 6u;
    return s;
}
// M5: make a copy's source/destination share one pixel format through LEGAL views only (source view
// first, then destination view). Fully typed color textures no longer carry PixelFormatView, so
// sRGB twins still match but true reinterpretations fall through to encode_bitcast_texture_copy.
static bool match_copy_formats(Bo3MetalTexture *dt, Bo3MetalTexture *st, __strong id<MTLTexture> &md,
                               __strong id<MTLTexture> &ms) {
    if (md.pixelFormat == ms.pixelFormat) return true;
    if (bo3_mtl_can_view_as(ms.pixelFormat, ms.usage, md.pixelFormat)) {
        id<MTLTexture> v = st->get_or_create_view(md.pixelFormat, ms.textureType, 0, 0, 0, 0);
        if (v && v.pixelFormat == md.pixelFormat) { ms = v; return true; }
    }
    if (bo3_mtl_can_view_as(md.pixelFormat, md.usage, ms.pixelFormat)) {
        id<MTLTexture> v = dt->get_or_create_view(ms.pixelFormat, md.textureType, 0, 0, 0, 0);
        if (v && v.pixelFormat == ms.pixelFormat) { md = v; return true; }
    }
    return false;
}

// Bytes of one texel moved by a raw staging-buffer bitcast: color texel size, or the depth plane
// of a depth(-stencil) format (Depth16Unorm 2, Depth32Float 4, Depth32Float_Stencil8 depth plane 4).
static uint32_t bitcast_texel_bytes(MTLPixelFormat pf) {
    uint32_t b = bo3_mtl_color_bytes_per_pixel(pf);
    return b ? b : bo3_mtl_depth_bytes_per_pixel(pf);
}
// Combined depth-stencil formats must name the depth plane for texture<->buffer blits.
static MTLBlitOption bitcast_blit_option(MTLPixelFormat pf) {
    return pf == MTLPixelFormatDepth32Float_Stencil8 ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone;
}

static bool can_bitcast_copy(id<MTLTexture> ms, id<MTLTexture> md) {
    if (ms.sampleCount != 1 || md.sampleCount != 1) return false;
    uint32_t bs = bitcast_texel_bytes(ms.pixelFormat);
    return bs != 0 && bs == bitcast_texel_bytes(md.pixelFormat);
}

// Same-size raw-bit copy between two formats that cannot share a view (D3D11 permits e.g.
// R32_FLOAT -> R32_UINT, or a D32 depth buffer (R32_TYPELESS) -> R32_FLOAT texture, inside one typeless
// family): texture -> private staging buffer -> texture, in two ordered blit encoders. Depth planes
// use MTLBlitOptionDepthFromDepthStencil for Depth32Float_Stencil8. Rare path; the CB retains tmp.
static bool encode_bitcast_texture_copy(Bo3MetalContext *c, id<MTLTexture> ms, uint32_t ssl, uint32_t smip,
                                        MTLOrigin so, MTLSize sz, id<MTLTexture> md, uint32_t dsl,
                                        uint32_t dmip, MTLOrigin dorg) {
    uint32_t bpp = bitcast_texel_bytes(ms.pixelFormat);
    if (bpp == 0 || sz.width == 0 || sz.height == 0 || sz.depth == 0) return false;
    const NSUInteger row = sz.width * bpp;
    const NSUInteger img = row * sz.height;
    id<MTLBuffer> tmp = [c->device->mtl_dev newBufferWithLength:img * sz.depth options:MTLResourceStorageModePrivate];
    if (!tmp) return false;
    const bool is3d = (ms.textureType == MTLTextureType3D);
    c->ensure_blit_encoder();
    if (!c->blit_enc) return false;
    [c->blit_enc copyFromTexture:ms sourceSlice:ssl sourceLevel:smip sourceOrigin:so sourceSize:sz
                        toBuffer:tmp destinationOffset:0 destinationBytesPerRow:row
         destinationBytesPerImage:(is3d ? img : 0) options:bitcast_blit_option(ms.pixelFormat)];
    c->end_active_encoder(); // order the texture->buffer copy before the buffer->texture copy
    c->ensure_blit_encoder();
    if (!c->blit_enc) return false;
    [c->blit_enc copyFromBuffer:tmp sourceOffset:0 sourceBytesPerRow:row
            sourceBytesPerImage:((md.textureType == MTLTextureType3D) ? img : 0) sourceSize:sz
                      toTexture:md destinationSlice:dsl destinationLevel:dmip destinationOrigin:dorg
                        options:bitcast_blit_option(md.pixelFormat)];
    static std::atomic<int> note{0};
    if (note.fetch_add(1, std::memory_order_relaxed) < 4) {
        fprintf(stderr, "[metal-ctx] bitcast texture copy fmt %lu -> %lu via staging buffer\n",
                (unsigned long)ms.pixelFormat, (unsigned long)md.pixelFormat);
        fflush(stderr);
    }
    return true;
}

// ---- MSAA same-family bitcast copy ----
// Blits cannot read/write multisample textures through buffers and concrete MSAA render targets no
// longer carry PixelFormatView (lossless compression), so a raw reinterpreting MSAA copy is a render
// pass on the destination (load + store, compression untouched) running a tiny per-sample
// ([[sample_id]]) fragment shader: read sample -> per-component raw bits -> destination type.
// Both formats must share one D3D11 typeless layout (same channel count + per-channel bit widths).
// Exact for every bit pattern except: SNORM -128/-32768 (reads as -1.0 == -127/-32767) and depth
// destinations, whose [[depth(any)]] output Metal clamps to [0,1] (all valid depth values are exact).
enum Bo3RawKind : uint8_t { RK_UNORM, RK_SNORM, RK_UINT, RK_SINT, RK_FLOAT, RK_DEPTH32, RK_DEPTH16 };
struct Bo3RawLayout { Bo3RawKind kind; uint8_t nc; uint8_t bits[4]; };

static bool raw_layout(MTLPixelFormat pf, Bo3RawLayout *o) {
    auto set = [&](Bo3RawKind k, uint8_t nc, uint8_t b0, uint8_t b1 = 0, uint8_t b2 = 0, uint8_t b3 = 0) {
        o->kind = k; o->nc = nc; o->bits[0] = b0; o->bits[1] = b1; o->bits[2] = b2; o->bits[3] = b3;
        return true;
    };
    switch (pf) {
        case MTLPixelFormatR8Unorm:   return set(RK_UNORM, 1, 8);
        case MTLPixelFormatR8Snorm:   return set(RK_SNORM, 1, 8);
        case MTLPixelFormatR8Uint:    return set(RK_UINT, 1, 8);
        case MTLPixelFormatR8Sint:    return set(RK_SINT, 1, 8);
        case MTLPixelFormatRG8Unorm:  return set(RK_UNORM, 2, 8, 8);
        case MTLPixelFormatRG8Snorm:  return set(RK_SNORM, 2, 8, 8);
        case MTLPixelFormatRG8Uint:   return set(RK_UINT, 2, 8, 8);
        case MTLPixelFormatRG8Sint:   return set(RK_SINT, 2, 8, 8);
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatBGRA8Unorm:
                                      return set(RK_UNORM, 4, 8, 8, 8, 8);
        case MTLPixelFormatRGBA8Snorm: return set(RK_SNORM, 4, 8, 8, 8, 8);
        case MTLPixelFormatRGBA8Uint: return set(RK_UINT, 4, 8, 8, 8, 8);
        case MTLPixelFormatRGBA8Sint: return set(RK_SINT, 4, 8, 8, 8, 8);
        case MTLPixelFormatR16Unorm:  return set(RK_UNORM, 1, 16);
        case MTLPixelFormatR16Snorm:  return set(RK_SNORM, 1, 16);
        case MTLPixelFormatR16Uint:   return set(RK_UINT, 1, 16);
        case MTLPixelFormatR16Sint:   return set(RK_SINT, 1, 16);
        case MTLPixelFormatR16Float:  return set(RK_FLOAT, 1, 16);
        case MTLPixelFormatRG16Unorm: return set(RK_UNORM, 2, 16, 16);
        case MTLPixelFormatRG16Snorm: return set(RK_SNORM, 2, 16, 16);
        case MTLPixelFormatRG16Uint:  return set(RK_UINT, 2, 16, 16);
        case MTLPixelFormatRG16Sint:  return set(RK_SINT, 2, 16, 16);
        case MTLPixelFormatRG16Float: return set(RK_FLOAT, 2, 16, 16);
        case MTLPixelFormatRGBA16Unorm: return set(RK_UNORM, 4, 16, 16, 16, 16);
        case MTLPixelFormatRGBA16Snorm: return set(RK_SNORM, 4, 16, 16, 16, 16);
        case MTLPixelFormatRGBA16Uint:  return set(RK_UINT, 4, 16, 16, 16, 16);
        case MTLPixelFormatRGBA16Sint:  return set(RK_SINT, 4, 16, 16, 16, 16);
        case MTLPixelFormatRGBA16Float: return set(RK_FLOAT, 4, 16, 16, 16, 16);
        case MTLPixelFormatR32Uint:   return set(RK_UINT, 1, 32);
        case MTLPixelFormatR32Sint:   return set(RK_SINT, 1, 32);
        case MTLPixelFormatR32Float:  return set(RK_FLOAT, 1, 32);
        case MTLPixelFormatRG32Uint:  return set(RK_UINT, 2, 32, 32);
        case MTLPixelFormatRG32Sint:  return set(RK_SINT, 2, 32, 32);
        case MTLPixelFormatRG32Float: return set(RK_FLOAT, 2, 32, 32);
        case MTLPixelFormatRGBA32Uint:  return set(RK_UINT, 4, 32, 32, 32, 32);
        case MTLPixelFormatRGBA32Sint:  return set(RK_SINT, 4, 32, 32, 32, 32);
        case MTLPixelFormatRGBA32Float: return set(RK_FLOAT, 4, 32, 32, 32, 32);
        case MTLPixelFormatRGB10A2Unorm: return set(RK_UNORM, 4, 10, 10, 10, 2);
        case MTLPixelFormatRGB10A2Uint:  return set(RK_UINT, 4, 10, 10, 10, 2);
        case MTLPixelFormatDepth32Float: case MTLPixelFormatDepth32Float_Stencil8:
                                         return set(RK_DEPTH32, 1, 32);
        case MTLPixelFormatDepth16Unorm: return set(RK_DEPTH16, 1, 16);
        default: return false;
    }
}

static bool msaa_layouts_compatible(const Bo3RawLayout &a, const Bo3RawLayout &b) {
    if (a.nc != b.nc) return false;
    for (int i = 0; i < a.nc; i++) if (a.bits[i] != b.bits[i]) return false;
    return true;
}

static MTLPixelFormat msaa_linear_twin(MTLPixelFormat pf) {
    if (pf == MTLPixelFormatRGBA8Unorm_sRGB) return MTLPixelFormatRGBA8Unorm;
    if (pf == MTLPixelFormatBGRA8Unorm_sRGB) return MTLPixelFormatBGRA8Unorm;
    return pf;
}

static bool can_msaa_bitcast_copy(id<MTLTexture> ms, id<MTLTexture> md) {
    if (ms.sampleCount <= 1 || ms.sampleCount != md.sampleCount) return false;
    if (!(md.usage & MTLTextureUsageRenderTarget) || !(ms.usage & MTLTextureUsageShaderRead)) return false;
    Bo3RawLayout a, b;
    return raw_layout(msaa_linear_twin(ms.pixelFormat), &a) &&
           raw_layout(msaa_linear_twin(md.pixelFormat), &b) &&
           msaa_layouts_compatible(a, b);
}

static std::string msaa_to_raw_expr(const Bo3RawLayout &l, int i, const char *v) {
    const unsigned b = l.bits[i];
    const std::string x = v;
    const std::string mask = (b >= 32) ? std::string("0xffffffffu") : std::to_string((1ull << b) - 1ull) + "u";
    switch (l.kind) {
        case RK_UNORM: case RK_DEPTH16:
            return "uint(rint(saturate(" + x + ") * " + std::to_string((1ull << b) - 1ull) + ".0))";
        case RK_SNORM:
            return "(uint(int(rint(clamp(" + x + ", -1.0, 1.0) * " + std::to_string((1ull << (b - 1)) - 1ull) +
                   ".0))) & " + mask + ")";
        case RK_UINT:  return "(" + x + " & " + mask + ")";
        case RK_SINT:  return "(as_type<uint>(" + x + ") & " + mask + ")";
        case RK_FLOAT: return b == 16 ? "uint(as_type<ushort>(half(" + x + ")))" : "as_type<uint>(" + x + ")";
        case RK_DEPTH32: return "as_type<uint>(" + x + ")";
    }
    return "0u";
}

static std::string msaa_from_raw_expr(const Bo3RawLayout &l, int i, const char *r) {
    const unsigned b = l.bits[i];
    const std::string x = r;
    const std::string sext = (b >= 32) ? "as_type<int>(" + x + ")"
                                       : "(as_type<int>(" + x + " << " + std::to_string(32 - b) + "u) >> " +
                                             std::to_string(32 - b) + ")";
    switch (l.kind) {
        case RK_UNORM: case RK_DEPTH16:
            return "(float(" + x + ") / " + std::to_string((1ull << b) - 1ull) + ".0)";
        case RK_SNORM:
            return "max(float(" + sext + ") / " + std::to_string((1ull << (b - 1)) - 1ull) + ".0, -1.0)";
        case RK_UINT:  return x;
        case RK_SINT:  return sext;
        case RK_FLOAT: return b == 16 ? "float(as_type<half>(ushort(" + x + ")))" : "as_type<float>(" + x + ")";
        case RK_DEPTH32: return "as_type<float>(" + x + ")";
    }
    return "0";
}

static std::string msaa_copy_msl(const Bo3RawLayout &sl, const Bo3RawLayout &dl, bool src_array) {
    const bool sdepth = sl.kind == RK_DEPTH32 || sl.kind == RK_DEPTH16;
    const bool ddepth = dl.kind == RK_DEPTH32 || dl.kind == RK_DEPTH16;
    const char *s_scalar = (sl.kind == RK_UINT) ? "uint" : (sl.kind == RK_SINT) ? "int" : "float";
    const char *d_scalar = (dl.kind == RK_UINT) ? "uint" : (dl.kind == RK_SINT) ? "int" : "float";
    std::string src_tex = sdepth ? (src_array ? "depth2d_ms_array<float>" : "depth2d_ms<float>")
                                 : std::string(src_array ? "texture2d_ms_array<" : "texture2d_ms<") + s_scalar + ">";
    std::string m = "#include <metal_stdlib>\nusing namespace metal;\n"
                    "struct VO { float4 pos [[position]]; };\n"
                    "struct P { int2 off; uint slice; uint pad; };\n"
                    "vertex VO msaa_copy_vs(uint vid [[vertex_id]]) {\n"
                    "  float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));\n"
                    "  VO o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;\n}\n";
    if (ddepth) m += "struct FO { float d [[depth(any)]]; };\n";
    m += std::string("fragment ") + (ddepth ? "FO" : std::string(d_scalar) + "4") +
         " msaa_copy_fs(VO in [[stage_in]], uint sid [[sample_id]], " + src_tex +
         " src [[texture(0)]], constant P &p [[buffer(0)]]) {\n"
         "  uint2 c = uint2(int2(in.pos.xy) + p.off);\n";
    const char *rd = src_array ? "src.read(c, p.slice, sid)" : "src.read(c, sid)";
    if (sdepth) m += std::string("  float4 v = float4(") + rd + ", 0.0, 0.0, 0.0);\n";
    else        m += std::string("  ") + s_scalar + "4 v = " + rd + ";\n";
    m += "  uint4 r = uint4(0u);\n";
    static const char *comp[4] = {"v.x", "v.y", "v.z", "v.w"};
    static const char *rcomp[4] = {"r.x", "r.y", "r.z", "r.w"};
    for (int i = 0; i < sl.nc; i++) m += std::string("  ") + rcomp[i] + " = " + msaa_to_raw_expr(sl, i, comp[i]) + ";\n";
    if (ddepth) {
        m += "  FO o; o.d = " + msaa_from_raw_expr(dl, 0, "r.x") + "; return o;\n}\n";
    } else {
        m += std::string("  ") + d_scalar + "4 o = " + d_scalar + "4(0);\n";
        static const char *ocomp[4] = {"o.x", "o.y", "o.z", "o.w"};
        for (int i = 0; i < dl.nc; i++) m += std::string("  ") + ocomp[i] + " = " + msaa_from_raw_expr(dl, i, rcomp[i]) + ";\n";
        m += "  return o;\n}\n";
    }
    return m;
}

static id<MTLRenderPipelineState> get_msaa_copy_pso(Bo3MetalContext *c, id<MTLTexture> ms, id<MTLTexture> md,
                                                    bool src_array) {
    const uint64_t key = (uint64_t)ms.pixelFormat | ((uint64_t)md.pixelFormat << 16) |
                         ((uint64_t)md.sampleCount << 32) | ((uint64_t)(src_array ? 1 : 0) << 40);
    auto it = c->msaa_copy_pso.find(key);
    if (it != c->msaa_copy_pso.end()) return it->second;
    Bo3RawLayout sl, dl;
    id<MTLRenderPipelineState> pso = nil;
    if (raw_layout(ms.pixelFormat, &sl) && raw_layout(md.pixelFormat, &dl)) {
        std::string src = msaa_copy_msl(sl, dl, src_array);
        NSError *err = nil;
        MTLCompileOptions *opt = [MTLCompileOptions new];
#if defined(__MAC_15_0)
        if (@available(macOS 15.0, *)) opt.languageVersion = MTLLanguageVersion3_2;
        else
#endif
#if defined(__MAC_14_0)
        if (@available(macOS 14.0, *)) opt.languageVersion = MTLLanguageVersion3_1;
        else
#endif
        opt.languageVersion = MTLLanguageVersion3_0;
        id<MTLLibrary> lib = [c->device->mtl_dev newLibraryWithSource:[NSString stringWithUTF8String:src.c_str()]
                                                              options:opt error:&err];
        if (lib) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [lib newFunctionWithName:@"msaa_copy_vs"];
            d.fragmentFunction = [lib newFunctionWithName:@"msaa_copy_fs"];
            d.rasterSampleCount = md.sampleCount;
            if (dl.kind == RK_DEPTH32 || dl.kind == RK_DEPTH16) {
                d.depthAttachmentPixelFormat = md.pixelFormat;
                if (md.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) d.stencilAttachmentPixelFormat = md.pixelFormat;
            } else {
                d.colorAttachments[0].pixelFormat = md.pixelFormat;
            }
            pso = bo3_pso_create_render(c->device->mtl_dev, d, &err, true);
        }
        if (!pso) {
            fprintf(stderr, "[metal-ctx] MSAA bitcast copy PSO %lu -> %lu failed: %s\n", (unsigned long)ms.pixelFormat,
                    (unsigned long)md.pixelFormat, err ? err.localizedDescription.UTF8String : "?");
            fflush(stderr);
        }
    }
    c->msaa_copy_pso[key] = pso; // nil cached too: never retried per call
    return pso;
}

// One MSAA slice/mip region copy (sample-exact). Caller holds c->lock and has touched both resources.
static bool encode_msaa_bitcast_copy(Bo3MetalContext *c, id<MTLTexture> ms, uint32_t ssl, MTLOrigin so, MTLSize sz,
                                     id<MTLTexture> md, uint32_t dsl, MTLOrigin dorg) {
    if (sz.width == 0 || sz.height == 0) return false;
    // View sRGB MSAA textures through their linear twin (legal without PixelFormatView) so raw
    // UNORM byte values copy without sRGB gamma conversion.
    MTLPixelFormat spf = msaa_linear_twin(ms.pixelFormat);
    MTLPixelFormat dpf = msaa_linear_twin(md.pixelFormat);
    if (spf != ms.pixelFormat) {
        ms = [ms newTextureViewWithPixelFormat:spf];
        if (!ms) return false;
    }
    if (dpf != md.pixelFormat) {
        md = [md newTextureViewWithPixelFormat:dpf];
        if (!md) return false;
    }
    const bool src_array = ms.textureType == MTLTextureType2DMultisampleArray;
    id<MTLRenderPipelineState> pso = get_msaa_copy_pso(c, ms, md, src_array);
    if (!pso) return false;
    const bool ddepth = is_depth_mtl_format(md.pixelFormat);
    if (ddepth && !c->msaa_copy_dss) {
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = YES;
        c->msaa_copy_dss = [c->device->mtl_dev newDepthStencilStateWithDescriptor:dd];
    }
    c->end_active_encoder(SPLIT_BLIT);
    c->ensure_cmd_buf();
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    if (ddepth) {
        rpd.depthAttachment.texture = md;
        rpd.depthAttachment.slice = dsl;
        rpd.depthAttachment.loadAction = MTLLoadActionLoad;
        rpd.depthAttachment.storeAction = MTLStoreActionStore;
        if (md.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
            rpd.stencilAttachment.texture = md;
            rpd.stencilAttachment.slice = dsl;
            rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
            rpd.stencilAttachment.storeAction = MTLStoreActionStore;
        }
    } else {
        rpd.colorAttachments[0].texture = md;
        rpd.colorAttachments[0].slice = dsl;
        rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    id<MTLRenderCommandEncoder> enc = [c->cmd_buf renderCommandEncoderWithDescriptor:rpd];
    if (!enc) return false;
    c->pass_splits++;
    if (c->perf_on) c->perf_account_pass(rpd);
    [enc setRenderPipelineState:pso];
    if (ddepth) [enc setDepthStencilState:c->msaa_copy_dss];
    MTLViewport vp = {(double)dorg.x, (double)dorg.y, (double)sz.width, (double)sz.height, 0.0, 1.0};
    [enc setViewport:vp];
    MTLScissorRect sc = {dorg.x, dorg.y, sz.width, sz.height};
    [enc setScissorRect:sc];
    struct { int32_t off[2]; uint32_t slice, pad; } p = {
        {(int32_t)so.x - (int32_t)dorg.x, (int32_t)so.y - (int32_t)dorg.y}, ssl, 0};
    [enc setFragmentTexture:ms atIndex:0];
    [enc setFragmentBytes:&p length:sizeof(p) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    static std::atomic<int> note{0};
    if (note.fetch_add(1, std::memory_order_relaxed) < 4) {
        fprintf(stderr, "[metal-ctx] MSAA x%lu bitcast copy fmt %lu -> %lu via per-sample pass\n",
                (unsigned long)md.sampleCount, (unsigned long)ms.pixelFormat, (unsigned long)md.pixelFormat);
        fflush(stderr);
    }
    return true;
}

// slot 46: CopySubresourceRegion(pDst, DstSub, DstX, DstY, DstZ, pSrc, SrcSub, pSrcBox)
static SHIM_DEF(ctx_copy_subres_region) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalResource *dst = (Bo3MetalResource *)rsi;
    uint32_t dst_sub = (uint32_t)rdx;
    uint32_t dx = (uint32_t)rcx, dy = (uint32_t)r8, dz = (uint32_t)r9;
    Bo3MetalResource *src = (Bo3MetalResource *)shim_stack_u64(rsp, 0);
    uint32_t src_sub = (uint32_t)shim_stack_u64(rsp, 1);
    const Bo3D3D11_BOX *box = (const Bo3D3D11_BOX *)shim_stack_u64(rsp, 2);
    if (!dst || !src) return ret_void();
    if (box && (box->right <= box->left || box->bottom <= box->top || box->back <= box->front)) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (dst->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER && src->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalBuffer *db = (Bo3MetalBuffer *)dst, *sb = (Bo3MetalBuffer *)src;
        c->materialize_renamed(db); // GPU writes must land in the owned buffer, never a ring copy
        c->touch_buf(sb);
        c->touch_buf(db);
        id<MTLBuffer> sbuf = sb->dyn_buf ? sb->dyn_buf : sb->mtl_buf;
        uint64_t sbase = sb->dyn_buf ? sb->dyn_offset : 0;
        id<MTLBuffer> dbuf = db->dyn_buf ? db->dyn_buf : db->mtl_buf;
        uint64_t dbase = db->dyn_buf ? db->dyn_offset : 0;
        uint64_t so = box ? box->left : 0;
        if (dx < db->desc.ByteWidth && so < sb->desc.ByteWidth) {
            uint64_t req = box ? (uint64_t)(box->right - box->left) : (uint64_t)sb->desc.ByteWidth;
            uint64_t sz = std::min(req, std::min((uint64_t)db->desc.ByteWidth - dx, (uint64_t)sb->desc.ByteWidth - so));
            if (sz > 0) c->encode_buffer_copy(sbuf, sbase + so, dbuf, dbase + dx, sz);
        }
    } else if (dst->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER && src->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalTexture *dt = (Bo3MetalTexture *)dst, *st = (Bo3MetalTexture *)src;
        id<MTLTexture> md = dt->current_mtl_texture(), ms = st->current_mtl_texture();
        if (md && ms) {
            const bool fmt_match = match_copy_formats(dt, st, md, ms);
            const bool bitcast = !fmt_match && can_bitcast_copy(ms, md);
            const bool msaa_cast = !fmt_match && !bitcast && can_msaa_bitcast_copy(ms, md);
            if (fmt_match || bitcast || msaa_cast) {
                // Decode subresources with the D3D11 mip count (Metal 1D textures are single-mip)
                uint32_t dmips = dt->d3d_mip_levels();
                uint32_t smips = st->d3d_mip_levels();
                uint32_t dmip = dst_sub % dmips, dsl = (dst->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D) ? 0u : (dst_sub / dmips);
                uint32_t smip = src_sub % smips, ssl = (src->dimension == BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D) ? 0u : (src_sub / smips);
                if (dsl < mtl_total_slices(md) && ssl < mtl_total_slices(ms) &&
                    dmip < md.mipmapLevelCount && smip < ms.mipmapLevelCount) {
                    uint32_t smw = std::max(1u, (uint32_t)ms.width >> smip);
                    uint32_t smh = std::max(1u, (uint32_t)ms.height >> smip);
                    uint32_t smd = std::max(1u, (uint32_t)ms.depth >> smip);
                    uint32_t dmw = std::max(1u, (uint32_t)md.width >> dmip);
                    uint32_t dmh = std::max(1u, (uint32_t)md.height >> dmip);
                    uint32_t dmd = std::max(1u, (uint32_t)md.depth >> dmip);
                    uint32_t sx = box ? box->left : 0, sy = box ? box->top : 0, sz0 = box ? box->front : 0;
                    if (sx < smw && sy < smh && sz0 < smd && dx < dmw && dy < dmh && dz < dmd) {
                        uint32_t sw = box ? std::min(box->right - sx, smw - sx) : smw;
                        uint32_t sh = box ? std::min(box->bottom - sy, smh - sy) : smh;
                        uint32_t sd = box ? std::min(box->back - sz0, smd - sz0) : smd;
                        sw = std::min(sw, dmw - dx);
                        sh = std::min(sh, dmh - dy);
                        sd = std::min(sd, dmd - dz);
                        if (sw > 0 && sh > 0 && sd > 0) {
                            // A1b: source reads, partial writes, and any aspect preserved by a
                            // depth-only bitcast path must see deferred clears; drop only the
                            // aspects actually overwritten once the copy encodes.
                            const bool full = dx == 0 && dy == 0 && dz == 0 && sw == dmw && sh == dmh && sd == dmd;
                            const bool depth_only_dst = (bitcast || msaa_cast) &&
                                                        md.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
                            const uint8_t written_aspect = depth_only_dst ? (uint8_t)BO3_ASPECT_COLOR_DEPTH
                                                                          : (uint8_t)BO3_ASPECT_ALL;
                            const Bo3SubRange dst_r = subres_range(dst, dmip, dsl);
                            if (!c->pending_clear_texs.empty()) {
                                c->materialize_res(src, subres_range(src, smip, ssl));
                                if (!full) {
                                    c->materialize_res(dst, dst_r);
                                } else if (written_aspect != BO3_ASPECT_ALL) {
                                    Bo3SubRange pres = dst_r;
                                    pres.aspect = (uint8_t)(BO3_ASPECT_ALL & ~written_aspect);
                                    c->materialize_res(dst, pres);
                                }
                            }
                            c->touch(dst);
                            c->touch(src);
                            bool wrote = false;
                            if (bitcast) {
                                wrote = encode_bitcast_texture_copy(c, ms, ssl, smip, MTLOriginMake(sx, sy, sz0),
                                                                    MTLSizeMake(sw, sh, sd), md, dsl, dmip,
                                                                    MTLOriginMake(dx, dy, dz));
                            } else if (msaa_cast) {
                                wrote = encode_msaa_bitcast_copy(c, ms, ssl, MTLOriginMake(sx, sy, 0), MTLSizeMake(sw, sh, 1),
                                                                 md, dsl, MTLOriginMake(dx, dy, 0));
                            } else {
                                c->ensure_blit_encoder();
                                if (c->blit_enc) {
                                    [c->blit_enc copyFromTexture:ms sourceSlice:ssl sourceLevel:smip
                                                    sourceOrigin:MTLOriginMake(sx, sy, sz0)
                                                      sourceSize:MTLSizeMake(sw, sh, sd)
                                                       toTexture:md destinationSlice:dsl destinationLevel:dmip
                                               destinationOrigin:MTLOriginMake(dx, dy, dz)];
                                    wrote = true;
                                }
                            }
                            if (wrote && full && !c->pending_clear_texs.empty()) {
                                Bo3SubRange dr = dst_r;
                                dr.aspect = written_aspect;
                                c->drop_clears(dt, dr);
                            }
                        }
                    }
                }
            }
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 47: CopyResource(pDst, pSrc)
static SHIM_DEF(ctx_copy_resource) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalResource *dst = (Bo3MetalResource *)rsi;
    Bo3MetalResource *src = (Bo3MetalResource *)rdx;
    if (!dst || !src) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (dst->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER && src->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalBuffer *db = (Bo3MetalBuffer *)dst, *sb = (Bo3MetalBuffer *)src;
        if (!db->is_dynamic) {
            // Whole-resource overwrite: drop any renamed ring copy and write the owned buffer
            db->clear_dyn();
        }
        c->touch_buf(sb);
        c->touch_buf(db);
        id<MTLBuffer> sbuf = sb->dyn_buf ? sb->dyn_buf : sb->mtl_buf;
        uint64_t sbase = sb->dyn_buf ? sb->dyn_offset : 0;
        id<MTLBuffer> dbuf = db->dyn_buf ? db->dyn_buf : db->mtl_buf;
        uint64_t dbase = db->dyn_buf ? db->dyn_offset : 0;
        size_t sz = std::min(db->desc.ByteWidth, sb->desc.ByteWidth);
        if (sz) c->encode_buffer_copy(sbuf, sbase, dbuf, dbase, sz);
    } else if (dst->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER && src->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalTexture *dt = (Bo3MetalTexture *)dst, *st = (Bo3MetalTexture *)src;
        id<MTLTexture> md = dt->current_mtl_texture(), ms = st->current_mtl_texture();
        if (md && ms) {
            const bool fmt_match = match_copy_formats(dt, st, md, ms);
            const bool bitcast = !fmt_match && can_bitcast_copy(ms, md);
            const bool msaa_cast = !fmt_match && !bitcast && can_msaa_bitcast_copy(ms, md);
            uint32_t dslices = mtl_total_slices(md);
            uint32_t sslices = mtl_total_slices(ms);
            if ((fmt_match || bitcast || msaa_cast) && md.width == ms.width && md.height == ms.height &&
                md.depth == ms.depth && md.mipmapLevelCount == ms.mipmapLevelCount &&
                md.sampleCount == ms.sampleCount && dslices == sslices && dslices > 0) {
                const bool depth_only_dst = (bitcast || msaa_cast) &&
                                            md.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
                const uint8_t written_aspect = depth_only_dst ? (uint8_t)BO3_ASPECT_COLOR_DEPTH
                                                              : (uint8_t)BO3_ASPECT_ALL;
                if (!c->pending_clear_texs.empty()) {
                    c->materialize_res(src, whole_range(src));
                    if (written_aspect != BO3_ASPECT_ALL) {
                        Bo3SubRange pres = whole_range(dst);
                        pres.aspect = (uint8_t)(BO3_ASPECT_ALL & ~written_aspect);
                        c->materialize_res(dst, pres);
                    }
                }
                c->touch(dst);
                c->touch(src);
                if (bitcast) {
                    for (uint32_t sl = 0; sl < dslices; sl++) {
                        for (uint32_t mip = 0; mip < (uint32_t)md.mipmapLevelCount; mip++) {
                            MTLSize msz = MTLSizeMake(std::max(1u, (uint32_t)ms.width >> mip),
                                                      std::max(1u, (uint32_t)ms.height >> mip),
                                                      std::max(1u, (uint32_t)ms.depth >> mip));
                            if (encode_bitcast_texture_copy(c, ms, sl, mip, MTLOriginMake(0, 0, 0), msz,
                                                            md, sl, mip, MTLOriginMake(0, 0, 0)) &&
                                !c->pending_clear_texs.empty()) {
                                Bo3SubRange dr = subres_range(dst, mip, sl);
                                dr.aspect = written_aspect;
                                c->drop_clears(dt, dr);
                            }
                        }
                    }
                } else if (msaa_cast) {
                    for (uint32_t sl = 0; sl < dslices; sl++) {
                        if (encode_msaa_bitcast_copy(c, ms, sl, MTLOriginMake(0, 0, 0),
                                                     MTLSizeMake(ms.width, ms.height, 1), md, sl, MTLOriginMake(0, 0, 0)) &&
                            !c->pending_clear_texs.empty()) {
                            Bo3SubRange dr = subres_range(dst, 0, sl);
                            dr.aspect = written_aspect;
                            c->drop_clears(dt, dr);
                        }
                    }
                } else if (md.textureType == ms.textureType) {
                    c->ensure_blit_encoder();
                    if (c->blit_enc) {
                        [c->blit_enc copyFromTexture:ms toTexture:md];
                        if (!c->pending_clear_texs.empty()) c->drop_clears(dt, whole_range(dst));
                    }
                } else {
                    // Allow CopyResource between 6-slice Texture2DArray <-> TextureCube (or 6*N <-> CubeArray)
                    c->ensure_blit_encoder();
                    if (c->blit_enc) {
                        uint32_t mips = (uint32_t)md.mipmapLevelCount;
                        for (uint32_t sl = 0; sl < dslices; sl++) {
                            for (uint32_t mip = 0; mip < mips; mip++) {
                                uint32_t mw = std::max(1u, (uint32_t)ms.width >> mip);
                                uint32_t mh = std::max(1u, (uint32_t)ms.height >> mip);
                                uint32_t mdp = std::max(1u, (uint32_t)ms.depth >> mip);
                                [c->blit_enc copyFromTexture:ms sourceSlice:sl sourceLevel:mip
                                                sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(mw, mh, mdp)
                                                   toTexture:md destinationSlice:sl destinationLevel:mip
                                           destinationOrigin:MTLOriginMake(0, 0, 0)];
                            }
                        }
                        if (!c->pending_clear_texs.empty()) c->drop_clears(dt, whole_range(dst));
                    }
                }
            }
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 48: UpdateSubresource(pDst, DstSub, pDstBox, pSrcData, SrcRowPitch, SrcDepthPitch)
static SHIM_DEF(ctx_update_subresource) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalResource *dst = (Bo3MetalResource *)rsi;
    uint32_t subres = (uint32_t)rdx;
    const Bo3D3D11_BOX *box = (const Bo3D3D11_BOX *)rcx;
    const void *src = (const void *)r8;
    uint32_t row_pitch = (uint32_t)r9;
    uint32_t depth_pitch = (uint32_t)shim_stack_u64(rsp, 0);
    if (!dst || !src) return ret_void();
    if (box && (box->right <= box->left || box->bottom <= box->top || box->back <= box->front)) return ret_void();

    os_unfair_lock_lock(&c->lock);
    if (dst->dimension == BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalBuffer *b = (Bo3MetalBuffer *)dst;
        uint32_t off = box ? box->left : 0;
        uint32_t sz = box ? (box->right - box->left) : b->desc.ByteWidth;
        const bool whole = (off == 0 && sz >= b->desc.ByteWidth);
        // Whole-buffer fast path: RENAME into the upload ring exactly like MAP_WRITE_DISCARD
        // (no render-pass break for a blit!). Only for buffers the GPU never writes itself
        // (constant buffers, or any non-UAV / non-SO / non-RT / non-staging buffer).
        const uint32_t gpu_write_binds = BO3_D3D11_BIND_UNORDERED_ACCESS | BO3_D3D11_BIND_STREAM_OUTPUT |
                                         BO3_D3D11_BIND_RENDER_TARGET | BO3_D3D11_BIND_DEPTH_STENCIL;
        const bool renamable = whole && !b->is_dynamic && !b->is_staging && b->desc.ByteWidth > 0 &&
                               ((b->desc.BindFlags & BO3_D3D11_BIND_CONSTANT_BUFFER) != 0 ||
                                (b->desc.BindFlags & gpu_write_binds) == 0);
        bool renamed = false;
        if (renamable) {
            id<MTLBuffer> rbuf = nil;
            uint64_t roff = 0;
            void *rptr = nullptr;
            if (c->upload_ring.alloc(b->desc.ByteWidth, 256, c->pending_fence(), &rbuf, &roff, &rptr)) {
                memcpy(rptr, src, b->desc.ByteWidth);
                b->set_dyn(rbuf, roff, Bo3UploadRing::CHUNK_SIZE);
                c->upload_ring.track_dynamic_user(b);
                renamed = true;
            }
        }
        if (!renamed && whole) {
            // Whole overwrite through the blit path: any renamed copy is fully superseded
            b->clear_dyn();
        } else if (!renamed) {
            // Partial update: fold the renamed ring copy back into mtl_buf (GPU-ordered) first
            c->materialize_renamed(b);
        }
        if (!renamed && off < b->desc.ByteWidth && sz > 0) {
            sz = std::min(sz, b->desc.ByteWidth - off);
            id<MTLBuffer> rbuf = nil;
            uint64_t roff = 0;
            void *rptr = nullptr;
            if (c->upload_ring.alloc(sz, 16, c->pending_fence(), &rbuf, &roff, &rptr)) {
                memcpy(rptr, src, sz);
            } else {
                // Ring overflow: allocate temporary shared staging buffer and encode ordered GPU copy!
                if (c->perf_on) c->perf_ring_overflows++;
                size_t alloc_sz = std::max<size_t>((sz + 15u) & ~15u, 16u);
                rbuf = [c->device->mtl_dev newBufferWithLength:alloc_sz options:MTLResourceStorageModeShared];
                roff = 0;
                if (rbuf) memcpy(rbuf.contents, src, sz);
            }
            if (rbuf) {
                // A2: whole-buffer blit into a buffer cmd_buf has not referenced yet -> hoist ahead of
                // the open render pass (4-byte aligned blits only; the compute byte-copy stays ordered).
                bool hoisted = false;
                if (whole && ((roff | off | sz) & 3u) == 0 && c->can_hoist(&b->res)) {
                    if (id<MTLBlitCommandEncoder> enc = c->hoist_blit_encoder()) {
                        c->mark_hoisted(&b->res);
                        [enc copyFromBuffer:rbuf sourceOffset:roff toBuffer:b->mtl_buf destinationOffset:off size:sz];
                        hoisted = true;
                    }
                }
                if (!hoisted) {
                    c->touch_buf(b);
                    c->encode_buffer_copy(rbuf, roff, b->mtl_buf, off, sz);
                }
            }
        }
    } else {
        Bo3MetalTexture *t = (Bo3MetalTexture *)dst;
        id<MTLTexture> mt = t->current_mtl_texture();
        if (mt) {
            const bool is_1d = (mt.textureType == MTLTextureType1D || mt.textureType == MTLTextureType1DArray);
            const bool is_3d = (mt.textureType == MTLTextureType3D);
            const bool rgb32 = bo3_format_is_rgb32(t->dxgi_format);
            uint32_t mips = t->d3d_mip_levels(); // D3D11 subresource decoding
            uint32_t mip = subres % mips, slice = is_3d ? 0u : (subres / mips);
            if (slice < mtl_total_slices(mt) && mip < mt.mipmapLevelCount) {
                uint32_t mw = std::max(1u, (uint32_t)mt.width >> mip);
                uint32_t mh = std::max(1u, (uint32_t)mt.height >> mip);
                uint32_t mdp = is_3d ? std::max(1u, (uint32_t)mt.depth >> mip) : 1u;
                uint32_t ox = box ? box->left : 0, oy = box ? box->top : 0, oz = box ? box->front : 0;
                if (ox < mw && oy < mh && oz < mdp) {
                    uint32_t w = box ? std::min(box->right - ox, mw - ox) : mw;
                    uint32_t h = box ? std::min(box->bottom - oy, mh - oy) : mh;
                    uint32_t d = box ? std::min(box->back - oz, mdp - oz) : mdp;
                    uint32_t calc_r = 0, calc_s = 0, rows = 0;
                    bo3_format_calc_pitch(t->dxgi_format, w, h, &calc_r, &calc_s, &rows);
                    if (calc_r > 0 && rows > 0 && d > 0) {
                        uint32_t src_rp = (!is_1d && row_pitch >= calc_r) ? row_pitch : calc_r;
                        // A1b: a partial update must land on top of cleared contents; a full update
                        // drops deferred clears only once the upload encoder actually succeeds.
                        const bool full = ox == 0 && oy == 0 && oz == 0 && w == mw && h == mh && d == mdp;
                        if (!full && !t->pending_clears.empty()) {
                            c->materialize_res(dst, subres_range(dst, mip, slice));
                        }
                        uint8_t uploaded_aspects = 0;
                        if (mt.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
                            id<MTLBlitCommandEncoder> enc = upload_encoder_for(c, dst);
                            uploaded_aspects = bo3_encode_depth_stencil_upload(c->device->mtl_dev, enc, mt, t->dxgi_format,
                                                                               slice, mip, ox, oy, w, h,
                                                                               (const uint8_t *)src, src_rp);
                        } else {
                            uint32_t src_sp = (is_3d && depth_pitch >= src_rp * rows) ? depth_pitch : (src_rp * rows);
                            // RGB32: 12-byte guest texels -> 16-byte Metal RGBA32 texels
                            uint32_t dst_rp = rgb32 ? w * 16u : calc_r;
                            uint32_t dst_sp = dst_rp * rows;
                            size_t total = (size_t)dst_sp * d;
                            id<MTLBuffer> stg = nil;
                            uint64_t soff = 0;
                            uint8_t *dst_p = nullptr;
                            if (alloc_upload_staging(c, total, &stg, &soff, &dst_p)) {
                                const uint8_t *src_base = (const uint8_t *)src;
                                for (uint32_t z = 0; z < d; z++) {
                                    const uint8_t *src_sl = src_base + (size_t)z * src_sp;
                                    uint8_t *dst_sl = dst_p + (size_t)z * dst_sp;
                                    if (!rgb32 && src_rp == dst_rp) {
                                        memcpy(dst_sl, src_sl, (size_t)dst_rp * rows);
                                        continue;
                                    }
                                    for (uint32_t r = 0; r < rows; r++) {
                                        if (rgb32) bo3_rgb32_expand_row(dst_sl + (size_t)r * dst_rp, src_sl + (size_t)r * src_rp, w, t->dxgi_format);
                                        else       memcpy(dst_sl + (size_t)r * dst_rp, src_sl + (size_t)r * src_rp, calc_r);
                                    }
                                }
                                id<MTLBlitCommandEncoder> enc = upload_encoder_for(c, dst);
                                if (enc) {
                                    [enc copyFromBuffer:stg sourceOffset:soff
                                      sourceBytesPerRow:(is_1d ? 0u : dst_rp)
                                    sourceBytesPerImage:(is_1d ? 0u : dst_sp)
                                             sourceSize:MTLSizeMake(w, h, d)
                                              toTexture:mt destinationSlice:slice destinationLevel:mip
                                      destinationOrigin:MTLOriginMake(ox, oy, oz)];
                                    uploaded_aspects = BO3_ASPECT_ALL;
                                }
                            }
                        }
                        if (uploaded_aspects && full && !t->pending_clears.empty()) {
                            Bo3SubRange dr = subres_range(dst, mip, slice);
                            dr.aspect = uploaded_aspects;
                            c->drop_clears(t, dr);
                        }
                    }
                }
            }
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 49: CopyStructureCount(pDstBuffer, DstAlignedByteOffset, pSrcView)
static SHIM_DEF(ctx_copy_structure_count) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalBuffer *dst = (Bo3MetalBuffer *)rsi;
    uint32_t dst_off = (uint32_t)rdx;
    Bo3MetalUAV *src_uav = (Bo3MetalUAV *)rcx;
    if (!dst || !src_uav || !src_uav->counter_buf) return ret_void();
    os_unfair_lock_lock(&c->lock);
    c->materialize_renamed(dst);
    c->touch_buf(dst);
    id<MTLBuffer> dbuf = dst->dyn_buf ? dst->dyn_buf : dst->mtl_buf;
    uint64_t dbase = dst->dyn_buf ? dst->dyn_offset : 0;
    if (dbuf && (uint64_t)dst_off + 4 <= dst->desc.ByteWidth) {
        c->encode_buffer_copy(src_uav->counter_buf, 0, dbuf, dbase + dst_off, 4);
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// A1a: if the clear [mip, s0, s0+n) of texture `t` overlaps an attachment of the open render pass,
// that pass must end before the clear (D3D11 order). An attachment the clear FULLY covers is never
// read before being overwritten -> its store is dropped (MTLStoreActionDontCare).
static void end_pass_for_clear(Bo3MetalContext *c, Bo3MetalTexture *t, uint32_t mip, uint32_t s0, uint32_t n,
                               bool is_ds, bool clr_depth, bool clr_stencil) {
    if (c->enc_mode != ENC_RENDER || !c->render_enc || !t) return;
    bool overlap = false;
    auto test = [&](uint32_t a0, uint32_t an, MTLStoreAction *store, bool can_drop) {
        const uint64_t ae = (uint64_t)a0 + an, ce = (uint64_t)s0 + n;
        if (!(s0 < ae && a0 < ce)) return;
        overlap = true;
        if (can_drop && s0 <= a0 && ce >= ae && *store != MTLStoreActionDontCare) {
            *store = MTLStoreActionDontCare;
            if (c->perf_on) c->perf_dontcare_saves++;
        }
    };
    const uint32_t layers = std::max(1u, c->active_layers);
    if (!is_ds) {
        for (uint32_t i = 0; i < 8; i++) {
            if (c->active_rt_res[i] != t || !c->active_rt_tex[i] || c->active_rt_lvl[i] != mip) continue;
            const uint32_t al = (c->active_rt_tex[i].textureType == MTLTextureType3D) ? 1u : layers;
            test(c->active_rt_sl[i], al, &c->active_rt_store[i], true);
        }
    } else if (c->active_ds_res == t && c->active_ds_tex && c->active_ds_lvl == mip) {
        MTLStoreAction dummy = MTLStoreActionStore;
        test(c->active_ds_sl, layers, clr_depth ? &c->active_ds_store : &dummy, clr_depth);
        if (c->active_dsv_has_stencil) test(c->active_ds_sl, layers, clr_stencil ? &c->active_st_store : &dummy, clr_stencil);
    }
    if (overlap) c->end_active_encoder(SPLIT_CLR);
}

// slot 50: ClearRenderTargetView(pRTV, ColorRGBA[4])
static SHIM_DEF(ctx_clear_rtv) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalRTV *rtv = (Bo3MetalRTV *)rsi;
    const float *col = (const float *)rdx;
    if (!rtv || !col) return ret_void();

    @autoreleasepool {
    os_unfair_lock_lock(&c->lock);
    // A1b: TBDR clear folding per texture subresource. The clear is only RECORDED here; it becomes
    // MTLLoadActionClear of the next pass attaching the subresource, or a minimal clear pass right
    // before anything else reads / partially writes it.
    if (rtv->resource && rtv->resource->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalTexture *t = (Bo3MetalTexture *)rtv->resource;
        id<MTLTexture> mt = resolve_rtv_mtl_texture(rtv);
        if (mt && rtv->mip_slice < mt.mipmapLevelCount) {
            const bool is3d = mt.textureType == MTLTextureType3D;
            const uint32_t max_sl = is3d ? std::max(1u, (uint32_t)mt.depth >> rtv->mip_slice) : mtl_total_slices(mt);
            const uint32_t s0 = rtv->array_slice;
            const uint32_t n = (s0 < max_sl) ? std::min(std::max(1u, rtv->array_size), max_sl - s0) : 0u;
            if (n > 0) {
                end_pass_for_clear(c, t, rtv->mip_slice, s0, n, false, false, false);
                Bo3TexPendingClear pc = {};
                pc.mip = rtv->mip_slice;
                pc.aspects = BO3_ASPECT_COLOR_DEPTH;
                pc.is_color = true;
                pc.fmt = mt.pixelFormat;
                memcpy(pc.color, col, 16);
                for (uint32_t k = 0; k < n; k++) {
                    pc.slice = s0 + k;
                    c->record_clear(t, pc);
                }
                c->om_dirty = true;
            }
        }
    }
    os_unfair_lock_unlock(&c->lock);
    }
    return ret_void();
}
// Helper for slot 51 (ClearUnorderedAccessViewUint) & slot 52 (ClearUnorderedAccessViewFloat)
static int mtl_format_num_type(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatR8Uint: case MTLPixelFormatRG8Uint: case MTLPixelFormatRGBA8Uint:
        case MTLPixelFormatR16Uint: case MTLPixelFormatRG16Uint: case MTLPixelFormatRGBA16Uint:
        case MTLPixelFormatR32Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRGBA32Uint:
        case MTLPixelFormatRGB10A2Uint:
            return BO3_TEX_NUM_UINT;
        case MTLPixelFormatR8Sint: case MTLPixelFormatRG8Sint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatR16Sint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA16Sint:
        case MTLPixelFormatR32Sint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA32Sint:
            return BO3_TEX_NUM_SINT;
        default:
            return BO3_TEX_NUM_FLOAT;
    }
}
// ---- D3D11 typed-UAV clear packing -------------------------------------------------------
// Channel layout of a DXGI format as stored in memory (channel k maps D3D Values[map[k]]).
struct Bo3ChanLayout {
    uint8_t nch = 0;
    uint8_t bits[4] = {0, 0, 0, 0};
    uint8_t map[4] = {0, 1, 2, 3};
    char    kind = 'u'; // 'f' float32, 'h' half, 'n' unorm, 's' snorm, 'u' uint, 'i' sint, 'p' r11g11b10 float
};
static bool dxgi_chan_layout(uint32_t f, Bo3ChanLayout *L) {
    auto set = [&](uint8_t n, uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3, char k) {
        L->nch = n; L->bits[0] = b0; L->bits[1] = b1; L->bits[2] = b2; L->bits[3] = b3; L->kind = k;
    };
    switch (f) {
        case 1: case 3: set(4, 32, 32, 32, 32, 'u'); return true;
        case 2: set(4, 32, 32, 32, 32, 'f'); return true;
        case 4: set(4, 32, 32, 32, 32, 'i'); return true;
        case 5: case 7: set(3, 32, 32, 32, 0, 'u'); return true;
        case 6: set(3, 32, 32, 32, 0, 'f'); return true;
        case 8: set(3, 32, 32, 32, 0, 'i'); return true;
        case 9: case 12: set(4, 16, 16, 16, 16, 'u'); return true;
        case 10: set(4, 16, 16, 16, 16, 'h'); return true;
        case 11: set(4, 16, 16, 16, 16, 'n'); return true;
        case 13: set(4, 16, 16, 16, 16, 's'); return true;
        case 14: set(4, 16, 16, 16, 16, 'i'); return true;
        case 15: case 17: set(2, 32, 32, 0, 0, 'u'); return true;
        case 16: set(2, 32, 32, 0, 0, 'f'); return true;
        case 18: set(2, 32, 32, 0, 0, 'i'); return true;
        case 23: case 25: set(4, 10, 10, 10, 2, 'u'); return true;
        case 24: set(4, 10, 10, 10, 2, 'n'); return true;
        case 26: set(3, 11, 11, 10, 0, 'p'); return true;
        case 27: case 30: set(4, 8, 8, 8, 8, 'u'); return true;
        case 28: case 29: set(4, 8, 8, 8, 8, 'n'); return true;
        case 31: set(4, 8, 8, 8, 8, 's'); return true;
        case 32: set(4, 8, 8, 8, 8, 'i'); return true;
        case 33: case 36: set(2, 16, 16, 0, 0, 'u'); return true;
        case 34: set(2, 16, 16, 0, 0, 'h'); return true;
        case 35: set(2, 16, 16, 0, 0, 'n'); return true;
        case 37: set(2, 16, 16, 0, 0, 's'); return true;
        case 38: set(2, 16, 16, 0, 0, 'i'); return true;
        case 39: case 42: set(1, 32, 0, 0, 0, 'u'); return true;
        case 40: case 41: set(1, 32, 0, 0, 0, 'f'); return true;
        case 43: set(1, 32, 0, 0, 0, 'i'); return true;
        case 48: case 50: set(2, 8, 8, 0, 0, 'u'); return true;
        case 49: set(2, 8, 8, 0, 0, 'n'); return true;
        case 51: set(2, 8, 8, 0, 0, 's'); return true;
        case 52: set(2, 8, 8, 0, 0, 'i'); return true;
        case 53: case 57: set(1, 16, 0, 0, 0, 'u'); return true;
        case 54: set(1, 16, 0, 0, 0, 'h'); return true;
        case 55: case 56: set(1, 16, 0, 0, 0, 'n'); return true;
        case 58: set(1, 16, 0, 0, 0, 's'); return true;
        case 59: set(1, 16, 0, 0, 0, 'i'); return true;
        case 60: case 62: set(1, 8, 0, 0, 0, 'u'); return true;
        case 61: set(1, 8, 0, 0, 0, 'n'); return true;
        case 63: set(1, 8, 0, 0, 0, 's'); return true;
        case 64: set(1, 8, 0, 0, 0, 'i'); return true;
        case 65: set(1, 8, 0, 0, 0, 'n'); L->map[0] = 3; return true; // A8_UNORM stores alpha
        case 87: case 88: case 90: case 91: case 92: case 93:
            set(4, 8, 8, 8, 8, (f == 90 || f == 92) ? 'u' : 'n');
            L->map[0] = 2; L->map[1] = 1; L->map[2] = 0; L->map[3] = 3; // memory order B,G,R,A
            return true;
        default: return false;
    }
}
static uint32_t f32_to_small_float(float f, int mant_bits) { // unsigned 5-bit-exponent float (R11G11B10)
    if (!(f > 0.0f)) return 0;
    uint32_t u; memcpy(&u, &f, 4);
    int e = (int)((u >> 23) & 0xff) - 127 + 15;
    uint32_t m = u & 0x7fffffu;
    uint32_t emax = 31;
    if ((u >> 23 & 0xff) == 0xff) return (emax << mant_bits) | (m ? 1u : 0u);
    if (e >= (int)emax) return ((emax - 1) << mant_bits) | ((1u << mant_bits) - 1);
    if (e <= 0) return 0;
    return ((uint32_t)e << mant_bits) | (m >> (23 - mant_bits));
}
// Pack one element; returns element size in bytes (0 if unsupported). uint clears copy the low
// n bits RAW into every channel (no conversion); float clears convert to the channel encoding.
static uint32_t pack_uav_clear_element(uint32_t dxgi, const uint32_t uvals[4], const float fvals[4],
                                       bool is_float, uint8_t out[16]) {
    Bo3ChanLayout L;
    if (!dxgi_chan_layout(dxgi, &L)) return 0;
    memset(out, 0, 16);
    uint32_t total_bits = 0;
    for (int k = 0; k < L.nch; k++) total_bits += L.bits[k];
    uint64_t lo = 0, hi = 0; // little-endian bit accumulator (max 128 bits)
    uint32_t bitpos = 0;
    for (int k = 0; k < L.nch; k++) {
        const uint32_t nb = L.bits[k];
        const int src = L.map[k];
        uint64_t v = 0;
        if (!is_float) {
            v = uvals[src];
        } else {
            float f = fvals[src];
            switch (L.kind) {
                case 'f': { uint32_t u; memcpy(&u, &f, 4); v = u; break; }
                case 'h': { __fp16 h = (__fp16)f; uint16_t u; memcpy(&u, &h, 2); v = u; break; }
                case 'n': { float c = std::clamp(f, 0.0f, 1.0f); v = (uint64_t)llroundf(c * (float)((1u << nb) - 1)); break; }
                case 's': { float c = std::clamp(f, -1.0f, 1.0f); int64_t iv = llroundf(c * (float)((1u << (nb - 1)) - 1)); v = (uint64_t)iv; break; }
                case 'p': v = f32_to_small_float(f, nb == 10 ? 5 : 6); break;
                case 'i': v = (uint64_t)(int64_t)f; break;
                default:  v = (uint64_t)(f > 0.0f ? f : 0.0f); break;
            }
        }
        if (nb < 64) v &= ((1ULL << nb) - 1ULL);
        if (bitpos < 64) {
            lo |= v << bitpos;
            if (bitpos + nb > 64 && bitpos > 0) hi |= v >> (64 - bitpos);
        } else {
            hi |= v << (bitpos - 64);
        }
        bitpos += nb;
    }
    memcpy(out, &lo, 8);
    memcpy(out + 8, &hi, 8);
    return (total_bits + 7) / 8;
}
// Same-size integer pixel format used to write RAW bits for ClearUnorderedAccessViewUint on
// float / unorm / snorm UAV textures (Invalid -> no raw view available).
static MTLPixelFormat raw_uint_view_format(MTLPixelFormat pf) {
    return bo3_mtl_raw_uint_view_format(pf);
}

static void do_clear_uav(Bo3MetalContext *c, Bo3MetalUAV *uav, const uint32_t uvals[4],
                         const float fvals[4], bool is_float) {
    if (!c || !uav) return;
    @autoreleasepool {
    os_unfair_lock_lock(&c->lock);
    c->ensure_clear_uav_psos();
    if (uav->is_buffer && uav->resource) {
        Bo3MetalBuffer *b = (Bo3MetalBuffer *)uav->resource;
        id<MTLBuffer> mb = b->mtl_buf ? b->mtl_buf : uav->mtl_buf;
        // Element pattern: raw/structured -> Values[0] into every DWORD; typed -> packed element
        uint8_t pat[16] = {0};
        uint32_t esz = 0;
        const uint32_t fmt = uav->desc.Format;
        const bool structured = b->desc.StructureByteStride != 0 && !uav->is_raw && fmt == 0;
        if (uav->is_raw || structured || fmt == 0) {
            uint32_t v = 0;
            if (is_float) memcpy(&v, &fvals[0], 4); else v = uvals[0];
            memcpy(pat, &v, 4);
            esz = 4;
        } else {
            esz = pack_uav_clear_element(fmt, uvals, fvals, is_float, pat);
        }
        const uint64_t elem_bytes = std::max(1u, uav->buf_stride);
        uint64_t byte_off = uav->buf_offset;
        uint64_t byte_len = (uint64_t)uav->buf_num_elements * elem_bytes;
        // Validate byte bounds against the real Metal buffer (never write out of bounds!)
        if (mb && esz > 0 && byte_off < mb.length) {
            byte_len = std::min<uint64_t>(byte_len, mb.length - byte_off);
            byte_len -= byte_len % esz; // whole elements only
        } else {
            byte_len = 0;
        }
        if (byte_len > 0 && byte_len <= 0xffffffffULL && byte_off <= 0xffffffffULL) {
            c->materialize_renamed(b);
            c->touch_buf(b);
            struct { uint32_t pat[4]; uint32_t off; uint32_t cnt; uint32_t period; uint32_t pad; } p = {};
            const bool dword_ok = ((byte_off | byte_len) & 3ULL) == 0 && (esz % 4 == 0 || 4 % esz == 0);
            id<MTLComputePipelineState> pso = nil;
            if (dword_ok && c->clear_uav_buf_pso) {
                // Replicate sub-DWORD elements (1/2 bytes) into a full DWORD pattern
                uint8_t rep[16] = {0};
                uint32_t period_bytes = std::max(esz, 4u);
                for (uint32_t i = 0; i < period_bytes; i++) rep[i] = pat[i % esz];
                memcpy(p.pat, rep, 16);
                p.off = (uint32_t)(byte_off / 4);
                p.cnt = (uint32_t)(byte_len / 4);
                p.period = period_bytes / 4;
                pso = c->clear_uav_buf_pso;
            } else if (c->clear_uav_bytes_pso) {
                memcpy(p.pat, pat, 16);
                p.off = (uint32_t)byte_off;
                p.cnt = (uint32_t)byte_len;
                p.period = esz;
                pso = c->clear_uav_bytes_pso;
            }
            if (pso && p.cnt > 0) {
                c->ensure_compute_encoder();
                [c->compute_enc setComputePipelineState:pso];
                [c->compute_enc setBuffer:mb offset:0 atIndex:0];
                [c->compute_enc setBytes:&p length:sizeof(p) atIndex:1];
                [c->compute_enc dispatchThreads:MTLSizeMake(p.cnt, 1, 1)
                          threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(p.cnt, 64), 1, 1)];
            }
        }
    } else if (!uav->is_buffer && uav->mtl_tex && (uav->mtl_tex.usage & MTLTextureUsageShaderWrite)) {
        id<MTLTexture> t = uav->mtl_tex;
        int nt = mtl_format_num_type(t.pixelFormat);
        uint32_t payload[4];
        if (nt == BO3_TEX_NUM_FLOAT && !is_float) {
            // ClearUnorderedAccessViewUint on a FLOAT/UNORM/SNORM UAV: copy RAW bits (no int->float
            // conversion) by writing through a same-size integer view of the texture.
            MTLPixelFormat raw_pf = raw_uint_view_format(t.pixelFormat);
            id<MTLTexture> rv = nil;
            if (raw_pf != MTLPixelFormatInvalid && bo3_mtl_can_view_as(t.pixelFormat, t.usage, raw_pf)) {
                rv = [t newTextureViewWithPixelFormat:raw_pf];
            }
            if (rv) {
                memcpy(payload, uvals, 16);
                if (t.pixelFormat == MTLPixelFormatBGRA8Unorm) std::swap(payload[0], payload[2]);
                if (t.pixelFormat == MTLPixelFormatRG11B10Float) {
                    payload[0] = (uvals[0] & 0x7ffu) | ((uvals[1] & 0x7ffu) << 11) | ((uvals[2] & 0x3ffu) << 22);
                }
                t = rv;
                nt = BO3_TEX_NUM_UINT;
            } else {
                // 32-bit float formats: as_type<float>(u) preserves the bit pattern exactly
                memcpy(payload, uvals, 16);
            }
        } else if (nt == BO3_TEX_NUM_FLOAT) {
            memcpy(payload, fvals, 16);
        } else {
            if (is_float) {
                for (int i = 0; i < 4; i++) payload[i] = (nt == BO3_TEX_NUM_SINT) ? (uint32_t)(int32_t)fvals[i] : (uint32_t)fvals[i];
            } else {
                memcpy(payload, uvals, 16);
            }
        }
        id<MTLComputePipelineState> pso = nil;
        MTLSize grid = MTLSizeMake(t.width, t.height, 1);
        MTLSize tg   = MTLSizeMake(8, 8, 1);
        switch (t.textureType) {
            case MTLTextureType1D:
                pso = c->clear_uav_1d_pso[nt];
                grid = MTLSizeMake(t.width, 1, 1);
                tg = MTLSizeMake(std::min<NSUInteger>(t.width, 64), 1, 1);
                break;
            case MTLTextureType1DArray:
                pso = c->clear_uav_1d_arr_pso[nt];
                grid = MTLSizeMake(t.width, t.arrayLength, 1);
                tg = MTLSizeMake(std::min<NSUInteger>(t.width, 64), 1, 1);
                break;
            case MTLTextureType2D:
                pso = c->clear_uav_2d_pso[nt];
                grid = MTLSizeMake(t.width, t.height, 1);
                tg = MTLSizeMake(std::min<NSUInteger>(t.width, 8), std::min<NSUInteger>(t.height, 8), 1);
                break;
            case MTLTextureType2DArray:
                pso = c->clear_uav_2d_arr_pso[nt];
                grid = MTLSizeMake(t.width, t.height, t.arrayLength);
                tg = MTLSizeMake(std::min<NSUInteger>(t.width, 8), std::min<NSUInteger>(t.height, 8), 1);
                break;
            case MTLTextureType3D:
                pso = c->clear_uav_3d_pso[nt];
                grid = MTLSizeMake(t.width, t.height, t.depth);
                tg = MTLSizeMake(std::min<NSUInteger>(t.width, 4), std::min<NSUInteger>(t.height, 4), std::min<NSUInteger>(t.depth, 4));
                break;
            default: break;
        }
        if (pso && grid.width > 0 && grid.height > 0 && grid.depth > 0) {
            c->touch(uav->resource);
            c->ensure_compute_encoder();
            if (c->compute_enc) {
                [c->compute_enc setComputePipelineState:pso];
                [c->compute_enc setTexture:t atIndex:0];
                [c->compute_enc setBytes:payload length:16 atIndex:0];
                [c->compute_enc dispatchThreads:grid threadsPerThreadgroup:tg];
                if (uav->resource && uav->resource->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
                    c->drop_clears((Bo3MetalTexture *)uav->resource, range_of_uav(uav));
                }
            }
        }
    }
    os_unfair_lock_unlock(&c->lock);
    }
}
// slot 51: ClearUnorderedAccessViewUint(pUAV, Values[4])
static SHIM_DEF(ctx_clear_uav_uint) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalUAV *uav = (Bo3MetalUAV *)rsi;
    const uint32_t *vals = (const uint32_t *)rdx;
    if (!uav || !vals) return ret_void();
    float dummy_f[4] = {0};
    do_clear_uav(c, uav, vals, dummy_f, false);
    return ret_void();
}
// slot 52: ClearUnorderedAccessViewFloat(pUAV, Values[4])
static SHIM_DEF(ctx_clear_uav_float) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalUAV *uav = (Bo3MetalUAV *)rsi;
    const float *vals = (const float *)rdx;
    if (!uav || !vals) return ret_void();
    uint32_t dummy_u[4] = {0};
    do_clear_uav(c, uav, dummy_u, vals, true);
    return ret_void();
}
// slot 53: ClearDepthStencilView(pDSV, ClearFlags, Depth(xmm0), Stencil(rcx))
static SHIM_DEF(ctx_clear_dsv) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalDSV *dsv = (Bo3MetalDSV *)rsi;
    uint32_t flags = (uint32_t)rdx;
    float depth = xmm_to_f32(xmm0);
    uint8_t stencil = (uint8_t)rcx;
    if (!dsv) return ret_void();
    const bool do_depth   = (flags & BO3_D3D11_CLEAR_DEPTH) != 0;
    const bool do_stencil = ((flags & BO3_D3D11_CLEAR_STENCIL) != 0) && dsv->has_stencil;
    if (!do_depth && !do_stencil) return ret_void();

    @autoreleasepool {
    os_unfair_lock_lock(&c->lock);
    if (dsv->resource && dsv->resource->dimension != BO3_D3D11_RESOURCE_DIMENSION_BUFFER) {
        Bo3MetalTexture *t = (Bo3MetalTexture *)dsv->resource;
        id<MTLTexture> dt = t->current_mtl_texture();
        if (dt && dsv->mip_slice < dt.mipmapLevelCount) {
            const uint32_t max_sl = mtl_total_slices(dt);
            const uint32_t s0 = dsv->array_slice;
            const uint32_t n = (s0 < max_sl) ? std::min(std::max(1u, dsv->array_size), max_sl - s0) : 0u;
            if (n > 0) {
                end_pass_for_clear(c, t, dsv->mip_slice, s0, n, true, do_depth, do_stencil);
                Bo3TexPendingClear pc = {};
                pc.mip = dsv->mip_slice;
                pc.aspects = (uint8_t)((do_depth ? BO3_ASPECT_COLOR_DEPTH : 0) | (do_stencil ? BO3_ASPECT_STENCIL : 0));
                pc.is_color = false;
                pc.fmt = dt.pixelFormat;
                pc.depth = depth;
                pc.stencil = stencil;
                for (uint32_t k = 0; k < n; k++) {
                    pc.slice = s0 + k;
                    c->record_clear(t, pc);
                }
                c->om_dirty = true;
            }
        }
    }
    os_unfair_lock_unlock(&c->lock);
    }
    return ret_void();
}
// slot 54: GenerateMips(pSRV)
static SHIM_DEF(ctx_generate_mips) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalSRV *srv = (Bo3MetalSRV *)rsi;
    if (!srv || srv->is_buffer) return ret_void();
    os_unfair_lock_lock(&c->lock);
    id<MTLTexture> mt = (srv->resource && ((Bo3MetalTexture *)srv->resource)->is_backbuffer)
                        ? ((Bo3MetalTexture *)srv->resource)->current_mtl_texture()
                        : srv->mtl_tex;
    if (mt && mt.mipmapLevelCount > 1 &&
        !is_compressed_mtl_format(mt.pixelFormat) &&
        !is_depth_mtl_format(mt.pixelFormat) &&
        !is_integer_mtl_format(mt.pixelFormat)) {
        c->materialize_res(srv->resource, whole_range(srv->resource));
        c->touch(srv->resource);
        c->ensure_blit_encoder();
        [c->blit_enc generateMipmapsForTexture:mt];
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 57: ResolveSubresource(pDst, DstSub, pSrc, SrcSub, Format)
static SHIM_DEF(ctx_resolve_subres) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalTexture *dt = (Bo3MetalTexture *)rsi;
    uint32_t dsub = (uint32_t)rdx;
    Bo3MetalTexture *st = (Bo3MetalTexture *)rcx;
    uint32_t ssub = (uint32_t)r8;
    uint32_t fmt = (uint32_t)r9;
    if (!dt || !st) return ret_void();
    os_unfair_lock_lock(&c->lock);
    id<MTLTexture> md = dt->current_mtl_texture(), ms = st->current_mtl_texture();
    if (!md || !ms) { os_unfair_lock_unlock(&c->lock); return ret_void(); }
    c->end_active_encoder(SPLIT_BLIT);
    c->ensure_cmd_buf();

    // Honor requested DXGI Format via compatible pixel-format views on ms and md. Depth MSAA sources
    // keep their depth format (e.g. R32_TYPELESS depth + DXGI_FORMAT_R32_FLOAT): a Depth32Float ->
    // R32Float view is illegal in Metal, so the resolve runs in the depth format and a mismatched
    // color destination receives the resolved bits through the staging-buffer bitcast below.
    const bool src_depth = is_depth_mtl_format(ms.pixelFormat);
    if (fmt != 0 && !src_depth) {
        MTLPixelFormat req_pf = bo3_dxgi_to_metal_format(fmt, false, false).pixel_format;
        if (req_pf != MTLPixelFormatInvalid) {
            if (ms.pixelFormat != req_pf && bo3_mtl_can_view_as(ms.pixelFormat, ms.usage, req_pf)) {
                id<MTLTexture> v = st->get_or_create_view(req_pf, ms.textureType, 0, 0, 0, 0);
                if (v && v.pixelFormat == req_pf) ms = v;
            }
            if (md.pixelFormat != req_pf && bo3_mtl_can_view_as(md.pixelFormat, md.usage, req_pf)) {
                id<MTLTexture> v = dt->get_or_create_view(req_pf, md.textureType, 0, 0, 0, 0);
                if (v && v.pixelFormat == req_pf) md = v;
            }
        }
    }

    uint32_t dm = dt->d3d_mip_levels(), sm = st->d3d_mip_levels();
    uint32_t dmip = dsub % dm, dsl = dsub / dm;
    uint32_t smip = ssub % sm, ssl = ssub / sm;
    if (dmip >= md.mipmapLevelCount || smip >= ms.mipmapLevelCount ||
        dsl >= mtl_total_slices(md) || ssl >= mtl_total_slices(ms)) {
        os_unfair_lock_unlock(&c->lock);
        return ret_void();
    }
    const bool can_direct = (ms.sampleCount > 1 && md.sampleCount == 1 && ms.pixelFormat == md.pixelFormat);
    const bool can_depth_bitcast = (!can_direct && ms.sampleCount > 1 && md.sampleCount == 1 && src_depth &&
                                    bitcast_texel_bytes(md.pixelFormat) == bo3_mtl_depth_bytes_per_pixel(ms.pixelFormat) &&
                                    !is_compressed_mtl_format(md.pixelFormat));
    const bool can_copy_1x = (!can_direct && !can_depth_bitcast &&
                              ms.sampleCount == 1 && md.sampleCount == 1 && md.pixelFormat == ms.pixelFormat);
    if (!can_direct && !can_depth_bitcast && !can_copy_1x) {
        os_unfair_lock_unlock(&c->lock);
        return ret_void();
    }
    const uint32_t sw = std::max(1u, (uint32_t)ms.width >> smip);
    const uint32_t sh = std::max(1u, (uint32_t)ms.height >> smip);
    const uint32_t dw = std::max(1u, (uint32_t)md.width >> dmip);
    const uint32_t dh = std::max(1u, (uint32_t)md.height >> dmip);
    const bool full_dst = (sw >= dw && sh >= dh);
    const bool depth_only_dst = (can_direct && is_depth_mtl_format(ms.pixelFormat) &&
                                 md.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) ||
                                (can_depth_bitcast && md.pixelFormat == MTLPixelFormatDepth32Float_Stencil8);
    const uint8_t written_aspect = depth_only_dst ? (uint8_t)BO3_ASPECT_COLOR_DEPTH
                                                  : (uint8_t)BO3_ASPECT_ALL;
    const Bo3SubRange dst_r = subres_range(&dt->res, dmip, dsl);
    if (!c->pending_clear_texs.empty()) {
        c->materialize_res(&st->res, subres_range(&st->res, smip, ssl));
        if (!full_dst) {
            c->materialize_res(&dt->res, dst_r);
        } else if (written_aspect != BO3_ASPECT_ALL) {
            Bo3SubRange pres = dst_r;
            pres.aspect = (uint8_t)(BO3_ASPECT_ALL & ~written_aspect);
            c->materialize_res(&dt->res, pres);
        }
    }
    c->touch(&dt->res);
    c->touch(&st->res);
    bool wrote = false;
    if (can_direct) {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        if (is_depth_mtl_format(ms.pixelFormat)) {
            rpd.depthAttachment.texture = ms;
            rpd.depthAttachment.level = smip;
            rpd.depthAttachment.slice = ssl;
            rpd.depthAttachment.resolveTexture = md;
            rpd.depthAttachment.resolveLevel = dmip;
            rpd.depthAttachment.resolveSlice = dsl;
            rpd.depthAttachment.loadAction = MTLLoadActionLoad;
            rpd.depthAttachment.storeAction = MTLStoreActionStoreAndMultisampleResolve;
        } else {
            rpd.colorAttachments[0].texture = ms;
            rpd.colorAttachments[0].level = smip;
            rpd.colorAttachments[0].slice = ssl;
            rpd.colorAttachments[0].resolveTexture = md;
            rpd.colorAttachments[0].resolveLevel = dmip;
            rpd.colorAttachments[0].resolveSlice = dsl;
            rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve;
        }
        id<MTLRenderCommandEncoder> enc = [c->cmd_buf renderCommandEncoderWithDescriptor:rpd];
        if (enc) {
            c->pass_splits++;
            if (c->perf_on) c->perf_account_pass(rpd);
            [enc endEncoding];
            wrote = true;
        }
    } else if (can_depth_bitcast) {
        // Depth MSAA -> same-family non-depth (or other depth) texture: resolve into a temporary
        // single-sample depth texture of the source format, then raw-bitcast it into md.
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ms.pixelFormat
                                                                                       width:sw height:sh mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> tmp = [c->device->mtl_dev newTextureWithDescriptor:td];
        if (tmp) {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.depthAttachment.texture = ms;
            rpd.depthAttachment.level = smip;
            rpd.depthAttachment.slice = ssl;
            rpd.depthAttachment.resolveTexture = tmp;
            rpd.depthAttachment.loadAction = MTLLoadActionLoad;
            rpd.depthAttachment.storeAction = MTLStoreActionStoreAndMultisampleResolve;
            id<MTLRenderCommandEncoder> enc = [c->cmd_buf renderCommandEncoderWithDescriptor:rpd];
            if (enc) {
                c->pass_splits++;
                if (c->perf_on) c->perf_account_pass(rpd);
                [enc endEncoding];
                wrote = encode_bitcast_texture_copy(c, tmp, 0, 0, MTLOriginMake(0, 0, 0),
                                                    MTLSizeMake(std::min(sw, dw), std::min(sh, dh), 1), md, dsl, dmip,
                                                    MTLOriginMake(0, 0, 0));
            }
        }
    } else if (can_copy_1x) {
        c->ensure_blit_encoder();
        if (c->blit_enc) {
            [c->blit_enc copyFromTexture:ms sourceSlice:ssl sourceLevel:smip
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(std::min(sw, dw), std::min(sh, dh), 1)
                               toTexture:md destinationSlice:dsl destinationLevel:dmip
                       destinationOrigin:MTLOriginMake(0, 0, 0)];
            wrote = true;
        }
    }
    if (wrote && full_dst && !c->pending_clear_texs.empty()) {
        Bo3SubRange dr = dst_r;
        dr.aspect = written_aspect;
        c->drop_clears(dt, dr);
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// Compute shader slots: 67 CSSetShaderResources, 68 CSSetUnorderedAccessViews, 69 CSSetShader, 70 CSSetSamplers, 71 CSSetConstantBuffers
static SHIM_DEF(ctx_cs_set_srv) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    uint32_t start = (uint32_t)rsi, count = (uint32_t)rdx;
    Bo3MetalSRV *const *srvs = (Bo3MetalSRV *const *)rcx;
    os_unfair_lock_lock(&c->lock);
    set_srvs_checked(c, c->cs_srv, start, count, srvs);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
static SHIM_DEF(ctx_cs_set_uav) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    uint32_t start = (uint32_t)rsi, count = (uint32_t)rdx;
    Bo3MetalUAV *const *uavs = (Bo3MetalUAV *const *)rcx;
    const uint32_t *init_counts = (const uint32_t *)r8;
    os_unfair_lock_lock(&c->lock);
    if (uavs) {
        for (uint32_t i = 0; i < count && start + i < 64; i++) {
            if (uavs[i] && uavs[i]->resource) {
                Bo3SubRange ur = range_of_uav(uavs[i]);
                c->unbind_srvs_overlapping(ur);
                c->unbind_om_overlapping(ur);
                c->unbind_uavs_overlapping(ur, true, false);
            }
        }
    }
    set_obj_array(c->cs_uav, start, count, 64, uavs);
    if (init_counts && uavs) {
        for (uint32_t i = 0; i < count && start + i < 64; i++) {
            if (uavs[i] && uavs[i]->counter_buf && init_counts[i] != 0xffffffffu) {
                c->encode_ordered_u32_write(uavs[i]->counter_buf, 0, init_counts[i]);
            }
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
static SHIM_DEF(ctx_cs_set_shader) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    Bo3MetalShader *s = (Bo3MetalShader *)rsi;
    os_unfair_lock_lock(&c->lock);
    if (s) s->com.add_ref();
    if (c->cs) c->cs->com.release();
    c->cs = s;
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
static SHIM_DEF(ctx_cs_set_samplers) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    set_obj_array(c->cs_smp, (uint32_t)rsi, (uint32_t)rdx, 16, (Bo3MetalSamplerState *const *)rcx);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
static SHIM_DEF(ctx_cs_set_cb) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    set_obj_array(c->cs_cb, (uint32_t)rsi, (uint32_t)rdx, 14, (Bo3MetalBuffer *const *)rcx);
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
void Bo3MetalContext::clear_all_state() {
    end_active_encoder();
    auto release_arr = [](auto **arr, size_t n) {
        for (size_t i = 0; i < n; i++) {
            if (arr[i]) { ((Bo3ComBase *)arr[i])->release(); arr[i] = nullptr; }
        }
    };
    release_arr(rtvs, 8);
    rtv_count = 0;
    if (dsv) { dsv->com.release(); dsv = nullptr; }
    release_arr(om_uavs, 8);
    if (blend_state) { blend_state->com.release(); blend_state = nullptr; }
    if (ds_state)    { ds_state->com.release();    ds_state = nullptr; }
    if (rs_state)    { rs_state->com.release();    rs_state = nullptr; }
    if (input_layout){ input_layout->com.release(); input_layout = nullptr; }
    release_arr(vbs, 16);
    memset(vb_strides, 0, sizeof(vb_strides));
    memset(vb_offsets, 0, sizeof(vb_offsets));
    if (ib)          { ib->res.com.release(); ib = nullptr; }
    ib_type = MTLIndexTypeUInt16;
    ib_offset = 0;
    if (vs)          { vs->com.release(); vs = nullptr; }
    if (ps)          { ps->com.release(); ps = nullptr; }
    if (cs)          { cs->com.release(); cs = nullptr; }
    release_arr(vs_cb, 14);  release_arr(ps_cb, 14);  release_arr(cs_cb, 14);
    release_arr(vs_srv, 128);release_arr(ps_srv, 128);release_arr(cs_srv, 128);
    release_arr(vs_smp, 16); release_arr(ps_smp, 16); release_arr(cs_smp, 16);
    release_arr(cs_uav, 64);
    for (int i = 0; i < 8; i++) {
        active_rt_tex[i] = nil;
        active_rt_lvl[i] = 0; active_rt_sl[i] = 0; active_rt_arr_sz[i] = 0;
        active_rt_fmt[i] = MTLPixelFormatInvalid;
        if (active_rt_res[i]) { active_rt_res[i]->res.com.release(); active_rt_res[i] = nullptr; }
        active_rt_store[i] = MTLStoreActionStore;
    }
    active_rtv_count = 0;
    active_ds_tex = nil; active_ds_lvl = 0; active_ds_sl = 0; active_ds_arr_sz = 0; active_ds_flags = 0;
    active_uav_only = false;
    active_dsv_has_stencil = false;
    pass_has_frag_uav_write = false;
    pass_w = 0; pass_h = 0;
    if (active_ds_res) { active_ds_res->res.com.release(); active_ds_res = nullptr; }
    om_dirty = true;
    pso_dirty = true;
    last_pso_valid = false;
    last_pso = nil;
    viewport_count = 0; scissor_count = 0;
    blend_factor[0] = blend_factor[1] = blend_factor[2] = blend_factor[3] = 1.0f;
    sample_mask = 0xffffffffu;
    stencil_ref = 0;
    topology = BO3_D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
}

// slot 110: ClearState
static SHIM_DEF(ctx_clear_state) {
    SHIM_UNUSED_ALL();
    @autoreleasepool {
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    c->clear_all_state(); // deferred clears are resource contents, not bindings: they persist
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
    }
}
// slot 111: Flush
static SHIM_DEF(ctx_flush) {
    SHIM_UNUSED_ALL();
    bo3_context_flush_now((Bo3MetalContext *)rdi, false);
    return ret_void();
}
// slot 3: ID3D11DeviceChild::GetDevice
static SHIM_DEF(ctx_get_device) {
    SHIM_UNUSED_ALL();
    Bo3MetalContext *c = (Bo3MetalContext *)rdi;
    if (rsi && c && c->device) {
        c->device->add_external_ref();
        *(void **)rsi = c->device;
    }
    return ret_void();
}
// No-op stubs for GS/HS/DS/SO/ExecuteCommandList (confirmed unused/stubbed by Aspyr)
static SHIM_DEF(ctx_noop_void) { SHIM_UNUSED_ALL(); return ret_void(); }

// =========================================================================
// ID3D11DeviceContext getters (slots 72..109) — every out-param is written (AddRef'd COM
// pointers or NULL/zero), never left as garbage.
// =========================================================================

template <typename T>
static void get_obj_array(Bo3MetalContext *c, T *const *src, uint32_t cap, uint64_t start_u, uint64_t num_u, uint64_t out_u) {
    T **out = (T **)out_u;
    if (!out) return;
    uint32_t start = (uint32_t)start_u, num = (uint32_t)num_u;
    os_unfair_lock_lock(&c->lock);
    for (uint32_t i = 0; i < num; i++) {
        T *v = (start + i < cap) ? src[start + i] : nullptr;
        if (v) ((Bo3ComBase *)v)->add_ref();
        out[i] = v;
    }
    os_unfair_lock_unlock(&c->lock);
}
template <typename T>
static void get_obj(Bo3MetalContext *c, T *src, uint64_t out_u) {
    T **out = (T **)out_u;
    if (!out) return;
    os_unfair_lock_lock(&c->lock);
    if (src) ((Bo3ComBase *)src)->add_ref();
    *out = src;
    os_unfair_lock_unlock(&c->lock);
}
static void zero_ptr_array(uint64_t num_u, uint64_t out_u) {
    void **out = (void **)out_u;
    if (!out) return;
    for (uint32_t i = 0; i < (uint32_t)num_u; i++) out[i] = nullptr;
}
// (ppShader, ppClassInstances, pNumClassInstances): no class linkage support -> 0 instances
static void get_shader_out(Bo3MetalContext *c, Bo3MetalShader *sh, uint64_t pp, uint64_t pci, uint64_t pnum) {
    get_obj(c, sh, pp);
    if (pnum) {
        uint32_t n = *(uint32_t *)pnum;
        if (pci) zero_ptr_array(n, pci);
        *(uint32_t *)pnum = 0;
    }
}

static SHIM_DEF(ctx_vs_get_cb)  { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->vs_cb, 14, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_ps_get_srv) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->ps_srv, 128, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_ps_get_shader) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_shader_out(c, c->ps, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_ps_get_smp) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->ps_smp, 16, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_vs_get_shader) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_shader_out(c, c->vs, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_ps_get_cb)  { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->ps_cb, 14, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_ia_get_il)  { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj(c, c->input_layout, rsi); return ret_void(); }
// IAGetVertexBuffers(StartSlot, NumBuffers, ppVBs, pStrides, pOffsets)
static SHIM_DEF(ctx_ia_get_vbs) {
    SHIM_UNUSED_ALL();
    auto *c = (Bo3MetalContext *)rdi;
    uint32_t start = (uint32_t)rsi, num = (uint32_t)rdx;
    Bo3MetalBuffer **pp = (Bo3MetalBuffer **)rcx;
    uint32_t *strides = (uint32_t *)r8, *offsets = (uint32_t *)r9;
    os_unfair_lock_lock(&c->lock);
    for (uint32_t i = 0; i < num; i++) {
        uint32_t s = start + i;
        Bo3MetalBuffer *b = (s < 16) ? c->vbs[s] : nullptr;
        if (pp) { if (b) b->res.com.add_ref(); pp[i] = b; }
        if (strides) strides[i] = (s < 16) ? c->vb_strides[s] : 0;
        if (offsets) offsets[i] = (s < 16) ? c->vb_offsets[s] : 0;
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// IAGetIndexBuffer(ppIB, pFormat, pOffset)
static SHIM_DEF(ctx_ia_get_ib) {
    SHIM_UNUSED_ALL();
    auto *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    if (rsi) { if (c->ib) c->ib->res.com.add_ref(); *(Bo3MetalBuffer **)rsi = c->ib; }
    if (rdx) *(uint32_t *)rdx = c->ib ? ((c->ib_type == MTLIndexTypeUInt32) ? 42u : 57u) : 0u;
    if (rcx) *(uint32_t *)rcx = c->ib_offset;
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
static SHIM_DEF(ctx_gs_get_shader_null) { // GSGetShader / HSGetShader / DSGetShader
    SHIM_UNUSED_ALL();
    if (rsi) *(void **)rsi = nullptr;
    if (rcx) { uint32_t n = *(uint32_t *)rcx; if (rdx) zero_ptr_array(n, rdx); *(uint32_t *)rcx = 0; }
    return ret_void();
}
static SHIM_DEF(ctx_get_array_null) { // {GS,HS,DS}Get{ConstantBuffers,ShaderResources,Samplers}(Start, Num, pp)
    SHIM_UNUSED_ALL();
    zero_ptr_array(rdx, rcx);
    return ret_void();
}
static SHIM_DEF(ctx_ia_get_topology) {
    SHIM_UNUSED_ALL();
    auto *c = (Bo3MetalContext *)rdi;
    if (rsi) *(uint32_t *)rsi = c->topology;
    return ret_void();
}
static SHIM_DEF(ctx_vs_get_srv) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->vs_srv, 128, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_vs_get_smp) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->vs_smp, 16, rsi, rdx, rcx); return ret_void(); }
// GetPredication(ppPredicate, pPredicateValue)
static SHIM_DEF(ctx_get_predication) {
    SHIM_UNUSED_ALL();
    if (rsi) *(void **)rsi = nullptr;
    if (rdx) *(int32_t *)rdx = 0;
    return ret_void();
}
// OMGetRenderTargets(NumViews, ppRTVs, ppDSV)
static SHIM_DEF(ctx_om_get_rts) {
    SHIM_UNUSED_ALL();
    auto *c = (Bo3MetalContext *)rdi;
    uint32_t n = (uint32_t)rsi;
    Bo3MetalRTV **pp = (Bo3MetalRTV **)rdx;
    os_unfair_lock_lock(&c->lock);
    if (pp) {
        for (uint32_t i = 0; i < n; i++) {
            Bo3MetalRTV *v = (i < 8) ? c->rtvs[i] : nullptr;
            if (v) v->com.add_ref();
            pp[i] = v;
        }
    }
    if (rcx) { if (c->dsv) c->dsv->com.add_ref(); *(Bo3MetalDSV **)rcx = c->dsv; }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// OMGetRenderTargetsAndUnorderedAccessViews(NumRTVs, ppRTVs, ppDSV, UAVStartSlot, NumUAVs, ppUAVs)
static SHIM_DEF(ctx_om_get_rts_and_uavs) {
    SHIM_UNUSED_ALL();
    auto *c = (Bo3MetalContext *)rdi;
    uint32_t n = (uint32_t)rsi;
    Bo3MetalRTV **pp = (Bo3MetalRTV **)rdx;
    uint32_t ustart = (uint32_t)r8, ucount = (uint32_t)r9;
    Bo3MetalUAV **ppu = (Bo3MetalUAV **)shim_stack_u64(rsp, 0);
    os_unfair_lock_lock(&c->lock);
    if (pp) {
        for (uint32_t i = 0; i < n; i++) {
            Bo3MetalRTV *v = (i < 8) ? c->rtvs[i] : nullptr;
            if (v) v->com.add_ref();
            pp[i] = v;
        }
    }
    if (rcx) { if (c->dsv) c->dsv->com.add_ref(); *(Bo3MetalDSV **)rcx = c->dsv; }
    if (ppu) {
        for (uint32_t i = 0; i < ucount; i++) {
            Bo3MetalUAV *u = (ustart + i < 8) ? c->om_uavs[ustart + i] : nullptr;
            if (u) u->com.add_ref();
            ppu[i] = u;
        }
    }
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// OMGetBlendState(ppBlendState, BlendFactor[4], pSampleMask)
static SHIM_DEF(ctx_om_get_blend) {
    SHIM_UNUSED_ALL();
    auto *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    if (rsi) { if (c->blend_state) c->blend_state->com.add_ref(); *(Bo3MetalBlendState **)rsi = c->blend_state; }
    if (rdx) memcpy((void *)rdx, c->blend_factor, 16);
    if (rcx) *(uint32_t *)rcx = c->sample_mask;
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// OMGetDepthStencilState(ppDepthStencilState, pStencilRef)
static SHIM_DEF(ctx_om_get_ds) {
    SHIM_UNUSED_ALL();
    auto *c = (Bo3MetalContext *)rdi;
    os_unfair_lock_lock(&c->lock);
    if (rsi) { if (c->ds_state) c->ds_state->com.add_ref(); *(Bo3MetalDepthStencilState **)rsi = c->ds_state; }
    if (rdx) *(uint32_t *)rdx = c->stencil_ref;
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
// SOGetTargets(NumBuffers, ppSOTargets)
static SHIM_DEF(ctx_so_get_targets) { SHIM_UNUSED_ALL(); zero_ptr_array(rsi, rdx); return ret_void(); }
static SHIM_DEF(ctx_rs_get_state) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj(c, c->rs_state, rsi); return ret_void(); }
// RSGetViewports(pNumViewports, pViewports) / RSGetScissorRects(pNumRects, pRects)
static SHIM_DEF(ctx_rs_get_viewports) {
    SHIM_UNUSED_ALL();
    auto *c = (Bo3MetalContext *)rdi;
    uint32_t *pn = (uint32_t *)rsi;
    if (!pn) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (rdx) {
        uint32_t cap = *pn;
        for (uint32_t i = 0; i < cap; i++) {
            if (i < c->viewport_count) memcpy((uint8_t *)rdx + i * sizeof(Bo3D3D11_VIEWPORT), &c->viewports[i], sizeof(Bo3D3D11_VIEWPORT));
            else memset((uint8_t *)rdx + i * sizeof(Bo3D3D11_VIEWPORT), 0, sizeof(Bo3D3D11_VIEWPORT));
        }
    }
    *pn = c->viewport_count;
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
static SHIM_DEF(ctx_rs_get_scissors) {
    SHIM_UNUSED_ALL();
    auto *c = (Bo3MetalContext *)rdi;
    uint32_t *pn = (uint32_t *)rsi;
    if (!pn) return ret_void();
    os_unfair_lock_lock(&c->lock);
    if (rdx) {
        uint32_t cap = *pn;
        for (uint32_t i = 0; i < cap; i++) {
            if (i < c->scissor_count) memcpy((uint8_t *)rdx + i * sizeof(Bo3RECT), &c->scissors[i], sizeof(Bo3RECT));
            else memset((uint8_t *)rdx + i * sizeof(Bo3RECT), 0, sizeof(Bo3RECT));
        }
    }
    *pn = c->scissor_count;
    os_unfair_lock_unlock(&c->lock);
    return ret_void();
}
static SHIM_DEF(ctx_cs_get_srv) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->cs_srv, 128, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_cs_get_uav) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->cs_uav, 64, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_cs_get_shader) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_shader_out(c, c->cs, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_cs_get_smp) { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->cs_smp, 16, rsi, rdx, rcx); return ret_void(); }
static SHIM_DEF(ctx_cs_get_cb)  { SHIM_UNUSED_ALL(); auto *c = (Bo3MetalContext *)rdi; get_obj_array(c, c->cs_cb, 14, rsi, rdx, rcx); return ret_void(); }
// GetPrivateData (slot 4): nothing is stored
static SHIM_DEF(ctx_get_private_data) {
    SHIM_UNUSED_ALL();
    if (rdx) *(uint32_t *)rdx = 0;
    return ret_u64(BO3_DXGI_ERROR_NOT_FOUND);
}
static SHIM_DEF(ctx_set_private_data) { SHIM_UNUSED_ALL(); return ret_u64(BO3_S_OK); }
// GetResourceMinLOD (slot 56) -> 0.0f
static SHIM_DEF(ctx_get_resource_min_lod) { SHIM_UNUSED_ALL(); return ret_f32(0.0f); }
// GetType (slot 112) -> D3D11_DEVICE_CONTEXT_IMMEDIATE (0); GetContextFlags (slot 113) -> 0
static SHIM_DEF(ctx_get_type) { SHIM_UNUSED_ALL(); return ret_u64(0); }
// FinishCommandList(RestoreDeferredContextState, ppCommandList) -> invalid on an immediate context
static SHIM_DEF(ctx_finish_command_list) {
    SHIM_UNUSED_ALL();
    if (rdx) *(void **)rdx = nullptr;
    return ret_u64(BO3_DXGI_ERROR_INVALID_CALL);
}

static uint32_t ctx_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_ID3D11DeviceChild) ||
        bo3_guid_eq(riid, &BO3_IID_ID3D11DeviceContext)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}
static void ctx_dtor(Bo3ComBase *self) {
    Bo3MetalContext *c = (Bo3MetalContext *)self;
    Bo3MetalDevice *dev = c->device;
    if (dev) {
        // Detach from the device so GetImmediateContext / resurrection never see a dead context
        os_unfair_lock_lock(&dev->ctx_lock);
        if (dev->immediate_ctx == c) {
            dev->immediate_ctx = nullptr;
            dev->holds_ctx_ref = false;
        }
        os_unfair_lock_unlock(&dev->ctx_lock);
    }
    // NOTE: no flush here — completion handlers hold COM refs, so reaching refcount 0 already
    // implies every committed command buffer has completed (a flush would resurrect `c`).
    c->clear_all_state();
    if (c->cur_frame_timing) {
        Bo3MetalContext::Bo3FrameTiming *ft = c->cur_frame_timing;
        c->cur_frame_timing = nullptr;
        if (ft->remaining.fetch_sub(1, std::memory_order_acq_rel) == 1) delete ft;
    }
    if (c->upload_blit_enc) { [c->upload_blit_enc endEncoding]; c->upload_blit_enc = nil; }
    c->upload_cmd_buf = nil;
    c->release_clear_list();
    c->upload_ring.release_all();
    delete c;
    if (dev) dev->release_internal_ref();
}

Bo3MetalContext *bo3_d3d11_create_context_obj(Bo3MetalDevice *dev) {
    Bo3MetalContext *c = new Bo3MetalContext();
    // Zero ONLY the plain POD shadow-state fields (never ARC id<MTLTexture>, upload_ring, or pso_cache!)
    memset(&c->rtvs, 0, offsetof(Bo3MetalContext, upload_ring) - offsetof(Bo3MetalContext, rtvs));
    c->active_rtv_count = 0;
    c->active_ds_lvl = 0; c->active_ds_sl = 0; c->active_ds_arr_sz = 0; c->active_ds_flags = 0;
    c->active_uav_only = false;
    c->pass_w = 0; c->pass_h = 0;
    for (int i = 0; i < 8; i++) {
        c->active_rt_lvl[i] = 0; c->active_rt_sl[i] = 0; c->active_rt_arr_sz[i] = 0;
        c->active_rt_fmt[i] = MTLPixelFormatInvalid;
        c->active_rt_res[i] = nullptr;
        c->active_rt_store[i] = MTLStoreActionStore;
        c->active_rt_bytes[i] = 0;
    }
    c->active_ds_res = nullptr;
    c->active_ds_store = MTLStoreActionStore;
    c->active_st_store = MTLStoreActionStore;
    c->active_ds_bytes = c->active_st_bytes = 0;
    c->active_layers = 1;
    c->om_dirty = true;
    c->com.init_com(g_vt_context, "ID3D11DeviceContext", ctx_qi, ctx_dtor);
    c->device = dev;
    dev->add_internal_ref();
    c->lock = OS_UNFAIR_LOCK_INIT;
    c->enc_mode = ENC_NONE;
    c->blend_factor[0] = c->blend_factor[1] = c->blend_factor[2] = c->blend_factor[3] = 1.0f;
    c->sample_mask = 0xffffffffu;
    c->topology = BO3_D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
    c->submitted_fence.store(0);
    c->completed_fence.store(0);
    c->upload_ring.init(dev->mtl_dev);
    // Apple-family GPUs reject render-encoder barriers whose afterStages include Fragment/Tile
    c->frag_barrier_ok = ![dev->mtl_dev supportsFamily:MTLGPUFamilyApple1];
    c->uav_counter_table = [dev->mtl_dev newBufferWithLength:32 options:MTLResourceStorageModePrivate];
    c->reset_enc_state_cache();
    bool init_perf = bo3_perf_enabled() || bo3_settings_hud_mode() == 2;
    c->perf_on = init_perf;
    c->perf_on_scope.store(init_perf, std::memory_order_release);
    return c;
}

void bo3_context_init_vtables() {
    bo3_com_init_vtable(g_vt_context, 118, "ID3D11DeviceContext");
    bo3_com_set_slot(g_vt_context, 3,   ctx_get_device);
    bo3_com_set_slot(g_vt_context, 7,   ctx_vs_set_cb);
    bo3_com_set_slot(g_vt_context, 8,   ctx_ps_set_srv);
    bo3_com_set_slot(g_vt_context, 9,   ctx_ps_set_shader);
    bo3_com_set_slot(g_vt_context, 10,  ctx_ps_set_samplers);
    bo3_com_set_slot(g_vt_context, 11,  ctx_vs_set_shader);
    bo3_com_set_slot(g_vt_context, 12,  ctx_draw_indexed);
    bo3_com_set_slot(g_vt_context, 13,  ctx_draw);
    bo3_com_set_slot(g_vt_context, 14,  ctx_map);
    bo3_com_set_slot(g_vt_context, 15,  ctx_unmap);
    bo3_com_set_slot(g_vt_context, 16,  ctx_ps_set_cb);
    bo3_com_set_slot(g_vt_context, 17,  ctx_ia_set_input_layout);
    bo3_com_set_slot(g_vt_context, 18,  ctx_ia_set_vbs);
    bo3_com_set_slot(g_vt_context, 19,  ctx_ia_set_ib);
    bo3_com_set_slot(g_vt_context, 20,  ctx_draw_indexed_instanced);
    bo3_com_set_slot(g_vt_context, 21,  ctx_draw_instanced);
    bo3_com_set_slot(g_vt_context, 22,  ctx_noop_void); // GSSetConstantBuffers
    bo3_com_set_slot(g_vt_context, 23,  ctx_noop_void); // GSSetShader
    bo3_com_set_slot(g_vt_context, 24,  ctx_ia_set_topology);
    bo3_com_set_slot(g_vt_context, 25,  ctx_vs_set_srv);
    bo3_com_set_slot(g_vt_context, 26,  ctx_vs_set_samplers);
    bo3_com_set_slot(g_vt_context, 27,  ctx_begin_query);
    bo3_com_set_slot(g_vt_context, 28,  ctx_end_query);
    bo3_com_set_slot(g_vt_context, 29,  ctx_get_data);
    bo3_com_set_slot(g_vt_context, 30,  ctx_noop_void); // SetPredication
    bo3_com_set_slot(g_vt_context, 31,  ctx_noop_void); // GSSetShaderResources
    bo3_com_set_slot(g_vt_context, 32,  ctx_noop_void); // GSSetSamplers
    bo3_com_set_slot(g_vt_context, 33,  ctx_om_set_rts);
    bo3_com_set_slot(g_vt_context, 34,  ctx_om_set_rts_and_uavs);
    bo3_com_set_slot(g_vt_context, 35,  ctx_om_set_blend);
    bo3_com_set_slot(g_vt_context, 36,  ctx_om_set_ds);
    bo3_com_set_slot(g_vt_context, 37,  ctx_noop_void); // SOSetTargets
    bo3_com_set_slot(g_vt_context, 39,  ctx_draw_indexed_instanced_indirect);
    bo3_com_set_slot(g_vt_context, 40,  ctx_draw_instanced_indirect);
    bo3_com_set_slot(g_vt_context, 41,  ctx_dispatch);
    bo3_com_set_slot(g_vt_context, 42,  ctx_dispatch_indirect);
    bo3_com_set_slot(g_vt_context, 43,  ctx_rs_set_state);
    bo3_com_set_slot(g_vt_context, 44,  ctx_rs_set_viewports);
    bo3_com_set_slot(g_vt_context, 45,  ctx_rs_set_scissors);
    bo3_com_set_slot(g_vt_context, 46,  ctx_copy_subres_region);
    bo3_com_set_slot(g_vt_context, 47,  ctx_copy_resource);
    bo3_com_set_slot(g_vt_context, 48,  ctx_update_subresource);
    bo3_com_set_slot(g_vt_context, 49,  ctx_copy_structure_count);
    bo3_com_set_slot(g_vt_context, 50,  ctx_clear_rtv);
    bo3_com_set_slot(g_vt_context, 51,  ctx_clear_uav_uint);
    bo3_com_set_slot(g_vt_context, 52,  ctx_clear_uav_float);
    bo3_com_set_slot(g_vt_context, 53,  ctx_clear_dsv);
    bo3_com_set_slot(g_vt_context, 54,  ctx_generate_mips);
    bo3_com_set_slot(g_vt_context, 57,  ctx_resolve_subres);
    bo3_com_set_slot(g_vt_context, 58,  ctx_noop_void); // ExecuteCommandList
    bo3_com_set_slot(g_vt_context, 59,  ctx_noop_void); // HSSetShaderResources
    bo3_com_set_slot(g_vt_context, 60,  ctx_noop_void); // HSSetShader
    bo3_com_set_slot(g_vt_context, 61,  ctx_noop_void); // HSSetSamplers
    bo3_com_set_slot(g_vt_context, 62,  ctx_noop_void); // HSSetConstantBuffers
    bo3_com_set_slot(g_vt_context, 63,  ctx_noop_void); // DSSetShaderResources
    bo3_com_set_slot(g_vt_context, 64,  ctx_noop_void); // DSSetShader
    bo3_com_set_slot(g_vt_context, 65,  ctx_noop_void); // DSSetSamplers
    bo3_com_set_slot(g_vt_context, 66,  ctx_noop_void); // DSSetConstantBuffers
    bo3_com_set_slot(g_vt_context, 67,  ctx_cs_set_srv);
    bo3_com_set_slot(g_vt_context, 68,  ctx_cs_set_uav);
    bo3_com_set_slot(g_vt_context, 69,  ctx_cs_set_shader);
    bo3_com_set_slot(g_vt_context, 70,  ctx_cs_set_samplers);
    bo3_com_set_slot(g_vt_context, 71,  ctx_cs_set_cb);
    bo3_com_set_slot(g_vt_context, 4,   ctx_get_private_data);
    bo3_com_set_slot(g_vt_context, 5,   ctx_set_private_data);
    bo3_com_set_slot(g_vt_context, 6,   ctx_set_private_data);
    bo3_com_set_slot(g_vt_context, 38,  ctx_noop_void); // DrawAuto (no stream-out)
    bo3_com_set_slot(g_vt_context, 55,  ctx_noop_void); // SetResourceMinLOD
    bo3_com_set_slot(g_vt_context, 56,  ctx_get_resource_min_lod);
    bo3_com_set_slot(g_vt_context, 72,  ctx_vs_get_cb);
    bo3_com_set_slot(g_vt_context, 73,  ctx_ps_get_srv);
    bo3_com_set_slot(g_vt_context, 74,  ctx_ps_get_shader);
    bo3_com_set_slot(g_vt_context, 75,  ctx_ps_get_smp);
    bo3_com_set_slot(g_vt_context, 76,  ctx_vs_get_shader);
    bo3_com_set_slot(g_vt_context, 77,  ctx_ps_get_cb);
    bo3_com_set_slot(g_vt_context, 78,  ctx_ia_get_il);
    bo3_com_set_slot(g_vt_context, 79,  ctx_ia_get_vbs);
    bo3_com_set_slot(g_vt_context, 80,  ctx_ia_get_ib);
    bo3_com_set_slot(g_vt_context, 81,  ctx_get_array_null);     // GSGetConstantBuffers
    bo3_com_set_slot(g_vt_context, 82,  ctx_gs_get_shader_null); // GSGetShader
    bo3_com_set_slot(g_vt_context, 83,  ctx_ia_get_topology);
    bo3_com_set_slot(g_vt_context, 84,  ctx_vs_get_srv);
    bo3_com_set_slot(g_vt_context, 85,  ctx_vs_get_smp);
    bo3_com_set_slot(g_vt_context, 86,  ctx_get_predication);
    bo3_com_set_slot(g_vt_context, 87,  ctx_get_array_null);     // GSGetShaderResources
    bo3_com_set_slot(g_vt_context, 88,  ctx_get_array_null);     // GSGetSamplers
    bo3_com_set_slot(g_vt_context, 89,  ctx_om_get_rts);
    bo3_com_set_slot(g_vt_context, 90,  ctx_om_get_rts_and_uavs);
    bo3_com_set_slot(g_vt_context, 91,  ctx_om_get_blend);
    bo3_com_set_slot(g_vt_context, 92,  ctx_om_get_ds);
    bo3_com_set_slot(g_vt_context, 93,  ctx_so_get_targets);
    bo3_com_set_slot(g_vt_context, 94,  ctx_rs_get_state);
    bo3_com_set_slot(g_vt_context, 95,  ctx_rs_get_viewports);
    bo3_com_set_slot(g_vt_context, 96,  ctx_rs_get_scissors);
    bo3_com_set_slot(g_vt_context, 97,  ctx_get_array_null);     // HSGetShaderResources
    bo3_com_set_slot(g_vt_context, 98,  ctx_gs_get_shader_null); // HSGetShader
    bo3_com_set_slot(g_vt_context, 99,  ctx_get_array_null);     // HSGetSamplers
    bo3_com_set_slot(g_vt_context, 100, ctx_get_array_null);     // HSGetConstantBuffers
    bo3_com_set_slot(g_vt_context, 101, ctx_get_array_null);     // DSGetShaderResources
    bo3_com_set_slot(g_vt_context, 102, ctx_gs_get_shader_null); // DSGetShader
    bo3_com_set_slot(g_vt_context, 103, ctx_get_array_null);     // DSGetSamplers
    bo3_com_set_slot(g_vt_context, 104, ctx_get_array_null);     // DSGetConstantBuffers
    bo3_com_set_slot(g_vt_context, 105, ctx_cs_get_srv);
    bo3_com_set_slot(g_vt_context, 106, ctx_cs_get_uav);
    bo3_com_set_slot(g_vt_context, 107, ctx_cs_get_shader);
    bo3_com_set_slot(g_vt_context, 108, ctx_cs_get_smp);
    bo3_com_set_slot(g_vt_context, 109, ctx_cs_get_cb);
    bo3_com_set_slot(g_vt_context, 110, ctx_clear_state);
    bo3_com_set_slot(g_vt_context, 111, ctx_flush);
    bo3_com_set_slot(g_vt_context, 112, ctx_get_type);
    bo3_com_set_slot(g_vt_context, 113, ctx_get_type);           // GetContextFlags -> 0
    bo3_com_set_slot(g_vt_context, 114, ctx_finish_command_list);
}

// Global init + shader name / debug marker hooks
extern void bo3_dxgi_init_vtables();
extern void bo3_d3d11_init_vtables();

static thread_local char g_tls_shader_name[1024] = {0};

// Exact replay of Aspyr's static GUID initializer constructor (0x1000cb900)
// Copies all 31 DXGI/D3D11/MF GUIDs from mapped __TEXT,__const into __DATA,__bss!
static void bo3_init_aspyr_bss_guids(void) {
    static const struct { uint64_t dst, src; } kGuids[] = {
        { 0x1104c9978ULL, 0x1017dcf04ULL },
        { 0x1104c9988ULL, 0x1017dcf34ULL },
        { 0x1104c9998ULL, 0x1017dd004ULL },
        { 0x1104c99a8ULL, 0x1017dcff4ULL },
        { 0x1104c99b8ULL, 0x1017dcd74ULL },
        { 0x1104c99c8ULL, 0x1017dcd84ULL },
        { 0x1104c99d8ULL, 0x1017dcd94ULL },
        { 0x1104c99e8ULL, 0x1017dcda4ULL },
        { 0x1104c99f8ULL, 0x1017dcdb4ULL },
        { 0x1104c9a08ULL, 0x1017dcdc4ULL },
        { 0x1104c9a18ULL, 0x1017dcdd4ULL },
        { 0x1104c9a28ULL, 0x1017dcde4ULL },
        { 0x1104c9a38ULL, 0x1017dcdf4ULL },
        { 0x1104c9a48ULL, 0x1017dce04ULL },
        { 0x1104c9a58ULL, 0x1017dce14ULL },
        { 0x1104c9a68ULL, 0x1017dce24ULL },
        { 0x1104c9a78ULL, 0x1017dce34ULL },
        { 0x1104c9a88ULL, 0x1017dce44ULL },
        { 0x1104c9a98ULL, 0x1017dd014ULL },
        { 0x1104c9aa8ULL, 0x1017dd024ULL },
        { 0x1104c9ab8ULL, 0x1017dd034ULL },
        { 0x1104c9ac8ULL, 0x1017dd044ULL },
        { 0x1104c9ad8ULL, 0x1017dd054ULL },
        { 0x1104c9ae8ULL, 0x1017dd064ULL },
        { 0x1104c9af8ULL, 0x1017dd074ULL },
        { 0x1104c9b08ULL, 0x1017dd084ULL },
        { 0x1104c9b18ULL, 0x1017dd094ULL },
        { 0x1104c9b28ULL, 0x1017dce64ULL },
        { 0x1104c9b38ULL, 0x1017dce74ULL },
        { 0x1104c9b48ULL, 0x1017dd0b4ULL },
        { 0x1104c9b58ULL, 0x1017dce84ULL },
    };
    for (const auto &g : kGuids) {
        memcpy((void *)g.dst, (const void *)g.src, 16);
    }
}

extern "C" void bo3_metal_init_all(void) {
    static std::once_flag once;
    std::call_once(once, []() {
        bo3_init_aspyr_bss_guids();
        bo3_dxgi_init_vtables();
        bo3_d3d11_init_vtables();
        bo3_context_init_vtables();
    });
}

extern "C" void bo3_metal_set_debug_marker(const char *name) {
    (void)name;
}

extern "C" void bo3_metal_set_shader_name(const char *name) {
    if (name) strlcpy(g_tls_shader_name, name, sizeof(g_tls_shader_name));
    else g_tls_shader_name[0] = 0;
}

extern "C" const char *bo3_metal_get_shader_name(void) {
    if (g_tls_shader_name[0]) return g_tls_shader_name;
    // Also check Aspyr's static global shader name buffer at 0x102105cc0
    const char *aspyr_buf = (const char *)0x102105cc0ULL;
    if (aspyr_buf[0]) return aspyr_buf;
    return "";
}

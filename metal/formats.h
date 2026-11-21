#pragma once
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct Bo3FormatInfo {
    MTLPixelFormat pixel_format;
    uint32_t       bytes_per_block;
    uint32_t       block_dim;     // 1 for uncompressed, 4 for BC1..BC7
    bool           is_depth;
    bool           has_stencil;
    bool           is_typeless;
    bool           is_srgb;
} Bo3FormatInfo;

// Map DXGI_FORMAT to Metal pixel format + block metrics.
// `for_dsv`: resolves typeless depth formats (e.g., R32_TYPELESS -> Depth32Float, R24G8_TYPELESS -> Depth32Float_Stencil8).
// `for_srv`: resolves depth formats to sampleable formats (or Depth32Float for depth2d shadow sampling).
Bo3FormatInfo bo3_dxgi_to_metal_format(uint32_t dxgi_fmt, bool for_dsv, bool for_srv);

// Map DXGI_FORMAT to MTLVertexFormat for ID3D11InputLayout.
MTLVertexFormat bo3_dxgi_to_vertex_format(uint32_t dxgi_fmt, uint32_t *out_byte_size);

// Compute row pitch and slice pitch for a subresource mip level.
void bo3_format_calc_pitch(uint32_t dxgi_fmt, uint32_t width, uint32_t height,
                           uint32_t *out_row_pitch, uint32_t *out_slice_pitch,
                           uint32_t *out_rows);

// RGB32 (DXGI 5..8) helpers: 12-byte guest texels <-> 16-byte RGBA32 Metal texels.
// Metal has no 96-bit pixel formats, so every CPU<->GPU texture transfer must convert.
bool bo3_format_is_rgb32(uint32_t dxgi_fmt);
void bo3_rgb32_expand_row(uint8_t *dst16, const uint8_t *src12, uint32_t texels, uint32_t dxgi_fmt);
void bo3_rgb32_narrow_row(uint8_t *dst12, const uint8_t *src16, uint32_t texels);

// =========================================================================
// M5: Apple Silicon lossless framebuffer compression preservation
// =========================================================================
// On Apple GPUs MTLTextureUsagePixelFormatView disables lossless texture compression, inflating
// TBDR load/store bandwidth. Verified on Apple M4 with MTL_DEBUG_LAYER=1:
//   * same-format views (mip/slice/type subsets) NEVER need PixelFormatView
//   * swizzle views (B8G8R8X8 alpha=1) NEVER need PixelFormatView
//   * sRGB <-> linear twins of the same layout (RGBA8, BGRA8, BC1/2/3/7) NEVER need PixelFormatView
//     (covers DXGI flip-model _SRGB RTVs on non-sRGB swap-chain buffers)
//   * X32_Stencil8 / Depth views of depth-stencil and any true bit reinterpretation
//     (R32Float -> R32Uint, RGBA8Unorm -> RGBA8Uint) DO need PixelFormatView.
// So PixelFormatView is only requested when a mismatched-format view can legally be created:
// typeless resources, depth/stencil resources, and UAV textures whose ClearUnorderedAccessViewUint
// must write raw bits through a same-size integer view (UAVs carry ShaderWrite anyway).
bool bo3_texture_needs_pixel_format_view(uint32_t dxgi_fmt, const Bo3FormatInfo *fi,
                                         bool is_dsv, bool is_uav, MTLPixelFormat pf);

// true when a and b differ only in sRGB encoding (identical memory layout & compression).
bool bo3_mtl_is_srgb_twin(MTLPixelFormat a, MTLPixelFormat b);

// true for every Metal depth and/or stencil pixel format (incl. X32_Stencil8 / X24_Stencil8 views).
bool bo3_mtl_is_depth_stencil_format(MTLPixelFormat pf);

// true when a view of `base_fmt`/`usage` may be created with `view_fmt` without Metal validation
// errors: same format; sRGB twin; Depth32Float_Stencil8 -> X32_Stencil8 (Depth24Unorm_Stencil8 ->
// X24_Stencil8) with PixelFormatView; otherwise PixelFormatView + same compressed/uncompressed class
// + same texel/block byte size + same block dimensions. Depth <-> color views are NEVER legal.
bool bo3_mtl_can_view_as(MTLPixelFormat base_fmt, MTLTextureUsage usage, MTLPixelFormat view_fmt);

// Same-size integer reinterpretation for raw-bit UAV clears (MTLPixelFormatInvalid if none).
MTLPixelFormat bo3_mtl_raw_uint_view_format(MTLPixelFormat pf);

// Bytes per texel for uncompressed, non-depth color formats (0 = unknown/compressed/depth).
uint32_t bo3_mtl_color_bytes_per_pixel(MTLPixelFormat pf);

// Bytes per sample of the depth / stencil aspect of a depth(-stencil) attachment format.
uint32_t bo3_mtl_depth_bytes_per_pixel(MTLPixelFormat pf);
uint32_t bo3_mtl_stencil_bytes_per_pixel(MTLPixelFormat pf);

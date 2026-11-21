#include "formats.h"
#include <algorithm>
#include <string.h>

Bo3FormatInfo bo3_dxgi_to_metal_format(uint32_t dxgi_fmt, bool for_dsv, bool for_srv) {
    (void)for_srv;
    Bo3FormatInfo f = { MTLPixelFormatInvalid, 4, 1, false, false, false, false };
    switch (dxgi_fmt) {
        // 128-bit RGBA
        case 1:  // R32G32B32A32_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatRGBA32Float; f.bytes_per_block = 16; break;
        case 2:  // R32G32B32A32_FLOAT
            f.pixel_format = MTLPixelFormatRGBA32Float; f.bytes_per_block = 16; break;
        case 3:  // R32G32B32A32_UINT
            f.pixel_format = MTLPixelFormatRGBA32Uint;  f.bytes_per_block = 16; break;
        case 4:  // R32G32B32A32_SINT
            f.pixel_format = MTLPixelFormatRGBA32Sint;  f.bytes_per_block = 16; break;
        // 96-bit RGB32: 12-byte guest texels (buffer SRV stride / CPU pitch = 12) backed by
        // 16-byte RGBA32 Metal texels -> CPU uploads/readbacks MUST expand/narrow via
        // bo3_rgb32_expand_row / bo3_rgb32_narrow_row (Metal has no 96-bit pixel formats).
        case 5: // R32G32B32_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatRGBA32Float; f.bytes_per_block = 12; break;
        case 6: // R32G32B32_FLOAT
            f.pixel_format = MTLPixelFormatRGBA32Float; f.bytes_per_block = 12; break;
        case 7: // R32G32B32_UINT
            f.pixel_format = MTLPixelFormatRGBA32Uint;  f.bytes_per_block = 12; break;
        case 8: // R32G32B32_SINT
            f.pixel_format = MTLPixelFormatRGBA32Sint;  f.bytes_per_block = 12; break;

        // 64-bit RGBA16 / RG32
        case 9:  // R16G16B16A16_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatRGBA16Float; f.bytes_per_block = 8; break;
        case 10: // R16G16B16A16_FLOAT
            f.pixel_format = MTLPixelFormatRGBA16Float; f.bytes_per_block = 8; break;
        case 11: // R16G16B16A16_UNORM
            f.pixel_format = MTLPixelFormatRGBA16Unorm; f.bytes_per_block = 8; break;
        case 12: // R16G16B16A16_UINT
            f.pixel_format = MTLPixelFormatRGBA16Uint;  f.bytes_per_block = 8; break;
        case 13: // R16G16B16A16_SNORM
            f.pixel_format = MTLPixelFormatRGBA16Snorm; f.bytes_per_block = 8; break;
        case 14: // R16G16B16A16_SINT
            f.pixel_format = MTLPixelFormatRGBA16Sint;  f.bytes_per_block = 8; break;
        case 15: // R32G32_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatRG32Float;   f.bytes_per_block = 8; break;
        case 16: // R32G32_FLOAT
            f.pixel_format = MTLPixelFormatRG32Float;   f.bytes_per_block = 8; break;
        case 17: // R32G32_UINT
            f.pixel_format = MTLPixelFormatRG32Uint;    f.bytes_per_block = 8; break;
        case 18: // R32G32_SINT
            f.pixel_format = MTLPixelFormatRG32Sint;    f.bytes_per_block = 8; break;

        // 64-bit Depth32 + Stencil8
        case 19: // R32G8X24_TYPELESS
            f.is_typeless = true; f.is_depth = true; f.has_stencil = true;
            f.pixel_format = MTLPixelFormatDepth32Float_Stencil8; f.bytes_per_block = 8; break;
        case 20: // D32_FLOAT_S8X24_UINT
            f.is_depth = true; f.has_stencil = true;
            f.pixel_format = MTLPixelFormatDepth32Float_Stencil8; f.bytes_per_block = 8; break;
        case 21: // R32_FLOAT_X8X24_TYPELESS
            f.is_depth = true;
            f.pixel_format = MTLPixelFormatDepth32Float_Stencil8; f.bytes_per_block = 8; break;
        case 22: // X32_TYPELESS_G8X24_UINT
            f.has_stencil = true;
            f.pixel_format = MTLPixelFormatX32_Stencil8; f.bytes_per_block = 8; break;

        // 32-bit packed & RGBA8
        case 23: // R10G10B10A2_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatRGB10A2Unorm; f.bytes_per_block = 4; break;
        case 24: // R10G10B10A2_UNORM
            f.pixel_format = MTLPixelFormatRGB10A2Unorm; f.bytes_per_block = 4; break;
        case 25: // R10G10B10A2_UINT
            f.pixel_format = MTLPixelFormatRGB10A2Uint;  f.bytes_per_block = 4; break;
        case 26: // R11G11B10_FLOAT
            f.pixel_format = MTLPixelFormatRG11B10Float; f.bytes_per_block = 4; break;
        case 27: // R8G8B8A8_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatRGBA8Unorm;   f.bytes_per_block = 4; break;
        case 28: // R8G8B8A8_UNORM
            f.pixel_format = MTLPixelFormatRGBA8Unorm;   f.bytes_per_block = 4; break;
        case 29: // R8G8B8A8_UNORM_SRGB
            f.is_srgb = true;
            f.pixel_format = MTLPixelFormatRGBA8Unorm_sRGB; f.bytes_per_block = 4; break;
        case 30: // R8G8B8A8_UINT
            f.pixel_format = MTLPixelFormatRGBA8Uint;    f.bytes_per_block = 4; break;
        case 31: // R8G8B8A8_SNORM
            f.pixel_format = MTLPixelFormatRGBA8Snorm;   f.bytes_per_block = 4; break;
        case 32: // R8G8B8A8_SINT
            f.pixel_format = MTLPixelFormatRGBA8Sint;    f.bytes_per_block = 4; break;

        // 32-bit RG16 / R32 / D32 / D24S8
        case 33: // R16G16_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatRG16Float;    f.bytes_per_block = 4; break;
        case 34: // R16G16_FLOAT
            f.pixel_format = MTLPixelFormatRG16Float;    f.bytes_per_block = 4; break;
        case 35: // R16G16_UNORM
            f.pixel_format = MTLPixelFormatRG16Unorm;    f.bytes_per_block = 4; break;
        case 36: // R16G16_UINT
            f.pixel_format = MTLPixelFormatRG16Uint;     f.bytes_per_block = 4; break;
        case 37: // R16G16_SNORM
            f.pixel_format = MTLPixelFormatRG16Snorm;    f.bytes_per_block = 4; break;
        case 38: // R16G16_SINT
            f.pixel_format = MTLPixelFormatRG16Sint;     f.bytes_per_block = 4; break;
        case 39: // R32_TYPELESS
            f.is_typeless = true;
            if (for_dsv) { f.is_depth = true; f.pixel_format = MTLPixelFormatDepth32Float; }
            else         { f.pixel_format = MTLPixelFormatR32Float; }
            f.bytes_per_block = 4; break;
        case 40: // D32_FLOAT
            f.is_depth = true;
            f.pixel_format = MTLPixelFormatDepth32Float; f.bytes_per_block = 4; break;
        case 41: // R32_FLOAT
            f.pixel_format = MTLPixelFormatR32Float;     f.bytes_per_block = 4; break;
        case 42: // R32_UINT
            f.pixel_format = MTLPixelFormatR32Uint;      f.bytes_per_block = 4; break;
        case 43: // R32_SINT
            f.pixel_format = MTLPixelFormatR32Sint;      f.bytes_per_block = 4; break;

        // Apple Silicon M4 does NOT support Depth24Unorm_Stencil8 -> promote to Depth32Float_Stencil8
        case 44: // R24G8_TYPELESS
            f.is_typeless = true; f.is_depth = true; f.has_stencil = true;
            f.pixel_format = MTLPixelFormatDepth32Float_Stencil8; f.bytes_per_block = 4; break;
        case 45: // D24_UNORM_S8_UINT
            f.is_depth = true; f.has_stencil = true;
            f.pixel_format = MTLPixelFormatDepth32Float_Stencil8; f.bytes_per_block = 4; break;
        case 46: // R24_UNORM_X8_TYPELESS
            f.is_depth = true;
            f.pixel_format = MTLPixelFormatDepth32Float_Stencil8; f.bytes_per_block = 4; break;
        case 47: // X24_TYPELESS_G8_UINT
            f.has_stencil = true;
            f.pixel_format = MTLPixelFormatX32_Stencil8; f.bytes_per_block = 4; break;

        // 16-bit RG8 / R16 / D16
        case 48: // R8G8_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatRG8Unorm;     f.bytes_per_block = 2; break;
        case 49: // R8G8_UNORM
            f.pixel_format = MTLPixelFormatRG8Unorm;     f.bytes_per_block = 2; break;
        case 50: // R8G8_UINT
            f.pixel_format = MTLPixelFormatRG8Uint;      f.bytes_per_block = 2; break;
        case 51: // R8G8_SNORM
            f.pixel_format = MTLPixelFormatRG8Snorm;     f.bytes_per_block = 2; break;
        case 52: // R8G8_SINT
            f.pixel_format = MTLPixelFormatRG8Sint;      f.bytes_per_block = 2; break;
        case 53: // R16_TYPELESS
            f.is_typeless = true;
            if (for_dsv) { f.is_depth = true; f.pixel_format = MTLPixelFormatDepth16Unorm; }
            else         { f.pixel_format = MTLPixelFormatR16Unorm; }
            f.bytes_per_block = 2; break;
        case 54: // R16_FLOAT
            f.pixel_format = MTLPixelFormatR16Float;     f.bytes_per_block = 2; break;
        case 55: // D16_UNORM
            f.is_depth = true;
            f.pixel_format = MTLPixelFormatDepth16Unorm; f.bytes_per_block = 2; break;
        case 56: // R16_UNORM
            f.pixel_format = MTLPixelFormatR16Unorm;     f.bytes_per_block = 2; break;
        case 57: // R16_UINT
            f.pixel_format = MTLPixelFormatR16Uint;      f.bytes_per_block = 2; break;
        case 58: // R16_SNORM
            f.pixel_format = MTLPixelFormatR16Snorm;     f.bytes_per_block = 2; break;
        case 59: // R16_SINT
            f.pixel_format = MTLPixelFormatR16Sint;      f.bytes_per_block = 2; break;

        // 8-bit R8 / A8
        case 60: // R8_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatR8Unorm;      f.bytes_per_block = 1; break;
        case 61: // R8_UNORM
            f.pixel_format = MTLPixelFormatR8Unorm;      f.bytes_per_block = 1; break;
        case 62: // R8_UINT
            f.pixel_format = MTLPixelFormatR8Uint;       f.bytes_per_block = 1; break;
        case 63: // R8_SNORM
            f.pixel_format = MTLPixelFormatR8Snorm;      f.bytes_per_block = 1; break;
        case 64: // R8_SINT
            f.pixel_format = MTLPixelFormatR8Sint;       f.bytes_per_block = 1; break;
        case 65: // A8_UNORM
            f.pixel_format = MTLPixelFormatA8Unorm;      f.bytes_per_block = 1; break;

        // Shared exponent RGB9E5
        case 67: // R9G9B9E5_SHAREDEXP
            f.pixel_format = MTLPixelFormatRGB9E5Float;  f.bytes_per_block = 4; break;

        // BC1..BC7 (all native on Apple M4 in 2D/2DArray/Cube/CubeArray/3D!)
        case 70: // BC1_TYPELESS
            f.is_typeless = true; f.pixel_format = MTLPixelFormatBC1_RGBA;      f.bytes_per_block = 8;  f.block_dim = 4; break;
        case 71: // BC1_UNORM
            f.pixel_format = MTLPixelFormatBC1_RGBA;      f.bytes_per_block = 8;  f.block_dim = 4; break;
        case 72: // BC1_UNORM_SRGB
            f.is_srgb = true; f.pixel_format = MTLPixelFormatBC1_RGBA_sRGB; f.bytes_per_block = 8;  f.block_dim = 4; break;
        case 73: // BC2_TYPELESS
            f.is_typeless = true; f.pixel_format = MTLPixelFormatBC2_RGBA;      f.bytes_per_block = 16; f.block_dim = 4; break;
        case 74: // BC2_UNORM
            f.pixel_format = MTLPixelFormatBC2_RGBA;      f.bytes_per_block = 16; f.block_dim = 4; break;
        case 75: // BC2_UNORM_SRGB
            f.is_srgb = true; f.pixel_format = MTLPixelFormatBC2_RGBA_sRGB; f.bytes_per_block = 16; f.block_dim = 4; break;
        case 76: // BC3_TYPELESS
            f.is_typeless = true; f.pixel_format = MTLPixelFormatBC3_RGBA;      f.bytes_per_block = 16; f.block_dim = 4; break;
        case 77: // BC3_UNORM
            f.pixel_format = MTLPixelFormatBC3_RGBA;      f.bytes_per_block = 16; f.block_dim = 4; break;
        case 78: // BC3_UNORM_SRGB
            f.is_srgb = true; f.pixel_format = MTLPixelFormatBC3_RGBA_sRGB; f.bytes_per_block = 16; f.block_dim = 4; break;
        case 79: // BC4_TYPELESS
            f.is_typeless = true; f.pixel_format = MTLPixelFormatBC4_RUnorm;    f.bytes_per_block = 8;  f.block_dim = 4; break;
        case 80: // BC4_UNORM
            f.pixel_format = MTLPixelFormatBC4_RUnorm;    f.bytes_per_block = 8;  f.block_dim = 4; break;
        case 81: // BC4_SNORM
            f.pixel_format = MTLPixelFormatBC4_RSnorm;    f.bytes_per_block = 8;  f.block_dim = 4; break;
        case 82: // BC5_TYPELESS
            f.is_typeless = true; f.pixel_format = MTLPixelFormatBC5_RGUnorm;   f.bytes_per_block = 16; f.block_dim = 4; break;
        case 83: // BC5_UNORM
            f.pixel_format = MTLPixelFormatBC5_RGUnorm;   f.bytes_per_block = 16; f.block_dim = 4; break;
        case 84: // BC5_SNORM
            f.pixel_format = MTLPixelFormatBC5_RGSnorm;   f.bytes_per_block = 16; f.block_dim = 4; break;

        // BGRA8 / BGRX8
        case 85: // B5G6R5_UNORM
            f.pixel_format = MTLPixelFormatB5G6R5Unorm;   f.bytes_per_block = 2; break;
        case 86: // B5G5R5A1_UNORM
            f.pixel_format = MTLPixelFormatBGR5A1Unorm;   f.bytes_per_block = 2; break;
        case 87: // B8G8R8A8_UNORM
        case 88: // B8G8R8X8_UNORM
            f.pixel_format = MTLPixelFormatBGRA8Unorm;    f.bytes_per_block = 4; break;
        case 90: // B8G8R8A8_TYPELESS
        case 92: // B8G8R8X8_TYPELESS
            f.is_typeless = true;
            f.pixel_format = MTLPixelFormatBGRA8Unorm;    f.bytes_per_block = 4; break;
        case 91: // B8G8R8A8_UNORM_SRGB
        case 93: // B8G8R8X8_UNORM_SRGB
            f.is_srgb = true;
            f.pixel_format = MTLPixelFormatBGRA8Unorm_sRGB; f.bytes_per_block = 4; break;

        // BC6H & BC7
        case 94: // BC6H_TYPELESS
            f.is_typeless = true; f.pixel_format = MTLPixelFormatBC6H_RGBUfloat; f.bytes_per_block = 16; f.block_dim = 4; break;
        case 95: // BC6H_UF16
            f.pixel_format = MTLPixelFormatBC6H_RGBUfloat; f.bytes_per_block = 16; f.block_dim = 4; break;
        case 96: // BC6H_SF16
            f.pixel_format = MTLPixelFormatBC6H_RGBFloat;  f.bytes_per_block = 16; f.block_dim = 4; break;
        case 97: // BC7_TYPELESS
            f.is_typeless = true; f.pixel_format = MTLPixelFormatBC7_RGBAUnorm; f.bytes_per_block = 16; f.block_dim = 4; break;
        case 98: // BC7_UNORM
            f.pixel_format = MTLPixelFormatBC7_RGBAUnorm;  f.bytes_per_block = 16; f.block_dim = 4; break;
        case 99: // BC7_UNORM_SRGB
            f.is_srgb = true; f.pixel_format = MTLPixelFormatBC7_RGBAUnorm_sRGB; f.bytes_per_block = 16; f.block_dim = 4; break;

        default:
            break;
    }
    return f;
}

MTLVertexFormat bo3_dxgi_to_vertex_format(uint32_t dxgi_fmt, uint32_t *out_byte_size) {
    uint32_t sz = 0;
    MTLVertexFormat vf = MTLVertexFormatInvalid;
    switch (dxgi_fmt) {
        case 2:  vf = MTLVertexFormatFloat4; sz = 16; break;
        case 3:  vf = MTLVertexFormatUInt4;  sz = 16; break;
        case 4:  vf = MTLVertexFormatInt4;   sz = 16; break;
        case 6:  vf = MTLVertexFormatFloat3; sz = 12; break;
        case 7:  vf = MTLVertexFormatUInt3;  sz = 12; break;
        case 8:  vf = MTLVertexFormatInt3;   sz = 12; break;
        case 10: vf = MTLVertexFormatHalf4;  sz = 8;  break;
        case 11: vf = MTLVertexFormatUShort4Normalized; sz = 8; break;
        case 12: vf = MTLVertexFormatUShort4; sz = 8; break;
        case 13: vf = MTLVertexFormatShort4Normalized; sz = 8; break;
        case 14: vf = MTLVertexFormatShort4; sz = 8; break;
        case 16: vf = MTLVertexFormatFloat2; sz = 8; break;
        case 17: vf = MTLVertexFormatUInt2;  sz = 8; break;
        case 18: vf = MTLVertexFormatInt2;   sz = 8; break;
        case 24: vf = MTLVertexFormatUInt1010102Normalized; sz = 4; break;
        case 25: vf = MTLVertexFormatUInt; sz = 4; break; // R10G10B10A2_UINT (4B)
        case 26:
#if defined(__MAC_14_0)
            if (@available(macOS 14.0, *)) vf = MTLVertexFormatFloatRG11B10;
            else
#endif
            vf = MTLVertexFormatUInt;
            sz = 4; break; // R11G11B10_FLOAT (4B)
        case 28: vf = MTLVertexFormatUChar4Normalized; sz = 4; break;
        case 30: vf = MTLVertexFormatUChar4; sz = 4; break;
        case 31: vf = MTLVertexFormatChar4Normalized; sz = 4; break;
        case 32: vf = MTLVertexFormatChar4;  sz = 4; break;
        case 34: vf = MTLVertexFormatHalf2;  sz = 4; break;
        case 35: vf = MTLVertexFormatUShort2Normalized; sz = 4; break;
        case 36: vf = MTLVertexFormatUShort2; sz = 4; break;
        case 37: vf = MTLVertexFormatShort2Normalized; sz = 4; break;
        case 38: vf = MTLVertexFormatShort2; sz = 4; break;
        case 41: vf = MTLVertexFormatFloat;  sz = 4; break;
        case 42: vf = MTLVertexFormatUInt;   sz = 4; break;
        case 43: vf = MTLVertexFormatInt;    sz = 4; break;
        case 49: vf = MTLVertexFormatUChar2Normalized; sz = 2; break;
        case 50: vf = MTLVertexFormatUChar2; sz = 2; break;
        case 51: vf = MTLVertexFormatChar2Normalized; sz = 2; break;
        case 52: vf = MTLVertexFormatChar2;  sz = 2; break;
        case 54: vf = MTLVertexFormatHalf;   sz = 2; break;
        case 56: vf = MTLVertexFormatUShortNormalized; sz = 2; break;
        case 57: vf = MTLVertexFormatUShort; sz = 2; break;
        case 58: vf = MTLVertexFormatShortNormalized; sz = 2; break;
        case 59: vf = MTLVertexFormatShort;  sz = 2; break;
        case 61: vf = MTLVertexFormatUCharNormalized; sz = 1; break;
        case 62: vf = MTLVertexFormatUChar;  sz = 1; break;
        case 63: vf = MTLVertexFormatCharNormalized; sz = 1; break;
        case 64: vf = MTLVertexFormatChar;   sz = 1; break;
        case 87: vf = MTLVertexFormatUChar4Normalized_BGRA; sz = 4; break;
        default: vf = MTLVertexFormatFloat4; sz = 16; break;
    }
    if (out_byte_size) *out_byte_size = sz;
    return vf;
}

void bo3_format_calc_pitch(uint32_t dxgi_fmt, uint32_t width, uint32_t height,
                           uint32_t *out_row_pitch, uint32_t *out_slice_pitch,
                           uint32_t *out_rows) {
    Bo3FormatInfo info = bo3_dxgi_to_metal_format(dxgi_fmt, false, false);
    uint32_t bw = (width  + info.block_dim - 1) / info.block_dim;
    uint32_t bh = (height + info.block_dim - 1) / info.block_dim;
    if (bw == 0) bw = 1;
    if (bh == 0) bh = 1;
    uint32_t row_pitch = bw * info.bytes_per_block;
    uint32_t slice_pitch = row_pitch * bh;
    if (out_row_pitch)   *out_row_pitch = row_pitch;
    if (out_slice_pitch) *out_slice_pitch = slice_pitch;
    if (out_rows)        *out_rows = bh;
}

// =========================================================================
// RGB32 (DXGI 5..8) <-> RGBA32 Metal texel conversion
// =========================================================================

bool bo3_format_is_rgb32(uint32_t dxgi_fmt) {
    return dxgi_fmt >= 5u && dxgi_fmt <= 8u;
}

void bo3_rgb32_expand_row(uint8_t *dst16, const uint8_t *src12, uint32_t texels, uint32_t dxgi_fmt) {
    if (!dst16 || !src12) return;
    uint32_t one = 0x3f800000u; // 1.0f for FLOAT/TYPELESS
    if (dxgi_fmt == 7u || dxgi_fmt == 8u) one = 1u; // integer alpha = 1
    for (uint32_t x = 0; x < texels; x++) {
        memcpy(dst16 + (size_t)x * 16u, src12 + (size_t)x * 12u, 12);
        memcpy(dst16 + (size_t)x * 16u + 12u, &one, 4);
    }
}

void bo3_rgb32_narrow_row(uint8_t *dst12, const uint8_t *src16, uint32_t texels) {
    if (!dst12 || !src16) return;
    for (uint32_t x = 0; x < texels; x++) {
        memcpy(dst12 + (size_t)x * 12u, src16 + (size_t)x * 16u, 12);
    }
}

// =========================================================================
// M5: Apple Silicon lossless framebuffer compression preservation
// =========================================================================

MTLPixelFormat bo3_mtl_raw_uint_view_format(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatR32Float: return MTLPixelFormatR32Uint;
        case MTLPixelFormatRG32Float: return MTLPixelFormatRG32Uint;
        case MTLPixelFormatRGBA32Float: return MTLPixelFormatRGBA32Uint;
        case MTLPixelFormatR16Float: case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: return MTLPixelFormatR16Uint;
        case MTLPixelFormatRG16Float: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm: return MTLPixelFormatRG16Uint;
        case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm: return MTLPixelFormatRGBA16Uint;
        case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm: return MTLPixelFormatR8Uint;
        case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Snorm: return MTLPixelFormatRG8Uint;
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatBGRA8Unorm: return MTLPixelFormatRGBA8Uint;
        case MTLPixelFormatRGB10A2Unorm: return MTLPixelFormatRGB10A2Uint;
        case MTLPixelFormatRG11B10Float: return MTLPixelFormatR32Uint;
        default: return MTLPixelFormatInvalid;
    }
}

bool bo3_texture_needs_pixel_format_view(uint32_t dxgi_fmt, const Bo3FormatInfo *fi,
                                         bool is_dsv, bool is_uav, MTLPixelFormat pf) {
    // A6: depth-only formats can never be legally viewed as another format in Metal (depth <-> color
    // views are illegal, see bo3_mtl_can_view_as; R32_TYPELESS/R16_TYPELESS color reads of a
    // Depth32Float/Depth16Unorm texture use same-format depth views or the staging-buffer bitcast).
    // PixelFormatView on them would ONLY disable Apple Silicon lossless depth compression. This holds
    // for DSV textures and depth-resolved typeless formats alike. Stencil-capable formats
    // (Depth32Float_Stencil8 / X32_Stencil8, fi->has_stencil) keep it for X32_Stencil8 stencil SRVs.
    if (pf == MTLPixelFormatDepth32Float || pf == MTLPixelFormatDepth16Unorm) {
        if (!fi || !fi->has_stencil) return false;
    }
    if (fi && (fi->is_typeless || fi->is_depth || fi->has_stencil)) return true;
    // Concrete BC4/BC5/BC6H UNORM<->SNORM / UF16<->SF16 are legal D3D11 CopyResource partners within
    // one typeless family (not sRGB twins). They are read-only compressed textures that can never be
    // render targets, so PixelFormatView costs zero TBDR compression and keeps the direct view blit.
    switch (dxgi_fmt) {
        case 80: case 81: // BC4_UNORM / BC4_SNORM
        case 83: case 84: // BC5_UNORM / BC5_SNORM
        case 95: case 96: // BC6H_UF16 / BC6H_SF16
            return true;
        default: break;
    }
    if (is_dsv) return true;
    if (pf == MTLPixelFormatDepth32Float || pf == MTLPixelFormatDepth32Float_Stencil8 ||
        pf == MTLPixelFormatDepth16Unorm || pf == MTLPixelFormatX32_Stencil8) return true;
    // ClearUnorderedAccessViewUint raw-bit writes need a same-size integer view (ShaderWrite
    // textures already opt out of the bandwidth-sensitive render-target compression path).
    if (is_uav && bo3_mtl_raw_uint_view_format(pf) != MTLPixelFormatInvalid) return true;
    return false;
}

static MTLPixelFormat srgb_linear_base(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatRGBA8Unorm_sRGB:    return MTLPixelFormatRGBA8Unorm;
        case MTLPixelFormatBGRA8Unorm_sRGB:    return MTLPixelFormatBGRA8Unorm;
        case MTLPixelFormatBC1_RGBA_sRGB:      return MTLPixelFormatBC1_RGBA;
        case MTLPixelFormatBC2_RGBA_sRGB:      return MTLPixelFormatBC2_RGBA;
        case MTLPixelFormatBC3_RGBA_sRGB:      return MTLPixelFormatBC3_RGBA;
        case MTLPixelFormatBC7_RGBAUnorm_sRGB: return MTLPixelFormatBC7_RGBAUnorm;
        default:                               return f;
    }
}

bool bo3_mtl_is_srgb_twin(MTLPixelFormat a, MTLPixelFormat b) {
    if (a == b) return false;
    MTLPixelFormat la = srgb_linear_base(a), lb = srgb_linear_base(b);
    return la == lb && (la != a || lb != b);
}

// Depth24Unorm_Stencil8 / X24_Stencil8 are deprecated in the macOS 27 SDK (and unsupported on Apple
// GPUs) but still recognized here by raw value so views of them can never be misclassified as color.
static constexpr MTLPixelFormat kBo3PfDepth24Unorm_Stencil8 = (MTLPixelFormat)255;
static constexpr MTLPixelFormat kBo3PfX24_Stencil8 = (MTLPixelFormat)262;

bool bo3_mtl_is_depth_stencil_format(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatDepth16Unorm:
        case MTLPixelFormatDepth32Float:
        case kBo3PfDepth24Unorm_Stencil8:
        case MTLPixelFormatDepth32Float_Stencil8:
        case MTLPixelFormatStencil8:
        case MTLPixelFormatX32_Stencil8:
        case kBo3PfX24_Stencil8:
            return true;
        default:
            return false;
    }
}

// Block metrics of a color format: bytes per texel (uncompressed, block 1x1) or per 4x4 BC block.
// Returns false for unknown / non-BC compressed / depth-stencil formats.
static int bc_format_family(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB:           return 1;
        case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB:           return 2;
        case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB:           return 3;
        case MTLPixelFormatBC4_RUnorm: case MTLPixelFormatBC4_RSnorm:            return 4;
        case MTLPixelFormatBC5_RGUnorm: case MTLPixelFormatBC5_RGSnorm:          return 5;
        case MTLPixelFormatBC6H_RGBFloat: case MTLPixelFormatBC6H_RGBUfloat:     return 6;
        case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB: return 7;
        default: return 0;
    }
}

static bool color_block_info(MTLPixelFormat pf, uint32_t *bytes, uint32_t *block_dim, bool *compressed) {
    switch (pf) {
        case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB:
        case MTLPixelFormatBC4_RUnorm: case MTLPixelFormatBC4_RSnorm:
            *bytes = 8; *block_dim = 4; *compressed = true; return true;
        case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB:
        case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB:
        case MTLPixelFormatBC5_RGUnorm: case MTLPixelFormatBC5_RGSnorm:
        case MTLPixelFormatBC6H_RGBFloat: case MTLPixelFormatBC6H_RGBUfloat:
        case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB:
            *bytes = 16; *block_dim = 4; *compressed = true; return true;
        default: break;
    }
    uint32_t b = bo3_mtl_color_bytes_per_pixel(pf);
    if (b == 0) return false;
    *bytes = b; *block_dim = 1; *compressed = false;
    return true;
}

bool bo3_mtl_can_view_as(MTLPixelFormat base_fmt, MTLTextureUsage usage, MTLPixelFormat view_fmt) {
    if (view_fmt == MTLPixelFormatInvalid || view_fmt == base_fmt) return true;
    const bool pfv = (usage & MTLTextureUsagePixelFormatView) != 0;
    // Depth/stencil: Metal only permits the stencil-aspect views of combined depth-stencil formats.
    // Depth <-> color reinterpretation (e.g. Depth32Float -> R32Float) is NEVER a legal view; those
    // copies go through the staging-buffer bitcast path instead.
    if (bo3_mtl_is_depth_stencil_format(base_fmt) || bo3_mtl_is_depth_stencil_format(view_fmt)) {
        if (!pfv) return false;
        return (base_fmt == MTLPixelFormatDepth32Float_Stencil8 && view_fmt == MTLPixelFormatX32_Stencil8) ||
               (base_fmt == kBo3PfDepth24Unorm_Stencil8 && view_fmt == kBo3PfX24_Stencil8);
    }
    if (bo3_mtl_is_srgb_twin(base_fmt, view_fmt)) return true;
    if (!pfv) return false;
    uint32_t bb = 0, bd = 0, vb = 0, vd = 0;
    bool bc = false, vc = false;
    if (!color_block_info(base_fmt, &bb, &bd, &bc) || !color_block_info(view_fmt, &vb, &vd, &vc)) return false;
    if (bc != vc || bb != vb || bd != vd) return false;
    if (bc && bc_format_family(base_fmt) != bc_format_family(view_fmt)) return false;
    return true;
}

uint32_t bo3_mtl_color_bytes_per_pixel(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm:
        case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint:
            return 1;
        case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint:
        case MTLPixelFormatR16Sint: case MTLPixelFormatR16Float:
        case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Snorm: case MTLPixelFormatRG8Uint:
        case MTLPixelFormatRG8Sint: case MTLPixelFormatB5G6R5Unorm: case MTLPixelFormatBGR5A1Unorm:
        case MTLPixelFormatA1BGR5Unorm: case MTLPixelFormatABGR4Unorm:
            return 2;
        case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatR32Float:
        case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm: case MTLPixelFormatRG16Uint:
        case MTLPixelFormatRG16Sint: case MTLPixelFormatRG16Float:
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatRGBA8Snorm:
        case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatBGR10A2Unorm:
        case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float:
            return 4;
        case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float:
        case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm: case MTLPixelFormatRGBA16Uint:
        case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float:
            return 8;
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float:
            return 16;
        default:
            return 0;
    }
}

uint32_t bo3_mtl_depth_bytes_per_pixel(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatDepth16Unorm:          return 2;
        case MTLPixelFormatDepth32Float:          return 4;
        case MTLPixelFormatDepth32Float_Stencil8: return 4;
        default:                                  return 0;
    }
}

uint32_t bo3_mtl_stencil_bytes_per_pixel(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatDepth32Float_Stencil8:
        case MTLPixelFormatStencil8:
        case MTLPixelFormatX32_Stencil8:          return 1;
        default:                                  return 0;
    }
}

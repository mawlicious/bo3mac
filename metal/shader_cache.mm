#import <Metal/Metal.h>
#include "d3d11_metal.h"
#include "dxbc/dxbc_to_msl.h"
#include <ctype.h>
#include <dirent.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <pwd.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <algorithm>
#include <atomic>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// =========================================================================
// Lightweight DXBC ISGN/ISG1 Parser (needed for CreateInputLayout!)
// =========================================================================

bool bo3_dxbc_extract_isgn(const uint8_t *dxbc, size_t len, std::vector<Bo3DxbcInputElem> *out) {
    if (!dxbc || len < 32 || !out) return false;
    if (memcmp(dxbc, "DXBC", 4) != 0) return false;
    uint32_t num_chunks = 0;
    memcpy(&num_chunks, dxbc + 28, 4);
    if (32 + (size_t)num_chunks * 4 > len) return false;

    for (uint32_t c = 0; c < num_chunks; c++) {
        uint32_t off = 0;
        memcpy(&off, dxbc + 32 + c * 4, 4);
        if ((size_t)off + 8 > len) continue;
        const uint8_t *ch = dxbc + off;
        bool is_isgn = (memcmp(ch, "ISGN", 4) == 0);
        bool is_isg1 = (memcmp(ch, "ISG1", 4) == 0);
        if (!is_isgn && !is_isg1) continue;

        uint32_t ch_len = 0;
        memcpy(&ch_len, ch + 4, 4);
        if ((size_t)off + 8 + ch_len > len || ch_len < 8) return false;
        const uint8_t *body = ch + 8;
        uint32_t count = 0;
        memcpy(&count, body, 4);
        uint32_t elem_stride = is_isg1 ? 32 : 24;
        if (8 + (size_t)count * elem_stride > ch_len) return false;

        out->clear();
        for (uint32_t i = 0; i < count; i++) {
            const uint8_t *e = body + 8 + i * elem_stride;
            uint32_t name_off = 0, sem_idx = 0, reg_idx = 0, comp_type = 3;
            if (is_isg1) {
                // ISG1: +0 stream, +4 name_off, +8 sem_idx, +12 sys_val, +16 comp_type, +20 reg_idx
                memcpy(&name_off,  e + 4,  4);
                memcpy(&sem_idx,   e + 8,  4);
                memcpy(&comp_type, e + 16, 4);
                memcpy(&reg_idx,   e + 20, 4);
            } else {
                // ISGN: +0 name_off, +4 sem_idx, +8 sys_val, +12 comp_type, +16 reg_idx
                memcpy(&name_off,  e + 0,  4);
                memcpy(&sem_idx,   e + 4,  4);
                memcpy(&comp_type, e + 12, 4);
                memcpy(&reg_idx,   e + 16, 4);
            }
            Bo3DxbcInputElem item = {};
            if (name_off < ch_len) {
                size_t avail = (size_t)ch_len - (size_t)name_off;
                size_t slen = strnlen((const char *)(body + name_off), avail);
                size_t ncopy = std::min(slen, sizeof(item.semantic) - 1);
                memcpy(item.semantic, body + name_off, ncopy);
                item.semantic[ncopy] = '\0';
            }
            item.semantic_index = sem_idx;
            item.register_idx = reg_idx;
            item.component_type = (uint8_t)comp_type;
            out->push_back(item);
        }
        return true;
    }
    return false;
}

// =========================================================================
// Shader Cache (Generic.metallib Reflection + Disk Cache + DXBC->MSL Fallback)
// =========================================================================

static std::mutex g_sc_mtx;
static id<MTLDevice>  g_sc_dev = nil;
static id<MTLLibrary> g_generic_lib = nil;
static id<MTLFunction> g_dummy_fs = nil;
static std::unordered_map<std::string, std::string> g_vs_by_base; // base_key -> full vs_main_* name
static std::unordered_set<std::string> g_generic_names;           // all function names in Generic.metallib (O(1) lookup)
static std::unordered_map<std::string, Bo3BindingMap> g_reflected_cache;
static std::atomic<uint32_t> g_hits{0}, g_misses{0}, g_translated{0}, g_tr_fail{0};

static uint32_t fnv1a_32(const uint8_t *p, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 16777619u; }
    return h;
}

static std::string sanitize_shader_name(const char *raw) {
    if (!raw) return "";
    std::string s(raw);
    for (char &c : s) {
        if (!isalnum((unsigned char)c) && c != '_') c = '_';
    }
    return s;
}

// Extract DCL_THREAD_GROUP (opcode 155), DCL_IMMEDIATE_CONSTANT_BUFFER (opcode 53, subtype 3),
// and resource numeric types (DCL_RESOURCE=88, DCL_UNORDERED_ACCESS_VIEW_TYPED=156) from DXBC SHDR/SHEX.
static bool parse_dxbc_cs_threads(const uint8_t *dxbc, size_t len, uint32_t out[3]) {
    if (!dxbc || len < 32 || memcmp(dxbc, "DXBC", 4) != 0) return false;
    uint32_t num_chunks = 0;
    memcpy(&num_chunks, dxbc + 28, 4);
    if (32 + (size_t)num_chunks * 4 > len) return false;
    for (uint32_t c = 0; c < num_chunks; c++) {
        uint32_t off = 0;
        memcpy(&off, dxbc + 32 + c * 4, 4);
        if ((size_t)off + 8 > len) continue;
        const uint8_t *ch = dxbc + off;
        if (memcmp(ch, "SHDR", 4) != 0 && memcmp(ch, "SHEX", 4) != 0) continue;
        uint32_t ch_len = 0;
        memcpy(&ch_len, ch + 4, 4);
        if ((size_t)off + 8 + ch_len > len || ch_len < 8) return false;
        const uint32_t *words = (const uint32_t *)(ch + 8);
        size_t nwords = ch_len / 4;
        size_t pc = 2; // skip version + length tokens
        while (pc < nwords) {
            uint32_t tok = words[pc];
            uint32_t op = tok & 0x7FFu;
            uint32_t insn_len = (tok >> 24) & 0x7Fu;
            if (op == 53u /* CUSTOMDATA */) {
                if (pc + 1 >= nwords) break;
                uint32_t clen = words[pc + 1];
                if (clen < 2 || pc + clen > nwords) break;
                pc += clen;
                continue;
            }
            if (insn_len == 0 || pc + insn_len > nwords) break;
            if (op == 155u /* DCL_THREAD_GROUP */ && insn_len >= 4) {
                out[0] = std::max(1u, words[pc + 1]);
                out[1] = std::max(1u, words[pc + 2]);
                out[2] = std::max(1u, words[pc + 3]);
                return true;
            }
            pc += insn_len;
        }
    }
    return false;
}

static id<MTLBuffer> extract_dxbc_icb_buffer(id<MTLDevice> mdev, const uint8_t *dxbc, size_t len) {
    if (!mdev || !dxbc || len < 32 || memcmp(dxbc, "DXBC", 4) != 0) return nil;
    uint32_t num_chunks = 0;
    memcpy(&num_chunks, dxbc + 28, 4);
    if (32 + (size_t)num_chunks * 4 > len) return nil;
    for (uint32_t c = 0; c < num_chunks; c++) {
        uint32_t off = 0;
        memcpy(&off, dxbc + 32 + c * 4, 4);
        if ((size_t)off + 8 > len) continue;
        const uint8_t *ch = dxbc + off;
        if (memcmp(ch, "SHDR", 4) != 0 && memcmp(ch, "SHEX", 4) != 0) continue;
        uint32_t ch_len = 0;
        memcpy(&ch_len, ch + 4, 4);
        if ((size_t)off + 8 + ch_len > len || ch_len < 8) return nil;
        const uint32_t *words = (const uint32_t *)(ch + 8);
        size_t nwords = ch_len / 4;
        size_t pc = 2;
        while (pc < nwords) {
            uint32_t tok = words[pc];
            uint32_t op = tok & 0x7FFu;
            uint32_t insn_len = (tok >> 24) & 0x7Fu;
            if (op == 53u /* D3D10_SB_OPCODE_CUSTOMDATA */) {
                if (pc + 1 >= nwords) break;
                uint32_t clen = words[pc + 1];
                uint32_t subtype = (tok >> 11) & 0x1FFFFFu;
                if (clen < 2 || pc + clen > nwords) break;
                if (subtype == 3u /* D3D10_SB_CUSTOMDATA_DCL_IMMEDIATE_CONSTANT_BUFFER */ && clen > 2) {
                    size_t byte_len = (size_t)(clen - 2) * 4;
                    size_t alloc_len = std::max<size_t>(byte_len, 16);
                    id<MTLBuffer> buf = [mdev newBufferWithLength:alloc_len options:MTLResourceStorageModeShared];
                    if (buf) {
                        memset(buf.contents, 0, alloc_len);
                        memcpy(buf.contents, words + pc + 2, byte_len);
                    }
                    return buf;
                }
                pc += clen;
                continue;
            }
            if (insn_len == 0 || pc + insn_len > nwords) break;
            pc += insn_len;
        }
    }
    return nil;
}

static void parse_dxbc_resource_num_types(const uint8_t *dxbc, size_t len, Bo3BindingMap *map) {
    if (!dxbc || !map || len < 32 || memcmp(dxbc, "DXBC", 4) != 0) return;
    uint32_t num_chunks = 0;
    memcpy(&num_chunks, dxbc + 28, 4);
    if (32 + (size_t)num_chunks * 4 > len) return;
    auto ret_type_to_num = [](uint32_t rt) -> uint8_t {
        // D3D10_SB_RESOURCE_RETURN_TYPE: 3=SINT, 4=UINT, else FLOAT/UNORM/SNORM
        if (rt == 4u) return BO3_TEX_NUM_UINT;
        if (rt == 3u) return BO3_TEX_NUM_SINT;
        return BO3_TEX_NUM_FLOAT;
    };
    for (uint32_t c = 0; c < num_chunks; c++) {
        uint32_t off = 0;
        memcpy(&off, dxbc + 32 + c * 4, 4);
        if ((size_t)off + 8 > len) continue;
        const uint8_t *ch = dxbc + off;
        if (memcmp(ch, "SHDR", 4) != 0 && memcmp(ch, "SHEX", 4) != 0) continue;
        uint32_t ch_len = 0;
        memcpy(&ch_len, ch + 4, 4);
        if ((size_t)off + 8 + ch_len > len || ch_len < 8) return;
        const uint32_t *words = (const uint32_t *)(ch + 8);
        size_t nwords = ch_len / 4;
        size_t pc = 2;
        while (pc < nwords) {
            uint32_t tok = words[pc];
            uint32_t op = tok & 0x7FFu;
            uint32_t insn_len = (tok >> 24) & 0x7Fu;
            if (op == 53u /* CUSTOMDATA */) {
                if (pc + 1 >= nwords) break;
                uint32_t clen = words[pc + 1];
                if (clen < 2 || pc + clen > nwords) break;
                pc += clen;
                continue;
            }
            if (insn_len == 0 || pc + insn_len > nwords) break;
            if (op == 88u /* DCL_RESOURCE */ && insn_len >= 4) {
                uint32_t slot = words[pc + 2];
                uint32_t rttok = words[pc + insn_len - 1];
                uint32_t rt = rttok & 0xFu;
                if (slot < 128) map->srv_num_type[slot] = ret_type_to_num(rt);
            } else if (op == 156u /* DCL_UNORDERED_ACCESS_VIEW_TYPED */ && insn_len >= 4) {
                uint32_t slot = words[pc + 2];
                uint32_t rttok = words[pc + insn_len - 1];
                uint32_t rt = rttok & 0xFu;
                if (slot < 64) map->uav_num_type[slot] = ret_type_to_num(rt);
            }
            pc += insn_len;
        }
    }
}

// Parse DXBC OSGN/OSG1 to determine exact per-MRT pixel format class (Float/Uint/Sint)
// so mixed-type MRT Generic.metallib fragment shaders reflect cleanly!
static bool parse_dxbc_osgn_formats(const uint8_t *dxbc, size_t len, MTLPixelFormat out_fmts[8]) {
    for (int i = 0; i < 8; i++) out_fmts[i] = MTLPixelFormatRGBA16Float;
    if (!dxbc || len < 32 || memcmp(dxbc, "DXBC", 4) != 0) return false;
    uint32_t num_chunks = 0;
    memcpy(&num_chunks, dxbc + 28, 4);
    if (32 + (size_t)num_chunks * 4 > len) return false;
    for (uint32_t c = 0; c < num_chunks; c++) {
        uint32_t off = 0;
        memcpy(&off, dxbc + 32 + c * 4, 4);
        if ((size_t)off + 8 > len) continue;
        const uint8_t *ch = dxbc + off;
        bool is_osgn = (memcmp(ch, "OSGN", 4) == 0);
        bool is_osg1 = (memcmp(ch, "OSG1", 4) == 0);
        if (!is_osgn && !is_osg1) continue;
        uint32_t ch_len = 0;
        memcpy(&ch_len, ch + 4, 4);
        if ((size_t)off + 8 + ch_len > len || ch_len < 8) return false;
        const uint8_t *body = ch + 8;
        uint32_t count = 0;
        memcpy(&count, body, 4);
        uint32_t elem_stride = is_osg1 ? 32 : 24;
        if (8 + (size_t)count * elem_stride > ch_len) return false;
        bool found_any = false;
        for (uint32_t i = 0; i < count; i++) {
            const uint8_t *e = body + 8 + i * elem_stride;
            uint32_t name_off = 0, sem_idx = 0, comp_type = 3, reg_idx = 0;
            if (is_osg1) {
                memcpy(&name_off,  e + 4,  4);
                memcpy(&sem_idx,   e + 8,  4);
                memcpy(&comp_type, e + 16, 4);
                memcpy(&reg_idx,   e + 20, 4);
            } else {
                memcpy(&name_off,  e + 0,  4);
                memcpy(&sem_idx,   e + 4,  4);
                memcpy(&comp_type, e + 12, 4);
                memcpy(&reg_idx,   e + 16, 4);
            }
            if (name_off >= ch_len) continue;
            size_t avail = (size_t)ch_len - (size_t)name_off;
            char sem[32] = {0};
            size_t slen = strnlen((const char *)(body + name_off), avail);
            size_t ncopy = std::min(slen, sizeof(sem) - 1);
            memcpy(sem, body + name_off, ncopy);
            if (strcasecmp(sem, "SV_Target") == 0) {
                uint32_t rt = (sem_idx < 8) ? sem_idx : reg_idx;
                if (rt < 8) {
                    if (comp_type == 1u)      out_fmts[rt] = MTLPixelFormatRGBA16Uint;
                    else if (comp_type == 2u) out_fmts[rt] = MTLPixelFormatRGBA16Sint;
                    else                      out_fmts[rt] = MTLPixelFormatRGBA16Float;
                    found_any = true;
                }
            }
        }
        return found_any;
    }
    return false;
}

static std::atomic<uint64_t> g_next_shader_uid{1};

// Parse Aspyr reflection binding name: cbN, tN, uN, sN, sNcube, auN, icb, bufferInfo, uavCounters
static void apply_reflection_bindings(NSArray<id<MTLBinding>> *bindings, Bo3BindingMap *map) {
    for (id<MTLBinding> b in bindings) {
        const char *name = b.name.UTF8String;
        if (!name) continue;
        NSUInteger idx = b.index;
        MTLBindingType type = b.type;

        if (strcmp(name, "icb") == 0 && type == MTLBindingTypeBuffer) {
            map->icb_buf = (uint8_t)idx;
            if (idx > map->max_buf_idx) map->max_buf_idx = (uint8_t)idx;
            continue;
        }
        if (strcmp(name, "bufferInfo") == 0 && type == MTLBindingTypeBuffer) {
            map->buffer_info_buf = (uint8_t)idx;
            if (idx > map->max_buf_idx) map->max_buf_idx = (uint8_t)idx;
            continue;
        }
        if (strcmp(name, "uavCounters") == 0 && type == MTLBindingTypeBuffer) {
            map->uav_counters_buf = (uint8_t)idx;
            if (idx > map->max_buf_idx) map->max_buf_idx = (uint8_t)idx;
            continue;
        }

        // Parse prefix + integer + optional "cube"
        const char *p = name;
        int kind = -1; // 0=cb, 1=t, 2=u, 3=s, 4=au
        if (p[0] == 'c' && p[1] == 'b' && isdigit((unsigned char)p[2]))      { kind = 0; p += 2; }
        else if (p[0] == 'a' && p[1] == 'u' && isdigit((unsigned char)p[2])) { kind = 4; p += 2; }
        else if (p[0] == 't' && isdigit((unsigned char)p[1]))                { kind = 1; p += 1; }
        else if (p[0] == 'u' && isdigit((unsigned char)p[1]))                { kind = 2; p += 1; }
        else if (p[0] == 's' && isdigit((unsigned char)p[1]))                { kind = 3; p += 1; }
        else continue;

        char *endp = nullptr;
        unsigned long slot = strtoul(p, &endp, 10);
        bool is_cube_smp = (kind == 3 && endp && strcmp(endp, "cube") == 0);
        if (!endp || (*endp != '\0' && !is_cube_smp)) continue;

        auto map_tex_expect = [](MTLTextureType tt, bool is_depth) -> uint8_t {
            switch (tt) {
                case MTLTextureType1D:                 return BO3_TEX_1D;
                case MTLTextureType1DArray:            return BO3_TEX_1D_ARRAY;
                case MTLTextureType2D:                 return is_depth ? BO3_TEX_DEPTH_2D : BO3_TEX_2D;
                case MTLTextureType2DArray:            return is_depth ? BO3_TEX_DEPTH_2D_ARRAY : BO3_TEX_2D_ARRAY;
                case MTLTextureType2DMultisample:      return BO3_TEX_2D_MS;
                case MTLTextureType2DMultisampleArray: return BO3_TEX_2D_MS_ARRAY;
                case MTLTextureTypeCube:               return is_depth ? BO3_TEX_DEPTH_CUBE : BO3_TEX_CUBE;
                case MTLTextureTypeCubeArray:          return is_depth ? BO3_TEX_DEPTH_CUBE_ARRAY : BO3_TEX_CUBE_ARRAY;
                case MTLTextureType3D:                 return BO3_TEX_3D;
                default:                               return BO3_TEX_2D;
            }
        };
        auto map_tex_num_type = [](MTLDataType dt) -> uint8_t {
            switch (dt) {
                case MTLDataTypeUInt: case MTLDataTypeUInt2:
                case MTLDataTypeUInt3: case MTLDataTypeUInt4:
                    return BO3_TEX_NUM_UINT;
                case MTLDataTypeInt: case MTLDataTypeInt2:
                case MTLDataTypeInt3: case MTLDataTypeInt4:
                    return BO3_TEX_NUM_SINT;
                default:
                    return BO3_TEX_NUM_FLOAT;
            }
        };

        if (kind == 0 && slot < 14 && type == MTLBindingTypeBuffer) {
            map->cb[slot] = (uint8_t)idx;
            map->cb_mask |= (uint16_t)(1u << slot);
            if (idx > map->max_buf_idx) map->max_buf_idx = (uint8_t)idx;
        } else if (kind == 1 && slot < 128) {
            if (type == MTLBindingTypeBuffer) {
                map->srv[slot] = (uint8_t)(BO3_BIND_IS_BUF | (idx & BO3_BIND_IDX_MASK));
                map->srv_expect[slot] = BO3_TEX_BUFFER;
                if (idx > map->max_buf_idx) map->max_buf_idx = (uint8_t)idx;
            } else if (type == MTLBindingTypeTexture) {
                map->srv[slot] = (uint8_t)(idx & BO3_BIND_IDX_MASK);
                id<MTLTextureBinding> tb = (id<MTLTextureBinding>)b;
                map->srv_expect[slot] = map_tex_expect(tb.textureType, tb.isDepthTexture);
                map->srv_num_type[slot] = map_tex_num_type(tb.textureDataType);
            }
            if (slot < 64) map->srv_mask_lo |= (1ULL << slot);
            else           map->srv_mask_hi |= (1ULL << (slot - 64));
        } else if ((kind == 2 || kind == 4) && slot < 64) {
            if (type == MTLBindingTypeBuffer) {
                map->uav[slot] = (uint8_t)(BO3_BIND_IS_BUF | (idx & BO3_BIND_IDX_MASK));
                map->uav_expect[slot] = BO3_TEX_BUFFER;
                if (idx > map->max_buf_idx) map->max_buf_idx = (uint8_t)idx;
            } else if (type == MTLBindingTypeTexture) {
                map->uav[slot] = (uint8_t)(idx & BO3_BIND_IDX_MASK);
                id<MTLTextureBinding> tb = (id<MTLTextureBinding>)b;
                map->uav_expect[slot] = map_tex_expect(tb.textureType, tb.isDepthTexture);
                map->uav_num_type[slot] = map_tex_num_type(tb.textureDataType);
            }
            map->uav_mask |= (1ULL << slot);
        } else if (kind == 3 && slot < 16 && type == MTLBindingTypeSampler) {
            if (is_cube_smp) {
                map->smp_cube[slot] = (uint8_t)idx;
                map->smp_cube_mask |= (uint16_t)(1u << slot);
            } else {
                map->smp[slot] = (uint8_t)idx;
                map->smp_mask |= (uint16_t)(1u << slot);
            }
        }
    }
}

static MTLVertexFormat data_type_to_vfmt(MTLDataType t) {
    switch (t) {
        case MTLDataTypeUInt4:  return MTLVertexFormatUInt4;
        case MTLDataTypeInt4:   return MTLVertexFormatInt4;
        case MTLDataTypeUInt3:  return MTLVertexFormatUInt3;
        case MTLDataTypeInt3:   return MTLVertexFormatInt3;
        case MTLDataTypeUInt2:  return MTLVertexFormatUInt2;
        case MTLDataTypeInt2:   return MTLVertexFormatInt2;
        case MTLDataTypeUInt:   return MTLVertexFormatUInt;
        case MTLDataTypeInt:    return MTLVertexFormatInt;
        case MTLDataTypeFloat2: return MTLVertexFormatFloat2;
        case MTLDataTypeFloat3: return MTLVertexFormatFloat3;
        case MTLDataTypeFloat:  return MTLVertexFormatFloat;
        default:                return MTLVertexFormatFloat4;
    }
}

void bo3_shader_cache_vs_inputs(id<MTLFunction> fn, uint32_t *mask, MTLVertexFormat fmts[31]) {
    if (mask) *mask = 0;
    if (fmts) for (int i = 0; i < 31; i++) fmts[i] = MTLVertexFormatInvalid;
    if (!fn || fn.functionType != MTLFunctionTypeVertex) return;
    @autoreleasepool {
        for (MTLVertexAttribute *va in fn.vertexAttributes) {
            if (!va.isActive || va.attributeIndex >= 31) continue;
            if (mask) *mask |= (1u << va.attributeIndex);
            if (fmts) fmts[va.attributeIndex] = data_type_to_vfmt(va.attributeType);
        }
    }
}

// Collect the D3D register slots a DXBC SHDR/SHEX program actually declares
// (dcl_constantbuffer / dcl_resource* / dcl_sampler / dcl_uav*) for Generic.metallib validation.
struct Bo3DxbcDeclSlots {
    uint16_t cb = 0;
    uint64_t srv_lo = 0, srv_hi = 0;
    uint64_t uav = 0;
    uint16_t smp = 0;
    bool     parsed = false;
};
static Bo3DxbcDeclSlots parse_dxbc_decl_slots(const uint8_t *dxbc, size_t len) {
    Bo3DxbcDeclSlots d;
    if (!dxbc || len < 32 || memcmp(dxbc, "DXBC", 4) != 0) return d;
    uint32_t num_chunks = 0;
    memcpy(&num_chunks, dxbc + 28, 4);
    if (32 + (size_t)num_chunks * 4 > len) return d;
    for (uint32_t c = 0; c < num_chunks; c++) {
        uint32_t off = 0;
        memcpy(&off, dxbc + 32 + c * 4, 4);
        if ((size_t)off + 8 > len) continue;
        const uint8_t *ch = dxbc + off;
        if (memcmp(ch, "SHDR", 4) != 0 && memcmp(ch, "SHEX", 4) != 0) continue;
        uint32_t ch_len = 0;
        memcpy(&ch_len, ch + 4, 4);
        if ((size_t)off + 8 + ch_len > len || ch_len < 8) return d;
        const uint32_t *words = (const uint32_t *)(ch + 8);
        size_t nwords = ch_len / 4;
        size_t pc = 2;
        while (pc < nwords) {
            uint32_t tok = words[pc];
            uint32_t op = tok & 0x7FFu;
            uint32_t insn_len = (tok >> 24) & 0x7Fu;
            if (op == 53u /* CUSTOMDATA */) {
                if (pc + 1 >= nwords) break;
                uint32_t clen = words[pc + 1];
                if (clen < 2 || pc + clen > nwords) break;
                pc += clen;
                continue;
            }
            if (insn_len == 0 || pc + insn_len > nwords) break;
            if (insn_len >= 3) {
                uint32_t slot = words[pc + 2];
                switch (op) {
                    case 89u: /* DCL_CONSTANT_BUFFER */
                        if (slot < 14) d.cb |= (uint16_t)(1u << slot);
                        break;
                    case 88u:  /* DCL_RESOURCE */
                    case 161u: /* DCL_RESOURCE_RAW */
                    case 162u: /* DCL_RESOURCE_STRUCTURED */
                        if (slot < 64) d.srv_lo |= (1ULL << slot);
                        else if (slot < 128) d.srv_hi |= (1ULL << (slot - 64));
                        break;
                    case 90u: /* DCL_SAMPLER */
                        if (slot < 16) d.smp |= (uint16_t)(1u << slot);
                        break;
                    case 156u: /* DCL_UNORDERED_ACCESS_VIEW_TYPED */
                    case 157u: /* DCL_UNORDERED_ACCESS_VIEW_RAW */
                    case 158u: /* DCL_UNORDERED_ACCESS_VIEW_STRUCTURED */
                        if (slot < 64) d.uav |= (1ULL << slot);
                        break;
                    default: break;
                }
            }
            pc += insn_len;
        }
        d.parsed = true;
        return d;
    }
    return d;
}

// A Generic.metallib function is only accepted when its stage matches and every reflected D3D slot
// is actually declared by the DXBC we were handed (guards against stale/mismatched name hints).
static bool generic_hit_compatible(Bo3ShaderStage stage, id<MTLFunction> fn, const Bo3BindingMap &bm,
                                   const uint8_t *dxbc, size_t len) {
    MTLFunctionType want = (stage == BO3_STAGE_VS) ? MTLFunctionTypeVertex
                         : (stage == BO3_STAGE_PS) ? MTLFunctionTypeFragment : MTLFunctionTypeKernel;
    if (!fn || fn.functionType != want) return false;
    static const bool no_bind_check = (getenv("BO3ARM_GENERIC_NO_BIND_CHECK") != nullptr);
    if (no_bind_check) return true;
    Bo3DxbcDeclSlots d = parse_dxbc_decl_slots(dxbc, len);
    if (!d.parsed) return true; // no DXBC to compare against -> trust the name
    if ((bm.cb_mask & ~d.cb) != 0) return false;
    if ((bm.srv_mask_lo & ~d.srv_lo) != 0 || (bm.srv_mask_hi & ~d.srv_hi) != 0) return false;
    if ((bm.uav_mask & ~d.uav) != 0) return false;
    if (((bm.smp_mask | bm.smp_cube_mask) & ~d.smp) != 0) return false;
    return true;
}

static MTLRenderPipelineDescriptor *make_vs_desc(id<MTLFunction> vs_fn) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs_fn;
    NSArray<MTLVertexAttribute *> *attrs = vs_fn.vertexAttributes;
    if (attrs.count > 0) {
        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        for (MTLVertexAttribute *a in attrs) {
            if (!a.isActive) continue;
            vd.attributes[a.attributeIndex].format = data_type_to_vfmt(a.attributeType);
            vd.attributes[a.attributeIndex].offset = 0;
            vd.attributes[a.attributeIndex].bufferIndex = 30;
        }
        vd.layouts[30].stride = 64;
        d.vertexDescriptor = vd;
    }
    return d;
}

static bool reflect_generic_function(Bo3ShaderStage stage, const std::string &fn_name,
                                     id<MTLFunction> fn, const uint8_t *dxbc, size_t dxbc_len,
                                     Bo3BindingMap *out_map) {
    bo3_binding_map_init(out_map);
    @autoreleasepool {
        NSError *err = nil;
        if (stage == BO3_STAGE_CS) {
            MTLComputePipelineReflection *refl = nil;
            id<MTLComputePipelineState> cps = [g_sc_dev newComputePipelineStateWithFunction:fn
                                                                                    options:MTLPipelineOptionBindingInfo
                                                                                 reflection:&refl
                                                                                      error:&err];
            if (cps && refl) {
                apply_reflection_bindings(refl.bindings, out_map);
                return true;
            }
            return false;
        }
        if (stage == BO3_STAGE_VS) {
            // Capture vertex attributes directly from MTLFunction
            for (MTLVertexAttribute *a in fn.vertexAttributes) {
                if (a.isActive && a.attributeIndex < 32) {
                    out_map->vs_input_mask |= (1u << a.attributeIndex);
                    if (a.attributeType == MTLDataTypeUInt4 || a.attributeType == MTLDataTypeUInt3 ||
                        a.attributeType == MTLDataTypeUInt2 || a.attributeType == MTLDataTypeUInt)
                        out_map->vs_input_types[a.attributeIndex] = 1;
                    else if (a.attributeType == MTLDataTypeInt4 || a.attributeType == MTLDataTypeInt3 ||
                             a.attributeType == MTLDataTypeInt2 || a.attributeType == MTLDataTypeInt)
                        out_map->vs_input_types[a.attributeIndex] = 2;
                }
            }
            MTLRenderPipelineDescriptor *d = make_vs_desc(fn);
            d.fragmentFunction = g_dummy_fs;
            d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
            MTLRenderPipelineReflection *refl = nil;
            id<MTLRenderPipelineState> rps = [g_sc_dev newRenderPipelineStateWithDescriptor:d
                                                                                    options:MTLPipelineOptionBindingInfo
                                                                                 reflection:&refl
                                                                                      error:&err];
            if (rps && refl) {
                apply_reflection_bindings(refl.vertexBindings, out_map);
                return true;
            }
            return false;
        }
        if (stage == BO3_STAGE_PS) {
            // Pair with a matching VS from Generic.metallib by base name (strip "fs_main_" and "_XXXXXXXX__GEN")
            id<MTLFunction> pair_vs = nil;
            if (fn_name.size() > 22) {
                std::string key = fn_name.substr(8, fn_name.size() - 22);
                auto it = g_vs_by_base.find(key);
                if (it != g_vs_by_base.end()) {
                    pair_vs = [g_generic_lib newFunctionWithName:[NSString stringWithUTF8String:it->second.c_str()]];
                }
            }
            if (!pair_vs) {
                // If DXBC ISGN is available, synthesize an exact-type reflection VS for this FS
                std::vector<Bo3DxbcInputElem> fs_in;
                if (dxbc && dxbc_len >= 32 && bo3_dxbc_extract_isgn(dxbc, dxbc_len, &fs_in) && !fs_in.empty()) {
                    std::string vsrc = "#include <metal_stdlib>\nusing namespace metal;\nstruct VOut { float4 pos [[position]];\n";
                    int vi = 0;
                    for (const auto &e : fs_in) {
                        if (!e.semantic[0] || strcasecmp(e.semantic, "SV_Position") == 0 ||
                            strncasecmp(e.semantic, "SV_", 3) == 0) continue;
                        const char *ty = (e.component_type == 1) ? "uint4" :
                                         (e.component_type == 2) ? "int4"  : "float4";
                        const char *flat = (e.component_type == 1 || e.component_type == 2) ? " [[flat]]" : "";
                        char line[128];
                        snprintf(line, sizeof(line), " %s v%d [[user(%s%u)]]%s;\n",
                                 ty, vi++, e.semantic, e.semantic_index, flat);
                        vsrc += line;
                    }
                    vsrc += "};\nvertex VOut dvs() { VOut o = {}; o.pos = float4(0,0,0,1); return o; }\n";
                    id<MTLLibrary> l = [g_sc_dev newLibraryWithSource:[NSString stringWithUTF8String:vsrc.c_str()]
                                                             options:nil error:nil];
                    if (l) pair_vs = [l newFunctionWithName:@"dvs"];
                }
            }
            if (!pair_vs) {
                // Fallback dummy VS with TEXCOORD0..15 and COLOR0..3 so FS reflection succeeds even without DXBC
                static id<MTLFunction> g_synth_vs = nil;
                static std::once_flag synth_once;
                std::call_once(synth_once, []() {
                    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                                     "struct VOut { float4 pos [[position]];"
                                     " float4 t0 [[user(TEXCOORD0)]]; float4 t1 [[user(TEXCOORD1)]];"
                                     " float4 t2 [[user(TEXCOORD2)]]; float4 t3 [[user(TEXCOORD3)]];"
                                     " float4 t4 [[user(TEXCOORD4)]]; float4 t5 [[user(TEXCOORD5)]];"
                                     " float4 t6 [[user(TEXCOORD6)]]; float4 t7 [[user(TEXCOORD7)]];"
                                     " float4 t8 [[user(TEXCOORD8)]]; float4 t9 [[user(TEXCOORD9)]];"
                                     " float4 t10 [[user(TEXCOORD10)]]; float4 t11 [[user(TEXCOORD11)]];"
                                     " float4 c0 [[user(COLOR0)]]; float4 c1 [[user(COLOR1)]];"
                                     " float4 c2 [[user(COLOR2)]]; float4 c3 [[user(COLOR3)]]; };\n"
                                     "vertex VOut dvs() { VOut o = {}; o.pos = float4(0,0,0,1); return o; }\n";
                    id<MTLLibrary> l = [g_sc_dev newLibraryWithSource:src options:nil error:nil];
                    g_synth_vs = [l newFunctionWithName:@"dvs"];
                });
                pair_vs = g_synth_vs;
            }
            MTLRenderPipelineDescriptor *d = make_vs_desc(pair_vs);
            d.fragmentFunction = fn;
            d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

            // First try exact per-MRT formats parsed from DXBC OSGN/OSG1 (fixes mixed Float/Uint/Sint MRT FS!)
            MTLPixelFormat osgn_fmts[8];
            if (dxbc && dxbc_len >= 32 && parse_dxbc_osgn_formats(dxbc, dxbc_len, osgn_fmts)) {
                for (int i = 0; i < 8; i++) d.colorAttachments[i].pixelFormat = osgn_fmts[i];
                MTLRenderPipelineReflection *refl = nil;
                id<MTLRenderPipelineState> rps = [g_sc_dev newRenderPipelineStateWithDescriptor:d
                                                                                        options:MTLPipelineOptionBindingInfo
                                                                                     reflection:&refl
                                                                                          error:&err];
                if (rps && refl) {
                    apply_reflection_bindings(refl.fragmentBindings, out_map);
                    return true;
                }
            }

            const MTLPixelFormat probe_fmts[3] = {
                MTLPixelFormatRGBA16Float, MTLPixelFormatRGBA16Uint, MTLPixelFormatRGBA16Sint
            };
            for (MTLPixelFormat pf : probe_fmts) {
                for (int i = 0; i < 8; i++) d.colorAttachments[i].pixelFormat = pf;
                MTLRenderPipelineReflection *refl = nil;
                id<MTLRenderPipelineState> rps = [g_sc_dev newRenderPipelineStateWithDescriptor:d
                                                                                        options:MTLPipelineOptionBindingInfo
                                                                                     reflection:&refl
                                                                                          error:&err];
                if (rps && refl) {
                    apply_reflection_bindings(refl.fragmentBindings, out_map);
                    return true;
                }
            }
            return false;
        }
    }
    return false;
}


// =========================================================================
// M5: Persistent MTLBinaryArchive PSO cache + Generic.metallib reflection cache
// =========================================================================
// Directory: $BO3ARM_CACHE_DIR or ~/Library/Caches/bo3arm/ (BO3ARM_NO_DISK_CACHE=1 disables).
//   pso_archive_v1.metallib, pso_archive_v1.<N>.metallib  (MTLBinaryArchive segments)
//   pso_archive_v1.meta  (key: GPU name + macOS version/build; mismatch -> all segments dropped)
//   refl_cache_v1.bin    (magic, schema, sizeof(Bo3BindingMap), Generic.metallib size+mtime, FNV-1a)
//
// Segmented archive (verified on Apple M4 / macOS 27.3): an MTLBinaryArchive loaded from a file
// cannot be appended to and re-serialized once its pipelines link real VS->FS varyings, and an
// archive that ever served as a binaryArchives lookup target serializes into a file that can never
// be appended to later ("Failed to generate machO ... expecting 'fragment' stage"). Therefore:
//   * every existing segment is loaded READ-ONLY and used only for PSO lookups;
//   * this session's new PSOs go into a FRESH archive that is never a lookup target, serialized
//     (atomically, tmp + rename) into this session's own new segment file;
//   * >= BO3_MAX_SEGMENTS segments (or an out-of-range index) -> the cache is reset; the session
//     segment takes the lowest unused index in 0..BO3_MAX_SEGMENTS-1 (bounded disk use & load time);
//   * one writer per cache dir (flock on .bo3arm.lock); concurrent launches run read-only;
//   * pipelines using Aspyr Generic.metallib (AIR 2.x, 2019) functions never touch the archive: on
//     M4 / macOS 27 they make serializeToURL: fail or write a corrupt segment (allow_archive=false).
// Hot path rules: draw-time PSO creation only does an archive lookup (read-only segments); adds,
// serialization and reflection-cache writes all run on one serial background queue, scheduled from
// Present (>= 25 new entries, or 5 s after the last new entry) and flushed synchronously at exit.

static constexpr uint32_t BO3_REFL_SCHEMA = 1;
static constexpr char     BO3_REFL_MAGIC[8] = {'B', 'O', '3', 'R', 'F', 'L', 'C', '1'};
static constexpr uint32_t BO3_FLUSH_BATCH = 25;
static constexpr uint64_t BO3_FLUSH_QUIET_NS = 5000000000ULL;
static constexpr uint64_t BO3_FLUSH_MIN_GAP_NS = 2000000000ULL;
static constexpr uint32_t BO3_MAX_SEGMENTS = 32;

struct Bo3DiskCache {
    std::string dir;
    std::string archive_meta_path, session_seg_path, refl_path;
    std::string meta_expected;
    dispatch_queue_t queue = nullptr;
    // Cross-process ownership: flock(LOCK_EX | LOCK_NB) on <dir>/.bo3arm.lock, held (fd open) for the
    // process lifetime. Without it the session is READ-ONLY (loads caches; never writes/unlinks/sweeps).
    int  lock_fd = -1;
    bool writable = false;
    // Read-only loaded segments (lookups only, guarded by lookup_mtx; never mutated/serialized)
    std::mutex lookup_mtx;
    NSArray<id<MTLBinaryArchive>> *read_segs = nil;
    uint32_t segs_loaded = 0;
    // Fresh session archive (adds + serialize on the queue, guarded by arch_mtx; NEVER a lookup target)
    std::mutex arch_mtx;
    id<MTLBinaryArchive> session = nil;
    std::atomic<uint32_t> arch_dirty{0};      // adds not yet serialized
    std::atomic<uint32_t> arch_queued{0};     // adds enqueued, not yet executed
    std::atomic<bool>     arch_broken{false}; // serialize failed BO3_ARCHIVE_MAX_FAILS times: stop adding/flushing
    uint32_t              arch_fail_streak = 0; // queue-owned
    // Reflection cache
    std::mutex refl_pend_mtx;
    std::vector<std::pair<std::string, Bo3BindingMap>> refl_pending; // render thread -> queue (refl_pend_mtx)
    std::atomic<uint32_t> refl_dirty{0};                             // modified only under refl_pend_mtx
    std::unordered_map<std::string, Bo3BindingMap> refl_persisted;   // queue-owned
    bool     refl_needs_write = false;                               // queue-owned
    uint32_t refl_write_fails = 0;                                   // queue-owned
    bool     lib_ok = false;
    uint64_t lib_size = 0;
    int64_t  lib_mtime_s = 0, lib_mtime_ns = 0;
    // Scheduling
    std::atomic<bool>     flush_scheduled{false};
    std::atomic<uint64_t> last_new_ns{0};
    std::atomic<uint64_t> last_flush_ns{0};
};

static constexpr uint32_t BO3_ARCHIVE_MAX_FAILS = 2;
static constexpr uint32_t BO3_REFL_MAX_FAILS = 3;
static constexpr off_t    BO3_MAX_CACHE_FILE = 64ll * 1024 * 1024;

// Published (release) only after every field is initialized; intentionally leaked (safe from
// static-destructor order at exit). Readers acquire.
static std::atomic<Bo3DiskCache *> g_dc_pub{nullptr};
static inline Bo3DiskCache *dc_get() { return g_dc_pub.load(std::memory_order_acquire); }

// Stats (relaxed atomics; read by the M5 perf report and the test harness)
static std::atomic<uint64_t> g_pso_builds{0}, g_pso_archive_hits{0}, g_pso_archive_adds{0};
static std::atomic<uint64_t> g_pso_archive_flushes{0}, g_refl_reflected{0}, g_refl_disk_hits{0};
static std::atomic<uint64_t> g_refl_loaded{0}, g_refl_flushes{0};
static std::atomic<bool>     g_archive_loaded{false};
static std::unordered_set<std::string> g_refl_disk_keys; // names loaded from refl_cache_v1.bin (g_sc_mtx)

static uint64_t dc_now_ns() {
    static mach_timebase_info_data_t tb;
    static std::once_flag once;
    std::call_once(once, [] { mach_timebase_info(&tb); });
    return mach_absolute_time() * tb.numer / tb.denom;
}

static bool mkdir_p(const std::string &path, mode_t mode) {
    if (path.empty()) return false;
    std::string cur;
    size_t pos = 0;
    while (pos <= path.size()) {
        size_t nx = path.find('/', pos);
        if (nx == std::string::npos) nx = path.size();
        cur = path.substr(0, nx);
        if (!cur.empty() && mkdir(cur.c_str(), mode) != 0 && errno != EEXIST) return false;
        pos = nx + 1;
    }
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

static uint64_t fnv1a_64(const uint8_t *p, size_t n, uint64_t h = 14695981039346656037ULL) {
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

// Atomic file replace: write a fresh <path>.tmp.<pid> (O_EXCL | O_NOFOLLOW | O_NONBLOCK: a planted
// FIFO/symlink can never block or redirect the write), fsync, rename() over <path>.
static bool write_file_atomic(const std::string &path, const void *data, size_t len) {
    std::string tmp = path + ".tmp." + std::to_string((long)getpid());
    unlink(tmp.c_str());
    int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0644);
    if (fd < 0) return false;
    const uint8_t *p = (const uint8_t *)data;
    size_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, p + off, len - off);
        if (w < 0) { if (errno == EINTR) continue; close(fd); unlink(tmp.c_str()); return false; }
        off += (size_t)w;
    }
    fsync(fd);
    close(fd);
    if (rename(tmp.c_str(), path.c_str()) != 0) { unlink(tmp.c_str()); return false; }
    return true;
}

// Regular files <= 64 MiB only; O_NONBLOCK so a FIFO at the path can never hang the open.
static bool read_file(const std::string &path, std::vector<uint8_t> *out) {
    int fd = open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > BO3_MAX_CACHE_FILE) {
        close(fd);
        return false;
    }
    out->resize((size_t)st.st_size);
    size_t off = 0;
    while (off < out->size()) {
        ssize_t r = read(fd, out->data() + off, out->size() - off);
        if (r < 0) { if (errno == EINTR) continue; close(fd); return false; }
        if (r == 0) break;
        off += (size_t)r;
    }
    close(fd);
    out->resize(off);
    return true;
}

static bool is_regular_file(const std::string &path, off_t *size_out = nullptr) {
    struct stat st;
    if (lstat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return false;
    if (size_out) *size_out = st.st_size;
    return true;
}

static std::string resolve_cache_dir() {
    const char *no = getenv("BO3ARM_NO_DISK_CACHE");
    if (no && no[0] && strcmp(no, "0") != 0) return std::string();
    const char *env = getenv("BO3MAC_CACHE_DIR");
    if (!env || !env[0]) env = getenv("BO3ARM_CACHE_DIR");
    if (env && env[0]) return std::string(env);
    const char *home = getenv("HOME");
    if (!home || !home[0]) {
        struct passwd *pw = getpwuid(getuid());
        home = pw ? pw->pw_dir : nullptr;
    }
    if (!home || !home[0]) return std::string();
    return std::string(home) + "/Library/Caches/bo3mac";
}

// ---- Reflection cache (refl_cache_v1.bin) ----
struct Bo3ReflHeader {
    char     magic[8];
    uint32_t schema;
    uint32_t map_size;   // sizeof(Bo3BindingMap)
    uint64_t lib_size;
    int64_t  lib_mtime_s;
    int64_t  lib_mtime_ns;
    uint32_t count;
    uint32_t reserved;
};

// Init-time (g_sc_mtx held, dc not yet published).
static void refl_cache_load_locked(Bo3DiskCache *dc, std::unordered_map<std::string, Bo3BindingMap> *into) {
    if (!dc || !dc->lib_ok) return;
    std::vector<uint8_t> buf;
    if (!read_file(dc->refl_path, &buf)) return;
    const char *why = nullptr;
    do {
        if (buf.size() < sizeof(Bo3ReflHeader) + 8) { why = "truncated"; break; }
        uint64_t want_sum = 0;
        memcpy(&want_sum, buf.data() + buf.size() - 8, 8);
        if (fnv1a_64(buf.data(), buf.size() - 8) != want_sum) { why = "checksum"; break; }
        Bo3ReflHeader h;
        memcpy(&h, buf.data(), sizeof(h));
        if (memcmp(h.magic, BO3_REFL_MAGIC, 8) != 0) { why = "magic"; break; }
        if (h.schema != BO3_REFL_SCHEMA || h.map_size != sizeof(Bo3BindingMap)) { why = "schema"; break; }
        if (h.lib_size != dc->lib_size || h.lib_mtime_s != dc->lib_mtime_s ||
            h.lib_mtime_ns != dc->lib_mtime_ns) { why = "Generic.metallib changed"; break; }
        size_t off = sizeof(h), end = buf.size() - 8;
        // Every entry is >= 4 (name length) + 1 (name) + sizeof(Bo3BindingMap) bytes: bound the
        // reservation by the bytes actually present so a malformed count can never bad_alloc.
        if ((uint64_t)h.count > (uint64_t)(end - off) / (5u + sizeof(Bo3BindingMap))) { why = "entry count"; break; }
        uint32_t n = 0;
        std::vector<std::pair<std::string, Bo3BindingMap>> tmp;
        tmp.reserve(h.count);
        for (; n < h.count; n++) {
            uint32_t nl = 0;
            if (off + 4 > end) break;
            memcpy(&nl, buf.data() + off, 4); off += 4;
            if (nl == 0 || nl > 4096 || off + nl + sizeof(Bo3BindingMap) > end) break;
            std::string name((const char *)buf.data() + off, nl); off += nl;
            Bo3BindingMap m;
            memcpy(&m, buf.data() + off, sizeof(m)); off += sizeof(m);
            tmp.emplace_back(std::move(name), m);
        }
        if (n != h.count || off != end) { why = "entry table"; break; }
        for (auto &e : tmp) {
            dc->refl_persisted[e.first] = e.second;
            into->emplace(e.first, e.second);
            g_refl_disk_keys.insert(e.first);
        }
        g_refl_loaded.store(tmp.size(), std::memory_order_relaxed);
    } while (0);
    if (why) {
        fprintf(stderr, "[shader-cache] refl_cache_v1.bin rejected (%s) -> rebuilding\n", why);
        dc->refl_needs_write = dc->writable; // replace the bad file on the first flush
    } else {
        fprintf(stderr, "[shader-cache] refl_cache_v1.bin: loaded %llu reflected binding maps\n",
                (unsigned long long)g_refl_loaded.load());
    }
    fflush(stderr);
}

// queue-only
static void refl_cache_flush_on_queue() {
    Bo3DiskCache *const g_dc = dc_get();
    if (!g_dc || !g_dc->lib_ok || !g_dc->writable) return;
    std::vector<std::pair<std::string, Bo3BindingMap>> pend;
    {
        // Drain + clear under the SAME mutex that refl_cache_note_new pushes + bumps under, so an
        // entry can never be counted in refl_dirty without being in refl_pending (or vice versa).
        std::lock_guard<std::mutex> lk(g_dc->refl_pend_mtx);
        pend.swap(g_dc->refl_pending);
        g_dc->refl_dirty.store(0, std::memory_order_relaxed);
    }
    for (auto &e : pend) g_dc->refl_persisted[e.first] = e.second;
    if (!pend.empty()) g_dc->refl_needs_write = true;
    if (!g_dc->refl_needs_write || g_dc->refl_write_fails >= BO3_REFL_MAX_FAILS) return;
    std::vector<uint8_t> out;
    out.reserve(sizeof(Bo3ReflHeader) + g_dc->refl_persisted.size() * (sizeof(Bo3BindingMap) + 64) + 8);
    Bo3ReflHeader h = {};
    memcpy(h.magic, BO3_REFL_MAGIC, 8);
    h.schema = BO3_REFL_SCHEMA;
    h.map_size = sizeof(Bo3BindingMap);
    h.lib_size = g_dc->lib_size;
    h.lib_mtime_s = g_dc->lib_mtime_s;
    h.lib_mtime_ns = g_dc->lib_mtime_ns;
    h.count = (uint32_t)g_dc->refl_persisted.size();
    out.insert(out.end(), (const uint8_t *)&h, (const uint8_t *)&h + sizeof(h));
    for (const auto &e : g_dc->refl_persisted) {
        uint32_t nl = (uint32_t)e.first.size();
        out.insert(out.end(), (const uint8_t *)&nl, (const uint8_t *)&nl + 4);
        out.insert(out.end(), e.first.begin(), e.first.end());
        out.insert(out.end(), (const uint8_t *)&e.second, (const uint8_t *)&e.second + sizeof(Bo3BindingMap));
    }
    uint64_t sum = fnv1a_64(out.data(), out.size());
    out.insert(out.end(), (const uint8_t *)&sum, (const uint8_t *)&sum + 8);
    if (write_file_atomic(g_dc->refl_path, out.data(), out.size())) {
        g_dc->refl_needs_write = false;
        g_dc->refl_write_fails = 0;
        g_refl_flushes.fetch_add(1, std::memory_order_relaxed);
    } else {
        const int e = errno;
        g_dc->refl_write_fails++;
        if (g_dc->refl_write_fails < BO3_REFL_MAX_FAILS) {
            // retry after the quiet period (never per frame)
            std::lock_guard<std::mutex> lk(g_dc->refl_pend_mtx);
            g_dc->refl_dirty.fetch_add(1, std::memory_order_relaxed);
            g_dc->last_new_ns.store(dc_now_ns(), std::memory_order_relaxed);
        }
        fprintf(stderr, "[shader-cache] WARNING: failed to write %s (errno=%d)%s\n", g_dc->refl_path.c_str(), e,
                g_dc->refl_write_fails >= BO3_REFL_MAX_FAILS ? " -> giving up for this session" : " -> will retry");
        fflush(stderr);
    }
}

static void refl_cache_note_new(const std::string &name, const Bo3BindingMap &m) {
    Bo3DiskCache *const g_dc = dc_get();
    if (!g_dc || !g_dc->lib_ok || !g_dc->writable) return;
    {
        std::lock_guard<std::mutex> lk(g_dc->refl_pend_mtx);
        g_dc->refl_pending.emplace_back(name, m);
        g_dc->refl_dirty.fetch_add(1, std::memory_order_relaxed);
    }
    g_dc->last_new_ns.store(dc_now_ns(), std::memory_order_relaxed);
}

// ---- MTLBinaryArchive segments (pso_archive_v1[.<N>].metallib) ----
static std::string segment_path(const std::string &dir, uint32_t n) {
    return dir + (n == 0 ? std::string("/pso_archive_v1.metallib")
                         : "/pso_archive_v1." + std::to_string(n) + ".metallib");
}

// "pso_archive_v1.metallib" -> 0, "pso_archive_v1.<N>.metallib" -> N (strict decimal, no sign/leading 0).
static bool parse_segment_name(const char *nm, uint64_t *out) {
    static const char kBase[] = "pso_archive_v1.metallib";
    static const char kPre[] = "pso_archive_v1.";
    static const char kSuf[] = ".metallib";
    if (strcmp(nm, kBase) == 0) { *out = 0; return true; }
    const size_t pl = sizeof(kPre) - 1, sl = sizeof(kSuf) - 1, len = strlen(nm);
    if (len <= pl + sl || strncmp(nm, kPre, pl) != 0 || strcmp(nm + len - sl, kSuf) != 0) return false;
    const char *d = nm + pl, *de = nm + len - sl;
    if (de - d > 9 || (*d == '0')) return false;
    uint64_t v = 0;
    for (const char *q = d; q < de; q++) {
        if (*q < '0' || *q > '9') return false;
        v = v * 10 + (uint64_t)(*q - '0');
    }
    *out = v;
    return v != 0;
}

// Writable sessions only: remove stale "<exact cache file>.tmp.<pid>" leftovers of killed processes.
static bool is_exact_cache_tmp_name(const char *nm) {
    const char *dot = strstr(nm, ".tmp.");
    if (!dot) return false;
    const char *pid = dot + 5;
    if (!*pid) return false;
    size_t pid_len = 0;
    for (const char *q = pid; *q; q++) {
        if (*q < '0' || *q > '9') return false;
        if (++pid_len > 10) return false;
    }
    std::string base(nm, (size_t)(dot - nm));
    if (base == "refl_cache_v1.bin" || base == "pso_archive_v1.meta") return true;
    uint64_t seg = 0;
    return parse_segment_name(base.c_str(), &seg);
}

static void sweep_stale_tmp_files(Bo3DiskCache *dc) {
    DIR *dp = opendir(dc->dir.c_str());
    if (!dp) return;
    uint32_t swept = 0;
    while (struct dirent *de = readdir(dp)) {
        const char *nm = de->d_name;
        if (!is_exact_cache_tmp_name(nm)) continue;
        std::string path = dc->dir + "/" + nm;
        struct stat st;
        if (lstat(path.c_str(), &st) != 0 || S_ISDIR(st.st_mode)) continue;
        if (unlink(path.c_str()) == 0) swept++;
    }
    closedir(dp);
    if (swept) {
        fprintf(stderr, "[shader-cache] swept %u stale temp file(s)\n", swept);
        fflush(stderr);
    }
}

// Init-time (g_sc_mtx held, dc not yet published).
static void archive_init(Bo3DiskCache *dc, id<MTLDevice> dev) {
    if (!dc) return;
    NSString *osv = [[NSProcessInfo processInfo] operatingSystemVersionString];
    dc->meta_expected = std::string("bo3arm-pso-archive v1\ngpu=") + (dev.name ? dev.name.UTF8String : "?") +
                        "\nos=" + (osv ? osv.UTF8String : "?") + "\n";
    // Enumerate every segment file actually present (no hard-coded index range).
    std::vector<uint64_t> present;
    bool out_of_range = false;
    if (DIR *dp = opendir(dc->dir.c_str())) {
        while (struct dirent *de = readdir(dp)) {
            uint64_t n = 0;
            if (!parse_segment_name(de->d_name, &n)) continue;
            present.push_back(n);
            if (n >= BO3_MAX_SEGMENTS) out_of_range = true;
        }
        closedir(dp);
    }
    std::sort(present.begin(), present.end());
    std::vector<uint8_t> meta;
    const bool key_ok = read_file(dc->archive_meta_path, &meta) &&
                        std::string(meta.begin(), meta.end()) == dc->meta_expected;
    const char *drop_why = nullptr;
    if (!present.empty() && !key_ok) drop_why = "GPU/macOS key mismatch";
    else if (present.size() >= BO3_MAX_SEGMENTS) drop_why = "segment cap reached";
    else if (out_of_range) drop_why = "segment index out of range";
    if (drop_why) {
        if (dc->writable) {
            fprintf(stderr, "[shader-cache] pso_archive_v1: %s -> resetting %zu segment(s)\n", drop_why, present.size());
            for (uint64_t n : present) unlink(segment_path(dc->dir, (uint32_t)n).c_str());
        } else {
            fprintf(stderr, "[shader-cache] pso_archive_v1: %s (read-only session) -> not loading segments\n", drop_why);
        }
        present.clear();
    }
    NSMutableArray<id<MTLBinaryArchive>> *segs = [NSMutableArray array];
    uint64_t bytes = 0;
    std::vector<bool> used(BO3_MAX_SEGMENTS, false);
    for (uint64_t n64 : present) {
        const uint32_t n = (uint32_t)n64;
        std::string path = segment_path(dc->dir, n);
        off_t sz = 0;
        if (!is_regular_file(path, &sz) || sz <= 0 || sz > BO3_MAX_CACHE_FILE) {
            // FIFO / symlink / empty / oversized: never handed to Metal (could block or mis-read)
            if (dc->writable) unlink(path.c_str());
            else used[n] = true;
            continue;
        }
        NSError *err = nil;
        MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
        ad.url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
        id<MTLBinaryArchive> a = [dev newBinaryArchiveWithDescriptor:ad error:&err];
        if (!a) {
            fprintf(stderr, "[shader-cache] pso_archive_v1: segment %u unreadable (%s) -> discarded\n", n,
                    err ? err.localizedDescription.UTF8String : "?");
            if (dc->writable) unlink(path.c_str());
            else used[n] = true;
            continue;
        }
        used[n] = true;
        [segs addObject:a];
        bytes += (uint64_t)sz;
    }
    if (segs.count > 0) {
        dc->read_segs = [segs copy];
        dc->segs_loaded = (uint32_t)segs.count;
        g_archive_loaded.store(true, std::memory_order_relaxed);
        fprintf(stderr, "[shader-cache] pso_archive_v1: loaded %u segment(s), %llu bytes\n",
                dc->segs_loaded, (unsigned long long)bytes);
    }
    if (dc->writable) {
        uint32_t next = BO3_MAX_SEGMENTS;
        for (uint32_t i = 0; i < BO3_MAX_SEGMENTS; i++) if (!used[i]) { next = i; break; }
        if (next < BO3_MAX_SEGMENTS) {
            dc->session_seg_path = segment_path(dc->dir, next);
            NSError *err = nil;
            dc->session = [dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&err];
            if (!dc->session) {
                fprintf(stderr, "[shader-cache] WARNING: MTLBinaryArchive unavailable (%s) -> new PSOs not persisted\n",
                        err ? err.localizedDescription.UTF8String : "?");
            }
        }
    }
    fflush(stderr);
}

// queue-only: rewrite this session's segment (all PSOs added this session) atomically.
static void archive_flush_on_queue() {
    Bo3DiskCache *const g_dc = dc_get();
    if (!g_dc || !g_dc->session || g_dc->arch_broken.load(std::memory_order_relaxed)) return;
    std::lock_guard<std::mutex> lk(g_dc->arch_mtx);
    uint32_t dirty = g_dc->arch_dirty.exchange(0, std::memory_order_acq_rel);
    if (dirty == 0) return;
    std::string tmp = g_dc->session_seg_path + ".tmp." + std::to_string((long)getpid());
    unlink(tmp.c_str());
    NSError *err = nil;
    NSURL *turl = [NSURL fileURLWithPath:[NSString stringWithUTF8String:tmp.c_str()]];
    if ([g_dc->session serializeToURL:turl error:&err] && rename(tmp.c_str(), g_dc->session_seg_path.c_str()) == 0 &&
        write_file_atomic(g_dc->archive_meta_path, g_dc->meta_expected.data(), g_dc->meta_expected.size())) {
        g_dc->arch_fail_streak = 0;
        g_pso_archive_flushes.fetch_add(1, std::memory_order_relaxed);
    } else {
        unlink(tmp.c_str());
        g_dc->arch_fail_streak++;
        if (g_dc->arch_fail_streak >= BO3_ARCHIVE_MAX_FAILS) {
            // A session archive that failed twice will keep failing: stop for good (no per-frame storm).
            g_dc->arch_broken.store(true, std::memory_order_relaxed);
        } else {
            g_dc->arch_dirty.fetch_add(dirty, std::memory_order_relaxed); // one retry after the quiet period
            g_dc->last_new_ns.store(dc_now_ns(), std::memory_order_relaxed);
        }
        fprintf(stderr, "[shader-cache] WARNING: pso_archive_v1 serialize failed (%u/%u): %s%s\n",
                g_dc->arch_fail_streak, BO3_ARCHIVE_MAX_FAILS,
                err ? err.localizedDescription.UTF8String : strerror(errno),
                g_dc->arch_broken.load(std::memory_order_relaxed) ? " -> archive persistence disabled this session" : "");
        fflush(stderr);
    }
}

static void disk_flush_on_queue() {
    archive_flush_on_queue();
    refl_cache_flush_on_queue();
    if (Bo3DiskCache *d = dc_get()) d->last_flush_ns.store(dc_now_ns(), std::memory_order_relaxed);
}

static void enqueue_archive_add(id descriptor, bool is_compute) {
    Bo3DiskCache *const g_dc = dc_get();
    if (!g_dc || !g_dc->session || !descriptor || g_dc->arch_broken.load(std::memory_order_relaxed)) return;
    id dcopy = [descriptor copy]; // the caller's descriptor is never mutated after this point
    g_dc->arch_queued.fetch_add(1, std::memory_order_relaxed);
    g_dc->last_new_ns.store(dc_now_ns(), std::memory_order_relaxed);
    dispatch_async(g_dc->queue, ^{
        @autoreleasepool {
            NSError *err = nil;
            BOOL ok = NO;
            if (!g_dc->arch_broken.load(std::memory_order_relaxed)) {
                std::lock_guard<std::mutex> lk(g_dc->arch_mtx);
                if (is_compute) {
                    ok = [g_dc->session addComputePipelineFunctionsWithDescriptor:(MTLComputePipelineDescriptor *)dcopy
                                                                            error:&err];
                } else {
                    ok = [g_dc->session addRenderPipelineFunctionsWithDescriptor:(MTLRenderPipelineDescriptor *)dcopy
                                                                           error:&err];
                }
                if (ok) {
                    g_dc->arch_dirty.fetch_add(1, std::memory_order_relaxed);
                    g_pso_archive_adds.fetch_add(1, std::memory_order_relaxed);
                } else {
                    static std::atomic<int> warn{0};
                    if (warn.fetch_add(1, std::memory_order_relaxed) < 5) {
                        fprintf(stderr, "[shader-cache] archive add failed: %s\n",
                                err ? err.localizedDescription.UTF8String : "?");
                        fflush(stderr);
                    }
                }
            }
            g_dc->arch_queued.fetch_sub(1, std::memory_order_relaxed);
            g_dc->last_new_ns.store(dc_now_ns(), std::memory_order_relaxed);
        }
    });
}

id<MTLRenderPipelineState> bo3_pso_create_render(id<MTLDevice> dev, MTLRenderPipelineDescriptor *d, NSError **err,
                                                 bool allow_archive) {
    if (!dev || !d) return nil;
    Bo3DiskCache *const g_dc = allow_archive ? dc_get() : nullptr;
    if (g_dc && g_dc->read_segs) {
        std::lock_guard<std::mutex> lk(g_dc->lookup_mtx); // never held by the disk queue
        d.binaryArchives = g_dc->read_segs;
        NSError *miss = nil;
        id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:d
                                                                           options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                                        reflection:nil
                                                                             error:&miss];
        d.binaryArchives = nil;
        if (pso) {
            g_pso_archive_hits.fetch_add(1, std::memory_order_relaxed);
            return pso;
        }
    }
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:d error:err];
    if (pso) {
        g_pso_builds.fetch_add(1, std::memory_order_relaxed);
        if (g_dc) enqueue_archive_add(d, false);
    }
    return pso;
}

id<MTLComputePipelineState> bo3_pso_create_compute(id<MTLDevice> dev, id<MTLFunction> fn, NSError **err,
                                                   bool allow_archive) {
    if (!dev || !fn) return nil;
    Bo3DiskCache *const g_dc = allow_archive ? dc_get() : nullptr;
    MTLComputePipelineDescriptor *cd = [MTLComputePipelineDescriptor new];
    cd.computeFunction = fn;
    if (g_dc && g_dc->read_segs) {
        std::lock_guard<std::mutex> lk(g_dc->lookup_mtx); // never held by the disk queue
        cd.binaryArchives = g_dc->read_segs;
        NSError *miss = nil;
        id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithDescriptor:cd
                                                                             options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                                          reflection:nil
                                                                               error:&miss];
        cd.binaryArchives = nil;
        if (pso) {
            g_pso_archive_hits.fetch_add(1, std::memory_order_relaxed);
            return pso;
        }
    }
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithDescriptor:cd
                                                                         options:MTLPipelineOptionNone
                                                                      reflection:nil
                                                                           error:err];
    if (pso) {
        g_pso_builds.fetch_add(1, std::memory_order_relaxed);
        if (g_dc) enqueue_archive_add(cd, true);
    }
    return pso;
}

void bo3_shader_cache_on_present(void) {
    Bo3DiskCache *const g_dc = dc_get();
    if (!g_dc || !g_dc->queue) return;
    uint32_t pend = g_dc->arch_dirty.load(std::memory_order_relaxed) +
                    g_dc->arch_queued.load(std::memory_order_relaxed) +
                    g_dc->refl_dirty.load(std::memory_order_relaxed);
    if (pend == 0 || g_dc->flush_scheduled.load(std::memory_order_relaxed)) return;
    const uint64_t now = dc_now_ns();
    const uint64_t ln = g_dc->last_new_ns.load(std::memory_order_relaxed);
    const uint64_t lf = g_dc->last_flush_ns.load(std::memory_order_relaxed);
    // Timestamps are written by other threads: guard against unsigned underflow when one is newer.
    const bool quiet = (now >= ln) && (now - ln >= BO3_FLUSH_QUIET_NS);
    const bool batch = pend >= BO3_FLUSH_BATCH && (now >= lf) && (now - lf >= BO3_FLUSH_MIN_GAP_NS);
    if (!quiet && !batch) return;
    if (g_dc->flush_scheduled.exchange(true, std::memory_order_acq_rel)) return;
    dispatch_async(g_dc->queue, ^{
        @autoreleasepool { disk_flush_on_queue(); }
        g_dc->flush_scheduled.store(false, std::memory_order_release);
    });
}

void bo3_shader_cache_flush_sync(void) {
    Bo3DiskCache *const g_dc = dc_get();
    if (!g_dc || !g_dc->queue) return;
    // Serial queue: every previously enqueued archive add runs first.
    dispatch_sync(g_dc->queue, ^{
        @autoreleasepool { disk_flush_on_queue(); }
    });
}

static void bo3_shader_cache_atexit(void) { bo3_shader_cache_flush_sync(); }

void bo3_pso_cache_get_stats(Bo3PsoCacheStats *out) {
    if (!out) return;
    Bo3DiskCache *const g_dc = dc_get();
    out->pso_builds        = g_pso_builds.load(std::memory_order_relaxed);
    out->pso_archive_hits  = g_pso_archive_hits.load(std::memory_order_relaxed);
    out->pso_archive_adds  = g_pso_archive_adds.load(std::memory_order_relaxed);
    out->pso_archive_flushes = g_pso_archive_flushes.load(std::memory_order_relaxed);
    out->refl_reflected    = g_refl_reflected.load(std::memory_order_relaxed);
    out->refl_disk_hits    = g_refl_disk_hits.load(std::memory_order_relaxed);
    out->refl_loaded       = g_refl_loaded.load(std::memory_order_relaxed);
    out->refl_flushes      = g_refl_flushes.load(std::memory_order_relaxed);
    out->archive_loaded    = g_archive_loaded.load(std::memory_order_relaxed);
    out->archive_segments  = g_dc ? g_dc->segs_loaded : 0;
    out->disk_cache_enabled = (g_dc != nullptr);
}

bool bo3_refl_cache_lookup(const char *name, Bo3BindingMap *out) {
    if (!name || !out) return false;
    std::lock_guard<std::mutex> lk(g_sc_mtx);
    auto it = g_reflected_cache.find(name);
    if (it == g_reflected_cache.end()) return false;
    *out = it->second;
    return true;
}

// Called from bo3_shader_cache_init with g_sc_mtx held.
static void disk_cache_init_locked(id<MTLDevice> dev, const char *lib_path) {
    std::string dir = resolve_cache_dir();
    if (dir.empty()) {
        fprintf(stderr, "[shader-cache] disk cache disabled (BO3ARM_NO_DISK_CACHE or no HOME)\n");
        fflush(stderr);
        return;
    }
    if (!mkdir_p(dir, 0755)) {
        fprintf(stderr, "[shader-cache] WARNING: cannot create cache dir %s (errno=%d) -> disk cache off\n",
                dir.c_str(), errno);
        fflush(stderr);
        return;
    }
    Bo3DiskCache *dc = new Bo3DiskCache();
    dc->dir = dir;
    dc->archive_meta_path = dir + "/pso_archive_v1.meta";
    dc->refl_path = dir + "/refl_cache_v1.bin";
    // Single-writer ownership across concurrent launches (fd kept open for the process lifetime).
    const std::string lock_path = dir + "/.bo3arm.lock";
    dc->lock_fd = open(lock_path.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0644);
    if (dc->lock_fd >= 0 && flock(dc->lock_fd, LOCK_EX | LOCK_NB) == 0) {
        dc->writable = true;
    } else {
        fprintf(stderr, "[shader-cache] cache dir %s is owned by another process (%s) -> read-only session\n",
                dir.c_str(), dc->lock_fd >= 0 ? "locked" : strerror(errno));
        if (dc->lock_fd >= 0) { close(dc->lock_fd); dc->lock_fd = -1; }
    }
    if (dc->writable) sweep_stale_tmp_files(dc);
    dc->queue = dispatch_queue_create("bo3arm.shader_cache.disk", DISPATCH_QUEUE_SERIAL);
    dc->last_flush_ns.store(dc_now_ns(), std::memory_order_relaxed);
    struct stat st;
    if (g_generic_lib && lib_path && stat(lib_path, &st) == 0) {
        dc->lib_ok = true;
        dc->lib_size = (uint64_t)st.st_size;
        dc->lib_mtime_s = (int64_t)st.st_mtimespec.tv_sec;
        dc->lib_mtime_ns = (int64_t)st.st_mtimespec.tv_nsec;
        refl_cache_load_locked(dc, &g_reflected_cache);
        if (dc->refl_needs_write) dc->refl_dirty.store(1, std::memory_order_relaxed);
    }
    archive_init(dc, dev);
    // Publish only now: every field (queue, read_segs, session, segs_loaded, ...) is initialized.
    g_dc_pub.store(dc, std::memory_order_release);
    atexit(bo3_shader_cache_atexit);
    fprintf(stderr, "[shader-cache] disk cache: %s (%s; pso archive %s, reflection cache %s)\n", dir.c_str(),
            dc->writable ? "writable" : "read-only", dc->session ? "on" : "off", dc->lib_ok ? "on" : "off");
    fflush(stderr);
}

void bo3_shader_cache_init(id<MTLDevice> dev) {
    std::lock_guard<std::mutex> lk(g_sc_mtx);
    if (g_sc_dev) return;
    g_sc_dev = dev;

    @autoreleasepool {
        NSError *err = nil;
        NSString *dfs_src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                             "fragment float4 dfs() { return float4(0); }\n";
        id<MTLLibrary> dl = [dev newLibraryWithSource:dfs_src options:nil error:&err];
        g_dummy_fs = [dl newFunctionWithName:@"dfs"];

        std::string resolved_lib;
        const char *lib_env = getenv("BO3MAC_METALLIB");
        if (!lib_env || !lib_env[0]) lib_env = getenv("BO3ARM_METALLIB");
        if (lib_env && lib_env[0]) {
            resolved_lib = lib_env;
        } else {
            // Default: BO3 runs with CWD = CoDBlkOps3.app/Contents/Assets -> ../Resources/Generic.metallib
            std::vector<std::string> cands;
            cands.push_back("../Resources/Generic.metallib");
            if (const char *gdir = getenv("BO3_GAME_DIR"); gdir && gdir[0]) {
                cands.push_back(std::string(gdir) + "/CoDBlkOps3.app/Contents/Resources/Generic.metallib");
            }
            if (const char *home = getenv("HOME"); home && home[0]) {
                cands.push_back(std::string(home) +
                    "/Library/Application Support/Steam/steamapps/common/Call of Duty Black Ops III/"
                    "CoDBlkOps3.app/Contents/Resources/Generic.metallib");
            }
            struct stat st;
            for (const auto &c : cands) {
                if (stat(c.c_str(), &st) == 0 && S_ISREG(st.st_mode)) {
                    resolved_lib = c;
                    break;
                }
            }
        }
        const char *lib_path = resolved_lib.empty() ? nullptr : resolved_lib.c_str();
        if (lib_path) {
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:lib_path]];
            g_generic_lib = [dev newLibraryWithURL:url error:&err];
        }
        if (g_generic_lib) {
            NSArray<NSString *> *names = g_generic_lib.functionNames;
            g_generic_names.reserve(names.count);
            for (NSString *ns in names) {
                std::string s(ns.UTF8String);
                g_generic_names.insert(s);
                if (s.rfind("vs_main_", 0) == 0 && s.size() > 22) {
                    std::string key = s.substr(8, s.size() - 22);
                    g_vs_by_base[key] = s;
                }
            }
            fprintf(stderr, "[shader-cache] Loaded Generic.metallib: %lu functions (%zu VS base keys)\n",
                    (unsigned long)names.count, g_vs_by_base.size());
        } else {
            fprintf(stderr, "[shader-cache] Generic.metallib not found (%s); using DXBC->MSL only\n",
                    err ? err.localizedDescription.UTF8String : "?");
        }
        fflush(stderr);
        disk_cache_init_locked(dev, lib_path);
    }
}

static void dump_dxbc_file(const char *subdir, const std::string &name, const uint8_t *dxbc, size_t len) {
    if (!dxbc || len == 0) return;
    std::string base = resolve_cache_dir();
    if (base.empty()) base = "/tmp/bo3mac-dxbc";
    std::string dir = base + "/" + subdir;
    mkdir_p(dir, 0755);
    std::string path = dir + "/" + name + ".dxbc";
    struct stat st;
    if (stat(path.c_str(), &st) == 0) return; // already dumped
    FILE *fp = fopen(path.c_str(), "wb");
    if (fp) {
        fwrite(dxbc, 1, len, fp);
        fclose(fp);
    }
}

static uint32_t shader_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    Bo3MetalShader *sh = (Bo3MetalShader *)self;
    bool match = bo3_guid_eq(riid, &BO3_IID_IUnknown) ||
                 bo3_guid_eq(riid, &BO3_IID_ID3D11DeviceChild) ||
                 (sh->stage == BO3_STAGE_VS && bo3_guid_eq(riid, &BO3_IID_ID3D11VertexShader)) ||
                 (sh->stage == BO3_STAGE_PS && bo3_guid_eq(riid, &BO3_IID_ID3D11PixelShader)) ||
                 (sh->stage == BO3_STAGE_CS && bo3_guid_eq(riid, &BO3_IID_ID3D11ComputeShader)) ||
                 (sh->stage == BO3_STAGE_GS && bo3_guid_eq(riid, &BO3_IID_ID3D11GeometryShader));
    if (match) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}
static void shader_dtor(Bo3ComBase *self) {
    Bo3MetalShader *sh = (Bo3MetalShader *)self;
    Bo3MetalDevice *dev = sh->device;
    delete sh;
    if (dev) dev->release_internal_ref();
}

// Translate + compile the retained DXBC into `out` (never touches the shader's primary state).
static bool compile_shader_from_dxbc_locked(Bo3MetalShader *sh, Bo3ShaderVariant *out, bool force_float4 = false) {
    if (!sh || !out || !sh->device || sh->dxbc_bytes.size() < 32) return false;
    DxbcTranslateResult res;
    try {
        bo3::dxbc::Options dxbc_opts{};
        dxbc_opts.force_float4_varyings = force_float4;
        res = bo3_translate_dxbc_to_msl(sh->dxbc_bytes.data(), sh->dxbc_bytes.size(),
                                        sh->name.c_str(), sh->name.c_str(), dxbc_opts);
    } catch (const std::exception &e) {
        res.ok = false;
        res.error = e.what();
    } catch (...) {
        res.ok = false;
        res.error = "unknown C++ exception in bo3_translate_dxbc_to_msl";
    }
    if (res.ok && !res.msl.empty()) {
        @autoreleasepool {
            NSError *err = nil;
            MTLCompileOptions *opts = [MTLCompileOptions new];
#if defined(__MAC_15_0)
            if (@available(macOS 15.0, *)) {
                opts.mathMode = MTLMathModeFast;
                opts.languageVersion = MTLLanguageVersion3_2;
            } else
#endif
            {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                opts.fastMathEnabled = YES;
#pragma clang diagnostic pop
#if defined(__MAC_14_0)
                if (@available(macOS 14.0, *)) {
                    opts.languageVersion = MTLLanguageVersion3_1;
                } else
#endif
                {
                    opts.languageVersion = MTLLanguageVersion3_0;
                }
            }
            id<MTLLibrary> lib = [sh->device->mtl_dev newLibraryWithSource:[NSString stringWithUTF8String:res.msl.c_str()]
                                                                   options:opts
                                                                     error:&err];
            if (lib) {
                const char *ename = res.entry_name.empty() ? sh->name.c_str() : res.entry_name.c_str();
                id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:ename]];
                if (fn) {
                    parse_dxbc_resource_num_types(sh->dxbc_bytes.data(), sh->dxbc_bytes.size(), &res.bindings);
                    out->mtl_fn = fn;
                    out->bindings = res.bindings;
                    bo3_shader_cache_vs_inputs(fn, &out->vs_input_mask, out->vs_input_fmt);
                    out->valid = true;
                    uint32_t tr = g_translated.fetch_add(1, std::memory_order_relaxed) + 1;
                    static const bool sc_verbose = (getenv("BO3ARM_VERBOSE") != nullptr &&
                                                    strcmp(getenv("BO3ARM_VERBOSE"), "0") != 0);
                    if ((bo3_perf_enabled() || sc_verbose) && (tr <= 15 || (tr % 50) == 0)) {
                        fprintf(stderr, "[shader-cache] TRANSLATED #%u (%s) hits=%u misses=%u\n",
                                tr, sh->name.c_str(), g_hits.load(), g_misses.load());
                        fflush(stderr);
                    }
                    return true;
                }
            }
            uint32_t tf = g_tr_fail.fetch_add(1, std::memory_order_relaxed) + 1;
            if (tf <= 15) {
                fprintf(stderr, "[shader-cache] MSL compile FAILED for %s: %s\n",
                        sh->name.c_str(), err ? err.localizedDescription.UTF8String : "no entry");
                fflush(stderr);
            }
        }
    } else {
        uint32_t tf = g_tr_fail.fetch_add(1, std::memory_order_relaxed) + 1;
        if (tf <= 15) {
            fprintf(stderr, "[shader-cache] DXBC translate FAILED for %s: %s\n",
                    sh->name.c_str(), res.error.c_str());
            fflush(stderr);
        }
    }
    return false;
}

bool bo3_shader_ensure_compiled(Bo3MetalShader *sh) {
    if (!sh) return false;
    if (sh->compiled.load(std::memory_order_acquire)) return sh->valid;
    std::lock_guard<std::mutex> lk(sh->compile_mtx);
    if (sh->compiled.load(std::memory_order_relaxed)) return sh->valid;

    // Producer 1 (Lazy): Generic.metallib hit — reflect/validate only on first actual bind!
    if (!sh->pending_generic_name.empty() && g_generic_lib) {
        const std::string &mtl_name = sh->pending_generic_name;
        const uint8_t *dxbc = sh->dxbc_bytes.empty() ? nullptr : sh->dxbc_bytes.data();
        size_t len = sh->dxbc_bytes.size();
        id<MTLFunction> fn = nil;
        @autoreleasepool {
            fn = [g_generic_lib newFunctionWithName:[NSString stringWithUTF8String:mtl_name.c_str()]];
        }
        if (fn) {
            Bo3BindingMap bm;
            bool cached = false, from_disk = false;
            {
                std::lock_guard<std::mutex> slk(g_sc_mtx);
                auto it = g_reflected_cache.find(mtl_name);
                if (it != g_reflected_cache.end()) {
                    bm = it->second;
                    cached = true;
                    from_disk = g_refl_disk_keys.count(mtl_name) != 0;
                }
            }
            bool ok = cached;
            if (cached) {
                // Only hits whose entry was actually loaded from refl_cache_v1.bin (not same-session reuse)
                if (from_disk) g_refl_disk_hits.fetch_add(1, std::memory_order_relaxed);
            } else {
                ok = reflect_generic_function(sh->stage, mtl_name, fn, dxbc, len, &bm);
                g_refl_reflected.fetch_add(1, std::memory_order_relaxed);
                if (ok) {
                    bool inserted;
                    {
                        std::lock_guard<std::mutex> slk(g_sc_mtx);
                        inserted = g_reflected_cache.emplace(mtl_name, bm).second;
                    }
                    if (inserted) refl_cache_note_new(mtl_name, bm);
                }
            }
            if (ok && !generic_hit_compatible(sh->stage, fn, bm, dxbc, len)) {
                static std::atomic<int> rej{0};
                if (rej.fetch_add(1, std::memory_order_relaxed) < 20) {
                    fprintf(stderr, "[shader-cache] REJECT Generic.metallib hit %s: stage/binding mismatch with DXBC -> translating\n",
                            mtl_name.c_str());
                    fflush(stderr);
                }
                ok = false;
            }
            if (ok) {
                if (sh->stage == BO3_STAGE_CS && dxbc && len >= 32) {
                    parse_dxbc_cs_threads(dxbc, len, bm.cs_threads);
                }
                if (bm.icb_buf != BO3_BIND_UNUSED && sh->device && dxbc && len >= 32) {
                    sh->icb_mtl_buf = extract_dxbc_icb_buffer(sh->device->mtl_dev, dxbc, len);
                }
                sh->mtl_fn = fn;
                sh->bindings = bm;
                bo3_shader_cache_vs_inputs(fn, &sh->vs_input_mask, sh->vs_input_fmt);
                sh->from_generic_metallib = true;
                sh->valid = true;
                sh->compiled.store(true, std::memory_order_release);
                return true;
            }
        }
        // Lazy Generic.metallib lookup/reflection/compatibility failed -> account & dump as miss
        g_misses.fetch_add(1, std::memory_order_relaxed);
        static const bool dump_all_lazy = (getenv("BO3ARM_DUMP_DXBC") != nullptr);
        if (dump_all_lazy && dxbc && len > 0) dump_dxbc_file("dxbc_misses", mtl_name, dxbc, len);
    }

    Bo3ShaderVariant v;
    if (compile_shader_from_dxbc_locked(sh, &v)) {
        sh->mtl_fn = v.mtl_fn;
        sh->cs_pso = nil;
        sh->bindings = v.bindings;
        sh->vs_input_mask = v.vs_input_mask;
        memcpy(sh->vs_input_fmt, v.vs_input_fmt, sizeof(sh->vs_input_fmt));
        sh->from_generic_metallib = false;
        sh->valid = true;
    }
    sh->compiled.store(true, std::memory_order_release);
    return sh->valid;
}

const Bo3ShaderVariant *bo3_shader_get_fallback(Bo3MetalShader *sh, int which) {
    if (!sh || which < 0 || which > 1) return nullptr;
    std::lock_guard<std::mutex> lk(sh->compile_mtx);
    Bo3ShaderVariant &v = sh->fallback_var[which];
    if (v.attempted) return v.valid ? &v : nullptr;
    v.attempted = true;
    // Variant 0 (plain translation) is only meaningful when the primary came from Generic.metallib
    if ((which == 0 && !sh->from_generic_metallib) || sh->dxbc_bytes.size() < 32) return nullptr;
    if (!compile_shader_from_dxbc_locked(sh, &v, which == 1)) {
        v.valid = false;
        return nullptr;
    }
    v.unique_id = g_next_shader_uid.fetch_add(1, std::memory_order_relaxed); // stable, allocated once
    return &v;
}

Bo3MetalShader *bo3_shader_cache_create(Bo3MetalDevice *dev, Bo3ShaderStage stage,
                                        const uint8_t *dxbc, size_t len, const char *name_hint) {
    Bo3MetalShader *sh = new Bo3MetalShader();
    sh->com.init_com(bo3_vtable_shader(), "ID3D11Shader", shader_qi, shader_dtor);
    sh->device = dev;
    if (dev) dev->add_internal_ref();
    sh->unique_id = g_next_shader_uid.fetch_add(1, std::memory_order_relaxed);
    sh->stage = stage;
    sh->hash = (dxbc && len) ? fnv1a_32(dxbc, len) : 0;
    sh->mtl_fn = nil;
    sh->cs_pso = nil;
    sh->icb_mtl_buf = nil;
    sh->from_generic_metallib = false;
    sh->valid = false;
    bo3_binding_map_init(&sh->bindings);
    if (dxbc && len > 0) {
        sh->dxbc_bytes.assign(dxbc, dxbc + len);
    }

    if (stage == BO3_STAGE_GS) {
        // Mac BO3 skips GS (Aspyr has no Metal GS backend)
        sh->name = name_hint ? name_hint : "gs_noop";
        sh->compiled.store(true, std::memory_order_release);
        return sh;
    }

    const char *prefix = (stage == BO3_STAGE_VS) ? "vs_main_" :
                         (stage == BO3_STAGE_PS) ? "fs_main_" : "cs_main_";
    std::string san = sanitize_shader_name(name_hint && name_hint[0] ? name_hint : "");
    if (san.empty()) {
        char buf[64];
        snprintf(buf, sizeof(buf), "anon_%08x", sh->hash);
        san = buf;
    }
    std::string mtl_name = std::string(prefix) + san;
    sh->name = mtl_name;

    static const bool dump_all = (getenv("BO3ARM_DUMP_DXBC") != nullptr);
    static const bool skip_generic = (getenv("BO3ARM_NO_GENERIC_METALLIB") != nullptr);
    if (dump_all) dump_dxbc_file("dxbc_all", mtl_name, dxbc, len);

    // Producer 1 (M3 Bootstrap): Generic.metallib O(1) name match; defer Metal reflection to first draw!
    if (!skip_generic && g_generic_lib && g_generic_names.count(mtl_name)) {
        sh->pending_generic_name = mtl_name;
        uint32_t h = g_hits.fetch_add(1, std::memory_order_relaxed) + 1;
        static const bool sc_hit_verbose = (getenv("BO3ARM_VERBOSE") != nullptr &&
                                            strcmp(getenv("BO3ARM_VERBOSE"), "0") != 0);
        if ((bo3_perf_enabled() || sc_hit_verbose) && (h <= 15 || (h % 500) == 0)) {
            fprintf(stderr, "[shader-cache] HIT #%u (%s) hits=%u misses=%u translated=%u\n",
                    h, mtl_name.c_str(), h, g_misses.load(), g_translated.load());
            fflush(stderr);
        }
        return sh;
    }

    // Generic.metallib miss -> defer DXBC->MSL translation & Metal compilation until first bind/use!
    uint32_t m = g_misses.fetch_add(1, std::memory_order_relaxed) + 1;
    if (dump_all) dump_dxbc_file("dxbc_misses", mtl_name, dxbc, len);
    if (dxbc && len >= 32) {
        sh->compiled.store(false, std::memory_order_release);
    } else {
        sh->compiled.store(true, std::memory_order_release);
        if (m <= 20 || (m % 100) == 0) {
            fprintf(stderr, "[shader-cache] MISS #%u (%s, %zu B DXBC) hits=%u\n",
                    m, mtl_name.c_str(), len, g_hits.load());
            fflush(stderr);
        }
    }
    return sh;
}

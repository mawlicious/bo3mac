#pragma once
#include "../binding_map.h"
#include <stddef.h>
#include <stdint.h>
#include <string>
#include <vector>

struct DxbcSigElem {
    std::string semantic_name;
    uint32_t semantic_index;
    uint32_t register_idx;
    uint8_t mask;
    uint8_t sys_value_type;
    uint8_t component_type; // 1=uint, 2=sint, 3=float
};

struct DxbcTranslateResult {
    bool ok = false;
    uint8_t stage = 0; // 0=PS, 1=VS, 2=GS, 5=CS
    std::string entry_name;
    std::string msl;
    Bo3BindingMap bindings;
    std::vector<DxbcSigElem> inputs;
    std::vector<DxbcSigElem> outputs;
    std::string error;
};

namespace bo3::dxbc {

struct Options {
    bool force_float4_varyings = false;
};

} // namespace bo3::dxbc

// buffer_info_buf binds uint32_t pairs indexed by Metal buffer slot.
// Each pair is {view element count, element stride in bytes}. Use zero pairs for
// unbound views. Each counter-enabled UAV uN has its own device atomic_uint
// pointer uN_counter. Bind that UAV's counter_buf at uav_counter_idx[N], which
// contains the Metal buffer index (or BO3_BIND_UNUSED for a UAV without a counter).
// max_buf_idx includes these bindings and uav_counters_buf is BO3_BIND_UNUSED.
// Immediate constants are embedded in the source and icb_buf is BO3_BIND_UNUSED.
// Texture atomics require MSL 3.1 and R32Uint/R32Sint textures with
// MTLTextureUsageShaderAtomic. Fence-only and global UAV sync require MSL 3.2.
DxbcTranslateResult bo3_translate_dxbc_to_msl(
    const uint8_t *dxbc, size_t len, const char *entry_name, const char *shader_debug_name);

DxbcTranslateResult bo3_translate_dxbc_to_msl(
    const uint8_t *dxbc, size_t len, const char *entry_name, const char *shader_debug_name,
    const bo3::dxbc::Options &options);

bool bo3_parse_dxbc_input_signature(
    const uint8_t *dxbc, size_t len, std::vector<DxbcSigElem> *out_inputs);

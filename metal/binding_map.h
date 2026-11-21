#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// Shared D3D11 -> Metal per-shader resource binding remap.
// Produced identically by:
//   (1) Generic.metallib reflection (M3 bootstrap fast path)
//   (2) Custom DXBC->MSL translator (metal/dxbc/)
//   (3) Disk-cached AOT metallib manifests
//
// Encoding of srv[slot] / uav[slot]:
//   0xFF = unused
//   bit 7 (0x80) = 1 -> Metal buffer index (value & 0x7F)
//   bit 7 (0x80) = 0 -> Metal texture index (value & 0x7F)
#define BO3_BIND_UNUSED   0xFFu
#define BO3_BIND_IS_BUF   0x80u
#define BO3_BIND_IDX_MASK 0x7Fu

typedef enum Bo3TexExpect {
    BO3_TEX_ANY              = 0,
    BO3_TEX_1D               = 1,
    BO3_TEX_2D               = 2,
    BO3_TEX_2D_ARRAY         = 3,
    BO3_TEX_2D_MS            = 4,
    BO3_TEX_CUBE             = 5,
    BO3_TEX_CUBE_ARRAY       = 6,
    BO3_TEX_3D               = 7,
    BO3_TEX_DEPTH_2D         = 8,
    BO3_TEX_DEPTH_2D_ARRAY   = 9,
    BO3_TEX_DEPTH_CUBE       = 10,
    BO3_TEX_DEPTH_CUBE_ARRAY = 11,
    BO3_TEX_BUFFER           = 12,
    BO3_TEX_1D_ARRAY         = 13,
    BO3_TEX_2D_MS_ARRAY      = 14,
} Bo3TexExpect;

typedef enum Bo3TexNumericType {
    BO3_TEX_NUM_FLOAT = 0,
    BO3_TEX_NUM_UINT  = 1,
    BO3_TEX_NUM_SINT  = 2,
} Bo3TexNumericType;

typedef struct Bo3BindingMap {
    uint8_t  cb[14];            // cb0..cb13 -> Metal buffer index (or 0xFF)
    uint8_t  srv[128];          // t0..t127  -> Metal texture index, or (0x80 | bufIdx), or 0xFF
    uint8_t  uav[64];           // u0..u63   -> Metal texture index, or (0x80 | bufIdx), or 0xFF
    uint8_t  smp[16];           // s0..s15   -> Metal sampler index (or 0xFF)
    uint8_t  smp_cube[16];      // s0cube..s15cube -> Metal sampler index (or 0xFF)
    uint8_t  icb_buf;           // immediate constant buffer -> Metal buffer index (or 0xFF)
    uint8_t  buffer_info_buf;   // bufferInfo -> Metal buffer index (or 0xFF)
    uint8_t  uav_counters_buf;  // uavCounters -> Metal buffer index (or 0xFF)
    uint8_t  max_buf_idx;       // highest Metal buffer index used (must stay < lowest VB slot)
    uint16_t cb_mask;           // bitmask of used cb0..cb13
    uint64_t srv_mask_lo;       // bitmask of used t0..t63
    uint64_t srv_mask_hi;       // bitmask of used t64..t127
    uint64_t uav_mask;          // bitmask of used u0..u63
    uint16_t smp_mask;          // bitmask of used s0..s15
    uint16_t smp_cube_mask;     // bitmask of used s0cube..s15cube
    uint8_t  srv_expect[128];   // Bo3TexExpect per SRV slot
    uint8_t  uav_expect[64];    // Bo3TexExpect per UAV slot
    uint8_t  srv_num_type[128]; // Bo3TexNumericType per SRV slot
    uint8_t  uav_num_type[64];  // Bo3TexNumericType per UAV slot
    uint8_t  uav_counter_idx[64]; // index into uavCounters buffer if append/consume, else 0xFF
    uint32_t cs_threads[3];     // compute threadgroup size (x, y, z)
    uint32_t vs_input_mask;     // active vertex attribute bitmask (0..31)
    uint8_t  vs_input_types[32]; // 0=float4, 1=uint4, 2=int4
} Bo3BindingMap;

static inline void bo3_binding_map_init(Bo3BindingMap *m) {
    memset(m, 0, sizeof(*m)); // zero padding: maps are persisted byte-for-byte to refl_cache_v1.bin
    for (int i = 0; i < 14; i++) m->cb[i] = BO3_BIND_UNUSED;
    for (int i = 0; i < 128; i++) {
        m->srv[i] = BO3_BIND_UNUSED;
        m->srv_expect[i] = BO3_TEX_ANY;
        m->srv_num_type[i] = BO3_TEX_NUM_FLOAT;
    }
    for (int i = 0; i < 64; i++) {
        m->uav[i] = BO3_BIND_UNUSED;
        m->uav_expect[i] = BO3_TEX_ANY;
        m->uav_num_type[i] = BO3_TEX_NUM_FLOAT;
        m->uav_counter_idx[i] = BO3_BIND_UNUSED;
    }
    for (int i = 0; i < 16; i++) { m->smp[i] = BO3_BIND_UNUSED; m->smp_cube[i] = BO3_BIND_UNUSED; }
    m->icb_buf = BO3_BIND_UNUSED;
    m->buffer_info_buf = BO3_BIND_UNUSED;
    m->uav_counters_buf = BO3_BIND_UNUSED;
    m->max_buf_idx = 0;
    m->cb_mask = 0;
    m->srv_mask_lo = 0;
    m->srv_mask_hi = 0;
    m->uav_mask = 0;
    m->smp_mask = 0;
    m->smp_cube_mask = 0;
    m->cs_threads[0] = m->cs_threads[1] = m->cs_threads[2] = 1;
    m->vs_input_mask = 0;
    for (int i = 0; i < 32; i++) m->vs_input_types[i] = 0;
}

#ifdef __cplusplus
}
#endif

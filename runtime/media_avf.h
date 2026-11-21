#pragma once
#include "shim_helpers.h"
#include <stdint.h>

// Native macOS VideoToolbox / AVFoundation Media Foundation shim for BO3 cinematics.
//
// Reverse-engineered BO3 Media Foundation seam (CoDBlkOps3_Exe):
//   - 0x1000ef820 : MFStartup(ULONG Version, DWORD dwFlags)
//   - 0x1000ef9f0 : MFShutdown(void)
//   - 0x1000ef82d : MFCreateAlignedMemoryBuffer(DWORD cbMaxLength, DWORD cbAlignment, IMFMediaBuffer **ppBuffer)
//   - 0x1000ef8b8 : MFCreateMediaType(IMFMediaType **ppMFType)
//   - 0x1000ef94c : MFCreateSample(IMFSample **ppIMFSample)
//   - 0x1000fbcb0 : CoCreateInstance(CLSID_CMSH264DecoderMFT, NULL, 1, IID_IMFTransform, &ppv)
//
// BO3 uses its own built-in Matroska (.mkv) demuxer to feed Annex-B H.264 SPS/PPS and
// compressed frame packets into IMFTransform::ProcessInput, negotiates NV12 output via
// MF_E_TRANSFORM_STREAM_CHANGE (0xC00D6D61), and uploads tightly-packed NV12 (Y + interleaved UV)
// planes to D3D11 textures from IMFTransform::ProcessOutput.

#ifdef __cplusplus
extern "C" {
#endif

// Initialize COM vtables / synthetic VA thunks for Media Foundation objects.
// Safe to call multiple times (idempotent via std::call_once).
void bo3_media_avf_init(void);

// CoCreateInstance hook for Media Foundation CLSIDs (CLSID_CMSH264DecoderMFT).
// Returns 1 if `rclsid` matched a Media Foundation class (and writes `*ppv` and `*out_hr`),
// or 0 if not handled so the caller can fall through to other COM factories.
int bo3_media_avf_try_cocreate(const void *rclsid, const void *riid, void **ppv, uint32_t *out_hr);

// Exact guest-ABI shims ready to wire at their CoDBlkOps3_Exe VAs:
SHIM_DEF(bo3_mf_startup);                      // 0x1000ef820
SHIM_DEF(bo3_mf_shutdown);                     // 0x1000ef9f0
SHIM_DEF(bo3_mf_create_aligned_memory_buffer); // 0x1000ef82d
SHIM_DEF(bo3_mf_create_media_type);            // 0x1000ef8b8
SHIM_DEF(bo3_mf_create_sample);                // 0x1000ef94c

#ifdef __cplusplus
}
#endif

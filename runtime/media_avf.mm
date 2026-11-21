#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include "media_avf.h"
#include "com_thunks.h"
#include "d3d11_abi.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <stdio.h>
#include <vector>

// =========================================================================
// Media Foundation HRESULTs, GUIDs, and ABI structs
// =========================================================================

static constexpr uint32_t BO3_E_UNEXPECTED                   = 0x8000FFFFu;
static constexpr uint32_t BO3_MF_E_BUFFERTOOSMALL            = 0xC00D36B1u;
static constexpr uint32_t BO3_MF_E_INVALIDSTREAMNUMBER       = 0xC00D36B3u;
static constexpr uint32_t BO3_MF_E_INVALIDTYPE               = 0xC00D36B4u;
static constexpr uint32_t BO3_MF_E_NO_MORE_TYPES             = 0xC00D36B9u;
static constexpr uint32_t BO3_MF_E_ATTRIBUTENOTFOUND         = 0xC00D36E6u;
static constexpr uint32_t BO3_MF_E_TRANSFORM_TYPE_NOT_SET    = 0xC00D6D60u;
static constexpr uint32_t BO3_MF_E_TRANSFORM_STREAM_CHANGE   = 0xC00D6D61u;
static constexpr uint32_t BO3_MF_E_TRANSFORM_NEED_MORE_INPUT = 0xC00D6D72u;

// MFT_MESSAGE_TYPE values used by BO3
static constexpr uint32_t BO3_MFT_MESSAGE_COMMAND_FLUSH          = 0x00000000u;
static constexpr uint32_t BO3_MFT_MESSAGE_COMMAND_DRAIN          = 0x00000001u;
static constexpr uint32_t BO3_MFT_MESSAGE_NOTIFY_BEGIN_STREAMING = 0x10000000u;
static constexpr uint32_t BO3_MFT_MESSAGE_NOTIFY_END_STREAMING   = 0x10000001u;
static constexpr uint32_t BO3_MFT_MESSAGE_NOTIFY_END_OF_STREAM   = 0x10000002u;
static constexpr uint32_t BO3_MFT_MESSAGE_NOTIFY_START_OF_STREAM = 0x10000003u;

// MFT_INPUT_STREAM_INFO / MFT_OUTPUT_STREAM_INFO flags (matches Aspyr binary)
static constexpr uint32_t BO3_MFT_STREAM_FLAGS_DEFAULT = 0x00000007u;
static constexpr uint32_t BO3_MFT_DEFAULT_OUTPUT_SIZE  = 0x003FC000u; // 4,177,920 bytes (>= 1920*1088*1.5)

// MF_ATTRIBUTE_TYPE values
static constexpr uint32_t BO3_MF_ATTRIBUTE_UINT32   = 19u;
static constexpr uint32_t BO3_MF_ATTRIBUTE_UINT64   = 21u;
static constexpr uint32_t BO3_MF_ATTRIBUTE_DOUBLE   = 5u;
static constexpr uint32_t BO3_MF_ATTRIBUTE_GUID     = 72u;
static constexpr uint32_t BO3_MF_ATTRIBUTE_BLOB     = 0x1011u;
static constexpr uint32_t BO3_MF_ATTRIBUTE_IUNKNOWN = 13u;

// Verified Media Foundation CLSIDs, IIDs, and attribute/format GUIDs from CoDBlkOps3_Exe
static const Bo3GUID BO3_CLSID_CMSH264DecoderMFT        = {0x62CE7E72, 0x4C71, 0x4D20, {0xB1, 0x5D, 0x45, 0x28, 0x31, 0xA8, 0x7D, 0x9D}};
static const Bo3GUID BO3_IID_IMFTransform               = {0xBF94C121, 0x5B05, 0x4E6F, {0x80, 0x00, 0xBA, 0x59, 0x89, 0x61, 0x41, 0x4D}};
static const Bo3GUID BO3_IID_IMFAttributes              = {0x2CD2D921, 0xC447, 0x44A7, {0xA1, 0x3C, 0x4A, 0xDA, 0xBF, 0xC2, 0x47, 0xE3}};
static const Bo3GUID BO3_IID_IMFMediaType               = {0x44AE0FA8, 0xEA31, 0x4109, {0x8D, 0x2E, 0x4C, 0xAE, 0x49, 0x97, 0xC5, 0x55}};
static const Bo3GUID BO3_IID_IMFMediaBuffer             = {0x045FA593, 0x8799, 0x42B8, {0xBC, 0x8D, 0x89, 0x68, 0xC6, 0x45, 0x35, 0x07}};
static const Bo3GUID BO3_IID_IMFSample                  = {0xC40A00F2, 0xB93A, 0x4D80, {0xAE, 0x8C, 0x5A, 0x1C, 0x63, 0x4F, 0x58, 0xE4}};

static const Bo3GUID BO3_MF_MT_MAJOR_TYPE               = {0x48EBA18E, 0xF8C9, 0x4687, {0xBF, 0x11, 0x0A, 0x74, 0xC9, 0xF9, 0x6A, 0x8F}};
static const Bo3GUID BO3_MF_MT_SUBTYPE                  = {0xF7E34C9A, 0x42E8, 0x4714, {0xB7, 0x4B, 0xCB, 0x29, 0xD7, 0x2C, 0x35, 0xE5}};
static const Bo3GUID BO3_MF_MT_FRAME_SIZE               = {0x1652C33D, 0xD6B2, 0x4012, {0xB8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xA3, 0x7D}};
static const Bo3GUID BO3_MF_MT_MINIMUM_DISPLAY_APERTURE = {0xD7388766, 0x18FE, 0x48C6, {0xA1, 0x77, 0xEE, 0x89, 0x48, 0x67, 0xC8, 0xC4}};
static const Bo3GUID BO3_MFMediaType_Video              = {0x73646976, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
static const Bo3GUID BO3_MFVideoFormat_H264             = {0x34363248, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
static const Bo3GUID BO3_MFVideoFormat_NV12             = {0x3231564E, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};

struct Bo3MFT_INPUT_STREAM_INFO {
    int64_t  hnsMaxLatency;
    uint32_t dwFlags;
    uint32_t cbSize;
    uint32_t cbMaxLookahead;
    uint32_t cbAlignment;
};
static_assert(sizeof(Bo3MFT_INPUT_STREAM_INFO) == 24, "MFT_INPUT_STREAM_INFO ABI mismatch");

struct Bo3MFT_OUTPUT_STREAM_INFO {
    uint32_t dwFlags;
    uint32_t cbSize;
    uint32_t cbAlignment;
};
static_assert(sizeof(Bo3MFT_OUTPUT_STREAM_INFO) == 12, "MFT_OUTPUT_STREAM_INFO ABI mismatch");

struct Bo3MFT_OUTPUT_DATA_BUFFER {
    uint32_t dwStreamID;
    uint32_t _pad0;
    void    *pSample;
    uint32_t dwStatus;
    uint32_t _pad1;
    void    *pEvents;
};
static_assert(sizeof(Bo3MFT_OUTPUT_DATA_BUFFER) == 32, "MFT_OUTPUT_DATA_BUFFER ABI mismatch");

struct Bo3MFOffset {
    int16_t fract;
    int16_t value;
};

struct Bo3MFVideoArea {
    Bo3MFOffset OffsetX;
    Bo3MFOffset OffsetY;
    int32_t     cx;
    int32_t     cy;
};
static_assert(sizeof(Bo3MFVideoArea) == 16, "MFVideoArea ABI mismatch");

// =========================================================================
// Vtables (populated once in bo3_media_avf_init)
// =========================================================================

static uint64_t g_vt_media_buffer[8];
static uint64_t g_vt_attributes[33];
static uint64_t g_vt_media_type[38];
static uint64_t g_vt_sample[47];
static uint64_t g_vt_transform[26];

// =========================================================================
// 1. IMFMediaBuffer implementation
// =========================================================================

struct Bo3MFMediaBuffer {
    Bo3ComBase com;
    std::mutex mtx;
    uint8_t   *data;
    uint32_t   max_len;
    uint32_t   cur_len;
    uint32_t   lock_count;
};
static_assert(offsetof(Bo3MFMediaBuffer, com) == 0, "Bo3ComBase must be at offset 0");

static uint32_t mf_buffer_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_IMFMediaBuffer)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static void mf_buffer_destroy(Bo3ComBase *self) {
    auto *b = reinterpret_cast<Bo3MFMediaBuffer *>(self);
    if (b->data) {
        free(b->data);
        b->data = nullptr;
    }
    delete b;
}

static Bo3MFMediaBuffer *mf_buffer_create(uint32_t max_len, uint32_t alignment) {
    bo3_media_avf_init();
    size_t alloc_size = max_len > 0 ? static_cast<size_t>(max_len) : 64u;
    size_t align = 64u;
    // Handle both power-of-two alignments and MF_*_BYTE_ALIGNMENT masks (e.g. 15 -> 16)
    if (alignment > 0) {
        size_t a = alignment;
        if ((a & (a - 1u)) != 0 && ((a + 1u) & a) == 0) {
            a = a + 1u;
        }
        if (a > align && (a & (a - 1u)) == 0 && a <= 4096u) {
            align = a;
        }
    }
    void *mem = nullptr;
    if (posix_memalign(&mem, align, alloc_size) != 0 || !mem) {
        return nullptr;
    }
    memset(mem, 0, alloc_size);

    auto *b = new Bo3MFMediaBuffer();
    b->com.init_com(g_vt_media_buffer, "IMFMediaBuffer", mf_buffer_qi, mf_buffer_destroy);
    b->data = static_cast<uint8_t *>(mem);
    b->max_len = max_len;
    b->cur_len = 0;
    b->lock_count = 0;
    return b;
}

// Slot 3 (+0x18): Lock(BYTE **ppbBuffer, DWORD *pcbMaxLength, DWORD *pcbCurrentLength)
static SHIM_DEF(mf_buffer_lock) {
    SHIM_UNUSED_ALL();
    auto *b = reinterpret_cast<Bo3MFMediaBuffer *>(rdi);
    auto **ppb = reinterpret_cast<uint8_t **>(rsi);
    auto *pcb_max = reinterpret_cast<uint32_t *>(rdx);
    auto *pcb_cur = reinterpret_cast<uint32_t *>(rcx);
    if (!b || !ppb) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(b->mtx);
    b->lock_count++;
    *ppb = b->data;
    if (pcb_max) *pcb_max = b->max_len;
    if (pcb_cur) *pcb_cur = b->cur_len;
    return ret_u64(BO3_S_OK);
}

// Slot 4 (+0x20): Unlock()
static SHIM_DEF(mf_buffer_unlock) {
    SHIM_UNUSED_ALL();
    auto *b = reinterpret_cast<Bo3MFMediaBuffer *>(rdi);
    if (!b) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(b->mtx);
    if (b->lock_count > 0) b->lock_count--;
    return ret_u64(BO3_S_OK);
}

// Slot 5 (+0x28): GetCurrentLength(DWORD *pcbCurrentLength)
static SHIM_DEF(mf_buffer_get_cur_len) {
    SHIM_UNUSED_ALL();
    auto *b = reinterpret_cast<Bo3MFMediaBuffer *>(rdi);
    auto *out = reinterpret_cast<uint32_t *>(rsi);
    if (!b || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(b->mtx);
    *out = b->cur_len;
    return ret_u64(BO3_S_OK);
}

// Slot 6 (+0x30): SetCurrentLength(DWORD cbCurrentLength)
static SHIM_DEF(mf_buffer_set_cur_len) {
    SHIM_UNUSED_ALL();
    auto *b = reinterpret_cast<Bo3MFMediaBuffer *>(rdi);
    uint32_t len = static_cast<uint32_t>(rsi);
    if (!b) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(b->mtx);
    if (len > b->max_len) return ret_u64(BO3_E_INVALIDARG);
    b->cur_len = len;
    return ret_u64(BO3_S_OK);
}

// Slot 7 (+0x38): GetMaxLength(DWORD *pcbMaxLength)
static SHIM_DEF(mf_buffer_get_max_len) {
    SHIM_UNUSED_ALL();
    auto *b = reinterpret_cast<Bo3MFMediaBuffer *>(rdi);
    auto *out = reinterpret_cast<uint32_t *>(rsi);
    if (!b || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(b->mtx);
    *out = b->max_len;
    return ret_u64(BO3_S_OK);
}

// =========================================================================
// 2. IMFAttributes base implementation (shared by IMFMediaType & IMFSample)
// =========================================================================

struct Bo3AttrItem {
    Bo3GUID  key{};
    uint32_t type = 0;
    uint32_t u32 = 0;
    uint64_t u64 = 0;
    double   f64 = 0.0;
    Bo3GUID  guid{};
    std::vector<uint8_t> blob;
    Bo3ComBase *unk = nullptr;
};

struct Bo3MFAttributes {
    Bo3ComBase               com;
    std::mutex               mtx;
    std::vector<Bo3AttrItem> items;

    Bo3AttrItem *find_locked(const Bo3GUID *key) {
        if (!key) return nullptr;
        for (auto &it : items) {
            if (bo3_guid_eq(&it.key, key)) return &it;
        }
        return nullptr;
    }

    void clear_locked() {
        for (auto &it : items) {
            if (it.type == BO3_MF_ATTRIBUTE_IUNKNOWN && it.unk) {
                it.unk->release();
                it.unk = nullptr;
            }
        }
        items.clear();
    }

    Bo3AttrItem &upsert_locked(const Bo3GUID *key, uint32_t type) {
        Bo3AttrItem *existing = find_locked(key);
        if (existing) {
            if (existing->type == BO3_MF_ATTRIBUTE_IUNKNOWN && existing->unk) {
                existing->unk->release();
                existing->unk = nullptr;
            }
            existing->blob.clear();
            existing->type = type;
            return *existing;
        }
        Bo3AttrItem item{};
        item.key = *key;
        item.type = type;
        items.push_back(std::move(item));
        return items.back();
    }

    void set_guid(const Bo3GUID *key, const Bo3GUID *val) {
        std::lock_guard<std::mutex> lk(mtx);
        auto &it = upsert_locked(key, BO3_MF_ATTRIBUTE_GUID);
        it.guid = *val;
    }

    void set_u32(const Bo3GUID *key, uint32_t val) {
        std::lock_guard<std::mutex> lk(mtx);
        auto &it = upsert_locked(key, BO3_MF_ATTRIBUTE_UINT32);
        it.u32 = val;
    }

    void set_u64(const Bo3GUID *key, uint64_t val) {
        std::lock_guard<std::mutex> lk(mtx);
        auto &it = upsert_locked(key, BO3_MF_ATTRIBUTE_UINT64);
        it.u64 = val;
    }

    void set_blob(const Bo3GUID *key, const uint8_t *buf, uint32_t sz) {
        std::lock_guard<std::mutex> lk(mtx);
        auto &it = upsert_locked(key, BO3_MF_ATTRIBUTE_BLOB);
        if (buf && sz > 0) {
            it.blob.assign(buf, buf + sz);
        }
    }

    bool get_guid(const Bo3GUID *key, Bo3GUID *out) {
        std::lock_guard<std::mutex> lk(mtx);
        auto *it = find_locked(key);
        if (!it || it->type != BO3_MF_ATTRIBUTE_GUID) return false;
        *out = it->guid;
        return true;
    }

    bool get_u32(const Bo3GUID *key, uint32_t *out) {
        std::lock_guard<std::mutex> lk(mtx);
        auto *it = find_locked(key);
        if (!it || it->type != BO3_MF_ATTRIBUTE_UINT32) return false;
        *out = it->u32;
        return true;
    }

    bool get_u64(const Bo3GUID *key, uint64_t *out) {
        std::lock_guard<std::mutex> lk(mtx);
        auto *it = find_locked(key);
        if (!it || it->type != BO3_MF_ATTRIBUTE_UINT64) return false;
        *out = it->u64;
        return true;
    }
};
static_assert(offsetof(Bo3MFAttributes, com) == 0, "Bo3ComBase must be at offset 0");

static uint32_t mf_attr_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) || bo3_guid_eq(riid, &BO3_IID_IMFAttributes)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static void mf_attr_destroy(Bo3ComBase *self) {
    auto *a = reinterpret_cast<Bo3MFAttributes *>(self);
    {
        std::lock_guard<std::mutex> lk(a->mtx);
        a->clear_locked();
    }
    delete a;
}

static Bo3MFAttributes *mf_attr_create() {
    bo3_media_avf_init();
    auto *a = new Bo3MFAttributes();
    a->com.init_com(g_vt_attributes, "IMFAttributes", mf_attr_qi, mf_attr_destroy);
    return a;
}

// Slot 4 (+0x20): GetItemType(REFGUID guidKey, MF_ATTRIBUTE_TYPE *pType)
static SHIM_DEF(mf_attr_get_item_type) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    auto *out = reinterpret_cast<uint32_t *>(rdx);
    if (!a || !key || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    auto *it = a->find_locked(key);
    if (!it) return ret_u64(BO3_MF_E_ATTRIBUTENOTFOUND);
    *out = it->type;
    return ret_u64(BO3_S_OK);
}

// Slot 7 (+0x38): GetUINT32(REFGUID guidKey, UINT32 *punValue)
static SHIM_DEF(mf_attr_get_u32) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    auto *out = reinterpret_cast<uint32_t *>(rdx);
    if (!a || !key || !out) return ret_u64(BO3_E_POINTER);
    return ret_u64(a->get_u32(key, out) ? BO3_S_OK : BO3_MF_E_ATTRIBUTENOTFOUND);
}

// Slot 8 (+0x40): GetUINT64(REFGUID guidKey, UINT64 *punValue)
static SHIM_DEF(mf_attr_get_u64) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    auto *out = reinterpret_cast<uint64_t *>(rdx);
    if (!a || !key || !out) return ret_u64(BO3_E_POINTER);
    return ret_u64(a->get_u64(key, out) ? BO3_S_OK : BO3_MF_E_ATTRIBUTENOTFOUND);
}

// Slot 9 (+0x48): GetDouble(REFGUID guidKey, double *pfValue)
static SHIM_DEF(mf_attr_get_double) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    auto *out = reinterpret_cast<double *>(rdx);
    if (!a || !key || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    auto *it = a->find_locked(key);
    if (!it || it->type != BO3_MF_ATTRIBUTE_DOUBLE) return ret_u64(BO3_MF_E_ATTRIBUTENOTFOUND);
    *out = it->f64;
    return ret_u64(BO3_S_OK);
}

// Slot 10 (+0x50): GetGUID(REFGUID guidKey, GUID *pguidValue)
static SHIM_DEF(mf_attr_get_guid) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    auto *out = reinterpret_cast<Bo3GUID *>(rdx);
    if (!a || !key || !out) return ret_u64(BO3_E_POINTER);
    return ret_u64(a->get_guid(key, out) ? BO3_S_OK : BO3_MF_E_ATTRIBUTENOTFOUND);
}

// Slot 14 (+0x70): GetBlobSize(REFGUID guidKey, UINT32 *pcbBlobSize)
static SHIM_DEF(mf_attr_get_blob_size) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    auto *out = reinterpret_cast<uint32_t *>(rdx);
    if (!a || !key || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    auto *it = a->find_locked(key);
    if (!it || it->type != BO3_MF_ATTRIBUTE_BLOB) return ret_u64(BO3_MF_E_ATTRIBUTENOTFOUND);
    *out = static_cast<uint32_t>(it->blob.size());
    return ret_u64(BO3_S_OK);
}

// Slot 15 (+0x78): GetBlob(REFGUID guidKey, UINT8 *pBuf, UINT32 cbBufSize, UINT32 *pcbBlobSize)
static SHIM_DEF(mf_attr_get_blob) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    auto *buf = reinterpret_cast<uint8_t *>(rdx);
    uint32_t buf_sz = static_cast<uint32_t>(rcx);
    auto *pcb_out = reinterpret_cast<uint32_t *>(r8);
    if (!a || !key) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    auto *it = a->find_locked(key);
    if (!it || it->type != BO3_MF_ATTRIBUTE_BLOB) return ret_u64(BO3_MF_E_ATTRIBUTENOTFOUND);
    uint32_t sz = static_cast<uint32_t>(it->blob.size());
    if (pcb_out) *pcb_out = sz;
    if (buf_sz < sz) return ret_u64(BO3_MF_E_BUFFERTOOSMALL);
    if (buf && sz > 0) memcpy(buf, it->blob.data(), sz);
    return ret_u64(BO3_S_OK);
}

// Slot 17 (+0x88): GetUnknown(REFGUID guidKey, REFIID riid, LPVOID *ppv)
static SHIM_DEF(mf_attr_get_unknown) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    const auto *riid = reinterpret_cast<const Bo3GUID *>(rdx);
    auto **ppv = reinterpret_cast<void **>(rcx);
    if (!a || !key || !ppv) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    auto *it = a->find_locked(key);
    if (!it || it->type != BO3_MF_ATTRIBUTE_IUNKNOWN || !it->unk) {
        *ppv = nullptr;
        return ret_u64(BO3_MF_E_ATTRIBUTENOTFOUND);
    }
    return ret_u64(it->unk->query_interface(riid, ppv));
}

// Slot 19 (+0x98): DeleteItem(REFGUID guidKey)
static SHIM_DEF(mf_attr_delete_item) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    if (!a || !key) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    for (auto it = a->items.begin(); it != a->items.end(); ++it) {
        if (bo3_guid_eq(&it->key, key)) {
            if (it->type == BO3_MF_ATTRIBUTE_IUNKNOWN && it->unk) it->unk->release();
            a->items.erase(it);
            break;
        }
    }
    return ret_u64(BO3_S_OK);
}

// Slot 20 (+0xa0): DeleteAllItems()
static SHIM_DEF(mf_attr_delete_all) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    if (!a) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    a->clear_locked();
    return ret_u64(BO3_S_OK);
}

// Slot 21 (+0xa8): SetUINT32(REFGUID guidKey, UINT32 unValue)
static SHIM_DEF(mf_attr_set_u32) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    if (!a || !key) return ret_u64(BO3_E_POINTER);
    a->set_u32(key, static_cast<uint32_t>(rdx));
    return ret_u64(BO3_S_OK);
}

// Slot 22 (+0xb0): SetUINT64(REFGUID guidKey, UINT64 unValue)
static SHIM_DEF(mf_attr_set_u64) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    if (!a || !key) return ret_u64(BO3_E_POINTER);
    a->set_u64(key, rdx);
    return ret_u64(BO3_S_OK);
}

// Slot 23 (+0xb8): SetDouble(REFGUID guidKey, double fValue)
static SHIM_DEF(mf_attr_set_double) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    if (!a || !key) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    auto &it = a->upsert_locked(key, BO3_MF_ATTRIBUTE_DOUBLE);
    it.f64 = xmm_to_f64(xmm0);
    return ret_u64(BO3_S_OK);
}

// Slot 24 (+0xc0): SetGUID(REFGUID guidKey, REFGUID guidValue)
static SHIM_DEF(mf_attr_set_guid) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    const auto *val = reinterpret_cast<const Bo3GUID *>(rdx);
    if (!a || !key || !val) return ret_u64(BO3_E_POINTER);
    a->set_guid(key, val);
    return ret_u64(BO3_S_OK);
}

// Slot 26 (+0xd0): SetBlob(REFGUID guidKey, const UINT8 *pBuf, UINT32 cbBufSize)
static SHIM_DEF(mf_attr_set_blob) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    const auto *buf = reinterpret_cast<const uint8_t *>(rdx);
    uint32_t sz = static_cast<uint32_t>(rcx);
    if (!a || !key) return ret_u64(BO3_E_POINTER);
    a->set_blob(key, buf, sz);
    return ret_u64(BO3_S_OK);
}

// Slot 27 (+0xd8): SetUnknown(REFGUID guidKey, IUnknown *pUnknown)
static SHIM_DEF(mf_attr_set_unknown) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    const auto *key = reinterpret_cast<const Bo3GUID *>(rsi);
    auto *unk = reinterpret_cast<Bo3ComBase *>(rdx);
    if (!a || !key) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    auto &it = a->upsert_locked(key, BO3_MF_ATTRIBUTE_IUNKNOWN);
    if (unk) unk->add_ref();
    it.unk = unk;
    return ret_u64(BO3_S_OK);
}

// Slot 28 (+0xe0): LockStore()
static SHIM_DEF(mf_attr_lock_store) {
    SHIM_UNUSED_ALL();
    return ret_u64(BO3_S_OK);
}

// Slot 29 (+0xe8): UnlockStore()
static SHIM_DEF(mf_attr_unlock_store) {
    SHIM_UNUSED_ALL();
    return ret_u64(BO3_S_OK);
}

// Slot 30 (+0xf0): GetCount(UINT32 *pcItems)
static SHIM_DEF(mf_attr_get_count) {
    SHIM_UNUSED_ALL();
    auto *a = reinterpret_cast<Bo3MFAttributes *>(rdi);
    auto *out = reinterpret_cast<uint32_t *>(rsi);
    if (!a || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(a->mtx);
    *out = static_cast<uint32_t>(a->items.size());
    return ret_u64(BO3_S_OK);
}

// Slot 32 (+0x100): CopyAllItems(IMFAttributes *pDest)
static SHIM_DEF(mf_attr_copy_all) {
    SHIM_UNUSED_ALL();
    auto *src = reinterpret_cast<Bo3MFAttributes *>(rdi);
    auto *dst = reinterpret_cast<Bo3MFAttributes *>(rsi);
    if (!src || !dst) return ret_u64(BO3_E_POINTER);
    if (src == dst) return ret_u64(BO3_S_OK);
    std::scoped_lock lk(src->mtx, dst->mtx);
    dst->clear_locked();
    dst->items = src->items;
    for (auto &it : dst->items) {
        if (it.type == BO3_MF_ATTRIBUTE_IUNKNOWN && it.unk) it.unk->add_ref();
    }
    return ret_u64(BO3_S_OK);
}

static void populate_attributes_vtable(uint64_t *vt) {
    bo3_com_set_slot(vt,  4, mf_attr_get_item_type);
    bo3_com_set_slot(vt,  7, mf_attr_get_u32);
    bo3_com_set_slot(vt,  8, mf_attr_get_u64);
    bo3_com_set_slot(vt,  9, mf_attr_get_double);
    bo3_com_set_slot(vt, 10, mf_attr_get_guid);
    bo3_com_set_slot(vt, 14, mf_attr_get_blob_size);
    bo3_com_set_slot(vt, 15, mf_attr_get_blob);
    bo3_com_set_slot(vt, 17, mf_attr_get_unknown);
    bo3_com_set_slot(vt, 19, mf_attr_delete_item);
    bo3_com_set_slot(vt, 20, mf_attr_delete_all);
    bo3_com_set_slot(vt, 21, mf_attr_set_u32);
    bo3_com_set_slot(vt, 22, mf_attr_set_u64);
    bo3_com_set_slot(vt, 23, mf_attr_set_double);
    bo3_com_set_slot(vt, 24, mf_attr_set_guid);
    bo3_com_set_slot(vt, 26, mf_attr_set_blob);
    bo3_com_set_slot(vt, 27, mf_attr_set_unknown);
    bo3_com_set_slot(vt, 28, mf_attr_lock_store);
    bo3_com_set_slot(vt, 29, mf_attr_unlock_store);
    bo3_com_set_slot(vt, 30, mf_attr_get_count);
    bo3_com_set_slot(vt, 32, mf_attr_copy_all);
}

// =========================================================================
// 3. IMFMediaType implementation (extends IMFAttributes)
// =========================================================================

struct Bo3MFMediaType {
    Bo3MFAttributes attrs;
};
static_assert(offsetof(Bo3MFMediaType, attrs) == 0, "Bo3MFAttributes must be at offset 0");

static uint32_t mf_media_type_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) ||
        bo3_guid_eq(riid, &BO3_IID_IMFAttributes) ||
        bo3_guid_eq(riid, &BO3_IID_IMFMediaType)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static void mf_media_type_destroy(Bo3ComBase *self) {
    auto *mt = reinterpret_cast<Bo3MFMediaType *>(self);
    {
        std::lock_guard<std::mutex> lk(mt->attrs.mtx);
        mt->attrs.clear_locked();
    }
    delete mt;
}

static Bo3MFMediaType *mf_media_type_create() {
    bo3_media_avf_init();
    auto *mt = new Bo3MFMediaType();
    mt->attrs.com.init_com(g_vt_media_type, "IMFMediaType", mf_media_type_qi, mf_media_type_destroy);
    return mt;
}

// Slot 33 (+0x108): GetMajorType(GUID *pguidMajorType)
static SHIM_DEF(mf_media_type_get_major_type) {
    SHIM_UNUSED_ALL();
    auto *mt = reinterpret_cast<Bo3MFMediaType *>(rdi);
    auto *out = reinterpret_cast<Bo3GUID *>(rsi);
    if (!mt || !out) return ret_u64(BO3_E_POINTER);
    return ret_u64(mt->attrs.get_guid(&BO3_MF_MT_MAJOR_TYPE, out) ? BO3_S_OK : BO3_MF_E_ATTRIBUTENOTFOUND);
}

// Slot 34 (+0x110): IsCompressedFormat(BOOL *pfCompressed)
static SHIM_DEF(mf_media_type_is_compressed) {
    SHIM_UNUSED_ALL();
    auto *mt = reinterpret_cast<Bo3MFMediaType *>(rdi);
    auto *out = reinterpret_cast<int32_t *>(rsi);
    if (!mt || !out) return ret_u64(BO3_E_POINTER);
    Bo3GUID sub{};
    if (mt->attrs.get_guid(&BO3_MF_MT_SUBTYPE, &sub) && bo3_guid_eq(&sub, &BO3_MFVideoFormat_H264)) {
        *out = 1;
    } else {
        *out = 0;
    }
    return ret_u64(BO3_S_OK);
}

// =========================================================================
// 4. IMFSample implementation (extends IMFAttributes)
// =========================================================================

struct Bo3MFSample {
    Bo3MFAttributes                attrs;
    std::mutex                     sample_mtx;
    uint32_t                       sample_flags = 0;
    int64_t                        sample_time = 0;
    int64_t                        sample_duration = 0;
    bool                           has_time = false;
    bool                           has_duration = false;
    std::vector<Bo3MFMediaBuffer *> buffers;
};
static_assert(offsetof(Bo3MFSample, attrs) == 0, "Bo3MFAttributes must be at offset 0");

static uint32_t mf_sample_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) ||
        bo3_guid_eq(riid, &BO3_IID_IMFAttributes) ||
        bo3_guid_eq(riid, &BO3_IID_IMFSample)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static void mf_sample_destroy(Bo3ComBase *self) {
    auto *s = reinterpret_cast<Bo3MFSample *>(self);
    {
        std::lock_guard<std::mutex> lk(s->sample_mtx);
        for (auto *buf : s->buffers) {
            if (buf) buf->com.release();
        }
        s->buffers.clear();
    }
    {
        std::lock_guard<std::mutex> lk(s->attrs.mtx);
        s->attrs.clear_locked();
    }
    delete s;
}

static Bo3MFSample *mf_sample_create() {
    bo3_media_avf_init();
    auto *s = new Bo3MFSample();
    s->attrs.com.init_com(g_vt_sample, "IMFSample", mf_sample_qi, mf_sample_destroy);
    return s;
}

// Slot 33 (+0x108): GetSampleFlags
static SHIM_DEF(mf_sample_get_flags) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    auto *out = reinterpret_cast<uint32_t *>(rsi);
    if (!s || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    *out = s->sample_flags;
    return ret_u64(BO3_S_OK);
}

// Slot 34 (+0x110): SetSampleFlags
static SHIM_DEF(mf_sample_set_flags) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    if (!s) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    s->sample_flags = static_cast<uint32_t>(rsi);
    return ret_u64(BO3_S_OK);
}

// Slot 35 (+0x118): GetSampleTime
static SHIM_DEF(mf_sample_get_time) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    auto *out = reinterpret_cast<int64_t *>(rsi);
    if (!s || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    if (!s->has_time) return ret_u64(BO3_MF_E_ATTRIBUTENOTFOUND);
    *out = s->sample_time;
    return ret_u64(BO3_S_OK);
}

// Slot 36 (+0x120): SetSampleTime
static SHIM_DEF(mf_sample_set_time) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    if (!s) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    s->sample_time = static_cast<int64_t>(rsi);
    s->has_time = true;
    return ret_u64(BO3_S_OK);
}

// Slot 37 (+0x128): GetSampleDuration
static SHIM_DEF(mf_sample_get_duration) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    auto *out = reinterpret_cast<int64_t *>(rsi);
    if (!s || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    if (!s->has_duration) return ret_u64(BO3_MF_E_ATTRIBUTENOTFOUND);
    *out = s->sample_duration;
    return ret_u64(BO3_S_OK);
}

// Slot 38 (+0x130): SetSampleDuration
static SHIM_DEF(mf_sample_set_duration) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    if (!s) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    s->sample_duration = static_cast<int64_t>(rsi);
    s->has_duration = true;
    return ret_u64(BO3_S_OK);
}

// Slot 39 (+0x138): GetBufferCount(DWORD *pdwBufferCount)
static SHIM_DEF(mf_sample_get_buffer_count) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    auto *out = reinterpret_cast<uint32_t *>(rsi);
    if (!s || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    *out = static_cast<uint32_t>(s->buffers.size());
    return ret_u64(BO3_S_OK);
}

// Slot 40 (+0x140): GetBufferByIndex(DWORD dwIndex, IMFMediaBuffer **ppBuffer)
static SHIM_DEF(mf_sample_get_buffer_by_index) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    uint32_t idx = static_cast<uint32_t>(rsi);
    auto **ppbuf = reinterpret_cast<Bo3MFMediaBuffer **>(rdx);
    if (!s || !ppbuf) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    if (idx >= s->buffers.size()) {
        *ppbuf = nullptr;
        return ret_u64(BO3_E_INVALIDARG);
    }
    Bo3MFMediaBuffer *buf = s->buffers[idx];
    if (buf) buf->com.add_ref();
    *ppbuf = buf;
    return ret_u64(BO3_S_OK);
}

// Slot 41 (+0x148): ConvertToContiguousBuffer(IMFMediaBuffer **ppBuffer)
static SHIM_DEF(mf_sample_convert_to_contiguous) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    auto **ppbuf = reinterpret_cast<Bo3MFMediaBuffer **>(rsi);
    if (!s || !ppbuf) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    if (s->buffers.empty()) {
        *ppbuf = nullptr;
        return ret_u64(BO3_E_UNEXPECTED);
    }
    if (s->buffers.size() == 1) {
        s->buffers[0]->com.add_ref();
        *ppbuf = s->buffers[0];
        return ret_u64(BO3_S_OK);
    }
    std::vector<uint8_t> tmp;
    for (auto *b : s->buffers) {
        if (!b) continue;
        std::lock_guard<std::mutex> blk(b->mtx);
        if (b->cur_len > 0 && b->data) {
            if (tmp.size() > static_cast<size_t>(UINT32_MAX) - b->cur_len) {
                *ppbuf = nullptr;
                return ret_u64(BO3_E_OUTOFMEMORY);
            }
            tmp.insert(tmp.end(), b->data, b->data + b->cur_len);
        }
    }
    uint32_t total = static_cast<uint32_t>(tmp.size());
    Bo3MFMediaBuffer *merged = mf_buffer_create(total, 64);
    if (!merged) return ret_u64(BO3_E_OUTOFMEMORY);
    if (total > 0) {
        memcpy(merged->data, tmp.data(), total);
    }
    merged->cur_len = total;
    *ppbuf = merged;
    return ret_u64(BO3_S_OK);
}

// Slot 42 (+0x150): AddBuffer(IMFMediaBuffer *pBuffer)
static SHIM_DEF(mf_sample_add_buffer) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    auto *buf = reinterpret_cast<Bo3MFMediaBuffer *>(rsi);
    if (!s || !buf) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    buf->com.add_ref();
    s->buffers.push_back(buf);
    return ret_u64(BO3_S_OK);
}

// Slot 43 (+0x158): RemoveBufferByIndex(DWORD dwIndex)
static SHIM_DEF(mf_sample_remove_buffer_by_index) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    uint32_t idx = static_cast<uint32_t>(rsi);
    if (!s) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    if (idx >= s->buffers.size()) return ret_u64(BO3_E_INVALIDARG);
    if (s->buffers[idx]) s->buffers[idx]->com.release();
    s->buffers.erase(s->buffers.begin() + idx);
    return ret_u64(BO3_S_OK);
}

// Slot 44 (+0x160): RemoveAllBuffers()
static SHIM_DEF(mf_sample_remove_all_buffers) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    if (!s) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    for (auto *b : s->buffers) {
        if (b) b->com.release();
    }
    s->buffers.clear();
    return ret_u64(BO3_S_OK);
}

// Slot 45 (+0x168): GetTotalLength(DWORD *pcbTotalLength)
static SHIM_DEF(mf_sample_get_total_len) {
    SHIM_UNUSED_ALL();
    auto *s = reinterpret_cast<Bo3MFSample *>(rdi);
    auto *out = reinterpret_cast<uint32_t *>(rsi);
    if (!s || !out) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(s->sample_mtx);
    uint32_t total = 0;
    for (auto *b : s->buffers) {
        std::lock_guard<std::mutex> blk(b->mtx);
        total += b->cur_len;
    }
    *out = total;
    return ret_u64(BO3_S_OK);
}

// =========================================================================
// 5. Minimal H.264 Bitstream / SPS / POC Parser for B-frame Reordering
// =========================================================================

namespace {

struct BitReader {
    const uint8_t *data = nullptr;
    size_t         size = 0;
    size_t         bit_pos = 0;

    bool eof() const { return bit_pos >= size * 8u; }

    uint32_t read_bits(int n) {
        uint32_t v = 0;
        for (int i = 0; i < n; i++) {
            if (bit_pos >= size * 8u) return v;
            uint8_t byte = data[bit_pos >> 3];
            uint32_t bit = (byte >> (7 - (bit_pos & 7u))) & 1u;
            v = (v << 1) | bit;
            bit_pos++;
        }
        return v;
    }

    uint32_t read_ue() {
        int zeros = 0;
        while (!eof() && read_bits(1) == 0) {
            zeros++;
            if (zeros > 31) return 0;
        }
        if (zeros == 0) return 0;
        return ((1u << zeros) - 1u) + read_bits(zeros);
    }

    int32_t read_se() {
        uint32_t ue = read_ue();
        int32_t mag = static_cast<int32_t>((ue + 1u) >> 1);
        return (ue & 1u) ? mag : -mag;
    }
};

// Remove H.264 emulation-prevention bytes (00 00 03 -> 00 00) from NAL payload (after 1-byte header).
static std::vector<uint8_t> nal_to_rbsp(const uint8_t *nal, size_t len, size_t max_out) {
    std::vector<uint8_t> rbsp;
    if (len <= 1) return rbsp;
    rbsp.reserve(std::min(len - 1, max_out));
    int zero_run = 0;
    for (size_t i = 1; i < len && rbsp.size() < max_out; i++) {
        uint8_t b = nal[i];
        if (zero_run == 2 && b == 0x03) {
            zero_run = 0;
            continue;
        }
        rbsp.push_back(b);
        zero_run = (b == 0) ? (zero_run + 1) : 0;
    }
    return rbsp;
}

static void skip_scaling_list(BitReader &br, int size_of_list) {
    int last_scale = 8;
    int next_scale = 8;
    for (int j = 0; j < size_of_list; j++) {
        if (next_scale != 0) {
            int delta_scale = br.read_se();
            next_scale = (last_scale + delta_scale + 256) % 256;
        }
        last_scale = (next_scale == 0) ? last_scale : next_scale;
    }
}

struct H264SpsInfo {
    bool     valid = false;
    uint32_t profile_idc = 0;
    bool     separate_colour_plane = false;
    uint32_t log2_max_frame_num = 4;
    uint32_t pic_order_cnt_type = 0;
    uint32_t log2_max_poc_lsb = 4;
    bool     frame_mbs_only = true;
    uint32_t max_num_reorder_frames = 0;
    bool     has_reorder_hint = false;
};

static bool parse_h264_sps(const uint8_t *nal, size_t len, H264SpsInfo &out) {
    std::vector<uint8_t> rbsp = nal_to_rbsp(nal, len, 256);
    if (rbsp.size() < 4) return false;

    BitReader br{rbsp.data(), rbsp.size(), 0};
    H264SpsInfo info{};
    info.profile_idc = br.read_bits(8);
    (void)br.read_bits(8); // constraint flags
    (void)br.read_bits(8); // level_idc
    (void)br.read_ue();    // seq_parameter_set_id

    if (info.profile_idc == 100 || info.profile_idc == 110 || info.profile_idc == 122 ||
        info.profile_idc == 244 || info.profile_idc == 44  || info.profile_idc == 83  ||
        info.profile_idc == 86  || info.profile_idc == 118 || info.profile_idc == 128 ||
        info.profile_idc == 138 || info.profile_idc == 139 || info.profile_idc == 134 ||
        info.profile_idc == 135) {
        uint32_t chroma_format_idc = br.read_ue();
        if (chroma_format_idc == 3) {
            info.separate_colour_plane = (br.read_bits(1) != 0);
        }
        (void)br.read_ue(); // bit_depth_luma_minus8
        (void)br.read_ue(); // bit_depth_chroma_minus8
        (void)br.read_bits(1); // qpprime_y_zero_transform_bypass_flag
        if (br.read_bits(1)) { // seq_scaling_matrix_present_flag
            int nlists = (chroma_format_idc != 3) ? 8 : 12;
            for (int i = 0; i < nlists; i++) {
                if (br.read_bits(1)) {
                    skip_scaling_list(br, i < 6 ? 16 : 64);
                }
            }
        }
    }

    info.log2_max_frame_num = br.read_ue() + 4u;
    if (info.log2_max_frame_num > 16u) info.log2_max_frame_num = 16u;
    info.pic_order_cnt_type = br.read_ue();
    if (info.pic_order_cnt_type == 0) {
        info.log2_max_poc_lsb = br.read_ue() + 4u;
        if (info.log2_max_poc_lsb > 16u) info.log2_max_poc_lsb = 16u;
    } else if (info.pic_order_cnt_type == 1) {
        (void)br.read_bits(1); // delta_pic_order_always_zero_flag
        (void)br.read_se();    // offset_for_non_ref_pic
        (void)br.read_se();    // offset_for_top_to_bottom_field
        uint32_t n = br.read_ue();
        for (uint32_t i = 0; i < n && i < 256; i++) (void)br.read_se();
    }

    uint32_t max_num_ref_frames = br.read_ue();
    (void)br.read_bits(1); // gaps_in_frame_num_value_allowed_flag
    (void)br.read_ue();    // pic_width_in_mbs_minus1
    (void)br.read_ue();    // pic_height_in_map_units_minus1
    info.frame_mbs_only = (br.read_bits(1) != 0);
    if (!info.frame_mbs_only) {
        (void)br.read_bits(1); // mb_adaptive_frame_field_flag
    }
    (void)br.read_bits(1); // direct_8x8_inference_flag
    if (br.read_bits(1)) { // frame_cropping_flag
        (void)br.read_ue();
        (void)br.read_ue();
        (void)br.read_ue();
        (void)br.read_ue();
    }

    // Parse VUI bitstream_restriction_flag if present to get exact max_num_reorder_frames
    if (!br.eof() && br.read_bits(1)) { // vui_parameters_present_flag
        if (br.read_bits(1)) { // aspect_ratio_info_present_flag
            if (br.read_bits(8) == 255) { // Extended_SAR
                (void)br.read_bits(16);
                (void)br.read_bits(16);
            }
        }
        if (br.read_bits(1)) (void)br.read_bits(1); // overscan_info
        if (br.read_bits(1)) { // video_signal_type
            (void)br.read_bits(3);
            (void)br.read_bits(1);
            if (br.read_bits(1)) (void)br.read_bits(24);
        }
        if (br.read_bits(1)) { // chroma_loc_info
            (void)br.read_ue();
            (void)br.read_ue();
        }
        if (br.read_bits(1)) { // timing_info
            (void)br.read_bits(32);
            (void)br.read_bits(32);
            (void)br.read_bits(1);
        }
        auto skip_hrd = [&br]() {
            uint32_t cpb_cnt = br.read_ue() + 1u;
            (void)br.read_bits(4);
            (void)br.read_bits(4);
            for (uint32_t i = 0; i < cpb_cnt && i < 32; i++) {
                (void)br.read_ue();
                (void)br.read_ue();
                (void)br.read_bits(1);
            }
            (void)br.read_bits(20);
        };
        bool nal_hrd = (br.read_bits(1) != 0);
        if (nal_hrd) skip_hrd();
        bool vcl_hrd = (br.read_bits(1) != 0);
        if (vcl_hrd) skip_hrd();
        if (nal_hrd || vcl_hrd) (void)br.read_bits(1);
        (void)br.read_bits(1); // pic_struct_present_flag
        if (!br.eof() && br.read_bits(1)) { // bitstream_restriction_flag
            (void)br.read_bits(1); // motion_vectors_over_pic_boundaries_flag
            (void)br.read_ue();    // max_bytes_per_pic_denom
            (void)br.read_ue();    // max_bits_per_mb_denom
            (void)br.read_ue();    // log2_max_mv_length_horizontal
            (void)br.read_ue();    // log2_max_mv_length_vertical
            info.max_num_reorder_frames = br.read_ue();
            info.has_reorder_hint = true;
        }
    }

    if (!info.has_reorder_hint) {
        // Baseline (66) or POC type 2 has no B-frame reordering; Main/High default to <= 2
        if (info.profile_idc == 66 || info.pic_order_cnt_type == 2) {
            info.max_num_reorder_frames = 0;
        } else {
            info.max_num_reorder_frames = std::min<uint32_t>(max_num_ref_frames, 2u);
        }
    }
    if (info.max_num_reorder_frames > 4u) info.max_num_reorder_frames = 4u;

    info.valid = true;
    out = info;
    return true;
}

struct H264SlicePoc {
    bool     valid = false;
    bool     is_idr = false;
    uint32_t slice_type = 0; // mod 5: 0=P, 1=B, 2=I
    uint32_t poc_lsb = 0;
};

static bool parse_h264_slice_poc(const uint8_t *nal, size_t len, const H264SpsInfo &sps, H264SlicePoc &out) {
    if (!sps.valid || len < 2) return false;
    uint8_t nal_type = nal[0] & 0x1Fu;
    if (nal_type < 1 || nal_type > 5) return false;

    std::vector<uint8_t> rbsp = nal_to_rbsp(nal, len, 32);
    if (rbsp.empty()) return false;

    BitReader br{rbsp.data(), rbsp.size(), 0};
    (void)br.read_ue(); // first_mb_in_slice
    uint32_t st = br.read_ue() % 5u;
    (void)br.read_ue(); // pic_parameter_set_id
    if (sps.separate_colour_plane) (void)br.read_bits(2);
    (void)br.read_bits(static_cast<int>(sps.log2_max_frame_num)); // frame_num
    if (!sps.frame_mbs_only) {
        if (br.read_bits(1)) (void)br.read_bits(1);
    }
    bool is_idr = (nal_type == 5);
    if (is_idr) {
        (void)br.read_ue(); // idr_pic_id
    }
    uint32_t poc_lsb = 0;
    if (sps.pic_order_cnt_type == 0) {
        poc_lsb = br.read_bits(static_cast<int>(sps.log2_max_poc_lsb));
    }

    out.valid = true;
    out.is_idr = is_idr;
    out.slice_type = st;
    out.poc_lsb = poc_lsb;
    return true;
}

// Parse Annex-B (00 00 01 / 00 00 00 01) OR 4-byte big-endian length-prefixed AVCC NAL units.
struct NalSpan {
    const uint8_t *ptr;
    size_t         len;
};

static void split_h264_nals(const uint8_t *buf, size_t size, std::vector<NalSpan> &out) {
    out.clear();
    if (!buf || size < 3) return;

    auto find_start_code = [&](size_t pos, size_t &sc_len) -> size_t {
        for (size_t i = pos; i + 2 < size; i++) {
            if (buf[i] == 0 && buf[i + 1] == 0) {
                if (buf[i + 2] == 1) {
                    sc_len = 3;
                    return i;
                }
                if (i + 3 < size && buf[i + 2] == 0 && buf[i + 3] == 1) {
                    sc_len = 4;
                    return i;
                }
            }
        }
        sc_len = 0;
        return size;
    };

    // Check if Annex-B formatted (starts with 00 00 01 or 00 00 00 01)
    size_t first_sc_len = 0;
    size_t first_sc = find_start_code(0, first_sc_len);
    if (first_sc == 0 && first_sc_len > 0) {
        size_t pos = first_sc_len;
        while (pos < size) {
            size_t next_sc_len = 0;
            size_t next_sc = find_start_code(pos, next_sc_len);
            size_t nal_end = next_sc;
            while (nal_end > pos && buf[nal_end - 1] == 0) nal_end--;
            if (nal_end > pos) {
                out.push_back({buf + pos, nal_end - pos});
            }
            if (next_sc >= size) break;
            pos = next_sc + next_sc_len;
        }
        return;
    }

    // Fallback: check 4-byte big-endian AVCC framing
    size_t pos = 0;
    bool avcc_ok = (size >= 5);
    std::vector<NalSpan> avcc_nals;
    while (avcc_ok && pos + 4 <= size) {
        uint32_t nlen = (static_cast<uint32_t>(buf[pos]) << 24) |
                        (static_cast<uint32_t>(buf[pos + 1]) << 16) |
                        (static_cast<uint32_t>(buf[pos + 2]) << 8) |
                        static_cast<uint32_t>(buf[pos + 3]);
        pos += 4;
        if (nlen == 0 || pos + nlen > size) {
            avcc_ok = false;
            break;
        }
        avcc_nals.push_back({buf + pos, nlen});
        pos += nlen;
    }
    if (avcc_ok && pos == size && !avcc_nals.empty()) {
        out = std::move(avcc_nals);
        return;
    }

    // Last resort: search for any embedded Annex-B start codes
    if (first_sc < size && first_sc_len > 0) {
        size_t cur = first_sc + first_sc_len;
        while (cur < size) {
            size_t next_sc_len = 0;
            size_t next_sc = find_start_code(cur, next_sc_len);
            size_t nal_end = next_sc;
            while (nal_end > cur && buf[nal_end - 1] == 0) nal_end--;
            if (nal_end > cur) {
                out.push_back({buf + cur, nal_end - cur});
            }
            if (next_sc >= size) break;
            cur = next_sc + next_sc_len;
        }
    }
}

} // namespace

// =========================================================================
// 6. IMFTransform (CLSID_CMSH264DecoderMFT) backed by VideoToolbox
// =========================================================================

struct DecodedNV12Frame {
    uint32_t             width = 0;
    uint32_t             height = 0;
    uint64_t             idr_epoch = 0;
    int64_t              poc = 0;
    uint64_t             decode_seq = 0;
    std::vector<uint8_t> nv12; // tightly packed: Y (w*h) followed by interleaved UV (w*(h/2))
};

struct VtFrameMeta {
    uint64_t idr_epoch = 0;
    int64_t  poc = 0;
    uint64_t decode_seq = 0;
};

static constexpr size_t BO3_VT_META_RING_SIZE = 64u;

struct Bo3MFH264Transform {
    Bo3ComBase               com;
    std::mutex               mtx;
    Bo3MFAttributes         *mft_attrs = nullptr;
    Bo3MFMediaType          *input_type = nullptr;
    Bo3MFMediaType          *output_type = nullptr;

    // H.264 parameter sets & SPS metadata
    std::vector<uint8_t>     sps;
    std::vector<uint8_t>     pps;
    H264SpsInfo              sps_info{};
    bool                     params_dirty = false;

    // VideoToolbox session state
    CMVideoFormatDescriptionRef fmt_desc = nullptr;
    VTDecompressionSessionRef   vt_session = nullptr;
    bool                        vt_failed_permanently = false;
    uint32_t                    width = 0;
    uint32_t                    height = 0;
    bool                        stream_change_pending = false;
    bool                        stream_change_notified = false;
    bool                        draining = false;

    // POC tracking & callback->reorder handoff (lock order: mtx -> cb_mtx)
    uint64_t                    idr_epoch = 0;
    int32_t                     prev_poc_msb = 0;
    int32_t                     prev_poc_lsb = 0;
    uint64_t                    decode_seq = 0;
    VtFrameMeta                 meta_ring[BO3_VT_META_RING_SIZE];
    std::mutex                  cb_mtx;
    std::vector<DecodedNV12Frame> cb_frames;
    std::vector<DecodedNV12Frame> reorder_buf;

    // Diagnostics
    uint64_t                    frames_in = 0;
    uint64_t                    frames_out = 0;
    std::atomic<uint32_t>       vt_err_count{0};
};
static_assert(offsetof(Bo3MFH264Transform, com) == 0, "Bo3ComBase must be at offset 0");

static void h264_vt_output_callback(
    void *decompressionOutputRefCon,
    void *sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration)
{
    (void)infoFlags;
    (void)presentationTimeStamp;
    (void)presentationDuration;

    if (!decompressionOutputRefCon) return;
    auto *mft = static_cast<Bo3MFH264Transform *>(decompressionOutputRefCon);
    if (status != noErr || !imageBuffer) {
        if (status != noErr && mft->vt_err_count++ < 8) {
            fprintf(stderr, "[media_avf] VT output callback error: %d\n", static_cast<int>(status));
            fflush(stderr);
        }
        return;
    }
    uint64_t seq = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(sourceFrameRefCon));
    CVPixelBufferRef pb = imageBuffer;

    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return;
    }

    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    size_t uv_h = (h + 1u) / 2u;

    DecodedNV12Frame frame;
    frame.width = static_cast<uint32_t>(w);
    frame.height = static_cast<uint32_t>(h);
    frame.nv12.resize(w * h + w * uv_h);

    const uint8_t *src_y = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pb, 0));
    size_t src_y_stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    const uint8_t *src_uv = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pb, 1));
    size_t src_uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);

    if (src_y && src_uv && src_y_stride >= w && src_uv_stride >= w) {
        uint8_t *dst_y = frame.nv12.data();
        if (src_y_stride == w) {
            memcpy(dst_y, src_y, w * h);
        } else {
            for (size_t row = 0; row < h; row++) {
                memcpy(dst_y + row * w, src_y + row * src_y_stride, w);
            }
        }

        uint8_t *dst_uv = dst_y + w * h;
        if (src_uv_stride == w) {
            memcpy(dst_uv, src_uv, w * uv_h);
        } else {
            for (size_t row = 0; row < uv_h; row++) {
                memcpy(dst_uv + row * w, src_uv + row * src_uv_stride, w);
            }
        }

        std::lock_guard<std::mutex> lk(mft->cb_mtx);
        const VtFrameMeta &meta = mft->meta_ring[seq % BO3_VT_META_RING_SIZE];
        frame.idr_epoch = meta.idr_epoch;
        frame.poc = meta.poc;
        frame.decode_seq = meta.decode_seq;
        if (mft->cb_frames.size() >= 16u) {
            mft->cb_frames.erase(mft->cb_frames.begin());
        }
        mft->cb_frames.push_back(std::move(frame));
    }

    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

static void h264_drain_cb_frames_locked(Bo3MFH264Transform *mft) {
    std::vector<DecodedNV12Frame> incoming;
    {
        std::lock_guard<std::mutex> lk(mft->cb_mtx);
        incoming.swap(mft->cb_frames);
    }
    for (auto &f : incoming) {
        if (mft->reorder_buf.size() >= 16u) {
            mft->reorder_buf.erase(mft->reorder_buf.begin());
        }
        mft->reorder_buf.push_back(std::move(f));
    }
}

static void h264_teardown_vt_locked(Bo3MFH264Transform *mft) {
    if (mft->vt_session) {
        VTDecompressionSessionWaitForAsynchronousFrames(mft->vt_session);
        VTDecompressionSessionInvalidate(mft->vt_session);
        CFRelease(mft->vt_session);
        mft->vt_session = nullptr;
    }
    if (mft->fmt_desc) {
        CFRelease(mft->fmt_desc);
        mft->fmt_desc = nullptr;
    }
}

static void h264_reset_stream_locked(Bo3MFH264Transform *mft, bool full_reset) {
    h264_teardown_vt_locked(mft);
    {
        std::lock_guard<std::mutex> lk(mft->cb_mtx);
        mft->cb_frames.clear();
    }
    mft->reorder_buf.clear();
    mft->draining = false;
    mft->vt_failed_permanently = false;
    mft->idr_epoch = 0;
    mft->prev_poc_msb = 0;
    mft->prev_poc_lsb = 0;
    mft->decode_seq = 0;
    if (full_reset) {
        mft->sps.clear();
        mft->pps.clear();
        mft->sps_info = H264SpsInfo{};
        mft->params_dirty = false;
        mft->width = 0;
        mft->height = 0;
        mft->stream_change_pending = false;
        mft->stream_change_notified = false;
        if (mft->output_type) {
            mft->output_type->attrs.com.release();
            mft->output_type = nullptr;
        }
    }
}

static void h264_refresh_output_type_locked(Bo3MFH264Transform *mft) {
    if (mft->output_type) {
        mft->output_type->attrs.com.release();
        mft->output_type = nullptr;
    }
    Bo3MFMediaType *mt = mf_media_type_create();
    mt->attrs.set_guid(&BO3_MF_MT_MAJOR_TYPE, &BO3_MFMediaType_Video);
    mt->attrs.set_guid(&BO3_MF_MT_SUBTYPE, &BO3_MFVideoFormat_NV12);
    if (mft->width > 0 && mft->height > 0) {
        uint64_t packed = (static_cast<uint64_t>(mft->width) << 32) | static_cast<uint64_t>(mft->height);
        mt->attrs.set_u64(&BO3_MF_MT_FRAME_SIZE, packed);
        Bo3MFVideoArea area{};
        area.OffsetX = {0, 0};
        area.OffsetY = {0, 0};
        area.cx = static_cast<int32_t>(mft->width);
        area.cy = static_cast<int32_t>(mft->height);
        mt->attrs.set_blob(&BO3_MF_MT_MINIMUM_DISPLAY_APERTURE,
                           reinterpret_cast<const uint8_t *>(&area),
                           sizeof(area));
    }
    mft->output_type = mt;
}

static bool h264_ensure_vt_session_locked(Bo3MFH264Transform *mft) {
    if (mft->vt_session && !mft->params_dirty) return true;
    if (mft->vt_failed_permanently) return false;
    if (mft->sps.empty() || mft->pps.empty()) return false;

    h264_teardown_vt_locked(mft);
    mft->params_dirty = false;

    const uint8_t *param_ptrs[2] = { mft->sps.data(), mft->pps.data() };
    const size_t   param_sizes[2] = { mft->sps.size(), mft->pps.size() };

    CMVideoFormatDescriptionRef fmt = nullptr;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, param_ptrs, param_sizes, 4, &fmt);
    if (st != noErr || !fmt) {
        fprintf(stderr, "[media_avf] CMVideoFormatDescriptionCreateFromH264ParameterSets failed: %d\n",
                static_cast<int>(st));
        mft->vt_failed_permanently = true;
        return false;
    }

    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);
    if (dims.width <= 0 || dims.height <= 0) {
        CFRelease(fmt);
        mft->vt_failed_permanently = true;
        return false;
    }

    uint32_t new_w = static_cast<uint32_t>(dims.width);
    uint32_t new_h = static_cast<uint32_t>(dims.height);

    // Destination CVPixelBuffer attributes: NV12 ('420v') + IOSurface for hardware decode
    CFMutableDictionaryRef dst_attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    uint32_t pix_fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef cf_fmt = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pix_fmt);
    CFNumberRef cf_w   = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &dims.width);
    CFNumberRef cf_h   = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &dims.height);
    CFDictionaryRef empty_dict = CFDictionaryCreate(
        kCFAllocatorDefault, nullptr, nullptr, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CFDictionarySetValue(dst_attrs, kCVPixelBufferPixelFormatTypeKey, cf_fmt);
    CFDictionarySetValue(dst_attrs, kCVPixelBufferWidthKey, cf_w);
    CFDictionarySetValue(dst_attrs, kCVPixelBufferHeightKey, cf_h);
    CFDictionarySetValue(dst_attrs, kCVPixelBufferIOSurfacePropertiesKey, empty_dict);

    CFRelease(cf_fmt);
    CFRelease(cf_w);
    CFRelease(cf_h);
    CFRelease(empty_dict);

    VTDecompressionOutputCallbackRecord cb{};
    cb.decompressionOutputCallback = h264_vt_output_callback;
    cb.decompressionOutputRefCon = mft;

    VTDecompressionSessionRef session = nullptr;
    st = VTDecompressionSessionCreate(
        kCFAllocatorDefault, fmt, nullptr, dst_attrs, &cb, &session);
    CFRelease(dst_attrs);

    if (st != noErr || !session) {
        fprintf(stderr, "[media_avf] VTDecompressionSessionCreate (%ux%u) failed: %d\n",
                new_w, new_h, static_cast<int>(st));
        CFRelease(fmt);
        mft->vt_failed_permanently = true;
        return false;
    }

    mft->fmt_desc = fmt;
    mft->vt_session = session;
    mft->vt_failed_permanently = false;

    if (!mft->stream_change_notified || mft->width != new_w || mft->height != new_h) {
        // Discard any frames from a previous format generation so old NV12 planes are never
        // delivered under the newly published dimensions.
        if (mft->width != 0 && (mft->width != new_w || mft->height != new_h)) {
            {
                std::lock_guard<std::mutex> clk(mft->cb_mtx);
                mft->cb_frames.clear();
            }
            mft->reorder_buf.clear();
        }
        mft->width = new_w;
        mft->height = new_h;
        mft->stream_change_pending = true;
        mft->stream_change_notified = true;
        h264_refresh_output_type_locked(mft);
        fprintf(stderr, "[media_avf] VideoToolbox H.264 session ready: %ux%u NV12 (reorder_depth=%u)\n",
                new_w, new_h, mft->sps_info.max_num_reorder_frames);
        fflush(stderr);
    }
    return true;
}

static uint32_t mf_transform_qi(Bo3ComBase *self, const Bo3GUID *riid, void **ppv) {
    if (!ppv) return BO3_E_POINTER;
    if (bo3_guid_eq(riid, &BO3_IID_IUnknown) ||
        bo3_guid_eq(riid, &BO3_IID_IMFTransform) ||
        bo3_guid_eq(riid, &BO3_CLSID_CMSH264DecoderMFT)) {
        self->add_ref();
        *ppv = self;
        return BO3_S_OK;
    }
    *ppv = nullptr;
    return BO3_E_NOINTERFACE;
}

static void mf_transform_destroy(Bo3ComBase *self) {
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(self);
    {
        std::lock_guard<std::mutex> lk(mft->mtx);
        h264_reset_stream_locked(mft, true);
        if (mft->input_type) {
            mft->input_type->attrs.com.release();
            mft->input_type = nullptr;
        }
        if (mft->mft_attrs) {
            mft->mft_attrs->com.release();
            mft->mft_attrs = nullptr;
        }
    }
    delete mft;
}

static Bo3MFH264Transform *mf_h264_transform_create() {
    bo3_media_avf_init();
    auto *mft = new Bo3MFH264Transform();
    mft->com.init_com(g_vt_transform, "IMFTransform(H264_VT)", mf_transform_qi, mf_transform_destroy);
    mft->mft_attrs = mf_attr_create();
    return mft;
}

// Slot 3 (+0x18): GetStreamLimits
static SHIM_DEF(mft_get_stream_limits) {
    SHIM_UNUSED_ALL();
    if (rsi) *reinterpret_cast<uint32_t *>(rsi) = 1;
    if (rdx) *reinterpret_cast<uint32_t *>(rdx) = 1;
    if (rcx) *reinterpret_cast<uint32_t *>(rcx) = 1;
    if (r8)  *reinterpret_cast<uint32_t *>(r8)  = 1;
    return ret_u64(BO3_S_OK);
}

// Slot 4 (+0x20): GetStreamCount
static SHIM_DEF(mft_get_stream_count) {
    SHIM_UNUSED_ALL();
    if (rsi) *reinterpret_cast<uint32_t *>(rsi) = 1;
    if (rdx) *reinterpret_cast<uint32_t *>(rdx) = 1;
    return ret_u64(BO3_S_OK);
}

// Slot 5 (+0x28): GetStreamIDs
static SHIM_DEF(mft_get_stream_ids) {
    SHIM_UNUSED_ALL();
    return ret_u64(BO3_E_NOTIMPL);
}

// Slot 6 (+0x30): GetInputStreamInfo(DWORD dwInputStreamID, MFT_INPUT_STREAM_INFO *pStreamInfo)
static SHIM_DEF(mft_get_input_stream_info) {
    SHIM_UNUSED_ALL();
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    auto *info = reinterpret_cast<Bo3MFT_INPUT_STREAM_INFO *>(rdx);
    if (!info) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);
    memset(info, 0, sizeof(*info));
    info->dwFlags = BO3_MFT_STREAM_FLAGS_DEFAULT;
    info->cbSize = 0x1000u;
    info->cbAlignment = 0;
    return ret_u64(BO3_S_OK);
}

// Slot 7 (+0x38): GetOutputStreamInfo(DWORD dwOutputStreamID, MFT_OUTPUT_STREAM_INFO *pStreamInfo)
static SHIM_DEF(mft_get_output_stream_info) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    auto *info = reinterpret_cast<Bo3MFT_OUTPUT_STREAM_INFO *>(rdx);
    if (!mft || !info) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);

    std::lock_guard<std::mutex> lk(mft->mtx);
    uint32_t nv12_sz = 0;
    if (mft->width > 0 && mft->height > 0) {
        nv12_sz = mft->width * mft->height + mft->width * ((mft->height + 1u) / 2u);
    }
    info->dwFlags = BO3_MFT_STREAM_FLAGS_DEFAULT;
    info->cbSize = std::max(BO3_MFT_DEFAULT_OUTPUT_SIZE, nv12_sz);
    info->cbAlignment = 0;
    return ret_u64(BO3_S_OK);
}

// Slot 8 (+0x40): GetAttributes(IMFAttributes **pAttributes)
static SHIM_DEF(mft_get_attributes) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    auto **pp = reinterpret_cast<Bo3MFAttributes **>(rsi);
    if (!mft || !pp) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(mft->mtx);
    mft->mft_attrs->com.add_ref();
    *pp = mft->mft_attrs;
    return ret_u64(BO3_S_OK);
}

// Slot 9..12: Stream attributes / dynamic stream add-delete -> E_NOTIMPL
static SHIM_DEF(mft_not_impl) {
    SHIM_UNUSED_ALL();
    return ret_u64(BO3_E_NOTIMPL);
}

// Slot 13 (+0x68): GetInputAvailableType(DWORD dwInputStreamID, DWORD dwTypeIndex, IMFMediaType **ppType)
static SHIM_DEF(mft_get_input_available_type) {
    SHIM_UNUSED_ALL();
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    uint32_t type_idx = static_cast<uint32_t>(rdx);
    auto **pp = reinterpret_cast<Bo3MFMediaType **>(rcx);
    if (!pp) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);
    if (type_idx != 0) return ret_u64(BO3_MF_E_NO_MORE_TYPES);
    Bo3MFMediaType *mt = mf_media_type_create();
    mt->attrs.set_guid(&BO3_MF_MT_MAJOR_TYPE, &BO3_MFMediaType_Video);
    mt->attrs.set_guid(&BO3_MF_MT_SUBTYPE, &BO3_MFVideoFormat_H264);
    *pp = mt;
    return ret_u64(BO3_S_OK);
}

// Slot 14 (+0x70): GetOutputAvailableType(DWORD dwOutputStreamID, DWORD dwTypeIndex, IMFMediaType **ppType)
static SHIM_DEF(mft_get_output_available_type) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    uint32_t type_idx = static_cast<uint32_t>(rdx);
    auto **pp = reinterpret_cast<Bo3MFMediaType **>(rcx);
    if (!mft || !pp) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);
    if (type_idx != 0) return ret_u64(BO3_MF_E_NO_MORE_TYPES);

    std::lock_guard<std::mutex> lk(mft->mtx);
    // Return a fresh IMFMediaType copy so guest mutations (e.g. SetGUID before SetOutputType)
    // never mutate the decoder's internal output_type object.
    Bo3MFMediaType *mt = mf_media_type_create();
    mt->attrs.set_guid(&BO3_MF_MT_MAJOR_TYPE, &BO3_MFMediaType_Video);
    mt->attrs.set_guid(&BO3_MF_MT_SUBTYPE, &BO3_MFVideoFormat_NV12);
    if (mft->width > 0 && mft->height > 0) {
        uint64_t packed = (static_cast<uint64_t>(mft->width) << 32) | static_cast<uint64_t>(mft->height);
        mt->attrs.set_u64(&BO3_MF_MT_FRAME_SIZE, packed);
        Bo3MFVideoArea area{};
        area.OffsetX = {0, 0};
        area.OffsetY = {0, 0};
        area.cx = static_cast<int32_t>(mft->width);
        area.cy = static_cast<int32_t>(mft->height);
        mt->attrs.set_blob(&BO3_MF_MT_MINIMUM_DISPLAY_APERTURE,
                           reinterpret_cast<const uint8_t *>(&area),
                           sizeof(area));
    }
    *pp = mt;
    return ret_u64(BO3_S_OK);
}

// Slot 15 (+0x78): SetInputType(DWORD dwInputStreamID, IMFMediaType *pType, DWORD dwFlags)
static SHIM_DEF(mft_set_input_type) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    auto *mt = reinterpret_cast<Bo3MFMediaType *>(rdx);
    uint32_t flags = static_cast<uint32_t>(rcx);
    if (!mft) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);

    if (mt) {
        Bo3GUID sub{};
        if (mt->attrs.get_guid(&BO3_MF_MT_SUBTYPE, &sub) && !bo3_guid_eq(&sub, &BO3_MFVideoFormat_H264)) {
            return ret_u64(BO3_MF_E_INVALIDTYPE);
        }
    }
    if ((flags & 1u) != 0) { // MFT_SET_TYPE_TEST_ONLY
        return ret_u64(BO3_S_OK);
    }

    std::lock_guard<std::mutex> lk(mft->mtx);
    if (mft->input_type) mft->input_type->attrs.com.release();
    mft->input_type = mt;
    if (mft->input_type) mft->input_type->attrs.com.add_ref();
    // Re-arm stream-change notification per movie open without discarding SPS/PPS or VT session
    // (guards against late deferred NOTIFY_END_STREAMING from the previous movie on the main thread).
    mft->draining = false;
    mft->vt_failed_permanently = false;
    mft->stream_change_notified = false;
    if (mft->width > 0 && mft->height > 0) {
        mft->stream_change_pending = true;
    }
    return ret_u64(BO3_S_OK);
}

// Slot 16 (+0x80): SetOutputType(DWORD dwOutputStreamID, IMFMediaType *pType, DWORD dwFlags)
static SHIM_DEF(mft_set_output_type) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    auto *mt = reinterpret_cast<Bo3MFMediaType *>(rdx);
    uint32_t flags = static_cast<uint32_t>(rcx);
    if (!mft) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);

    if (mt) {
        Bo3GUID sub{};
        if (mt->attrs.get_guid(&BO3_MF_MT_SUBTYPE, &sub) && !bo3_guid_eq(&sub, &BO3_MFVideoFormat_NV12)) {
            return ret_u64(BO3_MF_E_INVALIDTYPE);
        }
    }
    if ((flags & 1u) != 0) { // MFT_SET_TYPE_TEST_ONLY
        return ret_u64(BO3_S_OK);
    }

    std::lock_guard<std::mutex> lk(mft->mtx);
    if (mt != mft->output_type) {
        if (mft->output_type) mft->output_type->attrs.com.release();
        mft->output_type = mt;
        if (mft->output_type) mft->output_type->attrs.com.add_ref();
    }
    mft->stream_change_pending = false;
    return ret_u64(BO3_S_OK);
}

// Slot 17 (+0x88): GetInputCurrentType
static SHIM_DEF(mft_get_input_current_type) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    auto **pp = reinterpret_cast<Bo3MFMediaType **>(rdx);
    if (!mft || !pp) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);
    std::lock_guard<std::mutex> lk(mft->mtx);
    if (!mft->input_type) return ret_u64(BO3_MF_E_TRANSFORM_TYPE_NOT_SET);
    mft->input_type->attrs.com.add_ref();
    *pp = mft->input_type;
    return ret_u64(BO3_S_OK);
}

// Slot 18 (+0x90): GetOutputCurrentType
static SHIM_DEF(mft_get_output_current_type) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    auto **pp = reinterpret_cast<Bo3MFMediaType **>(rdx);
    if (!mft || !pp) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);
    std::lock_guard<std::mutex> lk(mft->mtx);
    if (!mft->output_type) return ret_u64(BO3_MF_E_TRANSFORM_TYPE_NOT_SET);
    mft->output_type->attrs.com.add_ref();
    *pp = mft->output_type;
    return ret_u64(BO3_S_OK);
}

// Slot 19 (+0x98): GetInputStatus
static SHIM_DEF(mft_get_input_status) {
    SHIM_UNUSED_ALL();
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    auto *flags = reinterpret_cast<uint32_t *>(rdx);
    if (!flags) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);
    *flags = 1u; // MFT_INPUT_STATUS_ACCEPT_DATA
    return ret_u64(BO3_S_OK);
}

// Slot 20 (+0xa0): GetOutputStatus
static SHIM_DEF(mft_get_output_status) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    auto *flags = reinterpret_cast<uint32_t *>(rsi);
    if (!mft || !flags) return ret_u64(BO3_E_POINTER);
    std::lock_guard<std::mutex> lk(mft->mtx);
    uint32_t depth = mft->draining ? 0u : mft->sps_info.max_num_reorder_frames;
    *flags = (mft->reorder_buf.size() > depth) ? 1u : 0u;
    return ret_u64(BO3_S_OK);
}

// Slot 21 (+0xa8): SetOutputBounds / Slot 22 (+0xb0): ProcessEvent
static SHIM_DEF(mft_ok_noop) {
    SHIM_UNUSED_ALL();
    return ret_u64(BO3_S_OK);
}

// Slot 23 (+0xb8): ProcessMessage(MFT_MESSAGE_TYPE eMessage, ULONG_PTR ulParam)
static SHIM_DEF(mft_process_message) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    uint32_t msg = static_cast<uint32_t>(rsi);
    if (!mft) return ret_u64(BO3_E_POINTER);

    std::lock_guard<std::mutex> lk(mft->mtx);
    switch (msg) {
        case BO3_MFT_MESSAGE_COMMAND_FLUSH:
            if (mft->vt_session) {
                VTDecompressionSessionWaitForAsynchronousFrames(mft->vt_session);
            }
            {
                std::lock_guard<std::mutex> clk(mft->cb_mtx);
                mft->cb_frames.clear();
            }
            mft->reorder_buf.clear();
            mft->draining = false;
            mft->prev_poc_msb = 0;
            mft->prev_poc_lsb = 0;
            break;

        case BO3_MFT_MESSAGE_COMMAND_DRAIN:
        case BO3_MFT_MESSAGE_NOTIFY_END_OF_STREAM:
            if (mft->vt_session) {
                VTDecompressionSessionWaitForAsynchronousFrames(mft->vt_session);
            }
            h264_drain_cb_frames_locked(mft);
            mft->draining = true;
            break;

        case BO3_MFT_MESSAGE_NOTIFY_BEGIN_STREAMING:
        case BO3_MFT_MESSAGE_NOTIFY_START_OF_STREAM:
            mft->draining = false;
            mft->vt_failed_permanently = false;
            break;

        case BO3_MFT_MESSAGE_NOTIFY_END_STREAMING:
            // Preserve SPS/PPS, VTDecompressionSession, and output_type (matches Windows MF MFT):
            // BO3 sends deferred FLUSH/END_OF_STREAM/END_STREAMING for movie A from the main thread
            // AFTER movie B has already opened and fed its SPS/PPS on the stream thread!
            mft->draining = false;
            break;

        default:
            break;
    }
    return ret_u64(BO3_S_OK);
}

// Slot 24 (+0xc0): ProcessInput(DWORD dwInputStreamID, IMFSample *pSample, DWORD dwFlags)
static SHIM_DEF(mft_process_input) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    uint32_t stream_id = static_cast<uint32_t>(rsi);
    auto *sample = reinterpret_cast<Bo3MFSample *>(rdx);
    if (!mft || !sample) return ret_u64(BO3_E_POINTER);
    if (stream_id != 0) return ret_u64(BO3_MF_E_INVALIDSTREAMNUMBER);

    // Gather all bytes from the sample's media buffers
    std::vector<uint8_t> raw_in;
    {
        std::lock_guard<std::mutex> slk(sample->sample_mtx);
        for (auto *buf : sample->buffers) {
            if (!buf) continue;
            std::lock_guard<std::mutex> blk(buf->mtx);
            uint32_t len = buf->cur_len;
            if (len > 0 && buf->data) {
                raw_in.insert(raw_in.end(), buf->data, buf->data + len);
            }
        }
    }
    if (raw_in.empty()) return ret_u64(BO3_S_OK);

    std::lock_guard<std::mutex> lk(mft->mtx);
    mft->draining = false;

    std::vector<NalSpan> nals;
    split_h264_nals(raw_in.data(), raw_in.size(), nals);
    if (nals.empty()) return ret_u64(BO3_S_OK);

    // Extract SPS/PPS and assemble AVCC access unit for VCL slices
    std::vector<uint8_t> avcc_au;
    avcc_au.reserve(raw_in.size() + nals.size() * 4u);

    H264SlicePoc first_slice{};
    for (const auto &nal : nals) {
        if (nal.len == 0) continue;
        uint8_t nal_type = nal.ptr[0] & 0x1Fu;
        if (nal_type == 7) { // SPS
            if (mft->sps.size() != nal.len || memcmp(mft->sps.data(), nal.ptr, nal.len) != 0) {
                mft->sps.assign(nal.ptr, nal.ptr + nal.len);
                parse_h264_sps(nal.ptr, nal.len, mft->sps_info);
                mft->params_dirty = true;
            }
        } else if (nal_type == 8) { // PPS
            if (mft->pps.size() != nal.len || memcmp(mft->pps.data(), nal.ptr, nal.len) != 0) {
                mft->pps.assign(nal.ptr, nal.ptr + nal.len);
                mft->params_dirty = true;
            }
        } else if (nal_type >= 1 && nal_type <= 5) { // VCL slice NAL unit
            if (!first_slice.valid) {
                parse_h264_slice_poc(nal.ptr, nal.len, mft->sps_info, first_slice);
            }
            uint32_t nlen = static_cast<uint32_t>(nal.len);
            avcc_au.push_back(static_cast<uint8_t>((nlen >> 24) & 0xFFu));
            avcc_au.push_back(static_cast<uint8_t>((nlen >> 16) & 0xFFu));
            avcc_au.push_back(static_cast<uint8_t>((nlen >> 8)  & 0xFFu));
            avcc_au.push_back(static_cast<uint8_t>(nlen & 0xFFu));
            avcc_au.insert(avcc_au.end(), nal.ptr, nal.ptr + nal.len);
        }
        // Skip AUD (9), Filler (12), SEI (6) — VideoToolbox does not need them
    }

    // Create or recreate VTDecompressionSession whenever SPS + PPS are ready
    if (!mft->sps.empty() && !mft->pps.empty()) {
        if (!h264_ensure_vt_session_locked(mft)) {
            return ret_u64(BO3_S_OK); // ProcessOutput will report E_FAIL cleanly if permanently failed
        }
    }

    if (avcc_au.empty() || !mft->vt_session || !mft->fmt_desc) {
        return ret_u64(BO3_S_OK);
    }

    // Compute display-order (idr_epoch, POC) per H.264 §8.2.1.1
    int64_t computed_poc = static_cast<int64_t>(mft->decode_seq);
    if (first_slice.valid && mft->sps_info.pic_order_cnt_type == 0) {
        int32_t max_poc_lsb = 1 << mft->sps_info.log2_max_poc_lsb;
        int32_t lsb = static_cast<int32_t>(first_slice.poc_lsb);
        int32_t msb = mft->prev_poc_msb;
        if (first_slice.is_idr) {
            mft->idr_epoch++;
            msb = 0;
            mft->prev_poc_msb = 0;
            mft->prev_poc_lsb = lsb;
        } else {
            if (lsb < mft->prev_poc_lsb && (mft->prev_poc_lsb - lsb) >= (max_poc_lsb / 2)) {
                msb = mft->prev_poc_msb + max_poc_lsb;
            } else if (lsb > mft->prev_poc_lsb && (lsb - mft->prev_poc_lsb) > (max_poc_lsb / 2)) {
                msb = mft->prev_poc_msb - max_poc_lsb;
            }
            // Only reference pictures update prev_poc_msb/lsb (nal_ref_idc != 0)
            if ((avcc_au[4] & 0x60u) != 0) {
                mft->prev_poc_msb = msb;
                mft->prev_poc_lsb = lsb;
            }
        }
        computed_poc = static_cast<int64_t>(msb) + static_cast<int64_t>(lsb);
    } else if (first_slice.valid && first_slice.is_idr) {
        mft->idr_epoch++;
    }

    // Wrap AVCC access unit into an owned CMBlockBuffer + CMSampleBuffer
    CMBlockBufferRef block_buf = nullptr;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        nullptr,
        avcc_au.size(),
        kCFAllocatorDefault,
        nullptr,
        0,
        avcc_au.size(),
        0,
        &block_buf);
    if (st != noErr || !block_buf) {
        return ret_u64(BO3_S_OK);
    }
    st = CMBlockBufferReplaceDataBytes(avcc_au.data(), block_buf, 0, avcc_au.size());
    if (st != noErr) {
        CFRelease(block_buf);
        return ret_u64(BO3_S_OK);
    }

    const size_t sample_size = avcc_au.size();
    CMSampleBufferRef cm_sample = nullptr;
    st = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        block_buf,
        mft->fmt_desc,
        1,
        0, nullptr,
        1, &sample_size,
        &cm_sample);
    CFRelease(block_buf);
    if (st != noErr || !cm_sample) {
        return ret_u64(BO3_S_OK);
    }

    uint64_t seq = mft->decode_seq++;
    {
        std::lock_guard<std::mutex> clk(mft->cb_mtx);
        mft->meta_ring[seq % BO3_VT_META_RING_SIZE] = VtFrameMeta{mft->idr_epoch, computed_poc, seq};
    }

    VTDecodeInfoFlags info_flags = 0;
    // Flags = 0 => synchronous decode; callback pushes into mft->cb_frames under mft->cb_mtx.
    st = VTDecompressionSessionDecodeFrame(
        mft->vt_session, cm_sample, 0, reinterpret_cast<void *>(static_cast<uintptr_t>(seq)), &info_flags);
    CFRelease(cm_sample);

    mft->frames_in++;
    if (st != noErr) {
        if (st == kVTInvalidSessionErr || st == kVTVideoDecoderMalfunctionErr) {
            mft->params_dirty = true; // rebuild session from cached SPS/PPS on next packet
        }
        if (mft->vt_err_count++ < 8) {
            fprintf(stderr, "[media_avf] VTDecompressionSessionDecodeFrame failed: %d (frame %llu)\n",
                    static_cast<int>(st), static_cast<unsigned long long>(mft->frames_in));
            fflush(stderr);
        }
        return ret_u64(BO3_S_OK);
    }

    h264_drain_cb_frames_locked(mft);
    return ret_u64(BO3_S_OK);
}

// Slot 25 (+0xc8): ProcessOutput(DWORD dwFlags, DWORD cOutputBufferCount,
//                                MFT_OUTPUT_DATA_BUFFER *pOutputSamples, DWORD *pdwStatus)
static SHIM_DEF(mft_process_output) {
    SHIM_UNUSED_ALL();
    auto *mft = reinterpret_cast<Bo3MFH264Transform *>(rdi);
    uint32_t out_count = static_cast<uint32_t>(rdx);
    auto *out_samples = reinterpret_cast<Bo3MFT_OUTPUT_DATA_BUFFER *>(rcx);
    auto *pdw_status = reinterpret_cast<uint32_t *>(r8);

    if (pdw_status) *pdw_status = 0;
    if (!mft || !out_samples || out_count == 0) return ret_u64(BO3_E_INVALIDARG);

    std::lock_guard<std::mutex> lk(mft->mtx);
    h264_drain_cb_frames_locked(mft);

    if (mft->vt_failed_permanently) {
        return ret_u64(BO3_E_FAIL);
    }

    // Notify BO3 of resolved stream dimensions before delivering decoded frames
    if (mft->stream_change_pending) {
        mft->stream_change_pending = false;
        return ret_u64(BO3_MF_E_TRANSFORM_STREAM_CHANGE);
    }

    // Hold up to `reorder_depth` frames so B-frames are emitted in display (POC) order
    uint32_t reorder_depth = mft->draining ? 0u : mft->sps_info.max_num_reorder_frames;
    if (mft->reorder_buf.size() <= reorder_depth) {
        return ret_u64(BO3_MF_E_TRANSFORM_NEED_MORE_INPUT);
    }

    // Drop any stale-dimension frames defensively before delivering under current output_type
    while (!mft->reorder_buf.empty()) {
        auto it = std::min_element(
            mft->reorder_buf.begin(), mft->reorder_buf.end(),
            [](const DecodedNV12Frame &a, const DecodedNV12Frame &b) {
                if (a.idr_epoch != b.idr_epoch) return a.idr_epoch < b.idr_epoch;
                if (a.poc != b.poc) return a.poc < b.poc;
                return a.decode_seq < b.decode_seq;
            });
        if (it->width == mft->width && it->height == mft->height) break;
        mft->reorder_buf.erase(it);
    }
    if (mft->reorder_buf.size() <= reorder_depth) {
        return ret_u64(BO3_MF_E_TRANSFORM_NEED_MORE_INPUT);
    }

    // Pick frame with lowest (idr_epoch, poc, decode_seq)
    auto best_it = std::min_element(
        mft->reorder_buf.begin(), mft->reorder_buf.end(),
        [](const DecodedNV12Frame &a, const DecodedNV12Frame &b) {
            if (a.idr_epoch != b.idr_epoch) return a.idr_epoch < b.idr_epoch;
            if (a.poc != b.poc) return a.poc < b.poc;
            return a.decode_seq < b.decode_seq;
        });

    auto *out_sample = reinterpret_cast<Bo3MFSample *>(out_samples[0].pSample);
    if (!out_sample) return ret_u64(BO3_E_INVALIDARG);

    Bo3MFMediaBuffer *dst_buf = nullptr;
    {
        std::lock_guard<std::mutex> slk(out_sample->sample_mtx);
        if (!out_sample->buffers.empty()) {
            dst_buf = out_sample->buffers[0];
            if (dst_buf) dst_buf->com.add_ref();
        }
    }
    if (!dst_buf) return ret_u64(BO3_E_INVALIDARG);

    uint32_t hr = BO3_S_OK;
    {
        std::lock_guard<std::mutex> blk(dst_buf->mtx);
        size_t need = best_it->nv12.size();
        if (!dst_buf->data || need > static_cast<size_t>(dst_buf->max_len)) {
            hr = BO3_MF_E_BUFFERTOOSMALL;
        } else {
            memcpy(dst_buf->data, best_it->nv12.data(), need);
            dst_buf->cur_len = static_cast<uint32_t>(need);
        }
    }
    dst_buf->com.release();

    if (hr == BO3_S_OK) {
        mft->reorder_buf.erase(best_it);
        out_samples[0].dwStatus = 0;
        out_samples[0].pEvents = nullptr;
        mft->frames_out++;
    }
    return ret_u64(hr);
}

// =========================================================================
// 7. Initialization & Exported C Entrypoints
// =========================================================================

void bo3_media_avf_init(void) {
    static std::once_flag once;
    std::call_once(once, []() {
        // IMFMediaBuffer (8 slots)
        bo3_com_init_vtable(g_vt_media_buffer, 8, "IMFMediaBuffer");
        bo3_com_set_slot(g_vt_media_buffer, 3, mf_buffer_lock);
        bo3_com_set_slot(g_vt_media_buffer, 4, mf_buffer_unlock);
        bo3_com_set_slot(g_vt_media_buffer, 5, mf_buffer_get_cur_len);
        bo3_com_set_slot(g_vt_media_buffer, 6, mf_buffer_set_cur_len);
        bo3_com_set_slot(g_vt_media_buffer, 7, mf_buffer_get_max_len);

        // IMFAttributes (33 slots)
        bo3_com_init_vtable(g_vt_attributes, 33, "IMFAttributes");
        populate_attributes_vtable(g_vt_attributes);

        // IMFMediaType (38 slots: 0..32 IMFAttributes, 33..37 IMFMediaType)
        bo3_com_init_vtable(g_vt_media_type, 38, "IMFMediaType");
        populate_attributes_vtable(g_vt_media_type);
        bo3_com_set_slot(g_vt_media_type, 33, mf_media_type_get_major_type);
        bo3_com_set_slot(g_vt_media_type, 34, mf_media_type_is_compressed);

        // IMFSample (47 slots: 0..32 IMFAttributes, 33..46 IMFSample)
        bo3_com_init_vtable(g_vt_sample, 47, "IMFSample");
        populate_attributes_vtable(g_vt_sample);
        bo3_com_set_slot(g_vt_sample, 33, mf_sample_get_flags);
        bo3_com_set_slot(g_vt_sample, 34, mf_sample_set_flags);
        bo3_com_set_slot(g_vt_sample, 35, mf_sample_get_time);
        bo3_com_set_slot(g_vt_sample, 36, mf_sample_set_time);
        bo3_com_set_slot(g_vt_sample, 37, mf_sample_get_duration);
        bo3_com_set_slot(g_vt_sample, 38, mf_sample_set_duration);
        bo3_com_set_slot(g_vt_sample, 39, mf_sample_get_buffer_count);
        bo3_com_set_slot(g_vt_sample, 40, mf_sample_get_buffer_by_index);
        bo3_com_set_slot(g_vt_sample, 41, mf_sample_convert_to_contiguous);
        bo3_com_set_slot(g_vt_sample, 42, mf_sample_add_buffer);
        bo3_com_set_slot(g_vt_sample, 43, mf_sample_remove_buffer_by_index);
        bo3_com_set_slot(g_vt_sample, 44, mf_sample_remove_all_buffers);
        bo3_com_set_slot(g_vt_sample, 45, mf_sample_get_total_len);

        // IMFTransform (26 slots)
        bo3_com_init_vtable(g_vt_transform, 26, "IMFTransform");
        bo3_com_set_slot(g_vt_transform,  3, mft_get_stream_limits);
        bo3_com_set_slot(g_vt_transform,  4, mft_get_stream_count);
        bo3_com_set_slot(g_vt_transform,  5, mft_get_stream_ids);
        bo3_com_set_slot(g_vt_transform,  6, mft_get_input_stream_info);
        bo3_com_set_slot(g_vt_transform,  7, mft_get_output_stream_info);
        bo3_com_set_slot(g_vt_transform,  8, mft_get_attributes);
        bo3_com_set_slot(g_vt_transform,  9, mft_not_impl);
        bo3_com_set_slot(g_vt_transform, 10, mft_not_impl);
        bo3_com_set_slot(g_vt_transform, 11, mft_not_impl);
        bo3_com_set_slot(g_vt_transform, 12, mft_not_impl);
        bo3_com_set_slot(g_vt_transform, 13, mft_get_input_available_type);
        bo3_com_set_slot(g_vt_transform, 14, mft_get_output_available_type);
        bo3_com_set_slot(g_vt_transform, 15, mft_set_input_type);
        bo3_com_set_slot(g_vt_transform, 16, mft_set_output_type);
        bo3_com_set_slot(g_vt_transform, 17, mft_get_input_current_type);
        bo3_com_set_slot(g_vt_transform, 18, mft_get_output_current_type);
        bo3_com_set_slot(g_vt_transform, 19, mft_get_input_status);
        bo3_com_set_slot(g_vt_transform, 20, mft_get_output_status);
        bo3_com_set_slot(g_vt_transform, 21, mft_ok_noop);
        bo3_com_set_slot(g_vt_transform, 22, mft_ok_noop);
        bo3_com_set_slot(g_vt_transform, 23, mft_process_message);
        bo3_com_set_slot(g_vt_transform, 24, mft_process_input);
        bo3_com_set_slot(g_vt_transform, 25, mft_process_output);
    });
}

int bo3_media_avf_try_cocreate(const void *rclsid, const void *riid, void **ppv, uint32_t *out_hr) {
    (void)riid;
    if (!rclsid) return 0;
    const auto *clsid = static_cast<const Bo3GUID *>(rclsid);
    if (!bo3_guid_eq(clsid, &BO3_CLSID_CMSH264DecoderMFT)) {
        return 0;
    }
    if (!ppv) {
        if (out_hr) *out_hr = BO3_E_POINTER;
        return 1;
    }
    bo3_media_avf_init();
    Bo3MFH264Transform *mft = mf_h264_transform_create();
    *ppv = mft;
    if (out_hr) *out_hr = mft ? BO3_S_OK : BO3_E_OUTOFMEMORY;
    fprintf(stderr, "[media_avf] CoCreateInstance(CLSID_CMSH264DecoderMFT) -> %p (VideoToolbox H.264)\n",
            static_cast<void *>(mft));
    fflush(stderr);
    return 1;
}

// 0x1000ef820: MFStartup(ULONG Version, DWORD dwFlags)
SHIM_DEF(bo3_mf_startup) {
    SHIM_UNUSED_ALL();
    bo3_media_avf_init();
    return ret_u64(BO3_S_OK);
}

// 0x1000ef9f0: MFShutdown(void)
SHIM_DEF(bo3_mf_shutdown) {
    SHIM_UNUSED_ALL();
    return ret_u64(BO3_S_OK);
}

// 0x1000ef82d: MFCreateAlignedMemoryBuffer(DWORD cbMaxLength, DWORD cbAlignment, IMFMediaBuffer **ppBuffer)
SHIM_DEF(bo3_mf_create_aligned_memory_buffer) {
    SHIM_UNUSED_ALL();
    uint32_t max_len = static_cast<uint32_t>(rdi);
    uint32_t alignment = static_cast<uint32_t>(rsi);
    auto **ppbuf = reinterpret_cast<Bo3MFMediaBuffer **>(rdx);
    if (!ppbuf) return ret_u64(BO3_E_POINTER);
    Bo3MFMediaBuffer *buf = mf_buffer_create(max_len, alignment);
    if (!buf) {
        *ppbuf = nullptr;
        return ret_u64(BO3_E_OUTOFMEMORY);
    }
    *ppbuf = buf;
    return ret_u64(BO3_S_OK);
}

// 0x1000ef8b8: MFCreateMediaType(IMFMediaType **ppMFType)
SHIM_DEF(bo3_mf_create_media_type) {
    SHIM_UNUSED_ALL();
    auto **pp = reinterpret_cast<Bo3MFMediaType **>(rdi);
    if (!pp) return ret_u64(BO3_E_POINTER);
    Bo3MFMediaType *mt = mf_media_type_create();
    if (!mt) {
        *pp = nullptr;
        return ret_u64(BO3_E_OUTOFMEMORY);
    }
    *pp = mt;
    return ret_u64(BO3_S_OK);
}

// 0x1000ef94c: MFCreateSample(IMFSample **ppIMFSample)
SHIM_DEF(bo3_mf_create_sample) {
    SHIM_UNUSED_ALL();
    auto **pp = reinterpret_cast<Bo3MFSample **>(rdi);
    if (!pp) return ret_u64(BO3_E_POINTER);
    Bo3MFSample *sample = mf_sample_create();
    if (!sample) {
        *pp = nullptr;
        return ret_u64(BO3_E_OUTOFMEMORY);
    }
    *pp = sample;
    return ret_u64(BO3_S_OK);
}

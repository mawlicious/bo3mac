#pragma once
#include <stdint.h>
#include <stddef.h>

// Exact macOS Aspyr BO3 D3D11 / DXGI ABI structs & constants.
// Verified empirically via Ghidra decompilation of CoDBlkOps3_Exe:
//   - BOOL = int32_t (4 bytes), LONG = int32_t (4 bytes), UINT = uint32_t (4 bytes)
//   - WCHAR in DXGI_ADAPTER_DESC(1) and DXGI_OUTPUT_DESC = uint32_t (macOS 32-bit wchar_t!)
//   - All other D3D11 structs match Windows x64 ABI exactly.

#define BO3_S_OK                    0x00000000u
#define BO3_S_FALSE                 0x00000001u
#define BO3_E_NOTIMPL               0x80004001u
#define BO3_E_NOINTERFACE           0x80004002u
#define BO3_E_POINTER               0x80004003u
#define BO3_E_FAIL                  0x80004005u
#define BO3_E_INVALIDARG            0x80070057u
#define BO3_E_OUTOFMEMORY           0x8007000Eu
#define BO3_DXGI_ERROR_INVALID_CALL 0x887A0001u
#define BO3_DXGI_ERROR_NOT_FOUND    0x887A0002u
#define BO3_DXGI_ERROR_MORE_DATA    0x887A0003u
#define BO3_DXGI_ERROR_UNSUPPORTED  0x887A0004u

typedef struct Bo3GUID {
    uint32_t Data1;
    uint16_t Data2;
    uint16_t Data3;
    uint8_t  Data4[8];
} Bo3GUID;

typedef struct Bo3RECT {
    int32_t left;
    int32_t top;
    int32_t right;
    int32_t bottom;
} Bo3RECT;

typedef struct Bo3DXGI_RATIONAL {
    uint32_t Numerator;
    uint32_t Denominator;
} Bo3DXGI_RATIONAL;

typedef struct Bo3DXGI_MODE_DESC {
    uint32_t         Width;
    uint32_t         Height;
    Bo3DXGI_RATIONAL RefreshRate;
    uint32_t         Format;
    uint32_t         ScanlineOrdering;
    uint32_t         Scaling;
} Bo3DXGI_MODE_DESC; // 28 bytes (0x1c)

typedef struct Bo3DXGI_SAMPLE_DESC {
    uint32_t Count;
    uint32_t Quality;
} Bo3DXGI_SAMPLE_DESC;

typedef struct Bo3DXGI_SWAP_CHAIN_DESC {
    Bo3DXGI_MODE_DESC   BufferDesc;
    Bo3DXGI_SAMPLE_DESC SampleDesc;
    uint32_t            BufferUsage;
    uint32_t            BufferCount;
    uint64_t            OutputWindow;
    int32_t             Windowed;
    uint32_t            SwapEffect;
    uint32_t            Flags;
} Bo3DXGI_SWAP_CHAIN_DESC;

// macOS Aspyr DXGI_ADAPTER_DESC (wchar_t = 32-bit, Description = 512 bytes)
typedef struct Bo3DXGI_ADAPTER_DESC1 {
    uint32_t Description[128];    // +0x000 (512 bytes)
    uint32_t VendorId;            // +0x200
    uint32_t DeviceId;            // +0x204
    uint32_t SubSysId;            // +0x208
    uint32_t Revision;            // +0x20c
    uint64_t DedicatedVideoMemory;// +0x210
    uint64_t DedicatedSystemMemory;// +0x218
    uint64_t SharedSystemMemory;  // +0x220
    uint32_t AdapterLuidLow;      // +0x228
    int32_t  AdapterLuidHigh;     // +0x22c
    uint32_t Flags;               // +0x230
    uint32_t _pad;                // +0x234
} Bo3DXGI_ADAPTER_DESC1;

// macOS Aspyr DXGI_OUTPUT_DESC (wchar_t = 32-bit, DeviceName = 128 bytes, total 0xA0)
typedef struct Bo3DXGI_OUTPUT_DESC {
    uint32_t DeviceName[32];      // +0x00 (128 bytes)
    Bo3RECT  DesktopCoordinates;  // +0x80 (16 bytes)
    int32_t  AttachedToDesktop;   // +0x90
    uint32_t Rotation;            // +0x94
    uint64_t Monitor;             // +0x98 (HMONITOR)
} Bo3DXGI_OUTPUT_DESC;

// D3D11 resource descriptors
typedef struct Bo3D3D11_BUFFER_DESC {
    uint32_t ByteWidth;
    uint32_t Usage;
    uint32_t BindFlags;
    uint32_t CPUAccessFlags;
    uint32_t MiscFlags;
    uint32_t StructureByteStride;
} Bo3D3D11_BUFFER_DESC;

typedef struct Bo3D3D11_TEXTURE1D_DESC {
    uint32_t Width;
    uint32_t MipLevels;
    uint32_t ArraySize;
    uint32_t Format;
    uint32_t Usage;
    uint32_t BindFlags;
    uint32_t CPUAccessFlags;
    uint32_t MiscFlags;
} Bo3D3D11_TEXTURE1D_DESC;

typedef struct Bo3D3D11_TEXTURE2D_DESC {
    uint32_t            Width;
    uint32_t            Height;
    uint32_t            MipLevels;
    uint32_t            ArraySize;
    uint32_t            Format;
    Bo3DXGI_SAMPLE_DESC SampleDesc;
    uint32_t            Usage;
    uint32_t            BindFlags;
    uint32_t            CPUAccessFlags;
    uint32_t            MiscFlags;
} Bo3D3D11_TEXTURE2D_DESC;

typedef struct Bo3D3D11_TEXTURE3D_DESC {
    uint32_t Width;
    uint32_t Height;
    uint32_t Depth;
    uint32_t MipLevels;
    uint32_t Format;
    uint32_t Usage;
    uint32_t BindFlags;
    uint32_t CPUAccessFlags;
    uint32_t MiscFlags;
} Bo3D3D11_TEXTURE3D_DESC;

typedef struct Bo3D3D11_SUBRESOURCE_DATA {
    const void *pSysMem;
    uint32_t    SysMemPitch;
    uint32_t    SysMemSlicePitch;
} Bo3D3D11_SUBRESOURCE_DATA;

typedef struct Bo3D3D11_MAPPED_SUBRESOURCE {
    void    *pData;
    uint32_t RowPitch;
    uint32_t DepthPitch;
} Bo3D3D11_MAPPED_SUBRESOURCE;

typedef struct Bo3D3D11_BOX {
    uint32_t left;
    uint32_t top;
    uint32_t front;
    uint32_t right;
    uint32_t bottom;
    uint32_t back;
} Bo3D3D11_BOX;

typedef struct Bo3D3D11_VIEWPORT {
    float TopLeftX;
    float TopLeftY;
    float Width;
    float Height;
    float MinDepth;
    float MaxDepth;
} Bo3D3D11_VIEWPORT;

// View Descriptors
typedef struct Bo3D3D11_SHADER_RESOURCE_VIEW_DESC {
    uint32_t Format;
    uint32_t ViewDimension;
    union {
        struct { uint32_t FirstElement; uint32_t NumElements; } Buffer;
        struct { uint32_t MostDetailedMip; uint32_t MipLevels; } Texture1D;
        struct { uint32_t MostDetailedMip; uint32_t MipLevels; uint32_t FirstArraySlice; uint32_t ArraySize; } Texture1DArray;
        struct { uint32_t MostDetailedMip; uint32_t MipLevels; } Texture2D;
        struct { uint32_t MostDetailedMip; uint32_t MipLevels; uint32_t FirstArraySlice; uint32_t ArraySize; } Texture2DArray;
        struct { uint32_t UnusedField; } Texture2DMS;
        struct { uint32_t FirstArraySlice; uint32_t ArraySize; } Texture2DMSArray;
        struct { uint32_t MostDetailedMip; uint32_t MipLevels; } Texture3D;
        struct { uint32_t MostDetailedMip; uint32_t MipLevels; } TextureCube;
        struct { uint32_t MostDetailedMip; uint32_t MipLevels; uint32_t First2DArrayFace; uint32_t NumCubes; } TextureCubeArray;
        struct { uint32_t FirstElement; uint32_t NumElements; uint32_t Flags; } BufferEx;
    };
} Bo3D3D11_SHADER_RESOURCE_VIEW_DESC;

typedef struct Bo3D3D11_RENDER_TARGET_VIEW_DESC {
    uint32_t Format;
    uint32_t ViewDimension;
    union {
        struct { uint32_t FirstElement; uint32_t NumElements; } Buffer;
        struct { uint32_t MipSlice; } Texture1D;
        struct { uint32_t MipSlice; uint32_t FirstArraySlice; uint32_t ArraySize; } Texture1DArray;
        struct { uint32_t MipSlice; } Texture2D;
        struct { uint32_t MipSlice; uint32_t FirstArraySlice; uint32_t ArraySize; } Texture2DArray;
        struct { uint32_t UnusedField; } Texture2DMS;
        struct { uint32_t FirstArraySlice; uint32_t ArraySize; } Texture2DMSArray;
        struct { uint32_t MipSlice; uint32_t FirstWSlice; uint32_t WSize; } Texture3D;
    };
} Bo3D3D11_RENDER_TARGET_VIEW_DESC;

typedef struct Bo3D3D11_DEPTH_STENCIL_VIEW_DESC {
    uint32_t Format;
    uint32_t ViewDimension;
    uint32_t Flags;
    union {
        struct { uint32_t MipSlice; } Texture1D;
        struct { uint32_t MipSlice; uint32_t FirstArraySlice; uint32_t ArraySize; } Texture1DArray;
        struct { uint32_t MipSlice; } Texture2D;
        struct { uint32_t MipSlice; uint32_t FirstArraySlice; uint32_t ArraySize; } Texture2DArray;
        struct { uint32_t UnusedField; } Texture2DMS;
        struct { uint32_t FirstArraySlice; uint32_t ArraySize; } Texture2DMSArray;
    };
} Bo3D3D11_DEPTH_STENCIL_VIEW_DESC;

typedef struct Bo3D3D11_UNORDERED_ACCESS_VIEW_DESC {
    uint32_t Format;
    uint32_t ViewDimension;
    union {
        struct { uint32_t FirstElement; uint32_t NumElements; uint32_t Flags; } Buffer;
        struct { uint32_t MipSlice; } Texture1D;
        struct { uint32_t MipSlice; uint32_t FirstArraySlice; uint32_t ArraySize; } Texture1DArray;
        struct { uint32_t MipSlice; } Texture2D;
        struct { uint32_t MipSlice; uint32_t FirstArraySlice; uint32_t ArraySize; } Texture2DArray;
        struct { uint32_t MipSlice; uint32_t FirstWSlice; uint32_t WSize; } Texture3D;
    };
} Bo3D3D11_UNORDERED_ACCESS_VIEW_DESC;

// State Descriptors
typedef struct Bo3D3D11_RENDER_TARGET_BLEND_DESC {
    int32_t  BlendEnable;
    uint32_t SrcBlend;
    uint32_t DestBlend;
    uint32_t BlendOp;
    uint32_t SrcBlendAlpha;
    uint32_t DestBlendAlpha;
    uint32_t BlendOpAlpha;
    uint8_t  RenderTargetWriteMask;
    uint8_t  _pad[3];
} Bo3D3D11_RENDER_TARGET_BLEND_DESC; // 32 bytes

typedef struct Bo3D3D11_BLEND_DESC {
    int32_t                           AlphaToCoverageEnable;
    int32_t                           IndependentBlendEnable;
    Bo3D3D11_RENDER_TARGET_BLEND_DESC RenderTarget[8];
} Bo3D3D11_BLEND_DESC;

typedef struct Bo3D3D11_DEPTH_STENCILOP_DESC {
    uint32_t StencilFailOp;
    uint32_t StencilDepthFailOp;
    uint32_t StencilPassOp;
    uint32_t StencilFunc;
} Bo3D3D11_DEPTH_STENCILOP_DESC;

typedef struct Bo3D3D11_DEPTH_STENCIL_DESC {
    int32_t                       DepthEnable;
    uint32_t                      DepthWriteMask;
    uint32_t                      DepthFunc;
    int32_t                       StencilEnable;
    uint8_t                       StencilReadMask;
    uint8_t                       StencilWriteMask;
    uint8_t                       _pad[2];
    Bo3D3D11_DEPTH_STENCILOP_DESC FrontFace;
    Bo3D3D11_DEPTH_STENCILOP_DESC BackFace;
} Bo3D3D11_DEPTH_STENCIL_DESC;

typedef struct Bo3D3D11_RASTERIZER_DESC {
    uint32_t FillMode;
    uint32_t CullMode;
    int32_t  FrontCounterClockwise;
    int32_t  DepthBias;
    float    DepthBiasClamp;
    float    SlopeScaledDepthBias;
    int32_t  DepthClipEnable;
    int32_t  ScissorEnable;
    int32_t  MultisampleEnable;
    int32_t  AntialiasedLineEnable;
} Bo3D3D11_RASTERIZER_DESC; // 40 bytes

typedef struct Bo3D3D11_SAMPLER_DESC {
    uint32_t Filter;
    uint32_t AddressU;
    uint32_t AddressV;
    uint32_t AddressW;
    float    MipLODBias;
    uint32_t MaxAnisotropy;
    uint32_t ComparisonFunc;
    float    BorderColor[4];
    float    MinLOD;
    float    MaxLOD;
} Bo3D3D11_SAMPLER_DESC;

typedef struct Bo3D3D11_INPUT_ELEMENT_DESC {
    const char *SemanticName;
    uint32_t    SemanticIndex;
    uint32_t    Format;
    uint32_t    InputSlot;
    uint32_t    AlignedByteOffset;
    uint32_t    InputSlotClass;
    uint32_t    InstanceDataStepRate;
} Bo3D3D11_INPUT_ELEMENT_DESC;

typedef struct Bo3D3D11_QUERY_DESC {
    uint32_t Query;
    uint32_t MiscFlags;
} Bo3D3D11_QUERY_DESC;

typedef struct Bo3D3D11_QUERY_DATA_TIMESTAMP_DISJOINT {
    uint64_t Frequency;
    int32_t  Disjoint;
    uint32_t _pad;
} Bo3D3D11_QUERY_DATA_TIMESTAMP_DISJOINT;

// D3D11 Enums
enum {
    BO3_D3D11_USAGE_DEFAULT   = 0,
    BO3_D3D11_USAGE_IMMUTABLE = 1,
    BO3_D3D11_USAGE_DYNAMIC   = 2,
    BO3_D3D11_USAGE_STAGING   = 3,
};

enum {
    BO3_D3D11_BIND_VERTEX_BUFFER    = 0x1,
    BO3_D3D11_BIND_INDEX_BUFFER     = 0x2,
    BO3_D3D11_BIND_CONSTANT_BUFFER  = 0x4,
    BO3_D3D11_BIND_SHADER_RESOURCE  = 0x8,
    BO3_D3D11_BIND_STREAM_OUTPUT    = 0x10,
    BO3_D3D11_BIND_RENDER_TARGET    = 0x20,
    BO3_D3D11_BIND_DEPTH_STENCIL    = 0x40,
    BO3_D3D11_BIND_UNORDERED_ACCESS = 0x80,
};

enum {
    BO3_D3D11_RESOURCE_MISC_GENERATE_MIPS       = 0x1,
    BO3_D3D11_RESOURCE_MISC_TEXTURECUBE         = 0x4,
    BO3_D3D11_RESOURCE_MISC_DRAWINDIRECT_ARGS   = 0x10,
    BO3_D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS = 0x20,
    BO3_D3D11_RESOURCE_MISC_BUFFER_STRUCTURED   = 0x40,
};

enum {
    BO3_D3D11_MAP_READ               = 1,
    BO3_D3D11_MAP_WRITE              = 2,
    BO3_D3D11_MAP_READ_WRITE         = 3,
    BO3_D3D11_MAP_WRITE_DISCARD      = 4,
    BO3_D3D11_MAP_WRITE_NO_OVERWRITE = 5,
};

enum {
    BO3_D3D11_CLEAR_DEPTH   = 0x1,
    BO3_D3D11_CLEAR_STENCIL = 0x2,
};

enum {
    BO3_D3D11_RESOURCE_DIMENSION_UNKNOWN   = 0,
    BO3_D3D11_RESOURCE_DIMENSION_BUFFER    = 1,
    BO3_D3D11_RESOURCE_DIMENSION_TEXTURE1D = 2,
    BO3_D3D11_RESOURCE_DIMENSION_TEXTURE2D = 3,
    BO3_D3D11_RESOURCE_DIMENSION_TEXTURE3D = 4,
};

enum {
    BO3_D3D11_SRV_DIMENSION_UNKNOWN          = 0,
    BO3_D3D11_SRV_DIMENSION_BUFFER           = 1,
    BO3_D3D11_SRV_DIMENSION_TEXTURE1D        = 2,
    BO3_D3D11_SRV_DIMENSION_TEXTURE1DARRAY   = 3,
    BO3_D3D11_SRV_DIMENSION_TEXTURE2D        = 4,
    BO3_D3D11_SRV_DIMENSION_TEXTURE2DARRAY   = 5,
    BO3_D3D11_SRV_DIMENSION_TEXTURE2DMS      = 6,
    BO3_D3D11_SRV_DIMENSION_TEXTURE2DMSARRAY = 7,
    BO3_D3D11_SRV_DIMENSION_TEXTURE3D        = 8,
    BO3_D3D11_SRV_DIMENSION_TEXTURECUBE      = 9,
    BO3_D3D11_SRV_DIMENSION_TEXTURECUBEARRAY = 10,
    BO3_D3D11_SRV_DIMENSION_BUFFEREX         = 11,
};

enum {
    BO3_D3D11_RTV_DIMENSION_UNKNOWN          = 0,
    BO3_D3D11_RTV_DIMENSION_BUFFER           = 1,
    BO3_D3D11_RTV_DIMENSION_TEXTURE1D        = 2,
    BO3_D3D11_RTV_DIMENSION_TEXTURE1DARRAY   = 3,
    BO3_D3D11_RTV_DIMENSION_TEXTURE2D        = 4,
    BO3_D3D11_RTV_DIMENSION_TEXTURE2DARRAY   = 5,
    BO3_D3D11_RTV_DIMENSION_TEXTURE2DMS      = 6,
    BO3_D3D11_RTV_DIMENSION_TEXTURE2DMSARRAY = 7,
    BO3_D3D11_RTV_DIMENSION_TEXTURE3D        = 8,
};

enum {
    BO3_D3D11_DSV_DIMENSION_UNKNOWN          = 0,
    BO3_D3D11_DSV_DIMENSION_TEXTURE1D        = 1,
    BO3_D3D11_DSV_DIMENSION_TEXTURE1DARRAY   = 2,
    BO3_D3D11_DSV_DIMENSION_TEXTURE2D        = 3,
    BO3_D3D11_DSV_DIMENSION_TEXTURE2DARRAY   = 4,
    BO3_D3D11_DSV_DIMENSION_TEXTURE2DMS      = 5,
    BO3_D3D11_DSV_DIMENSION_TEXTURE2DMSARRAY = 6,
};

enum {
    BO3_D3D11_UAV_DIMENSION_UNKNOWN        = 0,
    BO3_D3D11_UAV_DIMENSION_BUFFER         = 1,
    BO3_D3D11_UAV_DIMENSION_TEXTURE1D      = 2,
    BO3_D3D11_UAV_DIMENSION_TEXTURE1DARRAY = 3,
    BO3_D3D11_UAV_DIMENSION_TEXTURE2D      = 4,
    BO3_D3D11_UAV_DIMENSION_TEXTURE2DARRAY = 5,
    BO3_D3D11_UAV_DIMENSION_TEXTURE3D      = 8,
};

enum {
    BO3_D3D11_QUERY_EVENT                        = 0,
    BO3_D3D11_QUERY_OCCLUSION                    = 1,
    BO3_D3D11_QUERY_TIMESTAMP                    = 2,
    BO3_D3D11_QUERY_TIMESTAMP_DISJOINT           = 3,
    BO3_D3D11_QUERY_PIPELINE_STATISTICS          = 4,
    BO3_D3D11_QUERY_OCCLUSION_PREDICATE          = 5,
};

enum {
    BO3_D3D11_PRIMITIVE_TOPOLOGY_UNDEFINED       = 0,
    BO3_D3D11_PRIMITIVE_TOPOLOGY_POINTLIST       = 1,
    BO3_D3D11_PRIMITIVE_TOPOLOGY_LINELIST        = 2,
    BO3_D3D11_PRIMITIVE_TOPOLOGY_LINESTRIP       = 3,
    BO3_D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST    = 4,
    BO3_D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP   = 5,
};

#ifdef __cplusplus
static_assert(sizeof(Bo3DXGI_MODE_DESC) == 0x1c, "DXGI_MODE_DESC must be 28 bytes");
static_assert(offsetof(Bo3DXGI_ADAPTER_DESC1, VendorId) == 0x200, "DXGI_ADAPTER_DESC1.VendorId must be at +0x200");
static_assert(offsetof(Bo3DXGI_OUTPUT_DESC, DesktopCoordinates) == 0x80, "DXGI_OUTPUT_DESC.DesktopCoordinates must be at +0x80");
static_assert(offsetof(Bo3DXGI_OUTPUT_DESC, Monitor) == 0x98, "DXGI_OUTPUT_DESC.Monitor must be at +0x98");
static_assert(sizeof(Bo3DXGI_OUTPUT_DESC) == 0xA0, "DXGI_OUTPUT_DESC must be 0xA0 bytes");
static_assert(sizeof(Bo3D3D11_RENDER_TARGET_BLEND_DESC) == 32, "RT blend desc must be 32 bytes");
static_assert(sizeof(Bo3D3D11_RASTERIZER_DESC) == 40, "Rasterizer desc must be 40 bytes");
#endif

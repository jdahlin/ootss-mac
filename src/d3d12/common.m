// COM object basics, unimplemented-method stubs and DXGI format mapping.
#include "common.h"

// ---------------------------------------------------------------- objects
void object_init(Object *o, const void *vtbl, const IID *const *iids, Device *device) {
    o->vtbl = vtbl;
    o->iids = iids;
    atomic_init(&o->refs, 1);
    o->device = device;
}

HRESULT object_query(Object *o, REFIID iid, void **out) {
    if (!out) return S_FALSE; // existence check only
    bool supported = GUID_EQUAL(iid, &IID_IUnknown);
    for (const IID *const *i = o->iids; *i && !supported; i++) supported = GUID_EQUAL(iid, *i);
    if (!supported) {
        *out = NULL;
        return E_NOINTERFACE;
    }
    object_add_ref(o);
    *out = o;
    return S_OK;
}

ULONG object_add_ref(Object *o) { return atomic_fetch_add(&o->refs, 1) + 1; }

ULONG object_release(Object *o) {
    int refs = atomic_fetch_sub(&o->refs, 1) - 1;
    if (refs == 0 && o->destroy) o->destroy(o);
    return refs < 0 ? 0 : refs;
}

HRESULT STDMETHODCALLTYPE com_QueryInterface(void *self, REFIID iid, void **out) {
    return object_query(self, iid, out);
}
ULONG STDMETHODCALLTYPE com_AddRef(void *self) { return object_add_ref(self); }
ULONG STDMETHODCALLTYPE com_Release(void *self) { return object_release(self); }

HRESULT STDMETHODCALLTYPE com_GetPrivateData(void *self, REFGUID guid, UINT *size, void *data) {
    if (size) *size = 0;
    return DXGI_ERROR_NOT_FOUND;
}

HRESULT STDMETHODCALLTYPE com_SetPrivateData(void *self, REFGUID guid, UINT size, const void *data) { return S_OK; }
HRESULT STDMETHODCALLTYPE com_SetPrivateDataInterface(void *self, REFGUID guid, const IUnknown *data) { return S_OK; }
HRESULT STDMETHODCALLTYPE com_SetName(void *self, LPCWSTR name) { return S_OK; }

HRESULT STDMETHODCALLTYPE com_GetDevice(void *self, REFIID iid, void **device) {
    return object_query(&((Object *)self)->device->object, iid, device);
}

// ---------------------------------------------------------------- unimplemented methods
static const char *g_slot_names[1024];
static uint32_t g_slot_count;

__attribute__((used)) static WINAPI HRESULT unimplemented_method(uint32_t slot) {
    static uint8_t reported[1024];
    if (slot < g_slot_count && !reported[slot]++) D3D_LOG("unimplemented: %s", g_slot_names[slot]);
    return E_NOTIMPL;
}

// make_tagged_thunk puts the slot number in r10d; pass it on as the first (ms_abi) argument.
__asm__(".intel_syntax noprefix\n"
        "_unimplemented_method_entry:\n"
        "  mov ecx, r10d\n"
        "  jmp _unimplemented_method\n"
        ".att_syntax\n");
extern char unimplemented_method_entry[];

void fill_unimplemented(void *vtbl, size_t size, const char *interface_name) {
    void **slots = vtbl;
    for (size_t i = 0; i < size / sizeof *slots; i++) {
        if (slots[i] || g_slot_count == 1024) continue;
        char name[96];
        snprintf(name, sizeof name, "%s slot %zu", interface_name, i);
        g_slot_names[g_slot_count] = strdup(name);
        slots[i] = make_tagged_thunk(g_slot_count++, unimplemented_method_entry);
    }
}

// ---------------------------------------------------------------- formats
MTLPixelFormat mtl_format(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R32G32B32A32_FLOAT: return MTLPixelFormatRGBA32Float;
    case DXGI_FORMAT_R32G32B32A32_UINT: return MTLPixelFormatRGBA32Uint;
    case DXGI_FORMAT_R32G32B32A32_SINT: return MTLPixelFormatRGBA32Sint;
    case DXGI_FORMAT_R16G16B16A16_FLOAT: return MTLPixelFormatRGBA16Float;
    case DXGI_FORMAT_R16G16B16A16_UNORM: return MTLPixelFormatRGBA16Unorm;
    case DXGI_FORMAT_R16G16B16A16_UINT: return MTLPixelFormatRGBA16Uint;
    case DXGI_FORMAT_R16G16B16A16_SNORM: return MTLPixelFormatRGBA16Snorm;
    case DXGI_FORMAT_R16G16B16A16_SINT: return MTLPixelFormatRGBA16Sint;
    case DXGI_FORMAT_R32G32_FLOAT: return MTLPixelFormatRG32Float;
    case DXGI_FORMAT_R32G32_UINT: return MTLPixelFormatRG32Uint;
    case DXGI_FORMAT_R32G32_SINT: return MTLPixelFormatRG32Sint;
    case DXGI_FORMAT_R10G10B10A2_UNORM: return MTLPixelFormatRGB10A2Unorm;
    case DXGI_FORMAT_R10G10B10A2_UINT: return MTLPixelFormatRGB10A2Uint;
    case DXGI_FORMAT_R11G11B10_FLOAT: return MTLPixelFormatRG11B10Float;
    case DXGI_FORMAT_R9G9B9E5_SHAREDEXP: return MTLPixelFormatRGB9E5Float;
    case DXGI_FORMAT_R8G8B8A8_UNORM: return MTLPixelFormatRGBA8Unorm;
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: return MTLPixelFormatRGBA8Unorm_sRGB;
    case DXGI_FORMAT_R8G8B8A8_UINT: return MTLPixelFormatRGBA8Uint;
    case DXGI_FORMAT_R8G8B8A8_SNORM: return MTLPixelFormatRGBA8Snorm;
    case DXGI_FORMAT_R8G8B8A8_SINT: return MTLPixelFormatRGBA8Sint;
    case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8X8_UNORM: return MTLPixelFormatBGRA8Unorm;
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
    case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB: return MTLPixelFormatBGRA8Unorm_sRGB;
    case DXGI_FORMAT_R16G16_FLOAT: return MTLPixelFormatRG16Float;
    case DXGI_FORMAT_R16G16_UNORM: return MTLPixelFormatRG16Unorm;
    case DXGI_FORMAT_R16G16_UINT: return MTLPixelFormatRG16Uint;
    case DXGI_FORMAT_R16G16_SNORM: return MTLPixelFormatRG16Snorm;
    case DXGI_FORMAT_R16G16_SINT: return MTLPixelFormatRG16Sint;
    case DXGI_FORMAT_R32_FLOAT: return MTLPixelFormatR32Float;
    case DXGI_FORMAT_R32_UINT: return MTLPixelFormatR32Uint;
    case DXGI_FORMAT_R32_SINT: return MTLPixelFormatR32Sint;
    case DXGI_FORMAT_D32_FLOAT: return MTLPixelFormatDepth32Float;
    // Apple GPUs have no 24-bit depth: D24S8 is stored as D32S8 and viewed through the same format.
    case DXGI_FORMAT_D32_FLOAT_S8X24_UINT:
    case DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS:
    case DXGI_FORMAT_D24_UNORM_S8_UINT:
    case DXGI_FORMAT_R24_UNORM_X8_TYPELESS: return MTLPixelFormatDepth32Float_Stencil8;
    case DXGI_FORMAT_X32_TYPELESS_G8X24_UINT:
    case DXGI_FORMAT_X24_TYPELESS_G8_UINT: return MTLPixelFormatX32_Stencil8;
    case DXGI_FORMAT_R8G8_UNORM: return MTLPixelFormatRG8Unorm;
    case DXGI_FORMAT_R8G8_UINT: return MTLPixelFormatRG8Uint;
    case DXGI_FORMAT_R8G8_SNORM: return MTLPixelFormatRG8Snorm;
    case DXGI_FORMAT_R8G8_SINT: return MTLPixelFormatRG8Sint;
    case DXGI_FORMAT_R16_FLOAT: return MTLPixelFormatR16Float;
    case DXGI_FORMAT_D16_UNORM: return MTLPixelFormatDepth16Unorm;
    case DXGI_FORMAT_R16_UNORM: return MTLPixelFormatR16Unorm;
    case DXGI_FORMAT_R16_UINT: return MTLPixelFormatR16Uint;
    case DXGI_FORMAT_R16_SNORM: return MTLPixelFormatR16Snorm;
    case DXGI_FORMAT_R16_SINT: return MTLPixelFormatR16Sint;
    case DXGI_FORMAT_R8_UNORM: return MTLPixelFormatR8Unorm;
    case DXGI_FORMAT_R8_UINT: return MTLPixelFormatR8Uint;
    case DXGI_FORMAT_R8_SNORM: return MTLPixelFormatR8Snorm;
    case DXGI_FORMAT_R8_SINT: return MTLPixelFormatR8Sint;
    case DXGI_FORMAT_A8_UNORM: return MTLPixelFormatA8Unorm;
    case DXGI_FORMAT_BC1_UNORM: return MTLPixelFormatBC1_RGBA;
    case DXGI_FORMAT_BC1_UNORM_SRGB: return MTLPixelFormatBC1_RGBA_sRGB;
    case DXGI_FORMAT_BC2_UNORM: return MTLPixelFormatBC2_RGBA;
    case DXGI_FORMAT_BC2_UNORM_SRGB: return MTLPixelFormatBC2_RGBA_sRGB;
    case DXGI_FORMAT_BC3_UNORM: return MTLPixelFormatBC3_RGBA;
    case DXGI_FORMAT_BC3_UNORM_SRGB: return MTLPixelFormatBC3_RGBA_sRGB;
    case DXGI_FORMAT_BC4_UNORM: return MTLPixelFormatBC4_RUnorm;
    case DXGI_FORMAT_BC4_SNORM: return MTLPixelFormatBC4_RSnorm;
    case DXGI_FORMAT_BC5_UNORM: return MTLPixelFormatBC5_RGUnorm;
    case DXGI_FORMAT_BC5_SNORM: return MTLPixelFormatBC5_RGSnorm;
    case DXGI_FORMAT_BC6H_UF16: return MTLPixelFormatBC6H_RGBUfloat;
    case DXGI_FORMAT_BC6H_SF16: return MTLPixelFormatBC6H_RGBFloat;
    case DXGI_FORMAT_BC7_UNORM: return MTLPixelFormatBC7_RGBAUnorm;
    case DXGI_FORMAT_BC7_UNORM_SRGB: return MTLPixelFormatBC7_RGBAUnorm_sRGB;
    case DXGI_FORMAT_UNKNOWN: return MTLPixelFormatInvalid;
    default: D3D_TODO("no Metal format for DXGI format %d", format); return MTLPixelFormatInvalid;
    }
}

// The format a texture is allocated with. Typeless formats take the "natural" typed format, depth-stencil
// resources take a depth format, and every view is a pixel-format view of that allocation.
MTLPixelFormat mtl_resource_format(const D3D12_RESOURCE_DESC *desc) {
    bool depth = (desc->Flags & D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL) != 0;
    switch (desc->Format) {
    case DXGI_FORMAT_R32G32B32A32_TYPELESS: return MTLPixelFormatRGBA32Float;
    case DXGI_FORMAT_R16G16B16A16_TYPELESS: return MTLPixelFormatRGBA16Float;
    case DXGI_FORMAT_R32G32_TYPELESS: return MTLPixelFormatRG32Float;
    case DXGI_FORMAT_R32G8X24_TYPELESS:
    case DXGI_FORMAT_R24G8_TYPELESS: return MTLPixelFormatDepth32Float_Stencil8;
    case DXGI_FORMAT_R10G10B10A2_TYPELESS: return MTLPixelFormatRGB10A2Unorm;
    case DXGI_FORMAT_R8G8B8A8_TYPELESS: return MTLPixelFormatRGBA8Unorm;
    case DXGI_FORMAT_R16G16_TYPELESS: return MTLPixelFormatRG16Float;
    case DXGI_FORMAT_R32_TYPELESS: return depth ? MTLPixelFormatDepth32Float : MTLPixelFormatR32Float;
    case DXGI_FORMAT_R8G8_TYPELESS: return MTLPixelFormatRG8Unorm;
    case DXGI_FORMAT_R16_TYPELESS: return depth ? MTLPixelFormatDepth16Unorm : MTLPixelFormatR16Float;
    case DXGI_FORMAT_R8_TYPELESS: return MTLPixelFormatR8Unorm;
    case DXGI_FORMAT_BC1_TYPELESS: return MTLPixelFormatBC1_RGBA;
    case DXGI_FORMAT_BC2_TYPELESS: return MTLPixelFormatBC2_RGBA;
    case DXGI_FORMAT_BC3_TYPELESS: return MTLPixelFormatBC3_RGBA;
    case DXGI_FORMAT_BC4_TYPELESS: return MTLPixelFormatBC4_RUnorm;
    case DXGI_FORMAT_BC5_TYPELESS: return MTLPixelFormatBC5_RGUnorm;
    case DXGI_FORMAT_BC6H_TYPELESS: return MTLPixelFormatBC6H_RGBUfloat;
    case DXGI_FORMAT_BC7_TYPELESS: return MTLPixelFormatBC7_RGBAUnorm;
    case DXGI_FORMAT_B8G8R8A8_TYPELESS:
    case DXGI_FORMAT_B8G8R8X8_TYPELESS: return MTLPixelFormatBGRA8Unorm;
    default: return mtl_format(desc->Format);
    }
}

MTLVertexFormat mtl_vertex_format(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R32G32B32A32_FLOAT: return MTLVertexFormatFloat4;
    case DXGI_FORMAT_R32G32B32_FLOAT: return MTLVertexFormatFloat3;
    case DXGI_FORMAT_R32G32_FLOAT: return MTLVertexFormatFloat2;
    case DXGI_FORMAT_R32_FLOAT: return MTLVertexFormatFloat;
    case DXGI_FORMAT_R16G16B16A16_FLOAT: return MTLVertexFormatHalf4;
    case DXGI_FORMAT_R16G16_FLOAT: return MTLVertexFormatHalf2;
    case DXGI_FORMAT_R16G16B16A16_UNORM: return MTLVertexFormatUShort4Normalized;
    case DXGI_FORMAT_R16G16_UNORM: return MTLVertexFormatUShort2Normalized;
    case DXGI_FORMAT_R16G16B16A16_SNORM: return MTLVertexFormatShort4Normalized;
    case DXGI_FORMAT_R16G16_SNORM: return MTLVertexFormatShort2Normalized;
    case DXGI_FORMAT_R16G16B16A16_UINT: return MTLVertexFormatUShort4;
    case DXGI_FORMAT_R16G16_UINT: return MTLVertexFormatUShort2;
    case DXGI_FORMAT_R16G16B16A16_SINT: return MTLVertexFormatShort4;
    case DXGI_FORMAT_R16G16_SINT: return MTLVertexFormatShort2;
    case DXGI_FORMAT_R8G8B8A8_UNORM: return MTLVertexFormatUChar4Normalized;
    case DXGI_FORMAT_R8G8B8A8_SNORM: return MTLVertexFormatChar4Normalized;
    case DXGI_FORMAT_R8G8B8A8_UINT: return MTLVertexFormatUChar4;
    case DXGI_FORMAT_R8G8B8A8_SINT: return MTLVertexFormatChar4;
    case DXGI_FORMAT_R8G8_UNORM: return MTLVertexFormatUChar2Normalized;
    case DXGI_FORMAT_R8G8_UINT: return MTLVertexFormatUChar2;
    case DXGI_FORMAT_R10G10B10A2_UNORM: return MTLVertexFormatUInt1010102Normalized;
    case DXGI_FORMAT_R32G32B32A32_UINT: return MTLVertexFormatUInt4;
    case DXGI_FORMAT_R32G32B32_UINT: return MTLVertexFormatUInt3;
    case DXGI_FORMAT_R32G32_UINT: return MTLVertexFormatUInt2;
    case DXGI_FORMAT_R32_UINT: return MTLVertexFormatUInt;
    case DXGI_FORMAT_R32G32B32A32_SINT: return MTLVertexFormatInt4;
    case DXGI_FORMAT_R32G32B32_SINT: return MTLVertexFormatInt3;
    case DXGI_FORMAT_R32G32_SINT: return MTLVertexFormatInt2;
    case DXGI_FORMAT_R32_SINT: return MTLVertexFormatInt;
    default: D3D_TODO("no Metal vertex format for DXGI format %d", format); return MTLVertexFormatInvalid;
    }
}

UINT format_bytes_per_block(DXGI_FORMAT format, UINT *block_size) {
    *block_size = 1;
    switch (format) {
    case DXGI_FORMAT_BC1_UNORM:
    case DXGI_FORMAT_BC1_UNORM_SRGB:
    case DXGI_FORMAT_BC4_UNORM: *block_size = 4; return 8;
    case DXGI_FORMAT_BC2_UNORM:
    case DXGI_FORMAT_BC3_UNORM:
    case DXGI_FORMAT_BC3_UNORM_SRGB:
    case DXGI_FORMAT_BC5_UNORM:
    case DXGI_FORMAT_BC5_SNORM:
    case DXGI_FORMAT_BC6H_UF16:
    case DXGI_FORMAT_BC6H_SF16:
    case DXGI_FORMAT_BC7_UNORM:
    case DXGI_FORMAT_BC7_UNORM_SRGB: *block_size = 4; return 16;
    case DXGI_FORMAT_R32G32B32A32_FLOAT: return 16;
    case DXGI_FORMAT_R16G16B16A16_FLOAT:
    case DXGI_FORMAT_R16G16B16A16_UNORM:
    case DXGI_FORMAT_R32G32_FLOAT: return 8;
    case DXGI_FORMAT_R8G8_UNORM:
    case DXGI_FORMAT_R16_FLOAT:
    case DXGI_FORMAT_R16_UNORM:
    case DXGI_FORMAT_R16_UINT:
    case DXGI_FORMAT_D16_UNORM: return 2;
    case DXGI_FORMAT_R8_UNORM:
    case DXGI_FORMAT_R8_UINT:
    case DXGI_FORMAT_A8_UNORM: return 1;
    default: return 4;
    }
}

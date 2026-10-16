// Root signatures.
//
// The game passes a serialized root signature (the RTS0 part of a DXBC container, or the bare data). We
// parse it, give it to the shader converter to learn where each root parameter lives in the top-level
// argument buffer the converted shaders read, and build the descriptor table of static samplers the
// converter turns static samplers into.
#include "converter.h"
#include "objects.h"

// ---------------------------------------------------------------- serialized format
// Header: version, parameter count, parameters offset, static sampler count, static samplers offset, flags.
// Parameter: type, shader visibility, offset of its payload. Version 1 = 1.0, version 2 = 1.1.
enum { ROOT_SIGNATURE_1_0 = 1, ROOT_SIGNATURE_1_1 = 2 };

typedef struct {
    uint32_t version, parameter_count, parameters_offset, sampler_count, samplers_offset, flags;
} RootSignatureHeader;

typedef struct {
    uint32_t type, visibility, payload_offset;
} SerializedParameter;

typedef struct { // static sampler, 52 bytes
    uint32_t filter, address_u, address_v, address_w;
    float mip_lod_bias;
    uint32_t max_anisotropy, comparison_func, border_color;
    float min_lod, max_lod;
    uint32_t shader_register, register_space, visibility;
} SerializedSampler;
_Static_assert(sizeof(SerializedSampler) == 52, "serialized static sampler");

static const uint8_t *find_rts0(const uint8_t *blob, size_t size, size_t *rts0_size) {
    if (size >= 32 && !memcmp(blob, "DXBC", 4)) {
        uint32_t parts = *(const uint32_t *)(blob + 28);
        for (uint32_t i = 0; i < parts && 32 + 4 * i + 4 <= size; i++) {
            uint32_t offset = *(const uint32_t *)(blob + 32 + 4 * i);
            if (offset + 8 <= size && !memcmp(blob + offset, "RTS0", 4)) {
                *rts0_size = *(const uint32_t *)(blob + offset + 4);
                return blob + offset + 8;
            }
        }
        return NULL;
    }
    *rts0_size = size;
    return blob; // bare root signature data
}

// ---------------------------------------------------------------- translation to the converter's descriptor
typedef struct {
    IRVersionedRootSignatureDescriptor desc;
    IRRootParameter1 *parameters;
    IRDescriptorRange1 *ranges;
    IRStaticSamplerDescriptor *samplers;
    D3D12_ROOT_PARAMETER_TYPE *types; // for the layout, in parameter order
    uint32_t *constant_counts;
} Translated;

static bool translate(const uint8_t *data, size_t size, Translated *t) {
    const RootSignatureHeader *h = (const void *)data;
    if (size < sizeof *h || (h->version != ROOT_SIGNATURE_1_0 && h->version != ROOT_SIGNATURE_1_1)) return false;
    bool v11 = h->version == ROOT_SIGNATURE_1_1;

    memset(t, 0, sizeof *t);
    t->parameters = calloc(h->parameter_count + 1, sizeof *t->parameters);
    t->types = calloc(h->parameter_count + 1, sizeof *t->types);
    t->constant_counts = calloc(h->parameter_count + 1, sizeof *t->constant_counts);
    size_t range_capacity = 0;
    const SerializedParameter *sp = (const void *)(data + h->parameters_offset);
    for (uint32_t i = 0; i < h->parameter_count; i++)
        if (sp[i].type == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE)
            range_capacity += *(const uint32_t *)(data + sp[i].payload_offset);
    t->ranges = calloc(range_capacity + 1, sizeof *t->ranges);

    IRDescriptorRange1 *next_range = t->ranges;
    for (uint32_t i = 0; i < h->parameter_count; i++) {
        const uint32_t *payload = (const void *)(data + sp[i].payload_offset);
        IRRootParameter1 *p = &t->parameters[i];
        p->ParameterType = (IRRootParameterType)sp[i].type;
        p->ShaderVisibility = (IRShaderVisibility)sp[i].visibility;
        t->types[i] = (D3D12_ROOT_PARAMETER_TYPE)sp[i].type;
        switch (sp[i].type) {
        case D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE: {
            uint32_t count = payload[0];
            const uint32_t *range = (const void *)(data + payload[1]);
            p->DescriptorTable = (IRRootDescriptorTable1){count, next_range};
            for (uint32_t r = 0; r < count; r++, range += v11 ? 6 : 5) {
                // 1.0: type, count, base register, space, offset. 1.1 adds flags before the offset.
                IRDescriptorRange1 *out = next_range++;
                out->RangeType = (IRDescriptorRangeType)range[0];
                out->NumDescriptors = range[1];
                out->BaseShaderRegister = range[2];
                out->RegisterSpace = range[3];
                out->Flags = v11 ? (IRDescriptorRangeFlags)range[4] : (IRDescriptorRangeFlags)0x3; // volatile
                out->OffsetInDescriptorsFromTableStart = range[v11 ? 5 : 4];
            }
            break;
        }
        case D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS:
            p->Constants = (IRRootConstants){payload[0], payload[1], payload[2]};
            t->constant_counts[i] = payload[2];
            break;
        default: // root CBV, SRV, UAV
            p->Descriptor = (IRRootDescriptor1){payload[0], payload[1],
                                                v11 ? (IRRootDescriptorFlags)payload[2] : (IRRootDescriptorFlags)0x2};
            break;
        }
    }

    const SerializedSampler *ss = (const void *)(data + h->samplers_offset);
    t->samplers = calloc(h->sampler_count + 1, sizeof *t->samplers);
    for (uint32_t i = 0; i < h->sampler_count; i++) {
        t->samplers[i] = (IRStaticSamplerDescriptor){(IRFilter)ss[i].filter,
                                                     (IRTextureAddressMode)ss[i].address_u,
                                                     (IRTextureAddressMode)ss[i].address_v,
                                                     (IRTextureAddressMode)ss[i].address_w,
                                                     ss[i].mip_lod_bias,
                                                     ss[i].max_anisotropy,
                                                     (IRComparisonFunction)ss[i].comparison_func,
                                                     (IRStaticBorderColor)ss[i].border_color,
                                                     ss[i].min_lod,
                                                     ss[i].max_lod,
                                                     ss[i].shader_register,
                                                     ss[i].register_space,
                                                     (IRShaderVisibility)ss[i].visibility};
    }

    t->desc.version = IRRootSignatureVersion_1_1;
    t->desc.desc_1_1 = (IRRootSignatureDescriptor1){h->parameter_count, t->parameters, h->sampler_count, t->samplers,
                                                    (IRRootSignatureFlags)h->flags};
    return true;
}

static void free_translated(Translated *t) {
    free(t->parameters);
    free(t->ranges);
    free(t->samplers);
    free(t->types);
    free(t->constant_counts);
}

// Static samplers are described to the shaders as a table of sampler descriptors, in the order given.
static id<MTLBuffer> build_sampler_table(Device *device, const SerializedSampler *samplers, uint32_t count) {
    id<MTLBuffer> table =
        [device->mtl newBufferWithLength:MAX(count, 1) * sizeof(DescriptorEntry)
                                 options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
    DescriptorEntry *entries = table.contents;
    for (uint32_t i = 0; i < count; i++) {
        const SerializedSampler *s = &samplers[i];
        D3D12_SAMPLER_DESC desc = {
            .Filter = s->filter,
            .AddressU = s->address_u,
            .AddressV = s->address_v,
            .AddressW = s->address_w,
            .MipLODBias = s->mip_lod_bias,
            .MaxAnisotropy = s->max_anisotropy,
            .ComparisonFunc = s->comparison_func,
            .MinLOD = s->min_lod,
            .MaxLOD = s->max_lod,
        };
        static const float border[3][4] = {{0, 0, 0, 0}, {0, 0, 0, 1}, {1, 1, 1, 1}};
        memcpy(desc.BorderColor, border[MIN(s->border_color, 2u)], sizeof desc.BorderColor);
        binding_set_sampler(&entries[i], sampler_state(device, &desc), s->mip_lod_bias);
    }
    residency_add(table);
    return table;
}

// ---------------------------------------------------------------- ID3D12RootSignature
static void root_signature_destroy(Object *o) {
    RootSignature *r = (RootSignature *)o;
    if (r->ir) converter()->RootSignatureDestroy(r->ir);
    [r->static_sampler_table release];
    free(o);
}

static ID3D12RootSignatureVtbl root_signature_vtbl = {ID3D12_OBJECT_METHODS, .GetDevice = (void *)com_GetDevice};
static const IID *const root_signature_iids[] = {&IID_ID3D12RootSignature, &IID_ID3D12DeviceChild, &IID_ID3D12Object,
                                                 NULL};

static IRResourceType expected_resource_type(D3D12_ROOT_PARAMETER_TYPE type) {
    switch (type) {
    case D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE: return IRResourceTypeTable;
    case D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS: return IRResourceTypeConstant;
    case D3D12_ROOT_PARAMETER_TYPE_CBV: return IRResourceTypeCBV;
    case D3D12_ROOT_PARAMETER_TYPE_SRV: return IRResourceTypeSRV;
    default: return IRResourceTypeUAV;
    }
}

// Asks the converter for the layout. Entries come in parameter order, followed by the static sampler table.
static bool compute_layout(RootSignature *r, const Translated *t, const RootSignatureHeader *h) {
    const ConverterAPI *api = converter();
    if (!api) return false;
    IRError *error = NULL;
    IRRootSignature *ir = api->RootSignatureCreateFromDescriptor(&t->desc, &error);
    if (!ir) {
        D3D_LOG("the converter rejected a root signature (code %u)", error ? api->ErrorGetCode(error) : 0);
        if (error) api->ErrorDestroy(error);
        return false;
    }
    size_t count = api->RootSignatureGetResourceCount(ir);
    IRResourceLocation *locations = calloc(count + 1, sizeof *locations);
    api->RootSignatureGetResourceLocations(ir, locations);

    bool ok = count >= h->parameter_count && h->parameter_count <= MAX_ROOT_PARAMETERS;
    for (uint32_t i = 0; ok && i < h->parameter_count; i++) {
        if (locations[i].resourceType != expected_resource_type(t->types[i])) ok = false;
        r->parameters[i] = (RootParameter){t->types[i], locations[i].topLevelOffset, (uint32_t)locations[i].sizeBytes};
        r->argument_buffer_size = MAX(r->argument_buffer_size, r->parameters[i].offset + r->parameters[i].size);
    }
    r->parameter_count = h->parameter_count;
    r->static_sampler_offset = -1;
    if (ok && count > h->parameter_count) { // the static sampler table
        r->static_sampler_offset = (int32_t)locations[h->parameter_count].topLevelOffset;
        r->argument_buffer_size = MAX(r->argument_buffer_size, r->static_sampler_offset + 8u);
    }
    if (!ok)
        D3D_LOG("unexpected root signature layout from the converter (%zu entries for %u parameters)", count,
                h->parameter_count);
    if (getenv("D3D12_LOG_ROOTSIG")) {
        for (size_t i = 0; i < count; i++)
            D3D_LOG("rootsig entry %zu: type %d offset %u size %llu", i, locations[i].resourceType,
                    locations[i].topLevelOffset, (unsigned long long)locations[i].sizeBytes);
    }
    free(locations);
    r->ir = ir; // kept: shaders are compiled against it
    return ok;
}

HRESULT root_signature_create(Device *device, const void *blob, size_t size, REFIID iid, void **out) {
    static bool vtbl_ready;
    if (!vtbl_ready++) FILL_UNIMPLEMENTED(root_signature_vtbl);
    RootSignature *r = calloc(1, sizeof *r);
    object_init(&r->object, &root_signature_vtbl, root_signature_iids, device);
    r->object.destroy = root_signature_destroy;
    r->static_sampler_offset = -1;
    r->key = 1469598103934665603ull; // FNV-1a over the blob
    for (size_t i = 0; i < size; i++) r->key = (r->key ^ ((const uint8_t *)blob)[i]) * 1099511628211ull;

    size_t rts0_size;
    const uint8_t *data = find_rts0(blob, size, &rts0_size);
    Translated t;
    if (data && translate(data, rts0_size, &t)) {
        const RootSignatureHeader *h = (const void *)data;
        if (compute_layout(r, &t, h) && h->sampler_count)
            r->static_sampler_table =
                build_sampler_table(device, (const void *)(data + h->samplers_offset), h->sampler_count);
        free_translated(&t);
    } else {
        D3D_LOG("cannot parse a root signature (%zu bytes)", size);
    }
    HRESULT hr = object_query(&r->object, iid, out);
    object_release(&r->object);
    return hr;
}

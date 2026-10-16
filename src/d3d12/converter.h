// Apple's Metal Shader Converter (libmetalirconverter), loaded at run time.
#pragma once
#include <metal_irconverter/metal_irconverter.h>

typedef struct ConverterAPI {
    IRCompiler *(*CompilerCreate)(void);
    void (*CompilerDestroy)(IRCompiler *);
    void (*CompilerSetMinimumDeploymentTarget)(IRCompiler *, IROperatingSystem, const char *);
    void (*CompilerSetGlobalRootSignature)(IRCompiler *, const IRRootSignature *);
    IRObject *(*ObjectCreateFromDXIL)(const uint8_t *, size_t, IRBytecodeOwnership);
    void (*ObjectDestroy)(IRObject *);
    IRObject *(*CompilerAllocCompileAndLink)(IRCompiler *, const char *, const IRObject *, IRError **);
    IRShaderStage (*ObjectGetMetalIRShaderStage)(const IRObject *);
    IRMetalLibBinary *(*MetalLibBinaryCreate)(void);
    void (*MetalLibBinaryDestroy)(IRMetalLibBinary *);
    bool (*ObjectGetMetalLibBinary)(const IRObject *, IRShaderStage, IRMetalLibBinary *);
    size_t (*MetalLibGetBytecodeSize)(const IRMetalLibBinary *);
    size_t (*MetalLibGetBytecode)(const IRMetalLibBinary *, uint8_t *);
    uint32_t (*ErrorGetCode)(const IRError *);
    void (*ErrorDestroy)(IRError *);
    // reflection
    IRShaderReflection *(*ShaderReflectionCreate)(void);
    void (*ShaderReflectionDestroy)(IRShaderReflection *);
    bool (*ObjectGetReflection)(const IRObject *, IRShaderStage, IRShaderReflection *);
    bool (*ShaderReflectionCopyVertexInfo)(const IRShaderReflection *, IRReflectionVersion, IRVersionedVSInfo *);
    bool (*ShaderReflectionReleaseVertexInfo)(IRVersionedVSInfo *);
    bool (*ShaderReflectionCopyComputeInfo)(const IRShaderReflection *, IRReflectionVersion, IRVersionedCSInfo *);
    bool (*ShaderReflectionReleaseComputeInfo)(IRVersionedCSInfo *);
    // root signatures
    IRRootSignature *(*RootSignatureCreateFromDescriptor)(const IRVersionedRootSignatureDescriptor *, IRError **);
    void (*RootSignatureDestroy)(IRRootSignature *);
    size_t (*RootSignatureGetResourceCount)(const IRRootSignature *);
    void (*RootSignatureGetResourceLocations)(const IRRootSignature *, IRResourceLocation *);
} ConverterAPI;

// Loads the library on first use. NULL when it is not available.
const ConverterAPI *converter(void);

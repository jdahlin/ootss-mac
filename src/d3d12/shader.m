// Shader translation at runtime: DXIL -> Metal library through Apple's Metal Shader Converter.
//
// Nothing derived from the game's shaders is ever stored in the source tree. The game hands us its
// DXIL when it creates pipelines; we convert it on first use and keep the result in a per-user cache
// (~/Library/Caches/ootss-mac/shaders), so only the first launch pays for the conversion.
//
// The converter library is loaded with dlopen (next to the executable, or LOADER_MSC_LIB), so the
// game still starts, with a clear message, when it is missing.
#include <ctype.h>
#include <dlfcn.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <unistd.h>
#include "converter.h"
#include "objects.h"

static ConverterAPI g_api;
static char g_cache_dir[1024]; // empty: caching disabled
static atomic_uint g_converted, g_cached, g_failed;
static atomic_uint_fast64_t g_convert_nanoseconds;

// ---------------------------------------------------------------- loading
static void make_cache_directory(const char *library_path) {
    struct stat st = {0};
    stat(library_path, &st);
    const char *home = getenv("HOME");
    if (!home) return;
    char path[1024];
    // The cache is keyed by the converter build: its output changes with the library.
    snprintf(path, sizeof path, "%s/Library/Caches/ootss-mac", home);
    mkdir(path, 0755);
    snprintf(path, sizeof path, "%s/Library/Caches/ootss-mac/shaders", home);
    mkdir(path, 0755);
    snprintf(g_cache_dir, sizeof g_cache_dir, "%s/msc-%lld", path, (long long)st.st_size);
    if (mkdir(g_cache_dir, 0755) && access(g_cache_dir, W_OK)) g_cache_dir[0] = 0;
}

// Prints the totals when they changed since the last call.
static void print_shader_stats(void) {
    static unsigned last_total;
    unsigned converted = atomic_load(&g_converted), cached = atomic_load(&g_cached), failed = atomic_load(&g_failed);
    unsigned total = converted + cached + failed;
    if (total == last_total) return;
    last_total = total;
    D3D_LOG("shaders: %u converted (%.1f s of conversion), %u from cache, %u failed", converted,
            atomic_load(&g_convert_nanoseconds) / 1e9, cached, failed);
}

static bool load_converter(void) {
    char exe[1024], beside[1100];
    uint32_t size = sizeof exe;
    _NSGetExecutablePath(exe, &size);
    snprintf(beside, sizeof beside, "%s/libmetalirconverter.dylib", dirname(exe));
    const char *candidates[] = {getenv("LOADER_MSC_LIB"), beside};

    void *lib = NULL;
    const char *path = NULL;
    for (int i = 0; i < 2 && !lib; i++)
        if (candidates[i] && (lib = dlopen(candidates[i], RTLD_NOW))) path = candidates[i];
    if (!lib) {
        D3D_LOG("shader converter not found (run `make msc`, or set LOADER_MSC_LIB): %s", dlerror());
        return false;
    }
#define LOAD(field, name) (g_api.field = dlsym(lib, "IR" name))
    LOAD(CompilerCreate, "CompilerCreate");
    LOAD(CompilerDestroy, "CompilerDestroy");
    LOAD(CompilerSetMinimumDeploymentTarget, "CompilerSetMinimumDeploymentTarget");
    LOAD(CompilerSetGlobalRootSignature, "CompilerSetGlobalRootSignature");
    LOAD(ObjectCreateFromDXIL, "ObjectCreateFromDXIL");
    LOAD(ObjectDestroy, "ObjectDestroy");
    LOAD(CompilerAllocCompileAndLink, "CompilerAllocCompileAndLink");
    LOAD(ObjectGetMetalIRShaderStage, "ObjectGetMetalIRShaderStage");
    LOAD(MetalLibBinaryCreate, "MetalLibBinaryCreate");
    LOAD(MetalLibBinaryDestroy, "MetalLibBinaryDestroy");
    LOAD(ObjectGetMetalLibBinary, "ObjectGetMetalLibBinary");
    LOAD(MetalLibGetBytecodeSize, "MetalLibGetBytecodeSize");
    LOAD(MetalLibGetBytecode, "MetalLibGetBytecode");
    LOAD(ErrorGetCode, "ErrorGetCode");
    LOAD(ErrorDestroy, "ErrorDestroy");
    LOAD(ShaderReflectionCreate, "ShaderReflectionCreate");
    LOAD(ShaderReflectionDestroy, "ShaderReflectionDestroy");
    LOAD(ObjectGetReflection, "ObjectGetReflection");
    LOAD(ShaderReflectionCopyVertexInfo, "ShaderReflectionCopyVertexInfo");
    LOAD(ShaderReflectionReleaseVertexInfo, "ShaderReflectionReleaseVertexInfo");
    LOAD(ShaderReflectionCopyComputeInfo, "ShaderReflectionCopyComputeInfo");
    LOAD(ShaderReflectionReleaseComputeInfo, "ShaderReflectionReleaseComputeInfo");
    LOAD(RootSignatureCreateFromDescriptor, "RootSignatureCreateFromDescriptor");
    LOAD(RootSignatureDestroy, "RootSignatureDestroy");
    LOAD(RootSignatureGetResourceCount, "RootSignatureGetResourceCount");
    LOAD(RootSignatureGetResourceLocations, "RootSignatureGetResourceLocations");
#undef LOAD
    void **slots = (void **)&g_api;
    for (size_t i = 0; i < sizeof g_api / sizeof *slots; i++)
        if (!slots[i]) {
            D3D_LOG("shader converter library is missing an entry point (slot %zu)", i);
            return false;
        }

    make_cache_directory(path);
    D3D_LOG("shader converter: %s, cache: %s", path, g_cache_dir[0] ? g_cache_dir : "(disabled)");
    atexit(print_shader_stats);
    // Progress while the game builds its pipelines; the totals print only when they change.
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{ print_shader_stats(); });
    dispatch_resume(timer);
    return true;
}

const ConverterAPI *converter(void) {
    static dispatch_once_t once;
    static bool ready;
    dispatch_once(&once, ^{ ready = load_converter(); });
    return ready ? &g_api : NULL;
}

// ---------------------------------------------------------------- cache
// Each shader is two files named after the container hash: <hash>.metallib and <hash>.info (reflection).
static void cache_path(const uint8_t *dxbc, uint64_t root_key, const char *extension, char *out, size_t size) {
    int n = snprintf(out, size, "%s/", g_cache_dir);
    for (int i = 4; i < 20; i++) n += snprintf(out + n, size - n, "%02x", dxbc[i]);
    snprintf(out + n, size - n, "-%016llx.%s", (unsigned long long)root_key, extension);
}

static void write_cache(const char *path, const void *bytes, size_t size) {
    char temp[1100];
    snprintf(temp, sizeof temp, "%s.%d.tmp", path, getpid());
    FILE *f = fopen(temp, "wb");
    if (!f) return;
    bool ok = fwrite(bytes, 1, size, f) == size;
    ok = fclose(f) == 0 && ok;
    if (ok)
        rename(temp, path); // atomic: other threads and runs never see a partial file
    else
        unlink(temp);
}

// ---------------------------------------------------------------- reflection
static void collect_info(const IRObject *object, IRShaderStage stage, ShaderInfo *info) {
    memset(info, 0, sizeof *info);
    IRShaderReflection *reflection = g_api.ShaderReflectionCreate();
    if (g_api.ObjectGetReflection(object, stage, reflection)) {
        if (stage == IRShaderStageVertex) {
            IRVersionedVSInfo vs;
            if (g_api.ShaderReflectionCopyVertexInfo(reflection, IRReflectionVersion_1_0, &vs)) {
                const IRVSInfo_1_0 *v = &vs.info_1_0;
                for (size_t i = 0; i < v->num_vertex_inputs && info->input_count < 16; i++) {
                    snprintf(info->inputs[info->input_count].name, sizeof info->inputs[0].name, "%s",
                             v->vertex_inputs[i].name);
                    info->inputs[info->input_count++].attribute = v->vertex_inputs[i].attributeIndex;
                }
                g_api.ShaderReflectionReleaseVertexInfo(&vs);
            }
        } else if (stage == IRShaderStageCompute) {
            IRVersionedCSInfo cs;
            if (g_api.ShaderReflectionCopyComputeInfo(reflection, IRReflectionVersion_1_0, &cs)) {
                memcpy(info->threads_per_group, cs.info_1_0.tg_size, sizeof info->threads_per_group);
                g_api.ShaderReflectionReleaseComputeInfo(&cs);
            }
        }
    }
    g_api.ShaderReflectionDestroy(reflection);
}

// ---------------------------------------------------------------- conversion
// The container's hash (bytes 4..20) identifies the shader; the same hash always yields the same output.
static NSData *convert(const D3D12_SHADER_BYTECODE *code, const RootSignature *root, ShaderInfo *info) {
    const uint8_t *dxbc = code->pShaderBytecode;
    char library_path[1100] = "", info_path[1100] = "";
    if (g_cache_dir[0]) {
        cache_path(dxbc, root ? root->key : 0, "metallib", library_path, sizeof library_path);
        cache_path(dxbc, root ? root->key : 0, "info", info_path, sizeof info_path);
        NSData *library = [NSData dataWithContentsOfFile:@(library_path)];
        NSData *stored = [NSData dataWithContentsOfFile:@(info_path)];
        if (library && stored.length == sizeof *info) {
            memcpy(info, stored.bytes, sizeof *info);
            atomic_fetch_add(&g_cached, 1);
            return library;
        }
    }

    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    IRCompiler *compiler = g_api.CompilerCreate();
    g_api.CompilerSetMinimumDeploymentTarget(compiler, IROperatingSystem_macOS, "14.0");
    if (root && root->ir) g_api.CompilerSetGlobalRootSignature(compiler, root->ir);
    IRObject *input = g_api.ObjectCreateFromDXIL(dxbc, code->BytecodeLength, IRBytecodeOwnershipNone);
    IRError *error = NULL;
    IRObject *output = g_api.CompilerAllocCompileAndLink(compiler, NULL, input, &error);
    NSData *result = nil;
    if (output) {
        IRShaderStage stage = g_api.ObjectGetMetalIRShaderStage(output);
        IRMetalLibBinary *lib = g_api.MetalLibBinaryCreate();
        if (g_api.ObjectGetMetalLibBinary(output, stage, lib)) {
            size_t size = g_api.MetalLibGetBytecodeSize(lib);
            uint8_t *bytes = malloc(size);
            g_api.MetalLibGetBytecode(lib, bytes);
            collect_info(output, stage, info);
            if (library_path[0]) {
                write_cache(library_path, bytes, size);
                write_cache(info_path, info, sizeof *info);
            }
            result = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:YES];
        }
        g_api.MetalLibBinaryDestroy(lib);
        g_api.ObjectDestroy(output);
    }
    if (error) {
        D3D_LOG("shader conversion failed (code %u)", g_api.ErrorGetCode(error));
        g_api.ErrorDestroy(error);
    }
    g_api.ObjectDestroy(input);
    g_api.CompilerDestroy(compiler);
    atomic_fetch_add(&g_convert_nanoseconds, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start);
    atomic_fetch_add(result ? &g_converted : &g_failed, 1);
    return result;
}

// Returns a retained MTLLibrary, its (single) function name and reflection, or nil.
id<MTLLibrary> shader_library_create(id<MTLDevice> device, const D3D12_SHADER_BYTECODE *code, const RootSignature *root,
                                     NSString **function, ShaderInfo *info) {
    if (!converter() || !code->pShaderBytecode || code->BytecodeLength < 32) return nil;
    NSData *metallib = convert(code, root, info);
    if (!metallib) return nil;
    NSError *error = nil;
    dispatch_data_t data =
        dispatch_data_create(metallib.bytes, metallib.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
    dispatch_release(data);
    if (!library) {
        D3D_LOG("Metal rejected a converted shader: %s", error.localizedDescription.UTF8String);
        return nil;
    }
    if (function) *function = library.functionNames.firstObject;
    return library;
}

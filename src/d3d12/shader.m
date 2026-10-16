// Shader translation at runtime: DXIL -> Metal library through Apple's Metal Shader Converter.
//
// Nothing derived from the game's shaders is ever stored in the source tree. The game hands us its
// DXIL when it creates pipelines; we convert it on first use and keep the result in a per-user cache
// (~/Library/Caches/ootss-mac/shaders), so only the first launch pays for the conversion.
//
// The converter library is loaded with dlopen (next to the executable, or LOADER_MSC_LIB), so the
// game still starts, with a clear message, when it is missing.
#include <dlfcn.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <unistd.h>
#include "objects.h"
#import <dispatch/dispatch.h>
#include <metal_irconverter/metal_irconverter.h>

// ---------------------------------------------------------------- the converter library
static struct {
    IRCompiler *(*CompilerCreate)(void);
    void (*CompilerDestroy)(IRCompiler *);
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
    void (*CompilerSetMinimumDeploymentTarget)(IRCompiler *, IROperatingSystem, const char *);
} ir;

static char g_cache_dir[1024]; // empty: caching disabled
static bool g_converter_ready;
static atomic_uint g_converted, g_cached, g_failed;
static atomic_uint_fast64_t g_convert_nanoseconds;

static bool load_converter(void) {
    char exe[1024], path[1100];
    uint32_t size = sizeof exe;
    _NSGetExecutablePath(exe, &size);
    const char *override = getenv("LOADER_MSC_LIB");
    const char *candidates[] = {override, NULL, NULL};
    snprintf(path, sizeof path, "%s/libmetalirconverter.dylib", dirname(exe));
    candidates[1] = path;

    void *lib = NULL;
    for (int i = 0; i < 2 && !lib; i++)
        if (candidates[i]) lib = dlopen(candidates[i], RTLD_NOW);
    if (!lib) {
        D3D_LOG("shader converter not found (run `make msc`, or set LOADER_MSC_LIB): %s", dlerror());
        return false;
    }
#define LOAD(field, name) (ir.field = dlsym(lib, "IR" name))
    LOAD(CompilerCreate, "CompilerCreate");
    LOAD(CompilerDestroy, "CompilerDestroy");
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
    LOAD(CompilerSetMinimumDeploymentTarget, "CompilerSetMinimumDeploymentTarget");
#undef LOAD
    void **slots = (void **)&ir;
    for (size_t i = 0; i < sizeof ir / sizeof *slots; i++)
        if (!slots[i]) {
            D3D_LOG("shader converter library is missing an entry point (slot %zu)", i);
            return false;
        }

    // The cache directory is keyed by the converter build: its output changes with the library.
    struct stat st = {0};
    Dl_info info;
    if (dladdr((void *)dlsym(lib, "IRCompilerCreate"), &info)) stat(info.dli_fname, &st);
    const char *home = getenv("HOME");
    if (home) {
        snprintf(g_cache_dir, sizeof g_cache_dir, "%s/Library/Caches/ootss-mac/shaders/msc-%lld", home,
                 (long long)st.st_size);
        char parent[1024];
        snprintf(parent, sizeof parent, "%s/Library/Caches/ootss-mac", home);
        mkdir(parent, 0755);
        snprintf(parent, sizeof parent, "%s/Library/Caches/ootss-mac/shaders", home);
        mkdir(parent, 0755);
        if (mkdir(g_cache_dir, 0755) && access(g_cache_dir, W_OK)) g_cache_dir[0] = 0;
    }
    D3D_LOG("shader converter: %s, cache: %s", info.dli_fname, g_cache_dir[0] ? g_cache_dir : "(disabled)");
    return true;
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

// ---------------------------------------------------------------- conversion with cache
static NSData *read_file(const char *path) { return [NSData dataWithContentsOfFile:@(path)]; }

static void write_cache(const char *path, const uint8_t *bytes, size_t size) {
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

// The container's hash (bytes 4..20) identifies the shader; the same hash always yields the same output.
static NSData *convert(const D3D12_SHADER_BYTECODE *code) {
    const uint8_t *dxbc = code->pShaderBytecode;
    char cache_path[1100] = "";
    if (g_cache_dir[0]) {
        int n = snprintf(cache_path, sizeof cache_path, "%s/", g_cache_dir);
        for (int i = 4; i < 20; i++) n += snprintf(cache_path + n, sizeof cache_path - n, "%02x", dxbc[i]);
        snprintf(cache_path + n, sizeof cache_path - n, ".metallib");
        NSData *hit = read_file(cache_path);
        if (hit) {
            atomic_fetch_add(&g_cached, 1);
            return hit;
        }
    }

    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    IRCompiler *compiler = ir.CompilerCreate();
    ir.CompilerSetMinimumDeploymentTarget(compiler, IROperatingSystem_macOS, "14.0");
    IRObject *input = ir.ObjectCreateFromDXIL(dxbc, code->BytecodeLength, IRBytecodeOwnershipNone);
    IRError *error = NULL;
    IRObject *output = ir.CompilerAllocCompileAndLink(compiler, NULL, input, &error);
    NSData *result = nil;
    if (output) {
        IRMetalLibBinary *lib = ir.MetalLibBinaryCreate();
        if (ir.ObjectGetMetalLibBinary(output, ir.ObjectGetMetalIRShaderStage(output), lib)) {
            size_t size = ir.MetalLibGetBytecodeSize(lib);
            uint8_t *bytes = malloc(size);
            ir.MetalLibGetBytecode(lib, bytes);
            if (cache_path[0]) write_cache(cache_path, bytes, size);
            result = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:YES];
        }
        ir.MetalLibBinaryDestroy(lib);
        ir.ObjectDestroy(output);
    }
    if (error) {
        D3D_LOG("shader conversion failed (code %u)", ir.ErrorGetCode(error));
        ir.ErrorDestroy(error);
    }
    ir.ObjectDestroy(input);
    ir.CompilerDestroy(compiler);
    atomic_fetch_add(&g_convert_nanoseconds, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start);
    atomic_fetch_add(result ? &g_converted : &g_failed, 1);
    return result;
}

// Returns a retained MTLLibrary and its (single) function name, or nil.
id<MTLLibrary> shader_library_create(id<MTLDevice> device, const D3D12_SHADER_BYTECODE *code, NSString **function) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      g_converter_ready = load_converter();
      if (!g_converter_ready) return;
      atexit(print_shader_stats);
      // Progress while the game builds its pipelines; the totals print only when they change.
      dispatch_source_t timer =
          dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
      dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
      dispatch_source_set_event_handler(timer, ^{ print_shader_stats(); });
      dispatch_resume(timer);
    });
    if (!g_converter_ready || !code->pShaderBytecode || code->BytecodeLength < 32) return nil;

    NSData *metallib = convert(code);
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

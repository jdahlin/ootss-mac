# Order of the Sinking Star on macOS: x86_64 loader + Win32 shims, D3D12 via Apple's D3DMetal.
#
#   make                                            build build/sinking-star
#   make run GAME="/path/to/Order of the Sinking Star"
#   make format | lint                              clang-format / clang-tidy
#   make clean | distclean

CC     := clang
ARCH   := -arch x86_64 -mmacosx-version-min=15.0
CFLAGS := $(ARCH) -O2 -g -Wall -Wextra -Wno-unused-parameter -fno-builtin -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0
LDFLAGS := $(ARCH) -framework Cocoa -framework QuartzCore -framework AudioToolbox -framework CoreAudio -framework Carbon -framework Metal

DMN_REPO := https://github.com/utmapp/d3dmetal-native
DMN_REV  := fd09f2edd6f972f28b0f65117b39c361ecf99ad1
DMN_SRC  := deps/d3dmetal-native

# Apple's Metal Shader Converter (DXIL -> Metal). Its headers are vendored in third_party/; the library is
# Apple's binary, fetched by `make msc` (one file, checked against a pinned hash) and never redistributed.
MSC_REV    := cfed9ebffb64e1d784853edb8cdeea32456a75a0
MSC_URL    := https://raw.githubusercontent.com/MethanePowered/MetalShaderConverterBinary/$(MSC_REV)/binaries/MacOS.zip
MSC_SHA256 := 7e87a5994765537fb23a37a1199f0785f1a267ceae7b64b586bc908edd41b7ee
MSC_INC    := third_party/metal_irconverter/include

# The D3D12-on-Metal backend uses Microsoft's real headers (vendored, see src/d3d12/common.h).
DXH_SRC := third_party/DirectX-Headers
D3D12_CFLAGS := -fno-objc-arc -isystem $(MSC_INC) -isystem $(DXH_SRC)/include -isystem $(DXH_SRC)/include/wsl/stubs -isystem $(DXH_SRC)/include/directx

SRCS := $(wildcard src/*.c src/*.m src/d3d12/*.c src/d3d12/*.m)
OBJS := $(patsubst src/%,build/obj/%.o,$(SRCS))
HDRS := $(wildcard src/*.h src/d3d12/*.h)

all: build/sinking-star build/libmetalirconverter.dylib

# Optional: Apple's D3DMetal as a fallback graphics backend (LOADER_D3D=d3dmetal). Loaded with dlopen at run time.
d3dmetal: build/libd3dmetal-native.dylib

# The Info.plist is embedded so even the bare executable identifies itself as a game.
build/sinking-star: $(OBJS) resources/Info.plist
	$(CC) $(LDFLAGS) -Wl,-sectcreate,__TEXT,__info_plist,resources/Info.plist -o $@ $(OBJS)

# A real app bundle, which is what macOS needs to offer Game Mode. The libraries sit beside the executable.
APP := build/Order of the Sinking Star.app
app: all
	@mkdir -p "$(APP)/Contents/MacOS"
	cp resources/Info.plist "$(APP)/Contents/Info.plist"
	cp build/sinking-star build/libmetalirconverter.dylib "$(APP)/Contents/MacOS/"
	@test ! -e build/libd3dmetal-native.dylib || cp build/libd3dmetal-native.dylib "$(APP)/Contents/MacOS/"
	@test ! -e build/D3DMetal.framework || ln -sfn "$(CURDIR)/build/D3DMetal.framework" "$(APP)/Contents/MacOS/D3DMetal.framework"
	codesign --force --deep -s - "$(APP)"

build/obj/d3d12/%.c.o: src/d3d12/%.c $(HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(D3D12_CFLAGS) -c $< -o $@

# Apple's runtime header requires ARC and needs none of the D3D12 headers.
build/obj/d3d12/binding.m.o: D3D12_CFLAGS := -fobjc-arc -isystem $(MSC_INC)

build/obj/d3d12/%.m.o: src/d3d12/%.m $(HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(D3D12_CFLAGS) -c $< -o $@

build/obj/%.c.o: src/%.c $(HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

build/obj/%.m.o: src/%.m $(HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fobjc-arc -c $< -o $@

# For clang-tidy: one entry per source with the same flags as the build.
compile_commands.json: Makefile $(SRCS)
	@printf '[\n' > $@
	@for f in $(SRCS); do \
	  extra=; case $$f in src/d3d12/binding.m) extra="-fobjc-arc -isystem $(MSC_INC)";; src/d3d12/*) extra="$(D3D12_CFLAGS)";; *.m) extra=-fobjc-arc;; esac; \
	  printf '  {"directory": "%s", "file": "%s", "command": "clang -isysroot %s %s %s -c %s"},\n' "$(CURDIR)" "$$f" "$$(xcrun --show-sdk-path)" "$(CFLAGS)" "$$extra" "$$f" >> $@; \
	done
	@sed -i '' '$$ s/},$$/}/' $@ && printf ']\n' >> $@

format:
	clang-format -i src/*.c src/*.m src/*.h src/d3d12/*

lint: compile_commands.json
	clang-tidy --quiet $(SRCS)

msc: build/libmetalirconverter.dylib

deps/MacOS.zip:
	@mkdir -p deps
	curl -fL --progress-bar -o $@.part $(MSC_URL)
	@echo "$(MSC_SHA256)  $@.part" | shasum -a 256 -c - || { rm -f $@.part; echo "checksum mismatch: not using the download"; exit 1; }
	mv $@.part $@

build/libmetalirconverter.dylib: deps/MacOS.zip
	@mkdir -p build
	unzip -p $< lib/libmetalirconverter.dylib > $@

$(DMN_SRC):
	git clone --quiet $(DMN_REPO) $@
	git -C $@ checkout --quiet $(DMN_REV)

build/libd3dmetal-native.dylib: | $(DMN_SRC)
	test -d build/d3dmetal-native || \
	  meson setup build/d3dmetal-native $(DMN_SRC) --cross-file $(DMN_SRC)/build-macos-x86_64.txt -Dtests=disabled
	meson compile -C build/d3dmetal-native
	cp build/d3dmetal-native/libd3dmetal-native.dylib $@

run: app
	@test -n "$(GAME)" || { echo 'usage: make run GAME="/path/to/Order of the Sinking Star"'; exit 1; }
	"$(APP)/Contents/MacOS/sinking-star" "$(GAME)/sinking_star.exe"

clean:
	rm -rf build compile_commands.json

distclean: clean
	rm -rf deps

.PHONY: app d3dmetal all run msc format lint clean distclean

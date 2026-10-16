# Order of the Sinking Star on macOS: x86_64 loader + Win32 shims, D3D12 via Apple's D3DMetal.
#
#   make                                            build build/sinking-star
#   make run GAME="/path/to/Order of the Sinking Star"
#   make clean | distclean

CC     := clang
ARCH   := -arch x86_64 -mmacosx-version-min=14.0
CFLAGS := $(ARCH) -O2 -g -Wall -Wextra -Wno-unused-parameter -fno-builtin -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0
LDFLAGS := $(ARCH) -framework Cocoa -framework QuartzCore -framework AudioToolbox -framework CoreAudio

DMN_REPO := https://github.com/utmapp/d3dmetal-native
DMN_REV  := fd09f2edd6f972f28b0f65117b39c361ecf99ad1
DMN_SRC  := deps/d3dmetal-native

SRCS := $(wildcard src/*.c src/*.m)
OBJS := $(patsubst src/%,build/obj/%.o,$(SRCS))

all: build/sinking-star build/libd3dmetal-native.dylib

build/sinking-star: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

build/obj/%.c.o: src/%.c src/shim.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

build/obj/%.m.o: src/%.m src/shim.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fobjc-arc -c $< -o $@

$(DMN_SRC):
	git clone --quiet $(DMN_REPO) $@
	git -C $@ checkout --quiet $(DMN_REV)

build/libd3dmetal-native.dylib: | $(DMN_SRC)
	cd $(DMN_SRC) && meson setup build --cross-file build-macos-x86_64.txt -Dtests=disabled --reconfigure >/dev/null
	meson compile -C $(DMN_SRC)/build
	@mkdir -p build
	cp $(DMN_SRC)/build/libd3dmetal-native.dylib $@

run: all
	@test -n "$(GAME)" || { echo 'usage: make run GAME="/path/to/Order of the Sinking Star"'; exit 1; }
	build/sinking-star "$(GAME)/sinking_star.exe"

clean:
	rm -rf build

distclean: clean
	rm -rf deps

.PHONY: all run clean distclean

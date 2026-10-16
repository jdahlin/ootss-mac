# Order of the Sinking Star on macOS: x86_64 loader + Win32 shims, D3D12 via Apple's D3DMetal.
#
#   make                                            build build/sinking-star
#   make run GAME="/path/to/Order of the Sinking Star"
#   make format | lint                              clang-format / clang-tidy
#   make clean | distclean

CC     := clang
ARCH   := -arch x86_64 -mmacosx-version-min=14.0
CFLAGS := $(ARCH) -O2 -g -Wall -Wextra -Wno-unused-parameter -fno-builtin -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0
LDFLAGS := $(ARCH) -framework Cocoa -framework QuartzCore -framework AudioToolbox -framework CoreAudio -framework Carbon

DMN_REPO := https://github.com/utmapp/d3dmetal-native
DMN_REV  := fd09f2edd6f972f28b0f65117b39c361ecf99ad1
DMN_SRC  := deps/d3dmetal-native

SRCS := $(wildcard src/*.c src/*.m)
OBJS := $(patsubst src/%,build/obj/%.o,$(SRCS))
HDRS := $(wildcard src/*.h)

all: build/sinking-star build/libd3dmetal-native.dylib

build/sinking-star: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

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
	  extra=; case $$f in *.m) extra=-fobjc-arc;; esac; \
	  printf '  {"directory": "%s", "file": "%s", "command": "clang -isysroot %s %s %s -c %s"},\n' "$(CURDIR)" "$$f" "$$(xcrun --show-sdk-path)" "$(CFLAGS)" "$$extra" "$$f" >> $@; \
	done
	@sed -i '' '$$ s/},$$/}/' $@ && printf ']\n' >> $@

format:
	clang-format -i src/*.c src/*.m src/*.h

lint: compile_commands.json
	clang-tidy --quiet $(SRCS)

$(DMN_SRC):
	git clone --quiet $(DMN_REPO) $@
	git -C $@ checkout --quiet $(DMN_REV)

build/libd3dmetal-native.dylib: | $(DMN_SRC)
	test -d build/d3dmetal-native || \
	  meson setup build/d3dmetal-native $(DMN_SRC) --cross-file $(DMN_SRC)/build-macos-x86_64.txt -Dtests=disabled
	meson compile -C build/d3dmetal-native
	cp build/d3dmetal-native/libd3dmetal-native.dylib $@

run: all
	@test -n "$(GAME)" || { echo 'usage: make run GAME="/path/to/Order of the Sinking Star"'; exit 1; }
	build/sinking-star "$(GAME)/sinking_star.exe"

clean:
	rm -rf build compile_commands.json

distclean: clean
	rm -rf deps

.PHONY: all run format lint clean distclean

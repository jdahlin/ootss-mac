# Order of the Sinking Star on macOS

Runs the Windows build of *Order of the Sinking Star* on Apple Silicon Macs without Wine.

![The game running on an M4 MacBook at ~49 fps](docs/screenshot.webp)

A small x86_64 loader maps `sinking_star.exe` into memory and implements the ~300 Windows functions it
imports on top of macOS: Cocoa for the window and input, CoreAudio for sound, and our own Direct3D 12 on
Metal for graphics. Everything runs under Rosetta 2.

## Requirements

- An Apple Silicon Mac with macOS 15 or later and Rosetta 2 (`softwareupdate --install-rosetta`)
- Xcode Command Line Tools
- Your own copy of the game: the Windows build from Steam

## Get the game files

Download the Windows build with your Steam account (Steam is not needed to play):

```sh
steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "$HOME/Games/Order of the Sinking Star" \
         +login <your_steam_user> +app_update <appid> validate +quit
```

## Build and run

```sh
make msc     # fetches Apple's Metal Shader Converter (not bundled; it converts the game's shaders)
make
make run GAME="$HOME/Games/Order of the Sinking Star"
```

`make run` launches the game from an app bundle (`make app` builds `build/Order of the Sinking Star.app`),
which declares it a game so macOS can apply Game Mode. The game starts fullscreen as a borderless window with
the Dock and menu bar hidden; `LOADER_WINDOWED=1` starts windowed. Only one copy can run at a time. Saves go
to `~/Library/Application Support/Order of the Sinking Star`.

## Graphics

The game's D3D12 and DXGI calls are implemented on Metal in `src/d3d12/`: command lists are recorded and
replayed into Metal encoders, descriptor heaps become Metal buffers of descriptors, and the game's DXIL
shaders are converted at run time by Apple's Metal Shader Converter against each pipeline's root signature.
The first launch converts all 257 shaders, which takes a few seconds; the results are cached in
`~/Library/Caches/ootss-mac/shaders` (keyed by the shader, its root signature and the converter build).
Delete that folder to force a fresh conversion. Nothing derived from the game is stored in this repository.

At 2940x1912 on an M4 it runs about 28 fps against about 21 fps through D3DMetal, and the frames match
except for anti-aliasing at edges.

Not implemented: `ExecuteIndirect` count buffers and per-command root constants, depth resolve, UAV counters,
typed buffer views, queries and timestamps.

### D3DMetal (fallback)

`LOADER_D3D=d3dmetal` uses Apple's D3DMetal instead. Download the Game Porting Toolkit from Apple, copy
`D3DMetal.framework` to `build/D3DMetal.framework` (or set `D3DMETAL_FRAMEWORK_PATH`), and
`xattr -dr com.apple.quarantine` it if macOS blocks it. Then `make d3dmetal` builds
[d3dmetal-native](https://github.com/utmapp/d3dmetal-native) (MIT), which hosts it; the loader opens it with
`dlopen` only when this backend is selected (`brew install meson ninja`).

## Options

| Variable | Effect |
| --- | --- |
| `LOADER_FPS=1` | Show fps and frame time in the window title |
| `LOADER_MUTE=1` | Play no sound (the game's audio clock keeps running) |
| `LOADER_WINDOWED=1` | Start windowed instead of fullscreen |
| `LOADER_RENDER_SCALE=0.5` | Render at a fraction of the screen resolution (0.1 to 1); the layer stretches it to fit. Faster, softer |
| `D3D12_PROFILE=1` | Log GPU time per pass and compute shader, averaged per frame |
| `LOADER_DISPLAY=native` | Report the real screen resolution to the game instead of the window size |
| `LOADER_TRACE=1` | Log Win32 calls (verbose) |
| `D3D12_LOG_GPU=1` | Log GPU time per frame |
| `D3D12_LOG_PRESENT=1` | Check that the back buffer is not black; `D3D12_DUMP_FRAME=file.ppm` saves a frame |
| `D3D12_MAX_PRESENTS=n` | Exit after n frames (bounded debug runs) |
| `D3D12_NO_PRESENT=1` | Never show frames (benchmarking) |
| `D3D12_VSYNC=1` | Sync presentation to the display (off by default for lower input latency; `DMN_VSYNC` for D3DMetal) |
| `D3D12_DUMP_SHADERS=dir` | Write every DXIL shader the game creates pipelines from (for study; do not commit) |
| `D3D12_LOG_PSO=1`, `D3D12_LOG_ROOTSIG=1` | Log pipeline states and root signature layouts |
| `MTL_HUD_ENABLED=1` | Apple's Metal performance HUD |

Turn off Low Power Mode when playing; it roughly halves the frame rate.

## Status

Playable with keyboard, mouse and sound. Not done: gamepads, Steam features (achievements, cloud
saves), the clipboard. Steam is stubbed as "running, offline".

## Layout

| File | Contents |
| --- | --- |
| `src/loader.c` | PE loader, import binding, TEB/TLS through `%gs`, crash reports, `main` |
| `src/win32.h` | The Windows types, structures and constants we use, size-checked against x64 Windows |
| `src/shim.h` | Shim registration (`SHIM(...)`), logging and shared declarations |
| `src/sync.c` | Threads, events, semaphores, waits, critical sections |
| `src/files.c` | Files, directory search, file mappings, console output |
| `src/kernel32.c` | Virtual memory, heaps, time, system information, modules |
| `src/crt.c` | Universal CRT and VCRUNTIME, including Windows `printf` and `setjmp` |
| `src/window.m` | Window, message queue and display metrics on Cocoa |
| `src/input.m` | Keyboard, mouse and Raw Input |
| `src/audio.c` | MMDevice/WASAPI on CoreAudio (for the game's Wwise) |
| `src/d3d.m` | Chooses the graphics backend (ours, or D3DMetal as a fallback) |
| `src/d3d12/` | D3D12 and DXGI on Metal: `device.m`, `dxgi.m`, `queue.m`, `list.m` (recording), `replay.m` (Metal encoders), `resource.m`, `descriptor.m`, `rootsig.m`, `pipeline.m`, `shader.m` (converter and cache), `binding.m` (Apple's runtime header), `profile.m` |
| `resources/Info.plist` | Game Mode and app metadata, embedded in the executable and the app bundle |
| `src/misc.c` | Registry, COM, shell, dbghelp |
| `src/steam.c` | Steam, reported as running but offline |
| `src/strings.c` | UTF-16, path and printf helpers |

## Development

`make format` runs clang-format and `make lint` runs clang-tidy (`brew install llvm`).
`LOADER_TRACE=1` logs Win32 calls, and shims that are knowingly partial log their first calls as `[fixme]`.

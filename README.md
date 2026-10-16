# Order of the Sinking Star on macOS

Runs the Windows build of *Order of the Sinking Star* on Apple Silicon Macs without Wine.

A small x86_64 loader maps `sinking_star.exe` into memory and implements the ~300 Windows functions it
imports on top of macOS: Cocoa for the window and input, CoreAudio for sound, and Apple's D3DMetal
(from the Game Porting Toolkit) for Direct3D 12. Everything runs under Rosetta 2.

## Requirements

- An Apple Silicon Mac with macOS 14 or later and Rosetta 2 (`softwareupdate --install-rosetta`)
- Xcode Command Line Tools, `meson` and `ninja` (`brew install meson ninja`)
- Your own copy of the game: the Windows build from Steam
- `D3DMetal.framework` from Apple's [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/).
  It is Apple's and is not included here.

## Get the game files

Download the Windows build with your Steam account (Steam is not needed to play):

```sh
steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "$HOME/Games/Order of the Sinking Star" \
         +login <your_steam_user> +app_update <appid> validate +quit
```

## Get D3DMetal

Download the Game Porting Toolkit from Apple and find `D3DMetal.framework` in it. Then either copy it to
`build/D3DMetal.framework` after building, or point to it:

```sh
export D3DMETAL_FRAMEWORK_PATH=/path/to/D3DMetal.framework
```

If macOS quarantines it: `xattr -dr com.apple.quarantine D3DMetal.framework`.

## Build and run

```sh
make
make run GAME="$HOME/Games/Order of the Sinking Star"
```

`make` also fetches and builds [d3dmetal-native](https://github.com/utmapp/d3dmetal-native) (MIT), which
hosts D3DMetal outside Wine. Saves go to `~/Library/Application Support/Order of the Sinking Star`.

## Options

| Variable | Effect |
| --- | --- |
| `LOADER_FPS=1` | Show fps and frame time in the window title |
| `LOADER_DISPLAY=native` | Report the real screen resolution to the game instead of the window size |
| `LOADER_TRACE=1` | Log Win32 calls (verbose) |
| `DMN_VSYNC=1` | Sync presentation to the display (off by default for lower input latency) |
| `MTL_HUD_ENABLED=1` | Apple's Metal performance HUD |

Turn off Low Power Mode when playing; it roughly halves the frame rate.

## Status

Playable with keyboard, mouse and sound. Not done: gamepads, Steam features (achievements, cloud
saves), the clipboard. Steam is stubbed as "running, offline".

## Layout

| File | Contents |
| --- | --- |
| `src/loader.c` | PE loader, import binding, TEB/TLS through `%gs`, crash reports, `main` |
| `src/kernel32.c` | Threads, sync objects, files, memory, time |
| `src/crt.c` | Universal CRT and VCRUNTIME, including Windows `printf` and `setjmp` |
| `src/user32.m` | Window, message queue, keyboard/mouse/raw input on Cocoa |
| `src/audio.c` | MMDevice/WASAPI on CoreAudio (for the game's Wwise) |
| `src/d3d.m` | D3D12/DXGI through D3DMetal |
| `src/misc.c` | Registry, COM, shell, Steam stubs |
| `src/strings.c` | UTF-16, path and format helpers |

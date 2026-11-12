# Code mods (this fork)

This branch adds two things to Savage Wind that the upstream project doesn't have:

- **Code mods.** An exlaunch module made for the console (a `subsdk9`) is recompiled and loaded with the game, and its hooks work. It was written for the [BotW co-op mod](https://github.com/Jaiden56YT/botw-coop), which is the only mod it has run.
- **A Vulkan build on macOS**, through MoltenVK (`make MAC_VULKAN=1 B=build-vk`). The Metal backend doesn't draw this game.

Nothing here is supported by the Savage Wind authors: don't report problems with this branch to them.

## Where it stands

| System | Status |
|---|---|
| macOS, Apple silicon | Runs: the game on MoltenVK, and the co-op mod in it (two copies, with Ryujinx and Switch players). |
| Windows | **Never run.** The changed runtime files pass a syntax check for 64-bit Windows, and the mod's generated code compiles for it (portable C for floating point, as on every x86 PC). The socket code and the hook table's export are written for Windows and untested. |
| Linux | Never run. |

## How a mod gets in

A mod is part of the built game code, not a file dropped next to the app:

1. `tools/mod_add.py <subsdk9> <its .elf>` copies the module into `extracted/exefs` and writes `subsdk9.mod` next to it: the module's symbols, as `nm` prints them. That file is what marks the module as a mod. (The co-op mod's own setup does this step from its release package: `setup --recomp <this folder>`.)
2. `extracted/exefs/hooks.txt` lists the game functions the mod hooks, one `module+offset` per line. Each is generated with a hook point at its start, so calls from inside the game reach the hook too. A hook on a function that isn't listed only catches calls that go through the dispatcher (calls through a pointer and between modules); the log names such functions.
3. `make gen` recompiles the game code with the mod's module after the SDK, and `make` builds it.

The start screen's own builder (the one players of the official release use) knows nothing of mods: build with `make gen` and `make`.

## What the runtime does for a mod

`runtime/mods.c`:

- exlaunch's start-up and hooking are replaced: it would read the console's memory map and write branches into the game's code, which means nothing for code recompiled ahead of time. A hook is an entry in a table (`game_hook_slots`, in the game code library).
- `nn::socket` runs on the computer's own sockets and `nn::nifm` says the network is up, for mods only.
- The RomFS overlay (`SAVAGEWIND_ROMFS_OVERLAY`) can add folders the game doesn't have (`runtime/services/fs.c`), which is where a mod keeps its own files.

## macOS build

```bash
brew install sdl3 ffmpeg molten-vk vulkan-loader vulkan-headers shaderc
python3 -m venv tools/venv && tools/venv/bin/pip install lz4 capstone unicorn
# your own game files in extracted/exefs and extracted/romfs
make gen
make MAC_VULKAN=1 B=build-vk -j
./build-vk/savagewind extracted --play
```

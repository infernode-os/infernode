# InferNode - Quick Start Guide

## Running Inferno®

### From a release tarball

```bash
# Linux x86_64 or ARM64 (GUI) — extract and run
tar xzf infernode-*-linux-*-gui.tar.gz
cd infernode-*-linux-*-gui
./infernode                       # SDL3 is bundled, no dependencies needed

# Linux x86_64 or ARM64 (headless) — extract and run
tar xzf infernode-*-linux-*.tar.gz
cd infernode-*-linux-*
./infernode-headless

# Optional desktop/PATH integration (Linux, either tarball):
./setup-desktop.sh                # app-menu/dock icon (GUI) + `infernode` on $PATH
#   ./setup-desktop.sh --no-path  # icon only
#   ./setup-desktop.sh --no-icon  # PATH wrapper only (headless/server)
#   ./setup-desktop.sh --uninstall

# macOS ARM64 (Apple Silicon) — open DMG, drag to Applications, double-click
```

> Match the tarball to your CPU: `amd64` (Intel/AMD) vs `arm64` (Jetson / Raspberry Pi / Apple-Silicon Linux). Running the wrong arch fails with a missing `ld-linux-aarch64.so.1` / loader error.

### From source

```bash
# Linux x86_64 (Intel/AMD) — GUI build (requires SDL3)
./install-sdl3.sh                 # install SDL3 from source (one time)
./build-linux-amd64.sh            # builds with SDL3 GUI (default)
# launch — see "Running for Development" below

# Linux x86_64 (Intel/AMD) — headless build (no GUI dependencies)
./build-linux-amd64.sh headless
# launch — see "Running for Development" below

# Linux ARM64 (Jetson, Raspberry Pi, etc.)
./install-sdl3.sh                 # GUI only, one time
./build-linux-arm64.sh            # add 'headless' to skip SDL3

# macOS ARM64 (Apple Silicon)
./makemk.sh                       # bootstrap mk (one time)
brew install sdl3 sdl3_ttf        # GUI only
./build-macos-sdl3.sh             # or ./build-macos-headless.sh
```

### What does `-r.` mean?

The `-r` option sets the **root directory** for the Inferno® filesystem - where the emulator looks for `/dis`, `/module`, `/fonts`, and other Inferno® files.

- `-r.` = use current directory (`.`) as root
- `-r/opt/inferno` = use `/opt/inferno` as root (path is host filesystem convention)
- No `-r` = use compiled-in default (`/usr/inferno`)

Using `-r.` lets you run directly from the source tree without installing anywhere.

## After Cloning

Bootstrap the build tools and install the post-merge git hook:

```bash
./makemk.sh            # bootstrap mk build tool from source (~30s)
./hooks/install.sh     # auto-rebuild stale .dis files after git pull
```

This hook runs automatically after every `git pull` or `git merge`. It detects which `.m` (interface) and `.b` (source) files changed and rebuilds the affected `.dis` files. Without it, pulling interface changes can leave you with stale `.dis` files that fail at load time with `link typecheck` errors.

### Why are `.dis` files in git?

Inferno is a self-hosting OS — the `dis/` directory is its runtime, like `/usr/bin` on Unix. Without pre-built `.dis` files, a fresh clone has no shell, no `cat`, no `ls`. The runtime tree (`dis/`) is tracked so the system boots immediately after clone.

Build artifacts in source directories (`appl/**/*.dis`, `tests/**/*.dis`) are **not** tracked — only the runtime tree.

The trade-off: tracked `.dis` files can go stale when `.m` interfaces change between commits. The post-merge hook closes that gap automatically.

## First Steps

You'll see the `;` prompt. Try these commands:

```
; pwd
/
; date
Sat Jan 10 07:46:10 EST 2026
; ls
[directory listing]
; cat /dev/sysctl
Fourth Edition (20120928)
; cat /dev/user
pdfinn
; echo hello world
hello world
```

## Available Commands

After building (see Building section below):
- **Filesystem**: ls, pwd, cat, rm, mv, cp, mkdir, cd
- **System**: ps, kill, date, mount, bind
- **Network**: mntgen, trfs, os
- **Utilities**: du, wc, grep, ftest, echo

**Note:** The runtime `.dis` files in `dis/` are tracked in git, so basic commands work after clone. If you see `link typecheck` errors, run `./hooks/install.sh` and pull again, or rebuild manually with `mk install` in the affected `appl/` subdirectory.

## Building

### Linux x86_64 (Intel/AMD)

```bash
./build-linux-amd64.sh            # SDL3 GUI (default)
./build-linux-amd64.sh headless   # headless (no display)
```

This bootstraps the `mk` build tool, compiles all libraries, builds the `limbo` compiler, builds the emulator (SDL3 GUI by default, or headless), and compiles the Dis bytecode applications.

### Linux ARM64

```bash
./build-linux-arm64.sh            # SDL3 GUI (default)
./build-linux-arm64.sh headless   # headless (no display)
```

Same process as x86_64, but for ARM64 platforms like Jetson or Raspberry Pi.

### macOS ARM64

```bash
./makemk.sh                       # bootstrap mk (first time only)
./build-macos-sdl3.sh             # SDL3 GUI (requires: brew install sdl3 sdl3_ttf)
./build-macos-headless.sh         # headless (no display)
```

### Windows x86_64

Requires Visual Studio 2022 Build Tools (free). Open **x64 Native Tools Command Prompt for VS 2022**, then:

```powershell
powershell -ExecutionPolicy Bypass -File build-windows-amd64.ps1
```

This builds libraries, the `limbo` compiler, the headless emulator, and all Dis bytecode. For SDL3 GUI support, see [docs/WINDOWS-BUILD.md](docs/WINDOWS-BUILD.md).

## Running for Development

Run `emu` directly from a terminal — this is the standard developer launch path on every platform. stdout/stderr stream to the terminal, Ctrl-C exits, and there is no platform packaging or signing in the loop. The runtime tree (`dis/`, `lib/`, `module/`, …) is read live from the working tree, so `mk install` results show up on the next launch with no rebuild step.

| Platform | Mode | Run from the repo root |
|---|---|---|
| macOS   | GUI       | `./emu/MacOSX/o.emu -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r$PWD sh -l /lib/lucifer/boot.sh` |
| macOS   | headless  | `./emu/MacOSX/o.emu -c1 -r$PWD sh -l` |
| Linux   | GUI       | `./emu/Linux/o.emu -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r$PWD sh -l /lib/lucifer/boot.sh` |
| Linux   | headless  | `./emu/Linux/o.emu -c1 -r$PWD sh -l` |
| Windows | headless  | `.\emu\Nt\o.emu.exe -c1 -r%CD% sh -l` |
| Windows | GUI       | Build per [docs/WINDOWS-BUILD.md](docs/WINDOWS-BUILD.md), then same shape as the macOS/Linux GUI rows. |

Same shape on every platform; only the emu path and the trailing command differ. The GUI rows invoke `/lib/lucifer/boot.sh` — the canonical boot orchestration (login → LLM service → wallet → UI server → tools9p → lucibridge → lucifer GUI) and the same script the production macOS `.app` launcher invokes, so direct-emu tests the same code path end users run. The headless rows drop you at the Inferno `;` shell prompt.

Flags worth knowing:

- `-c1` — JIT on (default for performance). Use `-c0` for interpreter-only when investigating a JIT-suspected bug.
- `-pheap`/`-pmain`/`-pimage` — pool sizes; raise if you hit allocation pressure with large LLM contexts.
- `-r<path>` — Inferno root. Use `-r$PWD` from the repo root to run against the working tree.

### macOS: testing the `.app` packaging path

For the rare case when you need to validate the bundle layout, launcher script, or the read-only `Resources/` snapshot semantics — not for code iteration:

```sh
./build-dev-bundle.sh
open --stdout /tmp/infernode-dev.out --stderr /tmp/infernode-dev.err /tmp/InferNode-dev.app
tail -F /tmp/infernode-dev.out /tmp/infernode-dev.err
```

`build-dev-bundle.sh` mirrors the CI release pipeline (`.github/workflows/release.yml`) minus codesign, notarize, and strip. It produces `/tmp/InferNode-dev.app`, an unsigned but otherwise byte-identical bundle. `open --stdout/--stderr` is required because `open` detaches from the controlling terminal; for the direct-emu path above you don't need it.

## Architecture Notes

The emulator (`o.emu`) is a hosted Inferno® - it runs as a process on your host OS and provides:
- Dis virtual machine (executes `.dis` bytecode)
- Virtual filesystem namespace
- Host filesystem access via `/`
- Network stack

Inferno® programs are written in Limbo and compiled to Dis bytecode (`.dis` files in `/dis`).

## The 64-bit Fix

The critical fix for 64-bit platforms was changing pool quanta from 31 to 127 in `emu/port/alloc.c` to handle 64-bit pointer alignment.

---

**Status: 64-bit Inferno® is working on x86_64 Linux, ARM64 Linux, ARM64 macOS, and x86_64 Windows**

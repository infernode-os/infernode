# Differences Between InferNode and Standard Inferno®

**Purpose:** Document how InferNode differs from canonical Inferno® OS

**Reference:** https://github.com/inferno-os/inferno-os (standard Inferno®).
The upstream import this tree started from is commit `46439007c`
("20060303-partial") in this repository's history.

## High-Level Differences

**Standard Inferno®:**
- 32-bit hosted emulator and native kernels for the hardware of its time
- Tk/wm graphical environment, Acme, Charon and demo applications
- A one-line `lib/sh/profile`; the user sets up the namespace

**InferNode:**
- 64-bit hosted emulator on macOS, Linux and Windows, plus Android and iOS
  builds
- JIT compilers for AMD64, ARM64 and RISC-V (`libinterp/comp-amd64.c`,
  `comp-arm64.c`, `comp-riscv64.c`), alongside upstream's 32-bit ones
- Native (bare-metal) kernels for AArch64 and RISC-V boards in `os/`
- An SDL3 graphics backend and a new desktop, Lucia; Tk remains the GUI
  toolkit
- Veltro AI agents and an LLM service exposed as a 9P filesystem
- An opinionated login profile that mounts the host filesystem, a durable
  user overlay, secstore, factotum and the LLM service

## Directory Structure Differences

### Present in the upstream import, absent here

**Application categories:** `appl/alphabet/`, `appl/collab/`, `appl/demo/`,
`appl/ebook/`, `appl/spree/`, `appl/tiny/`

**Libraries:** `libprefab/`, `libfreetype/`, `liblogfs/`, `libnandfs/`,
`libdynld/`

### Present in both

- `appl/cmd/`, `appl/lib/`, `appl/acme/`, `appl/wm/`, `appl/charon/`,
  `appl/grid/`, `appl/math/`, `appl/svc/`
- `emu/`, `lib9/`, `libbio/`, `libdraw/`, `libmemdraw/`, `libmemlayer/`,
  `libinterp/`, `libkeyring/`, `libsec/`, `libmp/`, `libmath/`, `libtk/`
- `limbo/`, `module/`, `fonts/`, `icons/`, `locale/`, `services/`

### Added in InferNode

- `appl/veltro/` — Veltro AI agent system
- `appl/xenith/` — Xenith text environment (Acme fork)
- `appl/matrix/` — Matrix compositional module runtime
- `appl/mpeg/` — MPEG decoding
- `os/` — native kernels: `os/arm64` and `os/riscv64` (architecture),
  `os/port` (portable kernel), boards `os/bcm2837` (Raspberry Pi 3B+),
  `os/bcm2711` (Pi 4B), `os/virt` and `os/riscvvirt` (QEMU), `os/mpfs`
  (PolarFire SoC). See [BAREMETAL.md](BAREMETAL.md).
- `emu/Android/`, `emu/iOS/` — mobile platform glue
- `formal-verification/` — TLA+, SPIN and CBMC models
- `docs/`, `tests/` — documentation and the test suites

The upstream import also tracked compiled bytecode in `dis/`. Here `dis/` is a
build product and is not tracked; see [QUICKSTART.md](../QUICKSTART.md).

## lib/sh/profile

**Standard Inferno®:** one line, `# emu sh initialisation here`.

**InferNode:** about 340 lines. On macOS, Linux and Windows it:
- mounts the host filesystem at `/n/local` with `trfs` and sets `home` to the
  host home directory;
- union-binds the durable overlay in `~/.infernode` over `/usr`, `/lib/ndb`,
  `/lib/veltro` and `/tmp` (see [PERSISTENCE.md](PERSISTENCE.md));
- starts `secstored` and `factotum`, and provisions API keys;
- starts `llmsrv` at `/mnt/llm`, or mounts a remote one, from `/lib/ndb/llm`;
- starts `speech9p`.

Scripts written for standard Inferno® run, but may find `/n/local`, `/mnt/llm`
and the overlay already in place.

## Utilities

`appl/cmd/` has about 210 `.b` files at its top level (more in subdirectories),
against 157 in the upstream import. Additions include `llmsrv`, `lucifer` and
its zone programs, `trfs`, `mail9p`, `auditfs` and `nsaudit`.

## Graphics

**Standard Inferno®:** Tk and wm on platform-specific display backends.

**InferNode:**
- SDL3 backend (`emu/port/draw-sdl3.c`) on macOS, Linux and Windows, and on
  Android and iOS
- Lucia, the three-zone desktop (`appl/cmd/lucifer.b`, booted by
  `sh -l /lib/lucifer/boot.sh`); see [LUCIA.md](LUCIA.md)
- Tk is the toolkit for GUI applications
- A headless build with no display, for servers and embedded use

## Cryptography

InferNode adds Ed25519 signatures (`libkeyring/ed25519alg.c`) and post-quantum
algorithms (ML-KEM, ML-DSA and SLH-DSA in `libsec/`, with keyring support in
`libkeyring/`). See
[CRYPTO-MODERNIZATION.md](CRYPTO-MODERNIZATION.md).

## Build System

Both use `mk`, the same mkfile structure and the `limbo` compiler. InferNode
builds through per-platform scripts (`build-macos-*.sh`, `build-linux-*.sh`,
`build-windows-*.ps1`, `build-android-*.sh`, `build-ios-*.sh`); the native
kernels build only through `tests/host/baremetal_test.sh` and
`tests/host/baremetal_riscv64_test.sh`.

## Commands Known to Differ

### Accessing Host Files

**Standard Inferno®:**
```
; mount -ac {mntgen} /n
; trfs '#U*' /n/local
; ls /n/local
```

**InferNode:**
```
; # Already mounted by the profile
; ls $home
```

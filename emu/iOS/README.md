# emu/iOS — the hellaphone iOS target

This directory is the iOS half of InferNode's mobile build (*hellaphone*),
sitting alongside `emu/Android/`, `emu/MacOSX/`, etc. It will host the
iOS platform glue that lets `o.emu` run inside an iOS app. The design
rationale lives in `docs/IOS.md`; this file tracks status and the
mechanics of the directory.

## Status

**Phase A — Simulator headless proof of life.** Scaffolded, not yet
built. This is the iOS analogue of Android Phase 0: instead of Termux
(which has no iOS equivalent), the cheapest signal is a headless `o.emu`
cross-compiled against the **iphonesimulator** SDK and run via
`xcrun simctl spawn` inside a booted simulator. It proves the
interpreter-only (`-c0`) Dis VM, 9P, and the Veltro harness work under
Apple's runtime before any UIKit/app-bundle investment.

> **Not yet compiled.** The scaffolding here was authored on a Linux
> box with no Xcode/iOS SDK, so nothing in this directory has been run
> through clang yet. The first build on a macOS host is expected to
> surface a small set of iOS-SDK gaps the same way Android Phase 0
> surfaced Bionic gaps — see "Expected gaps" below.

### The key idea: iOS forks from macOS, not Linux/Android

The Android port's cost was dominated by Bionic-vs-glibc differences.
iOS ships Apple's BSD-derived libc — the same family as macOS — so those
differences mostly vanish. Phase A therefore reuses `emu/MacOSX/` and
`emu/port/` sources **unchanged**, via `:N:` rules in `mkfile-g`:

| Object | Reused from |
| --- | --- |
| `os.c` | `../MacOSX/os.c` |
| `cmd.c` | `../MacOSX/cmd.c` |
| `asm-arm64.s` | `../MacOSX/asm-arm64.s` |
| `stubs-headless.c` | `../MacOSX/stubs-headless.c` |
| `deveia.c` | `../MacOSX/deveia.c` |
| `ipif.c` | `../FreeBSD/ipif.c` |
| `devfs.c` | `../port/devfs-posix.c` |

The platform headers under `iOS/arm64/include/` are one-line forwards
to their `MacOSX/arm64/include/` counterparts for the same reason
(single source of truth). The only genuinely iOS-specific files are
`mkfiles/mkfile-iOS-arm64` (the Xcode toolchain), this directory's
`emu` config and `mkfile-g`, and `build-ios-arm64.sh`.

Phase B forks any of the reused sources into this directory the moment
it needs iOS-specific code (most likely `cmd.c`, whose host fork/exec is
impossible under the iOS app sandbox).

### No JIT — interpreter only

Apple's W^X policy denies executable `mmap`/`mprotect` to stock apps, so
`libinterp/comp-arm64.c` cannot run on-device. emu must be launched
`-c0`. The `emu` config here also sets `macjit = 0`. Expect the perf hit
the JIT benchmark predicts (~3–9×); benchmark it early.

### Expected gaps (Phase A will surface these on first macOS build)

These are predictions from reading `emu/MacOSX/os.c`, not confirmed:

* `emu/MacOSX/os.c` includes `<architecture/ppc/cframe.h>`; the iOS SDK
  almost certainly does not ship the PPC arch headers. Likely the first
  failure, and the trigger to fork `os.c` into `emu/iOS/`.
* It calls Mach VM primitives (`vm_allocate`, `vm_machine_attribute`).
  `vm_allocate` is fine on iOS; `vm_machine_attribute` (instruction-cache
  flush, a JIT path) may be restricted — but `-c0` should never reach it.
* Framework link set: Phase A drops macOS's `-framework IOKit` (restricted
  on iOS) and keeps `CoreFoundation`. The real minimal set gets nailed
  down at first link.

Each confirmed gap should be gated and noted against `INFR-107`, exactly
as the Android Bionic gaps were.

## Phase B — device build + SDL3 GUI. Not started.

Will introduce:

* `os.c`, `cmd.c` — iOS-specific forks (compile out host fork/exec;
  whatever the Phase A gaps require).
* An Xcode app target linking the emu objects as `libemu.a` plus the
  Inferno C libs, providing `UIApplicationMain` and code-signing.
* SDL3 (UIKit + Metal) wired to `emu/port/draw-sdl3.c`, reusing the
  touch/HiDPI logic already added there for Android.
* Inferno root bundled read-only in the `.app`; writable state in the
  app container; `emu -r <bundle>/inferno`.

## Phase C — on-device `/n/llm`. Not started.

Same retarget Android Phase 1 plans: the 9P surface at `/n/llm` stays,
the backend swaps from Ollama-over-HTTP to on-device inference. iOS-native
options (MLX, CoreML) are stronger here than Android's.

## Build (Phase A)

On a Mac with Xcode, from the repo root, after the macOS host build has
produced `MacOSX/arm64/bin/{mk,limbo}`:

```sh
./build-ios-arm64.sh                  # simulator slice (default)
IOSSDK=iphoneos ./build-ios-arm64.sh  # device slice (unsigned)
```

Then, for the simulator slice:

```sh
xcrun simctl boot 'iPhone 15'
xcrun simctl spawn booted ./emu/iOS/o.emu -c0 -r"$PWD" sh -l
```

You should land in an Inferno `;` shell. If `cat /dev/sysname` works,
Phase A is done — capture it against `INFR-107`.

## References

* `docs/IOS.md` — full iOS port design plan.
* `docs/HELLAPHONE.md`, `emu/Android/README.md` — the Android sibling.
* `mkfiles/mkfile-iOS-arm64` — the Xcode cross-compile toolchain flags.
* `build-ios-arm64.sh` — this phase's build driver.
* `INFR-107` — hellaphone tracking epic.

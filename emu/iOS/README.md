# emu/iOS — the hellaphone iOS target

This directory is the iOS half of InferNode's mobile build (*hellaphone*),
sitting alongside `emu/Android/`, `emu/MacOSX/`, etc. It will host the
iOS platform glue that lets `o.emu` run inside an iOS app. The design
rationale lives in `docs/IOS.md`; this file tracks status and the
mechanics of the directory.

## Status

**Phase A — Simulator headless proof of life. DONE.** This is the iOS
analogue of Android Phase 0: instead of Termux (which has no iOS
equivalent), the cheapest signal is a headless `o.emu` cross-compiled
against the **iphonesimulator** SDK and run via `xcrun simctl spawn`
inside a booted simulator. It proves the interpreter-only (`-c0`) Dis
VM, 9P, and the Veltro harness work under Apple's runtime before any
UIKit/app-bundle investment.

> **Built and run** on macOS (Xcode 26 / iPhoneSimulator26.2 SDK, iOS 17.4
> simulator, Apple silicon). `o.emu` links as a `Mach-O 64-bit arm64`
> simulator binary; `xcrun simctl spawn booted ./emu/iOS/o.emu -c0
> -r$PWD /dis/echo.dis hello` prints, `cat /dev/sysname` returns the
> host sysname, and the Limbo test runner executes (`hello_test` 4/4,
> `veltro_test` 14/15 — the lone failures are sandbox file-write /
> subprocess-spawn limits, not VM or codegen issues). Getting there
> took five small fixes, listed under "Gaps surfaced" below — the
> first compile-and-run did the job Android Phase 0 did: turn
> predictions into a known, gated list.

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
| `ipif.c` | `../port/ipif6-posix.c` |
| `devfs.c` | `../MacOSX/devfs.c` (→ `../port/devfs-posix.c`) |

Reuse is done by a thin forwarding stub in this directory — each of
`emu/iOS/{os,cmd,stubs-headless,ipif,devfs}.c` is a one-line `#include`
of its origin, and `emu/iOS/asm-arm64.s` an assembler `.include`. (The
`:N:` rules in `mkfile-g` only record the dependency; they cannot
themselves supply a source — that's what the stubs are for.) The
platform headers under `iOS/arm64/include/` are the same one-line
forwards to `MacOSX/arm64/include/`. The only genuinely iOS-specific
files are `mkfiles/mkfile-iOS-arm64` (the Xcode toolchain), this
directory's `emu` config, `mkfile-g`, `deveia.c` (see below), and
`build-ios-arm64.sh`.

`deveia.c` is **not** reused from macOS: the macOS serial driver
enumerates ports via IOKit, absent from the iOS SDK, so `emu/iOS/deveia.c`
is a first-class iOS fork built on the portable BSD template (no host
serial ports in the sandbox; it presents zero ports). Phase B forks
more of the reused sources the moment they need iOS-specific code —
most likely `cmd.c`, whose host fork/exec is impossible under the iOS
app sandbox.

### No JIT — interpreter only

Apple's W^X policy denies executable `mmap`/`mprotect` to stock apps, so
`libinterp/comp-arm64.c` cannot run on-device. emu must be launched
`-c0`. The `emu` config here also sets `macjit = 0`. Expect the perf hit
the JIT benchmark predicts (~3–9×); benchmark it early.

### Gaps surfaced (Phase A, confirmed on first build)

The first cross-compile turned predictions into a concrete, gated list.
Five fixes, all small, none requiring an `os.c` fork (the predicted
`<architecture/ppc/cframe.h>` failure never happened — that include is
`#if defined(__ppc__)`-guarded, so it's inert on arm64):

1. **lib9 `getcallerpc-iOS-arm64.s`** — missing per-target placeholder
   (getcallerpc is inlined in `lib9.h`). Added the comment-only `.s`,
   mirroring the macOS one.
2. **libmath `FPcontrol-iOS.c`** — missing per-OS FP-control source.
   Forwards to `FPcontrol-MacOSX.c` (iOS shares the arm64 `fpuctl.h`).
3. **`libinterp/comp-arm64.c` JIT W^X** — the ARM64 JIT calls
   `pthread_jit_write_protect_np`, marked *unavailable on iOS*. Gated
   the macOS-only W^X dance behind `APPLE_JIT` (`__APPLE__ &&
   !IOS_ARM64`) so the codegen compiles via the generic mmap path. It
   is never invoked: iOS runs `-c0`, `macjit=0`. Inert off iOS.
4. **`emu/iOS/deveia.c` IOKit** — the macOS serial driver pulls in
   `<IOKit/*>` (no iOS SDK). Forked to the portable BSD template.
5. **`emu/port/ipif6-posix.c` `<net/if_arp.h>`** — header not shipped in
   the iOS SDK. Guarded the include with `#ifndef IOS_ARM64`; the only
   consumer is under `#ifdef SIOCGARP` (undefined on iOS, and already
   on modern macOS), so `arpadd()` takes its existing "arp not
   implemented" fallback. Inert off iOS.

Runtime quirk (non-fatal, not yet fixed): `getuser()` in the reused
`os.c` prints `cannot getpwuid` under the simulator sandbox (no passwd
entry for the uid) and falls through. Cosmetic for Phase A; a Phase B
`os.c` fork can default the user. Framework link set is `-lm -lpthread
-framework CoreFoundation` (macOS's `-framework IOKit` dropped, verified
unreferenced). All gated against `INFR-107`, as the Android Bionic gaps
were.

## Phase B — the app. In progress.

Sub-phased. B0/B1 run on the simulator (no signing). B3 (device) signs
under a paid Apple Developer team via a generated Xcode project.

**B0 — headless app shell. DONE.** A real iOS `.app` (not a bare binary
under `simctl spawn`) that boots emu `-c0` and runs the Limbo test
runner, proving the app-target + libemu + bundled-root mechanics.

* `libemu.a` — the emu objects archived instead of linked, built with
  `EMUOPTIONS=-DEMU_NO_MAIN` so `emu/port/main.c` exports `emu_run()`
  but not `main()` (`mk -f mkfile-g … libemu`). The app owns `main`.
* `emu/iOS/app/main_ios.m` — UIKit `UIApplicationMain` on the main
  thread; `emu_run()` runs on a detached pthread (headless `libinit()`
  never returns, so it can't sit on the main/UI thread).
* `emu/iOS/app/Info.plist` + `build-ios-app.sh` assemble the bundle,
  stage `dis/ tests/ lib/` under `<App>.app/root`, ad-hoc sign, install
  and `--verify` (launch + assert `hello_test` passes). No signing
  identity needed for the simulator.
* **Gotcha gated:** the installed-bundle path (~180 chars) overflows
  emu's `rootdir` buffer (`MAXROOT = 5*KNAMELEN = 140`), so the app
  `chdir()`s into the bundle root and passes `-r .` (devfs-posix
  resolves relative to the CWD). A future general fix would bump
  `MAXROOT` in `emu/port/dat.h`.

**B1 — SDL3 GUI (Lucifer). DONE (simulator).** `./build-ios-app.sh --gui`
builds a GUI `libemu` (GUIBACK=sdl3) linking the iOS SDL3 static lib
(`build-sdl3-ios.sh` → `~/sdks/SDL3-ios-sim-arm64`), and `main_ios_gui.m`
lets SDL3 bootstrap UIKit (`SDL_RunApp`); the desktop `sdl3_mainloop`
coexists with the iOS run loop, so no callback rewrite was needed.
Lucifer renders through SDL3/Metal. Key fixes: stage the boot's
mountpoint dirs (`/n /tmp /usr /mnt` — `mount {mntgen} /n` fails without
them); copy the read-only bundle root to the writable container at launch
(`umask 0`, chmod writable); and the `wordsperline` texture-stride fix in
`draw-sdl3.c` (odd 3x widths sheared the frame — see that commit).

**B2 — `os.c`/`cmd.c` iOS forks.** Default `getuser()` past the
`cannot getpwuid` warning; compile out host `fork`/`exec` (impossible
under the app sandbox — the boot's `os sh` calls fail). Not yet done;
the GUI runs without it (those calls fail non-fatally).

**B3 — device build + code-signing. In progress.** We have a paid Apple
Developer team (`TJ448C32Q3`), so iOS signing is available. Build the
device slice (`IOSSDK=iphoneos` for `build-ios-arm64.sh` +
`build-sdl3-ios.sh`, then the GUI `libemu`), generate a thin Xcode app
project from `project.yml` (`xcodegen generate`), and let Xcode automatic
signing mint the Apple Development cert + profile under the team. Build +
install to the device with Xcode's Run, or `xcodebuild
-allowProvisioningUpdates` + `xcrun devicectl device install`. Requires
Developer Mode on the device and the iOS platform component in Xcode.

## Phase C — on-device `/mnt/llm`. Not started.

Same retarget Android Phase 1 plans: the 9P surface at `/mnt/llm` stays,
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
xcrun simctl boot 'iPhone 15'        # or any installed device name
# proof of life — runs a Dis program under the -c0 interpreter:
xcrun simctl spawn booted ./emu/iOS/o.emu -c0 -r"$PWD" /dis/echo.dis hello from inferno on ios
xcrun simctl spawn booted ./emu/iOS/o.emu -c0 -r"$PWD" /dis/cat.dis /dev/sysname
# Limbo test runner (if tests are built — see CLAUDE.md "Testing System"):
xcrun simctl spawn booted ./emu/iOS/o.emu -c0 -r"$PWD" /tests/hello_test.dis
```

`cat /dev/sysname` returning the host sysname means Phase A is done —
capture it against `INFR-107`.

> **`simctl spawn` caveats** (learned the hard way): it forwards
> stdout/stderr but **not stdin**, so drive emu by passing the command
> as *arguments* (a `.dis` path, or `/dis/sh.dis -c '…'`) rather than
> piping a script into an interactive `sh`. And the simulator sandbox
> denies writes to the host repo path, so read results from **stdout**,
> not from a file under `-r$PWD`.

## Build (Phase B0 — the headless app)

After `./build-ios-arm64.sh` has produced `iOS/arm64/lib/*.a`, with a
simulator booted:

```sh
xcrun simctl boot 'iPhone 15'
./build-ios-app.sh --verify    # build .app, install, launch, assert PASS
```

`--verify` launches the app with `simctl launch --console-pty` and fails
unless `hello_test` prints `PASS`. Drop `--verify` to just build+install,
then launch yourself with `xcrun simctl launch --console-pty booted
os.infernode.ios`. The app's `main_ios.m` boots emu `-c0` on a worker
thread against the Inferno root bundled at `<App>.app/root`.

## References

* `docs/IOS.md` — full iOS port design plan.
* `docs/HELLAPHONE.md`, `emu/Android/README.md` — the Android sibling.
* `mkfiles/mkfile-iOS-arm64` — the Xcode cross-compile toolchain flags.
* `build-ios-arm64.sh` — this phase's build driver.
* `INFR-107` — hellaphone tracking epic.

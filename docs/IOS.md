# InferNode on iOS — hellaphone Phase 2

*Design plan, and the spec the work is built against. **Phase A
(simulator headless proof of life) is implemented and runs** — the
`-c0` Dis VM, 9P and Veltro execute under the iOS simulator; see
`emu/iOS/README.md` for the build, the gaps that surfaced, and how to
run it. Phases B and C below are still ahead.*

This is the iOS counterpart to `docs/HELLAPHONE.md` (Android) and the
Phase 2 referenced in `emu/Android/README.md`. The goal is the same:
run InferNode — the Dis VM, 9P, the Veltro agent harness, and
eventually the GUI — on a stock Apple handset. Parent tracking epic is
the hellaphone effort (`INFR-107`); a dedicated iOS phase ticket should
be filed when Phase A starts.

## The one thing to get right first: iOS forks from macOS, not Android

The Android port's cost was dominated by Bionic-vs-glibc gaps —
`ushort`/`uint` typedefs, `rewind` collision, `getdtablesize`, OSS
audio, `malloc_usable_size`'s `const` signature
(`emu/Android/README.md:21-43`). **Almost none of that applies to
iOS.** iOS ships Apple's BSD-derived libc, the same family macOS uses,
so the natural ancestor for every iOS platform file is its
`emu/MacOSX/` equivalent, not the Linux/Android one:

| iOS file (to create) | Fork from | Why |
| --- | --- | --- |
| `emu/iOS/os.c` | `emu/MacOSX/os.c` | Shared Apple libc; already marshals GUI work to the main thread (AppKit → UIKit is the same constraint), uses dispatch queues, handles SIGSEGV-as-Dis-fault the Apple way. |
| `emu/iOS/cmd.c` | `emu/MacOSX/cmd.c` | Same `getuser`/arg-handling shape; no Bionic `sysconf` substitutions needed. |
| `$ROOT/iOS/arm64/include/*` | `$ROOT/MacOSX/arm64/include/*` | Apple headers expose the BSD shorthands and `rewind` semantics Inferno expects; the Android lib9.h patches are unnecessary here. |
| `emu/iOS/mkfile`, `mkfile-gui-sdl3` | `emu/Linux/mkfile{,-gui-sdl3}` | Build wiring is OS-shaped, not libc-shaped; the SDL3 backend is identical. |
| `emu/iOS/asm-arm64.S`, `segflush-arm64.c` | `emu/Linux/` | ARM64 ISA + cache-flush are the same; thin reuse, same as Android Phase 1 plans. |

Two things are also *cheaper* on iOS than they were on Android:

- **Root filesystem.** An iOS `.app` bundle is a real readable POSIX
  directory, so the Inferno root ships as bundle resources and
  `emu -r <bundle>/inferno` + the existing `devfs-posix.c` just work.
  Android Phase 1 needs an AAsset bridge because its assets are zipped;
  iOS needs nothing equivalent. Writable state goes in the app's
  `Documents`/`Library` container.
- **Audio.** iOS uses the same CoreAudio/AVAudioEngine family as macOS,
  so the macOS audio path is a starting point, not a rewrite. (Phase A
  is headless; defer this to Phase B.)

## The four hard iOS constraints

1. **No JIT — interpreter only.** Apple's W^X policy denies stock apps
   the executable `mmap`/`mprotect` the JIT needs, so `comp-arm64.c` is
   unusable on-device. emu must boot `-c0` (pure interpreter). The
   `cflag` switch already exists in `emu/port/main.c`, so this is a
   launch/build default, not new code. Expect a perf hit: the repo's
   note cites ~9× worst case; Android's measured `-c1` vs `-c0` delta is
   ~3× (`docs/HELLAPHONE.md:380`). Acceptable for a UI/agent workload;
   benchmark early so we know the real number on Apple silicon.

2. **No Termux escape hatch — Phase 0 isn't free.** Android got a
   near-zero-cost proof of life by piggybacking `o.emu` on
   `emu/Linux/` inside Termux (`docs/HELLAPHONE.md:13-20`). iOS has no
   general-purpose userspace that will host a hand-built binary, so the
   first signal requires an Xcode project and a static-lib build of emu.
   We make that as cheap as possible by targeting the **iOS Simulator**
   first (see Phase A) — no code-signing, no provisioning, CI-able.

3. **Single process — no `fork`/`exec` of separate binaries.** emu
   already runs Dis "processes" as host pthreads (`kproc-pthreads.c`),
   so the VM is unaffected. What breaks is host-command exec via the
   `os` device — the same `setuid`/`setgid`-after-fork path that bit
   Android (`emu/Android/README.md:447-458`). On iOS we don't gate it,
   we compile it out: there is no host shell to exec into.

4. **GUI is UIKit + Metal, on the main thread.** SDL3 has a UIKit/Metal
   backend, and `emu/port/draw-sdl3.c` already carries the touch and
   HiDPI logical-vs-pixel fixes done *for Android*
   (`emu/port/draw-sdl3.c:85-100`) — that work transfers directly to
   iOS, which is also a touch + Metal target. macOS already marshals
   draw calls to the main thread; iOS keeps that requirement.

## Build approach (decided): mk cross-compile + thin Xcode wrapper

There is no `mk` on-device for iOS, so the C side is cross-compiled
from a macOS host using the Xcode toolchain, exactly mirroring the
Android NDK pattern. An Xcode app target then links the resulting
`libemu` and provides the bundle, entitlements, and UIKit entry point.
A hand-maintained Xcode project listing every emu source was rejected:
it diverges from the repo's mk build and is painful to keep in sync as
`emu/port/` changes.

The host is macOS, so `mkconfig` already resolves `SYSHOST=MacOSX`; we
drive the target explicitly, just like Android does:

```sh
# Device build
mk SYSTARG=iOS OBJTYPE=arm64 IOSSDK=iphoneos
# Simulator build (Apple-silicon host; arm64 sim slice)
mk SYSTARG=iOS OBJTYPE=arm64 IOSSDK=iphonesimulator
```

`mkconfig:20-21` then pulls `mkfiles/mkhost-MacOSX` (host tools) and
`mkfiles/mkfile-iOS-arm64` (target flags). That target mkfile is a fork
of `mkfiles/mkfile-Android-arm64`, swapping the NDK toolchain for
`xcrun`:

```
TARGMODEL=  Posix
TARGSHTYPE= sh
CPUS=       arm64
O=          o

# IOSSDK selects device vs simulator: iphoneos | iphonesimulator
SDKPATH=    `{xcrun --sdk $IOSSDK --show-sdk-path}
CC=         `{xcrun --sdk $IOSSDK -f clang} -c
# Triple gets the -simulator suffix for the sim SDK; mk picks one of
# the two CFLAGS blocks on $IOSSDK. Device:
#   -target arm64-apple-ios14.0
# Simulator:
#   -target arm64-apple-ios14.0-simulator
CFLAGS=     -g -O -fno-strict-aliasing -fstack-protector-strong \
            -isysroot $SDKPATH -arch arm64 \
            -I$ROOT/iOS/arm64/include -I$ROOT/include -fcommon
AR=         `{xcrun --sdk $IOSSDK -f ar}
LD=         `{xcrun --sdk $IOSSDK -f clang}
```

Output objects land under `$ROOT/iOS/arm64/` and are archived into
`libemu.a`, which the Xcode target links. (Unlike Android there is no
`o.emu` executable on-device — iOS apps are a bundle whose `main()`
lives in the app target and calls into libemu.)

## Phase plan

**Phase A — Simulator headless proof of life. ✅ DONE.** The iOS analog
of Android Phase 0, and the cheapest path to "does interpreter-only Dis
actually run under Apple's sandbox." It does.

- `mkfiles/mkfile-iOS-arm64` + `build-ios-arm64.sh` driver (modelled on
  `build-android-ndk-arm64.sh`) — built.
- Cross-compiles emu to a headless `o.emu` for `iphonesimulator`
  (`emu/iOS/{emu,mkfile-g}`, reusing `emu/MacOSX` + `emu/port` via
  forwarding stubs). Linked as `Mach-O 64-bit arm64`.
- Booted `-c0` under `xcrun simctl spawn`: runs Dis bytecode
  (`/dis/echo.dis`), reads the cons device (`cat /dev/sysname`), and
  executes the Limbo test runner (`hello_test` 4/4, `veltro_test`
  14/15). Five small SDK gaps surfaced and were gated — see
  `emu/iOS/README.md`. This was the load-bearing milestone: the VM, 9P,
  and Veltro work without the JIT, before any UI investment.
- Still ahead within Phase A: a Minimal app/XCTest target whose entry
  boots emu and runs the runner, and CI via `xcodebuild test` on a
  macOS runner. (The CLI `simctl spawn` path above already proves the
  runtime; the XCTest wrapper is what makes it a gating CI check.)

**Phase B — Device build + SDL3 GUI.**

- `emu/iOS/{os.c, cmd.c, mkfile, mkfile-gui-sdl3}` forked from the
  ancestors in the table above; compile out host `fork`/`exec`.
- SDL3 iOS framework wired to `emu/port/draw-sdl3.c` (reusing the
  Android touch/HiDPI logic); Metal renderer.
- Real app target: Inferno root bundled read-only, writable state in
  the container, dev-cert signing, run Lucia/Xenith on hardware.
- Force `-c0` at launch; confirm W^X — no `PROT_EXEC` mappings.

**Phase C — on-device `/n/llm` + polish.** Same retarget Android Phase
1 plans (`emu/Android/README.md:62-65`): the 9P surface at `/n/llm`
stays put, the backend swaps from Ollama-over-HTTP to something
on-device. iOS-native options are stronger than Android's here —
MLX or CoreML alongside `llama.cpp`. App Store/TestFlight
considerations (entitlements, no downloaded executable code) live in
this phase. Full design — engine trade-offs (MLX vs llama.cpp), the two
wiring options, and the Full Moon / MLX prior art — is in
`docs/IOS-ONDEVICE-LLM.md`.

## Open questions

- **Simulator vs device for first GUI signal.** The Apple-silicon
  simulator is more permissive about W+X than a device; do we want a
  device-only smoke test gating Phase B so we never accidentally rely
  on JIT-ish behavior the simulator tolerates?
- **One mkfile with `IOSSDK`, or two mkfiles** (`mkfile-iOS-arm64` +
  `mkfile-iOSsim-arm64`)? The `IOSSDK` variable keeps it to one file
  but the `-simulator` triple suffix makes the CFLAGS branch slightly
  ugly. Lean toward one file unless it gets unreadable.
- **GUI long game: SDL3 vs native UIKit.** Phase B uses SDL3 to reach
  pixels fastest and reuse Android's work. A native UIKit front-end
  over a headless + 9P core is more iOS-idiomatic (better text input,
  share sheet, multitasking) but much more work. Revisit after Phase B
  ships.
- **Minimum iOS version.** Pick the floor once we know which APIs
  `os.c` actually needs; start at iOS 14 and raise only if forced.
- **App Store posture.** A self-contained OS demo that runs no
  downloaded executable code is generally reviewable, but "terminal /
  runs code" apps draw scrutiny. Decide TestFlight-only vs. store
  submission before Phase C polish.

## What this is NOT (yet)

- Not an app you can install today — no Xcode project exists.
- Not JIT-accelerated, and won't be on stock devices — `-c0` is the
  contract.
- Not on-device inference — `/n/llm` retarget is Phase C.

## References

- `docs/HELLAPHONE.md` — Android Phase 0, the sibling effort.
- `emu/Android/README.md` — Phase 2 scoping note and the Bionic-gap
  catalogue iOS mostly sidesteps.
- `emu/MacOSX/os.c`, `emu/MacOSX/cmd.c` — the iOS ancestors.
- `emu/port/draw-sdl3.c` — cross-platform GUI backend with touch/HiDPI.
- `emu/port/main.c` — the `-c[0-9]` JIT-level flag.
- `mkfiles/mkfile-Android-arm64`, `mkconfig` — the cross-compile pattern.
- `INFR-107` — hellaphone tracking epic.

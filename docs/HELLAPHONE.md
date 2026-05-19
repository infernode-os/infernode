# Hellaphone — InferNode on a Phone

*Phase 0: Termux on Android.*

The goal of the hellaphone effort is to run InferNode — the Dis VM, the
ARM64 JIT, 9P, and the Veltro agent harness — on a stock mobile phone.
This document walks through getting the **Phase 0 proof of life** up on
real Android hardware via Termux.

If you are looking for the bigger picture, see `INFR-107` and
`emu/Android/README.md`.

## Why Termux for Phase 0

Termux is a Linux-like userspace that runs as a normal Android app. It
ships `clang`, `mk`-able C, ARM64 hardware, and a POSIX-ish filesystem.
That is enough to bootstrap `mk`, build `limbo`, build `o.emu`, and run
Dis bytecode — without writing any NDK or JNI code first. If this
doesn't work, no amount of NDK plumbing will save us, so we want to
learn that here.

Phase 1 introduces a real `emu/Android/` target with NDK toolchain and
a proper Android app shell. Phase 0's job is to de-risk that work.

## Prerequisites

* An ARM64 Android device (modern Android phones are all aarch64).
* **Termux from F-Droid** (recommended) or the modern Play Store
  build (`googleplay.2025.10.05` or later, `targetSdk=36`). The older
  Play Store Termux was frozen on an old Android API for years and
  could not `pkg install` reliably; Termux re-released a modern build
  in October 2025 that works for Phase 0. F-Droid remains the
  default channel for the wider Termux community.
  F-Droid: <https://f-droid.org/en/packages/com.termux/>.
* ~2 GB of free storage for the source tree and build outputs.
* A few hundred MB of RAM headroom while building.

## One-time Termux setup

Inside the Termux shell:

```sh
pkg update
pkg install -y clang make binutils pkg-config which perl git byacc
termux-setup-storage   # optional, lets you read ~/storage/shared
```

`byacc` is required for the limbo compiler grammar (`limbo.y`); without
it the build dies with `yacc: not found` after the C libraries finish.

If you want to clone over SSH, also `pkg install openssh`. HTTPS clone
works out of the box.

### Keep the device awake during the build

The Phase 0 build runs for several minutes. Android's Doze and Samsung
One UI's background-app management can suspend Termux while the screen
is off, stalling or killing the build. Before kicking off a long build,
acquire a wake-lock:

```sh
termux-wake-lock
```

Release it after the build finishes (or just close Termux):

```sh
termux-wake-unlock
```

If you are driving the build over `adb` + `ssh` from a host machine
(see `INFR-107` discussion notes for the canonical workflow), the
wake-lock is mandatory — otherwise the device sleeps and the ssh
session stalls.

## Build

```sh
cd ~
git clone https://github.com/infernode-os/infernode.git
cd infernode
./build-android-termux.sh         # headless build (recommended)
```

The script:

1. Confirms it is running on Termux (`uname -o` reports `Android`).
2. Bootstraps `mk` using `clang`, then uses `mk` for everything else.
3. Builds the core C libraries, the `limbo` compiler, the emulator
   (`o.emu`, headless), and the Limbo applications (commands, shell,
   Veltro tools).
4. Drops outputs into `Linux/arm64/bin/` and `emu/Linux/o.emu`.

The `Linux/` prefix is on purpose for Phase 0 — see
`emu/Android/README.md` for why.

Expect the first run to take 5–15 minutes depending on the device. The
bootstrap of `mk` is the slowest single step.

## Smoke test

From the same Termux shell:

```sh
./emu/Linux/o.emu -c1 -r$PWD sh -l
```

You should land in an Inferno shell prompt (`;` by default). Try:

```
; cat /dev/sysname
; echo hello from inferno on a phone
; ls /appl
```

If that works, **Phase 0 is done.** You have InferNode running on a
phone. Capture the output, attach it to `INFR-107`, and we move on.

## Troubleshooting

**`clang: command not found`** — you missed `pkg install clang`, or the
Termux PATH is broken. Open a fresh Termux session.

**`/bin/sh: not found`** during the build — your Termux is unusual.
The build script picks up `sh` via `command -v sh`; if that fails,
export `SHELL=$(command -v sh)` before running.

**`fatal error: 'sys/foo.h' file not found`** — Bionic does not ship
every Linux header. Note the missing header, capture the offending
compile command, and file it against `INFR-107`. This is the kind of
signal Phase 0 exists to surface; it tells us what `emu/Android/` will
actually have to wrap in Phase 1.

**Build hangs or OOMs partway through** — Android may be killing
Termux for memory pressure. Close other apps; if the device is very
old, try a `headless` build only and skip the Limbo applications step.

**SDL3 build fails** — Phase 0 defaults to headless. Do not try the
SDL3 path on Termux yet; Phase 1 will sort the display backend.

## What this is NOT

* It is not an Android app. There is no APK, no Activity, no
  notification — Termux just runs the binary in a terminal app. Phase
  1 produces an actual installable app.
* It is not on-device inference. `/n/llm` is not wired to anything
  useful on the phone yet; that retarget happens in Phase 1.
* It is not GUI. No Lucia, no Xenith on the phone yet. Headless only.

## References

* `emu/Android/README.md` — what eventually lives in that directory.
* `build-android-termux.sh` — the Phase 0 build driver.
* `build-linux-arm64.sh` — the Linux ARM64 driver we piggyback on.
* `INFR-107` — tracking epic.

# emu/Android — the hellaphone target

This directory is the home of InferNode's mobile build: a **phone-shaped
InferNode**, internally codenamed *hellaphone*. It sits alongside
`emu/Linux/`, `emu/MacOSX/`, `emu/Nt/`, etc., and will eventually host
the Bionic / NDK / JNI platform glue that lets `o.emu` run as a native
Android binary (and, downstream, inside an APK).

## Status

**Phase 0 — proof of life (Termux).** Active. Directory is
intentionally near-empty; the Termux build piggybacks on `emu/Linux/`
via `../../build-android-termux.sh`, because Termux on ARM64 Android is
close enough to ARM64 Linux that we don't need fresh platform code to
get `o.emu` running on a handset. This gives us the cheapest possible
signal that the JIT, Dis VM, 9P stack, and Veltro agent harness work on
the device before we invest in NDK plumbing.

See `docs/HELLAPHONE.md` for end-user setup.

### Phase 0 surfaced Bionic gaps (now in master)

Building on real hardware (Samsung Galaxy A55 5G, Android 16, Termux
`googleplay.2025.10.05`, byacc 2.0, clang 21) turned up three Bionic
vs glibc incompatibilities that the Linux ARM64 mkfile assumes away:

| File patched                     | Symbol                         | Why Bionic differs                                                                 |
| -------------------------------- | ------------------------------ | ---------------------------------------------------------------------------------- |
| `Linux/arm64/include/lib9.h`     | `ushort`, `uint` typedefs      | Bionic's `<sys/types.h>` does not expose the BSD shorthands even with `_BSD_SOURCE`. |
| `Linux/arm64/include/lib9.h`     | `#define rewind infrewind`     | Bionic's `<stdio.h>` declares `rewind(FILE*)` unconditionally; collides with limbo/typecheck.c. |
| `emu/Linux/audio-oss.c`          | `#ifdef __BIONIC__` stub branch | Bionic does not ship `<sys/soundcard.h>` — Android replaced OSS with AAudio years ago. |
| `emu/Linux/cmd.c`                | `sysconf(_SC_OPEN_MAX)`        | Bionic's `<unistd.h>` does not expose the BSD `getdtablesize()`; the POSIX `sysconf` equivalent works on both. |
| `emu/port/alloc.c`               | `const void *` parameter       | Bionic's `<malloc.h>` declares `size_t malloc_usable_size(const void *)`; the deliberate override needs to match — a `#define` rename would break dlopen'd consumers (libnss_systemd etc.). |

All three patches are no-ops on glibc / real-Linux ARM64 (gated either
on `__BIONIC__` or on the `lib9.h` rename pattern that has carried
half-a-dozen identifiers since Inferno's macOS port). The audio stub
returns "audio not supported" if anything actually opens `/dev/audio`,
which never fires in the Phase 0 headless boot path.

Expect more such gaps to surface as more of the tree compiles
(libinterp's JIT path, Veltro's network code, anything that calls a
glibc-only syscall wrapper). Each is captured against INFR-107.

**Phase 1 — native NDK build.** Not started. Will introduce:

* `os.c`, `cmd.c` — Bionic-aware versions of the Linux equivalents
  (`getuser`, no `/proc/self/exe` on some Android versions, signal
  handling differences).
* `asm-arm64.S`, `segflush-arm64.c` — likely thin reuses of the Linux
  ARM64 versions; included here once the NDK toolchain is wired up.
* `audio-*.c` — Android audio backend (OpenSL ES or AAudio) replacing
  OSS.
* `devfs.c`, `deveia.c` — Android-appropriate filesystem and serial
  device shims.
* `mkfile`, `mkfile-arm64` — paralleling `emu/Linux/mkfile{,-arm64}`.
* JNI shim (in `os/Android/` or similar) for Activity / Service entry,
  app lifecycle, and AAsset-based root filesystem.
* `build-android-ndk-arm64.sh` at the repo root, replacing the
  Termux-piggyback driver.

**Phase 1 also retargets `/mnt/llm`.** Today `llmsrv.dis` proxies to
Ollama-over-HTTP on the host. On a handset there is no host; the 9P
surface stays the same and the backend swaps to `llama.cpp` (or MLC /
MediaPipe) running on-device. Agents and tools see no change.

**Phase 2 — iOS.** Out of scope for now. Apple's W^X policy will force
interpreter-only execution (no ARM64 JIT), which is a real perf hit
(~9× per the existing JIT benchmark). Tracked separately when ready.

## Where the code actually is during Phase 0

When you run `./build-android-termux.sh` on a Termux device:

* `SYSHOST=Linux`, `OBJTYPE=arm64` — same as a Linux ARM64 build.
* The build pipeline routes through `emu/Linux/mkfile` (not this
  directory).
* Output binaries land in `$ROOT/Linux/arm64/bin/` and
  `$ROOT/emu/Linux/o.emu`.

That's deliberate. When this directory grows real platform code, the
driver will switch to `SYSHOST=Android` and output will move to
`$ROOT/Android/arm64/`.

## References

* `docs/HELLAPHONE.md` — user-facing Termux build guide.
* `INFR-107` — tracking epic.
* `AGENTS.md` — repo-wide conventions; mkfiles use `;` not `&&`, and
  Plan 9 / Inferno idioms are preferred over policy-heavy mediation.

# emu/Android — the hellaphone target

This directory is the home of InferNode's mobile build: a **phone-shaped
InferNode**, internally codenamed *hellaphone*. It sits alongside
`emu/Linux/`, `emu/MacOSX/`, `emu/Nt/`, etc., and hosts the Bionic /
NDK / JNI platform glue that lets `o.emu` run as a native Android
binary, and as `libemu.so` inside the APK (`android-app/`).

## Status

**Phase 0 — proof of life (Termux).** Done, and still built. The
Termux build piggybacks on `emu/Linux/` via
`../../build-android-termux.sh`, because Termux on ARM64 Android is
close enough to ARM64 Linux that no fresh platform code is needed to
get `o.emu` running on a handset. It was the cheapest signal that the
JIT, Dis VM, 9P stack, and Veltro agent harness work on the device
before the NDK plumbing (`.github/workflows/android-termux.yml`).

See `docs/HELLAPHONE.md` for end-user setup.

### Phase 0 surfaced Bionic gaps (now in master)

Building on real hardware (Samsung Galaxy A55 5G, Android 16, Termux
`googleplay.2025.10.05`, byacc 2.0, clang 21) turned up three Bionic
vs glibc incompatibilities that the Linux ARM64 mkfile assumes away
(the table lists the five patches they took):

| File patched                     | Symbol                         | Why Bionic differs                                                                 |
| -------------------------------- | ------------------------------ | ---------------------------------------------------------------------------------- |
| `Linux/arm64/include/lib9.h`     | `ushort`, `uint` typedefs      | Bionic's `<sys/types.h>` does not expose the BSD shorthands even with `_BSD_SOURCE`. |
| `Linux/arm64/include/lib9.h`     | `#define rewind infrewind`     | Bionic's `<stdio.h>` declares `rewind(FILE*)` unconditionally; collides with limbo/typecheck.c. |
| `emu/Linux/audio-oss.c`          | `#ifdef __BIONIC__` stub branch | Bionic does not ship `<sys/soundcard.h>` — Android replaced OSS with AAudio years ago. |
| `emu/Linux/cmd.c`                | `sysconf(_SC_OPEN_MAX)`        | Bionic's `<unistd.h>` does not expose the BSD `getdtablesize()`; the POSIX `sysconf` equivalent works on both. |
| `emu/port/alloc.c`               | `const void *` parameter       | Bionic's `<malloc.h>` declares `size_t malloc_usable_size(const void *)`; the deliberate override needs to match — a `#define` rename would break dlopen'd consumers (libnss_systemd etc.). |

All five patches are no-ops on glibc / real-Linux ARM64 (gated either
on `__BIONIC__` or on the `lib9.h` rename pattern that has carried
half-a-dozen identifiers since Inferno's macOS port). The audio stub
returns "audio not supported" if anything actually opens `/dev/audio`,
which never fires in the Phase 0 headless boot path.

Expect more such gaps to surface as more of the tree compiles
(libinterp's JIT path, Veltro's network code, anything that calls a
glibc-only syscall wrapper). Each is captured against INFR-107.

**Phase 1 — native NDK build and APK.** Done. In this directory:

* `os.c`, `cmd.c` — Bionic-aware versions of the Linux equivalents.
* `asm-arm64.S`, `segflush-arm64.c` (and `asm-amd64.S`,
  `segflush-amd64.c` for the x86_64 emulator image).
* `audio-aaudio.c` (AAudio) and `audio-sdl3.c` — Android audio
  backends replacing OSS.
* `devfs.c`, `deveia.c` — filesystem and serial device shims.
* `phonebridge.c` — the native side of the phone device; calls into
  `android-app/.../InfernodePhoneBridge.kt` over JNI.
* `mkfile-g`, `mkfile-arm64`, `mkfile-gui-sdl3`, `mkfile-gui-headless`
  — the build, including the `libemu.so` target the APK links.

Drivers at the repo root: `build-android-ndk-arm64.sh` and
`build-android-ndk-x86_64.sh` (standalone `o.emu` via the NDK, run with
`adb shell`), `build-sdl3-android.sh` (SDL3 for the GUI), and
`build-android-apk.sh` (`libemu.so` + assets + Gradle). The app shell,
JNI entry and asset extraction are in `android-app/` (see its README).
CI: `.github/workflows/android-apk.yml` builds a debug APK;
`android-release.yml` builds a signed AAB for Google Play on
`android-v*` tags.

**LLM backend.** `llmsrv`'s default backend is the Anthropic API
(`-b api`); `-b openai` points it at any OpenAI-compatible server
(Ollama, for instance). The 9P surface at `/mnt/llm` stays the same
whatever is behind it, so an on-device engine would slot in behind
`llmsrv` with no change to agents or tools.

**Phase 2 — iOS.** Lives in `emu/iOS/`; see `emu/iOS/README.md` and
`docs/IOS.md`. Apple's W^X policy forces interpreter-only execution
(`-c0`) there.

## Where the code actually is during Phase 0

When you run `./build-android-termux.sh` on a Termux device:

* `SYSHOST=Linux`, `OBJTYPE=arm64` — same as a Linux ARM64 build.
* The build pipeline routes through `emu/Linux/mkfile` (not this
  directory).
* Output binaries land in `$ROOT/Linux/arm64/bin/` and
  `$ROOT/emu/Linux/o.emu`.

That's deliberate. The NDK and APK builds use this directory
(`SYSTARG=Android`), and their output goes to `$ROOT/Android/<arch>/`
and `emu/Android/`.

## References

* `docs/HELLAPHONE.md` — user-facing guide (Termux, and the APK path).
* `android-app/README.md` — the APK.
* `INFR-107` — tracking epic.
* `AGENTS.md` — repo-wide conventions; mkfiles use `;` not `&&`, and
  Plan 9 / Inferno idioms are preferred over policy-heavy mediation.

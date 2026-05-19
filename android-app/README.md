# android-app — InferNode hellaphone APK

Phase 1c (INFR-110) of the hellaphone effort: package `o.emu` as an
installable Android application — home-screen icon, foreground service,
permissions, lifecycle.

## Layout

```
android-app/
├── settings.gradle.kts
├── build.gradle.kts          # top-level
├── gradle.properties
├── README.md                 # this file
└── app/
    ├── build.gradle.kts      # module: AGP/NDK/Kotlin config
    └── src/main/
        ├── AndroidManifest.xml
        ├── java/io/infernode/
        │   ├── Emu.kt                 # JNI bridge: System.loadLibrary("emu")
        │   ├── InfernodeActivity.kt   # interactive console
        │   └── InfernodeService.kt    # foreground daemon for 9P export
        ├── cpp/
        │   └── jni-emu.c              # JNI ↔ emu_run() shim
        ├── res/values/strings.xml
        ├── jniLibs/arm64-v8a/         # libemu.so dropped here by the build driver
        └── assets/                    # dis/ runtime tree, extracted on first launch
```

## How the build splits

The C / asm / mkfile-driven part of the build is **not** owned by
Gradle. The existing Inferno toolchain (`build-android-ndk-arm64.sh`,
`mkfiles/mkfile-Android-arm64`, `emu/Android/mkfile-g`) produces
`libemu.so`; Gradle's job is to package it.

```
build-android-apk.sh (follow-up driver)
    1. build-android-ndk-arm64.sh                  # cross-build libs + emu
    2. relink emu/Android/o.emu as libemu.so       # via the Phase 1c.2 mkfile flag
    3. cp libemu.so → android-app/app/src/main/jniLibs/arm64-v8a/
    4. cp -r dis/  → android-app/app/src/main/assets/inferno-root/dis/
    5. ./gradlew assembleDebug                     # Gradle does the rest
```

This keeps mk as the source of truth for the runtime build and Gradle
strictly responsible for the Android shell.

## Status — Phase 1c v1 (in flight)

What's in this scaffold:

* `settings.gradle.kts`, `build.gradle.kts`, `app/build.gradle.kts` —
  Gradle structure pinned to AGP 8.7 / Kotlin 2.0.20 / NDK r29 /
  minSdk 28 / compileSdk 35.
* `AndroidManifest.xml` — Activity + foreground Service, the four
  permissions we'll need (`RECORD_AUDIO`, `INTERNET`,
  `FOREGROUND_SERVICE` + `_DATA_SYNC`, `POST_NOTIFICATIONS`).
* `Emu.kt` — Kotlin object that loads `libemu.so` and declares the
  `external fun run(argv): Int`.
* `InfernodeActivity.kt` — text-only TextView placeholder. Extracts
  assets, requests RECORD_AUDIO, spawns a worker that calls
  `Emu.run("-c1 -r <filesDir> /dis/sh.dis")`.
* `InfernodeService.kt` — foreground service with sticky notification,
  runs the 9P daemon recipe from `docs/HELLAPHONE.md`.
* `jni-emu.c` — JNI signature, marshals Java argv → C argv → `emu_run`.

What's deferred (Phase 1c.2 / .3 commits on this branch):

* **`emu_run` extraction** from `emu/port/main.c`. main()'s body needs
  to become a callable `emu_run(int, char**)`. Today's main() does its
  own argv parsing, signal setup, exits via panic/_exits. Needs a
  delicate factoring pass before it's JNI-safe.
* **libemu.so target** in `emu/Android/mkfile-g`. A `-shared` variant
  alongside the executable.
* **`build-android-apk.sh`** wrapper at the repo root, orchestrating
  the C build → asset copy → `./gradlew assembleDebug` pipeline.
* **Asset extraction** in `InfernodeActivity.extractAssetsIfNeeded` —
  currently just creates a marker file. Need recursive
  `AssetManager.list()` walk into `filesDir/inferno-root/`.
* **Real UI** — TextView is a scaffold marker, not a deliverable.
  Compose-based terminal is the v2 follow-up.
* **CI gate** running `./gradlew assembleDebug` on the GitHub aarch64
  runner.

See INFR-110 for the full work list.

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
    └── src/
        ├── release/AndroidManifest.xml  # release overlay: strips SMS perms and the service
        └── main/
            ├── AndroidManifest.xml
            ├── java/io/infernode/
            │   ├── Emu.kt                    # JNI bridge: System.loadLibrary("emu")
            │   ├── AssetExtractor.kt         # unpacks the bundled Inferno tree into filesDir
            │   ├── InfernodeSplashActivity.kt # launcher: extracts assets, hands off to the SDL activity
            │   ├── InfernodeSDLActivity.kt   # SDL3-hosted GUI (Lucia)
            │   ├── InfernodeActivity.kt      # interactive Inferno shell
            │   ├── InfernodeService.kt       # foreground service scaffold for a 9P daemon
            │   ├── InfernodePhoneBridge.kt   # call origination for emu/Android/phonebridge.c
            │   ├── InfernodeSmsReceiver.kt   # inbound SMS (debug builds)
            │   └── InfernodeBiometric.kt     # BiometricPrompt for keyring/secstore unlock
            ├── java/org/libsdl/app/          # SDL3's Android Java layer
            ├── cpp/
            │   └── jni-emu.c                 # JNI ↔ emu_run() shim
            ├── res/values/
            ├── jniLibs/<abi>/                # libemu.so dropped here by the build driver
            └── assets/                       # Inferno runtime tree, extracted on first launch
```

## How the build splits

The C / asm / mkfile-driven part of the build is **not** owned by
Gradle. The existing Inferno toolchain (`build-android-ndk-arm64.sh`,
`mkfiles/mkfile-Android-arm64`, `emu/Android/mkfile-g`) produces
`libemu.so`; Gradle's job is to package it.

```
build-android-apk.sh
    1. build-android-ndk-arm64.sh                  # cross-build libs + emu
    2. relink emu/Android/o.emu as libemu.so       # libemu.so target in emu/Android/mkfile-g
    3. cp libemu.so → android-app/app/src/main/jniLibs/arm64-v8a/
    4. cp -r dis/  → android-app/app/src/main/assets/inferno-root/dis/
    5. ./gradlew assembleDebug                     # Gradle does the rest
```

This keeps mk as the source of truth for the runtime build and Gradle
strictly responsible for the Android shell.

## Status

Phase 1c is done; the APK builds and runs.

* Gradle structure pinned to AGP 8.13.2 / Gradle 8.13 / Kotlin 2.1.21 /
  NDK r29 / minSdk 28 / compileSdk 36 / targetSdk 36.
* `emu_run()` is factored out of `emu/port/main.c`; `jni-emu.c` calls
  it. `emu/Android/mkfile-g` has the `libemu.so` target.
* `build-android-apk.sh` at the repo root runs the C build, stages
  `libemu.so` and the asset tree, and runs `./gradlew assembleDebug`
  (`--release`, `--abi=`, `--skip-gradle` options).
* `InfernodeActivity.copyAssetTree` and `AssetExtractor.kt` extract the
  bundled tree into `filesDir/inferno-root/` on first launch.
* `InfernodeSDLActivity.kt` hosts the SDL3 GUI; the launcher is
  `InfernodeSplashActivity.kt`.
* CI: `.github/workflows/android-apk.yml` cross-builds, stages the
  assets and runs `./gradlew assembleDebug`.
* The release manifest overlay (`src/release/AndroidManifest.xml`)
  strips the SMS permissions and `InfernodeService` for the Play build.

See INFR-110 for the full work list.

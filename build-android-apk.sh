#!/bin/sh
#
# Phase 1c build driver — produces an installable InferNode APK.
#
# Orchestrates the cross-build + Gradle pipeline:
#
#   1. Cross-compile libs + o.emu via build-android-ndk-arm64.sh
#      (the Phase 1a/1b path).
#   2. Link libemu.so out of the same .o set, plus the JNI wrapper
#      at android-app/app/src/main/cpp/jni-emu.c.
#   3. Stage libemu.so into android-app/app/src/main/jniLibs/arm64-v8a/.
#   4. Stage the dis/ runtime tree into
#      android-app/app/src/main/assets/inferno-root/dis/ so the Activity
#      can extract it on first launch and hand it to emu via -r.
#   5. Invoke `./gradlew assembleDebug` if a JDK + Android SDK are
#      available; otherwise stop after staging and print the gradle
#      command for manual invocation.
#
# Output (when gradle runs):
#   android-app/app/build/outputs/apk/debug/app-debug.apk
#
# Prereqs:
#   * Android NDK r29 (ANDROID_NDK_HOME, default $HOME/Android/Sdk/ndk/android-ndk-r29)
#   * Host mk + limbo at Linux/amd64/bin/
#   * (Optional, for full APK) JDK 17+ and Android SDK 35 with build-tools.
#     The script tolerates the SDK being absent and tells the user what
#     to do.
#
# Usage (from repo root):
#   ./build-android-apk.sh                 # debug APK
#   ./build-android-apk.sh --release       # release variant (unsigned)
#   ./build-android-apk.sh --skip-gradle   # stage artefacts only
#
# See:
#   docs/HELLAPHONE.md             user-facing setup
#   emu/Android/README.md          target tree status
#   build-android-ndk-arm64.sh     standalone-binary driver
#   INFR-110                       Phase 1c epic
#

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"

GRADLE_TASK=assembleDebug
SKIP_GRADLE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release)     GRADLE_TASK=assembleRelease; shift ;;
        --skip-gradle) SKIP_GRADLE=1; shift ;;
        *)             echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

echo "=== InferNode APK build (Phase 1c) ==="
echo ""

# --- Step 1: NDK cross-build (libs + standalone o.emu) -------------------
echo "::: 1/4  Cross-compile libs + emu via build-android-ndk-arm64.sh"
"$ROOT/build-android-ndk-arm64.sh" > "$ROOT/build-android-apk.ndk.log" 2>&1 || {
    echo "ERROR: NDK cross-build failed. See build-android-apk.ndk.log" >&2
    tail -20 "$ROOT/build-android-apk.ndk.log" >&2
    exit 1
}
echo "    -> emu/Android/o.emu produced"

# --- Step 2: libemu.so (JNI shared library) ------------------------------
echo "::: 2/4  Link libemu.so (shared variant for JNI)"
export ROOT
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${HOME}/Android/Sdk/ndk/android-ndk-r29}"
export PATH="$ROOT/Linux/amd64/bin:$PATH"
(
    cd "$ROOT/emu/Android"
    rm -f libemu.so jni-emu.o
    "$ROOT/Linux/amd64/bin/mk" -f mkfile-g SYSTARG=Android OBJTYPE=arm64 libemu
)
if [ ! -f "$ROOT/emu/Android/libemu.so" ]; then
    echo "ERROR: libemu.so was not produced" >&2
    exit 1
fi
echo "    -> emu/Android/libemu.so produced"

# --- Step 3: Stage native lib + runtime assets into the APK tree ---------
echo "::: 3/4  Stage libemu.so + dis/ runtime into android-app/"
JNILIBS="$ROOT/android-app/app/src/main/jniLibs/arm64-v8a"
ASSETS="$ROOT/android-app/app/src/main/assets/inferno-root"
mkdir -p "$JNILIBS" "$ASSETS"

cp "$ROOT/emu/Android/libemu.so" "$JNILIBS/libemu.so"
echo "    -> $JNILIBS/libemu.so"

# Runtime tree shipped as APK assets. dis/ is the compiled bytecode
# (sh.dis, cat.dis, the veltro suite, etc.). lib/ has shell profile +
# font data + boot scripts. module/ has the .m interface files some
# apps consult at runtime. Other top-level dirs (appl/, tests/, src,
# etc.) are not needed at runtime and stay out of the APK to keep it
# small.
rm -rf "$ASSETS/dis" "$ASSETS/lib" "$ASSETS/module"
cp -a "$ROOT/dis"    "$ASSETS/dis"
[ -d "$ROOT/lib" ]    && cp -a "$ROOT/lib"    "$ASSETS/lib"    || true
[ -d "$ROOT/module" ] && cp -a "$ROOT/module" "$ASSETS/module" || true

ASSET_SIZE=$(du -sh "$ASSETS" | cut -f1)
echo "    -> $ASSETS ($ASSET_SIZE)"

# --- Step 4: Gradle assemble ---------------------------------------------
if [ "$SKIP_GRADLE" -eq 1 ]; then
    echo ""
    echo "::: 4/4  --skip-gradle: stopping after staging."
    echo "    Run later: cd android-app && ./gradlew $GRADLE_TASK"
    exit 0
fi

if ! command -v java >/dev/null 2>&1; then
    echo ""
    echo "::: 4/4  java not on PATH — gradle step skipped."
    echo "    Artefacts are staged. Install JDK 17+ and run:"
    echo "      cd android-app && ./gradlew $GRADLE_TASK"
    exit 0
fi

if [ ! -d "$ROOT/android-app/gradle/wrapper" ]; then
    echo ""
    echo "::: 4/4  Gradle wrapper not initialised."
    echo "    Run once: cd android-app && gradle wrapper --gradle-version 8.10"
    echo "    Then: ./gradlew $GRADLE_TASK"
    exit 0
fi

echo "::: 4/4  ./gradlew $GRADLE_TASK"
(
    cd "$ROOT/android-app"
    ./gradlew "$GRADLE_TASK"
)

# --- Summary -------------------------------------------------------------
APK="$ROOT/android-app/app/build/outputs/apk/debug/app-debug.apk"
[ "$GRADLE_TASK" = "assembleRelease" ] && \
    APK="$ROOT/android-app/app/build/outputs/apk/release/app-release-unsigned.apk"

echo ""
echo "=== Build Summary ==="
if [ -f "$APK" ]; then
    echo "SUCCESS: APK at $APK"
    ls -la "$APK"
    echo ""
    echo "Install on a connected device:"
    echo "  adb install -r $APK"
else
    echo "FAIL: APK not found at $APK"
    exit 1
fi

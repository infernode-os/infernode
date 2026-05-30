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
#   ./build-android-apk.sh                       # debug APK, arm64-v8a (phone hw)
#   ./build-android-apk.sh --release             # release variant (unsigned)
#   ./build-android-apk.sh --skip-gradle         # stage artefacts only
#   ./build-android-apk.sh --abi=x86_64          # build for Android emulator on x86 host
#   ./build-android-apk.sh --abi=both            # multi-arch APK (phone + emulator)
#
# See:
#   docs/HELLAPHONE.md             user-facing setup
#   emu/Android/README.md          target tree status
#   build-android-ndk-arm64.sh     standalone-binary driver (arm64-v8a)
#   build-android-ndk-x86_64.sh    same, x86_64 (emulator iteration)
#   INFR-110                       Phase 1c epic
#

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"

GRADLE_TASK=assembleDebug
SKIP_GRADLE=0
GUIBACK=${GUIBACK:-headless}
# ABI selection. Default arm64-v8a (matches phone hardware); --abi=x86_64
# builds for the Android emulator on an x86 host; --abi=both stages both.
# Internally each entry maps to an NDK build script + jniLibs subdir.
ABI=arm64-v8a
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release)     GRADLE_TASK=assembleRelease; shift ;;
        --skip-gradle) SKIP_GRADLE=1; shift ;;
        --gui)         GUIBACK="$2"; shift 2 ;;
        --gui=*)       GUIBACK="${1#--gui=}"; shift ;;
        --abi)         ABI="$2"; shift 2 ;;
        --abi=*)       ABI="${1#--abi=}"; shift ;;
        *)             echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# Expand the ABI selector into the list of architectures we'll loop over.
case "$ABI" in
    arm64-v8a) ABIS="arm64-v8a" ;;
    x86_64)    ABIS="x86_64" ;;
    both)      ABIS="arm64-v8a x86_64" ;;
    *)
        echo "unknown --abi value '$ABI' (expected arm64-v8a, x86_64, or both)" >&2
        exit 2
        ;;
esac

# Internal helpers: ABI → NDK driver script + Inferno OBJTYPE + SDL3 prefix.
ndk_script_for_abi() {
    case "$1" in
        arm64-v8a) echo "$ROOT/build-android-ndk-arm64.sh" ;;
        x86_64)    echo "$ROOT/build-android-ndk-x86_64.sh" ;;
    esac
}
objtype_for_abi() {
    case "$1" in
        arm64-v8a) echo arm64 ;;
        x86_64)    echo amd64 ;;
    esac
}
sdl3_prefix_for_abi() {
    case "$1" in
        arm64-v8a) echo "$HOME/sdks/SDL3-android-arm64" ;;
        x86_64)    echo "$HOME/sdks/SDL3-android-x86_64" ;;
    esac
}

# GUIBACK is exported so both the inner NDK cross-build (which runs the
# ABI-specific NDK driver in a subshell) and the direct mk invocation
# below pick it up. For sdl3, ensure SDL3 is built per-ABI and stage
# libSDL3.so into the matching jniLibs subdir alongside libemu.so so
# the APK has both at runtime.
export GUIBACK
if [ "$GUIBACK" = "sdl3" ]; then
    for abi in $ABIS; do
        sdl3_prefix=$(sdl3_prefix_for_abi "$abi")
        if [ ! -f "$sdl3_prefix/lib/libSDL3.so" ]; then
            echo "::: SDL3 not at $sdl3_prefix — building via build-sdl3-android.sh --abi=$abi"
            "$ROOT/build-sdl3-android.sh" --abi="$abi" || {
                echo "ERROR: SDL3 cross-build failed for $abi" >&2; exit 1; }
        fi
    done
fi

echo "=== InferNode APK build (Phase 1c) — ABIs: $ABIS ==="
echo ""

ASSETS="$ROOT/android-app/app/src/main/assets/inferno-root"
mkdir -p "$ASSETS"

# Per-ABI loop: NDK cross-build → libemu.so link → stage into jniLibs/$ABI/.
step=1
for abi in $ABIS; do
    objtype=$(objtype_for_abi "$abi")
    ndk_script=$(ndk_script_for_abi "$abi")
    sdl3_prefix=$(sdl3_prefix_for_abi "$abi")

    # --- Step 1.x: NDK cross-build for this ABI --------------------------
    echo "::: ${step}/4  [$abi] Cross-compile libs + emu via $(basename "$ndk_script")"
    log="$ROOT/build-android-apk.ndk-${abi}.log"
    "$ndk_script" > "$log" 2>&1 || {
        echo "ERROR: NDK cross-build failed for $abi. See $log" >&2
        tail -20 "$log" >&2
        exit 1
    }
    echo "    -> emu/Android/o.emu ($abi) produced"

    # --- Step 2.x: libemu.so for this ABI --------------------------------
    echo "::: ${step}/4  [$abi] Link libemu.so (shared variant for JNI)"
    export ROOT
    export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${HOME}/Android/Sdk/ndk/android-ndk-r29}"
    # Same host-mk autodetection as build-android-ndk-arm64.sh: Linux CI
    # has Linux/amd64/bin/mk; a Mac dev box has MacOSX/arm64/bin/mk.
    HOST_BIN=""
    for cand in Linux/amd64 MacOSX/arm64 MacOSX/amd64; do
        if [ -x "$ROOT/$cand/bin/mk" ]; then
            HOST_BIN="$ROOT/$cand/bin"
            break
        fi
    done
    if [ -z "$HOST_BIN" ]; then
        echo "ERROR: host mk not built under $ROOT/{Linux/amd64,MacOSX/arm64,MacOSX/amd64}/bin/." >&2
        exit 1
    fi
    export PATH="$HOST_BIN:$PATH"
    # NDK host tag for the mkfile-Android-arm64 TOOLCHAIN path.
    case "$(uname -s)" in
        Linux*)  NDK_HOST_TAG=linux-x86_64 ;;
        Darwin*) NDK_HOST_TAG=darwin-x86_64 ;;
        *) NDK_HOST_TAG=linux-x86_64 ;;
    esac
    MKARGS="SYSTARG=Android OBJTYPE=$objtype GUIBACK=$GUIBACK NDK_HOST_TAG=$NDK_HOST_TAG"
    if [ "$GUIBACK" = "sdl3" ]; then
        MKARGS="$MKARGS SDL3_PREFIX=$sdl3_prefix"
    fi
    # Darwin: case-insensitive APFS, see comment in
    # build-android-ndk-arm64.sh + mkfile-Android-arm64.
    case "$(uname -s)" in
        Darwin*) MKARGS="$MKARGS MACOSINF=caseinsensitive" ;;
    esac
    (
        cd "$ROOT/emu/Android"
        rm -f libemu.so jni-emu.o
        "$HOST_BIN/mk" -f mkfile-g $MKARGS libemu
    )
    if [ ! -f "$ROOT/emu/Android/libemu.so" ]; then
        echo "ERROR: libemu.so was not produced for $abi" >&2
        exit 1
    fi

    # --- Step 3.x: Stage into jniLibs/$abi/ ------------------------------
    JNILIBS="$ROOT/android-app/app/src/main/jniLibs/$abi"
    mkdir -p "$JNILIBS"
    cp "$ROOT/emu/Android/libemu.so" "$JNILIBS/libemu.so"
    echo "    -> $JNILIBS/libemu.so"

    # Stale libSDL3.so from a previous --gui sdl3 build would still be
    # packaged into a headless APK. Clear it out when not using SDL3.
    if [ "$GUIBACK" != "sdl3" ]; then
        rm -f "$JNILIBS/libSDL3.so"
    fi

    # SDL3 GUI: stage libSDL3.so next to libemu.so so Android's
    # PackageManager loads it before libemu.so resolves its symbols.
    # Without this libemu.so loads but `dlopen("libSDL3.so")` fails
    # inside System.loadLibrary("emu").
    if [ "$GUIBACK" = "sdl3" ]; then
        SDL3_SO=$(ls -1 "$sdl3_prefix/lib/"libSDL3.so* 2>/dev/null | head -1)
        if [ -z "$SDL3_SO" ] || [ ! -f "$SDL3_SO" ]; then
            echo "ERROR: libSDL3.so missing at $sdl3_prefix/lib/ for $abi" >&2
            exit 1
        fi
        cp "$SDL3_SO" "$JNILIBS/libSDL3.so"
        echo "    -> $JNILIBS/libSDL3.so (from $SDL3_SO)"
    fi
done

# Runtime tree shipped as APK assets. dis/ is the compiled bytecode
# (sh.dis, cat.dis, the veltro suite, etc.). lib/ has shell profile +
# boot scripts. module/ has the .m interface files some apps consult
# at runtime. fonts/ holds the bitmap subfonts + combined manifests
# every UI widget loads via Font.open("/fonts/combined/…") — without
# this, libdraw falls back to *default* and every font bind in
# boot-mobile.sh is a no-op (this is exactly what bit INFR-115).
# Other top-level dirs (appl/, tests/, src, etc.) are not needed at
# runtime and stay out of the APK to keep it small.
rm -rf "$ASSETS/dis" "$ASSETS/lib" "$ASSETS/module" "$ASSETS/fonts"
cp -a "$ROOT/dis"    "$ASSETS/dis"
[ -d "$ROOT/lib" ]    && cp -a "$ROOT/lib"    "$ASSETS/lib"    || true
[ -d "$ROOT/module" ] && cp -a "$ROOT/module" "$ASSETS/module" || true
[ -d "$ROOT/fonts" ]  && cp -a "$ROOT/fonts"  "$ASSETS/fonts"  || true

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

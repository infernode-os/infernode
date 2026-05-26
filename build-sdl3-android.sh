#!/bin/sh
# build-sdl3-android.sh — cross-compile SDL3 for Android arm64.
#
# Phase 2b.0 (hellaphone GUI). The InferNode SDL3 backend
# (emu/port/draw-sdl3.c) wants libSDL3.so on the link line. macOS and
# Linux pick that up from Homebrew / apt. Android has no equivalent
# system package, so we build SDL3 from source against the NDK
# toolchain.
#
# Output: $SDK_HOME/SDL3-android-arm64/{include,lib,share}
#   - lib/libSDL3.so       — shared library, packaged into the APK
#   - include/SDL3/SDL.h   — headers, consumed by emu's mkfile-gui-sdl3
#
# Idempotent: skips the download + build if the install marker exists.
# Re-run with `--force` to rebuild.

set -eu

VERSION=${SDL3_VERSION:-3.2.16}
SDK_HOME=${SDK_HOME:-$HOME/sdks}
SRC=$SDK_HOME/SDL3-$VERSION-src
NDK=${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/android-ndk-r29}

# ABI selection: arm64-v8a (default, for phone hardware) or x86_64 (for
# emulator iteration on x86_64 hosts now that the Android emulator no
# longer translates arm64 → x86). Pass --abi=<name> or set SDL3_ABI.
ABI=${SDL3_ABI:-arm64-v8a}
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force)   FORCE=1 ;;
        --abi=*)   ABI="${arg#--abi=}" ;;
    esac
done

case "$ABI" in
    arm64-v8a)  PREFIX=$SDK_HOME/SDL3-android-arm64 ;;
    x86_64)     PREFIX=$SDK_HOME/SDL3-android-x86_64 ;;
    *)
        echo "::error::unsupported ABI '$ABI' (expected arm64-v8a or x86_64)" >&2
        exit 2
        ;;
esac

if [ ! -d "$NDK" ]; then
    echo "::error::ANDROID_NDK_HOME not set or NDK not found at $NDK" >&2
    exit 1
fi

if [ $FORCE -eq 0 ] && [ -f "$PREFIX/lib/libSDL3.so" ]; then
    echo "::: SDL3 already installed at $PREFIX (use --force to rebuild)"
    exit 0
fi

mkdir -p "$SDK_HOME"

if [ ! -d "$SRC" ]; then
    echo "::: Downloading SDL3 $VERSION source"
    curl -fsSL \
        "https://github.com/libsdl-org/SDL/releases/download/release-$VERSION/SDL3-$VERSION.tar.gz" \
        | tar -xz -C "$SDK_HOME"
    mv "$SDK_HOME/SDL3-$VERSION" "$SRC"
fi

BUILD="$SRC/build-android-${ABI}"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

echo "::: Configuring SDL3 for Android $ABI (NDK at $NDK)"
cmake "$SRC" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM=android-28 \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSDL_SHARED=ON \
    -DSDL_STATIC=OFF \
    -DSDL_TEST_LIBRARY=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_INSTALL_TESTS=OFF \
    -DSDL_EXAMPLES=OFF \
    > cmake-configure.log 2>&1 || {
        echo "::error::SDL3 cmake configure failed" >&2
        tail -50 cmake-configure.log >&2
        exit 1
    }

echo "::: Building SDL3 (parallel)"
cmake --build . --parallel "$(nproc 2>/dev/null || echo 4)" \
    > cmake-build.log 2>&1 || {
        echo "::error::SDL3 build failed" >&2
        tail -50 cmake-build.log >&2
        exit 1
    }

echo "::: Installing SDL3 to $PREFIX"
cmake --install . > cmake-install.log 2>&1 || {
    echo "::error::SDL3 install failed" >&2
    tail -50 cmake-install.log >&2
    exit 1
}

# Sanity check: the .so must match the requested ABI's ELF e_machine.
SO="$PREFIX/lib/libSDL3.so"
if [ ! -f "$SO" ]; then
    # Some installs land it as libSDL3.so.0 or similar — check.
    SO=$(ls -1 "$PREFIX/lib/"libSDL3*.so* 2>/dev/null | head -1)
fi
if [ -z "$SO" ] || [ ! -f "$SO" ]; then
    echo "::error::libSDL3.so not produced under $PREFIX/lib" >&2
    exit 1
fi

# ELF magic at bytes 0-3 + EM_* at byte 18 (e_machine little-endian).
# arm64 → EM_AARCH64 = 0xb7;  x86_64 → EM_X86_64 = 0x3e.
case "$ABI" in
    arm64-v8a) want=b7 ;;
    x86_64)    want=3e ;;
esac
elfhex=$(head -c 19 "$SO" | od -An -tx1 | tr -d ' \n')
case "$elfhex" in
    7f454c46*${want}) ;;
    *) echo "::error::$SO is not $ABI ELF (hex=$elfhex, want e_machine=$want)" >&2; exit 1 ;;
esac

echo ""
echo "::: SDL3 $VERSION installed at $PREFIX"
ls -la "$PREFIX/lib/"libSDL3*.so* 2>/dev/null || true

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
PREFIX=$SDK_HOME/SDL3-android-arm64
SRC=$SDK_HOME/SDL3-$VERSION-src
NDK=${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/android-ndk-r29}

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
    esac
done

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

BUILD="$SRC/build-android-arm64"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

echo "::: Configuring SDL3 for Android arm64 (NDK at $NDK)"
cmake "$SRC" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
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

# Sanity check: the .so must be aarch64.
SO="$PREFIX/lib/libSDL3.so"
if [ ! -f "$SO" ]; then
    # Some installs land it as libSDL3.so.0 or similar — check.
    SO=$(ls -1 "$PREFIX/lib/"libSDL3*.so* 2>/dev/null | head -1)
fi
if [ -z "$SO" ] || [ ! -f "$SO" ]; then
    echo "::error::libSDL3.so not produced under $PREFIX/lib" >&2
    exit 1
fi

# ELF magic + EM_AARCH64 (0xb7) at byte 18.
elfhex=$(head -c 19 "$SO" | od -An -tx1 | tr -d ' \n')
case "$elfhex" in
    7f454c46*b7) ;;
    *) echo "::error::$SO is not aarch64 ELF (hex=$elfhex)" >&2; exit 1 ;;
esac

echo ""
echo "::: SDL3 $VERSION installed at $PREFIX"
ls -la "$PREFIX/lib/"libSDL3*.so* 2>/dev/null || true

#!/bin/sh
# build-sdl3-ios.sh — cross-compile SDL3 for iOS arm64 (hellaphone Phase 2b).
#
# The InferNode SDL3 backend (emu/port/draw-sdl3.c) wants SDL3 on the link
# line. macOS/Linux pick it up from Homebrew/apt; iOS has no system package,
# so we build SDL3 from source against the iOS SDK — the iOS analogue of
# build-sdl3-android.sh. Static lib (not a .dylib) so the Xcode app target
# links it straight in with nothing to embed or codesign.
#
# Output: $SDK_HOME/SDL3-ios-<sim|dev>-arm64/{include,lib,...}
#   - lib/libSDL3.a        — static library, linked into o.emu / the .app
#   - include/SDL3/SDL.h   — headers, consumed by emu/iOS/mkfile-gui-sdl3
#
# Usage (on a Mac with Xcode):
#   ./build-sdl3-ios.sh                  # iphonesimulator slice (default)
#   IOSSDK=iphoneos ./build-sdl3-ios.sh  # device slice
#   ./build-sdl3-ios.sh --force          # rebuild even if installed
#
# Idempotent: skips download + build if the install marker exists.

set -eu

VERSION=${SDL3_VERSION:-3.2.26}
SDK_HOME=${SDK_HOME:-$HOME/sdks}
IOSSDK=${IOSSDK:-iphonesimulator}
IOSMIN=${IOSMIN:-14.0}
SRC=$SDK_HOME/SDL3-$VERSION-src

case "$IOSSDK" in
    iphonesimulator) SLICE=sim ;;
    iphoneos)        SLICE=dev ;;
    *) echo "ERROR: IOSSDK must be iphonesimulator or iphoneos (got $IOSSDK)" >&2; exit 1 ;;
esac
PREFIX=$SDK_HOME/SDL3-ios-$SLICE-arm64

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
    esac
done

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: iOS builds require a macOS host." >&2
    exit 1
fi
if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found (brew install cmake)." >&2
    exit 1
fi
if ! xcrun --sdk "$IOSSDK" --show-sdk-path >/dev/null 2>&1; then
    echo "ERROR: SDK '$IOSSDK' not available (install Xcode)." >&2
    exit 1
fi

if [ $FORCE -eq 0 ] && [ -f "$PREFIX/lib/libSDL3.a" ]; then
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

BUILD="$SRC/build-ios-$SLICE-arm64"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

echo "::: Configuring SDL3 for iOS arm64 ($IOSSDK, min $IOSMIN)"
cmake "$SRC" \
    -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$IOSSDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOSMIN" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSDL_STATIC=ON \
    -DSDL_SHARED=OFF \
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
cmake --build . --parallel "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
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

LIB="$PREFIX/lib/libSDL3.a"
if [ ! -f "$LIB" ]; then
    LIB=$(ls -1 "$PREFIX/lib/"libSDL3*.a 2>/dev/null | head -1)
fi
if [ -z "${LIB:-}" ] || [ ! -f "$LIB" ]; then
    echo "::error::libSDL3.a not produced under $PREFIX/lib" >&2
    exit 1
fi

# Sanity: must be an arm64 Mach-O archive for the requested platform.
echo "::: Verifying $LIB"
lipo -info "$LIB" 2>/dev/null || true
if ! lipo -info "$LIB" 2>/dev/null | grep -q arm64; then
    echo "::error::$LIB is not an arm64 archive" >&2
    exit 1
fi

echo ""
echo "::: SDL3 $VERSION ($IOSSDK) installed at $PREFIX"
echo "    point emu/iOS/mkfile-gui-sdl3 at it with SDL3_PREFIX=$PREFIX"

#!/bin/sh
#
# Phase A build driver — InferNode for iOS arm64, cross-compiled with
# the Xcode toolchain on a macOS host. hellaphone Phase 2.
#
# This is the iOS analogue of build-android-ndk-arm64.sh. It builds a
# HEADLESS o.emu against the iphonesimulator SDK; you run it inside a
# booted simulator with `xcrun simctl spawn`, which is the cheapest
# possible signal that the interpreter-only (-c0) Dis VM, 9P stack, and
# Veltro harness work under Apple's runtime before any UIKit/app-bundle
# investment. The device build (Phase B) links the same objects into an
# Xcode app target — see emu/iOS/README.md.
#
# Outputs:
#   iOS/arm64/lib/*.a    cross-compiled Inferno C libraries
#   emu/iOS/o.emu        the headless emulator (simulator slice)
#
# Prereqs (all macOS-only — you cannot build for iOS off a Mac):
#   * Xcode + command-line tools; `xcrun` on PATH.
#   * A host mk + limbo tree at MacOSX/arm64/bin/ — produced by
#     ./makemk.sh + the macOS build on a fresh clone.
#
# Usage (from repo root, on a Mac):
#   ./build-ios-arm64.sh                 # simulator (default)
#   IOSSDK=iphoneos ./build-ios-arm64.sh # device slice (unsigned; for
#                                        # the Phase B Xcode app to link)
#
# See:
#   docs/IOS.md            full iOS port design plan
#   emu/iOS/README.md      directory status and phase plan
#   INFR-107               hellaphone tracking epic
#

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
export ROOT

echo "=== InferNode iOS build (hellaphone Phase 2, Phase A) ==="
echo ""

# --- Host must be macOS with Xcode -----------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: iOS builds require a macOS host (uname -s reports $(uname -s))." >&2
    echo "  The Xcode toolchain (xcrun/clang + iOS SDKs) exists only on macOS." >&2
    exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
    echo "ERROR: xcrun not found. Install Xcode and its command-line tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

# --- SDK / target selection ------------------------------------------------
# IOSSDK picks simulator vs device; IOSTRIPLE follows it. Both are passed
# to mk as COMMAND-LINE vars so they survive mkconfig's SYSTARG reassign
# (same trick as the Android driver).
: "${IOSSDK:=iphonesimulator}"
: "${IOSMIN:=14.0}"
case "$IOSSDK" in
    iphonesimulator) : "${IOSTRIPLE:=arm64-apple-ios${IOSMIN}-simulator}" ;;
    iphoneos)        : "${IOSTRIPLE:=arm64-apple-ios${IOSMIN}}" ;;
    *) echo "ERROR: IOSSDK must be iphonesimulator or iphoneos (got $IOSSDK)." >&2; exit 1 ;;
esac

if ! xcrun --sdk "$IOSSDK" --show-sdk-path >/dev/null 2>&1; then
    echo "ERROR: SDK '$IOSSDK' not available. Installed SDKs:" >&2
    xcrun --show-sdk-path 2>/dev/null || true
    exit 1
fi

# --- Host mk + limbo -------------------------------------------------------
if [ ! -x "$ROOT/MacOSX/arm64/bin/mk" ]; then
    echo "ERROR: host mk not built. Run ./makemk.sh + the macOS build first." >&2
    exit 1
fi
if [ ! -x "$ROOT/MacOSX/arm64/bin/limbo" ]; then
    echo "WARNING: host limbo not at MacOSX/arm64/bin/limbo." >&2
    echo "  Some appl/ builds compiling .b -> .dis may need it." >&2
fi

MK="$ROOT/MacOSX/arm64/bin/mk"
MKARGS="SYSTARG=iOS OBJTYPE=arm64 IOSSDK=$IOSSDK IOSTRIPLE=$IOSTRIPLE IOSMIN=$IOSMIN"

export PATH="$ROOT/MacOSX/arm64/bin:$PATH"
mkdir -p "$ROOT/iOS/arm64/bin" "$ROOT/iOS/arm64/lib"

echo "ROOT=$ROOT"
echo "IOSSDK=$IOSSDK  IOSTRIPLE=$IOSTRIPLE"
echo "SDK path=$(xcrun --sdk "$IOSSDK" --show-sdk-path)"
echo "host mk=$MK"
echo ""

# --- Cross-compile core C libraries ----------------------------------------
# Same ordering and stale-.o nuke as the Android driver: Inferno mkfiles
# drop .o next to the source, so a prior macOS-native build collides with
# the iOS cross-build. Brute force: delete before each rebuild. (The
# MacOSX/arm64/lib/*.a stays intact.)
echo "=== Cross-compiling C libraries ==="
for lib in lib9 libbio libmp libsec libmath libmemdraw libmemlayer libdraw libfreetype; do
    [ -d "$ROOT/$lib" ] || continue
    echo "Building $lib..."
    cd "$ROOT/$lib"
    find . -maxdepth 1 -name '*.o' -delete 2>/dev/null || true
    "$MK" $MKARGS install || { echo "ERROR: $lib build failed" >&2; exit 1; }
done

for lib in libinterp libkeyring; do
    [ -d "$ROOT/$lib" ] || continue
    echo "Building $lib..."
    cd "$ROOT/$lib"
    find . -maxdepth 1 -name '*.o' -delete 2>/dev/null || true
    "$MK" $MKARGS install || { echo "ERROR: $lib build failed" >&2; exit 1; }
done

# --- Cross-compile emulator ------------------------------------------------
echo ""
echo "=== Cross-compiling emulator (headless) ==="
cd "$ROOT/emu/iOS"
rm -f *.o *.emu emu.root.h emu.root.c emu.root.s 2>/dev/null || true
"$MK" -f mkfile-g $MKARGS || { echo "ERROR: emulator build failed" >&2; exit 1; }

# --- Summary ---------------------------------------------------------------
echo ""
echo "=== Build Summary ==="
if [ -x "$ROOT/emu/iOS/o.emu" ]; then
    echo "SUCCESS: emulator at $ROOT/emu/iOS/o.emu"
    ls -la "$ROOT/emu/iOS/o.emu"
    file "$ROOT/emu/iOS/o.emu" 2>/dev/null || true
    echo ""
    if [ "$IOSSDK" = "iphonesimulator" ]; then
        echo "Run it in a booted simulator:"
        echo "  xcrun simctl boot 'iPhone 15'   # or any installed device name"
        echo "  xcrun simctl spawn booted $ROOT/emu/iOS/o.emu -c0 -r$ROOT sh -l"
        echo ""
        echo "Smoke test inside the Inferno ';' shell:"
        echo "  ; cat /dev/sysname"
        echo "  ; echo hello from inferno on ios"
    else
        echo "This is an unsigned device slice. Phase B links it into an"
        echo "Xcode app target for code-signing + UIKit. See emu/iOS/README.md."
    fi
    echo ""
else
    echo "FAIL: o.emu not found. See errors above."
    exit 1
fi

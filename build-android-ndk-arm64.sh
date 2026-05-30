#!/bin/sh
#
# Phase 1a build driver — InferNode for Android arm64, cross-compiled
# via the Android NDK r29 on a Linux host.
#
# Unlike Phase 0 (build-android-termux.sh, which runs ON a Termux phone
# and links against Termux's $PREFIX/lib), this script runs on the
# desktop / CI host with the NDK toolchain installed, and produces an
# o.emu that links against Android's system Bionic at /system/lib64/.
# The binary can be pushed via adb and run as `adb shell /data/local/tmp/o.emu`
# — no Termux required.
#
# Outputs:
#   Android/arm64/lib/*.a        cross-compiled libs
#   emu/Android/o.emu            the emulator binary
#
# Prereqs:
#   * Android NDK r29 installed.  Default location:
#       $HOME/Android/Sdk/ndk/android-ndk-r29
#     Override with ANDROID_NDK_HOME if it lives elsewhere.
#   * A host mk + limbo binary tree at Linux/amd64/bin/ — produced
#     by ./makemk.sh + build-linux-amd64.sh on a fresh clone.
#
# Usage (from repo root):
#   ./build-android-ndk-arm64.sh
#
# See:
#   docs/HELLAPHONE.md             user-facing setup and 9P daemon recipe
#   emu/Android/README.md          directory status and phase plan
#   build-android-termux.sh        Phase 0 piggyback build driver
#   INFR-107                       tracking epic
#

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
export ROOT

echo "=== InferNode Android NDK build (Phase 1a) ==="
echo ""

# --- NDK + toolchain sanity ------------------------------------------------
: "${ANDROID_NDK_HOME:=${HOME}/Android/Sdk/ndk/android-ndk-r29}"
if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: Android NDK not found at $ANDROID_NDK_HOME" >&2
    echo "  Install r29 from https://developer.android.com/ndk/downloads" >&2
    echo "  or set ANDROID_NDK_HOME to point at an existing install." >&2
    exit 1
fi
export ANDROID_NDK_HOME

# Pick the right NDK host tag for the build machine. linux-x86_64 covers
# CI; darwin-x86_64 covers Apple Silicon Macs too (Apple's NDK ships
# x86_64 binaries that run under Rosetta — there is no arm64 NDK host
# slice yet as of r28).
case "$(uname -s)" in
    Linux*)  NDK_HOST_TAG=linux-x86_64 ;;
    Darwin*) NDK_HOST_TAG=darwin-x86_64 ;;
    *) echo "ERROR: unsupported build host $(uname -s)" >&2; exit 1 ;;
esac
CROSS_PREFIX="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST_TAG/bin"
if [ ! -x "$CROSS_PREFIX/aarch64-linux-android24-clang" ]; then
    echo "ERROR: NDK clang wrapper missing at $CROSS_PREFIX/aarch64-linux-android24-clang" >&2
    echo "  NDK install at $ANDROID_NDK_HOME may be incomplete." >&2
    exit 1
fi

# --- Host mk + limbo ------------------------------------------------------
# CI runs Linux; a Mac dev box has MacOSX/arm64/bin/ instead. Pick whichever
# is present; bail with a useful message if neither is.
HOST_BIN=""
for cand in Linux/amd64 MacOSX/arm64 MacOSX/amd64; do
    if [ -x "$ROOT/$cand/bin/mk" ]; then
        HOST_BIN="$ROOT/$cand/bin"
        break
    fi
done
if [ -z "$HOST_BIN" ]; then
    echo "ERROR: host mk not built." >&2
    echo "  Tried Linux/amd64, MacOSX/arm64, MacOSX/amd64 under $ROOT." >&2
    echo "  On Linux: run ./makemk.sh + build-linux-amd64.sh." >&2
    echo "  On macOS: run ./makemk.sh (the rest of the host tools come" \
         "with build-macos-sdl3.sh or build-macos-headless.sh)." >&2
    exit 1
fi
export PATH="$HOST_BIN:$PATH"
if [ ! -x "$HOST_BIN/limbo" ]; then
    echo "WARNING: host limbo not at $HOST_BIN/limbo." >&2
    echo "  Some appl/ builds compiling .b -> .dis may need it." >&2
fi

# --- Cross-compile environment --------------------------------------------
# SYSTARG / OBJTYPE must be passed to mk as COMMAND-LINE variables, not env.
# mkconfig reassigns `SYSTARG=$SYSHOST` after auto-detect, which clobbers any
# env value — but Plan 9 mk freezes command-line vars so they survive.
#
# GUIBACK selects the GUI backend. Default headless (Phase 0–2a). Set
# GUIBACK=sdl3 in the environment to build the Lucifer-capable variant
# (Phase 2b.0+); that requires SDL3 cross-built for Android arm64,
# which build-sdl3-android.sh produces.
: "${GUIBACK:=headless}"
MKARGS="SYSTARG=Android OBJTYPE=arm64 GUIBACK=$GUIBACK"

if [ "$GUIBACK" = "sdl3" ]; then
    : "${SDL3_PREFIX:=$HOME/sdks/SDL3-android-arm64}"
    if [ ! -f "$SDL3_PREFIX/lib/libSDL3.so" ]; then
        echo "ERROR: SDL3 not found at $SDL3_PREFIX/lib/libSDL3.so" >&2
        echo "  Run ./build-sdl3-android.sh first, or set SDL3_PREFIX." >&2
        exit 1
    fi
    export SDL3_PREFIX
    MKARGS="$MKARGS SDL3_PREFIX=$SDL3_PREFIX"
fi

mkdir -p "$ROOT/Android/arm64/bin" "$ROOT/Android/arm64/lib"

echo "ROOT=$ROOT"
echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
echo "host mk=$HOST_BIN/mk"
echo "cross CC=$CROSS_PREFIX/aarch64-linux-android24-clang"
echo ""

MK="$HOST_BIN/mk"

# --- Cross-compile core C libraries ---------------------------------------
# Order matters: lib9 first (everything depends on it), then libs that
# only need libc + lib9, then libs that need other libs.
echo "=== Cross-compiling C libraries ==="
for lib in lib9 libbio libmp libsec libmath libmemdraw libmemlayer libdraw libfreetype; do
    if [ ! -d "$ROOT/$lib" ]; then
        continue
    fi
    echo "Building $lib..."
    cd "$ROOT/$lib"
    # Strip any host-built .o files from a previous Linux/amd64 build.
    # Inferno's mkfiles put .o next to the .c source rather than under
    # $OBJDIR, so cross-compile and host-compile collide and stale .o
    # files get archived into Android/arm64/lib/lib%.a unchanged. Brute
    # force: nuke before each rebuild. (The lib*.a in
    # Linux/amd64/lib/ stays intact.)
    find . -maxdepth 1 -name '*.o' -delete 2>/dev/null || true
    "$MK" $MKARGS install || { echo "ERROR: $lib build failed" >&2; exit 1; }
done

# libinterp + libkeyring need limbo to compile some .m → .c modules,
# but we use the host limbo for that. The output objects are arm64.
for lib in libinterp libkeyring; do
    if [ -d "$ROOT/$lib" ]; then
        echo "Building $lib..."
        cd "$ROOT/$lib"
        find . -maxdepth 1 -name '*.o' -delete 2>/dev/null || true
        "$MK" $MKARGS install || { echo "ERROR: $lib build failed" >&2; exit 1; }
    fi
done

# --- Cross-compile emulator -----------------------------------------------
echo ""
echo "=== Cross-compiling emulator (GUIBACK=$GUIBACK) ==="
cd "$ROOT/emu/Android"
rm -f *.o *.emu emu.root.h emu.root.c emu.root.s 2>/dev/null || true
"$MK" -f mkfile-g $MKARGS || { echo "ERROR: emulator build failed" >&2; exit 1; }

# --- Summary --------------------------------------------------------------
echo ""
echo "=== Build Summary ==="
if [ -x "$ROOT/emu/Android/o.emu" ]; then
    echo "SUCCESS: emulator at $ROOT/emu/Android/o.emu"
    ls -la "$ROOT/emu/Android/o.emu"
    file "$ROOT/emu/Android/o.emu" 2>/dev/null || true
    echo ""
    echo "Push to device:"
    echo "  adb push $ROOT/emu/Android/o.emu /data/local/tmp/o.emu"
    echo "  adb shell chmod +x /data/local/tmp/o.emu"
    echo "  adb shell /data/local/tmp/o.emu -h    # or pass root with -r ..."
    echo ""
else
    echo "FAIL: o.emu not found. See errors above."
    exit 1
fi

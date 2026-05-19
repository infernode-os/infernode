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

CROSS_PREFIX="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [ ! -x "$CROSS_PREFIX/aarch64-linux-android24-clang" ]; then
    echo "ERROR: NDK clang wrapper missing at $CROSS_PREFIX/aarch64-linux-android24-clang" >&2
    echo "  NDK install at $ANDROID_NDK_HOME may be incomplete." >&2
    exit 1
fi

# --- Host mk + limbo ------------------------------------------------------
if [ ! -x "$ROOT/Linux/amd64/bin/mk" ]; then
    echo "ERROR: host mk not built. Run ./makemk.sh + build-linux-amd64.sh first." >&2
    exit 1
fi
if [ ! -x "$ROOT/Linux/amd64/bin/limbo" ]; then
    echo "WARNING: host limbo not at Linux/amd64/bin/limbo." >&2
    echo "  Some appl/ builds compiling .b -> .dis may need it." >&2
fi

# --- Cross-compile environment --------------------------------------------
# SYSTARG / OBJTYPE must be passed to mk as COMMAND-LINE variables, not env.
# mkconfig reassigns `SYSTARG=$SYSHOST` after auto-detect, which clobbers any
# env value — but Plan 9 mk freezes command-line vars so they survive.
MKARGS="SYSTARG=Android OBJTYPE=arm64"
export PATH="$ROOT/Linux/amd64/bin:$PATH"

mkdir -p "$ROOT/Android/arm64/bin" "$ROOT/Android/arm64/lib"

echo "ROOT=$ROOT"
echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
echo "host mk=$ROOT/Linux/amd64/bin/mk"
echo "cross CC=$CROSS_PREFIX/aarch64-linux-android24-clang"
echo ""

MK="$ROOT/Linux/amd64/bin/mk"

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
echo "=== Cross-compiling emulator (headless) ==="
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

#!/bin/bash
#
# Build InferNode for macOS ARM64 (SDL3 GUI mode)
#
# !!! CRITICAL TODO !!!
# The emu-hosted Limbo compiler (/dis/limbo.dis) produces BROKEN bytecode on ARM64!
# It generates smaller .dis files with invalid opcodes (BADOP errors at runtime).
#
# ALWAYS use the native Limbo compiler for building Limbo modules:
#   ./MacOSX/arm64/bin/limbo -I module -o output.dis source.b
#
# DO NOT use:
#   ./emu/MacOSX/o.emu -r. 'limbo ...'
#
# The hosted limbo.dis needs to be rebuilt for ARM64 compatibility.
# See: appl/cmd/limbo/ and dis/limbo.dis
# !!! END CRITICAL TODO !!!
#

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
export ROOT

echo "=== InferNode macOS ARM64 Build (SDL3 GUI) ==="
echo "ROOT=$ROOT"
echo ""

# Check SDL3 is installed
if ! pkg-config --exists sdl3 2>/dev/null; then
    echo "Error: SDL3 not found!"
    echo "Install with: brew install sdl3 sdl3_ttf"
    exit 1
fi

SDL3_VERSION=$(pkg-config --modversion sdl3)
echo "Found SDL3 version: $SDL3_VERSION"

# Set up environment for macOS ARM64
export SYSHOST=MacOSX
export OBJTYPE=arm64
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"
export AWK=awk
export SHELLNAME=sh

echo "Building for: SYSHOST=$SYSHOST OBJTYPE=$OBJTYPE"
echo "GUI Backend: SDL3"
echo ""

# Stamp build version (matches CI workflow). Anchor on the unstamped form so
# a second run cannot stamp an already-stamped string. Restore from a copy
# taken here rather than from git, so an in-progress edit to version.h
# survives the build.
BUILD_DATE=$(date +%Y%m%d)
SHORT_SHA=$(git -C "$ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo "local")
VERSION_H="$ROOT/include/version.h"
VERSION_H_SAVED=$(mktemp "${TMPDIR:-/tmp}/version.h.XXXXXX")
cp "$VERSION_H" "$VERSION_H_SAVED"
restore_version_h() {
    cp "$VERSION_H_SAVED" "$VERSION_H"
    rm -f "$VERSION_H_SAVED"
}
trap restore_version_h EXIT
sed -i '' "s|InferNode 0.1 (|InferNode 0.1 build ${BUILD_DATE}-${SHORT_SHA} (|" "$VERSION_H"
echo "Version: $(grep VERSION "$ROOT/include/version.h")"
echo ""

# mkhost-MacOSX sets NDATE=ndate and resolves it through PATH. BSD date has
# no -n, so without utils/ndate built the emulator compiles KERNDATE from an
# empty string and fails on `ulong kerndate = ;`. The EMUDIRS walk builds it
# before emu; these scripts go straight to the emulator, so build it here.
if [[ ! -x "$ROOT/MacOSX/arm64/bin/ndate" ]]; then
    echo "Building utils/ndate (needed for KERNDATE)..."
    (cd "$ROOT/utils/ndate" && mk install)
fi

# Build emulator
cd "$ROOT/emu/MacOSX"

echo "Cleaning previous build..."
mk clean 2>/dev/null || true

echo "Building SDL3 GUI emulator..."
mk GUIBACK=sdl3

if [[ -f o.emu ]]; then
    echo ""
    echo "=== Build Successful ==="
    ls -lh o.emu
    file o.emu
    echo ""
    echo "Checking SDL3 dependencies..."
    otool -L o.emu | grep -i sdl
    echo ""

    # Copy to InferNode for app bundle (macOS menu shows executable name)
    cp o.emu InferNode
    echo "Copied o.emu -> InferNode (for InferNode.app bundle)"
    echo ""
    echo "Run from terminal (standard dev path):"
    echo "  $ROOT/emu/MacOSX/o.emu -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r$ROOT sh -l /lib/lucifer/boot.sh"
    echo ""
    echo "  stdout/stderr stream to the terminal; Ctrl-C exits."
    echo ""
    echo "To test the .app packaging path (codesign skipped):"
    echo "  $ROOT/build-dev-bundle.sh"
    echo "  open --stdout /tmp/infernode-dev.out --stderr /tmp/infernode-dev.err /tmp/InferNode-dev.app"
else
    echo "Build failed!"
    exit 1
fi

#!/bin/bash
#
# Build InferNode for macOS, Apple silicon (arm64) or Intel (amd64), Headless mode
#

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
export ROOT

case $(uname -m) in
x86_64)	OBJTYPE=amd64 ;;
*)	OBJTYPE=arm64 ;;
esac

echo "=== InferNode macOS $OBJTYPE Build (Headless) ==="
echo "ROOT=$ROOT"
echo ""

# Set up environment for macOS
export SYSHOST=MacOSX
export OBJTYPE
export PATH="$ROOT/MacOSX/$OBJTYPE/bin:$PATH"
export AWK=awk
export SHELLNAME=sh

echo "Building for: SYSHOST=$SYSHOST OBJTYPE=$OBJTYPE"
echo "GUI Backend: headless (no display)"
echo ""

# Build emulator
cd "$ROOT/emu/MacOSX"

echo "Cleaning previous build..."
mk clean 2>/dev/null || true

echo "Building headless emulator..."
mk GUIBACK=headless

if [[ -f o.emu ]]; then
    echo ""
    echo "=== Build Successful ==="
    ls -lh o.emu
    file o.emu
    echo ""
    echo "Checking for SDL dependencies..."
    otool -L o.emu | grep -i sdl || echo "  ✓ No SDL dependencies (correct for headless)"
    echo ""
    echo "Run from terminal (headless, drops to Inferno shell):"
    echo "  $ROOT/emu/MacOSX/o.emu -c1 -r$ROOT sh -l"
else
    echo "Build failed!"
    exit 1
fi

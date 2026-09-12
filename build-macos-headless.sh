#!/bin/bash
#
# Build InferNode for macOS ARM64 (Headless mode)
#

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
export ROOT

echo "=== InferNode macOS ARM64 Build (Headless) ==="
echo "ROOT=$ROOT"
echo ""

# Set up environment for macOS ARM64
export SYSHOST=MacOSX
export OBJTYPE=arm64
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"
export AWK=awk
export SHELLNAME=sh

missing_tools=""
for tool in mk limbo; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools="${missing_tools:+$missing_tools }$tool"
    fi
done
if [[ -n "$missing_tools" ]]; then
    echo "Error: required native build tool(s) not found: $missing_tools" >&2
    echo "Bootstrap them from the repository root; the whole sequence takes about 30 seconds:" >&2
    echo '  export ROOT="$PWD" PATH="$PWD/MacOSX/arm64/bin:$PATH"' >&2
    echo '  SYSTARG=MacOSX OBJTYPE=arm64 ./makemk.sh' >&2
    echo '  for d in lib9 libbio libmp libsec libmath utils/iyacc limbo; do (cd $d && mk install); done' >&2
    echo "Then re-run this script." >&2
    exit 1
fi

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

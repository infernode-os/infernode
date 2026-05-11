#!/bin/sh
#
# Regression test: Verify Xenith dis files are correctly built
#
# This test ensures that xenith.dis and its submodules are properly compiled.
# A previous bug caused truncated dis files, resulting in hangs at startup.
#
# !!! IMPORTANT !!!
# On ARM64 macOS, you MUST use the native limbo compiler (MacOSX/arm64/bin/limbo).
# The emu-hosted limbo (/dis/limbo.dis) produces broken bytecode with invalid opcodes.
# See build-macos-sdl3.sh for details.
#
# The test compares xenith dis file sizes against acme equivalents since
# they share the same codebase structure. Xenith files should be equal or
# larger than acme (xenith has additional theme support code).

set -e

. "$(dirname "$0")/common.sh"
INFERNODE_ROOT="$ROOT"

# Check if limbo compiler exists
if [ ! -x "$LIMBO" ]; then
    echo "SKIP: limbo compiler not found at $LIMBO (run build-{linux,macos}-*.sh first)"
    exit 77
fi

echo "Testing Xenith build integrity..."

# Temporary directory for test builds
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Build xenith.dis fresh
echo "  Building xenith.dis..."
"$LIMBO" -I "$INFERNODE_ROOT/module" \
    -o "$TMPDIR/xenith.dis" \
    "$INFERNODE_ROOT/appl/xenith/xenith.b" 2>&1

# Check xenith.dis was created
if [ ! -f "$TMPDIR/xenith.dis" ]; then
    echo "FAIL: xenith.dis was not created"
    exit 1
fi

# Get sizes
XENITH_SIZE=$(stat -f%z "$TMPDIR/xenith.dis" 2>/dev/null || stat -c%s "$TMPDIR/xenith.dis")
ACME_SIZE=$(stat -f%z "$ROOT/dis/acme.dis" 2>/dev/null || stat -c%s "$ROOT/dis/acme.dis")

echo "  xenith.dis size: $XENITH_SIZE bytes"
echo "  acme.dis size:   $ACME_SIZE bytes"

# Xenith should be larger than or equal to acme (it has theme support)
if [ "$XENITH_SIZE" -lt "$ACME_SIZE" ]; then
    echo "FAIL: xenith.dis ($XENITH_SIZE) is smaller than acme.dis ($ACME_SIZE)"
    echo "      This indicates a build problem - xenith has more code than acme."
    exit 1
fi

# Minimum sanity check - xenith.dis should be at least 25KB
MIN_SIZE=25000
if [ "$XENITH_SIZE" -lt "$MIN_SIZE" ]; then
    echo "FAIL: xenith.dis ($XENITH_SIZE) is suspiciously small (< $MIN_SIZE bytes)"
    exit 1
fi

# Test a few key submodules
for mod in gui col row; do
    echo "  Building ${mod}.dis..."
    "$LIMBO" -I "$INFERNODE_ROOT/module" -I "$INFERNODE_ROOT/appl/xenith" \
        -o "$TMPDIR/${mod}.dis" \
        "$INFERNODE_ROOT/appl/xenith/${mod}.b" 2>&1

    if [ ! -f "$TMPDIR/${mod}.dis" ]; then
        echo "FAIL: ${mod}.dis was not created"
        exit 1
    fi

    XENITH_MOD_SIZE=$(stat -f%z "$TMPDIR/${mod}.dis" 2>/dev/null || stat -c%s "$TMPDIR/${mod}.dis")
    ACME_MOD_SIZE=$(stat -f%z "$ROOT/dis/acme/${mod}.dis" 2>/dev/null || stat -c%s "$ROOT/dis/acme/${mod}.dis")

    echo "    xenith/${mod}.dis: $XENITH_MOD_SIZE bytes"
    echo "    acme/${mod}.dis:   $ACME_MOD_SIZE bytes"

    # Allow 10% variance but xenith should not be dramatically smaller
    MIN_EXPECTED=$((ACME_MOD_SIZE * 9 / 10))
    if [ "$XENITH_MOD_SIZE" -lt "$MIN_EXPECTED" ]; then
        echo "FAIL: xenith/${mod}.dis is too small compared to acme/${mod}.dis"
        exit 1
    fi
done

echo "PASS: Xenith build integrity verified"
exit 0

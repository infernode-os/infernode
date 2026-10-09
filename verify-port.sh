#!/bin/bash
# Verification script for the 64-bit macOS port (arm64 or amd64)
# Tests that critical functionality works

echo "========================================="
echo "64-bit macOS Inferno Port Verification"
echo "========================================="
echo ""

cd "$(dirname "$0")"

# Check emulator exists
if [[ ! -f emu/MacOSX/o.emu ]]; then
    echo "❌ FAIL: emu/MacOSX/o.emu not found"
    exit 1
fi
echo "✅ Emulator binary exists"

# Check limbo exists
case $(uname -m) in x86_64) objtype=amd64 ;; *) objtype=arm64 ;; esac
if [[ ! -f MacOSX/${OBJTYPE:-$objtype}/bin/limbo ]]; then
    echo "❌ FAIL: limbo compiler not found"
    exit 1
fi
echo "✅ Limbo compiler exists"

# Check critical .dis files
MISSING=0
for f in dis/emuinit.dis dis/sh.dis dis/lib/readdir.dis dis/cat.dis dis/ls.dis dis/pwd.dis; do
    if [[ ! -f "$f" ]]; then
        echo "❌ MISSING: $f"
        MISSING=$((MISSING + 1))
    else
        echo "  OK: $f ($(wc -c < "$f") bytes)"
    fi
done
if [[ "$MISSING" -gt 0 ]]; then
    echo ""
    echo "Debugging: listing dis/ directory contents:"
    ls -la dis/*.dis 2>/dev/null || echo "  (no .dis files in dis/)"
    ls -la dis/lib/*.dis 2>/dev/null || echo "  (no .dis files in dis/lib/)"
    echo ""
    echo "❌ FAIL: $MISSING critical .dis file(s) missing"
    exit 1
fi
echo "✅ Critical .dis files present"

# Test simple output
echo ""
echo "Testing console output..."
timeout 3 ./emu/MacOSX/o.emu -r. test-stderr.dis 2>&1 | grep -q "STDERR: Hello" && \
    echo "✅ Console output works" || \
    echo "❌ FAIL: No console output"

# Test shell commands
echo ""
echo "Testing shell commands..."
TEST_OUTPUT=$(timeout 5 ./emu/MacOSX/o.emu -r. <<'SHELL' 2>&1 | grep -v DEBUG
pwd
date
cat /dev/sysctl
SHELL
)

echo "$TEST_OUTPUT" | grep -q "/" && echo "✅ pwd works" || echo "❌ pwd failed"
echo "$TEST_OUTPUT" | grep -q "202[0-9]" && echo "✅ date works" || echo "❌ date failed"
echo "$TEST_OUTPUT" | grep -q "Fourth Edition" && echo "✅ cat works" || echo "❌ cat failed"

# Test ls
echo ""
echo "Testing ls command..."
timeout 5 ./emu/MacOSX/o.emu -r. <<'SHELL' 2>&1 | grep -v DEBUG | grep -q "/dis/ls.dis" && \
    echo "✅ ls works" || \
    echo "❌ ls failed"
ls /dis
SHELL

echo ""
echo "========================================="
echo "Verification Complete"
echo "========================================="
echo ""
echo "If all checks passed, the port is working!"
echo ""
echo "To use Inferno:"
echo "  ./emu/MacOSX/o.emu -r."
echo ""
echo "See QUICKSTART.md for more information."

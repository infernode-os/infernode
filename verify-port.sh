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

FAILS=0
check() {	# check name pattern output
    if printf '%s\n' "$3" | grep -q "$2"; then
        echo "✅ $1 works"
    else
        echo "❌ FAIL: $1; emu said:"
        printf '%s\n' "$3" | sed 's/^/    /' | head -20
        FAILS=$((FAILS + 1))
    fi
}

# Run emu with its shell's input from ours, and print what it says.  It
# is stopped after 10 seconds if it has not finished: by hand, as macOS
# has no timeout(1).
emu() {
    local in out pid killer
    in=$(mktemp) out=$(mktemp)
    cat >"$in"
    ./emu/MacOSX/o.emu -r. <"$in" >"$out" 2>&1 &
    pid=$!
    ( sleep 10; kill -9 "$pid" ) >/dev/null 2>&1 &
    killer=$!
    wait "$pid" 2>/dev/null
    kill "$killer" 2>/dev/null
    grep -v DEBUG "$out"
    rm -f "$in" "$out"
}

# Test shell commands
echo ""
echo "Testing shell commands..."
TEST_OUTPUT=$(emu <<'SHELL'
pwd
date
cat /dev/sysctl
SHELL
)
check pwd '^; */$' "$TEST_OUTPUT"
check date '20[0-9][0-9]' "$TEST_OUTPUT"
check cat 'Fourth Edition' "$TEST_OUTPUT"

# Test ls
echo ""
echo "Testing ls command..."
LS_OUTPUT=$(emu <<'SHELL'
ls /dis
SHELL
)
check ls '/dis/ls.dis' "$LS_OUTPUT"

if [[ "$FAILS" -gt 0 ]]; then
    echo "❌ $FAILS check(s) failed"
    exit 1
fi

echo ""
echo "========================================="
echo "Verification Complete"
echo "========================================="
echo ""
echo "All checks passed."
echo ""
echo "To use Inferno:"
echo "  ./emu/MacOSX/o.emu -r."
echo ""
echo "See QUICKSTART.md for more information."

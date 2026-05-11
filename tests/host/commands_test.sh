#!/bin/sh
# Systematically test all compiled utilities

. "$(dirname "$0")/common.sh"

echo "Testing all utilities in dis/*.dis"
echo "===================================="

cd "$ROOT"

FAILED=0
PASSED=0

for cmd in dis/*.dis; do
    CMD_NAME=$(basename "$cmd" .dis)

    # Skip special files
    case "$CMD_NAME" in
        emuinit|sh|test-*|acme|broke|dos|g|hg|hp|lc|lcmd|lookman|man|sig|src)
            continue
            ;;
    esac

    printf "Testing %s... " "$CMD_NAME"

    # Try running with -h or --help or no args
    timeout 2 "$EMU" -r. "$cmd" 2>&1 | grep -qi "usage\|badop\|illegal"
    RESULT=$?

    if [ $RESULT -eq 0 ]; then
        # Got usage or error
        timeout 2 "$EMU" -r. "$cmd" 2>&1 | grep -qi "badop\|illegal"
        if [ $? -eq 0 ]; then
            echo "❌ FAIL (illegal instruction)"
            FAILED=$((FAILED + 1))
        else
            echo "✓ OK (shows usage)"
            PASSED=$((PASSED + 1))
        fi
    else
        echo "✓ OK (runs)"
        PASSED=$((PASSED + 1))
    fi
done

echo ""
echo "===================================="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "===================================="

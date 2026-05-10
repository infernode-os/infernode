#!/bin/sh
#
# run-tests.sh - InferNode Test Suite Runner
#
# This is the outer harness that runs:
#   1. Host tests (tests/host/*_test.sh) - POSIX sh on host
#   2. Internal tests (tests/runner.dis) - Limbo + Inferno sh inside emu
#
# Usage:
#   ./run-tests.sh           Run all tests
#   ./run-tests.sh -h        Run only host tests
#   ./run-tests.sh -i        Run only internal (emu) tests
#   ./run-tests.sh -v        Verbose output
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   77 - Skip (no tests found or prerequisite missing)
#

set -e

# Find root directory
ROOT="$(cd "$(dirname "$0")" && pwd)"
export ROOT

# Platform detection
case "$(uname -s)" in
    Darwin) _EMUHOST=MacOSX ;;
    Linux)  _EMUHOST=Linux ;;
    *)      echo "Unsupported OS"; exit 1 ;;
esac

# Configuration
HOST_TESTS_DIR="$ROOT/tests/host"
EMU_PATH=""
if [ -x "$ROOT/emu/$_EMUHOST/o.emu" ]; then
    EMU_PATH="$ROOT/emu/$_EMUHOST/o.emu"
fi
RUNNER_DIS="/dis/tests/runner.dis"
VERBOSE=0
RUN_HOST=1
RUN_INTERNAL=1

# Counters
HOST_PASSED=0
HOST_FAILED=0
HOST_SKIPPED=0
INTERNAL_PASSED=0
INTERNAL_FAILED=0
INTERNAL_SKIPPED=0

# Colors (if terminal supports it)
if test -t 1; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

usage() {
    echo "Usage: $0 [-h] [-i] [-v]"
    echo "  -h    Run only host tests"
    echo "  -i    Run only internal (emu) tests"
    echo "  -v    Verbose output"
    exit 1
}

# Parse arguments
while getopts "hiv" opt; do
    case $opt in
        h)
            RUN_HOST=1
            RUN_INTERNAL=0
            ;;
        i)
            RUN_HOST=0
            RUN_INTERNAL=1
            ;;
        v)
            VERBOSE=1
            ;;
        *)
            usage
            ;;
    esac
done

echo "========================================"
echo "InferNode Test Suite"
echo "========================================"
echo ""

# Run host tests
run_host_tests() {
    echo "=== HOST TESTS ==="

    if [ ! -d "$HOST_TESTS_DIR" ]; then
        echo "No host tests directory found at $HOST_TESTS_DIR"
        return
    fi

    # Find all *_test.sh files
    for test_script in "$HOST_TESTS_DIR"/*_test.sh; do
        [ -f "$test_script" ] || continue

        test_name=$(basename "$test_script" _test.sh)
        printf '=== HOST  %s\n' "$test_name"

        # Run the test
        if [ "$VERBOSE" = "1" ]; then
            if "$test_script"; then
                printf '%s--- PASS: %s%s\n' "$GREEN" "$test_name" "$NC"
                HOST_PASSED=$((HOST_PASSED + 1))
            else
                status=$?
                if [ "$status" = "77" ]; then
                    printf '%s--- SKIP: %s%s\n' "$YELLOW" "$test_name" "$NC"
                    HOST_SKIPPED=$((HOST_SKIPPED + 1))
                else
                    printf '%s--- FAIL: %s%s\n' "$RED" "$test_name" "$NC"
                    HOST_FAILED=$((HOST_FAILED + 1))
                fi
            fi
        else
            if output=$("$test_script" 2>&1); then
                printf '%s--- PASS: %s%s\n' "$GREEN" "$test_name" "$NC"
                HOST_PASSED=$((HOST_PASSED + 1))
            else
                status=$?
                if [ "$status" = "77" ]; then
                    printf '%s--- SKIP: %s%s\n' "$YELLOW" "$test_name" "$NC"
                    HOST_SKIPPED=$((HOST_SKIPPED + 1))
                else
                    printf '%s--- FAIL: %s%s\n' "$RED" "$test_name" "$NC"
                    HOST_FAILED=$((HOST_FAILED + 1))
                    # Print output on failure
                    echo "$output" | sed 's/^/    /'
                fi
            fi
        fi
    done

    echo ""
}

# Run internal tests via emu
run_internal_tests() {
    echo "=== EMU TESTS ==="

    # Check if emulator exists
    if [ -z "$EMU_PATH" ] || [ ! -x "$EMU_PATH" ]; then
        echo "Emulator not found in emu/$_EMUHOST/"
        echo "Run 'mk' in emu/$_EMUHOST to build first"
        return 1
    fi

    # Check if runner.dis exists
    if [ ! -f "$ROOT/dis/tests/runner.dis" ]; then
        echo "runner.dis not found"
        echo "Run 'mk' in tests/ to build first"
        return 1
    fi

    # Build emu args
    EMU_ARGS="-r$ROOT"
    if [ "$VERBOSE" = "1" ]; then
        RUNNER_ARGS="-v"
    else
        RUNNER_ARGS=""
    fi

    # Run the emulator with the test runner
    # Capture output and parse results
    echo ""

    if output=$("$EMU_PATH" $EMU_ARGS "$RUNNER_DIS" $RUNNER_ARGS 2>&1); then
        emu_status=0
    else
        emu_status=$?
    fi

    # Print output
    echo "$output"

    # Parse the summary line to extract counts
    # Format: "Total:          X passed, Y failed, Z skipped"
    if total_line=$(echo "$output" | grep "^Total:"); then
        INTERNAL_PASSED=$(echo "$total_line" | sed 's/.*Total:[[:space:]]*\([0-9]*\) passed.*/\1/')
        INTERNAL_FAILED=$(echo "$total_line" | sed 's/.*passed, \([0-9]*\) failed.*/\1/')
        INTERNAL_SKIPPED=$(echo "$total_line" | sed 's/.*failed, \([0-9]*\) skipped.*/\1/')
    fi

    echo ""
    return $emu_status
}

# Main execution
OVERALL_STATUS=0

if [ "$RUN_HOST" = "1" ]; then
    run_host_tests || true
fi

if [ "$RUN_INTERNAL" = "1" ]; then
    run_internal_tests || OVERALL_STATUS=1
fi

# Print final summary
echo "========================================"
echo "Summary"
echo "========================================"

if [ "$RUN_HOST" = "1" ]; then
    printf 'Host tests:     %d passed, %d failed, %d skipped\n' \
        "$HOST_PASSED" "$HOST_FAILED" "$HOST_SKIPPED"
fi

if [ "$RUN_INTERNAL" = "1" ]; then
    printf 'Internal tests: %d passed, %d failed, %d skipped\n' \
        "$INTERNAL_PASSED" "$INTERNAL_FAILED" "$INTERNAL_SKIPPED"
fi

TOTAL_PASSED=$((HOST_PASSED + INTERNAL_PASSED))
TOTAL_FAILED=$((HOST_FAILED + INTERNAL_FAILED))
TOTAL_SKIPPED=$((HOST_SKIPPED + INTERNAL_SKIPPED))

printf 'Total:          %d passed, %d failed, %d skipped\n' \
    "$TOTAL_PASSED" "$TOTAL_FAILED" "$TOTAL_SKIPPED"

echo ""

if [ "$TOTAL_FAILED" -gt 0 ] || [ "$OVERALL_STATUS" != "0" ]; then
    printf '%sFAIL%s\n' "$RED" "$NC"
    exit 1
fi

if [ "$TOTAL_PASSED" -eq 0 ]; then
    printf '%sNO TESTS%s\n' "$YELLOW" "$NC"
    exit 77
fi

printf '%sPASS%s\n' "$GREEN" "$NC"
exit 0

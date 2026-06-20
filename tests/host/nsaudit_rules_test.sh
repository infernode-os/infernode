#!/bin/bash
#
# tests/host/nsaudit_rules_test.sh
#
# One test per nsaudit rule (INFR-18). Each rule has a fixture directory
# under tests/nsaudit-rules/<rule>/ shaped like a live /tool mount, plus
# an `expect` file naming the rule that fixture is designed to trigger.
# This runs `nsaudit -m` (machine-readable) against each fixture and
# asserts the expected `violation=<RULE>` record appears in the output.
#
# nsaudit exits nonzero when it finds high-severity violations, so we key
# off the output, not the exit code.
#
# Does NOT require the LLM service. Run from project root:
#   ./tests/host/nsaudit_rules_test.sh [-v]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
SH="/dis/sh.dis"
VERBOSE=0

while getopts "v" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        *) echo "Usage: $0 [-v]"; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

PASSED=0; FAILED=0; SKIPPED=0
pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED+1)); }
info() { [[ "$VERBOSE" -eq 1 ]] && echo "  $1" || true; }

echo -e "${BOLD}nsaudit rule tests${NC}"
echo ""

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
[[ -f "$ROOT/dis/nsaudit.dis" ]] || {
    skip "nsaudit.dis not found"
    echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped"; exit 0; }

RULESDIR="$ROOT/tests/nsaudit-rules"
for d in "$RULESDIR"/*/; do
    name="$(basename "$d")"
    [[ -f "$d/expect" ]] || { skip "$name (no expect file)"; continue; }
    want="$(tr -d ' \t\r\n' < "$d/expect")"
    log="/tmp/.nsaudit-${name}.log"
    # nsaudit may exit nonzero on high-severity findings; capture output regardless.
    timeout 30 "$EMU" -r"$ROOT" "$SH" -c \
        "path=(/dis/veltro /dis/cmd /dis .); nsaudit -m /tests/nsaudit-rules/$name" \
        </dev/null >"$log" 2>&1
    out="$(cat "$log")"
    if grep -q "violation=${want}\b" "$log"; then
        pass "$name -> $want"
    else
        fail "$name: expected violation=$want, got:"
        info "$out"
    fi
done

echo ""
echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped"
[[ "$FAILED" -eq 0 ]]

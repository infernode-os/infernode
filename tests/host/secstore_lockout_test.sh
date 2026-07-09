#!/bin/sh
#
# Regression test for secstored failed-attempt lockout.
#
# Control coverage: NIST SP 800-53 AC-7 (unsuccessful logon attempts) /
# SP 800-171 3.5.x / CC FIA_AFL.1. secstored is the single place a secstore
# password is verified over the wire, so it throttles online guessing: after
# Maxfail (10) consecutive wrong-password attempts an account is temporarily
# locked for Locksecs (60s), rejecting further attempts before any crypto.
#
# This test creates an account, makes more than Maxfail wrong-password attempts
# with the real secstore client, and asserts the server (a) locks the account at
# the threshold and (b) rejects subsequent attempts while locked. Assertions key
# off secstored's own log lines (captured from the same emu), so they do not
# depend on the client's error text.
#
# Skips cleanly when the emulator has not been built (e.g. a source-only
# checkout); runs in CI where emu is present.
#
set -e

ROOT="${ROOT:-.}"
. "$(dirname "$0")/common.sh"

USER="testuser-lockout"
CORRECT="correcthorse-battery-staple"
WRONG="wrongpass-guessing"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 0
fi

# Free the secstore port and clear prior state for a reproducible run.
lsof -ti :5356 2>/dev/null | xargs kill 2>/dev/null || true
sleep 1
rm -rf "$ROOT/usr/inferno/secstore/$USER" 2>/dev/null || true

FAILURES=0
TESTS=0
pass() { TESTS=$((TESTS + 1)); echo "PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL: $1"; }
check() {
    if echo "$2" | grep -q "$3"; then
        pass "$1"
    else
        fail "$1 (expected '$3' in output)"
        echo "  got: $(echo "$2" | tail -8)"
    fi
}

# Exit 124 (timeout) is tolerated: secstored is a background service that never
# exits, so the emu run is bounded by timeout and the captured output is used.
run_emu() {
    OUTPUT=$(timeout "$1" "$EMU" -r"$ROOT" -c0 sh "$2" 2>&1 || true)
    echo "$OUTPUT"
}

echo "=== secstored failed-attempt lockout (AC-7 / FIA_AFL.1) ==="

mkdir -p "$ROOT/tmp"

# 12 wrong attempts: #10 crosses the threshold (server logs "locked after"),
# #11 and #12 are refused before crypto (server logs "rejected locked account").
cat > "$ROOT/tmp/test_lockout.sh" << EOF
load std
bind -a '#I' /net
ndb/cs
auth/secstored &
sleep 2
auth/secstore-setup -u $USER -k $CORRECT
echo '--- begin wrong-password attempts ---'
for(i in 1 2 3 4 5 6 7 8 9 10 11 12){
	echo $WRONG | auth/secstore -i -u $USER -s tcp!localhost!5356 x factotum >[2=1]
}
echo '--- end wrong-password attempts ---'
EOF

OUTPUT=$(run_emu 90 /tmp/test_lockout.sh)

check "account locks at the failed-attempt threshold" "$OUTPUT" "locked after"
check "attempts are rejected while the account is locked" "$OUTPUT" "rejected locked account"

lsof -ti :5356 2>/dev/null | xargs kill 2>/dev/null || true
rm -rf "$ROOT/usr/inferno/secstore/$USER" 2>/dev/null || true

echo ""
echo "$((TESTS - FAILURES))/$TESTS passed"
if [ "$FAILURES" -eq 0 ]; then
    echo "=== PASS ==="
else
    echo "=== FAIL ==="
    exit 1
fi

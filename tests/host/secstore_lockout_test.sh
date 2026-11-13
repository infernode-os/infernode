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
checkabsent() {
    if echo "$2" | grep -q "$3"; then
        fail "$1 (unexpected '$3' in output)"
        echo "  got: $(echo "$2" | tail -8)"
    else
        pass "$1"
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
sleep 1

# Scenario 2 (reset on success): a handful of wrong attempts BELOW the threshold
# must not lock the account, and a subsequent correct password must still
# authenticate. This is the other half of FIA_AFL.1 — the control must bound
# attackers without penalising a legitimate user who fumbles a few times.
cat > "$ROOT/tmp/test_reset.sh" << EOF
load std
bind -a '#I' /net
ndb/cs
auth/secstored &
sleep 2
auth/secstore-setup -u $USER -k $CORRECT
echo '--- 3 wrong attempts (below the threshold) ---'
for(i in 1 2 3){
	echo $WRONG | auth/secstore -i -u $USER -s tcp!localhost!5356 x factotum >[2=1]
}
echo '--- now the correct password ---'
echo $CORRECT | auth/secstore -i -u $USER -s tcp!localhost!5356 t >[2=1]
echo '--- reset scenario done ---'
EOF

OUTPUT2=$(run_emu 60 /tmp/test_reset.sh)

checkabsent "a few wrong attempts do not lock a legitimate account" "$OUTPUT2" "locked after"
check "correct password authenticates despite prior failures" "$OUTPUT2" "authenticated: $USER"

lsof -ti :5356 2>/dev/null | xargs kill 2>/dev/null || true
rm -rf "$ROOT/usr/inferno/secstore/$USER" 2>/dev/null || true
sleep 1

# Scenario 3 (adversarial abort): a guessing client can read the server verifier
# and then close before sending k'. That still means it failed to prove knowledge
# of the password and must count toward the same lockout threshold.
cat > "$ROOT/tmp/test_abort_lockout.sh" << EOF
load std
bind -a '#I' /net
ndb/cs
auth/secstored &
sleep 2
auth/secstore-setup -u $USER -k $CORRECT
echo '--- abort after server verifier attempts ---'
/tests/secstore_abort_probe.dis $USER 10
echo '--- prove the account is now locked ---'
echo $WRONG | auth/secstore -i -u $USER -s tcp!localhost!5356 x factotum >[2=1]
echo '--- abort scenario done ---'
EOF

OUTPUT3=$(run_emu 90 /tmp/test_abort_lockout.sh)

check "abort-after-verifier attempts lock the account" "$OUTPUT3" "locked after"
check "post-abort attempts are rejected while locked" "$OUTPUT3" "rejected locked account"

lsof -ti :5356 2>/dev/null | xargs kill 2>/dev/null || true
rm -rf "$ROOT/usr/inferno/secstore/$USER" 2>/dev/null || true
sleep 1

# Scenario 4 (an m outside the group): the client's m must be between 0 and p.
# Zero in any spelling but the probe's "0" was taken, and made the shared
# secret 0 whatever the server chose: its verifier, sent next, was then the
# hash of things the client knows and the password's own verifier, so one
# connection let the password be searched for with no further word to the
# server. Refused, said to be bad, and counted as a failed attempt.
cat > "$ROOT/tmp/test_badm.sh" << EOF
load std
bind -a '#I' /net
ndb/cs
auth/secstored &
sleep 2
auth/secstore-setup -u $USER -k $CORRECT
echo '--- m outside the group ---'
/tests/secstore_abort_probe.dis -m 'AA==' $USER
/tests/secstore_abort_probe.dis -m 'AAAAAAAA' $USER
/tests/secstore_abort_probe.dis -m '!!!!' $USER
echo '--- an m inside it is still answered ---'
/tests/secstore_abort_probe.dis -m 'AQ==' $USER
echo '--- and the right password still authenticates ---'
echo $CORRECT | auth/secstore -i -u $USER -s tcp!localhost!5356 t >[2=1]
echo '--- bad m scenario done ---'
EOF

OUTPUT4=$(run_emu 60 /tmp/test_badm.sh)

check "an m of zero is refused" "$OUTPUT4" "m-probe AA==: reply begins '!bad m"
check "zero in another spelling is refused" "$OUTPUT4" "m-probe AAAAAAAA: reply begins '!bad m"
check "an m that is no number is refused" "$OUTPUT4" "m-probe !!!!: reply begins '!bad m"
check "an m in the group is answered" "$OUTPUT4" "m-probe AQ==: reply begins mu="
check "the server says it refused an m outside the group" "$OUTPUT4" "rejected m outside the group"
check "the right password authenticates after them" "$OUTPUT4" "authenticated: $USER"

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

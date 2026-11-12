#!/bin/sh
#
# secstored refuses a PAK m that is not in the group.
#
# A client that knows no password sends m = p (or 2p): m*Hi is then 0
# mod p, so sigma is 0 whatever y is, and the server's k is a function
# of the password alone, to be guessed against off line from one
# connection. m = p-1 is of order 2 and leaves the subgroup too. The
# server must answer each with an error and no verifier; the real
# client must still log in.
#
# tests/secstore_badm_probe.b is the client; it tries the guesses given
# (the right password among them) against whatever k it is sent.
#
set -e

ROOT="${ROOT:-.}"
. "$(dirname "$0")/common.sh"

USER="testuser-badm"
CORRECT="correcthorse-battery-staple"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 0
fi

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
        echo "  got: $(echo "$2" | grep "$3" | head -3)"
    else
        pass "$1"
    fi
}

echo "=== secstored refuses an m outside the group ==="

mkdir -p "$ROOT/tmp"
cat > "$ROOT/tmp/test_badm.sh" << EOF
load std
bind -a '#I' /net
ndb/cs
auth/secstored &
sleep 2
auth/secstore-setup -u $USER -k $CORRECT
for(m in p 2p p-1){
	/tests/secstore_badm_probe.dis $USER \$m password letmein $CORRECT hunter2 >[2=1]
}
echo '--- the real client ---'
echo $CORRECT | auth/secstore -i -u $USER -s tcp!localhost!5356 t >[2=1]
echo '--- done ---'
EOF

OUTPUT=$(timeout 90 "$EMU" -r"$ROOT" -c0 sh /tmp/test_badm.sh 2>&1 || true)

checkabsent "no password recovered from a verifier for a bad m" "$OUTPUT" "recovered:"
check "m = p refused" "$OUTPUT" "m=p: refused"
check "m = 2p refused" "$OUTPUT" "m=2p: refused"
check "m = p-1 refused" "$OUTPUT" "m=p-1: refused"
check "the real client still logs in" "$OUTPUT" "authenticated: $USER"

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

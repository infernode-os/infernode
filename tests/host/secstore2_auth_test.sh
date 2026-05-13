#!/bin/sh
# secstore2 verifier compatibility test (host-side)
# Tests: create secstore2 account -> authenticate with current client -> persist key -> reload
set -e

ROOT="${ROOT:-.}"
. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 0
fi

echo "=== secstore2 auth compatibility test ==="

rm -rf "$ROOT/tmp/secstore2_auth"

cat > "$ROOT/tmp/secstore2_auth_p1.sh" << 'INFERNO'
load std

echo '--- setup secstore2 account ---'
auth/secstore-setup -V secstore2 -k secstore2pass123 -u secstore2user -s /tmp/secstore2_auth

echo '--- starting secstored ---'
auth/secstored -d -s /tmp/secstore2_auth -a 'tcp!*!15359' &
sleep 2

echo '--- starting factotum with current client ---'
auth/factotum -d -S 'tcp!127.0.0.1!15359' -P secstore2pass123 -u secstore2user
sleep 1

echo '--- adding secstore2 test key ---'
echo 'key proto=pass service=secstore2-auth-test user=alice !password=cheshire' > /mnt/factotum/ctl
echo 'sync' > /mnt/factotum/ctl
sleep 2
INFERNO

echo "--- Phase 1: secstore2 account + save ---"
P1_OUT=$(timeout 25 "$EMU" -r"$ROOT" -c0 sh /tmp/secstore2_auth_p1.sh 2>&1 || true)
echo "$P1_OUT"

if [ ! -f "$ROOT/tmp/secstore2_auth/secstore2user/PAK" ]; then
    echo "FAIL: secstore2 PAK file missing"
    exit 1
fi
PAKHDR=$(LC_ALL=C awk '{print $1}' "$ROOT/tmp/secstore2_auth/secstore2user/PAK" 2>/dev/null || true)
if [ "$PAKHDR" != "secstore2" ]; then
    echo "FAIL: secstore2 account wrote wrong verifier tag '$PAKHDR'"
    exit 1
fi

cat > "$ROOT/tmp/secstore2_auth_p2.sh" << 'INFERNO'
load std

echo '--- starting secstored ---'
auth/secstored -d -s /tmp/secstore2_auth -a 'tcp!*!15359' &
sleep 2

echo '--- starting factotum with current client ---'
auth/factotum -d -S 'tcp!127.0.0.1!15359' -P secstore2pass123 -u secstore2user
sleep 1

echo '--- factotum keys after reload ---'
cat /mnt/factotum/ctl
INFERNO

echo ""
echo "--- Phase 2: Reload secstore2 account ---"
P2_OUT=$(timeout 25 "$EMU" -r"$ROOT" -c0 sh /tmp/secstore2_auth_p2.sh 2>&1 || true)
echo "$P2_OUT"

if echo "$P2_OUT" | grep -q "secstore2-auth-test"; then
    echo ""
    echo "=== PASS: current client still authenticates secstore2 account ==="
else
    echo ""
    echo "FAIL: current client could not reload secstore2 account"
    exit 1
fi

rm -rf "$ROOT/tmp/secstore2_auth"
rm -f "$ROOT/tmp/secstore2_auth_p1.sh" "$ROOT/tmp/secstore2_auth_p2.sh"

echo "secstore2_auth_test: done"

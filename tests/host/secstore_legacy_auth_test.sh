#!/bin/sh
# secstore legacy verifier compatibility test (host-side)
# Tests: create legacy secstore account -> authenticate with current client -> persist key -> reload
set -e

ROOT="${ROOT:-.}"
. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 0
fi

echo "=== secstore legacy auth compatibility test ==="

rm -rf "$ROOT/tmp/secstore_legacy"

cat > "$ROOT/tmp/secstore_legacy_p1.sh" << 'INFERNO'
load std

echo '--- setup legacy account ---'
auth/secstore-setup -V secstore -k legacypass123 -u legacyuser -s /tmp/secstore_legacy

echo '--- starting secstored ---'
auth/secstored -d -s /tmp/secstore_legacy -a 'tcp!*!15358' &
sleep 2

echo '--- starting factotum with current client ---'
auth/factotum -d -S 'tcp!127.0.0.1!15358' -P legacypass123 -u legacyuser
sleep 1

echo '--- adding legacy test key ---'
echo 'key proto=pass service=legacy-auth-test user=alice !password=cheshire' > /mnt/factotum/ctl
echo 'sync' > /mnt/factotum/ctl
sleep 2
INFERNO

echo "--- Phase 1: Legacy account + save ---"
P1_OUT=$(timeout 25 "$EMU" -r"$ROOT" -c0 sh /tmp/secstore_legacy_p1.sh 2>&1 || true)
echo "$P1_OUT"

if [ ! -f "$ROOT/tmp/secstore_legacy/legacyuser/PAK" ]; then
    echo "FAIL: legacy PAK file missing"
    exit 1
fi
PAKHDR=$(LC_ALL=C awk '{print $1}' "$ROOT/tmp/secstore_legacy/legacyuser/PAK" 2>/dev/null || true)
if [ "$PAKHDR" = "secstore2" ]; then
    echo "FAIL: legacy account unexpectedly wrote secstore2 verifier"
    exit 1
fi

cat > "$ROOT/tmp/secstore_legacy_p2.sh" << 'INFERNO'
load std

echo '--- starting secstored ---'
auth/secstored -d -s /tmp/secstore_legacy -a 'tcp!*!15358' &
sleep 2

echo '--- starting factotum with current client ---'
auth/factotum -d -S 'tcp!127.0.0.1!15358' -P legacypass123 -u legacyuser
sleep 1

echo '--- factotum keys after reload ---'
cat /mnt/factotum/ctl
INFERNO

echo ""
echo "--- Phase 2: Reload legacy account ---"
P2_OUT=$(timeout 25 "$EMU" -r"$ROOT" -c0 sh /tmp/secstore_legacy_p2.sh 2>&1 || true)
echo "$P2_OUT"

if echo "$P2_OUT" | grep -q "legacy-auth-test"; then
    echo ""
    echo "=== PASS: current client still authenticates legacy secstore account ==="
else
    echo ""
    echo "FAIL: current client could not reload legacy secstore account"
    exit 1
fi

rm -rf "$ROOT/tmp/secstore_legacy"
rm -f "$ROOT/tmp/secstore_legacy_p1.sh" "$ROOT/tmp/secstore_legacy_p2.sh"

echo "secstore_legacy_auth_test: done"

#!/bin/sh
# audit_signing_test (host-side) — factotum-held audit checkpoint signing.
#
# Exercises the full live path that the deterministic unit test
# (tests/auditsign_test.b) cannot: factotum self-generates the ML-DSA-87
# signer key (genkey verb), auditfs asks factotum to sign a checkpoint over
# its rpc file, serves the public key (op=pubkey), and the offline verifier
# confirms the signature. PASS requires a sig= in the chain AND a clean
# auditverify. Non-fatal in CI (best-effort, like the other host tests):
# a partial Inferno namespace yields SKIP, not failure.
#
# See doc/compliance/audit-log-factotum-signing-DESIGN.md.
set -e

. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 77
fi

echo "=== audit signing integration test ==="

cat > /tmp/audit_signing_testscript.sh << 'INFERNO'
load std

# Bring factotum up and have it MINT the audit signer key in-process
# (the private key never crosses the wire or touches disk).
auth/factotum &
sleep 2
echo '--- genkey ---'
echo 'genkey proto=sign service=audit alg=mldsa87 owner=audit' > /mnt/factotum/ctl
echo 'genkey written'

# Start the audit log; it will drive factotum to sign checkpoints.
mkdir -p /usr/inferno/audit
mount {auditfs} /mnt/audit
sleep 1

echo '--- log + checkpoint ---'
echo 'test event integration-check' > /mnt/audit/log
echo checkpoint > /mnt/audit/ctl
sleep 1

echo '--- chain ---'
cat /mnt/audit/chain
echo '--- pubkey (fetched from factotum) ---'
cat /mnt/audit/pubkey

# PASS only if a signature was sealed AND it verifies offline.
if {~ `{cat /mnt/audit/chain} sig=*} {
	echo 'signature present in checkpoint record'
	echo '--- verify ---'
	if {cat /mnt/audit/chain | auditverify -k /mnt/audit/pubkey} {
		echo '=== PASS ==='
	}{
		echo '=== FAIL: signature did not verify ==='
	}
}{
	echo '=== FAIL: no sig= in chain (signing did not happen) ==='
}
INFERNO

mkdir -p "$ROOT/tmp" 2>/dev/null || true
cp /tmp/audit_signing_testscript.sh "$ROOT/tmp/audit_signing_testscript.sh"

"$EMU" -r"$ROOT" -c0 sh /tmp/audit_signing_testscript.sh 2>&1 &
EMU_PID=$!
( sleep 40; kill $EMU_PID 2>/dev/null ) &
WATCHDOG=$!
wait $EMU_PID 2>/dev/null || true
kill $WATCHDOG 2>/dev/null || true

echo "audit_signing_test: done"

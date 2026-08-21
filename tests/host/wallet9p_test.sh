#!/bin/sh
# wallet9p integration test (host-side)
#
# Starts factotum + wallet9p inside emu and runs the wallet policy
# test suite (/dis/tests/wallet_policy_test.dis) against the live 9P
# server: budgets (uint256), the approval queue, x402 authorization,
# network pinning, request-injection rejection, per-fid result
# isolation, and the absence of the raw signing oracle.
#
# Offline: no RPC endpoint is contacted. Exit 77 = emu not built.
set -e

. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 77
fi

echo "=== wallet9p integration test ==="

mkdir -p "$ROOT/tmp" 2>/dev/null || true
cat > "$ROOT/tmp/wallet9p_testscript.sh" << 'INFERNO'
load std
auth/factotum &
sleep 1
/dis/veltro/wallet9p.dis &
sleep 2
# The policy suite lands in /dis/tests via `mk install`, but CI compiles
# tests straight into /tests. Accept either; a missing binary must be a
# loud failure, not a silent pass.
if {ftest -f /dis/tests/wallet_policy_test.dis} {
	/dis/tests/wallet_policy_test.dis
} {
	if {ftest -f /tests/wallet_policy_test.dis} {
		/tests/wallet_policy_test.dis
	} {
		echo 'FAIL: wallet_policy_test.dis not found in /dis/tests or /tests'
	}
}
echo '=== SCRIPT DONE ==='
INFERNO

OUT=$(mktemp /tmp/wallet9p_test_out.XXXXXX)
"$EMU" -r"$ROOT" -c0 sh /tmp/wallet9p_testscript.sh > "$OUT" 2>&1 &
EMU_PID=$!
# factotum and wallet9p stay running, so emu never self-exits: poll for
# the completion marker and stop it as soon as the script is done
# (45s hard cap for a genuine hang).
i=0
while [ $i -lt 45 ]; do
    if grep -q '=== SCRIPT DONE ===' "$OUT" 2>/dev/null; then
        break
    fi
    if ! kill -0 $EMU_PID 2>/dev/null; then
        break
    fi
    sleep 1
    i=$((i + 1))
done
kill $EMU_PID 2>/dev/null || true
wait $EMU_PID 2>/dev/null || true

fail=0
if ! grep -q '=== SCRIPT DONE ===' "$OUT"; then
    echo "FAIL: test script did not run to completion"
    fail=1
fi
# the testing framework prints "PASS"/"FAIL" plus a summary line
if grep -q '^FAIL' "$OUT"; then
    echo "FAIL: wallet policy assertions failed"
    fail=1
fi
if ! grep -qE '^[0-9]+ passed' "$OUT"; then
    echo "FAIL: no test summary produced"
    fail=1
fi

if [ $fail -ne 0 ]; then
    echo "--- emulator output ---"
    cat "$OUT"
    echo "--- end emulator output ---"
    rm -f "$OUT" "$ROOT/tmp/wallet9p_testscript.sh"
    echo "wallet9p_test: FAILED"
    exit 1
fi

grep -E '^(---|===) ' "$OUT" | grep -vi 'script done' || true
grep -E '^[0-9]+ passed' "$OUT"
rm -f "$OUT" "$ROOT/tmp/wallet9p_testscript.sh"
echo "wallet9p_test: PASS"

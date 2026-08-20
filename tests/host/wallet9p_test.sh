#!/bin/sh
# wallet9p integration test (host-side)
#
# Exercises the wallet9p policy surface end-to-end and ASSERTS on the
# output: import + address derivation, invalid-key rejection, strict
# amount parsing, budget enforcement (including currency fail-closed),
# the x402 authorize pending/approve/deny flow, and network pinning.
# Everything here is offline — no RPC endpoints are contacted.
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

echo '--- import ---'
echo 'import eth ethereum testkey 0000000000000000000000000000000000000000000000000000000000000001' > /n/wallet/new
echo '--- address ---'
cat /n/wallet/testkey/address
echo '--- network ---'
cat /n/wallet/network
echo '--- zero key rejected ---'
echo 'import eth ethereum badkey 0000000000000000000000000000000000000000000000000000000000000000' > /n/wallet/new
echo '--- fractional amount rejected ---'
echo '1.5 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf' > /n/wallet/testkey/pay
echo '--- over-budget pay rejected ---'
echo 'budget 1000 5000 ETH' > /n/wallet/testkey/ctl
echo '2000 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf' > /n/wallet/testkey/pay
echo '--- budget currency fail-closed ---'
echo 'scheme exact
network eip155:11155111
asset 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
payto 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf
amount 100
timeout 60
name USDC
version 2' > /n/wallet/testkey/authorize
echo '--- authorize pending + approve ---'
echo 'budget 500 2000 USDC' > /n/wallet/testkey/ctl
echo 'scheme exact
network eip155:11155111
asset 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
payto 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf
amount 100
timeout 60
name USDC
version 2' > /n/wallet/testkey/authorize
cat /n/wallet/testkey/authorize
echo 'approve 1' > /n/wallet/ctl
cat /n/wallet/testkey/authorize
echo '--- deny ---'
echo 'scheme exact
network eip155:11155111
asset 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
payto 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf
amount 200
timeout 60
name USDC
version 2' > /n/wallet/testkey/authorize
echo 'deny 2' > /n/wallet/ctl
cat /n/wallet/testkey/authorize
echo '--- wrong network refused ---'
echo 'scheme exact
network eip155:1
asset 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
payto 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf
amount 100
timeout 60
name USDC
version 2' > /n/wallet/testkey/authorize
echo '=== SCRIPT DONE ==='
INFERNO

OUT=$(mktemp /tmp/wallet9p_test_out.XXXXXX)
"$EMU" -r"$ROOT" -c0 sh /tmp/wallet9p_testscript.sh > "$OUT" 2>&1 &
EMU_PID=$!
# The Inferno script leaves factotum and wallet9p running, so emu never
# self-exits; poll for the completion marker and kill it as soon as the
# script is done (45s hard cap for hangs).
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
expect() {
    if grep -q "$1" "$OUT"; then
        echo "PASS: $2"
    else
        echo "FAIL: $2 (missing: $1)"
        fail=1
    fi
}

expect '=== SCRIPT DONE ===' "test script ran to completion"
expect '0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf' "address derived for privkey=1"
expect 'caip2 eip155:11155111' "network file reports CAIP-2 id"
expect 'invalid private key' "zero private key rejected"
expect 'invalid amount' "fractional amount rejected"
expect 'exceeds per-tx limit' "over-budget payment rejected"
expect 'budget is in ETH' "budget currency mismatch fails closed"
expect 'pending:1' "authorize queued pending approval"
if grep -Eq 'sig [0-9a-f]{130} from 0x' "$OUT"; then
    echo "PASS: approved authorization returns signature"
else
    echo "FAIL: approved authorization returns signature"
    fail=1
fi
expect 'denied' "denied authorization reports denied"
expect 'does not match active network' "wrong-network authorization refused"

if [ $fail -ne 0 ]; then
    echo "--- emulator output ($OUT) ---"
    cat "$OUT"
    echo "--- end emulator output ---"
    rm -f "$OUT" "$ROOT/tmp/wallet9p_testscript.sh"
    echo "wallet9p_test: FAILED"
    exit 1
fi
rm -f "$OUT" "$ROOT/tmp/wallet9p_testscript.sh"
echo "wallet9p_test: PASS"

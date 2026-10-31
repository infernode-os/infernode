#!/bin/sh
# wallet end-to-end test on the Ethereum Sepolia testnet: an account
# made through /mnt/wallet has an address, a chain, a key in factotum,
# and a balance read from the public RPC node (a fresh account's is
# "0 USDC, 0 ETH").
set -e

ROOT="${ROOT:-.}"
. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 77
fi

# The test queries the Sepolia RPC. If we can't reach the public node
# from the host, the emu's dial inside will fail with "invalid IP address"
# — an environment issue, not a wallet regression. Probe reachability up
# front; SKIP if unreachable, and again below if emu itself cannot dial
# it (a host that reaches it only through a proxy).
RPC_HOST=ethereum-sepolia-rpc.publicnode.com
if ! nc -z -w 3 "$RPC_HOST" 443 2>/dev/null; then
    echo "SKIP: cannot reach $RPC_HOST:443 (network/DNS unavailable)"
    exit 77
fi

echo "=== wallet end-to-end test (Sepolia) ==="

mkdir -p "$ROOT/tmp" 2>/dev/null || true
cat > "$ROOT/tmp/wallet_e2e.sh" << 'INFERNO'
load std

# Start services: the connection server, to dial the RPC node by name
bind -a '#I' /net
ndb/cs
auth/factotum &
sleep 1
/dis/veltro/wallet9p.dis &
sleep 2

echo 'eth ethereum e2e-test' > /mnt/wallet/new
echo address `{cat /mnt/wallet/e2e-test/address}
echo chain `{cat /mnt/wallet/e2e-test/chain}
echo balance `{cat /mnt/wallet/e2e-test/balance}
grep 'service=wallet-eth-e2e-test' /mnt/factotum/ctl
echo '=== end ==='
INFERNO

# emu does not exit when the script ends; the timeout stops it
OUT=$(with_timeout 45 "$EMU" -r"$ROOT" -c0 sh /tmp/wallet_e2e.sh 2>&1 || true)
rm -f "$ROOT/tmp/wallet_e2e.sh"
echo "$OUT"

fail() { echo "FAIL: $1"; exit 1; }
echo "$OUT" | grep -q '^=== end ===$' || fail "the script did not finish"
echo "$OUT" | grep -Eq '^address 0x[0-9A-Fa-f]{40}$' || fail "no address"
echo "$OUT" | grep -q '^chain ethereum$' || fail "chain is not ethereum"
echo "$OUT" | grep -q 'service=wallet-eth-e2e-test' || fail "no key in factotum"
if echo "$OUT" | grep -q '^balance .*RPC error'; then
    if echo "$OUT" | grep -q "dial tcp!$RPC_HOST!443"; then
        echo "SKIP: emu cannot dial $RPC_HOST (the host reaches it, emu does not)"
        exit 77
    fi
    fail "balance: RPC error"
fi
echo "$OUT" | grep -Eq '^balance .*(USDC|ETH)' || fail "no balance"
echo "=== PASS ==="

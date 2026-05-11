#!/bin/sh
# wallet end-to-end test on Base Sepolia testnet
set -e

ROOT="${ROOT:-.}"
. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 77
fi

# The test queries Base Sepolia RPC. If we can't reach the public node
# from the host, the emu's dial inside will fail with "invalid IP address"
# and the test FAILs — but that's an environment issue, not a wallet
# regression. Probe reachability up front; SKIP if unreachable.
RPC_HOST=ethereum-sepolia-rpc.publicnode.com
if ! nc -z -w 3 "$RPC_HOST" 443 2>/dev/null; then
    echo "SKIP: cannot reach $RPC_HOST:443 (network/DNS unavailable)"
    exit 77
fi

echo "=== wallet end-to-end test (Base Sepolia) ==="

mkdir -p "$ROOT/tmp" 2>/dev/null || true
cat > "$ROOT/tmp/wallet_e2e.sh" << 'INFERNO'
load std

# Start services
auth/factotum &
sleep 1
/dis/veltro/wallet9p.dis &
sleep 2

echo '=== 1. create account ==='
echo 'eth ethereum e2e-test' > /n/wallet/new
cat /n/wallet/new

echo '=== 2. read address ==='
cat /n/wallet/e2e-test/address

echo '=== 3. read chain ==='
cat /n/wallet/e2e-test/chain

echo '=== 4. query balance (Base Sepolia RPC) ==='
cat /n/wallet/e2e-test/balance

echo '=== 5. check factotum key ==='
cat /mnt/factotum/ctl

echo '=== PASS ==='
INFERNO

timeout 45 "$EMU" -r"$ROOT" -c0 sh /tmp/wallet_e2e.sh 2>&1

echo "wallet_e2e_test: done"

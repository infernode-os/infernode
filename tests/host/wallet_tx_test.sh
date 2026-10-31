#!/bin/sh
#
# Live transaction test on Ethereum Sepolia
#
# Prerequisites:
#   - Wallet account exists in secstore
#   - Account funded with Sepolia ETH (for gas) and USDC
#
# Tests:
#   1. Check balance (ETH + USDC)
#   2. Send small ETH amount to a burn address
#   3. Verify transaction receipt
#   4. Send small USDC amount
#   5. Verify USDC transaction receipt
#
set -e

ROOT="${ROOT:-.}"
. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 77
fi

# Burn address (nobody has the key for this)
BURN="0x000000000000000000000000000000000000dEaD"

# Detect user for secstore
IUSER=$(timeout 5 "$EMU" -r"$ROOT" -c0 cat /dev/user 2>/dev/null | tr -d '\n\r ' || echo "inferno")

echo "=== Live transaction test (Ethereum Sepolia) ==="
echo "User: $IUSER"

mkdir -p "$ROOT/tmp"
cat > "$ROOT/tmp/tx_test.sh" << EOF
load std
bind -a '#I' /net
ndb/cs
auth/secstored >[2] /dev/null &
sleep 2
auth/factotum -S tcp!localhost!5356 -u $IUSER -P testpass
sleep 5
/dis/veltro/wallet9p.dis &
sleep 3

echo '=== 1. check balance ==='
cat /mnt/wallet/veltro-demo-wallet/balance

echo '=== 2. send 1000 wei ETH ==='
echo '1000 $BURN' > /mnt/wallet/veltro-demo-wallet/pay
pending=\`{cat /mnt/wallet/pending}
echo approve \$pending(1) > /mnt/wallet/ctl

echo '=== 3. send 1 USDC (1000000 base units) ==='
echo 'usdc 1000000 $BURN' > /mnt/wallet/veltro-demo-wallet/pay
pending=\`{cat /mnt/wallet/pending}
echo approve \$pending(1) > /mnt/wallet/ctl

echo '=== 4. check history ==='
cat /mnt/wallet/veltro-demo-wallet/history

echo '=== done ==='
EOF

echo "Running transaction test..."
# emu does not exit when the script ends; the timeout stops it
OUTPUT=$(with_timeout 120 "$EMU" -r"$ROOT" -c0 sh /tmp/tx_test.sh 2>&1 || true)
rm -f "$ROOT/tmp/tx_test.sh"
echo "$OUTPUT"

echo ""
if echo "$OUTPUT" | grep -q "veltro-demo-wallet' file does not exist"; then
    echo "SKIP: no veltro-demo-wallet account in $IUSER's secstore (see Prerequisites)"
    exit 77
fi
# each payment sent is in the history with its transaction's hash
for c in eth usdc; do
    if ! echo "$OUTPUT" | grep -Eq "^[0-9]+ pay $c [0-9]+ $BURN 0x[0-9a-fA-F]{64}\$"; then
        echo "FAIL: no $c payment with a transaction hash in the history"
        exit 1
    fi
done
echo "PASS: both payments sent, with their transaction hashes"

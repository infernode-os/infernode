#!/dis/sh.dis
# /n/wallet capability narrowing: an agent may queue payment proposals but must
# not see wallet commit/config authority.
load std
path=(/dis .)
mkdir /n >[2] /dev/null
mount -ac {mntgen} /n
auth/factotum &
sleep 1
/tests/wallet_capability_test.dis
echo WALLETCAP DONE

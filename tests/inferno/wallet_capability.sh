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
unmount /n/wallet > /dev/null >[2] /dev/null
unmount /n > /dev/null >[2] /dev/null
kill wallet9p Wallet9p Styx > /dev/null >[2] /dev/null
kill factotum Factotum Factotum+Authio Mntgen Nametree > /dev/null >[2] /dev/null
echo WALLETCAP DONE

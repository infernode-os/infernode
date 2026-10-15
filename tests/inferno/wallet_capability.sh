#!/dis/sh.dis
# /mnt/wallet capability narrowing: an agent may queue payment proposals but must
# not see wallet commit/config authority.
load std
path=(/dis .)
# A factotum service of its own: #sfactotum is one for the whole emulator,
# and another test's factotum may still hold it.
auth/factotum -s factotum.^${pid} &
sleep 1
st=ok
if {! /tests/wallet_capability_test.dis check} {st=failed}
unmount /mnt/wallet > /dev/null >[2] /dev/null
if {! ~ $st ok} {raise 'fail:wallet_capability'}
echo WALLETCAP DONE

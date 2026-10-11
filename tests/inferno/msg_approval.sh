#!/dis/sh.dis
# A drafted reply is sent only on an exact trusted approval, once.
load std
path=(/dis/veltro /dis .)
mount -ac {mntgen} /n
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register email /dis/veltro/sources/mockmail.dis > /mnt/msg/ctl
st=ok
if {! /tests/msg_approval_test.dis check} {st=failed}
unmount /mnt/msg > /dev/null >[2] /dev/null
if {! ~ $st ok} {raise 'fail:msg_approval'}
echo MSGAPPROVAL DONE

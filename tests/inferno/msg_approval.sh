#!/dis/sh.dis
load std
path=(/dis/veltro /dis .)
mount -ac {mntgen} /n
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register email /dis/veltro/sources/mockmail.dis > /mnt/msg/ctl
/tests/msg_approval_test.dis

#!/dis/sh.dis
# /mnt/msg capability narrowing: granting /mnt/msg exposes only status (read);
# the draft endpoint is hidden unless /mnt/msg/draft is granted separately.
load std
path=(/dis .)
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register email /dis/veltro/sources/mockmail.dis > /mnt/msg/ctl
failed=()
for mode in draft send flag {
	if {! /tests/msg_capability_test.dis $mode} {failed=($failed $mode)}
}
unmount /mnt/msg > /dev/null >[2] /dev/null
if {! ~ $#failed 0} {raise 'fail:msg_capability: '^$"failed}
echo MSGCAP DONE

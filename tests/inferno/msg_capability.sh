#!/dis/sh.dis
# /mnt/msg capability narrowing: granting /mnt/msg exposes only status (read);
# the draft endpoint is hidden unless /mnt/msg/draft is granted separately.
load std
path=(/dis .)
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register email /dis/veltro/sources/mockmail.dis > /mnt/msg/ctl
/tests/msg_capability_test.dis draft
/tests/msg_capability_test.dis send
/tests/msg_capability_test.dis flag
echo MSGCAP DONE

#!/dis/sh.dis
# /mnt/msg capability narrowing: granting /mnt/msg exposes only status (read);
# the draft endpoint is hidden unless /mnt/msg/draft is granted separately.
load std
path=(/dis .)
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register email /dis/veltro/sources/mockmail.dis > /mnt/msg/ctl
/tests/msg_capability_test.dis draft
/tests/msg_capability_test.dis send
/tests/msg_capability_test.dis flag
unmount /mnt/msg > /dev/null >[2] /dev/null
kill msg9p Msg9p Styx MockMail > /dev/null >[2] /dev/null
echo MSGCAP DONE

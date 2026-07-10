#!/dis/sh.dis
# Regression test for INFR-364: msg9p + mockmail provides unread /mnt/msg, a
# restricted child cannot see it without an explicit path grant, and a child with
# /mnt/msg can read the status surface. Testing-only mock source.
load std
path=(/dis .)
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register email /dis/veltro/sources/mockmail.dis > /mnt/msg/ctl
/tests/mail_provision_test.dis nogrant
/tests/mail_provision_test.dis grant
echo MAILPROVISION DONE

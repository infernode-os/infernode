#!/dis/sh.dis
# Regression test for INFR-364: msg9p + mockmail provides unread /mnt/msg, and a
# restricted child (read tool) can read /mnt/msg/status. Testing-only mock source.
load std
path=(/dis .)
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register email /dis/veltro/sources/mockmail.dis > /mnt/msg/ctl
/tests/mail_provision_test.dis mailprobe
echo MAILPROVISION DONE

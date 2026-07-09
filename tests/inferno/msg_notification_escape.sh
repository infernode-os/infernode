#!/dis/sh.dis
# Hostile message fields must not create extra structured lines in msg9p
# notifications. Source data may contain newlines, but notification control
# fields must stay one line each.
load std
path=(/dis .)
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register bad /tests/msg_badsrc.dis > /mnt/msg/ctl
sleep 1
/tests/msg_notification_escape_test.dis
echo MSGESCAPE DONE

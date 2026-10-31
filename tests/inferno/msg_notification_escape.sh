#!/dis/sh.dis
# Hostile message fields must not create extra structured lines in msg9p
# notifications. Source data may contain newlines, but notification control
# fields must stay one line each.
load std
path=(/dis .)
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register bad /tests/msg_badsrc.dis > /mnt/msg/ctl
sleep 1
st=ok
if {! /tests/msg_notification_escape_test.dis check} {st=failed}
unmount /mnt/msg > /dev/null >[2] /dev/null
if {! ~ $st ok} {raise 'fail:msg_notification_escape'}
echo MSGESCAPE DONE

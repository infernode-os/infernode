#!/dis/sh.dis
# msg9p register must reject unsafe source names and module paths.
load std
path=(/dis .)
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
st=ok
if {! /tests/msg_register_test.dis check} {st=failed}
unmount /mnt/msg > /dev/null >[2] /dev/null
if {! ~ $st ok} {raise 'fail:msg_register'}
echo MSGREGISTER DONE

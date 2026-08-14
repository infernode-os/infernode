#!/dis/sh.dis
# msg9p register must reject unsafe source names and module paths.
load std
path=(/dis .)
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
/tests/msg_register_test.dis
unmount /mnt/msg > /dev/null >[2] /dev/null
kill msg9p Msg9p Styx > /dev/null >[2] /dev/null
echo MSGREGISTER DONE

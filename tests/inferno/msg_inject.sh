#!/dis/sh.dis
# Regression test: msgwatch injects the message-handling policy with each
# incoming message into activity 0's input (fire-time skill loading). Uses
# msg9p + the mock inbox source; no LLM needed.
load std
path=(/dis .)
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs
luciuisrv
echo activity create Main > /mnt/ui/ctl
sleep 1
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register email /dis/veltro/sources/mockmail.dis > /mnt/msg/ctl
sleep 1
/dis/veltro/msgwatch.dis -a 0 >[2] /dev/null &
sleep 2
/tests/msg_inject_test.dis msgreader
echo MSGINJECT DONE

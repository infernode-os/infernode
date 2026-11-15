#!/dis/sh.dis
# Deterministic pre-LLM triage: msg9p stamps a structure-derived verdict;
# msgwatch filters ignore/context (never injected) and dispatches only
# wake/preempt. Asserts the routing via msg_triage_test. No LLM needed.
load std
path=(/dis .)
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs
luciuisrv
echo activity create Main > /mnt/ui/ctl
sleep 1
# With no message layer mounted, and without -v (as the boot starts it),
# msgwatch says what is wrong: its log was empty whatever happened.
unmount /mnt/msg > /dev/null >[2] /dev/null
qlog=/tmp/msg_triage_q.^${pid}^.log
/dis/veltro/msgwatch.dis -a 0 >[2] $qlog &
qpid=$apid
sleep 2
kill $qpid >/dev/null >[2] /dev/null
if {! grep -s 'cannot open /mnt/msg/notify' $qlog} {
	echo MSGTRIAGE: FAIL msgwatch without -v logged nothing of a missing /mnt/msg/notify
	rm -f $qlog
	raise 'fail:msg_triage'
}
rm -f $qlog
/dis/veltro/msg9p.dis >[2] /dev/null &
sleep 1
echo register email /dis/veltro/sources/mockmail.dis > /mnt/msg/ctl
log=/tmp/msg_triage.^${pid}^.log
/dis/veltro/msgwatch.dis -a 0 -v >[2] $log &
sleep 14
st=ok
if {! /tests/msg_triage_test.dis check $log} {st=failed}
rm -f $log
if {! ~ $st ok} {raise 'fail:msg_triage'}
echo MSGTRIAGE DONE

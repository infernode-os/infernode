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

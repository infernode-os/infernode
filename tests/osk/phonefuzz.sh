#!/dis/sh.dis
#
# Lucifer's phone layout ground with random use (tests/phone_fuzz.b),
# for tests/host/phone_fuzz_test.sh (not a test itself).  $seed,
# $actions, $every, $w and $h choose the run; the fuzzer keeps a
# checkpoint every $every actions (/tmp/cp.N.*).  Afterwards osk's
# status and Lucifer's UI server's activity, read once more.
#
load std

while {! grep -s '^words [1-9]' /mnt/osk/status} {sleep 1}
/dis/tests/phone_fuzz.dis -s $seed -n $actions -c $every -w $w -h $h
cat /mnt/osk/status > /tmp/status.end
ls /mnt/ui > /tmp/ui.end
echo R done
echo halt > '#c/sysctl'

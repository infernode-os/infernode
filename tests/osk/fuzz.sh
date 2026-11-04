#!/dis/sh.dis
#
# wm/osk ground with random use (tests/osk_fuzz.b) as it types into a
# wm/editor under wm/wm, for tests/host/osk_fuzz_test.sh (not a test
# itself).  osk records what it types (-r /tmp/trace); afterwards the
# editor's text is copied to /tmp/body, osk's status to /tmp/status,
# and two q's are typed to see shift is not left on.
#
load std expr

home=/tmp/home
mkdir -p $home
wm/editor &
sleep 3
w=`{cat /chan/wmwindows}
x=${expr ${index 2 $w} 60 +}
y=${expr ${index 3 $w} 60 +}
echo m $x $y 1 > /dev/pointer
echo m $x $y 0 > /dev/pointer
sleep 1
wm/osk -r /tmp/trace &
sleep 1
while {! grep -s '^words [1-9]' /mnt/osk/status} {sleep 1}
echo R fuzzing
/dis/tests/osk_fuzz.dis -s $seed -n $actions
sleep 2
cat /mnt/osk/status > /tmp/status
echo R fuzzed
# the letters, shift off, then q twice: the second is a q
grep -s '^state shown' /mnt/osk/status || {
	echo f0 400 470 1 > /dev/fingers
	echo f0 400 470 0 > /dev/fingers
	sleep 1
}
fn keys { sleep 1; cat /mnt/osk/keys > /tmp/keys }
fn tapkey {
	pat='^'^$1^' '
	l=`{grep $pat /tmp/keys}
	if {! ~ $#l 0} {
		x=${expr ${index 2 $l} ${index 4 $l} + 2 /}
		y=${expr ${index 3 $l} ${index 5 $l} + 2 /}
		echo f0 $x $y 1 > /dev/fingers
		echo f0 $x $y 0 > /dev/fingers
	}
}
keys
tapkey abc
keys
tapkey abc
keys
grep -s '^shift locked' /mnt/osk/status && tapkey shift
echo mode plain > /mnt/osk/ctl
tapkey q
tapkey q
sleep 2
cat /mnt/osk/status > /tmp/status.end
cp /edit/1/body /tmp/body
echo R done

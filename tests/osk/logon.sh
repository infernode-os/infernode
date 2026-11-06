#!/dis/sh.dis
#
# wm/osk as the boot starts it for wm/logon (lib/lucifer/boot.sh):
# with no window manager, in secret mode, for
# tests/host/osk_logon_test.sh (not a test itself).  A reader of
# /dev/keyboard stands in for wm/logon.  What is typed goes to
# /tmp/typed, osk's status to /tmp/status.<step>, its keys to
# /tmp/keys, its trace to /tmp/trace.
#
load std expr
home=/tmp/home
mkdir -p $home
cat /dev/keyboard > /tmp/typed &
wm/osk -s -M secret -r /tmp/trace &
oskpid=$apid
sleep 1
while {! grep -s '^state ' /mnt/osk/status} {sleep 1}
cat /mnt/osk/status > /tmp/status.before
# the screen touched, above where the keyboard will be
echo f0 300 100 1 > /dev/fingers
echo f0 300 100 0 > /dev/fingers
sleep 2
cat /mnt/osk/status > /tmp/status.shown
cat /mnt/osk/keys > /tmp/keys
fn tapkey {
	pat='^'^$1^' '
	l=`{grep $pat /tmp/keys}
	x=${expr ${index 2 $l} ${index 4 $l} + 2 /}
	y=${expr ${index 3 $l} ${index 5 $l} + 2 /}
	echo f0 $x $y 1 > /dev/fingers
	echo f0 $x $y 0 > /dev/fingers
}
# a password, not a word: nothing put right, nothing shown
for k in h u n t e r space {tapkey $k}
sleep 1
# a touch above the keys types nothing (the login form is there)
echo f0 300 100 1 > /dev/fingers
echo f0 300 100 0 > /dev/fingers
sleep 1
cat /mnt/osk/status > /tmp/status.secret
echo mode text > /mnt/osk/ctl
sleep 1
while {! grep -s '^words [1-9]' /mnt/osk/status} {sleep 1}
cat /mnt/osk/status > /tmp/status.text
kill -g $oskpid
sleep 2
if {ftest -e /mnt/osk/status} {
	if {cat /mnt/osk/status > /dev/null >[2] /dev/null} {echo R alive} {echo R gone}
} {echo R gone}
cp /tmp/trace /tmp/trace.copy
echo R done
echo halt > '#c/sysctl'

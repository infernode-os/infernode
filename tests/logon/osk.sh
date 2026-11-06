#!/dis/sh.dis
#
# wm/logon with the keyboard on the screen, as the boot starts them
# (lib/lucifer/boot.sh: wm/osk -s -M secret, then wm/logon, no window
# manager), for tests/host/logon_osk_test.sh (not a test itself): run
# beside the boot.  The screen goes to /tmp/<step>.img, osk's status to
# /tmp/status.<step>; a password is tapped but never sent.
#
load std expr
fn shot { sleep 2; scap /tmp/$1.img; cat /mnt/osk/status > /tmp/status.$1; echo R $1 }
while {! ftest -e /mnt/osk/status} {sleep 1}
sleep 8
shot boot
# the screen touched with no keyboard attached: osk shows itself
echo f0 400 60 1 > /dev/fingers
echo f0 400 60 0 > /dev/fingers
shot shown
cat /mnt/osk/keys > /tmp/keys
fn tapkey {
	pat='^'^$1^' '
	l=`{grep $pat /tmp/keys}
	x=${expr ${index 2 $l} ${index 4 $l} + 2 /}
	y=${expr ${index 3 $l} ${index 5 $l} + 2 /}
	echo f0 $x $y 1 > /dev/fingers
	echo f0 $x $y 0 > /dev/fingers
}
for k in h u n t e r {tapkey $k}
shot typed
# hidden to its handle (as its keyboard glyph does)
echo toggle > /mnt/osk/ctl
shot handle
echo R done
echo halt > '#c/sysctl'

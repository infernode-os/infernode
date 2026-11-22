#!/dis/sh.dis
#
# wm/osk under wm/wm through a live switch to each theme, for
# tests/host/osk_theme_test.sh (not a test itself): in each, a key held
# down by one finger, the screen written to /tmp/<theme>.img and the
# keys to /tmp/<theme>.keys.
#
load std expr
home=/tmp/home
mkdir -p $home
wm/osk &
sleep 1
while {! grep -s '^words [1-9]' /mnt/osk/status} {sleep 1}
fn centre {
	pat='^'^$1^' '
	l=`{grep $pat /tmp/keys}
	echo ${expr ${index 2 $l} ${index 4 $l} + 2 /} ${expr ${index 3 $l} ${index 5 $l} + 2 /}
}
sleep 1
cat /mnt/osk/keys > /tmp/keys
for th in $themes {
	echo -n $th > /lib/lucifer/theme/current
	sleep 3
	cat /mnt/osk/keys > /tmp/$th.keys
	xy=`{centre t}
	echo f1 $xy 1 > /dev/fingers
	sleep 1
	scap /tmp/$th.img
	echo f1 $xy 0 > /dev/fingers
	echo f0 1 1 1 > /dev/fingers
	echo f0 1 1 0 > /dev/fingers
	sleep 1
}
echo -n $first > /lib/lucifer/theme/current
echo R done
echo halt > '#c/sysctl'

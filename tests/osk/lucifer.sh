#!/dis/sh.dis
#
# wm/osk as Lucifer's keyboard, for tests/host/osk_lucifer_test.sh
# (not a test itself): run in the shell that booted Lucifer, after it
# is up.  Its status is copied to /tmp/status.<step> after each step,
# the keys to /tmp/keys.<step>.
#
load std expr

fn centre {
	pat='^'^$1^' '
	l=`{grep $pat /tmp/keys}
	echo ${expr ${index 2 $l} ${index 4 $l} + 2 /} ${expr ${index 3 $l} ${index 5 $l} + 2 /}
}
fn keys { sleep 1; cat /mnt/osk/keys > /tmp/keys }
fn tapat { echo f$1 $2 $3 1 > /dev/fingers; echo f$1 $2 $3 0 > /dev/fingers }
fn taps { for k in $* { xy=`{centre $k}; tapat 0 $xy } }
fn snap {
	sleep 2
	cat /mnt/osk/status > /tmp/status.$1
	cat /mnt/osk/keys > /tmp/keys.$1
	echo R $1
}

while {! grep -s '^words [1-9]' /mnt/osk/status} {sleep 1}
snap before
# a touch on the screen: no keyboard is attached, so it shows itself
tapat 0 500 200
snap touched
scap /tmp/shot.img

# typed into the chat (the zone with the keyboard), and sent: the
# conversation has a message more (with no model configured the human's
# line is answered, not kept)
ls /mnt/ui/activity/0/conversation | wc -l > /tmp/nconv.before
keys
taps h e l l o enter
sleep 3
ls /mnt/ui/activity/0/conversation | wc -l > /tmp/nconv.after

# a keyboard attached: it goes, and the zones have the screen
echo kbd attach kt9 Test Keyboard > /dev/consctl
snap attached
echo kbd detach kt9 > /dev/consctl
snap detached
# the machine's keyboard typed on: it goes to its handle
echo -n x > /dev/keyboard
snap typedhard
echo R done
echo halt > '#c/sysctl'

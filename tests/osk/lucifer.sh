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

# With the mouse, the keys go where the last click was, not where the
# mouse crossed into the strip on its way down to them.  A shell in the
# presentation zone (its transcript #sshell/fs's body, copied to
# /tmp/body.<step>), in plain mode (nothing put right).
echo mode plain > /mnt/osk/ctl
fn mtaps {
	for k in $* {
		xy=`{centre $k}
		echo m $xy 0 > /dev/pointer
		echo m $xy 1 > /dev/pointer
		echo m $xy 0 > /dev/pointer
	}
}
fn click { echo m $1 $2 1 > /dev/pointer; echo m $1 $2 0 > /dev/pointer }
fn body {
	sleep 3
	cp /tmp/mshell/body /tmp/body.$1
	ls /mnt/ui/activity/0/conversation | wc -l > /tmp/nconv.$1
	echo R $1
}
mkdir -p /tmp/mshell
echo 'create id=shell type=app dis=/dis/wm/shell.dis label=shell' > /mnt/ui/activity/0/presentation/ctl
echo 'center id=shell' > /mnt/ui/activity/0/presentation/ctl
sleep 5
mount -A '#sshell/fs' /tmp/mshell
# a click in the chat, then over the shell to the keys: to the chat
click 100 400
echo m 540 300 0 > /dev/pointer
keys
mtaps h i enter
body tochat
# a click in the shell, then over the chat to the keys: to the shell
click 540 300
echo m 100 300 0 > /dev/pointer
mtaps e c h o space o k enter
body toshell
echo 'kill id=shell' > /mnt/ui/activity/0/presentation/ctl
unmount /tmp/mshell
sleep 2
# wm/wm in the zone with a shell of its own: a click in it, then over
# the chat to the keys: to wm/wm's shell
echo 'create id=wm type=app dis=/dis/wm/wm.dis label=wm data=wm/shell' > /mnt/ui/activity/0/presentation/ctl
echo 'center id=wm' > /mnt/ui/activity/0/presentation/ctl
sleep 6
mount -A '#sshell/fs' /tmp/mshell
scap /tmp/wm.img
click 540 300
echo m 100 300 0 > /dev/pointer
mtaps e c h o space w m enter
body towm
echo 'kill id=wm' > /mnt/ui/activity/0/presentation/ctl
unmount /tmp/mshell
echo mode text > /mnt/osk/ctl

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

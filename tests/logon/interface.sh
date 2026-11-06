#!/dis/sh.dis
#
# The interface picker on the login screen, and what the boot starts
# from it (lib/lucifer/boot.sh), for tests/host/interface_test.sh (not a
# test itself): run beside the boot, $phase saying which step.  The
# screen goes to /tmp/<step>.img, what it finds to R lines; it halts
# the emu when done.
#
#	look	the login screen as it first shows
#	pick	the interface chosen by a click at $x $y, keys typed into
#		the field after it, up and down, the screen skipped (Escape
#		twice); then the Desktop: its windows, a file plumbed
#	again	the login screen as it next shows
#	which	what the boot started, without the login screen
#	shown	the keyboard on the screen shown by a touch (wm/osk, as the
#		boot starts it for the login screen)
#	touch	that, then the interface chosen by a touch at $x $y and
#		a word tapped on the keyboard's keys
#	setpw	the first boot's password set (typed twice) with Desktop
#		chosen; a key added to factotum and saved to secstore
#	unlock	the password typed with Lucia chosen
#	retry	a wrong password typed, then the right one
#
# For the three with a password the driver reports whether factotum
# holds the key (R key yes|no) once the interface has started, and for
# retry also while the screen waits after the wrong one.
#
# A touch is what the screen sends for one: a finger down and up on
# /dev/fingers with a pointer press and release between.
#
load std expr
fn shot { sleep 1; scap /tmp/$1.img >[2] /dev/null; echo R shot $1 }
# waitfor what {condition}: up to 40 seconds for it, or say so and halt
fn waitfor {
	what=$1
	cond=$2
	n=0
	while {! $cond} {
		if {~ $n 40} {echo R timeout $what; echo halt > '#c/sysctl'}
		sleep 1
		n=${expr $n 1 +}
	}
}
fn windows { echo R windows `{wc -l < /chan/wmwindows} }
fn touch {
	echo f0 $1 $2 1 > /dev/fingers
	echo m $1 $2 1 > /dev/pointer
	echo m $1 $2 0 > /dev/pointer
	echo f0 $1 $2 0 > /dev/fingers
}
fn typeline { echo -n $1 > /dev/keyboard; sleep 1; echo > /dev/keyboard }
fn haskey {
	if {grep -s 'service=infernode-interface-test' /mnt/factotum/ctl} {echo R key yes} {echo R key no}
}
fn tapkey {
	# (the pattern made outside the backquote: in its block $1 is empty)
	pat='^'^$1^' '
	l=`{grep $pat /tmp/keys}
	touch ${expr ${index 2 $l} ${index 4 $l} + 2 /} ${expr ${index 3 $l} ${index 5 $l} + 2 /}
}
if {~ $phase look again} {
	sleep 10
	shot $phase
}
if {~ $phase pick} {
	sleep 10
	shot start
	echo m $x $y 1 > /dev/pointer
	echo m $x $y 0 > /dev/pointer
	# off the picker, or Desktop's label shows the pointer over it
	echo m 2 2 > /dev/pointer
	shot click
	echo -n abc > /dev/keyboard
	shot typed
	unicode -t e012 > /dev/keyboard
	shot up
	unicode -t e013 > /dev/keyboard
	shot down
	unicode -t 1b > /dev/keyboard
	sleep 1
	unicode -t 1b > /dev/keyboard
	waitfor desktop {ftest -e /chan/wmwindows}
	sleep 3
	windows
	plumb /lib/wm/plumbing
	waitfor plumbed {~ `{wc -l < /chan/wmwindows} 2}
	windows
}
if {~ $phase shown touch} {
	waitfor keyboard {ftest -e /mnt/osk/status}
	sleep 8
	# the corner, where the form has nothing
	touch 2 2
	shot shown
	cat /mnt/osk/status > /tmp/status.shown
}
if {~ $phase touch} {
	cat /mnt/osk/keys > /tmp/keys
	touch $x $y
	echo m 2 2 > /dev/pointer
	shot tapped
	for k in h u n t {tapkey $k}
	shot keyed
	cat /mnt/osk/status > /tmp/status.keyed
}
PW=hunter2
if {~ $phase setpw} {
	sleep 10
	unicode -t e013 > /dev/keyboard
	typeline $PW
	sleep 2
	typeline $PW
	waitfor desktop {ftest -e /chan/wmwindows}
	haskey
	echo 'key proto=pass service=infernode-interface-test user=tester !password=s3cret' > /mnt/factotum/ctl
	echo sync > /mnt/factotum/ctl
	haskey
	# Saved once secstored has written it: the sync returns when the
	# key is sent, and secstored truncates the file before it writes, so
	# halting at once could leave the store empty (the next boot then
	# loads no keys).
	waitfor saved {ftest -s /usr/inferno/secstore/^`{cat /dev/user}^/factotum}
}
if {~ $phase unlock} {
	sleep 10
	unicode -t e012 > /dev/keyboard
	typeline $PW
	waitfor lucia {ftest -e /mnt/ui/ctl}
	haskey
}
if {~ $phase retry} {
	sleep 10
	typeline wrongpass
	sleep 6
	echo R_WAITING
	haskey
	echo > /dev/keyboard
	sleep 1
	typeline $PW
	waitfor lucia {ftest -e /mnt/ui/ctl}
	haskey
}
if {~ $phase which} {
	waitfor interface {or {ftest -e /chan/wmwindows} {ftest -e /mnt/ui/ctl}}
	if {ftest -e /chan/wmwindows} {echo R started Desktop}
	if {ftest -e /mnt/ui/ctl} {echo R started Lucia}
}
echo R done
echo halt > '#c/sysctl'

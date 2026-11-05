#!/dis/sh.dis
#
# wm/dialpad under wm/wm, tapped through /dev/pointer and typed at
# through /dev/keyboard, dialling a phone file of the driver's own
# (file2chan on /chan/phone: each write a line of /tmp/writes; a dial
# of +44 is answered "connected", a hangup "disconnected", as
# devphone's reads report a call), for tests/host/dialpad_test.sh.
# Not a test itself.  A key is found by its line in the keys file
# wm/dialpad -k writes ("name minx miny maxx maxy"); lines "R <step>"
# go to the log.
#
load std expr file2chan

fn centre {
	pat='^'^$1^' '
	l=`{grep $pat /tmp/keys}
	echo ${expr ${index 2 $l} ${index 4 $l} + 2 /} ${expr ${index 3 $l} ${index 5 $l} + 2 /}
}
# button 1 down and up on each key named
fn taps {
	for k in $* {
		xy=`{centre $k}
		echo m $xy 1 > /dev/pointer
		echo m $xy 0 > /dev/pointer
		sleep 0
	}
}
# button 1 held on a key for longer than a long press
fn hold {
	k=$1	# (a block's $1 is its own)
	xy=`{centre $k}
	echo m $xy 1 > /dev/pointer
	sleep 1
	echo m $xy 0 > /dev/pointer
}
fn step { sleep 1; echo R $1 }

rtag=none
ev=connected
file2chan /chan/phone {rblock; rtag=$tag} {
	d=${rget data}
	echo $d >> /tmp/writes
	rwrite
	if {~ $d 'dial +44'} {
		if {! ~ $rtag none} {rread $rtag 'connected +44 2026-11-05T00:00:00Z
'}
	}
	if {~ $d hangup} {
		if {! ~ $rtag none} {rread $rtag 'disconnected +44 2026-11-05T00:00:01Z
'}
	}
}

wm/dialpad -p /chan -k /tmp/keys &
sleep 3
echo R windows `{cat /chan/wmwindows}

taps 5 5 5 1 2 3 4 call
step digits

# a long press of delete clears; a press slid from 8 to 9 types 9
hold delete
xy=`{centre 8}
echo m $xy 1 > /dev/pointer
xy=`{centre 9}
echo m $xy 1 > /dev/pointer
echo m $xy 0 > /dev/pointer
taps 7 delete 6 call
step slide

# the keyboard: Escape clears, Enter calls
unicode -t 1b > /dev/keyboard
echo -n 123 > /dev/keyboard
echo > /dev/keyboard
step keyboard

# Call with no number dials the last again
unicode -t 1b > /dev/keyboard
taps call
step redial

# the star key, shown a sextile, dials a star; and hash
hold delete
taps star 6 7 hash
sleep 1
scap /tmp/star.img
taps call
step star

# button 3 (a touch held) on 0 is +; a call that connects makes Call
# hang up
hold delete
xy=`{centre 0}
echo m $xy 4 > /dev/pointer
echo m $xy 0 > /dev/pointer
taps 4 4 call
step connected
scap /tmp/incall.img
taps call
step hangup
scap /tmp/ended.img
echo R done

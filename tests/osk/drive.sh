#!/dis/sh.dis
#
# wm/osk under wm/wm, typed on through /dev/fingers (and once with the
# pointer, as a mouse), into a wm/shell, for tests/host/osk_test.sh.
# Not a test itself.  A key is found by its line in /mnt/osk/keys
# ("name minx miny maxx maxy"); after each step the shell's transcript
# (#sshell/fs's body) is copied to /tmp/body.<step>, and osk's status
# to /tmp/status.<step>; lines "R <step> ..." go to the log.
#
load std expr

# the centre of key $1, from the keys file read last
fn centre {
	# (a block's $1 is its own: the pattern is made outside it)
	pat='^'^$1^' '
	l=`{grep $pat /tmp/keys}
	echo ${expr ${index 2 $l} ${index 4 $l} + 2 /} ${expr ${index 3 $l} ${index 5 $l} + 2 /}
}
# the keys shown now (after a moment: the touches before are taken in
# turn, and a layer they change may not have changed yet)
fn keys { sleep 1; cat /mnt/osk/keys > /tmp/keys }
# a finger (id $1) down and up at $2 $3
fn tapat { echo f$1 $2 $3 1 > /dev/fingers; echo f$1 $2 $3 0 > /dev/fingers }
# taps on keys by name, one finger
fn taps { for k in $* { xy=`{centre $k}; tapat 0 $xy } }
# a tap $2 pixels right of key $1's centre: a slip
fn slip {
	k=$1
	xy=`{centre $k}
	tapat 0 ${expr ${index 1 $xy} $2 +} ${index 2 $xy}
}
# a stroke through keys, one finger, six points between each two
fn stroke {
	first=1
	px=0
	py=0
	for k in $* {
		xy=`{centre $k}
		x=${index 1 $xy}
		y=${index 2 $xy}
		if {~ $first 1} {
			echo f0 $x $y 1 > /dev/fingers
			first=0
		} {
			for i in 1 2 3 4 5 6 {
				echo f0 ${expr $px $x $px - $i '*' 6 / +} ${expr $py $y $py - $i '*' 6 / +} 1 > /dev/fingers
			}
		}
		px=$x
		py=$y
	}
	echo f0 $px $py 0 > /dev/fingers
}
# taps on keys by name with the mouse: button 1 down and up on each
fn mtaps {
	for k in $* {
		xy=`{centre $k}
		echo m $xy 0 > /dev/pointer
		echo m $xy 1 > /dev/pointer
		echo m $xy 0 > /dev/pointer
	}
}
fn snap {
	sleep 2
	cp /mnt/shell/body /tmp/body.$1
	cat /mnt/osk/status > /tmp/status.$1
	echo R $1 `{cat /chan/wmwindows}
}

home=/tmp/home
mkdir -p $home

@{pctl forkns; wm/shell} &
sleep 4
w=`{cat /chan/wmwindows}
echo R shell $w
mount -A '#sshell/fs' /mnt/shell
# a click in the shell: the keyboard is the shell's
x=${expr ${index 2 $w} 40 +}
y=${expr ${index 3 $w} 40 +}
echo m $x $y 1 > /dev/pointer
echo m $x $y 0 > /dev/pointer
sx=$x
sy=$y
sleep 1

wm/osk &
# until its words are read (status's words line), as a slower machine
# takes longer
sleep 1
while {! grep -s '^words [1-9]' /mnt/osk/status} {sleep 1}
keys
cp /mnt/osk/keys /tmp/qwerty.keys
snap start

# taps type, into the window with the keyboard; enter sends the line
taps e c h o space h e l l o enter
snap hello

# the words offered as a word is typed: the word it begins
taps e c h o space k e y b o
sleep 2
cat /mnt/osk/suggestions > /tmp/suggestions
taps a r d enter
snap keyboard

# shift once: a capital, then lower case again
taps e c h o space shift h e y enter
snap shift

# a slip onto the key beside (e's tap well over on r), put right when
# the word ends
taps e c h o space h
slip e 45
taps l l o space enter
snap slip

# put right, then taken back by a delete straight after
taps e c h o space t e h space del enter
snap undo

# two thumbs: the second finger down before the first lifts
taps e c h o space
a=`{centre a}
b=`{centre b}
echo f0 $a 1 > /dev/fingers
echo f1 $b 1 > /dev/fingers
echo f0 $a 0 > /dev/fingers
echo f1 $b 0 > /dev/fingers
taps enter
snap rollover

# a mouse's click on a key types it too (a moment after the last
# finger: the pointer's press as a finger lands is that finger's,
# which the GUI also reports as the pointer)
taps e c h o space
sleep 1
xy=`{centre z}
echo m $xy 1 > /dev/pointer
echo m $xy 0 > /dev/pointer
sleep 1
taps enter
snap mouse

# a tap whose pointer press, made from the finger, is read and lifted
# before the finger lands (they come through two files) types once
taps e c h o space
sleep 1
xy=`{centre q}
echo m $xy 1 > /dev/pointer
echo m $xy 0 > /dev/pointer
echo f0 $xy 1 > /dev/fingers
echo f0 $xy 0 > /dev/fingers
taps enter
snap echo

# a stroke through a word's letters types it, and its trail goes when
# the finger lifts: the keys as they were before it (screens kept
# before the enter, whose tap would draw the keys again)
taps e c h o space
sleep 1
scap /tmp/keys.before.img
stroke h e l o
sleep 1
scap /tmp/keys.after.img
taps enter
snap swipe

# the symbols, and back
taps e c h o space sym
keys
taps 4 2 abc
keys
taps enter
snap symbols

# in plain mode nothing is put right
echo mode plain > /mnt/osk/ctl
taps e c h o space t e h space enter
snap plain
echo mode text > /mnt/osk/ctl

# another layout: Dvorak's keys, and it is kept
echo layout dvorak > /mnt/osk/ctl
sleep 1
keys
cp /tmp/keys /tmp/dvorak.keys
taps e c h o space d v o r a k enter
snap dvorak
cat $home/lib/osk/layout > /tmp/savedlayout
echo layout qwerty > /mnt/osk/ctl
sleep 1
keys

# the keys go to the window clicked in last, whatever the pointer
# crossed on its way to them: a wm/editor opened over the shell,
# clicked in, typed into by finger and by the mouse (moved over the
# shell first); then the shell clicked in, typed into by the mouse
# (moved over the editor first).  Plain mode: nothing put right.
echo mode plain > /mnt/osk/ctl
wm/editor &
sleep 4
echo R editor `{cat /chan/wmwindows}
# the editor's window: the second listed, under the keyboard
ew=`{sed -n 2p /chan/wmwindows}
ex=${expr ${index 2 $ew} ${index 4 $ew} + 2 /}
ey=${expr ${index 3 $ew} 30 +}
echo m $ex $ey 1 > /dev/pointer
echo m $ex $ey 0 > /dev/pointer
sleep 1
taps x y
# (a moment after the last finger, as for the mouse's click above)
sleep 1
echo m $sx $sy 0 > /dev/pointer
mtaps z
sleep 2
cat /edit/1/body > /tmp/editor.body
snap toeditor
# the shell, where the editor is not: the shell's top left corner
echo m $sx $sy 1 > /dev/pointer
echo m $sx $sy 0 > /dev/pointer
sleep 1
echo m $ex $ey 0 > /dev/pointer
mtaps e c h o space f o c u s enter
snap toshell
cat /edit/1/body > /tmp/editor.body2
echo mode text > /mnt/osk/ctl

# a swipe down from above the keys hides it to a handle; a touch on
# the handle shows it again
xy=`{grep '^q ' /tmp/keys}
x=${expr ${index 2 $xy} 10 +}
y=${expr ${index 3 $xy} 8 -}
echo f0 $x $y 1 > /dev/fingers
echo f0 $x ${expr $y 120 +} 1 > /dev/fingers
echo f0 $x ${expr $y 120 +} 0 > /dev/fingers
snap hidden
tapat 0 400 470
snap shownagain

echo R done
echo halt > '#c/sysctl'

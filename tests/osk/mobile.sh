#!/dis/sh.dis
#
# wm/osk in Lucifer's phone layout (infmobile=1), for
# tests/host/osk_mobile_test.sh and tablet_layout_test.sh (not a test
# itself): the chat's field tapped and the keyboard hidden by its
# strip's icon, twice, the screen captured after each step.  A tap is a
# finger and the pointer's press made from it, as SDL reports one on a
# phone.
#
load std expr

fn tapat { echo f0 $1 $2 1 > /dev/fingers; echo m $1 $2 1 > /dev/pointer; echo f0 $1 $2 0 > /dev/fingers; echo m $1 $2 0 > /dev/pointer }
fn snap {
	sleep 3
	cat /mnt/osk/status > /tmp/status.$1
	cat /mnt/osk/keys > /tmp/keys.$1
	scap /tmp/$1.img
	echo R $1
}
# the hide icon: at the right of the strip, just above the keys (the
# first line of keys is the top row's first)
fn hide {
	l=`{sed 1q /mnt/osk/keys}
	t=${index 3 $l}
	x=${expr $w 60 -}
	y=${expr $t 20 -}
	tapat $x $y
}

# where the chat's field is tapped: a third of the way across (the
# accordion's chat is the screen's width), or $tapx (a tablet's columns)
if {~ $#tapx 0} {tapx=${expr $w 3 /}}
while {! grep -s '^words [1-9]' /mnt/osk/status} {sleep 1}
snap boot
for i in 1 2 {
	tapat $tapx ${expr $h 50 -}
	snap shown$i
	hide
	snap hidden$i
}
echo R done
echo halt > '#c/sysctl'

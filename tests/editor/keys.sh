#!/dis/sh.dis
#
# wm/editor typed at through /dev/keyboard, for
# tests/host/wm_editor_keys_test.sh (not a test: the runner runs every
# script in tests/inferno): abd typed, then Left, c, F1, Insert, Page
# Down, Page Up, Up, End and e.  The arrows and End move the caret and
# the rest type nothing, so the document is abcde; it is copied from
# /edit/1/body to /tmp/body.
#
load std expr

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn code { unicode -t $1 > /dev/keyboard }

sleep 1
wm/editor &
sleep 4
w=`{cat /chan/wmwindows}
echo R start $w
# a click inside the window gives it the keyboard
x=${expr ${index 2 $w} ${index 4 $w} + 2 /}
y=${expr ${index 3 $w} ${index 5 $w} + 2 /}
ptr $x $y 1
ptr $x $y 0
sleep 1

echo -n abd > /dev/keyboard
code e014
echo -n c > /dev/keyboard
for k in e041 e063 e017 e016 e012 e011 {
	code $k
}
echo -n e > /dev/keyboard
sleep 2
cat /edit/1/body > /tmp/body
echo R done
echo halt > '#c/sysctl'

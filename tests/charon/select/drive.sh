#!/dis/sh.dis
#
# wm/charon under wm/wm, driven by /dev/pointer and /dev/keyboard, for
# tests/host/charon_select_test.sh (not a test: the runner runs every
# script in tests/inferno).  page.html's first line is 300 pixels tall
# and wm/wm gives Charon the screen, its page from about (4, 32): a drag
# along y 100 selects the line, a double-click on its first word that
# word, Ctrl-C copies each to /chan/snarf; a click in the field below
# and Ctrl-V pastes into it.  After each step it prints R, the step and
# the snarf buffer or the field's value; the screen after the drag is
# written to $1/drag.img.
#
load std
E=$1

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn code { unicode -t $1 > /dev/keyboard }
fn snarf { echo -n R $1 '['; cat /chan/snarf; echo ']' }

wm/charon file:///tests/charon/select/page.html &
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {! ftest -e '#scharon/fs'} { sleep 1 }
}
mkdir -p /tmp/charonsel
mount -A '#scharon/fs' /tmp/charonsel
sleep 3

echo -n start > /chan/snarf
# a click on the text, no drag: nothing selected, nothing copied
ptr 60 100 1; ptr 60 100 0
sleep 1
code 3
sleep 1
snarf click

# a drag along the line, past its end
ptr 5 100 1; ptr 30 100 1; ptr 600 100 1; ptr 900 100 1; ptr 900 100 0
sleep 1
code 3
sleep 1
snarf drag
scap $E/drag.img

# a double-click on the first word: two plain presses, as SDL sends them
ptr 40 182 1; ptr 40 182 0; ptr 40 182 1; ptr 40 182 0
sleep 1
code 3
sleep 1
snarf word

# Ctrl-A, Ctrl-C: the page
code 1
sleep 1
code 3
sleep 1
snarf all

# into the field: a click, Ctrl-V, Enter
echo -n 'pasted words' > /chan/snarf
ptr 100 355 1; ptr 100 355 0
sleep 1
code 16
sleep 1
echo > /dev/keyboard
sleep 2
echo R field; cat /tmp/charonsel/forms
echo R done
echo halt > '#c/sysctl'

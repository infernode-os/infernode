#!/dis/sh.dis
#
# wm/editor under wm/wm, for tests/host/editor_ui_test.sh: typed into
# through /chan/uitest, changed by a client through /edit and by the
# Veltro editor tool through /tmp/veltro/editor at once, its window
# deleted from wm's menu.  Prints R, a check's name and ok, or what it
# found instead (not a test: the runner runs every script in
# tests/inferno).  /tmp/big.txt is a text longer than one 9P message,
# with characters of two, three and four bytes.
#
load std

fn key { echo key $1 > /chan/uitest }
fn text { echo text $* > /chan/uitest }
fn ptr { echo ptr $1 $2 $3 > /chan/uitest }
fn click { ptr $1 $2 1; ptr $1 $2 0 }
# wm's button-3 menu: Delete, then the window chosen with button 3
fn delete { ptr 900 600 4; ptr 900 654 4; ptr 900 654 0; sleep 1; ptr 300 200 4; ptr 300 200 0; sleep 2 }
fn body { cat /edit/1/body }
# is name want got...: got, its words joined by spaces, is want
fn is {
	name=$1
	want=$2
	got=${tl ${tl $*}}
	got=$"got
	if {~ $"want $got} {echo R $name ok} {echo R $name got $got want $want}
}
fn same {
	if {cmp $2 $3 > /dev/null} {echo R $1 ok} {echo R $1 differs}
}

sleep 1
wm/editor &
sleep 4
click 300 200
sleep 1

# typing, a character at a time
text abc
sleep 1
is typed abc `{body}

# a client's insert, then undone and redone: undo crashed the editor
# (its own copy of the text no longer matched its undo records)
echo -n 'insert 1 1 X
Y
' > /edit/1/ctl
key 26
sleep 1
is undo-insert abc `{body}
key 26
sleep 1
is undo-typing '' `{body}
is undone-clean '1 0' `{cat /edit/index}
key 25
key 25
sleep 1
body > /tmp/redone
echo -n 'X
Yabc' > /tmp/want
same redo /tmp/redone /tmp/want

# a prompt open (find), then a click in the text: what is typed is the
# text's, and undone (the text widget's own bindings took the keys,
# unlogged, and Ctrl-Z typed a ^Z)
echo -n 'abc' > /edit/1/body
key 6
sleep 1
click 300 200
sleep 1
text Q
sleep 1
key 26
sleep 1
is prompt-click abc `{body}

# a body longer than one 9P message: each write replaced the text, so
# only its last part was kept
cp /tmp/big.txt /edit/1/body
body > /tmp/big.out
same big-body /tmp/big.txt /tmp/big.out

# changes not saved are kept: open, new and quit are refused
if {echo open /tmp/want > /edit/ctl >[2] /dev/null} {echo R open-dirty accepted} {echo R open-dirty ok}
if {echo new > /edit/ctl >[2] /dev/null} {echo R new-dirty accepted} {echo R new-dirty ok}
if {echo quit > /edit/ctl >[2] /dev/null} {echo R quit-dirty accepted} {echo R quit-dirty ok}
body > /tmp/big.out
same kept /tmp/big.txt /tmp/big.out

# a save that cannot be is an error, and the text stays not saved
if {echo saveas /nonexistent/f > /edit/1/ctl >[2] /dev/null} {echo R save-error accepted} {echo R save-error ok}
is save-error-name '1 1' `{cat /edit/index}

# the Veltro tool: its write is undone by the user; its open, over
# changes not saved, refused with the editor's answer
mkdir -p /tmp/veltro/scratch
tools9p editor &
sleep 2
echo 'write from the agent' > /tool/editor/run
is tool-write ok `{cat /tool/editor/run}
is tool-wrote 'from the agent' `{body}
key 26
sleep 1
body > /tmp/big.out
same tool-undone /tmp/big.txt /tmp/big.out
echo 'append  and more' > /tool/editor/run
is tool-append ok `{cat /tool/editor/run}
echo 'open /tmp/want' > /tool/editor/run
r=`{cat /tool/editor/run}
if {~ $r(1) error:} {echo R tool-open-dirty ok} {echo R tool-open-dirty got $r}

# Delete from wm's menu, with changes not saved: the editor stays; the
# second time, it goes
delete
if {ls /edit/1/body > /dev/null >[2] /dev/null} {echo R delete-kept ok} {echo R delete-kept gone}
delete
n=`{ps | grep Editor | wc -l}
is delete-again 0 $n

# a file not there yet is a new file of that name
wm/editor /tmp/notyet.txt &
sleep 4
click 300 200
sleep 1
text new text
key 19
sleep 1
is new-file 'new text' `{cat /tmp/notyet.txt}
is saved-clean '1 /tmp/notyet.txt 0' `{cat /edit/index}

echo R done
echo halt > '#c/sysctl'

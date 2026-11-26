#!/dis/sh.dis
#
# tests/host/dp9ik_live_test.sh's graphical half, run under wm/wm:
# rcpu(1) to 9front with a dp9ik key, each step's result a line
# "R step ..." on standard output and pictures in /tmp for the host to
# check by pixel.  $1 and $2 are the far end's rcpu and auth addresses.
#
load std expr

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn key { echo -n $* > /dev/keyboard }
fn nwin { cat /chan/wmwindows | wc -l }
fn lastwin { cat /chan/wmwindows | sed -n '$p' }

cpu=$1
auth=$2
auth/factotum
echo 'key proto=dp9ik dom=9front user=glenda !password=glendapass9f auth='^$auth > /mnt/factotum/ctl
echo R start `{nwin}

# a command that draws nothing gets no window
rcpu -h $cpu -c 'echo text only' > /tmp/text.out >[2=1]
echo R text `{nwin} `{cat /tmp/text.out}

# the far end's view: rcpu's files, draw in the session's scope
rcpu -h $cpu -c 'echo `{ls -p /mnt/term/dev}; cat /dev/winname >/dev/null; ls /mnt/term/dev/draw | wc -l; test -e /mnt/term/dev/screen && echo screen; ls /dev/draw | wc -l' > /tmp/view.out >[2=1]
echo R view `{cat /tmp/view.out}

# keys and the pointer, through cons (raw) and mouse
rcpu -h $cpu -c 'cat /dev/winname >/dev/null; {echo rawon; sleep 30} >/dev/consctl & sleep 1; k=`{read -c 5 </dev/cons}; echo keys $k; m=`{read -c 49 </dev/mouse}; echo mouse $m' > /tmp/keys.out >[2=1] &
sleep 8
echo R keywin `{nwin}
w=`{lastwin}
x=${expr ${index 2 $w} ${index 4 $w} + 2 /}
y=${expr ${index 3 $w} ${index 5 $w} + 2 /}
ptr $x $y 1
ptr $x $y 0
sleep 1
key hello
sleep 2
ptr ${expr $x 10 +} ${expr $y 7 +} 0
sleep 4
echo R keys `{grep '^keys' /tmp/keys.out}
echo R mouse `{grep '^mouse' /tmp/keys.out}
sleep 2
echo R keysdone `{nwin}

# 9front's colors, drawn in its window
rcpu -h $cpu -c 'colors & sleep 12; kill colors | rc' > /tmp/colors.out >[2=1] &
sleep 10
echo R colors `{nwin} `{lastwin}
scap /tmp/colors.img
sleep 6
echo R colorsgone `{nwin}

# this machine's fonts, read-only: chosen by a program there, not written
# (the refused write last: rc leaves the rest of the line after it)
rcpu -h $cpu -c 'rm /mnt/term/fonts/dejavu/mkfile; ls /mnt/term/fonts/dejavu/mkfile; echo x > /mnt/term/fonts/evil' > /tmp/fontsw.out >[2=1]
echo R wfonts `{grep 'mkfile$' /tmp/fontsw.out | wc -l}
rcpu -h $cpu -c 'acme -f /mnt/term/fonts/combined/go.16.font /lib/namespace & sleep 14; kill acme | rc' > /tmp/fonts.out >[2=1] &
sleep 12
echo R fonts `{nwin}
scap /tmp/fonts.img
sleep 5

# rio inside the window, running colors in a window of its own
rcpu -h $cpu -c 'rio -i ''window -r 20 20 400 300 colors'' & sleep 15; kill rio | rc' > /tmp/rio.out >[2=1] &
sleep 13
echo R rio `{nwin} `{lastwin}
scap /tmp/rio.img
sleep 6
echo R riogone `{nwin}
echo R done

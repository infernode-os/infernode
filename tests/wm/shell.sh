#!/dis/sh.dis
#
# wm/shell under wm/wm, typed at through /dev/keyboard, for
# tests/host/wm_shell_test.sh (not a test: the runner runs every
# script in tests/inferno).  After each step the transcript, as the
# window serves it for Veltro (#sshell/fs's body, mounted at
# /mnt/shell), is copied to
# /tmp/body.<step>, and the windows (a read of /chan/wmwindows) are
# printed as "R <step> ...".  The processes (/prog/*/status) are
# copied to /tmp/procs.before and procs.after, before the window and
# after its shell exits, to procs.deleted after a window running sleep
# is deleted from wm/wm's menu, and to procs.killed after another's
# group is killed from outside.
#
load std expr

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn key { echo -n $* > /dev/keyboard }
# a key by its code, in hex: 4 is ^D, a newline
fn code { unicode -t $1 > /dev/keyboard }
fn line { key $*; code a }
fn snap { sleep 2; cp /mnt/shell/body /tmp/body.$1; echo R $1 `{cat /chan/wmwindows} }

sleep 1
cat /prog/*/status > /tmp/procs.before
@{pctl forkns; wm/shell} &
sleep 4
w=`{cat /chan/wmwindows}
echo R start $w
mount -A '#sshell/fs' /mnt/shell
# a click well inside the window, below the prompt: the caret at the end
x=${expr ${index 2 $w} ${index 4 $w} + 2 /}
y=${expr ${index 3 $w} ${index 5 $w} + 2 /}
ptr $x $y 1
ptr $x $y 0
sleep 1

line echo hello
snap echo

# ^D ends what is typed without a newline, and on its own is end of file
line cat
sleep 1
key abc
code 4
sleep 1
code 4
sleep 1
line echo catdone
snap eof

# ^P brings the last line sent back
code 10
code a
snap history

# ^C discards what is typed and not sent
key echo discarded
code 3
line echo kept
snap discard

# ^C stops what the shell is running, and the shell goes on
line 'sleep 600; echo slept'
sleep 1
code 3
line echo interrupted
snap interrupt

# the arrow and other keys move the caret and type nothing: Left, c,
# End, F1, Insert, e makes abcde of abd
key echo abd
code e014
key c
code e011
code e041
code e063
line e
snap arrows

# ESC holds what is typed until ESC again
code 1b
line echo held
snap holding
code 1b
snap released

# raw mode: a key at a time, not echoed, to a program holding consctl
line '{echo rawon >[1=3]; read 1; echo gotraw} >[3] /dev/consctl'
sleep 1
key x
snap raw
line echo cooked
snap cooked

# shctl takes its commands
line 'echo cwd /shctl/dir > /chan/shctl; echo button b b > /chan/shctl; echo clear > /chan/shctl; echo shctl^$status'
snap shctl

# the shell exits, and its window goes
line exit
snap exit
sleep 2
cat /prog/*/status > /tmp/procs.after

# -c: a command run, and the window gone when it is done
@{pctl forkns; wm/shell -c 'sleep 4'} &
sleep 2
echo R cmd-running `{cat /chan/wmwindows}
sleep 5
echo R cmd-done `{cat /chan/wmwindows}

# a window closed from wm/wm's menu (Delete) takes its shell and what
# the shell runs with it
@{pctl forkns; wm/shell -c 'sleep 600'} &
sleep 3
w=`{cat /chan/wmwindows}
x=${expr ${index 2 $w} ${index 4 $w} + 2 /}
y=${expr ${index 3 $w} ${index 5 $w} + 2 /}
# button 3 on the background, Delete (54 below where the menu opened,
# as tests/wm/drive.sh has it), then button 3 on the window
ptr 900 100 4
ptr 900 154 4
ptr 900 154 0
ptr $x $y 4
ptr $x $y 0
sleep 3
echo R deleted `{cat /chan/wmwindows}
cat /prog/*/status > /tmp/procs.deleted

# a window whose group is killed from outside (no exit asked first, as
# Lucifer's last resort and kill -g do): its shell and what the shell
# runs go too.  The window's group is a Shell process's whose leader
# has exited (the theme watchers' leader is alive); killgrp is written
# to that process's ctl.
@{pctl forkns; wm/shell -c 'sleep 600'} &
sleep 3
m=()
for p in `{ls /prog} {
	s=`{cat $p/status >[2] /dev/null}
	if {~ ${index 7 $s} Shell} {
		if {! ftest -e /prog/${index 2 $s}} {
			m=${index 1 $s}
		}
	}
}
echo R wingroup $m
echo killgrp > /prog/$m/ctl
sleep 3
echo R killed `{cat /chan/wmwindows}
cat /prog/*/status > /tmp/procs.killed

echo R done
echo halt > '#c/sysctl'

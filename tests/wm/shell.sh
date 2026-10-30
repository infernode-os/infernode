#!/dis/sh.dis
#
# wm/shell under wm/wm, typed at through /dev/keyboard, for
# tests/host/wm_shell_test.sh (not a test: the runner runs every
# script in tests/inferno).  After each step the transcript, as the
# window writes it for Veltro (/tmp/veltro/shell/body), is copied to
# /tmp/body.<step>, and the windows (a read of /chan/wmwindows) are
# printed as "R <step> ...".  The processes (/prog/*/status) are
# copied to /tmp/procs.before and procs.after, before the window and
# after its shell exits.
#
load std expr

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn key { echo -n $* > /dev/keyboard }
# a key by its code, in hex: 4 is ^D, a newline
fn code { unicode -t $1 > /dev/keyboard }
fn line { key $*; code a }
fn snap { sleep 2; cp /tmp/veltro/shell/body /tmp/body.$1; echo R $1 `{cat /chan/wmwindows} }

sleep 1
cat /prog/*/status > /tmp/procs.before
@{pctl forkns; wm/shell} &
sleep 4
w=`{cat /chan/wmwindows}
echo R start $w
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

echo R done
echo halt > '#c/sysctl'

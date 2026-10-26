#!/dis/sh.dis
#
# wm/shell under wm/wm, for tests/host/shell_ui_test.sh: typed into
# through /chan/uitest, its transcript read from /tmp/veltro/shell.
# Prints R, a check's name and ok, or what it found instead (not a
# test: the runner runs every script in tests/inferno).  /tmp/big.txt
# is a text longer than one write of cat, with characters of two, three
# and four bytes.
#
load std

fn key { echo key $1 > /chan/uitest }
fn text { echo text $* > /chan/uitest }
fn ptr { echo ptr $1 $2 $3 > /chan/uitest }
fn click { ptr $1 $2 1; ptr $1 $2 0 }
fn enter { text $*; key 10 }
# the transcript, as the shell last wrote it for Veltro
fn body { cat /tmp/veltro/shell/body }
fn is {
	name=$1
	want=$2
	got=${tl ${tl $*}}
	got=$"got
	if {~ $"want $got} {echo R $name ok} {echo R $name got $got want $want}
}
# the lines of the transcript that match, in order, without the prompt
# output after it is on the line of
fn lines { body | sed 's/^; //' | grep $1 }

sleep 1
wm/shell &
sleep 4
click 300 200
sleep 1

enter 'echo hello'
sleep 2
is hello 'hello' `{lines '^hello'}

# lines typed while a command runs are run after it, in the order they
# were typed (they were run last first)
enter 'sleep 3'
sleep 1
enter 'echo one'
enter 'echo two'
enter 'echo three'
sleep 6
is typeahead 'one two three' `{lines '^(one|two|three)$'}

# Ctrl-C kills what the shell runs, and the shell goes on (it sent DEL
# bytes, which went into the next command)
enter 'sleep 100; echo NOTKILLED'
sleep 2
key 3
sleep 2
enter 'echo alive'
sleep 2
is interrupt 'alive' `{lines '^alive'}
is interrupt-killed '' `{lines '^NOTKILLED'}

# Ctrl-C to a shell run as a command: it is a command, and is killed
# (its frames are all sh's, so it was taken for one of the shell's own)
enter 'sh -c ''sleep 100; echo NESTED'''
sleep 2
key 3
sleep 2
enter 'echo afternested'
sleep 2
is interrupt-nested 'afternested' `{lines '^afternested|^NESTED'}

# a loop of sh's builtins has no command to kill: a second Ctrl-C, with
# the shell not reading what is typed, starts a new one
enter 'while {} {}'
sleep 2
key 3
sleep 1
key 3
sleep 2
enter 'echo afterloop'
sleep 3
is interrupt-loop 'afterloop' `{lines '^afterloop'}

# Ctrl-C to a command reading the console: the next line is the shell's
# (it went to the read of the command killed, and was lost)
enter 'cat'
sleep 2
key 3
sleep 2
enter 'echo afterread'
sleep 2
is interrupt-read 'afterread' `{lines '^afterread'}

# output in writes that divide characters: each whole
enter 'cat /tmp/big.txt'
sleep 4
body > /tmp/body.out
grep '^line 399 ' /tmp/body.out > /tmp/got
grep '^line 399 ' /tmp/big.txt > /tmp/want
if {cmp /tmp/got /tmp/want > /dev/null} {echo R utf ok} {echo R utf differs}
grep '^line ' /tmp/body.out | wc -l > /tmp/got
is utf-lines 400 `{cat /tmp/got}

# a flood of output, typed into while it comes
enter 'cat /tmp/big.txt /tmp/big.txt /tmp/big.txt /tmp/big.txt; echo FLOODED'
enter 'echo after'
sleep 6
is flood 'FLOODED after' `{lines '^(FLOODED|after)$'}

# history, and Ctrl-U
key 16
key 10
sleep 2
is history 'after after' `{lines '^after$'}
text 'echo never'
key 21
enter 'echo cleared'
sleep 2
is ctrl-u 'cleared' `{lines 'never|^cleared'}

echo R done
echo halt > '#c/sysctl'

#!/dis/sh.dis
#
# Wrap: a window's lines wrapped between words or anywhere, as Indent
# sets its indenting: Wrap toggles the window, Wrap word and Wrap char
# set it, Wrap WORD and Wrap CHAR every window and new ones; ctl's
# "wrap word" and "wrap char" do it for a client, and a read of ctl
# tells it (after Acme's eight fields). Only the display changes: the body, and the lines addresses count, are the
# same either way. (How the frame lays words out is
# tests/xenith_framesuite.b's.)
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#
# tests/host/xenith_wrap_test.sh starts Xenith and runs this.

load std

XENITH=/mnt/xenith

if {! ftest -f $XENITH/new/ctl} {
	raise 'skip:Xenith not mounted at /mnt/xenith'
}

failed=0

fn check {
	# check name got want
	if {~ $2 $3} {
		echo 'PASS:' $1
	} {
		echo 'FAIL:' $1 'got' $2 'want' $3
		failed=1
	}
}

# how window $1 wraps, as its ctl tells it
fn wrapof {
	# (a braced block, as the backquote's, has an argument list of its own)
	id := $1
	c := `{cat $XENITH/$id/ctl}
	echo ${index 9 $c}
}

fn newwin {
	c := `{cat $XENITH/new/ctl}
	echo ${index 1 $c}
}

# Execute the words $2... in window $1, as button 2 on them at the
# start of its body
fn execute {
	wid := $1
	cmd := $2
	echo -n '#0' > $XENITH/$wid/addr
	echo -n $cmd^' ' > $XENITH/$wid/data
	n := `{echo -n $cmd | wc -c}
	echo 'MX0 '^$n > $XENITH/$wid/event
	# and take the words out again
	echo -n '#0,#'^$n^'+#1' > $XENITH/$wid/addr
	echo -n '' > $XENITH/$wid/data
}

w=`{newwin}
check 'a new window wraps anywhere' `{wrapof $w} char

text='the quick brown fox jumps over the lazy dog, again and again and again, until the dog wakes
a second line'
echo -n $text > $XENITH/$w/body

# line 2's text, through the window's address (kept across opens of
# xdata; opening addr resets it)
fn line2 {
	id := $1
	echo -n 2 > $XENITH/$id/addr
	cat $XENITH/$id/xdata
}
l2="{line2 $w}
check 'line 2 to begin with' $"l2 'a second line'

echo 'wrap word' > $XENITH/$w/ctl
check 'ctl wrap word' `{wrapof $w} word
check 'the body is as it was' "{cat $XENITH/$w/body} $text
check 'line 2 is the same line' "{line2 $w} $"l2

echo 'wrap char' > $XENITH/$w/ctl
check 'ctl wrap char' `{wrapof $w} char

if {echo 'wrap sideways' > $XENITH/$w/ctl >[2] /dev/null} {
	check 'ctl wrap sideways refused' accepted refused
} {
	check 'ctl wrap sideways refused' refused refused
}
check 'and changes nothing' `{wrapof $w} char

execute $w Wrap
check 'Wrap toggles to word' `{wrapof $w} word
execute $w Wrap
check 'and back' `{wrapof $w} char
execute $w 'Wrap word'
check 'Wrap word' `{wrapof $w} word
execute $w 'Wrap word'
check 'Wrap word again: still word' `{wrapof $w} word
execute $w 'Wrap char'
check 'Wrap char' `{wrapof $w} char
check 'the commands left the body as it was' "{cat $XENITH/$w/body} $text

# every window, and new ones
o=`{newwin}
check 'another new window wraps anywhere' `{wrapof $o} char
execute $o 'Wrap WORD'
check 'Wrap WORD: this window' `{wrapof $o} word
echo 'wrap char' > $XENITH/$w/ctl
execute $o 'Wrap WORD'
check 'Wrap WORD: every window' `{wrapof $w} word
n=`{newwin}
check 'Wrap WORD: new windows' `{wrapof $n} word
execute $o 'Wrap CHAR'
check 'Wrap CHAR: every window' `{wrapof $w}^`{wrapof $n}^`{wrapof $o} charcharchar
n2=`{newwin}
check 'Wrap CHAR: new windows' `{wrapof $n2} char

for i in $w $o $n $n2 {
	echo clean > $XENITH/$i/ctl
	echo delete > $XENITH/$i/ctl
}

if {~ $failed 0} {
	echo 'ALL PASS'
} {
	echo 'SOME FAILED'
}

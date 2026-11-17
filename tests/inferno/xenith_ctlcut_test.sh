#!/dis/sh.dis
#
# A write to a window's ctl that is longer than one 9P message. The
# mount driver sends it in pieces, cut wherever a message ends, and
# Xenith ran each piece as commands of its own: the end of a long line
# as a command its writer never wrote. A piece that fills its message
# and does not end a line is refused, and the write fails there with
# the rest unsent. Whole lines that fill a message are still taken, as
# is a short command with no newline.
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#
# tests/host/xenith_ctlcut_test.sh starts Xenith and runs this.

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

# the window's name, as its tag shows it, up to " Del"
fn tagname {
	t=`{cat $W/tag}
	n=()
	done=0
	for f in $t {
		if {~ $f Del} {done=1}
		if {~ $done 0} {n=($n $f)}
	}
	echo $n
}

id=`{cat $XENITH/new/ctl}
id=${index 1 $id}
W=$XENITH/$id
echo 'name /tmp/ctlcut.txt' > $W/ctl
n=`{tagname}
check 'the window is named' $"n /tmp/ctlcut.txt

# Xenith's messages carry 8192 bytes of a write.

# 8192 bytes of commands with no newline among them: nomark 1364 times
# and mark twice. Each is a command (they are matched by their first
# letters), so the piece runs whole.
a=nomark
a4=$a^$a^$a^$a
a16=$a4^$a4^$a4^$a4
a64=$a16^$a16^$a16^$a16
a256=$a64^$a64^$a64^$a64
a1024=$a256^$a256^$a256^$a256
pad=$a1024^$a256^$a64^$a16^$a4^markmark

# One line, one write: the 8192 bytes and then, on the same line, what
# would be a command if a line began there.
st=ok
{echo $pad^'name /tmp/ctlcut-smuggled' > $W/ctl} >[2] /dev/null
st=$status
n=`{tagname}
check 'the end of a cut line is not run as a command' $"n /tmp/ctlcut.txt
if {~ $st ''} {r=taken} {r=refused}
check 'the cut write is refused' $r refused

# the same bytes with the name on a line of its own after them are two
# commands' worth of lines, but the first piece still ends mid-line
{echo $pad^'
name /tmp/ctlcut-second' > $W/ctl} >[2] /dev/null
n=`{tagname}
check 'a first piece that ends no line is refused with what follows' $"n /tmp/ctlcut.txt

# 8192 bytes that are whole lines: nomark and a newline 1166 times,
# mark and a newline 6 times
b='nomark
'
b2=$b^$b
b4=$b2^$b2
b8=$b4^$b4
b16=$b8^$b8
b32=$b16^$b16
b64=$b32^$b32
b128=$b64^$b64
b256=$b128^$b128
b512=$b256^$b256
b1024=$b512^$b512
m='mark
'
lines=$b1024^$b128^$b8^$b4^$b2^$m^$m^$m^$m^$m^$m

{echo -n $lines > $W/ctl} >[2] /dev/null
if {~ $status ''} {r=taken} {r=refused}
check 'whole lines that fill a message are taken' $r taken

# and a write that is cut exactly between two lines is both pieces
{echo $lines^'name /tmp/ctlcut-next.txt' > $W/ctl} >[2] /dev/null
if {~ $status ''} {r=taken} {r=refused}
check 'a write cut between lines is taken' $r taken
n=`{tagname}
check 'and its second piece is run' $"n /tmp/ctlcut-next.txt

# a short command with no newline, as echo -n writes one
{echo -n 'name /tmp/ctlcut-short.txt
clean' > $W/ctl} >[2] /dev/null
if {~ $status ''} {r=taken} {r=refused}
check 'a short write with no newline at its end is taken' $r taken
n=`{tagname}
check 'and run' $"n /tmp/ctlcut-short.txt

echo delete > $W/ctl

if {~ $failed 0} {
	echo 'ALL PASS'
}

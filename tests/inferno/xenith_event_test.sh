#!/dis/sh.dis
#
# Xenith's event protocol, through a window's event file:
#
#	reading: changes are reported, "E" when made through body or tag,
#	"F" through the other files, as Acme does;
#	writing: an event written back is carried out (MX executes body
#	text), and a malformed one is refused without harm.
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#   - /tmp is writable
#
# tests/host/xenith_event_test.sh starts Xenith and runs this.

load std

XENITH=/mnt/xenith
EV=/tmp/xenith_event_test.events

if {! ftest -f $XENITH/new/ctl} {
	raise 'skip:Xenith not mounted at /mnt/xenith'
}

failed=0

fn pass {
	echo 'PASS:' $*
}

fn fail {
	echo 'FAIL:' $*
	failed=1
}

id=`{cat $XENITH/new/ctl}
id=${index 1 $id}
if {~ $#id 0} {
	raise 'skip:cannot create a window'
}
W=$XENITH/$id

# hold the event file open, its events collected in $EV
cat $W/event > $EV &
reader=$apid
sleep 1

echo -n hello > $W/body
echo -n '#2' > $W/addr
echo -n X > $W/data
echo -n '#0,#1' > $W/addr
echo -n '' > $W/data
sleep 1

# expect name line: line is one of the events read
fn expect {
	if {grep -s '^'^$2^'$' $EV} {
		pass $1
	} {
		fail $1 '(no' $2 'in:' "{cat $EV} ')'
	}
}
expect 'a body write is an E insertion' 'EI0 5 0 5 hello'
expect 'a data write is an F insertion' 'FI2 3 0 1 X'
expect 'a data write over a range is an F deletion' 'FD0 1 0 0 '

# malformed events are refused, and Xenith carries on: short ones used
# to be read past their end, killing the Xfid and hanging the writer
echo -n , > $W/addr
echo -n keep > $W/data
for e in 'MX0' 'MX0 ' 'MX0 5' 'MX' 'M' 'M?0 5' 'MX9 0' 'MX0 99
' 'MX4 2
' {
	if {echo -n $e > $W/event >[2] /dev/null} {
		fail 'malformed event accepted:' $e
	}
}
if {ftest -f $W/ctl} {
	b="{cat $W/body}
	if {~ $b keep} {
		pass 'malformed events are refused without harm'
	} {
		fail 'the body changed after malformed events:' $b
	}
} {
	fail 'the window is gone after malformed events'
}

# an event written back is carried out: MX executes body text
echo clean > $W/ctl
echo -n , > $W/addr
echo -n Delete > $W/data
echo 'MX0 6' > $W/event >[2] /dev/null
sleep 1
if {ftest -d $W} {
	fail 'MX did not execute Delete in the body'
	echo clean > $W/ctl
	echo delete > $W/ctl
} {
	pass 'MX executes the text in the body'
}

kill $reader >[2] /dev/null
rm -f $EV

if {~ $failed 1} {
	raise 'fail:tests failed'
}
echo 'ALL PASS'

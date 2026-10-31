#!/dis/sh.dis
#
# Namespace-contract test for scenefs(4): the tree, the record wire,
# stanza files that behave as files, status, the shared camera, event,
# changes as a recording, scenereplay(1) playing one back, and refusals.
#

load std

if {! ftest -f /dis/scenefs.dis} {
	raise 'skip:scenefs.dis not built'
}

S=/tmp/scenefs_test
mkdir -p $S
mount -c {scenefs} $S
if {! ftest -f $S/status} {
	raise 'fail:scenefs did not mount'
}

for (f in ctl view status event changes log meta time) {
	if {! ftest -f $S/$f} {
		raise 'fail:'^$f^' missing'
	}
}
for (d in entities features layers) {
	if {! ftest -d $S/$d} {
		raise 'fail:'^$d^'/ missing'
	}
}

# A fresh scene asks its viewers for a fit.
v=`{cat $S/view}
if {! ~ ${index 13 $v} 1} {
	raise 'fail:a fresh scene should ask for a fit: '^$"v
}

# The record wire.
echo 'meta frame=xy units=m ''title=Test run''' > $S/log
echo 'time 0' > $S/log
echo 'ent a x=0 y=0 group=blue' > $S/log
echo 'time 1' > $S/log
echo 'ent a x=10 y=5 group=blue' > $S/log
echo 'time 2' > $S/log
echo 'ent a x=20 y=15 group=blue' > $S/log

v=`{grep '^title=' $S/meta}
if {! ~ $"v 'title=Test run'} {
	raise 'fail:meta: '^$"v
}
v=`{grep '^x=' $S/entities/a}
if {! ~ $"v 'x=20'} {
	raise 'fail:entity a after three updates: '^$"v
}

# Stanza files behave as files: > replaces, >> appends, rm removes.
echo 'x=100' > $S/entities/c
echo 'y=50' >> $S/entities/c
v=`{cat $S/entities/c}
if {! ~ $"v 'x=100 y=50'} {
	raise 'fail:entities/c after > and >>: '^$"v
}
echo 'ent b x=1 y=1' > $S/log
rm $S/entities/b
if {ftest -f $S/entities/b} {
	raise 'fail:rm did not remove entities/b'
}

# Status.
v=`{cat $S/status}
if {! ~ ${index 1 $v}^' '^${index 2 $v} 't 2'} {
	raise 'fail:status: '^$"v
}
if {ftest -f $S/history} {
	raise 'fail:history is gone: scenefs keeps no history'
}

# The shared camera.
echo 'center 5 6' > $S/ctl
echo 'zoom -1' > $S/ctl
echo 'follow a' > $S/ctl
v=`{cat $S/view}
if {! ~ $"v 'frame xy center 5 6 zoom -1 sel - follow a fit 0'} {
	raise 'fail:view: '^$"v
}

# event: selects reach a reader, and a second blocking read on the same
# open file gets the next event (events are a stream, not a file).
# (A select also moves the shared view, so a view event follows it.)
{ sleep 1; echo 'select a' > $S/ctl } &
v=`{ { read; read } < $S/event }
if {! ~ ${index 1 $v}^' '^${index 2 $v}^' '^${index 3 $v} 'select a view'} {
	raise 'fail:event: '^$"v
}

# changes: a reader begins with the scene as it stands, then gets every
# change, stamped by the clock: what it reads is a recording.
R=/tmp/scenefs_test.scene
cat $S/changes > $R &
cpid=$apid
sleep 1
echo clear > $S/log
echo 'time 0' > $S/log
echo 'ent a x=500 y=0' > $S/log
echo 'time 1' > $S/log
echo 'ent a x=501 y=0' > $S/log
echo 'x=7' > $S/entities/d
sleep 1
echo kill > /prog/$cpid/ctl
v=`{sed 1q $R}
if {! ~ $"v clear} {
	raise 'fail:changes should begin with the scene: '^$"v
}
n=`{grep '^time ' $R | wc -l}
if {! ~ $n 3} {
	raise 'fail:changes time records (the start and two): '^$"n
}

# scenereplay: the recording played back into another scene.
S2=/tmp/scenefs_test2
mkdir -p $S2
mount -c {scenefs} $S2
scenereplay -x 0 $R > $S2/log
v=`{grep '^x=' $S2/entities/a}
if {! ~ $"v 'x=501'} {
	raise 'fail:replayed entity a: '^$"v
}
if {! ftest -f $S2/entities/d} {
	raise 'fail:replay lost entities/d'
}
# from a start time: the scene as it stood then
echo clear > $S2/log
scenereplay -x 0 -t 0 $R > $S2/log
v=`{grep '^x=' $S2/entities/a}
if {! ~ $"v 'x=501'} {
	raise 'fail:replay from 0 ends with entity a: '^$"v
}
scenereplay -x 0 -t 0 $R | sed 20q > /tmp/scenefs_test.head
v=`{grep '^ent a ' /tmp/scenefs_test.head | grep 'x=500'}
if {~ $#v 0} {
	raise 'fail:replay from 0 should first show entity a at 500: '^$"v
}
unmount $S2
rm -f /tmp/scenefs_test.head

# Refusals answer with an error.
if {echo frobnicate > $S/ctl >[2] /dev/null} {
	raise 'fail:unknown ctl command accepted'
}
if {echo 'zoom' > $S/ctl >[2] /dev/null} {
	raise 'fail:zoom without a value accepted'
}
if {echo 'nonsense record' > $S/log >[2] /dev/null} {
	raise 'fail:unknown record accepted'
}

rm -f $R
unmount $S
echo PASS

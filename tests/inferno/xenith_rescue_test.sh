#!/dis/sh
#
# xenith_rescue_test.sh — what has not been saved is kept when Xenith
# goes wrong: run inside a Xenith started with $xenithfaults set (so a
# window's ctl "fault" makes an internal error) and $home a directory of
# its own, by tests/host/xenith_rescue_test.sh.
#
#	an internal error in a 9P request: the request answered with it,
#	Xenith going on, the windows kept in $home/xenith.rescue (a file's
#	changes, an unnamed window's text, typing not yet committed), the
#	user told where in +Errors, Dump's own file left as it was;
#	then one in a proc that does not recover ("fault exit"): Xenith
#	exits, keeping what has changed since (the host side checks).

load std expr

XENITH=/mnt/xenith

if {! ftest -f $XENITH/new/ctl} {
	raise 'skip:Xenith not mounted at /mnt/xenith'
}

failed=0

fn ok {
	echo 'PASS:' $*
}

fn bad {
	echo 'FAIL:' $*
	failed=1
}

fn newwin {
	w := `{cat $XENITH/new/ctl}
	echo ${index 1 $w}
}

D=/tmp/xenith_rescue
mkdir -p $D
echo 'alpha original' > $D/a.txt
echo 'the session dumped' > $home/xenith.dump

# a file's window with changes not Put
a=`{newwin}
echo name $D/a.txt > $XENITH/$a/ctl
echo get > $XENITH/$a/ctl
echo 'alpha edited' >> $XENITH/$a/body
# an unnamed window's text
u=`{newwin}
echo 'unnamed text' > $XENITH/$u/body
# typing not yet in a window's file: the window fills the column, so
# the pointer is in its body
t=`{newwin}
echo name $D/t.txt > $XENITH/$t/ctl
echo 'typing:' > $XENITH/$t/body
echo growfull > $XENITH/$t/ctl
sleep 1
echo m 400 400 0 > /dev/pointer
sleep 1
n0=${index 3 `{cat $XENITH/$t/ctl}}
echo -n 'TypedText' > /dev/keyboard
sleep 2
n1=${index 3 `{cat $XENITH/$t/ctl}}
if {ntest ${expr $n1 $n0 3 + '<'}} {ok 'the typing is held uncommitted'} {bad 'the typing was committed:' $n0 '->' $n1}

if {echo fault > $XENITH/$a/ctl} {
	bad 'no fault was made (is $xenithfaults set?)'
} {
	ok 'an internal error answers the request with it'
}
sleep 1
idx=`{cat $XENITH/index}
if {~ $#idx 0} {bad 'Xenith stopped answering'} {ok 'Xenith goes on after an internal error'}

R=$home/xenith.rescue
if {ftest -f $R} {
	ok 'what has not been saved is kept in' $R
	r="{cat $R}
	if {~ $r *'alpha edited'*} {ok 'a file''s changes are kept'} {bad 'a file''s changes are not kept'}
	if {~ $r *'unnamed text'*} {ok 'an unnamed window''s text is kept'} {bad 'an unnamed window''s text is not kept'}
	if {~ $r *TypedText*} {ok 'typing not yet committed is kept'} {bad 'typing not yet committed is not kept'}
} {
	bad 'nothing kept in' $R
}
d="{cat $home/xenith.dump}
if {~ $d 'the session dumped'*} {ok 'Dump''s own file is left as it was'} {bad 'Dump''s own file was changed'}
e=()
for l in ${split '
' "{cat $XENITH/index}} {
	if {~ $l *+Errors*} {
		e=${index 1 ${split ' 	' $l}}
	}
}
if {~ $#e 0} {
	bad 'no +Errors window'
} {
	b="{cat $XENITH/$e/body}
	if {~ $b *'unsaved work kept in'*} {ok 'the user is told where it is'} {bad '+Errors does not say where:' $b}
}
# the typing is still in its window
n2=${index 3 `{cat $XENITH/$t/ctl}}
echo -n '$' > $XENITH/$t/addr
b="{cat $XENITH/$t/body}
if {~ $b *TypedText*} {ok 'the typing is still in its window'} {bad 'the typing was lost from its window'}

if {~ $failed 0} {echo 'ALL PASS'}

# where nothing recovers, Xenith exits, keeping what changed since
echo 'beta after' >> $XENITH/$a/body
echo 'fault exit' > $XENITH/$a/ctl
sleep 10
echo 'FAIL: Xenith did not exit after an internal error where nothing recovers'

#!/dis/sh
#
# xenith_rescue_load.sh — run inside a Xenith loaded from the rescue
# file tests/inferno/xenith_rescue_test.sh left, by
# tests/host/xenith_rescue_test.sh: the windows are back, with their text.

load std

XENITH=/mnt/xenith
failed=0

fn ok {
	echo 'PASS:' $*
}

fn bad {
	echo 'FAIL:' $*
	failed=1
}

# a window's body, by a part of its name: body part
fn bodyof {
	a := $*
	for l in ${split '
' "{cat $XENITH/index}} {
		if {~ $l *^${index 1 $a}^*} {
			cat $XENITH/${index 1 ${split ' 	' $l}}^/body
		}
	}
}

sleep 2
b="{bodyof /tmp/xenith_rescue/a.txt}
if {~ $b *'alpha edited'*'beta after'*} {ok 'Load brings back a file''s changes'} {bad 'a.txt after Load:' $b}
b="{bodyof unnamed.}
if {~ $b *'unnamed text'*} {ok 'Load brings back an unnamed window''s text'} {bad 'the unnamed window after Load:' $b}
b="{bodyof /tmp/xenith_rescue/t.txt}
if {~ $b *TypedText*} {ok 'Load brings back typing that was not committed'} {bad 't.txt after Load:' $b}
if {~ $failed 0} {echo 'ALL PASS'}

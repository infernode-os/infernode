#!/dis/sh.dis
#
# wm/charon -h: Charon with no window, only its files.  The page is
# read and a form filled in and submitted through them, as a script or
# an agent would; the rendering (image) needs a draw device, and is
# checked unless there is none (#i has no frame buffer) or the caller
# sets nodraw=1.
#
# tests/host/charon_headless_test.sh runs this.

load std

P=/tmp/charon_headless_test
if {! ftest -d '#i'} {
	nodraw=1
}
PAGE=file:///tests/xenith/html/search.html
failed=0

fn pass {
	echo 'PASS:' $*
}

fn fail {
	echo 'FAIL:' $*
	failed=1
}

mkdir -p $P
wm/charon -h $PAGE &
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {! ftest -e '#scharon/fs'} {
		sleep 1
	}
}
if {! mount -A '#scharon/fs' $P} {
	fail 'no headless Charon posted at #scharon/fs'
	raise 'fail:tests failed'
}
t=`{cat $P/title}
if {~ $t Search} {
	pass 'the page, read through its files'
} {
	fail 'title:' $t
}
f=`{grep ' q ' $P/forms}
if {~ ${index 3 $f} text} {
	pass 'its form field listed:' $f
} {
	fail 'forms:' `{cat $P/forms}
}
echo set ${index 2 $f} headless > $P/ctl
echo submit 1 > $P/ctl
u=()
for i in 1 2 3 4 5 {
	if {! ~ $u *result.html*} {
		u=`{cat $P/url}
		sleep 1
	}
}
if {~ $u 'file:///tests/xenith/html/result.html?q=headless'} {
	pass 'the form set and submitted through ctl:' $u
} {
	fail 'url after submit:' $u
}
if {grep -s 'The results page' $P/text} {
	pass 'the result page''s text'
} {
	fail 'text:' `{cat $P/text}
}
n=`{cat $P/image | wc -c}
if {~ $nodraw 1} {
	echo 'SKIP: no draw device: no rendering'
} {~ $n 0} {
	fail 'no rendering (image is empty)'
} {
	pass 'its rendering, as an image'
}
unmount $P
if {~ $failed 1} {
	raise 'fail:tests failed'
}
echo 'ALL PASS'

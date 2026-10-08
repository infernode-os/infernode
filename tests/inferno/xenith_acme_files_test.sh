#!/dis/sh.dis
#
# Window files and ctl messages Xenith takes from canonical Acme
# (Plan 9 and plan9port acme(4)), which the Inferno port never had:
#
#	xdata	like data, but a read stops at the end of addr
#	errors	writes append to the window's +Errors window
#	ctl dirty	mark the window modified
#	ctl menu, nomenu	show or hide the automatic tag menu
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#
# tests/host/xenith_acme_files_test.sh starts Xenith and runs this.

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

id=`{cat $XENITH/new/ctl}
id=${index 1 $id}
if {~ $#id 0} {
	raise 'skip:cannot create a window'
}
W=$XENITH/$id

echo -n 'alpha beta gamma' > $W/body

# xdata stops at the end of addr; data runs to the end of the file
echo -n '#6,#10' > $W/addr
x=`{cat $W/xdata}
check 'xdata reads the addressed range' $"x beta
echo -n '#6,#10' > $W/addr
x=`{cat $W/data}
check 'data reads to the end of the file' $"x 'beta gamma'

# reading xdata advances addr to its end, so a second read is empty
# (addr itself resets when next opened, so it is not read back here)
echo -n '#0,#5' > $W/addr
x=`{cat $W/xdata}
check 'xdata from the start of the file' $"x alpha
x=`{cat $W/xdata}
check 'xdata is exhausted at the end of addr' $#x 0

# errors appends to the window's +Errors window, not to the window
echo name /tmp/xenith-acme-files > $W/ctl
echo 'something went wrong' > $W/errors
e=`{grep '/tmp/\+Errors' $XENITH/index}
if {~ $#e 0} {
	echo 'FAIL: no /tmp/+Errors window after writing errors'
	failed=1
} {
	echo 'PASS: errors made the /tmp/+Errors window'
	eid=${index 1 $e}
	b=`{cat $XENITH/$eid/body}
	check 'errors text lands in +Errors' $"b 'something went wrong'
	echo delete > $XENITH/$eid/ctl
}
b=`{cat $W/body}
check 'errors leaves the window body alone' $"b 'alpha beta gamma'

# dirty marks the window modified; clean clears it
echo clean > $W/ctl
d=`{grep '^ *'^$id^' ' $XENITH/index}
check 'clean window is not dirty' ${index 5 $d} 0
echo dirty > $W/ctl
d=`{grep '^ *'^$id^' ' $XENITH/index}
check 'dirty marks the window dirty' ${index 5 $d} 1
echo clean > $W/ctl

# nomenu drops the automatic Undo/Put entries; menu brings them back
echo -n ' more' >> $W/body
echo nomenu > $W/ctl
t=`{cat $W/tag}
if {~ $"t *Undo*} {
	echo 'FAIL: nomenu tag still shows Undo:' $t
	failed=1
} {
	echo 'PASS: nomenu hides the automatic menu'
}
echo menu > $W/ctl
t=`{cat $W/tag}
if {~ $"t *Undo*} {
	echo 'PASS: menu restores the automatic menu'
} {
	echo 'FAIL: menu tag lacks Undo:' $t
	failed=1
}

echo clean > $W/ctl
echo delete > $W/ctl

if {~ $failed 1} {
	raise 'fail:tests failed'
}
echo 'ALL PASS'

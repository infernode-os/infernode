#!/dis/sh.dis
#
# A file whose name has a blank in it, as Finder hands Xenith many: the
# tag shows the name quoted, as plan9port's acme does, and reads it back
# whole, so a change to the tag does not rename the window to the part
# before the blank, and Put writes the file that was opened.
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#
# tests/host/xenith_blankname_test.sh starts Xenith and runs this.

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

# the id of the window whose index line mentions the argument
fn winof {
	for l in ${split '
' "{cat $XENITH/index}} {
		if {~ $l *^$"*^*} {
			echo ${index 1 ${split ' 	' $l}}
		}
	}
}

# Look at $1 from the body of a scratch window, as B3 does over a
# selection: the whole name, blanks and all
fn look {
	file := $1
	sid := `{cat $XENITH/new/ctl}
	sid = ${index 1 $sid}
	echo -n $file > $XENITH/$sid/body
	n := `{echo -n $file | wc -c}
	echo 'ML0 '^$n > $XENITH/$sid/event
	echo clean > $XENITH/$sid/ctl
	echo delete > $XENITH/$sid/ctl
}

# (ctl name, like Acme's, takes no blanks)
F='/tmp/xenith blank name.txt'
echo first > $F
rm -f /tmp/xenith
look $F
id=()
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {~ $#id 0} {
		id=`{winof 'blank name.txt'}
		if {~ $#id 0} {sleep 1}
	}
}
if {~ $#id 0} {
	echo 'FAIL: the file did not open'
	raise 'fail:not opened'
}
W=$XENITH/$id

n=`{tagname}
check 'the tag quotes the name' $"n '''/tmp/xenith blank name.txt'''

# a change to the tag commits it; the name read back must be whole
echo -n ' x' > $W/tag
echo -n , > $W/addr
echo -n second > $W/data
n=`{tagname}
check 'the name survives a change to the tag' $"n '''/tmp/xenith blank name.txt'''

echo put > $W/ctl
x=`{cat $F}
check 'Put writes the file that was opened' $"x second
if {ftest -e /tmp/xenith} {e=yes} {e=no}
check 'no file named for the part before the blank' $e no

# a name beginning with a quote is quoted too, the quote doubled
echo 'name ''/tmp/q' > $W/ctl
n=`{tagname}
check 'a quote in a quoted name is doubled' $"n '''''''/tmp/q'''

# a name without a blank is shown as it is
echo 'name /tmp/plain.txt' > $W/ctl
n=`{tagname}
check 'a plain name is not quoted' $"n /tmp/plain.txt

echo delete > $W/ctl
rm -f $F

if {~ $failed 0} {
	echo 'ALL PASS'
}

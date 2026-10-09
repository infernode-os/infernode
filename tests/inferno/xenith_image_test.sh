#!/dis/sh.dis
#
# Xenith opens every image format imgload reads as an image, as a user
# does: a file name in a window's body, looked at (B3).  The look is an
# "L" event written back to the window, which Xenith carries out.
#
# Each fixture in /tests/imgload is 8 by 8; the new window's image
# file reports its path and size.  Formats with no decoder yet are
# refused with an error, and a text file still opens as text.
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#
# tests/host/xenith_image_test.sh starts Xenith and runs this.

load std

XENITH=/mnt/xenith
DIR=/tests/imgload

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

# The id of the window named $1, or nothing
fn winof {
	name := $1
	for l in ${split '
' "{cat $XENITH/index}} {
		fl := ${split ' 	' $l}
		if {~ ${index 6 $fl} $name} {
			echo ${index 1 $fl}
		}
	}
}

# Look at $1 from the body of a scratch window, as B3 does
fn look {
	file := $1
	id := `{cat $XENITH/new/ctl}
	id = ${index 1 $id}
	echo -n $file > $XENITH/$id/body
	n := `{echo -n $file | wc -c}
	echo 'ML0 '^$n > $XENITH/$id/event
	echo clean > $XENITH/$id/ctl
	echo delete > $XENITH/$id/ctl
}

# The image file of the window for $1, once its decode has finished
fn imageof {
	file := $1
	img := ()
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 {
		if {~ $#img 0} {
			w := `{winof $file}
			if {! ~ $#w 0} {
				img=`{cat $XENITH/$w/image >[2] /dev/null}
			}
			if {~ $#img 0} {
				sleep 1
			}
		}
	}
	echo $img
}

for f in rb.png rb.jpg rb.gif rb.svg rb.ppm wb.pgm bw.xbm rb.pic {
	look $DIR/$f
	img=`{imageof $DIR/$f}
	if {~ $#img 3 && ~ ${index 2 $img} 8 && ~ ${index 3 $img} 8} {
		pass $f 'opens as an 8x8 image'
	} {
		fail $f 'image file:' $img
	}
}

# No decoder yet: refused, with the reason in +Errors
for f in rb.avif rbl.webp {
	look $DIR/$f
	sleep 2
	errs=`{winof /+Errors}
	if {~ $#errs 0} {
		errs=`{winof +Errors}
	}
	found=0
	for w in $errs {
		if {grep -s $f $XENITH/$w/body} {
			found=1
		}
	}
	if {~ $found 1} {
		pass $f 'is refused, with the reason in +Errors'
	} {
		fail $f 'no error reported'
	}
}

# Not every file is an image
look $DIR/mkfixtures.py
w=()
for i in 1 2 3 4 5 {
	if {~ $#w 0} {
		w=`{winof $DIR/mkfixtures.py}
		sleep 1
	}
}
if {~ $#w 0} {
	fail 'mkfixtures.py did not open'
} {
	img=`{cat $XENITH/$w/image >[2] /dev/null}
	if {~ $#img 0 && grep -s Pillow $XENITH/$w/body} {
		pass 'a text file opens as text'
	} {
		fail 'mkfixtures.py: image' $img
	}
}

if {~ $failed 1} {
	raise 'fail:tests failed'
}
echo 'ALL PASS'

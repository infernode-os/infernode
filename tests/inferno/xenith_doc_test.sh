#!/dis/sh.dis
#
# A window's document (docview(2), docs/xenith-documents.md), through
# the window's files, as an agent sees it:
#
#	a PDF looked at (B3) is shown as a document, its body its text,
#	read-only (writes and Put refused), its doc directory telling
#	what it is and taking zoom, fit, sheet and Render;
#	Get opens it again as a document, not as its bytes;
#	a file plumbed to a window already open on it as text is shown;
#	Markdown opens as text and Render shows it set (doc/ctl, doc/text),
#	Render again goes back to the text;
#	an image looked at is a document of one sheet its size.
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#
# tests/host/xenith_doc_test.sh starts Xenith and runs this.

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

fn ok {
	echo 'PASS:' $*
}

fn bad {
	echo 'FAIL:' $*
	failed=1
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

# Look at the argument from the body of a scratch window, as B3 does
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

# The value of an attribute in a window's doc/ctl: attr id name (in
# `{...}, a function has its arguments in $* only)
fn attr {
	a := $*
	wid := ${index 1 $a}
	name := ${index 2 $a}
	v=()
	for l in ${split '
' "{cat $XENITH/$wid/doc/ctl}} {
		f := ${split ' ' $l}
		if {~ ${index 1 $f} $name} {
			v=${tl $f}
		}
	}
	echo $v
}

# Wait for a window's document to be loaded: loaded id
fn loaded {
	a := $*
	wid := ${index 1 $a}
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 {
		s=`{attr $wid sheets}
		if {~ $#s 0} {sleep 1}
	}
}

# ---- a PDF ----

PDF=/tmp/xenith_doc_test.pdf
cp /lib/legal/calderalic.pdf $PDF
look $PDF
id=()
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {~ $#id 0} {
		id=`{winof xenith_doc_test.pdf}
		if {~ $#id 0} {sleep 1}
	}
}
if {~ $#id 0} {
	bad 'the PDF looked at opened no window'
	raise 'fail:no window'
}
W=$XENITH/$id
loaded $id

check 'a PDF is a document of its kind' `{attr $id kind} pdf
check 'a binary document' `{attr $id class} binary
check 'shown' `{attr $id shown} 1
s=`{attr $id sheets}
if {! ~ $#s 0 && ! ~ $s 0} {ok 'its pages are its sheets:' $s} {bad 'sheets:' $s}
check 'fitted to the window''s width' `{attr $id fit} width

b=`{read 16 < $W/body}
check 'its body is its text, not its bytes' $"b '240 West Center'
t=`{read 16 < $W/doc/text}
check 'doc/text is its text' $"t '240 West Center'
img=`{cat $W/image}
check 'the image file names it' ${index 1 $img} $PDF

if {echo x > $W/body} {bad 'a write to its body was taken'} {ok 'a write to its body is refused'}
echo put > $W/ctl
h=`{read 5 < $PDF}
check 'Put does not write its text over the PDF' $"h '%PDF-'

echo scale 200 > $W/doc/ctl
check 'doc/ctl scale sets the scale' `{attr $id scale} 200
check 'and the fit is let go' `{attr $id fit} none
echo fit > $W/doc/ctl
check 'doc/ctl fit fits it again' `{attr $id fit} width
echo sheet 1 > $W/doc/ctl
check 'doc/ctl sheet goes to a sheet' `{attr $id sheet} 1

echo text > $W/doc/ctl
check 'doc/ctl text shows its text' `{attr $id shown} 0
echo render > $W/doc/ctl
check 'doc/ctl render shows the document again' `{attr $id shown} 1

echo get > $W/ctl
loaded $id
check 'Get opens it again as the document it is' `{attr $id kind} pdf
b=`{read 16 < $W/body}
check 'and its body is still its text' $"b '240 West Center'

if {echo nonsense > $W/doc/ctl} {bad 'a bad doc ctl was taken'} {ok 'a bad doc ctl is refused'}

echo Caldera > $W/doc/find
f=`{cat $W/doc/find}
if {~ ${index 1 $f} 1} {ok 'doc/find finds a word on the page:' $f} {bad 'doc/find:' $f}
if {echo nosuchwordanywhere > $W/doc/find} {bad 'a word not there was found'} {ok 'a word not there is not found'}

# ---- a file open as text, plumbed: shown as the document ----

PDF2=/tmp/xenith_doc_test2.pdf
cp $PDF $PDF2
nid=`{cat $XENITH/new/ctl}
nid=${index 1 $nid}
echo 'name '^$PDF2 > $XENITH/$nid/ctl
echo clean > $XENITH/$nid/ctl
look $PDF2
loaded $nid
check 'a window open on it as text shows it when it is opened again' `{attr $nid kind} pdf

# ---- Markdown: text, and Render ----

MD=/tmp/xenith_doc_test.md
echo '# Heading One' > $MD
echo '' >> $MD
echo 'A paragraph of *text*.' >> $MD
look $MD
mid=()
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {~ $#mid 0} {
		mid=`{winof xenith_doc_test.md}
		if {~ $#mid 0} {sleep 1}
	}
}
M=$XENITH/$mid
c=`{cat $M/doc/ctl}
check 'Markdown opens as its text' $#c 0
echo render > $M/doc/ctl
loaded $mid
check 'Render sets it as a document' `{attr $mid kind} markdown
check 'a source document' `{attr $mid class} source
t=`{cat $M/doc/text}
if {~ $"t *Heading* } {ok 'doc/text is the text as set'} {bad 'doc/text:' $"t}
b=`{read 13 < $M/body}
check 'its body is still its source' $"b '# Heading One'
echo text > $M/doc/ctl
c=`{cat $M/doc/ctl}
check 'Render again goes back to the text' $#c 0

# ---- an image ----

look /tests/imgload/rb.png
iid=()
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {~ $#iid 0} {
		iid=`{winof rb.png}
		if {~ $#iid 0} {sleep 1}
	}
}
loaded $iid
check 'an image is a document' `{attr $iid kind} image
check 'of one sheet' `{attr $iid sheets} 1
img=`{cat $XENITH/$iid/image}
check 'its size' $"img '/tests/imgload/rb.png 8 8'
check 'a picture is fitted whole' `{attr $iid fit} page

rm -f $PDF $PDF2 $MD

if {~ $failed 0} {
	echo 'ALL PASS'
}

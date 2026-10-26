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
#	a source document (Markdown, HTML) shown beside its text (Zerox)
#	is set again on Put and doc/ctl refresh; Live (in either window's
#	tag, or doc/ctl live) sets it again a moment after each edit too,
#	at once if its text changed meanwhile; Live in a window showing
#	only the text opens one below it, showing the document, live;
#	a large one (saved in the background) Put beside its document is
#	written whole;
#	an image looked at is a document of one sheet its size;
#	a PDF's links listed in doc/links, button 3 on one to a page goes
#	to it, on one to a URI browses it in a window of Xenith's and does
#	not plumb it (when a plumber runs); refresh after typing that is
#	not yet committed.
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

# Wait for a binary document's text, read after it is shown: hastext id
fn hastext {
	a := $*
	wid := ${index 1 $a}
	for i in 1 2 3 4 5 6 7 8 9 10 {
		b=`{read 16 < $XENITH/$wid/body}
		if {~ $#b 0} {sleep 1}
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

hastext $id
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
hastext $id
check 'Get opens it again as the document it is' `{attr $id kind} pdf
b=`{read 16 < $W/body}
check 'and its body is still its text' $"b '240 West Center'

if {echo nonsense > $W/doc/ctl} {bad 'a bad doc ctl was taken'} {ok 'a bad doc ctl is refused'}

echo Caldera > $W/doc/find
f=`{cat $W/doc/find}
if {~ ${index 1 $f} 1} {ok 'doc/find finds a word on the page:' $f} {bad 'doc/find:' $f}
if {echo nosuchwordanywhere > $W/doc/find} {bad 'a word not there was found'} {ok 'a word not there is not found'}

# a word clicked on the drawing is selected in the window's text too:
# where West is on the screen, from doc/find (on the page, at scale 100)
# and doc/ctl (the scale, where the view is), clicked through
# /dev/pointer
load expr
echo Center > $W/doc/find
f=`{cat $W/doc/find}
sc=`{attr $id scale}
scr=`{attr $id screen}
view=`{attr $id view}
col=`{attr $id column}
vw=${index 3 $view}
colw=${index 1 $col}
sw=${expr 612 $sc x 100 /}
x=${expr ${index 1 $scr} $colw $sw - 2 / +}
if {ntest ${expr $colw $vw '<'}} {x=${expr $x $vw $colw - 2 / +}} {x=${expr $x ${index 1 $view} -}}
y=${expr ${index 2 $scr} 12 + ${index 2 $view} -}
cx=${expr $x ${index 2 $f} ${index 4 $f} + 2 / $sc x 100 / +}
cy=${expr $y ${index 3 $f} ${index 5 $f} + 2 / $sc x 100 / +}
echo m $cx $cy 0 > /dev/pointer
echo m $cx $cy 1 > /dev/pointer
echo m $cx $cy 0 > /dev/pointer
sleep 1
sel=`{cat $W/rdsel}
check 'a word clicked on the drawing is selected in the text' $"sel Center

# button 2 on a word on the drawing executes it (here Center, no such
# command): the window held while the command runs and let go after, so
# it is there, as it was, however many times (it was let go once too
# often, and freed while shown: Xenith hung)
for i in 1 2 3 {
	echo m $cx $cy 0 > /dev/pointer
	echo m $cx $cy 2 > /dev/pointer
	echo m $cx $cy 0 > /dev/pointer
	sleep 1
}
sleep 2
check 'a word executed on the drawing leaves the document shown' `{attr $id shown} 1
echo scale 120 > $W/doc/ctl
check 'and the window still answers' `{attr $id scale} 120

# ---- a PDF's links ----
# tests/page/links.pdf: on page 1 (400x500) a link to a URI, one to
# page 2 by its destination, one by a named destination

look /tests/page/links.pdf
lid=()
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {~ $#lid 0} {
		lid=`{winof links.pdf}
		if {~ $#lid 0} {sleep 1}
	}
}
loaded $lid
L=$XENITH/$lid
links=${split '
' "{cat $L/doc/links}}
check 'doc/links lists a PDF''s links' $#links 3
check 'a link to a URI' ${index 1 $links} '1 50 160 250 200 http://example.com/'
check 'a link to a page' ${index 2 $links} '1 50 260 250 300 #page=2'
check 'a named destination, to its page' ${index 3 $links} '1 50 340 250 380 #page=2'

# where a point on page 1 (at scale 100) is on the screen: pt x y
fn pt {
	a := $*
	sc=`{attr $lid scale}
	scr=`{attr $lid screen}
	view=`{attr $lid view}
	col=`{attr $lid column}
	vw=${index 3 $view}
	colw=${index 1 $col}
	sw=${expr 400 $sc x 100 /}
	x=${expr ${index 1 $scr} $colw $sw - 2 / +}
	if {ntest ${expr $colw $vw '<'}} {x=${expr $x $vw $colw - 2 / +}} {x=${expr $x ${index 1 $view} -}}
	y=${expr ${index 2 $scr} 12 + ${index 2 $view} -}
	echo ${expr $x ${index 1 $a} $sc x 100 / +} ${expr $y ${index 2 $a} $sc x 100 / +}
}
fn b3 { a := $*; echo m $a 0 > /dev/pointer; echo m $a 4 > /dev/pointer; echo m $a 0 > /dev/pointer; sleep 2 }

# the window is short: at scale 100, scrolled to a link (at y on page 1)
fn tolink { echo sheet 1 > $L/doc/ctl; echo scroll ${expr $1 50 -} > $L/doc/ctl }
echo scale 100 > $L/doc/ctl
tolink 280
s0=`{attr $lid sheet}
b3 `{pt 150 280}
s1=`{attr $lid sheet}
if {~ $s0 $s1} {bad 'button 3 on a link to page 2 left the sheet at' $s1} {ok 'button 3 on a link to a page goes to it: sheet' $s0 '->' $s1}
tolink 360
b3 `{pt 150 360}
check 'and on a named destination' `{attr $lid sheet} $s1
# with a plumber whose rules take web addresses (the host test starts
# one, tests/xenith/plumbing), what reaches its port web is kept: a link
# clicked in Xenith opens there and is not plumbed away
PLUMBED=/tmp/xenith_doc_plumbed
rm -f $PLUMBED
if {ftest -e /chan/plumb.web} {
	# a reader the plumber knows of (it sends only to a started port)
	plumb -s web -d plumb start
	{ cat /chan/plumb.web > $PLUMBED >[2] /dev/null } &
	sleep 1
}
tolink 180
b3 `{pt 150 180}
uid=()
for i in 1 2 3 4 5 {
	if {~ $#uid 0} {
		uid=`{winof example.com}
		if {~ $#uid 0} {sleep 1}
	}
}
if {~ $#uid 0} {bad 'button 3 on a link to a URI opened no window in Xenith'} {ok 'button 3 on a link to a URI browses it in a window of Xenith''s'}
check 'and the PDF stays on its page' `{attr $lid sheet} $s0
if {ftest -e /chan/plumb.web} {
	p=`{cat $PLUMBED}
	if {~ $#p 0} {ok 'and it is not sent to the plumber, which would take it'} {bad 'a link clicked in Xenith was plumbed:' $p}
}
rm -f $PLUMBED

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

# ---- a source document shown beside its text (Zerox): set again ----
# ---- live, as its text is edited; or (nolive) on Put and refresh ----

# Execute a word in a window's tag, as B2 does (lower-case events are
# the tag's): tagexec id word
fn tagexec {
	a := $*
	wid := ${index 1 $a}
	word := ${index 2 $a}
	echo -n ' '^$word >> $XENITH/$wid/tag
	w=`{echo -n $word | wc -c}
	# the tag measured with the event file open: opening it takes the
	# file's menu (Undo, Put) from the tag, as Acme does for a program
	# reading the window's events
	{
		n=`{cat $XENITH/$wid/tag | wc -c}
		echo 'Mx'^${expr $n $w -}^' '^$n
	} > $XENITH/$wid/event
}

# Wait until a window's doc/text has a string: hasdoctext id string
fn hasdoctext {
	a := $*
	wid := ${index 1 $a}
	for i in 1 2 3 4 5 6 7 8 9 10 {
		t=`{cat $XENITH/$wid/doc/text}
		if {! ~ $"t *^${index 2 $a}^*} {sleep 1}
	}
}

# the other window on a file: other file id
fn other {
	a := $*
	for o in `{winof ${index 1 $a}} {
		if {! ~ $o ${index 2 $a}} {echo $o}
	}
}

for kind in md html {
	SRC=/tmp/xenith_doc_refresh.$kind
	if {~ $kind md} {
		echo '# First' > $SRC
	} {
		echo '<p>First</p>' > $SRC
	}
	look $SRC
	aid=()
	for i in 1 2 3 4 5 6 7 8 9 10 {
		if {~ $#aid 0} {
			aid=`{winof xenith_doc_refresh.$kind}
			if {~ $#aid 0} {sleep 1}
		}
	}
	tagexec $aid Zerox
	bid=()
	for i in 1 2 3 4 5 6 7 8 9 10 {
		if {~ $#bid 0} {
			bid=`{other xenith_doc_refresh.$kind $aid}
			if {~ $#bid 0} {sleep 1}
		}
	}
	if {~ $#bid 0} {
		bad $kind^': Zerox made no second window'
	} {
		echo render > $XENITH/$bid/doc/ctl
		loaded $bid
		hasdoctext $bid First
		# not live (as it opens): only Put and doc/ctl refresh set it again
		check $kind^': not live as it opens' `{attr $bid live} 0
		echo ' Early' >> $XENITH/$aid/body
		sleep 3
		t=`{cat $XENITH/$bid/doc/text}
		if {~ $"t *Early*} {bad $kind^': an edit set the document again (not live)'} {ok $kind^': not live, an edit in its twin does not set the document again'}
		# Live in its tag: set again now (its text changed), then once
		# the editing in its twin pauses
		tagexec $bid Live
		check $kind^': Live' `{attr $bid live} 1
		hasdoctext $bid Early
		t=`{cat $XENITH/$bid/doc/text}
		if {~ $"t *Early*} {ok $kind^': Live sets it again from the edits made before'} {bad $kind^': Live:' $"t}
		echo ' Live' >> $XENITH/$aid/body
		hasdoctext $bid Live
		t=`{cat $XENITH/$bid/doc/text}
		if {~ $"t *Live*} {ok $kind^': live, an edit in its twin sets it again from the unsaved text'} {bad $kind^': live:' $"t}
		# Live again, in the text's window: turned off
		tagexec $aid Live
		check $kind^': Live in the twin turns it off' `{attr $bid live} 0
		echo live > $XENITH/$bid/doc/ctl
		check $kind^': doc/ctl live' `{attr $bid live} 1
		echo nolive > $XENITH/$bid/doc/ctl
		check $kind^': doc/ctl nolive' `{attr $bid live} 0
		echo ' Unsaved' >> $XENITH/$aid/body
		sleep 3
		t=`{cat $XENITH/$bid/doc/text}
		if {~ $"t *Unsaved*} {bad $kind^': an edit set the document again (nolive)'} {ok $kind^': nolive, an edit does not set it again'}
		echo refresh > $XENITH/$bid/doc/ctl
		hasdoctext $bid Unsaved
		t=`{cat $XENITH/$bid/doc/text}
		if {~ $"t *Unsaved*} {ok $kind^': doc/ctl refresh sets it from the unsaved text'} {bad $kind^': refresh:' $"t}
		check $kind^': still shown' `{attr $bid shown} 1
		# typed into the twin, not committed (held in its cache, so not
		# in the body's length): refresh takes it too.  The twin's body
		# is where its document would be: render it to learn where.
		echo render > $XENITH/$aid/doc/ctl
		loaded $aid
		scr=`{attr $aid screen}
		echo text > $XENITH/$aid/doc/ctl
		echo -n '$' > $XENITH/$aid/addr
		echo 'dot=addr' > $XENITH/$aid/ctl
		sleep 1
		n0=${index 3 `{cat $XENITH/$aid/ctl}}
		echo m ${expr ${index 1 $scr} 20 +} ${expr ${index 2 $scr} 10 +} 0 > /dev/pointer
		sleep 1
		echo -n ' Typed' > /dev/keyboard
		sleep 2
		n1=${index 3 `{cat $XENITH/$aid/ctl}}
		# (a Markdown body commits the first rune; the rest stay cached)
		if {ntest ${expr $n1 $n0 3 + '<'}} {ok $kind^': typing is held uncommitted'} {bad $kind^': typing was committed:' $n0 '->' $n1}
		t=`{cat $XENITH/$bid/doc/text}
		if {~ $"t *Typed*} {bad $kind^': typing set the document again'} {ok $kind^': typing in its twin does not set the document again'}
		echo refresh > $XENITH/$bid/doc/ctl
		hasdoctext $bid Typed
		t=`{cat $XENITH/$bid/doc/text}
		if {~ $"t *Typed*} {ok $kind^': refresh takes typing not yet committed'} {bad $kind^': refresh after typing:' $"t}
		# each window on the file holds a copy of the typing; it goes
		# into the text once, not once for each window
		b=`{cat $XENITH/$aid/body}
		if {~ $"b *Typed*Typed* *yped*yped*} {bad $kind^': the typing went into the text twice:' $"b} {ok $kind^': the typing went into the text once'}
		echo ' Saved' >> $XENITH/$aid/body
		sleep 2
		t=`{cat $XENITH/$bid/doc/text}
		if {~ $"t *Saved*} {bad $kind^': an edit set the document again'} {}
		echo put > $XENITH/$aid/ctl
		hasdoctext $bid Saved
		t=`{cat $XENITH/$bid/doc/text}
		if {~ $"t *Saved*} {ok $kind^': Put in its twin sets the document again'} {bad $kind^': after Put:' $"t}
		f=`{cat $SRC}
		if {~ $"f *Saved*} {ok $kind^': and the file was written'} {bad $kind^': file:' $"f}
	}
	rm -f $SRC
}
# Live in a window showing only the text: a window opened below it
# showing the document, live
SRC=/tmp/xenith_doc_live.md
echo '# Alone' > $SRC
look $SRC
aid=()
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {~ $#aid 0} {
		aid=`{winof xenith_doc_live.md}
		if {~ $#aid 0} {sleep 1}
	}
}
tagexec $aid Live
bid=()
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {~ $#bid 0} {
		bid=`{other xenith_doc_live.md $aid}
		if {~ $#bid 0} {sleep 1}
	}
}
if {~ $#bid 0} {
	bad 'Live in a text window opened no window for its document'
} {
	loaded $bid
	check 'Live opens a window showing the document' `{attr $bid shown} 1
	check 'and it is live' `{attr $bid live} 1
	echo 'Beside' >> $XENITH/$aid/body
	hasdoctext $bid Beside
	t=`{cat $XENITH/$bid/doc/text}
	if {~ $"t *Alone*Beside*} {ok 'and follows the text'} {bad 'Live window:' $"t}
	echo clean > $XENITH/$bid/ctl
	echo delete > $XENITH/$bid/ctl
}
echo clean > $XENITH/$aid/ctl
echo delete > $XENITH/$aid/ctl
rm -f $SRC
# ---- a large file (written in the background) Put beside its ----
# ---- document: the writer read the window's Buffer as the document ----
# ---- was set again from it, and the file was written empty ----
for order in first twin {
	SRC=/tmp/xenith_doc_big_$order.md
	cp /CHANGELOG.md $SRC
	cp /CHANGELOG.md /tmp/xenith_doc_big.want
	echo -n ' Saved' >> /tmp/xenith_doc_big.want
	look $SRC
	aid=()
	for i in 1 2 3 4 5 6 7 8 9 10 {
		if {~ $#aid 0} {
			aid=`{winof xenith_doc_big_$order.md}
			if {~ $#aid 0} {sleep 1}
		}
	}
	if {~ $order first} {
		echo render > $XENITH/$aid/doc/ctl
		loaded $aid
	}
	tagexec $aid Zerox
	bid=()
	for i in 1 2 3 4 5 6 7 8 9 10 {
		if {~ $#bid 0} {
			bid=`{other xenith_doc_big_$order.md $aid}
			if {~ $#bid 0} {sleep 1}
		}
	}
	tw=$bid
	if {~ $order twin} {
		echo render > $XENITH/$bid/doc/ctl
		loaded $bid
		tw=$aid
	}
	echo -n ' Saved' >> $XENITH/$tw/body
	echo put > $XENITH/$tw/ctl
	for i in 1 2 3 4 5 6 7 8 9 10 {
		if {! cmp $SRC /tmp/xenith_doc_big.want > /dev/null} {sleep 1}
	}
	if {cmp $SRC /tmp/xenith_doc_big.want > /dev/null} {
		ok 'a large file Put beside its document ('^$order^' rendered) is written whole'
	} {
		bad 'a large file Put beside its document ('^$order^' rendered):' `{wc -c < $SRC} 'bytes, want' `{wc -c < /tmp/xenith_doc_big.want}
	}
	b=`{cat $XENITH/$tw/body | wc -c}
	check 'and its text is as it was ('^$order^' rendered)' $b `{wc -c < /tmp/xenith_doc_big.want}
	rm -f $SRC
}
rm -f /tmp/xenith_doc_big.want

if {echo refresh > $M/doc/ctl} {bad 'refresh on a window showing text was taken'} {ok 'refresh on a window showing its text is refused'}

# ---- a source document too long to set: its text, not the error ----
# a program's window, its kind named (render markdown), its text far
# too long for an image of it: the window shows its text again
(lid rest) = `{cat $XENITH/new/ctl}
echo name /+Long > $XENITH/$lid/ctl
rm -f /tmp/xenith_doc_long.md
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 {
	cat /CHANGELOG.md >> /tmp/xenith_doc_long.md
}
cat /tmp/xenith_doc_long.md > $XENITH/$lid/body
if {echo render markdown > $XENITH/$lid/doc/ctl} {ok 'render markdown taken by a window named for no kind'} {bad 'render markdown refused'}
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 {
	if {grep -s '^loading|^kind' $XENITH/$lid/doc/ctl} {sleep 1}
}
if {grep -s . $XENITH/$lid/doc/ctl} {
	bad 'a document too long to set is still the window''s:' `{cat $XENITH/$lid/doc/ctl}
} {
	ok 'a document too long to set gives the window its text again'
}
check 'and the text is whole' `{wc -c < $XENITH/$lid/body} `{wc -c < /tmp/xenith_doc_long.md}
echo delete > $XENITH/$lid/ctl
rm -f /tmp/xenith_doc_long.md

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

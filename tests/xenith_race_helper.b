implement XenithRaceHelper;

#
# The Limbo half of tests/host/xenith_race_test.sh: run inside a
# headless Xenith (xenith_inside.sh), where /mnt/xenith is. Each check
# drives Xenith through its files, as a client and its user do at once,
# at a place it once froze or exited; each runs on a proc of its own
# under a deadline, as a check that froze Xenith never returns. Prints
# PASS and FAIL lines and, when all pass, ALL PASS.
#

include "sys.m";
	sys: Sys;
include "draw.m";

XenithRaceHelper: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

X: con "/mnt/xenith";

failed := 0;

only: list of string;

init(nil: ref Draw->Context, args: list of string)
{
	if(args != nil)
		only = tl args;	# the checks named, by their functions' names
	sys = load Sys Sys->PATH;
	if(sys->open(X+"/index", Sys->OREAD) == nil){
		sys->print("SKIP: Xenith not mounted at %s\n", X);
		return;
	}
	# first, with the screen to themselves: they click where a window
	# taking the whole column is on an 800x600 screen with one column
	check("scrollthenlook", "a scroll bar's B3 ends when let go: the next B3 looks", scrollthenlook);
	check("typingthenget", "a client's get while the body holds typing", typingthenget);
	check("searchwrap", "a search from the end of the file comes round to it", searchwrap);
	check("putloading", "Put of a file still loading writes all of it", putloading);
	check("editloading", "an edit while a file loads goes where it was made", editloading);
	check("ctllock", "ctl unlock and a second lock are refused, not waited for", ctllock);
	check("ctldel", "ctl del then more commands in one write", ctldel);
	check("editxpipe", "Edit X with a pipe command locks each file it runs in", editxpipe);
	checkt("longpdf", "a long PDF's doc/text read and a click on its words leave the row free", longpdf, 150000);
	if(failed)
		raise "fail:tests failed";
	sys->print("ALL PASS\n");
}

# run f under a deadline; a check that does not return has frozen
# Xenith, and nothing after it can be checked
check(fname, name: string, f: ref fn(): string)
{
	checkt(fname, name, f, 20000);
}

checkt(fname, name: string, f: ref fn(): string, ms: int)
{
	if(only != nil){
		for(l := only; l != nil; l = tl l)
			if(hd l == fname)
				break;
		if(l == nil)
			return;
	}
	c := chan of string;
	spawn run(f, c);
	t := chan of int;
	spawn timer(t, ms);
	alt{
	err := <-c =>
		if(err != nil){
			sys->print("FAIL: %s: %s\n", name, err);
			failed = 1;
		}else if(!alive())
			fail(name+": Xenith stopped answering after it");
		else
			sys->print("PASS: %s\n", name);
	<-t =>
		fail(name+": did not return (Xenith frozen)");
	}
}

fail(s: string)
{
	sys->print("FAIL: %s\n", s);
	raise "fail:tests failed";
}

run(f: ref fn(): string, c: chan of string)
{
	err: string;
	{
		err = f();
	}
	exception e{
		"*" =>
			err = "exception: " + e;
	}
	c <-= err;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# the index read, which needs the row, answered in time (with no
# windows it is empty, and "" is nil)
alive(): int
{
	c := chan of int;
	spawn reader(X+"/index", c);
	t := chan of int;
	spawn timer(t, 5000);
	alt{
	ok := <-c =>
		return ok;
	<-t =>
		return 0;
	}
}

reader(f: string, c: chan of int)
{
	fd := sys->open(f, Sys->OREAD);
	b := array[Sys->ATOMICIO] of byte;
	c <-= fd != nil && sys->read(fd, b, len b) >= 0;
}

readall(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	b := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, b, len b)) > 0)
		s += string b[0:n];
	return s;
}

put(f, s: string): string
{
	fd := sys->open(f, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("open %s: %r", f);
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write %s: %r", f);
	return nil;
}

# a new window, named
newwin(name: string): string
{
	fd := sys->open(X+"/new/ctl", Sys->ORDWR);
	if(fd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	(nil, l) := sys->tokenize(string b[0:n], " ");
	id := hd l;
	sys->fprint(fd, "name %s\n", name);
	return X+"/"+id;
}

index(s, t: string): int
{
	for(i := 0; i+len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return -1;
}

ptr(fd: ref Sys->FD, x, y, b: int)
{
	sys->fprint(fd, "m %d %d %d", x, y, b);
	sys->sleep(100);
}

# the window's dot, q0 and q1
dot(w: string): (int, int)
{
	afd := sys->open(w+"/addr", Sys->ORDWR);	# held, so it is not reset
	put(w+"/ctl", "addr=dot\n");
	b := array[64] of byte;
	n := sys->pread(afd, b, len b, big 0);
	if(n <= 0)
		return (-1, -1);
	(nil, l) := sys->tokenize(string b[0:n], " ");
	if(len l < 2)
		return (-1, -1);
	return (int hd l, int hd tl l);
}

seq(n: int): string
{
	s := "";
	for(i := 1; i <= n; i++)
		s += string i + "\n";
	return s;
}

# The scroll bar's scroll went on until its button came up over text,
# and the release always comes with no buttons, which returned before
# it was looked for: it never ended, and the next click of that button
# scrolled the window again rather than doing what it was made for
scrollthenlook(): string
{
	pfd := sys->open("#m/pointer", Sys->OWRITE);
	if(pfd == nil)
		return sys->sprint("#m/pointer: %r");
	w := newwin("/tmp/xrace-scroll");
	if(w == nil)
		return sys->sprint("no window: %r");
	put(w+"/body", seq(400));
	put(w+"/ctl", "clean\n");
	afd := sys->open(w+"/addr", Sys->ORDWR);
	sys->fprint(afd, "#0");
	put(w+"/ctl", "dot=addr\nshow\n");
	afd = nil;
	# the window over the whole column: its tag at y 40, its body
	# from 60, its scroll bar at x 0 to 11
	put(w+"/ctl", "growfull\n");
	sys->sleep(500);
	# B3 in the scroll bar, then a B3 on the body's first line
	ptr(pfd, 5, 300, 0);
	ptr(pfd, 5, 300, 4);
	ptr(pfd, 5, 300, 0);
	ptr(pfd, 25, 69, 0);
	ptr(pfd, 25, 69, 4);
	ptr(pfd, 25, 69, 0);
	sys->sleep(500);
	(q0, q1) := dot(w);
	put(w+"/ctl", "delete\n");
	if(q1 <= q0)
		return sys->sprint("the B3 on the text looked at nothing: dot is %d,%d", q0, q1);
	return nil;
}

# a client's get read the file with typing still held in the body,
# which the load refused by taking Xenith down; the typing is a change
# and the window is not read over
typingthenget(): string
{
	pfd := sys->open("#m/pointer", Sys->OWRITE);
	kfd := sys->open("#c/keyboard", Sys->OWRITE);
	if(pfd == nil || kfd == nil)
		return sys->sprint("pointer or keyboard: %r");
	f := "/tmp/xrace-typed";
	fd := sys->create(f, Sys->OWRITE, 8r666);
	sys->fprint(fd, "one\ntwo\n");
	fd = nil;
	w := newwin(f);
	if(w == nil)
		return sys->sprint("no window: %r");
	put(w+"/ctl", "get\n");
	# over the whole column, its body from y 60; type in it
	put(w+"/ctl", "growfull\n");
	sys->sleep(500);
	ptr(pfd, 60, 100, 0);
	sys->sleep(500);
	sys->fprint(kfd, "xy");
	sys->sleep(500);
	put(w+"/ctl", "get\n");
	sys->sleep(500);
	body := readall(w+"/body");
	put(w+"/ctl", "clean\n");
	put(w+"/ctl", "delete\n");
	if(index(body, "xy") < 0)
		return "the typing was lost: "+body;
	return nil;
}

# B3 on a word in the tag looks for it in the body from the end of dot;
# from the end of the file, with the word's first letter the file's
# last character, the search stepped onto the end, wrapped, and went
# round for ever holding the row
searchwrap(): string
{
	w := newwin("/tmp/xrace-search");
	if(w == nil)
		return sys->sprint("no window: %r");
	# ending with the word's first letter: the search steps onto the end
	if((e := put(w+"/body", "hello w")) != nil)
		return e;
	efd := sys->open(w+"/event", Sys->ORDWR);	# the look comes back to us
	if(efd == nil)
		return sys->sprint("event: %r");
	afd := sys->open(w+"/addr", Sys->ORDWR);
	sys->fprint(afd, "$");
	put(w+"/ctl", "dot=addr\n");
	if((e = put(w+"/tag", " world")) != nil)
		return e;
	tag := readall(w+"/tag");
	q := index(tag, "world");
	if(q < 0)
		return "tag lacks the word: "+tag;
	if(sys->fprint(efd, "Ml%d %d\n", q, q+5) < 0)
		return sys->sprint("event write: %r");
	put(w+"/ctl", "delete\n");
	return nil;
}

bigfile(f: string): int
{
	fd := sys->create(f, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	line := array of byte "the quick brown fox jumps over the lazy dog, again\n";
	n := 0;
	for(i := 0; i < 8000; i++)
		n += sys->write(fd, line, len line);
	return n;
}

size(f: string): int
{
	(ok, d) := sys->stat(f);
	if(ok < 0)
		return -1;
	return int d.length;
}

# a file over 10K is read in the background; a Put while it came wrote
# what had come so far over the file
putloading(): string
{
	f := "/tmp/xrace-big";
	n := bigfile(f);
	w := newwin(f);
	if(w == nil)
		return sys->sprint("no window: %r");
	put(w+"/ctl", "get\n");
	if((e := put(w+"/ctl", "put\n")) != nil)
		return e;
	sys->sleep(2000);
	if((m := size(f)) != n)
		return sys->sprint("%s is %d bytes after the Put, not %d", f, m, n);
	put(w+"/ctl", "delete\n");
	return nil;
}

# an edit made while the file came moved the place its next part went
editloading(): string
{
	f := "/tmp/xrace-big2";
	n := bigfile(f);
	w := newwin(f);
	if(w == nil)
		return sys->sprint("no window: %r");
	put(w+"/ctl", "get\n");
	afd := sys->open(w+"/addr", Sys->ORDWR);
	sys->fprint(afd, "#0");
	if((e := put(w+"/data", "HEAD\n")) != nil)
		return e;
	afd = nil;
	sys->sleep(2000);
	body := readall(w+"/body");
	whole := string readallb(f);
	if(body != "HEAD\n"+whole)
		return sys->sprint("body is not HEAD then the file, in order (%d characters; the file and HEAD are %d)", len body, n+5);
	put(w+"/ctl", "clean\n");
	put(w+"/ctl", "delete\n");
	return nil;
}

readallb(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	(nil, d) := sys->fstat(fd);
	b := array[int d.length] of byte;
	n := 0;
	while(n < len b && (m := sys->read(fd, b[n:], len b - n)) > 0)
		n += m;
	return b[0:n];
}

# a ctl write is served holding the row: unlock of a lock nobody held
# waited for ever, and a second lock waited for an unlock that needed
# the row
ctllock(): string
{
	w := newwin("/tmp/xrace-lock");
	if(w == nil)
		return sys->sprint("no window: %r");
	if(put(w+"/ctl", "unlock\n") == nil)
		return "unlock without a lock was accepted";
	fd := sys->open(w+"/ctl", Sys->ORDWR);
	if(sys->fprint(fd, "lock\n") < 0)
		return sys->sprint("lock: %r");
	if(put(w+"/ctl", "lock\n") == nil)
		return "a second lock was accepted";
	if(sys->fprint(fd, "unlock\n") < 0)
		return sys->sprint("unlock by its holder: %r");
	fd = nil;
	put(w+"/ctl", "delete\n");
	return nil;
}

# a command after del in the same write ran on the deleted window,
# with no column, and the request died holding the row
ctldel(): string
{
	w := newwin("/tmp/xrace-del");
	if(w == nil)
		return sys->sprint("no window: %r");
	put(w+"/ctl", "clean\ndel\nshow\nclean\n");
	return nil;
}

# X ran its command in each file without locking it; a pipe command
# lets go of the file's lock while it waits, and, never taken, waited
# for ever holding the row
editxpipe(): string
{
	a := newwin("/tmp/xrace-x1");
	b := newwin("/tmp/xrace-x2");
	if(a == nil || b == nil)
		return sys->sprint("no window: %r");
	put(a+"/body", "b\na\n");
	put(b+"/body", "d\nc\n");
	if((e := put(a+"/edit", "X/xrace-x/ ,|sort\n")) != nil)
		return e;
	ab := readall(a+"/body");
	bb := readall(b+"/body");
	if(ab != "a\nb\n" || bb != "c\nd\n")
		return sys->sprint("not sorted: %q %q", ab, bb);
	put(a+"/ctl", "clean\n");
	put(b+"/ctl", "clean\n");
	put(a+"/ctl", "delete\n");
	put(b+"/ctl", "delete\n");
	return nil;
}

# ---- a long PDF ----

LONGPAGES: con 1000;
MOMENT: con 2000;	# ms: how long the index may wait for the row

# A PDF of n pages, 400 by 500 points, each full of small text and, in
# its middle, the word Zebra, large; "Page k" at the top of page k. Its
# text takes the engine seconds to read.
longpdf_write(f: string, n: int): string
{
	fd := sys->create(f, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("create %s: %r", f);
	nobj := 3 + 2*n;
	offs := array[nobj] of int;
	off := 0;
	obj := array[nobj] of string;
	kids := "";
	for(i := 0; i < n; i++)
		kids += sys->sprint("%d 0 R ", 4 + 2*i);
	obj[0] = "<< /Type /Catalog /Pages 2 0 R >>";
	obj[1] = sys->sprint("<< /Type /Pages /Kids [%s] /Count %d >>", kids, n);
	obj[2] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>";
	small := "";
	for(y := 486; y >= 20; y -= 6)
		if(y > 330 || y < 190)
			small += sys->sprint("BT /F1 5 Tf 10 %d Td (the quick brown fox jumps over the lazy dog) Tj 190 0 Td (pack my box with five dozen liquor jugs) Tj ET\n", y);
	for(i = 0; i < n; i++){
		c := sys->sprint("BT /F1 10 Tf 300 490 Td (Page %d) Tj ET\n", i+1);
		c += "BT /F1 120 Tf 40 200 Td (Zebra) Tj ET\n";
		c += small;
		obj[3+2*i] = sys->sprint("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Contents %d 0 R /Resources << /Font << /F1 3 0 R >> >> >>", 5+2*i);
		obj[4+2*i] = sys->sprint("<< /Length %d >>\nstream\n%sendstream", len c, c);
	}
	b := array of byte "%PDF-1.4\n";
	sys->write(fd, b, len b);
	off += len b;
	for(i = 0; i < nobj; i++){
		offs[i] = off;
		b = array of byte sys->sprint("%d 0 obj\n%s\nendobj\n", i+1, obj[i]);
		if(sys->write(fd, b, len b) != len b)
			return sys->sprint("write %s: %r", f);
		off += len b;
	}
	x := sys->sprint("xref\n0 %d\n0000000000 65535 f \n", nobj+1);
	for(i = 0; i < nobj; i++)
		x += sys->sprint("%.10d 00000 n \n", offs[i]);
	x += sys->sprint("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", nobj+1, off);
	b = array of byte x;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write %s: %r", f);
	return nil;
}

# how long a read of the index took, in ms (up to 60s)
indexms(): int
{
	t0 := sys->millisec();
	c := chan of int;
	spawn reader(X+"/index", c);
	t := chan of int;
	spawn timer(t, 60000);
	alt{
	<-c =>
		;
	<-t =>
		;
	}
	return sys->millisec() - t0;
}

# the first read of a file: what it gave, or the error
firstread(f: string, c: chan of (string, string))
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil){
		c <-= (nil, sys->sprint("%r"));
		return;
	}
	b := array[Sys->ATOMICIO] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		c <-= (nil, sys->sprint("%r"));
	else
		c <-= (string b[0:n], nil);
}

# a file read whole, however long, or the error
readbig(f: string): (array of byte, string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	b := array[64*1024] of byte;
	n := 0;
	for(;;){
		if(n + Sys->ATOMICIO > len b){
			nb := array[2 * len b] of byte;
			nb[0:] = b[0:n];
			b = nb;
		}
		m := sys->read(fd, b[n:], Sys->ATOMICIO);
		if(m < 0)
			return (nil, sys->sprint("%r"));
		if(m == 0)
			break;
		n += m;
	}
	return (b[0:n], nil);
}

# a value in a window's doc/ctl, as its words
attr(w, name: string): list of string
{
	(nil, lines) := sys->tokenize(readall(w+"/doc/ctl"), "\n");
	for(; lines != nil; lines = tl lines){
		(nil, l) := sys->tokenize(hd lines, " ");
		if(l != nil && hd l == name)
			return tl l;
	}
	return nil;
}

nth(l: list of string, n: int): int
{
	for(; l != nil && n > 0; l = tl l)
		n--;
	if(l == nil)
		return 0;
	return int hd l;
}

# the window's text at an address
textat(w, addr: string): string
{
	afd := sys->open(w+"/addr", Sys->ORDWR);	# held, so it is not reset
	if(afd == nil || sys->fprint(afd, "%s", addr) < 0)
		return nil;
	return readall(w+"/xdata");
}

# doc/text of a binary document read while it opens: the engine read
# every page's text for it holding the row and the window, and Xenith
# answered nothing else until it was done. And B1 on a word of a late
# page read the words of every page before it (a PDF keeps 32 pages'),
# on the mouse task, holding the row, to find the word in the text.
longpdf(): string
{
	f := "/tmp/xrace-long.pdf";
	if((e := longpdf_write(f, LONGPAGES)) != nil)
		return e;
	w := newwin(f);
	if(w == nil)
		return sys->sprint("no window: %r");
	put(w+"/ctl", "growfull\n");
	if((e = put(w+"/ctl", "image "+f+"\n")) != nil)
		return "showing the PDF: "+e;
	for(i := 0; i < 300 && attr(w, "sheets") == nil; i++)
		sys->sleep(100);
	if(attr(w, "sheets") == nil)
		return "the PDF did not open: "+readall(w+"/doc/ctl");

	# its text being read, a client reads doc/text; the index meanwhile
	c := chan of (string, string);
	spawn firstread(w+"/doc/text", c);
	sys->sleep(300);
	if((ms := indexms()) > MOMENT)
		return sys->sprint("the index waited %d ms while doc/text of a %d-page PDF was read", ms, LONGPAGES);
	<-c;

	# the text comes, all of it, and the links
	text: array of byte;
	last := array of byte sys->sprint("--- Page %d ---", LONGPAGES);
	for(i = 0; i < 1200; i++){
		(t, err) := readbig(w+"/doc/text");
		if(err == nil && len t > 2*len last){
			# the last page's mark, near the end
			s := string t[len t - len t/LONGPAGES - 2*len last:];
			if(index(s, string last) >= 0){
				text = t;
				break;
			}
		}
		if(err != nil && err != "loading")
			return "doc/text: "+err;
		sys->sleep(100);
	}
	if(text == nil)
		return "doc/text never gave the PDF's text";
	for(i = 0; i < 300; i++){
		(nil, err) := readbig(w+"/doc/links");
		if(err == nil)
			break;
		if(err != "loading")
			return "doc/links: "+err;
		sys->sleep(100);
	}

	# B1 on Zebra, on page k
	k := LONGPAGES - 20;
	put(w+"/doc/ctl", "scale 100\n");
	put(w+"/doc/ctl", sys->sprint("sheet %d\n", k));
	sys->sleep(500);
	scale := nth(attr(w, "scale"), 0);
	view := attr(w, "view");
	scr := attr(w, "screen");
	colw := nth(attr(w, "column"), 0);
	if(scale != 100 || view == nil || scr == nil)
		return "doc/ctl: "+readall(w+"/doc/ctl");
	vw := nth(view, 2);
	x := (colw - 400) / 2;
	if(colw < vw)
		x += (vw - colw) / 2;
	else
		x -= nth(view, 0);
	top := 12 + (k-1) * (500 + 12) - nth(view, 1);	# the sheet's top in the view
	px := nth(scr, 0) + x + 120;
	py := nth(scr, 1) + top + 270;	# in Zebra's e, 120pt high on its baseline at 300
	pfd := sys->open("#m/pointer", Sys->OWRITE);
	if(pfd == nil)
		return sys->sprint("#m/pointer: %r");
	ptr(pfd, px, py, 0);
	ptr(pfd, px, py, 1);
	ptr(pfd, px, py, 0);
	if((ms = indexms()) > MOMENT)
		return sys->sprint("the index waited %d ms after a click on a word of page %d", ms, k);
	sys->sleep(500);
	(q0, q1) := dot(w);
	word := textat(w, sys->sprint("#%d,#%d", q0, q1));
	mark := textat(w, sys->sprint("#%d-/--- Page [0-9]+ ---/", q0));
	put(w+"/ctl", "delete\n");
	if(word != "Zebra")
		return sys->sprint("the click selected %q (%d,%d) in the text, not Zebra", word, q0, q1);
	if(mark != sys->sprint("--- Page %d ---", k))
		return sys->sprint("the click selected the Zebra after %q, not page %d's", mark, k);
	return nil;
}

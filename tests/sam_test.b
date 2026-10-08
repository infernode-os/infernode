implement SamTest;

#
# The native sam engine (appl/wm/samengine.b), driven over its pipe by
# a scripted terminal.  The fake terminal keeps a rasp mirror of every
# file the way samterm does — holes filled by Trequest, changes applied
# from Hcut/Hgrow/Hgrowdata/Hdata — and balances the terminal's locks,
# so each test sees exactly what a real terminal would and can check
# that the mirror agrees with what `w` puts on disk.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

# appl/wm/samengine.m, which is not under module/
Samengine: module
{
	PATH:	con "/dis/wm/samengine.dis";
	run:	fn(io: ref Sys->FD, args: list of string);
};

# The sam terminal protocol, as appl/wm/samstub.m numbers it (the
# message numbers are Plan 9 sam's and do not change).
Tversion, Tstartcmdfile, Tcheck, Trequest, Torigin, Tstartfile,
Tworkfile, Ttype, Tcut, Tpaste, Tsnarf, Tstartnewfile, Twrite, Tclose,
Tlook, Tsearch, Tsend, Tdclick, Tstartsnarf, Tsetsnarf, Tack, Texit: con iota;

Hversion, Hbindname, Hcurrent, Hnewname, Hmovname, Hgrow, Hcheck0,
Hcheck, Hunlock, Hdata, Horigin, Hunlockfile, Hsetdot, Hgrowdata,
Hmoveto, Hclean, Hdirty, Hcut, Hsetpat, Hdelname, Hclose, Hsetsnarf,
Hsnarflen, Hack, Hexit: con iota;

TBLOCKSIZE: con 512;

SamTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/sam_test.b";

passed := 0;
failed := 0;
skipped := 0;

HOLE: con 16rFFFF;
CMDTAG: con 1000;
DIR: con "/tmp/samtest";

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# ---- the scripted terminal ----

Win: adt {
	tag:	int;
	name:	string;
	text:	string;		# rasp mirror; HOLE marks runes not yet sent
	dot0:	int;
	dot1:	int;
	open:	int;		# has a window
	dirty:	int;
	inmenu:	int;
};

Term: adt {
	io:	ref Sys->FD;
	msgs:	chan of (int, array of byte);
	wins:	list of ref Win;
	locks:	int;
	req:	int;		# a Trequest is outstanding
	pat:	string;		# last Hsetpat
	snarflen:	int;
	exited:	int;
	nexttag:	int;
	originat:	int;	# the last Horigin
	t:	ref T;

	start:	fn(t: ref T, files: list of string): ref Term;
	win:	fn(tm: self ref Term, tag: int): ref Win;
	byname:	fn(tm: self ref Term, name: string): ref Win;
	cmd:	fn(tm: self ref Term): ref Win;
	send:	fn(tm: self ref Term, mtype: int, data: array of byte);
	settle:	fn(tm: self ref Term);
	fill:	fn(tm: self ref Term): int;
	inmesg:	fn(tm: self ref Term, mtype: int, d: array of byte);
	unlock:	fn(tm: self ref Term);
	need:	fn(tm: self ref Term, tag: int, what: string): ref Win;
	openwin:	fn(tm: self ref Term, tag: int, what: string): ref Win;
	open:	fn(tm: self ref Term, w: ref Win);
	sync:	fn(tm: self ref Term);
	command:	fn(tm: self ref Term, w: ref Win, s: string): string;
	output:	fn(tm: self ref Term): string;
	stop:	fn(tm: self ref Term);
};

Term.start(t: ref T, files: list of string): ref Term
{
	engine := load Samengine Samengine->PATH;
	if(engine == nil)
		t.fatal(sys->sprint("can't load %s: %r", Samengine->PATH));
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	spawn engine->run(fds[1], files);
	fds[1] = nil;
	tm := ref Term(fds[0], chan of (int, array of byte), nil, 0, 0, nil, 0, 0, 2000, 0, t);
	spawn reader(fds[0], tm.msgs);

	tm.send(Tversion, pshort(0));
	tm.wins = ref Win(CMDTAG, nil, "", 0, 0, 1, 0, 0) :: nil;
	tm.send(Tstartcmdfile, pvlong(CMDTAG));
	tm.locks++;
	tm.settle();
	return tm;
}

reader(fd: ref Sys->FD, c: chan of (int, array of byte))
{
	hdr := array[3] of byte;
	for(;;){
		if(readn(fd, hdr, 3) != 3)
			break;
		n := int hdr[1] | (int hdr[2] << 8);
		data := array[n] of byte;
		if(readn(fd, data, n) != n)
			break;
		c <-= (int hdr[0], data);
	}
	alt {
	c <-= (-1, nil) =>
		;
	* =>
		;
	}
}

readn(fd: ref Sys->FD, buf: array of byte, n: int): int
{
	got := 0;
	while(got < n){
		r := sys->read(fd, buf[got:], n-got);
		if(r <= 0)
			return got;
		got += r;
	}
	return got;
}

Term.win(tm: self ref Term, tag: int): ref Win
{
	for(l := tm.wins; l != nil; l = tl l)
		if((hd l).tag == tag)
			return hd l;
	return nil;
}

Term.byname(tm: self ref Term, name: string): ref Win
{
	for(l := tm.wins; l != nil; l = tl l)
		if((hd l).name == name && (hd l).tag != CMDTAG)
			return hd l;
	return nil;
}

Term.cmd(tm: self ref Term): ref Win
{
	return tm.win(CMDTAG);
}

Term.send(tm: self ref Term, mtype: int, data: array of byte)
{
	n := len data;
	b := array[3+n] of byte;
	b[0] = byte mtype;
	b[1] = byte n;
	b[2] = byte (n>>8);
	b[3:] = data;
	sys->write(tm.io, b, len b);
}

# Handle host messages until the terminal would be unlocked and every
# open window's rasp is complete.
Term.settle(tm: self ref Term)
{
	for(;;){
		if(tm.locks == 0 && !tm.req && !tm.fill())
			return;
		timeout := chan of int;
		spawn timer(timeout, 5000);
		alt {
		(mtype, data) := <-tm.msgs =>
			if(mtype < 0){
				tm.exited = 1;
				return;
			}
			tm.inmesg(mtype, data);
		<-timeout =>
			tm.t.fatal(sys->sprint("engine silent with %d lock(s) held", tm.locks));
		}
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

# ask for the first hole in any open window; returns 1 if one was asked for.
Term.fill(tm: self ref Term): int
{
	if(tm.req)
		return 1;
	for(l := tm.wins; l != nil; l = tl l){
		w := hd l;
		if(!w.open)
			continue;
		for(i := 0; i < len w.text; i++)
			if(w.text[i] == HOLE){
				n := 0;
				while(i+n < len w.text && w.text[i+n] == HOLE && n < TBLOCKSIZE)
					n++;
				b := array[8] of byte;
				pshortat(b, 0, w.tag);
				plongat(b, 2, i);
				pshortat(b, 6, n);
				tm.send(Trequest, b);
				tm.req = 1;
				tm.locks++;
				return 1;
			}
	}
	return 0;
}

Term.inmesg(tm: self ref Term, mtype: int, d: array of byte)
{
	t := tm.t;
	case mtype {
	Hversion =>
		;
	Hnewname =>
		tag := gshort(d, 0);
		w := tm.win(tag);
		if(w == nil){
			w = ref Win(tag, "", "", 0, 0, 0, 0, 1);
			tm.wins = w :: tm.wins;
		}
		w.inmenu = 1;
	Hbindname =>
		tag := gshort(d, 0);
		termtag := int gvlong(d, 2);
		w := tm.win(termtag);
		if(w == nil)
			t.fatal(sys->sprint("Hbindname to unknown window %d", termtag));
		# the menu entry Hnewname made is replaced by the window
		nw: list of ref Win;
		for(l := tm.wins; l != nil; l = tl l)
			if((hd l).tag != tag || hd l == w)
				nw = hd l :: nw;
		tm.wins = nw;
		w.tag = tag;
		w.inmenu = 1;
	Hmovname =>
		w := tm.need(gshort(d, 0), "Hmovname");
		w.name = string d[2:];
	Hcurrent =>
		w := tm.need(gshort(d, 0), "Hcurrent");
		if(!w.open){
			w.open = 1;
			w.text = "";
			tm.send(Tstartfile, pvlong(w.tag));
			tm.locks++;
		}
	Hgrow =>
		w := tm.openwin(gshort(d, 0), "Hgrow");
		(p, n) := (glong(d, 2), glong(d, 6));
		if(p < 0 || p > len w.text)
			t.fatal(sys->sprint("Hgrow at %d in %d runes", p, len w.text));
		holes := "";
		for(i := 0; i < n; i++)
			holes[i] = HOLE;
		w.text = w.text[0:p] + holes + w.text[p:];
	Hgrowdata =>
		w := tm.openwin(gshort(d, 0), "Hgrowdata");
		(p, n) := (glong(d, 2), glong(d, 6));
		s := string d[10:];
		if(len s != n)
			t.fatal(sys->sprint("Hgrowdata says %d runes, carries %d", n, len s));
		if(p < 0 || p > len w.text)
			t.fatal(sys->sprint("Hgrowdata at %d in %d runes", p, len w.text));
		w.text = w.text[0:p] + s + w.text[p:];
	Hdata =>
		w := tm.openwin(gshort(d, 0), "Hdata");
		p := glong(d, 2);
		s := string d[6:];
		for(i := 0; i < len s; i++){
			if(p+i >= len w.text || w.text[p+i] != HOLE)
				t.fatal(sys->sprint("Hdata overwrites text at %d", p+i));
			w.text[p+i] = s[i];
		}
		tm.req = 0;
		tm.unlock();
	Hcut =>
		w := tm.openwin(gshort(d, 0), "Hcut");
		(p, n) := (glong(d, 2), glong(d, 6));
		if(p < 0 || p+n > len w.text)
			t.fatal(sys->sprint("Hcut %d,%d of %d runes", p, p+n, len w.text));
		w.text = w.text[0:p] + w.text[p+n:];
	Horigin =>
		tm.openwin(gshort(d, 0), "Horigin");
		tm.originat = glong(d, 2);
		tm.unlock();
	Hunlock =>
		tm.unlock();
	Hsetdot =>
		w := tm.openwin(gshort(d, 0), "Hsetdot");
		(w.dot0, w.dot1) = (glong(d, 2), glong(d, 6));
		if(w.dot0 < 0 || w.dot1 < w.dot0 || w.dot1 > len w.text)
			t.fatal(sys->sprint("Hsetdot %d,%d of %d runes", w.dot0, w.dot1, len w.text));
	Hmoveto =>
		tm.openwin(gshort(d, 0), "Hmoveto");
	Hcheck =>
		tm.need(gshort(d, 0), "Hcheck");
	Hdirty =>
		tm.openwin(gshort(d, 0), "Hdirty").dirty = 1;
	Hclean =>
		tm.openwin(gshort(d, 0), "Hclean").dirty = 0;
	Hsetpat =>
		tm.pat = string d;
	Hsnarflen =>
		tm.snarflen = glong(d, 0);
	Hclose =>
		w := tm.openwin(gshort(d, 0), "Hclose");
		w.open = 0;
		w.text = "";
	Hdelname =>
		w := tm.need(gshort(d, 0), "Hdelname");
		if(w.open)
			t.fatal("Hdelname of a file with a window");
		nw: list of ref Win;
		for(l := tm.wins; l != nil; l = tl l)
			if(hd l != w)
				nw = hd l :: nw;
		tm.wins = nw;
	Hexit =>
		tm.exited = 1;
	* =>
		t.fatal(sys->sprint("unexpected H message %d", mtype));
	}
}

Term.unlock(tm: self ref Term)
{
	if(tm.locks <= 0)
		tm.t.fatal("unlocked a terminal that wasn't locked");
	tm.locks--;
}

Term.need(tm: self ref Term, tag: int, what: string): ref Win
{
	w := tm.win(tag);
	if(w == nil || !w.inmenu)
		tm.t.fatal(sys->sprint("%s for tag %d, not in the menu", what, tag));
	return w;
}

# a message only a terminal with a window (samterm panics otherwise)
Term.openwin(tm: self ref Term, tag: int, what: string): ref Win
{
	w := tm.need(tag, what);
	if(!w.open)
		tm.t.fatal(sys->sprint("%s for %s, which has no window", what, w.name));
	return w;
}

# Type a command into the command window, as samterm does: Tworkfile
# then the typed text, one lock.  Returns what the command printed.
Term.command(tm: self ref Term, w: ref Win, s: string): string
{
	c := tm.cmd();
	before := len c.text;
	if(w != nil){
		b := array[10] of byte;
		pshortat(b, 0, w.tag);
		plongat(b, 2, w.dot0);
		plongat(b, 6, w.dot1);
		tm.send(Tworkfile, b);
	}
	c.text += s;
	tm.send(Ttype, tslS(CMDTAG, before, s));
	tm.locks++;
	tm.settle();
	# output is inserted after the typed command
	out := c.text[before+len s:];
	return out;
}

Term.output(tm: self ref Term): string
{
	return tm.cmd().text;
}

# wait until the engine has handled everything sent so far
Term.sync(tm: self ref Term)
{
	tm.command(nil, "=\n");
}

Term.stop(tm: self ref Term)
{
	tm.send(Texit, nil);
	# let the reader see the engine go
	for(;;){
		timeout := chan of int;
		spawn timer(timeout, 2000);
		alt {
		(mtype, nil) := <-tm.msgs =>
			if(mtype < 0)
				return;
		<-timeout =>
			return;
		}
	}
}

# ---- helpers ----

tsll(tag, a, b: int): array of byte
{
	d := array[10] of byte;
	pshortat(d, 0, tag);
	plongat(d, 2, a);
	plongat(d, 6, b);
	return d;
}

tsl(tag, a: int): array of byte
{
	d := array[6] of byte;
	pshortat(d, 0, tag);
	plongat(d, 2, a);
	return d;
}

tslS(tag, a: int, s: string): array of byte
{
	sb := array of byte s;
	d := array[6+len sb] of byte;
	pshortat(d, 0, tag);
	plongat(d, 2, a);
	d[6:] = sb;
	return d;
}

pshort(v: int): array of byte
{
	a := array[2] of byte;
	pshortat(a, 0, v);
	return a;
}

pshortat(a: array of byte, off, v: int)
{
	a[off] = byte v;
	a[off+1] = byte (v>>8);
}

plongat(a: array of byte, off, v: int)
{
	for(i := 0; i < 4; i++)
		a[off+i] = byte (v >> (8*i));
}

pvlong(v: int): array of byte
{
	a := array[8] of byte;
	for(i := 0; i < 8; i++)
		a[i] = byte (big v >> (8*i));
	return a;
}

gshort(a: array of byte, off: int): int
{
	return int a[off] | (int a[off+1] << 8);
}

glong(a: array of byte, off: int): int
{
	return int a[off] | (int a[off+1] << 8) | (int a[off+2] << 16) | (int a[off+3] << 24);
}

gvlong(a: array of byte, off: int): big
{
	v := big 0;
	for(i := 7; i >= 0; i--)
		v = (v << 8) | big (int a[off+i]);
	return v;
}

writefile(name, s: string)
{
	fd := sys->create(name, Sys->OWRITE, 8r666);
	b := array of byte s;
	sys->write(fd, b, len b);
}

readfile(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

SAMPLE: con "one apple\ntwo pears\nthree apples\nfour\n";

# A session with one file holding text, its window open and filled.
# As in sam, a file named on the command line is only put in the menu;
# the window is opened the way samterm does when the file is chosen
# from menu 3.
session(t: ref T, name, text: string): (ref Term, ref Win)
{
	path := DIR + "/" + name;
	writefile(path, text);
	tm := Term.start(t, path :: nil);
	w := tm.byname(path);
	if(w == nil)
		t.fatal("file not in the menu");
	if(w.open)
		t.fatal("a window was opened before anything asked for one");
	tm.open(w);
	return (tm, w);
}

# menu 3, a file with no window: sweeptext's Tstartfile
Term.open(tm: self ref Term, w: ref Win)
{
	w.open = 1;
	w.text = "";
	tm.send(Tstartfile, pvlong(w.tag));
	tm.locks++;
	tm.settle();
}

# the rasp must agree with the file written from it
checkwrite(t: ref T, tm: ref Term, w: ref Win, want: string)
{
	tm.command(w, "w\n");
	got := readfile(w.name);
	t.assertseq(got, want, "file on disk");
	t.assertseq(w.text, want, "terminal's rasp");
}

# ---- tests ----

testStartup(t: ref T)
{
	(tm, w) := session(t, "startup", SAMPLE);
	t.assertseq(w.text, SAMPLE, "rasp filled from Trequest");
	t.assertseq(tm.cmd().name, "~~sam~~", "command window has a menu entry");
	t.assertseq(tm.output(), " -. " + w.name + "\n", "load reported with the file's menu line");
	t.assert(!w.dirty, "fresh file is clean");
	tm.stop();
}

# sam.c and cmd.c: the files named are read only when first used, and
# the terminal is sent Hcurrent (which sweeps a window) after a command
# that reads the current file, or makes another file current
testLazyCurrent(t: ref T)
{
	path := DIR + "/lazy";
	writefile(path, SAMPLE);
	tm := Term.start(t, path :: nil);
	w := tm.byname(path);
	t.assert(w != nil && !w.open, "in the menu, no window");
	t.assertseq(tm.output(), "", "nothing read at startup");
	t.assertseq(tm.command(nil, "2p\n"), " -. " + path + "\ntwo pears\n", "read when first used");
	t.assert(w.open, "and its window asked for");
	t.assertseq(w.text, SAMPLE, "with the file in it");
	tm.stop();
}

# moveto.c's lookorigin: Torigin p0 ls starts the window ls lines back
# from p0, so 1 is the start of p0's own line
testOrigin(t: ref T)
{
	(tm, w) := session(t, "origin", SAMPLE);
	tm.originat = -1;
	tm.send(Torigin, tsll(w.tag, 14, 1));
	tm.locks++;
	tm.settle();
	t.asserteq(tm.originat, 10, "ls 1: start of the line");
	tm.send(Torigin, tsll(w.tag, 14, 2));
	tm.locks++;
	tm.settle();
	t.asserteq(tm.originat, 0, "ls 2: the line before");
	tm.send(Torigin, tsll(w.tag, 10, 1));
	tm.locks++;
	tm.settle();
	t.asserteq(tm.originat, 10, "ls 1 at a line start: that line");
	tm.stop();
}

testAddresses(t: ref T)
{
	(tm, w) := session(t, "addr", SAMPLE);
	t.assertseq(tm.command(w, "2p\n"), "two pears\n", "line address");
	t.assertseq(tm.command(w, "$-1p\n"), "four\n", "$-1");
	t.assertseq(tm.command(w, "#4,#9p\n"), "apple", "character addresses");
	t.assertseq(tm.command(w, "0,/pears/p\n"), "one apple\ntwo pears", "0,/re/");
	t.assertseq(tm.command(w, "/apple/=\n"), "3; #26,#31\n", "search continues from dot");
	tm.command(w, "/two/\n");
	t.assertseq(tm.command(w, "-/apple/=\n"), "1; #4,#9\n", "backward search with -");
	t.assertseq(tm.command(w, "?one?p\n"), "one", "?re?");
	t.assertseq(tm.command(w, "/^t/p\n"), "t", "^ matches at line starts");
	t.assertseq(tm.command(w, "/r$/-#1,/r$/p\n"), "ur", "$ matches at line ends");
	t.assertseq(tm.command(w, "2;+1p\n"), "two pears\nthree apples\n", "a;b evaluates b from a");
	t.assertseq(tm.command(w, "3\n"), "", "an address alone selects");
	t.asserteq(w.dot0, 20, "dot start after 3");
	t.asserteq(w.dot1, 33, "dot end after 3");
	# xec.c's nl_cmd: an empty command selects the next line and prints it
	tm.command(w, "1\n");
	t.assertseq(tm.command(w, "\n"), "two pears\n", "newline alone prints the next line");
	t.assertseq(tm.command(w, "9p\n"), "?address out of range\n", "range error");
	t.assertseq(tm.command(w, "/nothere/\n"), "?no match for regexp\n", "search error");
	tm.stop();
}

testEdits(t: ref T)
{
	(tm, w) := session(t, "edits", SAMPLE);
	tm.command(w, "1d\n");
	tm.command(w, "$a/five\\n/\n");
	tm.command(w, "1i/zero\\n/\n");
	tm.command(w, "/pears/c/plums/\n");
	t.assert(w.dirty, "edited file is dirty");
	checkwrite(t, tm, w, "zero\ntwo plums\nthree apples\nfour\nfive\n");
	t.assert(!w.dirty, "written file is clean");
	tm.stop();
}

testMultilineText(t: ref T)
{
	(tm, w) := session(t, "multi", "a\nb\n");
	# a/i/c text may follow on lines of its own, ended by "."
	tm.command(w, "1a\n");
	tm.command(w, "x\n");
	tm.command(w, "y\n");
	tm.command(w, ".\n");
	checkwrite(t, tm, w, "a\nx\ny\nb\n");
	tm.stop();
}

testSubstitute(t: ref T)
{
	(tm, w) := session(t, "subst", SAMPLE);
	tm.command(w, ",s/apple/fig/g\n");
	tm.command(w, ",s/p(e)(a)rs/p\\2\\1rs/\n");
	tm.command(w, "3s2/e/E/\n");		# second match only
	tm.command(w, ",s/four/[&]/\n");
	checkwrite(t, tm, w, "one fig\ntwo paers\nthreE figs\n[four]\n");
	t.assertseq(tm.command(w, ",s/nothing/x/\n"), "?no substitution\n", "no match");
	tm.stop();
}

testLoops(t: ref T)
{
	(tm, w) := session(t, "loops", SAMPLE);
	# every change is addressed in the original text, applied together
	tm.command(w, ",x/apple/c/orange/\n");
	tm.command(w, ",x g/pears/d\n");
	tm.command(w, ",x/.*\\n/ v/orange/ i/# /\n");
	tm.command(w, ",y/\\n/ a/;/\n");
	# y also runs on the empty piece after the last newline, as in sam
	checkwrite(t, tm, w, "one orange;\nthree oranges;\n# four;\n;");
	t.assertseq(tm.command(w, ",x/e/ =#\n"), "#2,#3\n#9,#10\n#15,#16\n#16,#17\n#23,#24\n",
		"x runs its body per match");
	tm.stop();
}

testBlocks(t: ref T)
{
	(tm, w) := session(t, "blocks", "abc\n");
	tm.command(w, "1{\n");
	tm.command(w, "i/</\n");
	tm.command(w, "a/>/\n");
	tm.command(w, "}\n");
	checkwrite(t, tm, w, "<abc\n>");
	t.assertseq(tm.command(w, ",{\n"), "", "open block waits for more");
	t.assertseq(tm.command(w, "a/x/\n"), "", "still waiting");
	t.assertseq(tm.command(w, "i/y/\n"), "", "still waiting");
	t.assertseq(tm.command(w, "}\n"), "?changes not in sequence\n", "sequence enforced");
	tm.stop();
}

testMoveCopy(t: ref T)
{
	(tm, w) := session(t, "mt", "1\n2\n3\n");
	tm.command(w, "1m$\n");
	tm.command(w, "$-1t0\n");
	checkwrite(t, tm, w, "1\n2\n3\n1\n");
	t.assertseq(tm.command(w, "1,2m1\n"), "?addresses overlap\n", "overlap refused");
	tm.stop();
}

testUndo(t: ref T)
{
	(tm, w) := session(t, "undo", SAMPLE);
	tm.command(w, "1d\n");
	tm.command(w, ",s/a/A/g\n");
	t.assert(w.dirty, "dirty after edits");
	tm.command(w, "u\n");
	t.assertseq(w.text, "two pears\nthree apples\nfour\n", "undo one command");
	tm.command(w, "u\n");
	t.assertseq(w.text, SAMPLE, "undo back to the start");
	t.assert(!w.dirty, "undone to the file as read: clean");
	tm.command(w, "u-2\n");
	t.assertseq(w.text, "two peArs\nthree Apples\nfour\n", "redo");
	t.assert(w.dirty, "redone: dirty again");
	tm.stop();
}

testTyping(t: ref T)
{
	(tm, w) := session(t, "typing", "hello\n");
	# the terminal echoes typing itself and tells the host afterwards
	w.text = "hello, world\n";
	tm.send(Ttype, tslS(w.tag, 5, ", wor"));
	tm.send(Ttype, tslS(w.tag, 10, "ld"));
	w.text = "hello, world";
	tm.send(Tcut, tsll(w.tag, 12, 13));
	checkwrite(t, tm, w, "hello, world");
	tm.command(w, "u\n");
	t.assertseq(w.text, "hello, world\n", "undo the cut");
	tm.command(w, "u\n");
	t.assertseq(w.text, "hello\n", "a run of typing undoes at once");
	tm.stop();
}

testSnarfPaste(t: ref T)
{
	(tm, w) := session(t, "snarf", "abc\ndef\n");
	tm.send(Tsnarf, tsll(w.tag, 0, 3));
	tm.send(Tpaste, tsl(w.tag, 8));
	tm.sync();
	t.assertseq(w.text, "abc\ndef\nabc", "pasted from the snarf buffer");
	t.asserteq(w.dot0, 8, "dot is the pasted text");
	t.asserteq(w.dot1, 11, "dot is the pasted text");
	tm.stop();
}

testLookSearch(t: ref T)
{
	(tm, w) := session(t, "look", "x.y a x.y b xzy\n");
	tm.send(Tlook, tsll(w.tag, 0, 3));
	tm.locks++;
	tm.settle();
	t.asserteq(w.dot0, 6, "look finds the literal text");
	t.assertseq(tm.pat, "x\\.y", "look sets the pattern, quoted");
	tm.send(Tworkfile, tsll(w.tag, w.dot0, w.dot1));
	tm.send(Tsearch, nil);
	tm.locks++;
	tm.settle();
	t.asserteq(w.dot0, 0, "search wraps to the next match");
	tm.stop();
}

testDoubleClick(t: ref T)
{
	(tm, w) := session(t, "dclick", "f(a, (b)) word_1 x\nline two\n");
	dclick(tm, w, 2);
	t.assertseq(w.text[w.dot0:w.dot1], "a, (b)", "inside brackets");
	dclick(tm, w, 12);
	t.assertseq(w.text[w.dot0:w.dot1], "word_1", "a word");
	dclick(tm, w, 19);
	t.assertseq(w.text[w.dot0:w.dot1], "line two\n", "start of a line");
	tm.stop();
}

dclick(tm: ref Term, w: ref Win, p: int)
{
	tm.send(Tdclick, tsl(w.tag, p));
	tm.locks++;
	tm.settle();
}

testSend(t: ref T)
{
	(tm, w) := session(t, "send", "p\n1d\n");
	tm.send(Tworkfile, tsll(w.tag, 0, 0));
	tm.send(Tsend, tsll(w.tag, 2, 4));
	tm.locks++;
	tm.settle();
	t.assertseq(w.text, "1d\n", "sent text ran as a command");
	t.asserteq(tm.snarflen, 2, "sent text is snarfed");
	tm.stop();
}

testCloseAndNew(t: ref T)
{
	(tm, w) := session(t, "close", "text\n");
	tm.command(w, "1d\n");
	tm.send(Tclose, pshort(w.tag));
	tm.locks++;
	tm.settle();
	t.assert(tm.win(w.tag) != nil, "dirty file not closed the first time");
	t.assert(len tm.output() > 0, "warned about changes");
	tm.send(Tclose, pshort(w.tag));
	tm.locks++;
	tm.settle();
	t.assert(tm.win(w.tag) == nil, "closed on the second request");

	# a new window becomes an unnamed file
	nw := ref Win(tm.nexttag++, "", "", 0, 0, 1, 0, 0);
	tm.wins = nw :: tm.wins;
	tm.send(Tstartnewfile, pvlong(nw.tag));
	tm.sync();
	t.assert(nw.tag < 1000, "host tag bound to the new window");
	t.assert(nw.inmenu, "new file is in the menu");
	tm.command(nw, "a/fresh\\n/\n");
	t.assertseq(tm.command(nw, "w\n"), "?no file name\n", "unnamed file needs a name");
	tm.command(nw, "w " + DIR + "/new\n");
	t.assertseq(readfile(DIR + "/new"), "fresh\n", "written under the given name");
	t.assertseq(nw.name, DIR + "/new", "and named by it");
	tm.stop();
}

testFiles(t: ref T)
{
	writefile(DIR + "/f1", "first\n");
	writefile(DIR + "/f2", "second\n");
	tm := Term.start(t, (DIR + "/f1") :: nil);
	w1 := tm.byname(DIR + "/f1");
	tm.open(w1);
	tm.command(w1, "B " + DIR + "/f2\n");
	w2 := tm.byname(DIR + "/f2");
	t.assert(w2 != nil && w2.open, "B opens a file");
	tm.command(w2, "X/f[12]/ ,s/$/!/\n");
	t.assertseq(w1.text, "first!\n", "X ran in f1");
	t.assertseq(w2.text, "second!\n", "X ran in f2");
	t.assertseq(tm.command(w2, "n\n"), "'+  " + DIR + "/f1\n'+. " + DIR + "/f2\n", "n lists files");
	tm.command(w2, "b " + DIR + "/f1\n");
	t.assertseq(tm.command(w1, "=\n"), "1; #0,#7\n", "b switches the current file");
	t.assertseq(tm.command(w1, "q\n"), "?changes to files\n", "q warns once");
	tm.command(w1, "q\n");
	t.assert(tm.exited, "second q exits");
	tm.stop();
}

testShell(t: ref T)
{
	(tm, w) := session(t, "shell", "abc\n");
	tm.command(w, ",|tr a-z A-Z\n");
	t.assertseq(w.text, "ABC\n", "| pipes dot through a command");
	tm.command(w, "$<echo tail\n");
	t.assertseq(w.text, "ABC\ntail\n", "< inserts a command's output");
	out := tm.command(w, "1>wc -c\n");
	t.assert(out != "" && out[len out-2:] == "!\n", "> shows output then !");
	tm.stop();
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	sys->create("/tmp", Sys->OREAD, Sys->DMDIR|8r777);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR|8r777);

	run("Startup", testStartup);
	run("LazyCurrent", testLazyCurrent);
	run("Origin", testOrigin);
	run("Addresses", testAddresses);
	run("Edits", testEdits);
	run("MultilineText", testMultilineText);
	run("Substitute", testSubstitute);
	run("Loops", testLoops);
	run("Blocks", testBlocks);
	run("MoveCopy", testMoveCopy);
	run("Undo", testUndo);
	run("Typing", testTyping);
	run("SnarfPaste", testSnarfPaste);
	run("LookSearch", testLookSearch);
	run("DoubleClick", testDoubleClick);
	run("Send", testSend);
	run("CloseAndNew", testCloseAndNew);
	run("Files", testFiles);
	run("Shell", testShell);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

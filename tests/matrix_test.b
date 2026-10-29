implement MatrixTest;

#
# matrix_test - Matrix composition runtime tests
#
# Phase 1: composition parser units via lib/matrixlib — the three
# shipped compositions parse to the expected shapes, and malformed
# input is rejected with a diagnostic rather than a partial tree.
#
# Later phases (added with the runtime work they test): transplant
# units, the /mnt/matrix 9P surface, service isolation, incremental
# reload, and watch rules.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;

include "tk.m";

include "matrix.m";

include "matrixtk.m";

include "matrixlib.m";
	matrixlib: MatrixLib;

include "sh.m";
	sh: Sh;

include "testing.m";
	testing: Testing;
	T: import testing;

MatrixTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/matrix_test.b";

passed := 0;
failed := 0;
skipped := 0;

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

# ── Helpers ─────────────────────────────────────────────────

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	content := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		content += string buf[0:n];
	}
	return content;
}

# Find a leaf by its region name.
leafbyname(node: ref LayoutNode, name: string): ref LayoutNode.Leaf
{
	if(node == nil)
		return nil;
	pick n := node {
	Split =>
		l := leafbyname(n.child1, name);
		if(l != nil)
			return l;
		return leafbyname(n.child2, name);
	Leaf =>
		if(n.name == name)
			return n;
	}
	return nil;
}

countleaves(node: ref LayoutNode): int
{
	if(node == nil)
		return 0;
	pick n := node {
	Split =>
		return countleaves(n.child1) + countleaves(n.child2);
	Leaf =>
		return 1;
	}
	return 0;
}

servicebyname(c: ref Composition, name: string): ref ServiceEntry
{
	for(sl := c.services; sl != nil; sl = tl sl)
		if((hd sl).name == name)
			return hd sl;
	return nil;
}

nservices(c: ref Composition): int
{
	n := 0;
	for(sl := c.services; sl != nil; sl = tl sl)
		n++;
	return n;
}

nassigns(c: ref Composition): int
{
	n := 0;
	for(al := c.assigns; al != nil; al = tl al)
		n++;
	return n;
}

# hasprefix for name checks without binding to full punctuation.
hasprefix(s, pre: string): int
{
	return len s >= len pre && s[0:len pre] == pre;
}

trim(s: string): string
{
	start := 0;
	end := len s;
	while(start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n'))
		start++;
	while(end > start && (s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\n'))
		end--;
	return s[start:end];
}

readbytesfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	data := array[0] of byte;
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		grown := array[len data + n] of byte;
		grown[0:] = data;
		grown[len data:] = buf[0:n];
		data = grown;
	}
	return data;
}

writestr(path, s: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte s;
	return sys->write(fd, b, len b);
}

# Poll until path stats OK, up to ms milliseconds.
waitfor(path: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 250) {
		(ok, nil) := sys->stat(path);
		if(ok >= 0)
			return 1;
		sys->sleep(250);
	}
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

lsnames(path: string): list of string
{
	names: list of string;
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			names = dirs[i].name :: names;
	}
	return names;
}

hasname(names: list of string, want: string): int
{
	for(; names != nil; names = tl names)
		if(hd names == want)
			return 1;
	return 0;
}

matrixpid := -1;

# Find the pid of a proc whose /prog status names the given module.
# Used to kill the matrix process group at teardown — matrix is
# launched via sh (see testControlFSStart), which does not report
# the background pid.
pidofmodule(modname: string): int
{
	# /prog/<pid>/status: pid pgrp user time state memsize module
	# The module name can carry a [$Sys] suffix while blocked in a
	# syscall.  Prefer the group leader (pid == pgrp) so killgrp on
	# the result takes the whole matrix process group down.
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	anypid := -1;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			status := readfile("/prog/" + dirs[i].name + "/status");
			if(status == nil)
				continue;
			(nil, toks) := sys->tokenize(status, " \t\n");
			last := "";
			pgrp := "";
			nf := 0;
			for(tp := toks; tp != nil; tp = tl tp) {
				if(nf == 1)
					pgrp = hd tp;
				last = hd tp;
				nf++;
			}
			if(!hasprefix(last, modname))
				continue;
			if(dirs[i].name == pgrp)
				return int dirs[i].name;
			if(anypid < 0)
				anypid = int dirs[i].name;
		}
	}
	return anypid;
}

# ── Parser: shipped compositions ────────────────────────────

testParseSysmon(t: ref T)
{
	text := readfile("/lib/matrix/compositions/sysmon");
	if(text == "")
		t.fatal("cannot read shipped sysmon composition");
	(c, err) := matrixlib->parsecomposition(text);
	t.assertnil(err, "sysmon parses cleanly");
	if(c == nil)
		t.fatal("nil composition");
	t.assert(hasprefix(c.name, "sysmon"), "name from first comment: " + c.name);
	t.assert(c.layout != nil, "has a layout");
	t.asserteq(countleaves(c.layout), 4, "hsplit + two vsplits = 4 leaves");
	t.asserteq(nassigns(c), 4, "four display assignments");
	t.asserteq(nservices(c), 1, "one service");

	se := servicebyname(c, "sysmon-svc");
	if(se == nil)
		t.fatal("sysmon-svc service missing");
	t.assertseq(se.mount, "/", "sysmon-svc mounts the whole namespace");

	lt := leafbyname(c.layout, "left/top");
	if(lt == nil)
		t.fatal("left/top leaf missing");
	t.assertseq(lt.modname, "cpu-gauge", "left/top module");
	t.assertseq(lt.mount, "/tmp/matrix/sysmon-svc", "displays read the service outdir");

	r := leafbyname(c.layout, "right/top");
	if(r == nil)
		t.fatal("right/top leaf missing");
	t.assertseq(r.modname, "proc-list", "right/top module");
	rb := leafbyname(c.layout, "right/bottom");
	if(rb == nil)
		t.fatal("right/bottom leaf missing");
	t.assertseq(rb.modname, "net-gauge", "right/bottom module");
}

testParsePerfDashboard(t: ref T)
{
	text := readfile("/lib/matrix/compositions/perf-dashboard");
	if(text == "")
		t.fatal("cannot read shipped perf-dashboard composition");
	(c, err) := matrixlib->parsecomposition(text);
	t.assertnil(err, "perf-dashboard parses cleanly");
	if(c == nil)
		t.fatal("nil composition");
	t.asserteq(countleaves(c.layout), 2, "vsplit = 2 leaves");
	t.asserteq(nservices(c), 1, "one service");

	se := servicebyname(c, "llm-recorder");
	if(se == nil)
		t.fatal("llm-recorder service missing");
	t.assertseq(se.mount, "/mnt/llm", "llm-recorder mount");

	top := leafbyname(c.layout, "top");
	if(top == nil)
		t.fatal("top leaf missing");
	t.assertseq(top.modname, "llm-sessions", "top module");
	t.assertseq(top.mount, "/tmp/matrix/llm-recorder", "top reads recorder outdir");
}

# a shipped composition with a nested split and a service
# (tbl4-overview was retired in ccac4516; video-demo has its shape)
testParseVideoDemo(t: ref T)
{
	text := readfile("/lib/matrix/compositions/video-demo");
	if(text == "")
		t.fatal("cannot read shipped video-demo composition");
	(c, err) := matrixlib->parsecomposition(text);
	t.assertnil(err, "video-demo parses cleanly");
	if(c == nil)
		t.fatal("nil composition");
	t.asserteq(countleaves(c.layout), 3, "nested split = 3 leaves");
	lb := leafbyname(c.layout, "left/bottom");
	if(lb == nil)
		t.fatal("left/bottom leaf missing");
	t.assertseq(lb.modname, "video-pane", "left/bottom module");
	t.assertseq(lb.mount, "/mnt/videob/0", "left/bottom mount");
	t.asserteq(nservices(c), 1, "one service");
}

# ── Parser: structure and edge cases ────────────────────────

testHeadlessComposition(t: ref T)
{
	(c, err) := matrixlib->parsecomposition("# svc-only\nservice foo /mnt/foo\nservice bar /mnt/bar\n");
	t.assertnil(err, "service-only composition parses");
	if(c == nil)
		t.fatal("nil composition");
	t.assert(c.layout == nil, "no layout");
	t.asserteq(nservices(c), 2, "two services");
	t.assert(c.watches == nil, "no watches yet");
}

testEmptyComposition(t: ref T)
{
	(c, err) := matrixlib->parsecomposition("# empty\n");
	t.assertnil(err, "empty composition parses");
	if(c == nil)
		t.fatal("nil composition");
	t.assert(c.layout == nil, "no layout");
	t.asserteq(nservices(c), 0, "no services");
	t.assertseq(c.name, "empty", "name from comment");
}

testNestedSplits(t: ref T)
{
	text := "layout hsplit 60 40\n" +
		"left vsplit 70 30\n" +
		"right vsplit 50 50\n" +
		"left/top a /m/a\n" +
		"left/bottom b /m/b\n" +
		"right/top c /m/c\n" +
		"right/bottom d /m/d\n";
	(c, err) := matrixlib->parsecomposition(text);
	t.assertnil(err, "nested splits parse");
	if(c == nil)
		t.fatal("nil composition");
	t.asserteq(countleaves(c.layout), 4, "four leaves");
	rb := leafbyname(c.layout, "right/bottom");
	if(rb == nil)
		t.fatal("right/bottom missing");
	t.assertseq(rb.modname, "d", "right/bottom assigned");
	t.assertseq(rb.mount, "/m/d", "right/bottom mount");
}

testDuplicateLayout(t: ref T)
{
	(c, err) := matrixlib->parsecomposition("layout hsplit 1 1\nlayout vsplit 1 1\n");
	t.assert(c == nil, "no composition on error");
	t.assertseq(err, "duplicate layout declaration", "duplicate layout rejected");
}

testBadOrientation(t: ref T)
{
	(nil, err) := matrixlib->parsecomposition("layout diagonal 1 1\n");
	t.assertseq(err, "layout: expected hsplit or vsplit", "bad orientation rejected");
}

testBadRatio(t: ref T)
{
	(nil, err) := matrixlib->parsecomposition("layout hsplit sixty 40\n");
	t.assertseq(err, "layout: bad ratio1", "non-integer ratio rejected");
}

testUnknownRegionSplit(t: ref T)
{
	(nil, err) := matrixlib->parsecomposition("layout hsplit 1 1\ncentre vsplit 1 1\n");
	t.assertseq(err, "centre: unknown region for split", "splitting unknown region rejected");
}

testUnknownRegionAssign(t: ref T)
{
	(nil, err) := matrixlib->parsecomposition("layout hsplit 1 1\ncentre mod /m\n");
	t.assertseq(err, "centre: region not found in layout", "assigning unknown region rejected");
}

testSplitConsumedRegion(t: ref T)
{
	# Splitting a region replaces it: the old name is no longer a leaf.
	(nil, err) := matrixlib->parsecomposition(
		"layout hsplit 1 1\nleft vsplit 1 1\nleft mod /m\n");
	t.assertseq(err, "left: region not found in layout", "split region no longer assignable");
}

testMaxDepth(t: ref T)
{
	text := "layout hsplit 1 1\n" +
		"left vsplit 1 1\n" +
		"left/top hsplit 1 1\n" +
		"left/top/left vsplit 1 1\n" +
		"left/top/left/top hsplit 1 1\n";
	(nil, err) := matrixlib->parsecomposition(text);
	t.assertseq(err, "left/top/left/top: max layout depth exceeded", "depth cap enforced");
}

testServiceNeedsMount(t: ref T)
{
	(nil, err) := matrixlib->parsecomposition("service lonely\n");
	t.assertseq(err, "service needs: name mount", "service without mount rejected");
}

testUnsafeCompositionTokens(t: ref T)
{
	(nil, err) := matrixlib->parsecomposition("service ../owned /m\n");
	t.assertseq(err, "service: unsafe module name", "unsafe service name rejected");

	(nil, err) = matrixlib->parsecomposition("service svc /m/../secret\n");
	t.assertseq(err, "service: unsafe mount path", "unsafe service mount rejected");

	(nil, err) = matrixlib->parsecomposition("service svc /m,secret\n");
	t.assertseq(err, "service: unsafe mount path", "unsafe service delimiter rejected");

	(nil, err) = matrixlib->parsecomposition("service svc /m extra\n");
	t.assertseq(err, "service needs: name mount", "extra service token rejected");

	(nil, err) = matrixlib->parsecomposition("layout hsplit 1 1\nleft ../owned /m\n");
	t.assertseq(err, "left: unsafe module name", "unsafe display module rejected");

	(nil, err) = matrixlib->parsecomposition("layout hsplit 1 1\nleft mod /m extra\n");
	t.assertseq(err, "left: display module needs: name mount", "extra display token rejected");

	(nil, err) = matrixlib->parsecomposition("layout hsplit 1 1\nleft app /dis/sh.dis\n");
	t.assertseq(err, "left: unsafe app path", "unsafe app path rejected");
}

# What the parser refuses because nothing sensible can come of it:
# each case was accepted, and either ignored or turned into a broken
# layout or a clash in the runtime.
# Every composition the library ships parses.
testShippedCompositions(t: ref T)
{
	names := lsnames("/lib/matrix/compositions");
	n := 0;
	for(; names != nil; names = tl names) {
		nm := hd names;
		(nil, err) := matrixlib->parsecomposition(readfile("/lib/matrix/compositions/" + nm));
		t.assertnil(err, nm + " parses");
		n++;
	}
	t.assert(n >= 10, sys->sprint("the library ships compositions (%d)", n));
}

testCompositionRefusals(t: ref T)
{
	cases := array[] of {
		# A negative weight puts the divider outside the pane.
		("layout hsplit -10 40\n", "layout: bad ratio1"),
		("layout hsplit 1 1\nleft vsplit 3 -1\n", "left: bad ratio2"),
		# Both zero divide nothing.
		("layout hsplit 0 0\n", "layout: ratios sum to zero"),
		# Weights big enough to overflow width*weight.
		("layout hsplit 9999999 1\n", "layout: bad ratio1"),
		# Trailing tokens were dropped without a word.
		("layout hsplit 60 40 20\n", "layout needs: hsplit|vsplit ratio1 ratio2"),
		("layout hsplit 1 1\nleft vsplit 1 1 1\n", "left: split needs: hsplit|vsplit ratio1 ratio2"),
		# A region assigned with no layout was ignored.
		("left cpu-gauge /m\nservice s /m\n", "left: region assignment needs a layout"),
		# A region assigned twice kept the first, silently.
		("layout hsplit 1 1\nleft a /m\nleft b /m\n", "left: region assigned twice"),
		# One name is one modules/<name> and one /tmp/matrix/<name>.
		("service s /a\nservice s /b\n", "service s: declared twice"),
		# Dot names hide (the picker skips them) and .ns is the
		# runtime's own shadow directory.
		("service .ns /m\n", "service: unsafe module name"),
		("layout hsplit 1 1\nleft .hidden /m\n", "left: unsafe module name"),
	};
	for(i := 0; i < len cases; i++) {
		(text, want) := cases[i];
		(c, err) := matrixlib->parsecomposition(text);
		t.assertseq(err, want, sys->sprint("refused: %q", text));
		t.assert(c == nil, "no composition with the error");
	}

	# Still accepted: a zero weight (the picker's "vsplit 100 0"), a
	# dot inside a name, and lines ending CR LF.
	(nil, err) := matrixlib->parsecomposition("layout vsplit 100 0\ntop comp-list /lib/matrix/compositions\n");
	t.assertnil(err, "a zero weight");
	(nil, err) = matrixlib->parsecomposition("service s.v2 /m\n");
	t.assertnil(err, "a dot inside a name");
	(c, cerr) := matrixlib->parsecomposition("# crlf\r\nlayout hsplit 1 1\r\nleft a /m/a\r\nservice s /m\r\n");
	t.assertnil(cerr, "CR LF line ends");
	if(c != nil)
		t.assertseq(servicebyname(c, "s").mount, "/m", "CR not part of the mount");
}

testUnrecognizedLine(t: ref T)
{
	(nil, err) := matrixlib->parsecomposition("gibberish\n");
	t.assertseq(err, "unrecognized line: gibberish", "junk line rejected");
}

testCommentsAndBlanks(t: ref T)
{
	text := "# name here\n\n   \n# another comment\nservice s /m\n";
	(c, err) := matrixlib->parsecomposition(text);
	t.assertnil(err, "comments and blanks skipped");
	if(c == nil)
		t.fatal("nil composition");
	t.assertseq(c.name, "name here", "first comment wins");
	t.asserteq(nservices(c), 1, "service parsed after comments");
}

testTextRoundTrip(t: ref T)
{
	text := "# rt\nlayout hsplit 2 1\nleft a /m/a\n";
	(c, err) := matrixlib->parsecomposition(text);
	t.assertnil(err, "parses");
	if(c == nil)
		t.fatal("nil composition");
	t.assertseq(c.text, text, "original text preserved verbatim");
}

# ── Watch-rule grammar ──────────────────────────────────────

nwatches(c: ref Composition): int
{
	n := 0;
	for(wl := c.watches; wl != nil; wl = tl wl)
		n++;
	return n;
}

testWatchGrammar(t: ref T)
{
	# The architecture doc's example, verbatim shape.
	text := "watch /n/tbl4/portfolio/defense/status\n" +
		"  crisis -> load defensive\n" +
		"  normal -> load trading-desk\n";
	(c, err) := matrixlib->parsecomposition(text);
	t.assertnil(err, "doc example parses");
	if(c == nil)
		t.fatal("nil composition");
	t.asserteq(nwatches(c), 1, "one rule");
	w := hd c.watches;
	t.assertseq(w.path, "/n/tbl4/portfolio/defense/status", "watched path");
	(p1, a1) := hd w.arms;
	(p2, a2) := hd tl w.arms;
	t.assertseq(p1, "crisis", "first pattern");
	t.assertseq(a1, "load defensive", "first action");
	t.assertseq(p2, "normal", "second pattern");
	t.assertseq(a2, "load trading-desk", "second action");
}

testWatchTerminator(t: ref T)
{
	# First non-arm line closes the block and parses normally;
	# comments and blanks inside the block do not close it.
	text := "watch /m/status\n" +
		"# a comment inside the block\n" +
		"up -> notify it is up\n" +
		"\n" +
		"down -> unload\n" +
		"service s /m\n" +
		"watch /m/other\n" +
		"x -> pin snap\n";
	(c, err) := matrixlib->parsecomposition(text);
	t.assertnil(err, "mixed watch/service parses");
	if(c == nil)
		t.fatal("nil composition");
	t.asserteq(nwatches(c), 2, "two rules in file order");
	t.assertseq((hd c.watches).path, "/m/status", "first rule first");
	t.asserteq(nservices(c), 1, "service after block parsed");
	(nil, a) := hd (hd c.watches).arms;
	t.assertseq(a, "notify it is up", "notify text preserved");
}

testWatchErrors(t: ref T)
{
	(nil, e1) := matrixlib->parsecomposition("watch\n");
	t.assertseq(e1, "watch needs: path", "missing path rejected");
	(nil, e2) := matrixlib->parsecomposition("watch /m/s\nservice s /m\n");
	t.assertseq(e2, "watch /m/s: empty block", "empty block via terminator rejected");
	(nil, e3) := matrixlib->parsecomposition("watch /m/s\n");
	t.assertseq(e3, "watch /m/s: empty block", "empty block via EOF rejected");
	(nil, e4) := matrixlib->parsecomposition("watch /m/s\nx -> reboot now\n");
	t.assertseq(e4, "watch /m/s: unknown watch action: reboot", "unknown verb rejected");
	(nil, e5) := matrixlib->parsecomposition("watch /m/s\nx -> load\n");
	t.assertseq(e5, "watch /m/s: load needs exactly one composition name", "load arity checked");
	(nil, e6) := matrixlib->parsecomposition("watch /m/s\nx -> unload now\n");
	t.assertseq(e6, "watch /m/s: unload takes no arguments", "unload arity checked");
	(nil, e7) := matrixlib->parsecomposition("watch /m/s\n-> load x\n");
	t.assertseq(e7, "watch /m/s: empty pattern", "empty pattern rejected");
	(nil, e8) := matrixlib->parsecomposition("watch /m/s\nx -> notify\n");
	t.assertseq(e8, "watch /m/s: notify needs a message", "notify needs text");
}

# ── Transplant units ────────────────────────────────────────
#
# transplant moves live module handles old→new for unchanged
# entries.  Real instances are fabricated by loading shipped
# modules; identity is asserted through the nil'd-in-old contract.

# App leaves: "region app <dis-path> [args...]" reserves the module
# name "app"; the path lands in mount and the tail in appargs.
testAppLeafGrammar(t: ref T)
{
	(c, err) := matrixlib->parsecomposition(
		"layout hsplit 1 1\nleft app /dis/wm/clock.dis -f fmt\nright cpu-gauge /m\n");
	t.assertnil(err, "app leaf parses");
	if(c == nil)
		t.fatal("nil composition");
	l := leafbyname(c.layout, "left");
	if(l == nil)
		t.fatal("left leaf missing");
	t.assertseq(l.modname, "app", "app kind recorded");
	t.assertseq(l.mount, "/dis/wm/clock.dis", "dis path in mount");
	t.assertseq(l.appargs, "-f fmt", "arguments captured");
	r := leafbyname(c.layout, "right");
	t.assertseq(r.appargs, "", "non-app leaf has no args");

	(c2, e2) := matrixlib->parsecomposition(readfile("/lib/matrix/compositions/app-demo"));
	t.assertnil(e2, "shipped app-demo parses");
	if(c2 == nil)
		t.fatal("nil composition");
	rr := leafbyname(c2.layout, "right/right");
	if(rr == nil)
		t.fatal("right/right missing");
	t.assertseq(rr.modname, "app", "app-demo hosts an app leaf");
}

# The Dis VM's load typecheck is the discriminator between the two
# display kinds: a Tk-hosted module must load as MatrixTkDisplay and
# refuse to load as MatrixDisplay, and vice versa.
testTkDisplayTypecheck(t: ref T)
{
	tkm := load MatrixTkDisplay "/dis/matrix/tk-notes.dis";
	t.assert(tkm != nil, "tk-notes loads as MatrixTkDisplay");
	dm := load MatrixDisplay "/dis/matrix/tk-notes.dis";
	t.assert(dm == nil, "tk-notes refuses MatrixDisplay");
	dm2 := load MatrixTkDisplay "/dis/matrix/cpu-gauge.dis";
	t.assert(dm2 == nil, "cpu-gauge refuses MatrixTkDisplay");

	(c, err) := matrixlib->parsecomposition(readfile("/lib/matrix/compositions/tk-demo"));
	t.assertnil(err, "tk-demo composition parses");
	if(c == nil)
		t.fatal("nil composition");
	rleaf := leafbyname(c.layout, "right");
	if(rleaf == nil)
		t.fatal("right leaf missing");
	t.assertseq(rleaf.modname, "tk-notes", "tk-notes assigned");
}

testTransplant(t: ref T)
{
	oldtext := "layout hsplit 1 1\nleft cpu-gauge /m/a\nright mem-gauge /m/b\n" +
		"service sysmon-svc /\nservice llm-recorder /mnt/llm\n";
	newtext := "layout hsplit 2 1\nleft cpu-gauge /m/a\nright mem-gauge /m/CHANGED\n" +
		"service sysmon-svc /\n";
	(old, e1) := matrixlib->parsecomposition(oldtext);
	(new, e2) := matrixlib->parsecomposition(newtext);
	t.assertnil(e1, "old parses");
	t.assertnil(e2, "new parses");

	dm := load MatrixDisplay "/dis/matrix/cpu-gauge.dis";
	dm2 := load MatrixDisplay "/dis/matrix/mem-gauge.dis";
	sm := load MatrixService "/dis/matrix/sysmon-svc.dis";
	sm2 := load MatrixService "/dis/matrix/llm-recorder.dis";
	if(dm == nil || dm2 == nil || sm == nil || sm2 == nil)
		t.fatal(sys->sprint("cannot load matrix modules: %r"));

	oldleft := leafbyname(old.layout, "left");
	oldright := leafbyname(old.layout, "right");
	oldleft.mod = dm;
	oldright.mod = dm2;
	os1 := servicebyname(old, "sysmon-svc");
	os2 := servicebyname(old, "llm-recorder");
	os1.mod = sm;
	os1.outdir = "/tmp/matrix/sysmon-svc";
	os1.pid = 42;
	os2.mod = sm2;

	matrixlib->transplant(old, new);

	# Unchanged leaf: handle moved.
	t.assert(leafbyname(new.layout, "left").mod != nil, "kept leaf adopted the instance");
	t.assert(oldleft.mod == nil, "kept leaf nil'd in old");
	# Changed mount: handle stays in old for shutdown.
	t.assert(leafbyname(new.layout, "right").mod == nil, "changed-mount leaf not adopted");
	t.assert(oldright.mod != nil, "changed-mount instance left in old");
	# Unchanged service: handle + runtime state moved.
	ns1 := servicebyname(new, "sysmon-svc");
	t.assert(ns1.mod != nil, "kept service adopted");
	t.assertseq(ns1.outdir, "/tmp/matrix/sysmon-svc", "outdir carried");
	t.asserteq(ns1.pid, 42, "pid carried");
	t.assert(os1.mod == nil, "kept service nil'd in old");
	# Dropped service: left in old.
	t.assert(os2.mod != nil, "dropped service left in old for shutdown");
}

# ── Service namespace isolation ─────────────────────────────

mkfixdir(path: string)
{
	for(i := 1; i <= len path; i++) {
		if(i < len path && path[i] != '/')
			continue;
		p := path[0:i];
		(ok, nil) := sys->stat(p);
		if(ok < 0)
			sys->create(p, Sys->OREAD, Sys->DMDIR | 8r755);
	}
}

createstr(path, s: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return -1;
	b := array of byte s;
	return sys->write(fd, b, len b);
}

FIXMOUNT: con "/tmp/mtest/tbl4";

mkfixture()
{
	mkfixdir(FIXMOUNT + "/portfolio/defense");
	createstr(FIXMOUNT + "/signals", "1 BTC long 0.95 breakout 1234\n");
	createstr(FIXMOUNT + "/portfolio/defense/status", "normal\n");
	createstr(FIXMOUNT + "/risk", "var 0.02\n");
}

# Replicates runservice's confinement sequence, then reports every
# violation it can find as a token; an empty report is a pass.
probe(mount, outdir: string, resc: chan of string)
{
	sys->pctl(Sys->NEWPGRP, nil);
	sys->pctl(Sys->FORKNS, nil);
	err := matrixlib->restrictsvcns(mount, outdir);
	if(err != nil) {
		resc <-= "restrict-failed: " + err;
		return;
	}
	sys->pctl(Sys->NODEVS, nil);

	r := "";
	(ok, nil) := sys->stat("/dis");
	if(ok >= 0)
		r += "dis-visible;";
	(ok, nil) = sys->stat("/lib");
	if(ok >= 0)
		r += "lib-visible;";
	(ok, nil) = sys->stat("/usr");
	if(ok >= 0)
		r += "usr-visible;";
	(ok, nil) = sys->stat("/mnt/matrix");
	if(ok >= 0)
		r += "controlfs-visible;";
	fd := sys->open(mount + "/signals", Sys->OREAD);
	if(fd == nil)
		r += "mount-unreadable;";
	# The mount is a read-only grant all the way down: no file in it
	# opened for writing, nothing made in a directory below it (an
	# unflagged bind refuses a create only at the bind point itself),
	# nothing removed.
	wfd := sys->open(mount + "/signals", Sys->OWRITE);
	if(wfd != nil)
		r += "mount-writable;";
	sfd := sys->create(mount + "/portfolio/probe-file", Sys->OWRITE, 8r644);
	if(sfd != nil)
		r += "mount-subdir-create;";
	if(sys->remove(mount + "/risk") >= 0)
		r += "mount-remove;";
	cfd := sys->create(outdir + "/probe-file", Sys->OWRITE, 8r644);
	if(cfd == nil)
		r += "outdir-unwritable;";
	efd := sys->create("/tmp/escape-probe", Sys->OWRITE, 8r644);
	if(efd != nil)
		r += "escape-write;";
	dfd := sys->open("#U*/", Sys->OREAD);
	if(dfd != nil)
		r += "devattach-open;";
	resc <-= r;
}

probenested(mount, outdir: string, resc: chan of string)
{
	sys->pctl(Sys->NEWPGRP, nil);
	sys->pctl(Sys->FORKNS, nil);
	mkfixdir(outdir);
	err := matrixlib->restrictsvcns(mount, outdir);
	if(err != nil) {
		resc <-= "restrict-failed: " + err;
		return;
	}
	sys->pctl(Sys->NODEVS, nil);
	r := "";
	if(sys->create(outdir + "/probe-file", Sys->OWRITE, 8r644) == nil)
		r += "outdir-unwritable;";
	if(sys->open(mount + "/tbl4/signals", Sys->OWRITE) != nil)
		r += "mount-writable;";
	if(sys->create(mount + "/tbl4/probe-file", Sys->OWRITE, 8r644) != nil)
		r += "mount-create;";
	resc <-= r;
}

testIsolation(t: ref T)
{
	mkfixture();
	mkfixdir("/tmp/matrix/mtest-probe");
	resc := chan of string;
	spawn probe(FIXMOUNT, "/tmp/matrix/mtest-probe", resc);
	r := <-resc;
	t.assertseq(r, "", "restricted proc sees only its grant");
	# The restriction was private to the probe's forked namespace.
	(ok, nil) := sys->stat("/dis");
	t.assert(ok >= 0, "parent namespace unaffected");

	# An outdir inside the read-only mount is still writable: it is
	# a mount point of its own below the read-only one.
	resn := chan of string;
	spawn probenested("/tmp/mtest", "/tmp/mtest/tbl4/out", resn);
	rn := <-resn;
	t.assertseq(rn, "", "outdir nested in a read-only mount");

	# A grant that cannot be bound must fail closed.
	resc2 := chan of string;
	spawn probe("/mtest-no-such-mount", "/tmp/matrix/mtest-probe", resc2);
	r2 := <-resc2;
	t.assert(hasprefix(r2, "restrict-failed"), "missing mount fails closed: " + r2);
}

# ── Control filesystem surface (/mnt/matrix) ────────────────
#
# Spawns the real runtime headless with the shipped sysmon
# composition and exercises the served tree end to end: status,
# composition round-trip, per-module files, the out/ passthrough
# into the service's output directory, the library/ passthrough
# (text and binary), notifications, and ctl verbs.

testControlFSStart(t: ref T)
{
	# Launch through sh rather than a typed load: this file takes
	# ref fn of its test functions, and a local command-module type
	# structurally identical to MatrixTest makes the load-site
	# import table swallow them (see wm_apps_test.b's "no ref fn"
	# workaround for the same trap).  sh's & shares the namespace,
	# so the /mnt/matrix mount is visible here.
	sh = load Sh Sh->PATH;
	if(sh == nil)
		t.fatal(sys->sprint("cannot load sh: %r"));
	sh->system(nil, "/dis/wm/matrix.dis -h /lib/matrix/compositions/sysmon &");
	# Poll on content, not existence: a stale real file under a
	# mnt/matrix directory (host-tree pollution from an unmounted
	# namespace) would satisfy a bare stat before the mount lands.
	up := 0;
	for(w := 0; w < 5000 && !up; w += 250) {
		if(trim(readfile("/mnt/matrix/ctl")) == "running")
			up = 1;
		else
			sys->sleep(250);
	}
	if(!up)
		t.fatal("/mnt/matrix/ctl never reported running");
	matrixpid = pidofmodule("Matrix");
	t.assert(matrixpid > 0, "matrix pid found in /prog");
}

testControlFSComposition(t: ref T)
{
	want := readfile("/lib/matrix/compositions/sysmon");
	got := readfile("/mnt/matrix/composition");
	t.assertseq(got, want, "composition round-trips verbatim");
}

testControlFSModules(t: ref T)
{
	names := lsnames("/mnt/matrix/modules");
	t.assert(hasname(names, "cpu-gauge"), "cpu-gauge listed");
	t.assert(hasname(names, "mem-gauge"), "mem-gauge listed");
	t.assert(hasname(names, "proc-list"), "proc-list listed");
	t.assert(hasname(names, "sysmon-svc"), "sysmon-svc listed");

	t.assertseq(trim(readfile("/mnt/matrix/modules/sysmon-svc/type")), "service", "service type");
	t.assertseq(trim(readfile("/mnt/matrix/modules/sysmon-svc/mount")), "/", "service mount");
	t.assertseq(trim(readfile("/mnt/matrix/modules/sysmon-svc/ctl")), "running", "service status");
	t.assertseq(trim(readfile("/mnt/matrix/modules/cpu-gauge/type")), "display", "display type");
	# Headless: display modules are never loaded, so they read stopped.
	t.assertseq(trim(readfile("/mnt/matrix/modules/cpu-gauge/ctl")), "stopped", "display stopped headless");
}

testControlFSOutPassthrough(t: ref T)
{
	# Give sysmon-svc time for at least one poll cycle.
	if(!waitfor("/mnt/matrix/modules/sysmon-svc/out/cpu/current", 5000))
		t.fatal("service output never appeared through the control fs");
	cur := trim(readfile("/mnt/matrix/modules/sysmon-svc/out/cpu/current"));
	t.assert(cur != "", "out/cpu/current non-empty through control fs");
	(nil, toks) := sys->tokenize(cur, " ");
	n := 0;
	for(; toks != nil; toks = tl toks)
		n++;
	t.asserteq(n, 3, "cpu/current is 'pct busy total'");

	# Nested passthrough dirs enumerate.
	names := lsnames("/mnt/matrix/modules/sysmon-svc/out");
	t.assert(hasname(names, "cpu"), "out/ lists cpu/");
	t.assert(hasname(names, "mem"), "out/ lists mem/");

	# Display modules have no out/.
	(ok, nil) := sys->stat("/mnt/matrix/modules/cpu-gauge/out");
	t.assert(ok < 0, "display module has no out/");

	# Writes through the passthrough are refused.
	t.assert(writestr("/mnt/matrix/modules/sysmon-svc/out/cpu/current", "x") < 0,
		"passthrough is read-only");
}

testControlFSLibrary(t: ref T)
{
	names := lsnames("/mnt/matrix/library/compositions");
	t.assert(hasname(names, "sysmon"), "library lists sysmon");
	t.assert(hasname(names, "perf-dashboard"), "library lists perf-dashboard");

	want := readfile("/lib/matrix/compositions/sysmon");
	got := readfile("/mnt/matrix/library/compositions/sysmon");
	t.assertseq(got, want, "library composition passthrough matches");

	# Binary passthrough: .dis bytes survive untouched.
	wantb := readbytesfile("/dis/matrix/cpu-gauge.dis");
	gotb := readbytesfile("/mnt/matrix/library/modules/cpu-gauge.dis");
	t.assert(wantb != nil && len wantb > 0, "real .dis readable");
	t.asserteq(len gotb, len wantb, ".dis length matches through passthrough");
	same := 1;
	for(i := 0; i < len wantb && i < len gotb; i++)
		if(wantb[i] != gotb[i]) {
			same = 0;
			break;
		}
	t.assert(same, ".dis bytes identical through passthrough");
}

# substring search for index-entry checks.
contains(s, sub: string): int
{
	if(len sub == 0)
		return 1;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

testControlFSIndex(t: ref T)
{
	# The library dir lists the discovery surface.
	names := lsnames("/mnt/matrix/library");
	t.assert(hasname(names, "man"), "library lists man/");
	t.assert(hasname(names, "index"), "library lists index");

	want := readfile("/lib/matrix/index");
	t.assert(want != "", "real index non-empty");
	got := readfile("/mnt/matrix/library/index");
	t.assertseq(got, want, "index passthrough matches");

	# whatis shape: every line is "name (display|service|tk-display) - synopsis".
	(nil, lines) := sys->tokenize(got, "\n");
	for(; lines != nil; lines = tl lines) {
		l := hd lines;
		ok := contains(l, " (display) - ") || contains(l, " (service) - ") ||
			contains(l, " (tk-display) - ");
		t.assert(ok, "index line is whatis-shaped: " + l);
	}

	t.assert(writestr("/mnt/matrix/library/index", "x") < 0, "index read-only");

	# Never-stale: the served index is synthesised from the man
	# pages on read.  A new man page appears in it immediately —
	# no regeneration step — and vanishes when the page goes.
	tmpman := "/lib/matrix/man/zz-mtest-probe";
	t.assert(createstr(tmpman,
		"NAME\n\tzz-mtest-probe (service) - synthetic index probe\n") > 0,
		"probe man page created");
	fresh := readfile("/mnt/matrix/library/index");
	sys->remove(tmpman);
	t.assert(contains(fresh, "zz-mtest-probe (service) - synthetic index probe"),
		"new man page appears in served index without regeneration");
	after := readfile("/mnt/matrix/library/index");
	t.assert(!contains(after, "zz-mtest-probe"),
		"removed man page leaves the served index");
}

testControlFSMan(t: ref T)
{
	names := lsnames("/mnt/matrix/library/man");
	t.assert(hasname(names, "cpu-gauge"), "man lists cpu-gauge");
	t.assert(hasname(names, "sysmon-svc"), "man lists sysmon-svc");

	want := readfile("/lib/matrix/man/cpu-gauge");
	got := readfile("/mnt/matrix/library/man/cpu-gauge");
	t.assert(want != "", "real man page non-empty");
	t.assertseq(got, want, "man page passthrough matches");

	t.assert(writestr("/mnt/matrix/library/man/cpu-gauge", "x") < 0, "man read-only");

	# Completeness: every shipped module has a man page and an
	# index entry — a module without documentation cannot land.
	idx := readfile("/mnt/matrix/library/index");
	mods := lsnames("/mnt/matrix/library/modules");
	for(; mods != nil; mods = tl mods) {
		m := hd mods;
		if(len m < 5 || m[len m - 4:] != ".dis")
			continue;
		name := m[0:len m - 4];
		(ok, nil) := sys->stat("/mnt/matrix/library/man/" + name);
		t.assert(ok >= 0, "module has a man page: " + name);
		t.assert(contains(idx, name + " ("), "module has an index entry: " + name);
	}
}

# The Veltro matrix tool is a thin wrapper over this same control
# fs; drive it against the live runtime to prove the agent-facing
# path end to end: scan the index, read a contract, inspect status,
# consume service output.
VTool: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
};

testControlFSVeltroTool(t: ref T)
{
	tool := load VTool "/dis/veltro/tools/matrix.dis";
	if(tool == nil)
		t.fatal(sys->sprint("cannot load matrix tool: %r"));
	err := tool->init();
	t.assert(err == nil, "tool init: " + err);
	t.assertseq(tool->name(), "matrix", "tool name");

	idx := tool->exec("index");
	t.assert(contains(idx, "cpu-gauge (display) - "), "index served through tool");

	man := tool->exec("man sysmon-svc");
	t.assert(contains(man, "WRITES"), "man page has WRITES section");
	t.assert(contains(man, "cpu/current"), "man page carries the contract");

	st := tool->exec("status");
	t.assert(contains(st, "runtime: running"), "status reports running: " + st);
	t.assert(contains(st, "sysmon-svc"), "status lists the service");

	lib := tool->exec("library");
	t.assert(contains(lib, "sysmon"), "library lists sysmon");

	story := tool->exec("story sysmon");
	t.assertseq(story, readfile("/lib/matrix/compositions/sysmon"), "story round-trips");

	outls := tool->exec("out sysmon-svc");
	t.assert(contains(outls, "cpu"), "out lists cpu/: " + outls);
	cur := tool->exec("out sysmon-svc cpu/current");
	t.assert(!hasprefix(cur, "error:") && cur != "", "out reads a service file");

	bad := tool->exec("man no-such-module");
	t.assert(hasprefix(bad, "error:"), "missing man page errors cleanly");
}

testControlFSNotifications(t: ref T)
{
	(ok, nil) := sys->stat("/mnt/matrix/notifications");
	t.assert(ok >= 0, "notifications file exists");
	t.assertseq(readfile("/mnt/matrix/notifications"), "", "notifications empty at start");
}

countlines(s: string): int
{
	n := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			n++;
	return n;
}

# Incremental reload: writing a new composition keeps unchanged
# modules running (qid identity + service state continuity) and
# drops removed ones.
testControlFSReload(t: ref T)
{
	histpath := "/mnt/matrix/modules/sysmon-svc/out/cpu/history";
	h1 := 0;
	for(w := 0; w < 8000 && h1 < 3; w += 500) {
		h1 = countlines(readfile(histpath));
		if(h1 < 3)
			sys->sleep(500);
	}
	t.assert(h1 >= 3, "service history warmed up");
	(ok1, d1) := sys->stat("/mnt/matrix/modules/sysmon-svc");
	t.assert(ok1 >= 0, "sysmon-svc stats before reload");

	# Same service, same cpu-gauge/proc-list leaves; mem-gauge
	# dropped; ratios changed.
	newtext := "# sysmon-lite\n" +
		"layout hsplit 60 40\n" +
		"left vsplit 50 50\n" +
		"left/top cpu-gauge /tmp/matrix/sysmon\n" +
		"right proc-list /tmp/matrix/sysmon\n" +
		"service sysmon-svc /\n";
	t.assert(writestr("/mnt/matrix/composition", newtext) > 0, "composition write accepted");
	applied := 0;
	for(w = 0; w < 3000 && !applied; w += 250) {
		if(readfile("/mnt/matrix/composition") == newtext)
			applied = 1;
		else
			sys->sleep(250);
	}
	t.assert(applied, "reload applied");

	# Dropped module gone from the tree.
	(gone, nil) := sys->stat("/mnt/matrix/modules/mem-gauge");
	t.assert(gone < 0, "dropped module unwalkable after reload");

	# Kept module: same qid, still running.
	(ok2, d2) := sys->stat("/mnt/matrix/modules/sysmon-svc");
	t.assert(ok2 >= 0, "sysmon-svc stats after reload");
	t.assert(d1.qid.path == d2.qid.path, "kept module qid stable across reload");
	t.assertseq(trim(readfile("/mnt/matrix/modules/sysmon-svc/ctl")), "running", "kept service still running");

	# Continuity: a restarted service would have reset its history
	# ring to a couple of entries; a kept one only grows.
	sys->sleep(1200);
	h2 := countlines(readfile(histpath));
	t.assert(h2 >= h1, sys->sprint("history continuity (%d -> %d)", h1, h2));

	# Restore the shipped composition for the tests that follow.
	t.assert(writestr("/mnt/matrix/ctl", "load sysmon") > 0, "restore accepted");
	t.assert(waitfor("/mnt/matrix/modules/mem-gauge", 3000), "shipped composition restored");
}

# End-to-end proof that a confined service works against its
# grant: alert-watcher runs against the fixture mount inside the
# restricted namespace and its alert lands in out/ through the
# control fs.
testControlFSAlertE2E(t: ref T)
{
	mkfixture();
	# Stale alerts from earlier runs of this suite would satisfy
	# the poll below; clear them.
	for(al := lsnames("/tmp/matrix/alert-watcher"); al != nil; al = tl al)
		sys->remove("/tmp/matrix/alert-watcher/" + hd al);

	newtext := "# alert-e2e\nservice alert-watcher " + FIXMOUNT + "\n";
	t.assert(writestr("/mnt/matrix/composition", newtext) > 0, "composition write accepted");
	alertpath := "/mnt/matrix/modules/alert-watcher/out/alert-0000";
	if(!waitfor(alertpath, 8000))
		t.fatal("confined alert-watcher never produced an alert");
	msg := readfile(alertpath);
	t.assert(hasprefix(msg, "high-confidence signal: BTC"), "alert content correct: " + msg);
	t.assertseq(readfile("/tmp/matrix/alert-watcher/alert-0000"), msg,
		"control-fs view matches the real outdir");
	t.assertseq(trim(readfile("/mnt/matrix/modules/alert-watcher/ctl")), "running",
		"confined service reports running");

	# A signal is alerted once, not at every poll (5 s): the outdir
	# is read-only to its readers, so repeats only piled up.  A new
	# signal is alerted, its confidence read as a number (".9" is
	# below "0.7" as a string).
	sys->sleep(6000);
	(dup, nil) := sys->stat("/tmp/matrix/alert-watcher/alert-0001");
	t.assert(dup < 0, "a signal still in the file is not alerted again");
	createstr(FIXMOUNT + "/signals", "1 BTC long 0.95 breakout 1234\n" +
		"2 ETH short .9 reversal 1240\n" +
		"3 SOL long 0.5 drift 1241\n");
	if(!waitfor("/tmp/matrix/alert-watcher/alert-0001", 8000))
		t.fatal("a new qualifying signal was not alerted");
	t.assert(hasprefix(readfile("/tmp/matrix/alert-watcher/alert-0001"), "high-confidence signal: ETH"),
		"the new signal's alert");
	sys->sleep(500);
	(more, nil) := sys->stat("/tmp/matrix/alert-watcher/alert-0002");
	t.assert(more < 0, "no alert for a signal under the threshold, none repeated");

	# Restore the shipped composition for the tests that follow.
	t.assert(writestr("/mnt/matrix/ctl", "load sysmon") > 0, "restore accepted");
	t.assert(waitfor("/mnt/matrix/modules/mem-gauge", 3000), "shipped composition restored");
}

# INFR-12 acceptance: a watch rule loads a pinned composition when
# the watched value transitions to a matching pattern, never on the
# first observation; notify lands in /mnt/matrix/notifications.
testControlFSWatch(t: ref T)
{
	mkfixture();
	statuspath := FIXMOUNT + "/portfolio/defense/status";
	createstr(statuspath, "normal\n");

	# The defensive composition watches for recovery and notifies.
	defensivetext := "# mtest-defensive\n" +
		"watch " + statuspath + "\n" +
		"normal -> notify defense back to normal\n" +
		"service alert-watcher " + FIXMOUNT + "\n";
	createstr("/lib/matrix/compositions/mtest-defensive", defensivetext);

	watchtext := "# watch-e2e\n" +
		"watch " + statuspath + "\n" +
		"crisis -> load mtest-defensive\n" +
		"service alert-watcher " + FIXMOUNT + "\n";
	t.assert(writestr("/mnt/matrix/composition", watchtext) > 0, "composition write accepted");
	applied := 0;
	for(w := 0; w < 3000 && !applied; w += 250) {
		if(readfile("/mnt/matrix/composition") == watchtext)
			applied = 1;
		else
			sys->sleep(250);
	}
	t.assert(applied, "watch composition loaded");

	# The current value already reads "normal"; two-plus watch
	# cycles must pass without anything firing.
	sys->sleep(2500);
	t.assertseq(readfile("/mnt/matrix/composition"), watchtext, "no fire on first observation");

	# Transition to crisis: the defensive composition must load.
	createstr(statuspath, "crisis\n");
	loaded := 0;
	for(w = 0; w < 10000 && !loaded; w += 500) {
		if(readfile("/mnt/matrix/composition") == defensivetext)
			loaded = 1;
		else
			sys->sleep(500);
	}
	t.assert(loaded, "crisis transition loaded the defensive composition");

	# Recovery: the defensive composition's watcher baselined on
	# "crisis", so flipping back is a transition and must notify.
	sys->sleep(1500);	# let the fresh watcher take its baseline
	createstr(statuspath, "normal\n");
	notified := 0;
	for(w = 0; w < 8000 && !notified; w += 500) {
		notifs := readfile("/mnt/matrix/notifications");
		for(i := 0; i + 22 < len notifs; i++)
			if(notifs[i:i+22] == "defense back to normal") {
				notified = 1;
				break;
			}
		if(!notified)
			sys->sleep(500);
	}
	t.assert(notified, "recovery transition notified");

	# Cleanup: unpin the fixture composition, restore sysmon.
	writestr("/mnt/matrix/ctl", "unpin mtest-defensive");
	t.assert(writestr("/mnt/matrix/ctl", "load sysmon") > 0, "restore accepted");
	t.assert(waitfor("/mnt/matrix/modules/mem-gauge", 3000), "shipped composition restored");
}

# A composition written to /mnt/matrix/composition is parsed by the
# runtime as it is written: one that does not parse is the writer's
# error, with the parser's diagnostic, and the live one stays; one
# longer than a 9P message arrives whole.
testControlFSCompositionWrite(t: ref T)
{
	live := readfile("/mnt/matrix/composition");

	bad := "# mtest-bad\nlayout hsplit 50 50\nleft cpu-gauge\n";
	t.assert(writestr("/mnt/matrix/composition", bad) < 0, "unparseable composition refused");
	e := sys->sprint("%r");
	t.assert(contains(e, "left cpu-gauge"), "refusal carries the diagnostic: " + e);
	sys->sleep(500);
	t.assertseq(readfile("/mnt/matrix/composition"), live, "live composition kept");

	# A pinned composition that does not parse is refused at load.
	createstr("/lib/matrix/compositions/mtest-broken", bad);
	t.assert(writestr("/mnt/matrix/ctl", "load mtest-broken") < 0, "broken pinned composition refused");
	e = sys->sprint("%r");
	t.assert(contains(e, "mtest-broken"), "load refusal names the composition: " + e);
	sys->remove("/lib/matrix/compositions/mtest-broken");

	# Longer than one message: padded with comments well past the
	# iounit, the real lines at the end.  Split into Twrites, each
	# fragment alone would be a different composition (or none).
	long := "# mtest-long\n";
	pad := "# ";
	for(i := 0; i < 70; i++)
		pad += "x";
	for(i = 0; i < 400; i++)
		long += pad + "\n";
	long += "layout hsplit 60 40\n" +
		"left cpu-gauge /tmp/matrix/sysmon-svc\n" +
		"right proc-list /tmp/matrix/sysmon-svc\n" +
		"service sysmon-svc /\n";
	t.assert(len array of byte long > 3*8192, "long composition spans messages");
	t.asserteq(writestr("/mnt/matrix/composition", long), len array of byte long,
		"long composition written");
	applied := 0;
	for(w := 0; w < 3000 && !applied; w += 250) {
		if(readfile("/mnt/matrix/composition") == long)
			applied = 1;
		else
			sys->sleep(250);
	}
	t.assert(applied, "long composition applied whole");
	(gone, nil) := sys->stat("/mnt/matrix/modules/mem-gauge");
	t.assert(gone < 0, "long composition's last lines took effect");

	# The agent's tool reports the runtime's refusal, and success
	# only once the composition is live.
	tool := load VTool "/dis/veltro/tools/matrix.dis";
	if(tool == nil)
		t.fatal(sys->sprint("cannot load matrix tool: %r"));
	tool->init();
	r := tool->exec("compose layout hsplit 50 50; left cpu-gauge");
	t.assert(hasprefix(r, "error:"), "tool reports a refused composition: " + r);
	r = tool->exec("compose layout hsplit 50 50; left cpu-gauge /tmp/matrix/sysmon-svc; " +
		"right proc-list /tmp/matrix/sysmon-svc; service sysmon-svc /tmp");
	t.assert(hasprefix(r, "composition applied"), "tool reports an applied composition: " + r);

	t.assert(writestr("/mnt/matrix/ctl", "load sysmon") > 0, "restore accepted");
	t.assert(waitfor("/mnt/matrix/modules/mem-gauge", 3000), "shipped composition restored");
}

# A service's ctl says how it is: running while its run() is, exited
# once run() returns, failed (with why) when run() raises or init
# refuses; and a service shut down whose run() will not return is
# killed, with what it started, after a grace.
SVCFIX: con "/dis/matrix/mtest-svc.dis";
SVCMOUNT: con "/tmp/mtest/svc";

# Each mode its own mount: an entry with the same name and mount is
# unchanged, and a reload keeps its instance.
svcmode(mode: string): string
{
	mnt := SVCMOUNT + "/" + mode;
	mkfixdir(mnt);
	createstr(mnt + "/mode", mode + "\n");
	text := "# mtest-svc " + mode + "\nservice mtest-svc " + mnt + "\n";
	if(writestr("/mnt/matrix/composition", text) < 0)
		return sys->sprint("composition refused: %r");
	for(w := 0; w < 3000; w += 100) {
		if(readfile("/mnt/matrix/composition") == text)
			return nil;
		sys->sleep(100);
	}
	return "composition not applied";
}

# Poll the service's ctl until it starts with want, up to ms.
svcctl(want: string, ms: int): string
{
	st := "";
	for(w := 0; w < ms; w += 100) {
		st = trim(readfile("/mnt/matrix/modules/mtest-svc/ctl"));
		if(hasprefix(st, want))
			break;
		sys->sleep(100);
	}
	return st;
}

alive(pid: string): int
{
	(ok, nil) := sys->stat("/prog/" + pid);
	return ok >= 0;
}

testControlFSServiceLifecycle(t: ref T)
{
	b := readfile("/dis/tests/matrix_svcfixture.dis");
	if(b == "")
		t.fatal("no /dis/tests/matrix_svcfixture.dis");
	if(copyfile("/dis/tests/matrix_svcfixture.dis", SVCFIX) < 0)
		t.fatal(sys->sprint("cannot install %s: %r", SVCFIX));

	t.assertnil(svcmode("ok"), "ok composition");
	t.assertseq(svcctl("running", 2000), "running", "a running service");

	t.assertnil(svcmode("exit"), "exit composition");
	t.assertseq(svcctl("exited", 2000), "exited", "run() returned: exited");
	# A reload restarts a service that ended, though its entry is
	# unchanged.
	createstr(SVCMOUNT + "/exit/mode", "ok\n");
	t.assert(writestr("/mnt/matrix/ctl", "load -") > 0, "load - accepted");
	t.assertseq(svcctl("running", 3000), "running", "load - restarts an exited service");

	t.assertnil(svcmode("raise"), "raise composition");
	st := svcctl("failed", 2000);
	t.assert(hasprefix(st, "failed") && contains(st, "boom"), "run() raised: " + st);

	t.assertnil(svcmode("initfail"), "initfail composition");
	st = svcctl("failed", 2000);
	t.assert(hasprefix(st, "failed init") && contains(st, "nope"), "init refused: " + st);

	sys->remove("/tmp/matrix/mtest-svc/pids");
	t.assertnil(svcmode("block"), "block composition");
	pids := "";
	for(w := 0; w < 3000 && pids == ""; w += 100) {
		pids = trim(readfile("/tmp/matrix/mtest-svc/pids"));
		if(pids == "")
			sys->sleep(100);
	}
	(n, pl) := sys->tokenize(pids, " ");
	if(n != 2)
		t.fatal("blocking service wrote no pids: " + pids);
	t.assert(alive(hd pl) && alive(hd tl pl), "blocking service and its child run");
	t.assert(writestr("/mnt/matrix/ctl", "load sysmon") > 0, "restore accepted");
	gone := 0;
	for(w = 0; w < 6000 && !gone; w += 200) {
		gone = !alive(hd pl) && !alive(hd tl pl);
		if(!gone)
			sys->sleep(200);
	}
	t.assert(gone, "a service that ignores shutdown is killed, child and all");
	t.assert(waitfor("/mnt/matrix/modules/mem-gauge", 3000), "shipped composition restored");
	sys->remove(SVCFIX);
}

copyfile(src, dst: string): int
{
	in := sys->open(src, Sys->OREAD);
	if(in == nil)
		return -1;
	out := sys->create(dst, Sys->OWRITE, 8r644);
	if(out == nil)
		return -1;
	buf := array[8192] of byte;
	while((n := sys->read(in, buf, len buf)) > 0)
		if(sys->write(out, buf, n) != n)
			return -1;
	return 0;
}

# The load cooldown spans compositions.  A's rule loads B on crisis,
# B's loads A on normal: flipping the value back within the cooldown
# of A's load must not ping-pong straight back to A.  (Each watcher
# reset the cooldown as it started, so B's could always fire.)
testControlFSWatchCooldown(t: ref T)
{
	mkfixture();
	p := FIXMOUNT + "/portfolio/defense/status";
	createstr(p, "normal\n");
	ping := "# mtest-ping\nwatch " + p + "\ncrisis -> load mtest-pong\n";
	pong := "# mtest-pong\nwatch " + p + "\nnormal -> load mtest-ping\n";
	createstr("/lib/matrix/compositions/mtest-ping", ping);
	createstr("/lib/matrix/compositions/mtest-pong", pong);

	t.assert(writestr("/mnt/matrix/ctl", "load mtest-ping") > 0, "load ping accepted");
	t.assert(waitcomp(ping, 3000), "ping loaded");
	sys->sleep(1500);	# ping's watcher takes its baseline

	createstr(p, "crisis\n");
	t.assert(waitcomp(pong, 4000), "crisis loaded pong");
	sys->sleep(300);	# pong's watcher takes its baseline: crisis
	createstr(p, "normal\n");
	# pong's next poll sees normal about a second after ping's load:
	# inside the 2 s cooldown, so it does not fire.
	sys->sleep(3000);
	t.assertseq(readfile("/mnt/matrix/composition"), pong, "no ping-pong inside the cooldown");

	sys->remove("/lib/matrix/compositions/mtest-ping");
	sys->remove("/lib/matrix/compositions/mtest-pong");
	t.assert(writestr("/mnt/matrix/ctl", "load sysmon") > 0, "restore accepted");
	t.assert(waitfor("/mnt/matrix/modules/mem-gauge", 3000), "shipped composition restored");
}

waitcomp(text: string, ms: int): int
{
	for(w := 0; w < ms; w += 100) {
		if(readfile("/mnt/matrix/composition") == text)
			return 1;
		sys->sleep(100);
	}
	return 0;
}

testControlFSCtlVerbs(t: ref T)
{
	t.assert(writestr("/mnt/matrix/ctl", "bogus-verb") < 0, "bad ctl verb rejected");
	t.assert(writestr("/mnt/matrix/ctl", "pin ../mtest-owned") < 0,
		"ctl pin rejects traversal name");
	t.assert(writestr("/mnt/matrix/ctl", "load sysmon\nunload") < 0,
		"ctl rejects control-delimited writes");
	t.assert(writestr("/mnt/matrix/ctl", "unpin ../sysmon") < 0,
		"ctl unpin rejects traversal name");

	# pin: current composition becomes a named library entry; unpin removes it.
	t.assert(writestr("/mnt/matrix/ctl", "pin mtest-pinned") > 0, "pin accepted");
	t.assert(waitfor("/mnt/matrix/library/compositions/mtest-pinned", 2000), "pinned composition served");
	t.assertseq(readfile("/mnt/matrix/library/compositions/mtest-pinned"),
		readfile("/mnt/matrix/composition"), "pinned text matches live composition");
	t.assert(writestr("/mnt/matrix/ctl", "unpin mtest-pinned") > 0, "unpin accepted");
	(ok, nil) := sys->stat("/lib/matrix/compositions/mtest-pinned");
	t.assert(ok < 0, "unpin removed the file");
}

# Unload returns to the picker composition (#454), or to nothing
# (status idle) where there is no picker file.
testControlFSUnload(t: ref T)
{
	picker := readfile("/lib/matrix/compositions/picker");
	t.assert(writestr("/mnt/matrix/ctl", "unload") > 0, "unload accepted");
	back := 0;
	for(waited := 0; waited < 5000; waited += 250) {
		if(picker != "")
			back = readfile("/mnt/matrix/composition") == picker;
		else
			back = trim(readfile("/mnt/matrix/ctl")) == "idle";
		if(back)
			break;
		sys->sleep(250);
	}
	if(picker != "")
		t.assert(back, "unload returns to the picker composition");
	else
		t.assert(back, "status idle after unload (no picker)");
	# Dead slots vanish from walks.
	(ok, nil) := sys->stat("/mnt/matrix/modules/sysmon-svc");
	t.assert(ok < 0, "unloaded module no longer walkable");
	names := lsnames("/mnt/matrix/modules");
	t.assert(!hasname(names, "sysmon-svc"), "unloaded module not listed");
}

stopmatrix()
{
	if(matrixpid <= 0)
		return;
	writestr("/mnt/matrix/ctl", "unload");
	sys->sleep(1500);	# let services notice shutdown
	fd := sys->open("/prog/" + string matrixpid + "/ctl", Sys->OWRITE);
	if(fd != nil) {
		b := array of byte "killgrp";
		sys->write(fd, b, len b);
	}
	sys->unmount(nil, "/mnt/matrix");
	matrixpid = -1;
}

# ── Main ────────────────────────────────────────────────────

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();

	matrixlib = load MatrixLib MatrixLib->PATH;
	if(matrixlib == nil) {
		sys->fprint(sys->fildes(2), "cannot load matrixlib: %r\n");
		raise "fail:cannot load matrixlib";
	}
	matrixlib->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("ParseSysmon", testParseSysmon);
	run("ParsePerfDashboard", testParsePerfDashboard);
	run("ParseVideoDemo", testParseVideoDemo);
	run("HeadlessComposition", testHeadlessComposition);
	run("EmptyComposition", testEmptyComposition);
	run("NestedSplits", testNestedSplits);
	run("DuplicateLayout", testDuplicateLayout);
	run("BadOrientation", testBadOrientation);
	run("BadRatio", testBadRatio);
	run("UnknownRegionSplit", testUnknownRegionSplit);
	run("UnknownRegionAssign", testUnknownRegionAssign);
	run("SplitConsumedRegion", testSplitConsumedRegion);
	run("MaxDepth", testMaxDepth);
	run("ServiceNeedsMount", testServiceNeedsMount);
	run("UnsafeCompositionTokens", testUnsafeCompositionTokens);
	run("UnrecognizedLine", testUnrecognizedLine);
	run("CompositionRefusals", testCompositionRefusals);
	run("ShippedCompositions", testShippedCompositions);
	run("CommentsAndBlanks", testCommentsAndBlanks);
	run("TextRoundTrip", testTextRoundTrip);
	run("WatchGrammar", testWatchGrammar);
	run("WatchTerminator", testWatchTerminator);
	run("WatchErrors", testWatchErrors);
	run("AppLeafGrammar", testAppLeafGrammar);
	run("TkDisplayTypecheck", testTkDisplayTypecheck);
	run("Transplant", testTransplant);
	run("Isolation", testIsolation);

	run("ControlFSStart", testControlFSStart);
	if(matrixpid > 0) {
		run("ControlFSComposition", testControlFSComposition);
		run("ControlFSModules", testControlFSModules);
		run("ControlFSOutPassthrough", testControlFSOutPassthrough);
		run("ControlFSLibrary", testControlFSLibrary);
		run("ControlFSIndex", testControlFSIndex);
		run("ControlFSMan", testControlFSMan);
		run("ControlFSVeltroTool", testControlFSVeltroTool);
		run("ControlFSNotifications", testControlFSNotifications);
		run("ControlFSReload", testControlFSReload);
		run("ControlFSCompositionWrite", testControlFSCompositionWrite);
		run("ControlFSServiceLifecycle", testControlFSServiceLifecycle);
		run("ControlFSAlertE2E", testControlFSAlertE2E);
		run("ControlFSWatch", testControlFSWatch);
		run("ControlFSWatchCooldown", testControlFSWatchCooldown);
		run("ControlFSCtlVerbs", testControlFSCtlVerbs);
		run("ControlFSUnload", testControlFSUnload);
	}
	stopmatrix();

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

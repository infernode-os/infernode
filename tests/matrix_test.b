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

include "matrix.m";

include "matrixlib.m";
	matrixlib: MatrixLib;

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
	t.asserteq(countleaves(c.layout), 3, "hsplit + left vsplit = 3 leaves");
	t.asserteq(nassigns(c), 3, "three display assignments");
	t.asserteq(nservices(c), 1, "one service");

	se := servicebyname(c, "sysmon-svc");
	if(se == nil)
		t.fatal("sysmon-svc service missing");
	t.assertseq(se.mount, "/", "sysmon-svc mounts the whole namespace");

	lt := leafbyname(c.layout, "left/top");
	if(lt == nil)
		t.fatal("left/top leaf missing");
	t.assertseq(lt.modname, "cpu-gauge", "left/top module");

	r := leafbyname(c.layout, "right");
	if(r == nil)
		t.fatal("right leaf missing");
	t.assertseq(r.modname, "proc-list", "right module");
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

testParseTbl4(t: ref T)
{
	text := readfile("/lib/matrix/compositions/tbl4-overview");
	if(text == "")
		t.fatal("cannot read shipped tbl4-overview composition");
	(c, err) := matrixlib->parsecomposition(text);
	t.assertnil(err, "tbl4-overview parses cleanly");
	if(c == nil)
		t.fatal("nil composition");
	t.asserteq(countleaves(c.layout), 3, "nested split = 3 leaves");
	lb := leafbyname(c.layout, "left/bottom");
	if(lb == nil)
		t.fatal("left/bottom leaf missing");
	t.assertseq(lb.modname, "signal-feed", "left/bottom module");
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
	run("ParseTbl4", testParseTbl4);
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
	run("UnrecognizedLine", testUnrecognizedLine);
	run("CommentsAndBlanks", testCommentsAndBlanks);
	run("TextRoundTrip", testTextRoundTrip);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

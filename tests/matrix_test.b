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
	if(!waitfor("/mnt/matrix/ctl", 5000))
		t.fatal("/mnt/matrix/ctl never appeared");
	matrixpid = pidofmodule("Matrix");
	t.assert(matrixpid > 0, "matrix pid found in /prog");
	t.assertseq(trim(readfile("/mnt/matrix/ctl")), "running", "status running");
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
	for(i := 0; i < 10; i++)
		sys->remove(sys->sprint("/tmp/matrix/alert-watcher/alert-%04d", i));

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

	# Restore the shipped composition for the tests that follow.
	t.assert(writestr("/mnt/matrix/ctl", "load sysmon") > 0, "restore accepted");
	t.assert(waitfor("/mnt/matrix/modules/mem-gauge", 3000), "shipped composition restored");
}

testControlFSCtlVerbs(t: ref T)
{
	t.assert(writestr("/mnt/matrix/ctl", "bogus-verb") < 0, "bad ctl verb rejected");

	# pin: current composition becomes a named library entry; unpin removes it.
	t.assert(writestr("/mnt/matrix/ctl", "pin mtest-pinned") > 0, "pin accepted");
	t.assert(waitfor("/mnt/matrix/library/compositions/mtest-pinned", 2000), "pinned composition served");
	t.assertseq(readfile("/mnt/matrix/library/compositions/mtest-pinned"),
		readfile("/mnt/matrix/composition"), "pinned text matches live composition");
	t.assert(writestr("/mnt/matrix/ctl", "unpin mtest-pinned") > 0, "unpin accepted");
	(ok, nil) := sys->stat("/lib/matrix/compositions/mtest-pinned");
	t.assert(ok < 0, "unpin removed the file");
}

testControlFSUnload(t: ref T)
{
	t.assert(writestr("/mnt/matrix/ctl", "unload") > 0, "unload accepted");
	idle := 0;
	for(waited := 0; waited < 5000; waited += 250) {
		if(trim(readfile("/mnt/matrix/ctl")) == "idle") {
			idle = 1;
			break;
		}
		sys->sleep(250);
	}
	t.assert(idle, "status idle after unload");
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
	run("WatchGrammar", testWatchGrammar);
	run("WatchTerminator", testWatchTerminator);
	run("WatchErrors", testWatchErrors);
	run("Transplant", testTransplant);
	run("Isolation", testIsolation);

	run("ControlFSStart", testControlFSStart);
	if(matrixpid > 0) {
		run("ControlFSComposition", testControlFSComposition);
		run("ControlFSModules", testControlFSModules);
		run("ControlFSOutPassthrough", testControlFSOutPassthrough);
		run("ControlFSLibrary", testControlFSLibrary);
		run("ControlFSNotifications", testControlFSNotifications);
		run("ControlFSReload", testControlFSReload);
		run("ControlFSAlertE2E", testControlFSAlertE2E);
		run("ControlFSCtlVerbs", testControlFSCtlVerbs);
		run("ControlFSUnload", testControlFSUnload);
	}
	stopmatrix();

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

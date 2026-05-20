implement MatrixPerfDashboardTest;

#
# Integration test for the perf-dashboard Matrix composition.
#
# Covers:
#   1. All three matrix modules (llm-recorder, llm-context,
#      llm-sessions) load with the right interface and at the
#      paths matrix.b's runtime expects (/dis/matrix/<name>.dis).
#   2. End-to-end recorder lifecycle against a hand-built fake
#      /n/llm tree under /tmp: init → spawned run → samples
#      land in outdir → shutdown is observed.
#   3. The recorder's output file format is what the display
#      modules parse: outdir/sessions, outdir/<id>/current,
#      outdir/<id>/history with the documented field shape.
#
# Display rendering is not exercised — that needs a Draw->Display
# which a headless emu does not have.  The compile-and-load step
# at (1) is the typecheck guard for the display-side code.
#

include "sys.m";
	sys: Sys;
	Dir: import sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "matrix.m";

MatrixPerfDashboardTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/matrix_perfdashboard_test.b";

# Use unique dirs under /tmp so concurrent runs don't collide.
FAKELLM: con "/tmp/perfdash-test-llm";
OUTDIR:  con "/tmp/perfdash-test-out";

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# ── Module-load typecheck tests ──────────────────────────────

testLoadRecorder(t: ref T)
{
	path := "/dis/matrix/llm-recorder.dis";
	mod := load MatrixService path;
	if(mod == nil)
		t.error("load failed: " + path);
}

testLoadContext(t: ref T)
{
	path := "/dis/matrix/llm-context.dis";
	mod := load MatrixDisplay path;
	if(mod == nil)
		t.error("load failed: " + path);
}

testLoadSessions(t: ref T)
{
	path := "/dis/matrix/llm-sessions.dis";
	mod := load MatrixDisplay path;
	if(mod == nil)
		t.error("load failed: " + path);
}

# ── End-to-end recorder test ─────────────────────────────────

testRecorderEndToEnd(t: ref T)
{
	if(!tmpok(t))
		return;

	cleardir(FAKELLM);
	cleardir(OUTDIR);

	# Build the fake /n/llm tree the recorder will poll.
	# Two sessions (0 and 7); a "new" file the recorder must skip.
	mkdir(FAKELLM);
	writefile(FAKELLM + "/new", "");
	mkdir(FAKELLM + "/0");
	writefile(FAKELLM + "/0/usage", "1234/200000\n");
	writefile(FAKELLM + "/0/model", "haiku\n");
	mkdir(FAKELLM + "/7");
	writefile(FAKELLM + "/7/usage", "98765/200000\n");
	writefile(FAKELLM + "/7/model", "sonnet\n");

	mkdir(OUTDIR);

	mod := load MatrixService "/dis/matrix/llm-recorder.dis";
	if(mod == nil) {
		t.fatal("cannot load llm-recorder.dis");
		return;
	}

	err := mod->init(FAKELLM, OUTDIR);
	t.assertnil(err, "recorder init returned nil");

	spawn mod->run();

	# Wait long enough for at least two poll cycles
	# (recorder POLL_MS is 1000).
	sys->sleep(2500);

	mod->shutdown();
	# Give run() time to observe the shutdown flag and unwind.
	sys->sleep(1500);

	# outdir/sessions should list both ids.
	sessions := readstr(OUTDIR + "/sessions");
	if(sessions == nil)
		t.error("outdir/sessions not written");
	t.assert(contains(sessions, "0") && contains(sessions, "7"),
		"outdir/sessions contains both session ids: " + sessions);
	t.assert(!contains(sessions, "new"),
		"outdir/sessions does not contain the 'new' entry");

	# outdir/0/current: "<ms> <model> <tokens> <limit>"
	cur := readstr(OUTDIR + "/0/current");
	if(cur == nil)
		t.error("outdir/0/current not written");
	(nc, tc) := sys->tokenize(stripnl(cur), " \t");
	t.asserteq(nc, 4, "outdir/0/current has 4 fields");
	if(nc == 4) {
		tc = tl tc;  # ms
		t.assertseq(hd tc, "haiku", "model field");
		tc = tl tc;
		t.assertseq(hd tc, "1234", "tokens field");
		tc = tl tc;
		t.assertseq(hd tc, "200000", "limit field");
	}

	# outdir/7/current
	cur7 := readstr(OUTDIR + "/7/current");
	if(cur7 == nil)
		t.error("outdir/7/current not written");
	(n7, t7) := sys->tokenize(stripnl(cur7), " \t");
	t.asserteq(n7, 4, "outdir/7/current has 4 fields");
	if(n7 == 4) {
		t7 = tl t7;
		t.assertseq(hd t7, "sonnet", "session 7 model");
	}

	# outdir/0/history: at least one sample line of "<ms> <tokens> <limit>"
	hist := readstr(OUTDIR + "/0/history");
	if(hist == nil)
		t.error("outdir/0/history not written");
	lines := countlines(hist);
	t.assert(lines >= 1, sys->sprint("history has >=1 sample (got %d)", lines));
	t.assert(lines <= 60,
		sys->sprint("history bounded by 60-sample ring (got %d)", lines));

	# Each history line must be "<ms> <tokens> <limit>".
	bad := badhistlines(hist);
	t.asserteq(bad, 0, "history lines all have 3 numeric fields");
}

# Recorder must keep polling between cycles: after a longer wait,
# the history file has more samples than after a shorter wait.
testRecorderRingGrows(t: ref T)
{
	if(!tmpok(t))
		return;

	cleardir(FAKELLM);
	cleardir(OUTDIR);

	mkdir(FAKELLM);
	mkdir(FAKELLM + "/0");
	writefile(FAKELLM + "/0/usage", "100/100000\n");
	writefile(FAKELLM + "/0/model", "haiku\n");
	mkdir(OUTDIR);

	mod := load MatrixService "/dis/matrix/llm-recorder.dis";
	if(mod == nil) {
		t.fatal("cannot load llm-recorder.dis");
		return;
	}
	if((err := mod->init(FAKELLM, OUTDIR)) != nil) {
		t.fatal("init: " + err);
		return;
	}
	spawn mod->run();

	sys->sleep(1500);
	hist1 := readstr(OUTDIR + "/0/history");
	n1 := countlines(hist1);

	sys->sleep(2000);
	hist2 := readstr(OUTDIR + "/0/history");
	n2 := countlines(hist2);

	mod->shutdown();
	sys->sleep(1500);

	t.assert(n2 > n1,
		sys->sprint("ring grew between polls: %d → %d", n1, n2));
}

# Recorder must drop sessions from outdir/sessions when they
# disappear from the source tree.
testRecorderSessionDisappears(t: ref T)
{
	if(!tmpok(t))
		return;

	cleardir(FAKELLM);
	cleardir(OUTDIR);

	mkdir(FAKELLM);
	mkdir(FAKELLM + "/3");
	writefile(FAKELLM + "/3/usage", "500/100000\n");
	writefile(FAKELLM + "/3/model", "haiku\n");
	mkdir(OUTDIR);

	mod := load MatrixService "/dis/matrix/llm-recorder.dis";
	if(mod == nil) { t.fatal("cannot load llm-recorder.dis"); return; }
	if((err := mod->init(FAKELLM, OUTDIR)) != nil) {
		t.fatal("init: " + err);
		return;
	}
	spawn mod->run();
	sys->sleep(1500);

	s1 := stripnl(readstr(OUTDIR + "/sessions"));
	t.assertseq(s1, "3", "session 3 visible initially: " + s1);

	# Remove the session from source.
	cleardir(FAKELLM + "/3");
	# rmdir via wstat is fiddly; the recorder treats absence-from-listing
	# as "gone".  Drop the model/usage files; the dir may still appear in
	# listings but reads of usage will fail and limit==0 will not push a
	# sample.  Either way, the new sessions file should no longer mention 3.
	sys->remove(FAKELLM + "/3");

	sys->sleep(1500);
	s2 := stripnl(readstr(OUTDIR + "/sessions"));
	t.assertseq(s2, "", "session 3 dropped after removal: '" + s2 + "'");

	mod->shutdown();
	sys->sleep(1500);
}

# ── init() / runner glue ─────────────────────────────────────

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2),
			"cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("LoadRecorder",          testLoadRecorder);
	run("LoadContextDisplay",    testLoadContext);
	run("LoadSessionsDisplay",   testLoadSessions);
	run("RecorderEndToEnd",      testRecorderEndToEnd);
	run("RecorderRingGrows",     testRecorderRingGrows);
	run("RecorderSessionDisappears", testRecorderSessionDisappears);

	# Tidy up scratch dirs.
	cleardir(FAKELLM);
	cleardir(OUTDIR);
	sys->remove(FAKELLM);
	sys->remove(OUTDIR);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

# Skip-gracefully helper.  Recorder tests need a writable /tmp in
# the namespace; CI creates one via `mkdir -p tmp` in the project
# root.  Local dev: `mkdir tmp` once.  Without it, all the FS work
# below would just be noise.
tmpok(t: ref T): int
{
	(ok, nil) := sys->stat("/tmp");
	if(ok == 0)
		return 1;
	t.skip("/tmp not in namespace (mkdir $ROOT/tmp once)");
	return 0;
}

# ── Filesystem helpers (no error-handling rigour: it's a test) ─

mkdir(path: string)
{
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
	if(fd != nil)
		fd = nil;
}

writefile(path, text: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	b := array of byte text;
	sys->write(fd, b, len b);
	fd = nil;
}

readstr(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	out := "";
	buf := array[4096] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		out += string buf[0:n];
	}
	fd = nil;
	return out;
}

# Best-effort: remove all entries below `dir`, then `dir` itself.
cleardir(dir: string)
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return;
	for(;;) {
		(n, ents) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			sub := dir + "/" + ents[i].name;
			if(ents[i].mode & Sys->DMDIR)
				cleardir(sub);
			sys->remove(sub);
		}
	}
	fd = nil;
}

stripnl(s: string): string
{
	if(s == nil)
		return s;
	end := len s;
	while(end > 0 && (s[end-1] == '\n' || s[end-1] == ' '))
		end--;
	return s[0:end];
}

contains(haystack, needle: string): int
{
	# Token-based: split haystack on whitespace and look for needle.
	(nil, toks) := sys->tokenize(haystack, " \t\n");
	for(; toks != nil; toks = tl toks)
		if(hd toks == needle)
			return 1;
	return 0;
}

countlines(s: string): int
{
	if(s == nil)
		return 0;
	n := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			n++;
	# Trailing partial line, if any.
	if(len s > 0 && s[len s - 1] != '\n')
		n++;
	return n;
}

# Returns count of non-empty history lines that DO NOT match the
# expected "<int> <int> <int>" shape.
badhistlines(s: string): int
{
	bad := 0;
	start := 0;
	for(i := 0; i <= len s; i++) {
		if(i == len s || s[i] == '\n') {
			if(i > start) {
				line := s[start:i];
				(nt, tt) := sys->tokenize(line, " \t");
				if(nt != 3) {
					bad++;
				} else {
					for(j := 0; j < 3; j++) {
						if(!isintstr(hd tt)) {
							bad++;
							break;
						}
						tt = tl tt;
					}
				}
			}
			start = i + 1;
		}
	}
	return bad;
}

isintstr(s: string): int
{
	if(len s == 0)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

implement MatrixSysmonTest;

#
# matrix_sysmon_test - sysmon composition integration tests
#
# Covers the two things INFR-133 asked for as the safety net:
#   1. Module-load typecheck of every sysmon module against the
#      MatrixDisplay/MatrixService interfaces (fast, no display).
#   2. End-to-end service lifecycle: run sysmon-svc against the
#      real emu namespace (/dev/memory, /prog, /net all exist
#      headless) for ~3 polls and verify every output file's shape,
#      including the INFR-133 additions proc/cpurates and the net
#      census.
#
# Display draw() paths are not exercised — headless emu has no
# Draw->Display; the load step is the typecheck guard.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "matrix.m";

include "testing.m";
	testing: Testing;
	T: import testing;

MatrixSysmonTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/matrix_sysmon_test.b";
OUTDIR: con "/tmp/sysmon-test-out";

passed := 0;
failed := 0;
skipped := 0;

svc: MatrixService;

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

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	out := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		out += string buf[0:n];
	}
	return out;
}

lines(s: string): list of string
{
	l: list of string;
	start := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n') {
			if(i > start)
				l = s[start:i] :: l;
			start = i + 1;
		}
	rev: list of string;
	for(; l != nil; l = tl l)
		rev = hd l :: rev;
	return rev;
}

ntoks(s: string): int
{
	(n, nil) := sys->tokenize(s, " \t");
	return n;
}

isint(s: string): int
{
	if(len s == 0)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

# ── Typecheck loads ─────────────────────────────────────────

testLoadDisplays(t: ref T)
{
	for(l := "cpu-gauge" :: "mem-gauge" :: "net-gauge" :: "proc-list" :: nil; l != nil; l = tl l) {
		m := load MatrixDisplay "/dis/matrix/" + hd l + ".dis";
		t.assert(m != nil, hd l + " loads as MatrixDisplay");
	}
}

testLoadService(t: ref T)
{
	m := load MatrixService "/dis/matrix/sysmon-svc.dis";
	t.assert(m != nil, "sysmon-svc loads as MatrixService");
}

# ── Service lifecycle ───────────────────────────────────────

runsvc()
{
	svc->run();
}

testServiceEndToEnd(t: ref T)
{
	svc = load MatrixService "/dis/matrix/sysmon-svc.dis";
	if(svc == nil)
		t.fatal(sys->sprint("cannot load sysmon-svc: %r"));
	err := svc->init("/", OUTDIR);
	t.assertnil(err, "init ok");
	spawn runsvc();
	sys->sleep(3500);	# ~3 polls at 1 Hz

	# mem/current: verbatim /dev/memory — pool lines of 8 fields.
	mem := readfile(OUTDIR + "/mem/current");
	t.assert(mem != "", "mem/current non-empty");
	t.assert(ntoks(hd lines(mem)) >= 8, "mem/current pool line shape");

	# cpu/current: "pct busy total", pct in range.
	cpu := readfile(OUTDIR + "/cpu/current");
	t.asserteq(ntoks(cpu), 3, "cpu/current is three fields");
	(nil, ctoks) := sys->tokenize(cpu, " \t\n");
	pct := int hd ctoks;
	t.assert(pct >= 0 && pct <= 100, "cpu pct in range");

	# Histories grow one line per poll.
	ch := lines(readfile(OUTDIR + "/cpu/history"));
	nch := 0;
	for(cl := ch; cl != nil; cl = tl cl) {
		t.asserteq(ntoks(hd cl), 2, "cpu/history line is ts pct");
		nch++;
	}
	t.assert(nch >= 2, sys->sprint("cpu/history has samples (%d)", nch));
	mh := lines(readfile(OUTDIR + "/mem/history"));
	if(mh != nil)
		t.asserteq(ntoks(hd mh), 7, "mem/history line shape");

	# proc/list: at least this test's procs, >= 7 fields per row.
	pl := lines(readfile(OUTDIR + "/proc/list"));
	npl := 0;
	for(pll := pl; pll != nil; pll = tl pll) {
		t.assert(ntoks(hd pll) >= 7, "proc/list row shape");
		npl++;
	}
	t.assert(npl >= 1, "proc/list non-empty");

	# proc/cpurates: "pid pct" per row, pids a subset of proc/list,
	# pct clamped 0..100.
	cr := lines(readfile(OUTDIR + "/proc/cpurates"));
	ncr := 0;
	for(crl := cr; crl != nil; crl = tl crl) {
		(nil, rt) := sys->tokenize(hd crl, " \t");
		t.asserteq(len rt, 2, "cpurates row is pid pct");
		pid := hd rt;
		rpct := int hd tl rt;
		t.assert(isint(pid), "cpurates pid numeric");
		t.assert(rpct >= 0 && rpct <= 100, "cpurates pct in range");
		found := 0;
		for(pl2 := pl; pl2 != nil; pl2 = tl pl2) {
			(nil, ft) := sys->tokenize(hd pl2, " \t");
			if(ft != nil && hd ft == pid) {
				found = 1;
				break;
			}
		}
		t.assert(found, "cpurates pid " + pid + " present in proc/list");
		ncr++;
	}
	t.assert(ncr >= 1, "cpurates non-empty");

	# net/current: census lines "tcp t c a" and "udp t c a".
	net := readfile(OUTDIR + "/net/current");
	nl := lines(net);
	t.asserteq(len nl, 2, "net/current has tcp and udp lines");
	for(nll := nl; nll != nil; nll = tl nll) {
		(nil, nt) := sys->tokenize(hd nll, " \t");
		t.asserteq(len nt, 4, "census line is proto t c a");
		proto := hd nt;
		t.assert(proto == "tcp" || proto == "udp", "census proto label");
		tot := int hd tl nt;
		conn := int hd tl tl nt;
		ann := int hd tl tl tl nt;
		t.assert(tot >= 0 && conn >= 0 && ann >= 0, "census counts non-negative");
		t.assert(conn + ann <= tot, "census states bounded by total");
	}

	# net/history mirrors the poll count.
	nh := lines(readfile(OUTDIR + "/net/history"));
	nnh := 0;
	for(nhl := nh; nhl != nil; nhl = tl nhl) {
		t.asserteq(ntoks(hd nhl), 4, "net/history line shape");
		nnh++;
	}
	t.assert(nnh >= 2, "net/history has samples");

	# Shutdown is observed within a poll.
	svc->shutdown();
	sys->sleep(1500);
	t.log("service shut down");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("LoadDisplays", testLoadDisplays);
	run("LoadService", testLoadService);
	run("ServiceEndToEnd", testServiceEndToEnd);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

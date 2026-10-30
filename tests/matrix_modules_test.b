implement MatrixModulesTest;

#
# matrix_modules_test - Matrix modules on their own: display modules
# on an image of their own, against files the test writes (what they
# read that is not shaped as sysmon-svc writes it, what a click does),
# and services through init, run and shutdown.  Skips where there is
# no display to draw on.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Pointer, Rect: import draw;

include "matrix.m";

include "testing.m";
	testing: Testing;
	T: import testing;

MatrixModulesTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/matrix_modules_test.b";
FIX: con "/tmp/mtest/mods";

passed := 0;
failed := 0;
skipped := 0;

display: ref Display;

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

mkdirp(path: string)
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

writefile(path, s: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	b := array of byte s;
	sys->write(fd, b, len b);
}

# Load a display module, init it on FIX, size it, update and draw it.
# Returns the module, or nil with the reason (a raise included).
drive(path: string, r: Rect): (MatrixDisplay, string)
{
	mod := load MatrixDisplay path;
	if(mod == nil)
		return (nil, sys->sprint("cannot load %s: %r", path));
	font := Font.open(display, "*default*");
	img := display.newimage(r, Draw->RGB24, 0, Draw->Black);
	{
		err := mod->init(display, font, FIX);
		if(err != nil)
			return (nil, "init: " + err);
		mod->resize(r);
		mod->update();
		mod->draw(img);
	} exception e {
	"*" =>
		return (nil, "raised " + e);
	}
	return (mod, nil);
}

# A history or list file whose last line has no newline (an agent's
# echo -n, any producer but sysmon-svc): the readers sized their
# arrays by newlines and then parsed the last line as well, one past
# the end.
testUnterminatedLastLine(t: ref T)
{
	mkdirp(FIX + "/cpu");
	mkdirp(FIX + "/net");
	mkdirp(FIX + "/proc");
	writefile(FIX + "/cpu/current", "5 1 3\n");
	writefile(FIX + "/cpu/history", "1 5\n2 6");
	writefile(FIX + "/net/current", "tcp 3 1 1\nudp 1 0 0\n");
	writefile(FIX + "/net/history", "1 3 1 1\n2 4 2 1");
	writefile(FIX + "/proc/list", "  999991  999991  root  0:00.0  ready  3K Fake\n" +
		"  999992  999992  root  0:00.0  alt  3K Fake");
	writefile(FIX + "/proc/cpurates", "999991 4\n999992 0");
	r := Rect((0, 0), (300, 200));
	for(l := "cpu-gauge" :: "net-gauge" :: "proc-list" :: nil; l != nil; l = tl l) {
		(nil, err) := drive("/dis/matrix/" + hd l + ".dis", r);
		t.assertnil(err, hd l + " reads a last line with no newline");
	}
}

# A click below the last row proc-list draws selected the row that
# would come next -- one not on screen -- which k then killed.
testProcListClickBelowRows(t: ref T)
{
	mkdirp(FIX + "/proc");
	rows := "";
	for(i := 0; i < 40; i++)
		rows += sys->sprint("  %d  %d  root  0:00.0  alt  3K Fake\n", 999900 + i, 999900 + i);
	writefile(FIX + "/proc/list", rows);
	writefile(FIX + "/proc/cpurates", "");
	r := Rect((0, 0), (300, 200));
	(mod, err) := drive("/dis/matrix/proc-list.dis", r);
	if(mod == nil)
		t.fatal(err);
	mod->pointer(ref Pointer(1, Point(20, r.max.y - 1), 0));
	mod->pointer(ref Pointer(0, Point(20, r.max.y - 1), 0));
	t.asserteq(mod->key('k'), 0, "nothing selected below the drawn rows, nothing to kill");

	# A click on a row drawn does select it.
	mod->pointer(ref Pointer(1, Point(20, r.max.y / 2), 0));
	mod->pointer(ref Pointer(0, Point(20, r.max.y / 2), 0));
	t.asserteq(mod->key('k'), 1, "a drawn row is selected by a click");
	mod->shutdown();
}

# A history file that grows by appends past 16K: line-plot and
# sparkline read 16K once, saw the same 16K at every update and
# froze; they see each new line.
testHistoryPastOneRead(t: ref T)
{
	mkdirp(FIX);
	h := "";
	for(i := 0; i < 4000; i++)
		h += sys->sprint("%d %d\n", 1000 + i, i % 50);
	path := FIX + "/history";
	writefile(path, h);
	r := Rect((0, 0), (300, 200));
	for(l := "line-plot" :: "sparkline" :: nil; l != nil; l = tl l) {
		(mod, err) := drive2(hd l, path, r);
		if(mod == nil) {
			t.error(hd l + ": " + err);
			continue;
		}
		fd := sys->open(path, Sys->OWRITE);
		sys->seek(fd, big 0, Sys->SEEKEND);
		sys->fprint(fd, "9999 77\n");
		fd = nil;
		t.asserteq(mod->update(), 1, hd l + " sees a line appended past 16K");
		t.asserteq(mod->update(), 0, hd l + " unchanged when the file is");
		mod->shutdown();
	}
}

drive2(name, mount: string, r: Rect): (MatrixDisplay, string)
{
	mod := load MatrixDisplay "/dis/matrix/" + name + ".dis";
	if(mod == nil)
		return (nil, sys->sprint("cannot load: %r"));
	font := Font.open(display, "*default*");
	img := display.newimage(r, Draw->RGB24, 0, Draw->Black);
	{
		err := mod->init(display, font, mount);
		if(err != nil)
			return (nil, "init: " + err);
		mod->resize(r);
		mod->update();
		mod->draw(img);
	} exception e {
	"*" =>
		return (nil, "raised " + e);
	}
	return (mod, nil);
}

# scene-fixture serves a scene when there is none, and takes it down
# at shutdown.  It left its scenefs mounted: the next load found the
# scene there, took it for someone else's, started no demo, and the
# scene stayed frozen.
SCENE: con "/tmp/mtest/scene-fix";

readall(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

# Start the fixture; return it once its scene's time moves.
scenerun(t: ref T, what: string): MatrixService
{
	svc := load MatrixService "/dis/matrix/scene-fixture.dis";
	if(svc == nil)
		t.fatal(sys->sprint("cannot load scene-fixture: %r"));
	err := svc->init(SCENE, "/tmp/mtest/scene-out");
	if(err != nil)
		t.fatal(what + ": init: " + err);
	spawn svcrun(svc);
	t0 := readall(SCENE + "/time");
	moved := 0;
	for(w := 0; w < 5000 && !moved; w += 200) {
		sys->sleep(200);
		moved = readall(SCENE + "/time") != t0;
	}
	t.assert(moved, what + ": the demo drives the scene");
	return svc;
}

svcrun(svc: MatrixService)
{
	svc->run();
}

testSceneFixtureRestart(t: ref T)
{
	(ok, nil) := sys->stat("/dis/scenefs.dis");
	if(ok < 0)
		t.skip("no scenefs");
	mkdirp(SCENE);
	svc := scenerun(t, "first load");
	svc->shutdown();
	sys->sleep(300);
	(st, nil) := sys->stat(SCENE + "/status");
	t.assert(st < 0, "shutdown takes the scene it served down");
	svc = scenerun(t, "second load");
	svc->shutdown();
}

# update() says whether its region needs redrawing: these nine said
# yes at every tick, so the runtime redrew them all every 2 s (and at
# a video pane's 40 ms, any that shared its cadence).  Unchanged files,
# no change; a file it reads rewritten, a change.
testUpdateOnlyOnChange(t: ref T)
{
	D := FIX + "/upd";
	mkdirp(D + "/cpu");
	mkdirp(D + "/net");
	mkdirp(D + "/proc");
	mkdirp(D + "/mem");
	mkdirp(D + "/positions");
	mkdirp(D + "/portfolio/defense");
	mkdirp(D + "/llm/1");
	writefile(D + "/cpu/current", "5 1 3\n");
	writefile(D + "/cpu/history", "1 5\n2 6\n");
	writefile(D + "/net/current", "tcp 3 1 1\nudp 1 0 0\n");
	writefile(D + "/net/history", "1 3 1 1\n");
	writefile(D + "/proc/list", "  999991  999991  root  0:00.0  ready  3K Fake\n");
	writefile(D + "/proc/cpurates", "999991 4\n");
	writefile(D + "/mem/current", "1000 2000 3 4 5 6 7 main\n");
	writefile(D + "/positions/BTC", "BTC 1 100 0\n");
	writefile(D + "/risk", "0.02 0.03 1000 500 normal\n");
	writefile(D + "/signals", "1 BTC long 0.9 breakout 1234\n");
	writefile(D + "/llm/sessions", "1\n");
	writefile(D + "/llm/1/current", "100 1000\n");
	writefile(D + "/llm/1/history", "1 100 1000\n");
	cases := array[] of {
		("cpu-gauge", D, D + "/cpu/current", "9 2 3\n"),
		("mem-gauge", D, D + "/mem/current", "1500 2000 3 4 5 6 7 main\n"),
		("net-gauge", D, D + "/net/current", "tcp 4 2 1\nudp 1 0 0\n"),
		("proc-list", D, D + "/proc/list", "  999992  999992  root  0:00.0  alt  3K Fake\n"),
		("position-table", D, D + "/positions/BTC", "BTC 2 100 0\n"),
		("risk-gauge", D + "/risk", D + "/risk", "0.05 0.03 1000 500 normal\n"),
		("signal-feed", D + "/signals", D + "/signals", "2 ETH short 0.8 reversal 1240\n"),
		("llm-context", D + "/llm", D + "/llm/1/current", "200 1000\n"),
		("llm-sessions", D + "/llm", D + "/llm/1/history", "1 100 1000\n2 200 1000\n"),
	};
	r := Rect((0, 0), (300, 200));
	for(i := 0; i < len cases; i++) {
		(name, mount, touch, text) := cases[i];
		(mod, err) := drive2(name, mount, r);
		if(mod == nil) {
			t.error(name + ": " + err);
			continue;
		}
		t.asserteq(mod->update(), 0, name + ": nothing changed, no redraw");
		writefile(touch, text);
		t.asserteq(mod->update(), 1, name + ": a file it reads changed");
		t.asserteq(mod->update(), 0, name + ": and then not again");
		mod->shutdown();
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	display = Display.allocate(nil);
	if(display == nil) {
		sys->print("SKIP: matrix_modules_test: no display\n");
		exit;
	}

	run("UnterminatedLastLine", testUnterminatedLastLine);
	run("ProcListClickBelowRows", testProcListClickBelowRows);
	run("HistoryPastOneRead", testHistoryPastOneRead);
	run("SceneFixtureRestart", testSceneFixtureRestart);
	run("UpdateOnlyOnChange", testUpdateOnlyOnChange);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

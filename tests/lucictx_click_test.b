implement LucictxClickTest;

#
# In Lucifer's context zone the tool a click acts on is the tool drawn
# where the click is.
#
# The zone lists an agent's tools, a click on one removes it.  The rows
# are drawn most recently used first; the click handlers found the row's
# number and counted that far down the list as tools9p gives it, which
# is in another order as soon as the agent has used any tool but the
# first.  So the human clicked the tool the agent was using (the top
# row) and another was removed: the agent kept the one they meant to
# take away.  A row now carries the name drawn in it.
#
# And a tap is taken at its release, at the place it was pressed, while
# the zone is drawn again at every event (an agent's every tool call):
# rows can move between the two.  A tap now acts only if it is still on
# what it was put down on.
#
# lucictx is run here as Lucifer runs it, on an image of the test's, with
# a real luciuisrv for the activity's resources and file2chan files in
# place of tools9p's: the pointer is the test's channel.  The row of the
# tool in use is found by its indicator, the only thing in the zone in
# the theme's accent colour.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Font, Rect, Point, Pointer: import draw;

include "lucitheme.m";

include "testing.m";
	testing: Testing;
	T: import testing;

LuciuiSrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

LuciCtx: module {
	init: fn(img: ref Draw->Image, dsp: ref Draw->Display,
	         font: ref Draw->Font,
	         mountpt: string, actid: int,
	         mouse: chan of ref Draw->Pointer,
	         evch:  chan of string,
	         rsz:   chan of ref Draw->Image,
	         req:   chan of string);
};

LucictxClickTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();
};

SRCFILE:	con "/tests/lucictx_click_test.b";
UI:		con "/tmp/lucictx_click_ui";

passed := 0;
failed := 0;
skipped := 0;

display: ref Display;
img: ref Image;
mouse: chan of ref Pointer;
evch: chan of string;
cmds: chan of string;		# what the zone wrote to tools9p's ctl
tools: list of string;		# the list as tools9p would give it
accent: array of byte;		# a pixel of the theme's accent colour
ready := 0;

_marker() {}

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

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

startui(done: chan of int)
{
	srv := load LuciuiSrv "/dis/luciuisrv.dis";
	if(srv == nil) {
		done <-= 0;
		return;
	}
	{
		srv->init(nil, "luciuisrv" :: "-m" :: UI :: nil);
		done <-= 1;
	} exception {
	* =>
		done <-= 0;
	}
}

# tools9p's files, as far as the zone uses them for activity 0: budget
# (the list shown) and ctl (remove, budget-remove).
toolfiles(budget, ctl: ref Sys->FileIO)
{
	for(;;) alt {
	(off, nil, nil, rc) := <-budget.read =>
		if(rc == nil)
			continue;
		s := "";
		for(l := tools; l != nil; l = tl l)
			s += hd l + "\n";
		b := array of byte s;
		if(off >= len b)
			rc <-= (nil, nil);
		else
			rc <-= (b[off:], nil);
	(nil, nil, nil, wc) := <-budget.write =>
		if(wc != nil)
			wc <-= (0, "read only");
	(nil, nil, nil, rc) := <-ctl.read =>
		if(rc != nil)
			rc <-= (nil, nil);
	(nil, data, nil, wc) := <-ctl.write =>
		if(wc == nil)
			continue;
		cmd := string data;
		if(len cmd > 7 && cmd[0:7] == "remove ") {
			kept: list of string;
			for(l := tools; l != nil; l = tl l)
				if(hd l != cmd[7:])
					kept = hd l :: kept;
			tools = nil;
			for(; kept != nil; kept = tl kept)
				tools = hd kept :: tools;
			cmds <-= cmd;
		}
		wc <-= (len data, nil);
	}
}

# The next "remove" the zone asks of tools9p, or nil in ms.
nextcmd(ms: int): string
{
	tc := chan[1] of int;
	spawn timer(tc, ms);
	alt {
	c := <-cmds =>
		return c;
	<-tc =>
		return nil;
	}
}

# The box of the accent-coloured pixels in the left half of the zone.
accentbox(): (int, Rect)
{
	r := img.r;
	w := r.dx();
	h := r.dy();
	buf := array[w * h * 3] of byte;
	if(img.readpixels(r, buf) < 0)
		return (0, r);
	n := 0;
	minx := w; miny := h; maxx := -1; maxy := -1;
	for(y := 0; y < h; y++)
		for(x := 0; x < w / 2; x++) {
			o := (y * w + x) * 3;
			if(buf[o] == accent[0] && buf[o+1] == accent[1] && buf[o+2] == accent[2]) {
				n++;
				if(x < minx) minx = x;
				if(x > maxx) maxx = x;
				if(y < miny) miny = y;
				if(y > maxy) maxy = y;
			}
		}
	return (n, Rect((minx, miny), (maxx + 1, maxy + 1)));
}

# Wait for the zone to be drawn with one tool's indicator lit; its box.
litrow(t: ref T): Rect
{
	for(i := 0; i < 100; i++) {
		(n, box) := accentbox();
		if(n > 0 && box.dy() < 40)
			return box;
		sys->sleep(100);
	}
	t.fatal("no tool's indicator is lit in the zone");
	return img.r;
}

press(pt: Point)
{
	mouse <-= ref Pointer(1, pt, sys->millisec());
}

release(pt: Point)
{
	mouse <-= ref Pointer(0, pt, sys->millisec());
}

ctxctl(cmd: string): int
{
	return writefile(UI + "/activity/0/context/ctl", cmd);
}

testSetup(t: ref T)
{
	display = Display.allocate(nil);
	if(display == nil)
		t.skip(sys->sprint("no display: %r"));
	font := Font.open(display, "*default*");
	if(font == nil)
		t.fatal(sys->sprint("no font: %r"));
	img = display.newimage(Rect((0, 0), (400, 600)), Draw->RGB24, 0, Draw->White);
	if(img == nil)
		t.fatal(sys->sprint("no image: %r"));
	lt := load Lucitheme Lucitheme->PATH;
	if(lt == nil)
		t.fatal(sys->sprint("cannot load lucitheme: %r"));
	th := lt->gettheme();
	one := display.newimage(Rect((0, 0), (1, 1)), Draw->RGB24, 0, Draw->White);
	one.draw(one.r, display.color(th.accent), nil, (0, 0));
	accent = array[3] of byte;
	one.readpixels(one.r, accent);

	done := chan[1] of int;
	spawn startui(done);
	tc := chan[1] of int;
	spawn timer(tc, 10000);
	ok := 0;
	alt {
	ok = <-done =>
		;
	<-tc =>
		t.fatal("luciuisrv did not start");
	}
	if(!ok)
		t.fatal("luciuisrv did not load or mount");
	t.assert(writefile(UI + "/ctl", "activity create Main") > 0, "activity 0");

	# tools9p's files for activity 0
	if(sys->bind("#s", "/tool", Sys->MREPL) < 0 || sys->bind("#s", "/mnt/toolctl", Sys->MREPL) < 0)
		t.fatal(sys->sprint("bind #s: %r"));
	budget := sys->file2chan("/tool", "budget");
	ctl := sys->file2chan("/mnt/toolctl", "ctl");
	if(budget == nil || ctl == nil)
		t.fatal(sys->sprint("file2chan: %r"));
	cmds = chan[8] of string;
	tools = "alpha" :: "bravo" :: "charlie" :: nil;
	spawn toolfiles(budget, ctl);

	# the tools as resources, the last of the list the one in use
	for(l := tools; l != nil; l = tl l)
		t.assert(ctxctl("resource add path=" + hd l + " label=" + hd l + " type=tool status=idle") > 0,
			"resource " + hd l);
	sys->sleep(20);		# lastused is a time in milliseconds
	t.assert(ctxctl("resource activity charlie") > 0, "charlie is used");
	t.assert(ctxctl("resource update path=charlie status=active") > 0, "and is active");

	ctx := load LuciCtx "/dis/lucictx.dis";
	if(ctx == nil)
		t.fatal(sys->sprint("cannot load lucictx: %r"));
	mouse = chan of ref Pointer;
	evch = chan of string;
	spawn ctx->init(img, display, font, UI, 0, mouse, evch,
		chan of ref Image, chan of string);
	ready = 1;
}

# The row of the tool in use is the top one; a click on it removes that tool.
testClickRemovesTheRowDrawn(t: ref T)
{
	if(!ready)
		t.skip("no zone");
	box := litrow(t);
	pt := Point(box.max.x + 40, (box.min.y + box.max.y) / 2);
	press(pt);
	release(pt);
	c := nextcmd(5000);
	t.assertseq(c, "remove charlie", "a click on the row of the tool in use removes it");
}

# A row that moves between press and release is not acted on.
testRowsMovedUnderATap(t: ref T)
{
	if(!ready)
		t.skip("no zone");
	nextcmd(300);		# nothing more from the click before
	# bravo in use: rows bravo, alpha
	sys->sleep(20);
	t.assert(ctxctl("resource update path=charlie status=idle") > 0, "charlie idle");
	t.assert(ctxctl("resource activity bravo") > 0, "bravo is used");
	t.assert(ctxctl("resource update path=bravo status=active") > 0, "and is active");
	evch <-= "context resources";
	box := litrow(t);
	rowh := 0;
	for(i := 0; i < 50 && rowh == 0; i++) {
		# the second row: found by lighting alpha too
		ctxctl("resource update path=alpha status=active");
		evch <-= "context resources";
		(nil, both) := accentbox();
		if(both.dy() > box.dy())
			rowh = both.max.y - box.max.y;
		else
			sys->sleep(100);
	}
	t.assert(rowh > 0, "two rows are drawn");
	ctxctl("resource update path=alpha status=idle");
	evch <-= "context resources";
	second := Point(box.max.x + 40, (box.min.y + box.max.y) / 2 + rowh);

	press(second);			# on alpha
	sys->sleep(20);
	t.assert(ctxctl("resource activity alpha") > 0, "alpha is used: rows alpha, bravo");
	evch <-= "context resources";
	release(second);		# where bravo is now
	c := nextcmd(1500);
	t.assertseq(c, "", "a tap whose row moved under it removes nothing");

	# and the zone still takes a tap
	press(second);
	release(second);
	c = nextcmd(5000);
	t.assertseq(c, "remove bravo", "a tap on the second row removes the tool drawn there");
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

	sys->pctl(Sys->FORKNS, nil);

	run("Setup", testSetup);
	run("ClickRemovesTheRowDrawn", testClickRemovesTheRowDrawn);
	run("RowsMovedUnderATap", testRowsMovedUnderATap);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

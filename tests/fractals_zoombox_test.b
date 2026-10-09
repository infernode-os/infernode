implement FractalsZoomboxTest;

#
# The wm/fractals zoom rubber-band must grow with a button-1 drag.
#
# The canvas bindings are read out of /appl/wm/fractals.b itself, so this
# exercises the app's real bindings against the real Tk event delivery
# (tk->pointer, the same path a mouse takes).  The handler below mirrors
# the app's b1down/b1drag/b1up cases.
#
# A drag reaches Tk as one Motion|Button1 event.  With only plain <Motion>
# bound, Tk falls back to partial matches and fires <Button-1> on every
# move too, so the box's corner chased the cursor and it never grew.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Pointer, Rect: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "string.m";
	str: String;

include "testing.m";
	testing: Testing;
	T: import testing;

FractalsZoomboxTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/fractals_zoombox_test.b";
APPSRC: con "/appl/wm/fractals.b";

W: con 400;
H: con 300;

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

# The `bind .top.frac ...` commands from the app source, as Tk commands.
appbinds(): list of string
{
	iob := bufio->open(APPSRC, Bufio->OREAD);
	if(iob == nil)
		return nil;
	l: list of string;
	while((line := iob.gets('\n')) != nil){
		(nil, s) := str->splitstrl(line, "\"bind .top.frac ");
		if(s == nil)
			continue;
		s = s[1:];
		for(i := 0; i < len s; i++)
			if(s[i] == '"')
				break;
		l = s[0:i] :: l;
	}
	return l;
}

# A no-wm toplevel holding the app's canvas, mapped onto an image so
# pointer events hit-test into it.
mktop(t: ref T, binds: list of string): (ref Toplevel, chan of string, ref Image)
{
	top := tk->toplevel(display, "");
	act := chan[64] of string;
	tk->namechan(top, act, "act");
	cmds := "frame .top" ::
		"canvas .top.frac -borderwidth 0 -background #000000" ::
		"pack .top.frac -side top -fill both -expand 1" ::
		"pack .top -side top -fill both -expand 1" ::
		"pack propagate . 0" ::
		sys->sprint(". configure -width %d -height %d", W, H) :: nil;
	for(; cmds != nil; cmds = tl cmds)
		tkok(t, top, hd cmds);
	for(; binds != nil; binds = tl binds)
		tkok(t, top, hd binds);
	tk->cmd(top, "update");
	r := Rect((0, 0), (W, H));
	img := display.newimage(r, display.image.chans, 0, Draw->Black);
	tk->putimage(top, ". -1", img, nil);
	tk->cmd(top, "update");
	return (top, act, img);
}

tkok(t: ref T, top: ref Toplevel, c: string)
{
	e := tk->cmd(top, c);
	if(e != nil && e[0] == '!')
		t.fatal(c + " -> " + e);
}

ptr(top: ref Toplevel, x, y, b: int)
{
	p: Pointer;
	p.xy = (x, y);
	p.buttons = b;
	p.msec = 0;
	tk->pointer(top, p);
}

# Drain the action channel through the app's handler; returns the
# number of b1down actions seen.
handle(top: ref Toplevel, act: chan of string, start: Point): (int, Point)
{
	ndown := 0;
	for(;;) alt {
	a := <-act =>
		(nil, toks) := sys->tokenize(a, " ");
		if(toks == nil)
			continue;
		q := Point(0, 0);
		if(tl toks != nil && tl tl toks != nil)
			q = Point(int hd tl toks, int hd tl tl toks);
		case hd toks {
		"b1down" =>
			ndown++;
			start = q;
			tk->cmd(top, ".top.frac delete zoombox");
			tk->cmd(top, sys->sprint(
				".top.frac create rectangle %d %d %d %d -outline #E8553A -width 2 -tags zoombox",
				q.x, q.y, q.x, q.y));
		"b1drag" =>
			tk->cmd(top, sys->sprint(".top.frac coords zoombox %d %d %d %d",
				start.x, start.y, q.x, q.y));
			tk->cmd(top, "update");
		}
	* =>
		return (ndown, start);
	}
}

# Drag from (50,40) to (250,200) with button 1 held, as a mouse does.
drag(top: ref Toplevel, act: chan of string): (int, Point)
{
	start := Point(-1, -1);
	ndown := 0;
	n: int;
	ptr(top, 50, 40, 0);
	ptr(top, 50, 40, 1);
	(n, start) = handle(top, act, start);
	ndown += n;
	for(i := 1; i <= 10; i++){
		ptr(top, 50 + 20*i, 40 + 16*i, 1);
		(n, start) = handle(top, act, start);
		ndown += n;
	}
	return (ndown, start);
}

pixel(img: ref Image, x, y: int): array of byte
{
	n := (img.depth + 7) / 8;
	buf := array[n] of byte;
	img.readpixels(Rect((x, y), (x+1, y+1)), buf);
	return buf;
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

testBoxGrows(t: ref T)
{
	binds := appbinds();
	if(binds == nil)
		t.fatal("no `bind .top.frac` lines found in " + APPSRC);
	(top, act, img) := mktop(t, binds);

	bg := pixel(img, 150, 200);
	(ndown, start) := drag(top, act);

	t.asserteq(ndown, 1, "b1down fires once per drag, not on every move");
	t.asserteq(start.x, 50, "drag start x stays at the press point");
	t.asserteq(start.y, 40, "drag start y stays at the press point");
	t.assertseq(tk->cmd(top, ".top.frac coords zoombox"), "50 40 250 200",
		"rubber-band spans press point to cursor");

	# The outline is on screen: a point on its left edge, which was
	# background before the drag, is now painted.
	t.assert(!same(pixel(img, 50, 120), bg), "box outline drawn on the window image");
	# ...and the interior is untouched (outline only).
	t.assert(same(pixel(img, 150, 120), bg), "box interior not filled");
}

# Pins the cause: plain <Motion> alone lets <Button-1> fire on every
# drag move.  If Tk's matching ever changes this, the comment in
# fractals.b needs revisiting.
testPlainMotionBreaks(t: ref T)
{
	binds := "bind .top.frac <Button-1> {send act b1down %x %y}" ::
		"bind .top.frac <Motion> {send act b1drag %x %y}" :: nil;
	(top, act, nil) := mktop(t, binds);
	(ndown, nil) := drag(top, act);
	t.assert(ndown > 1, sys->sprint("plain <Motion>: b1down fired %d times", ndown));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	display = Display.allocate("");
	if(display == nil){
		t := testing->newTsrc("Display", SRCFILE);
		{ t.skip("no display available"); } exception { * => ; }
		testing->done(t);
		skipped++;
	} else {
		run("BoxGrows", testBoxGrows);
		run("PlainMotionBreaks", testPlainMotionBreaks);
	}
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

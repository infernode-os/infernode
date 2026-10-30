implement IconTest;

#
# icon_test - the interface's glyphs (module/icon.m): every glyph
# icons/ui/LIST names is drawn at 16, 24, 32 and 48 pixels, some of it
# covered and not all; a glyph's coverage grows with the area (its
# stroke scales: the root's width and height are set, not its
# stroke-width); a glyph drawn once is kept; a name that is a path, or
# no glyph, is refused; a painted glyph is the colour asked for, drawn
# through its mask; a Tk image made from a glyph is its size, and made
# again in another colour keeps its name.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Chans: import draw;

include "tk.m";
	tk: Tk;

include "testing.m";
	testing: Testing;
	T: import testing;

include "icon.m";
	icon: Icon;

IconTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/icon_test.b";

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

# the coverage of a GREY8 mask: (pixels with any, the sum of all)
coverage(m: ref Image): (int, int)
{
	n := m.r.dx() * m.r.dy();
	buf := array[n] of byte;
	m.readpixels(m.r, buf);
	some := 0;
	sum := 0;
	for(i := 0; i < n; i++){
		if(buf[i] != byte 0)
			some++;
		sum += int buf[i];
	}
	return (some, sum);
}

pixel(m: ref Image, x, y: int): int
{
	buf := array[1] of byte;
	m.readpixels(Rect((x, y), (x+1, y+1)), buf);
	return int buf[0];
}

listed(): list of string
{
	fd := sys->open(Icon->DIR + "/LIST", Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	names: list of string;
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		for(i := 0; i < len l; i++)
			if(l[i] == '#'){
				l = l[0:i];
				break;
			}
		(nil, w) := sys->tokenize(l, " \t");
		if(w != nil)
			names = hd w :: names;
	}
	return names;
}

testEveryGlyph(t: ref T)
{
	names := listed();
	t.assert(len names >= 40, sys->sprint("LIST names %d glyphs", len names));
	sizes := array[] of {16, 24, 32, 48};
	for(; names != nil; names = tl names){
		for(k := 0; k < len sizes; k++){
			sz := sizes[k];
			(m, err) := icon->mask(hd names, sz);
			if(m == nil){
				t.error(sys->sprint("%s at %d: %s", hd names, sz, err));
				continue;
			}
			t.asserteq(m.r.dx(), sz, hd names + " width");
			t.asserteq(m.r.dy(), sz, hd names + " height");
			t.assert(m.chans.eq(Draw->GREY8), hd names + " mask is GREY8");
			(some, nil) := coverage(m);
			if(some == 0 || some == sz*sz)
				t.error(sys->sprint("%s at %d: %d of %d pixels covered", hd names, sz, some, sz*sz));
		}
	}
}

testScales(t: ref T)
{
	(m24, e24) := icon->mask("folder", 24);
	(m48, e48) := icon->mask("folder", 48);
	if(m24 == nil || m48 == nil)
		t.fatal("folder: " + e24 + e48);
	# the folder's top edge, M5 4h4: on the stroke at both sizes, the
	# corner off it
	t.assert(pixel(m24, 7, 4) > 128, sys->sprint("24: (7,4) covered (%d)", pixel(m24, 7, 4)));
	t.assert(pixel(m48, 14, 8) > 128, sys->sprint("48: (14,8) covered (%d)", pixel(m48, 14, 8)));
	t.asserteq(pixel(m24, 0, 0), 0, "24: the corner is clear");
	t.asserteq(pixel(m48, 0, 0), 0, "48: the corner is clear");
	(nil, s24) := coverage(m24);
	(nil, s48) := coverage(m48);
	r := real s48 / real s24;
	t.assert(r > 3.0 && r < 5.0, sys->sprint("coverage grows with the area: 48/24 is %g, want about 4", r));
}

testKept(t: ref T)
{
	(a, nil) := icon->mask("file", 32);
	(b, nil) := icon->mask("file", 32);
	(c, nil) := icon->mask("file", 16);
	t.assert(a != nil && a == b, "a glyph drawn again at a size is the one kept");
	t.assert(c != nil && c != a, "at another size it is drawn again");
}

testRefused(t: ref T)
{
	(m, err) := icon->mask("../LIST", 24);
	t.assert(m == nil, "a name with a / is refused");
	t.assertnotnil(err, "and says why");
	(m, err) = icon->mask("no-such-glyph", 24);
	t.assert(m == nil, "a glyph that is not there is refused");
	t.assertnotnil(err, "and says why");
	(m, err) = icon->mask("folder", 0);
	t.assert(m == nil, "size 0 is refused");
}

testPaint(t: ref T)
{
	colour := int 16rE8553AFF;	# Brimstone's accent
	(i, m, err) := icon->paint("folder", 24, colour);
	if(i == nil)
		t.fatal("paint: " + err);
	t.asserteq(i.r.dx(), 24, "painted width");
	dst := display.newimage(Rect((0, 0), (24, 24)), Draw->RGB24, 0, Draw->Black);
	dst.draw(dst.r, i, m, Point(0, 0));
	buf := array[3] of byte;
	dst.readpixels(Rect((7, 4), (8, 5)), buf);	# RGB24 is b g r
	t.assert(int buf[2] > 16rC0 && int buf[1] > 16r40 && int buf[1] < 16r70 && int buf[0] < 16r50,
		sys->sprint("on the stroke it is the colour: %02x%02x%02x", int buf[2], int buf[1], int buf[0]));
	dst.readpixels(Rect((0, 0), (1, 1)), buf);
	t.assert(buf[0] == byte 0 && buf[1] == byte 0 && buf[2] == byte 0, "off it, what was there");
}

testTkimage(t: ref T)
{
	tk = load Tk Tk->PATH;
	top := tk->toplevel(display, "");
	if(top == nil)
		t.fatal("no toplevel");
	err := icon->tkimage(top, "Folder", "folder", 32, int 16rCCCCCCFF);
	t.assertnil(err, "tkimage made");
	t.assertseq(tk->cmd(top, "image width Folder"), "32", "Tk image width");
	t.assertseq(tk->cmd(top, "image height Folder"), "32", "Tk image height");
	err = icon->tkimage(top, "Folder", "folder", 32, int 16r2266CCFF);
	t.assertnil(err, "tkimage made again in another colour");
	t.assertseq(tk->cmd(top, "image names"), "Folder", "still one image, by the same name");
	t.assertseq(tk->cmd(top, "label .l -image Folder"), ".l", "a label shows it");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	display = Display.allocate(nil);
	if(display == nil){
		sys->fprint(sys->fildes(2), "icon_test: no draw device: %r: skipped\n");
		testing->summary(0, 0, 1);
		return;
	}
	icon = load Icon Icon->PATH;
	if(icon == nil){
		sys->fprint(sys->fildes(2), "icon_test: cannot load %s: %r\n", Icon->PATH);
		raise "fail:load";
	}
	err := icon->init(display);
	if(err != nil){
		sys->fprint(sys->fildes(2), "icon_test: %s\n", err);
		raise "fail:init";
	}

	run("EveryGlyph", testEveryGlyph);
	run("Scales", testScales);
	run("Kept", testKept);
	run("Refused", testRefused);
	run("Paint", testPaint);
	run("Tkimage", testTkimage);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

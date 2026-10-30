implement TkTest;

#
# tk_test.b — regression tests for the reintegrated Tk engine.
#
# Tk was disabled on the shipping platforms while the native widget
# toolkit was in use; these tests guard the bring-up:
#   - the $Tk builtin loads and a toplevel can be created off-screen
#     (no window manager) on the in-memory headless display;
#   - top.screenr reports the real display rectangle (the C<->Limbo
#     Toplevel ABI, which an earlier attempt had papered over with a
#     coordinate band-aid);
#   - every widget type the apps rely on can be created;
#   - the brutalist default palette resolves to the Brimstone colours
#     and colour values round-trip cleanly through cget (no 64-bit
#     sign-extension, no <<-vs-& macro mangling);
#   - explicit per-widget colours are honoured;
#   - glyphs take the foreground colour: an anti-aliased (k8) font drawn
#     through libmemdraw's coverdraw came out black whatever the colour
#     when built with gcc, so dark themes were unreadable;
#   - two presses of a button, soon after and near each other, are a
#     double click: only the X11 driver marked one, so on SDL hosts no
#     <Double-Button-1> binding fired (wm/dir opened nothing).
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Rect, Chans: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "testing.m";
	testing: Testing;
	T: import testing;

TkTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tk_test.b";

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
	"fail:fatal" =>	;
	"fail:skip" =>	;
	* =>		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# A fresh off-screen toplevel for a test, or nil with the test skipped
# if no display is available (e.g. a build without devdraw).
newtop(t: ref T): ref Toplevel
{
	if(display == nil){
		t.skip("no display available");
		return nil;
	}
	top := tk->toplevel(display, "");
	if(top == nil)
		t.fatal(sys->sprint("tk->toplevel failed: %r"));
	return top;
}

# ── Tests ──────────────────────────────────────────────────────

# a press and release of button 1 at x y, the press at msec
click(top: ref Toplevel, x, y, msec: int)
{
	tk->pointer(top, Draw->Pointer(1, (x, y), msec));
	tk->pointer(top, Draw->Pointer(0, (x, y), msec + 10));
}

# what the label's bindings sent since the last call
heard(c: chan of string): string
{
	s := "";
	for(;;) alt {
	e := <-c =>
		s += e + " ";
	* =>
		return s;
	}
}

testDoubleClick(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	c := chan[16] of string;
	tk->namechan(top, c, "c");
	# mapped, as onscreen does, or pointer events find no widget
	tk->cmd(top, "label .l -width 200 -height 100 -text x; pack .l; . map; update");
	tk->cmd(top, "bind .l <Double-Button-1> {send c double}");
	tk->cmd(top, "bind .l <ButtonRelease-1> {send c up}");
	heard(c);
	click(top, 20, 20, 1000);
	click(top, 21, 20, 1150);
	t.assertseq(heard(c), "up double up ", "two clicks 150ms apart: the second a double");
	click(top, 20, 20, 3000);
	click(top, 20, 20, 3500);
	t.assertseq(heard(c), "up up ", "500ms apart: no double");
	click(top, 20, 20, 5000);
	click(top, 80, 60, 5100);
	t.assertseq(heard(c), "up up ", "far apart: no double");
	click(top, 20, 20, 0);
	click(top, 20, 20, 0);
	t.assertseq(heard(c), "up up ", "no time stamps: no double");
	tk->pointer(top, Draw->Pointer(1|(1<<8), (20, 20), 9000));
	tk->pointer(top, Draw->Pointer(0, (20, 20), 9010));
	t.assertseq(heard(c), "double up ", "a press X11 marked double (bit 8) still is one");
}

testToplevel(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	# screenr must mirror the display image rectangle — this is the
	# field the screenr band-aid used to fake.
	r := top.screenr;
	di := display.image.r;
	t.asserteq(r.min.x, di.min.x, "screenr.min.x");
	t.asserteq(r.min.y, di.min.y, "screenr.min.y");
	t.asserteq(r.max.x, di.max.x, "screenr.max.x");
	t.asserteq(r.max.y, di.max.y, "screenr.max.y");
	t.assert(r.dx() > 0 && r.dy() > 0, "screenr is non-empty");
}

testWidgetTypes(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	# Every widget type the apps need must create without error.  Tk
	# returns the widget path on success and a "!..." message on error.
	specs := array[] of {
		"frame .f",
		"label .f.l -text Hi",
		"button .f.b -text Go",
		"entry .f.e",
		"checkbutton .f.c -text On",
		"radiobutton .f.r -text A",
		"scrollbar .f.s",
		"listbox .f.lb",
		"menu .m",
	};
	for(i := 0; i < len specs; i++){
		e := tk->cmd(top, specs[i]);
		t.assert(e != nil && len e > 0 && e[0] != '!',
			sys->sprint("create %q -> %q", specs[i], e));
	}
}

testDefaultPalette(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	tk->cmd(top, "label .l -text Hi");
	# Bare widgets inherit the brutalist Brimstone defaults.  cget must
	# return clean 8-hex-digit colours (regression for both the macro
	# precedence bug and the 64-bit sign-extension).
	t.assertseq(tk->cmd(top, ".l cget -background"), "#080808ff",
		"default background is Brimstone bg");
	t.assertseq(tk->cmd(top, ".l cget -foreground"), "#ccccccff",
		"default foreground is Brimstone text");
}

testExplicitColour(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	# An explicit colour with the red byte's top bit set used to
	# sign-extend; it must now round-trip cleanly.
	tk->cmd(top, "label .l -text Hi -foreground #E8553A -background #12ABCD");
	t.assertseq(tk->cmd(top, ".l cget -foreground"), "#e8553aff",
		"explicit accent foreground round-trips");
	t.assertseq(tk->cmd(top, ".l cget -background"), "#12abcdff",
		"explicit background round-trips");
}

testGeometry(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	tk->cmd(top, "frame .f");
	tk->cmd(top, "button .f.b -text {Click me}");
	tk->cmd(top, "pack .f.b");
	tk->cmd(top, "pack .f");
	tk->cmd(top, "update");
	aw := int tk->cmd(top, ".f.b cget -actwidth");
	ah := int tk->cmd(top, ".f.b cget -actheight");
	t.assert(aw > 0, sys->sprint("button actwidth > 0 (got %d)", aw));
	t.assert(ah > 0, sys->sprint("button actheight > 0 (got %d)", ah));
}

# Forms are driven headlessly in the migrated apps' tests, so make sure
# the input path works: typed keys reach the focused entry.
testEntryInput(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	tk->cmd(top, "entry .e -width 20");
	tk->cmd(top, "pack .e");
	tk->cmd(top, "focus .e");
	tk->cmd(top, "update");
	s := "hello";
	for(i := 0; i < len s; i++)
		tk->keyboard(top, s[i]);
	tk->cmd(top, "update");
	t.assertseq(tk->cmd(top, ".e get"), "hello", "typed text reaches entry");
}

# A button's -command fires on invoke (how the app tests click actions).
testButtonInvoke(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	tk->cmd(top, "entry .e");
	tk->cmd(top, ".e insert end {x}");
	tk->cmd(top, "button .b -text Go -command {.e delete 0 end}");
	tk->cmd(top, ".b invoke");
	t.assertseq(tk->cmd(top, ".e get"), "", "button command cleared the entry");
}

testListbox(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	tk->cmd(top, "listbox .lb");
	tk->cmd(top, ".lb insert end {alpha} {beta} {gamma}");
	t.assertseq(tk->cmd(top, ".lb size"), "3", "listbox size");
	tk->cmd(top, ".lb selection set 1");
	t.assertseq(tk->cmd(top, ".lb curselection"), "1", "listbox selection");
	t.assertseq(tk->cmd(top, ".lb get 1"), "beta", "listbox get selected");
}

testToggles(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	# checkbutton drives its -variable
	tk->cmd(top, "variable ckv 0");
	tk->cmd(top, "checkbutton .ck -text On -variable ckv");
	tk->cmd(top, ".ck invoke");
	t.assertseq(tk->cmd(top, "variable ckv"), "1", "checkbutton sets variable");
	# radiobutton group shares one -variable, set to the chosen -value
	tk->cmd(top, "variable rgv {}");
	tk->cmd(top, "radiobutton .r1 -text A -variable rgv -value a");
	tk->cmd(top, "radiobutton .r2 -text B -variable rgv -value b");
	tk->cmd(top, ".r2 invoke");
	t.assertseq(tk->cmd(top, "variable rgv"), "b", "radiobutton sets group variable");
}

# The text widget is the editing surface the editor and shell migrations
# rely on as a view of their document/transcript model: typed keys insert
# at the insert mark, content round-trips through get, the cursor is
# addressable by index, ranges delete, and the sel tag drives selection.
# This guards that path (libtk text widget editing) against regression.
testTextEdit(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	tk->cmd(top, "text .t -wrap none");
	tk->cmd(top, "pack .t");
	tk->cmd(top, ".t insert end " + tk->quote("alpha\nbeta"));
	# whole-buffer round-trip. Note: unlike Tcl/Tk, this text widget does
	# not append an implicit trailing newline, so "1.0 end" is exact.
	t.assertseq(tk->cmd(top, ".t get 1.0 end"), "alpha\nbeta",
		"text round-trips through get");

	# typed keys reach the focused widget at the insert mark
	tk->cmd(top, ".t mark set insert {1.0 lineend}");
	tk->cmd(top, "focus .t");
	tk->cmd(top, "update");
	s := "XY";
	for(i := 0; i < len s; i++)
		tk->keyboard(top, s[i]);
	t.assertseq(tk->cmd(top, ".t get 1.0 {1.0 lineend}"), "alphaXY",
		"typed keys insert at the cursor");
	t.assertseq(tk->cmd(top, ".t index insert"), "1.7", "insert mark advances");

	# delete a range by index
	tk->cmd(top, ".t delete {1.0 + 5 chars} {1.0 + 7 chars}");
	t.assertseq(tk->cmd(top, ".t get 1.0 {1.0 lineend}"), "alpha",
		"range delete removes the typed chars");

	# selection via the sel tag
	tk->cmd(top, ".t tag add sel 2.0 {2.0 + 4 chars}");
	t.assertseq(tk->cmd(top, ".t get sel.first sel.last"), "beta",
		"sel tag selects the range");
}

# A label bound to a named bitmap image that is later filled with
# tk->putimage must pick up the new image's size and contents.  libtk
# had no Tk_ImageChanged-style notification, so the label kept its
# zero-size geometry from when the image was empty and rendered blank.
# This is the display path the dynamic-image apps (wm/fractals) rely on.
testDynamicImage(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	# bitmap image created empty, label bound to it before any content,
	# exactly as wm/fractals buildui() does.
	tk->cmd(top, "image create bitmap dyn");
	tk->cmd(top, "label .l -image dyn -borderwidth 0");
	tk->cmd(top, "pack .l");
	tk->cmd(top, "update");
	# while the image is empty the label has no image extent
	t.asserteq(int tk->cmd(top, ".l cget -actwidth"), 0,
		"label is zero-width before putimage");

	# build a 64x48 off-screen image and composite it in
	IW: con 64;
	IH: con 48;
	ir: Rect;
	ir.min = (0, 0);
	ir.max = (IW, IH);
	img := display.newimage(ir, display.image.chans, 0, Draw->Nofill);
	if(img == nil){
		t.fatal(sys->sprint("newimage failed: %r"));
		return;
	}
	img.draw(img.r, display.color(int 16rE8553AFF), nil, (0, 0));
	e := tk->putimage(top, "dyn", img, nil);
	t.assertnil(e, sys->sprint("putimage error: %q", e));
	tk->cmd(top, "update");

	# the label must now have grown to the image's size (plus the small
	# bitmap padding libtk adds), proving the change notification fired.
	aw := int tk->cmd(top, ".l cget -actwidth");
	ah := int tk->cmd(top, ".l cget -actheight");
	t.assert(aw >= IW, sys->sprint("label actwidth tracks image (got %d, want >= %d)", aw, IW));
	t.assert(ah >= IH, sys->sprint("label actheight tracks image (got %d, want >= %d)", ah, IH));
}


# ── Glyph colour ───────────────────────────────────────────────
#
# The Tk default face is DejaVu, whose subfonts are k8: 8-bit coverage,
# drawn S over D through a GREY8 mask (libmemdraw's coverdraw).  With
# bg under fg, a pixel of coverage c is c*fg + (1-c)*bg, so each channel
# of every glyph pixel lies between bg's and fg's, and the stems of an
# H, fully covered, are fg exactly.

AAFONT: con "/fonts/combined/unicode.sans.14.font";
GLYPHBG: con 16r0D0D0D;		# brimstone editbg

# Every glyph pixel (a pixel that is not bg) of img, as (r, g, b).
glyphpixels(t: ref T, img: ref Image): list of (int, int, int)
{
	nb: int;
	if(img.chans.eq(Draw->XRGB32))
		nb = 4;
	else if(img.chans.eq(Draw->RGB24))
		nb = 3;
	else{
		t.fatal(sys->sprint("glyphpixels: unexpected chans %s", img.chans.text()));
		return nil;
	}
	buf := array[img.r.dx()*img.r.dy()*nb] of byte;
	n := img.readpixels(img.r, buf);
	if(n != len buf){
		t.fatal(sys->sprint("readpixels: %d bytes, want %d: %r", n, len buf));
		return nil;
	}
	px: list of (int, int, int);
	bgr := (GLYPHBG>>16) & 16rFF;
	bgg := (GLYPHBG>>8) & 16rFF;
	bgb := GLYPHBG & 16rFF;
	# both layouts are little-endian: blue, green, red (, ignored)
	for(i := 0; i+nb <= n; i += nb){
		(r, g, b) := (int buf[i+2], int buf[i+1], int buf[i]);
		if(r != bgr || g != bgg || b != bgb)
			px = (r, g, b) :: px;
	}
	return px;
}

between(v, a, b: int): int
{
	if(a > b)
		(a, b) = (b, a);
	return v >= a && v <= b;
}

# Assert every glyph pixel of img blends bg towards fg, and some are fg.
assertglyphcolour(t: ref T, img: ref Image, fg: int, what: string)
{
	fr := (fg>>16) & 16rFF;
	fgg := (fg>>8) & 16rFF;
	fb := fg & 16rFF;
	br := (GLYPHBG>>16) & 16rFF;
	bg := (GLYPHBG>>8) & 16rFF;
	bb := GLYPHBG & 16rFF;
	px := glyphpixels(t, img);
	t.assert(len px > 0, what+": no glyph pixels drawn");
	full := 0;
	bad := 0;
	first := "";
	for(; px != nil; px = tl px){
		(r, g, b) := hd px;
		if(r == fr && g == fgg && b == fb)
			full++;
		if(!between(r, br, fr) || !between(g, bg, fgg) || !between(b, bb, fb)){
			if(bad++ == 0)
				first = sys->sprint("#%.2x%.2x%.2x", r, g, b);
		}
	}
	t.assert(bad == 0, sys->sprint("%s: %d glyph pixels not between bg #%.6x and fg #%.6x (first %s)",
		what, bad, GLYPHBG, fg, first));
	t.assert(full > 0, sys->sprint("%s: no glyph pixel is the foreground #%.6x", what, fg));
}

# Image.text in a colour, through an anti-aliased font, onto both
# 8-bit-channel layouts coverdraw handles.
testGlyphColour(t: ref T)
{
	if(display == nil){
		t.skip("no display available");
		return;
	}
	font := Font.open(display, AAFONT);
	if(font == nil){
		t.skip(sys->sprint("cannot open %s: %r", AAFONT));
		return;
	}
	chans := array[] of {Draw->XRGB32, Draw->RGB24};
	fgs := array[] of {16rCCCCCC, 16rE8553A};	# brimstone edittext, an accent
	for(c := 0; c < len chans; c++){
		for(f := 0; f < len fgs; f++){
			img := display.newimage(Rect((0, 0), (80, 24)), chans[c], 0, (GLYPHBG<<8)|16rFF);
			if(img == nil){
				t.fatal(sys->sprint("newimage %s: %r", chans[c].text()));
				return;
			}
			img.text((2, 2), display.color((fgs[f]<<8)|16rFF), (0, 0), font, "HHHH");
			assertglyphcolour(t, img, fgs[f],
				sys->sprint("text #%.6x on %s", fgs[f], chans[c].text()));
		}
	}
}

# The report: text and label widgets on a dark background, -fg honoured.
testForegroundRendered(t: ref T)
{
	top := newtop(t);
	if(top == nil)
		return;
	if(Font.open(display, AAFONT) == nil){
		t.skip(sys->sprint("cannot open %s: %r", AAFONT));
		return;
	}
	W: con 200;
	H: con 70;
	cmds := array[] of {
		sys->sprint(". configure -background #%.6x", GLYPHBG),
		sys->sprint("text .t -width 190 -height 24 -borderwidth 0 -highlightthickness 0 -background #%.6x -foreground #cccccc", GLYPHBG),
		sys->sprint("label .l -text HHHH -borderwidth 0 -background #%.6x -foreground #cccccc", GLYPHBG),
		"pack .t .l",
		".t insert end HHHH",
		sys->sprint(". configure -width %d -height %d", W, H),
		"update",
	};
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		t.assert(e == nil || e[0] != '!', sys->sprint("%q -> %q", cmds[i], e));
	}
	img := display.newimage(Rect((0, 0), (W, H)), Draw->XRGB32, 0, (GLYPHBG<<8)|16rFF);
	if(img == nil){
		t.fatal(sys->sprint("newimage: %r"));
		return;
	}
	e := tk->putimage(top, ". -1", img, nil);
	t.assertnil(e, sys->sprint("putimage error: %q", e));
	tk->cmd(top, "update");
	assertglyphcolour(t, img, 16rCCCCCC, "text and label -foreground #cccccc");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	if(tk == nil){
		sys->fprint(sys->fildes(2), "cannot load Tk ($Tk not built in?): %r\n");
		raise "fail:cannot load Tk";
	}

	# An off-screen display backed by the in-memory headless screen.
	# If devdraw is unavailable the per-test newtop() skips cleanly.
	display = Display.allocate("");

	run("Toplevel",        testToplevel);
	run("WidgetTypes",     testWidgetTypes);
	run("DefaultPalette",  testDefaultPalette);
	run("ExplicitColour",  testExplicitColour);
	run("Geometry",        testGeometry);
	run("EntryInput",      testEntryInput);
	run("ButtonInvoke",    testButtonInvoke);
	run("Listbox",         testListbox);
	run("Toggles",         testToggles);
	run("TextEdit",        testTextEdit);
	run("DynamicImage",    testDynamicImage);
	run("GlyphColour",     testGlyphColour);
	run("ForegroundRendered", testForegroundRendered);
	run("DoubleClick",     testDoubleClick);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

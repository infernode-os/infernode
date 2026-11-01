implement TkEntryGrowthTest;

#
# A key held down in a password field, as on the bench 3B+: something
# rested on the keyboard under the login screen for two days, the field
# grew to tens of thousands of characters, and the kernel's main pool ran
# out of room with nine tenths of it free -- "arena too large ... alloc =
# 334144", then "out of memory" on every key.
#
# Two things in libtk/entry.c grew with the text on every key:
#   - drawing a -show entry made a buffer of the WHOLE text's length,
#     4*(len+1) bytes, to draw the visible part of it: 334144 bytes is
#     83535 characters;
#   - insert grew the text by realloc to exactly one more character, and
#     delete shrank it to fit.
# Each key asked for a block four bytes bigger than the one just freed,
# which never fits back in the hole, and the pool fragmented until it
# could not grow.
#
# PerKeyCost is the test that tells the old code from the new: a key into
# a field of 200000 characters cost 7 times one into an empty field before
# (270 ms against 34 for 2000 keys), and costs the same now. HeldKey types
# 20000 keys and bounds the main pool's high water; the emulator's pool is
# big enough not to fragment on that, so it passes either way, and is
# there to catch a leak. ShowDrawsAsText checks the drawing: a scrolled,
# selected -show entry must draw exactly as an entry whose text is the
# show rune.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
include "tk.m";
	tk: Tk;
include "testing.m";
	testing: Testing;
	T: import testing;

TkEntryGrowthTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tk_entry_growth_test.b";

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

# main's row of /dev/memory: (in use, high water, arena growths)
mainpool(): (big, big, big)
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return (big -1, big -1, big -1);
	b := array[2048] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return (big -1, big -1, big -1);
	(nil, lines) := sys->tokenize(string b[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " \t");
		# cur max hw nalloc nfree nbrk free name: the name is last
		name := "";
		for(g := f; g != nil; g = tl g)
			name = hd g;
		if(nf >= 7 && name == "main"){
			cur := big hd f;
			hw := big hd tl tl f;
			nbrk := big hd tl tl tl tl tl f;
			return (cur, hw, nbrk);
		}
	}
	return (big -1, big -1, big -1);
}

Keys: con 20000;

testHeldKey(t: ref T)
{
	disp := Display.allocate("");
	if(disp == nil)
		t.skip(sys->sprint("no display: %r"));
	top := tk->toplevel(disp, "");
	for(c := list of {". configure -width 300 -height 40", "entry .e -show •", "pack .e", "focus .e", "update"}; c != nil; c = tl c)
		tk->cmd(top, hd c);
	# no window manager: give the toplevel an image of its own, or
	# nothing is ever drawn (tests/tkrender.b does the same)
	wr: Rect;
	wr.min = (0, 0);
	wr.max = (300, 40);
	tk->putimage(top, ". -1", disp.newimage(wr, disp.image.chans, 0, 16r000000FF), nil);
	tk->cmd(top, "update");
	(cur0, hw0, nbrk0) := mainpool();
	if(cur0 < big 0)
		t.skip("no main pool in /dev/memory");
	for(i := 0; i < Keys; i++){
		tk->cmd(top, ".e insert end x");
		tk->cmd(top, "update");	# draw it, as the screen would
	}
	got := tk->cmd(top, ".e get");
	t.asserteq(len got, Keys, "the entry holds every key typed");
	(cur1, hw1, nbrk1) := mainpool();
	t.log(sys->sprint("main: in use %bd -> %bd, high water %bd -> %bd, arena growths %bd -> %bd",
		cur0, cur1, hw0, hw1, nbrk0, nbrk1));
	# The text is Keys runes, 80 KB, and the string got back a little
	# more: allow a megabyte of high water for all of it, which the old
	# code passed by far (it drew from a whole-text copy every key).
	t.assert(hw1 - hw0 < big (1024*1024),
		sys->sprint("the main pool's high water grew %bd bytes for %d characters typed (%bd -> %bd)", hw1-hw0, Keys, hw0, hw1));
	# and deleting it all gives the room back
	tk->cmd(top, ".e delete 0 end");
	tk->cmd(top, "update");
	t.asserteq(len tk->cmd(top, ".e get"), 0, "the entry is empty after delete 0 end");
}

# a -show entry on its own toplevel, drawn
newentry(t: ref T): ref Tk->Toplevel
{
	disp := Display.allocate("");
	if(disp == nil)
		t.skip(sys->sprint("no display: %r"));
	top := tk->toplevel(disp, "");
	for(c := list of {". configure -width 300 -height 40", "entry .e -show •", "pack .e", "focus .e", "update"}; c != nil; c = tl c)
		tk->cmd(top, hd c);
	wr: Rect;
	wr.min = (0, 0);
	wr.max = (300, 40);
	tk->putimage(top, ". -1", disp.newimage(wr, disp.image.chans, 0, 16r000000FF), nil);
	tk->cmd(top, "update");
	return top;
}

# ms for n keys typed at the end, each drawn
typekeys(top: ref Tk->Toplevel, n: int): int
{
	t0 := sys->millisec();
	for(i := 0; i < n; i++){
		tk->cmd(top, ".e insert end x");
		tk->cmd(top, "update");
	}
	return sys->millisec() - t0;
}

Long: con 200000;
Probe: con 2000;

#
# What a key costs must not grow with what is already in the field: it did,
# a whole-text copy drawn every key, and a held key's cost and memory grew
# without end. Typing into a field of Long characters is measured against
# typing into an empty one.
#
testPerKeyCost(t: ref T)
{
	short := newentry(t);
	typekeys(short, 200);	# warm
	ms0 := typekeys(short, Probe);
	long := newentry(t);
	tk->cmd(long, ".e insert end " + string array[Long] of {* => byte 'x'});
	tk->cmd(long, "update");
	t.asserteq(len tk->cmd(long, ".e get"), Long, "the long field holds what was put in it");
	ms1 := typekeys(long, Probe);
	t.log(sys->sprint("%d keys: %d ms into an empty field, %d ms into one of %d characters", Probe, ms0, ms1, Long));
	if(ms0 < 1)
		ms0 = 1;
	t.assert(ms1 <= 4*ms0 + 50,
		sys->sprint("a key into a field of %d characters cost %d times one into an empty field (%d ms against %d, for %d keys)",
			Long, ms1/ms0, ms1, ms0, Probe));
}

# an entry on a toplevel of its own, drawn, and its image
drawnentry(t: ref T, opts, text: string): (ref Tk->Toplevel, ref Image)
{
	disp := Display.allocate("");
	if(disp == nil)
		t.skip(sys->sprint("no display: %r"));
	top := tk->toplevel(disp, "");
	for(c := list of {". configure -width 200 -height 30", "entry .e" + opts, "pack .e", "update"}; c != nil; c = tl c)
		tk->cmd(top, hd c);
	wr: Rect;
	wr.min = (0, 0);
	wr.max = (200, 30);
	img := disp.newimage(wr, disp.image.chans, 0, 16r000000FF);
	tk->putimage(top, ". -1", img, nil);
	tk->cmd(top, ".e insert end '" + text);
	tk->cmd(top, ".e icursor end");
	tk->cmd(top, ".e xview end");		# scrolled: the start is off to the left
	tk->cmd(top, ".e selection range 300 end-5");	# a selection inside what is shown
	tk->cmd(top, "focus .");		# no cursor, which blinks
	tk->cmd(top, "update");
	return (top, img);
}

#
# A -show entry draws only its visible runes now, from a buffer that
# starts at the first one shown, the selection included: it must look
# exactly like an entry whose text IS the show rune, scrolled and selected
# the same.
#
testShowDrawsAsText(t: ref T)
{
	n := 400;
	xs := string array[n] of {* => byte 'x'};
	dots := "";
	for(i := 0; i < n; i++)
		dots[i] = '•';
	(nil, a) := drawnentry(t, " -show •", xs);
	(nil, b) := drawnentry(t, "", dots);
	r := a.r;
	n0 := r.dx() * r.dy() * 4 + 64;
	pa := array[n0] of byte;
	pb := array[n0] of byte;
	la := a.readpixels(r, pa);
	lb := b.readpixels(r, pb);
	t.assert(la > 0 && la == lb, sys->sprint("pixels read: %d and %d", la, lb));
	same := 1;
	for(i = 0; i < la; i++)
		if(pa[i] != pb[i]){
			same = 0;
			break;
		}
	t.assert(same, sys->sprint("a scrolled, selected -show entry differs from one whose text is the show rune, at byte %d of %d", i, la));
	# and the comparison can see a difference: plain x's are not dots
	(nil, c) := drawnentry(t, "", xs);
	pc := array[n0] of byte;
	lc := c.readpixels(r, pc);
	diff := 0;
	for(i = 0; i < lc && i < lb; i++)
		if(pc[i] != pb[i]){
			diff = 1;
			break;
		}
	t.assert(diff, "an entry of x's draws the same as one of dots: the comparison sees nothing");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	run("HeldKey", testHeldKey);
	run("PerKeyCost", testPerKeyCost);
	run("ShowDrawsAsText", testShowDrawsAsText);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

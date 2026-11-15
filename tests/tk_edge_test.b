implement TkEdgeTest;

#
# $Tk's builtins (libinterp/tk.c, with libtk beneath) given scripts and
# events a program may give them.
#
# A binding is a script, and may destroy the widget it is run for.
# destroy freed the widget there and then, in the middle of delivering
# the event: Tk's pointer entry point, tkdeliver and the widget's own
# code went on using it (and, where the script had allocated since, used
# something else).  A Destroy binding that destroyed its own widget, or
# the next, started again inside itself until the C stack ran out, since
# each binding began the count of nested commands afresh; so did a
# button whose command invokes the button, with no binding at all.  Run
# for a toplevel the collector was sweeping, a Destroy binding's script
# could name what the sweep had already freed.  Each of these ended the
# emulator, or left the toplevel's lock held by an exception.
#
# A widget could be put inside itself: a frame made a window of the
# canvas packed in it, a canvas packed in a frame that is one of its
# windows.  Whatever walked up from a widget to its window then went
# round for ever, holding the VM: every program in the emulator stopped.
#
# A cursor command refused after its -image option kept the image's
# reference, and a toplevel freed with an image so counted was an
# abort().  A cursor image with no bits was read through nil.  A grab
# on .a let events through to .ab.  putimage cut its name argument at
# the blank, in the caller's own string.  A panel's image, replaced, was
# left for the collector.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point, Pointer: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "testing.m";
	testing: Testing;
	T: import testing;

TkEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tk_edge_test.b";

passed := 0;
failed := 0;
skipped := 0;

display: ref Display;

# with test names as arguments, only those are run
only: list of string;

run(name: string, testfn: ref fn(t: ref T))
{
	if(only != nil){
		for(l := only; l != nil; l = tl l)
			if(hd l == name)
				break;
		if(l == nil)
			return;
	}
	t := testing->newTsrc(name, SRCFILE);
	{
		if(display == nil)
			t.skip("no display");
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

# a toplevel of w by h with an image to draw on, as a window manager gives one
mktop(t: ref T, w, h: int): ref Toplevel
{
	top := tk->toplevel(display, "");
	if(top == nil)
		t.fatal(sys->sprint("tk->toplevel: %r"));
	tk->cmd(top, sys->sprint(". configure -width %d -height %d", w, h));
	tk->cmd(top, "update");
	img := display.newimage(Rect((0,0),(w,h)), display.image.chans, 0, Draw->White);
	if(img == nil)
		t.fatal(sys->sprint("newimage: %r"));
	e := tk->putimage(top, ". -1", img, nil);
	if(e != nil)
		t.fatal("putimage: " + e);
	tk->cmd(top, "update");
	return top;
}

# a command that must be taken
cmd(t: ref T, top: ref Toplevel, s: string): string
{
	e := tk->cmd(top, s);
	if(e != nil && e[0] == '!')
		t.error(sys->sprint("tk: %s: %s", s, e));
	return e;
}

ptr(top: ref Toplevel, x, y, b: int)
{
	tk->pointer(top, Pointer(b, Point(x, y), 0));
}

# what has been sent on c
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

# the toplevel still takes commands and events
works(t: ref T, top: ref Toplevel, what: string)
{
	e := tk->cmd(top, "frame .works -width 20 -height 20; pack .works; update");
	t.assert(e == nil || e[0] != '!', what + ": a frame is made and packed: " + e);
	t.assert(tk->rect(top, ".works", 0).dx() > 0, what + ": and has a place");
	ptr(top, 3, 3, 0);
	tk->cmd(top, "destroy .works; update");
	t.assert(tk->cmd(top, ".works cget -width")[0] == '!', what + ": and is destroyed");
}

testDestroyInBinding(t: ref T)
{
	c := chan[64] of string;

	# the wheel
	top := mktop(t, 200, 200);
	tk->namechan(top, c, "c");
	cmd(t, top, "frame .f -width 150 -height 150 -bg red; pack .f");
	cmd(t, top, "bind .f <ButtonPress-4> {destroy .f; send c wheel}");
	cmd(t, top, "bind .f <ButtonRelease-4> {send c wheelup}");
	cmd(t, top, "update");
	ptr(top, 50, 50, 8);
	ptr(top, 50, 50, 0);
	t.assertseq(heard(c), "wheel ", "a wheel binding that destroys its widget is run, and no other for it");
	works(t, top, "after the wheel");

	# button 1: press, motion and release
	top = mktop(t, 200, 200);
	tk->namechan(top, c, "c");
	cmd(t, top, "frame .f -width 150 -height 150 -bg red; pack .f");
	# the script goes on to allocate, in what the widget was
	cmd(t, top, "bind .f <ButtonPress-1> {destroy .f; frame .g -width 150 -height 150; pack .g; " +
		"label .l -text {0123456789012345678901234567890123456789}; send c press}");
	cmd(t, top, "bind .f <ButtonRelease-1> {send c release}");
	cmd(t, top, "bind .f <Button-1-Motion> {send c motion}");
	cmd(t, top, "update");
	ptr(top, 50, 50, 1);
	ptr(top, 60, 60, 1);
	ptr(top, 60, 60, 0);
	ptr(top, 70, 70, 0);
	t.assertseq(heard(c), "press ", "a press binding that destroys its widget, then motion and release");
	t.assert(cmd(t, top, ".g cget -width") == "150", "what the script made is there");
	works(t, top, "after the press");

	# a button's own command
	top = mktop(t, 200, 200);
	tk->namechan(top, c, "c");
	cmd(t, top, "button .b -text {press me} -command {destroy .b; send c gone}; pack .b; update");
	r := tk->rect(top, ".b", 0);
	ptr(top, r.min.x+4, r.min.y+4, 1);
	ptr(top, r.min.x+4, r.min.y+4, 0);
	t.assertseq(heard(c), "gone ", "a button whose command destroys it");
	works(t, top, "after the button");

	# a key
	top = mktop(t, 200, 200);
	tk->namechan(top, c, "c");
	cmd(t, top, "entry .e; pack .e; bind .e <Key> {destroy .e; send c key}; focus .e; update");
	tk->keyboard(top, 'a');
	tk->keyboard(top, 'b');
	t.assertseq(heard(c), "key ", "a key binding that destroys the widget with the focus");
	works(t, top, "after the key");
}

testDestroyOnce(t: ref T)
{
	c := chan[64] of string;

	# a Destroy binding that destroys its own widget
	top := mktop(t, 100, 100);
	tk->namechan(top, c, "c");
	cmd(t, top, "frame .f -width 50 -height 50; pack .f");
	cmd(t, top, "bind .f <Destroy> {send c f; destroy .f}; update");
	cmd(t, top, "destroy .f");
	t.assertseq(heard(c), "f ", "a widget whose Destroy binding destroys it is told once");
	works(t, top, "after it");

	# one that destroys the next, which the same command names
	cmd(t, top, "frame .a; frame .b; frame .d; pack .a .b .d");
	cmd(t, top, "bind .a <Destroy> {send c a; destroy .b}");
	cmd(t, top, "bind .b <Destroy> {send c b; destroy .a .d}");
	cmd(t, top, "bind .d <Destroy> {send c d}");
	cmd(t, top, "destroy .a .b");
	t.assertseq(heard(c), "a b d ", "widgets destroyed from each other's Destroy bindings are each told once");
	t.assert(tk->cmd(top, ".a cget -width")[0] == '!', ".a has gone");
	t.assert(tk->cmd(top, ".b cget -width")[0] == '!', ".b has gone");
	t.assert(tk->cmd(top, ".d cget -width")[0] == '!', ".d has gone");
	works(t, top, "after them");

	# the same, the toplevel dropped
	cmd(t, top, "frame .a; frame .b; pack .a .b");
	cmd(t, top, "bind .a <Destroy> {send c a; destroy .b}");
	cmd(t, top, "bind .b <Destroy> {send c b; destroy .a}");
	top = nil;
	t.assertseq(heard(c), "a b ", "and when the toplevel goes");
}

Nchain: con 300;

testBindingDepth(t: ref T)
{
	top := mktop(t, 100, 100);
	c := chan[Nchain+8] of string;
	tk->namechan(top, c, "c");
	# each widget's Destroy binding destroys the next
	for(k := 0; k < Nchain; k++){
		cmd(t, top, sys->sprint("frame .f%d", k));
		cmd(t, top, sys->sprint("bind .f%d <Destroy> {send c %d; destroy .f%d}", k, k, k+1));
	}
	tk->cmd(top, "destroy .f0");
	n := 0;
count:
	for(;;) alt {
	<-c =>
		n++;
	* =>
		break count;
	}
	t.assert(n >= 4 && n < 32, sys->sprint("bindings one inside another are held to a few: %d ran", n));
	t.assert(tk->cmd(top, ".f0 cget -width")[0] == '!', "the first has gone");
	t.assert(tk->cmd(top, sys->sprint(".f%d cget -width", Nchain-1))[0] != '!', "the last has not");
	# and one at a time they all go
	for(k = 0; k < Nchain; k++)
		tk->cmd(top, sys->sprint("bind .f%d <Destroy> {send c x}", k));
	tk->cmd(top, "destroy .");
	t.assert(tk->cmd(top, sys->sprint(".f%d cget -width", Nchain-1))[0] == '!', "all go when asked one by one");
	works(t, top, "after the chain");
}

testCommandDepth(t: ref T)
{
	# a button whose command invokes it
	top := mktop(t, 100, 100);
	cmd(t, top, "button .b -text x -command {.b invoke}; pack .b; update");
	e := tk->cmd(top, ".b invoke");
	t.assert(e != nil && e[0] == '!', "a command that runs itself is refused when it is too deep: " + e);
	works(t, top, "after it");
	r := tk->rect(top, ".b", 0);
	ptr(top, r.min.x+4, r.min.y+4, 1);
	ptr(top, r.min.x+4, r.min.y+4, 0);
	works(t, top, "after a click on it");

	# a command a few deep is run
	c := chan[4] of string;
	tk->namechan(top, c, "c");
	cmd(t, top, "button .b1 -command {.b2 invoke}; button .b2 -command {.b3 invoke}; button .b3 -command {send c three}");
	t.assertseq(tk->cmd(top, ".b1 invoke"), nil, "three buttons each invoking the next");
	t.assertseq(heard(c), "three ", "reach the third");
}

#
# A toplevel only the collector frees: in a cycle.  An ORCLOSE file in
# a cycle made after it is gone once the collector has swept it.
#
Cyc: adt {
	me:	cyclic ref Cyc;
	top:	ref Toplevel;
	fd:	ref Sys->FD;
};

Junk: adt {
	a, b:	big;
};

churn(stop: chan of int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	ring := array[4096] of ref Junk;
	for(i := 0;; i++){
		ring[i % len ring] = ref Junk(big 16r4141414141414141, big 16r4242424242424242);
		if(i % 256 == 0){
			alt {
			<-stop =>
				return;
			* =>
				sys->sleep(2);
			}
		}
	}
}

swept(t: ref T, what: string)
{
	sys->pctl(Sys->FORKENV, nil);
	p := "/env/tkedgesweep";
	stop := chan of int;
	pidc := chan of int;
	spawn churn(stop, pidc);
	<-pidc;
	for(round := 0; round < 2; round++){
		fd := sys->create(p, Sys->ORDWR|Sys->ORCLOSE, 8r666);
		if(fd == nil){
			stop <-= 1;
			t.fatal(sys->sprint("cannot create %s: %r", p));
		}
		l := ref Cyc(nil, nil, fd);
		l.me = l;
		l = nil;
		fd = nil;
		gone := 0;
		for(k := 0; k < 600 && !gone; k++){
			if(sys->stat(p).t0 < 0)
				gone = 1;
			else
				sys->sleep(100);
		}
		t.assert(gone, sys->sprint("%s: round %d: the collector swept what was dropped", what, round));
	}
	stop <-= 1;
}

# a toplevel with a Destroy binding on ., dropped in a cycle
dropcyclic(t: ref T, first: int, script: string, c: chan of string)
{
	img: ref Image;
	if(first)
		img = display.newimage(Rect((0,0),(100,100)), display.image.chans, 0, Draw->White);
	top := tk->toplevel(display, "");
	if(top == nil)
		t.fatal(sys->sprint("tk->toplevel: %r"));
	if(!first)
		img = display.newimage(Rect((0,0),(100,100)), display.image.chans, 0, Draw->White);
	tk->namechan(top, c, "c");
	tk->cmd(top, ". configure -width 100 -height 100; update");
	tk->putimage(top, ". -1", img, nil);
	tk->cmd(top, "frame .f; pack .f; update");
	img = nil;
	tk->cmd(top, "bind . <Destroy> {" + script + "}");
	tk->cmd(top, "bind .f <Destroy> {" + script + "}");
	x := ref Cyc(nil, top, nil);
	x.me = x;
}

testSweptTop(t: ref T)
{
	c := chan[64] of string;
	# the window's image made before the toplevel and after: either may be swept first
	for(first := 0; first < 2; first++){
		dropcyclic(t, first, "send c swept; destroy .", c);
		dropcyclic(t, first, "send c swept; . unmap", c);
		dropcyclic(t, first, "send c swept; destroy .f", c);
	}
	swept(t, "toplevels in cycles");
	t.assertseq(heard(c), "", "no Destroy binding is run for a toplevel the collector sweeps");
	top := mktop(t, 100, 100);
	works(t, top, "after the sweeps");
}

testCursor(t: ref T)
{
	top := mktop(t, 100, 100);
	t.assertseq(cmd(t, top, "image create bitmap img"), "img", "an image is made with no file");

	# no bits: refused, and the toplevel goes on
	e := tk->cmd(top, "cursor -image img");
	t.assert(e != nil && e[0] == '!', "a cursor image with no bits is refused: " + e);
	works(t, top, "after it");

	# 12 by 16 is not whole bytes across: its bits were sent as 16 bytes for 32
	b := display.newimage(Rect((0,0),(12,16)), Draw->GREY1, 0, Draw->White);
	t.assertseq(tk->putimage(top, "img", b, nil), nil, "it is given 12 by 16 bits");
drain:
	for(;;) alt {	# what was asked of the window manager so far
	<-top.wreq =>
		;
	* =>
		break drain;
	}
	e = tk->cmd(top, "cursor -image img");
	t.assert(e != nil && e[0] == '!', "a cursor 12 pixels wide is refused: " + e);
	b = display.newimage(Rect((0,0),(16,16)), Draw->GREY1, 0, Draw->White);
	t.assertseq(tk->putimage(top, "img", b, nil), nil, "and given 16 by 16");
	t.assertseq(tk->cmd(top, "cursor -image img"), nil, "it is taken");
	req := "";
	alt {
	req = <-top.wreq =>
		;
	* =>
		;
	}
	t.assertseq(req, "cursor 0 0 16 16 ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
		"and the window manager is sent its 32 bytes");

	# an option refused after -image: the image's count is given back
	e = tk->cmd(top, "cursor -image img -nonesuch 1");
	t.assert(e != nil && e[0] == '!', "a cursor command with a bad option is refused: " + e);
	e = tk->cmd(top, "cursor -image img -nonesuch 1");
	t.assert(e != nil && e[0] == '!', "twice: " + e);
	works(t, top, "after them");
	# the toplevel is freed here, and the emulator goes on
	top = nil;
	top = mktop(t, 100, 100);
	works(t, top, "another toplevel, once that one is freed");
}

testGrab(t: ref T)
{
	top := mktop(t, 300, 100);
	c := chan[16] of string;
	tk->namechan(top, c, "c");
	cmd(t, top, "frame .a -width 100 -height 80 -bg red");
	cmd(t, top, "frame .ab -width 100 -height 80 -bg blue");
	cmd(t, top, "frame .a.in -width 50 -height 50 -bg green");
	cmd(t, top, "pack .a .ab -side left; pack .a.in; update");
	cmd(t, top, "bind .ab <ButtonPress-1> {send c ab}");
	cmd(t, top, "bind .a.in <ButtonPress-1> {send c in}");
	cmd(t, top, "bind .a <ButtonPress-1> {send c a}");
	cmd(t, top, "grab set .a");
	r := tk->rect(top, ".ab", 0);
	ptr(top, r.min.x+10, r.min.y+10, 1);
	ptr(top, r.min.x+10, r.min.y+10, 0);
	t.assertseq(heard(c), "a ", "with a grab on .a a press on .ab goes to .a");
	r = tk->rect(top, ".a.in", 0);
	ptr(top, r.min.x+10, r.min.y+10, 1);
	ptr(top, r.min.x+10, r.min.y+10, 0);
	t.assertseq(heard(c), "in ", "and one on .a.in, which is inside it, to .a.in");
	cmd(t, top, "grab release .a");
	r = tk->rect(top, ".ab", 0);
	ptr(top, r.min.x+10, r.min.y+10, 1);
	ptr(top, r.min.x+10, r.min.y+10, 0);
	t.assertseq(heard(c), "ab ", "with no grab .ab has its press");
}

# a command that must be refused
refused(t: ref T, top: ref Toplevel, s: string, what: string)
{
	e := tk->cmd(top, s);
	t.assert(e != nil && e[0] == '!', sys->sprint("%s is refused: %s: %s", what, s, e));
}

testRings(t: ref T)
{
	# a canvas's or text's window that is what the canvas or text is in
	top := mktop(t, 200, 200);
	cmd(t, top, "frame .a; canvas .a.cv; pack .a.cv; update");
	refused(t, top, ".a.cv create window 20 20 -window .a", "the frame a canvas is packed in, as its window");
	cmd(t, top, "pack .a; update");
	works(t, top, "after it");

	top = mktop(t, 200, 200);
	cmd(t, top, "frame .a; frame .a.b; text .a.b.t; pack .a.b.t; pack .a.b; update");
	refused(t, top, ".a.b.t window create end -window .a", "a frame two above a text, as its window");
	cmd(t, top, "pack .a; update");
	works(t, top, "after it");

	# and the other way: packed, or gridded, in what is already its window
	top = mktop(t, 200, 200);
	cmd(t, top, "canvas .cv; frame .a; frame .a.b; pack .a.b");
	cmd(t, top, ".cv create window 20 20 -window .a");
	refused(t, top, "pack .cv -in .a", "a canvas packed in its own window");
	refused(t, top, "pack .cv -in .a.b", "or in a frame inside it");
	cmd(t, top, "pack .cv; update");
	works(t, top, "after it");

	top = mktop(t, 200, 200);
	cmd(t, top, "text .t; frame .a");
	cmd(t, top, ".t window create end -window .a");
	refused(t, top, "grid .t -in .a", "a text gridded in its own window");
	cmd(t, top, "pack .t; update");
	works(t, top, "after it");

	# what is allowed still is
	top = mktop(t, 200, 200);
	cmd(t, top, "frame .a; canvas .a.cv; frame .f; frame .g; pack .a.cv; pack .a");
	t.assert(cmd(t, top, ".a.cv create window 20 20 -window .f") != nil, "a frame that is nowhere is made a canvas's window");
	cmd(t, top, "pack .g -in .f; update");
	t.assert(tk->rect(top, ".g", 0).dx() >= 0, "and another is packed in it");
	works(t, top, "after them");
}

testPutimageName(t: ref T)
{
	top := mktop(t, 100, 100);
	cmd(t, top, "panel .p; pack .p; update");
	img := display.newimage(Rect((0,0),(8,8)), display.image.chans, 0, Draw->White);
	s := ".p 3";
	u := s;
	e := tk->putimage(top, s, img, nil);
	t.assert(e != nil && e[0] == '!', "a panel takes no request number: " + e);
	t.assertseq(s, ".p 3", "the name given to putimage is as it was");
	t.asserteq(s[2], ' ', "its blank a blank");
	t.assertseq(u, ".p 3", "and so is another holder of the string");
	e = tk->putimage(top, ".zz 9", img, nil);
	t.asserteq(".zz 9"[3], ' ', "a literal's blank is a blank after the call");
	t.assertseq(tk->putimage(top, ".p", img, nil), nil, "the panel takes the image by its name alone");
	# the root's image with a request number still goes in
	w := display.newimage(Rect((0,0),(100,100)), display.image.chans, 0, Draw->White);
	t.assertseq(tk->putimage(top, ". -1", w, nil), nil, "and . takes one with a request number");
	works(t, top, "after putimage");
}

# how many Draw->Image cells the heap has, from /dev/heaptypes
nimages(): int
{
	fd := sys->open("/dev/heaptypes", Sys->OREAD);
	if(fd == nil)
		return -1;
	# all of it: the listing has a line for every type in the heap, and
	# in a long-running emulator Image's is far past the first read
	text := "";
	buf := array[16384] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		text += string buf[0:n];
	if(text == "")
		return -1;
	(nil, lines) := sys->tokenize(text, "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf >= 2){
			last := "";
			for(g := f; g != nil; g = tl g)
				last = hd g;
			if(last == "Image")
				return int hd f;
		}
	}
	return 0;
}

testPanelImages(t: ref T)
{
	if(nimages() < 0)
		t.skip("no /dev/heaptypes");
	top := mktop(t, 100, 100);
	cmd(t, top, "panel .p; pack .p; update");
	n0 := nimages();
	imgs := array[50] of ref Image;
	for(k := 0; k < len imgs; k++){
		imgs[k] = display.newimage(Rect((0,0),(8,8)), display.image.chans, 0, Draw->White);
		tk->putimage(top, ".p", imgs[k], nil);	# in place of the one before
	}
	t.asserteq(nimages(), n0+50, "fifty images are made and shown in turn");
	for(k = 0; k < len imgs; k++)
		imgs[k] = nil;
	t.asserteq(nimages(), n0+1, "dropped by the program, only the one the panel shows is left");
	cmd(t, top, "destroy .p");
	t.asserteq(nimages(), n0, "and none once the panel has gone");
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
	if(args != nil)
		args = tl args;
	for(a := args; a != nil; a = tl a){
		if(hd a == "-v")
			testing->verbose(1);
		else
			only = hd a :: only;
	}

	if(tk != nil)
		display = Display.allocate(nil);

	run("DestroyInBinding", testDestroyInBinding);
	run("DestroyOnce", testDestroyOnce);
	run("BindingDepth", testBindingDepth);
	run("CommandDepth", testCommandDepth);
	run("Cursor", testCursor);
	run("Grab", testGrab);
	run("Rings", testRings);
	run("PutimageName", testPutimageName);
	run("PanelImages", testPanelImages);
	run("SweptTop", testSweptTop);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

implement DrawEdgeTest;

#
# $Draw's builtins (libinterp/draw.c, with libdraw beneath) given what a
# program may pass and no picture is.
#
# Image.writepixels took its rectangle as given.  One whose max.x is
# before its min.x has a line of -1 bytes, which was the length of the
# copy into the display's message buffer: the bytes either side of the
# program's array went over the Display's own fields and the block
# before it.  One 256 pixels wide and 2^24 high needs 2^32 bytes, none
# as an int, so sixteen were enough and each line of the image was read
# 256 bytes further past them.  Image.readpixels divided by a line of
# no bytes.  Draw->bytesperline with a depth no image has was libdraw's
# abort(), and the emulator's.
#
# Display.getwindow gave the display's own image a second Draw->Image
# when there was no window to name (dropping it freed the image under
# the Display), made the screen's fill, the display's white, another
# (the same), and given a Screen and Image to attach again handed them
# back holding what it had just freed.  Font.build with no name stored
# the nil; Image.text returned whatever was on the C stack when it drew
# nothing; a public screen's windows were made through its nil image;
# textbg sent the id of another display's image as the background.
#
# On a display that is not the emulator's own (one mounted, here over a
# pipe) a builtin holds the display's lock, and one that raised left it
# held: every other user of the display waited for ever.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point, Font, Screen, Path: import draw;

include "testing.m";
	testing: Testing;
	T: import testing;

DrawEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/draw_edge_test.b";

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

# an image of 100 by 100 grey pixels, all v
grey(t: ref T, d: ref Display, v: int): ref Image
{
	i := d.newimage(Rect((0,0),(100,100)), Draw->GREY8, 0, Draw->Black);
	if(i == nil)
		t.fatal(sys->sprint("newimage: %r"));
	a := array[100*100] of {* => byte v};
	if(i.writepixels(i.r, a) != len a)
		t.fatal(sys->sprint("writepixels of the whole image: %r"));
	return i;
}

# how many of an image's pixels are not v
others(t: ref T, i: ref Image, v: int): int
{
	b := array[100*100] of byte;
	if(i.readpixels(i.r, b) != len b)
		t.fatal(sys->sprint("readpixels of the whole image: %r"));
	n := 0;
	for(k := 0; k < len b; k++)
		if(int b[k] != v)
			n++;
	return n;
}

pixel(i: ref Image, p: Point): int
{
	b := array[1] of byte;
	if(i.readpixels(Rect(p, p.add((1,1))), b) != 1)
		return -1;
	return int b[0];
}

# the display still takes a drawing and gives it back
works(t: ref T, d: ref Display, what: string)
{
	i := grey(t, d, 16r55);
	i.draw(Rect((10,10),(20,20)), d.black, nil, (0,0));
	i.flush(Draw->Flushnow);
	t.asserteq(pixel(i, (15,15)), 0, what + ": a drawing is drawn");
	t.asserteq(pixel(i, (5,5)), 16r55, what + ": and only there");
}

testWriteBackwards(t: ref T)
{
	i := grey(t, display, 16r11);
	# the bytes either side of the slice are the program's
	a := array[4096] of {* => byte 16r41};
	rs := array[] of {
		Rect((1,0),(0,1)),		# max.x before min.x: a line of -1 bytes
		Rect((50,0),(10,1)),
		Rect((0,5),(10,2)),		# max.y before min.y
		Rect((9,9),(3,3)),
	};
	for(k := 0; k < len rs; k++){
		r := rs[k];
		n := i.writepixels(r, a[2048:]);
		t.asserteq(n, -1, sys->sprint("writepixels (%d,%d)-(%d,%d) is refused", r.min.x, r.min.y, r.max.x, r.max.y));
	}
	t.asserteq(others(t, i, 16r11), 0, "the image is as it was");
	works(t, display, "after backwards rectangles");
}

testWriteWrap(t: ref T)
{
	i := grey(t, display, 0);
	a := array[16] of {* => byte 16rEE};
	# bytes in a line times lines is a multiple of 2^32
	for(stride := 256; stride <= 65536; stride *= 16){
		rows := int ((big 1<<32) / big stride);
		n := i.writepixels(Rect((0,0),(stride,rows)), a);
		t.asserteq(n, -1, sys->sprint("%d bytes are not enough for %d by %d", len a, stride, rows));
	}
	# or just past an int
	t.asserteq(i.writepixels(Rect((0,0),(32768,65537)), a), -1, "nor for 32768 by 65537");
	t.asserteq(i.writepixels(Rect((0,-16r40000000),(4,16r40000000)), a), -1, "nor for 2^31 lines");
	# x beyond anything an image has
	t.asserteq(i.writepixels(Rect((16r4000000,0),(16r4000001,1)), a), -1, "x of 2^26 is refused");
	t.asserteq(i.writepixels(Rect((-16r4000000,0),(1,1)), a), -1, "x of -2^26 is refused");
	t.asserteq(others(t, i, 0), 0, "nothing was written to the image");
}

testWriteStill(t: ref T)
{
	i := grey(t, display, 0);
	a := array[10*10] of {* => byte 16r77};
	t.asserteq(i.writepixels(Rect((20,30),(30,40)), a), 100, "a block of ten by ten is written");
	t.asserteq(pixel(i, (20,30)), 16r77, "its first pixel");
	t.asserteq(pixel(i, (29,39)), 16r77, "its last pixel");
	t.asserteq(others(t, i, 0), 100, "and those hundred only");
	t.asserteq(i.writepixels(Rect((20,30),(30,40)), a[1:]), -1, "one byte short is refused");
	t.asserteq(i.writepixels(Rect((5,5),(5,5)), a), 0, "a rectangle of no pixels writes none");
	t.asserteq(i.writepixels(Rect((5,5),(5,9)), a), 0, "nor one of no width");
	t.asserteq(i.writepixels(Rect((5,5),(9,5)), a), 0, "nor one of no height");
	# a rectangle partly off the image: what is on it is written
	b := array[6] of {byte 1, byte 2, byte 3, byte 4, byte 5, byte 6};
	t.asserteq(i.writepixels(Rect((-3,0),(3,1)), b), 3, "three of six pixels are on the image");
	t.asserteq(pixel(i, (0,0)), 4, "the fourth byte is pixel 0");
	t.asserteq(pixel(i, (2,0)), 6, "the sixth is pixel 2");
	t.asserteq(i.writepixels(Rect((200,200),(210,210)), a), 0, "one wholly off it writes nothing");
}

testReadEdges(t: ref T)
{
	i := grey(t, display, 16r33);
	a := array[16] of {* => byte 16rAA};
	t.asserteq(i.readpixels(Rect((0,0),(0,1)), a), 0, "a rectangle of no width reads nothing");
	t.asserteq(i.readpixels(Rect((0,0),(4,0)), a), 0, "nor one of no height");
	t.asserteq(i.readpixels(Rect((2,0),(0,1)), a), -1, "one backwards is refused");
	t.asserteq(i.readpixels(Rect((0,3),(4,1)), a), -1, "either way");
	t.asserteq(int a[0], 16rAA, "and the array is untouched");
	t.asserteq(i.readpixels(Rect((0,0),(4,4)), a), 16, "sixteen pixels are read");
	t.asserteq(int a[15], 16r33, "the image's");
	t.asserteq(i.readpixels(Rect((0,0),(5,4)), a), -1, "twenty do not fit sixteen bytes");
	works(t, display, "after those reads");
}

raised(f: ref fn(): int): string
{
	{
		f();
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

bpl0(): int { return draw->bytesperline(Rect((0,0),(8,8)), 0); }
bplneg(): int { return draw->bytesperline(Rect((0,0),(8,8)), -1); }
bpl33(): int { return draw->bytesperline(Rect((0,0),(8,8)), 33); }
bplbig(): int { return draw->bytesperline(Rect((0,0),(8,8)), 16r40000000); }

testBytesperline(t: ref T)
{
	t.assertseq(raised(bpl0), "invalid argument", "a depth of 0 is refused");
	t.assertseq(raised(bplneg), "invalid argument", "a depth of -1");
	t.assertseq(raised(bpl33), "invalid argument", "a depth of 33");
	t.assertseq(raised(bplbig), "invalid argument", "a depth of 2^30");
	t.asserteq(draw->bytesperline(Rect((0,0),(8,8)), 1), 1, "eight pixels of one bit are a byte");
	t.asserteq(draw->bytesperline(Rect((0,0),(9,8)), 1), 2, "nine are two");
	t.asserteq(draw->bytesperline(Rect((3,0),(100,1)), 32), 388, "97 pixels of 32 bits are 388 bytes");
	t.asserteq(draw->bytesperline(Rect((3,0),(5,1)), 4), 2, "pixels 3 and 4 of 4 bits are in two bytes");
}

testFontBuild(t: ref T)
{
	desc := "10 8\n0 127\t*default*\n";
	f: ref Font;
	{
		f = Font.build(display, nil, desc);
	} exception e {
	"*" =>
		t.fatal("Font.build with no name: " + e);
	}
	t.assert(f != nil, "a font is built with no name");
	if(f != nil){
		t.assert(f.name == nil, "and has none");
		t.assert(f.width("abc") > 0, "its characters have a width");
	}
	f = nil;
	g := Font.build(display, "t4font", desc);
	t.assert(g != nil, "and with a name");
	if(g != nil)
		t.assertseq(g.name, "t4font", "which it keeps");
	# the description is the caller's string, and is not written on
	t.assertseq(desc, "10 8\n0 127\t*default*\n", "the description given is as it was");
	t.asserteq(desc[len desc-1], '\n', "its last byte a newline");
	# one that ends with its last name
	d2 := "12 9\n0 127\t*default*";
	g = Font.build(display, "t4font2", d2);
	t.assert(g != nil, "a description that ends with a name builds a font");
	if(g != nil)
		t.asserteq(g.height, 12, "of the height it says");
	t.assertseq(d2, "12 9\n0 127\t*default*", "and is as it was");
}

testTextNothing(t: ref T)
{
	i := grey(t, display, 16rFF);
	f := Font.open(display, "*default*");
	if(f == nil)
		t.fatal(sys->sprint("no default font: %r"));
	# no source: nothing is drawn, and the text ends where it began
	p := i.text((5,7), nil, (0,0), f, "x");
	t.asserteq(p.x, 5, "text drawing nothing returns its point's x");
	t.asserteq(p.y, 7, "and y");
	p = i.textbg((-9,11), nil, (0,0), f, "x", display.white, (0,0));
	t.asserteq(p.x, -9, "textbg too, x");
	t.asserteq(p.y, 11, "and y");
	p = i.text((3,4), display.black, (0,0), nil, "x");
	t.asserteq(p.x*1000+p.y, 3004, "and text with no font");
	# drawn, it ends past its text
	p = i.text((5,7), display.black, (0,0), f, "x");
	t.assert(p.x > 5 && p.y == 7, "text that is drawn ends to the right of where it began");
}

testTextbgOtherDisplay(t: ref T)
{
	d2 := Display.allocate(nil);
	if(d2 == nil)
		t.fatal(sys->sprint("no second display: %r"));
	# the same images made in the same order on each, so their ids are the same
	a1 := grey(t, display, 16rFF);
	g1 := grey(t, display, 16r40);
	a2 := grey(t, d2, 16rFF);
	b2 := grey(t, d2, 16rC0);
	f := Font.open(display, "*default*");
	if(f == nil)
		t.fatal(sys->sprint("no default font: %r"));
	p := a1.textbg((0,0), display.black, (0,0), f, "MMMM", b2, (0,0));
	t.asserteq(p.x*1000+p.y, 0, "textbg with another display's background draws nothing");
	t.asserteq(others(t, a1, 16rFF), 0, "the image is untouched");
	g1 = nil;
	a2 = nil;
}

# a second Display, and what the collector does with one that is dropped
testGetwindowNoName(t: ref T)
{
	d2 := Display.allocate(nil);
	if(d2 == nil)
		t.fatal(sys->sprint("no second display: %r"));
	(s, w) := d2.getwindow("/no/such/winname", nil, nil, Draw->Refbackup);
	t.assert(s == nil, "with no window to name there is no screen");
	t.assert(w != nil, "and the image is the display's");
	t.assert(w == d2.image, "the Display's own image, not another holding it");
	w = nil;
	d2.image.draw(Rect((0,0),(10,10)), d2.black, nil, (0,0));
	d2.image.flush(Draw->Flushnow);
	works(t, d2, "the display, once the window image is dropped");
	d2 = nil;
}

reattach(d: ref Display, s: ref Screen, w: ref Image): string
{
	{
		d.getwindow("/env/drawedgewin", s, w, Draw->Refnone);
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

testGetwindowNamed(t: ref T)
{
	sys->pctl(Sys->FORKENV, nil);
	d2 := Display.allocate(nil);
	if(d2 == nil)
		t.fatal(sys->sprint("no second display: %r"));
	base := d2.newimage(Rect((0,0),(200,200)), d2.image.chans, 0, Draw->White);
	if(base == nil)
		t.fatal(sys->sprint("newimage: %r"));
	t.asserteq(base.name("drawedgewin", 1), 1, "an image is named");
	fd := sys->create("/env/drawedgewin", Sys->OWRITE, 8r666);
	if(fd == nil)
		t.fatal(sys->sprint("cannot create /env/drawedgewin: %r"));
	sys->fprint(fd, "drawedgewin");
	fd = nil;

	(s, w) := d2.getwindow("/env/drawedgewin", nil, nil, Draw->Refnone);
	t.assert(s != nil && w != nil, "a window is made on the named image");
	if(s == nil || w == nil)
		return;
	t.assert(s.fill == d2.white, "its screen is filled with the Display's own white, not another holding it");
	t.assert(s.image != nil && s.image != base, "and has the named image");
	t.assert(w.screen == s, "the window is on that screen");
	w.draw(w.r, d2.black, nil, (0,0));

	# given the two back, to attach again: refused, and they still work
	t.assertseq(reattach(d2, s, w), "invalid argument", "a Screen and Image to attach again are refused");
	t.assertseq(reattach(d2, nil, w), "invalid argument", "the Image alone");
	t.assertseq(reattach(d2, s, nil), "invalid argument", "the Screen alone");
	w.draw(w.r, d2.white, nil, (0,0));
	nw := s.newwindow(Rect((10,10),(50,50)), Draw->Refnone, Draw->White);
	t.assert(nw != nil, "the screen still makes windows");
	nw = nil;

	s = nil;
	w = nil;
	base = nil;
	# the display's white is still the display's
	works(t, d2, "the display, once the window and screen are dropped");
	i := grey(t, d2, 0);
	i.draw(i.r, d2.white, nil, (0,0));
	t.asserteq(pixel(i, (50,50)), 16rFF, "its white is still white");
	d2 = nil;
}

testPublicScreen(t: ref T)
{
	i := display.newimage(Rect((0,0),(100,100)), display.image.chans, 0, Draw->White);
	if(i == nil)
		t.fatal(sys->sprint("newimage: %r"));
	s := Screen.allocate(i, display.white, 1);
	if(s == nil)
		t.fatal(sys->sprint("Screen.allocate: %r"));
	ps := display.publicscreen(s.id);
	t.assert(ps != nil, "a public screen is found by its id");
	if(ps == nil)
		return;
	w: ref Image;
	{
		w = ps.newwindow(Rect((10,10),(60,60)), Draw->Refbackup, Draw->Red);
	} exception e {
	"*" =>
		t.fatal("newwindow on a public screen: " + e);
	}
	t.assert(w != nil, "a window is made on it");
	if(w != nil)
		t.asserteq(w.chans.desc, display.image.chans.desc, "in the display's channels");
}

testLongName(t: ref T)
{
	i := grey(t, display, 0);
	s := "";
	for(k := 0; k < 30; k++)
		s += "0123456789";
	t.asserteq(i.name(s, 1), 0, "a name of 300 bytes is refused");
	t.asserteq(i.name("drawedgename", 1), 1, "one of twelve taken");
	t.asserteq(i.name("drawedgename", 0), 1, "and given up");
	works(t, display, "after naming");
}

#
# A display that is not the emulator's own: /dev/draw exported over a
# pipe and mounted.  Its lock is real.
#
exporter(fd: ref Sys->FD, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->export(fd, "/dev", Sys->EXPWAIT);
}

remote(t: ref T): ref Display
{
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("#i", "/dev", Sys->MBEFORE) < 0)
		t.skip(sys->sprint("no draw device: %r"));
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	pidc := chan of int;
	spawn exporter(fds[0], pidc);
	<-pidc;
	fds[0] = nil;
	if(sys->mount(fds[1], nil, "/n", Sys->MREPL, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	d := Display.allocate("/n");
	if(d == nil)
		t.fatal(sys->sprint("no display through the mount: %r"));
	return d;
}

worker(d: ref Display, i: ref Image, c: chan of string)
{
	i.draw(Rect((0,0),(5,5)), d.black, nil, (0,0));
	x := d.newimage(Rect((0,0),(4,4)), Draw->GREY8, 0, Draw->White);
	if(x == nil)
		c <-= "newimage failed";
	else
		c <-= "ok";
}

timer(c: chan of string, ms: int)
{
	sys->sleep(ms);
	c <-= "still waiting for the display's lock";
}

# another Prog can use the display
free(d: ref Display, i: ref Image): string
{
	c := chan[2] of string;
	spawn worker(d, i, c);
	spawn timer(c, 3000);
	return <-c;
}

rdi: ref Image;
rdd: ref Display;

rstroke(): int
{
	p := Path.new().moveto(1.0, 1.0).lineto(20.0, 20.0);
	rdi.strokepath(p, 1e30, 0, 0, rdd.black, (0,0));
	return 0;
}
rreadnil(): int { return rdi.readpixels(rdi.r, nil); }
rwritenil(): int { return rdi.writepixels(rdi.r, nil); }
rpolynil(): int { rdi.poly(nil, 0, 0, 0, rdd.black, (0,0)); return 0; }
rfillpolynil(): int { rdi.fillpoly(nil, 0, rdd.black, (0,0)); return 0; }
rbezsplinenil(): int { rdi.bezspline(nil, 0, 0, 0, rdd.black, (0,0)); return 0; }

testRemoteLock(t: ref T)
{
	d := remote(t);
	i := d.newimage(Rect((0,0),(100,100)), Draw->GREY8, 0, Draw->White);
	if(i == nil)
		t.fatal(sys->sprint("newimage on the mounted display: %r"));
	rdd = d;
	rdi = i;
	t.assertseq(free(d, i), "ok", "another Prog uses the mounted display");

	t.assertseq(raised(rstroke), "path coordinate out of range", "a stroke too wide is refused");
	t.assertseq(free(d, i), "ok", "and the display is not left locked");

	t.assertseq(raised(rreadnil), "dereference of nil", "readpixels into nil is refused");
	t.assertseq(free(d, i), "ok", "and the display is not left locked");

	t.assertseq(raised(rwritenil), "dereference of nil", "writepixels from nil");
	t.assertseq(free(d, i), "ok", "and the display is not left locked");

	t.assertseq(raised(rpolynil), "dereference of nil", "poly of nil");
	t.assertseq(raised(rfillpolynil), "dereference of nil", "fillpoly of nil");
	t.assertseq(raised(rbezsplinenil), "dereference of nil", "bezspline of nil");
	t.assertseq(free(d, i), "ok", "and the display is not left locked");

	# what was fixed for the emulator's own display holds through a mount
	a := array[4096] of {* => byte 16r41};
	t.asserteq(i.writepixels(Rect((1,0),(0,1)), a[2048:]), -1, "a backwards rectangle is refused here too");
	t.asserteq(i.readpixels(Rect((0,0),(0,1)), a), 0, "and one of no width reads nothing");
	t.assertseq(free(d, i), "ok", "the display is still not locked");

	rdd = nil;
	rdi = nil;
	i = nil;
	d = nil;
	sys->unmount(nil, "/n");
}

topnil(): int
{
	i := display.newimage(Rect((0,0),(50,50)), display.image.chans, 0, Draw->White);
	s := Screen.allocate(i, display.white, 0);
	s.top(nil);
	return 0;
}

testNilArrays(t: ref T)
{
	rdd = display;
	rdi = grey(t, display, 0);
	t.assertseq(raised(rreadnil), "dereference of nil", "readpixels into nil");
	t.assertseq(raised(rwritenil), "dereference of nil", "writepixels from nil");
	t.assertseq(raised(rpolynil), "dereference of nil", "poly of nil");
	t.assertseq(raised(rfillpolynil), "dereference of nil", "fillpoly of nil");
	t.assertseq(raised(rbezsplinenil), "dereference of nil", "bezspline of nil");
	t.assertseq(raised(topnil), "dereference of nil", "Screen.top of nil");
	rdd = nil;
	rdi = nil;
	works(t, display, "after nil arrays");
}

#
# What the tests above dropped that only the collector frees (a Display
# and its images hold each other): swept, with the emulator going on.
# An ORCLOSE file in a cycle made after them is gone once it has been.
#
FDLoop: adt {
	fd:	ref Sys->FD;
	next:	cyclic ref FDLoop;
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

testSwept(t: ref T)
{
	sys->pctl(Sys->FORKENV, nil);
	p := "/env/drawedgesweep";
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
		l := ref FDLoop(fd, nil);
		l.next = l;
		l = nil;
		fd = nil;
		gone := 0;
		for(k := 0; k < 600 && !gone; k++){
			if(sys->stat(p).t0 < 0)
				gone = 1;
			else
				sys->sleep(100);
		}
		t.assert(gone, sys->sprint("round %d: the collector swept what was dropped", round));
	}
	stop <-= 1;
	works(t, display, "after the collector's sweeps");
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
	if(args != nil)
		args = tl args;
	for(a := args; a != nil; a = tl a){
		if(hd a == "-v")
			testing->verbose(1);
		else
			only = hd a :: only;
	}

	display = Display.allocate(nil);

	run("WriteBackwards", testWriteBackwards);
	run("WriteWrap", testWriteWrap);
	run("WriteStill", testWriteStill);
	run("ReadEdges", testReadEdges);
	run("Bytesperline", testBytesperline);
	run("NilArrays", testNilArrays);
	run("FontBuild", testFontBuild);
	run("TextNothing", testTextNothing);
	run("TextbgOtherDisplay", testTextbgOtherDisplay);
	run("GetwindowNoName", testGetwindowNoName);
	run("GetwindowNamed", testGetwindowNamed);
	run("PublicScreen", testPublicScreen);
	run("LongName", testLongName);
	run("RemoteLock", testRemoteLock);
	run("Swept", testSwept);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

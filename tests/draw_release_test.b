implement DrawReleaseTest;

#
# Drawing lets the VM go while devdraw draws.
#
# A local display's buffer of draw requests was guarded by the Dis VM
# alone, so the write that hands the buffer to /dev/draw was made with
# the VM held: every Prog in the VM waited while devdraw drew all of it.
# On a Pi Zero 2 W drawbench froze its VM for 4.7 s at a time, and the
# card's file server and /tmp, served from the same VM, froze with it
# (a soak's verified TLS handshakes, reading /lib/certs, took 18 s and
# the server hung up).  A remote display was locked by its own lock and
# let the VM go; a local one is now locked the same way.
#
# A ticker sleeps 10 ms at a time and keeps its worst lateness while
# another Prog fills a large image again and again; the worst must stay
# far below what one buffer of fills takes.  Then two Progs draw into
# one display at once, and what they drew must be what each asked for.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;

include "testing.m";
	testing: Testing;
	T: import testing;

DrawReleaseTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/draw_release_test.b";

passed := 0;
failed := 0;
skipped := 0;

display: ref Display;

RUNMS: con 3000;
LIMITMS: con 250;
W: con 800;
H: con 600;

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

ticker(stop: chan of int, res: chan of int)
{
	worst := 0;
	for(;;){
		alt {
		<-stop =>
			res <-= worst;
			return;
		* =>
			t0 := sys->millisec();
			sys->sleep(10);
			late := sys->millisec() - t0 - 10;
			if(late > worst)
				worst = late;
		}
	}
}

# fills of the whole image, alpha-blended so each one costs devdraw
# work, until told to stop; a flush only when the buffer fills
filler(im: ref Image, stop: chan of int, done: chan of int)
{
	src := display.newimage(Rect((0, 0), (1, 1)), Draw->RGBA32, 1, int 16r7F3F1F7F);
	n := 0;
	for(;;){
		alt {
		<-stop =>
			im.flush(Draw->Flushnow);
			done <-= n;
			return;
		* =>
			im.draw(im.r, src, nil, (0, 0));
			n++;
		}
	}
}

testLateness(t: ref T)
{
	im := display.newimage(Rect((0, 0), (W, H)), Draw->XRGB32, 0, Draw->White);
	if(im == nil)
		t.fatal(sys->sprint("newimage: %r"));
	tstop := chan of int;
	tres := chan of int;
	fstop := chan of int;
	fdone := chan of int;
	spawn ticker(tstop, tres);
	spawn filler(im, fstop, fdone);
	sys->sleep(RUNMS);
	fstop <-= 1;
	n := <-fdone;
	tstop <-= 1;
	worst := <-tres;
	t.log(sys->sprint("%d fills of %dx%d in %d ms, worst ticker lateness %d ms", n, W, H, RUNMS, worst));
	t.assert(n > 0, "the filler drew");
	t.assert(worst < LIMITMS, sys->sprint("worst lateness %d ms, want < %d", worst, LIMITMS));
}

# two Progs drawing into one display at once each get what they asked
# for: the display's lock keeps one Prog's requests whole
painter(im: ref Image, colour: int, rounds: int, done: chan of int)
{
	c := display.color(colour);
	for(i := 0; i < rounds; i++){
		im.draw(im.r, c, nil, (0, 0));
		if(i % 7 == 0)
			im.flush(Draw->Flushnow);
	}
	im.flush(Draw->Flushnow);
	done <-= 1;
}

pixel(im: ref Image): int
{
	buf := array[4] of byte;
	if(im.readpixels(Rect((0, 0), (1, 1)), buf) != 4)
		return -1;
	return (int buf[2]<<16) | (int buf[1]<<8) | int buf[0];
}

testTwoProgs(t: ref T)
{
	a := display.newimage(Rect((0, 0), (400, 300)), Draw->XRGB32, 0, Draw->White);
	b := display.newimage(Rect((0, 0), (400, 300)), Draw->XRGB32, 0, Draw->White);
	done := chan of int;
	spawn painter(a, int 16rFF0000FF, 400, done);
	spawn painter(b, int 16r00FF00FF, 400, done);
	<-done;
	<-done;
	t.asserteq(pixel(a), 16rFF0000, "the first Prog's image is its colour");
	t.asserteq(pixel(b), 16r00FF00, "the second Prog's image is its colour");
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
	if(display == nil){
		t := testing->newTsrc("Display", SRCFILE);
		t.log(sys->sprint("no display: %r"));
		skipped++;
		testing->summary(passed, failed, skipped);
		return;
	}

	run("Lateness", testLateness);
	run("TwoProgs", testTwoProgs);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

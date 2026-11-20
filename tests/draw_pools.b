implement DrawPools;

#
# $Draw with a pool full (tests/host/draw_pools_test.sh runs each of
# these in an emulator of its own, with a small heap or image pool: it
# fills it, and the kernel says so).
#
# lock: a builtin that makes a Draw->Image made the display's image
# first and the Limbo cell for it after, with the display locked; with
# the heap full the cell is refused by an exception, which left the
# display locked for good, so every other user of the display waited
# for ever (on a display that is mounted: the emulator's own has no
# lock to keep).
#
# alloc: Display.allocate made the Display's cell and its five images'
# after the display, which it is handed locked.  With room for the first
# and not the rest the program was left a Display whose lock nobody
# would release, and freeing it waited for that lock: in the Prog that
# had it, as its exception unwound.
#
# nofont: a display made when the image pool has no room for the default
# font has none, and closing one that is nil faulted when the display
# was freed, which is the collector's sweep: the emulator exited.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point, Font, Screen: import draw;

DrawPools: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

big4k: list of array of byte;
small: list of array of byte;

# fill the Dis heap: large blocks, then the smallest
fillheap()
{
	{
		for(;;)
			big4k = array[4096] of byte :: big4k;
	} exception {
	"out of memory*" =>
		;
	}
	{
		for(;;)
			small = array[8] of byte :: small;
	} exception {
	"out of memory*" =>
		;
	}
}

exporter(fd: ref Sys->FD, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->export(fd, "/dev", Sys->EXPWAIT);
}

worker(d: ref Display, i: ref Image, c: chan of string)
{
	i.draw(Rect((0,0),(5,5)), d.black, nil, (0,0));
	i.flush(Draw->Flushnow);
	c <-= "ok";
}

timer(c: chan of string, ms: int)
{
	sys->sleep(ms);
	c <-= "waiting";
}

free(d: ref Display, i: ref Image): string
{
	c := chan[2] of string;
	spawn worker(d, i, c);
	spawn timer(c, 5000);
	return <-c;
}

lock()
{
	if(sys->bind("#i", "/dev", Sys->MBEFORE) < 0){
		sys->print("SKIP no draw device: %r\n");
		return;
	}
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0){
		sys->print("FAIL pipe: %r\n");
		return;
	}
	pidc := chan of int;
	spawn exporter(fds[0], pidc);
	<-pidc;
	fds[0] = nil;
	if(sys->mount(fds[1], nil, "/n", Sys->MREPL, nil) < 0){
		sys->print("FAIL mount: %r\n");
		return;
	}
	d := Display.allocate("/n");
	if(d == nil){
		sys->print("FAIL no display through the mount: %r\n");
		return;
	}
	i := d.newimage(Rect((0,0),(100,100)), Draw->GREY8, 0, Draw->White);
	sys->print("BEFORE %s\n", free(d, i));

	# with the heap full each of these is refused its cell; what the
	# collector frees meanwhile is used up by the ones that are not
	fillheap();
	kept: list of ref Image;
	raised := 0;
	for(k := 0; k < 4000 && raised < 4; k++){
		{
			x: ref Image;
			case raised {
			0 =>	x = d.newimage(Rect((0,0),(4,4)), Draw->GREY8, 0, Draw->White);
			1 =>	x = d.color(Draw->Red);
			2 =>	x = d.rgb(1, 2, 3);
			3 =>	x = d.colormix(Draw->Red, Draw->Blue);
			}
			kept = x :: kept;
		} exception e {
		"out of memory*" =>
			raised++;
		"*" =>
			sys->print("FAIL exception %s\n", e);
			k = 4000;
		}
	}
	big4k = nil;
	small = nil;
	kept = nil;
	sys->print("RAISED %d\n", raised);
	sys->print("AFTER %s\n", free(d, i));
}

hung(c: chan of int)
{
	alt {
	<-c =>
		;
	* =>
		sys->sleep(20000);
		alt {
		<-c =>
			;
		* =>
			sys->print("HUNG\n");
			fd := sys->open("/dev/sysctl", Sys->OWRITE);
			sys->fprint(fd, "halt");
		}
	}
}

alloc()
{
	c := chan[1] of int;
	spawn hung(c);
	fillheap();
	# displays until the heap has no room for one (what the collector
	# frees meanwhile is used up by those that are made), then the heap
	# given back a few bytes at a time until one fits: on the way there
	# is room for a Display's cell and not for its images'
	kept: list of ref Display;
	raised := 0;
	half := 0;
	d: ref Display;
	for(k := 0; k < 100000 && !half; k++){
		d = nil;
		{
			d = Display.allocate(nil);
			if(d == nil){
				sys->print("FAIL no display: %r\n");
				break;
			}
			if(raised > 0)
				break;
			kept = d :: kept;
		} exception e {
		"out of memory*" =>
			if(d != nil && (d.image == nil || d.transparent == nil))
				half = 1;	# refused, and the caller has a Display all the same
			raised++;
			if(small != nil)
				small = tl small;
			else if(big4k != nil)
				big4k = tl big4k;
		"*" =>
			sys->print("FAIL exception %s\n", e);
			break;
		}
	}
	big4k = nil;
	small = nil;
	kept = nil;
	c <-= 1;
	sys->print("RAISED %d\n", raised);
	if(half)
		sys->print("MADE half a display\n");
	else if(d != nil){
		i := d.newimage(Rect((0,0),(10,10)), Draw->GREY8, 0, Draw->Black);
		b := array[1] of byte;
		if(d.image == nil || d.black == nil || d.white == nil || d.opaque == nil || d.transparent == nil)
			sys->print("MADE half a display\n");
		else if(i != nil && i.readpixels(Rect((0,0),(1,1)), b) == 1 && b[0] == byte 0)
			sys->print("MADE ok\n");
		else
			sys->print("MADE a display that does not draw: %r\n");
		i = nil;
	}
	# and it is freed, which is the collector's to do
	d = nil;
	if(swept(150))
		sys->print("SWEPT\n");
	else
		sys->print("FAIL the collector did not sweep\n");
}

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

# wait for the collector to sweep what has been dropped: an ORCLOSE
# file in a cycle made after it is gone once it has
swept(tenths: int): int
{
	p := "/env/drawpoolssweep";
	stop := chan of int;
	pidc := chan of int;
	spawn churn(stop, pidc);
	<-pidc;
	ok := 1;
	for(round := 0; round < 2 && ok; round++){
		fd := sys->create(p, Sys->ORDWR|Sys->ORCLOSE, 8r666);
		if(fd == nil){
			ok = 0;
			break;
		}
		l := ref FDLoop(fd, nil);
		l.next = l;
		l = nil;
		fd = nil;
		gone := 0;
		for(k := 0; k < tenths && !gone; k++){
			if(sys->stat(p).t0 < 0)
				gone = 1;
			else
				sys->sleep(100);
		}
		ok = gone;
	}
	stop <-= 1;
	return ok;
}

nofont()
{
	d := Display.allocate(nil);
	if(d == nil){
		sys->print("SKIP no display: %r\n");
		return;
	}
	# fill the image pool: large images, then smaller, down to 32 by 32
	hold: list of ref Image;
	n := 0;
	for(side := 1024; side >= 32; side /= 2){
		for(;;){
			i := d.newimage(Rect((0,0),(side,side)), Draw->GREY8, 0, Draw->Nofill);
			if(i == nil)
				break;
			hold = i :: hold;
			n++;
		}
	}
	sys->print("FILLED %d\n", n);
	d2 := Display.allocate(nil);
	if(d2 == nil){
		sys->print("NODISPLAY\n");
		return;
	}
	f := Font.open(d2, "*default*");
	g: ref Font;
	{
		g = Font.build(d2, "*default*", nil);
	} exception e {
	"*" =>
		sys->print("FAIL Font.build: %s\n", e);
	}
	if(f == nil && g == nil)
		sys->print("FONT none\n");
	else
		sys->print("FONT made\n");
	f = nil;
	g = nil;
	d2 = nil;
	hold = nil;
	if(swept(600))
		sys->print("SWEPT\n");
	else
		sys->print("FAIL the collector did not sweep\n");
	i := d.newimage(Rect((0,0),(10,10)), Draw->GREY8, 0, Draw->Black);
	if(i != nil)
		sys->print("DRAWS\n");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	what := "";
	if(len args > 1)
		what = hd tl args;
	case what {
	"lock" =>
		lock();
	"alloc" =>
		alloc();
	"nofont" =>
		nofont();
	* =>
		sys->print("usage: draw_pools lock|alloc|nofont\n");
	}
	sys->print("DONE\n");
	fd := sys->open("/dev/sysctl", Sys->OWRITE);
	sys->fprint(fd, "halt");
}

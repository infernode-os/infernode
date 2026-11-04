implement CamsrvTest;

#
# camsrv against its simulated sensor: the vid9p schema, the colours
# through $Bayer, frames moving, ctl, and the stream's lifetime.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "bayer.m";

CamsrvTest: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

CamsrvMod: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/camsrv_test.b";
MNT: con "/tmp/camsrv_test";
W: con 288;
H: con 162;
FS: con W*H + 2*(W/2)*(H/2);

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

file(name: string): string
{
	fd := sys->open(MNT + "/0/" + name, Sys->OREAD);
	if(fd == nil)
		return "";
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "";
	return string b[0:n];
}

ctl(s: string): int
{
	fd := sys->open(MNT + "/0/ctl", Sys->OWRITE);
	if(fd == nil)
		return -1;
	return sys->fprint(fd, "%s", s);
}

has(s, t: string): int
{
	for(i := 0; i+len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

readframe(fd: ref Sys->FD, b: array of byte): int
{
	n := 0;
	while(n < len b){
		m := sys->read(fd, b[n:], len b - n);
		if(m <= 0)
			return n;
		n += m;
	}
	return n;
}

testSchema(t: ref T)
{
	t.assertseq(file("fmt"), sys->sprint("%d %d i420 30\n", W, H), "fmt");
	s := file("status");
	t.assert(has(s, "stream=off"), "no reader, no stream: " + s);
	t.assert(!has(s, "pos="), "no pos=: a live sequential source to video-pane");
	t.assert(has(file("ctl"), "focus -1"), "ctl reads back");
}

testFrames(t: ref T)
{
	fd := sys->open(MNT + "/0/frame", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open frame: %r"));
	a := array[FS] of byte;
	b := array[FS] of byte;
	t.asserteq(readframe(fd, a), FS, "a whole frame");
	t.asserteq(readframe(fd, b), FS, "and the next");
	t.assert(has(file("status"), "stream=on"), "a reader, a stream");
	y := a[0:W*H];
	# the first bar is white, the last black, away from the moving band
	row := H-8;
	t.assert(int y[row*W + W/16] > 200, sys->sprint("white bar: %d", int y[row*W + W/16]));
	t.assert(int y[row*W + W - W/16] < 30, sys->sprint("black bar: %d", int y[row*W + W - W/16]));
	# a magenta bar (the fifth) has colour in both planes
	cb := a[W*H:W*H+(W/2)*(H/2)];
	cr := a[W*H+(W/2)*(H/2):];
	o := (H/2-4)*(W/2) + 9*W/32;
	t.assert(int cb[o] > 140 && int cr[o] > 140, sys->sprint("magenta: cb %d cr %d", int cb[o], int cr[o]));
	diff := 0;
	for(i := 0; i < W*H; i++)
		if(a[i] != b[i])
			diff++;
	t.assert(diff > 0, "the band moves between frames");
	t.assert(ctl("mode 144 81") < 0, "a mode is refused while streaming");
	fd = nil;
}

testStop(t: ref T)
{
	sys->sleep(300);
	t.assert(has(file("status"), "stream=off"), "the last close stops the stream: " + file("status"));
}

testCtl(t: ref T)
{
	t.assert(ctl("fps 500") < 0, "fps out of range refused");
	t.assert(ctl("mode 1 1") < 0, "no such mode refused");
	t.assert(ctl("gain 2000") < 0, "gain out of range refused");
	t.assert(ctl("nonsense 1") < 0, "unknown ctl refused");
	t.assert(ctl("focus auto") < 0, "autofocus refused with nothing running");
	t.assert(ctl("focus 700") > 0, "focus taken with nothing running");
	t.assert(has(file("ctl"), "focus 700"), "and reads back");
	t.assert(ctl("mode 144 80") < 0, "a mode that does not divide the sensor refused");
	t.assert(ctl("fps 10") > 0, "fps taken");
	t.assert(has(file("fmt"), " i420 10"), "fmt says so");
}

testRaw(t: ref T)
{
	fd := sys->open(MNT + "/0/raw", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open raw: %r"));
	b := array[1152*648*2] of byte;
	t.asserteq(readframe(fd, b), len b, "raw is the sensor's size");
	# RGGB, white bar: 1023 in every cell at the top left of the frame's bottom
	o := (640*1152 + 8)*2;
	t.asserteq(int b[o] | int b[o+1]<<8, 1023, "a raw sample of the white bar");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if((bay := load Bayer Bayer->PATH) == nil){
		run("Loads", skipit);
	}else{
		sys->create("/tmp", Sys->OREAD, Sys->DMDIR|8r777);
		sys->create(MNT, Sys->OREAD, Sys->DMDIR|8r777);
		p := array[2] of ref Sys->FD;
		sys->pipe(p);
		spawn server(p[1]);
		if(sys->mount(p[0], nil, MNT, Sys->MREPL, "") < 0)
			sys->fprint(sys->fildes(2), "mount: %r\n");
		run("Schema", testSchema);
		run("Frames", testFrames);
		run("Stop", testStop);
		run("Ctl", testCtl);
		run("Raw", testRaw);
	}
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

server(fd: ref Sys->FD)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	cam := load CamsrvMod "/dis/camsrv.dis";
	cam->init(nil, "camsrv" :: "-t" :: nil);
}

skipit(t: ref T)
{
	t.skip("no $Bayer in this build");
}

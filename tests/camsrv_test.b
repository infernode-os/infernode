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

# a file read whole from where it is (raw, which is not numbered)
readall(fd: ref Sys->FD, b: array of byte): int
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

# frame n, read whole at its offset: (bytes, error)
readat(fd: ref Sys->FD, b: array of byte, n: int): (int, string)
{
	got := 0;
	while(got < len b){
		m := sys->pread(fd, b[got:], len b - got, big n * big len b + big got);
		if(m < 0)
			return (got, sys->sprint("%r"));
		if(m == 0)
			break;
		got += m;
	}
	return (got, nil);
}

# a value of status, as a number (-1 if absent)
statusnum(k: string): int
{
	(nil, f) := sys->tokenize(file("status"), " \t\n");
	for(; f != nil; f = tl f)
		if(len hd f > len k + 1 && (hd f)[0:len k + 1] == k + "=")
			return int (hd f)[len k + 1:];
	return -1;
}

# where a live reader starts: the newest frame if still kept, else the
# next, which a read waits for
newest(): int
{
	frames := statusnum("frames");
	first := statusnum("first");
	if(frames < 0)
		return -1;
	if(frames > first)
		return frames - 1;
	return frames;
}

# newest() of a camsrv mounted at dir
postednewest(dir: string): int
{
	(frames, first) := (-1, 0);
	(nil, w) := sys->tokenize(rd(dir + "/0/status"), " \t\n");
	for(; w != nil; w = tl w){
		if(len hd w > 7 && (hd w)[0:7] == "frames=")
			frames = int (hd w)[7:];
		if(len hd w > 6 && (hd w)[0:6] == "first=")
			first = int (hd w)[6:];
	}
	if(frames > first)
		return frames - 1;
	return frames;
}

# the newest frame, as a live reader takes it: one fallen behind (a
# slow machine; the ring keeps 8 frames) goes on from the newest again,
# as wm/camera and video-pane do
readframe(fd: ref Sys->FD, b: array of byte): int
{
	got := 0;
	for(try := 0; try < 5; try++){
		n := newest();
		if(n < 0)
			return 0;
		e: string;
		(got, e) = readat(fd, b, n);
		if(e != "frame expired"){
			if(e != nil)
				sys->fprint(sys->fildes(2), "readframe %d: %s\n", n, e);
			return got;
		}
	}
	return got;
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
	n := newest();
	(got, e) := readat(fd, b, n + 1);
	t.asserteq(got, FS, "and the next, waited for: " + e);
	t.assert(has(file("status"), "stream=on"), "a reader, a stream");

	# numbered as vid9p's: frame n is the same frame for every reader
	fd2 := sys->open(MNT + "/0/frame", Sys->OREAD);
	c := array[FS] of byte;
	(got, e) = readat(fd2, c, n + 1);
	t.asserteq(got, FS, "a second reader, the same frame: " + e);
	same := 1;
	for(j := 0; j < FS; j++)
		if(b[j] != c[j]){
			same = 0;
			break;
		}
	t.assert(same, "frame n is the same bytes to both readers");
	fd2 = nil;
	# kept: the last few; below them, refused
	sys->sleep(500);
	first := statusnum("first");
	frames := statusnum("frames");
	t.assert(first >= 0 && frames > first && frames - first <= 8, sys->sprint("status first=%d frames=%d", first, frames));
	(got, e) = readat(fd, c, first - 1);
	t.assert(first == 0 || e == "frame expired", "a frame no longer kept: " + e);
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
	t.asserteq(readall(fd, b), len b, "raw is the sensor's size");
	# RGGB, white bar: 1023 in every cell at the top left of the frame's bottom
	o := (640*1152 + 8)*2;
	t.asserteq(int b[o] | int b[o+1]<<8, 1023, "a raw sample of the white bar");
}

# A camera on its side: the feed served turned, sized as turned.
testRotate(t: ref T)
{
	t.assert(ctl("rotate 45") < 0, "only quarter turns");
	t.assert(ctl("rotate 90") > 0, "rotate 90 taken");
	t.assert(has(file("fmt"), sys->sprint("%d %d i420", H, W)), "fmt is turned: " + file("fmt"));
	t.assert(has(file("ctl"), "rotate 90"), "ctl reads back");
	t.assert(has(file("ctl"), sys->sprint("mode %d %d", H, W)), "the mode as served");
	t.assert(ctl(sys->sprint("mode %d %d", W, H)) < 0, "a mode asked unturned is no mode");
	fd := sys->open(MNT + "/0/frame", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open frame: %r"));
	a := array[FS] of byte;
	t.asserteq(readframe(fd, a), FS, "a whole frame, turned");
	t.assert(ctl("rotate 0") < 0, "no turning while streaming");
	# turned clockwise, the bars run top (white) to bottom (black), and
	# the picture's bottom, away from the moving band, is at the left
	col := 7;
	t.assert(int a[(W/16)*H + col] > 200, sys->sprint("white bar at the top: %d", int a[(W/16)*H + col]));
	t.assert(int a[(W-W/16)*H + col] < 30, sys->sprint("black bar at the bottom: %d", int a[(W-W/16)*H + col]));
	fd = nil;
	sys->sleep(300);
	t.assert(ctl("rotate 0") > 0, "rotate 0 once the stream is off");
	t.assert(has(file("fmt"), sys->sprint("%d %d i420", W, H)), "and fmt is as it was");
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
		run("Rotate", testRotate);
		run("Posted", testPosted);
	}
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

PostMod: module {
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# post(1) of a mounted camsrv, its pid (the leader of its group) sent first
postserver(spec, dir: string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	p := load PostMod "/dis/post.dis";
	if(p == nil){
		sys->fprint(sys->fildes(2), "load post: %r\n");
		return;
	}
	p->init(nil, "post" :: spec :: dir :: nil);
}

# its mount posted (post(1)), served to each that opens it: two
# connections, one camera
testPosted(t: ref T)
{
	spec := sys->sprint("camsrv_test.%d", sys->pctl(0, nil));
	pidc := chan of int;
	spawn postserver(spec, MNT, pidc);
	pid := <-pidc;
	f := "#s" + spec + "/fs";
	for(i := 0; i < 40 && sys->stat(f).t0 < 0; i++)
		sys->sleep(50);
	da := "/tmp/camsrv_test.a";
	db := "/tmp/camsrv_test.b";
	sys->create(da, Sys->OREAD, Sys->DMDIR|8r777);
	sys->create(db, Sys->OREAD, Sys->DMDIR|8r777);
	for(l := da :: db :: nil; l != nil; l = tl l){
		fd := sys->open(f, Sys->ORDWR);
		if(fd == nil || sys->mount(fd, nil, hd l, Sys->MREPL, "") < 0){
			t.fatal(sys->sprint("mount %s on %s: %r", f, hd l));
			return;
		}
	}
	t.assertseq(rd(da + "/0/fmt"), rd(db + "/0/fmt"), "one camera to both connections");
	t.assert(has(rd(da + "/0/fmt"), sys->sprint("%d %d i420", W, H)), "its fmt: " + rd(da + "/0/fmt"));
	fa := sys->open(da + "/0/frame", Sys->OREAD);
	fb := sys->open(db + "/0/frame", Sys->OREAD);
	a := array[FS] of byte;
	b := array[FS] of byte;
	n := -1;
	for(i = 0; i < 40 && n < 0; i++){
		(nil, w) := sys->tokenize(rd(da + "/0/status"), " \t\n");
		for(; w != nil; w = tl w)
			if(len hd w > 7 && (hd w)[0:7] == "frames=" && int (hd w)[7:] > 0)
				n = int (hd w)[7:];
		sys->sleep(50);
	}
	# frame n through both connections; fallen behind the ring on a
	# slow machine, a newer n
	(ga, ea, gb, eb) := (0, "", 0, "");
	for(try := 0; try < 5; try++){
		(ga, ea) = readat(fa, a, n);
		(gb, eb) = readat(fb, b, n);
		if(ea != "frame expired" && eb != "frame expired")
			break;
		n = postednewest(da);
	}
	t.asserteq(ga, FS, "frame n on the first connection: " + ea);
	t.asserteq(gb, FS, "frame n on the second: " + eb);
	same := 1;
	for(j := 0; j < FS; j++)
		if(a[j] != b[j]){
			same = 0;
			break;
		}
	t.assert(same, "frame n is the same bytes on both connections");
	# the second gone, the first reads on
	fb = nil;
	sys->unmount(nil, db);
	sys->sleep(200);
	(ga, ea) = readat(fa, a, postednewest(da));
	t.asserteq(ga, FS, "one connection gone, the other reads on: " + ea);
	fa = nil;
	sys->unmount(nil, da);
	k := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(k != nil)
		sys->fprint(k, "killgrp");
}

rd(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
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

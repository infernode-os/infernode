implement CamsrvTest;

#
# camsrv against its simulated sensor: the vid9p schema, the colours
# through $Bayer, frames moving, ctl, and the stream's lifetime.
#
# And requests that ended it (HostileRead, HostileCtl), each against a
# camsrv of its own, each request in a proc with a deadline.  Its serve
# loop had no handler, and one request from any holder of the feed
# broke it: every reader then waited for ever, with the capture left
# running and the sensor on.
#   - a read of frame at an offset near the frame size times 2^32: the
#     frame's number was cut to an int, went negative, and indexed the
#     ring before its start;
#   - "fps", "gain" or "flip" written to ctl with no value: the head of
#     the argument was taken before the words were counted.
# An argument that is no number ("exposure abc" set 0, automatic) and
# one out of range ("exposure -1") are refused; ctl is not writable by
# others.
#
# And the capture's own life (Settle, Stall), each against a camsrv of
# its own:
#   - a mode written just after the last close was taken while the
#     capture was still making its last frame, which it then merged at
#     one size into planes of another: the capture raised, never said it
#     had gone, and no capture was started again (the next reader waited
#     for ever).  The change waits for the capture.
#   - a capture told to stop looks between frames; with a frame that
#     never comes (a dead sensor link; "stall" with -t) it never went,
#     and nor did anything after it.  It is given three seconds.
#   - status said stream=on from the count of readers; it says what the
#     capture is.
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
	# both from one reading of status: read apart, a frame made between
	# the two put them nine apart on a loaded machine
	(first, frames) := (-1, -1);
	(nil, sw) := sys->tokenize(file("status"), " \t\n");
	for(; sw != nil; sw = tl sw){
		if(len hd sw > 6 && (hd sw)[0:6] == "first=")
			first = int (hd sw)[6:];
		if(len hd sw > 7 && (hd sw)[0:7] == "frames=")
			frames = int (hd sw)[7:];
	}
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
	# the frame being made when the last reader went is finished first
	# ("stopping"): how long that takes is the host's
	for(i := 0; i < 50 && !has(file("status"), "stream=off"); i++)
		sys->sleep(100);
	t.assert(has(file("status"), "stream=off"), "the last close stops the stream: " + file("status"));
}

# the status at dir once it has stream=want, waiting at most ms for it
waitstatus(dir, want: string, ms: int): string
{
	s := rd(dir + "/0/status");
	for(; ms > 0 && !has(s, "stream=" + want); ms -= 100){
		sys->sleep(100);
		s = rd(dir + "/0/status");
	}
	return s;
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

# A camera on its side: the feed served turned, sized as turned, and
# turned back while it streams.
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
	# the frames still kept are of before the turn, each said to be its
	# own size: the next one made is turned. A runner that stalls longer
	# than the window kept can let that number pass before the read is
	# served ("frame expired", macOS ARM64 CI): take the newest's next again.
	got := 0;
	e := "frame expired";
	for(try := 0; try < 5 && e == "frame expired"; try++)
		(got, e) = readat(fd, a, newest() + 1);
	t.asserteq(got, FS, "a whole frame, turned: " + e);
	# turned clockwise, the bars run top (white) to bottom (black), and
	# the picture's bottom, away from the moving band, is at the left
	col := 7;
	t.assert(int a[(W/16)*H + col] > 200, sys->sprint("white bar at the top: %d", int a[(W/16)*H + col]));
	t.assert(int a[(W-W/16)*H + col] < 30, sys->sprint("black bar at the bottom: %d", int a[(W-W/16)*H + col]));

	# turned back while it streams: taken, and the reader told once, at
	# the first frame of the new size, what it is; framesize is the same,
	# so the frame is where it was, and read again it is whole
	before := newest();
	t.assert(ctl("rotate 0") > 0, "a turn taken while streaming");
	t.assert(has(file("fmt"), sys->sprint("%d %d i420", W, H)), "fmt is as it was: " + file("fmt"));
	t.assert(ctl("flip 1") > 0, "a flip taken while streaming");
	want := sys->sprint("format changed: %d %d i420 10", W, H);
	told := 0;
	n := before + 1;
	for(i := 0; i < 20 && !told; i++){
		(got, e) = readat(fd, a, n);
		if(e == want)
			told = 1;
		else if(e == "frame expired")
			n = newest();
		else if(e != nil)
			t.fatal("read after the turn: " + e);
		else{
			t.asserteq(got, FS, "a frame of the old size, whole");
			n++;
		}
	}
	t.assert(told, "the reader told the new format: " + want);
	(got, e) = readat(fd, a, n);
	t.asserteq(got, FS, "the same frame read again, whole: " + e);
	row := H-8;
	t.assert(int a[row*W + W/16] > 200, sys->sprint("unturned, the white bar at the left: %d", int a[row*W + W/16]));
	(got, e) = readat(fd, a, n + 1);
	t.asserteq(got, FS, "the next with nothing more said: " + e);
	# a frame still kept from before the turn is of its own size, and said so
	(nil, e) = readat(fd, a, before);
	t.assert(e == "frame expired" || e == sys->sprint("format changed: %d %d i420 10", H, W), "an older frame, at its own size: " + e);
	# a second reader, opened now, has fmt's size: nothing said
	fd2 := sys->open(MNT + "/0/frame", Sys->OREAD);
	(got, e) = readat(fd2, a, newest());
	t.asserteq(got, FS, "a reader opened after the turn reads at once: " + e);
	fd2 = nil;
	fd = nil;
	sys->sleep(300);
	t.assert(ctl("flip 3") > 0, "flip back");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	testing->own();	# what this starts is killed at the end (reap)
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
		run("HostileRead", testHostileRead);
		run("HostileCtl", testHostileCtl);
		run("Settle", testSettle);
		run("Stall", testStall);
	}
	# nothing of the test's is left running: run as emu's own program
	# it never exited, for the servers and waiting procs it left
	testing->reap();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

# one request of the camsrv at dir, in a proc of its own:
#	ctl TEXT	written to ctl: "ok", or the error
#	frame N	8192 bytes read of frame at N frames: "read K", or the error
#	status	"ok" if status reads
op(dir, what, arg: string, n: big, done: chan of string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	case what {
	"ctl" =>
		fd := sys->open(dir + "/0/ctl", Sys->OWRITE);
		if(fd == nil)
			done <-= sys->sprint("open: %r");
		else if(sys->fprint(fd, "%s", arg) < 0)
			done <-= sys->sprint("%r");
		else
			done <-= "ok";
	"frame" =>
		fd := sys->open(dir + "/0/frame", Sys->OREAD);
		if(fd == nil){
			done <-= sys->sprint("open: %r");
			return;
		}
		b := array[8192] of byte;
		k := sys->pread(fd, b, len b, n * big FS);
		if(k < 0)
			done <-= sys->sprint("%r");
		else
			done <-= sys->sprint("read %d", k);
	"status" =>
		if(has(rd(dir + "/0/status"), "camera "))
			done <-= "ok";
		else
			done <-= "no status";
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# its answer, or "hung" if none has come in three seconds
try(dir, what, arg: string, n: big): string
{
	done := chan[1] of string;
	pidc := chan of int;
	spawn op(dir, what, arg, n, done, pidc);
	pid := <-pidc;
	tc := chan[1] of int;
	spawn timer(tc, 3000);
	alt {
	r := <-done =>
		return r;
	<-tc =>
		k := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
		if(k != nil)
			sys->fprint(k, "kill");
		return "hung";
	}
}

# a camsrv of the test's own, mounted at dir
own(dir: string): int
{
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	spawn server(p[1]);
	return sys->mount(p[0], nil, dir, Sys->MREPL, "");
}

# The body of a hostile test runs in a proc of its own and says what it
# found: against a camsrv that has stopped answering, an unmount or the
# close of a file waits for ever, and the suite with it.  A line
# beginning "FAIL " is a failure, "END" the end.
hostile(t: ref T, body: ref fn(out: chan of string))
{
	out := chan of string;
	spawn body(out);
	tc := chan[1] of int;
	spawn timer(tc, 60000);
	for(;;) alt {
	s := <-out =>
		if(s == "END")
			return;
		if(len s > 5 && s[0:5] == "FAIL ")
			t.error(s[5:]);
		else
			t.log(s);
	<-tc =>
		t.fatal("camsrv stopped answering");
	}
}

check(out: chan of string, ok: int, what: string)
{
	if(!ok)
		out <-= "FAIL " + what;
}

testHostileRead(t: ref T)
{
	hostile(t, hostileread);
}

hostileread(out: chan of string)
{
	dir := MNT + ".r";
	if(own(dir) < 0){
		out <-= sys->sprint("FAIL mount: %r");
		out <-= "END";
		return;
	}
	# held open, so the sensor is on and frames are made
	hold := sys->open(dir + "/0/frame", Sys->OREAD);
	check(out, hold != nil, "frame opens");
	sys->sleep(300);
	far := array[] of {
		big 16r100000000 - big 3,	# -3 as an int
		big 16r80000000,		# the most negative int
		big 16r100000000,		# 0 as an int: frame 0, which is not this one
		big 16r7fffffff,
		big 1 << 40,
		big 100000,
	};
	for(i := 0; i < len far; i++){
		r := try(dir, "frame", nil, far[i]);
		if(r == "hung"){
			out <-= sys->sprint("FAIL a read of frame %bd was never answered, and nor is anything after it", far[i]);
			out <-= "END";
			return;
		}
		check(out, r == "frame expired", sys->sprint("a read of frame %bd: %s", far[i], r));
	}
	check(out, try(dir, "status", nil, big 0) == "ok", "status reads after them");
	b := array[FS] of byte;
	n := 0;
	(nil, f) := sys->tokenize(rd(dir + "/0/status"), " \t\n");
	for(; f != nil; f = tl f)
		if(len hd f > 7 && (hd f)[0:7] == "frames=")
			n = int (hd f)[7:];
	(got, e) := readat(hold, b, n);
	check(out, got == FS && e == nil, sys->sprint("the next frame is read whole: %d bytes %s", got, e));
	hold = nil;
	sys->unmount(nil, dir);
	out <-= "END";
}

testHostileCtl(t: ref T)
{
	hostile(t, hostilectl);
}

hostilectl(out: chan of string)
{
	dir := MNT + ".c";
	if(own(dir) < 0){
		out <-= sys->sprint("FAIL mount: %r");
		out <-= "END";
		return;
	}
	(ok, d) := sys->stat(dir + "/0/ctl");
	check(out, ok >= 0 && (d.mode & 8r777) == 8r664, sys->sprint("ctl is not writable by others: %uo", d.mode & 8r777));
	bad := array[] of {
		"fps", "gain", "flip", "exposure", "focus", "rotate", "mode", "mode 144",
		"fps abc", "fps 1e1", "fps -5", "fps 10 20", "fps 99999999999",
		"gain abc", "gain -1", "gain 4294967297",
		"flip x", "flip -1",
		"exposure abc", "exposure -1", "exposure 70000", "exposure 1 2",
		"focus abc", "focus -1", "focus 2000",
		"mode abc def", "mode -144 -81", "mode 144 81 1",
		"", " ",
	};
	for(i := 0; i < len bad; i++){
		r := try(dir, "ctl", bad[i], big 0);
		if(r == "hung"){
			out <-= sys->sprint("FAIL \"%s\" written to ctl was never answered, and nor is anything after it", bad[i]);
			out <-= "END";
			return;
		}
		check(out, r != "ok" && has(r, "camsrv:"), sys->sprint("\"%s\" is refused: %s", bad[i], r));
	}
	good := array[] of {"fps 12", "gain 300", "flip 1", "exposure 500", "exposure 0", "focus 400", "mode 576 324", "rotate 180"};
	for(i = 0; i < len good; i++)
		check(out, try(dir, "ctl", good[i], big 0) == "ok", "\"" + good[i] + "\" is taken");
	c := rd(dir + "/0/ctl");
	check(out, has(c, "fps 12\n") && has(c, "gain 300\n") && has(c, "flip 1\n") && has(c, "exposure 0\n") &&
		has(c, "focus 400\n") && has(c, "mode 576 324\n") && has(c, "rotate 180\n"), "and read back: " + c);
	check(out, try(dir, "status", nil, big 0) == "ok", "status reads after them");
	sys->unmount(nil, dir);
	out <-= "END";
}

testSettle(t: ref T)
{
	hostile(t, settle);
}

# one frame read of the camsrv at dir, whole: "ok", an error, or "hung"
oneframe(dir: string, fs: int): string
{
	done := chan[1] of string;
	pidc := chan of int;
	spawn frameop(dir, fs, done, pidc);
	pid := <-pidc;
	tc := chan[1] of int;
	spawn timer(tc, 8000);
	alt {
	r := <-done =>
		return r;
	<-tc =>
		k := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
		if(k != nil)
			sys->fprint(k, "kill");
		return "hung";
	}
}

frameop(dir: string, fs: int, done: chan of string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(dir + "/0/frame", Sys->OREAD);
	if(fd == nil){
		done <-= sys->sprint("open: %r");
		return;
	}
	b := array[fs] of byte;
	for(try := 0; try < 5; try++){
		n := postednewest(dir);
		(got, e) := readat(fd, b, n);
		if(e == "frame expired")
			continue;
		if(e != nil)
			done <-= e;
		else if(got != fs)
			done <-= sys->sprint("short frame: %d of %d", got, fs);
		else
			done <-= "ok";
		return;
	}
	done <-= "frame expired, five times";
}

settle(out: chan of string)
{
	dir := MNT + ".s";
	if(own(dir) < 0){
		out <-= sys->sprint("FAIL mount: %r");
		out <-= "END";
		return;
	}
	check(out, try(dir, "ctl", "fps 56", big 0) == "ok", "fps 56");
	big1 := 576*324*3/2;
	small := 288*162*3/2;
	for(i := 0; i < 12; i++){
		r := try(dir, "ctl", "mode 576 324", big 0);
		check(out, r == "ok", sys->sprint("round %d: mode 576 324 after the close: %s", i, r));
		r = oneframe(dir, big1);
		if(r == "hung"){
			out <-= sys->sprint("FAIL round %d: no frame at 576x324: the capture never started again", i);
			break;
		}
		check(out, r == "ok", sys->sprint("round %d: a frame at 576x324: %s", i, r));
		# the reader has just closed: its capture is still in a frame
		r = try(dir, "ctl", "mode 288 162", big 0);
		check(out, r == "ok", sys->sprint("round %d: mode 288 162 after the close: %s", i, r));
		r = oneframe(dir, small);
		if(r == "hung"){
			out <-= sys->sprint("FAIL round %d: no frame at 288x162: the capture never started again", i);
			break;
		}
		check(out, r == "ok", sys->sprint("round %d: a frame at 288x162: %s", i, r));
	}
	sys->unmount(nil, dir);
	out <-= "END";
}

testStall(t: ref T)
{
	hostile(t, stall);
}

stall(out: chan of string)
{
	dir := MNT + ".t";
	if(own(dir) < 0){
		out <-= sys->sprint("FAIL mount: %r");
		out <-= "END";
		return;
	}
	hold := sys->open(dir + "/0/frame", Sys->OREAD);
	check(out, hold != nil, "frame opens");
	sys->sleep(300);
	check(out, has(rd(dir + "/0/status"), "stream=on"), "streaming: " + rd(dir + "/0/status"));
	check(out, try(dir, "ctl", "stall", big 0) == "ok", "stall is taken by the simulated sensor");
	sys->sleep(300);
	hold = nil;
	sys->sleep(300);
	# the capture is in a frame that will not come: not off, and it says so
	s := rd(dir + "/0/status");
	check(out, has(s, "stream=stopping"), "a capture told to stop and not yet gone: " + s);
	# Stopwait (3 s), and the host's time to kill it and say so
	s = waitstatus(dir, "off", 8000);
	check(out, has(s, "stream=off"), "given up after three seconds: " + s);
	r := oneframe(dir, FS);
	if(r == "hung")
		out <-= "FAIL after a capture that never stopped, no capture starts: a reader waits for ever";
	else
		check(out, r == "ok", "a reader after it gets a frame: " + r);
	sys->unmount(nil, dir);
	out <-= "END";
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

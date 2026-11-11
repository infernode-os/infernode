implement VidjpegTest;

#
# videnc(1) and vidjpeg(1) over vid9p(4), a clip the test writes: videnc
# union-mounted after the feed gives jpeg/ beside frame (fmt, ctl, index
# records whose offsets only grow, data that is the JPEG); vidjpeg over
# that gives frames of the feed's size within JPEG's error of the clip's,
# and status and fmt as the feed's; a frame past the clip's end refused
# through both; a quality written to jpeg/ctl taking effect (smaller
# frames, and the cache started again); one frame read as eight reads at
# once decoding the same bytes as one read.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "jpeg.m";
	jp: Jpegplanes;
include "parread.m";
	parread: Parread;
include "math.m";
	math: Math;
include "testing.m";
	testing: Testing;
	T: import testing;

VidjpegTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/vidjpeg_test.b";
W: con 64;
H: con 48;
NF: con 6;
FS: con W*H*3/2;

passed := 0;
failed := 0;
skipped := 0;
dir: string;
clip: array of array of byte;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# NF frames of gradients moving a few pixels a frame, as a .y4m file
mkclip(f: string): string
{
	fd := sys->create(f, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("can't create %s: %r", f);
	hdr := array of byte sys->sprint("YUV4MPEG2 W%d H%d F6:1 Ip A1:1 C420jpeg\n", W, H);
	sys->write(fd, hdr, len hdr);
	clip = array[NF] of array of byte;
	for(k := 0; k < NF; k++){
		b := array[FS] of byte;
		for(y := 0; y < H; y++)
			for(x := 0; x < W; x++)
				b[y*W+x] = byte ((x*3 + y*2 + k*5) % 256);
		for(i := W*H; i < FS; i++)
			b[i] = byte (100 + (i % 40));
		clip[k] = b;
		fh := array of byte "FRAME\n";
		sys->write(fd, fh, len fh);
		sys->write(fd, b, len b);
	}
	return nil;
}

mkdir(d: string)
{
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r755);
}

# cmd's module on dir, as mount {cmd args} dir does; flag MAFTER or MREPL
mountcmd(cmd: string, args: list of string, d: string, flag: int): string
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return sys->sprint("pipe: %r");
	pidc := chan of string;
	spawn server(cmd, args, p[1], pidc);
	if((e := <-pidc) != nil)
		return e;
	p[1] = nil;
	if(sys->mount(p[0], nil, d, flag, nil) < 0)
		return sys->sprint("mount %s on %s: %r", cmd, d);
	return nil;
}

Command: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

server(cmd: string, args: list of string, fd: ref Sys->FD, c: chan of string)
{
	sys->pctl(Sys->FORKNS|Sys->NEWFD, fd.fd :: 2 :: nil);
	sys->dup(fd.fd, 0);
	m := load Command cmd;
	if(m == nil){
		c <-= sys->sprint("load %s: %r", cmd);
		return;
	}
	c <-= nil;
	m->init(nil, cmd :: args);
}

readall(f: string): (string, string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	s := "";
	b := array[4096] of byte;
	while((n := sys->read(fd, b, len b)) > 0)
		s += string b[0:n];
	if(n < 0)
		return (s, sys->sprint("%r"));
	return (s, nil);
}

# the bytes a file reads as (raw bytes: not through a string, which takes them as UTF-8)
count(f: string): int
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return -1;
	t := 0;
	b := array[65536] of byte;
	while((n := sys->read(fd, b, len b)) > 0)
		t += n;
	return t;
}

# frame n's record from index: (off, len, error)
record(n: int): (big, int, string)
{
	fd := sys->open(dir + "/feed/0/jpeg/index", Sys->OREAD);
	if(fd == nil)
		return (big 0, 0, sys->sprint("%r"));
	b := array[32] of byte;
	k := sys->pread(fd, b, len b, big n * big 32);
	if(k <= 0)
		return (big 0, 0, sys->sprint("%r"));
	(nf, fl) := sys->tokenize(string b[0:k], " \n");
	if(nf != 2)
		return (big 0, 0, "bad record: " + string b[0:k]);
	return (big hd fl, int hd tl fl, nil);
}

psnr(a, b: array of byte): real
{
	s := 0.0;
	for(i := 0; i < len a; i++){
		d := real (int a[i] - int b[i]);
		s += d * d;
	}
	if(s == 0.0)
		return 99.0;
	return 10.0 * math->log10(255.0 * 255.0 * real len a / s);
}

setup(): string
{
	(ok, nil) := sys->stat("/tmp");
	if(ok < 0)
		mkdir("/tmp");
	dir = sys->sprint("/tmp/vidjpegtest.%d", sys->pctl(0, nil));
	mkdir(dir);
	mkdir(dir + "/feed");
	mkdir(dir + "/view");
	if((e := mkclip(dir + "/clip.y4m")) != nil)
		return e;
	if((e = mountcmd("/dis/vid9p.dis", dir + "/clip.y4m" :: nil, dir + "/feed", Sys->MREPL)) != nil)
		return e;
	if((e = mountcmd("/dis/videnc.dis", dir + "/feed/0" :: nil, dir + "/feed/0", Sys->MAFTER)) != nil)
		return e;
	if((e = mountcmd("/dis/vidjpeg.dis", dir + "/feed/0" :: nil, dir + "/view", Sys->MREPL)) != nil)
		return e;
	return nil;
}

testFiles(t: ref T)
{
	(f, e) := readall(dir + "/feed/0/jpeg/fmt");
	t.assertseq(f, sys->sprint("jpeg %d %d 420 6\n", W, H), "jpeg/fmt " + e);
	(c, nil) := readall(dir + "/feed/0/jpeg/ctl");
	t.assertseq(c, "quality 75\n", "jpeg/ctl");
	t.asserteq(count(dir + "/feed/0/frame"), NF*FS, "the feed's own frames are still there, beside jpeg/");
	lastoff := big -1;
	for(n := 0; n < NF; n++){
		(off, sz, err) := record(n);
		if(err != nil){
			t.error(sys->sprint("frame %d's record: %s", n, err));
			continue;
		}
		t.assert(off > lastoff && sz > 0, sys->sprint("frame %d at %bd, %d bytes: offsets grow", n, off, sz));
		lastoff = off;
		fd := sys->open(dir + "/feed/0/jpeg/data", Sys->OREAD);
		j := array[sz] of byte;
		(got, perr) := parread->pread(fd, j, off, 1);
		t.asserteq(got, sz, "its bytes from data " + perr);
		(dw, dh, y, nil, nil, derr) := jp->planes(j);
		t.assert(derr == nil && dw == W && dh == H, sys->sprint("frame %d is a %dx%d JPEG %s", n, W, H, derr));
		if(y != nil)
			t.assert(psnr(y, clip[n][0:W*H]) > 30.0, sys->sprint("frame %d near the clip's (%.1f dB)", n, psnr(y, clip[n][0:W*H])));
	}
	(nil, nil, err) := record(NF);
	t.assertnotnil(err, "a frame past the clip's end refused");
}

testView(t: ref T)
{
	(f, nil) := readall(dir + "/view/0/fmt");
	t.assertseq(f, sys->sprint("%d %d i420 6\n", W, H), "vidjpeg's fmt is a raw feed's");
	(st, nil) := readall(dir + "/view/0/status");
	(st2, nil) := readall(dir + "/feed/0/status");
	t.assertseq(st, st2, "status is the feed's");
	fd := sys->open(dir + "/view/0/frame", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open view frame: %r"));
	for(n := 0; n < NF; n++){
		b := array[FS] of byte;
		(got, err) := parread->pread(fd, b, big n * big FS, 1);
		t.asserteq(got, FS, sys->sprint("frame %d whole %s", n, err));
		t.assert(psnr(b[0:W*H], clip[n][0:W*H]) > 30.0, sys->sprint("frame %d within JPEG's error of the clip's (%.1f dB)", n, psnr(b[0:W*H], clip[n][0:W*H])));
	}
	# eight reads at once of one frame: the same bytes as one read
	one := array[FS] of byte;
	eight := array[FS] of byte;
	parread->pread(fd, one, big 2 * big FS, 1);
	(got, nil) := parread->pread(fd, eight, big 2 * big FS, 8);
	same := got == FS;
	for(i := 0; same && i < FS; i++)
		if(one[i] != eight[i])
			same = 0;
	t.assert(same, "eight reads at once of one frame, the same bytes as one");
	past := array[FS] of byte;
	k := sys->pread(fd, past, len past, big NF * big FS);
	t.assert(k <= 0, sys->sprint("a frame past the end refused through vidjpeg (%d: %r)", k));
}

testQuality(t: ref T)
{
	(off75, sz75, nil) := record(0);
	fd := sys->open(dir + "/feed/0/jpeg/ctl", Sys->OWRITE);
	t.assert(fd != nil && sys->fprint(fd, "quality 20") > 0, "quality 20 written");
	(c, nil) := readall(dir + "/feed/0/jpeg/ctl");
	t.assertseq(c, "quality 20\n", "and read back");
	(off20, sz20, nil) := record(0);
	t.assert(sz20 < sz75, sys->sprint("frame 0 smaller at 20 (%d) than at 75 (%d)", sz20, sz75));
	t.assert(off20 > off75, "encoded again, at a new offset");
	t.assert(fd != nil && sys->fprint(fd, "quality 0") < 0, "quality 0 refused");
	t.assert(sys->fprint(fd, "loud") < 0, "an unknown control refused");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	jp = load Jpegplanes Jpegplanes->PATH;
	parread = load Parread Parread->PATH;
	math = load Math Math->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := tl args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	sys->pctl(Sys->FORKNS|Sys->NEWPGRP, nil);
	if((e := setup()) != nil){
		sys->fprint(sys->fildes(2), "vidjpeg_test: %s\n", e);
		raise "fail:setup";
	}
	run("Vidjpeg/Files", testFiles);
	run("Vidjpeg/View", testView);
	run("Vidjpeg/Quality", testQuality);
	# the servers are in this group: end them, so that emu exits
	r := testing->summary(passed, failed, skipped);
	if((fd := sys->open(sys->sprint("/prog/%d/ctl", sys->pctl(0, nil)), Sys->OWRITE)) != nil)
		sys->fprint(fd, "killgrp");
	if(r > 0)
		raise "fail:tests failed";
}

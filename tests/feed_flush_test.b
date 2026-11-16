implement FeedFlushTest;

#
# A video feed's frame reads that wait for a frame not yet made, when the
# client gives them up: vid9p(4) and camsrv(4), each on a pipe, spoken
# to in raw Styx (a mount's kernel hides what is checked here).
#  - a read flushed while it waits is forgotten.  Both servers left it
#    parked (Tflush went to the library, which knows nothing of parked
#    reads): the next frame answered a tag the client had given up, and
#    might by then have used for another request, which got a frame's
#    bytes for its answer.
#  - a read whose fid is clunked while it waits is answered with an
#    error.  vid9p answered it later with the frame, on a fid that no
#    longer was; camsrv dropped it, and its tag waited for ever.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "testing.m";
	testing: Testing;
	T: import testing;
include "bayer.m";

FeedFlushTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Srv: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/feed_flush_test.b";
CLIP: con "/tmp/feed_flush_test.y4m";
CW: con 16;
CH: con 16;

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

server(fd: ref Sys->FD, path: string, args: list of string)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	m := load Srv path;
	if(m == nil)
		return;
	m->init(nil, args);
}

# the replies of a connection, as they come; nil at its end
reader(fd: ref Sys->FD, c: chan of ref Rmsg, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		r := Rmsg.read(fd, 64*1024);
		c <-= r;
		if(r == nil)
			return;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

Conn: adt {
	fd:	ref Sys->FD;
	c:	chan of ref Rmsg;
	pid:	int;

	send:	fn(k: self ref Conn, m: ref Tmsg);
	next:	fn(k: self ref Conn, ms: int): ref Rmsg;
	rpc:	fn(k: self ref Conn, t: ref T, m: ref Tmsg, kind: int): ref Rmsg;
	close:	fn(k: self ref Conn);
};

Conn.send(k: self ref Conn, m: ref Tmsg)
{
	b := m.pack();
	sys->write(k.fd, b, len b);
}

# the next reply, or nil if none comes in ms
Conn.next(k: self ref Conn, ms: int): ref Rmsg
{
	tc := chan[1] of int;
	spawn timer(tc, ms);
	alt {
	r := <-k.c =>
		return r;
	<-tc =>
		return nil;
	}
}

Conn.rpc(k: self ref Conn, t: ref T, m: ref Tmsg, kind: int): ref Rmsg
{
	k.send(m);
	r := k.next(5000);
	if(r == nil)
		t.fatal("no reply to " + m.text());
	if(tagof r != kind)
		t.fatal(m.text() + ": " + r.text());
	return r;
}

Conn.close(k: self ref Conn)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", k.pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
	k.fd = nil;
}

# a server on a pipe; fid 1 its root, fid 2 0/frame open, fid 3 0/status open
connect(t: ref T, path: string, args: list of string): ref Conn
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	spawn server(p[1], path, args);
	p[1] = nil;
	k := ref Conn(p[0], chan of ref Rmsg, 0);
	pidc := chan of int;
	spawn reader(k.fd, k.c, pidc);
	k.pid = <-pidc;
	k.rpc(t, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000"), tagof Rmsg.Version);
	k.rpc(t, ref Tmsg.Attach(1, 1, Styx->NOFID, "t", ""), tagof Rmsg.Attach);
	k.rpc(t, ref Tmsg.Walk(2, 1, 2, array[] of {"0", "frame"}), tagof Rmsg.Walk);
	k.rpc(t, ref Tmsg.Open(3, 2, Sys->OREAD), tagof Rmsg.Open);
	k.rpc(t, ref Tmsg.Walk(4, 1, 3, array[] of {"0", "status"}), tagof Rmsg.Walk);
	k.rpc(t, ref Tmsg.Open(5, 3, Sys->OREAD), tagof Rmsg.Open);
	return k;
}

# status's value of key, -1 if it is not there
status(t: ref T, k: ref Conn, key: string): int
{
	r := k.rpc(t, ref Tmsg.Read(6, 3, big 0, 512), tagof Rmsg.Read);
	s := "";
	pick m := r {
	Read =>
		s = string m.data;
	}
	(nil, f) := sys->tokenize(s, " \t\n");
	for(; f != nil; f = tl f)
		if(len hd f > len key + 1 && (hd f)[0:len key + 1] == key + "=")
			return int (hd f)[len key + 1:];
	return -1;
}

# Frames are made (waited for), then a read of a frame `ahead` frames on
# is sent and given up; what the server then does.
giveup(t: ref T, k: ref Conn, ahead: int)
{
	fs := 0;
	n := 0;
	for(i := 0; i < 50; i++){
		fs = status(t, k, "framesize");
		n = status(t, k, "frames");
		if(fs > 0 && n > 0)
			break;
		sys->sleep(100);
	}
	if(fs <= 0 || n <= 0)
		t.fatal(sys->sprint("no frames: framesize=%d frames=%d", fs, n));

	# flushed while it waits
	k.send(ref Tmsg.Read(20, 2, big (n + ahead) * big fs, 64));
	k.send(ref Tmsg.Flush(21, 20));
	r := k.next(3000);
	if(r == nil)
		t.fatal("the flush was not answered");
	t.assert(tagof r == tagof Rmsg.Flush && r.tag == 21, "the flush is answered: " + r.text());
	stale := 0;
	while((r = k.next(1500)) != nil)
		if(r.tag == 20){
			stale = 1;
			t.error("the flushed read was answered after its flush: " + r.text());
		}
	t.assert(!stale, "a flushed read is forgotten");

	# its fid clunked while it waits
	n = status(t, k, "frames");
	k.send(ref Tmsg.Read(30, 2, big (n + ahead) * big fs, 64));
	k.send(ref Tmsg.Clunk(31, 2));
	seen30 := seen31 := 0;
	for(i = 0; i < 2; i++){
		r = k.next(3000);
		if(r == nil)
			break;
		if(r.tag == 30){
			seen30 = 1;
			t.assert(tagof r == tagof Rmsg.Error, "the read of a clunked fid is an error: " + r.text());
		}else if(r.tag == 31){
			seen31 = 1;
			t.assert(tagof r == tagof Rmsg.Clunk, "the clunk is answered: " + r.text());
			t.assert(seen30, "the read is answered before its fid goes");
		}
	}
	t.assert(seen30, "a read parked on a clunked fid is answered");
	t.assert(seen31, "the clunk is answered");
	t.assert(status(t, k, "frames") > 0, "the server answers after them");
}

mkclip(t: ref T)
{
	fd := sys->create(CLIP, Sys->OWRITE, 8r666);
	if(fd == nil)
		t.fatal(sys->sprint("create %s: %r", CLIP));
	sys->fprint(fd, "YUV4MPEG2 W%d H%d F10:1 Ip A1:1 C420jpeg\n", CW, CH);
	fr := array[CW*CH + 2*(CW/2)*(CH/2)] of byte;
	for(i := 0; i < 4; i++){
		for(j := 0; j < len fr; j++)
			fr[j] = byte (60 + 40*i);
		sys->fprint(fd, "FRAME\n");
		sys->write(fd, fr, len fr);
	}
}

testVid9p(t: ref T)
{
	mkclip(t);
	k := connect(t, "/dis/vid9p.dis", "vid9p" :: "-w" :: "2" :: "-r" :: CLIP :: nil);
	giveup(t, k, 5);	# half a second on, at ten frames a second
	k.close();
	sys->remove(CLIP);
}

testCamsrv(t: ref T)
{
	if((load Bayer Bayer->PATH) == nil)
		t.skip("no $Bayer in this build");
	k := connect(t, "/dis/camsrv.dis", "camsrv" :: "-t" :: nil);
	giveup(t, k, 6);	# its ring is 8: further on is refused at once
	k.close();
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || styx == nil){
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:load";
	}
	testing->init();
	styx->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Vid9p", testVid9p);
	run("Camsrv", testCamsrv);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

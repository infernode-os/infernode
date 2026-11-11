implement SdgsrvTest;

#
# sdgsrv(1), the responder of sdg(2), against sdg(2)'s own client
# (relay) over UDP on the loopback, a directory of the test's served:
# a 300,000-byte file read whole and byte for byte through the mount
# with 1, 4 and 16 reads in flight (msize 1200: each read one datagram);
# a file whose reads answer only after 400 ms, past the client's 40 ms
# retransmission, so the server answers its retransmissions "pending"
# and the read still gets its bytes; two sessions at once, each its own
# export; a reader killed in the middle of its reads (a Tflush through
# the server's own tags), and the mount still reading after it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
include "keyring.m";
include "security.m";
	random: Random;
include "sdg.m";
	sdg: Sdg;
include "testing.m";
	testing: Testing;
	T: import testing;

SdgsrvTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/sdgsrv_test.b";
BIGLEN: con 300000;

passed := 0;
failed := 0;
skipped := 0;
scratch: string;
addr: string;
srvpid := -1;
slowpid := -1;
want: array of byte;

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

mkdir(d: string)
{
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r755);
}

hexfile(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[200] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	s := string b[0:n];
	while(len s > 0 && s[len s-1] == '\n')
		s = s[0:len s-1];
	a := array[len s/2] of byte;
	for(i := 0; i < len a; i++){
		v := 0;
		for(j := 0; j < 2; j++){
			c := s[2*i+j];
			if(c >= 'a')
				v = v*16 + c - 'a' + 10;
			else
				v = v*16 + c - '0';
		}
		a[i] = byte v;
	}
	return a;
}

# the slow file: each read answered 400 ms after it came
slow(fio: ref Sys->FileIO, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	for(;;) alt {
	(off, nil, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		spawn later(off, rc);
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "read only");
	}
}

later(off: int, rc: chan of (array of byte, string))
{
	sys->sleep(400);
	if(off > 0)
		rc <-= (nil, nil);
	else
		rc <-= (array of byte "slow but here", nil);
}

server(kd, a, d: string, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	srv := load Command "/dis/sdgsrv.dis";
	if(srv == nil){
		sys->fprint(sys->fildes(2), "sdgsrv_test: load sdgsrv: %r\n");
		return;
	}
	srv->init(nil, "sdgsrv" :: kd :: a :: d :: nil);
}

setup(): string
{
	(ok, nil) := sys->stat("/tmp");
	if(ok < 0)
		mkdir("/tmp");
	scratch = sys->sprint("/tmp/sdgsrvtest.%d.%d", sys->pctl(0, nil), sys->millisec());
	mkdir(scratch);
	d := scratch + "/srv";
	mkdir(d);
	want = array[BIGLEN] of byte;
	for(i := 0; i < BIGLEN; i++)
		want[i] = byte (i*7 + i/251);
	fd := sys->create(d + "/big", Sys->OWRITE, 8r644);
	if(fd == nil || sys->write(fd, want, len want) != len want)
		return sys->sprint("can't write %s/big: %r", d);
	if(sys->bind("#s", d, Sys->MBEFORE) < 0)
		return sys->sprint("bind #s: %r");
	fio := sys->file2chan(d, "slow");
	if(fio == nil)
		return sys->sprint("file2chan: %r");
	spc := chan of int;
	spawn slow(fio, spc);
	slowpid = <-spc;

	kd := scratch + "/keys";
	gen := load Command "/dis/sdgsrv.dis";
	if(gen == nil)
		return sys->sprint("load sdgsrv: %r");
	gen->init(nil, "sdgsrv" :: "-g" :: kd :: nil);
	if(len hexfile(kd + "/sdg.key") != 32)
		return "sdgsrv -g made no keys";

	port := 23000 + int (random->randombuf(Random->NotQuiteRandom, 2)[0]) * 100 + sys->millisec() % 97;
	addr = sys->sprint("udp!127.0.0.1!%d", port);
	pidc := chan of int;
	spawn server(kd, sys->sprint("udp!*!%d", port), d, pidc);
	srvpid = <-pidc;
	sys->sleep(300);
	return nil;
}

keys(): ref Sdg->Keys
{
	kd := scratch + "/keys";
	return ref Sdg->Keys(hexfile(kd + "/sdg.key"), hexfile(kd + "/sdg.brick"),
		hexfile(kd + "/sdg.psk"), kd + "/sdg.ctr");
}

# a session mounted on mnt; nil, or why not
mountsdg(mnt: string): string
{
	mkdir(mnt);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return sys->sprint("pipe: %r");
	if((e := sdg->relay(addr, keys(), p[1])) != nil)
		return "relay: " + e;
	p[1] = nil;
	# (fversion's result is the size asked for, not the size agreed: the
	# open file's iounit says what the mount uses)
	(got, nil) := sys->fversion(p[0], 8192, "9P2000");
	if(got <= 0)
		return sys->sprint("fversion: %r");
	if(sys->mount(p[0], nil, mnt, Sys->MREPL, nil) < 0)
		return sys->sprint("mount: %r");
	fd := sys->open(mnt + "/big", Sys->OREAD);
	if(fd == nil)
		return sys->sprint("open %s/big: %r", mnt);
	if((io := sys->iounit(fd)) <= 0 || io + 24 > Sdg->MSIZE)
		return sys->sprint("iounit %d: messages over a datagram", io);
	return nil;
}

# file f read whole as ways contiguous pieces at once
readways(f: string, ways: int): (array of byte, string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("open %s: %r", f));
	b := array[BIGLEN] of byte;
	done := chan of string;
	per := (BIGLEN + ways - 1) / ways;
	for(k := 0; k < ways; k++){
		lo := k * per;
		hi := lo + per;
		if(hi > BIGLEN)
			hi = BIGLEN;
		spawn piece(fd, b, lo, hi, done);
	}
	err: string;
	for(k = 0; k < ways; k++)
		if((e := <-done) != nil)
			err = e;
	return (b, err);
}

piece(fd: ref Sys->FD, b: array of byte, lo, hi: int, done: chan of string)
{
	for(o := lo; o < hi; ){
		n := sys->pread(fd, b[o:hi], hi - o, big o);
		if(n <= 0){
			done <-= sys->sprint("pread at %d: %d %r", o, n);
			return;
		}
		o += n;
	}
	done <-= nil;
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

testRead(t: ref T)
{
	if((e := mountsdg(scratch + "/m1")) != nil)
		t.fatal(e);
	(ok, d) := sys->stat(scratch + "/m1/big");
	t.assert(ok >= 0 && d.length == big BIGLEN, "the file's stat through sdg");
	for(w := (1 :: 4 :: 16 :: nil); w != nil; w = tl w){
		t0 := sys->millisec();
		(b, err) := readways(scratch + "/m1/big", hd w);
		t.assertnil(err, sys->sprint("%d in flight: read", hd w));
		t.assert(same(b, want), sys->sprint("%d in flight: 300,000 bytes byte for byte", hd w));
		t.log(sys->sprint("%d in flight: %d ms", hd w, sys->millisec() - t0));
	}
}

testPending(t: ref T)
{
	fd := sys->open(scratch + "/m1/slow", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open slow: %r"));
	b := array[100] of byte;
	t0 := sys->millisec();
	n := sys->read(fd, b, len b);
	ms := sys->millisec() - t0;
	t.assert(n > 0 && string b[0:n] == "slow but here", sys->sprint("a read answered after 400 ms gets its bytes (%d)", n));
	t.assert(ms >= 380 && ms < 3000, sys->sprint("in about the server's time, not a deadline's (%d ms)", ms));
}

testTwoSessions(t: ref T)
{
	if((e := mountsdg(scratch + "/m2")) != nil)
		t.fatal(e);
	c := chan of (string, int);
	spawn both(scratch + "/m1/big", c);
	spawn both(scratch + "/m2/big", c);
	for(i := 0; i < 2; i++){
		(err, ok) := <-c;
		t.assertnil(err, "a session's read");
		t.assert(ok, "its bytes");
	}
}

both(f: string, c: chan of (string, int))
{
	(b, err) := readways(f, 8);
	c <-= (err, same(b, want));
}

# a read held open (400 ms) while 150 others, one at a time, run past it:
# more than the 64 rids the window keeps, so the floor moves over the open
# one and its run map shifts with the 64th's bit set.  A big's >> copies
# that bit down (it is arithmetic), so rids not yet sent were taken for run
# ("reply gone"), and a map of ones held the session in ran() for good,
# answering nothing (the loss experiment, docs/experiments/loss)
testWindow(t: ref T)
{
	sc := chan of int;
	spawn slowread(scratch + "/m1/slow", sc);
	sys->sleep(50);
	fd := sys->open(scratch + "/m1/big", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open big: %r"));
	b := array[1] of byte;
	bad := 0;
	for(i := 0; i < 150 + 50; i++){
		if(sys->pread(fd, b, 1, big (i*997)) != 1 || b[0] != want[i*997]){
			if(bad++ == 0)
				t.error(sys->sprint("read %d past the open one: %r", i));
		}
		if(i == 150)
			<-sc;	# the slow one answered: on, past it
	}
	t.asserteq(bad, 0, "every read past a read held open answered, and right");
}

slowread(f: string, c: chan of int)
{
	fd := sys->open(f, Sys->OREAD);
	b := array[100] of byte;
	if(fd != nil)
		sys->read(fd, b, len b);
	c <-= 1;
}

testKilled(t: ref T)
{
	pidc := chan of int;
	spawn victim(scratch + "/m1/slow", pidc);
	pid := <-pidc;
	sys->sleep(100);	# its read is out, waiting
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
	sys->sleep(600);
	(b, err) := readways(scratch + "/m1/big", 4);
	t.assertnil(err, "the mount reads after a reader was killed in its read");
	t.assert(same(b, want), "and gets the bytes");
}

victim(f: string, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	fd := sys->open(f, Sys->OREAD);
	b := array[100] of byte;
	sys->read(fd, b, len b);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	random = load Random Random->PATH;
	sdg = load Sdg Sdg->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if(sdg == nil || sdg->init() != nil){
		sys->fprint(sys->fildes(2), "cannot load sdg: %r\n");
		raise "fail:cannot load sdg";
	}
	sys->pctl(Sys->FORKNS, nil);
	if((e := setup()) != nil){
		sys->fprint(sys->fildes(2), "sdgsrv_test: %s\n", e);
		raise "fail:setup";
	}
	run("Sdgsrv/Read", testRead);
	run("Sdgsrv/Pending", testPending);
	run("Sdgsrv/TwoSessions", testTwoSessions);
	run("Sdgsrv/Window", testWindow);
	run("Sdgsrv/KilledReader", testKilled);
	# the mounts (their relays end), the server and the slow file's, so that emu can exit
	sys->unmount(nil, scratch + "/m1");
	sys->unmount(nil, scratch + "/m2");
	for(pl := srvpid :: slowpid :: nil; pl != nil; pl = tl pl)
		if(hd pl >= 0){
			fd := sys->open(sys->sprint("/prog/%d/ctl", hd pl), Sys->OWRITE);
			if(fd != nil)
				sys->fprint(fd, "killgrp");
		}
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

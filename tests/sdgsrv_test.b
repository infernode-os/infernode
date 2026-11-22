implement SdgsrvTest;

#
# sdgsrv(1), the responder of sdg(2), against sdg(2)'s own client
# (relay) over UDP on the loopback, a directory of the test's served:
# a 300,000-byte file read whole and byte for byte through the mount
# with 1, 4 and 16 reads in flight (msize 1200: each read one datagram);
# a file whose reads answer only after 1.5 s, past the client's 40 ms
# retransmission, so the server answers its retransmissions "pending"
# and the read still gets its bytes; two sessions at once, each its own
# export; a reader killed in the middle of its reads (a Tflush through
# the server's own tags), and the mount still reading after it.
#
# Through a relay of the test's own, which keeps the first initiation it
# passes and the session's index (both are in the clear on the wire):
# junk sent under the session's index from another socket while a read
# waits gets none of the session's replies (the address replies go to,
# and the session's idle clock, were set from any packet carrying the
# index, before it had been opened: three replies went to the other
# socket); and the kept initiation, sent again to a server started again
# with its keys, is not answered (the newest counter accepted was not
# kept across a start: it opened a session), while a new handshake is.
# A counter store that cannot be read stops the server at its start.
#
# A flood of initiations that pass mac1 (anyone with the server's public
# key makes them) from one socket: past four a second the server answers
# with cookies and does no X25519 for them (it did two for each, as fast
# as they came, and answered nothing), a cookie opens under the key the
# client derives, and a client connecting through the flood, which gets
# a cookie and shows it, is served.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
include "keyring.m";
	keyring: Keyring;
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
SLOWMS: con 1500;	# past the client's 1 s retransmission of a request answered "pending"

passed := 0;
failed := 0;
skipped := 0;
scratch: string;
addr: string;
srvpid := -1;
lossypid := -1;
lossyaddr: string;
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

# the slow file: each read answered SLOWMS after it came
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
	sys->sleep(SLOWMS);
	if(off > 0)
		rc <-= (nil, nil);
	else
		rc <-= (array of byte "slow but here", nil);
}

server(opts: list of string, kd, a, d: string, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	srv := load Command "/dis/sdgsrv.dis";
	if(srv == nil){
		sys->fprint(sys->fildes(2), "sdgsrv_test: load sdgsrv: %r\n");
		return;
	}
	args := kd :: a :: d :: nil;
	for(r := rev(opts); r != nil; r = tl r)
		args = hd r :: args;
	srv->init(nil, "sdgsrv" :: args);
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
	spawn server(nil, kd, sys->sprint("udp!127.0.0.1!%d", port), d, pidc);
	srvpid = <-pidc;
	# the same, losing one data packet in 20 each way, keeping 1024 replies
	# so that a lost reply is still there when its request comes again: what
	# is left to fail is a lost request the client has outrun
	lossyaddr = sys->sprint("udp!127.0.0.1!%d", port+1);
	spawn server("-c" :: "1024" :: "-d" :: "20" :: nil, kd, sys->sprint("udp!127.0.0.1!%d", port+1), d, pidc);
	lossypid = <-pidc;
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
	return mountat(addr, mnt);
}

mountat(addr, mnt: string): string
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

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
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

# ---- a relay, another socket, a second server ----

Udphdr: con 52;

Tap: adt {
	first:	array of byte;	# the first initiation passed
	index:	int;		# the session's index, from a data packet
	have:	int;
	hdr:	array of byte;	# the client's address, as UDP headers give it
	njunk:	int;		# datagrams the other socket has been sent by the server
};

get4(a: array of byte, o: int): int
{
	return int a[o] | int a[o+1] << 8 | int a[o+2] << 16 | int a[o+3] << 24;
}

put4(a: array of byte, o, v: int)
{
	for(i := 0; i < 4; i++)
		a[o+i] = byte (v >> (8*i));
}

# client <-> server at saddr, on port
udprelay(port: int, saddr: string, tap: ref Tap, pidc: chan of int)
{
	pid := sys->pctl(Sys->NEWPGRP, nil);
	(ok, c) := sys->announce(sys->sprint("udp!127.0.0.1!%d", port));
	if(ok < 0 || sys->fprint(c.cfd, "headers") < 0){
		pidc <-= -1;
		return;
	}
	cfd := sys->open(c.dir + "/data", Sys->ORDWR);
	(ok2, sc) := sys->dial(saddr, nil);
	if(cfd == nil || ok2 < 0){
		pidc <-= -1;
		return;
	}
	spawn fromserver(sc.dfd, cfd, tap);
	pidc <-= pid;
	buf := array[2048] of byte;
	for(;;){
		n := sys->read(cfd, buf, len buf);
		if(n <= 0)
			return;
		if(n <= Udphdr)
			continue;
		h := array[Udphdr] of byte;
		h[0:] = buf[0:Udphdr];
		tap.hdr = h;
		m := array[n - Udphdr] of byte;
		m[0:] = buf[Udphdr:n];
		if(int m[0] == 1 && tap.first == nil)
			tap.first = m;
		if(int m[0] == 3 && len m >= 5){
			tap.index = get4(m, 1);
			tap.have = 1;
		}
		sys->write(sc.dfd, m, len m);
	}
}

fromserver(sfd, cfd: ref Sys->FD, tap: ref Tap)
{
	buf := array[2048] of byte;
	for(;;){
		n := sys->read(sfd, buf, len buf);
		if(n <= 0){
			sys->sleep(50);
			continue;
		}
		if(tap.hdr == nil)
			continue;
		p := array[Udphdr + n] of byte;
		p[0:] = tap.hdr;
		p[Udphdr:] = buf[0:n];
		sys->write(cfd, p, len p);
	}
}

# count what the server sends to fd
junkreader(fd: ref Sys->FD, tap: ref Tap, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[2048] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n > 0)
			tap.njunk++;
		else
			sys->sleep(20);
	}
}

# data packets under the session's index that open under no key
junker(fd: ref Sys->FD, tap: ref Tap, n: int, done: chan of int)
{
	for(i := 0; i < n; i++){
		p := array[1 + 4 + 8 + 24] of byte;
		r := random->randombuf(Random->NotQuiteRandom, len p);
		p[0:] = r;
		p[0] = byte 3;
		put4(p, 1, tap.index);
		p[12] &= byte 16r7f;
		sys->write(fd, p, len p);
		sys->sleep(10);
	}
	done <-= 1;
}

killgrp(pid: int)
{
	if(pid < 0)
		return;
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

copykeys(from, dst: string): string
{
	mkdir(dst);
	for(l := "sdgsrv.key" :: "sdgsrv.peer" :: "sdg.psk" :: "sdg.key" :: "sdg.brick" :: nil; l != nil; l = tl l){
		fd := sys->open(from + "/" + hd l, Sys->OREAD);
		b := array[256] of byte;
		n := -1;
		if(fd != nil)
			n = sys->read(fd, b, len b);
		o := sys->create(dst + "/" + hd l, Sys->OWRITE, 8r600);
		if(n <= 0 || o == nil || sys->write(o, b, n) != n)
			return sys->sprint("copy %s: %r", hd l);
	}
	return nil;
}

s3pid := -1;
relaypid := -1;
s3port: int;
tap: ref Tap;

# the second server, its relay, and a session through the relay on m4
setup2(t: ref T)
{
	if(tap != nil)
		return;
	kd2 := scratch + "/keys2";
	if((e := copykeys(scratch + "/keys", kd2)) != nil)
		t.fatal(e);
	(nil, f) := sys->tokenize(addr, "!");
	s3port = int hd tl tl f + 2;
	pidc := chan of int;
	spawn server(nil, kd2, sys->sprint("udp!127.0.0.1!%d", s3port), scratch + "/srv", pidc);
	s3pid = <-pidc;
	sys->sleep(300);
	tap = ref Tap(nil, 0, 0, nil, 0);
	spawn udprelay(s3port + 1, sys->sprint("udp!127.0.0.1!%d", s3port), tap, pidc);
	relaypid = <-pidc;
	if(relaypid < 0)
		t.fatal(sys->sprint("relay: %r"));
	if((e = mountat(sys->sprint("udp!127.0.0.1!%d", s3port + 1), scratch + "/m4")) != nil)
		t.fatal(e);
}

# Junk under the session's index from another socket: none of the
# session's replies go to it.
testJunk(t: ref T)
{
	setup2(t);
	t.assert(tap.have, "the relay saw the session's index");
	(ok, j) := sys->dial(sys->sprint("udp!127.0.0.1!%d", s3port), nil);
	if(ok < 0)
		t.fatal(sys->sprint("dial: %r"));
	pidc := chan of int;
	spawn junkreader(j.dfd, tap, pidc);
	jpid := <-pidc;
	done := chan of int;
	spawn junker(j.dfd, tap, 220, done);
	sys->sleep(100);
	fd := sys->open(scratch + "/m4/slow", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open slow: %r"));
	b := array[100] of byte;
	n := sys->read(fd, b, len b);
	t.assert(n > 0 && string b[0:n] == "slow but here", sys->sprint("the read waiting through the junk gets its bytes (%d: %r)", n));
	<-done;
	sys->sleep(200);
	t.asserteq(tap.njunk, 0, "datagrams the server sent to the junk's socket");
	# and the session still serves
	(bb, err) := readways(scratch + "/m4/big", 4);
	t.assertnil(err, "the session reads on");
	t.assert(same(bb, want), "byte for byte");
	jfd := sys->open(sys->sprint("/prog/%d/ctl", jpid), Sys->OWRITE);
	if(jfd != nil)
		sys->fprint(jfd, "kill");
}

# is the initiation m, sent to the server now, answered?
answered(m: array of byte): int
{
	(ok, c) := sys->dial(sys->sprint("udp!127.0.0.1!%d", s3port), nil);
	if(ok < 0)
		return -1;
	got := chan[1] of int;
	spawn readone(c.dfd, got);
	sys->write(c.dfd, m, len m);
	tick := chan[1] of int;
	spawn after(tick, 800);
	alt {
	n := <-got =>
		return n;
	<-tick =>
		sys->fprint(c.cfd, "hangup");
		return 0;
	}
}

readone(fd: ref Sys->FD, got: chan of int)
{
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n > 0)
		got <-= n;
}

after(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# An initiation recorded from the wire, sent again: not answered by the
# server that took it, nor by one started again with its keys.
testRestart(t: ref T)
{
	setup2(t);
	if(tap.first == nil)
		t.fatal("the relay kept no initiation");
	t.asserteq(answered(tap.first), 0, "the initiation sent again to the same server: bytes answered");
	sys->unmount(nil, scratch + "/m4");
	killgrp(s3pid);
	sys->sleep(300);
	pidc := chan of int;
	spawn server(nil, scratch + "/keys2", sys->sprint("udp!127.0.0.1!%d", s3port), scratch + "/srv", pidc);
	s3pid = <-pidc;
	sys->sleep(400);
	t.asserteq(answered(tap.first), 0, "and to the server started again: bytes answered");
	# a handshake of now is taken
	e := mountat(sys->sprint("udp!127.0.0.1!%d", s3port), scratch + "/m5");
	t.assertnil(e, "a new handshake with the restarted server");
	if(e == nil){
		(b, err) := readways(scratch + "/m5/big", 4);
		t.assert(err == nil && same(b, want), "and its session reads: " + err);
	}
}

hmac16(key, data: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	keyring->hmac_sha256(data, len data, key, d, nil);
	return d[0:16];
}

sha(a: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	keyring->sha256(a, len a, d, nil);
	return d;
}

catb(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

# an initiation that passes mac1 and nothing else, under index i
junkinit(mac1key: array of byte, i: int): array of byte
{
	m := array[1 + 4 + 108 + 16 + 16] of {* => byte 0};
	m[0] = byte 1;
	put4(m, 1, i);
	m[5:] = random->randombuf(Random->NotQuiteRandom, 108);
	m[113:] = hmac16(mac1key, m[0:113]);
	return m;
}

Flood: adt {
	cookies:	int;	# cookie replies
	others:	int;	# anything else
	last:	array of byte;	# the last cookie reply
};

floodreader(fd: ref Sys->FD, f: ref Flood, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[2048] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0){
			sys->sleep(20);
			continue;
		}
		if(n == 1 + 4 + 8 + 16 + 16 && int buf[0] == 4){
			f.cookies++;
			f.last = array[n] of byte;
			f.last[0:] = buf[0:n];
		}else
			f.others++;
	}
}

flooder(fd: ref Sys->FD, mac1key: array of byte, n, ms: int, done: chan of int)
{
	for(i := 0; i < n; i++){
		m := junkinit(mac1key, 1000 + i);
		sys->write(fd, m, len m);
		if(ms > 0)
			sys->sleep(ms);
	}
	done <-= 1;
}

testFlood(t: ref T)
{
	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		t.fatal(sys->sprint("load keyring: %r"));
	spub := hexfile(scratch + "/keys/sdg.brick");
	mac1key := sha(catb(array of byte "mac1", spub));
	ckey := sha(catb(array of byte "cookie--", spub));
	(ok, c) := sys->dial(addr, nil);
	if(ok < 0)
		t.fatal(sys->sprint("dial: %r"));
	f := ref Flood(0, 0, nil);
	pidc := chan of int;
	spawn floodreader(c.dfd, f, pidc);
	rpid := <-pidc;
	sys->sleep(1100);	# a second of the server's own, with nothing in it
	done := chan of int;
	spawn flooder(c.dfd, mac1key, 40, 0, done);
	<-done;
	sys->sleep(500);
	t.assert(f.cookies >= 20, sys->sprint("forty initiations at once: past its budget the server answers with cookies (%d)", f.cookies));
	t.asserteq(f.others, 0, "and with nothing else");
	if(f.last != nil){
		# the cookie opens under the key a client derives, sealed to
		# the initiation's mac1: remake that initiation's mac1 is not
		# possible (its bytes were random), so only its shape is asked
		t.asserteq(len f.last, 45, "a cookie reply's length");
		t.assert(get4(f.last, 1) >= 1000 && get4(f.last, 1) < 1040, "it names the initiation it answers");
	}
	# one whose mac1 we still have: its cookie opens
	m := junkinit(mac1key, 7777);
	f.last = nil;
	for(i := 0; i < 8; i++){
		j := junkinit(mac1key, 2000 + i);
		sys->write(c.dfd, j, len j);
	}
	sys->write(c.dfd, m, len m);
	sys->sleep(300);
	if(f.last == nil || get4(f.last, 1) != 7777)
		t.error("no cookie for the last initiation of a burst");
	else{
		nb := array[12] of {* => byte 0};
		nb[4:] = f.last[5:13];
		ck := keyring->ccpolydecrypt(f.last[13:29], m[113:129], f.last[29:45], ckey, nb);
		t.assert(ck != nil && len ck == 16, "the cookie opens under the key made from the server's public key, sealed to the initiation's mac1");
	}
	# a client through a flood: it is given a cookie, shows it, and is served
	spawn flooder(c.dfd, mac1key, 300, 10, done);
	sys->sleep(200);
	e := mountat(addr, scratch + "/m6");
	t.assertnil(e, "a client connecting through the flood");
	if(e == nil){
		(b, err) := readways(scratch + "/m6/big", 4);
		t.assert(err == nil && same(b, want), "and its session reads: " + err);
	}
	<-done;
	kfd := sys->open(sys->sprint("/prog/%d/ctl", rpid), Sys->OWRITE);
	if(kfd != nil)
		sys->fprint(kfd, "kill");
}

tryserver(kd, a: string, c: chan of string)
{
	sys->pctl(Sys->NEWPGRP|Sys->NEWFD, 0 :: 1 :: nil);
	srv := load Command "/dis/sdgsrv.dis";
	{
		srv->init(nil, "sdgsrv" :: kd :: a :: scratch + "/srv" :: nil);
		c <-= "returned";
	} exception e {
	"*" =>
		c <-= e;
	}
}

# A counter store with nothing in it to trust: the server does not start.
testBadStore(t: ref T)
{
	setup2(t);
	kd3 := scratch + "/keys3";
	if((e := copykeys(scratch + "/keys", kd3)) != nil)
		t.fatal(e);
	fd := sys->create(kd3 + "/sdgsrv.ctr.a", Sys->OWRITE, 8r600);
	sys->fprint(fd, "000000000000000000000001 0000000000000000\n");
	fd = nil;
	c := chan[1] of string;
	spawn tryserver(kd3, sys->sprint("udp!127.0.0.1!%d", s3port + 2), c);
	tick := chan[1] of int;
	spawn after(tick, 2000);
	alt {
	e := <-c =>
		t.assert(len e > 5 && e[0:5] == "fail:", "a store that cannot be trusted stops the server: " + e);
	<-tick =>
		t.error("the server started on a counter store it cannot trust");
	}
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
	t.assert(n > 0 && string b[0:n] == "slow but here", sys->sprint("a read answered after SLOWMS gets its bytes (%d)", n));
	t.assert(ms >= SLOWMS - 20 && ms < SLOWMS + 3000, sys->sprint("in about the server's time, not a deadline's (%d ms)", ms));
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

# a read held open (SLOWMS) while 150 others, one at a time, run past it:
# more than the 64 rids the window keeps, so the floor moves over the open
# one and its run map shifts with the 64th's bit set.  A big's >> copies
# that bit down (it is arithmetic), so rids not yet sent were taken for run
# ("reply gone"), and a map of ones held the session in ran() for good,
# answering nothing
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
			if(!<-sc)	# the slow one answered: on, past it
				t.error("the read held open, its rid passed by the window, got no bytes (its retransmission was answered gone)");
	}
	t.asserteq(bad, 0, "every read past a read held open answered, and right");
}

slowread(f: string, c: chan of int)
{
	fd := sys->open(f, Sys->OREAD);
	b := array[100] of byte;
	n := -1;
	if(fd != nil)
		n = sys->read(fd, b, len b);
	c <-= n > 0 && string b[0:n] == "slow but here";
}

# eight reads at once through a server losing one data packet in 20 each
# way: every lost request or reply is sent again and the file arrives whole.
# The client sent past the server's window of 64 rids while a lost request
# waited for its retransmission, and the server, its window moved on,
# answered it "reply gone" (STYX-DGRAM Rev S7).  With the brick's 16
# replies a lost reply can still be gone by then; reads re-sent under a
# new rid would cover that, and sdg(2) does not do it
testLossy(t: ref T)
{
	if((e := mountat(lossyaddr, scratch + "/m3")) != nil)
		t.fatal(e);
	for(i := 0; i < 3; i++){
		(b, err) := readways(scratch + "/m3/big", 8);
		t.assertnil(err, sys->sprint("pass %d: eight reads at once over a lossy link", i));
		t.assert(same(b, want), sys->sprint("pass %d: the file byte for byte", i));
	}
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
	testing->own();	# what this starts is killed at the end (reap)
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
	run("Sdgsrv/Lossy", testLossy);
	run("Sdgsrv/Junk", testJunk);
	run("Sdgsrv/Restart", testRestart);
	run("Sdgsrv/BadStore", testBadStore);
	run("Sdgsrv/Flood", testFlood);
	# the mounts (their relays end), the server and the slow file's, so that emu can exit
	sys->unmount(nil, scratch + "/m1");
	sys->unmount(nil, scratch + "/m2");
	sys->unmount(nil, scratch + "/m3");
	sys->unmount(nil, scratch + "/m4");
	sys->unmount(nil, scratch + "/m5");
	sys->unmount(nil, scratch + "/m6");
	for(pl := srvpid :: lossypid :: slowpid :: s3pid :: relaypid :: nil; pl != nil; pl = tl pl)
		if(hd pl >= 0){
			fd := sys->open(sys->sprint("/prog/%d/ctl", hd pl), Sys->OWRITE);
			if(fd != nil)
				sys->fprint(fd, "killgrp");
		}
	# nothing of the test's is left running: run as emu's own program
	# it never exited, for the servers and waiting procs it left
	testing->reap();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

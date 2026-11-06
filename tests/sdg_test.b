implement SdgTest;

#
# sdg(2), the datagram transport's client: its Noise IKpsk2 handshake
# against a responder written here from the Noise specification (over
# UDP on the loopback), and its handshake counter's store.
#
# Review 2026-11-06 of #1015: P1015-03, a DH giving no shared secret
# (a low-order key) mixed into the key instead of refused; P1015-04,
# the counter returned though its write failed, written in place, and
# allocated by two at once.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	keyring: Keyring;
include "security.m";
	random: Random;
include "sdg.m";
	sdg: Sdg;
include "testing.m";
	testing: Testing;
	T: import testing;

SdgTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/sdg_test.b";

passed := 0;
failed := 0;
skipped := 0;

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
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

#
# A scratch directory of the host's for each test's counter files.
#
scratchn := 0;
runid := "";

scratch(t: ref T): string
{
	base := "/tmp/sdg_test";
	sys->create(base, Sys->OREAD, Sys->DMDIR|8r700);
	if(runid == nil){
		# A fresh emu's pids repeat; the clock does not.
		fd := sys->open("/dev/time", Sys->OREAD);
		buf := array[32] of byte;
		n := 0;
		if(fd != nil)
			n = sys->read(fd, buf, len buf);
		if(n > 0)
			runid = string buf[0:n];
		else
			runid = string sys->millisec();
		if(runid[len runid - 1] == '\n')
			runid = runid[0:len runid - 1];
	}
	d := sys->sprint("%s/%s.%d", base, runid, scratchn++);
	fd := sys->create(d, Sys->OREAD, Sys->DMDIR|8r700);
	if(fd == nil)
		t.fatal(sys->sprint("can't make %s: %r", d));
	return d;
}

writefile(f, s: string): int
{
	fd := sys->create(f, Sys->OWRITE, 8r600);
	if(fd == nil)
		return -1;
	b := array of byte s;
	return sys->write(fd, b, len b);
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

exists(f: string): int
{
	(ok, nil) := sys->stat(f);
	return ok >= 0;
}

# ===================================================================
# P1015-04: the counter
# ===================================================================

testCounterFresh(t: ref T)
{
	f := scratch(t) + "/sdg.ctr";
	(v, err) := sdg->ctrnext(f, big 1000);
	t.assertnil(err, "first value from no store");
	t.assert(v == big 1000, sys->sprint("the clock's value when nothing came before: %bd", v));
	(v, err) = sdg->ctrnext(f, big 1000);
	t.assertnil(err, "second value");
	t.assert(v == big 1001, sys->sprint("one more than the last on the same clock: %bd", v));
	(v, err) = sdg->ctrnext(f, big 2000000);
	t.assert(err == nil && v == big 2000000, sys->sprint("the clock once it is ahead: %bd %s", v, err));
	t.assert(exists(f + ".a") && exists(f + ".b"), "both slots written");
	t.assert(!exists(f + ".lock"), "the lock let go");
}

testCounterBackwardClock(t: ref T)
{
	f := scratch(t) + "/sdg.ctr";
	sdg->ctrnext(f, big 5000000);
	(v, err) := sdg->ctrnext(f, big 10);
	t.assert(err == nil && v == big 5000001, sys->sprint("a clock stepped back: one more than the last, %bd %s", v, err));
	(v, err) = sdg->ctrnext(f, big 0);
	t.assert(err == nil && v == big 5000002, sys->sprint("and again: %bd %s", v, err));
}

testCounterLegacy(t: ref T)
{
	d := scratch(t);
	f := d + "/sdg.ctr";
	writefile(f, "777777\n");
	(v, err) := sdg->ctrnext(f, big 5);
	t.assert(err == nil && v == big 777778, sys->sprint("the old single-file counter read: %bd %s", v, err));
	(v, err) = sdg->ctrnext(f, big 5);
	t.assert(err == nil && v == big 777779, sys->sprint("and kept to after the slots are written: %bd %s", v, err));
}

# A crash or a short write spoils the slot being written: the older.
testCounterTornWrite(t: ref T)
{
	f := scratch(t) + "/sdg.ctr";
	sdg->ctrnext(f, big 100);		# .a = 100
	sdg->ctrnext(f, big 100);		# .b = 101, newest; .a is the next target
	for(l := "" :: "1" :: "10" :: "102" :: "102 " :: "102 0123" :: "102 0123456789abcdef" :: "garbage\n" :: nil; l != nil; l = tl l){
		writefile(f + ".a", hd l);
		(v, err) := sdg->ctrnext(f, big 0);
		t.assert(err == nil && v > big 101, sys->sprint("the older slot left as %#q: the newer kept, %bd %s", hd l, v, err));
	}
}

testCounterCorrupt(t: ref T)
{
	f := scratch(t) + "/sdg.ctr";
	writefile(f + ".a", "");
	(nil, err) := sdg->ctrnext(f, big 1);
	t.assertnotnil(err, "an empty slot and nothing valid: refused");

	f = scratch(t) + "/sdg.ctr";
	writefile(f + ".a", "5 0000000000000000\n");
	writefile(f + ".b", "6 0000000000000000\n");
	(nil, err) = sdg->ctrnext(f, big 1);
	t.assertnotnil(err, "two slots whose checks are wrong: refused");

	f = scratch(t) + "/sdg.ctr";
	writefile(f, "12x\n");
	(nil, err) = sdg->ctrnext(f, big 1);
	t.assertnotnil(err, "an old-format counter that is not a number: refused");
	t.assert(!exists(f + ".a") && !exists(f + ".b"), "and nothing written");
	t.assert(!exists(f + ".lock"), "the lock let go after a refusal");
}

testCounterUnwritable(t: ref T)
{
	(nil, err) := sdg->ctrnext("/tmp/sdg_test/no/such/dir/sdg.ctr", big 1);
	t.assertnotnil(err, "a directory that does not exist: refused");
	t.log(err);

	d := scratch(t);
	f := d + "/sdg.ctr";
	(v, nil) := sdg->ctrnext(f, big 1);
	dir := sys->nulldir;
	dir.mode = Sys->DMDIR | 8r500;
	if(sys->wstat(d, dir) < 0)
		t.fatal(sys->sprint("can't make %s read-only: %r", d));
	if(sys->create(d + "/probe", Sys->OWRITE, 8r600) != nil){
		dir.mode = Sys->DMDIR | 8r700;
		sys->wstat(d, dir);
		t.skip("a read-only directory is writable here (running as root?)");
	}
	t0 := sys->millisec();
	(nil, err) = sdg->ctrnext(f, big 1);
	ms := sys->millisec() - t0;
	t.assertnotnil(err, "a read-only directory: refused");
	t.log(err);
	t.assert(ms < 1000, sys->sprint("at once, not after the lock's wait: %d ms", ms));
	dir.mode = Sys->DMDIR | 8r700;
	sys->wstat(d, dir);
	(v2, err2) := sdg->ctrnext(f, big 1);
	t.assert(err2 == nil && v2 == v + big 1, sys->sprint("writable again: on from the last, %bd %s", v2, err2));
}

# The lock is had but the slot to be written is not writable: the value
# was not committed, so it is not returned (it was, P1015-04).
testCounterWriteFails(t: ref T)
{
	f := scratch(t) + "/sdg.ctr";
	(v, err) := sdg->ctrnext(f, big 50);	# .a = 50; .b is the next written
	t.assert(err == nil && v == big 50, sys->sprint("first value: %bd %s", v, err));
	if(sys->create(f + ".b", Sys->OREAD, Sys->DMDIR|8r700) == nil)
		t.fatal(sys->sprint("can't make %s a directory: %r", f + ".b"));
	(v, err) = sdg->ctrnext(f, big 0);
	t.assertnotnil(err, sys->sprint("the slot to be written a directory: refused (got %bd)", v));
	t.log(err);
	t.assert(!exists(f + ".lock"), "the lock let go");

	f = scratch(t) + "/sdg.ctr";
	sdg->ctrnext(f, big 50);			# .a = 50
	writefile(f + ".b", "garbage\n");
	dir := sys->nulldir;
	dir.mode = 8r400;
	if(sys->wstat(f + ".b", dir) < 0)
		t.fatal(sys->sprint("can't make %s read-only: %r", f + ".b"));
	if(sys->open(f + ".b", Sys->OWRITE) != nil)
		t.skip("a read-only file is writable here (running as root?)");
	(v, err) = sdg->ctrnext(f, big 0);
	t.assertnotnil(err, sys->sprint("the slot to be written read-only: refused (got %bd)", v));
	t.log(err);
	dir.mode = 8r600;
	sys->wstat(f + ".b", dir);
	(v, err) = sdg->ctrnext(f, big 0);
	t.assert(err == nil && v == big 51, sys->sprint("writable again: on from the last committed, %bd %s", v, err));
}

testCounterStaleLock(t: ref T)
{
	f := scratch(t) + "/sdg.ctr";
	writefile(f + ".lock", "");
	dir := sys->nulldir;
	dir.mtime = 1000000;	# 1970: left by a crash
	if(sys->wstat(f + ".lock", dir) < 0)
		t.fatal(sys->sprint("can't age the lock: %r"));
	(v, err) := sdg->ctrnext(f, big 7);
	t.assert(err == nil && v == big 7, sys->sprint("a lock left by a crash is taken: %bd %s", v, err));
}

testCounterHeldLock(t: ref T)
{
	f := scratch(t) + "/sdg.ctr";
	writefile(f + ".lock", "");
	spawn unlockafter(f + ".lock", 300);
	t0 := sys->millisec();
	(v, err) := sdg->ctrnext(f, big 7);
	ms := sys->millisec() - t0;
	t.assert(err == nil && v == big 7, sys->sprint("a held lock is waited for: %bd %s", v, err));
	t.assert(ms >= 250, sys->sprint("until it is let go: %d ms", ms));
}

unlockafter(f: string, ms: int)
{
	sys->sleep(ms);
	sys->remove(f);
}

# Two allocators at once (in another process, too) never give one value
# twice.
testCounterConcurrent(t: ref T)
{
	f := scratch(t) + "/sdg.ctr";
	NP: con 6;
	NV: con 15;
	c := chan of (big, string);
	for(i := 0; i < NP; i++)
		spawn allocator(f, NV, c);
	seen := array[NP*NV + 1] of {* => 0};
	errs := 0;
	for(i = 0; i < NP*NV; i++){
		(v, err) := <-c;
		if(err != nil){
			errs++;
			t.log(err);
			continue;
		}
		if(v < big 1 || v > big (NP*NV))
			t.error(sys->sprint("value %bd outside 1..%d", v, NP*NV));
		else if(seen[int v]++)
			t.error(sys->sprint("value %bd given twice", v));
	}
	t.asserteq(errs, 0, "no allocation refused");
}

allocator(f: string, n: int, c: chan of (big, string))
{
	sys->pctl(Sys->NEWPGRP, nil);
	for(i := 0; i < n; i++)
		c <-= sdg->ctrnext(f, big 1);
}

# ===================================================================
# P1015-03: the handshake, against a responder written from the Noise
# specification (Noise_IKpsk2_25519_ChaChaPoly_SHA256)
# ===================================================================

NAME:	con "Noise_IKpsk2_25519_ChaChaPoly_SHA256";
PROLOGUE:	con "styxbrick sdg 1";
Pinit, Presp: con 1+iota;
INITLEN:	con 1 + 4 + 108 + 16 + 16;
Udphdrlen:	con 52;

sha(a: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	keyring->sha256(a, len a, d, nil);
	return d;
}

hmac(key, data: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	keyring->hmac_sha256(data, len data, key, d, nil);
	return d;
}

cat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

# Noise's HKDF with two or three outputs.
hkdf(ck, ikm: array of byte): (array of byte, array of byte, array of byte)
{
	tk := hmac(ck, ikm);
	o1 := hmac(tk, array[] of {byte 1});
	o2 := hmac(tk, cat(o1, array[] of {byte 2}));
	o3 := hmac(tk, cat(o2, array[] of {byte 3}));
	return (o1, o2, o3);
}

nonce(n: int): array of byte
{
	b := array[12] of {* => byte 0};
	b[4] = byte n;
	return b;
}

# The responder's SymmetricState.
Ss: adt {
	ck, h, k:	array of byte;
	n:	int;
};

mixhash(s: ref Ss, d: array of byte)
{
	s.h = sha(cat(s.h, d));
}

mixkey(s: ref Ss, ikm: array of byte)
{
	(ck, k, nil) := hkdf(s.ck, ikm);
	s.ck = ck;
	s.k = k;
	s.n = 0;
}

encrypt(s: ref Ss, p: array of byte): array of byte
{
	(c, tag) := keyring->ccpolyencrypt(p, s.h, s.k, nonce(s.n++));
	c = cat(c, tag);
	mixhash(s, c);
	return c;
}

decrypt(s: ref Ss, c: array of byte): array of byte
{
	p := keyring->ccpolydecrypt(c[0:len c - 16], s.h, c[len c - 16:], s.k, nonce(s.n));
	if(p == nil)
		return nil;
	s.n++;
	mixhash(s, c);
	return p;
}

# What the responder does with message 2's DHs.
Mhonest, Mloworder: con iota;

Responder: adt {
	priv, pub, psk:	array of byte;
	mode:	int;
	inits:	int;		# initiations received
	datas:	int;		# packets after the handshake
};

# Answer initiations on fd until told to stop; report what was seen.
responder(r: ref Responder, fd: ref Sys->FD, stop: chan of int, done: chan of ref Responder)
{
	pkts := chan of array of byte;
	spawn udpreader(fd, pkts);
	for(;;) alt {
	<-stop =>
		done <-= r;
		return;
	p := <-pkts =>
		if(p == nil){
			done <-= r;
			return;
		}
		hdr := p[0:Udphdrlen];
		m := p[Udphdrlen:];
		if(len m == INITLEN && int m[0] == Pinit){
			r.inits++;
			resp := answer(r, m);
			if(resp != nil){
				out := cat(hdr, resp);
				sys->write(fd, out, len out);
			}
		}else
			r.datas++;
	}
}

udpreader(fd: ref Sys->FD, pkts: chan of array of byte)
{
	buf := array[2048] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0){
			pkts <-= nil;
			return;
		}
		pkts <-= buf[0:n];
	}
}

# Message 2 for message 1 m, or nil if m does not authenticate.
answer(r: ref Responder, m: array of byte): array of byte
{
	sender := m[1:5];
	m1 := m[5:5+108];
	s := ref Ss;
	s.h = sha(array of byte NAME);
	s.ck = s.h;
	mixhash(s, array of byte PROLOGUE);
	mixhash(s, r.pub);
	ei := m1[0:32];
	mixhash(s, ei);
	mixkey(s, ei);				# e, with a psk
	mixkey(s, keyring->x25519(r.priv, ei));	# es
	si := decrypt(s, m1[32:80]);		# s
	if(si == nil)
		return nil;
	mixkey(s, keyring->x25519(r.priv, si));	# ss
	if(decrypt(s, m1[80:108]) == nil)	# the counter
		return nil;

	re, ee, se: array of byte;
	case r.mode {
	Mhonest =>
		ep := random->randombuf(Random->NotQuiteRandom, 32);
		re = keyring->x25519_base(ep);
		ee = keyring->x25519(ep, ei);
		se = keyring->x25519(ep, si);
	Mloworder =>
		# A responder holding the static key and the PSK, sending the
		# point 0 as its ephemeral: every DH with it is nil, and what
		# the initiator mixed in for one (nil, before P1015-03) is
		# mixed in here, so message 2 authenticates unless nil is
		# refused.
		re = array[32] of {* => byte 0};
		ee = nil;
		se = nil;
	}
	mixhash(s, re);
	mixkey(s, re);				# e
	mixkey(s, ee);				# ee
	mixkey(s, se);				# se
	(ck, th, tk) := hkdf(s.ck, r.psk);	# psk
	s.ck = ck;
	mixhash(s, th);
	s.k = tk;
	s.n = 0;
	c := encrypt(s, array[] of {byte 1});

	out := array[1 + 4 + 4] of byte;
	out[0] = byte Presp;
	out[1:] = array[] of {byte 16r21, byte 16r43, byte 16r65, byte 16r07};	# our index
	out[5:] = sender;
	return cat(cat(out, re), c);
}

Rig: adt {
	addr:	string;
	fd:	ref Sys->FD;
	stop:	chan of int;
	done:	chan of ref Responder;
};

# A responder on the loopback; nil if UDP is not to be had.
rig(r: ref Responder): ref Rig
{
	for(try := 0; try < 20; try++){
		port := 20000 + int (random->randombuf(Random->NotQuiteRandom, 2)[0]) * 150 + try;
		# On every address: one announced on 127.0.0.1 is an IPv6 socket
		# bound to the v4-mapped address, which macOS will not send from
		# ("No route to host").
		(ok, c) := sys->announce(sys->sprint("udp!*!%d", port));
		if(ok < 0)
			continue;
		if(sys->fprint(c.cfd, "headers") < 0)
			return nil;
		fd := sys->open(c.dir + "/data", Sys->ORDWR);
		if(fd == nil)
			return nil;
		g := ref Rig(sys->sprint("udp!127.0.0.1!%d", port), fd, chan of int, chan of ref Responder);
		spawn responder(r, fd, g.stop, g.done);
		return g;
	}
	return nil;
}

Kp: adt {
	priv, pub:	array of byte;
};

keypair(): ref Kp
{
	p := random->randombuf(Random->NotQuiteRandom, 32);
	return ref Kp(p, keyring->x25519_base(p));
}

Pair: adt {
	me, brick:	ref Kp;
	psk:	array of byte;
	ctr:	string;
};

pair(t: ref T): ref Pair
{
	return ref Pair(keypair(), keypair(), random->randombuf(Random->NotQuiteRandom, 32),
		scratch(t) + "/sdg.ctr");
}

keys(p: ref Pair): ref Sdg->Keys
{
	return ref Sdg->Keys(p.me.priv, p.brick.pub, p.psk, p.ctr);
}

# relay(), in a process of its own group, with its error or nil and the
# time it took; the pipe's other end is kept open by the caller.
Result: adt {
	err:	string;
	ms:	int;
	pid:	int;
};

relayer(addr: string, k: ref Sdg->Keys, fd: ref Sys->FD, c: chan of ref Result)
{
	pid := sys->pctl(Sys->NEWPGRP, nil);
	t0 := sys->millisec();
	err := sdg->relay(addr, k, fd);
	c <-= ref Result(err, sys->millisec() - t0, pid);
}

killgrp(pid: int)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

# Run relay against responder r with keys k; returns (result, responder).
handshake(t: ref T, r: ref Responder, k: ref Sdg->Keys, limit: int): (ref Result, ref Responder)
{
	g := rig(r);
	if(g == nil)
		t.skip(sys->sprint("no UDP on the loopback: %r"));
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	c := chan of ref Result;
	spawn relayer(g.addr, k, p[0], c);
	tick := chan of int;
	spawn timer(tick, limit);
	res: ref Result;
	alt {
	res = <-c =>
		;
	<-tick =>
		res = ref Result("(still running)", limit, 0);
	}
	sys->sleep(300);	# for anything the relay sends after
	g.stop <-= 1;
	got := <-g.done;
	if(res.pid != 0)
		killgrp(res.pid);
	p[1] = nil;
	return (res, got);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

testHandshakeHonest(t: ref T)
{
	p := pair(t);
	r := ref Responder(p.brick.priv, p.brick.pub, p.psk, Mhonest, 0, 0);
	(res, got) := handshake(t, r, keys(p), 15000);
	t.assertnil(res.err, "a responder following the specification: the handshake completes");
	t.assert(got.inits >= 1, sys->sprint("it saw an initiation (%d)", got.inits));
}

testHandshakeWrongPSK(t: ref T)
{
	p := pair(t);
	r := ref Responder(p.brick.priv, p.brick.pub, random->randombuf(Random->NotQuiteRandom, 32), Mhonest, 0, 0);
	(res, nil) := handshake(t, r, keys(p), 15000);
	t.assertnotnil(res.err, "a responder with another PSK: refused");
}

# The responder's ephemeral key is a low-order point: ee and se give
# no shared secret, and message 2 must not authenticate, though it
# would have when nil was mixed in for them.
testHandshakeLowOrderEphemeral(t: ref T)
{
	p := pair(t);
	r := ref Responder(p.brick.priv, p.brick.pub, p.psk, Mloworder, 0, 0);
	(res, got) := handshake(t, r, keys(p), 15000);
	t.assertnotnil(res.err, "message 2 with a low-order ephemeral key: refused");
	t.log(sys->sprint("%s after %d ms, %d initiations", res.err, res.ms, got.inits));
	t.assert(got.inits >= 2, sys->sprint("its responses dropped, the initiator trying again (%d)", got.inits));
	t.asserteq(got.datas, 0, "nothing sent as a session");
}

# The server key configured is a low-order point: es and ss give no
# shared secret, and nothing is sent.
testHandshakeLowOrderStatic(t: ref T)
{
	# u = 0, u = 1, u = p - 1 (order 2), and u = p (0 not reduced)
	lows := array[] of {
		array[32] of {* => byte 0},
		cat(array[] of {byte 1}, array[31] of {* => byte 0}),
		cat(array[] of {byte 16rec}, cat(array[30] of {* => byte 16rff}, array[] of {byte 16r7f})),
		cat(array[] of {byte 16red}, cat(array[30] of {* => byte 16rff}, array[] of {byte 16r7f})),
	};
	for(i := 0; i < len lows; i++){
		p := pair(t);
		p.brick.pub = lows[i];
		r := ref Responder(p.brick.priv, p.brick.pub, p.psk, Mhonest, 0, 0);
		(res, got) := handshake(t, r, keys(p), 5000);
		t.assertnotnil(res.err, sys->sprint("low-order server key %d: refused", i));
		# Refused before anything is sent, not after the handshake's
		# deadline as an unanswered one is (the time is sdg's own
		# random index and ephemeral key, slow from ReallyRandom).
		t.assert(res.ms < Sdg->HSDEADLINE, sys->sprint("low-order server key %d: refused before the deadline (%d ms): %s", i, res.ms, res.err));
		t.asserteq(got.inits, 0, sys->sprint("low-order server key %d: nothing sent", i));
	}
}

testHandshakeKeyLengths(t: ref T)
{
	p := pair(t);
	good := keys(p);
	bad := array[] of {
		ref Sdg->Keys(good.key[0:31], good.server, good.psk, good.ctrfile),
		ref Sdg->Keys(cat(good.key, array[1] of byte), good.server, good.psk, good.ctrfile),
		ref Sdg->Keys(good.key, good.server[0:31], good.psk, good.ctrfile),
		ref Sdg->Keys(good.key, nil, good.psk, good.ctrfile),
		ref Sdg->Keys(good.key, good.server, good.psk[0:16], good.ctrfile),
		ref Sdg->Keys(good.key, good.server, good.psk, nil),
	};
	for(i := 0; i < len bad; i++){
		err := sdg->relay("udp!127.0.0.1!9", bad[i], nil);
		t.assertnotnil(err, sys->sprint("malformed keys %d: refused", i));
		t.log(err);
	}
	t.assert(!exists(good.ctrfile + ".a"), "no counter spent on them");
}

# A counter that cannot be committed: nothing sent.
testHandshakeCounterRefused(t: ref T)
{
	p := pair(t);
	writefile(p.ctr + ".a", "");
	r := ref Responder(p.brick.priv, p.brick.pub, p.psk, Mhonest, 0, 0);
	(res, got) := handshake(t, r, keys(p), 5000);
	t.assertnotnil(res.err, "a counter store holding nothing to trust: refused");
	t.asserteq(got.inits, 0, "nothing sent");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	keyring = load Keyring Keyring->PATH;
	random = load Random Random->PATH;
	testing = load Testing Testing->PATH;
	sdg = load Sdg Sdg->PATH;
	if(testing == nil || sdg == nil || keyring == nil || random == nil){
		sys->fprint(sys->fildes(2), "sdg_test: can't load: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	err := sdg->init();
	if(err != nil){
		sys->fprint(sys->fildes(2), "sdg_test: %s\n", err);
		raise "fail:init";
	}
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("CounterFresh", testCounterFresh);
	run("CounterBackwardClock", testCounterBackwardClock);
	run("CounterLegacy", testCounterLegacy);
	run("CounterTornWrite", testCounterTornWrite);
	run("CounterCorrupt", testCounterCorrupt);
	run("CounterUnwritable", testCounterUnwritable);
	run("CounterWriteFails", testCounterWriteFails);
	run("CounterStaleLock", testCounterStaleLock);
	run("CounterHeldLock", testCounterHeldLock);
	run("CounterConcurrent", testCounterConcurrent);
	run("HandshakeHonest", testHandshakeHonest);
	run("HandshakeWrongPSK", testHandshakeWrongPSK);
	run("HandshakeLowOrderEphemeral", testHandshakeLowOrderEphemeral);
	run("HandshakeLowOrderStatic", testHandshakeLowOrderStatic);
	run("HandshakeKeyLengths", testHandshakeKeyLengths);
	run("HandshakeCounterRefused", testHandshakeCounterRefused);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

implement Sdg;

#
# Styx over datagrams, the client (initiator) side.  The wire format and
# the rules are in the styxbrick repository's docs/STYX-DGRAM.md; the
# brick's side is its src/sdg.c and src/noise.c.
#
# The relay is one core process fed by channels: requests read from the
# mount driver's pipe, decrypted packets from the network, and a clock.
# It owns all session state, so nothing needs locking.
#

include "sys.m";
	sys: Sys;
include "keyring.m";
	keyring: Keyring;
include "security.m";
	random: Random;
include "sdg.m";

HASHLEN:	con 32;
NAME:	con "Noise_IKpsk2_25519_ChaChaPoly_SHA256";
PROLOGUE:	con "styxbrick sdg 1";

Pinit, Presp, Pdata, Pcookie: con 1+iota;
INITLEN:	con 1 + 4 + 108 + 16 + 16;
RESPLEN:	con 1 + 4 + 4 + 32 + 1 + 16;
COOKIELEN:	con 1 + 4 + 8 + 16 + 16;

Tversion:	con 100;
Rerror:	con 107;
Tflush:	con 108;
Twrite:	con 118;

init(): string
{
	sys = load Sys Sys->PATH;
	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		return sys->sprint("can't load %s: %r", Keyring->PATH);
	random = load Random Random->PATH;
	if(random == nil)
		return sys->sprint("can't load %s: %r", Random->PATH);
	return nil;
}

#
# Noise (initiator only).  The comments name the specification's
# functions; noise.c in the styxbrick repository is the other side.
#
Hs: adt {
	ck:	array of byte;
	h:	array of byte;
	k:	array of byte;
	n:	big;
	s, spub, e, epub, rs, re, psk:	array of byte;

	mixhash:	fn(hs: self ref Hs, d: array of byte);
	mixkey:	fn(hs: self ref Hs, ikm: array of byte);
	mixkeyandhash:	fn(hs: self ref Hs, ikm: array of byte);
	encrypthash:	fn(hs: self ref Hs, p: array of byte): array of byte;
	decrypthash:	fn(hs: self ref Hs, c: array of byte): array of byte;
	dh:	fn(hs: self ref Hs, priv, pub: array of byte);
};

sha256(a: array of byte): array of byte
{
	d := array[HASHLEN] of byte;
	keyring->sha256(a, len a, d, nil);
	return d;
}

hmac(key, data: array of byte): array of byte
{
	d := array[HASHLEN] of byte;
	keyring->hmac_sha256(data, len data, key, d, nil);
	return d;
}

hkdf(ck, ikm: array of byte): (array of byte, array of byte, array of byte)
{
	t := hmac(ck, ikm);
	o1 := hmac(t, array[] of {byte 1});
	o2 := hmac(t, cat(o1, array[] of {byte 2}));
	o3 := hmac(t, cat(o2, array[] of {byte 3}));
	return (o1, o2, o3);
}

nonce(n: big): array of byte
{
	b := array[12] of {* => byte 0};
	for(i := 0; i < 8; i++)
		b[4+i] = byte (n >> (8*i));
	return b;
}

seal(k: array of byte, n: big, ad, p: array of byte): array of byte
{
	(c, tag) := keyring->ccpolyencrypt(p, ad, k, nonce(n));
	return cat(c, tag);
}

# nil if forged (p must not be empty: see docs/STYX-DGRAM.md)
unseal(k: array of byte, n: big, ad, c: array of byte): array of byte
{
	if(len c <= 16)
		return nil;
	return keyring->ccpolydecrypt(c[0:len c - 16], ad, c[len c - 16:], k, nonce(n));
}

Hs.mixhash(hs: self ref Hs, d: array of byte)
{
	hs.h = sha256(cat(hs.h, d));
}

Hs.mixkey(hs: self ref Hs, ikm: array of byte)
{
	(ck, tk, nil) := hkdf(hs.ck, ikm);
	hs.ck = ck;
	hs.k = tk;
	hs.n = big 0;
}

Hs.mixkeyandhash(hs: self ref Hs, ikm: array of byte)
{
	(ck, th, tk) := hkdf(hs.ck, ikm);
	hs.ck = ck;
	hs.mixhash(th);
	hs.k = tk;
	hs.n = big 0;
}

Hs.encrypthash(hs: self ref Hs, p: array of byte): array of byte
{
	c := seal(hs.k, hs.n, hs.h, p);
	hs.n++;
	hs.mixhash(c);
	return c;
}

Hs.decrypthash(hs: self ref Hs, c: array of byte): array of byte
{
	p := unseal(hs.k, hs.n, hs.h, c);
	if(p == nil)
		return nil;
	hs.n++;
	hs.mixhash(c);
	return p;
}

Hs.dh(hs: self ref Hs, priv, pub: array of byte)
{
	hs.mixkey(keyring->x25519(priv, pub));
}

handshake1(k: ref Keys, payload: array of byte): (ref Hs, array of byte)
{
	hs := ref Hs;
	hs.h = sha256(array of byte NAME);	# the name exceeds HASHLEN
	hs.ck = hs.h;
	hs.mixhash(array of byte PROLOGUE);
	hs.s = k.key;
	hs.spub = keyring->x25519_base(k.key);
	hs.rs = k.server;
	hs.psk = k.psk;
	hs.mixhash(hs.rs);		# pre-message: the responder's static key
	hs.e = random->randombuf(Random->ReallyRandom, 32);
	hs.epub = keyring->x25519_base(hs.e);
	m := hs.epub;
	hs.mixhash(hs.epub);		# e (and, in a psk handshake, MixKey too)
	hs.mixkey(hs.epub);
	hs.dh(hs.e, hs.rs);		# es
	m = cat(m, hs.encrypthash(hs.spub));	# s
	hs.dh(hs.s, hs.rs);		# ss
	m = cat(m, hs.encrypthash(payload));
	return (hs, m);
}

# Message 2: returns its payload, or nil if it does not authenticate.
handshake2(hs: ref Hs, m: array of byte): array of byte
{
	if(len m < 32 + 16 + 1)
		return nil;
	hs.re = m[0:32];
	hs.mixhash(hs.re);
	hs.mixkey(hs.re);
	hs.dh(hs.e, hs.re);		# ee
	hs.dh(hs.s, hs.re);		# se
	hs.mixkeyandhash(hs.psk);	# psk
	return hs.decrypthash(m[32:]);
}

split(hs: ref Hs): (array of byte, array of byte)
{
	(k1, k2, nil) := hkdf(hs.ck, nil);
	return (k1, k2);
}

#
# The session.
#
Sess: adt {
	fd:	ref Sys->FD;	# the UDP connection
	me, them:	int;
	ksend, krecv:	array of byte;
	ctr:	big;
	recvmax:	big;
	window:	big;
	lastsend:	int;

	send:	fn(s: self ref Sess, plain: array of byte);
	fresh:	fn(s: self ref Sess, c: big): int;
};

Sess.send(s: self ref Sess, plain: array of byte)
{
	hdr := array[13] of byte;
	hdr[0] = byte Pdata;
	put4(hdr, 1, s.them);
	for(i := 0; i < 8; i++)
		hdr[5+i] = byte (s.ctr >> (8*i));
	pkt := cat(hdr, seal(s.ksend, s.ctr, hdr, plain));
	s.ctr++;
	sys->write(s.fd, pkt, len pkt);
	s.lastsend = sys->millisec();
}

# The anti-replay window (64): 1 if c is new, recording it.
Sess.fresh(s: self ref Sess, c: big): int
{
	if(s.recvmax >= big 64 && c + big 64 <= s.recvmax)
		return 0;
	if(c > s.recvmax || (s.recvmax == big 0 && s.window == big 0)){
		shift := c - s.recvmax;
		if(shift >= big 64)
			s.window = big 0;
		else
			s.window <<= int shift;
		s.window |= big 1;
		s.recvmax = c;
		return 1;
	}
	bit := big 1 << int (s.recvmax - c);
	if((s.window & bit) != big 0)
		return 0;
	s.window |= bit;
	return 1;
}

# The initiation counter: the clock in ns, but never less than one more
# than the last value used, persisted before it is sent.
counter(f: string): array of byte
{
	now := big 0;
	if((fd := sys->open("/dev/time", Sys->OREAD)) != nil){
		buf := array[64] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0)
			now = big string buf[0:n] * big 1000;	# microseconds to ns
	}
	last := big 0;
	if((fd = sys->open(f, Sys->OREAD)) != nil){
		buf := array[64] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0)
			last = big string buf[0:n];
	}
	v := now;
	if(v <= last)
		v = last + big 1;
	if((fd = sys->create(f, Sys->OWRITE, 8r600)) != nil)
		sys->fprint(fd, "%bd\n", v);
	b := array[12] of byte;
	secs := v / big 1000000000;
	ns := v % big 1000000000;
	for(i := 0; i < 8; i++)
		b[i] = byte (secs >> (8*(7-i)));
	for(i = 0; i < 4; i++)
		b[8+i] = byte (ns >> (8*(3-i)));
	return b;
}

mac16(key, data: array of byte): array of byte
{
	return hmac(key, data)[0:16];
}

connect(addr: string, k: ref Keys): (ref Sess, string)
{
	(ok, c) := sys->dial(addr, nil);
	if(ok < 0)
		return (nil, sys->sprint("can't dial %s: %r", addr));
	s := ref Sess(c.dfd, 0, 0, nil, nil, big 0, big 0, big 0, 0);
	mac1key := sha256(cat(array of byte "mac1", k.server));
	ckey := sha256(cat(array of byte "cookie--", k.server));
	cookie: array of byte;
	timer := chan of int;
	pkts := chan of array of byte;
	rpid := chan of int;
	spawn reader1(s.fd, pkts, rpid);
	reader := <-rpid;
	deadline := sys->millisec() + HSDEADLINE;
	wait := 250;
	while(sys->millisec() < deadline){
		# A fresh initiation each try (an accepted one would be refused as old).
		me := get4(random->randombuf(Random->ReallyRandom, 4), 0);
		(hs, m1) := handshake1(k, counter(k.ctrfile));
		p := array[1 + 4] of byte;
		p[0] = byte Pinit;
		put4(p, 1, me);
		p = cat(p, m1);
		p = cat(p, mac16(mac1key, p));
		if(cookie != nil)
			p = cat(p, mac16(cookie, p));
		else
			p = cat(p, array[16] of {* => byte 0});
		sys->write(s.fd, p, len p);
		# Each try replaces the last (the brick keeps the newest), so only
		# the newest try's response is useful: back off until the wait
		# exceeds the round trip, or a slow link would never connect.
		spawn ticker(timer, wait);
		if(wait < 2000)
			wait *= 2;
	wait:
		for(;;) alt {
		<-timer =>
			break wait;
		r := <-pkts =>
			if(len r == COOKIELEN && int r[0] == Pcookie && get4(r, 1) == me){
				# Under load: retry at once, proving our address.
				ctr := big 0;
				for(i := 0; i < 8; i++)
					ctr |= big r[5+i] << (8*i);
				ck := unseal(ckey, ctr, p[len p - 32:len p - 16], r[13:]);
				if(ck != nil){
					cookie = ck;
					break wait;
				}
				continue;
			}
			if(len r == RESPLEN && int r[0] == Presp && get4(r, 5) == me){
				v := handshake2(hs, r[9:]);
				if(v == nil || len v != 1 || int v[0] != 1)
					continue;
				kill(reader);	# from here on the relay reads the network
				s.me = me;
				s.them = get4(r, 1);
				(s.ksend, s.krecv) = split(hs);
				s.lastsend = sys->millisec();
				return (s, nil);
			}
		}
	}
	kill(reader);
	return (nil, "no handshake response from " + addr);
}

# Datagrams from the network, raw, for the handshake.
reader1(fd: ref Sys->FD, pkts: chan of array of byte, pid: chan of int)
{
	pid <-= sys->pctl(0, nil);
	buf := array[2048] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0){
			# An ICMP error (nobody listening yet) fails one read: keep on.
			sys->sleep(50);
			continue;
		}
		r := array[n] of byte;
		r[0:] = buf[0:n];
		alt {
		pkts <-= r =>
			;
		* =>
			;	# nobody listening (the handshake is over): drop
		}
	}
}

ticker(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

#
# The relay.
#
Req: adt {
	rid:	int;
	tag:	int;
	write:	int;	# a Twrite: its outcome is unknown if it times out
	pkt:	array of byte;	# rid || 9P message
	deadline:	int;
	nexttx:	int;
	tries:	int;
	pending:	int;
	heard:	int;
};

relay(addr: string, k: ref Keys, fd: ref Sys->FD): string
{
	(s, err) := connect(addr, k);
	if(s == nil)
		return err;
	reqs := chan of array of byte;
	pkts := chan of array of byte;
	tick := chan of int;
	pids := chan of int;
	spawn pipereader(fd, reqs, pids);
	spawn netreader(s, pkts, pids);
	spawn clock(tick, pids);
	p1 := <-pids;
	p2 := <-pids;
	p3 := <-pids;
	spawn core(s, fd, reqs, pkts, tick, p1 :: p2 :: p3 :: nil);
	return nil;
}

# 9P messages from the mount driver, framed by their size field.
pipereader(fd: ref Sys->FD, reqs: chan of array of byte, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	buf := array[0] of byte;
	tmp := array[Sys->ATOMICIO] of byte;
	for(;;){
		while(len buf >= 4 && len buf >= get4(buf, 0)){
			n := get4(buf, 0);
			if(n < 7)
				break;
			m := array[n] of byte;
			m[0:] = buf[0:n];
			reqs <-= m;
			buf = buf[n:];
		}
		n := sys->read(fd, tmp, len tmp);
		if(n <= 0)
			break;
		buf = cat(buf, tmp[0:n]);
	}
	reqs <-= nil;
}

# Authenticated, fresh packets from the brick: their plaintexts.
netreader(s: ref Sess, pkts: chan of array of byte, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	buf := array[2048] of byte;
	for(;;){
		n := sys->read(s.fd, buf, len buf);
		if(n <= 0){
			# An ICMP error (the brick rebooting, a router's complaint)
			# fails one read; the session goes on.
			sys->sleep(50);
			continue;
		}
		if(n < 13 + 16 || int buf[0] != Pdata || get4(buf, 1) != s.me)
			continue;
		ctr := big 0;
		for(i := 0; i < 8; i++)
			ctr |= big buf[5+i] << (8*i);
		hdr := array[13] of byte;
		hdr[0:] = buf[0:13];
		c := array[n - 13] of byte;
		c[0:] = buf[13:n];
		p := unseal(s.krecv, ctr, hdr, c);
		# (fresh() is the core's: it owns the window; send the counter along)
		if(p == nil || len p < 4)
			continue;
		pc := array[8 + len p] of byte;
		for(i = 0; i < 8; i++)
			pc[i] = byte (ctr >> (8*i));
		pc[8:] = p;
		pkts <-= pc;
	}
}

clock(tick: chan of int, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	for(;;){
		sys->sleep(20);
		tick <-= 1;
	}
}

core(s: ref Sess, fd: ref Sys->FD, reqs, pkts: chan of array of byte, tick: chan of int, pids: list of int)
{
	pend: list of ref Req;
	rid := 0;
	for(;;) alt {
	m := <-reqs =>
		if(m == nil){		# unmounted
			for(; pids != nil; pids = tl pids)
				kill(hd pids);
			return;
		}
		typ := int m[4];
		tag := int m[5] | int m[6] << 8;
		if(typ == Tversion && len m >= 11 && get4(m, 7) > MSIZE)
			put4(m, 7, MSIZE);	# one datagram
		if(typ == Tflush && len m >= 9){
			# The flushed request is answered by the Rflush, never
			# by a late reply: stop retransmitting it, forget it.
			old := int m[7] | int m[8] << 8;
			pend = drop(pend, old);
		}
		rid++;
		now := sys->millisec();
		r := ref Req(rid, tag, typ == Twrite, cat(le4(rid), m), now + DEADLINE, now + RTO, 1, 0, now);
		pend = r :: pend;
		s.send(r.pkt);
	pc := <-pkts =>
		ctr := big 0;
		for(i := 0; i < 8; i++)
			ctr |= big pc[i] << (8*i);
		if(!s.fresh(ctr))
			continue;
		p := pc[8:];
		id := get4(p, 0);
		for(l := pend; l != nil; l = tl l){
			r := hd l;
			if(r.rid != id)
				continue;
			if(len p == 4){		# pending: received, waiting for data
				r.pending = 1;
				r.heard = sys->millisec();
				r.nexttx = r.heard + KEEP;
			}else{
				sys->write(fd, p[4:], len p - 4);
				pend = remove(pend, r);
			}
			break;
		}
	<-tick =>
		now := sys->millisec();
		for(l := pend; l != nil; l = tl l){
			r := hd l;
			if(r.pending && now - r.heard > LIVE){
				rerror(fd, r.tag, "link down");
				pend = remove(pend, r);
			}else if(!r.pending && now >= r.deadline){
				if(r.write)
					rerror(fd, r.tag, "outcome unknown: timed out");
				else
					rerror(fd, r.tag, "timed out");
				pend = remove(pend, r);
			}else if(now >= r.nexttx){
				s.send(r.pkt);	# the same request, a new packet
				r.tries++;
				if(r.pending)
					r.nexttx = now + KEEP;
				else
					r.nexttx = now + rto(r.tries);
			}
		}
		if(now - s.lastsend > IDLE)
			s.send(le4(0));		# keepalive: rid 0 is never a request
	}
}

# Five fast retransmissions, then backing off by 1.5x to RTOMAX.
rto(tries: int): int
{
	t := RTO;
	for(i := 5; i < tries && t < RTOMAX; i++)
		t = t * 3 / 2;
	if(t > RTOMAX)
		t = RTOMAX;
	return t;
}

rerror(fd: ref Sys->FD, tag: int, msg: string)
{
	e := array of byte msg;
	m := array[4 + 1 + 2 + 2 + len e] of byte;
	put4(m, 0, len m);
	m[4] = byte Rerror;
	m[5] = byte tag;
	m[6] = byte (tag >> 8);
	m[7] = byte len e;
	m[8] = byte (len e >> 8);
	m[9:] = e;
	sys->write(fd, m, len m);
}

drop(l: list of ref Req, tag: int): list of ref Req
{
	r: list of ref Req;
	for(; l != nil; l = tl l)
		if((hd l).tag != tag)
			r = hd l :: r;
	return r;
}

remove(l: list of ref Req, x: ref Req): list of ref Req
{
	r: list of ref Req;
	for(; l != nil; l = tl l)
		if(hd l != x)
			r = hd l :: r;
	return r;
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

get4(a: array of byte, o: int): int
{
	return int a[o] | int a[o+1] << 8 | int a[o+2] << 16 | int a[o+3] << 24;
}

put4(a: array of byte, o: int, v: int)
{
	a[o] = byte v;
	a[o+1] = byte (v >> 8);
	a[o+2] = byte (v >> 16);
	a[o+3] = byte (v >> 24);
}

le4(v: int): array of byte
{
	a := array[4] of byte;
	put4(a, 0, v);
	return a;
}

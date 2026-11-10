implement Sdgsrv;

#
# sdgsrv - serve a directory as 9P over Noise-secured datagrams: the
# responder side of sdg(2), as styxbrick's firmware is, for an InferNode
# machine.  Built for docs/experiments/sdg-video (sdg against TCP for a
# live feed); the protocol is styxbrick's docs/STYX-DGRAM.md.
#
#	sdgsrv [-v] keydir addr dir
#	sdgsrv -g keydir
#
# keydir holds, as hex lines: sdgsrv.key (our X25519 private key),
# sdgsrv.peer (the one commander's public key) and sdg.psk (the
# pre-shared key).  -g makes a set: those three, and the commander's
# side beside them as sdg(2) and brick(1) name it (sdg.key, sdg.brick,
# sdg.psk), to be copied to the commander.
#
# Each accepted handshake is a session of its own, with its own export of
# dir, as each TCP connection to `listen ... {export dir}` is: several
# viewers are several sessions.  Within one, a request runs at most once
# under its rid, its reply kept among the last ncachemax (-c, 16 as the brick), a retransmission
# of one still running answered "pending" and of one gone from the cache
# (or abandoned below the floor) "gone".  9P tags are the session's own
# toward the export, so a tag the commander reuses after giving up on a
# request, and a Tflush, cannot reach the wrong request.
#
# Not here, as a closed bench does not need them: cookies under load,
# mac2, the 4-a-second handshake budget, and deferred promotion (STYX-DGRAM
# Rev S1).  A deployment needs those, and a CNSA suite in place of Noise's.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "security.m";
	random: Random;

Sdgsrv: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

NAME:	con "Noise_IKpsk2_25519_ChaChaPoly_SHA256";
PROLOGUE:	con "styxbrick sdg 1";
Pinit, Presp, Pdata: con 1+iota;
INITLEN:	con 1 + 4 + 108 + 16 + 16;
Udphdrlen:	con 52;
MSIZE:	con 1200;
ncachemax := 16;	# replies kept, as the brick keeps (-c)
Window:	con 64;		# rids above the floor that may be open
IDLEMS:	con 120000;	# a session with no packet this long is dropped
NOTAG:	con 16rFFFF;
Tversion:	con 100;
Tflush:	con 108;

verbose := 0;
spriv, speer, psk: array of byte;
mac1key: array of byte;
lastctr: array of byte;		# the newest initiation counter accepted (12 bytes)
sessions: list of ref Session;
dir: string;
udp: ref Sys->FD;
stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	random = load Random Random->PATH;
	stderr = sys->fildes(2);
	args = tl args;
	if(args != nil && hd args == "-g"){
		if(len args != 2)
			usage();
		genkeys(hd tl args);
		return;
	}
	ncachemax = 16;
	for(; args != nil && len hd args > 1 && (hd args)[0] == '-'; args = tl args)
		case hd args {
		"-v" =>
			verbose = 1;
		"-c" =>
			# replies kept: the brick's 16 is gone in 40 ms at wire speed
			if(tl args == nil || (ncachemax = int hd tl args) < 1)
				usage();
			args = tl args;
		* =>
			usage();
		}
	if(len args != 3)
		usage();
	kd := hd args;
	addr := hd tl args;
	dir = hd tl tl args;
	spriv = hexfile(kd + "/sdgsrv.key");
	speer = hexfile(kd + "/sdgsrv.peer");
	psk = hexfile(kd + "/sdg.psk");
	if(len spriv != 32 || len speer != 32 || len psk != 32)
		fatal("no keys in " + kd + " (sdgsrv -g makes them)");
	spub := kr->x25519_base(spriv);
	mac1key = sha(cat(array of byte "mac1", spub));
	lastctr = array[12] of {* => byte 0};

	(ok, c) := sys->announce(addr);
	if(ok < 0)
		fatal(sys->sprint("announce %s: %r", addr));
	if(sys->fprint(c.cfd, "headers") < 0)
		fatal(sys->sprint("headers: %r"));
	udp = sys->open(c.dir + "/data", Sys->ORDWR);
	if(udp == nil)
		fatal(sys->sprint("open %s/data: %r", c.dir));
	if(verbose)
		sys->fprint(stderr, "sdgsrv: %s on %s\n", dir, addr);
	dispatch();
}

usage()
{
	sys->fprint(stderr, "usage: sdgsrv [-v] [-c ncache] keydir addr dir\n       sdgsrv -g keydir\n");
	raise "fail:usage";
}

fatal(s: string)
{
	sys->fprint(stderr, "sdgsrv: %s\n", s);
	raise "fail:" + s;
}

# ---- keys ----

genkeys(kd: string)
{
	sk := random->randombuf(Random->NotQuiteRandom, 32);	# ours
	ck := random->randombuf(Random->NotQuiteRandom, 32);	# the commander's
	p := random->randombuf(Random->NotQuiteRandom, 32);
	sys->create(kd, Sys->OREAD, Sys->DMDIR|8r700);
	put(kd + "/sdgsrv.key", sk, 8r600);
	put(kd + "/sdgsrv.peer", kr->x25519_base(ck), 8r644);
	put(kd + "/sdg.psk", p, 8r600);
	put(kd + "/sdg.key", ck, 8r600);
	put(kd + "/sdg.brick", kr->x25519_base(sk), 8r644);
}

put(f: string, b: array of byte, mode: int)
{
	fd := sys->create(f, Sys->OWRITE, mode);
	if(fd == nil)
		fatal(sys->sprint("create %s: %r", f));
	sys->fprint(fd, "%s\n", hex(b));
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
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return unhex(s);
}

hex(b: array of byte): string
{
	s := "";
	for(i := 0; i < len b; i++)
		s += sys->sprint("%.2ux", int b[i]);
	return s;
}

unhex(s: string): array of byte
{
	if(len s % 2)
		return nil;
	b := array[len s/2] of byte;
	for(i := 0; i < len b; i++){
		v := 0;
		for(k := 0; k < 2; k++){
			c := s[2*i+k];
			case c {
			'0' to '9' => v = v*16 + c - '0';
			'a' to 'f' => v = v*16 + c - 'a' + 10;
			'A' to 'F' => v = v*16 + c - 'A' + 10;
			* => return nil;
			}
		}
		b[i] = byte v;
	}
	return b;
}

# ---- primitives ----

sha(a: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(a, len a, d, nil);
	return d;
}

hmac(key, data: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(data, len data, key, d, nil);
	return d;
}

cat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int a[i] ^ int b[i];
	return d == 0;
}

allzero(a: array of byte): int
{
	if(a == nil)
		return 1;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int a[i];
	return d == 0;
}

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

get4(a: array of byte, o: int): int
{
	return int a[o] | int a[o+1] << 8 | int a[o+2] << 16 | int a[o+3] << 24;
}

put4(a: array of byte, o, v: int)
{
	for(i := 0; i < 4; i++)
		a[o+i] = byte (v >> (8*i));
}

get2(a: array of byte, o: int): int
{
	return int a[o] | int a[o+1] << 8;
}

put2(a: array of byte, o, v: int)
{
	a[o] = byte v;
	a[o+1] = byte (v >> 8);
}

datanonce(n: big): array of byte
{
	b := array[12] of {* => byte 0};
	for(i := 0; i < 8; i++)
		b[4+i] = byte (n >> (8*i));
	return b;
}

# ---- the handshake (responder), as sdg_test.b's ----

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
	(c, tag) := kr->ccpolyencrypt(p, s.h, s.k, nonce(s.n++));
	c = cat(c, tag);
	mixhash(s, c);
	return c;
}

decrypt(s: ref Ss, c: array of byte): array of byte
{
	p := kr->ccpolydecrypt(c[0:len c - 16], s.h, c[len c - 16:], s.k, nonce(s.n));
	if(p == nil)
		return nil;
	s.n++;
	mixhash(s, c);
	return p;
}

# message 2 for message 1 m, and the session it opens; nil if m does not authenticate
answer(m: array of byte, hdr: array of byte): (array of byte, ref Session)
{
	# mac1, before any X25519
	if(!same(hmac(mac1key, m[0:113])[0:16], m[113:129]))
		return (nil, nil);
	sender := get4(m, 1);
	m1 := m[5:5+108];
	s := ref Ss;
	s.h = sha(array of byte NAME);
	s.ck = s.h;
	mixhash(s, array of byte PROLOGUE);
	mixhash(s, kr->x25519_base(spriv));
	ei := m1[0:32];
	mixhash(s, ei);
	mixkey(s, ei);
	es := kr->x25519(spriv, ei);
	if(allzero(es))
		return (nil, nil);
	mixkey(s, es);
	si := decrypt(s, m1[32:80]);
	if(si == nil || !same(si, speer))
		return (nil, nil);
	mixkey(s, kr->x25519(spriv, si));
	ctr := decrypt(s, m1[80:108]);
	if(ctr == nil || len ctr != 12 || !newer(ctr, lastctr))
		return (nil, nil);

	ep := random->randombuf(Random->NotQuiteRandom, 32);
	re := kr->x25519_base(ep);
	ee := kr->x25519(ep, ei);
	se := kr->x25519(ep, si);
	if(allzero(ee) || allzero(se))
		return (nil, nil);
	mixhash(s, re);
	mixkey(s, re);
	mixkey(s, ee);
	mixkey(s, se);
	(ck, th, tk) := hkdf(s.ck, psk);
	s.ck = ck;
	mixhash(s, th);
	s.k = tk;
	s.n = 0;
	c := encrypt(s, array[] of {byte 1});

	me := get4(random->randombuf(Random->NotQuiteRandom, 4), 0);
	out := array[1 + 4 + 4] of byte;
	out[0] = byte Presp;
	put4(out, 1, me);
	put4(out, 5, sender);
	(krecv, ksend, nil) := hkdf(s.ck, nil);
	lastctr = ctr;
	ss := newsession(me, sender, krecv, ksend, hdr);
	return (cat(cat(out, re), c), ss);
}

newer(a, b: array of byte): int
{
	for(i := 0; i < len a; i++){
		if(a[i] > b[i])
			return 1;
		if(a[i] < b[i])
			return 0;
	}
	return 0;
}

# ---- sessions ----

Req: adt {
	rid:	int;
	ctag:	int;	# the commander's tag
	stag:	int;	# ours, toward the export
	typ:	int;
	closed:	int;	# its tag reused: its reply, when the export gives it, is dropped
};

Session: adt {
	me, them:	int;
	krecv, ksend:	array of byte;
	hdr:	array of byte;		# the commander's address, as UDP headers give it
	sctr:	big;			# our next counter
	rhigh:	big;			# the highest counter received
	rmap:	big;			# the 64 below it, received
	rseen:	int;
	floor:	int;			# every rid <= floor is closed
	runmap:	big;			# bit i: rid floor+1+i has run
	running:	list of ref Req;
	cache:	list of (int, array of byte);	# (rid, plaintext reply), newest first
	ncache:	int;
	nexttag:	int;
	pkts:	chan of (array of byte, array of byte);	# (udp header, packet)
	replies:	chan of array of byte;
	exp:	ref Sys->FD;
	last:	int;
	nrun, npend, ngone, nresent:	int;
	dead:	int;
};

newsession(me, them: int, krecv, ksend, hdr: array of byte): ref Session
{
	ss := ref Session;
	ss.me = me;
	ss.them = them;
	ss.krecv = krecv;
	ss.ksend = ksend;
	ss.hdr = hdr;
	ss.sctr = big 0;
	ss.rhigh = big -1;
	ss.rmap = big 0;
	ss.floor = 0;
	ss.runmap = big 0;
	ss.nexttag = 1;
	ss.pkts = chan[64] of (array of byte, array of byte);
	ss.replies = chan[64] of array of byte;
	ss.last = sys->millisec();
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return nil;
	ss.exp = p[0];
	spawn exporter(p[1]);
	spawn expreader(ss);
	spawn session(ss);
	return ss;
}

exporter(fd: ref Sys->FD)
{
	sys->pctl(Sys->FORKNS|Sys->NEWFD, fd.fd :: 2 :: nil);
	if(sys->export(fd, dir, Sys->EXPWAIT) < 0)
		sys->fprint(stderr, "sdgsrv: export %s: %r\n", dir);
}

# the export's replies, whole 9P messages
expreader(ss: ref Session)
{
	buf := array[MSIZE + 64] of byte;
	have := 0;
	for(;;){
		while(have >= 4){
			sz := get4(buf, 0);
			if(sz < 7 || sz > len buf){
				ss.replies <-= nil;
				return;
			}
			if(have < sz)
				break;
			m := array[sz] of byte;
			m[0:] = buf[0:sz];
			buf[0:] = buf[sz:have];
			have -= sz;
			ss.replies <-= m;
		}
		n := sys->read(ss.exp, buf[have:], len buf - have);
		if(n <= 0){
			ss.replies <-= nil;
			return;
		}
		have += n;
	}
}

session(ss: ref Session)
{
	tick := chan of int;
	spawn ticker(tick);
	for(;;) alt {
	(hdr, p) := <-ss.pkts =>
		ss.hdr = hdr;
		ss.last = sys->millisec();
		datapkt(ss, p);
	m := <-ss.replies =>
		if(m == nil){
			drop(ss);
			return;
		}
		reply(ss, m);
	<-tick =>
		if(sys->millisec() - ss.last > IDLEMS){
			if(verbose)
				sys->fprint(stderr, "sdgsrv: session %ux idle: run=%d pending=%d gone=%d resent=%d\n",
					ss.me, ss.nrun, ss.npend, ss.ngone, ss.nresent);
			drop(ss);
			return;
		}
	}
}

ticker(c: chan of int)
{
	for(;;){
		sys->sleep(5000);
		alt {
		c <-= 1 =>
			;
		* =>
			;
		}
	}
}

# marked, not taken off the list: only dispatch changes the list
drop(ss: ref Session)
{
	ss.dead = 1;
	ss.exp = nil;
}

# an authenticated data packet's request
datapkt(ss: ref Session, m: array of byte)
{
	if(len m < 13 + 16 + 4)
		return;
	n := big 0;
	for(i := 0; i < 8; i++)
		n |= big m[5+i] << (8*i);
	if(!fresh(ss, n))
		return;
	p := kr->ccpolydecrypt(m[13:len m - 16], m[0:13], m[len m - 16:], ss.krecv, datanonce(n));
	if(p == nil || len p < 4)
		return;
	seen(ss, n);
	rid := get4(p, 0);
	if(rid == 0)
		return;		# keepalive
	msg := p[4:];

	for(c := ss.cache; c != nil; c = tl c){
		(r, rep) := hd c;
		if(r == rid){
			ss.nresent++;
			send(ss, rep);
			return;
		}
	}
	for(l := ss.running; l != nil; l = tl l)
		if((hd l).rid == rid && !(hd l).closed){
			ss.npend++;
			send(ss, ridonly(rid));
			return;
		}
	if(rid <= ss.floor || (rid - ss.floor <= Window && (ss.runmap & (big 1 << (rid - ss.floor - 1))) != big 0)){
		ss.ngone++;
		g := array[5] of byte;
		put4(g, 0, rid);
		g[4] = byte 0;
		send(ss, g);
		return;
	}
	if(len msg < 7 || get4(msg, 0) != len msg || len msg > MSIZE)
		return;
	while(rid - ss.floor > Window){
		# the oldest open rid is abandoned (or, run, closed): the floor moves up
		ss.floor++;
		ss.runmap >>= 1;
	}
	run(ss, rid, msg);
}

ridonly(rid: int): array of byte
{
	b := array[4] of byte;
	put4(b, 0, rid);
	return b;
}

# the 64-counter replay window
fresh(ss: ref Session, n: big): int
{
	if(ss.rhigh < big 0 || n > ss.rhigh)
		return 1;
	d := ss.rhigh - n;
	if(d >= big 64)
		return 0;
	return (ss.rmap & (big 1 << int d)) == big 0;
}

seen(ss: ref Session, n: big)
{
	if(ss.rhigh < big 0){
		ss.rhigh = n;
		ss.rmap = big 1;
		return;
	}
	if(n > ss.rhigh){
		d := n - ss.rhigh;
		if(d >= big 64)
			ss.rmap = big 0;
		else
			ss.rmap <<= int d;
		ss.rmap |= big 1;
		ss.rhigh = n;
		return;
	}
	ss.rmap |= big 1 << int (ss.rhigh - n);
}

# a new request: to the export under a tag of ours
run(ss: ref Session, rid: int, msg: array of byte)
{
	typ := int msg[4];
	ctag := get2(msg, 5);
	stag := NOTAG;
	if(ctag != NOTAG){
		# a tag in use again: the commander has finished with the
		# older request (STYX-DGRAM), which is closed so its reply
		# cannot take this one's place
		for(l := ss.running; l != nil; l = tl l)
			if((hd l).ctag == ctag && !(hd l).closed){
				(hd l).closed = 1;
				ran(ss, (hd l).rid);
			}
		stag = newtag(ss);
		put2(msg, 5, stag);
	}
	if(typ == Tflush && len msg >= 9){
		# the request flushed: the newest running under that tag of the commander's
		old := get2(msg, 7);
		for(l := ss.running; l != nil; l = tl l)
			if((hd l).ctag == old && !(hd l).closed){
				put2(msg, 7, (hd l).stag);
				break;
			}
	}
	if(verbose && typ == Tversion)
		sys->fprint(stderr, "sdgsrv: Tversion msize %d\n", get4(msg, 7));
	ss.running = ref Req(rid, ctag, stag, typ, 0) :: ss.running;
	ss.nrun++;
	if(sys->write(ss.exp, msg, len msg) != len msg)
		sys->fprint(stderr, "sdgsrv: export write: %r\n");
}

newtag(ss: ref Session): int
{
	for(;;){
		t := ss.nexttag++;
		if(ss.nexttag >= NOTAG)
			ss.nexttag = 1;
		busy := 0;
		for(l := ss.running; l != nil; l = tl l)
			if((hd l).stag == t)
				busy = 1;
		if(!busy)
			return t;
	}
}

# the export's reply m: to the request it answers
reply(ss: ref Session, m: array of byte)
{
	stag := get2(m, 5);
	r: ref Req;
	l: list of ref Req;
	for(q := ss.running; q != nil; q = tl q)
		if(r == nil && (hd q).stag == stag)
			r = hd q;
		else
			l = hd q :: l;
	if(r == nil)
		return;
	ss.running = l;
	if(r.closed)
		return;
	if(r.ctag != NOTAG)
		put2(m, 5, r.ctag);
	if(verbose && r.typ == Tversion)
		sys->fprint(stderr, "sdgsrv: Rversion %d msize %d\n", int m[4], get4(m, 7));
	plain := cat(ridonly(r.rid), m);
	ss.cache = (r.rid, plain) :: ss.cache;
	if(++ss.ncache > ncachemax){
		k: list of (int, array of byte);
		i := 0;
		for(c := ss.cache; c != nil && i < ncachemax; c = tl c){
			k = hd c :: k;
			i++;
		}
		ss.cache = nil;
		for(; k != nil; k = tl k)
			ss.cache = hd k :: ss.cache;
		ss.ncache = ncachemax;
	}
	ran(ss, r.rid);
	send(ss, plain);
}

# rid has run (or is closed): the floor moves over every run rid above it
ran(ss: ref Session, rid: int)
{
	if(rid > ss.floor && rid - ss.floor <= Window)
		ss.runmap |= big 1 << (rid - ss.floor - 1);
	while((ss.runmap & big 1) != big 0){
		ss.floor++;
		ss.runmap >>= 1;
	}
}

send(ss: ref Session, plain: array of byte)
{
	h := array[13] of byte;
	h[0] = byte Pdata;
	put4(h, 1, ss.them);
	for(i := 0; i < 8; i++)
		h[5+i] = byte (ss.sctr >> (8*i));
	(c, tag) := kr->ccpolyencrypt(plain, h, ss.ksend, datanonce(ss.sctr));
	ss.sctr++;
	pkt := array[Udphdrlen + 13 + len c + 16] of byte;
	pkt[0:] = ss.hdr;
	pkt[Udphdrlen:] = h;
	pkt[Udphdrlen+13:] = c;
	pkt[Udphdrlen+13+len c:] = tag;
	sys->write(udp, pkt, len pkt);
}

# ---- the socket ----

dispatch()
{
	buf := array[Udphdrlen + MSIZE + 256] of byte;
	for(;;){
		n := sys->read(udp, buf, len buf);
		if(n <= 0)
			fatal(sys->sprint("udp read: %r"));
		if(n < Udphdrlen + 1)
			continue;
		hdr := array[Udphdrlen] of byte;
		hdr[0:] = buf[0:Udphdrlen];
		m := array[n - Udphdrlen] of byte;
		m[0:] = buf[Udphdrlen:n];
		case int m[0] {
		Pinit =>
			if(len m != INITLEN)
				continue;
			(resp, ss) := answer(m, hdr);
			if(resp == nil || ss == nil)
				continue;
			l: list of ref Session;
			for(s := sessions; s != nil; s = tl s)
				if(!(hd s).dead)
					l = hd s :: l;
			sessions = ss :: l;
			if(verbose)
				sys->fprint(stderr, "sdgsrv: session %ux\n", ss.me);
			out := cat(hdr, resp);
			sys->write(udp, out, len out);
		Pdata =>
			if(len m < 13)
				continue;
			id := get4(m, 1);
			for(s := sessions; s != nil; s = tl s)
				if((hd s).me == id && !(hd s).dead){
					alt {
					(hd s).pkts <-= (hdr, m) =>
						;
					* =>
						;	# the session is behind: drop, as a link would
					}
					break;
				}
		}
	}
}

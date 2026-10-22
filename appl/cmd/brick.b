implement Brick;

#
# brick - pair with, configure and mount a styxbrick: a microcontroller
# serving its hardware as a Styx file tree.
#
#	brick key [-d keydir]
#	brick pair [-d keydir] usbmnt
#	brick wifi usbmnt  <creds
#	brick mount [-abu] [-d keydir] addr mountpoint
#	brick d2 [-d keydir] [-l leasems] brickmnt dir
#
# Over USB the brick is mounted with plain `mount -A`; physical access
# is the trust boundary.  Over the network it serves Styx inside TLS 1.3
# on TCP, or (-u) over Noise-secured datagrams on UDP (sdg(2)), and both
# ends authenticate by pinned key: `brick pair`, run against the USB
# mount, exchanges the keys.  Nothing about the keys crosses the network
# unverified.
#
# keydir (default /usr/$user/keyring/brick) holds:
#	client.key	our P-256 private scalar, 64 hex digits (mode 600)
#	client.crt	our self-signed X.509 certificate, DER
#	brick.spki	the brick's pin: SHA-256 of its SubjectPublicKeyInfo, hex
#	sdg.key	our X25519 private key, hex (mode 600)
#	sdg.psk	the pre-shared key we gave the brick, hex (mode 600)
#	sdg.brick	the brick's X25519 public key, hex
#	sdg.ctr	the datagram handshake counter
#	d2.key	the D2 safety key we gave the brick, hex (mode 600)
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "keyring.m";
	keyring: Keyring;
include "tls.m";
	tls: TLS;
	Conn: import tls;
include "security.m";
	random: Random;
include "sdg.m";
	sdg: Sdg;

Brick: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

PORT: con "564";
udp := 0;
leasems := 500;

keydir: string;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		fail("load", sys->sprint("can't load %s: %r", Keyring->PATH));

	if(args != nil)
		args = tl args;
	if(args == nil)
		usage();
	cmd := hd args;

	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail("load", sys->sprint("can't load %s: %r", Arg->PATH));
	arg->init(args);
	keydir = "/usr/" + user() + "/keyring/brick";
	flags := Sys->MREPL;
	while((o := arg->opt()) != 0){
		case o {
		'd' =>
			keydir = arg->earg();
		'a' =>
			flags = Sys->MAFTER;
		'b' =>
			flags = Sys->MBEFORE;
		'u' =>
			udp = 1;
		'l' =>
			leasems = int arg->earg();
		* =>
			usage();
		}
	}
	args = arg->argv();

	case cmd {
	"key" =>
		if(args != nil)
			usage();
		(nil, cert) := loadkeys(1);
		sys->print("%s\n", hex(certpin(cert)));
	"pair" =>
		if(len args != 1)
			usage();
		pair(hd args);
	"wifi" =>
		if(len args != 1)
			usage();
		wifi(hd args);
	"mount" =>
		if(len args != 2)
			usage();
		if(udp)
			dmount(hd args, hd tl args, flags);
		else
			mount(hd args, hd tl args, flags);
	"d2" =>
		if(len args != 2)
			usage();
		d2serve(hd args, hd tl args);
	* =>
		usage();
	}
}

usage()
{
	sys->fprint(sys->fildes(2), "usage:\tbrick key [-d keydir]\n" +
		"\tbrick pair [-d keydir] usbmnt\n" +
		"\tbrick wifi usbmnt <creds\n" +
		"\tbrick mount [-abu] [-d keydir] addr mountpoint\n" +
		"\tbrick d2 [-d keydir] [-l leasems] brickmnt dir\n");
	raise "fail:usage";
}

fail(status, msg: string)
{
	sys->fprint(sys->fildes(2), "brick: %s\n", msg);
	raise "fail:" + status;
}

#
# Pairing over the USB mount.
#
pair(mnt: string)
{
	(nil, cert) := loadkeys(1);
	mine := hex(certpin(cert));
	writefile(mnt + "/config/peer", mine + "\n");

	theirs := readfile(mnt + "/config/spki");
	if(len theirs > 0 && theirs[len theirs - 1] == '\n')
		theirs = theirs[0:len theirs - 1];
	if(unhex(theirs) == nil || len theirs != 64)
		fail("pair", "bad pin from brick: " + theirs);
	createfile(keydir + "/brick.spki", theirs + "\n", 8r644);
	sys->print("our pin   %s\nbrick pin %s\n", mine, theirs);

	# The datagram transport too, if the brick has one: our X25519 public
	# key and a fresh PSK go to it, its public key comes back.
	if(sys->stat(mnt + "/config/sdg").t0 < 0)
		return;
	random = load Random Random->PATH;
	if(random == nil)
		fail("load", sys->sprint("can't load %s: %r", Random->PATH));
	key := unhex(trim(readfile0(keydir + "/sdg.key")));
	if(key == nil || len key != 32){
		key = random->randombuf(Random->ReallyRandom, 32);
		createfile(keydir + "/sdg.key", hex(key) + "\n", 8r600);
	}
	psk := random->randombuf(Random->ReallyRandom, 32);
	writefile(mnt + "/config/sdg", "peer " + hex(keyring->x25519_base(key)));
	writefile(mnt + "/config/sdg", "psk " + hex(psk));
	createfile(keydir + "/sdg.psk", hex(psk) + "\n", 8r600);
	pub := "";
	(nil, lines) := sys->tokenize(readfile(mnt + "/config/sdg"), "\n");
	for(; lines != nil; lines = tl lines)
		if(hasprefix(hd lines, "pub "))
			pub = (hd lines)[4:];
	if(unhex(pub) == nil || len pub != 64)
		fail("pair", "bad datagram key from brick: " + pub);
	createfile(keydir + "/sdg.brick", pub + "\n", 8r644);
	sys->print("datagram  %s\n", pub);

	# And D2's safety key, if the brick has safety outputs to configure.
	if(sys->stat(mnt + "/config/d2").t0 >= 0){
		d2key := random->randombuf(Random->ReallyRandom, 32);
		writefile(mnt + "/config/d2", "key " + hex(d2key));
		createfile(keydir + "/d2.key", hex(d2key) + "\n", 8r600);
		sys->print("d2 key    set\n");
	}
}

wifi(mnt: string)
{
	buf := array[512] of byte;
	n := 0;
	while(n < len buf && (r := sys->read(sys->fildes(0), buf[n:], len buf - n)) > 0)
		n += r;
	creds := string buf[0:n];
	if(n == 0 || n == len buf || !hasprefix(creds, "ssid "))
		fail("wifi", "expected \"ssid NAME\\npass PASSPHRASE\\n\" on standard input");
	writefile(mnt + "/config/wifi", creds);
}

#
# Mounting over TLS.
#
mount(addr, mntpt: string, flags: int)
{
	tls = load TLS TLS->PATH;
	if(tls == nil)
		fail("load", sys->sprint("can't load %s: %r", TLS->PATH));
	if((e := tls->init()) != nil)
		fail("load", e);

	(key, cert) := loadkeys(0);
	s := readfile(keydir + "/brick.spki");
	if(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	pin := unhex(s);
	if(pin == nil || len pin != Keyring->SHA256dlen)
		fail("mount", "bad pin in " + keydir + "/brick.spki; run brick pair");

	if(!hasbang(addr))
		addr = "tcp!" + addr + "!" + PORT;
	(ok, c) := sys->dial(addr, nil);
	if(ok < 0)
		fail("mount", sys->sprint("can't dial %s: %r", addr));

	config := tls->defaultconfig();
	config.suites = TLS->TLS_AES_128_GCM_SHA256 :: TLS->TLS_CHACHA20_POLY1305_SHA256 :: nil;
	config.minver = TLS->TLS13;
	config.maxver = TLS->TLS13;
	config.clientcert = cert;
	config.clientkey = key;
	config.pinspki = pin;
	(conn, err) := tls->client(c.dfd, config);
	if(conn == nil)
		fail("mount", addr + ": " + err);
	c.dfd = nil;

	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		fail("mount", sys->sprint("can't make pipe: %r"));
	pids := chan of int;
	spawn tlsreader(conn, p[1], pids);
	spawn tlswriter(conn, p[1], pids);
	rpid := <-pids;
	wpid := <-pids;
	spawn reaper(conn, rpid, wpid, pids);
	p[1] = nil;

	if(sys->mount(p[0], nil, mntpt, flags, "") < 0){
		err = sys->sprint("mount failed: %r");
		kill(rpid);
		kill(wpid);
		conn.close();
		fail("mount", err);
	}
}

#
# Mounting over datagrams (sdg(2)): every request gets an answer, from
# the brick or, when its deadline passes or the link goes, an error.
#
dmount(addr, mntpt: string, flags: int)
{
	sdg = load Sdg Sdg->PATH;
	if(sdg == nil)
		fail("load", sys->sprint("can't load %s: %r", Sdg->PATH));
	if((e := sdg->init()) != nil)
		fail("load", e);
	k := ref Sdg->Keys;
	k.key = unhex(trim(readfile0(keydir + "/sdg.key")));
	k.server = unhex(trim(readfile0(keydir + "/sdg.brick")));
	k.psk = unhex(trim(readfile0(keydir + "/sdg.psk")));
	k.ctrfile = keydir + "/sdg.ctr";
	if(len k.key != 32 || len k.server != 32 || len k.psk != 32)
		fail("mount", "no datagram keys in " + keydir + "; run brick pair");
	if(!hasbang(addr))
		addr = "udp!" + addr + "!" + Sdg->PORT;
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		fail("mount", sys->sprint("can't make pipe: %r"));
	if((e = sdg->relay(addr, k, p[1])) != nil)
		fail("mount", e);
	p[1] = nil;
	if(sys->mount(p[0], nil, mntpt, flags, "") < 0)
		fail("mount", sys->sprint("mount failed: %r"));
}

#
# brick d2: hold safety outputs live for applications (docs/D2-SPEC.md in
# the styxbrick repository).  dir gets ctl, and a file per safety output
# (pwm.2, gpio.5, ...).  Writing a value to an output's file holds the
# output at that value: we renew it with fresh grants every leasems/5 for
# as long as it is wanted; "release" stops, and the brick takes the output
# to failsafe within a lease.  ctl takes "arm" and "safe"; arming is never
# automatic, so after any lapse (a lost link, or this program dying) the
# outputs stay at failsafe until an application arms again.
#
Out: adt {
	name:	string;	# pwm/2
	val:	int;
	held:	int;
	io:	ref Sys->FileIO;
};

D2: adt {
	devid, boot:	string;
	epoch:	int;
	tau:	int;
	seq:	int;
	key:	array of byte;
	grant, cmd:	ref Sys->FD;
	armed:	int;
	lapsed:	string;	# why we are disarmed, if we were armed
	last:	string;	# the last command's outcome
};

d2serve(bmnt, dir: string)
{
	key := unhex(trim(readfile0(keydir + "/d2.key")));
	if(key == nil || len key != 32)
		fail("d2", "no D2 key in " + keydir + "; run brick pair");
	d := ref D2;
	d.key = key;
	# The session: opening clone made it; its text names it.
	(nil, w) := sys->tokenize(readfile(bmnt + "/d2/clone"), " \n");
	if(len w != 4)
		fail("d2", "bad answer from " + bmnt + "/d2/clone");
	d.devid = hd w;
	d.boot = hd tl w;
	d.epoch = int hd tl tl w;
	d.tau = int hd tl tl tl w;
	# (opening clone again would make another session: keep this one's)
	d.grant = sys->open(bmnt + "/d2/grant", Sys->OREAD);
	d.cmd = sys->open(bmnt + "/d2/cmd", Sys->OWRITE);
	if(d.grant == nil || d.cmd == nil)
		fail("d2", sys->sprint("can't open %s/d2: %r", bmnt));
	# The safety outputs, from the brick's status.
	outs: list of ref Out;
	(nil, lines) := sys->tokenize(readfile(bmnt + "/d2/status"), "\n");
	for(; lines != nil; lines = tl lines){
		(nil, f) := sys->tokenize(hd lines, " ");
		if(f != nil && (hasprefix(hd f, "pwm/") || hasprefix(hd f, "gpio/")))
			outs = ref Out(hd f, 0, 0, nil) :: outs;
	}
	if(outs == nil)
		fail("d2", "the brick has no safety outputs");
	if(sys->bind("#s", dir, Sys->MBEFORE) < 0)
		fail("d2", sys->sprint("can't bind #s on %s: %r", dir));
	ctl := sys->file2chan(dir, "ctl");
	n := len outs;
	o := array[n] of ref Out;
	reads := array[n] of chan of (int, int, int, Sys->Rread);
	writes := array[n] of chan of (int, array of byte, int, Sys->Rwrite);
	for(i := 0; i < n; i++){
		o[i] = hd outs;
		outs = tl outs;
		fname := o[i].name;
		for(j := 0; j < len fname; j++)
			if(fname[j] == '/')
				fname[j] = '.';
		o[i].io = sys->file2chan(dir, fname);
		if(ctl == nil || o[i].io == nil)
			fail("d2", sys->sprint("can't make files in %s: %r", dir));
		reads[i] = o[i].io.read;
		writes[i] = o[i].io.write;
	}
	tick := chan of int;
	spawn d2clock(tick, leasems / 5);
	spawn d2core(d, o, ctl, reads, writes, tick);
}

d2clock(tick: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		tick <-= 1;
	}
}

d2core(d: ref D2, o: array of ref Out, ctl: ref Sys->FileIO,
	reads: array of chan of (int, int, int, Sys->Rread),
	writes: array of chan of (int, array of byte, int, Sys->Rwrite), tick: chan of int)
{
	renewing := 0;
	renewed := chan of int;
	for(;;) alt {
	(off, nil, nil, rc) := <-ctl.read =>
		if(rc == nil)
			break;
		st := sys->sprint("session %d %s\nlease %d\nlast %s\n",
			d.epoch, armedstr(d), leasems, d.last);
		rc <-= (sliced(st, off), nil);
	(nil, data, nil, wc) := <-ctl.write =>
		if(wc == nil)
			break;
		case trim(string data) {
		"arm" =>
			e := d2send(d, "arm", held(o), 1);
			if(e == nil){
				d.armed = 1;
				d.lapsed = nil;
			}
			wc <-= (len data, e);
		"safe" =>
			for(i := 0; i < len o; i++)
				o[i].held = 0;
			e := d2send(d, "safe", nil, 0);
			d.armed = 0;
			d.lapsed = "safe";
			wc <-= (len data, e);
		* =>
			wc <-= (0, "unknown control message");
		}
	(i, (off, nil, nil, rc)) := <-reads =>
		if(rc == nil)
			break;
		st := "released\n";
		if(o[i].held)
			st = sys->sprint("%d %s\n", o[i].val, armedstr(d));
		rc <-= (sliced(st, off), nil);
	(i, (nil, data, nil, wc)) := <-writes =>
		if(wc == nil)
			break;
		v := trim(string data);
		if(v == "release" || v == "off"){
			# An orderly release: to failsafe now, the others untouched
			# (a lapsed lease would disarm everything).
			o[i].held = 0;
			e: string;
			if(d.armed)
				e = d2send(d, "release", sys->sprint("%s=0", o[i].name) :: nil, 0);
			wc <-= (len data, e);
			break;
		}
		if(len v == 0 || !isnum(v)){
			wc <-= (0, "want a value, or release");
			break;
		}
		o[i].val = int v;
		o[i].held = 1;
		# Apply at once (and so learn at once if it is refused).
		e: string;
		if(d.armed)
			e = d2send(d, "set", held(o), 1);
		else
			e = "not armed: write arm to ctl";
		wc <-= (len data, e);
	<-tick =>
		# Renew whatever is held, before its lease runs out - in another
		# process, so that ctl (safe above all) never waits behind a
		# renewal stuck on the link.  One at a time; d2send's state
		# (seq, armed) is shared, and only a renewal and a ctl or value
		# write can overlap, which the brick orders by seq.
		h := held(o);
		if(d.armed && h != nil && !renewing){
			renewing = 1;
			spawn renew(d, h, renewed);
		}
	<-renewed =>
		renewing = 0;
	}
}

renew(d: ref D2, h: list of string, done: chan of int)
{
	d2send(d, "set", h, 1);
	done <-= 1;
}

held(o: array of ref Out): list of string
{
	l: list of string;
	for(i := 0; i < len o; i++)
		if(o[i].held)
			l = sys->sprint("%s=%d", o[i].name, o[i].val) :: l;
	return l;
}

# One D2 command under a fresh grant; nil, or why it was refused.
d2send(d: ref D2, kind: string, outs: list of string, lease: int): string
{
	gid := 0;
	if(kind != "safe" && kind != "release"){
		buf := array[64] of byte;
		n := 0;
		# The brick issues at most 20 grants a second: wait our turn.
		for(tries := 0; tries < 4; tries++){
			n = sys->pread(d.grant, buf, len buf, big 0);
			if(n > 0)
				break;
			if(!contains(sys->sprint("%r"), "rate"))
				break;
			sys->sleep(55);
		}
		if(n <= 0)
			return d2refused(d, sys->sprint("grant: %r"));
		(nil, w) := sys->tokenize(string buf[0:n], " \n");
		if(len w != 3)
			return d2refused(d, "grant: bad answer");
		gid = int hd tl tl w;
	}
	d.seq++;
	if(lease)
		lease = leasems;
	body := sys->sprint("d2 %s %s %d %d %s %d %d", d.devid, d.boot, d.epoch, d.seq, kind, gid, lease);
	for(; outs != nil; outs = tl outs)
		body += " " + hd outs;
	b := array of byte body;
	mac := array[Keyring->SHA256dlen] of byte;
	keyring->hmac_sha256(b, len b, d.key, mac, nil);
	m := array of byte (body + " " + hex(mac[0:16]));
	if(sys->write(d.cmd, m, len m) != len m)
		return d2refused(d, sys->sprint("%r"));
	d.last = "ok";
	return nil;
}

# A refusal; a lapsed lease or an evicted session leaves us disarmed.
d2refused(d: ref D2, e: string): string
{
	d.last = e;
	if(contains(e, "not armed") || contains(e, "session") || contains(e, "holding") ||
	   contains(e, "boot")){
		if(d.armed)
			d.lapsed = e;
		d.armed = 0;
	}
	return e;
}

armedstr(d: ref D2): string
{
	if(d.armed)
		return "live";
	if(d.lapsed != nil)
		return "failsafe (" + d.lapsed + "; write arm to ctl)";
	return "failsafe (not armed)";
}

sliced(s: string, off: int): array of byte
{
	b := array of byte s;
	if(off >= len b)
		return nil;
	return b[off:];
}

isnum(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i + len t] == t)
			return 1;
	return 0;
}

# Brick to us: TLS records into the pipe the mount driver reads.
tlsreader(conn: ref Conn, fd: ref Sys->FD, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	buf := array[Sys->ATOMICIO] of byte;
	while((n := conn.read(buf, len buf)) > 0)
		if(sys->write(fd, buf, n) != n)
			break;
	pids <-= 0;
}

# Us to the brick: whatever the mount driver writes, sealed.
tlswriter(conn: ref Conn, fd: ref Sys->FD, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		if(conn.write(buf, n) != n)
			break;
	pids <-= 0;
}

# When either direction ends (unmount, or the brick went away), stop
# the other and close the connection.
reaper(conn: ref Conn, rpid, wpid: int, done: chan of int)
{
	<-done;
	kill(rpid);
	kill(wpid);
	conn.close();
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

#
# Keys.
#
# Our key and self-signed certificate, made if need be (when `make`).
loadkeys(make: int): (array of byte, array of byte)
{
	key := unhex(trim(readfile0(keydir + "/client.key")));
	cert := readbytes(keydir + "/client.crt");
	if(key != nil && len key == 32 && cert != nil)
		return (key, cert);
	if(!make)
		fail("keys", "no client key in " + keydir + "; run brick pair");

	(priv, pt) := keyring->p256_keygen();
	if(priv == nil || pt == nil)
		fail("keys", "P-256 key generation failed");
	pub := keyring->p256_point_bytes(pt);
	cert = mkcert(priv, pub, "infernode-" + user());
	mkdirs(keydir);
	createfile(keydir + "/client.key", hex(priv) + "\n", 8r600);
	createbytes(keydir + "/client.crt", cert, 8r644);
	return (priv, cert);
}

# The pin of a certificate: SHA-256 of its SubjectPublicKeyInfo.
certpin(cert: array of byte): array of byte
{
	spki := findspki(cert);
	if(spki == nil)
		fail("keys", "can't find the key in " + keydir + "/client.crt");
	return sha256(spki);
}

#
# A minimal self-signed X.509 v3 certificate for a P-256 key, signed
# ecdsa-with-SHA256.  Only its key matters (peers pin it), but it is
# well formed so that any X.509 parser accepts it.
#
oid(b: array of int): array of byte
{
	a := array[len b] of byte;
	for(i := 0; i < len b; i++)
		a[i] = byte b[i];
	return der(16r06, a);
}

mkcert(priv, pub: array of byte, cn: string): array of byte
{
	sigalg := der(16r30, oid(array[] of {16r2A, 16r86, 16r48, 16rCE, 16r3D, 16r04, 16r03, 16r02}));
	name := der(16r30, der(16r31, der(16r30, cat(oid(array[] of {16r55, 16r04, 16r03}), der(16r0C, array of byte cn)))));
	validity := der(16r30, cat(der(16r17, array of byte "260101000000Z"),
		der(16r18, array of byte "99991231235959Z")));
	spki := der(16r30, cat(der(16r30, cat(oid(array[] of {16r2A, 16r86, 16r48, 16rCE, 16r3D, 16r02, 16r01}), oid(array[] of {16r2A, 16r86, 16r48, 16rCE, 16r3D, 16r03, 16r01, 16r07}))),
		der(16r03, cat(array[] of {byte 0}, pub))));
	serial := sha256(pub)[0:16];
	serial[0] &= byte 16r7F;
	serial[0] |= byte 16r01;	# positive, minimal: no leading zero byte

	tbs := der(16r30, cat(der(16rA0, der(16r02, array[] of {byte 2})),	# v3
		cat(der(16r02, serial),
		cat(sigalg,
		cat(name,
		cat(validity,
		cat(name, spki)))))));

	raw := keyring->p256_ecdsa_sign(priv, sha256(tbs));
	if(raw == nil || len raw != 64)
		fail("keys", "certificate signature failed");
	sig := der(16r30, cat(derint(raw[0:32]), derint(raw[32:64])));
	return der(16r30, cat(tbs, cat(sigalg, der(16r03, cat(array[] of {byte 0}, sig)))));
}

der(tag: int, body: array of byte): array of byte
{
	n := len body;
	hdr: array of byte;
	if(n < 16r80)
		hdr = array[] of {byte tag, byte n};
	else if(n < 16r100)
		hdr = array[] of {byte tag, byte 16r81, byte n};
	else
		hdr = array[] of {byte tag, byte 16r82, byte (n >> 8), byte n};
	return cat(hdr, body);
}

# DER INTEGER for the unsigned big-endian b.
derint(b: array of byte): array of byte
{
	i := 0;
	while(i < len b - 1 && b[i] == byte 0)
		i++;
	b = b[i:];
	if(int b[0] & 16r80)
		b = cat(array[] of {byte 0}, b);
	return der(16r02, b);
}

# The SubjectPublicKeyInfo in a certificate: the element after the
# subject in tbsCertificate.
findspki(c: array of byte): array of byte
{
	(t, h, n) := tlv(c, 0);
	if(t != 16r30)
		return nil;
	off := h;
	(t, h, n) = tlv(c, off);
	if(t != 16r30)
		return nil;
	off += h;
	end := off + n;
	(t, h, n) = tlv(c, off);
	if(t == 16rA0){
		off += h + n;
		(t, h, n) = tlv(c, off);
	}
	for(i := 0; i < 5; i++){
		if(t < 0 || off + h + n > end)
			return nil;
		off += h + n;
		(t, h, n) = tlv(c, off);
	}
	if(t != 16r30 || off + h + n > end)
		return nil;
	return c[off:off+h+n];
}

tlv(a: array of byte, off: int): (int, int, int)
{
	if(off < 0 || off + 2 > len a)
		return (-1, 0, 0);
	n := int a[off+1];
	h := 2;
	if(n & 16r80){
		k := n & 16r7F;
		if(k == 0 || k > 3 || off + 2 + k > len a)
			return (-1, 0, 0);
		n = 0;
		for(i := 0; i < k; i++)
			n = (n << 8) | int a[off+2+i];
		h += k;
	}
	if(n > len a - off - h)
		return (-1, 0, 0);
	return (int a[off], h, n);
}

#
# Utilities.
#
sha256(a: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	keyring->sha256(a, len a, d, nil);
	return d;
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

unhex(s: string): array of byte
{
	if(len s == 0 || len s % 2)
		return nil;
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++){
		hi := hexval(s[2*i]);
		lo := hexval(s[2*i+1]);
		if(hi < 0 || lo < 0)
			return nil;
		a[i] = byte (hi << 4 | lo);
	}
	return a;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

trim(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

hasbang(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '!')
			return 1;
	return 0;
}

user(): string
{
	return trim(readfile0("/dev/user"));
}

readbytes(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || d.length > big 65536)
		return nil;
	buf := array[int d.length] of byte;
	n := 0;
	while(n < len buf && (r := sys->read(fd, buf[n:], len buf - n)) > 0)
		n += r;
	return buf[0:n];
}

# A small file, or "" if it isn't there.
readfile0(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		fail("io", sys->sprint("can't open %s: %r", f));
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		fail("io", sys->sprint("can't read %s: %r", f));
	return string buf[0:n];
}

# One write: the brick takes each write as a whole command.
writefile(f, s: string)
{
	fd := sys->open(f, Sys->OWRITE);
	if(fd == nil)
		fail("io", sys->sprint("can't open %s: %r", f));
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		fail("io", sys->sprint("can't write %s: %r", f));
}

createfile(f, s: string, mode: int)
{
	createbytes(f, array of byte s, mode);
}

createbytes(f: string, b: array of byte, mode: int)
{
	fd := sys->create(f, Sys->OWRITE, mode);
	if(fd == nil)
		fail("io", sys->sprint("can't create %s: %r", f));
	if(sys->write(fd, b, len b) != len b)
		fail("io", sys->sprint("can't write %s: %r", f));
}

mkdirs(d: string)
{
	(ok, nil) := sys->stat(d);
	if(ok >= 0)
		return;
	for(i := len d - 1; i > 0; i--)
		if(d[i] == '/'){
			mkdirs(d[0:i]);
			break;
		}
	fd := sys->create(d, Sys->OREAD, Sys->DMDIR | 8r700);
	if(fd == nil)
		fail("io", sys->sprint("can't make %s: %r", d));
}

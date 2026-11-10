implement CryptoBench;

#
# crypto_bench: how fast this machine moves bytes through the crypto a
# 9P mount pays for, with no network: a copy (the floor), SHA-256 and
# HMAC-SHA-256, AES-256 in CBC and GCM, ChaCha20-Poly1305, and devssl
# itself between the ends of a loopback TCP connection (digest alone,
# and the aes_256_cbc sha256 that mount -C sets), and that connection
# with no devssl on it.  Each for -t seconds (2) on blocks of -b
# bytes (32K, a message of the size an encrypted mount now takes).  Not
# a test: it measures.  One line each:
#
#	what=NAME MB/s=R bytes=B ms=T
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "keyring.m";
	kr: Keyring;
include "security.m";
	ssl: SSL;

CryptoBench: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

secs := 2;
bsize := 32*1024;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	ssl = load SSL SSL->PATH;
	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("crypto_bench [-t secs] [-b bytes]");
	while((o := arg->opt()) != 0)
		case o {
		't' =>	secs = int arg->earg();
		'b' =>	bsize = int arg->earg();
		* =>	arg->usage();
		}
	buf := array[bsize] of byte;
	for(i := 0; i < len buf; i++)
		buf[i] = byte (i * 31);
	key := array[32] of {* => byte 7};
	out := array[bsize] of byte;
	digest := array[Keyring->SHA256dlen] of byte;

	# the floor: copying the block
	t0 := sys->millisec();
	n := big 0;
	while(sys->millisec() - t0 < secs*1000){
		out[0:] = buf;
		n += big bsize;
	}
	report("copy", n, sys->millisec() - t0);

	t0 = sys->millisec();
	n = big 0;
	while(sys->millisec() - t0 < secs*1000){
		kr->sha256(buf, len buf, digest, nil);
		n += big bsize;
	}
	report("sha256", n, sys->millisec() - t0);

	t0 = sys->millisec();
	n = big 0;
	while(sys->millisec() - t0 < secs*1000){
		kr->hmac_sha256(buf, len buf, key, digest, nil);
		n += big bsize;
	}
	report("hmac_sha256", n, sys->millisec() - t0);

	st := kr->aessetup(key, array[Keyring->AESbsize] of {* => byte 0});
	t0 = sys->millisec();
	n = big 0;
	while(sys->millisec() - t0 < secs*1000){
		kr->aescbc(st, buf, len buf, Keyring->Encrypt);
		n += big bsize;
	}
	report("aes256_cbc", n, sys->millisec() - t0);

	gs := kr->aesgcmsetup(key, array[12] of {* => byte 1});
	t0 = sys->millisec();
	n = big 0;
	while(sys->millisec() - t0 < secs*1000){
		kr->aesgcmencrypt(gs, buf, nil);
		n += big bsize;
	}
	report("aes256_gcm", n, sys->millisec() - t0);

	nonce := array[12] of {* => byte 2};
	t0 = sys->millisec();
	n = big 0;
	while(sys->millisec() - t0 < secs*1000){
		kr->ccpolyencrypt(buf, nil, key, nonce);
		n += big bsize;
	}
	report("chacha20_poly1305", n, sys->millisec() - t0);

	sslpipe("tcp_loopback", nil, buf);
	sslpipe("ssl_sha256", "sha256", buf);
	sslpipe("ssl_aes256cbc_sha256", "aes_256_gcm", buf);
}

# devssl pushed on both ends of a TCP connection over the loopback with
# alg; one process writes blocks, this one reads them, for secs.  (Not
# a pipe: a record larger than the pipe holds is never read whole.)
sslpipe(what, alg: string, buf: array of byte)
{
	(ok, ac) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0){
		sys->print("what=%s error=announce %r\n", what);
		return;
	}
	(nil, f) := sys->tokenize(readfile(ac.dir + "/local"), "!\n");
	srv := chan of ref Sys->FD;
	spawn accept(ac, srv);
	(dok, c) := sys->dial("tcp!127.0.0.1!" + hd tl f, nil);
	if(dok < 0){
		sys->print("what=%s error=dial %r\n", what);
		return;
	}
	sfd := <-srv;
	if(sfd == nil){
		sys->print("what=%s error=listen\n", what);
		return;
	}
	sa := array[64] of {* => byte 3};
	sb := array[64] of {* => byte 4};
	(w, e1) := (c.dfd, "");
	(r, e2) := (sfd, "");
	if(alg != nil){	# nil: the TCP connection alone
		(w, e1) = push(c.dfd, sa, sb, alg);
		(r, e2) = push(sfd, sb, sa, alg);
	}
	if(w == nil || r == nil){
		sys->print("what=%s error=%s%s\n", what, e1, e2);
		return;
	}
	stop := chan of int;
	spawn writer(w, buf, stop);
	rb := array[len buf] of byte;
	t0 := sys->millisec();
	n := big 0;
	while(sys->millisec() - t0 < secs*1000){
		k := sys->read(r, rb, len rb);
		if(k <= 0)
			break;
		n += big k;
	}
	ms := sys->millisec() - t0;
	report(what, n, ms);
	w = r = nil;
	stop <-= 1;
}

accept(ac: Sys->Connection, srv: chan of ref Sys->FD)
{
	(ok, c) := sys->listen(ac);
	if(ok < 0){
		srv <-= nil;
		return;
	}
	srv <-= sys->open(c.dir + "/data", Sys->ORDWR);
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

writer(fd: ref Sys->FD, buf: array of byte, stop: chan of int)
{
	for(;;) alt {
	<-stop =>
		return;
	* =>
		if(sys->write(fd, buf, len buf) != len buf)
			return;
	}
}

push(fd: ref Sys->FD, sin, sout: array of byte, alg: string): (ref Sys->FD, string)
{
	(err, c) := ssl->connect(fd);
	if(err != nil)
		return (nil, err);
	err = ssl->secret(c, sin, sout);
	if(err != nil)
		return (nil, err);
	if(sys->fprint(c.cfd, "alg %s", alg) < 0)
		return (nil, sys->sprint("alg %s: %r", alg));
	return (c.dfd, nil);
}

report(what: string, n: big, ms: int)
{
	if(ms <= 0)
		ms = 1;
	sys->print("what=%s MB/s=%.1f bytes=%bd ms=%d\n", what, real n / 1e6 / (real ms / 1000.0), n, ms);
}

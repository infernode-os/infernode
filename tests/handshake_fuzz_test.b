implement HandshakeFuzzTest;

#
# Handshake wire fuzzing (receiver robustness): a hostile client connects and
# sends malformed handshake bytes, then drops the connection.  The server's
# auth->server must FAIL CLOSED on every input -- return an error, never derive
# a secret, never crash, never hang.  This is the remote-protocol-attacker
# property (threat-model #2): a peer feeding garbage must not be able to wedge,
# crash, or fool the node.
#
# Real loopback TCP (so the malformed stream and its close behave exactly as on
# the wire), driving the production auth->server directly.  pqauth_test already
# covers two MITM negatives (flipped / truncated ML-KEM key mid-handshake);
# this sweeps a family of malformed *inbound* streams against the server.
#
# Each case is timeout-guarded so a HANG is reported as a failure.  Skips
# cleanly where the host has no IP stack.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";
	auth: Auth;

include "testing.m";
	testing: Testing;
	T: import testing;

HandshakeFuzzTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/handshake_fuzz_test.b";

# server outcome codes
CLEAN, ACCEPTED, CRASHED: con iota;	# 0 errored cleanly, 1 wrongly succeeded, 2 raised

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip" => ;
	* => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

mkauthinfo(signersk: ref Keyring->SK, signerpk: ref Keyring->PK,
		alpha, p: ref Keyring->IPint, name: string): ref Keyring->Authinfo
{
	sk := kr->genSKfromPK(signerpk, name);
	pk := kr->sktopk(sk);
	pkbuf := array of byte kr->pktostr(pk);
	state := kr->sha256(pkbuf, len pkbuf, nil, nil);
	cert := kr->sign(signersk, 0, state, "sha256");
	ai := ref Keyring->Authinfo;
	ai.mysk = sk; ai.mypk = pk; ai.cert = cert;
	ai.spk = signerpk; ai.alpha = alpha; ai.p = p;
	return ai;
}

timerproc(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# server: accept one connection, run auth->server, report the outcome.  A
# wrapped exception handler guarantees a crash is reported, not silently lost.
serveOnce(ai: ref Keyring->Authinfo, dfd: ref Sys->FD, rc: chan of int)
{
	outcome := CLEAN;
	{
		(wrapped, nil) := auth->server("aes_256_cbc" :: "sha256" :: nil, ai, dfd, 0);
		if(wrapped != nil)
			outcome = ACCEPTED;
	} exception {
	"*" =>
		outcome = CRASHED;
	}
	rc <-= outcome;
}

server(ac: Sys->Connection, ai: ref Keyring->Authinfo, rc: chan of int)
{
	for(;;){
		(lok, nc) := sys->listen(ac);
		if(lok < 0)
			return;
		dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if(dfd == nil)
			continue;
		spawn serveOnce(ai, dfd, rc);
	}
}

# hostile client: dial, write the malformed stream, drop the connection.
attacker(addr: string, data: array of byte)
{
	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0)
		return;
	if(len data > 0)
		sys->write(dc.dfd, data, len data);
	# returning drops dc -> socket closes, server sees the bytes then EOF
}

frame(len4: int, payload: array of byte): array of byte
{
	hdr := array of byte sys->sprint("%4.4d\n", len4);
	out := array[len hdr + len payload] of byte;
	out[0:] = hdr;
	out[len hdr:] = payload;
	return out;
}

# deterministic pseudo-random fill
fill(n, seed: int): array of byte
{
	a := array[n] of byte;
	s := seed;
	for(i := 0; i < n; i++){
		s = (s * 1103515245 + 12345) & 16r7fffffff;
		a[i] = byte (s >> 16);
	}
	return a;
}

# build malformed inbound stream `i`; returns (name, bytes) or (nil, nil) past the end
fuzzcase(i: int): (string, array of byte)
{
	case i {
	0 =>
		return ("empty", array[0] of byte);
	1 =>
		return ("garbage-512", fill(512, 1));
	2 =>
		return ("nonnumeric-header", array of byte "abcd\nhello world padding bytes here");
	3 =>		# claims 100 bytes, sends 10, then closes (truncated payload)
		return ("truncated-payload", frame(100, fill(10, 3)));
	4 =>		# claims 9000 bytes, sends 32, then closes (under-delivered)
		return ("underdelivered-len", frame(9000, fill(32, 4)));
	5 =>		# many zero-length frames then close
		{
			z := array of byte "";
			out := array[0] of byte;
			for(k := 0; k < 64; k++)
				out = concat(out, frame(0, z));
			return ("zerolen-flood", out);
		}
	6 =>
		return ("partial-header", array of byte "01");	# 2 bytes then close
	7 =>		# a plausible version frame, then garbage where alpha**r0 goes
		return ("garbage-after-version", concat(frame(1, array of byte "2"), frame(64, fill(64, 7))));
	8 =>		# well-formed framing, but every payload byte is 0xff
		{
			ff := array[200] of byte;
			for(k := 0; k < len ff; k++) ff[k] = byte 16rff;
			return ("allones-frames", concat(frame(200, ff), frame(200, ff)));
		}
	* =>
		return (nil, nil);
	}
}

concat(a, b: array of byte): array of byte
{
	out := array[len a + len b] of byte;
	out[0:] = a;
	out[len a:] = b;
	return out;
}

testFuzz(t: ref T)
{
	signersk := kr->genSK("ed25519", "fuzz-signer", 0);
	if(signersk == nil)
		t.fatal(sys->sprint("genSK: %r"));
	signerpk := kr->sktopk(signersk);
	(alpha, p) := kr->dhparams(2048);
	srv := mkauthinfo(signersk, signerpk, alpha, p, "server");

	addr := "tcp!127.0.0.1!19660";
	(aok, ac) := sys->announce(addr);
	if(aok < 0){
		t.skip(sys->sprint("network unavailable: %r"));
		return;
	}
	rc := chan of int;
	spawn server(ac, srv, rc);

	hangs := 0;
	accepts := 0;
	crashes := 0;
	total := 0;
	for(i := 0; ; i++){
		(name, data) := fuzzcase(i);
		if(name == nil)
			break;
		total++;
		spawn attacker(addr, data);

		tmo := chan of int;
		spawn timerproc(tmo, 15000);
		alt {
		outcome := <-rc =>
			case outcome {
			ACCEPTED =>
				accepts++;
				t.log(sys->sprint("%s: server ACCEPTED malformed input (derived a secret!)", name));
			CRASHED =>
				crashes++;
				t.log(sys->sprint("%s: server auth->server raised an exception", name));
			* =>
				; # clean error -- good
			}
		<-tmo =>
			hangs++;
			t.log(sys->sprint("%s: server hung (no result within timeout)", name));
		}
	}

	t.asserteq(accepts, 0, "no malformed inbound stream is accepted as a valid handshake");
	t.asserteq(crashes, 0, "no malformed inbound stream crashes auth->server");
	t.asserteq(hangs, 0, "no malformed inbound stream hangs the server");
	t.log(sys->sprint("fuzzed %d malformed inbound streams: all failed closed cleanly", total));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	testing = load Testing Testing->PATH;
	if(sys == nil || kr == nil || testing == nil)
		raise "fail:cannot load core modules";
	if(auth == nil)
		raise "fail:cannot load auth";
	auth->init();

	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("HandshakeFuzz", testFuzz);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

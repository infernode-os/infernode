implement SecstoreAbortProbe;

# Drives the secstore PAK abort path for lockout tests: establish the normal
# SSL transport, send a version 5 PAK hello, read mu, send an ML-KEM key,
# read the server's ciphertext and verifier, then close before sending k'.
# This simulates a guessing client that stops after learning its password
# guess was wrong from the server verifier.

include "sys.m";
	sys: Sys;

include "draw.m";

include "dial.m";

include "keyring.m";
	kr: Keyring;

include "encoding.m";
	base64: Encoding;

include "secstore.m";
	secstore: Secstore;

SecstoreAbortProbe: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	secstore = load Secstore Secstore->PATH;
	kr = load Keyring Keyring->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	if(secstore == nil || kr == nil || base64 == nil)
		fail("cannot load secstore");
	secstore->init();

	args = tl args;
	# -m value: send that for m in one hello, and print how the reply
	# begins (a server must refuse an m that is not in the group)
	if(args != nil && hd args == "-m"){
		args = tl args;
		if(args == nil || tl args == nil)
			usage();
		maddr := "tcp!localhost!5356";
		if(tl tl args != nil)
			maddr = hd tl tl args;
		mprobe(hd args, hd tl args, maddr);
		return;
	}
	if(args == nil)
		usage();
	user := hd args;
	args = tl args;
	if(args == nil)
		usage();
	count := int hd args;
	addr := "tcp!localhost!5356";
	args = tl args;
	if(args != nil)
		addr = hd args;

	for(i := 0; i < count; i++) {
		conn := secstore->dial(addr);
		if(conn == nil)
			fail(sys->sprint("dial %s failed: %r", addr));
		if(sys->fprint(conn.dfd, "secstore5\tPAK\nC=%s\nm=AQ==\n", user) < 0)
			fail(sys->sprint("hello write failed: %r"));
		buf := array[8192] of byte;
		n := sys->read(conn.dfd, buf, len buf);
		if(n <= 0)
			fail(sys->sprint("server's mu read failed: %r"));
		reply := string buf[0:n];
		if(len reply < 3 || reply[0:3] != "mu=")
			fail("unexpected server reply: " + reply);
		# an ML-KEM key, and the server's ciphertext and verifier for it
		(ek, nil) := kr->mlkem1024_keygen();
		if(sys->fprint(conn.dfd, "ek=%s\n", base64->enc(ek)) < 0)
			fail(sys->sprint("key write failed: %r"));
		n = sys->read(conn.dfd, buf, len buf);
		if(n <= 0)
			fail(sys->sprint("server verifier read failed: %r"));
		reply = string buf[0:n];
		if(len reply < 3 || reply[0:3] != "ct=")
			fail("unexpected server reply: " + reply);

		conn.dfd = nil;
		conn.cfd = nil;
		conn = nil;
	}

	sys->print("abort-probe: %d aborts sent for %s\n", count, user);
}

mprobe(m, user, addr: string)
{
	conn := secstore->dial(addr);
	if(conn == nil)
		fail(sys->sprint("dial failed: %r"));
	if(sys->fprint(conn.dfd, "secstore5\tPAK\nC=%s\nm=%s\n", user, m) < 0)
		fail(sys->sprint("hello write failed: %r"));
	buf := array[4096] of byte;
	n := sys->read(conn.dfd, buf, len buf);
	reply := "(nothing)";
	if(n > 0)
		reply = string buf[0:n];
	if(len reply > 12)
		reply = reply[0:12];
	sys->print("m-probe %s: reply begins %q\n", m, reply);
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: secstore_abort_probe user count [addr]\n");
	sys->fprint(sys->fildes(2), "       secstore_abort_probe -m value user [addr]\n");
	raise "fail:usage";
}

fail(msg: string)
{
	sys->fprint(sys->fildes(2), "secstore_abort_probe: %s\n", msg);
	raise "fail:" + msg;
}

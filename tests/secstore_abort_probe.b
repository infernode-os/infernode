implement SecstoreAbortProbe;

# Drives the secstore PAK abort path for lockout tests: establish the normal
# SSL transport, send a PAK hello, read the server verifier, then close before
# sending k'. This simulates a guessing client that stops after learning its
# password guess was wrong from the server verifier.

include "sys.m";
	sys: Sys;

include "draw.m";

include "dial.m";

include "secstore.m";
	secstore: Secstore;

SecstoreAbortProbe: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	secstore = load Secstore Secstore->PATH;
	if(secstore == nil)
		fail("cannot load secstore");
	secstore->init();

	args = tl args;
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

	# an m the server takes (an element of the group, as a client's
	# is), made from a password that is not the account's
	m := secstore->mkverifier(user, "secstore3", secstore->mkseckey2("not the password"));
	for(i := 0; i < count; i++) {
		conn := secstore->dial(addr);
		if(conn == nil)
			fail(sys->sprint("dial %s failed: %r", addr));
		if(sys->fprint(conn.dfd, "secstore3\tPAK\nC=%s\nm=%s\n", user, m) < 0)
			fail(sys->sprint("hello write failed: %r"));
		buf := array[4096] of byte;
		n := sys->read(conn.dfd, buf, len buf);
		if(n <= 0)
			fail(sys->sprint("server verifier read failed: %r"));
		reply := string buf[0:n];
		if(len reply < 3 || reply[0:3] != "mu=")
			fail("unexpected server reply: " + reply);

		conn.dfd = nil;
		conn.cfd = nil;
		conn = nil;
	}

	sys->print("abort-probe: %d aborts sent for %s\n", count, user);
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: secstore_abort_probe user count [addr]\n");
	raise "fail:usage";
}

fail(msg: string)
{
	sys->fprint(sys->fildes(2), "secstore_abort_probe: %s\n", msg);
	raise "fail:" + msg;
}

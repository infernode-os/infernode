implement NodeClient;

# Minimal connecting node for cross-binary interop testing.
#   node_client keyfile addr mountpt file outpath
# Reads its Authinfo, dials `addr`, authenticates with the hybrid PQ handshake,
# wraps the line in aes_256_cbc/sha256 ssl, mounts the remote export at
# `mountpt`, reads `mountpt+file` over the encrypted 9P channel and writes the
# bytes to `outpath` (so a harness can compare against the source). Prints
# OK/ERR summary to stderr.  (A dedicated output file avoids relying on how emu
# wires fd 1/2 when a .dis is run directly.)

include "sys.m"; sys: Sys;
include "draw.m";
include "keyring.m"; kr: Keyring;
include "security.m"; auth: Auth;

NodeClient: module { init: fn(nil: ref Draw->Context, args: list of string); };

fail(s: string) { sys->fprint(sys->fildes(2), "node_client: %s\n", s); raise "fail:error"; }

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	if(auth == nil) fail(sys->sprint("load Auth: %r"));
	if((e := auth->init()) != nil) fail("auth init: " + e);

	args = tl args;
	if(len args != 5) fail("usage: node_client keyfile addr mountpt file outpath");
	keyfile := hd args; addr := hd tl args; mountpt := hd tl tl args;
	file := hd tl tl tl args; outpath := hd tl tl tl tl args;

	ai := kr->readauthinfo(keyfile);
	if(ai == nil) fail(sys->sprint("readauthinfo %s: %r", keyfile));

	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0) fail(sys->sprint("dial %s: %r", addr));

	(wrapped, cerr) := auth->client("aes_256_cbc sha256", ai, dc.dfd);
	if(wrapped == nil) fail("client auth+ssl: " + cerr);
	sys->fprint(sys->fildes(2), "node_client: authenticated to %s\n", addr);

	sys->unmount(nil, mountpt);
	if(sys->mount(wrapped, nil, mountpt, Sys->MREPL, "") < 0) fail(sys->sprint("mount %s: %r", mountpt));

	fd := sys->open(mountpt + file, Sys->OREAD);
	if(fd == nil) fail(sys->sprint("open %s%s: %r", mountpt, file));
	out := sys->create(outpath, Sys->OWRITE, 8r644);
	if(out == nil) fail(sys->sprint("create %s: %r", outpath));
	tot := 0;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0) fail(sys->sprint("read: %r"));
		if(n == 0) break;
		if(sys->write(out, buf, n) != n) fail(sys->sprint("write %s: %r", outpath));
		tot += n;
	}
	sys->fprint(sys->fildes(2), "node_client: OK read %d bytes of %s over cert-auth + PQC + ssl\n", tot, file);
	sys->unmount(nil, mountpt);
}

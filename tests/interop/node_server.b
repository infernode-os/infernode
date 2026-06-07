implement NodeServer;

# Minimal serving node for cross-binary interop testing.
#   node_server keyfile addr exporttree
# Reads its Authinfo (a signer keyfile from auth/createsignerkey), announces
# `addr`, and on each connection authenticates the peer with the native hybrid
# post-quantum handshake, wraps the line in aes_256_cbc/sha256 ssl, and exports
# `exporttree` as a 9P service over the encrypted channel.

include "sys.m"; sys: Sys;
include "draw.m";
include "keyring.m"; kr: Keyring;
include "security.m"; auth: Auth;

NodeServer: module { init: fn(nil: ref Draw->Context, args: list of string); };

fail(s: string) { sys->fprint(sys->fildes(2), "node_server: %s\n", s); raise "fail:error"; }

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	if(auth == nil) fail(sys->sprint("load Auth: %r"));
	if((e := auth->init()) != nil) fail("auth init: " + e);

	args = tl args;
	if(len args != 3) fail("usage: node_server keyfile addr exporttree");
	keyfile := hd args; addr := hd tl args; tree := hd tl tl args;

	ai := kr->readauthinfo(keyfile);
	if(ai == nil) fail(sys->sprint("readauthinfo %s: %r", keyfile));

	(aok, ac) := sys->announce(addr);
	if(aok < 0) fail(sys->sprint("announce %s: %r", addr));
	sys->fprint(sys->fildes(2), "node_server: listening on %s, exporting %s\n", addr, tree);

	for(;;){
		(lok, nc) := sys->listen(ac);
		if(lok < 0) fail(sys->sprint("listen: %r"));
		dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if(dfd == nil) { sys->fprint(sys->fildes(2), "node_server: open data: %r\n"); continue; }
		spawn serve(ai, tree, dfd);
	}
}

serve(ai: ref Keyring->Authinfo, tree: string, dfd: ref Sys->FD)
{
	algs := "aes_256_cbc" :: "sha256" :: nil;
	(wrapped, who) := auth->server(algs, ai, dfd, 0);
	if(wrapped == nil) { sys->fprint(sys->fildes(2), "node_server: auth failed: %s\n", who); return; }
	sys->fprint(sys->fildes(2), "node_server: peer authenticated (%s); serving %s\n", who, tree);
	sys->export(wrapped, tree, Sys->EXPWAIT);
}

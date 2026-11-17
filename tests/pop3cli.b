implement Pop3cli;

#
# tests/host/pop3_tls_test.sh's client: pop3(2) as the mail readers use
# it (open, stat, msgnolist, get, delete, close), saying what each gave.
#
# usage: pop3cli server [fetchdir]	(server is host!port; TLS)
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "pop3.m";
	pop3: Pop3;

Pop3cli: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	pop3 = load Pop3 Pop3->PATH;
	if(pop3 == nil || len args < 2) {
		sys->print("pop3cli: usage: pop3cli server [fetchdir]\n");
		return;
	}
	server := hd tl args;
	pop3->timeout(3000);
	t0 := sys->millisec();
	(ok, s) := pop3->open("alice", "x", server, 1);
	sys->print("open: %d %s (%d ms)\n", ok, s, sys->millisec() - t0);
	if(ok < 0)
		return;
	(sok, serr, n, nil) := pop3->stat();
	sys->print("stat: %d %s messages=%d\n", sok, serr, n);
	(lok, lerr, l) := pop3->msgnolist();
	sys->print("list: %d %s", lok, lerr);
	for(; l != nil; l = tl l)
		sys->print(" %d", hd l);
	sys->print("\n");
	(gok, gerr, text) := pop3->get(1);
	sys->print("get: %d %s len=%d\n%s", gok, gerr, len text, text);
	if(gok >= 0) {
		(g2, g2err, t2) := pop3->get(2);
		sys->print("get2: %d %s\n%s", g2, g2err, t2);
	}
	if(len args > 2) {
		(fok, ferr) := pop3->fetch(hd tl tl args, 1);
		sys->print("fetch: %d %s\n", fok, ferr);
	}
	(dok, derr) := pop3->delete(2);
	sys->print("delete: %d %s\n", dok, derr);
	(cok, cerr) := pop3->close();
	sys->print("close: %d %s\n", cok, cerr);
}

implement Auditget;

#
# auditget - fetch and verify an audit-record payload from the
# provenance content store.
#
# A payload-bearing audit record carries content=<score> sha256=<hex>
# (see auditprov(2)). auditget fetches the payload by score, checks it
# against the given SHA-256, and streams it to standard output. The
# fetch alone already verifies the venti scores; -s additionally pins
# the payload to the hash the chain sealed.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;

include "draw.m";

include "arg.m";

include "auditprov.m";
	ap: AuditProv;

Auditget: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sprint("load arg: %r"));
	ap = load AuditProv AuditProv->PATH;
	if(ap == nil)
		fail(sprint("load auditprov: %r"));
	err := ap->init();
	if(err != nil)
		fail(err);

	addr, sha: string;
	arg->init(args);
	arg->setusage("auditget [-a addr] [-s sha256] score");
	while((c := arg->opt()) != 0)
		case c {
		'a' =>	addr = arg->earg();
		's' =>	sha = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();

	err = ap->attach(addr);
	if(err != nil)
		fail(err);
	(data, gerr) := ap->get(hd args);
	if(gerr != nil)
		fail(gerr);
	if(sha != nil) {
		got := ap->sha256(data);
		if(got != sha)
			fail("sha256 mismatch: payload " + got + ", record " + sha);
	}
	for(o := 0; o < len data; ) {
		n := sys->write(sys->fildes(1), data[o:], len data - o);
		if(n <= 0)
			fail(sprint("write: %r"));
		o += n;
	}
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "auditget: %s\n", s);
	raise "fail:" + s;
}

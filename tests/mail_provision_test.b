implement MailProbe;

# Regression test for INFR-364: with msg9p + the mockmail source running,
# namespace restriction hides /mnt/msg by default, while an explicit /mnt/msg
# grant exposes the read-only message status surface. Run inside
# tests/inferno/mail_provision.sh.

include "sys.m";
	sys: Sys;
include "draw.m";
include "nsconstruct.m";
	nsc: NsConstruct;

MailProbe: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	nsc = load NsConstruct NsConstruct->PATH;
	if(nsc == nil) {
		sys->print("MAILPROBE: FAIL cannot load nsconstruct\n");
		return;
	}
	nsc->init();

	mode := "grant";
	if(tl args != nil)
		mode = hd tl args;

	paths: list of string;
	if(mode == "grant")
		paths = "/mnt/msg" :: nil;
	else if(mode == "nogrant")
		paths = nil;
	else
		fail("unknown mode: " + mode);

	# A typical email task agent: read tool plus the paths explicitly granted
	# by the parent namespace. actid=-1 => no cowfs.
	caps := ref NsConstruct->Capabilities("read" :: nil, paths, nil, nil, nil, nil, 0, 0, -1, nil, nil);
	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil)
		fail(sys->sprint("restrictns err: %s", err));

	fd := sys->open("/mnt/msg/status", Sys->OREAD);
	if(mode == "nogrant") {
		if(fd == nil) {
			pass("nogrant hides /mnt/msg/status");
			return;
		}
		fail("nogrant unexpectedly exposes /mnt/msg/status");
	}

	if(fd == nil) {
		fail(sys->sprint("/mnt/msg/status not readable from restricted ns: %r"));
	}
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		fail("empty status read");
	s := string buf[0:n];
	if(contains(s, "unread")) {
		pass(sys->sprint("grant exposes /mnt/msg/status (%d bytes, has 'unread')", n));
		return;
	}
	fail("status readable but no 'unread': " + s);
}

pass(msg: string)
{
	sys->print("MAILPROBE: PASS %s\n", msg);
}

fail(msg: string)
{
	sys->print("MAILPROBE: FAIL %s\n", msg);
	raise "fail:mailprobe";
}

contains(hay, needle: string): int
{
	nl := len needle;
	for(i := 0; i <= len hay - nl; i++)
		if(hay[i:i+nl] == needle)
			return 1;
	return 0;
}

implement MailProbe;

# Regression test for INFR-364: with msg9p + the mockmail source running,
# a delegated child (restricted namespace) can read /mnt/msg/status and see the
# unread mail. Verifies both the harness provisioning and the nsconstruct
# /mnt/msg grant. Run inside tests/inferno/mail_provision.sh.

include "sys.m";
	sys: Sys;
include "draw.m";
include "nsconstruct.m";
	nsc: NsConstruct;

MailProbe: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	nsc = load NsConstruct NsConstruct->PATH;
	if(nsc == nil) {
		sys->print("MAILPROBE: FAIL cannot load nsconstruct\n");
		return;
	}
	nsc->init();

	# A typical email task agent: read tool only. actid=-1 => no cowfs.
	caps := ref NsConstruct->Capabilities("read" :: nil, nil, nil, nil, nil, nil, 0, 0, -1, nil, nil);
	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil)
		sys->print("MAILPROBE: restrictns err: %s\n", err);

	fd := sys->open("/mnt/msg/status", Sys->OREAD);
	if(fd == nil) {
		sys->print("MAILPROBE: FAIL /mnt/msg/status not readable from restricted ns: %r\n");
		return;
	}
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0) {
		sys->print("MAILPROBE: FAIL empty status read\n");
		return;
	}
	s := string buf[0:n];
	if(contains(s, "unread"))
		sys->print("MAILPROBE: PASS status readable from restricted child (%d bytes, has 'unread')\n", n);
	else
		sys->print("MAILPROBE: FAIL status readable but no 'unread': %s\n", s);
}

contains(hay, needle: string): int
{
	nl := len needle;
	for(i := 0; i <= len hay - nl; i++)
		if(hay[i:i+nl] == needle)
			return 1;
	return 0;
}

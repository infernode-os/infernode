implement MsgCapTest;

# Capability narrowing for /mnt/msg: granting "/mnt/msg" exposes ONLY the read
# surface (status); the proposal endpoint (draft) is invisible unless
# "/mnt/msg/draft" is granted separately. A reading agent cannot see or write
# the draft path. Run inside tests/inferno/msg_capability.sh.
#
#   msg_capability_test.dis draft   — caps.paths=["/mnt/msg"]:        status yes, draft NO
#   msg_capability_test.dis send    — caps.paths=["/mnt/msg/draft"]:  draft yes
#   msg_capability_test.dis flag    — caps.paths=["/mnt/msg/flag"]:   flag yes, ctl NO

include "sys.m";
	sys: Sys;
include "draw.m";
include "nsconstruct.m";
	nsc: NsConstruct;

MsgCapTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	nsc = load NsConstruct NsConstruct->PATH;
	if(nsc == nil) { sys->print("MSGCAP: FAIL load nsconstruct\n"); return; }
	nsc->init();

	mode := "draft";
	if(tl args != nil)
		mode = hd tl args;

	paths: list of string;
	if(mode == "send")
		paths = "/mnt/msg/draft" :: nil;
	else if(mode == "flag")
		paths = "/mnt/msg/flag" :: nil;
	else
		paths = "/mnt/msg" :: nil;

	caps := ref NsConstruct->Capabilities("read" :: nil, paths, nil, nil, nil, nil, 0, 0, -1, nil, nil);
	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil) { sys->print("MSGCAP %s: restrictns err: %s\n", mode, err); return; }

	(sok, nil) := sys->stat("/mnt/msg/status");
	(draftok, nil) := sys->stat("/mnt/msg/draft");
	(pok, nil) := sys->stat("/mnt/msg/pending");
	(aok, nil) := sys->stat("/mnt/msg/approve");
	(dok, nil) := sys->stat("/mnt/msg/deny");
	(fok, nil) := sys->stat("/mnt/msg/flag");
	(cok, nil) := sys->stat("/mnt/msg/ctl");
	statusvis := sok >= 0;
	draftvis := draftok >= 0;
	sys->print("MSGCAP %s: status=%d draft=%d\n", mode, statusvis, draftvis);

	if(mode == "send") {
		if(draftvis && pok < 0 && aok < 0 && dok < 0 && fok < 0 && cok < 0) {
			fd := sys->open("/mnt/msg/draft", Sys->OWRITE);
			if(fd == nil)
				fail(sys->sprint("send: cannot open draft: %r"));
			data := "email\n1\nqueued reply";
			b := array of byte data;
			if(sys->write(fd, b, len b) != len b)
				fail(sys->sprint("send: draft write rejected: %r"));
			sys->print("MSGCAP send: PASS draft visible with explicit /mnt/msg/draft grant and write queues\n");
		} else
			fail(sys->sprint("send: draft visible=%d pending=%d approve=%d deny=%d", draftvis, pok >= 0, aok >= 0, dok >= 0));
	} else if(mode == "flag") {
		if(fok >= 0 && cok < 0 && !draftvis)
			sys->print("MSGCAP flag: PASS flag visible, trusted ctl and draft HIDDEN\n");
		else
			fail(sys->sprint("flag: flag=%d ctl=%d draft=%d", fok >= 0, cok >= 0, draftvis));
	} else {
		if(statusvis && !draftvis)
			sys->print("MSGCAP draft: PASS read surface only — status visible, draft path HIDDEN\n");
		else
			fail(sys->sprint("draft: status=%d draft=%d; want status=1 draft=0", statusvis, draftvis));
	}
}

fail(msg: string)
{
	sys->print("MSGCAP: FAIL %s\n", msg);
	raise "fail:msgcap";
}

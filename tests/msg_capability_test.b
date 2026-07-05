implement MsgCapTest;

# Capability narrowing for /mnt/msg: granting "/mnt/msg" exposes ONLY the read
# surface (status); the send endpoint (reply) is invisible unless "/mnt/msg/reply"
# is granted separately. A drafting agent cannot see — let alone write — the send
# path. Run inside tests/inferno/msg_capability.sh (needs msg9p serving /mnt/msg).
#
#   msg_capability_test.dis draft   — caps.paths=["/mnt/msg"]:        status yes, reply NO
#   msg_capability_test.dis send    — caps.paths=["/mnt/msg/reply"]:  reply yes
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
		paths = "/mnt/msg/reply" :: nil;
	else if(mode == "flag")
		paths = "/mnt/msg/flag" :: nil;
	else
		paths = "/mnt/msg" :: nil;

	caps := ref NsConstruct->Capabilities("read" :: nil, paths, nil, nil, nil, nil, 0, 0, -1, nil);
	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil) { sys->print("MSGCAP %s: restrictns err: %s\n", mode, err); return; }

	(sok, nil) := sys->stat("/mnt/msg/status");
	(rok, nil) := sys->stat("/mnt/msg/reply");
	(pok, nil) := sys->stat("/mnt/msg/pending");
	(aok, nil) := sys->stat("/mnt/msg/approve");
	(dok, nil) := sys->stat("/mnt/msg/deny");
	(fok, nil) := sys->stat("/mnt/msg/flag");
	(cok, nil) := sys->stat("/mnt/msg/ctl");
	statusvis := sok >= 0;
	replyvis := rok >= 0;
	sys->print("MSGCAP %s: status=%d reply=%d\n", mode, statusvis, replyvis);

	if(mode == "send") {
		if(replyvis && pok < 0 && aok < 0 && dok < 0 && fok < 0 && cok < 0)
			sys->print("MSGCAP send: PASS reply visible with explicit /mnt/msg/reply grant\n");
		else
			sys->print("MSGCAP send: FAIL request visible=%d pending=%d approve=%d deny=%d\n", replyvis, pok >= 0, aok >= 0, dok >= 0);
	} else if(mode == "flag") {
		if(fok >= 0 && cok < 0 && !replyvis)
			sys->print("MSGCAP flag: PASS flag visible, trusted ctl and reply HIDDEN\n");
		else
			sys->print("MSGCAP flag: FAIL flag=%d ctl=%d reply=%d\n", fok >= 0, cok >= 0, replyvis);
	} else {
		if(statusvis && !replyvis)
			sys->print("MSGCAP draft: PASS read surface only — status visible, send path HIDDEN\n");
		else
			sys->print("MSGCAP draft: FAIL (status=%d reply=%d; want status=1 reply=0)\n", statusvis, replyvis);
	}
}

implement MsgCapTest;

# Capability narrowing for /mnt/msg: granting "/mnt/msg" exposes ONLY the read
# surface (status); the send endpoint (reply) is invisible unless "/mnt/msg/reply"
# is granted separately. A drafting agent cannot see — let alone write — the send
# path. Run inside tests/inferno/msg_capability.sh (needs msg9p serving /mnt/msg).
#
#   msg_capability_test.dis draft   — caps.paths=["/mnt/msg"]:        status yes, reply NO
#   msg_capability_test.dis send    — caps.paths=["/mnt/msg/reply"]:  reply yes

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
	else
		paths = "/mnt/msg" :: nil;

	caps := ref NsConstruct->Capabilities("read" :: nil, paths, nil, nil, nil, nil, 0, 0, -1, nil);
	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil) { sys->print("MSGCAP %s: restrictns err: %s\n", mode, err); return; }

	(sok, nil) := sys->stat("/mnt/msg/status");
	(rok, nil) := sys->stat("/mnt/msg/reply");
	statusvis := sok >= 0;
	replyvis := rok >= 0;
	sys->print("MSGCAP %s: status=%d reply=%d\n", mode, statusvis, replyvis);

	if(mode == "send") {
		if(replyvis)
			sys->print("MSGCAP send: PASS reply visible with explicit /mnt/msg/reply grant\n");
		else
			sys->print("MSGCAP send: FAIL reply should be visible when granted\n");
	} else {
		if(statusvis && !replyvis)
			sys->print("MSGCAP draft: PASS read surface only — status visible, send path HIDDEN\n");
		else
			sys->print("MSGCAP draft: FAIL (status=%d reply=%d; want status=1 reply=0)\n", statusvis, replyvis);
	}
}

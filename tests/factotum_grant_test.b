implement FacGrant;

# Deterministic security test for INFR-363 credential access.
# Applies nsconstruct->restrictns() in a forked namespace and checks that
# /mnt/factotum is visible (and the key readable) IFF the agent holds a tool
# that authenticates via factotum (websearch), and cannot execute arbitrary
# code. Expected: with => VISIBLE; without and withexec => HIDDEN.

include "sys.m";
	sys: Sys;
include "draw.m";
include "nsconstruct.m";
	nsc: NsConstruct;
include "factotum.m";
	fact: Factotum;

FacGrant: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	nsc = load NsConstruct NsConstruct->PATH;
	if(nsc == nil) {
		sys->print("FACGRANT: cannot load nsconstruct\n");
		return;
	}
	nsc->init();

	mode := "with";
	if(tl args != nil)
		mode = hd tl args;

	tools: list of string;
	if(mode == "with")
		tools = "websearch" :: "read" :: nil;
	else if(mode == "vision")
		tools = "vision" :: nil;
	else if(mode == "withexec")
		tools = "websearch" :: "exec" :: "read" :: nil;
	else
		tools = "read" :: nil;

	# Capabilities(tools, paths, shellcmds, llmconfig, fds, mcproviders,
	#              memory, xenith, actid, writepaths). actid=-1 => no cowfs.
	caps := ref NsConstruct->Capabilities(tools, nil, nil, nil, nil, nil, 0, 0, -1, nil);

	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil)
		sys->print("FACGRANT %s: restrictns err: %s\n", mode, err);

	(ok, nil) := sys->stat("/mnt/factotum");
	if(ok >= 0)
		sys->print("FACGRANT %s: /mnt/factotum VISIBLE\n", mode);
	else
		sys->print("FACGRANT %s: /mnt/factotum HIDDEN\n", mode);

	if(ok >= 0) {
		fact = load Factotum Factotum->PATH;
		if(fact != nil) {
			fact->init();
			(nil, pw) := fact->getuserpasswd("proto=pass service=brave");
			sys->print("FACGRANT %s: getuserpasswd keylen=%d\n", mode, len pw);
		}
	}
}

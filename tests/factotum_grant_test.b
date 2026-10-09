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
	mode := "";
	if(tl args != nil)
		mode = hd tl args;
	if(mode != "with" && mode != "vision" && mode != "withexec" && mode != "without")
		raise "skip:helper for tests/inferno/factotum_grant.sh, which runs it";

	nsc = load NsConstruct NsConstruct->PATH;
	if(nsc == nil) {
		sys->print("FACGRANT: FAIL cannot load nsconstruct: %r\n");
		raise "fail:facgrant";
	}
	nsc->init();

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
	caps := ref NsConstruct->Capabilities(tools, nil, nil, nil, nil, nil, 0, 0, -1, nil, nil);

	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil) {
		sys->print("FACGRANT %s: FAIL restrictns err: %s\n", mode, err);
		raise "fail:facgrant";
	}

	(ok, nil) := sys->stat("/mnt/factotum");
	if(ok >= 0)
		sys->print("FACGRANT %s: /mnt/factotum VISIBLE\n", mode);
	else
		sys->print("FACGRANT %s: /mnt/factotum HIDDEN\n", mode);

	# Granted only with a credentialed tool and no exec, which could
	# read the key out and hand it anywhere.
	want := mode == "with" || mode == "vision";
	if((ok >= 0) != want) {
		sys->print("FACGRANT %s: FAIL /mnt/factotum should be %s\n", mode, hidden(want));
		raise "fail:facgrant";
	}

	if(ok >= 0) {
		fact = load Factotum Factotum->PATH;
		if(fact == nil) {
			sys->print("FACGRANT %s: FAIL cannot load factotum: %r\n", mode);
			raise "fail:facgrant";
		}
		fact->init();
		(nil, pw) := fact->getuserpasswd("proto=pass service=brave");
		sys->print("FACGRANT %s: getuserpasswd keylen=%d\n", mode, len pw);
		if(len pw != len "DUMMYBRAVEKEY01") {
			sys->print("FACGRANT %s: FAIL the script's key not read through the grant\n", mode);
			raise "fail:facgrant";
		}
	}
	sys->print("FACGRANT %s: PASS\n", mode);
}

hidden(visible: int): string
{
	if(visible)
		return "VISIBLE";
	return "HIDDEN";
}

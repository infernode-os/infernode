implement WireformatTest;

#
# wireformat_test.b - Round-trip tests for the LLM-bridge TOOL: wire format.
#
# Both provider paths in appl/lib/llmclient.b normalise tool calls into the
# provider-agnostic wire format consumed by the agent stack:
#
#     STOP:<reason>
#     TOOL:<id>:<name>:<args>
#
# As of the Phase 1 fix, encode and decode are the SAME shared codec
# (module/wirefmt.m, appl/lib/wirefmt.b): the producer (llmclient.b) calls
# wirefmt->encodetool and the consumer (agentlib->parsellmresponse) calls
# wirefmt->parsetoolline. These tests exercise that real codec end to end:
# encodetool -> parsellmresponse -> recovered (id, name, args).
#
# History: before Phase 1 the escape (llmclient.b) and unescape (agentlib.b)
# halves were separate, incomplete inverses, so any arg containing a backslash
# was silently corrupted (taxonomy A1/A2) and a colon in id/name mis-split the
# line (B1). The cases marked "regression guard" below pin those exact inputs
# and now round-trip verbatim; they will fail if the codec ever regresses.
# See docs/veltro-llm-bridge-bug-taxonomy.md.
#
# To run: emu -r. /tests/wireformat_test.dis [-v]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "wirefmt.m";
	wirefmt: WireFmt;

include "../appl/veltro/agentlib.m";
	agentlib: AgentLib;

WireformatTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/wireformat_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Encode a tool call with the REAL shared producer codec, wrap it in a tool_use
# response exactly as llmsrv would, feed it through the REAL consumer, and
# return the recovered (id, name, args). A correct codec makes this the
# identity on every field.
roundtrip(id, name, args: string): (string, string, string)
{
	resp := "STOP:tool_use\n" + wirefmt->encodetool(id, name, args) + "\n";
	(nil, tools, nil) := agentlib->parsellmresponse(resp);
	if(tools == nil)
		return ("", "", "");
	return hd tools;
}

# ===================== basic round-trip identity =====================

testIdentityPlain(t: ref T)
{
	(id, name, args) := roundtrip("toolu_abc", "read", "/appl/veltro/repl.b");
	t.assertseq(id, "toolu_abc", "plain: id round-trips");
	t.assertseq(name, "read", "plain: name round-trips");
	t.assertseq(args, "/appl/veltro/repl.b", "plain: args round-trip");
}

testIdentityEmptyArgs(t: ref T)
{
	(nil, nil, args) := roundtrip("id1", "list", "");
	t.assertseq(args, "", "empty: args round-trip to empty");
}

# A real newline in args is escaped and restored -> identity.
testIdentityRealNewline(t: ref T)
{
	orig := "line1\nline2\nline3";
	(nil, nil, args) := roundtrip("tid", "write", orig);
	t.assertseq(args, orig, "real newline: multi-line args round-trip");
}

# Colons in args round-trip (escaped on the wire, restored on decode).
testIdentityColonInArgs(t: ref T)
{
	orig := "http://host:8080/path:with:colons";
	(nil, name, args) := roundtrip("tid", "webfetch", orig);
	t.assertseq(name, "webfetch", "colon-in-args: name intact");
	t.assertseq(args, orig, "colon-in-args: args round-trip");
}

testIdentityTrailingBackslash(t: ref T)
{
	orig := "ends-with-backslash\\";
	(nil, nil, args) := roundtrip("tid", "exec", orig);
	t.assertseq(args, orig, "trailing backslash: round-trips");
}

testIdentityBackslashOther(t: ref T)
{
	orig := "a\\bc";          # backslash, b, c
	(nil, nil, args) := roundtrip("tid", "exec", orig);
	t.assertseq(args, orig, "backslash-other: round-trips");
}

# =============== regression guards (formerly KNOWN DEFECT) ===============
# Taxonomy A1/A2/B1. Pre-Phase-1 these corrupted; the shared codec now makes
# them round-trip verbatim. If any of these fails, the wire-format codec has
# regressed — see docs/veltro-llm-bridge-bug-taxonomy.md.

# A1: a literal backslash-n in args (regex "\n", code written via write/edit)
# must survive as two characters, not collapse into a real newline.
testGuardA1_BackslashN(t: ref T)
{
	orig := "\\n";           # two chars: backslash, n
	(nil, nil, args) := roundtrip("tid", "grep", orig);
	t.assertseq(args, orig, "A1 guard: literal backslash-n round-trips (taxonomy A1)");
}

# A2: a doubled backslash (UNC path, escaped regex) must not collapse.
testGuardA2_DoubleBackslash(t: ref T)
{
	orig := "\\\\server";    # two actual backslashes, then "server"
	(nil, nil, args) := roundtrip("tid", "mount", orig);
	t.assertseq(args, orig, "A2 guard: doubled backslash round-trips (taxonomy A2)");
}

# B1: a colon in the tool name must not mis-split the line.
testGuardB1_ColonInName(t: ref T)
{
	(id, name, args) := roundtrip("tid", "foo:bar", "X");
	t.assertseq(id, "tid", "B1 guard: id correct");
	t.assertseq(name, "foo:bar", "B1 guard: colon in name preserved (taxonomy B1)");
	t.assertseq(args, "X", "B1 guard: args intact (taxonomy B1)");
}

# Belt-and-braces: a colon in the id too, plus a backslash in args.
testGuardColonInId(t: ref T)
{
	(id, name, args) := roundtrip("ns:42", "edit", "a\\nb");   # args: a, backslash, n, b
	t.assertseq(id, "ns:42", "colon-in-id: id preserved");
	t.assertseq(name, "edit", "colon-in-id: name intact");
	t.assertseq(args, "a\\nb", "colon-in-id: backslash arg intact");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

	wirefmt = load WireFmt WireFmt->PATH;
	if(wirefmt == nil) {
		sys->fprint(sys->fildes(2), "cannot load wirefmt module: %r\n");
		raise "fail:cannot load wirefmt";
	}
	wirefmt->init();

	agentlib = load AgentLib AgentLib->PATH;
	if(agentlib == nil) {
		sys->fprint(sys->fildes(2), "cannot load agentlib module: %r\n");
		raise "fail:cannot load agentlib";
	}
	agentlib->init();

	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("IdentityPlain", testIdentityPlain);
	run("IdentityEmptyArgs", testIdentityEmptyArgs);
	run("IdentityRealNewline", testIdentityRealNewline);
	run("IdentityColonInArgs", testIdentityColonInArgs);
	run("IdentityTrailingBackslash", testIdentityTrailingBackslash);
	run("IdentityBackslashOther", testIdentityBackslashOther);

	run("GuardA1_BackslashN", testGuardA1_BackslashN);
	run("GuardA2_DoubleBackslash", testGuardA2_DoubleBackslash);
	run("GuardB1_ColonInName", testGuardB1_ColonInName);
	run("GuardColonInId", testGuardColonInId);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

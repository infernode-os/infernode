implement WireformatTest;

#
# wireformat_test.b - Round-trip characterization of the LLM-bridge wire format.
#
# Phase 0 of the "systematically identify and fix" program for the
# Anthropic<->OpenAI bridge. See docs/veltro-llm-bridge-bug-taxonomy.md.
#
# Both provider paths in appl/lib/llmclient.b normalise tool calls into the
# provider-agnostic wire format consumed by the agent stack:
#
#     STOP:<reason>
#     TOOL:<id>:<name>:<args-with-newlines-escaped>
#
# The PRODUCER (llmclient.b:283 / :431 / :1067) escapes args with the recipe
# replicated below in wireescape(). The CONSUMER (agentlib->parsellmresponse
# -> parsetoolline -> unescapenl) reverses it. These tests drive the *real*
# consumer with the real producer recipe and assert what round-trips.
#
# Two suites:
#   - IDENTITY: cases that should (and currently do) round-trip. These are the
#     spec and the safety net for the upcoming codec refactor.
#   - KNOWN DEFECT: cases where unescape(escape(x)) != x today. We pin the
#     CURRENT (corrupted) output so the suite stays green; when the codec is
#     fixed to be a true inverse, these assertions go red and MUST be updated
#     to the identity behaviour. Each is cross-referenced to the taxonomy.
#
# To run: emu -r. /tests/wireformat_test.dis [-v]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

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

# --- producer side, replicated verbatim from llmclient.b:283/:431/:1067 ---
# safeargs := replaceall(args, "\n", "\\n");
# Implemented inline (no escape of backslash) so the test exercises the EXACT
# current producer contract. If llmclient.b's escaping changes, update here.
wireescape(args: string): string
{
	out := "";
	for(i := 0; i < len args; i++) {
		if(args[i] == '\n')
			out += "\\n";
		else
			out += args[i:i+1];
	}
	return out;
}

# Build the wire form exactly as the producer does, feed it through the real
# consumer, and return the recovered (id, name, args) for the single tool call.
roundtrip(id, name, args: string): (string, string, string)
{
	resp := "STOP:tool_use\nTOOL:" + id + ":" + name + ":" + wireescape(args) + "\n";
	(nil, tools, nil) := agentlib->parsellmresponse(resp);
	if(tools == nil)
		return ("", "", "");
	return hd tools;
}

# ============================ IDENTITY SUITE ============================
# These document the contract that the codec MUST preserve. They pass today.

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

# A real newline in args is escaped to \n by the producer and restored by the
# consumer -> identity. (This is the case the escaping was designed for.)
testIdentityRealNewline(t: ref T)
{
	orig := "line1\nline2\nline3";
	(nil, nil, args) := roundtrip("tid", "write", orig);
	t.assertseq(args, orig, "real newline: multi-line args round-trip");
}

# Colons in ARGS are safe: args is the unparsed remainder after the 2nd colon.
testIdentityColonInArgs(t: ref T)
{
	orig := "http://host:8080/path:with:colons";
	(nil, name, args) := roundtrip("tid", "webfetch", orig);
	t.assertseq(name, "webfetch", "colon-in-args: name intact");
	t.assertseq(args, orig, "colon-in-args: args round-trip (colons after field 2 are safe)");
}

# A trailing lone backslash round-trips (unescapenl's i+1<len guard keeps it).
testIdentityTrailingBackslash(t: ref T)
{
	orig := "ends-with-backslash\\";
	(nil, nil, args) := roundtrip("tid", "exec", orig);
	t.assertseq(args, orig, "trailing backslash: round-trips");
}

# A backslash followed by a non-n, non-backslash char round-trips (the '*'
# branch of unescapenl keeps the backslash).
testIdentityBackslashOther(t: ref T)
{
	orig := "a\\bc";          # backslash, b, c
	(nil, nil, args) := roundtrip("tid", "exec", orig);
	t.assertseq(args, orig, "backslash-other: round-trips");
}

# ========================== KNOWN DEFECT SUITE ==========================
# These pin CURRENT (corrupted) behaviour. See
# docs/veltro-llm-bridge-bug-taxonomy.md. When the escaping codec is fixed to
# be a true inverse, each of these will start round-tripping to identity and
# the assertion will FAIL -- that is the signal to replace it with the
# commented-out identity assertion beneath it.

# Taxonomy A1: literal backslash-n in args (e.g. a regex "\n", or code written
# via the write/edit tools) is corrupted into a real newline, because the
# producer does not escape the backslash but the consumer unescapes "\n".
testDefectA1_BackslashN(t: ref T)
{
	orig := "\\n";           # two chars: backslash, n
	(nil, nil, args) := roundtrip("tid", "grep", orig);
	# KNOWN DEFECT: corrupted to a single real newline.
	t.assertseq(args, "\n", "A1 KNOWN DEFECT: literal \\n corrupted to newline (see taxonomy A1)");
	# When fixed, replace the line above with:
	#   t.assertseq(args, orig, "A1: literal backslash-n round-trips");
}

# Taxonomy A2: a doubled backslash (e.g. UNC path "\\server") collapses to a
# single backslash, because the consumer unescapes "\\" -> "\" but the producer
# emitted it unescaped.
testDefectA2_DoubleBackslash(t: ref T)
{
	orig := "\\\\server";    # four source backslashes == two actual, then "server"
	(nil, nil, args) := roundtrip("tid", "mount", orig);
	# KNOWN DEFECT: leading "\\" collapses to "\".
	t.assertseq(args, "\\server", "A2 KNOWN DEFECT: \\\\ collapses to \\ (see taxonomy A2)");
	# When fixed, replace the line above with:
	#   t.assertseq(args, orig, "A2: doubled backslash round-trips");
}

# Taxonomy B1: a colon in the tool NAME mis-splits the line, because id/name
# are interpolated unescaped and split on the first two colons.
testDefectB1_ColonInName(t: ref T)
{
	(id, name, args) := roundtrip("tid", "foo:bar", "X");
	t.assertseq(id, "tid", "B1: id still correct");
	# KNOWN DEFECT: name truncated at the colon, remainder leaks into args.
	t.assertseq(name, "foo", "B1 KNOWN DEFECT: name truncated at colon (see taxonomy B1)");
	t.assertseq(args, "bar:X", "B1 KNOWN DEFECT: name remainder leaks into args (see taxonomy B1)");
	# When fixed, replace the two lines above with:
	#   t.assertseq(name, "foo:bar", "B1: colon in name preserved");
	#   t.assertseq(args, "X", "B1: args intact");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

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

	# Identity suite — the contract the codec must preserve.
	run("IdentityPlain", testIdentityPlain);
	run("IdentityEmptyArgs", testIdentityEmptyArgs);
	run("IdentityRealNewline", testIdentityRealNewline);
	run("IdentityColonInArgs", testIdentityColonInArgs);
	run("IdentityTrailingBackslash", testIdentityTrailingBackslash);
	run("IdentityBackslashOther", testIdentityBackslashOther);

	# Known-defect suite — pins current corrupted behaviour (see taxonomy).
	run("DefectA1_BackslashN", testDefectA1_BackslashN);
	run("DefectA2_DoubleBackslash", testDefectA2_DoubleBackslash);
	run("DefectB1_ColonInName", testDefectB1_ColonInName);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

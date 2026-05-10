implement ToolLimbo;

#
# limbo - Author Limbo source code via the dedicated Limbo-trained
# model (devstral-limbo-v3:latest). Routes the request to that
# model's /n/llm session, returns the fenced source.
#
# Why this exists: gpt-oss/low is the action-loop orchestrator
# (fast, no chat-template leakage) but cannot author Limbo —
# 0/10 compile-pass on standard scenarios because the base has
# no Limbo training. devstral-limbo-v3 is the dedicated Limbo
# author (10/10 compile-pass on the same scenarios). This tool
# gives the orchestrator a way to delegate Limbo authoring
# without polluting its own dispatch flow.
#
# v0 ships routing only. Follow-ups (tracked in IOL/INFR Jira):
#   - compile-gate-in-the-loop: pipe response through
#     tools/compile_gate/local.sh, return error if non-compiling
#     so the orchestrator can re-prompt with the gate's stderr.
#   - per-request budget guard against runaway re-prompt loops.
#   - session reuse across multiple calls in same Veltro request.
#
# See docs/LLM-AS-TOOL.md and docs/V4-LEARNINGS.md (in the
# infernode-os-llm repo) for the full design rationale.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "../tool.m";

ToolLimbo: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
};

# Configuration. The model name is the Ollama tag of the dedicated
# Limbo-author LoRA. If this isn't loaded on the configured serve-llm,
# the model write below will succeed (llmsrv accepts any string) and
# the request will fail when the backend reports the model as missing —
# the error surfaces in /ask's response, which we return verbatim.
LIMBO_MODEL:    con "devstral-limbo-v3:latest";
LIMBO_SYSTEM:   con "You are an expert Limbo programmer for the Inferno operating system. When given a description, respond with one complete, compilable Limbo source file inside a single ```limbo code fence. Do not add explanation outside the code fence.";

LLMROOT: con "/n/llm";
MAX_RESPONSE: con 65536;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	return nil;
}

name(): string
{
	return "limbo";
}

doc(): string
{
	return "limbo - Author a complete, compilable Limbo source file.\n\n" +
		"Args: a natural-language description of what the program should do.\n" +
		"Returns: the source code in a ```limbo code fence.\n\n" +
		"Use this whenever the user asks for Limbo, .b files, Inferno modules, " +
		"or any code that needs to run on Inferno.\n\n" +
		"DO NOT attempt to write Limbo yourself — the orchestrator's training " +
		"is general-purpose and will produce Go-style or Python-style code " +
		"the Inferno compiler rejects (verified 0/10 compile-pass). The " +
		"limbo tool dispatches to a dedicated Limbo-trained model that " +
		"produces compileable code (10/10 on the same scenarios).\n\n" +
		"Example:\n" +
		"  limbo a Cat command that copies stdin to stdout if argv is " +
		"empty, or concatenates each named file to stdout otherwise";
}

# Write `data` to the file at `path`, replacing existing contents.
writefile(path: string, data: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("error: cannot open %s for write: %r", path);
	buf := array of byte data;
	n := sys->write(fd, buf, len buf);
	if(n != len buf)
		return sys->sprint("error: short write to %s (%d of %d)", path, n, len buf);
	return nil;
}

# Read `path` fully (handles synthetic 9P files with length=0).
readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return ("", sys->sprint("error: cannot open %s: %r", path));
	CHUNK: con 8192;
	buf := array[CHUNK] of byte;
	total := 0;
	for(;;) {
		if(total >= len buf) {
			nb := array[len buf * 2] of byte;
			nb[0:] = buf;
			buf = nb;
		}
		if(total >= MAX_RESPONSE)
			break;
		n := sys->read(fd, buf[total:], len buf - total);
		if(n <= 0)
			break;
		total += n;
	}
	return (string buf[0:total], nil);
}

exec(args: string): string
{
	if(sys == nil) {
		err := init();
		if(err != nil)
			return "error: " + err;
	}

	desc := args;
	while(len desc > 0 && (desc[0] == ' ' || desc[0] == '\t' || desc[0] == '\n'))
		desc = desc[1:];
	while(len desc > 0 && (desc[len desc - 1] == ' ' || desc[len desc - 1] == '\t' || desc[len desc - 1] == '\n'))
		desc = desc[:len desc - 1];

	if(desc == "")
		return "error: usage: limbo <description-of-what-to-write>";

	# 1. Create a fresh session via /n/llm/new
	(idstr, rerr) := readfile(LLMROOT + "/new");
	if(rerr != nil)
		return "error: cannot create session (is /n/llm mounted? is serve-llm running?): " + rerr;
	idstr = str->drop(idstr, " \t\n");
	if(idstr == "")
		return "error: /n/llm/new returned empty session id";

	sessdir := sys->sprint("%s/%s", LLMROOT, idstr);

	# 2. Override session model to the Limbo author. llmsrv accepts any
	#    string; resolution happens at request-time.
	werr := writefile(sessdir + "/model", LIMBO_MODEL);
	if(werr != nil)
		return werr;

	# 3. Set the focused system prompt for code authoring.
	werr = writefile(sessdir + "/system", LIMBO_SYSTEM);
	if(werr != nil)
		return werr;

	# 4. Send the prompt. Writing to /ask triggers generation; reading
	#    /ask afterwards blocks until generation completes and returns
	#    the lastresponse (set by llmsrv's askprompt path).
	werr = writefile(sessdir + "/ask", desc);
	if(werr != nil)
		return werr;

	(resp, rerr2) := readfile(sessdir + "/ask");
	if(rerr2 != nil)
		return rerr2;

	# 5. Return the response. v0 returns it verbatim; the orchestrator
	#    sees the model's full output (typically a ```limbo fence with
	#    the source). Compile-gate-in-the-loop is a follow-up — when
	#    added, this is the place to extract the fenced block, run the
	#    gate, and either return clean source or the gate error so the
	#    orchestrator can re-prompt with the failure visible.
	if(resp == "")
		return "error: empty response from " + LIMBO_MODEL +
			" (is the model loaded on the configured serve-llm?)";
	return resp;
}

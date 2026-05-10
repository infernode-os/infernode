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

# Hosted Limbo compiler is a Command-style module loaded dynamically in gate().
Command: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
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

# Returns a non-empty token-name if the description looks like code
# the orchestrator wrote itself rather than a natural-language request.
# Empty return = looks like a description, OK to pass through.
# Detection is heuristic (tokens that are unambiguously code-shaped);
# the false-positive cost is low (orchestrator gets a clear error and
# re-prompts), the false-negative cost is high (devstral gets garbage).
codeshape(s: string): string
{
	# Multi-char language-marker tokens. Order matters: longer first.
	patterns := array[] of {
		"package main", "func main(", "func main {", "import \"",
		"#include", "include \"sys.m\"", "implement ", "<?php",
		"def main", "public static void", "console.log",
		"fmt.Println",
	};
	for(i := 0; i < len patterns; i++) {
		if(strstr(s, patterns[i]) >= 0)
			return patterns[i];
	}
	# Single-char tokens: braces and semicolons are decisive in this
	# arg context (no description should contain them). Allow common
	# punctuation: . , ' " - / etc.
	for(j := 0; j < len s; j++) {
		c := s[j];
		if(c == '{' || c == '}')
			return "{ or } (curly brace — code shape)";
		if(c == ';')
			return "; (semicolon — code shape)";
	}
	return "";
}

# strstr — substring search; returns first index or -1.
strstr(s, sub: string): int
{
	if(len sub == 0)
		return 0;
	for(i := 0; i + len sub <= len s; i++) {
		if(s[i:i+len sub] == sub)
			return i;
	}
	return -1;
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

	# 0. Args validation — orchestrators trained for code generation
	#    sometimes pass their own (wrong-language) source as args
	#    instead of a description. Catch the obvious cases and return
	#    a structured error so the orchestrator can re-prompt with
	#    a real description. Verified V4-PLAN finding: gpt-oss/low
	#    passed `args="package main\nimport \"fmt\"\nfunc main(){...}"`
	#    when asked for Limbo hello-world; devstral got Go-as-prompt
	#    and produced unrelated Limbo. (See INFR-2 v0 e2e findings.)
	bad := codeshape(desc);
	if(bad != "") {
		return "error: limbo tool received code-shaped input as args (token: " + bad + ").\n" +
			"Args must be a natural-language DESCRIPTION of what the program should do, " +
			"not source code. Re-call with a description.\n" +
			"Example: \"write a Limbo hello-world that prints 'hello, limbo'\"\n" +
			"Not:     \"package main; func main() {...}\"\n" +
			"If you have source in another language and want it ported, frame args as: " +
			"\"port this Python <description>: <source>\".";
	}

	# 1. Create a fresh session via /n/llm/new
	(idstr, rerr) := readfile(LLMROOT + "/new");
	if(rerr != nil)
		return "error: cannot create session (is /n/llm mounted? is serve-llm running?): " + rerr;
	# str->drop only strips LEADING chars; trim both ends manually so a
	# trailing newline doesn't end up in the session-dir path.
	while(len idstr > 0 && (idstr[0] == ' ' || idstr[0] == '\t' || idstr[0] == '\n' || idstr[0] == '\r'))
		idstr = idstr[1:];
	while(len idstr > 0 && (idstr[len idstr - 1] == ' ' || idstr[len idstr - 1] == '\t' || idstr[len idstr - 1] == '\n' || idstr[len idstr - 1] == '\r'))
		idstr = idstr[:len idstr - 1];
	if(idstr == "")
		return "error: /n/llm/new returned empty session id";

	sessdir := sys->sprint("%s/%s", LLMROOT, idstr);

	# 2. Override session model to the Limbo author. llmsrv accepts any
	#    string; resolution happens at request-time.
	werr := writefile(sessdir + "/model", LIMBO_MODEL);
	if(werr != nil)
		return werr;

	# 2a. Clear reasoning_effort. The serve-llm daemon default is "low"
	#     (set via -r flag) for the gpt-oss orchestrator's benefit, but
	#     devstral-limbo-v3 doesn't support reasoning_effort and Ollama
	#     returns 500 if it's set. Per-session writable file added in
	#     llmsrv (Qreasoning) for exactly this case.
	werr = writefile(sessdir + "/reasoning", "");
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

	if(resp == "")
		return "error: empty response from " + LIMBO_MODEL +
			" (is the model loaded on the configured serve-llm?)";

	# 5. Compile-gate-in-loop. Extract the first ```limbo block and run
	#    the hosted Limbo compiler against it. On compile-pass: return
	#    the response verbatim (orchestrator sees the source). On fail:
	#    append a structured <gate> diagnostic so the orchestrator can
	#    re-call /tool/limbo with a refined description that addresses
	#    the error. v1 is single-shot per call; internal retry is a v2
	#    follow-up (would require pushing failure context into the same
	#    /n/llm/<sid> conversation rather than re-entering at the tool
	#    boundary).
	gateerr := gate(resp, idstr);
	if(gateerr == "")
		return resp;
	return resp + "\n\n" + gateerr;
}

# Extract the first ```limbo ... ``` block from a model response.
# Returns "" if no fenced block is found (caller treats as gate-skip).
# Accepts ```limbo, ```b, or bare ``` as the opening fence — devstral
# is consistent with ```limbo but be liberal in what we accept.
extractblock(s: string): string
{
	(start, fencelen) := (-1, 0);
	tags := array[] of {"```limbo", "```b\n", "```b\r", "```\n"};
	taglens := array[] of {8, 5, 5, 4};
	for(i := 0; i < len tags; i++) {
		p := strstr(s, tags[i]);
		if(p >= 0 && (start < 0 || p < start)) {
			start = p;
			fencelen = taglens[i];
		}
	}
	if(start < 0)
		return "";
	body := start + fencelen;
	# tag list above already swallows the trailing \n where applicable;
	# for ```limbo we still need to skip an immediately-following \n.
	if(body < len s && s[body] == '\n')
		body++;
	for(end := body; end + 3 <= len s; end++) {
		if(s[end:end+3] == "```")
			return s[body:end];
	}
	return "";
}

# Compile-gate the response. Returns "" on pass (or skip), or a
# diagnostic block on fail. Uses the hosted /dis/limbo.dis compiler;
# stderr is redirected to a temp file via sys->dup so we can recover
# the diagnostic text and surface it to the orchestrator.
gate(resp: string, sid: string): string
{
	code := extractblock(resp);
	if(code == "")
		return "";

	srcpath := sys->sprint("/tmp/limbo-gate-%s.b", sid);
	werr := writefile(srcpath, code);
	if(werr != nil)
		return "";

	errpath := sys->sprint("/tmp/limbo-gate-%s.err", sid);
	dispath := srcpath[:len srcpath - 2] + ".dis";

	saved := sys->dup(2, -1);
	if(saved < 0) {
		sys->remove(srcpath);
		return "";
	}
	errfd := sys->create(errpath, Sys->OWRITE, 8r644);
	if(errfd == nil) {
		sys->dup(saved, 2);
		sys->remove(srcpath);
		return "";
	}
	sys->dup(errfd.fd, 2);
	errfd = nil;

	ok := 1;
	limbo := load Command "/dis/limbo.dis";
	if(limbo == nil) {
		ok = 0;
	} else {
		{
			limbo->init(nil, "limbo" :: "-I" :: "/module" :: srcpath :: nil);
		} exception {
		"*" =>
			ok = 0;
		}
	}
	limbo = nil;

	(stok, nil) := sys->stat(dispath);
	if(stok < 0)
		ok = 0;

	sys->dup(saved, 2);
	sys->remove(dispath);

	if(ok) {
		sys->remove(srcpath);
		sys->remove(errpath);
		return "";
	}

	(errtxt, _) := readfile(errpath);
	sys->remove(srcpath);
	sys->remove(errpath);

	return "<gate>\n" +
		"status: failed\n" +
		"compiler: hosted limbo (/dis/limbo.dis)\n" +
		"stderr:\n" + errtxt +
		"</gate>\n" +
		"The emitted Limbo did not compile. Re-call /tool/limbo with a description that avoids the above errors, or quote the failing line back to the user if the error is unfixable.";
}

implement LlmLive;

#
# Manual live diagnostic: drive the REAL llmclient->askopenai() against a
# real OpenAI-compatible backend (Ollama) so the actual parser path is
# exercised end-to-end against a real model — not a mock.
#
# Deliberately NOT named *_test so tests/runner.dis does not auto-run it
# (it needs a live backend). Run by hand:
#
#   emu -r$ROOT /tests/llmlive.dis mistral-small:latest http://127.0.0.1:11434/v1
#
# Prints the parsed AskResponse for: (1) a tool-mode prompt that should
# induce a tool call, and (2) a plain-text prompt.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "llmclient.m";
	llmclient: Llmclient;
	AskRequest, ToolDef: import llmclient;

LlmLive: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	llmclient = load Llmclient Llmclient->PATH;
	if(llmclient == nil) {
		sys->fprint(sys->fildes(2), "cannot load llmclient: %r\n");
		return;
	}
	llmclient->init();

	model := "mistral-small:latest";
	url := "http://127.0.0.1:11434/v1";
	args = tl args;
	if(args != nil) { model = hd args; args = tl args; }
	if(args != nil) { url = hd args; args = tl args; }

	sys->print("=== live llmclient->askopenai: model=%s url=%s ===\n", model, url);

	# Tool definition: a 'read' tool with a path argument.
	td := ref ToolDef;
	td.name = "read";
	td.description = "Read the contents of a file at an absolute path";
	td.inputschema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute file path\"}},\"required\":[\"path\"]}";

	# --- Probe 1: tool mode ---
	r1 := ref AskRequest;
	r1.model = model;
	r1.temperature = 0.0;
	r1.maxtokens = 0;
	r1.systemprompt = "You are an agent with tools. Use the read tool to read files when the user asks.";
	r1.prompt = "Please read the file /tool/editor/doc and tell me what it contains.";
	r1.tooldefs = td :: nil;
	r1.reasoningeffort = "";

	sys->print("\n--- PROBE 1: tool mode ---\n");
	(resp1, err1) := llmclient->askopenai(url, "", r1);
	if(err1 != nil)
		sys->print("ERROR: %s\n", err1);
	else {
		sys->print("response:\n%s\n", resp1.response);
		sys->print("structuredjson:\n%s\n", resp1.structuredjson);
		sys->print("tokens: %d\n", resp1.tokens);
		# Assert the recovered path is clean (no \/ mangling).
		if(strstr(resp1.response, "/tool/editor/doc") >= 0)
			sys->print("CHECK: clean path present  [OK]\n");
		else if(strstr(resp1.response, "\\/tool") >= 0)
			sys->print("CHECK: path is SLASH-MANGLED (\\/)  [BUG]\n");
		else
			sys->print("CHECK: path token not found (model may not have called the tool)\n");
	}

	# --- Probe 2: plain text mode ---
	r2 := ref AskRequest;
	r2.model = model;
	r2.temperature = 0.0;
	r2.maxtokens = 0;
	r2.systemprompt = "You are a terse assistant.";
	r2.prompt = "Reply with exactly the word: pong";
	r2.reasoningeffort = "";

	sys->print("\n--- PROBE 2: plain text mode ---\n");
	(resp2, err2) := llmclient->askopenai(url, "", r2);
	if(err2 != nil)
		sys->print("ERROR: %s\n", err2);
	else {
		sys->print("response: %s\n", resp2.response);
		sys->print("tokens: %d\n", resp2.tokens);
	}
}

strstr(haystack, needle: string): int
{
	hl := len haystack;
	nl := len needle;
	if(nl == 0) return 0;
	if(nl > hl) return -1;
	for(i := 0; i <= hl - nl; i++) {
		match := 1;
		for(j := 0; j < nl; j++)
			if(haystack[i+j] != needle[j]) { match = 0; break; }
		if(match) return i;
	}
	return -1;
}

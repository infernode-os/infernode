implement ReqshapeTest;

#
# llmclient_reqshape_test.b - Request-body shape tests for the LLM bridge.
#
# Phase 2 of the LLM-bridge bug program (taxonomy Class C): the Anthropic and
# OpenAI request bodies are assembled by hand-concatenated JSON. This test:
#
#   1. Locks the byte-exact shape of buildanthropicrequest /
#      buildopenairequestjson for representative requests, so any future
#      refactor of the builders must reproduce the wire bytes verbatim
#      (Anthropic prompt-cache prefix matching is byte-sensitive).
#   2. Guards the m.sc raw-insertion seam: a message with valid structured
#      content must splice in verbatim AND keep the whole body valid JSON; a
#      message with MALFORMED sc must NOT corrupt the body — the builder falls
#      back to a plain-text message and the body still parses.
#
# To run: emu -r. /tests/llmclient_reqshape_test.dis [-v]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;

include "json.m";
	json: JSON;

include "testing.m";
	testing: Testing;
	T: import testing;

include "llmclient.m";
	llmclient: Llmclient;
	AskRequest, LlmMessage, ToolDef: import Llmclient;

ReqshapeTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/llmclient_reqshape_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip" => ;
	* => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Does s parse as a single well-formed JSON value?
parsesok(s: string): int
{
	bio := bufio->aopen(array of byte s);
	if(bio == nil)
		return 0;
	(jv, err) := json->readjson(bio);
	return jv != nil && err == "";
}

# A small, representative request: system prompt, a single prompt, one tool.
basereq(): ref AskRequest
{
	td := ref ToolDef("read", "Read a file",
		"{\"type\":\"object\",\"properties\":{\"args\":{\"type\":\"string\"}},\"required\":[\"args\"]}");
	return ref AskRequest(
		nil,                # messages
		"hello",            # prompt
		"claude-sonnet-4-5",# model
		1.0,                # temperature
		1024,               # maxtokens
		"You are Veltro.",  # systemprompt
		0,                  # thinkingtokens
		"",                 # reasoningeffort
		"",                 # prefill
		td :: nil,          # tooldefs
		nil,                # toolresults
		nil);               # streamch
}

# A request whose history contains one assistant message with valid
# structured content (a tool_use block).
screq(sc: string): ref AskRequest
{
	m := ref LlmMessage("assistant", "I'll read it.", sc);
	return ref AskRequest(
		m :: nil, "", "claude-sonnet-4-5", 1.0, 1024, "sys",
		0, "", "", nil, nil, nil);
}

VALIDSC: con "[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\",\"input\":{\"args\":\"/x\"}}]";

# Byte-exact goldens captured from the current builders. These lock the wire
# shape (incl. the Anthropic cache_control prompt-cache markers) so any future
# refactor of the builders must reproduce the bytes verbatim. If a builder
# change is intentional, update these strings deliberately.
ANTHROPIC_GOLDEN: con "{\"model\":\"claude-sonnet-4-5\",\"max_tokens\":1024,\"temperature\":1.00,\"system\":[{\"type\":\"text\",\"text\":\"You are Veltro.\",\"cache_control\":{\"type\":\"ephemeral\"}}],\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}],\"tools\":[{\"name\":\"read\",\"description\":\"Read a file\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"args\":{\"type\":\"string\"}},\"required\":[\"args\"]},\"cache_control\":{\"type\":\"ephemeral\"}}],\"tool_choice\":{\"type\":\"auto\"}}";
OPENAI_GOLDEN: con "{\"model\":\"claude-sonnet-4-5\",\"max_tokens\":1024,\"temperature\":1.00,\"messages\":[{\"role\":\"system\",\"content\":\"You are Veltro.\"},{\"role\":\"user\",\"content\":\"hello\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read\",\"description\":\"Read a file\",\"parameters\":{\"type\":\"object\",\"properties\":{\"args\":{\"type\":\"string\"}},\"required\":[\"args\"]}}}],\"tool_choice\":\"auto\"}";

# ---- seam: valid sc splices verbatim and the whole body is valid JSON ----
testAnthropicValidSc(t: ref T)
{
	body := llmclient->buildanthropicrequest(screq(VALIDSC));
	t.assert(parsesok(body), "valid sc: body parses as JSON");
	t.assert(contains(body, VALIDSC), "valid sc: spliced verbatim");
}

# ---- seam fix: malformed sc must NOT corrupt the body ----
testAnthropicMalformedSc(t: ref T)
{
	body := llmclient->buildanthropicrequest(screq("[{ this is not json"));
	t.assert(parsesok(body), "malformed sc: body still parses (fallback, no corruption)");
	t.assert(!contains(body, "this is not json"), "malformed sc: garbage not spliced raw");
	t.assert(contains(body, "I'll read it."), "malformed sc: fell back to text content");
}

# ---- both builders always emit valid JSON for the base request ----
testAnthropicGolden(t: ref T)
{
	body := llmclient->buildanthropicrequest(basereq());
	t.assert(parsesok(body), "anthropic base: valid JSON");
	t.assertseq(body, ANTHROPIC_GOLDEN, "anthropic base: byte-exact request shape");
}

testOpenAiGolden(t: ref T)
{
	body := llmclient->buildopenairequestjson(basereq());
	t.assert(parsesok(body), "openai base: valid JSON");
	t.assertseq(body, OPENAI_GOLDEN, "openai base: byte-exact request shape");
}

contains(s, sub: string): int
{
	if(sub == "")
		return 1;
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:cannot load testing";
	}
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil) {
		sys->fprint(sys->fildes(2), "cannot load bufio: %r\n");
		raise "fail:cannot load bufio";
	}
	json = load JSON JSON->PATH;
	if(json == nil) {
		sys->fprint(sys->fildes(2), "cannot load json: %r\n");
		raise "fail:cannot load json";
	}
	json->init(bufio);
	llmclient = load Llmclient Llmclient->PATH;
	if(llmclient == nil) {
		sys->fprint(sys->fildes(2), "cannot load llmclient: %r\n");
		raise "fail:cannot load llmclient";
	}
	llmclient->init();

	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("AnthropicValidSc", testAnthropicValidSc);
	run("AnthropicMalformedSc", testAnthropicMalformedSc);
	run("AnthropicGolden", testAnthropicGolden);
	run("OpenAiGolden", testOpenAiGolden);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

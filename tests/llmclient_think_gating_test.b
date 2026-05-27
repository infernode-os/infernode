implement LlmclientThinkGatingTest;

#
# Regression test for INFR-132: llmclient must gate the Ollama
# `options.think` sub-object AND the OpenAI-standard `reasoning_effort`
# field on the *model's* thinking capability, not emit them blindly.
#
# Bug: buildopenairequestjson() used to call thinkoptions(tokens)
# unconditionally, embedding `{"think":false}` (or `{"think":true,...}`)
# on every request. Models that don't support thinking (mistral, llama,
# plain qwen, ...) reject such a request with:
#
#     Error: "<model>" does not support thinking
#
# This made cross-model A/B evaluation impossible: the first model worked,
# the hot-swapped second model failed every turn. Fix (commit 95b89b8):
# thinkmode(model, tokens) returns "" for non-thinking models, and the
# call site drops BOTH the options key and reasoning_effort when it does.
#
# The gating is only observable in the request body string, so the test
# calls the (now exposed) buildopenairequestjson directly and asserts on
# the wire format. No networking — deterministic in every environment.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "llmclient.m";
	llmclient: Llmclient;
	AskRequest: import llmclient;

LlmclientThinkGatingTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/llmclient_think_gating_test.b";

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

# Build a chat AskRequest; only the fields that influence thinking gating
# vary between tests.
mkreq(model: string, thinkingtokens: int, reasoningeffort: string): ref AskRequest
{
	r := ref AskRequest;
	r.model = model;
	r.temperature = 0.0;
	r.maxtokens = 0;
	r.systemprompt = "You are Veltro.";
	r.prompt = "Hello.";
	r.messages = nil;
	r.tooldefs = nil;
	r.toolresults = nil;
	r.thinkingtokens = thinkingtokens;
	r.reasoningeffort = reasoningeffort;
	r.prefill = "";
	r.streamch = nil;
	return r;
}

body(model: string, thinkingtokens: int, reasoningeffort: string): string
{
	return llmclient->buildopenairequestjson(mkreq(model, thinkingtokens, reasoningeffort));
}

# gpt-oss is a thinking-required model: the request MUST carry the Ollama
# options.think object and (when set) the reasoning_effort field.
testGptOssEmitsThinkAndEffort(t: ref T)
{
	b := body("gpt-oss:20b", 0, "low");
	t.log("request body: " + b);
	t.assert(strstr(b, "\"options\":{\"think\":true") >= 0,
		"gpt-oss request must include options.think:true");
	t.assert(strstr(b, "\"think_level\":\"low\"") >= 0,
		"gpt-oss tokens==0 must default think_level to low");
	t.assert(strstr(b, "\"reasoning_effort\":\"low\"") >= 0,
		"gpt-oss request must forward reasoning_effort when set");
}

# mistral does not support thinking: NEITHER options.think NOR
# reasoning_effort may appear, even when reasoningeffort is set on the
# request. This is the exact condition INFR-132 regressed on.
testMistralOmitsThinkAndEffort(t: ref T)
{
	b := body("mistral-small:latest", 0, "low");
	t.log("request body: " + b);
	t.assert(strstr(b, "\"options\"") < 0,
		"mistral request must NOT include an options block");
	t.assert(strstr(b, "\"reasoning_effort\"") < 0,
		"mistral request must NOT include reasoning_effort");
	t.assert(strstr(b, "\"think\"") < 0,
		"mistral request must NOT mention think at all");
}

# deepseek-r1 is also in the thinking-required family.
testDeepseekEmitsThink(t: ref T)
{
	b := body("deepseek-r1:7b", 0, "");
	t.log("request body: " + b);
	t.assert(strstr(b, "\"options\":{\"think\":true") >= 0,
		"deepseek-r1 request must include options.think:true");
}

# Plain llama (no thinking support) must also be omitted — guards against
# a future whitelist that's too broad.
testLlamaOmitsThink(t: ref T)
{
	b := body("llama3.1:8b", 0, "high");
	t.log("request body: " + b);
	t.assert(strstr(b, "\"options\"") < 0,
		"llama request must NOT include an options block");
	t.assert(strstr(b, "\"reasoning_effort\"") < 0,
		"llama request must NOT include reasoning_effort");
}

# think_level scales with the requested budget for thinking models.
testThinkLevelScalesWithBudget(t: ref T)
{
	lo := body("gpt-oss:20b", 5000, "");
	t.log("5000-token body: " + lo);
	t.assert(strstr(lo, "\"think_level\":\"low\"") >= 0,
		"a 5000-token budget must map to think_level low");

	mid := body("gpt-oss:20b", 15000, "");
	t.log("15000-token body: " + mid);
	t.assert(strstr(mid, "\"think_level\":\"medium\"") >= 0,
		"a 15000-token budget must map to think_level medium");

	hi := body("gpt-oss:20b", 30000, "");
	t.log("30000-token body: " + hi);
	t.assert(strstr(hi, "\"think_level\":\"high\"") >= 0,
		"a 30000-token budget must map to think_level high");
}

# Tiny substring search — returns index of needle in haystack, or -1.
strstr(haystack, needle: string): int
{
	hl := len haystack;
	nl := len needle;
	if(nl == 0)
		return 0;
	if(nl > hl)
		return -1;
	for(i := 0; i <= hl - nl; i++) {
		match := 1;
		for(j := 0; j < nl; j++)
			if(haystack[i+j] != needle[j]) {
				match = 0;
				break;
			}
		if(match)
			return i;
	}
	return -1;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	llmclient = load Llmclient Llmclient->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(llmclient == nil) {
		sys->fprint(sys->fildes(2), "cannot load llmclient module: %r\n");
		raise "fail:cannot load llmclient";
	}
	testing->init();
	llmclient->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("GptOssEmitsThinkAndEffort", testGptOssEmitsThinkAndEffort);
	run("MistralOmitsThinkAndEffort", testMistralOmitsThinkAndEffort);
	run("DeepseekEmitsThink", testDeepseekEmitsThink);
	run("LlamaOmitsThink", testLlamaOmitsThink);
	run("ThinkLevelScalesWithBudget", testThinkLevelScalesWithBudget);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

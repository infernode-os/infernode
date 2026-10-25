implement LlmclientAnthropicTest;

#
# llmclient_anthropic_test.b - what llmclient asks of, and reads from,
# the Anthropic Messages API.
#
# The request a model is sent depends on its generation: a current
# Claude refuses temperature, prefill and a thinking budget (a 400
# each), a legacy one takes them.  The reply is read into the content
# blocks the model wrote, in order: thinking kept whole (the API must be
# given it back in a tool exchange), a reply cut off by max_tokens said
# as such, a tool call cut off with it kept as valid JSON.  And a failed
# request is tried again only when that is worth it.
#
# To run: emu -r. /tests/llmclient_anthropic_test.dis [-v]
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
	AskRequest, LlmMessage, ToolDef, ToolResult: import Llmclient;

LlmclientAnthropicTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/llmclient_anthropic_test.b";

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

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

parsesok(s: string): int
{
	bio := bufio->aopen(array of byte s);
	if(bio == nil)
		return 0;
	(jv, err) := json->readjson(bio);
	return jv != nil && err == "";
}

readtool(): ref ToolDef
{
	return ref ToolDef("read", "Read a file",
		"{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}");
}

req(model: string, think: int, effort, prefill: string, tools: int): ref AskRequest
{
	td: list of ref ToolDef;
	if(tools)
		td = readtool() :: nil;
	return ref AskRequest(nil, "hello", model, 0.2, 0, "sys", think, effort,
		prefill, td, nil, nil);
}

testGenerations(t: ref T)
{
	cases := array[] of {
		("claude-haiku-4-5-20251001", Llmclient->CLAUDE_LEGACY),
		("claude-sonnet-4-5", Llmclient->CLAUDE_LEGACY),
		("claude-sonnet-4-20250514", Llmclient->CLAUDE_LEGACY),
		("claude-opus-4-1-20250805", Llmclient->CLAUDE_LEGACY),
		("claude-3-5-haiku-20241022", Llmclient->CLAUDE_LEGACY),
		("claude-opus-4-6", Llmclient->CLAUDE_46),
		("claude-sonnet-4-6", Llmclient->CLAUDE_46),
		("claude-opus-4-7", Llmclient->CLAUDE_MODERN),
		("claude-opus-4-8", Llmclient->CLAUDE_MODERN),
		("claude-opus-5-5", Llmclient->CLAUDE_MODERN),
		("claude-sonnet-5-5", Llmclient->CLAUDE_MODERN),
		("claude-haiku-5-5", Llmclient->CLAUDE_MODERN),
		("claude-fable-5-1", Llmclient->CLAUDE_MODERN),
		("some-future-model", Llmclient->CLAUDE_MODERN),
	};
	for(i := 0; i < len cases; i++) {
		(m, want) := cases[i];
		t.asserteq(llmclient->claudegen(m), want, m);
	}
}

# A current model: no temperature, no prefill, thinking adaptive when
# asked for, its depth the effort; a cap with room for a whole file.
testModernRequest(t: ref T)
{
	body := llmclient->buildanthropicrequest(req("claude-haiku-5-5", 0, "", "[Veltro] ", 0));
	t.assert(parsesok(body), "valid JSON");
	t.assert(!contains(body, "temperature"), "no temperature: " + body);
	t.assert(!contains(body, "[Veltro]"), "no prefill");
	t.assert(!contains(body, "\"thinking\""), "no thinking unless asked");
	t.assert(contains(body, "\"max_tokens\":16000"), "unstreamed default cap");

	body = llmclient->buildanthropicrequest(req("claude-sonnet-5-5", 8000, "high", "", 1));
	t.assert(parsesok(body), "valid JSON (thinking)");
	t.assert(contains(body, "\"thinking\":{\"type\":\"adaptive\"}"), "adaptive thinking: " + body);
	t.assert(contains(body, "\"output_config\":{\"effort\":\"high\"}"), "effort");
	t.assert(!contains(body, "budget_tokens"), "no budget");

	r := req("claude-opus-5-5", 0, "", "", 1);
	r.streamch = chan of string;
	body = llmclient->buildanthropicrequest(r);
	t.assert(contains(body, "\"max_tokens\":32000"), "streamed default cap");
	t.assert(contains(body, "\"stream\":true"), "streamed");
}

# A legacy model: temperature and prefill as before; thinking as a
# budget below max_tokens, and then no temperature.
testLegacyRequest(t: ref T)
{
	body := llmclient->buildanthropicrequest(req("claude-haiku-4-5", 0, "", "[Veltro] ", 0));
	t.assert(contains(body, "\"temperature\":0.20"), "temperature kept: " + body);
	t.assert(contains(body, "[Veltro] "), "prefill kept");

	r := req("claude-haiku-4-5", 20000, "high", "", 1);
	r.maxtokens = 8000;
	body = llmclient->buildanthropicrequest(r);
	t.assert(parsesok(body), "valid JSON");
	t.assert(contains(body, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":20000}"), "budget: " + body);
	t.assert(contains(body, "\"max_tokens\":24096"), "max_tokens above the budget");
	t.assert(!contains(body, "temperature"), "no temperature with thinking");
	t.assert(!contains(body, "output_config"), "no effort on a legacy model");
}

# The newest message carries the conversation's cache breakpoint: the
# prompt, or the last of the tool results.
testCacheBreakpoint(t: ref T)
{
	r := req("claude-haiku-5-5", 0, "", "", 1);
	r.prompt = "";
	r.messages = ref LlmMessage("user", "q", "") ::
		ref LlmMessage("assistant", "", "[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"read\",\"input\":{}},{\"type\":\"tool_use\",\"id\":\"b\",\"name\":\"read\",\"input\":{}}]") :: nil;
	r.toolresults = ref ToolResult("a", "one") :: ref ToolResult("b", "two") :: nil;
	body := llmclient->buildanthropicrequest(r);
	t.assert(parsesok(body), "valid JSON");
	t.assert(contains(body, "\"tool_use_id\":\"a\",\"content\":\"one\"}"), "first result unmarked: " + body);
	t.assert(contains(body, "\"tool_use_id\":\"b\",\"content\":\"two\",\"cache_control\":{\"type\":\"ephemeral\"}}"), "last result marked");
	n := 0;
	for(i := 0; i + 13 <= len body; i++)
		if(body[i:i+13] == "cache_control")
			n++;
	t.asserteq(n, 3, "three breakpoints: system, tools, newest message");
}

THINKREPLY: con "{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[" +
	"{\"type\":\"thinking\",\"thinking\":\"look first\",\"signature\":\"SIG==\"}," +
	"{\"type\":\"text\",\"text\":\"Reading it.\"}," +
	"{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\",\"input\":{\"path\":\"/x\"}}]," +
	"\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":10,\"cache_read_input_tokens\":1000," +
	"\"cache_creation_input_tokens\":5,\"output_tokens\":20}}";

# Thinking is kept, whole and first, in what is replayed; the tokens
# are the context's: input, cache reads and writes, output.
testThinkingKept(t: ref T)
{
	(resp, err) := llmclient->parseanthropicresponse(THINKREPLY, req("claude-haiku-5-5", 0, "", "", 1));
	if(err != nil)
		t.fatal("parse: " + err);
	t.assert(contains(resp.response, "STOP:tool_use\nTOOL:toolu_1:read:"), "tool call: " + resp.response);
	t.assert(contains(resp.response, "Reading it."), "text");
	t.assert(!contains(resp.response, "look first"), "thinking not shown");
	t.assert(parsesok(resp.structuredjson), "history valid JSON");
	t.assert(contains(resp.structuredjson,
		"[{\"type\":\"thinking\",\"thinking\":\"look first\",\"signature\":\"SIG==\"},{\"type\":\"text\""),
		"thinking first, with its signature: " + resp.structuredjson);
	t.asserteq(resp.tokens, 1035, "tokens");
}

SSEREPLY: con
	"event: message_start\n" +
	"data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7,\"cache_read_input_tokens\":100,\"output_tokens\":1}}}\n\n" +
	"data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}\n" +
	"data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hm\"}}\n" +
	"data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"S1\"}}\n" +
	"data: {\"type\":\"content_block_stop\",\"index\":0}\n" +
	"data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" +
	"data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Writ\"}}\n" +
	"data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"ing.\"}}\n" +
	"data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t9\",\"name\":\"write\",\"input\":{}}}\n" +
	"data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/tmp/a\\\",\\\"content\\\":\\\"lo\"}}\n" +
	"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":40}}\n" +
	"data: {\"type\":\"message_stop\"}\n";

# Streamed: the blocks in their order; cut off by max_tokens, the turn
# says so, and the call cut off with it is kept as valid JSON.
testStreamCutOff(t: ref T)
{
	(resp, err) := llmclient->parseanthropicsse(SSEREPLY, req("claude-haiku-5-5", 0, "", "", 1));
	if(err != nil)
		t.fatal("parse: " + err);
	t.assert(contains(resp.response, "STOP:max_tokens\n"), "max_tokens said: " + resp.response);
	t.assert(contains(resp.response, "TOOL:t9:write:{}"), "cut-off call's arguments: {}");
	t.assert(contains(resp.response, "Writing."), "text joined");
	t.assert(parsesok(resp.structuredjson), "history valid JSON: " + resp.structuredjson);
	t.assert(contains(resp.structuredjson, "{\"type\":\"thinking\",\"thinking\":\"hm\",\"signature\":\"S1\"}"), "thinking with signature");
	t.asserteq(resp.tokens, 147, "tokens");
}

testStreamError(t: ref T)
{
	body := "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n";
	(nil, err) := llmclient->parseanthropicsse(body, req("claude-haiku-5-5", 0, "", "", 1));
	t.assert(err != nil && contains(err, "overloaded_error"), "error event: " + err);
}

testRetry(t: ref T)
{
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 529 Overloaded: {}", 0), 1000, "529");
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 429 Too Many Requests retry-after=7: {}", 0), 7000, "429 retry-after");
	t.asserteq(llmclient->retrydelay("openai: HTTP error: HTTP/1.1 503 Service Unavailable", 2), 4000, "503 backoff");
	t.asserteq(llmclient->retrydelay("openai: cannot connect to localhost: connection refused", 1), 2000, "not listening");
	t.asserteq(llmclient->retrydelay("anthropic: overloaded_error: Overloaded", 0), 1000, "overloaded event");
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 400 Bad Request: {}", 0), -1, "400 not retried");
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 401 Unauthorized", 0), -1, "401 not retried");
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 429 x retry-after=600", 0), 60000, "capped");
}

# OpenAI shape: no cap set is none sent; a cut-off reply is said; an
# explicit thinking request reaches a model the table does not know.
testOpenAi(t: ref T)
{
	r := req("qwen3:8b", 0, "", "", 1);
	body := llmclient->buildopenairequestjson(r);
	t.assert(!contains(body, "max_tokens"), "no cap sent: " + body);
	t.assert(!contains(body, "reasoning_effort"), "no reasoning unasked");
	r.thinkingtokens = 15000;
	body = llmclient->buildopenairequestjson(r);
	t.assert(contains(body, "\"reasoning_effort\":\"medium\""), "reasoning asked: " + body);
	r.maxtokens = 500;
	body = llmclient->buildopenairequestjson(r);
	t.assert(contains(body, "\"max_tokens\":500"), "cap sent when set");
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
	json = load JSON JSON->PATH;
	if(bufio == nil || json == nil) {
		sys->fprint(sys->fildes(2), "cannot load bufio/json: %r\n");
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

	run("Generations", testGenerations);
	run("ModernRequest", testModernRequest);
	run("LegacyRequest", testLegacyRequest);
	run("CacheBreakpoint", testCacheBreakpoint);
	run("ThinkingKept", testThinkingKept);
	run("StreamCutOff", testStreamCutOff);
	run("StreamError", testStreamError);
	run("Retry", testRetry);
	run("OpenAi", testOpenAi);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

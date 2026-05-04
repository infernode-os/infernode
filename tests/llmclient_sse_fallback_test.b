implement LlmclientSseFallbackTest;

#
# Regression test for the SSE fallback in parseopenaisseresponse.
#
# Bug: when llmsrv requests `stream: true` from an OpenAI-compatible
# backend that doesn't actually implement SSE streaming (e.g. our local
# Devstral chat_server.py, vLLM with stream disabled, etc.), the backend
# silently returns a complete chat.completion JSON object instead of
# `data: …` SSE chunks. The original parseopenaisseresponse looked only
# for `data: ` prefixes, found none, and returned an empty AskResponse —
# the model's actual content was visible in the body but discarded.
#
# Fix (appl/lib/llmclient.b parseopenaisseresponse): if the body starts
# with `{` after any whitespace, fall through to parseopenairesponse.
#
# This test exercises the public askopenai entry point against a tiny
# in-process mock HTTP server so the dispatch and parsing chain are both
# covered. See docs/postmortems/2026-05-04-* (boot-decouple postmortem
# discusses adjacent issues; the SSE bug surfaced in the same session).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "llmclient.m";
	llmclient: Llmclient;
	AskRequest, AskResponse, LlmMessage: import llmclient;

LlmclientSseFallbackTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/llmclient_sse_fallback_test.b";

passed := 0;
failed := 0;
skipped := 0;

# Canned chat.completion JSON body the mock server returns for every
# request. Single assistant message, finish_reason="stop", no tool_calls.
# Content has an embedded apostrophe so we also catch any naive
# byte-stripping in the parser path.
EXPECTED_CONTENT: con "Hello! I'm Veltro.";
RESP_JSON: con "{\"id\":\"chatcmpl-test\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"devstral-limbo-v2\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"Hello! I'm Veltro.\"},\"finish_reason\":\"stop\"}],\"usage\":{\"completion_tokens\":-1,\"prompt_tokens\":-1,\"total_tokens\":-1}}";

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

# Mock HTTP server: announce on port, listen for one connection, read
# whatever HTTP request comes in, write back a fixed chat.completion
# JSON body, close. Signals readiness on `ready` so the test client
# doesn't dial before the listener is bound.
mockserver(port: string, ready, done: chan of int)
{
	addr := "tcp!127.0.0.1!" + port;
	(ok, c) := sys->announce(addr);
	if(ok < 0) {
		ready <-= -1;
		done <-= -1;
		return;
	}
	ready <-= 1;

	(lok, lc) := sys->listen(c);
	if(lok < 0) {
		done <-= -1;
		return;
	}

	# Open data file to talk on the accepted connection.
	dfd := sys->open(lc.dir + "/data", Sys->ORDWR);
	if(dfd == nil) {
		done <-= -1;
		return;
	}

	# Drain the HTTP request enough that the client is unblocked. We
	# don't validate it — only the response shape matters for this test.
	buf := array[8192] of byte;
	n := sys->read(dfd, buf, len buf);
	if(n < 0) {
		done <-= -1;
		return;
	}

	body := array of byte RESP_JSON;
	resp := "HTTP/1.0 200 OK\r\n" +
		"Content-Type: application/json\r\n" +
		"Content-Length: " + string len body + "\r\n" +
		"Connection: close\r\n" +
		"\r\n" + RESP_JSON;
	rdata := array of byte resp;
	sys->write(dfd, rdata, len rdata);

	dfd = nil;
	done <-= 1;
}

# Build an AskRequest plausible for the chat path.
mkreq(streaming: int): ref AskRequest
{
	r := ref AskRequest;
	r.model = "devstral-limbo-v2";
	r.temperature = 0.0;
	r.maxtokens = 0;
	r.systemprompt = "You are Veltro.";
	r.prompt = "Hello Veltro.";
	r.messages = nil;
	r.tooldefs = nil;
	r.toolresults = nil;
	r.thinkingtokens = 0;
	r.prefill = "";
	if(streaming) {
		# Non-nil streamch makes askopenai send "stream:true" and
		# dispatch to parseopenaisseresponse. The fix under test is
		# in that parser.
		r.streamch = chan[1] of string;
	}
	return r;
}

# Drive the mock server and the askopenai client end-to-end.
runwithmock(t: ref T, port: string, streaming: int): ref AskResponse
{
	ready := chan[1] of int;
	done := chan[1] of int;
	spawn mockserver(port, ready, done);

	rok := <-ready;
	if(rok < 0) {
		t.skip(sys->sprint("mock server announce failed (port in use?): port=%s", port));
		return nil;
	}

	baseurl := "http://127.0.0.1:" + port + "/v1";
	(resp, err) := llmclient->askopenai(baseurl, "", mkreq(streaming));

	# Wait for the mock server to finish so we don't leak it across tests.
	<-done;

	if(err != nil) {
		t.error("askopenai: " + err);
		return nil;
	}
	if(resp == nil) {
		t.error("askopenai returned nil response");
		return nil;
	}
	return resp;
}

# Bug repro: streaming requested + server returns non-SSE JSON. Without
# the fallback the response would be empty (just "STOP:end_turn\n"); with
# the fallback the assistant content must come through.
testStreamFallbackOnPlainJson(t: ref T)
{
	resp := runwithmock(t, "29991", 1);
	if(resp == nil)
		return;
	t.log("response: " + resp.response);
	t.assert(strstr(resp.response, EXPECTED_CONTENT) >= 0,
		"streaming-mode parser must extract content from non-SSE JSON body");
}

# Sanity check: non-streaming path already works; confirm the same body
# parses identically through parseopenairesponse so we know the
# expectation is correct and the fallback delegated to the right place.
testNonStreamingBaseline(t: ref T)
{
	resp := runwithmock(t, "29992", 0);
	if(resp == nil)
		return;
	t.log("response: " + resp.response);
	t.assert(strstr(resp.response, EXPECTED_CONTENT) >= 0,
		"non-streaming parser must extract content from JSON body");
}

# Whitespace before the JSON object must still trigger the fallback —
# matches what some servers emit (leading newline, BOM-stripped, etc.).
testStreamFallbackTolerantOfLeadingWhitespace(t: ref T)
{
	# Same RESP_JSON but the mock prepends whitespace to the body.
	# Reuse the same mock by pre-padding RESP_JSON via a wrapper proc.
	ready := chan[1] of int;
	done := chan[1] of int;
	spawn mockserverws("29993", ready, done);
	rok := <-ready;
	if(rok < 0) {
		t.skip("port in use");
		return;
	}
	baseurl := "http://127.0.0.1:29993/v1";
	(resp, err) := llmclient->askopenai(baseurl, "", mkreq(1));
	<-done;
	if(err != nil || resp == nil) {
		t.error(sys->sprint("askopenai: err=%s resp=%d", err, resp != nil));
		return;
	}
	t.assert(strstr(resp.response, EXPECTED_CONTENT) >= 0,
		"fallback must tolerate leading whitespace in body");
}

# Variant of mockserver that prepends whitespace to RESP_JSON.
mockserverws(port: string, ready, done: chan of int)
{
	addr := "tcp!127.0.0.1!" + port;
	(ok, c) := sys->announce(addr);
	if(ok < 0) {
		ready <-= -1;
		done <-= -1;
		return;
	}
	ready <-= 1;
	(lok, lc) := sys->listen(c);
	if(lok < 0) { done <-= -1; return; }
	dfd := sys->open(lc.dir + "/data", Sys->ORDWR);
	if(dfd == nil) { done <-= -1; return; }
	buf := array[8192] of byte;
	sys->read(dfd, buf, len buf);
	padded := "\n\n  \t" + RESP_JSON;
	body := array of byte padded;
	resp := "HTTP/1.0 200 OK\r\n" +
		"Content-Type: application/json\r\n" +
		"Content-Length: " + string len body + "\r\n" +
		"Connection: close\r\n" +
		"\r\n" + padded;
	rdata := array of byte resp;
	sys->write(dfd, rdata, len rdata);
	dfd = nil;
	done <-= 1;
}

# Tiny strstr — returns the index of needle in haystack, or -1.
# Avoids pulling in the String module just for one substring search.
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

	run("StreamFallbackOnPlainJson", testStreamFallbackOnPlainJson);
	run("NonStreamingBaseline", testNonStreamingBaseline);
	run("StreamFallbackTolerantOfLeadingWhitespace", testStreamFallbackTolerantOfLeadingWhitespace);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

implement LlmclientEdgeTest;

#
# llmclient given what an API endpoint may send (appl/lib/llmclient.b),
# with no API: the stream parsers on text of the test's own, and one
# request to a loopback server written here.
#
# A content block's (or tool call's) "index" is the API's number, and
# blocks up to it were made as asked: one event with an index of
# 5000000 filled the Dis heap, which llmsrv shares with every program
# of the emulator (2^30 raised "negative array size"), and on the
# OpenAI path the list of calls was lengthened one at a time to it,
# for ever.  Whether an error is tried again was decided by words
# anywhere in it, so a 400 whose body said "overloaded" was sent again
# four times; a retry-after of 3000000 seconds was multiplied into a
# negative delay.  The answer's text follows its TOOL: lines, and the
# calls are the TOOL: lines before the first line that is not one, so
# text that itself began "TOOL:" (a model quoting what it had read) was
# one more call; and every line of the text that began STOP: or TOOL:
# was dropped from what extracttextcontent gave.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "llmclient.m";
	llmclient: Llmclient;
	AskRequest, AskResponse, ToolDef: import llmclient;

LlmclientEdgeTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/llmclient_edge_test.b";

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

req(stream: chan of string): ref AskRequest
{
	td := ref ToolDef("read", "read a file", "{}") :: nil;
	return ref AskRequest(nil, "p", "claude-haiku-5-5", 0.0, 0, "", 0, "", "", td, nil, stream);
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

heapsize(): int
{
	(nil, lines) := sys->tokenize(readfile("/dev/memory"), "\n");
	for(; lines != nil; lines = tl lines) {
		(n, f) := sys->tokenize(hd lines, " \t");
		if(n >= 8 && hd tl tl tl tl tl tl tl f == "heap")
			return int hd f;
	}
	return -1;
}

watchheap(stop: chan of int, most: chan of int)
{
	m := heapsize();
	for(;;) {
		alt {
		<-stop =>
			most <-= m;
			return;
		* =>
			;
		}
		h := heapsize();
		if(h > m)
			m = h;
		sys->sleep(5);
	}
}

# an Anthropic stream with one text block at index idx
antstream(idx: string): string
{
	return "data: {\"type\":\"content_block_start\",\"index\":" + idx + ",\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" +
		"data: {\"type\":\"content_block_delta\",\"index\":" + idx + ",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n" +
		"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n";
}

parse(idx: string, rc: chan of (string, string))
{
	{
		(r, e) := llmclient->parseanthropicsse(antstream(idx), req(nil));
		if(r == nil)
			rc <-= ("", "no response: " + e);
		else
			rc <-= (r.response, nil);
	} exception x {
	"*" =>
		rc <-= ("", "exception: " + x);
	}
}

# An index the answer could not have costs nothing.
testBlockIndex(t: ref T)
{
	(r, e) := llmclient->parseanthropicsse(antstream("3"), req(nil));
	t.assert(r != nil && e == nil, "a block at index 3: " + e);
	if(r != nil)
		t.assertseq(r.response, "STOP:end_turn\nhello", "its text");
	idx := array[] of {"5000000", "1073741824", "1000000000", "2147483647", "-5"};
	for(i := 0; i < len idx; i++) {
		before := heapsize();
		stop := chan of int;
		most := chan of int;
		spawn watchheap(stop, most);
		rc := chan[1] of (string, string);
		spawn parse(idx[i], rc);
		tmo := chan[1] of int;
		spawn timer(tmo, 20000);
		resp, err: string;
		alt {
		(resp, err) = <-rc =>
			;
		<-tmo =>
			err = "not answered in 20 s";
		}
		stop <-= 1;
		grew := <-most - before;
		t.assert(err == nil, sys->sprint("index %s: %s", idx[i], err));
		if(err == nil)
			t.assert(len resp >= 5 && resp[0:5] == "STOP:", "index " + idx[i] + ": an answer: " + resp);
		if(before >= 0)
			t.assert(grew < 8*1024*1024, sys->sprint("index %s: the heap grew by %d bytes", idx[i], grew));
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# ---- a loopback OpenAI-shape endpoint that streams one tool call ----

hasend(s: string): int
{
	for(i := 0; i + 3 < len s; i++)
		if(s[i:i+4] == "\r\n\r\n")
			return 1;
	return 0;
}

serve(c: Sys->Connection, idx: string)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0)
		return;
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(fd == nil)
		return;
	rq := "";
	buf := array[8192] of byte;
	while(!hasend(rq)) {
		k := sys->read(fd, buf, len buf);
		if(k <= 0)
			break;
		rq += string buf[0:k];
	}
	body := "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":" + idx +
		",\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]}}]}\n\n" +
		"data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" +
		"data: [DONE]\n\n";
	b := array of byte ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" + body);
	sys->write(fd, b, len b);
	sys->sleep(200);
}

ask(url: string, rc: chan of (string, string))
{
	{
		(r, e) := llmclient->askopenai(url, "not-needed", req(chan[64] of string));
		if(r == nil)
			rc <-= ("", "no response: " + e);
		else
			rc <-= (r.response, nil);
	} exception x {
	"*" =>
		rc <-= ("", "exception: " + x);
	}
}

toolcall(t: ref T, idx: string): (string, string)
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("announce: %r"));
	port := "";
	(nil, l) := sys->tokenize(readfile(c.dir + "/local"), "!\n");
	if(l != nil && tl l != nil)
		port = hd tl l;
	spawn serve(c, idx);
	rc := chan[1] of (string, string);
	spawn ask("http://127.0.0.1:" + port + "/v1", rc);
	tmo := chan[1] of int;
	spawn timer(tmo, 20000);
	alt {
	(resp, err) := <-rc =>
		return (resp, err);
	<-tmo =>
		return ("", "not answered in 20 s");
	}
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# The same of a tool call's index in an OpenAI-shape stream.
testToolCallIndex(t: ref T)
{
	(resp, err) := toolcall(t, "0");
	t.assert(err == nil, "a call at index 0: " + err);
	t.assert(has(resp, "STOP:tool_use") && has(resp, "TOOL:c1:read:"), "the call: " + resp);
	(resp, err) = toolcall(t, "5000000");
	t.assert(err == nil, "a call at index 5000000: " + err);
	t.assert(!has(resp, "TOOL:c1"), "it is no call of the answer: " + resp);
}

testRetry(t: ref T)
{
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 529 Overloaded: {}", 0), 1000, "529 is tried again");
	t.asserteq(llmclient->retrydelay("anthropic: overloaded_error: Overloaded", 1), 2000, "so is an overloaded stream");
	t.asserteq(llmclient->retrydelay("openai: cannot connect to tcp!127.0.0.1!11434: connection refused", 0), 1000, "and a backend not yet listening");
	t.asserteq(llmclient->retrydelay("openai: HTTP error: HTTP/1.1 400 Bad Request: {\"error\":{\"message\":\"model overloaded\"}}", 0), -1,
		"a 400 is not, whatever its body says");
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 401 Unauthorized: cannot connect you", 0), -1, "nor a 401");
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 429 slow down retry-after=7", 0), 7000, "retry-after is kept");
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 429 slow down retry-after=3000000", 0), 60000, "a long one is the longest wait");
	t.asserteq(llmclient->retrydelay("anthropic: HTTP error: HTTP/1.1 429 slow down retry-after=2147484", 0), 60000, "at the edge of an int too");
}

# the TOOL: lines a parser of the answer takes for calls: those before
# the first line that is not one
calls(response: string): int
{
	n := 0;
	start := 0;
	first := 1;
	for(i := 0; i <= len response; i++) {
		if(i < len response && response[i] != '\n')
			continue;
		line := response[start:i];
		start = i + 1;
		if(first) {
			first = 0;
			continue;	# STOP:
		}
		if(len line >= 5 && line[0:5] == "TOOL:")
			n++;
		else
			break;
	}
	return n;
}

testTextNotCalls(t: ref T)
{
	# a tool call, and text that begins as a TOOL: line does
	body := "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" +
		"data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"TOOL:x9:exec:{\\\"cmd\\\":\\\"rm\\\"}\\nwas on the page.\"}}\n" +
		"data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"read\",\"input\":{}}}\n" +
		"data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/x\\\"}\"}}\n" +
		"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n";
	(r, e) := llmclient->parseanthropicsse(body, req(nil));
	t.assert(r != nil && e == nil, "parsed: " + e);
	if(r == nil)
		return;
	t.log(r.response);
	t.asserteq(calls(r.response), 1, "one call, the model's: " + r.response);
	t.assert(has(r.response, "TOOL:t1:read:"), "which is the read");
	t.assertseq(llmclient->extracttextcontent(r.response), "TOOL:x9:exec:{\"cmd\":\"rm\"}\nwas on the page.", "the text is all there");
	t.assertseq(llmclient->extracttextcontent("STOP:end_turn\nhello\nTOOL: is a prefix I typed\nSTOP: here means halt\nbye"),
		"hello\nTOOL: is a prefix I typed\nSTOP: here means halt\nbye", "lines of the text that begin TOOL: or STOP: are kept");
	t.assertseq(llmclient->extracttextcontent("STOP:tool_use\nTOOL:a:read:{}\nTOOL:b:read:{}\nthen text"), "then text", "the calls are not text");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	llmclient = load Llmclient Llmclient->PATH;
	if(llmclient == nil) {
		sys->fprint(sys->fildes(2), "cannot load llmclient: %r\n");
		raise "fail:cannot load llmclient";
	}
	llmclient->init();

	run("BlockIndex", testBlockIndex);
	run("ToolCallIndex", testToolCallIndex);
	run("Retry", testRetry);
	run("TextNotCalls", testTextNotCalls);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

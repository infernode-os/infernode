implement TexttoolsTest;

#
# llmclient_texttools_test.b - Text-embedded tool-call recovery.
#
# Some OpenAI-shaped local models emit a tool call as ordinary message
# content instead of the structured tool_calls field. extracttexttoolcalls
# must recognise a lone JSON object with name plus arguments/parameters,
# and must not treat surrounding prose or unrelated JSON as a tool call.
#
# To run: emu -r. /tests/llmclient_texttools_test.dis [-v]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;

include "json.m";
	json: JSON;
	JValue: import json;

include "testing.m";
	testing: Testing;
	T: import testing;

include "llmclient.m";
	llmclient: Llmclient;
	ToolDef: import Llmclient;

TexttoolsTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/llmclient_texttools_test.b";

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

saytools(): list of ref ToolDef
{
	td := ref ToolDef("say", "Speak text",
		"{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}");
	return td :: nil;
}

# Read the "text" field out of a tool-args JSON object.
argtext(args: string): string
{
	bio := bufio->aopen(array of byte args);
	if(bio == nil)
		return "";
	(jv, err) := json->readjson(bio);
	if(jv == nil || err != "")
		return "";
	tv := jv.get("text");
	if(tv == nil)
		return "";
	pick t := tv {
	String =>
		return t.s;
	}
	return "";
}

ncalls(calls: list of (string, string, string)): int
{
	n := 0;
	for(; calls != nil; calls = tl calls)
		n++;
	return n;
}

# Observed payload: bare object, "parameters" spelling, no wrapper tags.
testBareParameters(t: ref T)
{
	content := "{\"name\": \"say\", \"parameters\": {\"text\": \"local llm working\"}}";
	(remaining, calls) := llmclient->extracttexttoolcalls(content, saytools());
	t.asserteq(ncalls(calls), 1, "bare parameters: one tool call");
	if(calls == nil)
		return;
	(nil, name, args) := hd calls;
	t.assertseq(name, "say", "bare parameters: name");
	t.assertseq(argtext(args), "local llm working", "bare parameters: text arg");
	t.assertseq(remaining, "", "bare parameters: no leftover text");
}

# Same shape with the OpenAI "arguments" spelling.
testBareArguments(t: ref T)
{
	content := "{\"name\": \"say\", \"arguments\": {\"text\": \"local llm working\"}}";
	(remaining, calls) := llmclient->extracttexttoolcalls(content, saytools());
	t.asserteq(ncalls(calls), 1, "bare arguments: one tool call");
	if(calls == nil)
		return;
	(nil, name, args) := hd calls;
	t.assertseq(name, "say", "bare arguments: name");
	t.assertseq(argtext(args), "local llm working", "bare arguments: text arg");
	t.assertseq(remaining, "", "bare arguments: no leftover text");
}

# Leading/trailing whitespace around a lone object is still a tool call.
testBareWhitespace(t: ref T)
{
	content := "\n  {\"name\": \"say\", \"parameters\": {\"text\": \"local llm working\"}}  \n";
	(remaining, calls) := llmclient->extracttexttoolcalls(content, saytools());
	t.asserteq(ncalls(calls), 1, "whitespace: one tool call");
	if(calls == nil)
		return;
	(nil, name, args) := hd calls;
	t.assertseq(name, "say", "whitespace: name");
	t.assertseq(argtext(args), "local llm working", "whitespace: text arg");
	t.assertseq(remaining, "", "whitespace: leftover stripped");
}

# Surrounding prose must not become a silent tool invocation.
testBareProseNotACall(t: ref T)
{
	content := "Here you go: {\"name\": \"say\", \"parameters\": {\"text\": \"local llm working\"}}";
	(remaining, calls) := llmclient->extracttexttoolcalls(content, saytools());
	t.asserteq(ncalls(calls), 0, "prose: not a tool call");
	t.assertseq(remaining, content, "prose: original text preserved");
}

# A lone JSON object that is not a tool-call shape must stay as text.
testBareUnrelatedJson(t: ref T)
{
	content := "{\"reply\": \"hello\", \"ok\": true}";
	(remaining, calls) := llmclient->extracttexttoolcalls(content, saytools());
	t.asserteq(ncalls(calls), 0, "unrelated JSON: not a tool call");
	t.assertseq(remaining, content, "unrelated JSON: original text preserved");
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

	run("BareParameters", testBareParameters);
	run("BareArguments", testBareArguments);
	run("BareWhitespace", testBareWhitespace);
	run("BareProseNotACall", testBareProseNotACall);
	run("BareUnrelatedJson", testBareUnrelatedJson);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

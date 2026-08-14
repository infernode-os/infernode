implement SmsToolTest;

# sms_tool_test - Agent-facing SMS tool validation.

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Tool: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
};

SmsToolTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/sms_tool_test.b";

tool: Tool;
passed := 0;
failed := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else
		failed++;
}

testRejectsUnsafeNumber(t: ref T)
{
	r := tool->exec("+15551234\nsend +1999 owned hello");
	t.assert(hassubstr(r, "sms: unsafe number"),
		"rejects newline in recipient before /phone/sms write");

	r = tool->exec("alice hello");
	t.assert(hassubstr(r, "sms: unsafe number"),
		"rejects non-phone recipient token before /phone/sms write");

	r = tool->exec("+1-555-1234 hello");
	t.assert(hassubstr(r, "/phone/sms") || hassubstr(r, "queued"),
		"accepts a syntactically safe number");
}

hassubstr(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	tool = load Tool "/dis/veltro/tools/sms.dis";
	if(tool == nil)
		raise "fail:cannot load sms tool";
	err := tool->init();
	if(err != nil)
		raise "fail:sms init: " + err;

	run("RejectsUnsafeNumber", testRejectsUnsafeNumber);

	if(testing->summary(passed, failed, 0) > 0)
		raise "fail:tests failed";
}

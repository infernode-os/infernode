implement VeltroCharonSecurityTest;

include "sys.m";
	sys: Sys;
include "draw.m";

Tool: module {
	init: fn(): string;
	exec: fn(args: string): string;
};

VeltroCharonSecurityTest: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i + len sub] == sub)
			return 1;
	return 0;
}

check(tool: Tool, command, want: string)
{
	got := tool->exec(command);
	if(!contains(got, want)) {
		sys->fprint(sys->fildes(2), "FAIL %q: got %q, want substring %q\n",
			command, got, want);
		raise "fail:test";
	}
	sys->print("PASS %s\n", command);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	tool := load Tool "/dis/veltro/tools/charon.dis";
	if(tool == nil)
		raise "fail:cannot load charon";
	err := tool->init();
	if(err != nil)
		raise "fail:charon init: " + err;

	check(tool, "follow", "usage: follow");
	check(tool, "follow 3 back", "invalid link number");
	check(tool, "follow 3\nnavigate https://example.com", "invalid link number");
	check(tool, "follow ../3", "invalid link number");
	check(tool, "follow 3=4", "invalid link number");
	check(tool, "follow 1234567890", "invalid link number");
	check(tool, "follow 3", "cannot create /tmp/veltro/browser/ctl");
	check(tool, "navigate file:/lib/veltro/system.txt", "only http:// and https://");
	check(tool, "navigate https://example.com\nfollow 1", "only http:// and https://");
}

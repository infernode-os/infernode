implement VeltroPresentSecurityTest;

include "sys.m";
	sys: Sys;
include "draw.m";

Tool: module {
	init: fn(): string;
	exec: fn(args: string): string;
};

VeltroPresentSecurityTest: module {
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
	tool := load Tool "/dis/veltro/tools/present.dis";
	if(tool == nil)
		raise "fail:cannot load present";
	err := tool->init();
	if(err != nil)
		raise "fail:present init: " + err;

	check(tool, "navigate charon file:/lib/veltro/system.txt", "only accepts http:// and https://");
	check(tool, "navigate charon FILE:///env/secret", "only accepts http:// and https://");
	check(tool, "navigate charon http://example.com data=-c owned", "only accepts http:// and https://");
	check(tool, "navigate charon https://example.com\n" + "dis=/dis/wm/shell.dis", "only accepts http:// and https://");
	check(tool, "navigate editor https://example.com", "only supported for charon");
	check(tool, "create sneaky type=app label=Shell", "unsupported artifact type");
	check(tool, "create sneaky2 app Shell", "unsupported artifact type");
	# A permitted URL gets past policy validation and reaches the absent test UI.
	check(tool, "navigate charon HTTPS://example.com", "no active activity");
}

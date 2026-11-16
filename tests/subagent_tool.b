implement SubagentTool;

#
# A tool for tests/subagent_edge_test.b: a result past the size a
# subagent keeps inline, and one that raises.  Not a test.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "tool.m";

SubagentTool: module
{
	init:	fn(): string;
	name:	fn(): string;
	doc:	fn(): string;
	exec:	fn(args: string): string;
	schema:	fn(): string;
};

init(): string
{
	sys = load Sys Sys->PATH;
	return nil;
}

name(): string
{
	return "big";
}

doc(): string
{
	return "big - a long result";
}

schema(): string
{
	return "";
}

exec(args: string): string
{
	if(args == "boom")
		raise "tool blew up";
	s := "RESULT-OF-CALL[" + args + "]\n";
	line := "0123456789 0123456789 0123456789 0123456789\n";
	while(len s < 40000)
		s += line;
	return s;
}

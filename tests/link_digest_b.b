implement LinkDigestB;

#
# A module that loads tests/link_digest_a.dis itself, for
# tests/link_digest_test.b: the test takes this module's type digests
# away and has it import from a module that has them.
#

include "sys.m";
	sys: Sys;

LinkDigestB: module
{
	init:	fn();
	try:	fn(path: string): string;
};

A: module
{
	plain:	fn(x: int): int;
};

init()
{
	sys = load Sys Sys->PATH;
}

# nil if path loads as an A and works, or why not
try(path: string): string
{
	a := load A path;
	if(a == nil)
		return sys->sprint("%r");
	if(a->plain(41) != 42)
		return "plain(41) is not 42";
	return nil;
}

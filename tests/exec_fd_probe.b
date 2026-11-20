implement ExecFdProbe;

#
# Run by tests/host/exec_fd_test.sh through the agent's exec tool.
#
# With no argument: one line for each file descriptor this process has,
# "fd N: path" (fildes gives a copy under another number, so they are
# asked for from the highest down and each copy dropped at once).
# spam: lines for ever.
#

include "sys.m";
	sys: Sys;
include "draw.m";

ExecFdProbe: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	if(tl argv != nil && hd tl argv == "spam")
		for(n := 0; ; n++)
			sys->print("line %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", n);
	out := "";
	for(i := 63; i >= 0; i--) {
		fd := sys->fildes(i);
		if(fd == nil)
			continue;
		p := sys->fd2path(fd);
		fd = nil;
		out = sys->sprint("fd %d: %s\n", i, p) + out;
	}
	sys->print("%sFDS-END\n", out);
}

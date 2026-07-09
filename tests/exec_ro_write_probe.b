implement ExecRoWriteProbe;

include "sys.m";
	sys: Sys;

include "draw.m";

ExecRoWriteProbe: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	args = tl args;
	if(args == nil) {
		sys->print("ERROR: missing target\n");
		return;
	}
	target := hd args;
	fd := sys->create(target, Sys->OWRITE, 8r644);
	if(fd == nil) {
		sys->print("DENIED %s: %r\n", target);
		return;
	}
	sys->fprint(fd, "changed\n");
	fd = nil;
	sys->print("WROTE %s\n", target);
}

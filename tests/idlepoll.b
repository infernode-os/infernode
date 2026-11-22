implement Idlepoll;

#
# idlepoll ms dir: every ms milliseconds, list dir and drop the listing,
# for ever. A program that wakes to look and allocates a little each
# time, as lib/layers' watcher does (500 ms, a directory listed): the
# idle collector must still rest between rounds with one of these
# running. tests/host/idle_poll_cpu_test.sh runs it beside a loaded page.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Idlepoll: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	args = tl args;
	if(len args != 2){
		sys->fprint(sys->fildes(2), "usage: idlepoll ms dir\n");
		raise "fail:usage";
	}
	ms := int hd args;
	dir := hd tl args;
	for(;;){
		sys->sleep(ms);
		fd := sys->open(dir, Sys->OREAD);
		if(fd == nil)
			continue;
		for(;;){
			(n, nil) := sys->dirread(fd);
			if(n <= 0)
				break;
		}
	}
}

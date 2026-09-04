implement TaskConcurrentProbe;

include "sys.m";
	sys: Sys;
include "draw.m";

TaskConcurrentProbe: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	if(args == nil || tl args == nil) {
		sys->print("error: label required\n");
		return;
	}
	label := hd tl args;
	fd := sys->open("/tool/task/ctl", Sys->ORDWR);
	if(fd == nil) {
		sys->print("RESULT %s error: cannot open task tool\n", label);
		return;
	}
	cmd := array of byte ("create label=" + label + " tools=read");
	if(sys->write(fd, cmd, len cmd) != len cmd) {
		sys->print("RESULT %s error: write failed: %r\n", label);
		return;
	}
	sys->seek(fd, big 0, Sys->SEEKSTART);
	result := "";
	buf := array[1024] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		result += string buf[0:n];
	}
	sys->print("RESULT %s %s\n", label, result);
}

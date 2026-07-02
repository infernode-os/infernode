implement ExecConfinementProbe;

include "sys.m";
	sys: Sys;
include "draw.m";

ExecConfinementProbe: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(0, nil);

	fd := sys->open("#p/1/status", Sys->OREAD);
	if(fd != nil) {
		sys->print("FAIL: direct process-device attachment succeeded\n");
		return;
	}

	fd = sys->open("/prog", Sys->OREAD);
	if(fd == nil) {
		sys->print("FAIL: restricted /prog is unavailable\n");
		return;
	}
	seen := 0;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		seen += len dirs;
	}
	if(seen != 0) {
		sys->print("FAIL: restricted /prog entry count %d\n", seen);
		return;
	}
	sys->print("PASS: exec process and device capabilities are confined\n");
}

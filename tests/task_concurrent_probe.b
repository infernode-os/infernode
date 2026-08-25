implement TaskConcurrentProbe;

include "sys.m";
	sys: Sys;
include "draw.m";

TaskConcurrentProbe: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

worker(start: chan of int, done: chan of (string, string), label: string)
{
	fd := sys->open("/tool/task/ctl", Sys->ORDWR);
	if(fd == nil) {
		done <-= (label, "error: cannot open task tool");
		return;
	}
	<-start;
	cmd := array of byte ("create label=" + label + " tools=read");
	if(sys->write(fd, cmd, len cmd) != len cmd) {
		done <-= (label, sys->sprint("error: write failed: %r"));
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
	done <-= (label, result);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	start := chan of int;
	done := chan of (string, string);
	labels := array[] of {"ConcurrentA", "ConcurrentB", "ConcurrentC"};
	for(i := 0; i < len labels; i++)
		spawn worker(start, done, labels[i]);
	for(i = 0; i < len labels; i++)
		start <-= 1;
	for(i = 0; i < len labels; i++) {
		(label, result) := <-done;
		sys->print("RESULT %s %s\n", label, result);
	}
}

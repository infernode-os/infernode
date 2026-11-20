implement Toolcall;

#
# toolcall - load one Veltro tool module and call it, for host tests
#
#	toolcall [-m n] /dis/veltro/tools/x.dis 'arguments' ...
#
# Each call's result is printed between two lines of its own:
#
#	R_CALL n ms procs
#	(the result)
#	R_RET n
#
# ms is how long exec took and procs the number of entries in /prog
# after it, so a test can see a call that returned leaving processes
# behind.  With -m, a result longer than n characters is printed as its
# first and last n/2, with its length between.  The tool is called directly, with no tools9p worker and no
# restricted name space: what is tested is the tool.
#

include "sys.m";
	sys: Sys;

include "draw.m";

Tool: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
};

Toolcall: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	if(len args < 2) {
		sys->fprint(sys->fildes(2), "usage: toolcall tool.dis args ...\n");
		raise "fail:usage";
	}
	args = tl args;
	max := 0;
	if(hd args == "-m" && len args >= 3) {
		max = int hd tl args;
		args = tl tl args;
	}
	path := hd args;
	t := load Tool path;
	if(t == nil) {
		sys->fprint(sys->fildes(2), "toolcall: cannot load %s: %r\n", path);
		raise "fail:load";
	}
	if((e := t->init()) != nil) {
		sys->fprint(sys->fildes(2), "toolcall: %s: init: %s\n", path, e);
		raise "fail:init";
	}
	n := 0;
	for(args = tl args; args != nil; args = tl args) {
		n++;
		t0 := sys->millisec();
		r := t->exec(hd args);
		ms := sys->millisec() - t0;
		if(max > 0 && len r > max)
			r = r[0:max/2] + sys->sprint("\n...[%d characters]...\n", len r) + r[len r - max/2:];
		sys->print("R_CALL %d %d %d\n%s\nR_RET %d\n", n, ms, nprocs(), r, n);
	}
}

nprocs(): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	t := 0;
	for(;;) {
		(n, nil) := sys->dirread(fd);
		if(n <= 0)
			break;
		t += n;
	}
	return t;
}

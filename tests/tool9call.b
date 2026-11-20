implement Tool9call;

#
# tool9call [-m root] tool [arg ...]
#
# Makes one call of a tool served by tools9p, as an agent's harness does:
# the arguments, joined by blanks, are written to root/tool/ctl (root is
# /tool by default) and the result is read back on the same file
# descriptor and printed.  Host tests use it where calls are made at once,
# each needing its own answer.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Tool9call: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	argv = tl argv;
	root := "/tool";
	if(argv != nil && hd argv == "-m" && tl argv != nil) {
		root = hd tl argv;
		argv = tl tl argv;
	}
	if(argv == nil) {
		sys->fprint(sys->fildes(2), "usage: tool9call [-m root] tool [arg ...]\n");
		raise "fail:usage";
	}
	tool := hd argv;
	args := "";
	for(argv = tl argv; argv != nil; argv = tl argv) {
		if(args != "")
			args += " ";
		args += hd argv;
	}
	fd := sys->open(root + "/" + tool + "/ctl", Sys->ORDWR);
	if(fd == nil) {
		sys->print("tool9call: cannot open %s/%s/ctl: %r\n", root, tool);
		raise "fail:open";
	}
	b := array of byte args;
	if(sys->write(fd, b, len b) != len b)
		sys->print("tool9call: write: %r\n");
	sys->seek(fd, big 0, Sys->SEEKSTART);
	out := "";
	buf := array[65536] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		out += string buf[0:n];
	sys->print("%s\n", out);
}

implement Loadtest;

#
# loadtest - what it costs to load a freshly generated module: a
# compiled JavaScript function arrives as one, and the JIT translates
# it when it is loaded.  Loads N distinct copies of tiny.dis (copied
# to dir/tNNNN.dis beforehand, so none is the cached one) and calls
# each once.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Loadtest: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Tiny: module
{
	f:	fn(a, b: real): real;
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	argv = tl argv;
	dir := hd argv;
	n := int hd tl argv;
	t := sys->millisec();
	s := 0.0;
	for(i := 0; i < n; i++) {
		m := load Tiny sys->sprint("%s/t%04d.dis", dir, i);
		if(m == nil) {
			sys->print("cannot load %d: %r\n", i);
			return;
		}
		s += m->f(real i, 2.0);
	}
	t = sys->millisec() - t;
	sys->print("%d modules loaded and called: %d ms, %.1f µs each (%g)\n", n, t, real t * 1000.0 / real n, s);
}

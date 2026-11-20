implement Jit4gb;

#
# Calls into a compiled module whose code is at a multiple of 4GB.
# Run by tests/host/jit_4gb_test.sh, which puts it there (the file named
# is made just before the module is loaded: the test's preloaded mmap
# moves the next piece of JIT memory asked for).
#
# The amd64 JIT's call into another module tested the low 32 bits of the
# callee's Modlink.prog to tell a built-in module (nil) from a compiled
# one.  With the callee's code at a multiple of 4GB it took the module
# for a built-in and called its code from C as a function, which never
# came back; a few thousand calls later the emulator was gone.
#
# usage: jit_4gb file
#

include "sys.m";
	sys: Sys;
include "draw.m";

Jit4gb: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Jit4gbMod: module
{
	f:	fn(x: int): int;
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	if(len args != 2){
		sys->print("SKIP usage: jit_4gb file\n");
		return;
	}
	if(sys->create(hd tl args, Sys->OWRITE, 8r666) == nil){
		sys->print("SKIP cannot create %s: %r\n", hd tl args);
		return;
	}
	h := load Jit4gbMod "/dis/tests/jit_4gb_mod.dis";
	if(h == nil){
		sys->print("SKIP cannot load the module: %r\n");
		return;
	}
	s := 0;
	for(i := 0; i < 100000; i++)
		s += h->f(i) - i;
	sys->print("SUM %d\n", s);
}

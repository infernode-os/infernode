implement JitSmall;

#
# jit_small_helper - a module of fewer than 128 Dis instructions, which
# tests/host/jit_byte_test.sh requires the JIT to compile. The amd64
# JIT's overflow test on its scratch size (compile(), comp-amd64.c) was
# made after the size had been raised to its floor, and refused every
# module this small: under -c1 they ran in the interpreter, silently.
#

include "sys.m";
	sys: Sys;

include "draw.m";

JitSmall: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	x := byte 7;
	y := byte 5;
	sys->print("small %d\n", int (x % y));
}

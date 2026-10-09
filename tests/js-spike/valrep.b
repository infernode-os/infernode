implement Valrep;

#
# valrep - what a value costs to copy, by how many pointers it holds.
# Dis counts references: copying a pointer field adjusts a count, nil
# or not.  A JavaScript value is copied at every assignment, argument
# and return, so this is the price of each.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Valrep: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Box: adt { n: int; };

V2: adt { t: int; n: real; a: ref Box; b: ref Box; };	# the spike's Val: two pointers
V1: adt { t: int; n: real; p: ref Box; };		# one pointer for every heap kind
V0: adt { t: int; n: real; };				# none: a number, or an index into a heap table

N: con 5000000;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	a2 := array[64] of V2;
	a1 := array[64] of V1;
	a0 := array[64] of V0;
	bx := ref Box(1);

	t := sys->millisec();
	for(i := 0; i < N; i++) {
		v := a2[i & 63];
		v.n += 1.0;
		a2[(i + 1) & 63] = v;
	}
	sys->print("2 pointers, nil\t%d ms\n", sys->millisec() - t);

	for(k := 0; k < 64; k++)
		a2[k].a = bx;
	t = sys->millisec();
	for(i = 0; i < N; i++) {
		v := a2[i & 63];
		v.n += 1.0;
		a2[(i + 1) & 63] = v;
	}
	sys->print("2 pointers, one set\t%d ms\n", sys->millisec() - t);

	for(k = 0; k < 64; k++)
		a1[k].p = bx;
	t = sys->millisec();
	for(i = 0; i < N; i++) {
		v := a1[i & 63];
		v.n += 1.0;
		a1[(i + 1) & 63] = v;
	}
	sys->print("1 pointer, set\t%d ms\n", sys->millisec() - t);

	t = sys->millisec();
	for(i = 0; i < N; i++) {
		v := a0[i & 63];
		v.n += 1.0;
		a0[(i + 1) & 63] = v;
	}
	sys->print("no pointers\t%d ms\n", sys->millisec() - t);

	# a number kept apart from the pointers: tag, number, pointer arrays
	tags := array[64] of int;
	nums := array[64] of real;
	t = sys->millisec();
	for(i = 0; i < N; i++) {
		j := i & 63;
		k2 := (i + 1) & 63;
		tags[k2] = tags[j];
		nums[k2] = nums[j] + 1.0;
	}
	sys->print("split arrays (no pointer touched)\t%d ms\n", sys->millisec() - t);
}

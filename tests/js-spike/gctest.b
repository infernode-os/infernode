implement Gctest;

#
# gctest - the pauses a page would see from Dis's collector.  JavaScript
# objects are cyclic (a function and its prototype point at each other;
# closures capture their makers), so reference counting cannot free
# them and Dis's mark-and-sweep does.  Builds rounds of a large heap of
# small objects in cycles, drops each, and keeps timing a steady loop:
# the longest gap between its iterations is the worst pause.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Gctest: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

O: adt {
	v:	real;
	next:	cyclic ref O;
	prev:	cyclic ref O;	# a cycle with next: reference counts never reach zero
	a:	array of byte;
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	n := 500000;
	if(tl argv != nil)
		n = int hd tl argv;
	worst := 0;
	t0 := sys->millisec();
	last := t0;
	for(round := 0; round < 6; round++) {
		head: ref O;
		for(i := 0; i < n; i++) {
			o := ref O(real i, head, nil, array[48] of byte);
			if(head != nil)
				head.prev = o;
			head = o;
			if((i & 1023) == 0) {
				now := sys->millisec();
				if(now - last > worst)
					worst = now - last;
				last = now;
			}
		}
		head = nil;	# a whole round's cycles, garbage
	}
	sys->print("%d rounds of %d cyclic objects (about %d MB each): %d ms; worst pause %d ms\n",
		6, n, n * 120 / 1000000, sys->millisec() - t0, worst);
}

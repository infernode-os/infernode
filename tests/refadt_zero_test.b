implement RefAdtZeroTest;

#
# `t := ref T;` -- an adt allocated with no initializer -- must come back
# with every scalar member zero and every reference member nil, under
# the interpreter (-c0) and the JIT (-c1) alike.
#
# It did not.  The compiler emitted the Dis `new` instruction for this
# form, and `new` (heap() in libinterp/heap.c) only rewrote the pointer
# slots to H; the scalars between them were whatever the pool's recycled
# block last held.  Which slots were garbage depended on the allocation
# history, so the interpreter and the JIT disagreed, and Charon's layout
# engine lost a grid column to a Box whose x/w were -1 (the H of a freed
# object's pointer slot).  The compiler now emits `newz` for this form
# and heap() zero-fills regardless, as newa() already did for arrays.
#
# The test poisons the heap first: it allocates and drops blocks of the
# same sizes, filled with non-zero values, so the allocation under test
# is handed recycled memory and a missing zero-fill shows up as the
# poison, not as the zero that fresh arena memory happens to hold.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

RefAdtZeroTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/refadt_zero_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Scalars interleaved with references, the shape of Charon's Box: the
# reference slots are the ones the VM's type map covers, the scalars
# between them are the ones it used to skip.
Box: adt {
	a, b, c: int;
	s: string;
	x, y, w, h: int;
	kids: cyclic array of ref Box;
	parent: cyclic ref Box;
	n: int;
	l: big;
	r: real;
	by: byte;
};

# No reference members at all: the type has an empty map, so before the
# fix nothing touched this memory after the allocator handed it over.
Scalars: adt {
	a, b, c, d: int;
	l: big;
	r: real;
	by: byte;
};

Poison: con 16r5A5A5A5A;
Rounds: con 32;
Churn: con 64;

# Fill the free lists with blocks of exactly the sizes under test, every
# byte of them non-zero, then drop them all on return.
churn()
{
	bl: list of ref Box;
	sl: list of ref Scalars;
	for(i := 0; i < Churn; i++) {
		bl = ref Box(Poison, Poison, Poison, "poison", Poison, Poison, Poison, Poison,
			nil, nil, Poison, big Poison, 1.0, byte 16rA5) :: bl;
		sl = ref Scalars(Poison, Poison, Poison, Poison, big Poison, 1.0, byte 16rA5) :: sl;
	}
}

# The forms under test, in their own functions so the allocation is a
# plain `ref T` with nothing else in the frame to hide behind.
mkbox(a: int): ref Box
{
	b := ref Box;
	b.a = a;
	return b;
}

mkscalars(): ref Scalars
{
	return ref Scalars;
}

checkbox(t: ref T, b: ref Box, round: int)
{
	where := sys->sprint(" (round %d)", round);
	t.asserteq(b.a, 1, "Box.a keeps its assigned value" + where);
	t.asserteq(b.b, 0, "Box.b is zero" + where);
	t.asserteq(b.c, 0, "Box.c is zero" + where);
	t.assertnil(b.s, "Box.s is nil" + where);
	t.asserteq(b.x, 0, "Box.x is zero" + where);
	t.asserteq(b.y, 0, "Box.y is zero" + where);
	t.asserteq(b.w, 0, "Box.w is zero" + where);
	t.asserteq(b.h, 0, "Box.h is zero" + where);
	t.assert(b.kids == nil, "Box.kids is nil" + where);
	t.assert(b.parent == nil, "Box.parent is nil" + where);
	t.asserteq(b.n, 0, "Box.n is zero" + where);
	t.assert(b.l == big 0, "Box.l (big) is zero" + where);
	t.assert(b.r == 0.0, "Box.r (real) is zero" + where);
	t.asserteq(int b.by, 0, "Box.by (byte) is zero" + where);
}

checkscalars(t: ref T, s: ref Scalars, round: int)
{
	where := sys->sprint(" (round %d)", round);
	t.asserteq(s.a, 0, "Scalars.a is zero" + where);
	t.asserteq(s.b, 0, "Scalars.b is zero" + where);
	t.asserteq(s.c, 0, "Scalars.c is zero" + where);
	t.asserteq(s.d, 0, "Scalars.d is zero" + where);
	t.assert(s.l == big 0, "Scalars.l (big) is zero" + where);
	t.assert(s.r == 0.0, "Scalars.r (real) is zero" + where);
	t.asserteq(int s.by, 0, "Scalars.by (byte) is zero" + where);
}

testBoxZeroed(t: ref T)
{
	for(round := 0; round < Rounds; round++) {
		churn();
		b := mkbox(1);
		checkbox(t, b, round);
		if(t.failed)
			t.fatal(sys->sprint("ref Box came back dirty: b=%d c=%d x=%d y=%d w=%d h=%d n=%d l=%bd r=%g by=%d",
				b.b, b.c, b.x, b.y, b.w, b.h, b.n, b.l, b.r, int b.by));
	}
}

testScalarsZeroed(t: ref T)
{
	for(round := 0; round < Rounds; round++) {
		churn();
		s := mkscalars();
		checkscalars(t, s, round);
		if(t.failed)
			t.fatal(sys->sprint("ref Scalars came back dirty: a=%d b=%d c=%d d=%d l=%bd r=%g by=%d",
				s.a, s.b, s.c, s.d, s.l, s.r, int s.by));
	}
}

# A reference held in a local that already points at a live value: the
# old value is released after the new one is allocated, so the fresh
# block cannot be the one just freed.  Still has to be zero.
testReassigned(t: ref T)
{
	churn();
	b := ref Box(Poison, Poison, Poison, "poison", Poison, Poison, Poison, Poison,
		nil, nil, Poison, big Poison, 1.0, byte 16rA5);
	b = ref Box;
	b.a = 1;
	checkbox(t, b, 0);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("BoxZeroed", testBoxZeroed);
	run("ScalarsZeroed", testScalarsZeroed);
	run("Reassigned", testReassigned);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

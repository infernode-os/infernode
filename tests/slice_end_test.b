implement SliceEndTest;

#
# Where the interpreter ends a Prog's time slice (libinterp/xec.c).
#
# Compiled code gives up the processor only after a backward branch, a
# call or a return, and the Limbo compiler's code is written for that:
# `a[i] = v` is two instructions, one that finds the element's address
# and one that stores through it, with nothing holding the array between
# them.  The interpreter ended a slice wherever its count of instructions
# ran out, between any two: another Prog, run between those two, could
# drop the array, and the store then went into whatever was allocated in
# its place.
#
# One Prog stores into an element of a global array for ever; this one
# replaces the array and allocates others of its size, which must stay as
# they were made.  Run under -c0 it is the test; under -c1 it pins what
# compiled code does.  tests/host/slice_end_test.sh runs both.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

SliceEndTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/slice_end_test.b";

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
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

PAT: con big 16r5a5a5a5a5a5a5a5a;
VAL: con big 16r4142434445464748;

ga: array of big;
gs: array of string;
stop := 0;

writer(done: chan of int)
{
	n := 0;
	{
		for(; !stop; n++)
			ga[1] = VAL;
	} exception {
	"*" =>
		;
	}
	done <-= n;
}

# the same with a pointer stored: the old value is let go, so a stale
# store frees something of another array's
swriter(done: chan of int)
{
	n := 0;
	s := "written";
	{
		for(; !stop; n++)
			gs[1] = s;
	} exception {
	"*" =>
		;
	}
	done <-= n;
}

testStoreAfterIndex(t: ref T)
{
	ROUNDS: con 4000;
	ga = array[2] of {* => big 0};
	stop = 0;
	done := chan of int;
	spawn writer(done);
	hits := 0;
	kb := array[64] of array of big;
	r := 0;
	for(; r < ROUNDS && hits == 0; r++){
		ga = array[2] of {* => big 0};
		for(i := 0; i < len kb; i++)
			kb[i] = array[2] of {* => PAT};
		for(i = 0; i < len kb; i++)
			if(kb[i][0] != PAT || kb[i][1] != PAT){
				t.log(sys->sprint("round %d: an array nobody wrote to holds %bux %bux", r, kb[i][0], kb[i][1]));
				hits++;
			}
	}
	stop = 1;
	n := <-done;
	t.log(sys->sprint("%d rounds beside %d stores", r, n));
	t.assert(n > 0, "the other Prog stored into the array's element meanwhile");
	t.asserteq(hits, 0, "no array allocated since holds what was stored into one replaced");
}

testPointerStoreAfterIndex(t: ref T)
{
	ROUNDS: con 4000;
	gs = array[2] of string;
	stop = 0;
	done := chan of int;
	spawn swriter(done);
	hits := 0;
	kb := array[64] of array of string;
	r := 0;
	for(; r < ROUNDS && hits == 0; r++){
		gs = array[2] of string;
		for(i := 0; i < len kb; i++)
			kb[i] = array[2] of {* => "kept"};
		for(i = 0; i < len kb; i++)
			if(kb[i][0] != "kept" || kb[i][1] != "kept"){
				t.log(sys->sprint("round %d: an array nobody wrote to holds %q %q", r, kb[i][0], kb[i][1]));
				hits++;
			}
	}
	stop = 1;
	n := <-done;
	t.log(sys->sprint("%d rounds beside %d stores", r, n));
	t.assert(n > 0, "the other Prog stored a string into the array's element meanwhile");
	t.asserteq(hits, 0, "no array allocated since holds it");
}

# a slice still ends: two Progs that only loop both run
spinner(c: chan of int, stopc: chan of int)
{
	n := 0;
	for(;;){
		alt {
		<-stopc =>
			c <-= n;
			return;
		* =>
			n++;
		}
	}
}

busy(done: chan of int)
{
	x := 0;
	for(i := 0; i < 3000000; i++)
		x += i & 7;
	done <-= x;
}

testSlicesStillEnd(t: ref T)
{
	c := chan of int;
	stopc := chan[1] of int;
	done := chan of int;
	spawn spinner(c, stopc);
	spawn busy(done);
	spawn busy(done);
	<-done;
	<-done;
	stopc <-= 1;
	n := <-c;
	t.assert(n > 100, sys->sprint("a Prog that loops ran beside two others that loop: %d turns", n));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("StoreAfterIndex", testStoreAfterIndex);
	run("PointerStoreAfterIndex", testPointerStoreAfterIndex);
	run("SlicesStillEnd", testSlicesStillEnd);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

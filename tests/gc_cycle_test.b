implement GcCycleTest;

#
# Garbage only the collector can free -- objects in a cycle, which no
# reference count ever brings to zero -- is freed, and soon.
#
# Every sh is such a cycle (it holds itself, load Sh "$self"), so this
# is what keeps a machine that starts shells from filling its heap. On
# the native kernel the collector's epochs stopped ending once the heap
# was large (wm/osk's lexicon): no cycle was freed, 27 objects a console
# shell, for as long as the board ran. tests/host/baremetal_test.sh runs
# this at the desktop's console, with the lexicon in the heap; the test
# runner runs it in emu.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

GcCycleTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/gc_cycle_test.b";
Ncycles: con 1000;
Waitms: con 60*1000;	# the native kernel starts a round of idle collection 10s after its last

passed := 0;
failed := 0;
skipped := 0;

C: adt {
	me:	ref C;
	n:	int;
};

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

# the heap's live objects: /dev/memory's heap line, allocations less frees
live(): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return -1;
	b := array[2048] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return -1;
	(nil, l) := sys->tokenize(string b[0:n], "\n");
	for(; l != nil; l = tl l){
		(nt, f) := sys->tokenize(hd l, " ");
		if(nt == 8){
			a := array[8] of string;
			for(i := 0; i < 8; i++){
				a[i] = hd f;
				f = tl f;
			}
			if(a[7] == "heap")
				return int a[3] - int a[4];
		}
	}
	return -1;
}

makecycles(n: int)
{
	for(i := 0; i < n; i++){
		c := ref C(nil, i);
		c.me = c;
	}
}

testCyclesFreed(t: ref T)
{
	before := live();
	if(before < 0)
		t.fatal(sys->sprint("cannot read the heap's line in /dev/memory: %r"));
	makecycles(Ncycles);
	made := live();
	t.log(sys->sprint("live objects %d before, %d with %d cycles dropped", before, made, Ncycles));
	if(made - before < Ncycles/2)
		t.skip(sys->sprint("the cycles were freed as they were made (%d -> %d)", before, made));

	# the rest of the system allocates and frees as well, so not exactly
	# before: within half the cycles of it
	for(waited := 0; waited < Waitms; waited += 500){
		now := live();
		if(now - before < Ncycles/2){
			t.log(sys->sprint("freed after %d ms: %d live", waited, now));
			return;
		}
		sys->sleep(500);
	}
	t.error(sys->sprint("%d cycles not freed in %d s: %d live, %d before",
		Ncycles, Waitms/1000, live(), before));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("CyclesFreed", testCyclesFreed);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

implement GcCycleTest;

#
# Garbage only the collector can free -- objects in a cycle, which no
# reference count ever brings to zero -- is freed, and soon.
#
# Every sh is such a cycle (it holds itself, load Sh "$self"), so this
# is what keeps a machine that starts shells from filling its heap. On
# the native kernel, with wm/osk's lexicon in the heap, the collector took
# 54 traversals an epoch: the Pi 4 freed a shell's 27 objects minutes
# after it ended and fell behind under load, and under QEMU no epoch ended
# at all. tests/host/baremetal_test.sh runs
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
# The native kernel starts a round of idle collection Idlegcgap (60 s,
# os/port/dis.c) after its last one ends, so a cycle dropped just after a
# round can wait that long, and the round's epochs on top: twice it.
Waitms: con 120*1000;

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

# This module's live objects, from /dev/heaptypes (cons(3)): its lines
# "count bytes obj owner" whose owner is a type this module declared.
# Counted by type, not as the heap's total, so what the rest of the
# system allocates meanwhile does not count: under QEMU a desktop still
# loading wm/osk's lexicon grew the heap by some 19000 objects during
# the wait, and the total never came back to where it was.
mine(): int
{
	fd := sys->open("/dev/heaptypes", Sys->OREAD);
	if(fd == nil)
		return -1;
	text := "";
	b := array[8192] of byte;
	n: int;
	while((n = sys->read(fd, b, len b)) > 0)
		text += string b[0:n];
	if(n < 0)
		return -1;
	count := 0;
	(nil, l) := sys->tokenize(text, "\n");
	for(; l != nil; l = tl l){
		(nt, f) := sys->tokenize(hd l, " ");
		if(nt < 6)
			continue;
		a := array[6] of string;
		for(i := 0; i < 6; i++){
			a[i] = hd f;
			f = tl f;
		}
		# count bytes obj PATH type N size S
		if(a[2] == "obj" && a[4] == "type" && suffix(a[3], "/gc_cycle_test.dis"))
			count += int a[0];
	}
	return count;
}

suffix(s, suf: string): int
{
	return len s >= len suf && s[len s - len suf:] == suf;
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
	before := mine();
	if(before < 0)
		t.fatal(sys->sprint("cannot read /dev/heaptypes: %r"));
	makecycles(Ncycles);
	made := mine();
	t.log(sys->sprint("this module's objects %d before, %d with %d cycles dropped", before, made, Ncycles));
	if(made - before < Ncycles/2)
		t.skip(sys->sprint("the cycles were freed as they were made (%d -> %d)", before, made));

	# a read walks the whole heap holding the VM: not too often
	for(waited := 0; waited < Waitms; waited += 1000){
		now := mine();
		if(now - before < Ncycles/10){
			t.log(sys->sprint("freed after %d ms: %d of this module's objects left", waited, now));
			return;
		}
		sys->sleep(1000);
	}
	t.error(sys->sprint("%d cycles not freed in %d s: %d of this module's objects, %d before",
		Ncycles, Waitms/1000, mine(), before));
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

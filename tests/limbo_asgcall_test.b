implement LimboAsgcallTest;

#
# a[i] = f(), where f makes a new a.  The compiler found the element's
# address (indx) before the call and passed it as where f's result
# goes; f's new array dropped the old one's last reference, so the
# result was written into freed memory and the new array never had it.
# The JavaScript engine's value stack grows so (jsvm.b growvs, a getter
# run from vs[k] = get(...)), and corrupted the heap on reddit.com.
#
# The call is made first now, into a temporary.  Each case checks the
# result is in the array the name holds after the assignment.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

LimboAsgcallTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/limbo_asgcall_test.b";

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

V: adt {
	t:	int;
	n:	real;
	s:	string;
};

O: adt {
	x:	int;
	s:	string;
};

vs: array of V;
ss: array of string;
ns: array of int;
o: ref O;

grows(): V
{
	nv := array[2 * len vs] of V;
	nv[0:] = vs;
	vs = nv;
	return V(7, 2.5, "seven");
}

growss(): string
{
	nss := array[2 * len ss] of string;
	nss[0:] = ss;
	ss = nss;
	return "made";
}

growns(): int
{
	nns := array[2 * len ns] of int;
	nns[0:] = ns;
	ns = nns;
	return 42;
}

newo(): string
{
	o = ref O(1, "new");
	return "set";
}

testAdt(t: ref T)
{
	vs = array[4] of V;
	vs[2] = grows();
	t.asserteq(len vs, 8, "grown");
	t.asserteq(vs[2].t, 7, "the adt's int in the new array");
	t.assertseq(vs[2].s, "seven", "the adt's string in the new array");
}

testPointer(t: ref T)
{
	ss = array[4] of string;
	ss[1] = growss();
	t.assertseq(ss[1], "made", "a string in the new array");
}

testInt(t: ref T)
{
	ns = array[4] of int;
	ns[3] = growns();
	t.asserteq(ns[3], 42, "an int in the new array");
	ns = array[4] of int;
	ns[0] = 1;
	ns[0] += growns();
	t.asserteq(ns[0], 43, "+= with a call: the new array's");
}

testInExpression(t: ref T)
{
	ns = array[4] of int;
	ns[1] = growns() + 1;
	t.asserteq(ns[1], 43, "a call inside the right side");
}

testField(t: ref T)
{
	o = ref O(0, "old");
	o.s = newo();
	t.assertseq(o.s, "set", "a field of the object the call made");
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
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Adt", testAdt);
	run("Pointer", testPointer);
	run("Int", testInt);
	run("InExpression", testInExpression);
	run("Field", testField);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

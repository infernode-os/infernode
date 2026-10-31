implement LimboInlineTest;

#
# Code the Limbo compiler produces when it inlines a small function
# (one whose body is `return e;`, or an if/else of two returns).
#
# 1. An argument with side effects that the body uses more than once is
#    put in a temporary: sel(array[] of {...}, i) with sel(a, i) =
#    a[i % len a] becomes (tmp = array[] of {...}, tmp[i % len tmp]).
#    eacom() compiled that to the address of tmp[i % len tmp] and then
#    freed tmp -- which stores nil into it, releasing the array and the
#    strings only it held -- before the caller read the element.  The
#    caller then read freed memory: `b += "<" + sel(...)` faulted in
#    addstring's memmove, or appended garbage, or corrupted the heap.
#
# 2. A function returning an adt, inlined as v = f(v), built its result
#    straight into v one member at a time, so a later member computed
#    from v saw the members already written.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

LimboInlineTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/limbo_inline_test.b";

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

# inlined; a used twice, so an argument with side effects goes in a temporary
sel(a: array of string, i: int): string
{
	return a[i % len a];
}

testTempArgOutlivesUse(t: ref T)
{
	b := "";
	want := "";
	for(i := 0; i < 2000; i++) {
		b += "<" + sel(array[] of {"n" + string i, "a"}, 0);
		want += "<n" + string i;
	}
	t.assertseq(b, want, "element of an inlined call's array argument");

	s := sel(array[] of {"x" + string 7, "y"}, 2) + sel(array[] of {"p", "q" + string 9}, 1);
	t.assertseq(s, "x7q9", "two inlined calls in one expression");
}

V: adt {
	t:	int;
	x:	int;
	r:	real;
};

h(v: V): int
{
	return v.t * 10 + v.x;
}

# inlined as an if/else of two returns
conv(v: V): V
{
	if(v.t == 5)
		return v;
	return V(5, h(v), 0.5);
}

swap(v: V): V
{
	return (v.x, v.t, v.r);
}

testResultAliasesArgument(t: ref T)
{
	v := V(1, 2, 0.0);
	v = conv(v);
	t.asserteq(v.t, 5, "v = conv(v): t");
	t.asserteq(v.x, 12, "v = conv(v): x computed from the old v");

	w := V(3, 4, 0.0);
	w = swap(w);
	t.asserteq(w.t, 4, "w = swap(w): t");
	t.asserteq(w.x, 3, "w = swap(w): x");

	a := array[1] of {V(1, 2, 0.0)};
	a[0] = conv(a[0]);
	t.asserteq(a[0].x, 12, "a[0] = conv(a[0])");

	u := V(1, 2, 0.0);
	z := conv(u);
	t.asserteq(z.x, 12, "z := conv(u)");
	t.asserteq(u.t, 1, "conv(u) leaves u");
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

	run("TempArgOutlivesUse", testTempArgOutlivesUse);
	run("ResultAliasesArgument", testResultAliasesArgument);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

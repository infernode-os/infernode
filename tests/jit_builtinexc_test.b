implement JitBuiltinexcTest;

#
# jit_builtinexc_test - an exception a builtin raises (Sys->utfbytes's
# "array bounds error") inside a handler block is caught by that
# block, in the calling function's frame, from compiled code as from
# the interpreter.
#
# The JITs called a builtin with R.PC whatever was last punted: after a
# punted instruction in the block (a tuple's movmp), the handler search
# matched it with the builtin's own frame, zeroed that frame's slots as
# though the caller's locals, wrote the exception into it and resumed
# the caller there (destroy of nil, a nil frame pointer in compiled
# code: tools/sysfuzz with a main pool too small, the native chaos
# build). tests/host/jit_builtinexc_test.sh runs it under -c0 and -c1.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitBuiltinexcTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_builtinexc_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# the tuple's copy is a punted movmp, inside the block, before the call
caught(ex: (string, array of byte), n: int): string
{
	r := "none";
	{
		(s, b) := ex;
		x := sys->utfbytes(b, n);
		r = s + string x;
	} exception e {
	"*" =>
		r = "caught " + e;
	}
	return r;
}

# the same, with the call in a callee: caught a frame further up
inner(b: array of byte, n: int): int
{
	return sys->utfbytes(b, n);
}

caughtup(ex: (string, array of byte), n: int): string
{
	r := "none";
	{
		(s, b) := ex;
		x := inner(b, n);
		r = s + string x;
	} exception e {
	"*" =>
		r = "caught " + e;
	}
	return r;
}

testCaughtAtCall(t: ref T)
{
	b := array[2] of byte;
	for(i := 0; i < 2000; i++){
		r := caught(("abc", b), 5);
		if(r != "caught array bounds error"){
			t.fatal(sys->sprint("call %d: %s", i, r));
			return;
		}
	}
	t.assertseq(caught(("abc", b), 1), "abc1", "and returns when it does not raise");
}

testCaughtAbove(t: ref T)
{
	b := array[2] of byte;
	for(i := 0; i < 2000; i++){
		r := caughtup(("abc", b), 5);
		if(r != "caught array bounds error"){
			t.fatal(sys->sprint("call %d: %s", i, r));
			return;
		}
	}
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

	run("CaughtAtCall", testCaughtAtCall);
	run("CaughtAbove", testCaughtAbove);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

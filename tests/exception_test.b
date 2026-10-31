implement ExceptionTest;

#
# The exception handler's search (os/port/exception.c, emu/port/
# exception.c): an exception block whose clauses do not match and has
# no wildcard is NOT a handler -- the search goes on to the caller's
# frames. For four days on the board it was one (#635): the "no
# handler" sentinel is (ulong)-1 and the kernel compared it with a
# 32-bit 0xffffffff, so the Prog was resumed at prog - 1, "misaligned
# PC in compiled module". These cases are exactly the shapes that did
# it: a callee raising something the caller's block does not name.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

ExceptionTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/exception_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip" => ;
	"*" => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# raises something the innermost block below does not name
inner(what: string)
{
	{
		raise what;
	} exception {
	"fail:*" =>
		raise "wrong handler: fail clause took " + what;
	}
}

middle(what: string)
{
	{
		inner(what);
	} exception {
	"other:*" =>
		raise "wrong handler: other clause took " + what;
	}
}

testUnmatchedInnerBlock(t: ref T)
{
	# two blocks with clauses that do not match, then the one that does
	got := "";
	{
		middle("boom: not fail, not other");
	} exception e {
	"boom:*" =>
		got = e;
	}
	t.assertseq(got, "boom: not fail, not other", "the exception passed two non-matching blocks to the one that names it");
}

testWildcardInOuter(t: ref T)
{
	got := "";
	{
		middle("anything at all");
	} exception e {
	"*" =>
		got = e;
	}
	t.assertseq(got, "anything at all", "an outer wildcard takes what inner blocks did not name");
}

testMatchedInner(t: ref T)
{
	# the ordinary case still works: the innermost matching clause wins
	got := "";
	{
		{
			raise "fail:inner";
		} exception e {
		"fail:*" =>
			got = "inner took " + e;
		}
	} exception e {
	"*" =>
		got = "outer took " + e;
	}
	t.assertseq(got, "inner took fail:inner", "the innermost matching block handles it");
}

testNonStringException(t: ref T)
{
	# an exception with no string form crossing a non-matching block
	got := 0;
	{
		{
			raise "nomatch:here";
		} exception {
		"fail:*" =>
			got = -1;
		}
	} exception {
	"nomatch:*" =>
		got = 1;
	}
	t.asserteq(got, 1, "a non-matching inner block does not swallow the exception");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("UnmatchedInnerBlock", testUnmatchedInnerBlock);
	run("WildcardInOuter", testWildcardInOuter);
	run("MatchedInner", testMatchedInner);
	run("NonStringException", testNonStringException);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

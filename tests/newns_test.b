implement NewnsTest;

#
# newns(2), a name space built from a file (appl/lib/newns.b; nsbuild is
# its one caller).
#
# A line with a variable that was not set was taken for a comment, so a
# file's bind over what the name space must not show was left out and
# the rest of the file applied as though it had been made.  A word that
# was empty (a quoted nothing, a variable set to nothing) in a command's
# place raised an exception in the reader.  A mount with too few
# arguments and -i was no error.  And a user had to be named, though it
# is not used: nsbuild names none, and built nothing.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "newns.m";
	newns: Newns;
include "testing.m";
	testing: Testing;
	T: import testing;

NewnsTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/newns_test.b";
DIR: con "/tmp/newns_test";

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

put(path, text: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd != nil)
		sys->fprint(fd, "%s", text);
}

mkdir(path: string)
{
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

get(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# Build a name space from text, in a process with a name space and an
# environment of its own: what newns returned ("raised: ..." if it
# raised), and what a probe file then reads as.
build(r: chan of (string, string), user, text, probe: string)
{
	sys->pctl(Sys->FORKNS|Sys->FORKENV, nil);
	fd := sys->create("#e/newnsset", Sys->OWRITE, 8r664);
	if(fd != nil)
		sys->fprint(fd, "%s", DIR + "/a");
	fd = sys->create("#e/newnsempty", Sys->OWRITE, 8r664);
	fd = nil;
	put(DIR + "/ns", text);
	e: string;
	{
		e = newns->newns(user, DIR + "/ns");
	} exception x {
	"*" =>
		e = "raised: " + x;
	}
	r <-= (e, get(probe));
}

try(user, text, probe: string): (string, string)
{
	r := chan of (string, string);
	spawn build(r, user, text, probe);
	return <-r;
}

fixture()
{
	mkdir(DIR);
	mkdir(DIR + "/a");
	mkdir(DIR + "/b");
	mkdir(DIR + "/x");
	put(DIR + "/a/f", "a");
	put(DIR + "/b/f", "b");
	put(DIR + "/x/f", "x");
}

testUnsetVariable(t: ref T)
{
	# set: the bind is made
	(e, got) := try("inferno", "bind $newnsset " + DIR + "/x\n", DIR + "/x/f");
	t.assertseq(e, "", "a line with a variable that is set");
	t.assertseq(got, "a", "its bind is made");
	# not set: an error, and what follows is not done
	(e, got) = try("inferno", "bind $newnsnotset " + DIR + "/x\nbind " + DIR + "/b " + DIR + "/x\n", DIR + "/x/f");
	t.assert(e != "" && has(e, "newnsnotset"), "a line with a variable that is not set is an error naming it: " + e);
	t.assertseq(got, "x", "nothing after it is done");
}

testEmptyWord(t: ref T)
{
	(e, nil) := try("inferno", "'' " + DIR + "/a " + DIR + "/x\n", DIR + "/x/f");
	t.assert(e != "" && !has(e, "raised"), "an empty word as a command is an error, not an exception: " + e);
	(e, nil) = try("inferno", "$newnsempty " + DIR + "/a " + DIR + "/x\n", DIR + "/x/f");
	t.assert(e != "" && !has(e, "raised"), "a variable set to nothing as a command is an error, not an exception: " + e);
	(e, nil) = try("inferno", "# a comment\n\nbind " + DIR + "/a " + DIR + "/x\n", DIR + "/x/f");
	t.assertseq(e, "", "comments and empty lines are passed over");
}

testMountArguments(t: ref T)
{
	(e, nil) := try("inferno", "mount -i\n", DIR + "/x/f");
	t.assert(e != "", "a mount with no arguments is an error with -i too");
	(e, nil) = try("inferno", "bind -i\n", DIR + "/x/f");
	t.assert(e != "", "a bind with no arguments is an error with -i");
	(e, nil) = try("inferno", "bind -i " + DIR + "/nosuch " + DIR + "/x\n", DIR + "/x/f");
	t.assertseq(e, "", "a bind that fails is passed over with -i");
}

# Lines that asked for Plan 9's authentication (factotum's p9any, which
# is gone) say so; they dialled, and failed at the far end or for want
# of one.
testPlan9(t: ref T)
{
	(e, nil) := try("inferno", "mount -9 tcp!127.0.0.1!1 " + DIR + "/x\n", DIR + "/x/f");
	t.assert(has(e, "p9sk1") && !has(e, "dial"), "mount -9 is refused before it dials: " + e);
	(e, nil) = try("inferno", "import tcp!127.0.0.1!1 / " + DIR + "/x\n", DIR + "/x/f");
	t.assert(has(e, "p9sk1") && !has(e, "tcp!"), "import is refused before it dials: " + e);
}

testNoUser(t: ref T)
{
	(e, got) := try(nil, "bind " + DIR + "/b " + DIR + "/x\n", DIR + "/x/f");
	t.assertseq(e, "", "a name space is built with no user named");
	t.assertseq(got, "b", "its bind is made");
}

testNested(t: ref T)
{
	put(DIR + "/inner", "bind " + DIR + "/b " + DIR + "/x\n");
	(e, got) := try("inferno", ". " + DIR + "/inner\n", DIR + "/x/f");
	t.assertseq(e, "", "a file that reads another");
	t.assertseq(got, "b", "the other's bind is made");
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
	newns = load Newns Newns->PATH;
	if(newns == nil) {
		sys->fprint(sys->fildes(2), "cannot load newns: %r\n");
		raise "fail:cannot load newns";
	}
	fixture();

	run("UnsetVariable", testUnsetVariable);
	run("EmptyWord", testEmptyWord);
	run("MountArguments", testMountArguments);
	run("Plan9", testPlan9);
	run("NoUser", testNoUser);
	run("Nested", testNested);

	for(l := "/ns" :: "/inner" :: "/a/f" :: "/b/f" :: "/x/f" :: "/a" :: "/b" :: "/x" :: "" :: nil; l != nil; l = tl l)
		sys->remove(DIR + hd l);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

implement NewnsRootTest;

#
# pctl(NEWNS) makes the current directory the root of the new name space
# (sys-pctl(2)). Nothing above it may be reached from there: not by /..,
# not by a relative .., not by chdir("..").
#
# The absolute forms were held once Cname recorded the mount points a walk
# crossed (INFR-407). The relative ones were not: the new dot was a clone
# that kept the name dot had, with the stack of the path that led to it, so
# ../x opened a file of the old parent and chdir("..") went there.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

NewnsRootTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/newns_root_test.b";

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

# what the confined process found
Found: adt {
	err:	string;		# could not be set up
	inside:	int;		# /inside opened
	absup:	int;		# /../canary opened
	relup:	int;		# ../canary opened
	relup2:	int;		# the canary opened by ../../<scratch>/canary
	wrote:	int;		# create ../made left a file that is not /made
	climbed:	int;		# canary opened after chdir("..")
	stayed:	int;		# inside still there after four chdir("..")
};

base, leaf: string;

mkfile(name, text: string): int
{
	fd := sys->create(name, Sys->OWRITE, 8r644);
	if(fd == nil)
		return -1;
	return sys->fprint(fd, "%s", text);
}

setup(): string
{
	leaf = sys->sprint("newns_root_test.%d", sys->pctl(0, nil));
	base = "/tmp/" + leaf;
	if(sys->create(base, Sys->OREAD, Sys->DMDIR|8r755) == nil)
		return sys->sprint("mkdir %s: %r", base);
	if(sys->create(base+"/jail", Sys->OREAD, Sys->DMDIR|8r755) == nil)
		return sys->sprint("mkdir %s/jail: %r", base);
	if(mkfile(base+"/jail/inside", "inside\n") < 0 || mkfile(base+"/canary", "outside\n") < 0)
		return sys->sprint("create: %r");
	return nil;
}

cleanup()
{
	sys->remove(base+"/jail/inside");
	sys->remove(base+"/jail/made");
	sys->remove(base+"/jail");
	sys->remove(base+"/canary");
	sys->remove(base+"/made");
	sys->remove(base);
}

opens(name: string): int
{
	return sys->open(name, Sys->OREAD) != nil;
}

# in a process of its own: the new name space is this process's alone
confined(dir, leaf: string, flags: int, c: chan of ref Found)
{
	f := ref Found(nil, 0, 0, 0, 0, 0, 0, 0);
	if(sys->chdir(dir) < 0){
		f.err = sys->sprint("chdir %s: %r", dir);
		c <-= f;
		return;
	}
	if(sys->pctl(flags, nil) < 0){
		f.err = sys->sprint("pctl: %r");
		c <-= f;
		return;
	}
	f.inside = opens("/inside");
	f.absup = opens("/../canary");
	f.relup = opens("../canary");
	f.relup2 = opens("../../" + leaf + "/canary");

	fd := sys->create("../made", Sys->OWRITE, 8r644);
	if(fd != nil){
		fd = nil;
		(ok, nil) := sys->stat("/made");
		f.wrote = ok < 0;	# made, and not in the root: it is above it
	}

	for(i := 0; i < 4; i++){
		if(sys->chdir("..") < 0)
			break;
		if(opens("canary"))
			f.climbed = 1;
	}
	f.stayed = opens("inside");
	c <-= f;
}

confine(flags: int): ref Found
{
	c := chan of ref Found;
	spawn confined(base+"/jail", leaf, flags, c);
	return <-c;
}

check(t: ref T, f: ref Found)
{
	if(f.err != nil)
		t.fatal(f.err);
	t.assert(f.inside, "/inside, a file of the new root, opens");
	t.assert(!f.absup, "/../canary does not open");
	t.assert(!f.relup, "../canary does not open");
	t.assert(!f.relup2, "the canary does not open by ../../ and its directory's name");
	t.assert(!f.wrote, "create ../made makes the file in the root, not above it");
	t.assert(!f.climbed, "chdir(\"..\") does not reach the directory above the root");
	t.assert(f.stayed, "after four chdir(\"..\") the directory is still the root");
}

testNewns(t: ref T)
{
	check(t, confine(Sys->NEWNS));
}

testNewnsNodevs(t: ref T)
{
	check(t, confine(Sys->NEWNS|Sys->NODEVS));
}

# the name space the test itself runs in is as it was
testParentUnchanged(t: ref T)
{
	confine(Sys->NEWNS);
	t.assert(opens(base+"/canary"), "the parent still names the canary by its path");
	t.assert(opens(base+"/jail/inside"), "the parent still names the jail's file by its path");
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

	err := setup();
	if(err != nil){
		sys->fprint(sys->fildes(2), "newns_root_test: %s\n", err);
		raise "fail:setup";
	}

	run("Newns", testNewns);
	run("NewnsNodevs", testNewnsNodevs);
	run("ParentUnchanged", testParentUnchanged);

	cleanup();

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

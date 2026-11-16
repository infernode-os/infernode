implement WstatOwnerTest;

#
# A wstat of a host file (#U, emu/port/devfs-posix.c) that names a new
# owner is refused.
#
# The owner was not looked at: the wstat did whatever else it was asked
# and said it had succeeded, whatever the name (one of 65480 bytes
# too), so chgrp -o and cp -u reported an owner changed that was not.
# The owner of a host's file is not ours to give away (stat(5)).
#
# - a wstat naming another owner fails, and changes nothing else it
#   asked for (the mode)
# - one of 65480 bytes fails
# - a wstat naming the owner the file has (a stat written back) is no
#   change and succeeds; nulldir and a mode alone as before
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

WstatOwnerTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/wstat_owner_test.b";
FILE: con "/tmp/wstat_owner_test.file";

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

testOwner(t: ref T)
{
	fd := sys->create(FILE, Sys->OWRITE, 8r644);
	if(fd == nil)
		t.skip(sys->sprint("cannot create %s: %r", FILE));
	fd = nil;
	(ok, d0) := sys->stat(FILE);
	if(ok < 0)
		t.fatal(sys->sprint("stat: %r"));
	if(d0.dtype != 'U')
		t.skip(sys->sprint("%s is not a host file (device %c)", FILE, d0.dtype));

	# another owner, and a mode with it: refused whole
	d := sys->nulldir;
	d.uid = "nobody-of-this-name";
	d.mode = 8r600;
	t.assert(sys->wstat(FILE, d) < 0, "a wstat naming another owner is refused");
	(nil, d1) := sys->stat(FILE);
	t.asserteq(d1.mode & 8r777, 8r644, "and the mode it asked for with it is not set");
	t.assertseq(d1.uid, d0.uid, "and the owner is the one it was");

	# a name no owner has, of any length
	d = sys->nulldir;
	d.uid = string array[65480] of {* => byte 'u'};
	t.assert(sys->wstat(FILE, d) < 0, "a wstat naming an owner of 65480 bytes is refused");

	# the owner it has: no change
	d = sys->nulldir;
	d.uid = d0.uid;
	t.assert(sys->wstat(FILE, d) >= 0, sys->sprint("a wstat naming the owner the file has succeeds: %r"));
	t.assert(sys->wstat(FILE, d0) >= 0, sys->sprint("a stat written back succeeds: %r"));
	t.assert(sys->wstat(FILE, sys->nulldir) >= 0, sys->sprint("a wstat that changes nothing succeeds: %r"));
	d = sys->nulldir;
	d.mode = 8r600;
	t.assert(sys->wstat(FILE, d) >= 0, sys->sprint("a wstat of the mode alone succeeds: %r"));
	(nil, d1) = sys->stat(FILE);
	t.asserteq(d1.mode & 8r777, 8r600, "and sets it");
	sys->remove(FILE);
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

	run("Owner", testOwner);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

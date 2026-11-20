implement DevipConvTest;

#
# The hosted emulator's /net (emu/port/devip.c): its conversations.
#
#  - A conversation claimed by a clone, or by the first open of its ctl,
#    whose socket could not be had (the host out of descriptors) was
#    left claimed: locked and in use for good from the clone, in use for
#    good from the open.  Each failure lost one, and with enough of them
#    the protocol had none to give.
#  - The table of conversations was grown by realloc while reads of a
#    conversation's files index it with no lock held.
#  - Whether a user might open a conversation was asked of the owner's
#    permission bits whoever the user was: any user could open any
#    other's ctl, data and listen files.  As in the native kernel, the
#    owner is asked by the owner's bits and anyone else by the others'.
#
# The first needs a limit on the emulator's descriptors that is reached
# before the table is full: tests/host/devip_conv_test.sh runs this
# under one.  Permission is tested last, as it gives up the identity the
# tests run with.
#
# A conversation once made is in its protocol's directory for as long as
# the emulator runs, and a walk to one costs a pass over those before
# it.  The first two tests make hundreds, and with no limit on
# descriptors thousands: every listing of /net after them is that much
# slower (3000 conversations of tcp took a second to read the status
# files of, where there had been two; matrix's sysmon service, which
# reads them each second, fell behind its tests' deadlines on a slow
# machine).  So they run only with -o, in an emulator of their own, as
# the host test runs them; in the suite's emulator they are skipped.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

DevipConvTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/devip_conv_test.b";

# whether the emulator is this test's alone (-o)
own := 0;
OWN: con "leaves its conversations in the emulator's table: run with -o in an emulator of its own (tests/host/devip_conv_test.sh)";

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

# a new conversation of proto: its ctl file and its number, or (nil, -1)
clone(proto: string): (ref Sys->FD, int)
{
	fd := sys->open("/net/" + proto + "/clone", Sys->ORDWR);
	if(fd == nil)
		return (nil, -1);
	buf := array[32] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return (nil, -1);
	return (fd, int string buf[0:n]);
}

# the number of conversations proto has made
nconv(proto: string): int
{
	fd := sys->open("/net/" + proto, Sys->OREAD);
	if(fd == nil)
		return -1;
	n := 0;
	for(;;){
		(nd, d) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd; i++)
			if(d[i].mode & Sys->DMDIR)
				n++;
	}
	return n;
}

lister(proto: string, stop: chan of int, done: chan of int)
{
	n := 0;
	for(;;){
		alt{
		<-stop =>
			done <-= n;
			return;
		* =>
			;
		}
		if(nconv(proto) < 0)
			break;
		fd := sys->open(sys->sprint("/net/%s/%d/status", proto, n % 8), Sys->OREAD);
		if(fd != nil)
			sys->read(fd, array[64] of byte, 64);
		n++;
	}
	<-stop;
	done <-= -1;
}

# The table grows (at 64 conversations of udp, and again at 128) while
# another Prog lists the protocol and reads its conversations' files.
testGrow(t: ref T)
{
	if(!own)
		t.skip(OWN);
	stop := chan of int;
	done := chan of int;
	spawn lister("udp", stop, done);
	fds: list of ref Sys->FD;
	got := 0;
	for(round := 0; round < 3; round++){
		for(i := 0; i < 150; i++){
			(fd, nil) := clone("udp");
			if(fd == nil)
				break;
			fds = fd :: fds;
			got++;
		}
		fds = nil;
	}
	stop <-= 1;
	n := <-done;
	t.assert(got >= 150, sys->sprint("conversations made while the protocol was listed: %d", got));
	t.assert(n > 0, sys->sprint("the protocol was listed %d times meanwhile", n));
	(fd, nil) := clone("udp");
	t.assert(fd != nil, "a conversation is to be had afterwards");
}

MAXTRY: con 3000;

# all the conversations of tcp there are descriptors for, and their numbers
fill(want: int): (array of ref Sys->FD, array of int, int)
{
	fds := array[MAXTRY] of ref Sys->FD;
	nums := array[MAXTRY] of int;
	for(n := 0; n < want; n++){
		(fds[n], nums[n]) = clone("tcp");
		if(fds[n] == nil)
			break;
	}
	return (fds, nums, n);
}

testSlots(t: ref T)
{
	if(!own)
		t.skip(OWN);
	(fds, nums, n0) := fill(MAXTRY);
	if(n0 >= MAXTRY){
		fds = nil;
		t.skip("no limit on descriptors below the table's size (tests/host/devip_conv_test.sh sets one)");
	}
	if(n0 < 20){
		fds = nil;
		t.fatal(sys->sprint("only %d conversations to be had", n0));
	}
	made := nconv("tcp");

	# with none to be had, fifty more are asked for
	refused := 0;
	for(i := 0; i < 50; i++){
		(fd, nil) := clone("tcp");
		if(fd == nil)
			refused++;
	}

	# one is given back and its descriptor taken by a file: the first
	# open of its ctl needs a socket, and there is none
	k := nums[n0/2];
	fds[n0/2] = nil;
	hf := sys->open("/dis/sh.dis", Sys->OREAD);
	cfd := sys->open(sys->sprint("/net/tcp/%d/ctl", k), Sys->ORDWR);
	reopened := cfd != nil;
	cfd = nil;
	hf = nil;

	# all given back
	for(i = 0; i < n0; i++)
		fds[i] = nil;
	fds = nil;

	t.asserteq(refused, 50, "clones refused with no descriptor left");
	t.assert(!reopened, "a ctl opened with no descriptor left is refused");

	# and the same conversations are to be had again
	(fds2, nums2, n1) := fill(n0);
	now := nconv("tcp");
	fds2 = nil;
	t.asserteq(n1, n0, "conversations to be had after the refusals");
	same := n1 == n0;
	for(i = 0; same && i < n0; i++)
		same = nums[i] == nums2[i];
	t.assert(same, "and they are the same ones, none lost");
	t.assert(now - made <= 1, sys->sprint("conversations made by 50 refused clones: %d", now - made));
}

iserr(want: string): int
{
	e := sys->sprint("%r");
	for(i := 0; i + len want <= len e; i++)
		if(e[i:i+len want] == want)
			return 1;
	return 0;
}

testPermission(t: ref T)
{
	# the host owner's: one announced, one only made
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("announce: %r"));
	(mine, n) := clone("udp");
	if(mine == nil)
		t.fatal(sys->sprint("clone: %r"));
	udpdir := sys->sprint("/net/udp/%d", n);
	t.assert(sys->open(c.dir + "/ctl", Sys->ORDWR) != nil, "its owner opens a conversation's ctl again");
	t.assert(sys->open(udpdir + "/data", Sys->ORDWR) != nil, "and another's data");

	ufd := sys->open("/dev/user", Sys->OWRITE);
	if(ufd == nil)
		t.skip("not the host owner");
	other := array of byte "devip-conv-test";
	if(sys->write(ufd, other, len other) != len other)
		t.fatal(sys->sprint("cannot give up the host owner's name: %r"));
	ufd = nil;

	# now someone else
	files := array[] of {c.dir + "/ctl", c.dir + "/data", c.dir + "/listen", udpdir + "/ctl", udpdir + "/data"};
	for(i := 0; i < len files; i++){
		fd := sys->open(files[i], Sys->ORDWR);
		t.assert(fd == nil && iserr("permission"), sys->sprint("another user's open of %s is refused: %r", files[i]));
		fd = sys->open(files[i], Sys->OREAD);
		t.assert(fd == nil, "and its open for reading");
	}
	t.assert(sys->open(c.dir + "/status", Sys->OREAD) != nil, "its status is anyone's to read");
	# the host's ARP table and the network database are the host owner's to change
	t.assert(sys->open("/net/arp", Sys->OWRITE) == nil && iserr("permission"), sys->sprint("another user's open of /net/arp to write it is refused: %r"));
	t.assert(sys->open("/net/arp", Sys->ORDWR) == nil, "and to read and write it");
	t.assert(sys->open("/net/ndb", Sys->ORDWR) == nil, "and of /net/ndb");

	# and a conversation of that user's own
	(own, on) := clone("tcp");
	if(own == nil)
		t.fatal(sys->sprint("clone as another user: %r"));
	t.assert(sys->open(sys->sprint("/net/tcp/%d/ctl", on), Sys->ORDWR) != nil, "a user opens their own conversation's ctl again");
	t.assert(sys->open(sys->sprint("/net/tcp/%d/data", on), Sys->ORDWR) != nil, "and its data");
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
		else if(hd a == "-o")
			own = 1;

	run("Grow", testGrow);
	run("Slots", testSlots);
	run("Permission", testPermission);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

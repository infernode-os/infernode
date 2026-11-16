implement File2chanGaveupTest;

#
# A file2chan server can tell that a request has been given up.
#
# A read or write of a file2chan file waits for the server's answer on
# the request's reply channel.  When the reader was killed, or its 9P
# request flushed, the kernel stopped waiting and the server was not
# told: its answer went into the channel's buffer and nowhere else.  A
# server that hands out a stream (post9p(2): a posted connection's 9P
# replies) then gave the next piece of it to the request that had gone,
# and the reader after it waited for a reply that had been spent.
#
# The reply channel now holds (nil, "interrupted") (for a write, (0,
# "interrupted")) once its request is given up, which a server takes
# with a receive that does not wait (devsrv.c, both kernels;
# sys-file2chan(2)).
#
# - a reader killed in its read: the server finds "interrupted" on that
#   request's reply channel, keeps the piece that was for it, and the
#   next reader gets that piece
# - a writer killed in its write: the same on its reply channel
# - a server that does not look answers the dead request without
#   waiting, and the next reader gets its own answer, not that one
# - requests that are not given up have nothing on their channels
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

File2chanGaveupTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/file2chan_gaveup_test.b";
DIR: con "/tmp/f2c_gaveup";

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

# what the server saw
told := 0;		# requests it found given up
toldwhy := "";
nowait := 0;	# answers to dead requests that did not wait

# has the request with this reply channel been given up?
gone(rc: Sys->Rread): int
{
	alt{
	(nil, why) := <-rc =>
		told++;
		toldwhy = why;
		return 1;
	* =>
		return 0;
	}
}

wgone(wc: Sys->Rwrite): int
{
	alt{
	(nil, why) := <-wc =>
		told++;
		toldwhy = why;
		return 1;
	* =>
		return 0;
	}
}

#
# A stream: pieces "piece 0", "piece 1", ..., one to each read, each
# held until release says so (a server that answers late).  With look,
# a piece whose reader has gone is kept for the next; without, it is
# sent to the dead request, as a server that does not look does.
#
stream(f: ref Sys->FileIO, look: int, held: chan of int, release: chan of int)
{
	n := 0;
	for(;;) alt{
	(nil, nil, nil, rc) := <-f.read =>
		if(rc == nil)
			continue;
		held <-= 1;
		<-release;
		if(look && gone(rc))
			continue;	# the piece is still to give
		alt{
		rc <-= (array of byte sys->sprint("piece %d", n), nil) =>
			nowait++;
		* =>
			;	# an answer never waits: there is room for it
		}
		n++;
	(nil, nil, nil, wc) := <-f.write =>
		if(wc == nil)
			continue;
		held <-= 1;
		<-release;
		if(look && wgone(wc))
			continue;
		wc <-= (1, nil);
	}
}

reader(file: string, pidc: chan of int, c: chan of string)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil){
		c <-= sys->sprint("open: %r");
		return;
	}
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		c <-= sys->sprint("read: %r");
	else
		c <-= string buf[0:n];
}

writer(file: string, pidc: chan of int, c: chan of string)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(file, Sys->OWRITE);
	if(fd == nil){
		c <-= sys->sprint("open: %r");
		return;
	}
	b := array of byte "x";
	if(sys->write(fd, b, len b) != len b)
		c <-= sys->sprint("write: %r");
	else
		c <-= "written";
}

kill(pid: int)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

timer(c: chan of string, ms: int)
{
	sys->sleep(ms);
	alt{
	c <-= "TIMEOUT" =>
		;
	* =>
		;
	}
}

# the next thing a reader or writer says, or TIMEOUT
result(c: chan of string): string
{
	spawn timer(c, 5000);
	return <-c;
}

mkfile(name: string, look: int): (chan of int, chan of int)
{
	f := sys->file2chan(DIR, name);
	if(f == nil)
		raise sys->sprint("fail:file2chan %s: %r", name);
	held := chan of int;
	release := chan of int;
	spawn stream(f, look, held, release);
	return (held, release);
}

testReaderKilled(t: ref T)
{
	(held, release) := mkfile("looks", 1);
	told = 0;
	toldwhy = "";
	pidc := chan of int;
	c := chan[4] of string;

	# a reader that is answered: nothing on its channel
	spawn reader(DIR + "/looks", pidc, c);
	<-pidc;
	<-held;
	release <-= 1;
	t.assertseq(result(c), "piece 0", "a reader that waits gets the first piece");
	t.asserteq(told, 0, "and its request was not given up");

	# one killed while the server holds its request
	spawn reader(DIR + "/looks", pidc, c);
	pid := <-pidc;
	<-held;
	kill(pid);
	sys->sleep(200);
	release <-= 1;
	sys->sleep(100);
	t.asserteq(told, 1, "the server finds the killed reader's request given up");
	t.assertseq(toldwhy, "interrupted", "and why");

	# the next reader gets the piece that was for it
	spawn reader(DIR + "/looks", pidc, c);
	<-pidc;
	<-held;
	release <-= 1;
	t.assertseq(result(c), "piece 1", "the next reader gets the piece the killed one did not");
	t.asserteq(told, 1, "and its request was not given up");
}

testWriterKilled(t: ref T)
{
	(held, release) := mkfile("wlooks", 1);
	told = 0;
	toldwhy = "";
	pidc := chan of int;
	c := chan[4] of string;

	spawn writer(DIR + "/wlooks", pidc, c);
	pid := <-pidc;
	<-held;
	kill(pid);
	sys->sleep(200);
	release <-= 1;
	sys->sleep(100);
	t.asserteq(told, 1, "the server finds the killed writer's request given up");
	t.assertseq(toldwhy, "interrupted", "and why");

	spawn writer(DIR + "/wlooks", pidc, c);
	<-pidc;
	<-held;
	release <-= 1;
	t.assertseq(result(c), "written", "the next writer is answered");
	t.asserteq(told, 1, "and its request was not given up");
}

testDoesNotLook(t: ref T)
{
	(held, release) := mkfile("blind", 0);
	nowait = 0;
	pidc := chan of int;
	c := chan[4] of string;

	spawn reader(DIR + "/blind", pidc, c);
	pid := <-pidc;
	<-held;
	kill(pid);
	sys->sleep(200);
	release <-= 1;
	sys->sleep(100);
	t.asserteq(nowait, 1, "an answer to a request given up does not wait");

	spawn reader(DIR + "/blind", pidc, c);
	<-pidc;
	<-held;
	release <-= 1;
	t.assertseq(result(c), "piece 1", "the next reader gets its own answer, not the one made for the killed reader");
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

	sys->pctl(Sys->FORKNS, nil);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR|8r777);
	if(sys->bind("#s", DIR, Sys->MREPL) < 0){
		sys->fprint(sys->fildes(2), "cannot bind #s on %s: %r\n", DIR);
		raise "fail:setup";
	}

	run("ReaderKilled", testReaderKilled);
	run("WriterKilled", testWriterKilled);
	run("DoesNotLook", testDoesNotLook);

	sys->unmount(nil, DIR);
	sys->remove(DIR);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

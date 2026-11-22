implement File2chanCloseTest;

#
# A file2chan server is told of every close.
#
# When a file2chan file is closed the server is sent a request with no
# reply channel on each of its channels (sys-file2chan(2)).  The kernel
# sent it only if the channel's buffer, sixteen requests, had room at
# that moment, and otherwise dropped it and printed "csendalt failed":
# a server busy for a moment while files were closed never heard of the
# seventeenth close, and one that counts its clients (post9p(2), cs)
# kept those for good, so opening and closing quickly used up its limit.
# A server that never receives on one channel (the plumber, on read)
# had the message printed at every close.
#
# The notices now wait in the kernel until the server receives
# (devsrv.c, both kernels), and a read or write on a fid whose last
# close still waits sends that close first.
#
# - Burst: 200 files open, the server not receiving, all closed at
#   once: the server is told of each on both channels (it was told of
#   sixteen)
# - Reuse: with those closes still waiting, new opens (given the Chans,
#   and so the fids, just closed) write and read: the server hears each
#   fid's close before its new request, a writer killed while it waits
#   to send costs no notice, and the new opens' own closes arrive
# - Churn: twenty clients opening, writing and closing against a server
#   that takes its time: every write is for a fid the server knows to
#   be closed, and at the end it knows of nobody
# - WriteOnly: a server that never receives on read is told of every
#   close on write, and leaving with notices waiting harms nothing
# - ServerLeaves: a server that goes while its files are being closed,
#   thirty times: the closes end, the file goes, and the next server's
#   file works (under tools/sanemu, nothing freed is used)
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

File2chanCloseTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/file2chan_close_test.b";
DIR: con "/tmp/f2c_close";

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

# what a server knows, one of these for each of its channels
Side: adt {
	live:	list of int;	# fids with a request and no close since
	requests:	int;
	closes:	int;	# of a fid that was live
	stray:	int;	# of one that was not
	early:	int;	# requests for a fid whose last close has not come

	request:	fn(s: self ref Side, fid: int);
	close:	fn(s: self ref Side, fid: int);
	has:	fn(s: self ref Side, fid: int): int;
};

Side.has(s: self ref Side, fid: int): int
{
	for(l := s.live; l != nil; l = tl l)
		if(hd l == fid)
			return 1;
	return 0;
}

Side.request(s: self ref Side, fid: int)
{
	s.requests++;
	if(s.has(fid))
		s.early++;
	else
		s.live = fid :: s.live;
}

Side.close(s: self ref Side, fid: int)
{
	if(!s.has(fid)){
		s.stray++;
		return;
	}
	s.closes++;
	nl: list of int;
	for(l := s.live; l != nil; l = tl l)
		if(hd l != fid)
			nl = hd l :: nl;
	s.live = nl;
}

Srv: adt {
	r, w:	ref Side;
	ctl:	chan of int;	# sent to: stop receiving until sent to again; -1: leave
	ack:	chan of int;
	slow:	int;	# ms after each request
};

#
# Each open here makes one request on a channel, so a request for a fid
# that is live is one whose close has been lost or is still to come.
#
serve(f: ref Sys->FileIO, s: ref Srv, reads: int)
{
	rd := f.read;
	if(!reads)
		rd = chan of (int, int, int, Sys->Rread);	# never ready
	for(;;) alt{
	(nil, nil, fid, rc) := <-rd =>
		if(rc == nil){
			s.r.close(fid);
			continue;
		}
		s.r.request(fid);
		rc <-= (array of byte "r", nil);
		if(s.slow)
			sys->sleep(s.slow);
	(nil, data, fid, wc) := <-f.write =>
		if(wc == nil){
			s.w.close(fid);
			continue;
		}
		s.w.request(fid);
		wc <-= (len data, nil);
		if(s.slow)
			sys->sleep(s.slow);
	v := <-s.ctl =>
		if(v < 0){
			s.ack <-= 1;
			return;
		}
		s.ack <-= 1;
		<-s.ctl;
	}
}

mksrv(name: string, slow: int, reads: int): ref Srv
{
	f := sys->file2chan(DIR, name);
	if(f == nil)
		raise sys->sprint("fail:file2chan %s: %r", name);
	s := ref Srv(ref Side(nil, 0, 0, 0, 0), ref Side(nil, 0, 0, 0, 0), chan of int, chan of int, slow);
	spawn serve(f, s, reads);
	return s;
}

pause(s: ref Srv)
{
	s.ctl <-= 1;
	<-s.ack;
}

resume(s: ref Srv)
{
	s.ctl <-= 1;
}

# wait, for five seconds at most, for the closes a server is to be told of
settle(s: ref Srv, rcloses, wcloses: int)
{
	for(i := 0; i < 100; i++){
		if(s.r.closes >= rcloses && s.w.closes >= wcloses)
			break;
		sys->sleep(50);
	}
	sys->sleep(100);	# and for any more than that
}

N: con 200;

# N files open, each with a write and a read behind it
openall(t: ref T, file: string): array of ref Sys->FD
{
	fds := array[N] of ref Sys->FD;
	buf := array[8] of byte;
	for(i := 0; i < N; i++){
		fds[i] = sys->open(file, Sys->ORDWR);
		if(fds[i] == nil)
			t.fatal(sys->sprint("open %d: %r", i));
		if(sys->write(fds[i], array of byte "x", 1) != 1)
			t.fatal(sys->sprint("write %d: %r", i));
		if(sys->read(fds[i], buf, len buf) != 1)
			t.fatal(sys->sprint("read %d: %r", i));
	}
	return fds;
}

testBurst(t: ref T)
{
	s := mksrv("burst", 0, 1);
	fds := openall(t, DIR + "/burst");
	t.asserteq(len s.w.live, N, "the server knows of every open by its write");
	t.asserteq(len s.r.live, N, "and by its read");

	pause(s);
	for(i := 0; i < N; i++)
		fds[i] = nil;
	resume(s);
	settle(s, N, N);

	t.asserteq(s.w.closes, N, "the server is told of every close on its write channel");
	t.asserteq(s.r.closes, N, "and on its read channel");
	t.asserteq(len s.w.live, 0, "so it knows of nobody");
	t.asserteq(s.w.stray + s.r.stray, 0, "and was told of each once");
}

writer(file: string, pidc: chan of int, c: chan of string)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(file, Sys->ORDWR);
	if(fd == nil){
		c <-= sys->sprint("open: %r");
		return;
	}
	if(sys->write(fd, array of byte "y", 1) != 1){
		c <-= sys->sprint("write: %r");
		return;
	}
	buf := array[8] of byte;
	if(sys->read(fd, buf, len buf) != 1){
		c <-= sys->sprint("read: %r");
		return;
	}
	c <-= "done";
	<-pidc;		# keep the file open until told
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

testReuse(t: ref T)
{
	s := mksrv("reuse", 0, 1);
	fds := openall(t, DIR + "/reuse");
	old := s.w.live;

	pause(s);
	for(i := 0; i < N; i++)
		fds[i] = nil;

	# new opens, while the old ones' closes wait
	M: con 4;
	pidc := chan of int;
	c := chan[M+1] of string;
	pids := array[M] of int;
	for(i = 0; i < M; i++){
		spawn writer(DIR + "/reuse", pidc, c);
		pids[i] = <-pidc;
	}
	sys->sleep(300);	# each is waiting to send
	kill(pids[0]);
	sys->sleep(100);
	resume(s);

	spawn timer(c, 5000);
	for(i = 1; i < M; i++)
		t.assertseq(<-c, "done", "a new open's write and read are answered");
	settle(s, N, N);

	reused := 0;
	for(l := s.w.live; l != nil; l = tl l)
		for(o := old; o != nil; o = tl o)
			if(hd o == hd l)
				reused++;
	t.log(sys->sprint("%d of the %d new opens have a fid that was closed", reused, M-1));

	t.asserteq(s.w.early, 0, "no write arrives before its fid's last close");
	t.asserteq(s.r.early, 0, "and no read");
	t.asserteq(s.w.closes, N, "the server is told of every close on its write channel");
	t.asserteq(s.r.closes, N, "and on its read channel");
	t.asserteq(len s.w.live, M-1, "and knows only of the new opens");
	t.asserteq(s.w.requests, N+M-1, "the killed writer wrote nothing");

	# the new ones go
	for(i = 1; i < M; i++)
		pidc <-= 1;
	settle(s, N+M-1, N+M-1);
	t.asserteq(s.w.closes, N+M-1, "the new opens' closes are told too");
	t.asserteq(len s.w.live, 0, "and the server knows of nobody");
	t.asserteq(len s.r.live, 0, "on either channel");
}

churner(file: string, n: int, c: chan of string)
{
	for(i := 0; i < n; i++){
		fd := sys->open(file, Sys->OWRITE);
		if(fd == nil){
			c <-= sys->sprint("open: %r");
			return;
		}
		if(sys->write(fd, array of byte "z", 1) != 1){
			c <-= sys->sprint("write: %r");
			return;
		}
		fd = nil;
	}
	c <-= "done";
}

testChurn(t: ref T)
{
	P: con 20;
	K: con 10;
	s := mksrv("churn", 2, 1);
	c := chan[P+1] of string;
	for(i := 0; i < P; i++)
		spawn churner(DIR + "/churn", K, c);
	spawn timer(c, 20000);
	for(i = 0; i < P; i++)
		t.assertseq(<-c, "done", "a client's opens, writes and closes");
	settle(s, 0, P*K);

	t.asserteq(s.w.requests, P*K, "every write reached the server");
	t.asserteq(s.w.early, 0, "each for a fid it knew to be closed");
	t.asserteq(s.w.closes, P*K, "and it was told of every close");
	t.asserteq(len s.w.live, 0, "so it knows of nobody");
}

testWriteOnly(t: ref T)
{
	s := mksrv("wonly", 0, 0);
	c := chan[2] of string;
	spawn churner(DIR + "/wonly", 100, c);
	spawn timer(c, 10000);
	t.assertseq(<-c, "done", "a hundred opens, writes and closes");
	settle(s, 0, 100);
	t.asserteq(s.w.closes, 100, "the server is told of every close on the channel it receives on");
	t.asserteq(s.w.early, 0, "in order");

	# it leaves, with the read channel's notices never taken
	s.ctl <-= -1;
	<-s.ack;
	sys->sleep(100);
	fd := sys->open(DIR + "/wonly", Sys->OWRITE);
	t.assert(fd == nil, "the file goes with its server");
	(ok, nil) := sys->stat(DIR);
	t.asserteq(ok, 0, "and the directory still answers");
}

closer(fds: array of ref Sys->FD, c: chan of int)
{
	for(i := 0; i < len fds; i++){
		fds[i] = nil;
		if(i%8 == 7)
			sys->sleep(0);
	}
	c <-= 1;
}

testServerLeaves(t: ref T)
{
	K: con 40;
	buf := array[8] of byte;
	for(round := 0; round < 30; round++){
		name := sys->sprint("leaves%d", round);
		file := DIR + "/" + name;
		s := mksrv(name, 0, round%2);
		fds := array[K] of ref Sys->FD;
		for(i := 0; i < K; i++){
			fds[i] = sys->open(file, Sys->ORDWR);
			if(fds[i] == nil || sys->write(fds[i], array of byte "x", 1) != 1)
				t.fatal(sys->sprint("round %d: open and write %d: %r", round, i));
			if(round%2 && sys->read(fds[i], buf, len buf) != 1)
				t.fatal(sys->sprint("round %d: read %d: %r", round, i));
		}
		# half the rounds with notices already waiting when it leaves
		if(round%4 >= 2){
			pause(s);
			for(i = 0; i < K/2; i++)
				fds[i] = nil;
			resume(s);
		}
		c := chan of int;
		spawn closer(fds, c);
		s.ctl <-= -1;
		<-s.ack;
		<-c;
		for(i = 0; i < 20 && sys->open(file, Sys->OREAD) != nil; i++)
			sys->sleep(10);
		if(sys->open(file, Sys->OREAD) != nil)
			t.fatal(sys->sprint("round %d: the file outlived its server", round));
	}
	t.log("thirty servers left while their files were closed");

	s := mksrv("after", 0, 1);
	fd := sys->open(DIR + "/after", Sys->ORDWR);
	t.assert(fd != nil && sys->write(fd, array of byte "x", 1) == 1, "a new server's file is written");
	fd = nil;
	settle(s, 0, 1);
	t.asserteq(s.w.closes, 1, "and its server is told of the close");
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

	run("Burst", testBurst);
	run("Reuse", testReuse);
	run("Churn", testChurn);
	run("WriteOnly", testWriteOnly);
	run("ServerLeaves", testServerLeaves);

	sys->unmount(nil, DIR);
	sys->remove(DIR);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

implement Post9pTest;

#
# post9p(2), a 9P server posted in #s (appl/lib/post9p.b): what post(1),
# gpsfs, sdrfs, tools9p, the editor, charonfs and others post with.
#
# One loop takes every read and write of the posted file, for every
# connection.  It handed each to its connection's reader or writer through
# a small buffered channel, and waited when that was full: a client with
# six reads outstanding on one descriptor (the reader in the first, on a
# pipe with nothing in it, four more in the buffer) stopped the loop in
# the sixth, and every other connection and every new mount of the post
# with it, for good.  Writes did the same once a server had stopped
# reading a connection.  A connection closed while its reader or writer
# was in the pipe was never closed at the server's end.  And a write to a
# connection whose server had closed its end was never answered.  A post
# with no spec was made, in a directory nobody else can attach.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "post9p.m";
	post9p: Post9p;
	Post: import post9p;
include "testing.m";
	testing: Testing;
	T: import testing;

Post9pTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/post9p_test.b";
DIR: con "/tmp/post9p_test";
SIZE: con 300000;

passed := 0;
failed := 0;
skipped := 0;
nspec := 0;

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

kill(pid: int)
{
	fd := sys->open("#p/"+string pid+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

timer(c: chan of string, ms: int)
{
	for(e := 0; e < ms; e += 100)
		sys->sleep(100);
	alt{
	c <-= "TIMEOUT" =>
		;
	* =>
		;
	}
}

# what a connection's server does with it: export the directory, or (the
# first hold connections) keep it unread and hand it to the test
server(conns: chan of ref Sys->FD, hold: int, held: chan of ref Sys->FD, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		fd := <-conns;
		if(hold > 0){
			hold--;
			held <-= fd;
			continue;
		}
		sys->export(fd, DIR + "/tree", Sys->EXPASYNC);
	}
}

Posted: adt {
	p:	ref Post;
	file:	string;
	spid:	int;
	held:	chan of ref Sys->FD;

	end:	fn(pd: self ref Posted);
};

mkpost(t: ref T, hold: int): ref Posted
{
	conns := chan of ref Sys->FD;
	(p, e) := post9p->post(sys->sprint("post9ptest%d.%d", sys->pctl(0, nil), nspec++), conns);
	if(p == nil)
		t.fatal("cannot post: " + e);
	pd := ref Posted(p, p.path, 0, chan[4] of ref Sys->FD);
	pidc := chan of int;
	spawn server(conns, hold, pd.held, pidc);
	pd.spid = <-pidc;
	return pd;
}

Posted.end(pd: self ref Posted)
{
	pd.p.unpost();
	kill(pd.spid);
}

mountproc(file, on: string, c: chan of string)
{
	fd := sys->open(file, Sys->ORDWR);
	if(fd == nil){
		c <-= sys->sprint("open %s: %r", file);
		return;
	}
	if(sys->mount(fd, nil, on, Sys->MREPL, nil) < 0){
		c <-= sys->sprint("mount: %r");
		return;
	}
	(ok, d) := sys->stat(on + "/big");
	if(ok < 0)
		c <-= sys->sprint("stat: %r");
	else
		c <-= sys->sprint("mounted %bd", d.length);
}

# mount the post and look at a file through it; "TIMEOUT" if that does not end
tmount(file, on: string): string
{
	c := chan[1] of string;
	spawn mountproc(file, on, c);
	spawn timer(c, 5000);
	return <-c;
}

readall(file: string, c: chan of string)
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil){
		c <-= sys->sprint("open: %r");
		return;
	}
	buf := array[8192] of byte;
	tot := 0;
	bad := 0;
	while((n := sys->read(fd, buf, len buf)) > 0){
		for(i := 0; i < n; i++)
			if(buf[i] != byte ((tot+i) % 251))
				bad++;
		tot += n;
	}
	if(n < 0)
		c <-= sys->sprint("read: %r");
	else
		c <-= sys->sprint("%d bytes, %d wrong", tot, bad);
}

tread(file: string): string
{
	c := chan[1] of string;
	spawn readall(file, c);
	spawn timer(c, 10000);
	return <-c;
}

WHOLE: con "300000 bytes, 0 wrong";

reader(fd: ref Sys->FD, pidc: chan of int, res: chan of string)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[64] of byte;
	if(sys->read(fd, buf, len buf) < 0)
		res <-= sys->sprint("%r");
	else
		res <-= "read";
}

testSixReads(t: ref T)
{
	pd := mkpost(t, 0);
	t.assertseq(tmount(pd.file, DIR + "/m1"), "mounted 300000", "a mount of the post");

	# a client that opens the posted file and only reads, six times at once
	fd := sys->open(pd.file, Sys->ORDWR);
	t.assert(fd != nil, sys->sprint("open of the posted file: %r"));
	pidc := chan of int;
	res := chan[8] of string;
	pids: list of int;
	for(i := 0; i < 6; i++){
		spawn reader(fd, pidc, res);
		pids = <-pidc :: pids;
	}
	sys->sleep(300);
	t.assertseq(tmount(pd.file, DIR + "/m2"), "mounted 300000", "with one client holding six reads, a new mount");
	t.assertseq(tread(DIR + "/m1/big"), WHOLE, "and the first mount reads its file");
	for(; pids != nil; pids = tl pids)
		kill(hd pids);
	fd = nil;
	sys->sleep(200);
	t.assertseq(tmount(pd.file, DIR + "/m3"), "mounted 300000", "after that client has gone, a new mount");
	sys->unmount(nil, DIR + "/m1");
	sys->unmount(nil, DIR + "/m2");
	sys->unmount(nil, DIR + "/m3");
	pd.end();
}

writer(fd: ref Sys->FD, n: int, pidc: chan of int, res: chan of string)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[n] of {* => byte 'w'};
	if(sys->write(fd, buf, len buf) < 0)
		res <-= sys->sprint("%r");
	else
		res <-= "written";
}

drain(fd: ref Sys->FD, c: chan of string)
{
	buf := array[64*1024] of byte;
	tot := 0;
	while((n := sys->read(fd, buf, len buf)) > 0)
		tot += n;
	if(n < 0)
		c <-= sys->sprint("read error: %r");
	else
		c <-= "end of file";
}

testStuckWrites(t: ref T)
{
	# the first connection's server does not read it
	pd := mkpost(t, 1);
	fd := sys->open(pd.file, Sys->ORDWR);
	t.assert(fd != nil, sys->sprint("open of the posted file: %r"));
	pidc := chan of int;
	res := chan[64] of string;
	pids: list of int;
	for(i := 0; i < 40; i++){
		spawn writer(fd, 32*1024, pidc, res);
		pids = <-pidc :: pids;
	}
	sfd := <-pd.held;
	sys->sleep(300);
	t.assertseq(tmount(pd.file, DIR + "/m1"), "mounted 300000", "with forty writes waiting on a connection nobody reads, a new mount");
	t.assertseq(tread(DIR + "/m1/big"), WHOLE, "which reads its file");

	# the client goes: its connection ends at the server too
	for(; pids != nil; pids = tl pids)
		kill(hd pids);
	fd = nil;
	c := chan[1] of string;
	spawn drain(sfd, c);
	sfd = nil;
	spawn timer(c, 5000);
	t.assertseq(<-c, "end of file", "a connection closed with writes waiting is closed at its server's end");
	sys->unmount(nil, DIR + "/m1");
	pd.end();
}

testManyReads(t: ref T)
{
	# more reads at once than a connection may have waiting
	Over: con 12;
	n := 1 + 1024 + Over;	# one with the reader, 1024 waiting
	pd := mkpost(t, 1);
	fd := sys->open(pd.file, Sys->ORDWR);
	t.assert(fd != nil, sys->sprint("open of the posted file: %r"));
	pidc := chan of int;
	res := chan[n] of string;
	pids: list of int;
	for(i := 0; i < n; i++){
		spawn reader(fd, pidc, res);
		pids = <-pidc :: pids;
	}
	sfd := <-pd.held;
	tc := chan[1] of string;
	spawn timer(tc, 10000);
	refused := 0;
	other := "";
	while(refused < Over){
		alt{
		r := <-res =>
			if(r == "too many reads outstanding on one connection")
				refused++;
			else
				other = r;
		<-tc =>
			t.error(sys->sprint("%d reads of %d refused in 10 s", refused, Over));
			refused = Over + 1;
		}
	}
	t.asserteq(refused, Over, "the reads past what a connection may have waiting are refused");
	t.assertnil(other, "and no other read is answered");
	t.assertseq(tmount(pd.file, DIR + "/m1"), "mounted 300000", "a new mount meanwhile");
	for(; pids != nil; pids = tl pids)
		kill(hd pids);
	fd = nil;
	c := chan[1] of string;
	spawn drain(sfd, c);
	sfd = nil;
	spawn timer(c, 5000);
	t.assertseq(<-c, "end of file", "a connection closed with a read in its pipe is closed at its server's end");
	sys->unmount(nil, DIR + "/m1");
	pd.end();
}

twrite(fd: ref Sys->FD): string
{
	pidc := chan of int;
	res := chan[1] of string;
	spawn writer(fd, 100, pidc, res);
	<-pidc;
	spawn timer(res, 5000);
	return <-res;
}

testServerGone(t: ref T)
{
	# the first connection's server closes its end at once
	pd := mkpost(t, 1);
	fd := sys->open(pd.file, Sys->ORDWR);
	t.assert(fd != nil, sys->sprint("open of the posted file: %r"));
	t.assertseq(twrite(fd), "written", "a write makes the connection");
	sfd := <-pd.held;
	sfd = nil;
	sys->sleep(100);
	for(i := 0; i < 3; i++){
		r := twrite(fd);
		t.assert(r != "TIMEOUT" && r != "written", "a write to a connection its server has closed is refused: " + r);
	}
	fd = nil;
	t.assertseq(tmount(pd.file, DIR + "/m1"), "mounted 300000", "and the post serves its next connection");
	sys->unmount(nil, DIR + "/m1");
	pd.end();
}

testNoSpec(t: ref T)
{
	conns := chan of ref Sys->FD;
	(p, e) := post9p->post("", conns);
	t.assert(p == nil && e != nil, "a post with no spec, which nobody could reach, is refused: " + e);
	if(p != nil)
		p.unpost();
	(p, e) = post9p->postas("", "fs", conns);
	t.assert(p == nil && e != nil, "and under a name of the caller's: " + e);
	if(p != nil)
		p.unpost();
}

testTwoMounts(t: ref T)
{
	pd := mkpost(t, 0);
	t.assertseq(tmount(pd.file, DIR + "/m1"), "mounted 300000", "one mount");
	t.assertseq(tmount(pd.file, DIR + "/m2"), "mounted 300000", "and another");
	c := chan[16] of string;
	for(i := 0; i < 8; i++){
		spawn readall(DIR + "/m1/big", c);
		spawn readall(DIR + "/m2/big", c);
	}
	spawn timer(c, 20000);
	ok := 0;
	bad := "";
	for(i = 0; i < 16; i++){
		r := <-c;
		if(r == WHOLE)
			ok++;
		else{
			bad = r;
			if(r == "TIMEOUT")
				break;
		}
	}
	t.asserteq(ok, 16, "sixteen readers at once through two connections each read the file whole: " + bad);
	sys->unmount(nil, DIR + "/m1");
	t.assertseq(tread(DIR + "/m2/big"), WHOLE, "one unmounted, the other reads on");
	sys->unmount(nil, DIR + "/m2");
	pd.end();
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
	post9p = load Post9p Post9p->PATH;
	if(post9p == nil){
		sys->fprint(sys->fildes(2), "cannot load post9p: %r\n");
		raise "fail:cannot load post9p";
	}
	post9p->init();

	sys->pctl(Sys->FORKNS, nil);
	dirs := array[] of {"", "/tree", "/m1", "/m2", "/m3"};
	for(i := 0; i < len dirs; i++)
		sys->create(DIR + dirs[i], Sys->OREAD, Sys->DMDIR|8r755);
	fd := sys->create(DIR + "/tree/big", Sys->OWRITE, 8r644);
	buf := array[SIZE] of byte;
	for(i = 0; i < SIZE; i++)
		buf[i] = byte (i % 251);
	if(fd == nil || sys->write(fd, buf, len buf) != len buf){
		sys->fprint(sys->fildes(2), "cannot make %s/tree/big: %r\n", DIR);
		raise "fail:setup";
	}
	fd = nil;

	run("SixReads", testSixReads);
	run("StuckWrites", testStuckWrites);
	run("ManyReads", testManyReads);
	run("ServerGone", testServerGone);
	run("NoSpec", testNoSpec);
	run("TwoMounts", testTwoMounts);

	sys->remove(DIR + "/tree/big");
	for(i = len dirs - 1; i >= 0; i--)
		sys->remove(DIR + dirs[i]);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

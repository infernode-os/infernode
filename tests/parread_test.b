implement ParreadTest;

#
# parread(2): a buffer read as several preads of contiguous pieces at
# once.  The bytes are the file's, in place, for every number of ways
# and offset; a file shorter than the buffer gives what it has; the
# reads are in flight together (a server that holds each read counts
# them); a piece refused gives its error and the bytes before it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "parread.m";
	parread: Parread;
include "testing.m";
	testing: Testing;
	T: import testing;

ParreadTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/parread_test.b";
FILE: con "/tmp/parread_test.dat";
SIZE: con 300000;

passed := 0;
failed := 0;
skipped := 0;
data: array of byte;

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

same(b: array of byte, off: int): int
{
	for(i := 0; i < len b; i++)
		if(b[i] != data[off+i])
			return 0;
	return 1;
}

testBytes(t: ref T)
{
	fd := sys->open(FILE, Sys->OREAD);
	for(ways := 1; ways <= 8; ways++)
		for(off := 0; off <= 12345; off += 12345){
			b := array[SIZE - off] of byte;
			(n, err) := parread->pread(fd, b, big off, ways);
			t.asserteq(n, len b, sys->sprint("ways %d at %d: every byte", ways, off));
			t.assertnil(err, "and no error");
			t.assert(same(b[0:n], off), sys->sprint("ways %d at %d: the file's bytes, in place", ways, off));
		}
}

testShort(t: ref T)
{
	fd := sys->open(FILE, Sys->OREAD);
	b := array[100000] of byte;
	(n, err) := parread->pread(fd, b, big (SIZE - 30000), 4);
	t.asserteq(n, 30000, "a buffer past the end gets what the file has");
	t.assertnil(err, "and no error");
	t.assert(same(b[0:n], SIZE - 30000), "the file's bytes");
}

# a file whose reads are each held HOLDMS before they are answered,
# counting how many are waiting at once; a read at REFUSE is refused
HOLDMS: con 100;
REFUSE: con 3*65536;
inflight := 0;
most := 0;

holdsrv(fio: ref Sys->FileIO, lock: chan of int)
{
	for(;;) alt {
	(off, nbytes, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		spawn answer(off, nbytes, rc, lock);
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "no writes");
	}
}

answer(off, nbytes: int, rc: chan of (array of byte, string), lock: chan of int)
{
	<-lock;
	inflight++;
	if(inflight > most)
		most = inflight;
	lock <-= 1;
	sys->sleep(HOLDMS);
	<-lock;
	inflight--;
	lock <-= 1;
	if(off == REFUSE){
		rc <-= (nil, "refused here");
		return;
	}
	if(off >= SIZE){
		rc <-= (nil, nil);
		return;
	}
	e := off + nbytes;
	if(e > SIZE)
		e = SIZE;
	rc <-= (data[off:e], nil);
}

testInFlight(t: ref T)
{
	sys->bind("#s", "/chan", Sys->MBEFORE);
	fio := sys->file2chan("/chan", "parread_test");
	if(fio == nil){
		t.skip(sys->sprint("file2chan: %r"));
		return;
	}
	lock := chan[1] of int;
	lock <-= 1;
	spawn holdsrv(fio, lock);
	fd := sys->open("/chan/parread_test", Sys->OREAD);
	b := array[4*65536] of byte;
	most = 0;
	t0 := sys->millisec();
	(n, err) := parread->pread(fd, b, big 0, 1);
	one := sys->millisec() - t0;
	t.asserteq(most, 1, "one way: one read at a time");
	most = 0;
	t0 = sys->millisec();
	(n, err) = parread->pread(fd, b[0:3*65536], big 0, 3);
	three := sys->millisec() - t0;
	t.log(sys->sprint("one way %d ms, three %d ms, most in flight %d", one, three, most));
	t.asserteq(n, 3*65536, "three ways: every byte");
	t.assertnil(err, "and no error");
	t.assert(same(b[0:n], 0), "the file's bytes");
	t.assert(most >= 3, sys->sprint("three ways: three reads in flight at once (%d)", most));
	# a piece refused: its error, and only the bytes before it
	(n, err) = parread->pread(fd, b, big 0, 4);
	t.asserteq(n, REFUSE, "a piece refused: the bytes before it");
	t.assertseq(err, "refused here", "and its error");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	parread = load Parread Parread->PATH;
	if(parread == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Parread->PATH);
		raise "fail:load";
	}
	data = array[SIZE] of byte;
	for(i := 0; i < SIZE; i++)
		data[i] = byte (i*7 + i/251);
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR|8r777);	# a fresh tree has none
	fd := sys->create(FILE, Sys->OWRITE, 8r666);
	sys->write(fd, data, len data);
	fd = nil;
	run("Bytes", testBytes);
	run("Short", testShort);
	run("InFlight", testInFlight);
	sys->remove(FILE);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

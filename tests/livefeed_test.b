implement LivefeedTest;

#
# livefeed(2) against a feed of its own (file2chan): status read for the
# newest frame, and an unreadable or malformed status giving -1; the
# edge advancing by the clock at fmt's rate, a frame's due time from it,
# a reader more than a few frames behind it seeing so; the edge taken
# again (after "frame expired") from a status that moved, and a status
# read that fails changing nothing; a read answered "reply gone" sent
# again up to GONETRIES times and another error returned at once; a
# small buffer read in its pieces at once (all in flight together), the
# bytes in place, a refused piece giving the bytes before it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "livefeed.m";
	livefeed: Livefeed;
	Edge: import livefeed;
include "testing.m";
	testing: Testing;
	T: import testing;

LivefeedTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/livefeed_test.b";
FEED: con "/tmp/livefeed_test";

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

# what the fake feed answers, set by each test
statustext := "frames=100 first=40 eof=0";
statuserr := "";		# status read refused with this, if set
gone := 0;			# data reads to answer "reply gone" before the bytes
othererr := "";			# data reads answered with this, if set
datareads := 0;			# data reads asked
HOLDMS: con 100;
hold := 0;			# hold each data read this long
inflight := 0;
most := 0;
REFUSE := -1;			# a data read at this offset is refused
SIZE: con 9000;
data: array of byte;

statussrv(fio: ref Sys->FileIO)
{
	for(;;) alt {
	(off, nil, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		if(statuserr != nil){
			rc <-= (nil, statuserr);
			continue;
		}
		b := array of byte statustext;
		if(off >= len b)
			rc <-= (nil, nil);
		else
			rc <-= (b[off:], nil);
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "no writes");
	}
}

datasrv(fio: ref Sys->FileIO, lock: chan of int)
{
	for(;;) alt {
	(off, nbytes, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		<-lock;
		datareads++;
		g := 0;
		if(gone > 0){
			gone--;
			g = 1;
		}
		lock <-= 1;
		if(g){
			rc <-= (nil, "reply gone");
			continue;
		}
		if(othererr != nil){
			rc <-= (nil, othererr);
			continue;
		}
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
	if(hold)
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

setup(): string
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR|8r777);
	sys->create(FEED, Sys->OREAD, Sys->DMDIR|8r777);
	if(sys->bind("#s", FEED, Sys->MREPL) < 0)
		return sys->sprint("bind #s: %r");
	sfio := sys->file2chan(FEED, "status");
	dfio := sys->file2chan(FEED, "data");
	if(sfio == nil || dfio == nil)
		return sys->sprint("file2chan: %r");
	lock := chan[1] of int;
	lock <-= 1;
	spawn statussrv(sfio);
	spawn datasrv(dfio, lock);
	return nil;
}

testStatus(t: ref T)
{
	statustext = "frames=100 first=40 eof=0";
	statuserr = nil;
	(n, nil) := livefeed->status(FEED);
	t.asserteq(n, 99, "the newest is frames= less one");
	statustext = "w=640 frames=0 first=0";
	(n, nil) = livefeed->status(FEED);
	t.asserteq(n, 0, "nothing made yet: 0, the next");
	statustext = "w=640 h=360";
	(n, nil) = livefeed->status(FEED);
	t.asserteq(n, -1, "no frames= in it: -1");
	statustext = "frames=100 first=40";
	statuserr = "timed out";
	(n, nil) = livefeed->status(FEED);
	t.asserteq(n, -1, "a status read that fails: -1");
	(n, nil) = livefeed->status("/tmp/livefeed_test_none");
	t.asserteq(n, -1, "no feed there: -1");
	statuserr = nil;
}

testEdge(t: ref T)
{
	statustext = "frames=100 first=40";
	statuserr = nil;
	e := Edge.new(FEED, 30);
	if(e == nil)
		t.fatal("Edge.new: nil with a readable status");
	t.asserteq(e.lf, 99, "anchored at the newest");
	n0 := e.newest();
	t.assert(n0 >= 99 && n0 <= 100, sys->sprint("newest at once: about 99 (%d)", n0));
	d := e.due(99 + 30);
	t.assert(d > 900 && d <= 1000, sys->sprint("a frame 30 ahead is due in about a second (%d ms)", d));
	sys->sleep(500);
	n1 := e.newest();
	t.assert(n1 - 99 >= 13 && n1 - 99 <= 17, sys->sprint("half a second on, about 15 frames newer (%d)", n1 - 99));
	t.assert(e.due(99) < 0, "a frame made before is due already");
	# a reader that read frame 100 half a second ago is more than 3 behind
	t.assert(e.newest() - 101 > 3, "a reader left behind sees it is more than 3 frames behind");
	statuserr = "timed out";
	t.assert(Edge.new(FEED, 30) == nil, "no edge from a status that cannot be read");
	statuserr = nil;
}

testAgain(t: ref T)
{
	statustext = "frames=100 first=40";
	statuserr = nil;
	e := Edge.new(FEED, 30);
	if(e == nil)
		t.fatal("Edge.new: nil");
	statustext = "frames=500 first=440";
	t.asserteq(e.again(), 1, "taken again from a status that moved");
	t.asserteq(e.lf, 499, "the newest it names");
	(lf, lt) := (e.lf, e.lt);
	statuserr = "reply gone";
	t.asserteq(e.again(), 0, "a status read that fails: not taken");
	t.asserteq(e.lf, lf, "and the edge unchanged (not frame 0)");
	t.asserteq(e.lt, lt, "nor its time");
	e.set(-1, 0);
	t.asserteq(e.lf, lf, "set with no frame changes nothing");
	statuserr = nil;
}

# next: a reader whose frames come a steady lag behind the edge (the
# network's round trips) reads on; one fallen more than behind frames
# further back than that goes to that lag behind the edge
testNext(t: ref T)
{
	statustext = "frames=1000 first=900";
	statuserr = nil;
	e := Edge.new(FEED, 30);
	if(e == nil)
		t.fatal("Edge.new: nil");
	# five frames behind, steadily: reads on
	ok := 1;
	for(i := 0; i < 10; i++){
		f := e.newest() - 5;
		if(e.next(f, 3) != f + 1)
			ok = 0;
	}
	t.assert(ok, "a steady lag of five frames (more than three): reads on, frame after frame");
	# ten behind now: five further back than usual, more than three
	f := e.newest() - 10;
	n := e.next(f, 3);
	t.assert(n > f + 1, sys->sprint("ten behind: it skips (%d to %d)", f, n));
	t.assert(e.newest() - n >= 4 && e.newest() - n <= 6, sys->sprint("to its usual five behind the edge (%d)", e.newest() - n));
	# two further back than usual: within three, reads on
	f = e.newest() - 7;
	t.asserteq(e.next(f, 3), f + 1, "two further back than usual: reads on");
}

testGone(t: ref T)
{
	fd := sys->open(FEED + "/data", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open data: %r"));
	b := array[100] of byte;
	othererr = nil;
	hold = 0;
	gone = Livefeed->GONETRIES - 1;
	datareads = 0;
	n := livefeed->pread(fd, b, len b, big 1000);
	t.asserteq(n, 100, sys->sprint("\"reply gone\" %d times, then the bytes", Livefeed->GONETRIES - 1));
	t.asserteq(datareads, Livefeed->GONETRIES, "each sent again");
	t.assert(b[0] == data[1000] && b[99] == data[1099], "the bytes at the offset");
	gone = Livefeed->GONETRIES;
	datareads = 0;
	n = livefeed->pread(fd, b, len b, big 1000);
	t.asserteq(n, -1, "\"reply gone\" every time: an error");
	t.assertseq(sys->sprint("%r"), "reply gone", "and it is that");
	t.asserteq(datareads, Livefeed->GONETRIES, "after GONETRIES tries, not more");
	gone = 0;
	othererr = "timed out";
	datareads = 0;
	n = livefeed->pread(fd, b, len b, big 1000);
	t.asserteq(n, -1, "another error: returned");
	t.assertseq(sys->sprint("%r"), "timed out", "as it was");
	t.asserteq(datareads, 1, "at once, not sent again");
	othererr = nil;
}

testPieces(t: ref T)
{
	fd := sys->open(FEED + "/data", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open data: %r"));
	othererr = nil;
	gone = 0;
	hold = 1;
	most = 0;
	b := array[SIZE] of byte;
	(n, err) := livefeed->read(fd, b, big 0, 8);
	t.asserteq(n, SIZE, "a 9000-byte frame in eight pieces: every byte");
	t.assertnil(err, "and no error");
	ok := 1;
	for(i := 0; i < SIZE; i++)
		if(b[i] != data[i])
			ok = 0;
	t.assert(ok, "the bytes in place");
	t.assert(most >= 8, sys->sprint("its eight pieces in flight at once, small as they are (%d)", most));
	# with reply gone once in the middle: still whole
	gone = 1;
	(n, err) = livefeed->read(fd, b, big 0, 8);
	t.asserteq(n, SIZE, "a piece answered \"reply gone\" once: still every byte");
	# a piece refused: its error and the bytes before it
	REFUSE = 3 * ((SIZE + 7) / 8);
	(n, err) = livefeed->read(fd, b, big 0, 8);
	t.asserteq(n, REFUSE, "a piece refused: the bytes before it");
	t.assertseq(err, "refused here", "and its error");
	REFUSE = -1;
	hold = 0;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	livefeed = load Livefeed Livefeed->PATH;
	if(livefeed == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Livefeed->PATH);
		raise "fail:load";
	}
	livefeed->init();
	sys->pctl(Sys->FORKNS, nil);
	data = array[SIZE] of byte;
	for(i := 0; i < SIZE; i++)
		data[i] = byte (i*7 + i/251);
	if((e := setup()) != nil){
		sys->fprint(sys->fildes(2), "livefeed_test: %s\n", e);
		raise "fail:skip:" + e;
	}
	run("Status", testStatus);
	run("Edge", testEdge);
	run("Again", testAgain);
	run("Next", testNext);
	run("Gone", testGone);
	run("Pieces", testPieces);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

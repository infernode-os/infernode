implement ExportHostileTest;

#
# export(2)'s 9P server (emu/port/exportfs.c, os/port/exportfs.c) spoken
# to by a client that is not a mount: messages a mount never sends, in
# orders it never sends them.  Each case has a connection of its own.
#  - a read before any Tversion is held to the request's own buffer (the
#    count was compared with msize-IOHDRSZ, msize 0: nothing was too big,
#    and the device read into 8K as much as was asked for)
#  - a Tversion raising msize sent in one write with the Tread after it:
#    the read's buffer is the size the Tversion set
#  - a walk refused for its name (a slash in it) leaves the fid usable
#    and clunkable (it stayed in use for good, its Chan with it)
#  - a fid past 2^31 can be clunked (it was stored as an int and never
#    found again)
#  - an open before Tversion reports an iounit a read can use
#  - requests on one fid sent together (attach and open; two walks that
#    keep the fid; two reads of a directory) are answered or refused,
#    and the fid works afterwards
#  - what a mount does still works: eight reads of one fid in flight,
#    create, write, remove
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "testing.m";
	testing: Testing;
	T: import testing;

ExportHostileTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/export_hostile_test.b";
DIR: con "/tmp/export_hostile_test";
BIGLEN: con 96*1024;
HIGHFID: con int 16r80000001;

bigdata: array of byte;
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

# DIR exported on a TCP connection over the loopback; the client's end
exported(t: ref T): ref Sys->FD
{
	(ok, ac) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0){
		t.fatal(sys->sprint("announce: %r"));
		return nil;
	}
	local := readfile(ac.dir + "/local");
	(nil, f) := sys->tokenize(local, "!\n");
	if(len f < 2){
		t.fatal("no local address: " + local);
		return nil;
	}
	ready := chan of string;
	spawn serve(ac, ready);
	(dok, c) := sys->dial("tcp!127.0.0.1!" + hd tl f, nil);
	if(dok < 0){
		t.fatal(sys->sprint("dial: %r"));
		return nil;
	}
	if((e := <-ready) != nil){
		t.fatal("export: " + e);
		return nil;
	}
	return c.dfd;
}

serve(ac: Sys->Connection, ready: chan of string)
{
	(ok, c) := sys->listen(ac);
	if(ok < 0){
		ready <-= sys->sprint("listen: %r");
		return;
	}
	dfd := sys->open(c.dir + "/data", Sys->ORDWR);
	if(dfd == nil){
		ready <-= sys->sprint("open data: %r");
		return;
	}
	if(sys->export(dfd, DIR, Sys->EXPASYNC) < 0){
		ready <-= sys->sprint("%r");
		return;
	}
	ready <-= nil;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

send(t: ref T, fd: ref Sys->FD, ms: array of ref Tmsg)
{
	n := 0;
	for(i := 0; i < len ms; i++)
		n += ms[i].packedsize();
	b := array[n] of byte;
	o := 0;
	for(i = 0; i < len ms; i++){
		p := ms[i].pack();
		b[o:] = p;
		o += len p;
	}
	if(sys->write(fd, b, len b) != len b)
		t.fatal(sys->sprint("write of %d messages: %r", len ms));
}

# a reply, or a failed test: the server must go on answering
recv(t: ref T, fd: ref Sys->FD, what: string): ref Rmsg
{
	r := Rmsg.read(fd, 1024*1024);
	if(r == nil){
		t.fatal("no reply (connection closed): " + what);
		return nil;
	}
	pick e := r {
	Readerror =>
		t.fatal("reply unreadable: " + what + ": " + e.error);
	}
	return r;
}

rpc(t: ref T, fd: ref Sys->FD, m: ref Tmsg): ref Rmsg
{
	send(t, fd, array[] of {m});
	return recv(t, fd, m.text());
}

ename(r: ref Rmsg): string
{
	pick e := r {
	Error =>
		return e.ename;
	}
	return nil;
}

# the reply must be of this kind
want(t: ref T, r: ref Rmsg, kind: int, what: string)
{
	if(r == nil || tagof r != kind)
		t.fatal(what + ": got " + r.text());
}

refused(t: ref T, r: ref Rmsg, why: string, what: string)
{
	e := ename(r);
	if(e == nil){
		t.error(what + ": not refused: " + r.text());
		return;
	}
	if(!contains(e, why))
		t.error(what + ": refused with \"" + e + "\", want \"" + why + "\"");
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# fid 1 the root, fid 2 the big file, open for reading
openbig(t: ref T, fd: ref Sys->FD): int
{
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "inferno", "")), tagof Rmsg.Attach, "attach");
	want(t, rpc(t, fd, ref Tmsg.Walk(2, 1, 2, array[] of {"big"})), tagof Rmsg.Walk, "walk to big");
	r := rpc(t, fd, ref Tmsg.Open(3, 2, Sys->OREAD));
	want(t, r, tagof Rmsg.Open, "open big");
	pick o := r {
	Open =>
		return o.iounit;
	}
	return -1;
}

samedata(d: array of byte, off: int): int
{
	if(off + len d > len bigdata)
		return 0;
	for(i := 0; i < len d; i++)
		if(d[i] != bigdata[off+i])
			return 0;
	return 1;
}

# the connection still serves: the root's stat through a new fid
alive(t: ref T, fd: ref Sys->FD, fid: int)
{
	want(t, rpc(t, fd, ref Tmsg.Walk(900, 1, fid, nil)), tagof Rmsg.Walk, "walk after");
	want(t, rpc(t, fd, ref Tmsg.Stat(901, fid)), tagof Rmsg.Stat, "stat after");
	want(t, rpc(t, fd, ref Tmsg.Clunk(902, fid)), tagof Rmsg.Clunk, "clunk after");
}

testNoVersionBigRead(t: ref T)
{
	fd := exported(t);
	iounit := openbig(t, fd);
	t.assert(iounit > 0 && iounit <= 8192, sys->sprint("iounit before a Tversion is one a read can use (%d)", iounit));
	# more than the 8K a request's buffer has before any Tversion
	r := rpc(t, fd, ref Tmsg.Read(4, 2, big 0, 65535));
	refused(t, r, "count too big", "read of 65535 before Tversion");
	# as much as the buffer has is fine
	r = rpc(t, fd, ref Tmsg.Read(5, 2, big 0, 8192));
	pick d := r {
	Read =>
		t.assert(len d.data == 8192 && samedata(d.data, 0), sys->sprint("a read of 8192 before Tversion gives the file's first 8192 (%d)", len d.data));
	* =>
		t.error("read of 8192 before Tversion: " + r.text());
	}
	alive(t, fd, 9);
}

testVersionThenRead(t: ref T)
{
	fd := exported(t);
	openbig(t, fd);
	# both in one write: the read's buffer is made after the Tversion is read
	send(t, fd, array[] of {
		ref Tmsg.Version(Styx->NOTAG, 24+65536, "9P2000"),
		ref Tmsg.Read(7, 2, big 4096, 65536),
	});
	rv := recv(t, fd, "Tversion");
	msize := 0;
	pick v := rv {
	Version =>
		msize = v.msize;
	* =>
		t.fatal("Tversion: " + rv.text());
	}
	t.assert(msize == 24+65536, sys->sprint("msize taken (%d)", msize));
	r := recv(t, fd, "Tread after Tversion");
	pick d := r {
	Read =>
		t.assert(len d.data == 65536 && samedata(d.data, 4096), sys->sprint("the read sent with the Tversion gives the file's bytes (%d)", len d.data));
	Error =>
		# refused is safe too, but the buffer should be the new size
		t.error("read sent with the Tversion refused: " + d.ename);
	* =>
		t.error("read sent with the Tversion: " + r.text());
	}
	# and a count past the new msize is refused
	refused(t, rpc(t, fd, ref Tmsg.Read(8, 2, big 0, 65537)), "count too big", "read past msize");
	alive(t, fd, 9);
}

testWalkBadName(t: ref T)
{
	fd := exported(t);
	want(t, rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000")), tagof Rmsg.Version, "version");
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "inferno", "")), tagof Rmsg.Attach, "attach");
	for(i := 0; i < 50; i++){
		r := rpc(t, fd, ref Tmsg.Walk(2, 1, 2, array[] of {"a/b"}));
		if(ename(r) == nil)
			t.fatal("walk to a name with a slash: " + r.text());
	}
	# the fid the refused walks started from is not held by them
	want(t, rpc(t, fd, ref Tmsg.Walk(3, 1, 2, array[] of {"sub"})), tagof Rmsg.Walk, "walk after refused walks");
	want(t, rpc(t, fd, ref Tmsg.Clunk(4, 2)), tagof Rmsg.Clunk, "clunk 2");
	want(t, rpc(t, fd, ref Tmsg.Clunk(5, 1)), tagof Rmsg.Clunk, "clunk 1");
	r := rpc(t, fd, ref Tmsg.Attach(6, 1, Styx->NOFID, "inferno", ""));
	t.assert(tagof r == tagof Rmsg.Attach, "fid 1 can be attached again once clunked: " + r.text());
	# a walk in place refused for its name leaves the fid where it was
	r = rpc(t, fd, ref Tmsg.Walk(7, 1, 1, array[] of {"sub", "x/y"}));
	t.assert(ename(r) != nil, "walk in place to a bad name refused: " + r.text());
	alive(t, fd, 9);
}

testHighFid(t: ref T)
{
	fd := exported(t);
	want(t, rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000")), tagof Rmsg.Version, "version");
	want(t, rpc(t, fd, ref Tmsg.Attach(1, HIGHFID, Styx->NOFID, "inferno", "")), tagof Rmsg.Attach, "attach of a fid past 2^31");
	r := rpc(t, fd, ref Tmsg.Stat(2, HIGHFID));
	t.assert(tagof r == tagof Rmsg.Stat, "a fid past 2^31 is found again: " + r.text());
	r = rpc(t, fd, ref Tmsg.Clunk(3, HIGHFID));
	t.assert(tagof r == tagof Rmsg.Clunk, "and can be clunked: " + r.text());
	r = rpc(t, fd, ref Tmsg.Attach(4, HIGHFID, Styx->NOFID, "inferno", ""));
	t.assert(tagof r == tagof Rmsg.Attach, "and attached again: " + r.text());
}

# requests on one fid sent together: answered or refused, never neither
testTogether(t: ref T)
{
	fd := exported(t);
	want(t, rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000")), tagof Rmsg.Version, "version");
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "inferno", "")), tagof Rmsg.Attach, "attach");

	# a fid attached and opened in one write
	for(i := 0; i < 200; i++){
		fid := 100+i;
		send(t, fd, array[] of {
			ref Tmsg.Attach(10, fid, Styx->NOFID, "inferno", ""),
			ref Tmsg.Open(11, fid, Sys->OREAD),
			ref Tmsg.Stat(12, fid),
		});
		for(j := 0; j < 3; j++)
			recv(t, fd, "attach, open and stat together");
		r := rpc(t, fd, ref Tmsg.Clunk(13, fid));
		if(tagof r != tagof Rmsg.Clunk)
			t.fatal("clunk after attach and open together: " + r.text());
	}

	# two walks that keep the fid, and one from it, in one write
	want(t, rpc(t, fd, ref Tmsg.Walk(20, 1, 2, nil)), tagof Rmsg.Walk, "clone");
	for(i = 0; i < 200; i++){
		ws := array[3] of ref Tmsg;
		ws[0] = ref Tmsg.Walk(21, 2, 2, array[] of {"sub"});
		ws[1] = ref Tmsg.Walk(22, 2, 2, array[] of {".."});
		ws[2] = ref Tmsg.Walk(23, 2, 3, array[] of {"sub"});
		send(t, fd, ws);
		got3 := 0;
		for(j := 0; j < 3; j++){
			r := recv(t, fd, "walks together");
			if(r.tag == 23 && tagof r == tagof Rmsg.Walk){
				pick w := r {
				Walk =>
					got3 = len w.qids == 1;
				}
			}
		}
		if(got3)
			want(t, rpc(t, fd, ref Tmsg.Clunk(24, 3)), tagof Rmsg.Clunk, "clunk of the fid walked to");
		# wherever fid 2 ended, it is a directory that can be statted
		r := rpc(t, fd, ref Tmsg.Stat(25, 2));
		if(tagof r != tagof Rmsg.Stat)
			t.fatal("stat after walks together: " + r.text());
		want(t, rpc(t, fd, ref Tmsg.Walk(26, 1, 2, nil)), tagof Rmsg.Error, "fid 2 is still in use");
		want(t, rpc(t, fd, ref Tmsg.Clunk(27, 2)), tagof Rmsg.Clunk, "clunk 2");
		want(t, rpc(t, fd, ref Tmsg.Walk(28, 1, 2, nil)), tagof Rmsg.Walk, "clone again");
	}

	# two reads of one directory in one write
	want(t, rpc(t, fd, ref Tmsg.Walk(30, 1, 4, nil)), tagof Rmsg.Walk, "clone for directory");
	want(t, rpc(t, fd, ref Tmsg.Open(31, 4, Sys->OREAD)), tagof Rmsg.Open, "open directory");
	for(i = 0; i < 100; i++){
		rs := array[2] of ref Tmsg;
		rs[0] = ref Tmsg.Read(32, 4, big 0, 4096);
		rs[1] = ref Tmsg.Read(33, 4, big 0, 4096);
		send(t, fd, rs);
		for(j := 0; j < 2; j++){
			r := recv(t, fd, "directory reads together");
			pick d := r {
			Read =>
				if(len d.data > 4096)
					t.fatal(sys->sprint("a directory read gave %d bytes for 4096", len d.data));
			Error =>
				;
			* =>
				t.fatal("directory read: " + r.text());
			}
		}
	}
	alive(t, fd, 9);
}

# what a mount does
testOrdinary(t: ref T)
{
	fd := exported(t);
	want(t, rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 24+16384, "9P2000")), tagof Rmsg.Version, "version");
	openbig(t, fd);
	# eight reads of the one fid in flight
	ms := array[8] of ref Tmsg;
	for(i := 0; i < len ms; i++)
		ms[i] = ref Tmsg.Read(40+i, 2, big (i*8192), 8192);
	send(t, fd, ms);
	for(i = 0; i < len ms; i++){
		r := recv(t, fd, "reads in flight");
		pick d := r {
		Read =>
			t.assert(len d.data == 8192 && samedata(d.data, (r.tag-40)*8192), sys->sprint("read %d of eight in flight is the file's bytes", r.tag-40));
		* =>
			t.error("one of eight reads in flight: " + r.text());
		}
	}
	# a whole directory, read to its end
	want(t, rpc(t, fd, ref Tmsg.Walk(50, 1, 5, nil)), tagof Rmsg.Walk, "clone");
	want(t, rpc(t, fd, ref Tmsg.Open(51, 5, Sys->OREAD)), tagof Rmsg.Open, "open root");
	off := 0;
	for(;;){
		r := rpc(t, fd, ref Tmsg.Read(52, 5, big off, 4096));
		n := -1;
		pick d := r {
		Read =>
			n = len d.data;
		}
		if(n < 0)
			t.fatal("directory read: " + r.text());
		if(n == 0)
			break;
		off += n;
	}
	t.assert(off > 0, "the root directory has entries");
	# create, write, read back, remove
	want(t, rpc(t, fd, ref Tmsg.Walk(60, 1, 6, nil)), tagof Rmsg.Walk, "clone");
	want(t, rpc(t, fd, ref Tmsg.Create(61, 6, "made", 8r664, Sys->ORDWR)), tagof Rmsg.Create, "create");
	data := array of byte "what a mount does\n";
	r := rpc(t, fd, ref Tmsg.Write(62, 6, big 0, data));
	pick w := r {
	Write =>
		t.asserteq(w.count, len data, "write count");
	* =>
		t.error("write: " + r.text());
	}
	r = rpc(t, fd, ref Tmsg.Read(63, 6, big 0, 100));
	pick d := r {
	Read =>
		t.assertseq(string d.data, string data, "read back");
	* =>
		t.error("read back: " + r.text());
	}
	want(t, rpc(t, fd, ref Tmsg.Remove(64, 6)), tagof Rmsg.Remove, "remove");
	(ok, nil) := sys->stat(DIR + "/made");
	t.assert(ok < 0, "the removed file is gone");
	r = rpc(t, fd, ref Tmsg.Stat(65, 6));
	refused(t, r, "no such fid", "the removed file's fid");
	# a remove refused still clunks its fid
	want(t, rpc(t, fd, ref Tmsg.Walk(66, 1, 7, array[] of {"sub"})), tagof Rmsg.Walk, "walk to sub");
	want(t, rpc(t, fd, ref Tmsg.Walk(67, 7, 8, array[] of {"inside"})), tagof Rmsg.Walk, "walk to sub/inside");
	r = rpc(t, fd, ref Tmsg.Remove(68, 7));
	t.assert(ename(r) != nil, "remove of a directory with a file in it refused: " + r.text());
	refused(t, rpc(t, fd, ref Tmsg.Stat(69, 7)), "no such fid", "the fid of a refused remove");
	want(t, rpc(t, fd, ref Tmsg.Stat(70, 8)), tagof Rmsg.Stat, "the file inside is still there");
	alive(t, fd, 9);
}

setup(): string
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->remove(DIR + "/made");
	sys->remove(DIR + "/sub/inside");
	sys->remove(DIR + "/sub");
	sys->remove(DIR + "/big");
	sys->remove(DIR);
	if(sys->create(DIR, Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		return sys->sprint("create %s: %r", DIR);
	if(sys->create(DIR + "/sub", Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		return sys->sprint("create %s/sub: %r", DIR);
	fd := sys->create(DIR + "/sub/inside", Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("create %s/sub/inside: %r", DIR);
	bigdata = array[BIGLEN] of byte;
	for(i := 0; i < len bigdata; i++)
		bigdata[i] = byte (i*7 + (i>>8));
	fd = sys->create(DIR + "/big", Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("create %s/big: %r", DIR);
	if(sys->write(fd, bigdata, len bigdata) != len bigdata)
		return sys->sprint("write %s/big: %r", DIR);
	return nil;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(styx == nil){
		sys->fprint(sys->fildes(2), "cannot load styx: %r\n");
		raise "fail:cannot load styx";
	}
	styx->init();
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	if((e := setup()) != nil){
		sys->fprint(sys->fildes(2), "export_hostile_test: %s\n", e);
		raise "fail:setup";
	}

	run("NoVersionBigRead", testNoVersionBigRead);
	run("VersionThenRead", testVersionThenRead);
	run("WalkBadName", testWalkBadName);
	run("HighFid", testHighFid);
	run("Together", testTogether);
	run("Ordinary", testOrdinary);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

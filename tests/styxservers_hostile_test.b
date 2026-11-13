implement StyxserversHostileTest;

#
# styxservers(2), the library most of the tree's file servers are made
# with, serving one directory with one file on a pipe, spoken to in raw
# Styx by a client that is not a mount:
#  - a request before any Tversion makes no fid: an attach was answered
#    "Tversion not seen" with its fid made all the same, and "in use"
#    ever after
#  - a Tversion refused for its size leaves the connection with no
#    version agreed (the default size was stored before the offer was
#    looked at, and every request after was served)
#  - readbytes and readstr given a count of ff ff ff ff, or one that
#    wraps offset+count, answer with what there is (a server that used
#    them without canread ended on the slice)
#  - a directory read at an offset past 2^31 gives nothing (cut to an
#    int, it gave the directory's first entries again)
#  - a walk or create to a name with a slash in it is refused, and the
#    new fid of a refused walk is not left behind
#  - a connection holds Styxservers->MAXFIDS fids and no more
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Navop: import styxservers;
include "testing.m";
	testing: Testing;
	T: import testing;

StyxserversHostileTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/styxservers_hostile_test.b";
Qroot, Qfile: con big iota;
CONTENT: con "twenty bytes of file\n";
BATCH: con 128;

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

dirof(path: big): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.uid = "t";
	d.gid = "t";
	d.muid = "t";
	if(path == Qroot){
		d.name = ".";
		d.qid = Sys->Qid(Qroot, 0, Sys->QTDIR);
		d.mode = Sys->DMDIR | 8r777;
	}else{
		d.name = "file";
		d.qid = Sys->Qid(Qfile, 0, Sys->QTFILE);
		d.mode = 8r666;
		d.length = big len CONTENT;
	}
	return d;
}

navigator(c: chan of ref Navop)
{
	for(;;){
		op := <-c;
		if(op == nil)
			return;
		pick m := op {
		Stat =>
			m.reply <-= (dirof(m.path), nil);
		Walk =>
			if(m.path == Qroot && m.name == "file")
				m.reply <-= (dirof(Qfile), nil);
			else if(m.name == "..")
				m.reply <-= (dirof(Qroot), nil);
			else
				m.reply <-= (nil, "file does not exist");
		Readdir =>
			if(m.path == Qroot && m.offset == 0 && m.count > 0)
				m.reply <-= (dirof(Qfile), nil);
			m.reply <-= (nil, nil);
		}
	}
}

# the server: the file is read with readbytes and no canread, as some are
serve(fd: ref Sys->FD, done: chan of int)
{
	navc := chan of ref Navop;
	spawn navigator(navc);
	(tc, srv) := Styxserver.new(fd, Navigator.new(navc), Qroot);
	fd = nil;
	for(;;){
		gm := <-tc;
		if(gm == nil)
			break;
		pick m := gm {
		Readerror =>
			navc <-= nil;
			done <-= 1;
			return;
		Read =>
			c := srv.getfid(m.fid);
			if(c != nil && c.isopen && c.path == Qfile)
				srv.reply(styxservers->readbytes(m, array of byte CONTENT));
			else
				srv.default(gm);
		Create =>
			(nil, nil, nil, err) := srv.cancreate(m);
			if(err == nil)
				err = "created (not really)";
			srv.reply(ref Rmsg.Error(m.tag, err));
		* =>
			srv.default(gm);
		}
	}
	navc <-= nil;
	done <-= 1;
}

# a server on one end of a pipe; the other end, and what says it ended
served(t: ref T): (ref Sys->FD, chan of int)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	done := chan[1] of int;
	spawn serve(p[1], done);
	return (p[0], done);
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

recv(t: ref T, fd: ref Sys->FD, what: string): ref Rmsg
{
	r := Rmsg.read(fd, 64*1024);
	if(r == nil){
		t.fatal("no reply (the server ended): " + what);
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

version(t: ref T, fd: ref Sys->FD)
{
	want(t, rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000")), tagof Rmsg.Version, "version");
}

# fid 1 the root, fid 2 the file open for reading
openfile(t: ref T, fd: ref Sys->FD)
{
	version(t, fd);
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "t", "")), tagof Rmsg.Attach, "attach");
	want(t, rpc(t, fd, ref Tmsg.Walk(2, 1, 2, array[] of {"file"})), tagof Rmsg.Walk, "walk to file");
	want(t, rpc(t, fd, ref Tmsg.Open(3, 2, Sys->OREAD)), tagof Rmsg.Open, "open file");
}

testBeforeVersion(t: ref T)
{
	(fd, nil) := served(t);
	refused(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "t", "")), "Tversion not seen", "attach before Tversion");
	version(t, fd);
	r := rpc(t, fd, ref Tmsg.Attach(2, 1, Styx->NOFID, "t", ""));
	t.assert(tagof r == tagof Rmsg.Attach, "the fid of the refused attach is free after the Tversion: " + r.text());
}

testVersionRefused(t: ref T)
{
	(fd, nil) := served(t);
	r := rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 100, "9P2000"));
	t.assert(ename(r) != nil, "a Tversion offering 100 bytes is refused: " + r.text());
	refused(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "t", "")), "Tversion not seen", "attach after a refused Tversion");
	r = rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P1999"));
	pick v := r {
	Version =>
		t.assertseq(v.version, "unknown", "a version not known is answered unknown");
	* =>
		t.error("Tversion 9P1999: " + r.text());
	}
	refused(t, rpc(t, fd, ref Tmsg.Attach(2, 1, Styx->NOFID, "t", "")), "Tversion not seen", "attach after an unknown version");
	version(t, fd);
	want(t, rpc(t, fd, ref Tmsg.Attach(3, 1, Styx->NOFID, "t", "")), tagof Rmsg.Attach, "attach once a version is agreed");
}

readlen(t: ref T, fd: ref Sys->FD, fid: int, off: big, count: int, what: string): int
{
	r := rpc(t, fd, ref Tmsg.Read(9, fid, off, count));
	pick d := r {
	Read =>
		return len d.data;
	}
	t.error(what + ": " + r.text());
	return -1;
}

testReadCounts(t: ref T)
{
	(fd, nil) := served(t);
	openfile(t, fd);
	t.asserteq(readlen(t, fd, 2, big 0, 100, "read"), len CONTENT, "a read of the file");
	t.asserteq(readlen(t, fd, 2, big 0, -1, "read with a count of -1"), 0, "a read with a count of -1");
	t.asserteq(readlen(t, fd, 2, big 5, 16r7fffffff, "read with a count that wraps"), len CONTENT - 5, "a read with a count that wraps the sum");
	t.asserteq(readlen(t, fd, 2, (big 1 << 32), 10, "read past 2^32"), 0, "a read at an offset past 2^32");
	t.asserteq(readlen(t, fd, 2, big 3, 4, "read"), 4, "the server still reads");
}

testDirOffset(t: ref T)
{
	(fd, nil) := served(t);
	version(t, fd);
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "t", "")), tagof Rmsg.Attach, "attach");
	want(t, rpc(t, fd, ref Tmsg.Open(2, 1, Sys->OREAD)), tagof Rmsg.Open, "open root");
	n := readlen(t, fd, 1, big 0, 4096, "directory read");
	t.assert(n > 0, "the directory has an entry");
	t.asserteq(readlen(t, fd, 1, big n, 4096, "directory read at its end"), 0, "a read at the directory's end");
	t.asserteq(readlen(t, fd, 1, (big 1 << 31), 4096, "directory read past 2^31"), 0, "a directory read at an offset past 2^31");
	t.asserteq(readlen(t, fd, 1, (big 1 << 32), 4096, "directory read at 2^32"), 0, "a directory read at an offset of 2^32");
	t.asserteq(readlen(t, fd, 1, big 0, 4096, "directory read again"), n, "the directory read again from 0");
}

testNames(t: ref T)
{
	(fd, nil) := served(t);
	version(t, fd);
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "t", "")), tagof Rmsg.Attach, "attach");
	refused(t, rpc(t, fd, ref Tmsg.Walk(2, 1, 2, array[] of {"a/b"})), "bad character", "walk to a name with a slash");
	refused(t, rpc(t, fd, ref Tmsg.Walk(3, 1, 2, array[] of {"file", "../x"})), "bad character", "walk whose second name has a slash");
	refused(t, rpc(t, fd, ref Tmsg.Walk(4, 1, 2, array[] of {""})), "bad character", "walk to an empty name");
	want(t, rpc(t, fd, ref Tmsg.Walk(5, 1, 2, array[] of {"file"})), tagof Rmsg.Walk, "the new fid of the refused walks is free");
	refused(t, rpc(t, fd, ref Tmsg.Create(6, 1, "x/y", 8r666, Sys->OWRITE)), "bad character", "create of a name with a slash");
	refused(t, rpc(t, fd, ref Tmsg.Create(7, 1, "plain", 8r666, Sys->OWRITE)), "created", "create of a plain name gets as far as the server");
}

testFidLimit(t: ref T)
{
	(fd, nil) := served(t);
	version(t, fd);
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "t", "")), tagof Rmsg.Attach, "attach");
	max := Styxservers->MAXFIDS;
	total := max + 40;	# fid 1 is one of them
	ok := 0;
	toomany := 0;
	other := 0;
	for(i := 0; i < total; i += BATCH){
		m := total - i;
		if(m > BATCH)
			m = BATCH;
		ms := array[m] of ref Tmsg;
		for(j := 0; j < m; j++)
			ms[j] = ref Tmsg.Walk(j, 1, 10+i+j, nil);
		send(t, fd, ms);
		for(j = 0; j < m; j++){
			r := recv(t, fd, "walks");
			e := ename(r);
			if(e == nil)
				ok++;
			else if(contains(e, "too many fids"))
				toomany++;
			else
				other++;
		}
	}
	t.asserteq(ok, max-1, "fids made by walks, with the attach's one");
	t.asserteq(toomany, total-(max-1), "walks refused as too many fids");
	t.asserteq(other, 0, "walks refused otherwise");
	want(t, rpc(t, fd, ref Tmsg.Clunk(1, 10)), tagof Rmsg.Clunk, "clunk one");
	want(t, rpc(t, fd, ref Tmsg.Walk(2, 1, 10, nil)), tagof Rmsg.Walk, "one clunked makes room for one");
	refused(t, rpc(t, fd, ref Tmsg.Walk(3, 1, 5, nil)), "too many fids", "and no more");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || styx == nil || styxservers == nil){
		sys->fprint(sys->fildes(2), "cannot load testing, styx or styxservers: %r\n");
		raise "fail:load";
	}
	styx->init();
	styxservers->init(styx);
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("BeforeVersion", testBeforeVersion);
	run("VersionRefused", testVersionRefused);
	run("ReadCounts", testReadCounts);
	run("DirOffset", testDirOffset);
	run("Names", testNames);
	run("FidLimit", testFidLimit);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

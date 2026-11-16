implement NinepNulTest;

#
# A 9P string with a NUL in it (lib9's convM2S and convM2D, libkern's
# for the native kernels): it is two strings, the one C reads, up to
# the NUL, and the one a reader that keeps the count has, and the
# kernel took the first.
#
# - The export server (export(2)) spoken to in raw Styx: a Twalk to
#   "sub", NUL, "x" is not walked (it was a walk to "sub"); a Twstat
#   renaming a file to "bug", NUL, "zz" is refused and the file keeps
#   its name (it was renamed "bug").
# - The mount driver with a server of the test's own: a stat whose
#   answer names the file "na", NUL, "me" fails (it was the file "na"),
#   a directory whose entry is so named does not list (it listed
#   "fi"), and the mount goes on working.
#
# And a Dir that is no stat (convD2M, sizeD2M): a wstat whose name does
# not fit a stat's 16-bit size is refused, at any length, and the file
# keeps its name.
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

NinepNulTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ninep_nul_test.b";
DIR: con "/tmp/ninep_nul_test";
MNT: con "/n/client";

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

# the first Z in b becomes a NUL
nul(b: array of byte): array of byte
{
	for(i := 0; i < len b; i++)
		if(b[i] == byte 'Z'){
			b[i] = byte 0;
			break;
		}
	return b;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
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

# a reply to bytes written as they are; nil if the server hung up
raw(t: ref T, fd: ref Sys->FD, b: array of byte): ref Rmsg
{
	if(sys->write(fd, b, len b) != len b)
		t.fatal(sys->sprint("write: %r"));
	r := Rmsg.read(fd, 65536);
	if(r == nil)
		return nil;
	pick e := r {
	Readerror =>
		return nil;
	}
	return r;
}

rpc(t: ref T, fd: ref Sys->FD, m: ref Tmsg, kind: int): ref Rmsg
{
	r := raw(t, fd, m.pack());
	if(r == nil)
		t.fatal("no reply to " + m.text());
	if(tagof r != kind)
		t.fatal(m.text() + ": got " + r.text());
	return r;
}

begin(t: ref T): ref Sys->FD
{
	fd := exported(t);
	rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000"), tagof Rmsg.Version);
	rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "inferno", ""), tagof Rmsg.Attach);
	return fd;
}

testExportWalk(t: ref T)
{
	fd := begin(t);
	# the walk itself, as a client that means it sends it
	rpc(t, fd, ref Tmsg.Walk(2, 1, 2, array[] of {"sub"}), tagof Rmsg.Walk);
	rpc(t, fd, ref Tmsg.Clunk(3, 2), tagof Rmsg.Clunk);
	r := raw(t, fd, nul((ref Tmsg.Walk(4, 1, 2, array[] of {"subZx"})).pack()));
	if(r != nil){
		pick w := r {
		Walk =>
			t.error(sys->sprint("a walk to \"sub\\0x\" walked %d names", len w.qids));
		* =>
			;	# an error will do
		}
	}
	# and another connection is served
	fd = begin(t);
	rpc(t, fd, ref Tmsg.Walk(2, 1, 2, array[] of {"sub"}), tagof Rmsg.Walk);
}

testExportWstat(t: ref T)
{
	fd := begin(t);
	rpc(t, fd, ref Tmsg.Walk(2, 1, 2, array[] of {"file"}), tagof Rmsg.Walk);
	d := sys->nulldir;
	d.name = "bugZzz";
	r := raw(t, fd, nul((ref Tmsg.Wstat(3, 2, d)).pack()));
	if(r != nil){
		pick w := r {
		Wstat =>
			t.error("a wstat to the name \"bug\\0zz\" was done");
		* =>
			;
		}
	}
	(ok, nil) := sys->stat(DIR + "/bug");
	t.assert(ok < 0, "the file has not been renamed \"bug\"");
	(ok, nil) = sys->stat(DIR + "/file");
	t.assert(ok == 0, "and is still \"file\"");
	if(r != nil){
		# the connection goes on: a rename that is one
		d.name = "other";
		rpc(t, fd, ref Tmsg.Wstat(4, 2, d), tagof Rmsg.Wstat);
		(ok, nil) = sys->stat(DIR + "/other");
		t.assert(ok == 0, "a wstat to the name \"other\" renames it");
	}
}

#
# the mount driver: a server whose root holds "good" and a file whose
# name, as the server gives it, has a NUL in it
#
Qroot, Qgood, Qbad: con iota;

dirof(q: int): Sys->Dir
{
	d := sys->zerodir;
	d.uid = "none";
	d.gid = "none";
	d.muid = "none";
	case q {
	Qroot =>
		d.name = "/";
		d.qid = Sys->Qid(big Qroot, 0, Sys->QTDIR);
		d.mode = Sys->DMDIR | 8r555;
	Qgood =>
		d.name = "good";
		d.qid = Sys->Qid(big Qgood, 0, Sys->QTFILE);
		d.mode = 8r444;
	Qbad =>
		d.name = "naZme";	# the Z goes out as a NUL
		d.qid = Sys->Qid(big Qbad, 0, Sys->QTFILE);
		d.mode = 8r444;
	}
	return d;
}

# The server's fids, by number.  They were kept in sixty-four places by
# the number's remainder: the mount driver's fids are the kernel's, so
# after enough mounts elsewhere (the suite's tests before this one) a
# walk's new fid fell on the root's place and its clunk forgot the root.
Fids: adt {
	l:	list of (int, int);
	get:	fn(f: self ref Fids, fid: int): int;
	set:	fn(f: self ref Fids, fid: int, q: int);
};

Fids.get(f: self ref Fids, fid: int): int
{
	for(l := f.l; l != nil; l = tl l){
		(n, q) := hd l;
		if(n == fid)
			return q;
	}
	return -1;
}

Fids.set(f: self ref Fids, fid: int, q: int)
{
	nl: list of (int, int);
	for(l := f.l; l != nil; l = tl l){
		(n, nil) := hd l;
		if(n != fid)
			nl = hd l :: nl;
	}
	if(q >= 0)
		nl = (fid, q) :: nl;
	f.l = nl;
}

server(fd: ref Sys->FD, listbad: int)
{
	fids := ref Fids;
	for(;;){
		m := Tmsg.read(fd, 8192);
		if(m == nil)
			break;
		r: ref Rmsg;
		b: array of byte;
		pick x := m {
		Readerror =>
			return;
		Version =>
			r = ref Rmsg.Version(x.tag, 8192, "9P2000");
		Attach =>
			fids.set(x.fid, Qroot);
			r = ref Rmsg.Attach(x.tag, dirof(Qroot).qid);
		Walk =>
			q := fids.get(x.fid);
			qids := array[len x.names] of Sys->Qid;
			e := "";
			for(i := 0; i < len x.names; i++){
				if(q == Qroot && x.names[i] == "good")
					q = Qgood;
				else if(q == Qroot && x.names[i] == "bad")
					q = Qbad;
				else{
					e = "file does not exist";
					break;
				}
				qids[i] = dirof(q).qid;
			}
			if(e != nil && i == 0)
				r = ref Rmsg.Error(x.tag, e);
			else{
				if(i == len x.names)
					fids.set(x.newfid, q);
				r = ref Rmsg.Walk(x.tag, qids[0:i]);
			}
		Open =>
			r = ref Rmsg.Open(x.tag, dirof(fids.get(x.fid)).qid, 0);
		Read =>
			data := array[0] of byte;
			if(fids.get(x.fid) == Qroot && x.offset == big 0){
				data = styx->packdir(dirof(Qgood));
				if(listbad){
					bd := nul(styx->packdir(dirof(Qbad)));
					nd := array[len data + len bd] of byte;
					nd[0:] = data;
					nd[len data:] = bd;
					data = nd;
				}
			}
			r = ref Rmsg.Read(x.tag, data);
		Stat =>
			q := fids.get(x.fid);
			r = ref Rmsg.Stat(x.tag, dirof(q));
			if(q == Qbad)
				b = nul(r.pack());
		Clunk =>
			fids.set(x.fid, -1);
			r = ref Rmsg.Clunk(x.tag);
		Flush =>
			r = ref Rmsg.Flush(x.tag);
		* =>
			r = ref Rmsg.Error(x.tag, "not served");
		}
		if(b == nil)
			b = r.pack();
		if(sys->write(fd, b, len b) != len b)
			break;
	}
}

mounted(t: ref T, listbad: int)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	spawn server(p[0], listbad);
	p[0] = nil;
	if(sys->mount(p[1], nil, MNT, Sys->MREPL, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
}

names(t: ref T): (int, string)
{
	fd := sys->open(MNT, Sys->OREAD);
	if(fd == nil){
		t.error(sys->sprint("open %s: %r", MNT));
		return (-1, nil);
	}
	s := "";
	tot := 0;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n < 0)
			return (-1, s);
		if(n == 0)
			break;
		for(i := 0; i < n; i++)
			s += d[i].name + " ";
		tot += n;
	}
	return (tot, s);
}

testMountStat(t: ref T)
{
	mounted(t, 0);
	(ok, d) := sys->stat(MNT + "/good");
	t.assert(ok == 0 && d.name == "good", "the file \"good\" is found");
	(ok, d) = sys->stat(MNT + "/bad");
	t.assert(ok < 0, sys->sprint("a stat answered with the name \"na\\0me\" is the file \"%s\"", d.name));
	(ok, d) = sys->stat(MNT + "/good");
	t.assert(ok == 0 && d.name == "good", "and \"good\" is found after it");
	(n, s) := names(t);
	t.assert(n == 1 && s == "good ", sys->sprint("the directory lists \"good\" (%d: %s)", n, s));
	sys->unmount(nil, MNT);
}

testMountDir(t: ref T)
{
	mounted(t, 1);
	(n, s) := names(t);
	t.assert(n < 0, sys->sprint("a directory with an entry named \"na\\0me\" lists %d: %s", n, s));
	(ok, d) := sys->stat(MNT + "/good");
	t.assert(ok == 0 && d.name == "good", "and \"good\" is found after it");
	sys->unmount(nil, MNT);
}

testWstatLong(t: ref T)
{
	lens := array[] of {65480, 65488, 65489, 65536, 70000, 131072+10, 300000};
	for(i := 0; i < len lens; i++){
		name := "";
		while(len name < lens[i])
			name += "nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn";
		d := sys->nulldir;
		d.name = name[0:lens[i]];
		r := sys->wstat(DIR + "/file", d);
		t.assert(r < 0, sys->sprint("a wstat to a name of %d bytes is refused", lens[i]));
		if(lens[i] <= 65488)
			continue;	# a stat it fits: the device's to refuse
		d = sys->nulldir;
		d.uid = name[0:lens[i]];
		r = sys->wstat(DIR + "/file", d);
		t.assert(r < 0, sys->sprint("a wstat to an owner of %d bytes is refused", lens[i]));
	}
	(ok, nil) := sys->stat(DIR + "/file");
	t.assert(ok == 0, "and the file is still \"file\"");
	fd := sys->open(DIR + "/file", Sys->OREAD);
	if(fd != nil){
		name := "";
		while(len name < 70000)
			name += "nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn";
		d := sys->nulldir;
		d.name = name;
		t.assert(sys->fwstat(fd, d) < 0, "an fwstat to a name of 70000 bytes is refused");
	}
}

setup(): string
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->remove(DIR + "/sub");
	sys->remove(DIR + "/file");
	sys->remove(DIR + "/bug");
	sys->remove(DIR + "/other");
	sys->remove(DIR);
	if(sys->create(DIR, Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		return sys->sprint("create %s: %r", DIR);
	if(sys->create(DIR + "/sub", Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		return sys->sprint("create %s/sub: %r", DIR);
	if(sys->create(DIR + "/file", Sys->OWRITE, 8r666) == nil)
		return sys->sprint("create %s/file: %r", DIR);
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
	styx->init();
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	e := setup();
	if(e != nil){
		sys->fprint(sys->fildes(2), "ninep_nul_test: %s\n", e);
		raise "fail:setup";
	}
	run("ExportWalk", testExportWalk);
	run("ExportWstat", testExportWstat);
	setup();
	run("WstatLong", testWstatLong);
	run("MountStat", testMountStat);
	run("MountDir", testMountDir);
	setup();
	sys->remove(DIR + "/sub");
	sys->remove(DIR + "/file");
	sys->remove(DIR);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

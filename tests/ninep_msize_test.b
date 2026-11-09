implement NinepMsizeTest;

#
# 9P message sizes past 8K, through export(2) and the mount driver:
#  - exportfs offered a message size above 65544 (Linux's v9fs offers
#    512K; it takes at most 64K and the header) answers Tstat with the
#    stat: the room it gave a stat was the rest of the message, in
#    Fcall's 16-bit nstat, which wrapped, and every stat was "stat
#    buffer too small"
#  - a mount at the driver's own size (64K) stats and lists its
#    directory and reads a file whole (the same wrap broke the first two
#    when the mount offered IOHDRSZ+64K, against the exportfs every
#    machine was running)
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

NinepMsizeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ninep_msize_test.b";
DIR: con "/tmp/ninep_msize_test";

filedata: array of byte;
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
# returned.  Not a pipe: exportfs takes no more than its transport's
# unit, a pipe's 32K, and the wrap needs more than 65544
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
	ready := chan of int;
	spawn serve(ac, ready);
	(dok, c) := sys->dial("tcp!127.0.0.1!" + hd tl f, nil);
	if(dok < 0){
		t.fatal(sys->sprint("dial: %r"));
		return nil;
	}
	if(<-ready < 0){
		t.fatal(sys->sprint("export: %r"));
		return nil;
	}
	return c.dfd;
}

serve(ac: Sys->Connection, ready: chan of int)
{
	(ok, c) := sys->listen(ac);
	if(ok < 0){
		ready <-= -1;
		return;
	}
	dfd := sys->open(c.dir + "/data", Sys->ORDWR);
	if(dfd == nil || sys->export(dfd, DIR, Sys->EXPASYNC) < 0){
		ready <-= -1;
		return;
	}
	ready <-= 0;
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

rpc(t: ref T, fd: ref Sys->FD, m: ref Tmsg): ref Rmsg
{
	b := m.pack();
	if(sys->write(fd, b, len b) != len b){
		t.fatal(sys->sprint("write %s: %r", m.text()));
		return nil;
	}
	r := Rmsg.read(fd, 1024*1024);
	if(r == nil){
		t.fatal("no reply to " + m.text());
		return nil;
	}
	return r;
}

testLargeOffer(t: ref T)
{
	fd := exported(t);
	r := rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 1024*1024, "9P2000"));
	msize := 0;
	pick v := r {
	Version =>
		msize = v.msize;
	* =>
		t.fatal("Tversion: " + r.text());
	}
	t.log(sys->sprint("1M offered, %d taken", msize));
	t.assert(msize > 65544, sys->sprint("exportfs takes more than 65544 of a large offer (%d), where the wrap was", msize));
	r = rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "inferno", ""));
	if(tagof r != tagof Rmsg.Attach)
		t.fatal("Tattach: " + r.text());
	r = rpc(t, fd, ref Tmsg.Stat(2, 1));
	pick s := r {
	Stat =>
		t.assert(s.stat.qid.qtype & Sys->QTDIR, "the root's stat is a directory's");
	Error =>
		t.error("Tstat of the root at msize " + string msize + ": " + s.ename);
	* =>
		t.error("Tstat: " + r.text());
	}
	r = rpc(t, fd, ref Tmsg.Walk(3, 1, 2, array[] of {"f"}));
	if(tagof r != tagof Rmsg.Walk)
		t.fatal("Twalk: " + r.text());
	r = rpc(t, fd, ref Tmsg.Stat(4, 2));
	pick s := r {
	Stat =>
		t.asserteq(int s.stat.length, 200000, "a file's stat at that size");
	* =>
		t.error("Tstat of f: " + r.text());
	}
}

testMount(t: ref T)
{
	fd := exported(t);
	mnt := DIR + ".mnt";
	sys->create(mnt, Sys->OREAD, Sys->DMDIR|8r777);
	if(sys->mount(fd, nil, mnt, Sys->MREPL, nil) < 0){
		t.fatal(sys->sprint("mount: %r"));
		return;
	}
	(ok, d) := sys->stat(mnt);
	t.assert(ok >= 0, sys->sprint("the mount's root stats: %r"));
	t.assert(ok >= 0 && (d.qid.qtype & Sys->QTDIR), "as a directory");
	dfd := sys->open(mnt, Sys->OREAD);
	(n, dirs) := sys->dirread(dfd);
	t.assert(n == 1 && dirs[0].name == "f", sys->sprint("its directory lists f (%d entries)", n));
	ffd := sys->open(mnt + "/f", Sys->OREAD);
	if(ffd == nil){
		t.fatal(sys->sprint("open f: %r"));
		return;
	}
	buf := array[len filedata] of byte;
	k := 0;
	while(k < len buf && (m := sys->read(ffd, buf[k:], len buf - k)) > 0)
		k += m;
	t.asserteq(k, len filedata, "the file read whole through the mount");
	same := k == len filedata;
	for(i := 0; same && i < k; i++)
		same = buf[i] == filedata[i];
	t.assert(same, "and its bytes are the file's");
	sys->unmount(nil, mnt);
	sys->remove(mnt);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	styx->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR|8r777);
	fd := sys->create(DIR + "/f", Sys->OWRITE, 8r666);
	filedata = array[200000] of byte;
	for(i := 0; i < len filedata; i++)
		filedata[i] = byte (i % 251);
	sys->write(fd, filedata, len filedata);
	fd = nil;
	run("LargeOffer", testLargeOffer);
	run("Mount", testMount);
	sys->remove(DIR + "/f");
	sys->remove(DIR);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

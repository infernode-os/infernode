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
#  - eight readers at once through one encrypted mount at 64K
#    (devssl, aes_256_cbc and sha256, as mount -C sets it) each read the
#    file byte for byte: devssl wrote a reply longer than its record
#    limit (about 32K) as pieces locked one at a time, two of exportfs's
#    workers replying at once interleaved them, and replies reached the
#    wrong tags ("unexpected reply tag", "mnt: proc released ...
#    mismatch"), then the mount wedged
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
	ssl: SSL;
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
	return exportedalg(t, nil);
}

ALG: con "aes_256_cbc sha256";
SECRETA: array of byte;	# aes_256 wants a long secret; set in init
SECRETB: array of byte;

secret(seed: int): array of byte
{
	b := array[64] of byte;
	for(i := 0; i < len b; i++)
		b[i] = byte (seed + 7*i);
	return b;
}

# as exported(), with devssl pushed on both ends when alg is set
exportedalg(t: ref T, alg: string): ref Sys->FD
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
	spawn serve(ac, alg, ready);
	(dok, c) := sys->dial("tcp!127.0.0.1!" + hd tl f, nil);
	if(dok < 0){
		t.fatal(sys->sprint("dial: %r"));
		return nil;
	}
	if((e := <-ready) != nil){
		t.fatal("export: " + e);
		return nil;
	}
	if(alg == nil)
		return c.dfd;
	(fd, err) := pushssl(c.dfd, SECRETB, SECRETA, alg);
	if(fd == nil)
		t.fatal("client ssl: " + err);
	return fd;
}

pushssl(fd: ref Sys->FD, secretin, secretout: array of byte, alg: string): (ref Sys->FD, string)
{
	(err, c) := ssl->connect(fd);
	if(err != nil)
		return (nil, err);
	err = ssl->secret(c, secretin, secretout);
	if(err != nil)
		return (nil, err);
	if(sys->fprint(c.cfd, "alg %s", alg) < 0)
		return (nil, sys->sprint("alg %s: %r", alg));
	return (c.dfd, nil);
}

serve(ac: Sys->Connection, alg: string, ready: chan of string)
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
	if(alg != nil){
		err: string;
		(dfd, err) = pushssl(dfd, SECRETA, SECRETB, alg);
		if(dfd == nil){
			ready <-= "server ssl: " + err;
			return;
		}
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

NREADERS: con 8;

testEncryptedReaders(t: ref T)
{
	fd := exportedalg(t, ALG);
	(got, nil) := sys->fversion(fd, 65536, "9P2000");
	t.asserteq(got, 65536, "the encrypted connection takes 64K");
	mnt := DIR + ".enc";
	sys->create(mnt, Sys->OREAD, Sys->DMDIR|8r777);
	if(sys->mount(fd, nil, mnt, Sys->MREPL, nil) < 0){
		t.fatal(sys->sprint("mount: %r"));
		return;
	}
	done := chan of string;
	for(i := 0; i < NREADERS; i++)
		spawn readwhole(mnt + "/f", done);
	tick := chan of int;
	spawn timer(tick, 30000);
	ok := 0;
	for(i = 0; i < NREADERS; i++)
		alt {
		e := <-done =>
			if(e == nil)
				ok++;
			else
				t.error(e);
		<-tick =>
			t.error(sys->sprint("%d of %d readers not done after 30s", NREADERS - i, NREADERS));
			i = NREADERS;
		}
	t.asserteq(ok, NREADERS, "every reader read the file whole and right");
	sys->unmount(nil, mnt);
	sys->remove(mnt);
}

readwhole(f: string, done: chan of string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil){
		done <-= sys->sprint("open: %r");
		return;
	}
	buf := array[len filedata] of byte;
	k := 0;
	while(k < len buf && (m := sys->read(fd, buf[k:], len buf - k)) > 0)
		k += m;
	if(k != len filedata){
		done <-= sys->sprint("read %d of %d: %r", k, len filedata);
		return;
	}
	for(i := 0; i < k; i++)
		if(buf[i] != filedata[i]){
			done <-= sys->sprint("byte %d differs", i);
			return;
		}
	done <-= nil;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	ssl = load SSL SSL->PATH;
	SECRETA = secret(1);
	SECRETB = secret(101);
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
	run("EncryptedReaders", testEncryptedReaders);
	sys->remove(DIR + "/f");
	sys->remove(DIR);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

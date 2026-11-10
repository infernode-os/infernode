implement NinepDisconnectTest;

#
# Readers killed in the middle of their reads, through an encrypted 9P
# mount, round after round, as viewers of a feed come and go:
#  - export(2) serves a directory over TCP on the loopback with devssl
#    pushed (aes_256_cbc sha256, as mount -C and listen's connections
#    set it), as `listen ... {export dir}` serves a board's feed
#  - the directory holds a 1 MB file and a file2chan file, slow, whose
#    reads answer late, much later, or never, as a feed's do until its
#    next frame
#  - each round starts a few readers in a process group of their own,
#    each with several reads in flight (pread at different offsets), on
#    both files, and kills the group at a random moment: the mount
#    flushes what they had outstanding while replies are on their way
#  - then the same mount must still walk, stat and read the big file
#    byte for byte (a board's mount went out of step after many viewers
#    left: Rwalk "too many QIDs", "fid already in use"), and every few
#    rounds the connection itself is dropped and another made
#  - at the end no Prog is left over from the rounds
# -n rounds (default 60), -s seed.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
	ssl: SSL;
include "testing.m";
	testing: Testing;
	T: import testing;

NinepDisconnectTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ninep_disconnect_test.b";
DIR: con "/tmp/ninep_disconnect_test";
ALG: con "aes_256_cbc sha256";
BIGLEN: con 1024*1024;
PIECE: con 32*1024;

bigdata: array of byte;
SECRETA, SECRETB: array of byte;
rounds := 60;
seed := 1;
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

# a small linear congruential generator: the same rounds for a seed
rnd := 0;
rand(n: int): int
{
	rnd = rnd*1103515245 + 12345;
	return ((rnd >> 16) & 16r7fff) % n;
}

secret(seed: int): array of byte
{
	b := array[64] of byte;
	for(i := 0; i < len b; i++)
		b[i] = byte (seed + 7*i);
	return b;
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

pushssl(fd: ref Sys->FD, secretin, secretout: array of byte): (ref Sys->FD, string)
{
	(err, c) := ssl->connect(fd);
	if(err != nil)
		return (nil, err);
	err = ssl->secret(c, secretin, secretout);
	if(err != nil)
		return (nil, err);
	if(sys->fprint(c.cfd, "alg %s", ALG) < 0)
		return (nil, sys->sprint("alg %s: %r", ALG));
	return (c.dfd, nil);
}

# DIR exported over an encrypted TCP connection on the loopback; the
# client's end returned
connect(): (ref Sys->FD, string)
{
	(ok, ac) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		return (nil, sys->sprint("announce: %r"));
	(nil, f) := sys->tokenize(readfile(ac.dir + "/local"), "!\n");
	if(len f < 2)
		return (nil, "no local address");
	ready := chan of string;
	spawn serve(ac, ready);
	(dok, c) := sys->dial("tcp!127.0.0.1!" + hd tl f, nil);
	if(dok < 0)
		return (nil, sys->sprint("dial: %r"));
	if((e := <-ready) != nil)
		return (nil, "export: " + e);
	return pushssl(c.dfd, SECRETB, SECRETA);
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
	err: string;
	(dfd, err) = pushssl(dfd, SECRETA, SECRETB);
	if(dfd == nil){
		ready <-= "server ssl: " + err;
		return;
	}
	if(sys->export(dfd, DIR, Sys->EXPASYNC) < 0){
		ready <-= sys->sprint("%r");
		return;
	}
	ready <-= nil;
}

# slow's server: each read answered by a Prog of its own after 0-150 ms,
# after 2 s, or never; in a group of its own, killed at the end
slowsrv(io: ref Sys->FileIO, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	n := 0;
	for(;;) alt {
	(nil, count, nil, rc) := <-io.read =>
		if(rc == nil)
			continue;
		n++;
		case n % 10 {
		0 =>
			;	# never
		1 =>
			spawn answer(rc, count, 2000);
		* =>
			spawn answer(rc, count, (n*37) % 150);
		}
	(nil, nil, nil, wc) := <-io.write =>
		if(wc != nil)
			wc <-= (0, "read only");
	}
}

answer(rc: chan of (array of byte, string), count, ms: int)
{
	sys->sleep(ms);
	if(count > 4096)
		count = 4096;
	b := array[count] of {* => byte 'x'};
	alt {
	rc <-= (b, nil) =>
		;
	* =>
		;	# flushed: the reader is gone
	}
}

# a reader: k reads in flight on f at offsets spread through it, round
# and round until killed
reader(f: string, k: int)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return;
	for(i := 1; i < k; i++)
		spawn preader(fd, big (i*PIECE));
	preader(fd, big 0);
}

preader(fd: ref Sys->FD, off: big)
{
	buf := array[PIECE] of byte;
	for(;;){
		if(sys->pread(fd, buf, len buf, off) <= 0)
			off = big 0;
		else
			off += big (4*PIECE);
		if(off >= big BIGLEN)
			off = big 0;
	}
}

# the group's leader: its readers in a group of their own, its pid sent
readers(mnt: string, nbig, nslow, k: int, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	for(i := 0; i < nbig; i++)
		spawn reader(mnt + "/big", k);
	for(i = 0; i < nslow; i++)
		spawn reader(mnt + "/slow", k);
	for(;;)
		sys->sleep(10000);
}

killgrp(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

nprogs(): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	n := 0;
	for(;;){
		(k, nil) := sys->dirread(fd);
		if(k <= 0)
			break;
		n += k;
	}
	return n;
}

# the mount still answers, in step: walk, stat, and the big file whole
check(mnt: string): string
{
	(ok, d) := sys->stat(mnt + "/big");
	if(ok < 0)
		return sys->sprint("stat: %r");
	if(d.length != big BIGLEN)
		return sys->sprint("stat: length %bd", d.length);
	fd := sys->open(mnt + "/big", Sys->OREAD);
	if(fd == nil)
		return sys->sprint("open: %r");
	buf := array[BIGLEN] of byte;
	got := 0;
	while(got < BIGLEN && (n := sys->read(fd, buf[got:], BIGLEN - got)) > 0)
		got += n;
	if(got != BIGLEN)
		return sys->sprint("read %d of %d: %r", got, BIGLEN);
	for(i := 0; i < BIGLEN; i++)
		if(buf[i] != bigdata[i])
			return sys->sprint("byte %d differs", i);
	(nok, nil) := sys->stat(mnt + "/nonesuch");
	if(nok >= 0)
		return "a file that is not there was found";
	return nil;
}

# the check under a deadline: a wedged mount is a failure, not a hang
checktimed(mnt: string): string
{
	c := chan of string;
	spawn checker(mnt, c);
	tick := chan of int;
	pidc := chan of int;
	spawn timer(tick, 30000, pidc);
	tpid := <-pidc;
	alt {
	e := <-c =>
		kill(tpid);
		return e;
	<-tick =>
		return "the mount did not answer in 30 s";
	}
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

checker(mnt: string, c: chan of string)
{
	c <-= check(mnt);
}

timer(c: chan of int, ms: int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->sleep(ms);
	c <-= 1;
}

mountnew(mnt: string): string
{
	(fd, err) := connect();
	if(fd == nil)
		return err;
	if(sys->mount(fd, nil, mnt, Sys->MREPL, nil) < 0)
		return sys->sprint("mount: %r");
	return nil;
}

testKilledReaders(t: ref T)
{
	mnt := DIR + ".mnt";
	sys->create(mnt, Sys->OREAD, Sys->DMDIR|8r777);
	base := nprogs();
	if((e := mountnew(mnt)) != nil){
		t.fatal(e);
		return;
	}
	if((e = checktimed(mnt)) != nil){
		t.fatal("before any reader: " + e);
		return;
	}
	pidc := chan of int;
	reconnects := 0;
	for(r := 0; r < rounds; r++){
		nbig := 1 + rand(4);
		nslow := rand(3);
		k := 1 + rand(4);
		spawn readers(mnt, nbig, nslow, k, pidc);
		pid := <-pidc;
		sys->sleep(rand(80));
		killgrp(pid);
		if((e = checktimed(mnt)) != nil){
			t.error(sys->sprint("round %d (%d big, %d slow, %d in flight each), after the kill: %s", r, nbig, nslow, k, e));
			return;
		}
		if(rand(5) == 0){
			# drop the connection and make another
			sys->unmount(nil, mnt);
			if((e = mountnew(mnt)) != nil){
				t.error(sys->sprint("round %d, remount: %s", r, e));
				return;
			}
			reconnects++;
		}
	}
	t.log(sys->sprint("%d rounds, %d connections dropped and made again", rounds, reconnects));
	sys->unmount(nil, mnt);
	sys->remove(mnt);
	# the readers, the slow file's answers that are still asleep (2 s),
	# and the servers of dropped connections take a moment to go
	left := 0;
	for(i := 0; i < 50; i++){
		sys->sleep(200);
		left = nprogs() - base;
		if(left <= 12)
			break;
	}
	t.assert(left <= 12, sys->sprint("%d Progs left over from the rounds", left));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	ssl = load SSL SSL->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := tl args; a != nil; a = tl a)
		case hd a {
		"-v" =>
			testing->verbose(1);
		"-n" =>
			if(tl a != nil){
				a = tl a;
				rounds = int hd a;
			}
		"-s" =>
			if(tl a != nil){
				a = tl a;
				seed = int hd a;
			}
		}
	rnd = seed;
	SECRETA = secret(1);
	SECRETB = secret(101);

	sys->create("/tmp", Sys->OREAD, Sys->DMDIR|8r777);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR|8r777);
	bigdata = array[BIGLEN] of byte;
	for(i := 0; i < BIGLEN; i++)
		bigdata[i] = byte (i*7 + i/251);
	fd := sys->create(DIR + "/big", Sys->OWRITE, 8r666);
	if(fd == nil || sys->write(fd, bigdata, len bigdata) != len bigdata){
		sys->fprint(sys->fildes(2), "cannot make %s/big: %r\n", DIR);
		raise "fail:setup";
	}
	fd = nil;
	sys->bind("#s", "/chan", Sys->MBEFORE);
	io := sys->file2chan("/chan", "ninep_disconnect_slow");
	if(io == nil){
		sys->fprint(sys->fildes(2), "file2chan: %r\n");
		raise "fail:setup";
	}
	slowpid := chan of int;
	spawn slowsrv(io, slowpid);
	slowgrp := <-slowpid;
	sys->create(DIR + "/slow", Sys->OWRITE, 8r666);
	if(sys->bind("/chan/ninep_disconnect_slow", DIR + "/slow", Sys->MREPL) < 0){
		sys->fprint(sys->fildes(2), "bind slow: %r\n");
		raise "fail:setup";
	}

	run("KilledReaders", testKilledReaders);

	killgrp(slowgrp);
	sys->unmount(nil, DIR + "/slow");
	sys->remove(DIR + "/slow");
	sys->remove(DIR + "/big");
	sys->remove(DIR);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

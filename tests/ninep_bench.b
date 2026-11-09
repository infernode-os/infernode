implement NinepBench;

#
# ninep_bench: 9P throughput and latency through a mount, for comparing
# message sizes.  Not a test (the runner would not know what to expect of
# a network); tests/host/ninep_bench.sh drives it and does the
# statistics.
#
#	ninep_bench [-A] [-C alg] [-k keyfile] [-m msize,...] [-c readers,...]
#		[-n runs] [-s] [-l stats] addr path
#
# For each run, each message size and each number of readers: dial addr
# afresh, authenticate as mount(1) does (or not, -A), set the message
# size with fversion, mount, then start the readers together on path,
# each reading the whole file in reads as large as the size allows.
# -s gives each reader a connection and mount of its own (several
# machines) rather than all of them one (several windows on one).  Then
# time -l stats of path, one after another (a small message's round
# trip).  One line a run:
#
#	msize=N readers=R shared=S run=I bytes=B ms=T stat_us=U
#
# bytes is every reader's together; a reader that got less than the file
# is an error, printed and counted.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "dial.m";
	dial: Dial;
include "keyring.m";
	kr: Keyring;
include "security.m";
	auth: Auth;

NinepBench: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

noauth := 0;
alg := "aes_256_cbc/sha256";
keyfile := "";
nstats := 50;
errors := 0;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	kr = load Keyring Keyring->PATH;
	arg := load Arg Arg->PATH;
	msizes := 8192 :: 65536 :: nil;
	readers := 1 :: nil;
	runs := 5;
	separate := 0;
	arg->init(args);
	arg->setusage("ninep_bench [-A] [-C alg] [-k keyfile] [-m msize,...] [-c readers,...] [-n runs] [-s] [-l stats] addr path");
	while((o := arg->opt()) != 0)
		case o {
		'A' =>	noauth = 1;
		'C' =>	alg = arg->earg();
		'k' =>	keyfile = arg->earg();
		'm' =>	msizes = ints(arg->earg());
		'c' =>	readers = ints(arg->earg());
		'n' =>	runs = int arg->earg();
		's' =>	separate = 1;
		'l' =>	nstats = int arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 2)
		arg->usage();
	addr := dial->netmkaddr(hd args, "tcp", "styx");
	path := hd tl args;
	if(!noauth){
		auth = load Auth Auth->PATH;
		if(auth == nil || (e := auth->init()) != nil)
			fatal("cannot load auth: " + e);
	}
	sys->pctl(Sys->FORKNS, nil);
	# runs outermost, and within a run each case in an order turned by
	# one each run: a link that drifts over minutes then falls on every
	# case alike, not on whichever was measured first
	cases: list of (int, int);
	for(m := msizes; m != nil; m = tl m)
		for(r := readers; r != nil; r = tl r)
			cases = (hd m, hd r) :: cases;
	ca := array[len cases] of (int, int);
	for(k := len ca - 1; cases != nil; cases = tl cases)
		ca[k--] = hd cases;
	for(i := 1; i <= runs; i++)
		for(k = 0; k < len ca; k++){
			(msize, nr) := ca[(k + i - 1) % len ca];
			run(addr, path, msize, nr, separate, i);
		}
	if(errors)
		raise "fail:errors";
}

# a connection to addr, authenticated, at msize, mounted on dir
connect(addr: string, msize: int, dir: string): int
{
	c := dial->dial(addr, nil);
	if(c == nil){
		sys->fprint(sys->fildes(2), "ninep_bench: dial %s: %r\n", addr);
		return -1;
	}
	fd := c.dfd;
	if(!noauth){
		ai := kr->readauthinfo(keyname());
		if(ai == nil){
			sys->fprint(sys->fildes(2), "ninep_bench: no key %s: %r\n", keyname());
			return -1;
		}
		err: string;
		(fd, err) = auth->client(alg, ai, fd);
		if(fd == nil){
			sys->fprint(sys->fildes(2), "ninep_bench: auth: %s\n", err);
			return -1;
		}
	}
	(got, nil) := sys->fversion(fd, msize, "9P2000");
	if(got <= 0){
		sys->fprint(sys->fildes(2), "ninep_bench: fversion %d: %r\n", msize);
		return -1;
	}
	if(got != msize)
		sys->fprint(sys->fildes(2), "ninep_bench: asked msize %d, got %d\n", msize, got);
	if(sys->mount(fd, nil, dir, Sys->MREPL, nil) < 0){
		sys->fprint(sys->fildes(2), "ninep_bench: mount: %r\n");
		return -1;
	}
	return got;
}

keyname(): string
{
	if(keyfile != nil && keyfile[0] == '/')
		return keyfile;
	user := "inferno";
	if((fd := sys->open("/dev/user", Sys->OREAD)) != nil){
		b := array[64] of byte;
		n := sys->read(fd, b, len b);
		if(n > 0)
			user = string b[0:n];
	}
	if(keyfile == nil)
		keyfile = "default";
	return "/usr/" + user + "/keyring/" + keyfile;
}

run(addr, path: string, msize, nreaders, separate, i: int)
{
	dirs := array[nreaders] of string;
	got := 0;
	for(r := 0; r < nreaders; r++){
		dirs[r] = "/n/bench0";
		if(separate)
			dirs[r] = "/n/bench" + string r;
		if(r == 0 || separate){
			sys->create(dirs[r], Sys->OREAD, Sys->DMDIR|8r777);
			got = connect(addr, msize, dirs[r]);
			if(got < 0){
				errors++;
				return;
			}
		}
	}
	(ok, d) := sys->stat(dirs[0] + path);
	if(ok < 0){
		sys->fprint(sys->fildes(2), "ninep_bench: stat %s: %r\n", path);
		errors++;
		return;
	}
	size := int d.length;
	done := chan of int;
	go := chan of int;
	for(r = 0; r < nreaders; r++)
		spawn reader(dirs[r] + path, size, go, done);
	t0 := sys->millisec();
	for(r = 0; r < nreaders; r++)
		go <-= 1;
	total := 0;
	for(r = 0; r < nreaders; r++)
		total += <-done;
	ms := sys->millisec() - t0;
	if(total != size * nreaders){
		sys->fprint(sys->fildes(2), "ninep_bench: read %d bytes, want %d\n", total, size*nreaders);
		errors++;
	}
	t0 = sys->millisec();
	for(s := 0; s < nstats; s++)
		sys->stat(dirs[0] + path);
	us := 0;
	if(nstats > 0)
		us = (sys->millisec() - t0) * 1000 / nstats;
	sys->print("msize=%d readers=%d shared=%d run=%d bytes=%d ms=%d stat_us=%d\n",
		got, nreaders, !separate, i, total, ms, us);
	for(r = 0; r < nreaders; r++)
		if(r == 0 || separate)
			sys->unmount(nil, dirs[r]);
}

reader(file: string, size: int, go: chan of int, done: chan of int)
{
	fd := sys->open(file, Sys->OREAD);
	buf := array[1024*1024] of byte;
	<-go;
	n := 0;
	if(fd != nil)
		while(n < size && (k := sys->read(fd, buf, len buf)) > 0)
			n += k;
	done <-= n;
}

ints(s: string): list of int
{
	(nil, l) := sys->tokenize(s, ",");
	r: list of int;
	for(; l != nil; l = tl l)
		r = int hd l :: r;
	# back in the order given
	o: list of int;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "ninep_bench: %s\n", s);
	raise "fail:" + s;
}

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
# is an error, printed and counted.  A run that takes longer than -t
# seconds (120) prints stalled=1 in place of its measurements, is killed
# and is followed by the next; the stalls are counted at the end.
#
# -f secs reads a feed instead (vid9p(4), camsrv(4)): path is the feed's
# directory, and each reader does what wm/camera does: read fmt, start at
# the newest frame (-0: at frame 0, so a loaded clip is read as fast as
# it can be, unpaced), and read each frame after it whole, one pread at
# its offset, for secs seconds.  One line a run:
#
#	msize=N readers=R shared=S run=I frames=F ms=T framebytes=B p50_ms=P p95_ms=Q lost=L
#
# frames is every reader's together; p50 and p95 are of one frame's read;
# lost counts frames that expired before they were read.
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
stalls := 0;
deadline := 120;	# seconds a run may take before it is called stalled
feedsecs := 0;		# -f: read a feed for this long
fromzero := 0;		# -0: from frame 0, not the newest
mntbase := "/n/bench";	# -D: where the mounts go (a machine's /n may not take one)

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
	arg->setusage("ninep_bench [-A] [-C alg] [-k keyfile] [-m msize,...] [-c readers,...] [-n runs] [-s] [-l stats] [-t secs] [-f secs [-0]] [-D dir] addr path");
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
		't' =>	deadline = int arg->earg();
		'f' =>	feedsecs = int arg->earg();
		'0' =>	fromzero = 1;
		'D' =>	mntbase = arg->earg() + "/bench";
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
			timed(addr, path, msize, nr, separate, i);
		}
	if(stalls)
		sys->print("stalls=%d\n", stalls);
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

# a run under a deadline: one that does not finish is reported, its
# process group (readers and all) killed, and the next begun
timed(addr, path: string, msize, nreaders, separate, i: int)
{
	pidc := chan of int;
	done := chan of int;
	spawn runner(addr, path, msize, nreaders, separate, i, pidc, done);
	pid := <-pidc;
	tick := chan of int;
	spawn timer(tick, deadline*1000);
	alt {
	<-done =>
		;
	<-tick =>
		stalls++;
		sys->print("msize=%d readers=%d shared=%d run=%d stalled=1 secs=%d\n",
			msize, nreaders, !separate, i, deadline);
		if((fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE)) != nil)
			sys->fprint(fd, "killgrp");
		for(r := 0; r < nreaders; r++)
			sys->unmount(nil, mntbase + string r);
	}
}

runner(addr, path: string, msize, nreaders, separate, i: int, pidc, done: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	run(addr, path, msize, nreaders, separate, i);
	done <-= 1;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

run(addr, path: string, msize, nreaders, separate, i: int)
{
	dirs := array[nreaders] of string;
	got := 0;
	for(r := 0; r < nreaders; r++){
		dirs[r] = mntbase + "0";
		if(separate)
			dirs[r] = mntbase + string r;
		if(r == 0 || separate){
			sys->create(dirs[r], Sys->OREAD, Sys->DMDIR|8r777);
			got = connect(addr, msize, dirs[r]);
			if(got < 0){
				errors++;
				return;
			}
		}
	}
	if(feedsecs > 0){
		feedrun(dirs, path, got, nreaders, separate, i);
		for(r = 0; r < nreaders; r++)
			if(r == 0 || separate)
				sys->unmount(nil, dirs[r]);
		return;
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

feedrun(dirs: array of string, path: string, msize, nreaders, separate, i: int)
{
	(w, h) := feedfmt(dirs[0] + path + "/fmt");
	if(w <= 0){
		sys->fprint(sys->fildes(2), "ninep_bench: %s/fmt: %r\n", path);
		errors++;
		return;
	}
	size := w*h + 2*(w/2)*(h/2);
	go := chan of int;
	done := chan of (int, int, list of int);
	for(r := 0; r < nreaders; r++)
		spawn feedreader(dirs[r] + path, size, go, done);
	t0 := sys->millisec();
	for(r = 0; r < nreaders; r++)
		go <-= t0 + feedsecs*1000;
	frames := 0;
	lost := 0;
	times: list of int;
	for(r = 0; r < nreaders; r++){
		(n, l, ts) := <-done;
		frames += n;
		lost += l;
		for(; ts != nil; ts = tl ts)
			times = hd ts :: times;
	}
	ms := sys->millisec() - t0;
	a := array[len times] of int;
	for(k := 0; times != nil; times = tl times)
		a[k++] = hd times;
	sort(a);
	(p50, p95) := (0, 0);
	if(len a > 0){
		p50 = a[len a / 2];
		p95 = a[len a * 95 / 100];
	}
	sys->print("msize=%d readers=%d shared=%d run=%d frames=%d ms=%d framebytes=%d p50_ms=%d p95_ms=%d lost=%d\n",
		msize, nreaders, !separate, i, frames, ms, size, p50, p95, lost);
}

# wm/camera's reader, without the drawing: frames in order from the
# newest (or 0), each whole at its offset, until the deadline
feedreader(dir: string, size: int, go: chan of int, done: chan of (int, int, list of int))
{
	fd := sys->open(dir + "/frame", Sys->OREAD);
	buf := array[size] of byte;
	f := 0;
	if(!fromzero)
		f = newest(dir + "/status");
	end := <-go;
	n := 0;
	lost := 0;
	times: list of int;
	while(fd != nil && sys->millisec() < end){
		t := sys->millisec();
		got := 0;
		e := "";
		while(got < size){
			m := sys->pread(fd, buf[got:], size - got, big f * big size + big got);
			if(m < 0){
				e = sys->sprint("%r");
				break;
			}
			if(m == 0)
				break;
			got += m;
		}
		if(got < size){
			if(e == "frame expired"){
				lost++;
				f = newest(dir + "/status");
				continue;
			}
			# the feed ended (a loaded clip read to its end), or failed:
			# said, so a short run is not taken for a fast one
			if(e != nil && e != "")
				sys->fprint(sys->fildes(2), "ninep_bench: reader stopped at frame %d after %d: %s\n", f, n, e);
			break;
		}
		times = (sys->millisec() - t) :: times;
		n++;
		f++;
	}
	done <-= (n, lost, times);
}

feedfmt(file: string): (int, int)
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		return (0, 0);
	b := array[128] of byte;
	k := sys->read(fd, b, len b);
	if(k <= 0)
		return (0, 0);
	(nil, t) := sys->tokenize(string b[0:k], " \t\n");
	if(len t < 2)
		return (0, 0);
	return (int hd t, int hd tl t);
}

# the newest frame kept, as wm/camera finds it (status frames= less one)
newest(file: string): int
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		return 0;
	b := array[512] of byte;
	k := sys->read(fd, b, len b);
	if(k <= 0)
		return 0;
	(frames, first) := (0, 0);
	(nil, t) := sys->tokenize(string b[0:k], " \t\n");
	for(; t != nil; t = tl t){
		s := hd t;
		for(j := 0; j < len s; j++)
			if(s[j] == '='){
				case s[0:j] {
				"frames" =>	frames = int s[j+1:];
				"first" =>	first = int s[j+1:];
				}
				break;
			}
	}
	if(frames > first)
		return frames - 1;
	return frames;
}

sort(a: array of int)
{
	for(i := 1; i < len a; i++)
		for(j := i; j > 0 && a[j-1] > a[j]; j--)
			(a[j-1], a[j]) = (a[j], a[j-1]);
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

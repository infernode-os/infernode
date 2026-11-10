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
# its offset (-p ways: that many at once, each a contiguous piece), for
# secs seconds.  One line a run:
#
#	msize=N readers=R shared=S run=I frames=F ms=T framebytes=B p50_ms=P p95_ms=Q p99_ms=R max_ms=X lost=L
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
include "sdg.m";
	sdg: Sdg;

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
mntbase := "/n/bench";
sdgkeys := "";		# -U: over sdg(2), its keys in this directory
ways := 1;		# -p: each frame read as this many preads at once	# -D: where the mounts go (a machine's /n may not take one)

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
	arg->setusage("ninep_bench [-A] [-C alg] [-k keyfile] [-m msize,...] [-c readers,...] [-n runs] [-s] [-l stats] [-t secs] [-f secs [-0] [-p ways]] [-D dir] [-U keydir] addr path");
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
		'p' =>	ways = int arg->earg();
		'U' =>	sdgkeys = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 2)
		arg->usage();
	addr := dial->netmkaddr(hd args, "tcp", "styx");
	if(sdgkeys != nil){
		addr = dial->netmkaddr(hd args, "udp", "5640");
		sdg = load Sdg Sdg->PATH;
		if(sdg == nil)
			fatal(sys->sprint("cannot load %s: %r", Sdg->PATH));
		if((e := sdg->init()) != nil)
			fatal("sdg: " + e);
		noauth = 1;
	}
	path := hd tl args;
	if(!noauth){
		auth = load Auth Auth->PATH;
		if(auth == nil || (e := auth->init()) != nil)
			fatal("cannot load auth: " + e);
	}
	sys->pctl(Sys->FORKNS|Sys->NEWPGRP, nil);
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
	# the deadline timers sleep on: end them, so that emu exits now,
	# after errors as well (it waited out the caller's timeout)
	if(errors)
		sys->fprint(sys->fildes(2), "ninep_bench: %d errors\n", errors);
	if((fd := sys->open(sys->sprint("/prog/%d/ctl", sys->pctl(0, nil)), Sys->OWRITE)) != nil)
		sys->fprint(fd, "killgrp");
}

# a connection to addr, authenticated, at msize, mounted on dir
connect(addr: string, msize: int, dir: string): int
{
	if(sdgkeys != nil)
		return sdgconnect(addr, msize, dir);
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

# the same over sdg(2): keys from sdgkeys (sdgsrv -g's sdg.key, sdg.brick, sdg.psk)
sdgconnect(addr: string, msize: int, dir: string): int
{
	k := ref Sdg->Keys(hexfile(sdgkeys + "/sdg.key"), hexfile(sdgkeys + "/sdg.brick"),
		hexfile(sdgkeys + "/sdg.psk"), sdgkeys + "/sdg.ctr");
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return -1;
	if((e := sdg->relay(addr, k, p[1])) != nil){
		sys->fprint(sys->fildes(2), "ninep_bench: sdg %s: %s\n", addr, e);
		return -1;
	}
	p[1] = nil;
	(got, nil) := sys->fversion(p[0], msize, "9P2000");
	if(got <= 0){
		sys->fprint(sys->fildes(2), "ninep_bench: fversion %d: %r\n", msize);
		return -1;
	}
	if(got != msize)
		sys->fprint(sys->fildes(2), "ninep_bench: asked msize %d, got %d\n", msize, got);
	if(sys->mount(p[0], nil, dir, Sys->MREPL, nil) < 0){
		sys->fprint(sys->fildes(2), "ninep_bench: mount: %r\n");
		return -1;
	}
	return got;
}

hexfile(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[200] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	s := string b[0:n];
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' '))
		s = s[0:len s-1];
	if(len s % 2)
		return nil;
	a := array[len s/2] of byte;
	for(i := 0; i < len a; i++){
		v := 0;
		for(j := 0; j < 2; j++){
			c := s[2*i+j];
			case c {
			'0' to '9' => v = v*16 + c - '0';
			'a' to 'f' => v = v*16 + c - 'a' + 10;
			* => return nil;
			}
		}
		a[i] = byte v;
	}
	return a;
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
	(p50, p95, p99, pmax) := (0, 0, 0, 0);
	if(len a > 0){
		p50 = a[len a / 2];
		p95 = a[len a * 95 / 100];
		p99 = a[len a * 99 / 100];
		pmax = a[len a - 1];
	}
	sys->print("msize=%d readers=%d shared=%d run=%d frames=%d ms=%d framebytes=%d p50_ms=%d p95_ms=%d p99_ms=%d max_ms=%d lost=%d\n",
		msize, nreaders, !separate, i, frames, ms, size, p50, p95, p99, pmax, lost);
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
		(got, e) := parpread(fd, buf, big f * big size, ways);
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

# b read at off as ways preads of contiguous pieces at once (parread(2)
# does this; a copy here so the bench runs where the library is not)
parpread(fd: ref Sys->FD, b: array of byte, off: big, ways: int): (int, string)
{
	if(ways <= 1)
		return piece(fd, b, off);
	size := (len b + ways - 1) / ways;
	done := chan[ways] of (int, int, string);
	n := 0;
	for(s := 0; s < len b; s += size){
		e := s + size;
		if(e > len b)
			e = len b;
		spawn pworker(fd, b[s:e], off + big s, n, done);
		n++;
	}
	got := array[n] of int;
	errs := array[n] of string;
	for(i := 0; i < n; i++){
		(k, m, err) := <-done;
		got[k] = m;
		errs[k] = err;
	}
	total := 0;
	for(i = 0; i < n; i++){
		want := size;
		if(i == n-1)
			want = len b - size*(n-1);
		total += got[i];
		if(got[i] < want)
			return (total, errs[i]);
	}
	return (total, nil);
}

pworker(fd: ref Sys->FD, b: array of byte, off: big, k: int, done: chan of (int, int, string))
{
	(m, err) := piece(fd, b, off);
	done <-= (k, m, err);
}

piece(fd: ref Sys->FD, b: array of byte, off: big): (int, string)
{
	got := 0;
	while(got < len b){
		m := sys->pread(fd, b[got:], len b - got, off + big got);
		if(m < 0)
			return (got, sys->sprint("%r"));
		if(m == 0)
			break;
		got += m;
	}
	return (got, nil);
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

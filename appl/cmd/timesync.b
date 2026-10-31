implement Timesync;

#
# timesync - set this host's clock from the GPS's.
#
# After Plan 9's aux/timesync -G.  gpsfs(4)'s time file gives the time
# of the last fix beside this host's clock when its first sentence
# began to arrive.  A sentence arrives after its time, never before,
# and the delay varies, so of several samples the one with the largest
# offset (gps - local) was the least delayed: that is the offset taken.
# Only samples marked sync=yes are used: never a recording's, a feed's,
# nor a fix whose time this host stamped itself.
#
# What is left is the receiver's own delay between the second and its
# sentence (tens to hundreds of milliseconds, by receiver): -o adds a
# correction in milliseconds, found once against a better clock.
#
# The clock is stepped (cons(3)'s /dev/time) when it is off by more
# than -t milliseconds (200).  With -p it does so every so many
# seconds, quietly unless it steps.
#
# Usage:	timesync [-n samples] [-o ms] [-t ms] [-p seconds] [timefile]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "string.m";
	str: String;

Timesync: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

DEFAULT: con "/mnt/gps/time";
stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	if(arg == nil || str == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	nsamples := 5;
	adjust := big 0;
	threshold := big 200000;
	period := 0;
	arg->init(argv);
	arg->setusage("timesync [-n samples] [-o ms] [-t ms] [-p seconds] [timefile]");
	while((o := arg->opt()) != 0)
		case o {
		'n' =>
			nsamples = int arg->earg();
		'o' =>
			adjust = big (real arg->earg() * 1000.0);
		't' =>
			threshold = big (real arg->earg() * 1000.0);
		'p' =>
			period = int arg->earg();
		* =>
			arg->usage();
		}
	argv = arg->argv();
	file := DEFAULT;
	if(argv != nil)
		file = hd argv;
	if(argv != nil && tl argv != nil || nsamples < 1)
		arg->usage();

	if(file == DEFAULT && sys->stat(file).t0 < 0) {
		# gpsfs mounted elsewhere: its posted files, in a name space
		# of this command's own
		sys->pctl(Sys->FORKNS, nil);
		fd := sys->open("#sgps/fs", Sys->ORDWR);
		if(fd == nil || sys->mount(fd, nil, "/mnt/gps", Sys->MREPL, nil) < 0)
			fatal(sys->sprint("no GPS time: %s: not served, nor #sgps/fs posted", file));
	}

	for(;;) {
		(offset, err) := sample(file, nsamples);
		if(err != nil) {
			sys->fprint(stderr, "timesync: %s\n", err);
			if(period <= 0)
				raise "fail:" + err;
		} else {
			offset += adjust;
			if(offset >= threshold || offset <= -threshold) {
				if((err = step(offset)) != nil) {
					sys->fprint(stderr, "timesync: %s\n", err);
					if(period <= 0)
						raise "fail:" + err;
				} else
					sys->print("timesync: clock %s by %s s: set\n", way(offset), secs(offset));
			} else if(period <= 0)
				sys->print("timesync: clock %s by %s s: left\n", way(offset), secs(offset));
		}
		if(period <= 0)
			return;
		sys->sleep(period * 1000);
	}
}

fatal(s: string)
{
	sys->fprint(stderr, "timesync: %s\n", s);
	raise "fail:" + s;
}

way(offset: big): string
{
	if(offset >= big 0)
		return "slow";
	return "fast";
}

secs(us: big): string
{
	if(us < big 0)
		us = -us;
	return sys->sprint("%bd.%.6bd", us / big 1000000, us % big 1000000);
}

# the largest offset of the samples marked sync=yes, each a fix of its
# own; or why there is none
sample(file: string, n: int): (big, string)
{
	best := big 0;
	got := 0;
	last := "";
	# only fixes from now on: one from before a step is stale
	since := clock();
	why := "no live GPS time in " + file;
	for(i := 0; i < n + 2 && got < n; i++) {
		if(i > 0)
			sys->sleep(1100);
		s := readfile(file);
		if(s == nil)
			return (big 0, sys->sprint("%s: %r", file));
		local, offset, sync: string;
		for(l := str->unquoted(s); l != nil; l = tl l) {
			(k, v) := str->splitl(hd l, "=");
			if(v == nil)
				continue;
			v = v[1:];
			case k {
			"local" =>	local = v;
			"offset" =>	offset = v;
			"sync" =>	sync = v;
			}
		}
		if(sync != "yes") {
			if(sync == "no")
				why = "the GPS time is not a live receiver's (" + file + " says sync=no)";
			continue;
		}
		if(local == last || big local <= since)
			continue;	# the same fix again, or one from before
		last = local;
		o := big offset;
		if(got == 0 || o > best)
			best = o;
		got++;
	}
	if(got == 0)
		return (big 0, why);
	return (best, nil);
}

# this host's clock, microseconds since the epoch
clock(): big
{
	s := readfile("/dev/time");
	if(s == nil)
		return big 0;
	return big s;
}

# set the clock forward by offset microseconds
step(offset: big): string
{
	fd := sys->open("/dev/time", Sys->ORDWR);
	if(fd == nil)
		return sys->sprint("/dev/time: %r");
	b := array[32] of byte;
	n := sys->pread(fd, b, len b, big 0);
	if(n <= 0)
		return sys->sprint("read /dev/time: %r");
	now := big string b[0:n];
	if(sys->fprint(fd, "%bd", now + offset) < 0)
		return sys->sprint("set /dev/time: %r");
	return nil;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return nil;
	return string b[0:n];
}

implement Timesync;

#
# timesync - set this host's clock from the GPS's.
#
# After Plan 9's aux/timesync -G.  gpsfs(4)'s time file gives the time
# of the last fix beside this host's clock when its first sentence
# began to arrive.  A sentence arrives after its time, never before,
# and the delay varies, so of several samples the one with the largest
# offset (gps - local) was the least delayed.  Only samples marked
# sync=yes are used: never a recording's, a feed's, nor a fix whose
# time this host stamped itself.
#
# What says the time is not always the receiver: where gpsfs listens
# to a UDP port, it is whoever sends a datagram there, and a receiver
# itself hears whatever is strongest.  The clock decides which
# certificates are in date, so a time is not taken on one say-so:
#
#   - A time before this system was built is no time.  The bound is
#     the later of the day this was written (Written) and the kernel's
#     build date, which is the modification time of its device files
#     (0 where the kernel was not given one).  It was taken: a time a
#     hundred years back set the clock negative.
#   - The median of the samples says which are the receiver's: those
#     within Near of it, which must be most of them; the offset is the
#     largest of those.  It was the largest of all, so one sample in
#     five a year ahead carried the clock a year ahead.
#   - A clock that has been set (it is past the bound above) is not
#     stepped by more than -m seconds, a day unless given: one kept by
#     the host or an RTC is off by its drift, seconds a day, or by a
#     time zone, hours; more is another date and the operator's to
#     allow (-m 0 allows any step).  A clock never set, as a board's
#     with no RTC is at power-on, takes whatever step brings it to the
#     time.
#   - No record is used that is not later, by the receiver's own time,
#     than the last one a result was made from, nor one this host
#     stamped before its clock was last stepped.  One record, never
#     replaced because the receiver had gone, was applied again every
#     period once the clock had been stepped back past it.
#
# What is left is the receiver's own delay between the second and its
# sentence (tens to hundreds of milliseconds, by receiver): -o adds a
# correction in milliseconds, found once against a better clock.
#
# The clock is stepped (cons(3)'s /dev/time) when it is off by more
# than -t milliseconds (200).  With -p it does so every so many
# seconds, quietly unless it steps.
#
# Usage:	timesync [-n samples] [-o ms] [-t ms] [-m seconds] [-p seconds] [timefile]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "string.m";
	str: String;

include "daytime.m";
	daytime: Daytime;

Timesync: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

DEFAULT: con "/mnt/gps/time";
stderr: ref Sys->FD;

Written: con 1793491200;	# 2026-11-01: no fix is from before this was written
Near: con big 2000000;	# microseconds: samples of one receiver are this close
Maxstep: con 86400;	# seconds a clock already set is stepped, unless -m
Micro: con big 1000000;

floor: big;		# microseconds: a time before this is none
lastgps := big 0;	# the receiver's time in the newest record a result was made from

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	daytime = load Daytime Daytime->PATH;
	if(arg == nil || str == nil || daytime == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	nsamples := 5;
	adjust := big 0;
	threshold := big 200000;
	period := 0;
	maxstep := big Maxstep * Micro;
	arg->init(argv);
	arg->setusage("timesync [-n samples] [-o ms] [-t ms] [-m seconds] [-p seconds] [timefile]");
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
		'm' =>
			a := arg->earg();
			if(!isdigits(a))
				arg->usage();
			maxstep = big a * Micro;
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

	floor = big Written * Micro;
	(ok, d) := sys->stat("#c/time");
	if(ok >= 0 && big d.mtime * Micro > floor)
		floor = big d.mtime * Micro;	# the kernel's build date

	for(;;) {
		(offset, err) := sample(file, nsamples);
		if(err != nil) {
			sys->fprint(stderr, "timesync: %s\n", err);
			if(period <= 0)
				raise "fail:" + err;
		} else {
			offset += adjust;
			if(offset >= threshold || offset <= -threshold) {
				# a clock that has been set is stepped only so far
				if(maxstep > big 0 && clock() >= floor && (offset > maxstep || offset < -maxstep))
					err = sys->sprint("clock %s by %s s, more than the %bd s a clock already set is stepped: not set (-m seconds allows more, -m 0 any step)",
						way(offset), secs(offset), maxstep / Micro);
				else
					err = step(offset);
				if(err != nil) {
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

isdigits(s: string): int
{
	if(len s == 0 || len s > 12)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

# a number of microseconds as a record gives one: (value, ok)
micros(s: string): (big, int)
{
	if(len s == 0 || len s > 19)
		return (big 0, 0);
	i := 0;
	if(s[0] == '-')
		i++;
	if(i == len s)
		return (big 0, 0);
	for(; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return (big 0, 0);
	return (big s, 1);
}

date(us: big): string
{
	t := us / Micro;
	if(t < big 0 || t > big 16r7fffffff)
		return sys->sprint("%bd s from 1970", t);	# past what Daytime holds
	return daytime->text(daytime->gmt(int t));
}

# The offset the samples give, each a fix of its own marked sync=yes,
# or why there is none: the largest of those within Near of their
# median, which must be most of them.
sample(file: string, n: int): (big, string)
{
	offs := array[n] of big;
	gpss := array[n] of big;
	got := 0;
	seen := "";
	# only fixes from now on: one from before a step is stale
	since := clock();
	why := "no live GPS time in " + file;
	for(i := 0; i < n + 2 && got < n; i++) {
		if(i > 0)
			sys->sleep(1100);
		(s, rerr) := readfile(file);
		if(rerr != nil)
			return (big 0, sys->sprint("%s: %s", file, rerr));
		if(s == nil) {
			why = "no fix with a time yet in " + file;
			continue;
		}
		gps, local, offset, sync: string;
		for(l := str->unquoted(s); l != nil; l = tl l) {
			(k, v) := str->splitl(hd l, "=");
			if(v == nil)
				continue;
			v = v[1:];
			case k {
			"gps" =>	gps = v;
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
		# a record says all three, and they agree (one with no offset
		# was a sample of no offset: the clock was called right)
		(g, gok) := micros(gps);
		(lo, lok) := micros(local);
		(o, ook) := micros(offset);
		if(!gok || !lok || !ook || g - lo != o) {
			why = "a record of " + file + " that is none: " + clean(s);
			continue;
		}
		if(local == seen)
			continue;	# the same fix again
		seen = local;
		if(g < floor) {
			why = sys->sprint("the GPS time (%s) is before this system was built (%s): not a time", date(g), date(floor));
			continue;
		}
		# stamped before this began, or by a clock since stepped back
		# (it is ahead of the clock), or no later than the last one a
		# result came from
		if(lo <= since || lo > clock() + Micro || g <= lastgps)
			continue;
		offs[got] = o;
		gpss[got] = g;
		got++;
	}
	if(got == 0)
		return (big 0, why);
	# sorted, to find the median
	a := array[got] of big;
	a[0:] = offs[0:got];
	for(i = 1; i < got; i++)
		for(j := i; j > 0 && a[j] < a[j-1]; j--)
			(a[j], a[j-1]) = (a[j-1], a[j]);
	med := a[(got-1)/2];
	best := med;
	agree := 0;
	newest := big 0;
	for(i = 0; i < got; i++) {
		if(offs[i] - med > Near || med - offs[i] > Near)
			continue;
		agree++;
		if(offs[i] > best)
			best = offs[i];
		if(gpss[i] > newest)
			newest = gpss[i];
	}
	if(2*agree <= got)
		return (big 0, sys->sprint("the GPS times disagree: of %d samples, %d are within %bd s of their median (%s s %s)",
			got, agree, Near / Micro, secs(med), way(med)));
	lastgps = newest;
	return (best, nil);
}

# a record for a message: its first line, printable
clean(s: string): string
{
	r := "";
	for(i := 0; i < len s && i < 120 && s[i] != '\n'; i++)
		if(s[i] >= ' ' && s[i] <= '~')
			r[len r] = s[i];
		else
			r[len r] = '?';
	return r;
}

# this host's clock, microseconds since the epoch
clock(): big
{
	(s, nil) := readfile("/dev/time");
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

# (what the file holds, nil) or (nil, why it could not be read): a file
# with nothing in it is not an error (gpsfs's time is empty until the
# first fix, and was reported with whatever error had come last)
readfile(f: string): (string, string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return (nil, sys->sprint("%r"));
	return (string b[0:n], nil);
}

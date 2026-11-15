implement HistorySvc;

#
# history-svc — Matrix service module: any directory of numbers,
# sampled into rings.
#
# Its mount is a directory (a sensor's, /mnt/env from envsrv(4), or any
# other); every file directly in it whose content starts with a number
# is read once a minute, and the last 1440 samples (24 hours) of each
# are kept:
#
#   <outdir>/<file>/history   one "ts value" line per sample, oldest
#                             first, ts in seconds since the epoch
#   <outdir>/<file>/current   the last value read
#
# line-plot and sparkline draw the history files; line-plot places them
# by their times, so a sample the source did not give (a sensor that
# stopped answering, the composition not loaded) shows as a gap.
#
# At init it reads the history files already in its outdir back, so a
# composition loaded again, or an emulator started again, keeps the day
# it had: /tmp/matrix/<name> is on the host's disk.
#
# A file that is not a number (a ctl file, a sensor's error) is passed
# over; a file that has gone keeps its history. The first sample is
# taken at start, then one each minute after.
#
# The time comes from the clock read in init (the service runs with no
# /dev), carried on by the millisecond counter.
#
# Composition usage:
#     service history-svc /mnt/env
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "daytime.m";
	daytime: Daytime;

include "matrix.m";

HistorySvc: module
{
	init:		fn(mount: string, outdir: string): string;
	run:		fn();
	shutdown:	fn();
};

PERIOD:	con 60;		# seconds between samples
HISTLEN:	con 1440;	# samples kept: 24 hours

Ring: adt {
	name:	string;
	ts:	array of int;
	v:	array of string;
	n:	int;		# samples held
	w:	int;		# next to write

	add:	fn(r: self ref Ring, t: int, v: string);
	text:	fn(r: self ref Ring): string;
};

mount_g, outdir_g: string;
rings: list of ref Ring;
running: int;

# the clock: epoch seconds at init and the millisecond counter then
base: int;
basems: int;
lastms: int;
carried: big;		# milliseconds since init, past the counter's wrap

init(mount: string, outdir: string): string
{
	sys = load Sys Sys->PATH;
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		return sys->sprint("cannot load %s: %r", Daytime->PATH);
	mount_g = mount;
	outdir_g = outdir;
	running = 1;
	base = daytime->now();
	basems = lastms = sys->millisec();
	carried = big 0;
	rings = nil;
	mkdir(outdir_g);
	restore();
	return nil;
}

run()
{
	while(running){
		sample();
		# a second at a time, so shutdown is prompt
		for(i := 0; i < PERIOD && running; i++)
			sys->sleep(1000);
	}
}

shutdown()
{
	running = 0;
}

now(): int
{
	ms := sys->millisec();
	carried += big (ms - lastms);	# the difference is right across a wrap
	lastms = ms;
	return base + int (carried / big 1000);
}

sample()
{
	fd := sys->open(mount_g, Sys->OREAD);
	if(fd == nil)
		return;
	t := now();
	for(;;){
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			d := dirs[i];
			if(d.mode & Sys->DMDIR)
				continue;
			v := number(readfile(mount_g + "/" + d.name));
			if(v == nil)
				continue;
			r := ring(d.name);
			r.add(t, v);
			mkdir(outdir_g + "/" + d.name);
			writefile(outdir_g + "/" + d.name + "/history", r.text());
			writefile(outdir_g + "/" + d.name + "/current", v + "\n");
		}
	}
}

# the history files already there, read back
restore()
{
	fd := sys->open(outdir_g, Sys->OREAD);
	if(fd == nil)
		return;
	for(;;){
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			if((dirs[i].mode & Sys->DMDIR) == 0)
				continue;
			s := readfile(outdir_g + "/" + dirs[i].name + "/history");
			if(s == nil)
				continue;
			r: ref Ring;
			(nil, lines) := sys->tokenize(s, "\n");
			for(; lines != nil; lines = tl lines){
				(nt, toks) := sys->tokenize(hd lines, " \t");
				if(nt != 2 || number(hd tl toks) == nil)
					continue;
				if(r == nil)
					r = ring(dirs[i].name);
				r.add(int hd toks, hd tl toks);
			}
		}
	}
}

ring(name: string): ref Ring
{
	for(l := rings; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	r := ref Ring(name, array[HISTLEN] of int, array[HISTLEN] of string, 0, 0);
	rings = r :: rings;
	return r;
}

Ring.add(r: self ref Ring, t: int, v: string)
{
	r.ts[r.w] = t;
	r.v[r.w] = v;
	r.w = (r.w + 1) % HISTLEN;
	if(r.n < HISTLEN)
		r.n++;
}

Ring.text(r: self ref Ring): string
{
	s := "";
	start := 0;
	if(r.n == HISTLEN)
		start = r.w;
	for(i := 0; i < r.n; i++){
		k := (start + i) % HISTLEN;
		s += sys->sprint("%d %s\n", r.ts[k], r.v[k]);
	}
	return s;
}

# the number a file starts with, as it was written, or nil
number(s: string): string
{
	(nt, toks) := sys->tokenize(s, " \t\n");
	if(nt == 0)
		return nil;
	w := hd toks;
	digits := 0;
	i := 0;
	if(i < len w && (w[i] == '-' || w[i] == '+'))
		i++;
	for(; i < len w && w[i] >= '0' && w[i] <= '9'; i++)
		digits++;
	if(i < len w && w[i] == '.')
		for(i++; i < len w && w[i] >= '0' && w[i] <= '9'; i++)
			digits++;
	if(digits == 0)
		return nil;
	if(i < len w && (w[i] == 'e' || w[i] == 'E')){
		j := i + 1;
		if(j < len w && (w[j] == '-' || w[j] == '+'))
			j++;
		k := j;
		for(; j < len w && w[j] >= '0' && w[j] <= '9'; j++)
			;
		if(j > k)
			i = j;
	}
	if(i != len w)
		return nil;
	return w;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	out := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		out += string buf[0:n];
	return out;
}

# replace via tmp + rename so readers never see a torn write
writefile(path, content: string)
{
	tmp := path + ".tmp";
	fd := sys->create(tmp, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	data := array of byte content;
	sys->write(fd, data, len data);
	fd = nil;
	sys->remove(path);
	nd := sys->nulldir;
	nd.name = basename(path);
	sys->wstat(tmp, nd);
}

basename(p: string): string
{
	for(i := len p - 1; i >= 0; i--)
		if(p[i] == '/')
			return p[i+1:];
	return p;
}

mkdir(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok == 0)
		return;
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

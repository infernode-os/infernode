implement Fsbench;

#
# fsbench dir -- the measurements a disk file server is held to, run in
# dir: what kfs gave on a Pi 5's NVMe is the baseline gefs is compared
# with, so both are measured by this same program.
#
#	seqwrite, seqread	256 MB in 64 KB writes, then read back
#	smallcreate		2000 files of 1 KB, created and written
#	smallstat		each stat'ed
#	smallremove		each removed
#	bigdir			5000 empty files in one directory
#	lookup			the last of them opened 1000 times
#
# Each line is "name ms rate", rate in MB/s or operations a second.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Fsbench: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	if(len args != 2){
		sys->fprint(stderr, "usage: fsbench dir\n");
		raise "fail:usage";
	}
	dir := hd tl args + "/fsbench";
	if(sys->create(dir, Sys->OREAD, Sys->DMDIR|8r775) == nil){
		sys->fprint(stderr, "fsbench: create %s: %r\n", dir);
		raise "fail:create";
	}
	memory("before");
	seq(dir);
	small(dir);
	bigdir(dir);
	memory("after");
	sys->remove(dir);
}

ms(): int
{
	return sys->millisec();
}

report(name: string, t: int, n: real, unit: string)
{
	if(t <= 0)
		t = 1;
	sys->print("%-12s %7d ms %10.1f %s\n", name, t, n*1000.0/real t, unit);
}

seq(dir: string)
{
	f := dir + "/seq";
	fd := sys->create(f, Sys->OWRITE, 8r664);
	if(fd == nil){
		sys->fprint(stderr, "fsbench: create %s: %r\n", f);
		return;
	}
	buf := array[65536] of byte;
	for(i := 0; i < len buf; i++)
		buf[i] = byte (i*7);
	n := 4096;		# 256 MB
	t := ms();
	for(i = 0; i < n; i++)
		if(sys->write(fd, buf, len buf) != len buf){
			sys->fprint(stderr, "fsbench: write: %r\n");
			return;
		}
	fd = nil;
	report("seqwrite", ms()-t, real n/16.0, "MB/s");
	fd = sys->open(f, Sys->OREAD);
	t = ms();
	tot := 0;
	while((r := sys->read(fd, buf, len buf)) > 0)
		tot += r;
	report("seqread", ms()-t, real tot/1048576.0, "MB/s");
	if(tot != n*len buf)
		sys->print("seqread: read %d of %d bytes\n", tot, n*len buf);
	fd = nil;
	sys->remove(f);
}

small(dir: string)
{
	d := dir + "/small";
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r775);
	buf := array[1024] of byte;
	n := 2000;
	t := ms();
	for(i := 0; i < n; i++){
		fd := sys->create(d + "/f" + string i, Sys->OWRITE, 8r664);
		if(fd == nil || sys->write(fd, buf, len buf) != len buf){
			sys->fprint(stderr, "fsbench: small %d: %r\n", i);
			return;
		}
	}
	report("smallcreate", ms()-t, real n, "files/s");
	t = ms();
	for(i = 0; i < n; i++)
		sys->stat(d + "/f" + string i);
	report("smallstat", ms()-t, real n, "stats/s");
	t = ms();
	for(i = 0; i < n; i++)
		sys->remove(d + "/f" + string i);
	report("smallremove", ms()-t, real n, "files/s");
	sys->remove(d);
}

bigdir(dir: string)
{
	d := dir + "/big";
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r775);
	n := 5000;
	t := ms();
	for(i := 0; i < n; i++)
		sys->create(d + "/e" + string i, Sys->OREAD, 8r664);
	report("bigdir", ms()-t, real n, "files/s");
	last := d + "/e" + string (n-1);
	t = ms();
	for(i = 0; i < 1000; i++)
		sys->open(last, Sys->OREAD);
	report("lookup", ms()-t, 1000.0, "opens/s");
	for(i = 0; i < n; i++)
		sys->remove(d + "/e" + string i);
	sys->remove(d);
}

memory(when: string)
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n > 0)
		sys->print("memory %s:\n%s", when, string buf[0:n]);
}

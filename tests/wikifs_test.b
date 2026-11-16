implement WikifsTest;

#
# wikifs and its store (appl/cmd/wikifs/wiki.b, wikifs.b), on stores of
# the test's own, through the Wiki module and through a mount.
#
# The page cache's eviction looked for the least recently used page below
# ~0, which is -1: it found none, and the loop that makes room in a full
# bucket never ended.  A bucket is a page number mod 64 and holds four,
# and any integer walked (to an empty page), so five walks, of 0, 64,
# 128, 192 and 256, stopped the one process every walk of the wiki
# waits for.  A number past 65535 ran into the qid's type: /262144 was
# page 0's index.html.
#
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "sh.m";
include "../appl/cmd/wikifs/wiki.m";
include "testing.m";
	testing: Testing;
	T: import testing;

WikifsTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/wikifs_test.b";
DEADLINE: con 30*1000;	# a test's; the faults this is about never return

passed := 0;
failed := 0;
skipped := 0;
seq := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	done := chan[1] of int;
	pidc := chan[1] of int;
	spawn runproc(t, testfn, pidc, done);
	pid := <-pidc;
	(tick, tpid) := timer(DEADLINE);
	alt {
	<-done =>
		kill(tpid);
	<-tick =>
		t.error("did not finish");
		kill(pid);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

runproc(t: ref T, testfn: ref fn(t: ref T), pidc, done: chan of int)
{
	pidc <-= sys->pctl(Sys->FORKNS, nil);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}
	done <-= 1;
}

timer(ms: int): (chan of int, int)
{
	c := chan[1] of int;
	pidc := chan of int;
	spawn sleeper(ms, c, pidc);
	return (c, <-pidc);
}

sleeper(ms: int, c, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->sleep(ms);
	c <-= 1;
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

# ---- stores

putfile(f: string, s: string): int
{
	fd := sys->create(f, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}

getfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[65536] of byte;
	a := array[0] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0){
		na := array[len a + n] of byte;
		na[0:] = a;
		na[len a:] = buf[0:n];
		a = na;
	}
	s = string a;
	return s;
}

templates := array[] of {"page.html", "edit.html", "diff.html", "history.html", "oldpage.html", "werror.html", "page.txt", "oldpage.txt"};

# a store in dir: the templates and an empty d
mkstore(t: ref T, dir: string)
{
	if(sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777) == nil || sys->create(dir + "/d", Sys->OREAD, Sys->DMDIR|8r777) == nil)
		t.fatal(sys->sprint("cannot make %s: %r", dir));
	for(i := 0; i < len templates; i++)
		putfile(dir + "/" + templates[i], getfile("/services/wiki/" + templates[i]));
	putfile(dir + "/d/map", "");
}

# a store of the host's (the emulator's root has a tmp)
hoststore(t: ref T): string
{
	dir := sys->sprint("/tmp/wikifs_test.%d.%d", sys->pctl(0, nil), seq++);
	rmrf(dir);
	mkstore(t, dir);
	return dir;
}

rmrf(dir: string)
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd != nil)
		for(;;){
			(n, d) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++)
				if(d[i].mode & Sys->DMDIR)
					rmrf(dir + "/" + d[i].name);
				else
					sys->remove(dir + "/" + d[i].name);
		}
	fd = nil;
	sys->remove(dir);
}

# page n as its file holds it, one version
pagefile(title: string, vers: int, text: string): string
{
	return sys->sprint("%s\nD%d\nAtest\n#%s\n", title, vers, text);
}

addpage(dir: string, n: int, title, text: string)
{
	putfile(sys->sprint("%s/d/%d", dir, n), pagefile(title, 1000, text));
	putfile(sys->sprint("%s/d/%d.hist", dir, n), pagefile(title, 1000, text));
	fd := sys->open(dir + "/d/map", Sys->OWRITE);
	sys->seek(fd, big 0, Sys->SEEKEND);
	sys->fprint(fd, "%d %s\n", n, title);
}

# the Wiki module, a copy of its own, on dir
wikion(t: ref T, dir: string): Wiki
{
	w := load Wiki Wiki->PATH;
	if(w == nil)
		t.fatal(sys->sprint("cannot load %s: %r", Wiki->PATH));
	w->init(bufio);
	w->setwikidir(dir);
	return w;
}

words(pl: list of ref Wiki->Wpage): string
{
	s := "";
	for(; pl != nil; pl = tl pl)
		s += (hd pl).text;
	return s;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

clip(s: string): string
{
	if(len s > 20)
		return s[0:20] + "...";
	return s;
}

# ---- the cache

testEviction(t: ref T)
{
	dir := hoststore(t);
	w := wikion(t, dir);
	# numbers that are no page: nothing, and no place taken
	for(i := 0; i < 10; i++)
		t.assert(w->getcurrent(i*64) == nil, sys->sprint("page %d of an empty wiki is nil", i*64));
	t.assert(w->getcurrent(-1) == nil, "page -1 is nil");
	t.assert(w->getcurrent(1<<20) == nil, "page 2^20 is nil");

	# five pages of one bucket, each read; then the first again
	for(i = 0; i < 6; i++)
		addpage(dir, i*64, sys->sprint("page %d", i*64), sys->sprint("text%d", i*64));
	for(i = 0; i < 6; i++){
		wh := w->getcurrent(i*64);
		t.assert(wh != nil && words(wh.doc[0].wtxt) == sys->sprint("text%d", i*64), sys->sprint("page %d read", i*64));
	}
	wh := w->getcurrent(0);
	t.assert(wh != nil && words(wh.doc[0].wtxt) == "text0", "the page evicted is read again");
	wh = w->gethistory(320);
	t.assert(wh != nil && wh.ndoc == 1, "and a history");
	rmrf(dir);
}

# ---- through a mount

# wikifs on dir, mounted on /n/wiki of the caller's name space
mountwiki(t: ref T, dir: string)
{
	p := startwikifs(t, dir);
	sys->create("/tmp/wikifs_test.mnt", Sys->OREAD, Sys->DMDIR|8r777);
	sys->bind("/tmp/wikifs_test.mnt", "/n", Sys->MREPL);
	if(sys->mount(p, nil, "/n", Sys->MREPL, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
}

# wikifs on dir: the other end of its pipe
startwikifs(t: ref T, dir: string): ref Sys->FD
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	sync := chan of string;
	spawn wikifsproc(p[1], dir, sync);
	p[1] = nil;
	if((e := <-sync) != nil)
		t.fatal(e);
	return p[0];
}

wikifsproc(fd: ref Sys->FD, dir: string, sync: chan of string)
{
	sys->pctl(Sys->NEWFD|Sys->FORKNS, fd.fd :: 2 :: nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	wikifs := load Command "/dis/wikifs.dis";
	if(wikifs == nil){
		sync <-= sys->sprint("cannot load wikifs: %r");
		return;
	}
	{
		wikifs->init(nil, "wikifs" :: "-d" :: dir :: nil);
	} exception e {
	"*" =>
		sync <-= "wikifs: " + e;
		return;
	}
	sync <-= nil;
}

exists(f: string): int
{
	(ok, nil) := sys->stat(f);
	return ok >= 0;
}

testWalkNumbers(t: ref T)
{
	dir := hoststore(t);
	addpage(dir, 0, "front page", "the front page");
	addpage(dir, 7, "seventh", "the seventh");
	mountwiki(t, dir);
	t.assert(exists("/n/0/index.html"), "page 0 by its number");
	t.assert(exists("/n/7/index.html"), "page 7 by its number");
	t.assert(exists("/n/seventh/index.html"), "and by its name");
	nope := array[] of {"5000", "64", "128", "192", "256", "320", "65535", "65536", "65543", "262144", "4294967296", "99999999999999999999", "-5", "1"};
	for(i := 0; i < len nope; i++){
		t.assert(!exists("/n/" + nope[i]), "/" + nope[i] + " is no page: not found");
		t.assert(!exists("/n/" + nope[i] + "/index.html"), "nor its index.html");
	}
	t.assert(exists("/n/front_page/index.html"), "the wiki still answers");
	s := getfile("/n/0/index.html");
	t.assert(contains(s, "front"), "and serves page 0");

	unmountwiki();
	rmrf(dir);
}

unmountwiki()
{
	sys->unmount(nil, "/n");
}

# a page written to new as httpd writes it: (the page's name, the
# error of the commit; nil if it was taken)
post(title: string, vers: int, text: string): (string, string)
{
	fd := sys->open("/n/new", Sys->ORDWR);
	if(fd == nil)
		return (nil, sys->sprint("open new: %r"));
	b := array of byte (title + "\nD" + string vers + "\nAtest\n\n" + text);
	if(sys->write(fd, b, len b) != len b)
		return (nil, sys->sprint("write: %r"));
	err: string;
	if(sys->write(fd, b, 0) != 0)
		err = sys->sprint("%r");
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return (nil, err);
	return (string buf[0:n], err);
}

# the version of the page named name (its current file's D line)
version(name: string): int
{
	s := getfile("/n/" + name + "/current");
	for(i := 0; i + 1 < len s; i++)
		if(s[i] == '\n' && s[i+1] == 'D')
			return int s[i+2:];
	return -1;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	bufio = load Bufio Bufio->PATH;
	styx = load Styx Styx->PATH;
	if(bufio == nil || styx == nil){
		sys->fprint(sys->fildes(2), "cannot load bufio or styx: %r\n");
		raise "fail:cannot load";
	}
	styx->init();

	run("Eviction", testEviction);
	run("WalkNumbers", testWalkNumbers);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

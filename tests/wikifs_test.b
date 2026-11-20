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
# Nothing bounded a title or the map: past its limit the map was no
# longer read while lines went on being added to it, and at the next
# start there was none (nil, in the same process).  A title was checked
# before it was put in the map's form, so "Map", " new" and "42" made
# pages no walk could reach.  A page was written by truncating it and
# then two writes nobody checked; one holding its title alone was a
# history of no versions, indexed by whoever looked at it.
#
# The update-conflict check was made under a lock that is a file made
# for exclusive use, which the host file system does not have: two
# edits of one version at once were both taken.
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

# ---- titles and the map

testTitles(t: ref T)
{
	dir := hoststore(t);
	w := wikion(t, dir);
	long := "";
	for(i := 0; i < Wiki->Maxtitle + 1; i++)
		long[i] = 'a' + i%26;
	bad := array[] of {"Map", " new", "NEW", "map_", "42", " 0 ", "   ", "", "___", ".", "..", "a/b", "a\u0001b", long};
	for(i = 0; i < len bad; i++){
		n := w->allocnum(bad[i], 0);
		t.assert(n < 0, sys->sprint("title %q refused (%d)", clip(bad[i]), n));
	}
	t.assertseq(getfile(dir + "/d/map"), "", "and nothing was added to the map");

	n := w->allocnum("  A   Good_Title ", 0);
	t.assert(n >= 0, sys->sprint("a good title taken: %r"));
	t.assertseq(getfile(dir + "/d/map"), sys->sprint("%d a good title\n", n), "in the map in the form a walk looks up");
	t.asserteq(w->nametonum("A_Good_Title"), n, "found by its name");
	t.assertseq(w->numtoname(n), "a good title", "and by its number");
	t.asserteq(w->allocnum("a good title", 0), n, "the same title again is the same page");
	t.asserteq(w->allocnum("A_good  TITLE", 0), n, "in any spelling");
	t.assert(w->allocnum("a good title", 1) < 0, "and refused where it must be new");
	t.assert(w->allocnum(long[0:Wiki->Maxtitle], 0) >= 0, "a title of Maxtitle characters taken");
	rmrf(dir);
}

testMapFull(t: ref T)
{
	# the last number a qid can carry is taken: no page more
	dir := hoststore(t);
	putfile(dir + "/d/map", sys->sprint("0 first\n%d last\n", Wiki->Maxpages - 1));
	w := wikion(t, dir);
	t.asserteq(w->nametonum("last"), Wiki->Maxpages - 1, "the last page a qid can number is in the map");
	before := getfile(dir + "/d/map");
	t.assert(w->allocnum("one more", 0) < 0, "a page past it refused");
	t.assert(contains(sys->sprint("%r"), "full"), sys->sprint("saying the wiki is full: %r"));
	t.assertseq(getfile(dir + "/d/map"), before, "the map unchanged");
	rmrf(dir);

	# a map twenty bytes short of its size: nothing longer is added to it
	dir = hoststore(t);
	line := "7 ";
	for(i := 0; i < 100000; i++)
		line[len line] = 'x';
	line += "\n";
	lb := array of byte line;
	fd := sys->create(dir + "/d/map", Sys->OWRITE, 8r666);
	for(n := 0; n + 2*len lb <= Wiki->Maxmap; n += len lb)
		sys->write(fd, lb, len lb);
	room := Wiki->Maxmap - n - 20;
	pad := array[room] of { * => byte 'y' };
	pad[0] = byte '9';
	pad[1] = byte ' ';
	pad[room - 1] = byte '\n';
	sys->write(fd, pad, room);
	fd = nil;
	w = wikion(t, dir);
	(nil, d0) := sys->stat(dir + "/d/map");
	t.assert(int d0.length == Wiki->Maxmap - 20, "a map 20 bytes short of Maxmap");
	t.assert(w->allocnum("a title that would take the map past its size", 0) < 0, "a title that would take the map past Maxmap refused");
	t.assert(contains(sys->sprint("%r"), "full"), sys->sprint("saying the wiki is full: %r"));
	(nil, d1) := sys->stat(dir + "/d/map");
	t.assert(d1.length == d0.length, "the map unchanged");
	t.assert(w->allocnum("short", 0) >= 0, sys->sprint("one that fits taken: %r"));

	# a map past its size (made by hand, or by wikifs before it had a
	# limit): not read, and nothing that asks of it raises
	fd = sys->open(dir + "/d/map", Sys->OWRITE);
	sys->seek(fd, big 0, Sys->SEEKEND);
	sys->write(fd, lb, len lb);
	fd = nil;
	w = wikion(t, dir);
	t.asserteq(w->nametonum("short"), -1, "a map past Maxmap is not read: no page by name");
	t.assertnil(w->numtoname(7), "none by number");
	(nil, d2) := sys->stat(dir + "/d/map");
	t.assert(w->allocnum("after the cap", 0) < 0, "and no page is added");
	t.assert(w->allocnum("after the cap", 0) < 0, "nor at a second try");
	(nil, d3) := sys->stat(dir + "/d/map");
	t.assert(d2.length == d3.length, "the map does not grow");
	rmrf(dir);
}

testDamagedStore(t: ref T)
{
	# no map at all
	dir := hoststore(t);
	sys->remove(dir + "/d/map");
	w := wikion(t, dir);
	t.asserteq(w->nametonum("anything"), -1, "no map: no page by name");
	t.assertnil(w->numtoname(0), "none by number");
	t.assert(w->allocnum("a page", 0) < 0, "and none made");
	rmrf(dir);

	# a map with lines that are no entries
	dir = hoststore(t);
	addpage(dir, 3, "good page", "good");
	fd := sys->open(dir + "/d/map", Sys->OWRITE);
	sys->seek(fd, big 0, Sys->SEEKEND);
	sys->fprint(fd, "garbage\n\n-4 minus\n99999999999 huge\n12\n12 \n5 another page\n8 cut sho");
	fd = nil;
	addpage(dir, 5, "another page", "another");
	w = wikion(t, dir);
	t.asserteq(w->nametonum("good page"), 3, "a damaged map: its good entries read");
	t.asserteq(w->nametonum("another page"), 5, "after the bad ones too");
	t.asserteq(w->nametonum("garbage"), -1, "a line with no number is no page");
	t.asserteq(w->nametonum("minus"), -1, "nor one with a negative number");
	t.asserteq(w->nametonum("huge"), -1, "nor a number no qid holds");
	n := w->allocnum("added after", 0);
	t.assert(n > 8, sys->sprint("a page added to it has a number of its own (%d)", n));
	w = wikion(t, dir);
	t.asserteq(w->nametonum("added after"), n, "and is read back: the line cut short before it was ended");

	# a page that holds its title alone, and one that is not a page
	putfile(dir + "/d/3", "good page\n");
	putfile(dir + "/d/5", "");
	w = wikion(t, dir);
	t.assert(w->getcurrent(3) == nil, "a page file of a title and nothing else is no page");
	t.assert(w->getcurrent(5) == nil, "nor an empty one");

	# a history whose last version was cut short
	putfile(dir + "/d/3.hist", "good page\nD1000\nAtest\n#one\nD1001\nAtest\n#");
	wh := w->gethistory(3);
	t.assert(wh != nil && wh.ndoc == 1, "a history cut short in its last version: the versions before it");
	putfile(dir + "/d/3.hist", "good page\nD1000\nAtest\n");
	w = wikion(t, dir);
	t.assert(w->gethistory(3) == nil, "a history of no versions is none");
	rmrf(dir);
}

# A write that fails says so and leaves the page: on memfs with room
# for the history's record and not for the page.
testWriteChecked(t: ref T)
{
	memfs := load Command "/dis/memfs.dis";
	if(memfs == nil)
		t.skip("no memfs");
	memfs->init(nil, "memfs" :: "-m" :: "131072" :: "/n" :: nil);
	dir := "/n/store";
	mkstore(t, dir);
	w := wikion(t, dir);
	n := w->allocnum("small page", 0);
	t.assert(n >= 0, sys->sprint("a page made on memfs: %r"));
	t.asserteq(w->writepage(n, 0, "D1000\nAtest\n#the old text\n#", "small page"), 0, "its first version written");
	wh := w->getcurrent(n);
	t.assert(wh != nil && contains(words(wh.doc[0].wtxt), "the old text"), "and read");

	# all the room but what a reserve file holds: 12K
	block := array[512] of { * => byte 'r' };
	rfd := sys->create("/n/reserve", Sys->OWRITE, 8r666);
	for(i := 0; i < 24; i++)
		sys->write(rfd, block, len block);
	rfd = nil;
	ffd := sys->create("/n/filler", Sys->OWRITE, 8r666);
	while(sys->write(ffd, block, len block) == len block)
		;
	ffd = nil;
	sys->remove("/n/reserve");

	text := "";
	for(i = 0; i < 100; i++)
		text += "#the new text, line " + string i + " of a version of about ten thousand bytes in all, too long to fit\n";
	r := w->writepage(n, 1000, "D2000\nAtest\n" + text + "#", "small page");
	t.assert(r < 0, sys->sprint("a version there is no room for is refused (%d)", r));
	raw := getfile(dir + "/d/" + string n);
	t.assert(contains(raw, "the old text") && !contains(raw, "the new text"), "and the page's file is the old version, whole: " + clip(raw));
	w = wikion(t, dir);
	wh = w->getcurrent(n);
	t.assert(wh != nil && contains(words(wh.doc[0].wtxt), "the old text"), "which is still the page");

	sys->remove("/n/filler");
	r = w->writepage(n, 1000, "D2000\nAtest\n" + text + "#", "small page");
	t.asserteq(r, 0, "with room again it is written");
	w = wikion(t, dir);
	wh = w->getcurrent(n);
	t.assert(wh != nil && contains(words(wh.doc[0].wtxt), "the new text, line 99"), "and is the page");
}

# ---- templates and diffs

testTextTemplate(t: ref T)
{
	dir := hoststore(t);
	addpage(dir, 0, "front", "some text");
	putfile(dir + "/page.txt", "TEMPLATE-TOP TITLE\nPAGE\nTEMPLATE-END\n");
	w := wikion(t, dir);
	wh := w->getcurrent(0);
	if(wh == nil)
		t.fatal("no page");
	s := w->totext(wh, wh.doc[0], Wiki->Tpage);
	t.assert(contains(s, "TEMPLATE-TOP front") && contains(s, "some text") && contains(s, "TEMPLATE-END"), "a page's text is set in page.txt: " + clip(s));
	s = w->totext(wh, wh.doc[0], Wiki->Thistory);
	t.assert(!contains(s, "TEMPLATE-TOP"), "a history's text (no history.txt here) in none");
	rmrf(dir);
}

testDiffBound(t: ref T)
{
	dir := hoststore(t);
	addpage(dir, 0, "busy page", "v0");
	h := "busy page\n";
	for(i := 0; i < 300; i++)
		h += sys->sprint("D%d\nAtest\n#version %d\n", 1000 + i, i);
	putfile(dir + "/d/0.hist", h);
	w := wikion(t, dir);
	wh := w->gethistory(0);
	if(wh == nil)
		t.fatal("no history");
	t.asserteq(wh.ndoc, 300, "a history of 300 versions read");
	t0 := sys->millisec();
	s := w->tohtml(wh, wh.doc[wh.ndoc-1], Wiki->Tdiff);
	ms := sys->millisec() - t0;
	nd := 0;
	for(i = 0; i + 8 <= len s; i++)
		if(s[i:i+8] == "<br><hr>")
			nd++;
	t.asserteq(nd, Wiki->Maxdiff, "its diff page compares the newest Maxdiff versions");
	t.assert(contains(s, "history.html"), "and names the history for the rest");
	t.log(sys->sprint("diff.html of 300 versions: %d ms, %d bytes", ms, len s));
	s = w->tohtml(wh, wh.doc[wh.ndoc-1], Wiki->Thistory);
	t.assert(contains(s, ">" + "Thu") || len s > 300*20, "the history lists them all");
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

	# a page the map names and no file holds (its write never came)
	putfile(dir + "/d/map", getfile(dir + "/d/map") + "9 never written\n");
	sys->sleep(100);
	fd := sys->open("/n/map", Sys->ORDWR);
	t.assert(fd != nil, "the map file opens");
	unmountwiki();
	mountwiki(t, dir);
	t.assert(!exists("/n/never_written/index.html") && !exists("/n/9"), "a title in the map with no page file is not found");
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

testPostRefusals(t: ref T)
{
	dir := hoststore(t);
	addpage(dir, 0, "front page", "the front page");
	mountwiki(t, dir);
	(name, err) := post("A new page", 0, "itstext\n");
	t.assertseq(name, "a_new_page", "a page posted: its name");
	t.assertnil(err, "taken");
	t.assert(contains(getfile("/n/a_new_page/index.html"), "itstext"), "and served");
	long := "";
	for(i := 0; i < 300; i++)
		long[i] = 'l';
	(name, err) = post(long, 0, "x\n");
	t.assert(name == nil && contains(err, "title too long"), "a title of 300 characters refused, saying so: " + err);
	(name, err) = post("Map", 0, "x\n");
	t.assert(name == nil && contains(err, "reserved"), "the title Map refused: " + err);
	(name, err) = post("42", 0, "x\n");
	t.assert(name == nil && contains(err, "digits"), "a title of digits refused: " + err);
	(name, err) = post("   ", 0, "x\n");
	t.assert(name == nil && err != nil, "a title of blanks refused: " + err);
	(name, err) = post("no text", 0, "");
	t.assert(name == nil && err != nil, "a page with no text refused: " + err);
	t.assertseq(getfile(dir + "/d/map"), "0 front page\n1 a new page\n", "the map has the one page added");

	# a header's last line of one byte and no newline: an error, where
	# the worker raised and the write was never answered
	fd := sys->open("/n/new", Sys->ORDWR);
	b := array of byte "one byte\nA";
	sys->write(fd, b, len b);
	t.assert(sys->write(fd, b, 0) != 0, sys->sprint("a message ending in a header line of one byte is answered (%r)"));
	fd = nil;

	# a file's length the same at each stat
	fd = sys->open("/n/0/index.html", Sys->OREAD);
	(nil, d1) := sys->fstat(fd);
	(nil, d2) := sys->fstat(fd);
	t.assert(d1.length > big 0 && d1.length == d2.length, sys->sprint("an open page's length is the same at a second stat (%bd, %bd)", d1.length, d2.length));
	fd = nil;
	unmountwiki();
	rmrf(dir);
}

# Two writers at once, each with the version the other has: one is the
# page, the other a conflict.
testSimultaneous(t: ref T)
{
	dir := hoststore(t);
	mountwiki(t, dir);
	(name, err) := post("race page", 0, "start\n");
	t.assert(name == "race_page" && err == nil, "a page made");
	both := none := 0;
	ROUNDS: con 30;
	for(i := 0; i < ROUNDS; i++){
		v := version("race_page");
		go := chan of int;
		res := chan of string;
		for(k := 0; k < 2; k++)
			spawn writer(go, res, v, sys->sprint("round %d writer %d\n", i, k));
		go <-= 1;
		go <-= 1;
		ok := 0;
		for(k = 0; k < 2; k++)
			if(<-res == nil)
				ok++;
		if(ok == 2)
			both++;
		if(ok == 0)
			none++;
	}
	t.asserteq(both, 0, sys->sprint("of %d pairs of edits of one version at once, those both taken", ROUNDS));
	t.asserteq(none, 0, "those neither taken");
	h := getfile("/n/race_page/history.txt");
	nc := 0;
	for(i = 0; i + 11 <= len h; i++)
		if(h[i:i+11] == "conflicting")
			nc++;
	t.asserteq(nc, ROUNDS, "each pair's other edit is in the history as a conflicting write");
	unmountwiki();
	rmrf(dir);
}

writer(go: chan of int, res: chan of string, v: int, text: string)
{
	<-go;
	(nil, err) := post("race page", v, text);
	res <-= err;
}

# ---- the server itself

# Progs that are wikifs's
# The wikifs processes among those made after pid "after": only theirs
# are read.  The suite's earlier tests leave Progs behind (3362 of them
# by here on macOS's Intel runner, interpreted), and reading every one's
# status, as this did, took the test past its deadline there.
wikiprogs(after: int): int
{
	n := 0;
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	for(;;){
		(k, d) := sys->dirread(fd);
		if(k <= 0)
			break;
		for(i := 0; i < k; i++){
			if(int d[i].name <= after)
				continue;
			s := getfile("/prog/" + d[i].name + "/status");
			if(contains(s, "Wikifs") && !contains(s, "WikifsTest") || contains(s, " Wiki") && !contains(s, "Wikifs"))
				n++;
		}
	}
	return n;
}

# The highest pid there is now; pids only grow
lastpid(): int
{
	last := 0;
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return 0;
	for(;;){
		(k, d) := sys->dirread(fd);
		if(k <= 0)
			break;
		for(i := 0; i < k; i++)
			if(int d[i].name > last)
				last = int d[i].name;
	}
	return last;
}

testEndsWithConnection(t: ref T)
{
	dir := hoststore(t);
	addpage(dir, 0, "front page", "the front page");
	after := lastpid();
	mountwiki(t, dir);
	for(i := 0; i < 5; i++)
		getfile("/n/0/index.html");
	post("another", 0, "text\n");
	t.assert(wikiprogs(after) > 0, "wikifs is running");
	unmountwiki();
	for(i = 0; i < 50 && wikiprogs(after) > 0; i++)
		sys->sleep(100);
	t.asserteq(wikiprogs(after), 0, "none of its processes is left when its connection has gone");
	rmrf(dir);
}

rpc(fd: ref Sys->FD, m: ref Tmsg): ref Rmsg
{
	b := m.pack();
	if(sys->write(fd, b, len b) != len b)
		return nil;
	rc := chan[1] of ref Rmsg;
	pidc := chan[1] of int;
	spawn rreader(fd, rc, pidc);
	pid := <-pidc;
	(tick, tpid) := timer(5000);
	alt {
	r := <-rc =>
		kill(tpid);
		return r;
	<-tick =>
		kill(pid);
		return nil;
	}
}

rreader(fd: ref Sys->FD, rc: chan of ref Rmsg, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	rc <-= Rmsg.read(fd, 0);
}

testStatBadFid(t: ref T)
{
	dir := hoststore(t);
	addpage(dir, 0, "front page", "the front page");
	fd := startwikifs(t, dir);
	r := rpc(fd, ref Tmsg.Version(Styx->NOTAG, 8192, "9P2000"));
	t.assert(r != nil && tagof r == tagof Rmsg.Version, "version");
	r = rpc(fd, ref Tmsg.Attach(1, 0, Styx->NOFID, "test", ""));
	t.assert(r != nil && tagof r == tagof Rmsg.Attach, "attach");
	r = rpc(fd, ref Tmsg.Stat(2, 99));
	t.assert(r != nil && tagof r == tagof Rmsg.Error, "a stat of a fid not in use is an error");
	r = rpc(fd, ref Tmsg.Stat(3, 0));
	t.assert(r != nil && tagof r == tagof Rmsg.Stat, "and the server answers the next request");
	fd = nil;
	rmrf(dir);
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
	run("Titles", testTitles);
	run("MapFull", testMapFull);
	run("DamagedStore", testDamagedStore);
	run("WriteChecked", testWriteChecked);
	run("PostRefusals", testPostRefusals);
	run("Simultaneous", testSimultaneous);
	run("TextTemplate", testTextTemplate);
	run("DiffBound", testDiffBound);
	run("StatBadFid", testStatBadFid);
	run("EndsWithConnection", testEndsWithConnection);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

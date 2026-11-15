implement CowfsControlTest;

#
# cowfs (appl/veltro/cowfs.b): what a task that holds the mount can do to
# the overlay's own records, and what a promote then does to the base.
#
# The overlay keeps three records in the directory the mount's writes land
# in: .cowmeta (the folder it stages for), .cowbase (what each base file
# was when first shadowed: the conflict check) and .whiteout (deletions).
# They were left out of listings and nothing else: through the mount a task
# read them, removed .cowbase (a promote then wrote over the user's newer
# edit), wrote .whiteout (deletions of its choosing) and gave .cowmeta
# another basepath, which the promoter took for the folder to write in.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "readdir.m";
	readdir: Readdir;

include "testing.m";
	testing: Testing;
	T: import testing;

include "cowfs.m";
	cowfs: Cowfs;

CowfsControlTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/cowfs_control_test.b";

passed := 0;
failed := 0;
skipped := 0;

TESTBASE: con "/tmp/veltro/cowctltest";

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

# --- helpers ---

setup(name: string): (string, string, string)
{
	root := TESTBASE + "/" + name;
	removetree(root);
	mkdirp(root + "/base");
	mkdirp(root + "/overlay");
	mkdirp(root + "/mnt");
	return (root + "/base", root + "/overlay", root + "/mnt");
}

mountcow(t: ref T, basedir, overlaydir, mntpoint: string)
{
	if(sys->bind(basedir, mntpoint, Sys->MREPL) < 0)
		t.fatal(sys->sprint("bind base to mnt: %r"));
	(mntfd, err) := cowfs->start(mntpoint, overlaydir);
	if(err != nil)
		t.fatal("cowfs start: " + err);
	if(sys->mount(mntfd, nil, mntpoint, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("cowfs mount: %r"));
}

unmountcow(mntpoint: string)
{
	sys->unmount(nil, mntpoint);	# the server
	sys->unmount(nil, mntpoint);	# the base under it
}

writefile(path, content: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return -1;
	data := array of byte content;
	return sys->write(fd, data, len data);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

isdir(path: string): int
{
	(ok, d) := sys->stat(path);
	return ok >= 0 && (d.mode & Sys->DMDIR);
}

mkdirp(path: string)
{
	if(exists(path))
		return;
	for(i := len path - 1; i > 0; i--)
		if(path[i] == '/') {
			mkdirp(path[0:i]);
			break;
		}
	sys->create(path, Sys->OREAD, 8r755 | Sys->DMDIR);
}

removetree(path: string)
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return;
	if(d.mode & Sys->DMDIR) {
		(dirs, n) := readdir->init(path, Readdir->NONE);
		for(i := 0; i < n; i++)
			removetree(path + "/" + dirs[i].name);
	}
	sys->remove(path);
}

names(path: string): string
{
	(dirs, n) := readdir->init(path, Readdir->NAME);
	s := "";
	for(i := 0; i < n; i++)
		s += dirs[i].name + " ";
	return s;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

hassuffix(s, suf: string): int
{
	return len s >= len suf && s[len s - len suf:] == suf;
}

inlist(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

RECORDS := array[] of {".cowmeta", ".cowbase", ".whiteout"};

# Names a host file system that folds names would open a record by.
ALIASES := array[] of {
	".COWMETA", ".CowMeta", ".cowmeta.", ".cowmeta ", ".cowmeta. .",
	".COWBASE", ".cowbase.", ".WHITEOUT", ".whiteout..", ".Whiteout ",
};

# --- tests ---

# No walk reaches a record, nothing is made or removed under its name,
# and the overlay's files are as they were.
testRecordsNotReached(t: ref T)
{
	(basedir, overlaydir, mntpoint) := setup("records");
	victim := TESTBASE + "/records/victim";
	mkdirp(victim);
	writefile(basedir + "/doc.txt", "v1");
	writefile(basedir + "/gone.txt", "to be removed");
	mkdirp(basedir + "/sub");
	mountcow(t, basedir, overlaydir, mntpoint);

	# So that all three records exist.
	t.assert(writefile(mntpoint + "/doc.txt", "v1 task") > 0, "the task writes a file");
	t.asserteq(sys->remove(mntpoint + "/gone.txt"), 0, "the task removes a file");
	before := array[len RECORDS] of string;
	for(i := 0; i < len RECORDS; i++) {
		before[i] = readfile(overlaydir + "/" + RECORDS[i]);
		t.assert(before[i] != nil && before[i] != "", RECORDS[i] + " is kept in the overlay");
	}

	forged := "basepath=" + victim + "\n";
	for(i = 0; i < len RECORDS; i++) {
		r := RECORDS[i];
		p := mntpoint + "/" + r;
		t.assert(!exists(p), r + " is not found by stat");
		t.assert(sys->open(p, Sys->OREAD) == nil, r + " is not opened to read");
		t.assert(sys->open(p, Sys->OWRITE) == nil, r + " is not opened to write");
		t.assert(sys->open(p, Sys->OWRITE|Sys->OTRUNC) == nil, r + " is not truncated");
		t.assert(writefile(p, forged) < 0, r + " is not made again");
		t.assert(sys->create(p, Sys->OREAD, 8r755|Sys->DMDIR) == nil, r + " is not made as a directory");
		t.assert(sys->remove(p) < 0, r + " is not removed");
		# by other walks to the same place
		t.assert(sys->open(mntpoint + "/sub/../" + r, Sys->OREAD) == nil, r + " is not reached through ..");
		t.assert(sys->open(mntpoint + "/./" + r, Sys->OREAD) == nil, r + " is not reached through .");
		# nor by a rename onto its name
		d := sys->nulldir;
		d.name = r;
		t.assert(sys->wstat(mntpoint + "/doc.txt", d) < 0, "no file is renamed to " + r);
	}
	for(i = 0; i < len ALIASES; i++) {
		p := mntpoint + "/" + ALIASES[i];
		t.assert(sys->open(p, Sys->OREAD) == nil, "'" + ALIASES[i] + "' is not opened");
		t.assert(writefile(p, forged) < 0, "'" + ALIASES[i] + "' is not made");
	}
	listing := names(mntpoint);
	for(i = 0; i < len RECORDS; i++) {
		t.assert(!contains(listing, RECORDS[i]), RECORDS[i] + " is not listed");
		t.assertseq(readfile(overlaydir + "/" + RECORDS[i]), before[i], RECORDS[i] + " is as it was");
	}
	t.assert(!contains(names(overlaydir), "COW") && !contains(names(overlaydir), "cowmeta."),
		"nothing was made beside the records: " + names(overlaydir));

	# What the overlay says its folder is has not moved, and a promote
	# writes there and nowhere else.
	t.assert(contains(readfile(overlaydir + "/.cowmeta"), "basepath=" + mntpoint + "\n"),
		"the overlay still names its own folder");
	unmountcow(mntpoint);
	(n, err) := cowfs->promote(basedir, overlaydir);
	t.assert(err == nil, "promote: " + err);
	t.asserteq(n, 2, "the change and the removal are applied");
	t.assertseq(readfile(basedir + "/doc.txt"), "v1 task", "the change is in the folder");
	t.assert(!exists(basedir + "/gone.txt"), "the removal is in the folder");
	t.assertseq(names(victim), "", "nothing is written anywhere else");
}

# The conflict check cannot be switched off from inside the mount.
testConflictRecordKept(t: ref T)
{
	(basedir, overlaydir, mntpoint) := setup("conflict");
	writefile(basedir + "/doc.txt", "v1");
	mountcow(t, basedir, overlaydir, mntpoint);

	writefile(mntpoint + "/doc.txt", "task's version made from v1");
	sys->sleep(1100);	# a later mtime, as an edit at another time has
	writefile(basedir + "/doc.txt", "v2 the user's newer edit");

	t.assert(sys->remove(mntpoint + "/.cowbase") < 0, "the task does not remove .cowbase");
	t.assert(writefile(mntpoint + "/.cowbase", "\n") < 0, "nor empty it");
	unmountcow(mntpoint);

	(n, err) := cowfs->promote(basedir, overlaydir);
	t.asserteq(n, 0, "nothing is applied over the user's edit");
	t.assert(err != nil && contains(err, "doc.txt"), "the conflict is said: " + err);
	t.assertseq(readfile(basedir + "/doc.txt"), "v2 the user's newer edit", "the user's edit is kept");
}

# No deletion is staged by writing the whiteout list.
testNoForgedWhiteout(t: ref T)
{
	(basedir, overlaydir, mntpoint) := setup("whiteout");
	writefile(basedir + "/keep", "the user's file");
	writefile(basedir + "/other", "x");
	mountcow(t, basedir, overlaydir, mntpoint);

	t.assert(writefile(mntpoint + "/.whiteout", "keep\n") < 0, "the task does not write .whiteout");
	t.asserteq(sys->remove(mntpoint + "/other"), 0, "it removes a file");
	t.assert(writefile(mntpoint + "/.whiteout", "keep\nother\n") < 0, "nor once .whiteout exists");
	unmountcow(mntpoint);

	d := cowfs->diff(overlaydir);
	t.assert(!inlist("D keep", d), "no deletion of keep is staged");
	(nil, err) := cowfs->promote(basedir, overlaydir);
	t.assert(err == nil, "promote: " + err);
	t.assert(exists(basedir + "/keep"), "keep is still there");
	t.assert(!exists(basedir + "/other"), "the file the task removed is gone");
}

# A record's name below the root is a file like any other.
testDotfileBelowRoot(t: ref T)
{
	(basedir, overlaydir, mntpoint) := setup("below");
	mkdirp(basedir + "/sub");
	mountcow(t, basedir, overlaydir, mntpoint);

	t.assert(writefile(mntpoint + "/sub/.cowmeta", "a project's own file") > 0, "sub/.cowmeta is made");
	t.assertseq(readfile(mntpoint + "/sub/.cowmeta"), "a project's own file", "and read back");
	t.assert(contains(names(mntpoint + "/sub"), ".cowmeta"), "and listed");
	unmountcow(mntpoint);

	t.assert(inlist("A sub/.cowmeta", cowfs->diff(overlaydir)), "it is in the diff");
	(n, err) := cowfs->promote(basedir, overlaydir);
	t.assert(err == nil, "promote: " + err);
	t.asserteq(n, 1, "it is promoted");
	t.assertseq(readfile(basedir + "/sub/.cowmeta"), "a project's own file", "to the folder");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	readdir = load Readdir Readdir->PATH;
	if(readdir == nil)
		raise "fail:cannot load readdir";
	cowfs = load Cowfs Cowfs->PATH;
	if(cowfs == nil) {
		sys->fprint(sys->fildes(2), "cannot load cowfs module: %r\n");
		raise "fail:cannot load cowfs";
	}

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	mkdirp(TESTBASE);

	run("RecordsNotReached", testRecordsNotReached);
	run("ConflictRecordKept", testConflictRecordKept);
	run("NoForgedWhiteout", testNoForgedWhiteout);
	run("DotfileBelowRoot", testDotfileBelowRoot);

	removetree(TESTBASE);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

implement ToolsTruthTest;

#
# What the agent's file tools answer when the answer is not the usual one:
# a model, and the person reading over its shoulder, act on these words.
#
# read    a limit lifted the bound on bytes (5000 long lines came back
#         whole); a directory was read as a file; a number that was none
#         was read as 0; a file with no end was read for ever to count
#         its lines.
# edit    a file with bytes that are not UTF-8 was rewritten with each
#         such byte replaced, in lines the edit did not name; an empty
#         file was "cannot read", with another call's error; "new": null
#         put in the word null; old and new given beside edits shifted
#         the numbering of edits[] in errors.
# grep    a path that does not exist was "no matches found"; each file
#         had the limit on matches to itself; the depth limit was never
#         applied.
# find    with no path, names were joined to "." (".lib"), so nothing
#         below the first level was found; an option it does not have was
#         passed over and its argument searched; -iname matched case; a
#         path that does not exist was "no matches found"; what stopped a
#         search was not said.
# launch  what the presentation zone answered was not looked at: a
#         launch it refused was "launched"; data given with xenith was
#         dropped and reported delivered.
# shell   a transcript beginning "error:" was a shell not running; a
#         character lying across two reads came out as two wrong ones;
#         the whole transcript was returned however long.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

Tool: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
};

ToolsTruthTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tools_truth_test.b";

passed := 0;
failed := 0;
skipped := 0;

top: string;	# scratch, in the tools' workspace so that edit and write take it

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

loadtool(t: ref T, name: string): Tool
{
	mod := load Tool "/dis/veltro/tools/" + name + ".dis";
	if(mod == nil)
		t.fatal(sprint("cannot load the %s tool: %r", name));
	err := mod->init();
	if(err != nil)
		t.fatal(name + " init: " + err);
	return mod;
}

mkdir(path: string)
{
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

putb(path: string, b: array of byte)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd != nil)
		sys->write(fd, b, len b);
}

put(path, s: string)
{
	putb(path, array of byte s);
}

slurpb(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	data := array[0] of byte;
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0) {
		nd := array[len data + n] of byte;
		nd[0:] = data;
		nd[len data:] = buf[0:n];
		data = nd;
	}
	return data;
}

slurp(path: string): string
{
	return string slurpb(path);
}

cleanup(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		sys->remove(path);
		return;
	}
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			child := path + "/" + dirs[i].name;
			if(dirs[i].qid.qtype & Sys->QTDIR)
				cleanup(child);
			else
				sys->remove(child);
		}
	}
	fd = nil;
	sys->remove(path);
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

iserror(s: string): int
{
	return len s >= 6 && s[0:6] == "error:";
}

nlines(s: string): int
{
	n := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			n++;
	return n;
}

# a tool's answer, or nil if it has none after ms
call(tool: Tool, args: string, ms: int): string
{
	done := chan[1] of string;
	spawn callone(tool, args, done);
	tick := chan[1] of int;
	spawn timer(tick, ms);
	alt {
	r := <-done =>
		return r;
	<-tick =>
		return nil;
	}
}

callone(tool: Tool, args: string, done: chan of string)
{
	done <-= tool->exec(args);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# --- read ---

endless(fio: ref Sys->FileIO)
{
	text := "";
	for(i := 0; i < 200; i++)
		text += "one more line of a file that has no end\n";
	chunk := array of byte text;
	for(;;) alt {
	(nil, count, nil, rc) := <-fio.read =>
		if(rc != nil) {
			if(count > len chunk)
				count = len chunk;
			rc <-= (chunk[0:count], nil);
		}
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "no");
	}
}

broken(fio: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-fio.read =>
		if(rc != nil)
			rc <-= (nil, "the disk is on fire");
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "no");
	}
}

testRead(t: ref T)
{
	read := loadtool(t, "read");
	dir := top + "/read";
	mkdir(dir);

	# 5000 lines of 80 characters, 400K
	line := "";
	for(i := 0; i < 79; i++)
		line[len line] = 'a' + i % 26;
	line += "\n";
	block := "";
	for(i = 0; i < 100; i++)
		block += line;
	bb := array of byte block;
	fd := sys->create(dir + "/big.txt", Sys->OWRITE, 8r644);
	for(i = 0; i < 50; i++)
		sys->write(fd, bb, len bb);
	fd = nil;

	r := read->exec(dir + "/big.txt 0 5000");
	t.assert(len r <= 125000, sprint("a read with a limit is bounded in bytes: %d came back", len r));
	t.assert(contains(r, "of 5000.") && contains(r, "read again with offset"), "and says how many lines there are and where to go on");
	r = read->exec(dir + "/big.txt");
	t.assert(len r <= 31000, sprint("a read without one is 30000 bytes: %d came back", len r));
	t.assert(contains(r, "of 5000."), "and counts the file's lines: " + r[len r - 80:]);

	put(dir + "/five.txt", "1\n2\n3\n4\n5");
	r = read->exec(dir + "/five.txt 0 2");
	t.assert(contains(r, "[lines 1-2 of 5."), "the count of a file whose last line has no newline: " + r);
	put(dir + "/five.txt", "1\n2\n3\n4\n5\n");
	r = read->exec(dir + "/five.txt 1 2");
	t.assert(contains(r, "[lines 2-3 of 5."), "and of one that has: " + r);
	r = read->exec(dir + "/five.txt");
	t.assert(contains(r, "    5\t5") && !contains(r, "read again"), "a short file is read whole: " + r);

	r = read->exec(dir);
	t.assert(iserror(r) && contains(r, "directory"), "a directory is not read as a file: " + r);

	r = read->exec(dir + "/five.txt abc");
	t.assert(iserror(r), "an offset that is no number is an error: " + r);
	r = read->exec(dir + "/five.txt 0 many");
	t.assert(iserror(r), "a limit that is no number is an error: " + r);
	put(dir + "/my", "the wrong file\n");
	r = read->exec(dir + "/my file.txt");
	t.assert(iserror(r) && !contains(r, "the wrong file"), "a path with a blank in it is not read as its first word: " + r);

	# one line of 300000 characters and no newline
	long := "";
	for(i = 0; i < 3000; i++)
		long += "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789";
	put(dir + "/long.txt", long);
	r = read->exec(dir + "/long.txt");
	t.assert(contains(r, "[line cut: 300000 characters]") && len r < 4000, sprint("a long line is cut and its length said: %d came back", len r));

	# a file with no end, and one whose reads fail
	if(sys->bind("#s", dir, Sys->MBEFORE) < 0)
		t.skip(sprint("cannot bind #s: %r"));
	fio := sys->file2chan(dir, "endless");
	bio := sys->file2chan(dir, "broken");
	if(fio == nil || bio == nil)
		t.skip(sprint("file2chan: %r"));
	spawn endless(fio);
	spawn broken(bio);
	r = read->exec(dir + "/broken");
	t.assert(iserror(r) && contains(r, "the disk is on fire"), "a file that cannot be read is an error, not an empty file: " + r);
	r = call(read, dir + "/endless", 60000);
	t.assert(r != nil, "a file with no end is not read for ever");
	if(r != nil)
		t.assert(contains(r, "of more than "), "and the count of its lines says it goes on: " + r[len r - 90:]);
}

# --- edit ---

testEdit(t: ref T)
{
	edit := loadtool(t, "edit");
	dir := top + "/edit";
	mkdir(dir);

	# bytes that are not UTF-8, in a line the edit does not name
	latin := array[] of {byte 'A', byte 16rff, byte 'B', byte '\n',
		byte 's', byte 'e', byte 'c', byte 'o', byte 'n', byte 'd', byte '\n'};
	putb(dir + "/latin.txt", latin);
	r := edit->exec(dir + "/latin.txt second SECOND");
	t.assert(iserror(r) && contains(r, "UTF-8"), "a file with bytes that are not UTF-8 is not edited: " + r);
	got := slurpb(dir + "/latin.txt");
	same := len got == len latin;
	for(i := 0; same && i < len got; i++)
		same = got[i] == latin[i];
	t.assert(same, "and its bytes are as they were");

	put(dir + "/empty.txt", "");
	r = edit->exec(dir + "/empty.txt x y");
	t.assert(iserror(r) && contains(r, "is empty"), "an empty file is said to be empty: " + r);

	put(dir + "/null.txt", "keep abc keep\n");
	r = edit->exec("-j " + dir + "/null.txt {\"old\":\" abc\",\"new\":null}");
	t.assertseq(slurp(dir + "/null.txt"), "keep keep\n", "\"new\": null takes the text out: " + r);

	put(dir + "/both.txt", "one two three\n");
	r = edit->exec("-j " + dir + "/both.txt {\"old\":\"one\",\"new\":\"1\",\"edits\":[{\"old\":\"nothere\",\"new\":\"x\"}]}");
	t.assert(iserror(r) && contains(r, "not both"), "old and new beside edits are refused: " + r);
	t.assertseq(slurp(dir + "/both.txt"), "one two three\n", "and nothing is changed");

	# and an ordinary edit is made
	put(dir + "/plain.txt", "alpha beta\n");
	r = edit->exec(dir + "/plain.txt beta gamma");
	t.assertseq(slurp(dir + "/plain.txt"), "alpha gamma\n", "an ordinary edit: " + r);
	r = edit->exec(dir);
	t.assert(iserror(r), "a directory is not edited: " + r);
}

# --- grep ---

testGrep(t: ref T)
{
	grep := loadtool(t, "grep");
	dir := top + "/grep";
	mkdir(dir);

	r := grep->exec("x " + dir + "/nonexistent");
	t.assert(iserror(r) && contains(r, "cannot search"), "a path that does not exist is an error: " + r);
	put(dir + "/plain.txt", "nothing here\n");
	r = grep->exec("needle " + dir + "/plain.txt");
	t.assertseq(r, "no matches found", "a file without the pattern has no matches");

	# three files of 150 matching lines: 200 are reported, and said to be
	body := "";
	for(i := 0; i < 150; i++)
		body += sprint("needle %d\n", i);
	mkdir(dir + "/many");
	put(dir + "/many/a.txt", body);
	put(dir + "/many/b.txt", body);
	put(dir + "/many/c.txt", body);
	r = grep->exec("-r needle " + dir + "/many");
	t.assert(nlines(r) <= 202, sprint("matches are limited across files, not for each: %d lines came back", nlines(r)));
	t.assert(contains(r, "200 matches") && contains(r, "there may be more"), "and the answer says where it stopped: " + r[len r - 80:]);

	# a file 25 directories down is past the depth searched, and that is said
	deep := dir + "/deep";
	mkdir(deep);
	for(i = 0; i < 25; i++) {
		deep += "/d";
		mkdir(deep);
	}
	put(deep + "/far.txt", "needle\n");
	r = grep->exec("-r needle " + dir + "/deep");
	t.assert(!contains(r, "far.txt"), "directories are followed to a depth and no further: " + r);
	t.assert(contains(r, "not looked into"), "and a search that stopped short says so: " + r);

	# a long line is matched, to a length
	long := "needle";
	for(i = 0; i < 2000; i++)
		long += " 0123456789";
	put(dir + "/long.txt", long + " tail\n");
	r = grep->exec("needle " + dir + "/long.txt");
	t.assert(contains(r, "1 matches") && len r < 1000, "a long line is matched and shown cut: " + r[0:60]);
}

# --- find ---

testFind(t: ref T)
{
	find := loadtool(t, "find");
	dir := top + "/find";
	mkdir(dir);
	mkdir(dir + "/sub");
	mkdir(dir + "/sub/deep");
	put(dir + "/sub/deep/target.txt", "x\n");
	put(dir + "/top.txt", "x\n");

	# with no path: the current directory, whole
	here := sys->fd2path(sys->open(".", Sys->OREAD));
	if(sys->chdir(dir) < 0)
		t.fatal(sprint("chdir: %r"));
	r := find->exec("target.txt");
	sys->chdir(here);
	t.assert(contains(r, dir + "/sub/deep/target.txt"), "with no path the current directory is searched, below its first level too: " + r);
	t.assert(!contains(r, "\n."), "and no name is made of a dot and a name: " + r);

	r = find->exec("target.txt " + dir);
	t.assert(contains(r, dir + "/sub/deep/target.txt"), "with a path: " + r);

	r = find->exec(dir + " -type f");
	t.assert(iserror(r) && contains(r, "-type"), "an option find does not have is an error: " + r);
	r = find->exec(dir + " -name");
	t.assert(iserror(r), "-name with nothing after it is an error: " + r);
	r = find->exec(dir + " -iname TARGET.TXT");
	t.assert(contains(r, "target.txt"), "-iname matches without regard to case: " + r);
	r = find->exec(dir + " -name TARGET.TXT");
	t.assert(!contains(r, "target.txt"), "-name does not: " + r);

	r = find->exec("x " + dir + "/nonexistent");
	t.assert(iserror(r) && contains(r, "cannot search"), "a path that does not exist is an error: " + r);
	r = find->exec("x " + dir + "/top.txt");
	t.assert(iserror(r) && contains(r, "not a directory"), "a file is not searched as a directory: " + r);

	deep := dir + "/far";
	mkdir(deep);
	for(i := 0; i < 25; i++) {
		deep += "/d";
		mkdir(deep);
	}
	put(deep + "/farthest.txt", "x\n");
	r = find->exec("farthest.txt " + dir + "/far");
	t.assert(contains(r, "no matches found") && contains(r, "deep were not entered"), "a search that did not go all the way down says so: " + r);

	mkdir(dir + "/many");
	for(i = 0; i < 120; i++)
		put(dir + sprint("/many/m%d.txt", i), "");
	r = find->exec("m*.txt " + dir + "/many");
	t.assert(contains(r, "100 matches") && contains(r, "stopped at 100 results"), "more results than are returned are said to be: " + r[len r - 80:]);
}

# --- launch ---

# the presentation zone's ctl: takes the first create of an id, refuses
# the second as luciuisrv does, and anything of "full" as too many
Zone: adt {
	cmds:	list of string;
	have:	list of string;
};

zoneserve(fio: ref Sys->FileIO, z: ref Zone)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-fio.read =>
		if(rc != nil)
			rc <-= (nil, nil);
	(nil, data, nil, wc) := <-fio.write =>
		if(wc == nil)
			continue;
		cmd := string data;
		z.cmds = cmd :: z.cmds;
		err: string;
		if(len cmd > 10 && cmd[0:10] == "create id=") {
			id := cmd[10:];
			for(i := 0; i < len id; i++)
				if(id[i] == ' ') {
					id = id[0:i];
					break;
				}
			for(h := z.have; h != nil; h = tl h)
				if(hd h == id)
					err = "artifact already exists";
			if(id == "bounce")
				err = "too many artifacts";
			if(err == nil)
				z.have = id :: z.have;
		}
		if(err != nil)
			wc <-= (0, err);
		else
			wc <-= (len data, nil);
	}
}

testLaunch(t: ref T)
{
	launch := loadtool(t, "launch");
	(ok, nil) := sys->stat("/dis/wm/clock.dis");
	if(ok < 0)
		t.skip("no /dis/wm/clock.dis");

	ui := top + "/ui";
	mkdir(ui);
	mkdir(ui + "/activity");
	mkdir(ui + "/activity/0");
	mkdir(ui + "/activity/0/presentation");
	if(sys->bind("#s", ui + "/activity/0/presentation", Sys->MREPL) < 0)
		t.skip(sprint("cannot bind #s: %r"));
	fio := sys->file2chan(ui + "/activity/0/presentation", "ctl");
	if(fio == nil)
		t.skip(sprint("file2chan: %r"));
	z := ref Zone(nil, nil);
	spawn zoneserve(fio, z);
	if(sys->bind(ui, "/mnt/ui", Sys->MREPL) < 0)
		t.skip(sprint("cannot bind /mnt/ui: %r"));

	r := launch->exec("clock");
	t.assertseq(r, "launched clock in presentation zone", "an app the zone takes is launched");
	r = launch->exec("clock");
	t.assert(!contains(r, "launched clock in presentation zone") && contains(r, "already open"),
		"one already open is said to be, not launched again: " + r);
	r = launch->exec("bounce");
	t.assert(iserror(r) && contains(r, "too many artifacts"), "a launch the zone refuses is an error, with the zone's reason: " + r);

	n := len z.cmds;
	r = launch->exec("xenith /some/file");
	t.assert(iserror(r) && !contains(r, "with url"), "data is not said to be given to an app that takes none: " + r);
	r = launch->exec("clock!x");
	t.assert(iserror(r), "a name that is no app's is an error: " + r);
	t.asserteq(len z.cmds, n, "and neither reaches the presentation zone");
}

# --- shell ---

testShell(t: ref T)
{
	shell := loadtool(t, "shell");
	dir := top + "/shell";
	mkdir(dir);
	if(sys->bind(dir, "/mnt/shell", Sys->MREPL) < 0)
		t.skip(sprint("cannot bind /mnt/shell: %r"));

	r := shell->exec("status");
	t.assert(contains(r, "not running"), "with no transcript file the shell is not running: " + r);
	r = shell->exec("read");
	t.assert(iserror(r), "and a read says so: " + r);

	put(dir + "/input", "ls -l");
	put(dir + "/body", "error: this is what a command printed\nsecond line\nthird line\n");
	r = shell->exec("status");
	t.assert(contains(r, "shell is running") && contains(r, "ls -l"), "a transcript that begins error: is a shell that is running: " + r);
	r = shell->exec("tail 1");
	t.assertseq(r, "third line", "and its tail is its last line");
	r = shell->exec("read");
	t.assert(contains(r, "error: this is what a command printed\nsecond line"), "and it is read as it is: " + r);

	# a character lying across the 8192nd byte
	s := "";
	for(i := 0; i < 8191; i++)
		s[len s] = 'a';
	s += "é after\n";
	put(dir + "/body", s);
	r = shell->exec("read");
	t.assert(contains(r, "aé after") && !contains(r, "�"), "a character lying across two reads is one character");

	# 600K of transcript: its end comes back, and that is said
	line := "a line of the transcript, forty bytes..\n";
	chunk := "";
	for(i = 0; i < 1000; i++)
		chunk += line;
	fd := sys->create(dir + "/body", Sys->OWRITE, 8r644);
	cb := array of byte chunk;
	for(i = 0; i < 15; i++)
		sys->write(fd, cb, len cb);
	sys->fprint(fd, "the last line\n");
	fd = nil;
	r = shell->exec("read");
	t.assert(len r <= 270000, sprint("a long transcript is returned to a length: %d came back", len r));
	t.assert(contains(r, "the last line\n") && contains(r, "its last"), "its end, and said to be: " + r[0:70]);
	r = shell->exec("tail 2");
	t.assertseq(r, "a line of the transcript, forty bytes..\nthe last line", "and its tail is still its last lines");
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

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	# a name space of the test's own: files stand in for tools9p, the
	# presentation zone and the shell's window
	sys->pctl(Sys->FORKNS, nil);
	mkdir("/tmp/veltro");
	mkdir("/tmp/veltro/scratch");
	top = "/tmp/veltro/scratch/tools_truth_test." + string sys->pctl(0, nil);
	cleanup(top);
	mkdir(top);
	mkdir(top + "/tool");
	put(top + "/tool/activity", "0");
	put(top + "/tool/paths", "");
	if(sys->bind(top + "/tool", "/tool", Sys->MREPL) < 0) {
		sys->fprint(sys->fildes(2), "cannot bind /tool: %r\n");
		raise "fail:bind";
	}

	run("Read", testRead);
	run("Edit", testEdit);
	run("Grep", testGrep);
	run("Find", testFind);
	run("Launch", testLaunch);
	run("Shell", testShell);

	cleanup(top);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

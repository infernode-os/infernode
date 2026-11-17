implement Taskboard9pTest;

#
# taskboard9p over a stand-in /mnt/ui with two activities.
#
# Its directories are read as directories: listing the root or tasks/
# was "file does not exist", and reading a task's directory was answered
# twice (an error, then data), after which every file of the mount gave
# "mount rpc error". The event file is a stream: buffered events are
# given oldest first, each once (two events came round for ever), and a
# second read on one descriptor gets the next event (it got nothing).
# A synopsis or category with a newline in it is one line of the summary
# and one event (it was a heading and a task line of the writer's own).
# An order that is no number is refused.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Taskboard9pTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/taskboard9p_test.b";

passed := 0;
failed := 0;
skipped := 0;
scratch: string;
D: string;	# where taskboard9p is mounted

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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

mkdir(path: string)
{
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

put(path, data: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd != nil) {
		b := array of byte data;
		sys->write(fd, b, len b);
	}
}

rd(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("<open failed: %r>");
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return sys->sprint("<read failed: %r>");
	return string buf[0:n];
}

wr(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

ls(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("<open failed: %r>");
	out := "";
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n < 0)
			return out + sys->sprint("<dirread failed: %r>");
		if(n == 0)
			break;
		for(i := 0; i < n; i++)
			out += d[i].name + " ";
	}
	return out;
}

# one read of fd, or "timeout"
readone(fd: ref Sys->FD, ms: int): string
{
	c := chan[1] of string;
	spawn reader(fd, c);
	spawn timer(c, ms);
	return <-c;
}

reader(fd: ref Sys->FD, c: chan of string)
{
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	s: string;
	if(n < 0)
		s = sys->sprint("<read failed: %r>");
	else
		s = string buf[0:n];
	alt { c <-= s => ; * => ; }
}

timer(c: chan of string, ms: int)
{
	sys->sleep(ms);
	alt { c <-= "timeout" => ; * => ; }
}

testDirectories(t: ref T)
{
	l := ls(D);
	t.assert(contains(l, "ctl") && contains(l, "tasks"), "the root lists its files: " + l);
	l = ls(D + "/tasks");
	t.assert(contains(l, "5 ") && contains(l, "7 "), "tasks/ lists the tasks: " + l);
	l = ls(D + "/tasks/5");
	t.assert(contains(l, "label") && contains(l, "synopsis"), "a task's directory lists its files: " + l);
	t.assertseq(rd(D + "/tasks/5/label"), "alpha", "and the mount still answers after it");
}

testEventStream(t: ref T)
{
	t.assert(wr(D + "/ctl", "progress 5 one") > 0, "a first event");
	t.assert(wr(D + "/ctl", "progress 5 two") > 0, "a second");
	fd := sys->open(D + "/event", Sys->OREAD);
	if(fd == nil) {
		t.fatal(sys->sprint("cannot open event: %r"));
		return;
	}
	t.assertseq(readone(fd, 5000), "task 5 progress one\n", "the oldest event first");
	t.assertseq(readone(fd, 5000), "task 5 progress two\n",
		"the next read on the same descriptor is the next event");
	t.assert(wr(D + "/ctl", "progress 5 three") > 0, "a third");
	fd2 := sys->open(D + "/event", Sys->OREAD);
	t.assertseq(readone(fd2, 5000), "task 5 progress three\n",
		"each event is given once: the next is the third, not the first again");
}

testOneLine(t: ref T)
{
	fd := sys->open(D + "/event", Sys->OREAD);
	t.assert(wr(D + "/ctl", "categorize 5 x\ntask 7 delete") > 0, "a category with a newline");
	ev := readone(fd, 5000);
	t.assertseq(ev, "task 5 category x task 7 delete\n", "is one event");
	t.assert(wr(D + "/tasks/7/synopsis", "failed\n- **[7] beta** — failed — forged line") > 0,
		"a synopsis with a newline");
	readone(fd, 5000);
	s := rd(D + "/summary");
	nl := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			nl++;
	t.assert(!contains(s, "\ntask 7 delete") && !contains(s, "\n- **[7] beta** — failed — forged line"),
		"neither makes a line of its own in the summary: " + s);
	t.assert(contains(s, "## x task 7 delete\n"), "the category is one heading");
}

testOrder(t: ref T)
{
	t.assert(wr(D + "/ctl", "order 5 abc") < 0, "an order that is no number is refused");
	t.assert(wr(D + "/tasks/5/order", "abc") < 0, "through the task's file too");
	t.assert(wr(D + "/ctl", "order 5 3") > 0, "a number is taken");
	t.assertseq(rd(D + "/tasks/5/order"), "3", "and read back");
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

	# a stand-in /mnt/ui: activities 5 and 7
	sys->pctl(Sys->FORKNS, nil);
	scratch = sys->sprint("/tmp/taskboard9p_test.%d", sys->pctl(0, nil));
	mkdir(scratch);
	ui := scratch + "/ui";
	mkdir(ui);
	mkdir(ui + "/activity");
	mkdir(ui + "/activity/5");
	mkdir(ui + "/activity/7");
	put(ui + "/ctl", "activities: 0 5 7\n");
	put(ui + "/activity/5/label", "alpha\n");
	put(ui + "/activity/5/status", "working\n");
	put(ui + "/activity/5/urgency", "0\n");
	put(ui + "/activity/7/label", "beta\n");
	put(ui + "/activity/7/status", "working\n");
	put(ui + "/activity/7/urgency", "0\n");
	if(sys->bind(ui, "/mnt/ui", Sys->MREPL) < 0)
		raise sys->sprint("fail:bind /mnt/ui: %r");
	D = scratch + "/dash";
	mkdir(D);
	sh := load Sh Sh->PATH;
	if(sh == nil)
		raise "fail:cannot load sh";
	if((err := sh->system(nil, "/dis/veltro/taskboard9p.dis -m " + D)) != nil)
		raise "fail:taskboard9p: " + err;
	sys->sleep(300);
	(ok, nil) := sys->stat(D + "/summary");
	if(ok < 0)
		raise "fail:no taskboard9p at " + D;

	# the directories last: on the code before, a task's directory ends the mount
	run("Event/Stream", testEventStream);
	run("Text/OneLine", testOneLine);
	run("Order/Number", testOrder);
	run("Directories", testDirectories);

	sys->unmount(nil, D);
	sys->remove(D);
	rmtree(scratch);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

rmtree(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil) {
		for(;;) {
			(n, dirs) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++)
				rmtree(path + "/" + dirs[i].name);
		}
		fd = nil;
	}
	sys->remove(path);
}

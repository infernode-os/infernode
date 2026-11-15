implement XenithToolTest;

#
# The xenith tool's own checks, against a /chan of plain files that only
# hold what a window would and keep what is written to them.
#
# - Reading a window's body is allowed when the file the window shows is
#   in the agent's name space.  An unnamed window's tag begins with its
#   commands, "Del Snarf ...", so "Del" was taken for the file and looked
#   up in the tool's working directory: an agent with a file of that name
#   there read every unnamed window.  A name that is not an absolute path
#   is no file.
# - A directory's +Errors window is readable when the directory is: the
#   test compared "/+Errors", eight characters, with the name's last
#   seven, so it never held.
# - A window is named by its number.  "new" is a name in /chan too, and
#   reading its tag made a window, as often as asked.
# - Errors and Agent are Xenith's own window names; an agent's window is
#   not given one.
# - A request to a window's ctl is one 9P message: Xenith runs each
#   message as it comes, and only the first word of a line was checked,
#   so a line longer than a message ended in a command of the agent's
#   choice ("name <file>", "put"), which the tool otherwise refuses.
# - create says when the window could not be named; delete says when it
#   could not be deleted.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Tool: module {
	init: fn(): string;
	exec: fn(args: string): string;
};

XenithToolTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE:	con "/tests/xenith_tool_test.b";
FAKE:		con "/tmp/xenith_tool_test";

passed := 0;
failed := 0;
skipped := 0;

tool: Tool;

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

mkdir(path: string)
{
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r777);
}

mkfile(path, data: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd != nil && data != nil)
		sys->fprint(fd, "%s", data);
}

readall(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i + len sub] == sub)
			return 1;
	return 0;
}

fill(n: int, c: int): string
{
	s := "";
	for(i := 0; i < n; i++)
		s[len s] = c;
	return s;
}

# a window: its tag and body, an empty ctl
window(id, tag, body: string)
{
	mkdir(FAKE + "/chan/" + id);
	mkfile(FAKE + "/chan/" + id + "/tag", tag);
	mkfile(FAKE + "/chan/" + id + "/body", body);
	mkfile(FAKE + "/chan/" + id + "/ctl", nil);
}

testSetup(t: ref T)
{
	mkdir(FAKE);
	mkdir(FAKE + "/chan");
	mkdir(FAKE + "/dir");
	mkdir(FAKE + "/cwd");
	mkfile(FAKE + "/cwd/Del", "a file named Del");
	mkfile(FAKE + "/dir/file.txt", "a file");
	# 5: a directory's +Errors; 6: unnamed; 7: a file that is there;
	# 8: a file that is not; new: what a walk to it would make
	window("5", FAKE + "/dir/+Errors Del Snarf | Look ", "errors of dir");
	window("6", " Del Snarf | Look ", "an unnamed window's text");
	window("7", FAKE + "/dir/file.txt Del Snarf | Look ", "the file's text");
	window("8", "/n/elsewhere/secret.txt Del Snarf | Look ", "a file outside");
	window("9", "/n/elsewhere/+Errors Del Snarf | Look ", "errors of elsewhere");
	window("new", " Del Snarf | Look ", "");
	mkfile(FAKE + "/chan/new/ctl", "         40          0          0          0          0 ");
	window("40", "", "");
	if(sys->bind(FAKE + "/chan", "/chan", Sys->MREPL | Sys->MCREATE) < 0)
		t.fatal(sys->sprint("bind /chan: %r"));
	if(sys->chdir(FAKE + "/cwd") < 0)
		t.fatal(sys->sprint("chdir: %r"));
	tool = load Tool "/dis/veltro/tools/xenith.dis";
	if(tool == nil)
		t.fatal(sys->sprint("cannot load the xenith tool: %r"));
	err := tool->init();
	if(err != nil)
		t.fatal("init: " + err);
}

testBodyAccess(t: ref T)
{
	if(tool == nil)
		t.skip("no tool");
	t.assertseq(tool->exec("read 7 body"), "the file's text", "a window on a file the agent has is read");
	r := tool->exec("read 8 body");
	t.assert(contains(r, "access denied"), "one on a file it has not is refused: " + r);
	r = tool->exec("read 6 body");
	t.assert(contains(r, "access denied"), "an unnamed window is refused, a file named Del or not: " + r);
	t.assertseq(tool->exec("read 5 body"), "errors of dir", "a directory's +Errors is read when the directory is there");
	r = tool->exec("read 9 body");
	t.assert(contains(r, "access denied"), "and refused when it is not: " + r);
}

testWindowNumber(t: ref T)
{
	if(tool == nil)
		t.skip("no tool");
	r := tool->exec("read new tag");
	t.assert(contains(r, "error") && contains(r, "number"), "new is not a window to read: " + r);
	r = tool->exec("read ../chan/7 body");
	t.assert(contains(r, "error"), "nor is a path: " + r);
	t.assert(contains(tool->exec("read 7 tag"), "file.txt"), "a number is");
}

testCreate(t: ref T)
{
	if(tool == nil)
		t.skip("no tool");
	r := tool->exec("create Errors");
	t.assert(contains(r, "error"), "a window is not named Errors: " + r);
	r = tool->exec("create /+Agent");
	t.assert(contains(r, "error"), "nor Agent: " + r);
	t.assertseq(readall("/chan/40/ctl"), "", "none was made for them");

	t.assertseq(tool->exec("create notes"), "40", "a window with a label of its own is made");
	t.assertseq(readall("/chan/40/ctl"), "name /+notes\n", "and named");

	# the ctl file gone: the window cannot be named
	sys->remove("/chan/40/ctl");
	r = tool->exec("create other");
	t.assert(len r > 2 && r[0:2] == "40" && contains(r, "could not be named"),
		"create says when it could not name the window: " + r);
	r = tool->exec("delete 40");
	t.assert(contains(r, "error"), "delete says when it could not delete: " + r);
	mkfile("/chan/40/ctl", nil);
}

testCtlLength(t: ref T)
{
	if(tool == nil)
		t.skip("no tool");
	t.assertseq(tool->exec("ctl 40 show"), "ok", "a layout command to an owned window");
	t.assertseq(readall("/chan/40/ctl"), "show\n", "is written");
	mkfile("/chan/40/ctl", nil);
	# the first word of the line is allowed; its end falls in a second message
	head := "show ";
	r := tool->exec("ctl 40 " + head + fill(8192 - len head, 'x') + "name /lib/veltro/meta.txt");
	t.assert(contains(r, "error") && contains(r, "too long"), "a request longer than a message is refused: " + r);
	t.assertseq(readall("/chan/40/ctl"), "", "and not written");
	r = tool->exec("ctl 40 name /lib/veltro/meta.txt");
	t.assert(contains(r, "not allowed"), "name is not an agent's command: " + r);
	r = tool->exec("colors 40 tagbg #" + fill(9000, 'a'));
	t.assert(contains(r, "too long"), "a long colors request is refused: " + r);
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

	sys->pctl(Sys->FORKNS, nil);

	run("Setup", testSetup);
	run("BodyAccess", testBodyAccess);
	run("WindowNumber", testWindowNumber);
	run("Create", testCreate);
	run("CtlLength", testCtlLength);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

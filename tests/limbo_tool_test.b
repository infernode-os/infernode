implement LimboToolTest;

#
# The agent's limbo tool (appl/veltro/tools/limbo.b): where it saves, what
# its compiler may open, and the descriptors it compiles with.
#
#   - "limbo -o path" saved the source wherever the name space let a file
#     be made.  write and edit hold a path to the workspace or the most
#     specific rw grant of /tool/paths; this tool asked nothing, so a
#     directory granted read-only inside one granted read-write was
#     written to.
#   - "limbo compile file" ran the compiler in the tool's own name space,
#     and the compiler opens what an include line names: a file under
#     /mnt/llm, which only this tool is given, was read as source (and a
#     read of /mnt/llm/new makes a model session each time).
#   - The compiler ran in the call's thread with descriptors 1 and 2 of
#     the group all tool calls share turned to a pipe and back: compiles
#     made at once waited on each other for ever, and each compile left
#     two descriptors open.
#   - A read the model server refused was taken for the end of the file.
#
# The test stands in for tools9p and the model server with plain files:
# /tool/paths names the grants, and /mnt/llm holds a session whose ask
# file already has the model's answer after the room the question takes.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

LimboToolTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

ToolLimbo: module
{
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

SRCFILE: con "/tests/limbo_tool_test.b";

passed := 0;
failed := 0;
skipped := 0;

limbo: ToolLimbo;
top: string;
scratch: string;	# a file name stem in the tool's workspace

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

PROGRAM: con "implement Hello;\n\ninclude \"sys.m\";\n\tsys: Sys;\ninclude \"draw.m\";\n\n" +
	"Hello: module\n{\n\tinit: fn(nil: ref Draw->Context, nil: list of string);\n};\n\n" +
	"init(nil: ref Draw->Context, nil: list of string)\n{\n\tsys = load Sys Sys->PATH;\n\tsys->print(\"hello\\n\");\n}\n";

mkdir(path: string)
{
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

put(path, s: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd != nil) {
		b := array of byte s;
		sys->write(fd, b, len b);
	}
}

slurp(path: string): string
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

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
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

# the model's answer, waiting in the session's ask file
answer()
{
	pad := "";
	for(i := 0; i < 400; i++)
		pad += "\n";
	put(top + "/llm/s1/ask", pad + "```limbo\n" + PROGRAM + "```\n");
}

testSaveObeysGrants(t: ref T)
{
	desc := " a program that prints hello";

	answer();
	r := limbo->exec("-o " + top + "/wr/ro/x.b" + desc);
	t.assert(contains(r, "read-only"), "a path under a read-only grant inside a read-write one is refused: " + r);
	t.assert(!exists(top + "/wr/ro/x.b"), "and nothing is written there");

	answer();
	r = limbo->exec("-o " + top + "/other/x.b" + desc);
	t.assert(contains(r, "not covered by an rw path grant"), "a path no grant covers is refused: " + r);
	t.assert(!exists(top + "/other/x.b"), "and nothing is written there");

	answer();
	r = limbo->exec("-o " + top + "/wr/../other/y.b" + desc);
	t.assert(contains(r, "invalid path"), "a path with .. is refused: " + r);
	t.assert(!exists(top + "/other/y.b"), "and nothing is written there");

	answer();
	r = limbo->exec("-o " + top + "/wr/ok.b" + desc);
	t.assert(contains(r, "Saved to " + top + "/wr/ok.b"), "a path under the rw grant is saved: " + r);
	t.assertseq(slurp(top + "/wr/ok.b"), PROGRAM, "with the source");
	t.assert(contains(r, "status: compiled"), "and the source was compiled first");

	answer();
	r = limbo->exec("-o " + scratch + "-saved.b" + desc);
	t.assert(contains(r, "Saved to " + scratch + "-saved.b"), "the workspace needs no grant: " + r);
	sys->remove(scratch + "-saved.b");
}

testCompileIncludes(t: ref T)
{
	head := "implement X;\ninclude \"sys.m\";\ninclude \"draw.m\";\n";
	tail := "X: module { init: fn(nil: ref Draw->Context, nil: list of string); };\n" +
		"init(nil: ref Draw->Context, nil: list of string)\n{\n\tv := FROMINCLUDE;\n\tv = v;\n}\n";

	# a header beside the source is the source's own
	put(top + "/wr/local.m", "FROMINCLUDE: con 2;\n");
	put(top + "/wr/own.b", head + "include \"local.m\";\n" + tail);
	r := limbo->exec("compile " + top + "/wr/own.b");
	t.assert(contains(r, "status: compiled"), "a source including a header beside it compiles: " + r);

	# a file of a service is not source
	put(top + "/llm/consts", "FROMINCLUDE: con 1;\n");
	put(top + "/wr/svc.b", head + "include \"/mnt/llm/consts\";\n" + tail);
	r = limbo->exec("compile " + top + "/wr/svc.b");
	t.assert(contains(r, "status: failed"), "a source including a file under /mnt is not given it: " + r);

	put(top + "/wr/svc2.b", head + "include \"../../../../mnt/llm/consts\";\n" + tail);
	r = limbo->exec("compile " + top + "/wr/svc2.b");
	t.assert(contains(r, "status: failed"), "nor by a relative name: " + r);

	# and this process still has what the compiler was not given
	t.assert(exists("/mnt/llm/consts") && exists("/tool/paths"), "the caller's name space is as it was");
	t.assert(!exists(scratch[0:len "/tmp/veltro/scratch"] + "/limbo-gate-c" + string sys->pctl(0, nil) + ".empty"),
		"nothing is left in the workspace");
}

compileone(path: string, done: chan of string)
{
	done <-= limbo->exec("compile " + path);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

testCompilesAtOnce(t: ref T)
{
	put(top + "/wr/hello.b", PROGRAM);
	N: con 6;
	done := chan[N] of string;
	for(i := 0; i < N; i++)
		spawn compileone(top + "/wr/hello.b", done);
	tick := chan[1] of int;
	spawn timer(tick, 120000);
	got := 0;
	good := 0;
	while(got < N) {
		alt {
		r := <-done =>
			got++;
			if(contains(r, "status: compiled"))
				good++;
			else
				t.log("a compile answered: " + r);
		<-tick =>
			t.fatal(sprint("%d of %d compiles made at once answered; the rest wait for ever", got, N));
		}
	}
	t.asserteq(good, N, "every compile made at once says it compiled");
}

# the descriptors this process has open (fildes gives a copy, so they are
# asked for from the highest down and each copy dropped at once)
nfds(): int
{
	n := 0;
	for(i := 127; i >= 0; i--) {
		fd := sys->fildes(i);
		if(fd != nil)
			n++;
		fd = nil;
	}
	return n;
}

testNoDescriptorsLeft(t: ref T)
{
	put(top + "/wr/hello.b", PROGRAM);
	put(top + "/wr/broken.b", "implement Broken;\nthis is not Limbo\n");
	before := nfds();
	for(i := 0; i < 5; i++) {
		r := limbo->exec("compile " + top + "/wr/hello.b");
		t.assert(contains(r, "status: compiled"), "a source that compiles: " + r);
		r = limbo->exec("compile " + top + "/wr/broken.b");
		t.assert(contains(r, "status: failed") && contains(r, "broken.b:"), "one that does not, with the compiler's errors: " + r);
	}
	t.asserteq(nfds(), before, "ten compiles leave no descriptor open in the caller's group");
}

refuse(fio: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-fio.read =>
		if(rc != nil)
			rc <-= (nil, "cannot allocate session");
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "no");
	}
}

# Last: it puts another /mnt/llm in place.
testReadErrorReported(t: ref T)
{
	if(sys->bind("#s", "/mnt/llm", Sys->MREPL) < 0)
		t.skip(sprint("cannot bind #s: %r"));
	fio := sys->file2chan("/mnt/llm", "new");
	if(fio == nil)
		t.skip(sprint("file2chan: %r"));
	spawn refuse(fio);
	r := limbo->exec("a program that prints hello");
	t.assert(contains(r, "cannot allocate session"), "what the model server refused with is what the tool says: " + r);
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

	limbo = load ToolLimbo "/dis/veltro/tools/limbo.dis";
	if(limbo == nil) {
		sys->fprint(sys->fildes(2), "cannot load the limbo tool: %r\n");
		raise "fail:cannot load the limbo tool";
	}
	err := limbo->init();
	if(err != nil)
		raise "fail:limbo tool init: " + err;

	# a name space of the test's own, with files where tools9p and the
	# model server would be
	sys->pctl(Sys->FORKNS, nil);
	pid := sys->pctl(0, nil);
	top = "/tmp/limbo_tool_test." + string pid;
	cleanup(top);
	mkdir(top);
	mkdir(top + "/wr");
	mkdir(top + "/wr/ro");
	mkdir(top + "/other");
	mkdir(top + "/tool");
	mkdir(top + "/llm");
	mkdir(top + "/llm/s1");
	put(top + "/tool/paths", top + "/wr rw\n" + top + "/wr/ro ro\n");
	put(top + "/llm/new", "s1\n");
	put(top + "/llm/s1/model", "");
	put(top + "/llm/s1/reasoning", "");
	put(top + "/llm/s1/system", "");
	put(top + "/llm/s1/ctl", "");
	mkdir("/tmp/veltro");
	mkdir("/tmp/veltro/scratch");
	scratch = "/tmp/veltro/scratch/limbo_tool_test_" + string pid;
	mkdir("/tool");	# the mount points: a fresh tree has neither
	mkdir("/mnt/llm");
	if(sys->bind(top + "/tool", "/tool", Sys->MREPL) < 0 ||
	   sys->bind(top + "/llm", "/mnt/llm", Sys->MREPL | Sys->MCREATE) < 0) {
		sys->fprint(sys->fildes(2), "cannot bind the stand-ins: %r\n");
		raise "fail:bind";
	}

	run("SaveObeysGrants", testSaveObeysGrants);
	run("CompileIncludes", testCompileIncludes);
	run("CompilesAtOnce", testCompilesAtOnce);
	run("NoDescriptorsLeft", testNoDescriptorsLeft);
	run("ReadErrorReported", testReadErrorReported);

	cleanup(top);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

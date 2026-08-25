implement TaskConsistencyTest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

LuciuiSrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

ToolTask: module {
	init: fn(): string;
	name: fn(): string;
	doc: fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

TaskConsistencyTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();
};

SRCFILE: con "/tests/task_consistency_test.b";
UI: con "/mnt/ui";

passed := 0;
failed := 0;
skipped := 0;
taskid := "";

_marker() {}

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip" => ;
	"*" => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

mkdirp(path: string)
{
	parts: list of string;
	start := 1;
	for(i := 1; i <= len path; i++) {
		if(i == len path || path[i] == '/') {
			if(i > start)
				parts = path[start:i] :: parts;
			start = i + 1;
		}
	}
	rev: list of string;
	for(; parts != nil; parts = tl parts)
		rev = hd parts :: rev;
	cur := "";
	for(; rev != nil; rev = tl rev) {
		cur += "/" + hd rev;
		(ok, nil) := sys->stat(cur);
		if(ok < 0) {
			fd := sys->create(cur, Sys->OREAD, Sys->DMDIR | 8r755);
			fd = nil;
		}
	}
}

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

strip(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[0:len s - 1];
	return s;
}

hasprefix(s, pfx: string): int
{
	return len s >= len pfx && s[0:len pfx] == pfx;
}

hassubstr(s, sub: string): int
{
	if(sub == "")
		return 1;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i + len sub] == sub)
			return 1;
	return 0;
}

createdid(s: string): string
{
	pfx := "created activity ";
	if(!hasprefix(s, pfx))
		return "";
	s = s[len pfx:];
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return s[0:i];
	return s;
}

startserver(done: chan of int)
{
	srv := load LuciuiSrv "/dis/luciuisrv.dis";
	if(srv == nil) {
		done <-= 0;
		return;
	}
	{
		srv->init(nil, "luciuisrv" :: "-m" :: UI :: nil);
		done <-= 1;
	} exception {
	"*" => done <-= 0;
	}
}

setup(t: ref T): ToolTask
{
	mkdirp(UI);
	mkdirp("/tool");
	mkdirp("/tmp/veltro/tasks");
	mkdirp("/tmp/veltro/.ns");
	pfd := sys->create("/tool/provision", Sys->OWRITE, 8r644);
	if(pfd == nil) {
		t.fatal("cannot create fake provision endpoint");
		return nil;
	}
	pfd = nil;

	done := chan[1] of int;
	spawn startserver(done);
	ok := <-done;
	if(!ok) {
		t.fatal("cannot start luciuisrv");
		return nil;
	}
	if(writefile(UI + "/ctl", "activity create Meta") < 0) {
		t.fatal("cannot create meta activity");
		return nil;
	}

	tool := load ToolTask "/dis/veltro/tools/task.dis";
	if(tool == nil) {
		t.fatal("cannot load task tool");
		return nil;
	}
	err := tool->init();
	if(err != nil) {
		t.fatal("cannot initialize task tool: " + err);
		return nil;
	}
	return tool;
}

testDelayedSetupConsistency(t: ref T)
{
	tool := setup(t);
	if(tool == nil)
		return;

	r := tool->exec("create label=DelayedSetup tools=read");
	t.assert(hasprefix(r, "created activity "), "accepted create must report the surviving activity: " + r);
	id := createdid(r);
	t.assert(id != "" && id != "0", "created activity has a task id");
	taskid = id;
	t.assert(readfile(UI + "/activity/" + id + "/label") != nil, "created activity has an id");
	listing := tool->exec("list");
	t.assert(hassubstr(listing, id + ": DelayedSetup [provisioning]"), "list agrees that delayed activity is provisioning: " + listing);
	status := tool->exec("status " + id);
	t.assert(hassubstr(status, "[provisioning]"), "status agrees that delayed activity is provisioning: " + status);

	writefile(UI + "/activity/" + id + "/status", "done");
	writefile(UI + "/activity/" + id + "/conversation/ctl", "role=veltro text=delayed task finished");
	result := tool->exec("result " + id);
	t.assert(hassubstr(result, "delayed task finished"), "surviving activity result remains retrievable: " + result);
}

testExplicitProvisionFailure(t: ref T)
{
	tool := setup(t);
	if(tool == nil)
		return;
	if(writefile(UI + "/ctl", "activity create FailedSetup") < 0) {
		t.fatal("cannot create failed activity");
		return;
	}
	id := "1";
	writefile(UI + "/activity/" + id + "/conversation/ctl", "clear");
	writefile(UI + "/activity/" + id + "/status", "failed: namespace setup did not complete");
	result := tool->exec("result " + id);
	t.assert(hassubstr(result, "failed before producing a reply"), "failed provisioning has an explicit result: " + result);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil)
		raise "fail:cannot load testing";
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("ExplicitProvisionFailure", testExplicitProvisionFailure);
	sys->unmount(nil, UI);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

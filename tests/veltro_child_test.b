implement VeltroChildTest;

#
# The name space of a spawned subagent, and of a path grant
# (appl/veltro/nsconstruct.b).
#
# A subagent's name space is made from the spawn tool's, inside its
# parent's tool call, out of what the model asked for.  It was made by
# the coordinator's rule (restrictns), which keeps /tool/<tool> for every
# tool in the capabilities: for a subagent that was its parent's tool
# server, which runs each call with the parent's grants and keeps each
# tool's last result.  A child given read and no paths read its parent's
# files by writing a name to /tool/read/ctl.  The same rule let it be
# granted /mnt/llm, where every session's conversation is, and asked the
# install's audit switch of a name space that cannot see it, so a child
# ran unrecorded where recording is required.
#
# A path grant under /tmp/veltro put its first component in the view,
# whole and writable: /tmp/veltro/memory/x was the agent's memory,
# /tmp/veltro/proj/a was all of proj, and a grant listed ro was written.
#
# The memory and plan tools' stores were whole in the view of any call
# of those tools: one activity's agent read and rewrote another's.  The
# UI's files, for any tool that needs them, were every activity's, each
# with the conversation input its agent takes the user's words from; a
# child with exec beside a UI tool had them for its commands to write.
# A child could be given sms, dial or task, whose calls the coordinator
# asks the user about and a child's calls never reach.  An account named
# for one of the wallet's own files put that file in the wallet's view.
#
# The rest are the builder's own: an entry name with a slash or ".."
# taken from a caller or a server; a tool named for one of the tool
# server's files; a service mount named in another case; an overlay of
# an earlier session used when it could not be set aside; cleanup()
# removing the files a view showed; exec's audit record with no name
# space in it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "nsconstruct.m";
	nsconstruct: NsConstruct;
include "testing.m";
	testing: Testing;
	T: import testing;

VeltroChildTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/veltro_child_test.b";

passed := 0;
failed := 0;
skipped := 0;

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

mkdirp(path: string)
{
	if(sys->stat(path).t0 >= 0)
		return;
	for(i := len path - 1; i > 0; i--)
		if(path[i] == '/') {
			mkdirp(path[0:i]);
			break;
		}
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

put(path, text: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd != nil)
		sys->fprint(fd, "%s", text);
}

get(path: string): string
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
	return sys->stat(path).t0 >= 0;
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

rmrf(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil) {
		names: list of (string, int);
		for(;;) {
			(n, d) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++)
				names = (d[i].name, d[i].mode & Sys->DMDIR) :: names;
		}
		fd = nil;
		for(; names != nil; names = tl names) {
			(nm, isdir) := hd names;
			if(isdir)
				rmrf(path + "/" + nm);
			else
				sys->remove(path + "/" + nm);
		}
	}
	sys->remove(path);
}

caps(tools, paths, wpaths: list of string, actid: int): ref NsConstruct->Capabilities
{
	return ref NsConstruct->Capabilities(tools, paths, nil, nil,
		0 :: 1 :: 2 :: nil, nil, 0, 0, actid, wpaths, nil);
}

# A world of the test's own before the root of the calling process's
# name space (which must be its own): a tool server's tree as tools9p
# serves one, a model service with a session in it, and the agent's own
# mount.  Nothing is left in the emulator's root.
world(): string
{
	fix := sys->sprint("/tmp/vct.%d", sys->pctl(0, nil));
	for(d := "/tool/read" :: "/tool/exec" :: "/tool/meta" :: "/mnt/llm/0" :: "/mnt/veltro" ::
		"/mnt/audit" :: nil; d != nil; d = tl d)
		mkdirp(fix + hd d);
	put(fix + "/tool/tools", "spawn\nread\nexec\n");
	put(fix + "/tool/paths", "/tmp/veltro/scratch cow\n/usr/inferno ro\n");
	put(fix + "/tool/activity", "7");
	put(fix + "/tool/ctl", "");
	put(fix + "/tool/budget", "read\nexec\n");
	put(fix + "/tool/read/ctl", "THE PARENT'S LAST RESULT");
	put(fix + "/tool/exec/ctl", "");
	put(fix + "/tool/meta/audit", "off\n");
	put(fix + "/mnt/llm/new", "1");
	put(fix + "/mnt/llm/0/context", "another session's conversation");
	if(sys->bind(fix, "/", Sys->MBEFORE|Sys->MCREATE) < 0)
		return sys->sprint("bind %s before /: %r", fix);
	return nil;
}

unworld(pid: int)
{
	rmrf(sys->sprint("/tmp/vct.%d", pid));
}

# Each check runs in a process with a name space of its own and says ""
# or what was wrong.
inworker(t: ref T, f: ref fn(r: chan of (int, string)))
{
	r := chan of (int, string);
	spawn f(r);
	(pid, e) := <-r;
	unworld(pid);
	if(e != "")
		t.error(e);
}

# The spawn tool's own worker, as tools9p makes it: the budget's tools.
asworker(paths: list of string): string
{
	e := world();
	if(e != nil)
		return e;
	e = nsconstruct->restricttoolns(caps("spawn" :: "read" :: "exec" :: nil, paths, nil, -1));
	if(e != nil)
		return "the spawn worker's name space: " + e;
	return nil;
}

notoolserver(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := asworker(nil);
	if(e == nil && !exists("/tool/read/ctl"))
		e = "fixture: the worker itself has no /tool/read/ctl";
	if(e == nil)
		e = nsconstruct->restrictchildns(caps("read" :: nil, nil, nil, -1), 0);
	if(e != nil) {
		r <-= (pid, e);
		return;
	}
	e = "";
	if(exists("/tool/read/ctl") || exists("/tool/read"))
		e += "a child given read has its parent's /tool/read; ";
	fd := sys->open("/tool/read/ctl", Sys->ORDWR);
	if(fd != nil)
		e += "a child opened its parent's /tool/read/ctl; ";
	if(exists("/tool/exec") || exists("/tool/ctl"))
		e += "a child has /tool/exec or /tool/ctl; ";
	if(get("/tool/tools") != "read\n")
		e += sys->sprint("/tool/tools is %q, not the child's own; ", get("/tool/tools"));
	if(has(get("/tool/paths"), "/usr/inferno"))
		e += "/tool/paths lists the parent's grants; ";
	if(!has(get("/tool/paths"), "/tmp/veltro/scratch cow"))
		e += sys->sprint("/tool/paths is %q; ", get("/tool/paths"));
	if(get("/tool/activity") != "7")
		e += sys->sprint("/tool/activity is %q; ", get("/tool/activity"));
	if(sys->open("/tool/paths", Sys->OWRITE) != nil)
		e += "/tool/paths opens for writing; ";
	if(sys->create("/tool/x", Sys->OWRITE, 8r644) != nil)
		e += "a file can be made in /tool; ";
	r <-= (pid, e);
}

noexecserver(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := asworker(nil);
	if(e == nil)
		e = nsconstruct->restrictchildns(caps("exec" :: nil, nil, nil, -1), 0);
	if(e == nil) {
		e = "";
		if(exists("/tool/exec/ctl") || exists("/tool/exec"))
			e = "a child given exec has its parent's /tool/exec";
		else if(sys->open("/tool/exec/ctl", Sys->OWRITE) != nil)
			e = "a child given exec opened its parent's /tool/exec/ctl";
	}
	r <-= (pid, e);
}

testNoToolServer(t: ref T)
{
	inworker(t, notoolserver);
	inworker(t, noexecserver);
}

nomodelservice(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := asworker("/mnt/llm" :: "/mnt/veltro" :: nil);
	if(e == nil && !exists("/mnt/llm/0/context"))
		e = "fixture: the worker itself has no /mnt/llm";
	if(e != nil) {
		r <-= (pid, e);
		return;
	}
	e = nsconstruct->restrictchildns(caps("read" :: nil, "/mnt/llm" :: nil, nil, -1), 0);
	if(e == nil) {
		if(exists("/mnt/llm/0/context"))
			e = "a child was granted /mnt/llm and reads another session";
		else
			e = "a child's grant of /mnt/llm was taken (and dropped): not refused";
		r <-= (pid, e);
		return;
	}
	# the same name space still restricts with what a child may have
	e = nsconstruct->restrictchildns(caps("read" :: nil, "/mnt/llm/0" :: nil, nil, -1), 0);
	if(e == nil) {
		r <-= (pid, "a child was granted a session of /mnt/llm");
		return;
	}
	e = nsconstruct->restrictchildns(caps("read" :: nil, "/mnt/veltro" :: nil, nil, -1), 0);
	if(e == nil) {
		r <-= (pid, "a child was granted /mnt/veltro");
		return;
	}
	e = nsconstruct->restrictchildns(caps("read" :: nil, nil, nil, -1), 0);
	if(e == nil && exists("/mnt"))
		e = "a child with no grants has a /mnt";
	if(e == nil)
		e = "";
	r <-= (pid, e);
}

testNoModelService(t: ref T)
{
	inworker(t, nomodelservice);
}

# The coordinator's own grant of the model service is as it was.
coordinatorllm(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := world();
	if(e == nil)
		e = nsconstruct->restrictns(caps("read" :: nil, "/mnt/llm" :: nil, nil, -1));
	if(e == nil && !exists("/mnt/llm/new"))
		e = "the coordinator's grant of /mnt/llm gave it nothing";
	if(e == nil && !exists("/tool/read/ctl"))
		e = "the coordinator has no /tool/read/ctl to call its tool by";
	if(e == nil)
		e = "";
	r <-= (pid, e);
}

testCoordinatorUnchanged(t: ref T)
{
	inworker(t, coordinatorllm);
}

auditrequired(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := asworker(nil);
	if(e != nil) {
		r <-= (pid, e);
		return;
	}
	# no sink in this name space, and the install requires auditing
	e = nsconstruct->restrictchildns(caps("read" :: nil, nil, nil, -1), 1);
	if(e == nil)
		r <-= (pid, "a child whose restriction cannot be recorded was made, under required auditing");
	else if(!has(e, "audit"))
		r <-= (pid, "refused, but not for the audit sink: " + e);
	else
		r <-= (pid, "");
}

auditrecorded(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := world();
	sink := sys->sprint("/tmp/vct.%d/mnt/audit/log", pid);
	put(sink, "");
	if(e == nil)
		e = nsconstruct->restricttoolns(caps("spawn" :: "read" :: nil, "/mnt/audit/log" :: nil, nil, -1));
	if(e == nil)
		e = nsconstruct->restrictchildns(caps("read" :: nil, "/mnt/audit/log" :: nil, nil, -1), 1);
	if(e == nil && get("/tool/meta/audit") != "required\n")
		e = sys->sprint("the child's /tool/meta/audit is %q", get("/tool/meta/audit"));
	if(e == nil && exists("/mnt/audit/chain"))
		e = "the child has more of /mnt/audit than its log";
	if(e == nil)
		e = "";
	r <-= (pid, e);
}

testAuditRequired(t: ref T)
{
	inworker(t, auditrequired);
	# with the sink there, the child is made and both restrictions sealed
	r := chan of (int, string);
	spawn auditrecorded(r);
	(pid, e) := <-r;
	log := get(sys->sprint("/tmp/vct.%d/mnt/audit/log", pid));
	unworld(pid);
	if(e != "")
		t.error(e);
	# (the sink here is a plain file, in which the child's record
	# replaces the worker's)
	t.assert(has(log, "veltro nsrestrict"), "the child's restriction is in the audit sink");
}

# A sealed record's manifest is not written over by a later process with
# the same pid (an earlier start of the emulator's, say).
manifestkept(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := world();
	put(sys->sprint("/tmp/vct.%d/mnt/audit/log", pid), "");
	mkdirp("/tmp/.veltro-ns/audit");
	put(sys->sprint("/tmp/.veltro-ns/audit/%d.ns", pid), "EARLIER");
	if(e == nil)
		e = nsconstruct->restricttoolns(caps("read" :: nil, nil, nil, -1));
	if(e == nil)
		e = "";
	r <-= (pid, e);
}

testManifestKept(t: ref T)
{
	r := chan of (int, string);
	spawn manifestkept(r);
	(pid, e) := <-r;
	log := get(sys->sprint("/tmp/vct.%d/mnt/audit/log", pid));
	unworld(pid);
	if(e != "")
		t.error(e);
	old := sys->sprint("/tmp/.veltro-ns/audit/%d.ns", pid);
	t.assertseq(get(old), "EARLIER", "the manifest an earlier record names");
	t.assert(has(log, sys->sprint("manifest=%d.", pid)) && !has(log, sys->sprint("manifest=%d.ns", pid)),
		"the new record names a manifest of its own: " + log);
	sys->remove(old);
	for(i := 1; i < 8; i++)
		sys->remove(sys->sprint("/tmp/.veltro-ns/audit/%d.%d.ns", pid, i));
}

VPROJ: con "/tmp/veltro/vctproj";

tmpfixture()
{
	mkdirp(VPROJ + "/a");
	mkdirp(VPROJ + "/b");
	put(VPROJ + "/a/f", "granted");
	put(VPROJ + "/b/g", "not granted");
	put(VPROJ + "/top", "not granted");
}

tmpdrilled(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restrictns(caps("read" :: nil, VPROJ + "/a" :: nil, nil, -1));
	if(e != nil) {
		r <-= (pid, e);
		return;
	}
	e = "";
	if(get(VPROJ + "/a/f") != "granted")
		e += "the granted directory is not there; ";
	if(exists(VPROJ + "/b") || exists(VPROJ + "/b/g") || exists(VPROJ + "/top"))
		e += "a grant of one directory shows its siblings; ";
	if(sys->open(VPROJ + "/a/f", Sys->OWRITE) != nil)
		e += "a file of a read-only grant opens for writing; ";
	if(sys->create(VPROJ + "/a/new", Sys->OWRITE, 8r644) != nil)
		e += "a file is made in a read-only grant; ";
	if(sys->create(VPROJ + "/new", Sys->OWRITE, 8r644) != nil)
		e += "a file is made beside the grant; ";
	r <-= (pid, e);
}

tmpwhole(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restrictns(caps("read" :: nil, VPROJ :: nil, nil, -1));
	if(e != nil) {
		r <-= (pid, e);
		return;
	}
	e = "";
	if(get(VPROJ + "/b/g") != "not granted")
		e += "a grant of the whole directory does not show it; ";
	if(sys->open(VPROJ + "/top", Sys->OWRITE) != nil || sys->create(VPROJ + "/new", Sys->OWRITE, 8r644) != nil)
		e += "a read-only grant under /tmp/veltro is written; ";
	r <-= (pid, e);
}

tmpwritable(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restrictns(caps("read" :: nil, VPROJ + "/a" :: nil, VPROJ + "/a" :: nil, -1));
	if(e != nil) {
		r <-= (pid, e);
		return;
	}
	e = "";
	if(sys->open(VPROJ + "/a/f", Sys->OWRITE) == nil)
		e = sys->sprint("a grant given for writing cannot be written: %r");
	else if(exists(VPROJ + "/b"))
		e = "a grant for writing shows its siblings";
	r <-= (pid, e);
}

inplain(t: ref T, f: ref fn(r: chan of (int, string)))
{
	r := chan of (int, string);
	spawn f(r);
	(nil, e) := <-r;
	if(e != "")
		t.error(e);
}

testTmpVeltroGrants(t: ref T)
{
	tmpfixture();
	inplain(t, tmpdrilled);
	inplain(t, tmpwhole);
	inplain(t, tmpwritable);
	t.assertseq(get(VPROJ + "/a/f"), "granted", "the fixture is as it was");
	rmrf(VPROJ);
}

refused(r: chan of (int, string), c: ref NsConstruct->Capabilities, what: string)
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restrictns(c);
	if(e == nil)
		r <-= (pid, what + ": not refused");
	else
		r <-= (pid, "");
}

accepted(r: chan of (int, string), c: ref NsConstruct->Capabilities, what: string)
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restrictns(c);
	if(e != nil)
		r <-= (pid, what + ": " + e);
	else
		r <-= (pid, "");
}

expect(t: ref T, ok: int, c: ref NsConstruct->Capabilities, what: string)
{
	r := chan of (int, string);
	if(ok)
		spawn accepted(r, c, what);
	else
		spawn refused(r, c, what);
	(nil, e) := <-r;
	if(e != "")
		t.error(e);
}

testGrantsRefused(t: ref T)
{
	mkdirp("/tmp/veltro/memory");
	mkdirp("/tmp/veltro/plans");
	# the memory, plan and todo tools' state is not a path grant
	expect(t, 0, caps("read" :: nil, "/tmp/veltro/memory/x" :: nil, nil, -1), "a path grant of the memory tool's directory");
	expect(t, 0, caps("read" :: nil, "/tmp/veltro/memory" :: nil, nil, -1), "a path grant of the memory tool's directory, whole");
	expect(t, 0, caps("read" :: nil, "/tmp/veltro/plans/p" :: nil, nil, -1), "a path grant of the plan tool's directory");
	expect(t, 0, caps("read" :: nil, "/tmp/veltro/todo.txt" :: nil, nil, -1), "a path grant of the todo tool's file");
	expect(t, 1, caps("memory" :: "read" :: nil, "/tmp/veltro/memory/x" :: nil, nil, -1), "the memory tool's own directory, to the memory tool");
	# a service mount is named in lower case
	expect(t, 0, caps("read" :: nil, "/mnt/Msg" :: nil, nil, -1), "/mnt/Msg");
	expect(t, 0, caps("read" :: nil, "/MNT/msg" :: nil, nil, -1), "/MNT/msg");
	expect(t, 1, caps("read" :: nil, "/mnt/mcp/OSM" :: nil, nil, -1), "/mnt/mcp/OSM (the case of a name below the service's is its own)");
	# a tool is not named for a file of the tool server
	expect(t, 0, caps("ctl" :: nil, nil, nil, -1), "a tool named ctl");
	expect(t, 0, caps("read" :: "Provision" :: nil, nil, nil, -1), "a tool named Provision");
	expect(t, 1, caps("read" :: nil, nil, nil, -1), "a tool named read");
}

entrynames(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	d := sys->sprint("/tmp/vct.%d/t/tools", pid);
	mkdirp(d + "/ok");
	put(sys->sprint("/tmp/vct.%d/t/beside", pid), "beside");
	e := "";
	if(nsconstruct->restrictdir(d, ".." :: "ok" :: nil, 0) == nil)
		e += "an entry named .. was taken; ";
	if(nsconstruct->restrictdir(d, "ok/../.." :: nil, 0) == nil)
		e += "an entry name with a slash was taken; ";
	if(nsconstruct->restrictdir(d, "" :: nil, 0) == nil)
		e += "an empty entry name was taken; ";
	if(nsconstruct->restrictdir(d, "ok" :: nil, 0) != nil)
		e += "a plain name was refused; ";
	if(exists(d + "/../beside") && get(d + "/beside") == "beside")
		e += "the directory's parent is in its view; ";
	r <-= (pid, e);
}

testEntryNames(t: ref T)
{
	inworker(t, entrynames);
}

cleanupkeeps(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	d := sys->sprint("/tmp/vct.%d/c", pid);
	mkdirp(d + "/keep/sub");
	put(d + "/keep/sentinel", "kept");
	put(d + "/keep/sub/deep", "kept");
	put(d + "/file", "kept");
	e := nsconstruct->restrictdir(d, "keep" :: "file" :: nil, 1);
	if(e == nil) {
		nsconstruct->cleanup();
		e = "";
	}
	r <-= (pid, e);
}

testCleanupKeepsFiles(t: ref T)
{
	r := chan of (int, string);
	spawn cleanupkeeps(r);
	(pid, e) := <-r;
	if(e != "")
		t.error(e);
	d := sys->sprint("/tmp/vct.%d/c", pid);
	t.assertseq(get(d + "/keep/sentinel"), "kept", "a file of a directory the view showed, after cleanup()");
	t.assertseq(get(d + "/keep/sub/deep"), "kept", "a file below it");
	t.assertseq(get(d + "/file"), "kept", "a file the view showed");
	unworld(pid);
}

# The memory and plan tools' stores are one an activity.
storeview(r: chan of (int, string), tool: string)
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restricttoolns(caps(tool :: nil, nil, nil, 987641));
	if(e != nil) {
		r <-= (pid, e);
		return;
	}
	d := "/tmp/veltro/memory";
	own := "987641";
	other := "987642";
	if(tool == "plan") {
		d = "/tmp/veltro/plans";
		own = "a987641";
		other = "a987642";
	}
	e = "";
	if(get(d + "/" + own + "/mine") != "mine")
		e += tool + ": the activity's own store is not there; ";
	if(exists(d + "/" + other) || get(d + "/" + other + "/theirs") == "theirs")
		e += tool + ": another activity's store is in the view; ";
	if(exists(d + "/loose"))
		e += tool + ": a file beside the stores is in the view; ";
	fd := sys->create(d + "/" + own + "/new", Sys->OWRITE, 8r644);
	if(fd == nil)
		e += sys->sprint("%s: nothing can be made in the activity's own store: %r; ", tool);
	else
		sys->remove(d + "/" + own + "/new");
	r <-= (pid, e);
}

storefresh(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restricttoolns(caps("memory" :: "plan" :: nil, nil, nil, 987643));
	if(e == nil) {
		e = "";
		if(!exists("/tmp/veltro/memory/987643") || !exists("/tmp/veltro/plans/a987643"))
			e = "an activity with no store yet is not given one";
	}
	r <-= (pid, e);
}

testStoresPerActivity(t: ref T)
{
	for(d := "/tmp/veltro/memory/987641" :: "/tmp/veltro/memory/987642" ::
		"/tmp/veltro/plans/a987641" :: "/tmp/veltro/plans/a987642" :: nil; d != nil; d = tl d)
		mkdirp(hd d);
	put("/tmp/veltro/memory/987641/mine", "mine");
	put("/tmp/veltro/memory/987642/theirs", "theirs");
	put("/tmp/veltro/memory/loose", "loose");
	put("/tmp/veltro/plans/a987641/mine", "mine");
	put("/tmp/veltro/plans/a987642/theirs", "theirs");
	put("/tmp/veltro/plans/loose", "loose");
	r := chan of (int, string);
	spawn storeview(r, "memory");
	(nil, e) := <-r;
	if(e != "")
		t.error(e);
	spawn storeview(r, "plan");
	(nil, e) = <-r;
	if(e != "")
		t.error(e);
	inplain(t, storefresh);
	t.assertseq(get("/tmp/veltro/memory/987642/theirs"), "theirs", "the other activity's memory is as it was");
	for(d = "/tmp/veltro/memory/987641" :: "/tmp/veltro/memory/987642" :: "/tmp/veltro/memory/987643" ::
		"/tmp/veltro/plans/a987641" :: "/tmp/veltro/plans/a987642" :: "/tmp/veltro/plans/a987643" :: nil; d != nil; d = tl d)
		rmrf(hd d);
	sys->remove("/tmp/veltro/memory/loose");
	sys->remove("/tmp/veltro/plans/loose");
}

# The UI's files.  A tool other than task has its own activity's, less
# the conversation; a child that can run commands has none of them.
uiworld(pid: int): string
{
	fix := sys->sprint("/tmp/vct.%d", pid);
	for(a := "7" :: "9" :: nil; a != nil; a = tl a) {
		d := fix + "/mnt/ui/activity/" + hd a;
		mkdirp(d + "/conversation");
		mkdirp(d + "/presentation");
		mkdirp(d + "/context");
		put(d + "/conversation/input", "");
		put(d + "/presentation/ctl", "");
		put(d + "/label", "activity " + hd a);
	}
	put(fix + "/mnt/ui/activity/current", "9");
	put(fix + "/mnt/ui/ctl", "");
	return world();
}

uiview(): string
{
	e := "";
	if(get("/mnt/ui/activity/7/label") != "activity 7")
		e += "its own activity is not there; ";
	if(sys->open("/mnt/ui/activity/7/presentation/ctl", Sys->OWRITE) == nil)
		e += "its own activity's presentation cannot be written; ";
	if(exists("/mnt/ui/activity/9"))
		e += "another activity is in the view; ";
	if(exists("/mnt/ui/activity/7/conversation") || sys->open("/mnt/ui/activity/7/conversation/input", Sys->OWRITE) != nil)
		e += "its activity's conversation input is in the view; ";
	if(sys->open("/mnt/ui/activity/9/conversation/input", Sys->OWRITE) != nil)
		e += "another activity's conversation input opens for writing; ";
	c := get("/mnt/ui/activity/current");
	if(c != "7\n")
		e += sys->sprint("current reads %q, not the tool's own activity; ", c);
	if(exists("/mnt/ui/ctl"))
		e += "the UI's ctl is in the view; ";
	return e;
}

uitool(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := uiworld(pid);
	if(e == nil)
		e = nsconstruct->restricttoolns(caps("present" :: nil, nil, nil, 7));
	if(e == nil)
		e = uiview();
	r <-= (pid, e);
}

uitask(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := uiworld(pid);
	if(e == nil)
		e = nsconstruct->restricttoolns(caps("task" :: nil, nil, nil, 7));
	if(e == nil) {
		e = "";
		if(!exists("/mnt/ui/activity/9/conversation/input") || !exists("/mnt/ui/ctl"))
			e = "the task tool has not the activities and the UI's ctl";
	}
	r <-= (pid, e);
}

uichild(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := uiworld(pid);
	if(e == nil)
		e = nsconstruct->restricttoolns(caps("spawn" :: "exec" :: "present" :: nil, nil, nil, 7));
	if(e == nil)
		e = nsconstruct->restrictchildns(caps("present" :: nil, nil, nil, -1), 0);
	if(e == nil)
		e = uiview();
	r <-= (pid, e);
}

uiexecchild(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := uiworld(pid);
	if(e == nil)
		e = nsconstruct->restricttoolns(caps("spawn" :: "exec" :: "present" :: nil, nil, nil, 7));
	if(e == nil && !exists("/mnt/ui/activity/7/presentation/ctl"))
		e = "fixture: the spawn worker has no /mnt/ui/activity";
	if(e == nil)
		e = nsconstruct->restrictchildns(caps("exec" :: "present" :: nil, nil, nil, -1), 0);
	if(e == nil) {
		e = "";
		if(exists("/mnt/ui") || exists("/mnt/ui/activity/9/conversation/input") ||
		   sys->open("/mnt/ui/activity/7/conversation/input", Sys->OWRITE) != nil)
			e = "a child that runs commands, given a UI tool, has the UI's files";
	}
	r <-= (pid, e);
}

testUiView(t: ref T)
{
	inworker(t, uitool);
	inworker(t, uitask);
	inworker(t, uichild);
	inworker(t, uiexecchild);
}

# A child holds no tool whose effect needs the user's approval.
gatedchild(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := world();
	if(e == nil)
		e = nsconstruct->restricttoolns(caps("spawn" :: "read" :: "sms" :: "dial" :: "task" :: nil, nil, nil, -1));
	if(e != nil) {
		r <-= (pid, e);
		return;
	}
	e = "";
	for(tl0 := "sms" :: "dial" :: "task" :: "Task" :: nil; tl0 != nil; tl0 = tl tl0)
		if(nsconstruct->restrictchildns(caps("read" :: hd tl0 :: nil, nil, nil, -1), 0) == nil) {
			e += sys->sprint("a child was given %s; ", hd tl0);
			break;
		}
	if(e == "" && nsconstruct->restrictchildns(caps("read" :: nil, nil, nil, -1), 0) != nil)
		e = "a child given read alone was refused";
	r <-= (pid, e);
}

testGatedTools(t: ref T)
{
	inworker(t, gatedchild);
	t.assert(nsconstruct->gatedtool("sms") && nsconstruct->gatedtool("dial") && nsconstruct->gatedtool("task"),
		"sms, dial and task need the user's approval");
	t.assert(!nsconstruct->gatedtool("read") && !nsconstruct->gatedtool("plan"), "read and plan do not");
}

# The wallet's view: accounts, and nothing of the wallet's own files
# whatever the accounts are called.
walletview(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	fix := sys->sprint("/tmp/vct.%d", pid);
	mkdirp(fix + "/mnt/wallet/main");
	put(fix + "/mnt/wallet/accounts", "main ctl pending new event\n");
	for(f := "default" :: "network" :: "ctl" :: "pending" :: "new" :: "event" :: nil; f != nil; f = tl f)
		put(fix + "/mnt/wallet/" + hd f, hd f);
	put(fix + "/mnt/wallet/main/address", "0x1");
	put(fix + "/mnt/wallet/main/ctl", "budget");
	e: string;
	if(sys->bind(fix, "/", Sys->MBEFORE|Sys->MCREATE) < 0)
		e = sys->sprint("bind: %r");
	if(e == nil)
		e = nsconstruct->restrictns(caps("wallet" :: nil, "/mnt/wallet" :: nil, nil, -1));
	if(e != nil) {
		r <-= (pid, e);
		return;
	}
	e = "";
	if(get("/mnt/wallet/main/address") != "0x1")
		e += "the account is not in the view; ";
	if(exists("/mnt/wallet/main/ctl"))
		e += "the account's ctl is in the view; ";
	for(f = "ctl" :: "pending" :: "new" :: "event" :: nil; f != nil; f = tl f)
		if(exists("/mnt/wallet/" + hd f))
			e += sys->sprint("an account named %s put the wallet's own %s in the view; ", hd f, hd f);
	r <-= (pid, e);
}

wallethalf(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	fix := sys->sprint("/tmp/vct.%d", pid);
	mkdirp(fix + "/mnt/wallet/main");
	mkdirp(fix + "/mnt/wallet/zlast");
	# an account that is not a directory: its view cannot be made
	put(fix + "/mnt/wallet/afile", "x");
	put(fix + "/mnt/wallet/accounts", "main afile zlast\n");
	put(fix + "/mnt/wallet/main/ctl", "budget");
	put(fix + "/mnt/wallet/zlast/ctl", "budget");
	e: string;
	if(sys->bind(fix, "/", Sys->MBEFORE|Sys->MCREATE) < 0)
		e = sys->sprint("bind: %r");
	if(e == nil)
		e = nsconstruct->restrictns(caps("wallet" :: nil, "/mnt/wallet" :: nil, nil, -1));
	if(e == nil) {
		r <-= (pid, "a wallet whose view cannot be made whole was accepted");
		return;
	}
	e = "";
	if(exists("/mnt/wallet/main/ctl") || exists("/mnt/wallet/zlast/ctl") ||
	   exists("/mnt/wallet/main") || exists("/mnt/wallet/accounts"))
		e = "a wallet view that failed half made is left with accounts in it";
	r <-= (pid, e);
}

testWalletView(t: ref T)
{
	inworker(t, walletview);
	inworker(t, wallethalf);
}

# nsconstruct's name for a write path's overlay: FNV-1a of the path.
overlaykey(path: string): string
{
	h := int 16r811c9dc5;
	b := array of byte path;
	for(i := 0; i < len b; i++) {
		h = h ^ int b[i];
		h = h * 16r01000193;
	}
	return sys->sprint("%8.8ux", h);
}

ACT: con 987601;

staleoverlay(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restrictns(caps("read" :: nil, "/tmp/vctw" :: nil, "/tmp/vctw" :: nil, ACT));
	if(e == nil) {
		e = "an earlier session's overlay that could not be set aside was used";
		if(get("/tmp/vctw/staged") == "an earlier session's change")
			e += ": its staged file is in the view";
	} else if(!has(e, "set aside"))
		e = "refused, but not for the overlay: " + e;
	else
		e = "";
	r <-= (pid, e);
}

testStaleOverlayRefused(t: ref T)
{
	mkdirp("/tmp/vctw");
	name := sys->sprint("%d-%s", ACT, overlaykey("/tmp/vctw"));
	ov := "/tmp/veltro/cow/" + name;
	mkdirp(ov);
	put(ov + "/staged", "an earlier session's change");
	put(ov + "/.cowmeta", "boot=1\n");
	# where it would be kept is taken, by something that is not empty
	kept := "/tmp/veltro/cow/kept-1-" + name;
	mkdirp(kept);
	put(kept + "/x", "x");
	inplain(t, staleoverlay);
	t.assert(!has(get(ov + "/.cowmeta"), "boot=1\nboot=") && has(get(ov + "/.cowmeta"), "boot=1"),
		"the overlay is not stamped as this session's");
	rmrf(ov);
	rmrf(kept);
	rmrf("/tmp/vctw");
}

execmanifest(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restricttoolns(caps("exec" :: nil, nil, nil, -1));
	if(e == nil)
		e = "";
	r <-= (pid, e);
}

testExecManifestHasNamespace(t: ref T)
{
	r := chan of (int, string);
	spawn execmanifest(r);
	(pid, e) := <-r;
	if(e != "")
		t.error(e);
	m := get(sys->sprint("/tmp/.veltro-ns/audit/%d.ns", pid));
	t.assert(has(m, "tools=exec"), "exec's restriction has a manifest");
	t.assert(has(m, "# Current namespace:"), "exec's manifest has the name space in it");
	sys->remove(sys->sprint("/tmp/.veltro-ns/audit/%d.ns", pid));
}

progview(r: chan of (int, string), tools: list of string)
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restricttoolns(caps(tools, nil, nil, -1));
	if(e == nil) {
		e = "self only";
		if(exists("/prog/1"))
			e = "whole";
		if(!exists(sys->sprint("/prog/%d/status", pid)))
			e = "without itself";
	}
	r <-= (pid, e);
}

childprog(r: chan of (int, string))
{
	pid := sys->pctl(Sys->FORKNS, nil);
	e := nsconstruct->restricttoolns(caps("spawn" :: "read" :: nil, nil, nil, -1));
	if(e == nil)
		e = nsconstruct->restrictchildns(caps("read" :: nil, nil, nil, -1), 0);
	if(e == nil) {
		e = "self only";
		if(exists("/prog/1"))
			e = "whole";
		else if(sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE) != nil)
			e = "writable";
	}
	r <-= (pid, e);
}

# The spawn tool's worker stops the subagents it starts by their ctl
# files; a subagent, and every other tool, sees itself alone.
testProgForSpawnAlone(t: ref T)
{
	r := chan of (int, string);
	spawn progview(r, "spawn" :: "read" :: nil);
	(nil, e) := <-r;
	t.assertseq(e, "whole", "the spawn tool's worker's /prog");
	spawn progview(r, "read" :: nil);
	(nil, e) = <-r;
	t.assertseq(e, "self only", "another tool's /prog");
	spawn childprog(r);
	(nil, e) = <-r;
	t.assertseq(e, "self only", "a subagent's /prog");
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
	nsconstruct = load NsConstruct NsConstruct->PATH;
	if(nsconstruct == nil) {
		sys->fprint(sys->fildes(2), "cannot load nsconstruct: %r\n");
		raise "fail:cannot load nsconstruct";
	}
	nsconstruct->init();

	run("NoToolServer", testNoToolServer);
	run("NoModelService", testNoModelService);
	run("CoordinatorUnchanged", testCoordinatorUnchanged);
	run("AuditRequired", testAuditRequired);
	run("ManifestKept", testManifestKept);
	run("TmpVeltroGrants", testTmpVeltroGrants);
	run("GrantsRefused", testGrantsRefused);
	run("StoresPerActivity", testStoresPerActivity);
	run("WalletView", testWalletView);
	run("UiView", testUiView);
	run("GatedTools", testGatedTools);
	run("EntryNames", testEntryNames);
	run("CleanupKeepsFiles", testCleanupKeepsFiles);
	run("StaleOverlayRefused", testStaleOverlayRefused);
	run("ExecManifestHasNamespace", testExecManifestHasNamespace);
	run("ProgForSpawnAlone", testProgForSpawnAlone);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

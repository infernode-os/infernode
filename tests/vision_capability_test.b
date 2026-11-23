implement VisionCapabilityTest;

#
# The vision tool's grant (nsconstruct).  An agent given the vision tool
# held all of /mnt/vision, as the server's user: besides sending a
# picture it could load and unload models (the server's ctl), have the
# server open any feed, a camera among them (a session's ctl: src), make
# sessions without end (clone) and read every other session's answers.
#
# A tool call's name space now has the models to read and one session,
# made for it, with its image, detections and status: no ctl of either
# kind, no clone, no other session; the session goes when the call's
# descriptors do.  The agent loop's own name space has the models alone.
# A subagent made from inside a call's name space is given that call's
# session, and the descriptor that keeps it (NsConstruct->held).  A
# generic path grant of /mnt/vision, without the tool, gives nothing.
# The tool finds the session it was given, and applies -c and -t itself.
#
# visionfs runs in the test, with no model unless one is given:
#	vision_capability_test [-v] [-m modeldir picture]
# (tests/host/visionfs_test.sh gives its own; without one the tool's
# picture is answered "no model", by the session it was given.)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "nsconstruct.m";
	nsc: NsConstruct;

# Tool interface (as /appl/veltro/tool.m)
Tool: module {
	init:	fn(): string;
	exec:	fn(args: string): string;
};

VisionCapabilityTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/vision_capability_test.b";
V: con "/mnt/vision";
PICDIR: con "/tmp/veltro/vision_capability_test";	# a path that can be granted
PIC: con PICDIR + "/p.ppm";

passed := 0;
failed := 0;
skipped := 0;

model := "";	# a model directory, if one was given
picture := PIC;	# the test's copy: what the tool is asked about
given := "";	# the picture given with a model
other := "";	# a session of the test's own: another's, to an agent
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

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

isnumber(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return len s > 0;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# a directory's names, sorted, on one line
names(dir: string): string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return "-";
	l: list of string;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			l = d[i].name :: l;
	}
	a := array[len l] of string;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	for(i = 1; i < len a; i++)
		for(j := i; j > 0 && a[j-1] > a[j]; j--)
			(a[j-1], a[j]) = (a[j], a[j-1]);
	s := "";
	for(i = 0; i < len a; i++){
		if(i > 0)
			s += " ";
		s += a[i];
	}
	return s;
}

# the sessions in a view of /mnt/vision
sessions(): list of string
{
	(nil, l) := sys->tokenize(names(V), " ");
	r: list of string;
	for(; l != nil; l = tl l)
		if(isnumber(hd l))
			r = hd l :: r;
	return r;
}

# /mnt/vision as seen: its names with "N" for a session that is not the
# test's own, and that session's names
view(): string
{
	if(!exists(V))
		return "nothing";
	(nil, l) := sys->tokenize(names(V), " ");
	s := "";
	for(; l != nil; l = tl l){
		n := hd l;
		if(isnumber(n) && n != other)
			n = "N[" + names(V + "/" + n) + "]";
		else if(n == other)
			n = "OTHER";
		s += n + " ";
	}
	return s;
}

caps(tools, paths: list of string): ref NsConstruct->Capabilities
{
	return ref NsConstruct->Capabilities(tools, paths,
		nil, nil, nil, nil, 0, 0, -1, nil, nil);
}

Kcoord, Ktool, Kchild, Knested: con iota;

# what an agent with these capabilities sees, from a name space and a
# descriptor table of its own; then what args asks of the tool, if any
agentview(c: ref NsConstruct->Capabilities, kind: int, args: list of string, rc: chan of string)
{
	sys->pctl(Sys->FORKNS|Sys->FORKFD, nil);
	err: string;
	case kind {
	Kcoord =>
		err = nsc->restrictns(c);
	Ktool =>
		err = nsc->restricttoolns(c);
	Kchild =>
		err = nsc->restrictchildns(c, 0);
	Knested =>
		err = nsc->restricttoolns(c);
		before := view();
		if(err == nil)
			err = nsc->restrictchildns(c, 0);
		if(err == nil && view() != before)
			err = "the child's view is not its parent's: " + view() + ", not " + before;
		if(err == nil){
			# a child keeps what held() gives and no other descriptor
			h := nsc->held();
			if(len h != 1)
				err = sys->sprint("held() gave %d descriptors", len h);
			else
				sys->pctl(Sys->NEWFD, 1 :: 2 :: h);
		}
	}
	if(err != nil){
		rc <-= "restrict: " + err;
		return;
	}
	s := view();
	for(; args != nil; args = tl args)
		s += "| " + tool->exec(hd args);
	rc <-= s;
}

ask(c: ref NsConstruct->Capabilities, kind: int, args: list of string): string
{
	rc := chan of string;
	spawn agentview(c, kind, args, rc);
	return <-rc;
}

Granted: con "N[detections image status] models ";

testToolGrant(t: ref T)
{
	t.assert(contains(view(), "clone ") && contains(view(), "ctl ") && contains(view(), "OTHER "),
		"the mount has ctl, clone and another's session: " + view());
	s := ask(caps("vision" :: nil, nil), Ktool, nil);
	t.assertseq(s, Granted, "a tool call has the models and a session's picture and answer, and no more");
}

testCoordinator(t: ref T)
{
	s := ask(caps("vision" :: "read" :: nil, nil), Kcoord, nil);
	t.assertseq(s, "models ", "the agent loop's own name space has the models alone");
}

testChild(t: ref T)
{
	s := ask(caps("vision" :: nil, nil), Kchild, nil);
	t.assertseq(s, Granted, "a subagent has the models and a session");
	args := picture :: nil;
	s = ask(caps("vision" :: nil, PICDIR :: nil), Knested, args);
	t.assert(len s > len Granted && s[0:len Granted] == Granted,
		"a subagent made in a call's name space has that call's session: " + s);
	t.assert(!contains(s, "no vision service") && !contains(s, "does not exist"),
		"and it outlives the subagent's other descriptors (held): " + s);
}

testPathGrant(t: ref T)
{
	s := ask(caps("read" :: nil, V :: nil), Kcoord, nil);
	t.assert(s == "nothing" || len s > 9 && s[0:9] == "restrict:",
		"a generic grant of /mnt/vision gives nothing: '" + s + "'");
}

testTool(t: ref T)
{
	c := caps("vision" :: nil, PICDIR :: nil);
	if(model == nil){
		s := ask(c, Ktool, picture :: nil);
		t.assert(contains(s, "| error:") && contains(s, "no model"),
			"the tool's picture reaches the session it was given, which has no model: " + s);
		t.assert(!contains(s, "no vision service"), "it found its session");
		return;
	}
	s := ask(c, Ktool, picture :: nil);
	t.assert(contains(s, "| class=") && contains(s, " score="), "a picture's detection through the grant: " + s);
	s = ask(c, Ktool, "-c nosuchclass " + picture :: nil);
	t.assert(contains(s, "| nothing found"), "a class that is not there, left out by the tool: " + s);
	s = ask(c, Ktool, "-t 1 " + picture :: nil);
	t.assert(contains(s, "| nothing found"), "a score no detection has, left out by the tool: " + s);
	s = ask(c, Ktool, "-t 0 " + picture :: nil);
	t.assert(contains(s, "| class="), "any score kept: " + s);
	s = ask(c, Ktool, "-t x " + picture :: nil);
	t.assert(contains(s, "| error: thresh"), "a score that is no number refused by the tool: " + s);
}

# every session made for a view went with it
testSessionsGone(t: ref T)
{
	for(i := 0; i < 30 && len sessions() > 1; i++)
		sys->sleep(100);
	t.asserteq(len sessions(), 1, "the sessions made for the views are gone with them: " + names(V));
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
	if(args != nil)
		args = tl args;
	for(; args != nil; args = tl args){
		if(hd args == "-v")
			testing->verbose(1);
		else if(hd args == "-m" && len args >= 3){
			model = hd tl args;
			given = hd tl tl args;
			args = tl tl args;
		}
	}
	nsc = load NsConstruct NsConstruct->PATH;
	visionfs := load Command "/dis/visionfs.dis";
	tool = load Tool "/dis/veltro/tools/vision.dis";
	if(nsc == nil || visionfs == nil || tool == nil)
		raise "skip:nsconstruct, visionfs or the vision tool not built";
	nsc->init();
	if((e := tool->init()) != nil)
		raise "fail:vision init: " + e;

	sys->pctl(Sys->FORKNS, nil);
	# what a tool server makes before its first call's name space
	for(dl := "/tmp/veltro" :: "/tmp/veltro/.ns" :: nil; dl != nil; dl = tl dl)
		if(!exists(hd dl))
			sys->create(hd dl, Sys->OREAD, Sys->DMDIR | 8r755);
	{
		if(model != nil)
			visionfs->init(nil, "visionfs" :: "-m" :: V :: "load" :: "m" :: model :: nil);
		else
			visionfs->init(nil, "visionfs" :: "-m" :: V :: nil);
	} exception x {
	"*" =>
		raise "skip:visionfs: " + x;
	}
	# the picture, where an agent can be granted it
	sys->create(PICDIR, Sys->OREAD, Sys->DMDIR | 8r755);
	fd := sys->create(PIC, Sys->OWRITE, 8r644);
	if(fd == nil)
		raise sys->sprint("fail:%s: %r", PIC);
	if(model == nil)
		sys->fprint(fd, "P6\n1 1\n255\nabc");
	else{
		gfd := sys->open(given, Sys->OREAD);
		if(gfd == nil)
			raise sys->sprint("fail:%s: %r", given);
		buf := array[Sys->ATOMICIO] of byte;
		while((gn := sys->read(gfd, buf, len buf)) > 0)
			sys->write(fd, buf, gn);
	}
	fd = nil;
	# another's session, held open through the tests
	ofd := sys->open(V + "/clone", Sys->OREAD);
	if(ofd == nil)
		raise sys->sprint("fail:clone: %r");
	b := array[32] of byte;
	n := sys->read(ofd, b, len b);
	if(n <= 1)
		raise "fail:clone gave no session";
	other = string b[0:n-1];

	run("ToolGrant", testToolGrant);
	run("Coordinator", testCoordinator);
	run("Child", testChild);
	run("PathGrant", testPathGrant);
	run("Tool", testTool);
	run("SessionsGone", testSessionsGone);

	ofd = nil;
	sys->remove(PIC);
	sys->remove(PICDIR);
	# the server's last reference: visionfs sees the hangup and exits
	sys->unmount(nil, V);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

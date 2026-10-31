implement GpsCapabilityTest;

#
# The gps tool's grant (nsconstruct): an agent given the gps tool sees
# /mnt/gps's read files (position, fix, event, satellites, status) and
# not ctl, feed or nmea, and the tool reads the position through them;
# an agent given a generic path grant of /mnt/gps, without the tool,
# sees no /mnt/gps at all.  gpsfs runs in the test, fed a fix.
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

include "../appl/veltro/tool.m";

GpsCapabilityTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/gps_capability_test.b";

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

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

caps(tools, paths: list of string): ref NsConstruct->Capabilities
{
	return ref NsConstruct->Capabilities(tools, paths,
		nil, nil, nil, nil, 0, 0, -1, nil, nil);
}

# what an agent with these capabilities sees, from a name space of its
# own: one line a file, and the tool's answer if the tool is given
agentview(c: ref NsConstruct->Capabilities, tool: Tool, rc: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	if((err := nsc->restrictns(c)) != nil) {
		rc <-= "restrictns: " + err;
		return;
	}
	s := "";
	for(l := "position" :: "fix" :: "event" :: "satellites" :: "status" ::
			"ctl" :: "feed" :: "nmea" :: nil; l != nil; l = tl l)
		if(exists("/mnt/gps/" + hd l))
			s += hd l + " ";
	if(exists("/mnt/gps"))
		s = "dir " + s;
	if(tool != nil)
		s += "| " + tool->exec("position");
	rc <-= s;
}

testToolGrant(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/gps.dis";
	if(tool == nil)
		t.fatal(sys->sprint("cannot load the gps tool: %r"));
	if((err := tool->init()) != nil)
		t.fatal("gps init: " + err);
	rc := chan of string;
	spawn agentview(caps("gps" :: nil, nil), tool, rc);
	s := <-rc;
	t.assertseq(s, "dir position fix event satellites status | -33.866667 151.200000\n",
		"the read files only, and the tool reads the position");
}

testPathGrant(t: ref T)
{
	rc := chan of string;
	spawn agentview(caps("read" :: nil, "/mnt/gps" :: nil), nil, rc);
	s := <-rc;
	t.assert(s == "" || len s > 10 && s[0:10] == "restrictns",
		"a generic grant of /mnt/gps gives nothing: '" + s + "'");
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
	nsc = load NsConstruct NsConstruct->PATH;
	gpsfs := load Command "/dis/gpsfs.dis";
	if(nsc == nil || gpsfs == nil)
		raise "skip:nsconstruct or gpsfs not built";
	nsc->init();

	# a receiver of the test's own, given a fix through feed
	sys->pctl(Sys->FORKNS, nil);
	gpsfs->init(nil, "gpsfs" :: "-m" :: "/mnt/gps" :: nil);
	fd := sys->open("/mnt/gps/feed", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "$GPRMC,090000.00,A,3352.0000,S,15112.0000,E,,,311026,,,A\n") < 0)
		raise sys->sprint("fail:feed: %r");
	fd = nil;

	run("ToolGrant", testToolGrant);
	run("PathGrant", testPathGrant);
	# the receiver's last reference: gpsfs sees the hangup and exits
	sys->unmount(nil, "/mnt/gps");

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

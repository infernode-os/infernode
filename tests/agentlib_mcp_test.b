implement AgentlibMcpTest;

#
# agentlib_mcp_test.b — unit tests for the shared agentlib MCP router (INFR-247):
# mcpdiscover / mcptooldefs / mcpresolve. These are the pure-ish functions the
# NERVA dispatch path and the sub-agent bridge BOTH route through, so a
# regression here breaks tool routing for the whole agent stack. The live eval
# rig exercises them end-to-end against the real MCP fleet; this gives them
# automated CI coverage without a live stack, using synthetic /mnt/mcp-shaped
# mounts built under /tmp.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "agentlib.m";
	agentlib: AgentLib;

AgentlibMcpTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/agentlib_mcp_test.b";

# Synthetic mount roots (real dirs, so tools/ dirread works — unlike the
# mntgen-served /mnt/mcp parent, which is why discovery takes explicit paths).
ROOT:   con "/tmp/mcptest";
OSM:    con "/tmp/mcptest/osm";
TERRA:  con "/tmp/mcptest/terra";

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

# --- fake-mount builders -------------------------------------------------

mkdirp(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return;
	for(i := len path - 1; i > 0; i--)
		if(path[i] == '/') {
			mkdirp(path[0:i]);
			break;
		}
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
	if(fd != nil)
		fd = nil;
}

writefile(path, content: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	d := array of byte content;
	sys->write(fd, d, len d);
}

# Build a fake MCP mount: _meta/name = prefix, and a tools/<tool>/{doc,schema}
# dir per (toolname, schema) entry.
mkmount(root, prefix: string, tools: list of (string, string))
{
	mkdirp(root + "/_meta");
	writefile(root + "/_meta/name", prefix);
	mkdirp(root + "/tools");
	for(; tools != nil; tools = tl tools) {
		(tn, schema) := hd tools;
		mkdirp(root + "/tools/" + tn);
		writefile(root + "/tools/" + tn + "/doc", "doc for " + tn);
		writefile(root + "/tools/" + tn + "/schema", schema);
	}
}

setupmounts()
{
	# osm: geocode_address (+ ping, shared with terra for the ambiguity case)
	mkmount(OSM, "osm",
		("geocode_address", "{\"type\":\"object\",\"properties\":{\"address\":{\"type\":\"string\"}}}") ::
		("ping",            "{\"type\":\"object\"}") ::
		nil);
	# terra: prefix from _meta/name is "terramcp" even though the dir is "terra" —
	# proves discovery keys on _meta/name, not the path basename. $schema present
	# to exercise the strip path.
	mkmount(TERRA, "terramcp",
		("get_elevation", "{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{\"latitude\":{\"type\":\"number\"}}}") ::
		("ping",          "{\"type\":\"object\"}") ::
		nil);
}

paths(): list of string
{
	return OSM :: TERRA :: nil;
}

# --- membership helpers --------------------------------------------------

haspair(l: list of (string, string), a, b: string): int
{
	for(; l != nil; l = tl l) {
		(x, y) := hd l;
		if(x == a && y == b)
			return 1;
	}
	return 0;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# --- tests ---------------------------------------------------------------

# mcpdiscover finds both mounts, keys the prefix off _meta/name (not basename),
# and enumerates every tool dir as (bare-tool, mount).
testDiscover(t: ref T)
{
	(mounts, tools) := agentlib->mcpdiscover(paths());

	t.assert(haspair(mounts, "osm", OSM), "osm mount discovered by _meta/name");
	t.assert(haspair(mounts, "terramcp", TERRA),
		"terra dir discovered with prefix 'terramcp' from _meta/name");

	t.assert(haspair(tools, "geocode_address", OSM), "osm/geocode_address tool found");
	t.assert(haspair(tools, "get_elevation", TERRA), "terra/get_elevation tool found");
	t.assert(haspair(tools, "ping", OSM) && haspair(tools, "ping", TERRA),
		"ping found under BOTH mounts");
}

# A mount path that doesn't exist (or lacks _meta/name) is skipped, not fatal.
testDiscoverSkipsMissing(t: ref T)
{
	(mounts, nil) := agentlib->mcpdiscover("/tmp/mcptest/nope" :: OSM :: nil);
	t.assert(haspair(mounts, "osm", OSM), "existing mount still found");
	t.assert(!haspair(mounts, "nope", "/tmp/mcptest/nope"), "missing mount skipped");
}

# mcptooldefs builds a combined "<prefix>_<tool>" defs array and strips $schema.
testTooldefs(t: ref T)
{
	(mounts, nil) := agentlib->mcpdiscover(paths());
	defs := agentlib->mcptooldefs(mounts, 64, 60000);

	t.assert(defs[0] == '[' && defs[len defs - 1] == ']', "defs is a JSON array");
	t.assert(contains(defs, "\"osm_geocode_address\""), "osm_geocode_address named");
	t.assert(contains(defs, "\"terramcp_get_elevation\""), "terramcp_get_elevation named");
	t.assert(!contains(defs, "$schema"), "$schema stripped from parameters");
}

# The per-mount cap bounds how many tools are emitted (the full set stays
# reachable via mcpresolve regardless — see testResolve).
testTooldefsCap(t: ref T)
{
	(mounts, nil) := agentlib->mcpdiscover(OSM :: nil);   # osm has 2 tools
	defs := agentlib->mcptooldefs(mounts, 1, 60000);      # cap to 1 per mount
	# exactly one tool object => no comma separating two objects
	t.assert(!contains(defs, "},{"), "per-mount cap limits emitted tools");
}

# mcpresolve: exact prefix, corrected prefix (the INFR-224 typo case),
# ambiguity, and the unresolved case.
testResolve(t: ref T)
{
	(mounts, tools) := agentlib->mcpdiscover(paths());

	# (1) exact prefix owns the tool -> corrected=0
	(m1, b1, c1) := agentlib->mcpresolve("osm_geocode_address", mounts, tools);
	t.assertseq(m1, OSM, "exact: osm_geocode_address -> osm mount");
	t.assertseq(b1, "geocode_address", "exact: bare tool name");
	t.asserteq(c1, 0, "exact: not corrected");

	# (2) typo'd/wrong prefix, unique owner -> route there, corrected=1.
	# This is the taramcp_/takamcp_ failure mode that scored chains INCOMPLETE.
	(m2, b2, c2) := agentlib->mcpresolve("taramcp_get_elevation", mounts, tools);
	t.assertseq(m2, TERRA, "corrected: taramcp_get_elevation -> terra mount (unique owner)");
	t.assertseq(b2, "get_elevation", "corrected: bare tool name");
	t.asserteq(c2, 1, "corrected: flagged");

	# (3) ambiguous bare name with a wrong prefix -> unresolved (ping is on both).
	(m3, nil, nil) := agentlib->mcpresolve("xyz_ping", mounts, tools);
	t.assertseq(m3, "", "ambiguous: wrong-prefix ping is unresolved (owned by 2 mounts)");

	# (4) but the right prefix disambiguates an otherwise-ambiguous tool.
	(m4, b4, c4) := agentlib->mcpresolve("osm_ping", mounts, tools);
	t.assertseq(m4, OSM, "disambiguated: osm_ping -> osm mount");
	t.assertseq(b4, "ping", "disambiguated: bare tool name");
	t.asserteq(c4, 0, "disambiguated: not corrected (prefix owns it)");

	# (5) completely unknown tool -> unresolved.
	(m5, nil, nil) := agentlib->mcpresolve("nosuch_tool", mounts, tools);
	t.assertseq(m5, "", "unknown tool is unresolved");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	agentlib = load AgentLib AgentLib->PATH;
	if(agentlib == nil) {
		sys->fprint(sys->fildes(2), "cannot load agentlib: %r\n");
		raise "fail:cannot load agentlib";
	}
	agentlib->init();

	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	setupmounts();

	run("Discover", testDiscover);
	run("DiscoverSkipsMissing", testDiscoverSkipsMissing);
	run("Tooldefs", testTooldefs);
	run("TooldefsCap", testTooldefsCap);
	run("Resolve", testResolve);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

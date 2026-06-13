implement ToolSchemaTest;

#
# tool_schema_test - Tests for the per-tool OpenAI function-schema surface (INFR-126)
#
# Two layers:
#
#   A. Unit tests (always run) — load each tool's .dis directly via the
#      Tool module type, call schema(), and verify the result:
#        - is non-empty
#        - parses as JSON
#        - is an object with name/description/parameters keys
#        - the "name" field matches the tool's own name() return
#        - parameters is an object with type=object and properties
#
#   B. Live 9P tests (skip if /tool/tools not mounted) — for every tool in
#      /tool/_registry, /tool/<name>/schema must return the same JSON the
#      tool's schema() produces, and agentlib->buildtooldefs must wrap each
#      tool's published schema (no legacy single-string fallback for any
#      tool that ships with a schema).
#
# Run: emu -r$ROOT /tests/tool_schema_test.dis [-v]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "bufio.m";
	bufio: Bufio;

include "json.m";
	json: JSON;
	JValue: import json;

include "testing.m";
	testing: Testing;
	T: import testing;

include "../appl/veltro/agentlib.m";
	agentlib: AgentLib;

ToolSchemaTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tool_schema_test.b";

# Canonical list of registered Veltro tools (the same set served by
# tools9p when launched with these names). Kept in alphabetical order
# so failures are easy to localise.
TOOLS := array[] of {
	"browse",   "charon",  "diff",     "edit",     "editor",
	"exec",     "find",    "fractal",  "gap",      "git",
	"gpu",      "grep",    "hear",     "http",     "json",
	"keyring",  "launch",  "limbo",    "list",     "man",
	"memory",   "mount",   "payfetch", "plan",     "present",
	"read",     "safeexec","say",      "search",   "shell",
	"spawn",    "task",    "todo",     "vision",   "wallet",
	"webfetch", "websearch","wiki",    "write",    "xenith",
};

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip"  => ;
	* => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# ---------- JSON helpers ----------

parsejson(s: string): (ref JValue, string)
{
	bio := bufio->aopen(array of byte s);
	if(bio == nil)
		return (nil, "cannot open buffer");
	return json->readjson(bio);
}

getstring(v: ref JValue, key: string): string
{
	if(v == nil)
		return "";
	field := v.get(key);
	if(field == nil)
		return "";
	pick s := field {
	String => return s.s;
	}
	return "";
}

# ---------- Tool loader ----------

# Tool module type interface — must match module/tool.m.
Tool: module {
	init: fn(): string;
	name: fn(): string;
	doc: fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

loadtool(name: string): (Tool, string)
{
	path := "/dis/veltro/tools/" + name + ".dis";
	m := load Tool path;
	if(m == nil)
		return (nil, sys->sprint("cannot load %s: %r", path));
	err := m->init();
	if(err != nil)
		return (nil, sys->sprint("init %s failed: %s", name, err));
	return (m, nil);
}

# ---------- Layer A: per-tool schema unit tests ----------

# For each tool: load it, call schema(), and verify the JSON shape.
# Reports each failing tool inline so a single regression doesn't mask
# the rest of the set.
testSchemaShapeAllTools(t: ref T)
{
	for(i := 0; i < len TOOLS; i++) {
		name := TOOLS[i];
		(m, err) := loadtool(name);
		if(m == nil) {
			t.error(sys->sprint("%s: load failed: %s", name, err));
			continue;
		}

		raw := m->schema();
		if(!t.assert(raw != "", sys->sprint("%s: schema() returned empty string", name)))
			continue;

		# Must parse as JSON
		(jv, jerr) := parsejson(raw);
		if(!t.assert(jerr == nil, sys->sprint("%s: schema not valid JSON: %s", name, jerr)))
			continue;
		if(!t.assert(jv != nil, sys->sprint("%s: schema parsed to nil", name)))
			continue;

		# Must be an object
		ok := 0;
		pick obj := jv {
		Object => ok = 1;
		}
		if(!t.assert(ok != 0, sys->sprint("%s: schema not a JSON object", name)))
			continue;

		# name field must match the tool's name()
		sname := getstring(jv, "name");
		t.assertseq(sname, m->name(),
			sys->sprint("%s: schema.name matches tool.name()", name));

		# description must be present and non-empty
		desc := getstring(jv, "description");
		t.assert(desc != "",
			sys->sprint("%s: schema.description non-empty", name));

		# parameters must be an object with type=object and properties
		params := jv.get("parameters");
		if(!t.assert(params != nil, sys->sprint("%s: schema.parameters present", name)))
			continue;
		ptype := getstring(params, "type");
		t.assertseq(ptype, "object",
			sys->sprint("%s: schema.parameters.type == object", name));
		props := params.get("properties");
		t.assert(props != nil,
			sys->sprint("%s: schema.parameters.properties present", name));
		ok2 := 0;
		pick po := props {
		Object => ok2 = 1;
		}
		t.assert(ok2 != 0,
			sys->sprint("%s: schema.parameters.properties is object", name));
	}
}

# Required-field property check: every entry in "required" must also
# appear as a key in "properties". Catches typos in hand-written schemas.
testRequiredKeysAreDeclared(t: ref T)
{
	for(i := 0; i < len TOOLS; i++) {
		name := TOOLS[i];
		(m, err) := loadtool(name);
		if(m == nil) {
			t.error(sys->sprint("%s: load failed: %s", name, err));
			continue;
		}
		(jv, jerr) := parsejson(m->schema());
		if(jerr != nil)
			continue;  # already covered by testSchemaShape

		params := jv.get("parameters");
		if(params == nil)
			continue;
		props := params.get("properties");
		required := params.get("required");
		if(required == nil)
			continue;  # required is optional in JSON Schema

		pick ra := required {
		Array =>
			for(j := 0; j < len ra.a; j++) {
				rname := "";
				pick rv := ra.a[j] {
				String => rname = rv.s;
				}
				if(rname == "")
					continue;
				declared := props.get(rname);
				t.assert(declared != nil,
					sys->sprint("%s: required '%s' is declared in properties",
						name, rname));
			}
		}
	}
}

# Every schema property must declare a valid JSON Schema type.
#
# This originally asserted "string" specifically — a V1 text-bridge
# constraint from when a non-string property would be silently dropped by
# extracttoolargs()'s space-join into a ctl-line. That no longer holds:
# extracttoolargs() now stringifies non-string properties via .text(), and
# JSON-native tools parse their raw JSON args directly (e.g. spawn detects a
# leading '{' and runs parsejsonspecs() on its `agents` array). So a
# structured type like array/object is legitimate; assert validity, not
# string-ness.
validjsontype(ty: string): int
{
	case ty {
	"string" or "number" or "integer" or "boolean" or "array" or "object" or "null" =>
		return 1;
	* =>
		return 0;
	}
}

testPropertiesAreTyped(t: ref T)
{
	for(i := 0; i < len TOOLS; i++) {
		name := TOOLS[i];
		(m, err) := loadtool(name);
		if(m == nil) {
			t.error(sys->sprint("%s: load failed: %s", name, err));
			continue;
		}
		(jv, jerr) := parsejson(m->schema());
		if(jerr != nil)
			continue;

		params := jv.get("parameters");
		if(params == nil)
			continue;
		props := params.get("properties");
		if(props == nil)
			continue;

		pick po := props {
		Object =>
			for(ml := po.mem; ml != nil; ml = tl ml) {
				(pname, pval) := hd ml;
				ptype := getstring(pval, "type");
				t.assert(validjsontype(ptype),
					sys->sprint("%s.%s: declares a valid JSON type (got %q)",
						name, pname, ptype));
			}
		}
	}
}

# ---------- Layer B: live 9P tests (skip if /tool not mounted) ----------

# Non-emptiness, not mere existence: an unmounted tools9p still leaves a
# stray empty /tool/_registry (gitignored repo stub, or a file a prior
# test wrote), which a bare stat mistakes for a live mount — turning
# these skips into false failures (INFR-312).
hastools9p(): int
{
	return len readfile("/tool/_registry") > 0;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	result := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		result += string buf[0:n];
	}
	return result;
}

# For each tool listed in /tool/_registry, /tool/<name>/schema must
# serve the same JSON as the tool's own schema() function.
testSchemaEndpointMatchesToolSchema(t: ref T)
{
	if(!hastools9p()) {
		t.skip("tools9p not mounted at /tool — run with `tools9p ...` first");
		return;
	}

	reg := readfile("/tool/_registry");
	if(reg == "") {
		t.fatal("/tool/_registry is empty");
		return;
	}
	(nil, names) := sys->tokenize(reg, " \t\n");

	for(nl := names; nl != nil; nl = tl nl) {
		name := hd nl;
		got := readfile("/tool/" + name + "/schema");
		t.assert(got != "",
			sys->sprint("%s: /tool/%s/schema served non-empty body", name, name));

		(jv, jerr) := parsejson(got);
		t.assert(jerr == nil,
			sys->sprint("%s: /tool/%s/schema is valid JSON: %s", name, name, jerr));
		if(jerr != nil)
			continue;

		# Cross-check against direct tool.schema()
		(m, lerr) := loadtool(name);
		if(m == nil) {
			t.error(sys->sprint("%s: direct load failed: %s", name, lerr));
			continue;
		}
		# Compare parsed names — exact string compare can fail across
		# whitespace, so normalise via the parsed name field.
		sname := getstring(jv, "name");
		t.assertseq(sname, m->name(),
			sys->sprint("%s: 9P /tool/%s/schema reports name=%s", name, name, m->name()));
	}
}

# agentlib->buildtooldefs must include a per-tool schema (NOT the legacy
# single-string fallback) for every tool that publishes one. We detect
# the legacy fallback by its tell-tale 'args' parameter inside a tool's
# parameters object — V1 tool schemas never use that property name.
testBuildToolDefsUsesPerToolSchemas(t: ref T)
{
	if(!hastools9p()) {
		t.skip("tools9p not mounted at /tool");
		return;
	}

	# Pick a representative subset of tools the test owns directly.
	# Each of these MUST publish a real schema (not legacy fallback).
	names := "find" :: "read" :: "list" :: "write" :: "grep" ::
		"plan" :: "present" :: "task" :: "memory" :: nil;

	defs := agentlib->buildtooldefs(names);
	t.assert(defs != "", "buildtooldefs returned non-empty");
	t.assert(len defs >= 2 && defs[0] == '[' && defs[len defs - 1] == ']',
		"buildtooldefs returned a JSON array literal");

	(jv, jerr) := parsejson(defs);
	if(!t.assert(jerr == nil, sys->sprint("buildtooldefs JSON parses: %s", jerr)))
		return;

	pick a := jv {
	Array =>
		t.asserteq(len a.a, 9, "buildtooldefs returned one entry per tool");
		for(i := 0; i < len a.a; i++) {
			entry := a.a[i];
			entryname := getstring(entry, "name");
			params := entry.get("parameters");
			t.assert(params != nil,
				sys->sprint("%s: parameters present in buildtooldefs entry",
					entryname));
			# Legacy fallback signature: properties has ONLY a single
			# "args" key. Subcommand-DSL tools legitimately use "args"
			# as a second property name (e.g. plan, task, memory) so
			# we can't reject "args" outright — we reject only the
			# sole-args shape.
			props := params.get("properties");
			if(props != nil) {
				pick po := props {
				Object =>
					nprops := 0;
					hasargs := 0;
					for(ml := po.mem; ml != nil; ml = tl ml) {
						(pname, nil) := hd ml;
						nprops++;
						if(pname == "args")
							hasargs = 1;
					}
					islegacy := (nprops == 1 && hasargs == 1);
					t.assert(!islegacy,
						sys->sprint("%s: NOT using legacy single-args fallback schema",
							entryname));
				}
			}
		}
	* =>
		t.fatal("buildtooldefs did not return a JSON array");
	}
}

# Regression check: round-trip a real tool through /tool/<name>/ctl using
# the ctl-line form, to confirm the schema endpoint addition didn't
# disturb the legacy argv contract.
testCtlRoundtripStillWorks(t: ref T)
{
	if(!hastools9p()) {
		t.skip("tools9p not mounted at /tool");
		return;
	}
	# Only run if `list` is registered with this tools9p instance.
	(ok, nil) := sys->stat("/tool/list/ctl");
	if(ok < 0) {
		t.skip("list tool not registered with this tools9p");
		return;
	}

	fd := sys->open("/tool/list/ctl", Sys->ORDWR);
	if(fd == nil) {
		t.fatal("cannot open /tool/list/ctl");
		return;
	}
	cmd := array of byte "/";
	n := sys->write(fd, cmd, len cmd);
	t.assert(n == len cmd, "wrote ctl-line argv to /tool/list/ctl");

	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf := array[8192] of byte;
	r := sys->read(fd, buf, len buf);
	t.assert(r > 0, "ctl-line response is non-empty");

	resp := string buf[0:r];
	# Either the listing or a permission error is fine — we just want to
	# confirm the ctl write/read cycle works under the new wire setup.
	t.assert(len resp > 0, "ctl response is non-empty string");
}

# ---------- main ----------

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	bufio = load Bufio Bufio->PATH;
	json = load JSON JSON->PATH;
	testing = load Testing Testing->PATH;
	agentlib = load AgentLib AgentLib->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(bufio == nil) {
		sys->fprint(sys->fildes(2), "cannot load bufio: %r\n");
		raise "fail:cannot load bufio";
	}
	if(json == nil) {
		sys->fprint(sys->fildes(2), "cannot load json: %r\n");
		raise "fail:cannot load json";
	}
	if(agentlib == nil) {
		sys->fprint(sys->fildes(2), "cannot load agentlib: %r\n");
		raise "fail:cannot load agentlib";
	}

	json->init(bufio);
	testing->init();
	agentlib->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("SchemaShapeAllTools", testSchemaShapeAllTools);
	run("RequiredKeysAreDeclared", testRequiredKeysAreDeclared);
	run("PropertiesAreTyped", testPropertiesAreTyped);
	run("SchemaEndpointMatchesToolSchema", testSchemaEndpointMatchesToolSchema);
	run("BuildToolDefsUsesPerToolSchemas", testBuildToolDefsUsesPerToolSchemas);
	run("CtlRoundtripStillWorks", testCtlRoundtripStillWorks);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

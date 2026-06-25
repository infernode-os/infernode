implement ToolSpawn;

#
# spawn - Create subagent(s) with secure namespace isolation for Veltro agent
#
# SYNTAX (v4 — parallel-capable, breaking change from v3):
# =========================================================
#   Spawn [timeout=N] -- tools=<t> paths=<p> [options] :: <task>
#                     -- tools=<t2> paths=<p2> :: <task2>
#
# Each -- section is one subagent (max 5). The :: separator is REQUIRED.
# Global options (timeout=N in seconds) go before the first --.
# Subagents run in parallel; results collected with per-subagent timeout.
# Note: task text must not contain ' -- ' (section separator).
#
# SECURITY MODEL (v4):
# ====================
# Same as v3 (FORKNS + bind-replace), extended for parallel children.
# Each child gets:
#   - Its OWN SubAgent module instance (prevents data-race on subagent globals)
#   - Its OWN LLM session (/mnt/llm/new clone pattern)
#   - Its OWN tools= and paths= (no sharing between parallel agents)
#   - Fresh NEWPGRP, FORKNS, NEWENV, NEWFD, NODEVS
# Tool modules are shared (read-only after init — no mutable global state).
#
# Child isolation steps (same as v3):
#   1. pctl(NEWPGRP)   - Empty srv registry
#   2. pctl(FORKNS)    - Fork parent's restricted namespace
#   3. pctl(NEWENV)    - Empty environment
#   4. Open LLM FDs    - While /mnt/llm still accessible
#   5. restrictns()    - Further bind-replace restrictions
#   6. verifysafefds() - Verify FDs 0-2 are safe
#   7. pctl(NEWFD)     - Prune all other FDs
#   8. pctl(NODEVS)    - Block #U/#p/#c
#   9. samod->runloop() - Execute task using dedicated SubAgent instance
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "daytime.m";
	daytime: Daytime;

include "rfc3339.m";
	rfc3339: Rfc3339;

include "bufio.m";
	bufio: Bufio;

include "json.m";
	json: JSON;
	JValue: import json;

include "../tool.m";
include "../nsconstruct.m";
	nsconstruct: NsConstruct;
include "../subagent.m";
include "agentlib.m";
	agentlib: AgentLib;

ToolSpawn: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

# Per-subagent specification (parsed from args)
SubSpec: adt {
	tools:     list of string;
	paths:     list of string;
	shellcmds: list of string;
	llmconfig: ref NsConstruct->LLMConfig;
	task:      string;
	# Scheduling (INFR-14). Inferno-native scheduling primitive: a sleeping
	# subagent in its own attenuated namespace, registered in /prog. No
	# scheduler service, no central registry, no cron syntax.
	at_ms:     int;   # >0: sleep this many ms before single runloop call
	every_ms:  int;   # >0: loop {sleep this many ms; runloop} until killed
};

# Wrapper so SubAgent module values can be stored in a list
SubAgentSlot: adt {
	mod: SubAgent;
};

# Pre-loaded tool modules.
# Shared across parallel children — safe because tool modules have no
# mutable globals after init().
PreloadedTool: adt {
	name: string;
	mod:  Tool;
};
preloadedtools: list of ref PreloadedTool;

# Result from a collector goroutine
ResultMsg: adt {
	idx:    int;
	result: string;
};

MAX_SUBAGENTS:      con 5;
DEFAULT_TIMEOUT_MS: con 300000;   # 5 minutes
RESULT_END:         con "\n<<EOF>>\n";
UI_MOUNT:           con "/mnt/ui";

# Per-subagent trajectory log directory. spawn.b opens one file per child
# before FORKNS and passes the fd into subagent->runloop. /usr/inferno/...
# is unreachable from inside the restricted namespace; opening before
# restriction is the only way to give subagents an observable record.
# Under /tmp/veltro — the ONLY tmp subtree nsconstruct keeps writable after the
# restriction (it allows just "veltro/" under /tmp and pre-creates it). The old
# /usr/inferno path isn't creatable post-restriction, so logs were silently lost.
SUBAGENT_LOG_BASE:  con "/tmp/veltro/subagents";

inited := 0;

init(): string
{
	if(inited)
		return nil;
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	nsconstruct = load NsConstruct NsConstruct->PATH;
	if(nsconstruct == nil)
		return "cannot load NsConstruct";
	nsconstruct->init();
	# daytime + rfc3339 are optional — only needed by at= scheduling.
	# If either load fails, at= parsing returns an error; the rest of
	# spawn keeps working.
	daytime = load Daytime Daytime->PATH;
	rfc3339 = load Rfc3339 Rfc3339->PATH;
	if(rfc3339 != nil)
		rfc3339->init();
	# bufio + json are optional — only needed to accept JSON tool-call args
	# (the LLM-native form). If either fails to load, exec falls back to the
	# DSL parser and a JSON arg returns a clear error.
	bufio = load Bufio Bufio->PATH;
	json = load JSON JSON->PATH;
	if(json != nil)
		json->init(bufio);
	# agentlib provides the shared MCP router (INFR-247) used to bridge MCP
	# tools into children. Loaded here in the PARENT namespace (before any
	# FORKNS/restriction); the loaded module survives FORKNS into runchild.
	# Optional: if it fails to load, children simply get no MCP tools.
	agentlib = load AgentLib AgentLib->PATH;
	if(agentlib != nil)
		agentlib->init();
	inited = 1;
	return nil;
}

name(): string
{
	return "spawn";
}

doc(): string
{
	return "Spawn - Create subagent(s) with secure namespace isolation\n\n" +
		"Usage:\n" +
		"  Spawn [timeout=N] -- tools=<t> paths=<p> [options] :: <task>\n" +
		"                    -- tools=<t2> paths=<p2> :: <task2>\n\n" +
		"Each -- section defines one subagent (max " + string MAX_SUBAGENTS + ").\n" +
		"The :: separator between spec and task is REQUIRED in every section.\n\n" +
		"Global options (before the first --):\n" +
		"  timeout=N     Seconds before each subagent is killed (default: 300)\n\n" +
		"Per-subagent options (in each -- section, before ::):\n" +
		"  tools=        Comma-separated tools to grant (REQUIRED)\n" +
		"  paths=        Comma-separated paths to expose\n" +
		"  shellcmds=    Comma-separated shell commands to allow\n" +
		"  model=        LLM model (default: haiku)\n" +
		"  temperature=  LLM temperature 0.0-2.0 (default: 0.7)\n" +
		"  thinking=     Thinking budget: off, max, or token count\n" +
		"  agenttype=    Load prompt from /lib/veltro/agents/<type>.txt\n" +
		"  system=       System prompt string (overrides agenttype)\n" +
		"  at=           Sleep until RFC3339 instant (e.g. 2026-05-10T09:00:00Z)\n" +
		"                then run a single iteration (returns 'scheduled' immediately)\n" +
		"  every=        Sleep <int><s|m|h|d> between iterations, looping forever\n" +
		"                until killed (echo kill > /prog/<pid>/ctl)\n\n" +
		"Examples:\n" +
		"  Spawn -- tools=read,list paths=/appl :: List all .b files\n" +
		"  Spawn -- tools=read,list agenttype=explore paths=/appl :: Find handlers\n" +
		"  Spawn timeout=60\n" +
		"       -- tools=read paths=/appl :: Analyze structure\n" +
		"       -- tools=grep paths=/lib :: Search for patterns\n\n" +
		"Output:\n" +
		"  Single subagent: result returned directly.\n" +
		"  Multiple: === Subagent N: <task> === blocks, one per agent.\n\n" +
		"Security:\n" +
		"  Each subagent gets its own tools, paths, and LLM session.\n" +
		"  Each parallel child gets a fresh SubAgent instance (no data races).\n" +
		"  Environment is empty. Capability attenuation: child can only narrow.\n" +
		"  Task text must not contain ' -- ' (section separator).";
}

schema(): string
{
	return "{" +
		"\"name\":\"spawn\"," +
		"\"description\":\"Delegate work to one or more subagents that run concurrently, each in an isolated namespace. Use for genuinely independent multi-step subtasks; collect their results and synthesize. Max 5 per call. Example: {\\\"agents\\\":[{\\\"task\\\":\\\"research topic A\\\"},{\\\"task\\\":\\\"research topic B\\\"}]}\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"agents\":{\"type\":\"array\",\"description\":\"Subagents to spawn in parallel (1-5).\"," +
					"\"items\":{\"type\":\"object\"," +
						"\"properties\":{" +
							"\"task\":{\"type\":\"string\",\"description\":\"What this subagent must do — a complete, self-contained instruction.\"}," +
							"\"tools\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Tool names this subagent may use (optional; defaults to a reasoning-only grant).\"}," +
							"\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"MCP server mounts to grant this subagent, e.g. [\\\"/mnt/mcp/osm\\\",\\\"/mnt/mcp/terramcp\\\"]. The child then runs its OWN tool loop against those servers. Grant only the servers the subtask needs.\"}" +
						"}," +
						"\"required\":[\"task\"]" +
					"}" +
				"}" +
			"}," +
			"\"required\":[\"agents\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();
	if(nsconstruct == nil)
		return "error: cannot load nsconstruct module";

	# Parse all subagent specs. A JSON-tool-calling model (the common case now)
	# emits a JSON object as the tool args rather than the legacy DSL string;
	# accept both. parsejsonspecs builds SubSpecs directly (no DSL round-trip,
	# so a task containing " :: " or " -- " can't mis-split). See parsejsonspecs.
	a := strip(args);
	specs: list of ref SubSpec;
	timeout_ms: int;
	perr: string;
	# A JSON tool-calling model emits {"agents":[...]}; agentlib's
	# extracttoolargs unwraps the single object property, so what reaches us
	# is the bare array "[...]". Route BOTH '{' and '[' to the JSON parser
	# (parsejsonspecs handles a bare array via jv.isarray()) — otherwise the
	# schema-correct structured call falls through to the DSL parser and is
	# rejected, defeating fan-out.
	if(a != "" && (a[0] == '{' || a[0] == '['))
		(specs, timeout_ms, perr) = parsejsonspecs(a);
	else
		(specs, timeout_ms, perr) = parsespecs(a);
	if(perr != "")
		return "error: " + perr;
	if(specs == nil)
		return "error: no subagent specs provided";

	# Count specs
	N := 0;
	{
		cntlist := specs;
		for(; cntlist != nil; cntlist = tl cntlist)
			N++;
	}

	# Pre-load one fresh SubAgent instance per spec, BEFORE any namespace
	# restriction or spawn.  subagent.b has module-level globals (loadedtools,
	# loadedtoolnames, llmaskfd) set in runloop().  If N parallel children
	# shared one SubAgent instance they would race on those globals.
	# Each `load SubAgent SubAgent->PATH` returns an independent instance
	# with its own globals.
	samods: list of ref SubAgentSlot;
	{
		sscnt := specs;
		for(; sscnt != nil; sscnt = tl sscnt) {
			sa := load SubAgent SubAgent->PATH;
			if(sa == nil)
				return sys->sprint("error: cannot load subagent: %r");
			saerr := sa->init();
			if(saerr != nil)
				return "error: cannot init subagent: " + saerr;
			samods = ref SubAgentSlot(sa) :: samods;
		}
	}
	samods = reversesamods(samods);

	# Pre-load tool modules (union of all specs' tool sets), BEFORE namespace
	# restriction.  Tools are stateless after init() — sharing is safe.
	toolerr := preloadmulti(specs);
	if(toolerr != "")
		return "error: " + toolerr;

	# Register sub-agents as background tasks in the Activity section.
	actid := currentactid();
	bgbase := -1;
	if(actid >= 0) {
		bgbase = countbgtasks(actid);
		for(ss := specs; ss != nil; ss = tl ss) {
			label := tasksummary((hd ss).task);
			bgadd(actid, label);
		}
	}

	# Result channel: buffered N so collector goroutines never block.
	resultchan := chan[N] of ref ResultMsg;

	# Common timestamp for all subagents in this batch — combined with idx,
	# gives each child a unique log filename without coordinating writers.
	batchms := sys->millisec();

	# Launch all subagents in parallel
	idx := 0;
	speclist := specs;
	salist := samods;
	while(speclist != nil) {
		spec := hd speclist;
		slot := hd salist;
		speclist = tl speclist;
		salist = tl salist;

		# Filter out memory tool — parent agent owns memory exclusively.
		# Subagents return results via pipe; parent persists what matters.
		childtools := dropitem("memory", spec.tools);

		caps := ref NsConstruct->Capabilities(
			childtools,
			spec.paths,
			spec.shellcmds,
			spec.llmconfig,
			0 :: 1 :: 2 :: nil,
			nil,
			0,    # No memory
			0,    # No xenith
			-1,   # No cowfs — subagents inherit parent's cowfs via FORKNS
			nil
		);

		# Open the trajectory log fd in the parent namespace, before
		# spawning. Survives FORKNS + bind-replace via the same fd-keep
		# pattern as llmaskfd. nil-on-failure: logging is best-effort —
		# a missing log must never break the agent loop.
		logfd := opensubagentlog(batchms, idx);

		# Scheduled (at= or every=): fire-and-forget. The child becomes a
		# real, killable process visible in /prog; result collection
		# would block well past any sane timeout (at= may be hours away;
		# every= never returns), so we report "scheduled" immediately and
		# do not spawn a collector. Cancellation: echo kill > /prog/$pid/ctl.
		if(spec.at_ms > 0 || spec.every_ms > 0) {
			# Pass nil pipe — runchild detects this and writes nothing back.
			spawn runchild(nil, logfd, caps, spec.task, slot.mod, spec.at_ms, spec.every_ms);
			schedmsg: string;
			if(spec.at_ms > 0)
				schedmsg = sys->sprint("scheduled: single run in %d ms", spec.at_ms);
			else
				schedmsg = sys->sprint("scheduled: every %d ms (kill via /prog/<pid>/ctl)", spec.every_ms);
			resultchan <-= ref ResultMsg(idx, schedmsg);
			idx++;
			continue;
		}

		pipefds := array[2] of ref Sys->FD;
		if(sys->pipe(pipefds) < 0) {
			# Send error directly — channel is buffered, won't block
			resultchan <-= ref ResultMsg(idx, "ERROR:cannot create pipe");
			idx++;
			continue;
		}

		spawn runchild(pipefds[1], logfd, caps, spec.task, slot.mod, 0, 0);
		pipefds[1] = nil;
		spawn collectorwithTimeout(pipefds[0], resultchan, timeout_ms, idx);
		idx++;
	}

	# Collect all results (order via idx field, not arrival order)
	results := array[N] of string;
	for(i := 0; i < N; i++) {
		msg := <-resultchan;
		results[msg.idx] = msg.result;
		# Update background task status as each result arrives
		if(actid >= 0 && bgbase >= 0) {
			status := "done";
			if(hasprefix(msg.result, "ERROR:"))
				status = "error";
			bgupdatestatus(actid, bgbase + msg.idx, status);
		}
	}

	# Remove completed background tasks after a brief display delay.
	# Remove from highest index to lowest so shifting doesn't
	# invalidate pending indices.
	if(actid >= 0 && bgbase >= 0) {
		sys->sleep(2000);
		for(ri := N - 1; ri >= 0; ri--)
			bgremove(actid, bgbase + ri);
	}

	# Format output
	if(N == 1) {
		r := results[0];
		if(hasprefix(r, "ERROR:"))
			return "error: " + r[6:];
		return r;
	}

	out := "";
	idx = 0;
	for(ss := specs; ss != nil; ss = tl ss) {
		spec := hd ss;
		if(out != "")
			out += "\n\n";
		r := results[idx];
		if(hasprefix(r, "ERROR:"))
			r = "error: " + r[6:];
		out += sys->sprint("=== Subagent %d: %s ===\n", idx+1, tasksummary(spec.task)) + r;
		idx++;
	}
	return out;
}

# Pre-load tool modules for the union of all specs' tool sets.
# Returns "" on success, error string on failure.
preloadmulti(specs: list of ref SubSpec): string
{
	# Collect union of tool names (deduplicated)
	seen: list of string;
	for(ss := specs; ss != nil; ss = tl ss) {
		spec := hd ss;
		for(t := spec.tools; t != nil; t = tl t) {
			nm := hd t;
			if(!inlist(nm, seen))
				seen = nm :: seen;
		}
	}

	preloadedtools = nil;
	for(s := seen; s != nil; s = tl s) {
		nm := hd s;
		path := "/dis/veltro/tools/" + nm + ".dis";
		mod := load Tool path;
		if(mod == nil)
			return sys->sprint("cannot load tool %s: %r", nm);
		merr := mod->init();
		if(merr != nil)
			return sys->sprint("cannot init tool %s: %s", nm, merr);
		preloadedtools = ref PreloadedTool(nm, mod) :: preloadedtools;
	}

	return "";
}

# Parse all subagent specs from the exec() args string.
#
# Syntax:  [timeout=N] -- spec1 :: task1 -- spec2 :: task2 ...
#   where spec = tools=<t> [paths=<p>] [model=M] ...
#
# Returns (specs, timeout_ms, error).  On error, specs is nil.
# --- JSON tool-call args (LLM-native) -> SubSpecs ---------------------------
# A JSON-tool-calling model emits a JSON object as the tool args, not the legacy
# DSL string. Accept, in addition to the DSL:
#   {"spec": "<dsl string>"}                          -> reuse the DSL parser
#   {"agents"|"tasks"|"subagents": [ {agent}, ... ]}  -> one SubSpec per element
#   [ {agent}, ... ]                                   -> bare array of agents
#   {task|prompt|..., tools, ...}                      -> a single SubSpec
# plus an optional top-level {"timeout": <seconds>}. Specs are built DIRECTLY
# (no DSL round-trip) so a task containing " :: " or " -- " can't mis-split.

# Extract a plain string from a JValue (String only; "" otherwise).
jvstr(v: ref JValue): string
{
	if(v == nil)
		return "";
	pick s := v {
	String =>
		return s.s;
	}
	return "";
}

# Numeric JValue (or numeric string) as a real; dflt if absent/non-numeric.
jvreal(v: ref JValue, dflt: real): real
{
	if(v == nil)
		return dflt;
	pick n := v {
	Real =>		return n.value;
	Int =>		return real n.value;
	String =>	return real n.s;
	}
	return dflt;
}

# First non-empty string among the named keys of an object.
jfirststr(o: ref JValue, keys: list of string): string
{
	for(; keys != nil; keys = tl keys) {
		s := strip(jvstr(o.get(hd keys)));
		if(s != "")
			return s;
	}
	return "";
}

# A JValue that is an array of strings OR a comma-separated string -> lowercased,
# stripped list. nil if absent.
jvstrlist(v: ref JValue): list of string
{
	r: list of string;
	if(v == nil)
		return nil;
	pick x := v {
	Array =>
		for(i := 0; i < len x.a; i++) {
			e := strip(jvstr(x.a[i]));
			if(e != "")
				r = str->tolower(e) :: r;
		}
		return reverse(r);
	String =>
		(nil, toks) := sys->tokenize(x.s, ",");
		for(; toks != nil; toks = tl toks)
			r = str->tolower(strip(hd toks)) :: r;
		return reverse(r);
	}
	return nil;
}

clampthink(t: int): int
{
	if(t < 0)
		return 0;
	if(t > 30000)
		return 30000;
	return t;
}

# Thinking budget from a JValue: "off"/"max"/"on"/number-string or a number.
jthinking(v: ref JValue): int
{
	if(v == nil)
		return 0;
	s := str->tolower(strip(jvstr(v)));
	if(s == "off" || s == "0")
		return 0;
	if(s == "max" || s == "on")
		return -1;
	if(s != "")
		return clampthink(int s);
	pick n := v {
	Int =>		return clampthink(int n.value);
	Real =>		return clampthink(int n.value);
	}
	return 0;
}

# Build one SubSpec from a JSON agent object.
buildagent(o: ref JValue): (ref SubSpec, string)
{
	if(o == nil)
		return (nil, "null subagent spec");
	spec := ref SubSpec;
	tkeys := "task" :: "prompt" :: "instruction" :: "description" :: "role" :: "goal" :: nil;
	spec.task = jfirststr(o, tkeys);
	if(spec.task == "") {
		# Some models nest the real fields under "arguments"/"parameters".
		inner := o.get("arguments");
		if(inner == nil)
			inner = o.get("parameters");
		if(inner != nil)
			spec.task = jfirststr(inner, tkeys);
	}
	if(spec.task == "")
		return (nil, "each subagent needs a task (task/prompt/instruction)");

	spec.tools = jvstrlist(o.get("tools"));
	if(spec.tools == nil)
		spec.tools = "plan" :: nil;   # a reasoning child still needs a grant; plan is safe
	spec.paths = jvstrlist(o.get("paths"));
	spec.shellcmds = jvstrlist(o.get("shellcmds"));

	# Scheduling (optional) — same primitives as the DSL at=/every=. Track via
	# locals (default 0) and assign explicitly, so an absent field is always 0
	# regardless of struct-init details.
	atms := 0;
	evms := 0;
	ats := strip(jvstr(o.get("at")));
	if(ats != "") {
		(dms, derr) := parserfc3339delta(ats);
		if(derr != "")
			return (nil, "at: " + derr);
		atms = dms;
	}
	evs := strip(jvstr(o.get("every")));
	if(evs != "") {
		(pms, eerr) := parseduration(evs);
		if(eerr != "")
			return (nil, "every: " + eerr);
		if(pms <= 0)
			return (nil, "every: period must be positive");
		evms = pms;
	}
	if(atms > 0 && evms > 0)
		return (nil, "cannot combine at and every in one subagent");
	spec.at_ms = atms;
	spec.every_ms = evms;

	# Default to the BACKEND's own model (empty => llmsrv default) rather than a
	# hardcoded Claude-era "haiku" — a non-Anthropic backend (e.g. a local
	# gpt-oss server) 404s on "haiku". An explicit "model" in the args still wins.
	llmmodel := str->tolower(jfirststr(o, "model" :: nil));
	llmtemp := jvreal(o.get("temperature"), 0.7);
	if(llmtemp < 0.0)
		llmtemp = 0.0;
	if(llmtemp > 2.0)
		llmtemp = 2.0;
	llmthink := jthinking(o.get("thinking"));
	llmsystem := jvstr(o.get("system"));
	agenttype := str->tolower(jfirststr(o, "agenttype" :: "agent_type" :: nil));
	if(llmsystem == "" && agenttype != "")
		llmsystem = loadagentprompt(agenttype);
	# No unconditional default.txt fallback for the JSON path: leave system empty
	# so spawn skips /system and the subagent's own (agentlib-appropriate) default
	# applies — the legacy default.txt carries the ReAct/DONE protocol that breaks
	# harmony backends.
	spec.llmconfig = ref NsConstruct->LLMConfig(llmmodel, llmtemp, llmsystem, llmthink);
	return (spec, "");
}

# The first array-valued property of a JSON object (key-agnostic fallback so any
# key a model picks — "spawns", "children", "workers", ... — still resolves).
firstarrayvalue(o: ref JValue): ref JValue
{
	pick obj := o {
	Object =>
		for(ml := obj.mem; ml != nil; ml = tl ml) {
			(nil, v) := hd ml;
			if(v != nil && v.isarray())
				return v;
		}
	}
	return nil;
}

# Build the spec list from a JSON array value.
buildfromarray(arr: ref JValue, timeout_ms: int): (list of ref SubSpec, int, string)
{
	specs: list of ref SubSpec;
	pick x := arr {
	Array =>
		if(len x.a == 0)
			return (nil, 0, "empty subagent array");
		if(len x.a > MAX_SUBAGENTS)
			return (nil, 0, sys->sprint("too many subagents (max %d)", MAX_SUBAGENTS));
		for(i := 0; i < len x.a; i++) {
			(sp, e) := buildagent(x.a[i]);
			if(e != "")
				return (nil, 0, e);
			specs = sp :: specs;
		}
		return (reversespecs(specs), timeout_ms, "");
	}
	return (nil, 0, "expected a JSON array of subagents");
}

parsejsonspecs(s: string): (list of ref SubSpec, int, string)
{
	if(json == nil)
		return (nil, 0, "JSON args unavailable; use the spec string form: -- tools=<csv> :: <task>");
	buf := bufio->aopen(array of byte s);
	if(buf == nil)
		return (nil, 0, "cannot buffer JSON args");
	(jv, jerr) := json->readjson(buf);
	if(jv == nil)
		return (nil, 0, "invalid JSON args: " + jerr);

	# Bare array of agents.
	if(jv.isarray())
		return buildfromarray(jv, DEFAULT_TIMEOUT_MS);

	timeout_ms := DEFAULT_TIMEOUT_MS;
	tosecs := jvreal(jv.get("timeout"), 0.0);
	if(tosecs > 0.0)
		timeout_ms = (int tosecs) * 1000;

	# {"spec": "<dsl>"} — the schema's documented contract; reuse the DSL parser.
	specstr := strip(jvstr(jv.get("spec")));
	if(specstr != "")
		return parsespecs(specstr);

	# {"agents"|"tasks"|"subagents"|"spawns": [ ... ]}, or — to be robust to
	# whatever key a model invents — the first array-valued property of the object.
	arr := jv.get("agents");
	if(arr == nil)
		arr = jv.get("tasks");
	if(arr == nil)
		arr = jv.get("subagents");
	if(arr == nil)
		arr = jv.get("spawns");
	if(arr == nil)
		arr = firstarrayvalue(jv);
	if(arr != nil)
		return buildfromarray(arr, timeout_ms);

	# Otherwise treat the whole object as a single subagent.
	(sp, e) := buildagent(jv);
	if(e != "")
		return (nil, 0, e);
	return (sp :: nil, timeout_ms, "");
}

parsespecs(s: string): (list of ref SubSpec, int, string)
{
	timeout_ms := DEFAULT_TIMEOUT_MS;
	s = strip(s);

	if(s == "")
		return (nil, 0, "usage: Spawn [timeout=N] -- tools=<t> paths=<p> :: <task>");

	# Separate global options from subagent sections.
	# If s starts with "--", there are no global options.
	global := "";
	rest := "";
	if(len s >= 2 && s[0:2] == "--") {
		# Skip the leading "--" — rest is the first section's body
		rest = strip(s[2:]);
	} else {
		# Global options precede the first " -- "
		(global, rest) = spliton(s, " -- ");
		rest = strip(rest);
		global = strip(global);
	}

	# Parse global options (currently only timeout=N)
	if(global != "") {
		(nil, gtoks) := sys->tokenize(global, " \t");
		for(; gtoks != nil; gtoks = tl gtoks) {
			tok := hd gtoks;
			if(hasprefix(tok, "timeout=")) {
				t := int tok[8:];
				if(t > 0)
					timeout_ms = t * 1000;
			}
		}
	}

	if(rest == "")
		return (nil, 0, "usage: Spawn [timeout=N] -- tools=<t> paths=<p> :: <task>");

	# Split rest on " -- " to get individual section strings
	subparts := splitonall(rest, " -- ");

	if(listlen(subparts) > MAX_SUBAGENTS)
		return (nil, 0, sys->sprint("too many subagents (max %d)", MAX_SUBAGENTS));

	specs: list of ref SubSpec;
	for(; subparts != nil; subparts = tl subparts) {
		(spec, serr) := parsespecsection(strip(hd subparts));
		if(serr != "")
			return (nil, 0, serr);
		specs = spec :: specs;
	}

	specs = reversespecs(specs);
	return (specs, timeout_ms, "");
}

# Parse one section of the form "tools=<t> [opts...] :: <task>".
# Returns (spec, error).
parsespecsection(section: string): (ref SubSpec, string)
{
	if(section == "")
		return (nil, "empty section after --");

	# Split on " :: " to separate spec options from task text
	(specpart, taskpart) := spliton(section, " :: ");
	task := strip(taskpart);
	if(task == "")
		return (nil, "missing ' :: ' separator in section: \"" + section + "\"");

	spec := ref SubSpec;
	spec.task = task;

	llmmodel   := "haiku";
	llmtemp    := 0.7;
	llmsystem  := "";
	llmthink   := 0;
	agenttype  := "";

	(nil, tokens) := sys->tokenize(specpart, " \t");
	for(; tokens != nil; tokens = tl tokens) {
		tv := hd tokens;
		if(hasprefix(tv, "tools=")) {
			(nil, tlist) := sys->tokenize(tv[6:], ",");
			for(; tlist != nil; tlist = tl tlist)
				spec.tools = str->tolower(hd tlist) :: spec.tools;
			spec.tools = reverse(spec.tools);
		} else if(hasprefix(tv, "paths=")) {
			(nil, plist) := sys->tokenize(tv[6:], ",");
			for(; plist != nil; plist = tl plist)
				spec.paths = hd plist :: spec.paths;
			spec.paths = reverse(spec.paths);
		} else if(hasprefix(tv, "shellcmds=")) {
			(nil, clist) := sys->tokenize(tv[10:], ",");
			for(; clist != nil; clist = tl clist)
				spec.shellcmds = str->tolower(hd clist) :: spec.shellcmds;
			spec.shellcmds = reverse(spec.shellcmds);
		} else if(hasprefix(tv, "model=")) {
			llmmodel = str->tolower(tv[6:]);
		} else if(hasprefix(tv, "temperature=")) {
			llmtemp = real tv[12:];
			if(llmtemp < 0.0)
				llmtemp = 0.0;
			if(llmtemp > 2.0)
				llmtemp = 2.0;
		} else if(hasprefix(tv, "thinking=")) {
			thinkval := str->tolower(tv[9:]);
			if(thinkval == "off" || thinkval == "0")
				llmthink = 0;
			else if(thinkval == "max" || thinkval == "on")
				llmthink = -1;
			else {
				llmthink = int thinkval;
				if(llmthink < 0)
					llmthink = 0;
				if(llmthink > 30000)
					llmthink = 30000;
			}
		} else if(hasprefix(tv, "system=")) {
			llmsystem = stripquotes(tv[7:]);
		} else if(hasprefix(tv, "agenttype=")) {
			agenttype = str->tolower(tv[10:]);
		} else if(hasprefix(tv, "at=")) {
			# Schedule a single run after sleeping until the named
			# RFC3339 instant. Inferno-native: the schedule IS a
			# sleeping subagent in /prog. No daemon, no registry.
			(delta_ms, derr) := parserfc3339delta(tv[3:]);
			if(derr != "")
				return (nil, "at=: " + derr);
			spec.at_ms = delta_ms;
		} else if(hasprefix(tv, "every=")) {
			# Schedule a recurring run every <duration>. Loops until
			# the subagent process is killed (echo kill > /prog/$pid/ctl).
			(period_ms, perr) := parseduration(tv[6:]);
			if(perr != "")
				return (nil, "every=: " + perr);
			if(period_ms <= 0)
				return (nil, "every=: period must be positive");
			spec.every_ms = period_ms;
		}
	}

	if(spec.at_ms > 0 && spec.every_ms > 0)
		return (nil, "cannot combine at= and every= in the same section");

	if(spec.tools == nil)
		return (nil, "tools= is required in each section");

	if(llmsystem == "" && agenttype != "")
		llmsystem = loadagentprompt(agenttype);
	if(llmsystem == "")
		llmsystem = loadagentprompt("default");

	spec.llmconfig = ref NsConstruct->LLMConfig(llmmodel, llmtemp, llmsystem, llmthink);
	return (spec, "");
}

# parseduration accepts ISO-8601-flavoured suffixes: <int><unit>
# where unit is s, m, h, or d. Returns (milliseconds, error).
# Examples: "30s" -> (30000, ""); "1h" -> (3600000, ""); "1d" -> (86400000, "").
parseduration(s: string): (int, string)
{
	if(s == "")
		return (0, "empty duration");
	n := len s;
	if(n < 2)
		return (0, "duration too short (need <int><s|m|h|d>)");
	unit := s[n-1];
	digits := s[0:n-1];
	# Reject non-digit prefixes early — `int "30s"` would silently strip
	# the suffix and succeed, defeating the unit check.
	for(i := 0; i < len digits; i++)
		if(digits[i] < '0' || digits[i] > '9')
			return (0, "duration must be <int><unit>");
	val := int digits;
	if(val < 0)
		return (0, "negative duration");
	mult: int;
	case unit {
	's' => mult = 1000;
	'm' => mult = 60 * 1000;
	'h' => mult = 3600 * 1000;
	'd' => mult = 86400 * 1000;
	*   => return (0, "unknown unit (use s/m/h/d)");
	}
	return (val * mult, "");
}

# parserfc3339delta wraps the shared appl/lib/rfc3339 parser to return
# the delta from now in milliseconds. Returns an error if parsing fails
# or the target is in the past. The "in the past" policy is local to
# scheduling — rfc3339->parse itself is policy-free and just returns
# absolute UTC epoch seconds.
parserfc3339delta(s: string): (int, string)
{
	if(rfc3339 == nil || daytime == nil)
		return (0, "rfc3339 / daytime module not available");
	(target, perr) := rfc3339->parse(s);
	if(perr != "")
		return (0, perr);
	now := daytime->now();
	if(target <= now)
		return (0, "target time is in the past");
	return ((target - now) * 1000, "");
}

# Collector goroutine: reads result from pipe with a per-subagent timeout.
# Sends a ResultMsg to resultchan when done (result or timeout error).
collectorwithTimeout(readfd: ref Sys->FD, resultchan: chan of ref ResultMsg, timeout_ms, idx: int)
{
	# Buffered capacity 1: goroutines can complete their send and exit even
	# after the alt has moved on, preventing them from blocking indefinitely.
	innerc := chan[1] of string;
	spawn pipereader(readfd, innerc);
	timeoutc := chan[1] of int;
	spawn timer(timeoutc, timeout_ms);
	result: string;
	alt {
	result = <-innerc =>
		;
	<-timeoutc =>
		result = sys->sprint("ERROR:subagent timed out after %ds", timeout_ms / 1000);
		# Close the read end so pipereader's sys->read() returns an error,
		# allowing it to break its loop, send to innerc (buffered), and exit.
		readfd = nil;
	}
	resultchan <-= ref ResultMsg(idx, result);
}

# Run one child agent with FORKNS + bind-replace namespace isolation.
# samod is a dedicated SubAgent instance — not shared with any other child.
#
# Scheduling caps (INFR-14):
#   at_ms > 0    -> sleep that many ms once, then run a single iteration
#   every_ms > 0 -> loop {sleep that many ms; run iteration} until killed
#   both 0       -> single iteration immediately (existing behaviour)
# When scheduled, pipefd is nil: parent has already reported "scheduled"
# and is not waiting. Cancellation: echo kill > /prog/$pid/ctl.
runchild(pipefd: ref Sys->FD, logfd: ref Sys->FD,
         caps: ref NsConstruct->Capabilities, task: string,
         samod: SubAgent, at_ms: int, every_ms: int)
{
	# Step 1: Fresh process group (empty service registry)
	sys->pctl(Sys->NEWPGRP, nil);

	# Step 2: Fork namespace (inherits already-restricted parent namespace)
	sys->pctl(Sys->FORKNS, nil);

	# Step 3: Empty environment (no inherited secrets)
	sys->pctl(Sys->NEWENV, nil);

	# Step 4: Create LLM session using /mnt/llm/new clone pattern.
	# Each child gets its own session — fully isolated from parent and siblings.
	llmaskfd: ref Sys->FD;
	sessionid := "";  # hoisted so we can close the session after runloop
	if(caps.llmconfig != nil) {
		newfd := sys->open("/mnt/llm/new", Sys->OREAD);
		if(newfd != nil) {
			buf := array[32] of byte;
			n := sys->read(newfd, buf, len buf);
			newfd = nil;
			if(n > 0) {
				sessionid = string buf[0:n];
				if(len sessionid > 0 && sessionid[len sessionid - 1] == '\n')
					sessionid = sessionid[0:len sessionid - 1];
				if(sessionid != "") {
					# Configure model — only if one was specified. An empty model
					# leaves the session at the llmsrv default (what the backend
					# actually serves), avoiding a 404 on backends that don't have
					# the legacy "haiku" default.
					if(caps.llmconfig.model != "") {
						modelfd := sys->open("/mnt/llm/" + sessionid + "/model", Sys->OWRITE);
						if(modelfd != nil) {
							modeldata := array of byte caps.llmconfig.model;
							sys->write(modelfd, modeldata, len modeldata);
							modelfd = nil;
						}
					}

					# Thinking: honor an explicit budget; leave the DEFAULT (0) at
					# the backend default rather than forcing "off". Forcing off
					# makes a reasoning backend (e.g. gpt-oss/harmony) emit an empty
					# final channel — the child then returns nothing. The parent
					# agent's session never disables thinking, and works; match that.
					tval := "";
					if(caps.llmconfig.thinking < 0)
						tval = "on";
					else if(caps.llmconfig.thinking > 0)
						tval = string caps.llmconfig.thinking;
					if(tval != "") {
						thinkfd := sys->open("/mnt/llm/" + sessionid + "/thinking", Sys->OWRITE);
						if(thinkfd != nil) {
							tdata := array of byte tval;
							sys->write(thinkfd, tdata, len tdata);
							thinkfd = nil;
						}
					}

					# Configure system prompt
					if(caps.llmconfig.system != "") {
						sysfd := sys->open("/mnt/llm/" + sessionid + "/system", Sys->OWRITE);
						if(sysfd != nil) {
							sysdata := array of byte caps.llmconfig.system;
							sys->write(sysfd, sysdata, len sysdata);
							sysfd = nil;
						}
					}

					# Open ask fd (used by runloop)
					llmaskfd = sys->open("/mnt/llm/" + sessionid + "/ask", Sys->ORDWR);
				}
			}
		}
	}

	# Step 5: Apply namespace restrictions (FORKNS + bind-replace)
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		writeresult(pipefd, "ERROR:namespace restriction failed: " + err);
		return;
	}

	# Step 5b: Bridge MCP tools into the child (INFR-247). restrictns has just
	# attenuated /mnt/mcp to ONLY the servers granted via caps.paths, so
	# discovering here scopes the child to exactly what it is allowed to reach.
	# Register their tool-defs on the child's fresh session (so the model emits
	# native tool calls for them) and hand the routing maps to the sub-agent.
	# Bounded by the same per-mount/byte caps NERVA uses. Best-effort: any failure
	# just leaves the child without MCP tools, never breaks the run.
	if(agentlib != nil && sessionid != "") {
		mcppaths := filtermcp(caps.paths);
		if(mcppaths != nil) {
			(mcpmounts, mcptools) := agentlib->mcpdiscover(mcppaths);
			if(mcpmounts != nil) {
				defs := agentlib->mcptooldefs(mcpmounts, 64, 60000);
				tfd := sys->open("/mnt/llm/" + sessionid + "/tools", Sys->OWRITE);
				if(tfd != nil) {
					db := array of byte defs;
					sys->write(tfd, db, len db);
					tfd = nil;
				}
				samod->setmcp(mcpmounts, mcptools);
			}
		}
	}

	# Step 6: Verify FDs 0-2 are safe endpoints
	verifysafefds();

	# Step 7: Prune FDs — keep stdin, stdout, stderr; pipe (if present);
	# the LLM ask fd; and the trajectory log fd (if present). pipefd and
	# logfd may both be nil (logfd: log creation failed; pipefd:
	# fire-and-forget scheduled run).
	keepfds := 0 :: 1 :: 2 :: nil;
	if(pipefd != nil)
		keepfds = pipefd.fd :: keepfds;
	if(llmaskfd != nil)
		keepfds = llmaskfd.fd :: keepfds;
	if(logfd != nil)
		keepfds = logfd.fd :: keepfds;
	sys->pctl(Sys->NEWFD, keepfds);

	# Step 8: Block device naming (after all bind operations)
	sys->pctl(Sys->NODEVS, nil);

	# Step 9: Build tool list for this child (filter preloadedtools to this spec)
	toolmods: list of Tool;
	toolnames: list of string;
	for(pt := preloadedtools; pt != nil; pt = tl pt) {
		if(inlist((hd pt).name, caps.tools)) {
			toolmods = (hd pt).mod :: toolmods;
			toolnames = (hd pt).name :: toolnames;
		}
	}

	systemprompt := "";
	if(caps.llmconfig != nil)
		systemprompt = caps.llmconfig.system;

	# at= scheduling: sleep once before the (single) iteration. Caps are
	# already attenuated above — the sleeping process holds the same
	# restricted namespace it will run in. Cancellation works as expected
	# (echo kill > /prog/$pid/ctl) because we are a real Limbo process.
	if(at_ms > 0)
		sys->sleep(at_ms);

	# every= scheduling: loop forever. Each iteration reuses the LLM
	# session opened in Step 4, so conversation history accumulates across
	# runs (the SubAgent is essentially having one long conversation,
	# punctuated by sleeps). For tasks where this matters, opening a
	# fresh session per iteration is a follow-up; for "list new emails
	# every hour"-style polling against tools that read a freshly-mounted
	# 9P fs, history reuse is fine.
	if(every_ms > 0) {
		for(;;) {
			sys->sleep(every_ms);
			samod->runloop(task, toolmods, toolnames, systemprompt, llmaskfd, logfd, 50);
		}
		# unreachable
	}

	# Run the agent loop using the dedicated (non-shared) SubAgent instance
	result := samod->runloop(task, toolmods, toolnames, systemprompt, llmaskfd, logfd, 50);

	writeresult(pipefd, result);
	pipefd = nil;

	# Release the LLM session. The ctl "close" decrements the self-reference
	# (refs 1→0), allowing the server to free the session immediately rather
	# than waiting for a server restart.
	if(sessionid != "") {
		ctlfd := sys->open("/mnt/llm/" + sessionid + "/ctl", Sys->OWRITE);
		if(ctlfd != nil) {
			data := array of byte "close";
			sys->write(ctlfd, data, len data);
			ctlfd = nil;
		}
	}
}

# ---- Helper functions ----

# Verify FDs 0-2 are safe; redirect to /dev/null if missing.
verifysafefds()
{
	if(sys->fildes(0) == nil) {
		null := sys->open("/dev/null", Sys->OREAD);
		if(null != nil)
			sys->dup(null.fd, 0);
	}
	if(sys->fildes(1) == nil) {
		null := sys->open("/dev/null", Sys->OWRITE);
		if(null != nil)
			sys->dup(null.fd, 1);
	}
	if(sys->fildes(2) == nil) {
		null := sys->open("/dev/null", Sys->OWRITE);
		if(null != nil)
			sys->dup(null.fd, 2);
	}
}

# Write result string to pipe followed by the sentinel marker.
writeresult(fd: ref Sys->FD, result: string)
{
	# fd is nil for fire-and-forget scheduled children (at=/every= caps).
	# Discard quietly; the parent has already reported "scheduled" to the
	# user and is no longer waiting on a result.
	if(fd == nil)
		return;
	data := array of byte (result + RESULT_END);
	sys->write(fd, data, len data);
}

# Read from pipe until sentinel or EOF; send complete result to resultch.
pipereader(fd: ref Sys->FD, resultch: chan of string)
{
	result := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		result += string buf[0:n];
		if(len result >= len RESULT_END) {
			endpos := len result - len RESULT_END;
			if(result[endpos:] == RESULT_END) {
				result = result[0:endpos];
				break;
			}
		}
	}
	resultch <-= result;
}

# Timer goroutine: send on ch after ms milliseconds.
timer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

# Load agent prompt from /lib/veltro/agents/<type>.txt.
loadagentprompt(agenttype: string): string
{
	# Reject path traversal attempts
	for(i := 0; i < len agenttype; i++)
		if(agenttype[i] == '/' || agenttype[i] == '\\')
			return "";
	if(agenttype == ".." || agenttype == ".")
		return "";
	fd := sys->open("/lib/veltro/agents/" + agenttype + ".txt", Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

# Split args string on all occurrences of sep; return ordered list of parts.
splitonall(s, sep: string): list of string
{
	parts: list of string;
	for(;;) {
		(before, after) := spliton(s, sep);
		parts = before :: parts;
		if(after == "")
			break;
		s = after;
	}
	return reverse(parts);
}

# Split s on the first occurrence of sep.
# Returns (before, after) where after excludes sep.
# Returns (s, "") if sep not found.
spliton(s, sep: string): (string, string)
{
	for(i := 0; i <= len s - len sep; i++) {
		if(s[i:i+len sep] == sep)
			return (s[0:i], s[i+len sep:]);
	}
	return (s, "");
}

# Strip leading and trailing whitespace.
strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}

# Return 1 if s has the given prefix, 0 otherwise.
hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

# Return 1 if needle is in the list, 0 otherwise.
inlist(needle: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == needle)
			return 1;
	return 0;
}

# Remove a single item from a string list.
dropitem(item: string, l: list of string): list of string
{
	result: list of string;
	for(; l != nil; l = tl l)
		if(hd l != item)
			result = hd l :: result;
	return reverse(result);
}

# Select the granted MCP server mounts from a path list — entries under
# /mnt/mcp/ (INFR-247). These are the per-server subtrees nsconstruct kept for
# the child; each is a mount agentlib->mcpdiscover can probe.
filtermcp(l: list of string): list of string
{
	result: list of string;
	for(; l != nil; l = tl l) {
		p := hd l;
		if(len p > 9 && p[0:9] == "/mnt/mcp/")
			result = p :: result;
	}
	return reverse(result);
}

# Reverse a list of strings.
reverse(l: list of string): list of string
{
	result: list of string;
	for(; l != nil; l = tl l)
		result = hd l :: result;
	return result;
}

# Reverse a list of SubSpecs.
reversespecs(l: list of ref SubSpec): list of ref SubSpec
{
	result: list of ref SubSpec;
	for(; l != nil; l = tl l)
		result = hd l :: result;
	return result;
}

# Reverse a list of SubAgentSlots.
reversesamods(l: list of ref SubAgentSlot): list of ref SubAgentSlot
{
	result: list of ref SubAgentSlot;
	for(; l != nil; l = tl l)
		result = hd l :: result;
	return result;
}

# Count the length of a list of strings.
listlen(l: list of string): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

# Return first N characters of task, truncated with "..." if longer.
tasksummary(task: string): string
{
	if(len task <= 50)
		return task;
	return task[0:47] + "...";
}

# --- Activity / background task helpers ---

# Get the current activity ID from luciuisrv.
currentactid(): int
{
	s := readfile(UI_MOUNT + "/activity/current");
	if(s == nil)
		return -1;
	s = strip(s);
	(n, nil) := str->toint(s, 10);
	return n;
}

# Count existing background tasks for an activity.
countbgtasks(actid: int): int
{
	base := sys->sprint("%s/activity/%d/context/background", UI_MOUNT, actid);
	for(i := 0; ; i++) {
		s := readfile(sys->sprint("%s/%d", base, i));
		if(s == nil)
			return i;
	}
	return 0;  # unreachable
}

# Add a background task to the activity.
bgadd(actid: int, label: string)
{
	ctxctl := sys->sprint("%s/activity/%d/context/ctl", UI_MOUNT, actid);
	cmd := "bg add label=" + label + " status=live";
	writefile(ctxctl, cmd);
}

# Update a background task's status.
bgupdatestatus(actid, idx: int, status: string)
{
	ctxctl := sys->sprint("%s/activity/%d/context/ctl", UI_MOUNT, actid);
	cmd := sys->sprint("bg update %d status=%s progress=100", idx, status);
	writefile(ctxctl, cmd);
}

# Remove a background task from the activity display.
bgremove(actid, idx: int)
{
	ctxctl := sys->sprint("%s/activity/%d/context/ctl", UI_MOUNT, actid);
	cmd := sys->sprint("bg remove %d", idx);
	writefile(ctxctl, cmd);
}

writefile(path, data: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("cannot open %s: %r", path);
	b := array of byte data;
	n := sys->write(fd, b, len b);
	if(n < 0)
		return sys->sprint("write to %s failed: %r", path);
	return nil;
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

# Strip surrounding single or double quotes from a string.
stripquotes(s: string): string
{
	if(len s < 2)
		return s;
	if((s[0] == '"' && s[len s - 1] == '"') ||
	   (s[0] == '\'' && s[len s - 1] == '\''))
		return s[1:len s - 1];
	return s;
}

# Open a per-subagent trajectory log fd. Best-effort: returns nil on any
# failure so logging never breaks the agent loop. Caller passes the fd
# into runchild before FORKNS; subagent.b writes step entries to it.
opensubagentlog(batchms, idx: int): ref Sys->FD
{
	ensuredir("/tmp/veltro");
	ensuredir(SUBAGENT_LOG_BASE);

	path := sys->sprint("%s/%d.%d.log", SUBAGENT_LOG_BASE, batchms, idx);
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		sys->fprint(sys->fildes(2), "spawn: subagent log %s not created: %r\n", path);
	return fd;
}

# Ensure a directory exists; no-op if already present.
ensuredir(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return;
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

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
#   0. (parent) open the child's model session and its files
#   1. pctl(NEWPGRP)   - Its own process group; the parent takes its ctl file
#   2. pctl(FORKNS)    - Fork parent's restricted namespace
#   3. pctl(NEWENV)    - Empty environment
#   5. restrictchildns() - Further bind-replace restrictions; no tool
#                        server, no model service
#   6. verifysafefds() - Verify FDs 0-2 are safe
#   7. pctl(NEWFD)     - Prune all other FDs
#   8. pctl(NODEVS)    - Block #U/#p/#c
#   9. samod->runloop() - Execute task using dedicated SubAgent instance
#
# A subagent's life is its parent's to end, and it is ended: when it has
# answered, at its timeout, or (one scheduled with at= or every=) when the
# tool server that started it has gone.  Ending it kills its process
# group and every group made below it, and closes its model session.
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
include "nsconstruct.m";
	nsconstruct: NsConstruct;
include "../subagent.m";
include "agentlib.m";
	agentlib: AgentLib;

include "audit.m";

include "auditprov.m";

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
# In the activity's scratch, the one part of the tool call's /tmp that is
# kept: /tmp/veltro itself is, for a tool call, a directory made for the
# call and removed after it, and a log made there went with it.
SUBAGENT_LOG_BASE:  con "/tmp/veltro/scratch/subagents";

# Where the provenance store is (auditventi), read where the tool server
# starts: a tool call's environment has only the session's name in it.
storeaddr := "";

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
	sa := readfile("/env/auditventi");
	if(sa != nil) {
		while(len sa > 0 && (sa[len sa - 1] == '\n' || sa[len sa - 1] == 0))
			sa = sa[0:len sa - 1];
		storeaddr = sa;
	}
	schedlock = chan[1] of int;
	inited = 1;
	return nil;
}

# ---- Provenance (INFR-355) ----

# Seal one parent-side provenance record, with the call's own emitter.
# Optional auditing may degrade to content=unstored; required auditing
# treats either store or sink failure as fatal: -1.
provemit(prov: AuditProv, required: int, event, msg: string, payload: array of byte): int
{
	if(prov == nil)
		return -required;
	if(prov->log("veltro", event, msg, payload) != 0 && required)
		return -1;
	return 0;
}

# Serialize what a child was granted, for the subcaps record payload.
capsmanifest(caps: ref NsConstruct->Capabilities, at_ms, every_ms, timeout_ms: int): string
{
	s := "tools=" + joinlist(caps.tools) + "\n";
	s += "paths=" + joinlist(caps.paths) + "\n";
	s += "shellcmds=" + joinlist(caps.shellcmds) + "\n";
	if(caps.llmconfig != nil) {
		s += "model=" + caps.llmconfig.model + "\n";
		s += sys->sprint("thinking=%d\n", caps.llmconfig.thinking);
	}
	s += sys->sprint("at_ms=%d every_ms=%d timeout_ms=%d\n", at_ms, every_ms, timeout_ms);
	return s;
}

joinlist(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l) {
		if(s != "")
			s += ",";
		s += hd l;
	}
	return s;
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
		"  timeout=N     Seconds before each subagent is stopped (default: 300)\n\n" +
		"Per-subagent options (in each -- section, before ::):\n" +
		"  tools=        Comma-separated tools to grant (REQUIRED)\n" +
		"  paths=        Comma-separated paths to expose\n" +
		"  shellcmds=    Comma-separated shell commands to allow\n" +
		"  temperature=  LLM temperature 0.0-2.0 (default: 0.7)\n" +
		"  thinking=     Thinking budget: off, max, or token count\n" +
		"  agenttype=    Load prompt from /lib/veltro/agents/<type>.txt\n" +
		"  system=       System prompt string (overrides agenttype)\n" +
		"  at=           Sleep until RFC3339 instant (e.g. 2026-05-10T09:00:00Z)\n" +
		"                then run a single iteration (returns 'scheduled' immediately)\n" +
		"  every=        Sleep <int><s|m|h|d> between iterations, looping until\n" +
		"                the agent's tool server ends or its group is killed\n" +
		"                (the result names it); at most " + string MAXSCHED + " scheduled at once\n\n" +
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
		"  A path is granted only inside one this agent holds (/tool/paths).\n" +
		"  sms, dial and task are not given to a subagent: what they do needs\n" +
		"  the user's approval, which only this agent's own call asks for.\n" +
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

# One subagent of a call, as its parent holds it.
Child: adt {
	idx:	int;
	pid:	int;			# its process group's leader
	kfd:	ref Sys->FD;		# /prog/pid/ctl: killtree ends it and all it started
	sess:	string;			# its model session, closed with it
	rfd:	ref Sys->FD;		# its result; end of file when it has gone
	marker:	string;			# scheduled: what names it in the Activity panel
};

# Subagents scheduled (at=, every=) by this tool server and still there.
MAXSCHED: con 8;
nsched := 0;
schedlock: chan of int;

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
	# Everything that can refuse the call is asked before any subagent is
	# started: a later section's refusal used to come after the earlier
	# sections' subagents were running, and they were left.
	nameerr := validatespecs(specs);
	if(nameerr != "")
		return "error: " + nameerr;

	# Count specs
	N := 0;
	nsch := 0;
	{
		cntlist := specs;
		for(; cntlist != nil; cntlist = tl cntlist) {
			N++;
			if((hd cntlist).at_ms > 0 || (hd cntlist).every_ms > 0)
				nsch++;
		}
	}

	# Provenance (INFR-355).  Whether the install requires auditing is
	# the tool server's word (it can see the switch; this name space has
	# no /usr), and the sink is the append file the server bound here.
	# Required, with no sink or no content store, nothing is started.
	(provrequired, swerr) := auditswitch();
	if(swerr != nil)
		return "error: " + swerr;
	auditing := sys->stat(Audit->LOGFILE).t0 >= 0;
	if(provrequired && !auditing)
		return "error: auditing is required but /mnt/audit/log is unavailable";
	prov: AuditProv;
	if(auditing) {
		# An emitter of this call's own: its connection to the store is
		# a descriptor of this call.
		prov = load AuditProv AuditProv->PATH;
		if(prov != nil && prov->init() != nil)
			prov = nil;
		aerr := "cannot load the provenance module";
		if(prov != nil)
			aerr = prov->attach(storeaddr);
		if(aerr != nil && provrequired)
			return "error: auditing is required but the provenance store cannot be reached: " + aerr;
	}

	if(nsch > 0) {
		# A scheduled subagent ends with the tool server that started
		# it; with none to watch, nothing would ever end it.
		if(sys->stat("/tool/activity").t0 < 0)
			return "error: at= and every= need the agent's tool server, which a scheduled subagent ends with";
		schedlock <-= 1;
		if(nsched + nsch > MAXSCHED) {
			n := nsched;
			<-schedlock;
			return sys->sprint("error: too many scheduled subagents: %d are running and at most %d may", n, MAXSCHED);
		}
		nsched += nsch;
		<-schedlock;
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
			saerr: string;
			if(sa == nil)
				saerr = sys->sprint("cannot load subagent: %r");
			else if((saerr = sa->init()) != nil)
				saerr = "cannot init subagent: " + saerr;
			if(saerr != nil) {
				unsched(nsch);
				return "error: " + saerr;
			}
			samods = ref SubAgentSlot(sa) :: samods;
		}
	}
	samods = reversesamods(samods);

	# Pre-load tool modules (union of all specs' tool sets), BEFORE namespace
	# restriction.  Tools are stateless after init() — sharing is safe.
	# The list is this call's: kept in the module, a second call emptied
	# it under the first call's children.
	(tools, toolerr) := preloadmulti(specs);
	if(toolerr != "") {
		unsched(nsch);
		return "error: " + toolerr;
	}

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
	scheduled := array[N] of {* => 0};
	started: list of ref Child;
	fatal := "";
	while(speclist != nil && fatal == "") {
		spec := hd speclist;
		slot := hd salist;
		speclist = tl speclist;
		salist = tl salist;
		sched := spec.at_ms > 0 || spec.every_ms > 0;
		scheduled[idx] = sched;

		# Filter out memory tool — parent agent owns memory exclusively.
		# Subagents return results via pipe; parent persists what matters.
		childtools := dropitem("memory", spec.tools);

		# Provenance (INFR-355): when this install audits, every child gets
		# the append-only audit sink bound into its namespace. Install
		# policy, not a model-granted capability: /mnt/audit/log is a
		# write-only sink (auditcontrolpath keeps chain/ctl/root
		# ungrantable), not an inspection surface.
		childpaths := spec.paths;
		if(auditing)
			childpaths = Audit->LOGFILE :: childpaths;

		caps := ref NsConstruct->Capabilities(
			childtools,
			childpaths,
			spec.shellcmds,
			spec.llmconfig,
			0 :: 1 :: 2 :: nil,
			nil,
			0,    # No memory
			0,    # No xenith
			-1,   # No cowfs — subagents inherit parent's cowfs via FORKNS
			nil
		, nil);

		# Open the trajectory log fd in the parent namespace, before
		# spawning. Survives FORKNS + bind-replace via the same fd-keep
		# pattern as llmaskfd. nil-on-failure: logging is best-effort —
		# a missing log must never break the agent loop.
		logfd := opensubagentlog(batchms, idx);

		# Provenance (INFR-355): name the child, seal what it was asked
		# and what it was granted, and dial it a content-store
		# connection to carry into the restricted namespace.  Required
		# and not sealed, the call stops here.
		childid := "";
		provfd: ref Sys->FD;
		if(auditing) {
			childid = sys->sprint("sub-%d-%d", batchms, idx);
			if(provemit(prov, provrequired, "spawn", "child=" + childid, array of byte spec.task) < 0 ||
			   provemit(prov, provrequired, "subcaps", "child=" + childid,
				array of byte capsmanifest(caps, spec.at_ms, spec.every_ms, timeout_ms)) < 0) {
				fatal = "auditing is required and the subagent's record could not be written";
				break;
			}
			if(prov != nil)
				(provfd, nil) = prov->dialraw(storeaddr);
			if(provfd == nil && provrequired) {
				fatal = "auditing is required but the provenance store cannot be reached";
				break;
			}
		}

		# What the child's restriction would refuse of its grants is
		# refused before a session is opened for it, in the words the
		# child would have used.
		capserr := nsconstruct->checkchildcaps(caps);
		if(capserr != nil) {
			resultchan <-= ref ResultMsg(idx, "ERROR:namespace restriction failed: " + capserr);
			if(sched)
				unsched(1);
			scheduled[idx] = 0;
			idx++;
			continue;
		}

		# The child's model session, opened here: its parent closes it
		# when the child ends, however it ends.  (The child opened it,
		# and closed it by a name its own name space no longer had:
		# every child left one behind.)
		(sess, askfd, toolsfd, serr) := newsession(caps.llmconfig);
		if(serr != nil) {
			resultchan <-= ref ResultMsg(idx, "ERROR:" + serr);
			if(sched)
				unsched(1);
			scheduled[idx] = 0;
			idx++;
			continue;
		}

		pipefds := array[2] of ref Sys->FD;
		if(sys->pipe(pipefds) < 0) {
			closesession(sess);
			resultchan <-= ref ResultMsg(idx, "ERROR:cannot create pipe");
			if(sched)
				unsched(1);
			scheduled[idx] = 0;
			idx++;
			continue;
		}

		# The child says who it is, and waits to be told to go on: it is
		# started only once this proc holds the file that ends it.
		pidc := chan of int;
		goc := chan of int;
		spawn runchild(pidc, goc, pipefds[1], logfd, caps, spec.task, slot.mod, childid, provfd,
			provrequired, spec.at_ms, spec.every_ms, askfd, toolsfd, tools);
		pipefds[1] = nil;
		askfd = nil;
		toolsfd = nil;
		cpid := <-pidc;
		kfd: ref Sys->FD;
		if(cpid > 0)
			kfd = sys->open(sys->sprint("/prog/%d/ctl", cpid), Sys->OWRITE);
		if(kfd == nil) {
			why := sys->sprint("%r");
			if(cpid > 0)
				goc <-= 0;
			closesession(sess);
			resultchan <-= ref ResultMsg(idx, "ERROR:cannot supervise a subagent here (" + why + "): not started");
			if(sched)
				unsched(1);
			scheduled[idx] = 0;
			idx++;
			continue;
		}
		child := ref Child(idx, cpid, kfd, sess, pipefds[0], "");
		started = child :: started;
		goc <-= 1;

		# Scheduled (at= or every=): the call does not wait for it.  A
		# keeper proc of this call does: it ends the subagent when its
		# work is done or the tool server has gone, and until then keeps
		# the call's process group, and so the name space the subagent
		# runs in, from being reclaimed.
		if(sched) {
			child.marker = sys->sprint("(pid %d)", cpid);
			schedmsg: string;
			if(spec.at_ms > 0)
				schedmsg = sys->sprint("scheduled: single run in %d ms", spec.at_ms);
			else
				schedmsg = sys->sprint("scheduled: every %d ms", spec.every_ms);
			schedmsg += sys->sprint(", as process group %d; it ends with this agent's tool server, or when its group is killed (echo killtree > /prog/%d/ctl)", cpid, cpid);
			if(actid >= 0 && bgbase >= 0)
				bgrelabel(actid, bgbase + idx, tasksummary(spec.task) + " " + child.marker);
			spawn schedkeeper(child, actid);
			resultchan <-= ref ResultMsg(idx, schedmsg);
			idx++;
			continue;
		}

		spawn collector(child, resultchan, timeout_ms);
		idx++;
	}
	if(fatal != "") {
		# nothing of a refused call is left running
		for(; started != nil; started = tl started)
			stopchild(hd started);
		unsched(nsch);
		if(actid >= 0 && bgbase >= 0)
			for(ri := N - 1; ri >= 0; ri--)
				bgremove(actid, bgbase + ri);
		return "error: " + fatal;
	}

	# Collect all results (order via idx field, not arrival order)
	results := array[N] of string;
	for(i := 0; i < N; i++) {
		msg := <-resultchan;
		results[msg.idx] = msg.result;
		# Update background task status as each result arrives; a
		# scheduled subagent's stays live while it does.
		if(actid >= 0 && bgbase >= 0 && !scheduled[msg.idx]) {
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
			if(!scheduled[ri])
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

unsched(n: int)
{
	if(n <= 0)
		return;
	schedlock <-= 1;
	nsched -= n;
	if(nsched < 0)
		nsched = 0;
	<-schedlock;
}

# Whether this install requires auditing.  The tool server says
# (/tool/meta/audit): it sees the install's switch, which a tool call's
# name space does not.  With no tool server the switch is looked for; and
# where neither can be seen it is taken as required: a subagent that may
# not run unrecorded is not started on a guess.
auditswitch(): (int, string)
{
	s := readfile("/tool/meta/audit");
	if(s != nil)
		return (strip(s) == "required", nil);
	if(sys->stat(Audit->ONFILE).t0 >= 0)
		return (1, nil);
	if(sys->stat("/usr").t0 >= 0)
		return (0, nil);
	if(sys->stat(Audit->LOGFILE).t0 >= 0)
		return (1, nil);
	return (0, nil);
}

# Open a model session for a child: its id, its ask file and its tools
# file.  The model, when one is named, thinking and the system prompt are
# set as before.
newsession(cfg: ref NsConstruct->LLMConfig): (string, ref Sys->FD, ref Sys->FD, string)
{
	newfd := sys->open("/mnt/llm/new", Sys->OREAD);
	if(newfd == nil)
		return (nil, nil, nil, sys->sprint("cannot open a model session: %r"));
	buf := array[64] of byte;
	n := sys->read(newfd, buf, len buf);
	newfd = nil;
	if(n <= 0)
		return (nil, nil, nil, sys->sprint("cannot open a model session: %r"));
	sess := strip(string buf[0:n]);
	# the id is a name in /mnt/llm
	if(sess == "" || !validcapname(sess))
		return (nil, nil, nil, "cannot open a model session: the service gave no session");
	dir := "/mnt/llm/" + sess;
	if(cfg != nil) {
		# Configure model — only if one was specified. An empty model
		# leaves the session at the llmsrv default (what the backend
		# actually serves), avoiding a 404 on backends that don't have
		# the legacy "haiku" default.
		if(cfg.model != "")
			writefile(dir + "/model", cfg.model);
		# Thinking: honor an explicit budget; leave the DEFAULT (0) at
		# the backend default rather than forcing "off". Forcing off
		# makes a reasoning backend (e.g. gpt-oss/harmony) emit an empty
		# final channel — the child then returns nothing. The parent
		# agent's session never disables thinking, and works; match that.
		if(cfg.thinking < 0)
			writefile(dir + "/thinking", "on");
		else if(cfg.thinking > 0)
			writefile(dir + "/thinking", string cfg.thinking);
		if(cfg.system != "")
			writefile(dir + "/system", cfg.system);
	}
	askfd := sys->open(dir + "/ask", Sys->ORDWR);
	if(askfd == nil) {
		e := sys->sprint("cannot open a model session: %r");
		closesession(sess);
		return (nil, nil, nil, e);
	}
	# the tool definitions', written once the child's tools are known:
	# after the restriction there is no /mnt/llm to open
	toolsfd := sys->open(dir + "/tools", Sys->OWRITE);
	return (sess, askfd, toolsfd, nil);
}

# Release a model session. The ctl "close" decrements the self-reference
# (refs 1→0), allowing the server to free the session immediately rather
# than waiting for a server restart.
closesession(sess: string)
{
	if(sess != "")
		writefile("/mnt/llm/" + sess + "/ctl", "close");
}

# End a subagent: its whole process group tree (all it started, and what
# those started), then its model session.  Once only.
stopchild(c: ref Child)
{
	if(c.kfd != nil) {
		b := array of byte "killtree";
		sys->write(c.kfd, b, len b);
		c.kfd = nil;
	}
	if(c.sess != "") {
		closesession(c.sess);
		c.sess = "";
	}
}

killproc(pid: int)
{
	if(pid > 0)
		writefile(sys->sprint("/prog/%d/ctl", pid), "kill");
}

# Write a child's tool definitions to its model session: the schema each
# tool publishes (a single "args" string for one that publishes none),
# then the MCP tools' (a JSON array, or "").
installchildtools(tfd: ref Sys->FD, mods: list of Tool, names: list of string, mcpdefs: string)
{
	parts := "";
	for(; mods != nil && names != nil; (mods, names) = (tl mods, tl names)) {
		entry := (hd mods)->schema();
		entry = strip(entry);
		if(len entry < 2 || entry[0] != '{' || entry[len entry - 1] != '}')
			entry = "{\"name\":\"" + hd names + "\",\"description\":\"The " + hd names +
				" tool\",\"parameters\":{\"type\":\"object\",\"properties\":{\"args\":" +
				"{\"type\":\"string\"}},\"required\":[\"args\"]}}";
		if(parts != "")
			parts += ",";
		parts += entry;
	}
	m := strip(mcpdefs);
	if(len m > 2 && m[0] == '[' && m[len m - 1] == ']') {
		if(parts != "")
			parts += ",";
		parts += m[1:len m - 1];
	}
	if(parts == "")
		return;
	b := array of byte ("[" + parts + "]");
	sys->write(tfd, b, len b);
}

# Pre-load tool modules for the union of all specs' tool sets.
# Returns "" on success, error string on failure.
preloadmulti(specs: list of ref SubSpec): (list of ref PreloadedTool, string)
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

	preloadedtools: list of ref PreloadedTool;
	for(s := seen; s != nil; s = tl s) {
		nm := hd s;
		path := "/dis/veltro/tools/" + nm + ".dis";
		mod := load Tool path;
		if(mod == nil) {
			# Only the delegation budget's tools are in this namespace
			# to load: "file does not exist" said nothing of why.
			(ok, nil) := sys->stat(path);
			if(ok < 0)
				return (nil, sys->sprint("tool %s may not be given to a child: it is not in the delegation budget (see GRANTABLE TO CHILD TASKS)", nm));
			return (nil, sys->sprint("cannot load tool %s: %r", nm));
		}
		merr := mod->init();
		if(merr != nil)
			return (nil, sys->sprint("cannot init tool %s: %s", nm, merr));
		preloadedtools = ref PreloadedTool(nm, mod) :: preloadedtools;
	}

	return (preloadedtools, "");
}

validatespecs(specs: list of ref SubSpec): string
{
	(held, known) := heldpaths();
	for(; specs != nil; specs = tl specs) {
		spec := hd specs;
		for(t := spec.tools; t != nil; t = tl t) {
			if(!validcapname(hd t))
				return "invalid tool name: " + hd t;
			# A subagent's tool calls are not seen by the
			# coordinator, which asks the user before a call of
			# these runs: a subagent is not given them, whatever
			# the delegation budget holds.
			if(nsconstruct->gatedtool(hd t))
				return sys->sprint("tool %s may not be given to a subagent: what it does needs the user's approval, which only the agent's own call of it asks for", hd t);
		}
		for(c := spec.shellcmds; c != nil; c = tl c)
			if(!validcapname(hd c))
				return "invalid shell command name: " + hd c;
		if(spec.paths != nil && (inlist("exec", spec.tools) || spec.shellcmds != nil))
			return "exec/shell subagents cannot receive path grants; use read/list/find/grep for read-only inspection or write/edit with explicit staged write grants";
		for(p := spec.paths; p != nil; p = tl p) {
			e := childpatherr(hd p, held, known);
			if(e != nil)
				return e;
		}
	}
	return "";
}

# The agent's own path grants, as its tool server lists them
# (/tool/paths, "path perm" a line), and whether there is a list.
heldpaths(): (list of string, int)
{
	s := readfile("/tool/paths");
	if(s == nil)
		return (nil, 0);
	held: list of string;
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines) {
		(nil, f) := sys->tokenize(hd lines, " \t");
		if(f != nil)
			held = hd f :: held;
	}
	return (held, 1);
}

# A path a subagent asks for is the model's request.  It is granted only
# inside what the agent itself was granted to read: the tool call this
# runs in also holds what the tools of the delegation budget need (the
# model service, for one), and the name space alone would have let a
# subagent be given those.  The agent's own services are refused
# whatever the grants say.
childpatherr(path: string, held: list of string, known: int): string
{
	lp := str->tolower(path);
	own := array[] of {"/mnt/llm", "/mnt/audit", "/mnt/ui", "/mnt/veltro", "/mnt/toolctl", "/tool"};
	for(i := 0; i < len own; i++)
		if(lp == own[i] || hasprefix(lp, own[i] + "/") || hasprefix(lp, own[i] + "."))
			return sys->sprint("path %s is one of the agent's own services: a subagent is not granted it", path);
	if(!known)
		return nil;	# no tool server to ask: the name space is the bound
	# what every subagent has without asking
	base := array[] of {"/lib/veltro", "/lib/certs", "/dis/veltro", "/tmp/veltro/scratch"};
	for(i = 0; i < len base; i++)
		if(pathwithin(base[i], path))
			return nil;
	for(; held != nil; held = tl held) {
		g := hd held;
		if(g == path || (pathwithin(g, path) && !nsconstruct->policyroot(g)))
			return nil;
	}
	return sys->sprint("path %s is outside this agent's grants (see /tool/paths): a subagent may be given only what the agent holds", path);
}

pathwithin(grant, want: string): int
{
	if(grant == want)
		return 1;
	return len want > len grant && want[0:len grant] == grant && want[len grant] == '/';
}

validcapname(n: string): int
{
	if(n == nil || n == "" || n == "." || n == "..")
		return 0;
	for(i := 0; i < len n; i++) {
		c := n[i];
		if((c >= 'a' && c <= 'z') ||
		   (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') ||
		   c == '_' || c == '-')
			continue;
		return 0;
	}
	return 1;
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

# A JValue that is an array of strings OR a comma-separated string -> stripped
# list, in lower case when lower is set (tool and command names; a path
# is taken as written: lowered, /usr/x/Proj named a file that is not
# there, and the grant was dropped without a word). nil if absent.
jvstrlist(v: ref JValue, lower: int): list of string
{
	r: list of string;
	if(v == nil)
		return nil;
	pick x := v {
	Array =>
		for(i := 0; i < len x.a; i++) {
			e := strip(jvstr(x.a[i]));
			if(e != "" && lower)
				e = str->tolower(e);
			if(e != "")
				r = e :: r;
		}
		return reverse(r);
	String =>
		(nil, toks) := sys->tokenize(x.s, ",");
		for(; toks != nil; toks = tl toks) {
			e := strip(hd toks);
			if(lower)
				e = str->tolower(e);
			r = e :: r;
		}
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

	spec.tools = jvstrlist(o.get("tools"), 1);
	if(spec.tools == nil)
		spec.tools = "plan" :: nil;   # a reasoning child still needs a grant; plan is safe
	spec.paths = jvstrlist(o.get("paths"), 0);
	spec.shellcmds = jvstrlist(o.get("shellcmds"), 1);

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

	# The model is the server's (llmsrv -M): a subagent never chooses one,
	# and a "model" in the args is ignored.
	llmmodel := "";
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
	if(tosecs > real (MAXMS / 1000))
		return (nil, 0, sys->sprint("timeout too long: at most %d seconds", MAXMS / 1000));
	if(tosecs >= 1.0)
		timeout_ms = (int tosecs) * 1000;

	# {"spec": "<dsl>"} — the schema's documented contract; reuse the DSL parser.
	specstr := strip(jvstr(jv.get("spec")));
	if(specstr != "")
		return parsespecs(specstr);

	# {"agents"|"tasks"|"subagents"|"spawns": [ ... ]}.
	arr := jv.get("agents");
	if(arr == nil)
		arr = jv.get("tasks");
	if(arr == nil)
		arr = jv.get("subagents");
	if(arr == nil)
		arr = jv.get("spawns");
	if(arr != nil)
		return buildfromarray(arr, timeout_ms);

	# A top-level task/prompt/etc. object is one subagent. Check this before the
	# key-agnostic array fallback below; otherwise a valid single-agent object
	# with tools=[...] or paths=[...] would be misread as an array of subagents.
	if(jfirststr(jv, "task" :: "prompt" :: "instruction" :: "description" :: "role" :: "goal" :: nil) != "") {
		(sp, e) := buildagent(jv);
		if(e != "")
			return (nil, 0, e);
		return (sp :: nil, timeout_ms, "");
	}

	# Key-agnostic fallback so any array key a model picks — "children",
	# "workers", ... — still resolves when the object is clearly a wrapper.
	arr = firstarrayvalue(jv);
	if(arr != nil)
		return buildfromarray(arr, timeout_ms);

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
				# in big: seconds times 1000 wrapped an int, and
				# timeout=3000000 was a timeout already past
				digits := tok[8:];
				for(di := 0; di < len digits; di++)
					if(digits[di] < '0' || digits[di] > '9')
						return (nil, 0, "timeout must be a number of seconds");
				if(len digits > 12 || big digits * big 1000 > big MAXMS)
					return (nil, 0, sys->sprint("timeout too long: at most %d seconds", MAXMS / 1000));
				if(int digits > 0)
					timeout_ms = int digits * 1000;
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
	spec.at_ms = 0;
	spec.every_ms = 0;

	llmmodel   := "";	# the server's; model= is ignored
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
			;	# the model is the server's
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
	# As the JSON form: no default.txt, whose text-protocol instructions
	# (the tool's name as the first word, DONE at the end) are wrong for a
	# child called with native tool definitions; the subagent's own
	# default applies.

	spec.llmconfig = ref NsConstruct->LLMConfig(llmmodel, llmtemp, llmsystem, llmthink);
	return (spec, "");
}

# The longest wait sys->sleep takes: 2^31-1 ms, some 24.8 days.
# Durations and at= times are refused beyond it, not wrapped.
MAXMS: con 16r7FFFFFFF;

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
	mult: big;
	case unit {
	's' => mult = big 1000;
	'm' => mult = big (60 * 1000);
	'h' => mult = big (3600 * 1000);
	'd' => mult = big (86400 * 1000);
	*   => return (0, "unknown unit (use s/m/h/d)");
	}
	# in big: an int of milliseconds holds no more than MAXMS
	if(len digits > 12)
		return (0, "duration too long: at most 24 days");
	ms := big digits * mult;
	if(ms > big MAXMS)
		return (0, "duration too long: at most 24 days");
	return (int ms, "");
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
	ms := (big target - big now) * big 1000;
	if(ms > big MAXMS)
		return (0, "target time is more than 24 days ahead");
	return (int ms, "");
}

# The most a subagent's result may be.  It is one reply of its model's,
# but the pipe is read until its end, whatever is written to it.
MAXRESULT: con 1024*1024;

# Collector goroutine: reads result from pipe with a per-subagent timeout.
# Sends a ResultMsg to resultchan when done (result or timeout error).
# Either way the subagent is then ended: its process group and all below
# it are killed and its model session closed.  A timeout used only to stop
# waiting: the subagent went on asking its model, and its parent, the
# model and the Activity panel had been told it was over.
collector(c: ref Child, resultchan: chan of ref ResultMsg, timeout_ms: int)
{
	# Buffered capacity 1: goroutines can complete their send and exit even
	# after the alt has moved on, preventing them from blocking indefinitely.
	innerc := chan[1] of (string, int);
	spawn pipereader(c.rfd, innerc);
	timeoutc := chan[1] of int;
	tpidc := chan[1] of int;
	spawn timer(timeoutc, tpidc, timeout_ms);
	tpid := <-tpidc;
	result: string;
	alt {
	(r, ended) := <-innerc =>
		result = r;
		# A subagent that goes without finishing its result (killed,
		# or broken) did not succeed: what it had written was returned
		# as its answer, an empty one included.
		if(!ended) {
			result = "ERROR:subagent ended without finishing its result";
			if(r != "")
				result += "; it had written:\n" + r;
		}
		killproc(tpid);
	<-timeoutc =>
		result = sys->sprint("ERROR:subagent timed out after %ds and was stopped", timeout_ms / 1000);
	}
	stopchild(c);
	c.rfd = nil;
	resultchan <-= ref ResultMsg(c.idx, result);
}

# A scheduled subagent's keeper.  It stays, a process of the call's own
# group, for as long as the subagent does, and ends it (as stopchild
# does) when its run is over, when it has gone, or when the tool server
# that started it has: asked every few seconds, since a server that is
# killed says nothing.  A scheduled subagent had no one: it outlived the
# call, the tool server and the session, asking its model for ever.
SCHEDPOLL: con 2000;

schedkeeper(c: ref Child, actid: int)
{
	donec := chan[1] of (string, int);
	spawn pipereader(c.rfd, donec);
	tickc := chan of int;
	tpidc := chan[1] of int;
	spawn ticker(tickc, tpidc, SCHEDPOLL);
	tpid := <-tpidc;
	# The server is asked in a proc of its own: one that has gone may
	# not answer at all (its end of the mount can be held open by
	# another), and a question three polls old is taken as no.
	probec := chan[2] of (int, int);
	probing := 0;
	late := 0;
	probepid := 0;
	status := "done";
Wait:
	for(;;) alt {
	(nil, ended) := <-donec =>
		if(!ended)
			status = "error";
		break Wait;
	(pid, ok) := <-probec =>
		if(pid != 0 && ok < 0) {
			# the proc says who it is, then what it found
			probepid = pid;
			continue;
		}
		probing = 0;
		late = 0;
		if(!ok) {
			status = "stopped";
			break Wait;
		}
	<-tickc =>
		if(!probing) {
			probing = 1;
			late = 0;
			spawn serverprobe(probec);
		} else if(++late >= 3) {
			status = "stopped";
			break Wait;
		}
	}
	stopchild(c);
	c.rfd = nil;
	killproc(tpid);
	if(probing)
		killproc(probepid);
	unsched(1);
	if(actid >= 0)
		bgfinish(actid, c.marker, status);
}

# Is the tool server there?  (pid, -1) first, then (0, yes).
serverprobe(c: chan of (int, int))
{
	c <-= (sys->pctl(0, nil), -1);
	c <-= (0, sys->stat("/tool/activity").t0 >= 0);
}

ticker(c: chan of int, pidc: chan of int, ms: int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;) {
		sys->sleep(ms);
		c <-= 1;
	}
}

# Wait to be ended.  A subagent's process does not go by itself: its
# parent ends it with everything it started, which it can do only while
# the group's leader is there to name.
park()
{
	<-chan of int;
}

# Run one child agent with FORKNS + bind-replace namespace isolation.
# samod is a dedicated SubAgent instance — not shared with any other child.
#
# Scheduling caps (INFR-14):
#   at_ms > 0    -> sleep that many ms once, then run a single iteration
#   every_ms > 0 -> loop {sleep that many ms; run iteration} until ended
#   both 0       -> single iteration immediately (existing behaviour)
runchild(pidc, goc: chan of int, pipefd: ref Sys->FD, logfd: ref Sys->FD,
         caps: ref NsConstruct->Capabilities, task: string,
         samod: SubAgent, childid: string, provfd: ref Sys->FD, provrequired: int,
         at_ms: int, every_ms: int, llmaskfd, llmtoolsfd: ref Sys->FD,
         tools: list of ref PreloadedTool)
{
	# Step 1: Fresh process group (empty service registry).  Its leader is
	# this process, by whose ctl file the parent ends the whole of it.
	if(sys->pctl(Sys->NEWPGRP, nil) < 0) {
		pidc <-= -1;
		return;
	}
	pidc <-= sys->pctl(0, nil);
	if(<-goc == 0)
		return;

	# Step 2: Fork namespace (inherits already-restricted parent namespace)
	if(sys->pctl(Sys->FORKNS, nil) < 0) {
		writeresult(pipefd, "ERROR:cannot fork namespace");
		park();
	}

	# Step 3: Empty environment (no inherited secrets)
	if(sys->pctl(Sys->NEWENV, nil) < 0) {
		writeresult(pipefd, "ERROR:cannot clear environment");
		park();
	}

	# Step 4: The LLM session is the parent's to open (newsession) and to
	# close; the child has its ask and tools files, open.

	# Step 5: Apply namespace restrictions (FORKNS + bind-replace): a
	# child's, which holds nothing of the parent's tool server or of the
	# model service, and under required auditing is refused if its
	# restriction cannot be recorded.
	err := nsconstruct->restrictchildns(caps, provrequired);
	if(err != nil) {
		writeresult(pipefd, "ERROR:namespace restriction failed: " + err);
		park();
	}

	# Step 5b: Bridge MCP tools into the child (INFR-247). restrictns has just
	# attenuated /mnt/mcp to ONLY the servers granted via caps.paths, so
	# discovering here scopes the child to exactly what it is allowed to reach.
	# Register their tool-defs on the child's fresh session (so the model emits
	# native tool calls for them) and hand the routing maps to the sub-agent.
	# Bounded by the same per-mount/byte caps the agent runtime uses. Best-effort: any failure
	# just leaves the child without MCP tools, never breaks the run.
	mcpdefs := "";	# installed with the native tools' (Step 9)
	if(agentlib != nil) {
		mcppaths := filtermcp(caps.paths);
		if(mcppaths != nil) {
			(mcpmounts, mcptools) := agentlib->mcpdiscover(mcppaths);
			if(mcpmounts != nil) {
				mcpdefs = agentlib->mcptooldefs(mcpmounts, 64, 60000);
				samod->setmcp(mcpmounts, mcptools);
			}
		}
	}

	# Step 5c: The child's tools, as its model is to call them: each
	# native tool's own schema, and the MCP tools granted.  Given only as
	# prose in its prompt, a child had nothing it could call, and answered
	# with what it would have done.
	toolmods: list of Tool;
	toolnames: list of string;
	for(pt := tools; pt != nil; pt = tl pt) {
		if(inlist((hd pt).name, caps.tools)) {
			toolmods = (hd pt).mod :: toolmods;
			toolnames = (hd pt).name :: toolnames;
		}
	}
	if(llmtoolsfd != nil) {
		installchildtools(llmtoolsfd, toolmods, toolnames, mcpdefs);
		llmtoolsfd = nil;
	}

	# Step 6: Verify FDs 0-2 are safe endpoints
	verifysafefds();

	# Step 7: Prune FDs — keep stdin, stdout, stderr; pipe (if present);
	# the LLM ask fd; and the trajectory log fd (if present).
	keepfds := 0 :: 1 :: 2 :: nil;
	if(pipefd != nil)
		keepfds = pipefd.fd :: keepfds;
	if(llmaskfd != nil)
		keepfds = llmaskfd.fd :: keepfds;
	if(logfd != nil)
		keepfds = logfd.fd :: keepfds;
	if(provfd != nil)
		keepfds = provfd.fd :: keepfds;
	if(sys->pctl(Sys->NEWFD, keepfds) < 0) {
		writeresult(pipefd, "ERROR:cannot restrict file descriptors");
		park();
	}

	# Step 8: Block device naming (after all bind operations)
	if(sys->pctl(Sys->NODEVS, nil) < 0) {
		writeresult(pipefd, "ERROR:cannot disable device attachment");
		park();
	}

	systemprompt := "";
	if(caps.llmconfig != nil)
		systemprompt = caps.llmconfig.system;

	# Arm provenance (INFR-355): the child completes the content-store
	# handshake and seals its own trajectory from inside the restricted
	# namespace (the audit sink is bound via the caps auto-grant above).
	if(childid != "")
		samod->setprov(childid, provfd, provrequired);

	# A record the child must write and cannot ends it (fail:audit, from
	# the subagent's loop): said, where the parent had read nothing and
	# taken the child for one that finished.
	result := "";
	{
		# at= scheduling: sleep once before the (single) iteration. Caps are
		# already attenuated above — the sleeping process holds the same
		# restricted namespace it will run in.
		if(at_ms > 0)
			sys->sleep(at_ms);

		# every= scheduling: loop until ended. Each iteration reuses the LLM
		# session, so conversation history accumulates across runs (the
		# SubAgent is essentially having one long conversation, punctuated
		# by sleeps).
		if(every_ms > 0)
			for(;;) {
				sys->sleep(every_ms);
				samod->runloop(task, toolmods, toolnames, systemprompt, llmaskfd, logfd, 50);
			}

		# Run the agent loop using the dedicated (non-shared) SubAgent instance
		result = samod->runloop(task, toolmods, toolnames, systemprompt, llmaskfd, logfd, 50);
	} exception e {
	"fail:audit" =>
		result = "ERROR:auditing is required and a record of the subagent's work could not be written: it was stopped";
	"*" =>
		result = "ERROR:subagent failed: " + e;
	}

	writeresult(pipefd, result);
	pipefd = nil;
	park();
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

# Read from pipe until sentinel or EOF; send what was read to resultch,
# and whether the sentinel ended it.
pipereader(fd: ref Sys->FD, resultch: chan of (string, int))
{
	result := "";
	ended := 0;
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
				ended = 1;
				break;
			}
		}
		if(len result > MAXRESULT) {
			result = result[0:MAXRESULT] + sys->sprint("\n... (result cut at %d characters)", MAXRESULT);
			ended = 1;
			break;
		}
	}
	resultch <-= (result, ended);
}

# Timer goroutine: says who it is, then sends on ch after ms milliseconds.
timer(ch: chan of int, pidc: chan of int, ms: int)
{
	pidc <-= sys->pctl(0, nil);
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

# Text written into luciuisrv ctl attributes must stay inert display text.
# The ctl parser treats any whitespace-delimited word ending in '=' as a new
# attribute, so collapse controls and replace '=' before embedding task text.
safeattrtext(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '=')
			out[len out] = ':';
		else if(c == '\n' || c == '\r' || c == '\t')
			out[len out] = ' ';
		else
			out[len out] = c;
	}
	return strip(out);
}

# --- Activity / background task helpers ---

# Get the current activity ID from luciuisrv.
currentactid(): int
{
	# the agent's own activity, as its tool server has it; with no
	# tool server, the one on show
	s := readfile("/tool/activity");
	if(s == nil)
		s = readfile(UI_MOUNT + "/activity/current");
	if(s == nil)
		return -1;
	s = strip(s);
	(n, nil) := str->toint(s, 10);
	# with no UI serving it there is nothing to register in
	if(sys->stat(sys->sprint("%s/activity/%d", UI_MOUNT, n)).t0 < 0)
		return -1;
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
	cmd := "bg add status=live label=" + safeattrtext(label);
	writefile(ctxctl, cmd);
}

# Update a background task's status.
bgupdatestatus(actid, idx: int, status: string)
{
	ctxctl := sys->sprint("%s/activity/%d/context/ctl", UI_MOUNT, actid);
	cmd := sys->sprint("bg update %d status=%s progress=100", idx, status);
	writefile(ctxctl, cmd);
}

# Name a background task for what it now is.
bgrelabel(actid, idx: int, label: string)
{
	ctxctl := sys->sprint("%s/activity/%d/context/ctl", UI_MOUNT, actid);
	writefile(ctxctl, sys->sprint("bg update %d label=%s", idx, safeattrtext(label)));
}

# A scheduled subagent's entry, found by its marker (entries are numbered
# by position, and others come and go while it runs): said to be over.
bgfinish(actid: int, marker, status: string)
{
	base := sys->sprint("%s/activity/%d/context/background", UI_MOUNT, actid);
	for(i := 0; i < 256; i++) {
		s := readfile(sys->sprint("%s/%d", base, i));
		if(s == nil)
			return;
		for(j := 0; j + len marker <= len s; j++)
			if(s[j:j+len marker] == marker) {
				bgupdatestatus(actid, i, status);
				return;
			}
	}
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

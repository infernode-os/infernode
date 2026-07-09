implement Veltro;

#
# veltro - Veltro Agent Loop
#
# A minimal agent where namespace IS the capability system.
#
# Design principles:
#   - Namespace = capability (constructed, not filtered)
#   - Agent operates freely within its world
#   - Everything visible is usable
#
# Usage:
#   veltro "task description"
#   veltro -v "task description"          # verbose mode
#   veltro -r last                        # resume most recent session
#   veltro -r <name>                      # resume named session
#   veltro -r <name> "extra instruction"  # resume + redirect
#
# Requires:
#   - /tool mounted (via tools9p)
#   - /mnt/llm mounted (LLM interface)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "string.m";
	str: String;

include "nsconstruct.m";
	nsconstruct: NsConstruct;

include "agentlib.m";
	agentlib: AgentLib;

Veltro: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# Large result: chars of preview to include inline before referring to scratch file
TRUNC_PREVIEW: con 2000;

# Task complexity threshold: tasks at or above this length trigger a planning turn
PLAN_TASK_THRESHOLD: con 80;

# Maximum steps in the agent loop (safety net, primary stop is end_turn from API)
DEFAULT_MAX_STEPS: con 200;
MAX_MAX_STEPS: con 1000;

# Session storage: persistent across reboots
SESSION_BASE: con "/usr/inferno/veltro/sessions";

# How many log lines to inject into resume context
LOG_RESUME_LINES: con 15;

# Max chars of tool args / result to record per log entry
LOG_PREVIEW: con 200;

# Default thinking token budget (0 = disabled)
THINK_DEFAULT: con 8000;

# Configuration
verbose := 0;
thinkbudget := 0;
maxsteps := DEFAULT_MAX_STEPS;

# Agent persona: -a <type> layers /lib/veltro/agents/<type>.txt onto the
# base system prompt, running this top-level loop as that agent (e.g.
# research, explore, plan). Empty = the default Veltro behaviour.
agenttype := "";

# -m <model>: override the LLM model for this run by writing it to the
# session's /mnt/llm/<id>/model file (llmsrv routes per-session). Empty = the
# server's default. Used for multi-model evaluation (gpt-oss vs mistral) without
# reconfiguring the server.
model := "";

# Active session directory (empty = sessions disabled for this run)
sessiondir := "";

stderr: ref Sys->FD;

usage()
{
	sys->fprint(stderr, "Usage: veltro [-v] [-t] [-a type] [-m model] [-p paths] <task>\n");
	sys->fprint(stderr, "       veltro [-v] [-t] [-a type] [-m model] [-p paths] -r <name> [extra instruction]\n");
	sys->fprint(stderr, "\nOptions:\n");
	sys->fprint(stderr, "  -v          Verbose output\n");
	sys->fprint(stderr, "  -t          Enable extended thinking (%d token budget)\n", THINK_DEFAULT);
	sys->fprint(stderr, "  -a type     Run as agent persona /lib/veltro/agents/<type>.txt (e.g. research)\n");
	sys->fprint(stderr, "  -m model    Override the LLM model for this run (e.g. mistral-small3.2:24b)\n");
	sys->fprint(stderr, "  -r name     Resume session ('last' = most recent)\n");
	sys->fprint(stderr, "  -p paths    Comma-separated /n/local/ paths to expose (e.g. /n/local/Users/you/proj)\n");
	sys->fprint(stderr, "\nRequires /tool and /mnt/llm to be mounted.\n");
	raise "fail:usage";
}

nomod(s: string)
{
	sys->fprint(stderr, "veltro: can't load %s: %r\n", s);
	raise "fail:load";
}

# Load the persona prompt named by -a from /lib/veltro/agents/<type>.txt.
# Returns "" when no persona was requested or the file is unreadable; the
# traversal guard mirrors spawn.b's loadagentprompt.
loadpersona(): string
{
	if(agenttype == "")
		return "";
	for(i := 0; i < len agenttype; i++)
		if(agenttype[i] == '/' || agenttype[i] == '\\')
			return "";
	if(agenttype == ".." || agenttype == ".")
		return "";
	p := agentlib->readfile("/lib/veltro/agents/" + agenttype + ".txt");
	if(p == "")
		sys->fprint(stderr, "veltro: warning: persona '%s' empty or unreadable\n", agenttype);
	return p;
}

# Apply the -m model override to a freshly created session by writing the model
# name to /mnt/llm/<id>/model (llmsrv stores it per-session). No-op when -m was
# not given.
setmodel(id: string)
{
	if(model == "")
		return;
	path := "/mnt/llm/" + id + "/model";
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil) {
		sys->fprint(stderr, "veltro: warning: cannot set model %s: %r\n", model);
		return;
	}
	sys->fprint(fd, "%s", model);
	if(verbose)
		sys->fprint(stderr, "veltro: model set to %s\n", model);
}

# Deterministic intent classifier: map a task to a specialist persona by its
# leading verb / strong opening phrase. Conservative — only an unambiguous
# signal routes; anything else stays the general agent. Unlike the prompt-cue
# routing (which gpt-oss/Mistral follow unreliably), this engages the persona
# for the run regardless of the model. Explicit -a always overrides it.
classifyintent(task: string): string
{
	t := str->tolower(agentlib->strip(task));
	if(t == "")
		return "";
	(n, toks) := sys->tokenize(t, " \t\n");
	first := "";
	if(n > 0)
		first = hd toks;
	case first {
	"verify" or "confirm" =>
		return "verify";
	"research" or "investigate" or "compare" =>
		return "research";
	}
	if(agentlib->hasprefix(t, "check that ") || agentlib->hasprefix(t, "check whether ") ||
	   agentlib->hasprefix(t, "check if ") || agentlib->hasprefix(t, "make sure "))
		return "verify";
	if(agentlib->hasprefix(t, "find out "))
		return "research";
	return "";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	str = load String String->PATH;
	if(str == nil)
		nomod(String->PATH);

	agentlib = load AgentLib AgentLib->PATH;
	if(agentlib == nil)
		nomod(AgentLib->PATH);
	agentlib->init();

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);
	arg->init(args);

	resumename := "";
	pathlist: list of string;
	while((o := arg->opt()) != 0)
		case o {
		'v' =>	verbose = 1;
		't' =>	thinkbudget = THINK_DEFAULT;
		'r' =>	resumename = arg->earg();
		'a' =>	agenttype = arg->earg();
		'm' =>	model = arg->earg();
		'p' =>
			(nil, pathlist) = sys->tokenize(arg->earg(), ",");
		* =>	usage();
		}
	args = arg->argv();

	agentlib->setverbose(verbose);

	# Check required mounts
	if(!agentlib->pathexists("/tool"))
		sys->fprint(stderr, "warning: /tool not mounted (run tools9p first)\n");
	if(!agentlib->pathexists("/mnt/llm"))
		sys->fprint(stderr, "warning: /mnt/llm not mounted (LLM unavailable)\n");

	# Namespace restriction (v3): FORKNS + bind-replace
	# Load nsconstruct module (must happen while /dis is unrestricted)
	nsconstruct = load NsConstruct NsConstruct->PATH;
	if(nsconstruct == nil) {
		sys->fprint(stderr, "veltro: cannot load namespace confinement: %r\n");
		raise "fail:namespace";
	} else {
		nsconstruct->init();

		# Read tools list before restriction to grant correct capabilities.
		# exec tool needs sh.dis+cmd/; xenith tool needs /chan.
		(nil, toollist) := sys->tokenize(agentlib->readfile("/tool/tools"), "\n");
		xgrant := 0;
		for(tl2 := toollist; tl2 != nil; tl2 = tl tl2)
			if(hd tl2 == "xenith") { xgrant = 1; break; }

		# Register -p paths in tools9p store (before FORKNS so trusted control is
		# reachable). caps.paths drives restrictns; /tool/paths gives observability.
		if(agentlib->pathexists("/tool"))
			for(pp := pathlist; pp != nil; pp = tl pp)
				writefile("/mnt/toolctl/ctl", "bindpath " + hd pp);

		# Write agent name before FORKNS so user process can read it.
		# /tmp/veltro/ and .ns/ may not exist yet — create them.
		sys->create("/tmp/veltro", Sys->OREAD, 8r700 | Sys->DMDIR);
		sys->create("/tmp/veltro/.ns", Sys->OREAD, 8r700 | Sys->DMDIR);
		{
			afd := sys->create("/tmp/veltro/.ns/agentname", Sys->OWRITE, 8r644);
			if(afd != nil) {
				sys->fprint(afd, "Veltro");
				afd = nil;
			}
		}

		# Preserve only the shared session pointer when restrictns allowlists /env.
		(envsessionok, nil) := sys->stat("/env/VELTRO_SESSION");
		if(envsessionok < 0) {
			efd := sys->create("/env/VELTRO_SESSION", Sys->OWRITE, 8r600);
			if(efd == nil) {
				sys->fprint(stderr, "veltro: cannot create session environment slot: %r\n");
				raise "fail:namespace";
			}
		}
		# Fork namespace so caller is unaffected
		if(sys->pctl(Sys->FORKNS, nil) < 0) {
			sys->fprint(stderr, "veltro: cannot fork namespace: %r\n");
			raise "fail:namespace";
		}
		if(sys->pctl(Sys->NODEVS, nil) < 0) {
			sys->fprint(stderr, "veltro: cannot disable device attachment: %r\n");
			raise "fail:namespace";
		}

		# This loop opens its LLM session by path after restriction. Keep this
		# internal grant out of the user-supplied bindpath registration above:
		# /mnt is capability-driven, but /mnt/llm is required for this launcher.
		for(pl := pathlist; pl != nil; pl = tl pl)
			if(hd pl == "/mnt/llm")
				break;
		if(pl == nil)
			pathlist = "/mnt/llm" :: pathlist;

		parent_caps := ref NsConstruct->Capabilities(
			toollist, pathlist, nil, nil, nil, nil, 0, xgrant, -1, nil
		, nil);

		# Apply namespace restrictions
		nserr := nsconstruct->restrictns(parent_caps);
		if(nserr != nil) {
			sys->fprint(stderr, "veltro: namespace restriction failed: %s\n", nserr);
			raise "fail:namespace";
		} else {
			if(verbose)
				sys->fprint(stderr, "veltro: namespace restricted\n");
			# Emit namespace manifest from the restricted namespace
			# so stat checks reflect exactly what the agent can see
			nsconstruct->emitmanifest(parent_caps, "/tmp/veltro/.ns/manifest");
		}
	}

	if(resumename != "") {
		# Resume mode: remaining args become optional extra instruction
		extra := "";
		for(; args != nil; args = tl args) {
			if(extra != "")
				extra += " ";
			extra += hd args;
		}
		runresume(resumename, extra);
	} else {
		if(args == nil)
			usage();
		task := "";
		for(; args != nil; args = tl args) {
			if(task != "")
				task += " ";
			task += hd args;
		}
		# Deterministic intent routing: auto-engage a specialist persona when the
		# request unambiguously signals one and no -a was given explicitly.
		if(agenttype == "") {
			agenttype = classifyintent(task);
			if(verbose && agenttype != "")
				sys->fprint(stderr, "veltro: intent routing -> %s agent\n", agenttype);
		}
		runagent(task);
	}
}

# ---- Session management ----

# Derive a URL-safe slug from a task string (max ~30 chars)
makeslug(task: string): string
{
	lower := str->tolower(task);
	slug := "";
	prevhyph := 0;
	for(i := 0; i < len lower; i++) {
		c := lower[i];
		if((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
			slug += string c;
			prevhyph = 0;
		} else if(c == ' ' || c == '-' || c == '_') {
			if(!prevhyph && len slug > 0) {
				slug += "-";
				prevhyph = 1;
			}
		}
		if(len slug >= 30)
			break;
	}
	# Trim trailing hyphen
	while(len slug > 0 && slug[len slug - 1] == '-')
		slug = slug[0:len slug - 1];
	if(slug == "")
		slug = "task";
	return slug;
}

# Find a free session name: if base exists, try base-2, base-3, ...
findfreeslug(base: string): string
{
	(ok, nil) := sys->stat(SESSION_BASE + "/" + base);
	if(ok < 0)
		return base;
	for(n := 2; n < 1000; n++) {
		candidate := base + "-" + string n;
		(ok2, nil) := sys->stat(SESSION_BASE + "/" + candidate);
		if(ok2 < 0)
			return candidate;
	}
	return base + "-x";
}

# Create path and all missing parent directories (mkdir -p equivalent)
mkdirall(path: string): string
{
	for(i := 1; i < len path; i++) {
		if(path[i] == '/')
			sys->create(path[0:i], Sys->OREAD, 8r755 | Sys->DMDIR);
	}
	fd := sys->create(path, Sys->OREAD, 8r755 | Sys->DMDIR);
	if(fd == nil) {
		# May already exist as a directory — check
		(ok, d) := sys->stat(path);
		if(ok >= 0 && (d.mode & Sys->DMDIR))
			return nil;
		return sys->sprint("cannot create %s: %r", path);
	}
	fd = nil;
	return nil;
}

# Write string content to a file (create or overwrite)
writefile(path, content: string): string
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	data := array of byte content;
	if(sys->write(fd, data, len data) < 0) {
		fd = nil;
		return sys->sprint("write %s failed: %r", path);
	}
	fd = nil;
	return nil;
}

# Read entire file contents; returns "" silently on error
readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	content := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		content += string buf[0:n];
	fd = nil;
	return content;
}

# Write a value to /env/name (Inferno environment variable mechanism)
setenv(name, val: string)
{
	fd := sys->create("/env/" + name, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	data := array of byte val;
	sys->write(fd, data, len data);
	fd = nil;
}

# Write thinking token budget to the session's thinking file.
# budget <= 0 means no-op (thinking stays disabled).
setthinking(llmsessionid: string, budget: int)
{
	if(budget <= 0)
		return;
	path := "/mnt/llm/" + llmsessionid + "/thinking";
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil) {
		if(verbose)
			sys->fprint(stderr, "veltro: cannot open %s: %r\n", path);
		return;
	}
	val := string budget;
	data := array of byte val;
	sys->write(fd, data, len data);
	fd = nil;
	if(verbose)
		sys->fprint(stderr, "veltro: thinking budget: %d tokens\n", budget);
}

# Replace newlines and tabs with spaces (for single-line log entries)
collapsenl(s: string): string
{
	result := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '\n' || c == '\r' || c == '\t')
			result += " ";
		else
			result += string c;
	}
	return result;
}

# Append one step entry to the session log file
appendlog(step: int, tool, toolargs, result: string)
{
	if(sessiondir == "")
		return;

	apreview := toolargs;
	if(len apreview > LOG_PREVIEW)
		apreview = apreview[0:LOG_PREVIEW] + "...";
	rpreview := result;
	if(len rpreview > LOG_PREVIEW)
		rpreview = rpreview[0:LOG_PREVIEW] + "...";

	line := sys->sprint("step %d: %s %s -> %s\n",
		step, tool, collapsenl(apreview), collapsenl(rpreview));

	logpath := sessiondir + "/log";
	fd := sys->open(logpath, Sys->OWRITE);
	if(fd == nil)
		fd = sys->create(logpath, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	sys->seek(fd, big 0, 2);	# append to end
	data := array of byte line;
	sys->write(fd, data, len data);
	fd = nil;
}

# Resolve "last" session name from the pointer file
resolvelast(): string
{
	name := readfile(SESSION_BASE + "/last");
	# Trim whitespace
	i := 0;
	while(i < len name && (name[i] == ' ' || name[i] == '\n' || name[i] == '\r'))
		i++;
	j := len name;
	while(j > i && (name[j-1] == ' ' || name[j-1] == '\n' || name[j-1] == '\r'))
		j--;
	if(i >= j)
		return "";
	return name[i:j];
}

# Extract the last n lines from log content (oldest-first chronological order)
loglines(logcontent: string, n: int): string
{
	if(logcontent == "")
		return "";

	# Parse all lines; build newest-first list by prepending
	newest: list of string;
	nc := len logcontent;
	i := 0;
	while(i < nc) {
		j := i;
		while(j < nc && logcontent[j] != '\n')
			j++;
		if(j > i)
			newest = logcontent[i:j] :: newest;
		i = j + 1;
	}

	# Reverse back to oldest-first
	oldest: list of string;
	l: list of string;
	for(l = newest; l != nil; l = tl l)
		oldest = hd l :: oldest;

	# Count total lines
	total := 0;
	for(l = oldest; l != nil; l = tl l)
		total++;

	# Skip lines before the last n
	skip := total - n;
	if(skip < 0)
		skip = 0;

	result := "";
	cnt := 0;
	for(l = oldest; l != nil; l = tl l) {
		if(cnt >= skip) {
			if(result != "")
				result += "\n";
			result += hd l;
		}
		cnt++;
	}
	return result;
}

# Strip trailing whitespace/newlines from s
trimright(s: string): string
{
	j := len s;
	while(j > 0 && (s[j-1] == ' ' || s[j-1] == '\n' || s[j-1] == '\r' || s[j-1] == '\t'))
		j--;
	return s[0:j];
}

# Build the initial prompt for a resumed session
buildresumecontext(task, plan, logcontent, extra: string): string
{
	# Count total steps from log line count
	nsteps := 0;
	for(i := 0; i < len logcontent; i++) {
		if(logcontent[i] == '\n')
			nsteps++;
	}

	ctx := "== Resuming Task ==\n" + task;

	if(plan != "")
		ctx += "\n\nPlan:\n" + plan;

	if(nsteps > 0) {
		ctx += sys->sprint("\n\nPrevious steps (%d total). Recent actions:\n", nsteps);
		ctx += loglines(logcontent, LOG_RESUME_LINES);
	}

	# Include todo state if the session has one
	todostate := readfile(sessiondir + "/todo.txt");
	if(todostate != "")
		ctx += "\n\nCurrent todo list:\n" + todostate;

	if(extra != "")
		ctx += "\n\nAdditional instruction: " + extra;

	ctx += "\n\nContinue the task.";
	return ctx;
}

# ---- Planning ----

# Decide whether this task warrants a planning turn before the action loop.
# Triggers on long tasks (>= PLAN_TASK_THRESHOLD chars) or known complex keywords.
shouldplan(task: string): int
{
	if(len task >= PLAN_TASK_THRESHOLD)
		return 1;
	lower := str->tolower(task);
	keywords := array[] of {
		"refactor", "implement", "debug", "analyze", "design", "migrate"
	};
	for(i := 0; i < len keywords; i++) {
		if(agentlib->contains(lower, keywords[i]))
			return 1;
	}
	return 0;
}

# Run a single planning-only LLM turn.
# Returns the plan text, or "" if the turn fails or produces nothing useful.
doplanningturn(llmfd: ref Sys->FD, task: string): string
{
	# Ask for the plan as plain text rather than via a specific tool: the
	# `say` tool is not always provisioned (headless runs, restricted
	# subagent toolsets, persona agents). Mandating a missing tool left the
	# model unable to comply — it returned an empty turn that then poisoned
	# the agentloop conversation. Plain text works for every toolset; the
	# say fast-path below still fires when say happens to be available.
	planprompt := "== Task ==\n" + task +
		"\n\nBefore taking any action, state your plan as 3-5 numbered steps in plain text.\n" +
		"Do not call any tools yet.";

	if(verbose)
		sys->fprint(stderr, "veltro: planning turn\n");

	planresponse := agentlib->queryllmfd(llmfd, planprompt);
	if(planresponse == "")
		return "";

	if(verbose)
		sys->fprint(stderr, "veltro: plan response: %s\n",
			agentlib->truncate(planresponse, 500));

	(nil, tools, text) := agentlib->parsellmresponse(planresponse);

	# Prefer say-tool content; fall back to text
	for(tc := tools; tc != nil; tc = tl tc) {
		(id, name, args) := hd tc;
		if(name == "say") {
			# Acknowledge say so conversation history stays consistent
			results := (id, "plan noted") :: nil;
			wire := agentlib->buildtoolresults(results);
			agentlib->queryllmfd(llmfd, wire);
			return args;
		}
	}
	return text;
}

# ---- Context compaction ----

# Threshold: compact when estimated context exceeds 75% of 200K limit
COMPACT_THRESHOLD: con 150000;

# selfmanagecompaction tells llmsrv that this client drives compaction itself
# (via checkandcompact, below) by disabling the server-side auto-compaction
# safety net for this session (INFR-223). Without this, both the server's
# high-water trigger and veltro's checkandcompact would fire near the same
# threshold; opting out keeps exactly one authority — the client — for veltro
# sessions, while the server net stays on by default for clients that don't
# self-manage (the primary agent, repl, sub-agents).
selfmanagecompaction(llmsessionid: string)
{
	ctlpath := "/mnt/llm/" + llmsessionid + "/ctl";
	err := writefile(ctlpath, "autocompact 0");
	if(err != nil && verbose)
		sys->fprint(stderr, "veltro: could not disable server auto-compact: %s\n", err);
}

# checkandcompact reads /mnt/llm/N/usage and triggers compaction if needed.
# The usage file returns "estimated_tokens/context_limit\n".
# A write to /mnt/llm/N/compact triggers the summarisation LLM call.
checkandcompact(llmsessionid: string)
{
	usagepath := "/mnt/llm/" + llmsessionid + "/usage";
	s := readfile(usagepath);
	if(s == "")
		return;
	# s is "estimated/limit\n" — extract the numerator
	n := 0;
	for(i := 0; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		n = n * 10 + (s[i] - '0');
	if(n < COMPACT_THRESHOLD)
		return;
	if(verbose)
		sys->fprint(stderr, "veltro: context at ~%d tokens, compacting session\n", n);
	compactpath := "/mnt/llm/" + llmsessionid + "/compact";
	err := writefile(compactpath, "compact");
	if(err != nil)
		sys->fprint(stderr, "veltro: compaction failed: %s\n", err);
	else if(verbose)
		sys->fprint(stderr, "veltro: session compacted\n");
}

# ---- Parallel tool execution ----

# Per-tool timeout: 60 seconds default
TOOL_TIMEOUT: con 60000;

runtoolchan(tool, args: string, ch: chan of string)
{
	ch <-= agentlib->calltool(tool, args);
}

tooltimer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

# Execute a single tool call with a timeout.
# Returns result string, or an error if the tool hangs.
exectool1(name, args: string): string
{
	resultch := chan of string;
	spawn runtoolchan(name, args, resultch);
	timeoutch := chan of int;
	spawn tooltimer(timeoutch, TOOL_TIMEOUT);
	r := "";
	alt {
	r = <-resultch =>
		;
	<-timeoutch =>
		r = sys->sprint("error: tool '%s' timed out after %d seconds", name, TOOL_TIMEOUT / 1000);
	}
	return r;
}

# Execute a list of native tool_use calls in parallel.
# calls: list of (tool_use_id, name, args) from parsellmresponse.
# Provenance header stamped at the top of a scratch-spilled tool result so
# the model can attribute facts to their real source (e.g. the webfetch URL
# or the file path) instead of citing the opaque scratch path it reads from.
provenance(name, args: string): string
{
	return sys->sprint("SOURCE: %s %s\n\n", name, args);
}

# Read-cache (dedup of identical read-only tool calls) lives in agentlib now —
# agentlib->dedup{reset,check,record}; shared with lucibridge.b.

# Returns list of (tool_use_id, content) for buildtoolresults.
exectools(calls: list of (string, string, string), step: int): list of (string, string)
{
	n := 0;
	i: int;
	for(cl := calls; cl != nil; cl = tl cl)
		n++;

	# Single tool: execute with timeout
	if(n == 1) {
		(id, name, args) := hd calls;
		skip := agentlib->dedupcheck(name, args);
		if(skip != "")
			return (id, skip) :: nil;
		r := exectool1(name, args);
		agentlib->deduprecord(name, args, r, step);
		if(len r > AgentLib->STREAM_THRESHOLD) {
			scratchfile := agentlib->writescratch(provenance(name, args) + r, step);
			r = sys->sprint("(output from %s %s written to %s, %d bytes; its first line records the source — cite that, not the scratch path)",
				name, agentlib->truncate(args, 120), scratchfile, len r);
		}
		return (id, r) :: nil;
	}

	# Multiple tools: one channel per tool for ordered collection
	channels := array[n] of chan of string;
	for(i = 0; i < n; i++)
		channels[i] = chan of string;

	cl2 := calls;
	for(i = 0; cl2 != nil; i++) {
		(nil, name, args) := hd cl2;
		cl2 = tl cl2;
		spawn runtoolchan(name, args, channels[i]);
	}

	# Collect results in original order, with per-tool timeout
	results: list of (string, string);
	cl3 := calls;
	for(i = 0; cl3 != nil; i++) {
		(id, name, args) := hd cl3;
		cl3 = tl cl3;
		timeoutch := chan of int;
		spawn tooltimer(timeoutch, TOOL_TIMEOUT);
		r := "";
		alt {
		r = <-channels[i] =>
			;
		<-timeoutch =>
			r = sys->sprint("error: tool '%s' timed out after %d seconds", name, TOOL_TIMEOUT / 1000);
		}
		agentlib->deduprecord(name, args, r, step);
		if(len r > AgentLib->STREAM_THRESHOLD) {
			scratchfile := agentlib->writescratch(provenance(name, args) + r, step * 10 + i);
			r = sys->sprint("(output from %s %s written to %s, %d bytes; its first line records the source — cite that, not the scratch path)",
				name, agentlib->truncate(args, 120), scratchfile, len r);
		}
		results = (id, r) :: results;
	}

	# Reverse to restore original order
	rev: list of (string, string);
	for(rl := results; rl != nil; rl = tl rl)
		rev = (hd rl) :: rev;
	return rev;
}

# ---- Core action loop (shared by runagent and runresume) ----

agentloop(fd: ref Sys->FD, id, initialprompt: string)
{
	agentlib->dedupreset();	# fresh read-cache per run
	if(verbose)
		sys->fprint(stderr, "veltro: agentloop start\n");

	response := agentlib->queryllmfd(fd, initialprompt);
	if(response == "") {
		sys->fprint(stderr, "veltro: LLM returned empty response\n");
		return;
	}

	for(step := 0; step < maxsteps; step++) {
		if(verbose)
			sys->fprint(stderr, "veltro: step %d\n", step + 1);

		(stopreason, tools, text) := agentlib->parsellmresponse(response);

		if(text != "")
			sys->print("%s\n", text);

		# Agent is done
		if(stopreason == "end_turn" || stopreason == "" || tools == nil)
			break;

		# Display tool invocations
		for(tc := tools; tc != nil; tc = tl tc) {
			(nil, name, args) := hd tc;
			sys->print("[%s %s]\n", name, agentlib->truncate(args, 80));
		}

		# Execute tools (parallel if multiple)
		results := exectools(tools, step);

		# Log each result
		for(rl := results; rl != nil; rl = tl rl) {
			(nil, result) := hd rl;
			appendlog(step + 1, "tools", "", agentlib->truncate(result, 200));
		}

		checkandcompact(id);

		# Submit tool results and get next response
		wire := agentlib->buildtoolresults(results);
		response = agentlib->queryllmfd(fd, wire);
		if(response == "") {
			sys->fprint(stderr, "veltro: empty response after tool results\n");
			break;
		}
	}

	if(verbose)
		sys->fprint(stderr, "veltro: agentloop done\n");
}

# ---- New session ----

runagent(task: string)
{
	if(verbose)
		sys->fprint(stderr, "veltro: starting with task: %s\n", task);

	# Create session directory and set environment
	slug := findfreeslug(makeslug(task));
	sdir := SESSION_BASE + "/" + slug;
	if(mkdirall(sdir) != nil) {
		sys->fprint(stderr, "veltro: warning: cannot create session dir — session not saved\n");
		sdir = "";
	}
	if(sdir != "") {
		writefile(sdir + "/task", task);
		writefile(SESSION_BASE + "/last", slug);
		setenv("VELTRO_SESSION", sdir);
		sessiondir = sdir;
		sys->fprint(stderr, "veltro: session %s\n", slug);
	}

	# Create LLM session — clone pattern: read /mnt/llm/new returns session ID
	llmsessionid := agentlib->createsession();
	if(llmsessionid == "") {
		sys->fprint(stderr, "veltro: cannot create LLM session\n");
		return;
	}
	setmodel(llmsessionid);
	if(verbose)
		sys->fprint(stderr, "veltro: llm session %s\n", llmsessionid);

	# Veltro owns its own compaction policy (checkandcompact) — opt out of the
	# server-side auto-compaction net so the two don't both trigger.
	selfmanagecompaction(llmsessionid);

	# Set prefill to keep model in character
	prefillpath := "/mnt/llm/" + llmsessionid + "/prefill";
	agentlib->setprefillpath(prefillpath, "[Veltro]\n");
	setthinking(llmsessionid, thinkbudget);

	# Discover namespace — this IS our capability set
	ns := agentlib->discovernamespace();
	if(verbose)
		sys->fprint(stderr, "veltro: namespace:\n%s\n", ns);

	# Set system prompt for native tool_use
	systempath := "/mnt/llm/" + llmsessionid + "/system";
	agentlib->setsystemprompt(systempath, agentlib->buildsystemprompt(ns, loadpersona()));

	# Install tool definitions for native tool_use protocol
	(nil, toollist) := sys->tokenize(agentlib->readfile("/tool/tools"), "\n");
	agentlib->initsessiontools(llmsessionid, toollist);

	# Open session's ask file
	askpath := "/mnt/llm/" + llmsessionid + "/ask";
	llmfd := sys->open(askpath, Sys->ORDWR);
	if(llmfd == nil) {
		sys->fprint(stderr, "veltro: cannot open %s: %r\n", askpath);
		return;
	}

	# Optional planning turn for complex tasks
	plan := "";
	if(shouldplan(task)) {
		plan = doplanningturn(llmfd, task);
		if(verbose && plan != "")
			sys->fprint(stderr, "veltro: plan:\n%s\n", plan);
	}

	# Save plan to session directory
	if(sdir != "" && plan != "")
		writefile(sdir + "/plan", plan);

	# Assemble initial prompt (system prompt already set separately)
	prompt: string;
	if(plan != "") {
		prompt = "Plan:\n" + plan +
			"\n\nNow begin execution. Respond with your first tool invocation or DONE if already complete.";
	} else {
		prompt = "== Task ==\n" + task + "\n\nBegin. Respond with your first tool call or DONE.";
	}

	agentloop(llmfd, llmsessionid, prompt);
	agentlib->closesession(llmsessionid);
}

# ---- Resume session ----

runresume(name, extra: string)
{
	# Resolve "last" to actual session name
	actualname := name;
	if(name == "last") {
		actualname = resolvelast();
		if(actualname == "") {
			sys->fprint(stderr, "veltro: no previous session found\n");
			return;
		}
	}

	sdir := SESSION_BASE + "/" + actualname;
	task := trimright(readfile(sdir + "/task"));
	if(task == "") {
		sys->fprint(stderr, "veltro: session '%s' not found\n", actualname);
		return;
	}

	plan := trimright(readfile(sdir + "/plan"));
	logcontent := readfile(sdir + "/log");

	# Restore session context
	sessiondir = sdir;
	setenv("VELTRO_SESSION", sdir);
	writefile(SESSION_BASE + "/last", actualname);

	sys->fprint(stderr, "veltro: resuming session %s\n", actualname);
	if(extra != "" && verbose)
		sys->fprint(stderr, "veltro: extra instruction: %s\n", extra);

	# Create new LLM session
	llmsessionid := agentlib->createsession();
	if(llmsessionid == "") {
		sys->fprint(stderr, "veltro: cannot create LLM session\n");
		return;
	}
	setmodel(llmsessionid);

	# Veltro owns its own compaction policy (checkandcompact) — opt out of the
	# server-side auto-compaction net so the two don't both trigger.
	selfmanagecompaction(llmsessionid);

	prefillpath := "/mnt/llm/" + llmsessionid + "/prefill";
	agentlib->setprefillpath(prefillpath, "[Veltro]\n");
	setthinking(llmsessionid, thinkbudget);

	# Discover namespace and set system prompt for native tool_use
	ns := agentlib->discovernamespace();
	if(verbose)
		sys->fprint(stderr, "veltro: namespace:\n%s\n", ns);

	systempath := "/mnt/llm/" + llmsessionid + "/system";
	agentlib->setsystemprompt(systempath, agentlib->buildsystemprompt(ns, loadpersona()));

	# Install tool definitions for native tool_use protocol
	(nil, toollist) := sys->tokenize(agentlib->readfile("/tool/tools"), "\n");
	agentlib->initsessiontools(llmsessionid, toollist);

	askpath := "/mnt/llm/" + llmsessionid + "/ask";
	llmfd := sys->open(askpath, Sys->ORDWR);
	if(llmfd == nil) {
		sys->fprint(stderr, "veltro: cannot open %s: %r\n", askpath);
		return;
	}

	# Build resume context as the initial prompt
	prompt := buildresumecontext(task, plan, logcontent, extra);

	agentloop(llmfd, llmsessionid, prompt);
	agentlib->closesession(llmsessionid);
}

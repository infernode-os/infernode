implement Veltro;

#
# veltro - run the Veltro agent on a task, from the command line
#
# A client of veltrosrv(4): it starts the harness with the grants given
# here, writes the task to the session's input and prints the agent's
# text as it arrives.  What is the command line's stays here: the
# planning turn for a complex task, intent routing to a persona, the
# session directory that -r resumes from, and answering the agent's
# approval requests on the terminal.
#
#	veltro [-v] [-t] [-y] [-a type] [-m model] [-p paths] <task>
#	veltro [-v] [-t] [-y] [-a type] [-m model] [-p paths] -r <name> [extra]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "string.m";
	str: String;

include "agentlib.m";
	agentlib: AgentLib;

include "veltrosrv.m";

Veltro: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# Tasks at least this long, or with a complexity keyword, get a planning
# turn before the action loop.
PLAN_TASK_THRESHOLD: con 80;

DEFAULT_MAX_STEPS: con 200;

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
nogate := 0;
maxsteps := DEFAULT_MAX_STEPS;

# Agent persona: -a <type> layers /lib/veltro/agents/<type>.txt onto the
# base system prompt, running this top-level loop as that agent (e.g.
# research, explore, plan). Empty = the default Veltro behaviour.
agenttype := "";

# -m <model>: override the LLM model for this run. Empty = the server's
# default. Used for multi-model evaluation without reconfiguring the server.
model := "";

# Active session directory (empty = sessions disabled for this run)
sessiondir := "";

# The agent session: its directory under /mnt/veltro.
sess := "";
srvpid := 0;

stderr: ref Sys->FD;
stdout: ref Sys->FD;

usage()
{
	sys->fprint(stderr, "Usage: veltro [-v] [-t] [-y] [-a type] [-m model] [-p paths] <task>\n");
	sys->fprint(stderr, "       veltro [-v] [-t] [-y] [-a type] [-m model] [-p paths] -r <name> [extra instruction]\n");
	sys->fprint(stderr, "\nOptions:\n");
	sys->fprint(stderr, "  -v          Verbose output (the agent's trajectory)\n");
	sys->fprint(stderr, "  -t          Enable extended thinking (%d token budget)\n", THINK_DEFAULT);
	sys->fprint(stderr, "  -y          Answer the agent's approval requests yes (no gate)\n");
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

# ---- The harness ----

# Start veltrosrv in a process group of its own, so it can be stopped
# when this run is over.  It mounts at /mnt/veltro in this namespace.
# This process stays, so the group has a member to send killgrp to.
srvstop: chan of int;

srvproc(srv: VeltroSrv, args: list of string, started: chan of int)
{
	pid := sys->pctl(Sys->NEWPGRP, nil);
	{
		srv->init(nil, args);
		started <-= pid;
	} exception e {
	"fail:*" =>
		sys->fprint(stderr, "veltro: %s\n", e[5:]);
		started <-= -1;
		return;
	}
	<-srvstop;
}

startharness(pathlist: list of string)
{
	srv := load VeltroSrv VeltroSrv->PATH;
	if(srv == nil)
		nomod(VeltroSrv->PATH);
	args: list of string;
	args = "-n" :: string maxsteps :: args;
	if(verbose)
		args = "-v" :: args;
	if(pathlist != nil)
		args = "-p" :: join(pathlist, ",") :: args;
	args = "veltrosrv" :: args;
	started := chan of int;
	srvstop = chan of int;
	spawn srvproc(srv, args, started);
	srvpid = <-started;
	if(srvpid < 0)
		raise "fail:cannot start the agent";

	sid := agentlib->strip(agentlib->readfile("/mnt/veltro/new"));
	if(sid == "") {
		sys->fprint(stderr, "veltro: cannot start an agent session\n");
		raise "fail:no session";
	}
	sess = "/mnt/veltro/" + sid;
}

stopharness()
{
	if(sess != "")
		ctl("close");
	sys->unmount(nil, "/mnt/veltro");
	if(srvpid > 0) {
		fd := sys->open("/prog/" + string srvpid + "/ctl", Sys->OWRITE);
		if(fd != nil)
			sys->fprint(fd, "killgrp");
	}
}

ctl(req: string): int
{
	fd := sys->open(sess + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte req;
	n := sys->write(fd, b, len b);
	if(n < 0 && verbose)
		sys->fprint(stderr, "veltro: ctl %s: %r\n", req);
	return n;
}

join(l: list of string, sep: string): string
{
	s := "";
	for(; l != nil; l = tl l) {
		if(s != "")
			s += sep;
		s += hd l;
	}
	return s;
}

# ---- One turn ----

# What the agent said in the turn, for the planning step.
turntext := "";
curstep := 0;

# Print the agent's text as it streams, and keep what it said.
textfollow(done: chan of int)
{
	fd := sys->open(sess + "/text", Sys->OREAD);
	if(fd == nil) {
		done <-= 1;
		return;
	}
	buf := array[8192] of byte;
	offset := big 0;
	(ok, d) := sys->fstat(fd);
	if(ok >= 0)
		offset = d.length;
	role := "";
	atline := 1;
	held := "";
	for(;;) {
		n := sys->pread(fd, buf, len buf, offset);
		if(n <= 0)
			break;
		offset += big n;
		chunk := string buf[0:n];
		out := "";
		for(i := 0; i < len chunk; i++) {
			c := chunk[i];
			if(held != "" || (atline && c == '=')) {
				held[len held] = c;
				if(c == '\n') {
					if(len held > 3 && held[0:3] == "== ") {
						(role, nil) = str->splitl(held[3:len held - 1], " ");
						if(out != "" && out[len out - 1] != '\n')
							out += "\n";
					} else
						out += emit(role, held);
					held = "";
					atline = 1;
				} else if(len held <= 3 && held != "== "[0:len held]) {
					out += emit(role, held);
					held = "";
					atline = 0;
				}
				continue;
			}
			out += emit(role, chunk[i:i+1]);
			atline = c == '\n';
		}
		if(out != "")
			sys->fprint(stdout, "%s", out);
	}
	if(held != "")
		sys->fprint(stdout, "%s", emit(role, held));
	done <-= 1;
}

emit(role, s: string): string
{
	case role {
	"veltro" =>
		turntext += s;
		return s;
	"note" =>
		return s;
	}
	return "";
}

# Follow the log: the tool calls, as this command has always shown them,
# and the session log that -r resumes from.
logfollow(done: chan of int)
{
	fd := sys->open(sess + "/log", Sys->OREAD);
	if(fd == nil) {
		done <-= 1;
		return;
	}
	buf := array[8192] of byte;
	offset := big 0;
	(ok, d) := sys->fstat(fd);
	if(ok >= 0)
		offset = d.length;
	partial := "";
	curtool := "";
	curargs := "";
	for(;;) {
		n := sys->pread(fd, buf, len buf, offset);
		if(n <= 0)
			break;
		offset += big n;
		partial += string buf[0:n];
		for(;;) {
			(line, rest) := str->splitl(partial, "\n");
			if(rest == "")
				break;
			partial = rest[1:];
			if(verbose)
				sys->fprint(stderr, "veltro: %s\n", line);
			if(agentlib->hasprefix(line, "step ") && agentlib->contains(line, ": writing ")) {
				(curstep, nil) = str->toint(line[5:], 10);
			} else if(agentlib->hasprefix(line, "tool ")) {
				(nm, rest2) := str->splitl(line[5:], ":");
				if(agentlib->hasprefix(rest2, ": args ")) {
					curtool = nm;
					curargs = rest2[7:];
					sys->fprint(stdout, "[%s %s]\n", nm, agentlib->truncate(curargs, 80));
				} else if(agentlib->hasprefix(rest2, ": done, ") && nm == curtool)
					appendlog(curstep, nm, curargs, rest2[8:]);
			}
		}
	}
	done <-= 1;
}

# Answer the agent's requests for approval on the terminal.
approver(done: chan of int)
{
	cons := sys->open("/dev/cons", Sys->ORDWR);
	for(;;) {
		fd := sys->open(sess + "/approve", Sys->OREAD);
		if(fd == nil)
			break;
		buf := array[8192] of byte;
		n := sys->read(fd, buf, len buf);
		fd = nil;
		if(n <= 0)
			break;		# the turn is over
		req := agentlib->strip(string buf[0:n]);
		(callid, rest) := str->splitl(req, " ");
		rest = str->drop(rest, " ");
		answer := "deny";
		if(cons != nil) {
			sys->fprint(cons, "veltro: allow %s? [y/N] ", rest);
			ab := array[64] of byte;
			an := sys->read(cons, ab, len ab);
			if(an > 0) {
				a := str->tolower(agentlib->strip(string ab[0:an]));
				if(a == "y" || a == "yes")
					answer = "allow";
			}
		}
		afd := sys->open(sess + "/approve", Sys->OWRITE);
		if(afd != nil)
			sys->fprint(afd, "%s %s", answer, callid);
	}
	done <-= 1;
}

# Send one message and return when the agent has finished with it.
turn(input: string): int
{
	turntext = "";
	curstep = 0;
	fd := sys->open(sess + "/input", Sys->OWRITE);
	if(fd == nil) {
		sys->fprint(stderr, "veltro: cannot open %s/input: %r\n", sess);
		return -1;
	}
	b := array of byte input;
	if(sys->write(fd, b, len b) != len b) {
		sys->fprint(stderr, "veltro: %r\n");
		return -1;
	}
	fd = nil;
	done := chan of int;
	spawn textfollow(done);
	spawn logfollow(done);
	spawn approver(done);
	<-done;
	<-done;
	<-done;
	return 0;
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
			slug[len slug] = c;
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
	buf := array[65536] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

setenv(name, val: string)
{
	fd := sys->create("/env/" + name, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	data := array of byte val;
	sys->write(fd, data, len data);
	fd = nil;
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
			result[len result] = c;
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
	return agentlib->strip(readfile(SESSION_BASE + "/last"));
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

# Run a single planning-only turn.  Returns the plan text, or "" if the
# turn fails or produces nothing useful.  The plan is asked for as plain
# text rather than through a tool: the say tool is not always provisioned
# (headless runs, restricted toolsets, persona agents), and mandating a
# missing tool left the model unable to comply.
doplanningturn(task: string): string
{
	planprompt := "== Task ==\n" + task +
		"\n\nBefore taking any action, state your plan as 3-5 numbered steps in plain text.\n" +
		"Do not call any tools yet.";

	if(verbose)
		sys->fprint(stderr, "veltro: planning turn\n");
	if(turn(planprompt) < 0)
		return "";
	if(verbose)
		sys->fprint(stderr, "veltro: plan response: %s\n", agentlib->truncate(turntext, 500));
	return trimright(turntext);
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

	# Optional planning turn for complex tasks
	plan := "";
	if(shouldplan(task)) {
		plan = doplanningturn(task);
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

	turn(prompt);
	if(sdir != "")
		writefile(sdir + "/transcript", readfile(sess + "/text"));
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

	# Build resume context as the initial prompt
	prompt := buildresumecontext(task, plan, logcontent, extra);
	turn(prompt);
	writefile(sdir + "/transcript", readfile(sess + "/text"));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	stdout = sys->fildes(1);

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
		'y' =>	nogate = 1;
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

	task := "";
	extra := "";
	if(resumename != "") {
		# Resume mode: remaining args become optional extra instruction
		for(; args != nil; args = tl args) {
			if(extra != "")
				extra += " ";
			extra += hd args;
		}
	} else {
		if(args == nil)
			usage();
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
	}

	startharness(pathlist);
	if(agenttype != "" && ctl("persona " + agenttype) < 0)
		sys->fprint(stderr, "veltro: warning: persona '%s' empty or unreadable\n", agenttype);
	if(model != "" && ctl("model " + model) >= 0 && verbose)
		sys->fprint(stderr, "veltro: model set to %s\n", model);
	if(thinkbudget > 0 && ctl("think " + string thinkbudget) >= 0 && verbose)
		sys->fprint(stderr, "veltro: thinking budget: %d tokens\n", thinkbudget);
	if(nogate)
		ctl("gate off");

	{
		if(resumename != "")
			runresume(resumename, extra);
		else
			runagent(task);
	} exception e {
	"fail:*" =>
		stopharness();
		raise e;
	}
	stopharness();
}

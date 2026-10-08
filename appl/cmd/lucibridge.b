implement LuciBridge;

#
# lucibridge - Lucia's client of the Veltro agent harness
#
# Reads human messages from /mnt/ui/activity/{id}/conversation/input
# (blocking read), hands each to the agent through /mnt/veltro, and
# renders the agent's text, tool activity and questions back into the
# UI: conversation messages, the context zone, status and urgency,
# dialogue tiles for approvals.
#
# The agent loop itself is veltrosrv(4): this program starts one with
# the activity's grants (it mounts at /mnt/veltro in this namespace
# only) and is a client of its files.  What is Lucia's stays here: the
# first-run wizard, the welcome document, the guided tour, the context
# zone, slash commands, the cowfs overlay commands.
#
# Usage: lucibridge [-v] [-s] [-n maxsteps] [-a actid] [-t tools] [-p paths]
#   -v            verbose logging (the agent's trajectory is echoed to
#                 stderr under the lucibridge: prefix, as before)
#   -s            register the speech resource
#   -n steps      max agent steps per turn (default: 100)
#   -a id         activity ID (default: 0)
#   -t tools      comma-separated initial tool list (e.g. read,list,write)
#   -p paths      comma-separated namespace paths to expose via /n/local/
#
# Prerequisites:
#   - luciuisrv running (serves /mnt/ui/)
#   - LLM service mounted at /mnt/llm/
#   - tools9p running (serves /tool/) — optional but enables tool use
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "arg.m";
	arg: Arg;

include "agentlib.m";
	agentlib: AgentLib;

include "veltrosrv.m";

LuciBridge: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

DEFAULT_MAX_STEPS: con 100;
MAX_MAX_STEPS: con 500;

verbose := 0;
autospeak := 0;
maxsteps := DEFAULT_MAX_STEPS;
stderr: ref Sys->FD;

# The agent session: its directory under /mnt/veltro.
sess := "";

# Activity state
actid := 0;
toolmount := "/tool";		# /tool for activity 0, /tool.N for child N
convcount := 0;				# conversation message count (index for streaming updates)
userinteracted := 0;		# set once the human sends a message to this activity
currentpathsraw := "";		# last-seen /tool/paths content (for diffing)

toolargs: list of string;	# from -t flag (comma-separated tool names)
pathargs: list of string;	# from -p flag (comma-separated paths)

# The role suffix appended to the system prompt when no role file applies.
BRIDGE_SUFFIX: con "\n\nYou are %AGENT%, the AI agent in a Lucifer activity. " +
	"The user sends messages through the UI. " +
	"Reply directly in plain text for conversation, greetings, and answers. " +
	"Use tools only when the user asks you to perform a task.";

# Meta-agent prompt for activity 0 (the Chief of Staff).
META_PROMPT_PATH: con "/lib/veltro/meta.txt";

# First-run greeting shown by the setup wizard (overridable).
SETUP_GREETING_PATH: con "/lib/veltro/setup-greeting.txt";

# Agent identity (data-driven: the owner can rename the agent without
# code changes).  The harness reads the same files.
AGENT_NAME_PATH: con "/lib/veltro/agent-name";
OS_NAME_PATH: con "/lib/veltro/os-name";
agentname := "Veltro";
osname := "InferNode";

log(msg: string)
{
	if(verbose)
		sys->fprint(stderr, "lucibridge: %s\n", msg);
}

fatal(msg: string)
{
	sys->fprint(stderr, "lucibridge: %s\n", msg);
	raise "fail:" + msg;
}

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

toolctlmount(mpt: string): string
{
	if(mpt == "/tool")
		return "/mnt/toolctl";
	if(len mpt > 6 && mpt[0:6] == "/tool.")
		return "/mnt/toolctl." + mpt[6:];
	return "/mnt/toolctl";
}

# Extract value for key from "key1=val1 key2=val2 ..." string
getkv(line, key: string): string
{
	target := key + "=";
	tlen := len target;
	i := 0;
	while(i <= len line - tlen) {
		if(line[i:i+tlen] == target) {
			# Found key= at position i
			start := i + tlen;
			end := start;
			while(end < len line && line[end] != ' ' && line[end] != '\t')
				end++;
			return line[start:end];
		}
		# Skip to next whitespace-separated token
		while(i < len line && line[i] != ' ' && line[i] != '\t')
			i++;
		while(i < len line && (line[i] == ' ' || line[i] == '\t'))
			i++;
	}
	return "";
}

# Read a field from a simple key=value config file (one per line)
readndbfield(path, field: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	content := string buf[0:n];
	prefix := field + "=";
	plen := len prefix;
	for(i := 0; i < len content; ) {
		# Find end of line
		eol := i;
		while(eol < len content && content[eol] != '\n')
			eol++;
		if(eol - i >= plen && content[i:i+plen] == prefix)
			return content[i+plen:eol];
		i = eol + 1;
	}
	return nil;
}

# Check if the LLM service is actually functional (not just a mntgen stub).
# mntgen auto-creates /mnt/llm as an empty mount point on stat, so pathexists
# always returns true.  Instead, try to open /mnt/llm/new which only exists
# when llmsrv (or a remote llm9p) is actually serving.
llmserviceok(): int
{
	fd := sys->open("/mnt/llm/new", Sys->OREAD);
	if(fd == nil)
		return 0;
	fd = nil;
	return 1;
}

# Register namespace entries from the manifest written by tools9p.
# The manifest reflects the agent's actual restricted namespace — it is
# the single source of truth.  No hardcoded path lists.
registernamespace()
{
	mpath: string;
	if(actid == 0)
		mpath = "/tmp/veltro/.ns/manifest";
	else
		mpath = "/tmp/veltro/.ns/manifest." + string actid;

	ctxpath := sys->sprint("/mnt/ui/activity/%d/context/ctl", actid);
	nreg := 0;

	mdata := agentlib->readfile(mpath);
	if(mdata != "") {
		# Manifest format: path=X label=Y perm=Z (one per line)
		(nil, lines) := sys->tokenize(mdata, "\n");
		for(; lines != nil; lines = tl lines) {
			line := agentlib->strip(hd lines);
			if(line == "")
				continue;
			path := getkv(line, "path");
			label := getkv(line, "label");
			perm := getkv(line, "perm");
			if(path == "")
				continue;
			if(label == "")
				label = path;
			# Classify: /n/* and /dev/* are services/devices, rest are fs
			atype := "fs";
			if(len path > 3 && path[0:3] == "/n/")
				atype = "service";
			else if(len path > 5 && path[0:5] == "/dev/")
				atype = "device";
			cmd := "resource add path=" + path +
				" label=" + label +
				" type=" + atype +
				" status=idle";
			if(perm != "")
				cmd += " via=" + perm;
			if(writefile(ctxpath, cmd) >= 0)
				nreg++;
		}
	} else {
		log("context: manifest not found at " + mpath);
	}

	# Also register speech if available but not already in manifest
	hasspeech := 0;
	if(mdata != "") {
		(nil, sl) := sys->tokenize(mdata, "\n");
		for(; sl != nil; sl = tl sl)
			if(agentlib->hasprefix(hd sl, "path=/n/speech"))
				hasspeech = 1;
	}
	if(!hasspeech) {
		(speechok, nil) := sys->stat("/n/speech");
		if(speechok >= 0) {
			cmd := "resource add path=/n/speech label=Speech type=service status=idle";
			if(writefile(ctxpath, cmd) >= 0)
				nreg++;
		}
	}

	log(sys->sprint("context: registered %d namespace entries", nreg));
}

# Read from a blocking fd, strip trailing newline
blockread(fd: ref Sys->FD): string
{
	buf := array[65536] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := string buf[0:n];
	if(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

# Replace every occurrence of `from` with `to` (for %AGENT% injection).
substall(s, pat, repl: string): string
{
	if(pat == "")
		return s;
	out := "";
	fl := len pat;
	i := 0;
	while(i < len s) {
		if(i + fl <= len s && s[i:i+fl] == pat) {
			out += repl;
			i += fl;
		} else {
			out[len out] = s[i];
			i++;
		}
	}
	return out;
}

writemsg(role, text: string)
{
	path := sys->sprint("/mnt/ui/activity/%d/conversation/ctl", actid);
	msg := "role=" + role + " text=" + text;
	if(writefile(path, msg) < 0)
		sys->fprint(stderr, "lucibridge: write to %s failed: %r\n", path);
	else
		convcount++;
}

# Sync convcount with the server's actual message count.
# Called before a turn to prevent index drift when dialogue tiles
# or other messages are injected externally.
syncconvcount()
{
	base := sys->sprint("/mnt/ui/activity/%d/conversation", actid);
	for(convcount = 0; ; convcount++) {
		(cok, nil) := sys->stat(sys->sprint("%s/%d", base, convcount));
		if(cok < 0)
			break;
	}
}

# Write a dialogue tile to the conversation.
# Returns the message index for later updates (e.g. progress).
writedialogue(title, text, progress, options: string): int
{
	path := sys->sprint("/mnt/ui/activity/%d/conversation/ctl", actid);
	msg := "role=veltro dtype=dialogue";
	if(title != "")
		msg += " title=" + title;
	if(progress != "")
		msg += " progress=" + progress;
	if(options != "")
		msg += " options=" + options;
	msg += " text=" + text;
	if(writefile(path, msg) < 0) {
		sys->fprint(stderr, "lucibridge: writedialogue failed: %r\n");
		return -1;
	}
	idx := convcount;
	convcount++;
	return idx;
}

# Show the first-run LLM setup wizard. Offers five peer options
# (Remote API, Local model, Claude CLI, Codex CLI, Remote 9P), launches
# the right configurator for each, and parks until the user restarts.
#
# The two CLI options are the subscription route: a host-side gateway
# (tools/claude-gate, tools/codex-gate) serving whatever the host's own
# `claude`/`codex` login is, with no API key anywhere. They belong here
# rather than only in Settings — a user who already pays for one of those
# subscriptions should not have to find their way to a config panel to
# discover that pasting an API key isn't the only option.
#
# NOTE: the dialogue returns the clicked LABEL as the choice string, so
# the labels in the option list below and the choice comparisons further
# down MUST stay in sync.  If you rename a button, rename its comparison.
runsetupwizard()
{
	greeting := agentlib->readfile(SETUP_GREETING_PATH);
	if(greeting == nil)
		greeting = "Welcome to InferNode! I'm **Veltro**, your AI agent.\n\n" +
			"I need an LLM connection to get started. Choose an option below:";
	writemsg("veltro", agentlib->strip(greeting));
	writedialogue("LLM Setup",
		"Choose how to connect to an AI model:",
		"", "Remote API,Local model,Claude CLI,Codex CLI,Remote 9P");
	log("displayed LLM setup dialogue");

	pctl := sys->sprint("/mnt/ui/activity/%d/presentation/ctl", actid);
	inputpath := sys->sprint("/mnt/ui/activity/%d/conversation/input", actid);
	for(;;) {
		inputfd := sys->open(inputpath, Sys->OREAD);
		if(inputfd == nil)
			break;
		choice := blockread(inputfd);
		inputfd = nil;
		if(choice == nil)
			break;
		log("setup choice: " + choice);

		if(choice == "Remote API") {
			writefile(pctl, "create id=keyring type=app dis=/dis/wm/keyring.dis label=Keyring");
			sys->sleep(500);
			writefile(pctl, "center id=keyring");
			writemsg("veltro",
				"Keyring is open. Select API Key, enter `anthropic` as the service, paste your key. " +
				"Then close InferNode and relaunch it.");
		} else if(choice == "Local model") {
			# data= must come last (terminal attribute, consumes the
			# remainder of the line). -c llm tells wm/settings to open
			# directly on the LLM Service panel — INFR-100.
			writefile(pctl, "create id=settings type=app dis=/dis/wm/settings.dis label=Settings data=-c llm");
			sys->sleep(500);
			writefile(pctl, "center id=settings");
			writemsg("veltro",
				"Settings is open on **LLM Service**. Keep Mode on Local, choose the Ollama backend, " +
				"and set the URL (e.g. `http://localhost:11434/v1`). " +
				"Then close InferNode and relaunch it.");
		} else if(choice == "Claude CLI" || choice == "Codex CLI") {
			# CLI gateways: no key, the host CLI's own subscription
			# login. emu never starts host daemons, so the wizard can
			# only open Settings and say what has to be running on the
			# host side. `llmctl set <cli>` matches the gate names.
			cli := "claude";
			gate := "claude-gate";
			if(choice == "Codex CLI") {
				cli = "codex";
				gate = "codex-gate";
			}
			writefile(pctl, "create id=settings type=app dis=/dis/wm/settings.dis label=Settings data=-c llm");
			sys->sleep(500);
			writefile(pctl, "center id=settings");
			writemsg("veltro",
				"Settings is open on **LLM Service**. Keep Mode on Local, choose the " +
				"**" + choice + "** backend, and press Apply — no API key is needed, " +
				"it uses your host `" + cli + "` login.\n\n" +
				"On the host: run `" + cli + " login` once if you haven't, and make sure " +
				"the gateway is running (`tools/" + gate + "/serve-" + gate + ".sh`, or " +
				"`llmctl set " + cli + "` where systemd runs it). " +
				"Then close InferNode and relaunch it.");
		} else if(choice == "Remote 9P") {
			writefile(pctl, "create id=settings type=app dis=/dis/wm/settings.dis label=Settings data=-c llm");
			sys->sleep(500);
			writefile(pctl, "center id=settings");
			writemsg("veltro",
				"Settings is open on **LLM Service**. Switch Mode to Remote (9P), and enter the " +
				"dial address (`tcp!host!port`) of an InferNode exporting `/mnt/llm`. " +
				"Then close InferNode and relaunch it.");
		} else {
			# A typed message (not one of the option buttons) before any
			# LLM is configured. Echo it and explain, rather than silently
			# eating it (the symptom: "my message just disappears").
			writemsg("user", choice);
			writemsg("veltro",
				"I'm not connected to an LLM yet, so I can't reply. Choose an option above " +
				"(Remote API / Local model / Claude CLI / Codex CLI / Remote 9P) to set one " +
				"up — or, if you already configured it in Settings, close InferNode and " +
				"relaunch so the change takes effect.");
			continue;	# keep listening; don't park
		}
		# A configurator was opened — park until the user quits and relaunches.
		for(;;)
			sys->sleep(60000);
	}
}

# Update a dialogue tile in-place (e.g. progress bar update).
updatedialogue(idx: int, progress, title, text: string)
{
	path := sys->sprint("/mnt/ui/activity/%d/conversation/ctl", actid);
	msg := "update idx=" + string idx;
	if(progress != "")
		msg += " progress=" + progress;
	if(title != "")
		msg += " title=" + title;
	if(text != "")
		msg += " text=" + text;
	writefile(path, msg);
}

# Read a single user input from the conversation input file (blocking).
readuserinput(): string
{
	path := sys->sprint("/mnt/ui/activity/%d/conversation/input", actid);
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	return blockread(fd);
}

setstatus(status: string)
{
	path := sys->sprint("/mnt/ui/activity/%d/status", actid);
	writefile(path, status);
}

seturgency(level: int)
{
	path := sys->sprint("/mnt/ui/activity/%d/urgency", actid);
	writefile(path, string level);
}

# Update an existing conversation message in place (for streaming token display).
updateliveconvmsg(idx: int, text: string)
{
	path := sys->sprint("/mnt/ui/activity/%d/conversation/ctl", actid);
	msg := "update idx=" + string idx + " text=" + text;
	if(writefile(path, msg) < 0)
		sys->fprint(stderr, "lucibridge: updateliveconvmsg failed: %r\n");
}

# Display welcome.md in the presentation zone on first launch.
# Two-level guard prevents duplicate tabs:
#   1. artifact check  — idempotent within a luciuisrv session (same emu run)
#   2. marker file     — cross-session guard so it only appears once ever
showwelcome(aid: int)
{
	# Idempotent: if the welcome artifact is already showing (e.g. lucibridge
	# restarted inside the same running luciuisrv), do nothing.
	typepath := sys->sprint("/mnt/ui/activity/%d/presentation/welcome/type", aid);
	(atok, nil) := sys->stat(typepath);
	if(atok >= 0)
		return;

	# Cross-session guard.  Use a plain (non-hidden) filename: trfs on some
	# platforms silently fails sys->stat on dot-files, causing the marker to
	# be missed and the welcome to reappear on every launch.
	marker := "/lib/veltro/welcome_shown";
	(ok, nil) := sys->stat(marker);
	if(ok >= 0)
		return;

	wfd := sys->open("/lib/veltro/welcome.md", Sys->OREAD);
	if(wfd == nil)
		return;
	buf := array[65536] of byte;
	n := sys->read(wfd, buf, len buf);
	wfd = nil;
	if(n <= 0)
		return;
	content := string buf[0:n];

	pctl := sys->sprint("/mnt/ui/activity/%d/presentation/ctl", aid);
	writefile(pctl, "create id=welcome type=markdown label=Welcome");
	datapath := sys->sprint("/mnt/ui/activity/%d/presentation/welcome/data", aid);
	writefile(datapath, content);
	writefile(pctl, "center id=welcome");

	fd := sys->create(marker, Sys->OWRITE, 8r644);
	fd = nil;
}

# Offer a guided tour on the second launch (keys configured, first-run done).
# Non-blocking: shows a dialogue tile and returns. Button clicks are handled
# in the main input loop via handletourchoice().
tour_offered := 0;

offertour()
{
	# Only offer once per install — check marker
	marker := "/lib/veltro/tour_offered";
	(ok, nil) := sys->stat(marker);
	if(ok >= 0)
		return;

	# Only offer if first-run is done (welcome was already shown)
	(wok, nil) := sys->stat("/lib/veltro/welcome_shown");
	if(wok < 0)
		return;

	writemsg("veltro",
		"Welcome back! Would you like a quick guided tour of InferNode? " +
		"Or just start chatting — the tour will wait.");
	writedialogue("Guided Tour",
		"I can walk you through the basics: launching apps, using tools, and navigating the workspace.",
		"", "Start Tour,Skip,Don't show again");
	tour_offered = 1;
	log("offered guided tour (non-blocking)");
}

# Handle tour dialogue button clicks. Returns 1 if the input was consumed.
handletourchoice(input: string): int
{
	if(!tour_offered)
		return 0;

	marker := "/lib/veltro/tour_offered";

	if(input == "Start Tour") {
		tour_offered = 0;
		fd := sys->create(marker, Sys->OWRITE, 8r644);
		fd = nil;
		writemsg("veltro",
			"Starting the tour! Check the Tasks tab for the guided walkthrough.");
		if(agentlib->pathexists(toolmount)) {
			result := agentlib->calltool("task",
				"create label=Tour " +
				"tools=read,list,find,search,present,launch,say,gap,memory,exec,editor,fractal,grep " +
				"brief=\"Run an interactive guided tour of InferNode for a new user. " +
				"Read the tour script at /lib/veltro/demos/tour.txt and follow it step by step. " +
				"Demonstrate each feature live using your tools. " +
				"When the script says 'ask', write a message and wait for the user to reply. " +
				"Keep it friendly and concise.\"");
			log("tour task created: " + result);
		}
		return 1;
	}
	if(input == "Skip") {
		tour_offered = 0;
		fd := sys->create(marker, Sys->OWRITE, 8r644);
		fd = nil;
		log("tour skipped");
		return 1;
	}
	if(input == "Don't show again") {
		tour_offered = 0;
		fd := sys->create(marker, Sys->OWRITE, 8r644);
		fd = nil;
		writemsg("veltro", "Got it. You can always say 'run the tour' if you change your mind.");
		log("tour dismissed permanently");
		return 1;
	}

	# Not a tour button — user typed something else. Dismiss the offer
	# silently and let the main loop handle it as normal chat.
	tour_offered = 0;
	fd := sys->create(marker, Sys->OWRITE, 8r644);
	fd = nil;
	return 0;
}

# Find the first Inferno path (starts with /) in tool args.
# Generic — decoupled from which tool is being called or its arg order.
filepathof(args: string): string
{
	(nil, toks) := sys->tokenize(args, " \t\n\"{}:,");
	for(; toks != nil; toks = tl toks) {
		t := hd toks;
		if(len t > 1 && t[0] == '/' && safeattrpath(t))
			return t;
	}
	return nil;
}

# A path is safe as an attribute value when it carries no characters that
# could terminate or inject a key=value field in the ctl line.
safeattrpath(p: string): int
{
	for(i := 0; i < len p; i++) {
		c := p[i];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '=' || c < ' ')
			return 0;
	}
	return 1;
}

# Replace characters that would break a key=value attribute.
safeattrtext(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '=' || c < ' ')
			out[len out] = '_';
		else
			out[len out] = c;
	}
	return out;
}

# Last path component (basename)
pathbase(path: string): string
{
	if(path == nil || path == "")
		return nil;
	while(len path > 1 && path[len path - 1] == '/')
		path = path[0:len path - 1];
	i := len path;
	while(i > 0 && path[i - 1] != '/')
		i--;
	return path[i:];
}

strcontains(l: list of string, name: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == name)
			return 1;
	return 0;
}

# Split a "path [perm]" line into (path, perm).
splitpathperm(s: string): (string, string)
{
	s = agentlib->strip(s);
	(p, rest) := str->splitl(s, " \t");
	rest = str->drop(rest, " \t");
	return (p, rest);
}

# Extract just the paths from "path perm" lines.
extractpaths(lines: list of string): list of string
{
	out: list of string;
	for(; lines != nil; lines = tl lines) {
		(p, nil) := splitpathperm(hd lines);
		if(p != "")
			out = p :: out;
	}
	rev: list of string;
	for(; out != nil; out = tl out)
		rev = hd out :: rev;
	return rev;
}

# Permission of a path in "path perm" lines ("" when absent).
lookuppathperm(lines: list of string, path: string): string
{
	for(; lines != nil; lines = tl lines) {
		(p, perm) := splitpathperm(hd lines);
		if(p == path)
			return perm;
	}
	return "";
}

# Reflect /tool/paths into the context zone.  Diffs against the last-seen
# content; binds new paths into this namespace, unmounts removed ones, and
# pushes resource events so the namespace view updates immediately.  The
# agent's own system prompt follows /tool/paths inside the harness.
applypathchanges()
{
	if(!agentlib->pathexists(toolmount))
		return;
	latest := agentlib->readfile(toolmount + "/paths");
	if(latest == currentpathsraw)
		return;
	(nil, newlines) := sys->tokenize(latest, "\n");
	(nil, oldlines) := sys->tokenize(currentpathsraw, "\n");

	newpaths := extractpaths(newlines);
	oldpaths := extractpaths(oldlines);

	# Paths already under /n/local/ are accessible via the trfs OS mount —
	# no rebind needed (and no writable target would exist anyway).
	# Inferno-native paths (/dis/, /lib/, /mnt/llm/, etc.) are already in the
	# namespace — binding them to /n/local/<base> would fail (no such dir).
	ctxpath := sys->sprint("/mnt/ui/activity/%d/context/ctl", actid);
	for(np := newpaths; np != nil; np = tl np) {
		p := hd np;
		if(p == "" || strcontains(oldpaths, p))
			continue;
		if(len p >= 9 && p[0:9] == "/n/local/") {
			log("path accessible: " + p);
		} else if(agentlib->pathexists(p)) {
			log("path accessible (Inferno-native): " + p);
		} else {
			base := pathbase(p);
			if(base == nil || base == "")
				base = "path";
			tgt := "/n/local/" + base;
			if(sys->bind(p, tgt, Sys->MBEFORE) < 0)
				log("bindpath " + p + ": failed");
			else
				log("bound " + p + " -> " + tgt);
		}
		base := pathbase(p);
		if(base == nil || base == "")
			base = p;
		base = safeattrtext(base);
		writefile(ctxpath, "resource upsert path=" + p +
			" label=" + base + " type=fs status=idle via=bound");
	}

	# Unmount removed paths (only those we actually bound, not /n/local/ pass-throughs)
	for(op := oldpaths; op != nil; op = tl op) {
		p := hd op;
		if(p == "" || strcontains(newpaths, p))
			continue;
		if(!(len p >= 9 && p[0:9] == "/n/local/") && !agentlib->pathexists(p)) {
			base := pathbase(p);
			if(base == nil || base == "")
				base = "path";
			tgt := "/n/local/" + base;
			sys->unmount(nil, tgt);
			log("unbound " + p);
		}
		writefile(ctxpath, "resource remove " + p);
	}

	currentpathsraw = latest;
}

# Handle slash commands from the input channel.
# Returns 1 if the command was handled (don't pass to agent), 0 otherwise.
handleslash(cmd: string): int
{
	if(len cmd == 0 || cmd[0] != '/')
		return 0;
	rest := cmd[1:];
	(verb, afterverb) := str->splitl(rest, " \t");
	cmdarg := str->drop(afterverb, " \t");
	ack := "";
	case verb {
	"bind" =>
		if(cmdarg == "") {
			ack = "usage: /bind <path> [ro|rw]";
		} else {
			ctlcmd := "bindpath " + cmdarg;
			if(writefile(toolctlmount(toolmount) + "/ctl", ctlcmd) != len array of byte ctlcmd) {
				ack = "bind failed: " + cmdarg;
			} else {
				# Push context event so the namespace view updates immediately
				ctxpath := sys->sprint("/mnt/ui/activity/%d/context/ctl", actid);
				base := pathbase(cmdarg);
				if(base == nil || base == "")
					base = cmdarg;
				base = safeattrtext(base);
				writefile(ctxpath, "resource upsert path=" + cmdarg +
					" label=" + base + " type=fs status=idle via=bound");
				ack = "bound: " + cmdarg;
			}
		}
	"unbind" =>
		if(cmdarg == "") {
			ack = "usage: /unbind <path>";
		} else {
			ctlcmd := "unbindpath " + cmdarg;
			if(writefile(toolctlmount(toolmount) + "/ctl", ctlcmd) != len array of byte ctlcmd) {
				ack = "unbind failed: " + cmdarg;
			} else {
				# Push context event so the namespace view updates immediately
				ctxpath := sys->sprint("/mnt/ui/activity/%d/context/ctl", actid);
				writefile(ctxpath, "resource remove " + cmdarg);
				ack = "unbound: " + cmdarg;
			}
		}
	"tools" =>
		if(len cmdarg == 0) {
			ack = "usage: /tools +name or /tools -name";
		} else if(cmdarg[0] == '+') {
			ctlcmd := "add " + cmdarg[1:];
			if(writefile(toolctlmount(toolmount) + "/ctl", ctlcmd) != len array of byte ctlcmd)
				ack = "tool add failed: " + cmdarg[1:];
			else
				ack = "tool added: " + cmdarg[1:];
		} else if(cmdarg[0] == '-') {
			ctlcmd := "remove " + cmdarg[1:];
			if(writefile(toolctlmount(toolmount) + "/ctl", ctlcmd) != len array of byte ctlcmd)
				ack = "tool remove failed: " + cmdarg[1:];
			else
				ack = "tool removed: " + cmdarg[1:];
		} else {
			ack = "usage: /tools +name or /tools -name";
		}
	"voice" =>
		if(cmdarg == "" || cmdarg == "on") {
			autospeak = 1;
			ack = "voice: auto-speak enabled";
		} else if(cmdarg == "off") {
			autospeak = 0;
			ack = "voice: auto-speak disabled";
		} else {
			# Set voice name
			writefile("/n/speech/ctl", "voice " + cmdarg);
			ack = "voice: set to " + cmdarg;
		}
	"diff" =>
		ack = cowdiff();
	"promote" =>
		ack = cowpromote(cmdarg);
	"revert" =>
		ack = cowrevert(cmdarg);
	"help" =>
		ack = "/bind <path>  — add namespace path\n" +
		      "/unbind <path>  — remove namespace path\n" +
		      "/tools +name  — add tool\n" +
		      "/tools -name  — remove tool\n" +
		      "/voice on|off  — toggle auto-speak\n" +
		      "/voice <name>  — change voice\n" +
		      "/diff  — show cowfs changes\n" +
		      "/promote [path]  — promote cowfs changes\n" +
		      "/revert [path]  — revert cowfs changes";
	* =>
		return 0;	# unknown slash: pass to agent
	}
	writemsg("assistant", ack);
	return 1;
}

# --- Cowfs slash command helpers ---

Cowfs: module {
	PATH: con "/dis/veltro/cowfs.dis";
	diff:        fn(overlaydir: string): list of string;
	promote:     fn(basepath, overlaydir: string): (int, string);
	revert:      fn(overlaydir: string): string;
	promotefile: fn(basepath, overlaydir, relpath: string): string;
	revertfile:  fn(overlaydir, relpath: string): string;
};

cowfindoverlay(): string
{
	# Overlay dir is /tmp/veltro/cow/{actid}-*
	prefix := sys->sprint("%d-", actid);
	fd := sys->open("/tmp/veltro/cow", Sys->OREAD);
	if(fd == nil)
		return nil;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			nm := dirs[i].name;
			if(len nm >= len prefix && nm[0:len prefix] == prefix)
				return "/tmp/veltro/cow/" + nm;
		}
	}
	return nil;
}

cowdiff(): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return "error: cannot load cowfs module";
	overlay := cowfindoverlay();
	if(overlay == nil)
		return "no cowfs overlay for this activity";
	changes := cowfs->diff(overlay);
	if(changes == nil)
		return "no changes";
	result := "";
	for(; changes != nil; changes = tl changes) {
		if(result != "")
			result += "\n";
		result += hd changes;
	}
	return result;
}

cowpromote(arg: string): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return "error: cannot load cowfs module";
	overlay := cowfindoverlay();
	if(overlay == nil)
		return "no cowfs overlay for this activity";
	# Read basepath from .cowmeta
	basepath := agentlib->readfile(overlay + "/.cowmeta");
	if(basepath != nil) {
		# Trim trailing whitespace/newlines
		while(len basepath > 0 && (basepath[len basepath - 1] == '\n' || basepath[len basepath - 1] == ' '))
			basepath = basepath[0:len basepath - 1];
	}
	if(basepath == nil || basepath == "")
		return "error: cannot determine base path";
	if(arg != "") {
		err := cowfs->promotefile(basepath, overlay, arg);
		if(err != nil)
			return "error: " + err;
		return "promoted: " + arg;
	}
	(n, err) := cowfs->promote(basepath, overlay);
	if(err != nil)
		return "error: " + err;
	return sys->sprint("promoted %d file(s)", n);
}

cowrevert(arg: string): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return "error: cannot load cowfs module";
	overlay := cowfindoverlay();
	if(overlay == nil)
		return "no cowfs overlay for this activity";
	if(arg != "") {
		err := cowfs->revertfile(overlay, arg);
		if(err != nil)
			return "error: " + err;
		return "reverted: " + arg;
	}
	err := cowfs->revert(overlay);
	if(err != nil)
		return "error: " + err;
	return "all changes reverted";
}

# --- The harness ---

# Start veltrosrv with this activity's grants.  It mounts at /mnt/veltro in
# this namespace (the spawned process shares it) and its init returns; the
# serving process has forked and restricted its own namespace by then.
srvdone: chan of int;

runsrv(srv: VeltroSrv, args: list of string)
{
	srv->init(nil, args);
	srvdone <-= 1;
}

startharness()
{
	srv := load VeltroSrv VeltroSrv->PATH;
	if(srv == nil)
		fatal("cannot load " + VeltroSrv->PATH);
	args: list of string;
	args = "-a" :: sys->sprint("activity=%d", actid) :: args;
	args = "-S" :: sys->sprint("%s/%d", AgentLib->SCRATCH_PATH, actid) :: args;
	args = "-m" :: toolmount :: args;
	args = "-n" :: string maxsteps :: args;
	if(verbose)
		args = "-v" :: args;
	if(toolargs != nil)
		args = "-t" :: join(toolargs, ",") :: args;
	if(pathargs != nil)
		args = "-p" :: join(pathargs, ",") :: args;
	args = "veltrosrv" :: args;

	srvdone = chan of int;
	spawn runsrv(srv, args);
	timeout := chan of int;
	spawn timer(timeout, 20000);
	alt {
	<-srvdone =>
		;
	<-timeout =>
		fatal("veltrosrv did not start");
	}

	sid := agentlib->strip(agentlib->readfile("/mnt/veltro/new"));
	if(sid == "")
		fatal("cannot start an agent session");
	sess = "/mnt/veltro/" + sid;
	log("agent session at " + sess);
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

timer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

ctl(req: string): int
{
	n := writefile(sess + "/ctl", req);
	if(n < 0)
		log(sys->sprint("ctl %s: %r", req));
	return n;
}

# Give the session its role.  Activity 0 is the Chief of Staff (meta.txt);
# a child activity runs the task prompt, or a specific agent type the task
# tool named; BRIDGE_SUFFIX stands in when a file is missing.  The task tool
# may also override the model.  Then the task brief and instructions, as
# <task> and <instructions> in the system prompt.
configuresession(): (string, string)
{
	atype := "";
	if(actid == 0) {
		if(agentlib->readfile(META_PROMPT_PATH) != nil)
			ctl("role meta");
		else
			ctl("brief " + substall(substall(BRIDGE_SUFFIX, "%AGENT%", agentname), "%OS%", osname));
	} else {
		modelname := agentlib->strip(agentlib->readfile(
			sys->sprint("/tmp/veltro/tasks/model.%d", actid)));
		if(modelname != "") {
			if(ctl("model " + modelname) >= 0)
				log("session model set to " + modelname);
			else
				log("session model write failed for " + modelname);
		}
		atype = agentlib->strip(agentlib->readfile(
			sys->sprint("/tmp/veltro/tasks/agenttype.%d", actid)));
		role := "task";
		if(atype != "" && safeagenttype(atype) &&
		   agentlib->readfile("/lib/veltro/agents/" + atype + ".txt") != nil)
			role = atype;
		if(ctl("role " + role) < 0)
			ctl("brief " + substall(substall(BRIDGE_SUFFIX, "%AGENT%", agentname), "%OS%", osname));
	}

	taskbrief := "";
	taskinstr := "";
	if(actid > 0) {
		taskbrief = agentlib->readfile(sys->sprint("/tmp/veltro/tasks/brief.%d", actid));
		if(taskbrief != nil)
			taskbrief = agentlib->strip(taskbrief);
		else
			taskbrief = "";
		taskinstr = agentlib->readfile(sys->sprint("/tmp/veltro/tasks/instructions.%d", actid));
		if(taskinstr != nil)
			taskinstr = agentlib->strip(taskinstr);
		else
			taskinstr = "";
		injection := "";
		if(taskbrief != "")
			injection += "<task>" + taskbrief + "</task>";
		if(taskinstr != "")
			injection += "\n\n<instructions>" + taskinstr + "</instructions>";
		if(injection != "") {
			ctl("brief " + injection);
			log("injected task brief into system prompt: " + agentlib->truncate(taskbrief, 100));
			if(taskinstr != "")
				log("injected instructions: " + agentlib->truncate(taskinstr, 100));
		}
	}
	return (taskbrief, taskinstr);
}

# --- One turn: the agent's files, rendered into the UI ---

# Shared between the followers of one turn.
placeholder := -1;		# the ▌ bubble shown while the first reply is awaited
placeholderused := 0;
curstep := 0;

# Follow text from offset until the session goes idle, rendering each
# message as it arrives: the first reply of a turn fills the placeholder,
# later ones get their own bubble, titled notes become dialogue tiles.
textfollow(done: chan of int)
{
	fd := sys->open(sess + "/text", Sys->OREAD);
	if(fd == nil) {
		done <-= 1;
		return;
	}
	buf := array[8192] of byte;
	offset := big 0;
	# Skip what was there before this turn.
	(ok, d) := sys->fstat(fd);
	if(ok >= 0)
		offset = d.length;

	role := "";		# of the message being received
	title := "";
	body := "";
	idx := -1;		# conversation index of the live bubble
	atline := 1;
	held := "";		# a possible header, held until it is known
	for(;;) {
		n := sys->pread(fd, buf, len buf, offset);
		if(n <= 0)
			break;
		offset += big n;
		chunk := string buf[0:n];
		changed := 0;
		for(i := 0; i < len chunk; i++) {
			c := chunk[i];
			if(held != "" || (atline && c == '=')) {
				held[len held] = c;
				if(c == '\n') {
					if(len held > 3 && held[0:3] == "== ") {
						# A header: finish the message in hand.
						endmessage(role, title, body, idx);
						(role, title) = splitheader(held[3:len held - 1]);
						body = "";
						idx = beginmessage(role, title);
						changed = 0;
					} else {
						body += held;
						changed = 1;
					}
					held = "";
					atline = 1;
				} else if(len held <= 3 && held != "== "[0:len held]) {
					body += held;
					held = "";
					changed = 1;
					atline = 0;
				}
				continue;
			}
			body[len body] = c;
			changed = 1;
			atline = c == '\n';
		}
		if(changed && idx >= 0)
			updateliveconvmsg(idx, trimnl(body));
	}
	if(held != "")
		body += held;
	endmessage(role, title, body, idx);
	done <-= 1;
}

splitheader(h: string): (string, string)
{
	(role, rest) := str->splitl(h, " ");
	return (role, str->drop(rest, " "));
}

trimnl(s: string): string
{
	while(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

# A message starts: the bubble it will stream into, or -1 for one that is
# shown whole at its end (notes, and the user's own words, already shown).
# The first streamed reply of a turn fills the placeholder; a say, which
# the loop delivers whole, always gets its own bubble.
beginmessage(role, title: string): int
{
	if(role != "veltro")
		return -1;
	if(title != "say" && placeholder >= 0 && !placeholderused && curstep <= 1) {
		placeholderused = 1;
		return placeholder;
	}
	writemsg("veltro", "");
	return convcount - 1;
}

endmessage(role, title, body: string, idx: int)
{
	body = trimnl(body);
	case role {
	"veltro" =>
		if(idx >= 0)
			updateliveconvmsg(idx, body);
	"note" =>
		if(title != "") {
			writedialogue(title, body, "", "");
			if(title == "Agent stuck")
				seturgency(1);
		} else
			writemsg("veltro", body);
	}
}

# Follow the log: echo it under our prefix (the trajectory grind scores),
# and keep status and the context zone in step with the tools.
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
	ctxpath := sys->sprint("/mnt/ui/activity/%d/context/ctl", actid);
	curtool := "";
	curpath := "";
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
			log(line);
			if(agentlib->hasprefix(line, "step ") && agentlib->contains(line, ": writing ")) {
				(stepno, nil) := str->toint(line[5:], 10);
				curstep = stepno;
				# A tool-only first step leaves the placeholder empty:
				# clear it rather than show a stale cursor.
				if(curstep >= 2 && placeholder >= 0 && !placeholderused) {
					placeholderused = 1;
					updateliveconvmsg(placeholder, "");
				}
			} else if(agentlib->hasprefix(line, "tool ")) {
				(nm, rest2) := str->splitl(line[5:], ":");
				nm = str->tolower(nm);
				if(agentlib->hasprefix(rest2, ": args ")) {
					curtool = nm;
					curpath = filepathof(rest2[7:]);
					writefile(ctxpath, "resource activity " + nm);
					writefile(ctxpath, "resource update path=" + nm + " status=active");
					log("context: active " + nm);
					if(curpath != nil) {
						base := safeattrtext(pathbase(curpath));
						ftype := "file";
						if(curpath[len curpath - 1] == '/')
							ftype = "dir";
						writefile(ctxpath, "resource upsert path=" + curpath +
							" label=" + base + " type=" + ftype +
							" via=" + nm + " status=active");
						log("context: file " + curpath + " via " + nm);
					}
				} else if(agentlib->hasprefix(rest2, ": calling")) {
					setstatus(nm);
				} else if(agentlib->hasprefix(rest2, ": done")) {
					setstatus("working");
					writefile(ctxpath, "resource update path=" + nm + " status=idle");
					if(nm == curtool && curpath != nil)
						writefile(ctxpath, "resource update path=" + curpath + " status=idle");
				}
			} else if(agentlib->hasprefix(line, "pretool: awaiting")) {
				setstatus("blocked");
				seturgency(2);
			} else if(agentlib->hasprefix(line, "pretool: user responded")) {
				setstatus("working");
				seturgency(0);
			}
		}
	}
	done <-= 1;
}

# Answer the agent's requests for approval with a dialogue tile.
approver(done: chan of int)
{
	for(;;) {
		fd := sys->open(sess + "/approve", Sys->OREAD);
		if(fd == nil)
			break;
		req := blockread(fd);
		fd = nil;
		if(req == nil)
			break;		# the turn is over
		(callid, rest) := str->splitl(req, " ");
		rest = str->drop(rest, " ");
		didx := writedialogue("Permission required", rest, "", "Allow,Deny");
		response := readuserinput();
		answer := "allow";
		if(response == "Deny" || response == "deny" || response == "no")
			answer = "deny";
		writefile(sess + "/approve", answer + " " + callid);
		if(didx >= 0) {
			if(answer == "deny")
				updatedialogue(didx, "", "Denied", "");
			else
				updatedialogue(didx, "", "Allowed", "");
		}
	}
	done <-= 1;
}

# Run the agent for one human turn.
agentturn(input: string)
{
	# Sync convcount with actual server message count before streaming.
	syncconvcount();

	# Apply any namespace path changes (via /tool/ctl bindpath/unbindpath).
	applypathchanges();

	setstatus("working");
	placeholder = -1;
	placeholderused = 0;
	curstep = 0;

	if(writefile(sess + "/input", input) < 0) {
		writemsg("veltro", sys->sprint("(the agent is unavailable: %r)"));
		setstatus("idle");
		return;
	}
	# Show activity at once: a cursor while the first reply is awaited.
	placeholder = convcount;
	writemsg("veltro", "▌");

	done := chan of int;
	spawn textfollow(done);
	spawn logfollow(done);
	spawn approver(done);
	<-done;
	<-done;
	<-done;

	if(placeholder >= 0 && !placeholderused)
		updateliveconvmsg(placeholder, "");

	# For spawned tasks (actid > 0), signal the user only for the initial
	# autonomous turn.  Once the user has sent a message, further
	# completions don't raise urgency — the user is already engaged.
	# "complete" tells the MA this TA finished its autonomous assignment.
	if(actid > 0 && !userinteracted)
		setstatus("complete");
	else
		setstatus("idle");
	if(actid > 0 && !userinteracted)
		seturgency(1);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	str = load String String->PATH;
	if(str == nil)
		fatal("cannot load String");

	arg = load Arg Arg->PATH;
	if(arg == nil)
		fatal("cannot load Arg");

	agentlib = load AgentLib AgentLib->PATH;
	if(agentlib == nil)
		fatal("cannot load agentlib: " + AgentLib->PATH);
	agentlib->init();

	an := agentlib->readfile(AGENT_NAME_PATH);
	if(an != nil) {
		an = agentlib->strip(an);
		if(an != "")
			agentname = an;
	}
	on := agentlib->readfile(OS_NAME_PATH);
	if(on != nil) {
		on = agentlib->strip(on);
		if(on != "")
			osname = on;
	}

	arg->init(args);
	while((c := arg->opt()) != 0) {
		case c {
		'v' =>
			verbose = 1;
		's' =>
			autospeak = 1;
		'n' =>
			s := arg->arg();
			if(s == nil)
				fatal("-n requires step count");
			(maxsteps, nil) = str->toint(s, 10);
			if(maxsteps < 1)
				maxsteps = 1;
			if(maxsteps > MAX_MAX_STEPS)
				maxsteps = MAX_MAX_STEPS;
		'a' =>
			s := arg->arg();
			if(s == nil)
				fatal("-a requires activity ID");
			(actid, nil) = str->toint(s, 10);
		't' =>
			s := arg->arg();
			if(s == nil)
				fatal("-t requires tool list");
			(nil, toolargs) = sys->tokenize(s, ",");
		'p' =>
			s := arg->arg();
			if(s == nil)
				fatal("-p requires path list");
			(nil, pathargs) = sys->tokenize(s, ",");
		* =>
			sys->fprint(stderr,
				"usage: lucibridge [-v] [-s] [-n maxsteps] [-a actid] [-t tools] [-p paths]\n");
			raise "fail:usage";
		}
	}

	agentlib->setverbose(verbose);

	# Set tools9p mount point based on activity ID
	if(actid > 0)
		toolmount = "/tool." + string actid;
	agentlib->settoolmount(toolmount);

	# Verify prerequisites
	if(sys->open("/mnt/ui/ctl", Sys->OREAD) == nil)
		fatal("/mnt/ui/ not mounted — start luciuisrv first");
	# Check LLM configuration — two distinct failure modes:
	#   1. Nothing configured: no API key, no Ollama → prompt to configure
	#   2. Configured but unreachable: key exists but service down → different message
	mode := readndbfield("/lib/ndb/llm", "mode");
	if(mode == nil || mode == "")
		mode = "local";
	backend := readndbfield("/lib/ndb/llm", "backend");
	if(backend == nil || backend == "")
		backend = "api";
	dial := readndbfield("/lib/ndb/llm", "dial");
	llmconfigured := 0;
	if(mode == "remote") {
		# Remote 9P mount: configured iff a dial address is set.
		# The actual reachability check happens via llmserviceok() below.
		if(dial != nil && dial != "")
			llmconfigured = 1;
	} else if(backend == "api") {
		# Check factotum for an anthropic API key
		ctldata := agentlib->readfile("/mnt/factotum/ctl");
		if(ctldata != nil && len ctldata > 0) {
			(nil, ctllines) := sys->tokenize(ctldata, "\n");
			for(; ctllines != nil; ctllines = tl ctllines) {
				(nil, found) := str->splitstrl(hd ctllines, "service=anthropic");
				if(found != nil)
					llmconfigured = 1;
			}
		}
	} else if(backend == "openai" || backend == "cli" || backend == "codex") {
		# Ollama/OpenAI, or a CLI gateway (claude-gate backend=cli,
		# codex-gate backend=codex — both OpenAI-shaped on localhost):
		# configured if a URL is set
		ourl := readndbfield("/lib/ndb/llm", "url");
		if(ourl != nil && ourl != "")
			llmconfigured = 1;
	}

	if(!llmconfigured) {
		# Nothing configured — show the wizard. It blocks until the
		# user picks an option and then parks until quit-and-relaunch.
		runsetupwizard();
		fatal("/mnt/llm/ not mounted — configure an LLM and restart");
	} else if(!llmserviceok()) {
		# Failure mode 2: Configured but LLM not ready yet.
		# llmsrv may still be starting — retry a few times before giving up.
		log("llm configured but not ready, waiting...");
		for(retry := 0; retry < 5; retry++) {
			sys->sleep(2000);
			if(llmserviceok()) {
				log("llm service came up after retry");
				break;
			}
		}
		if(!llmserviceok()) {
			if(mode == "remote")
				writemsg("veltro",
					"Remote LLM at " + dial + " is configured, but I can't reach it. " +
					"Check that the remote InferNode is running and llmsrv is exporting via 9P, " +
					"then close InferNode and relaunch it.");
			else if(backend == "api")
				writemsg("veltro",
					"Your API key is configured, but llmsrv didn't come up. " +
					"Common causes: an invalid key, blocked network access to api.anthropic.com, " +
					"or a startup error logged at /tmp/lucibridge.log. " +
					"Open Settings → LLM Service, then close InferNode and relaunch it.");
			else if(backend == "cli")
				writemsg("veltro",
					"The Claude CLI gateway is configured, but I can't reach it. " +
					"Start it on the host (tools/claude-gate/serve-claude-gate.sh, " +
					"or `llmctl set claude` where systemd runs it), " +
					"then close InferNode and relaunch it.");
			else if(backend == "codex")
				writemsg("veltro",
					"The Codex CLI gateway is configured, but I can't reach it. " +
					"Start it on the host (tools/codex-gate/serve-codex-gate.sh, " +
					"or `llmctl set codex` where systemd runs it), " +
					"then close InferNode and relaunch it.");
			else
				writemsg("veltro",
					"Your Ollama server is configured, but I can't reach it. " +
					"Make sure Ollama is running and close InferNode and relaunch it.");
			writedialogue("LLM Unreachable",
				"The LLM service is configured but not responding.",
				"", "Open Settings");
			inputpath := sys->sprint("/mnt/ui/activity/%d/conversation/input", actid);
			for(;;) {
				inputfd := sys->open(inputpath, Sys->OREAD);
				if(inputfd == nil) break;
				choice := blockread(inputfd);
				inputfd = nil;
				if(choice == nil) break;
				if(choice == "Open Settings") {
					pctl := sys->sprint("/mnt/ui/activity/%d/presentation/ctl", actid);
					# Open directly on the LLM Service panel (INFR-100).
					writefile(pctl, "create id=settings type=app dis=/dis/wm/settings.dis label=Settings data=-c llm");
					sys->sleep(500);
					writefile(pctl, "center id=settings");
					writemsg("veltro", "Settings is open on **LLM Service**. Check your LLM configuration, then restart.");
				} else {
					# A typed message while the LLM is unreachable: echo it
					# and explain, instead of silently eating it.
					writemsg("user", choice);
					writemsg("veltro",
						"I still can't reach the LLM, so I can't reply yet. Check the dial " +
						"address and that the remote is running, then close InferNode and " +
						"relaunch — or tap Open Settings above.");
					continue;	# keep listening; don't park
				}
				for(;;) sys->sleep(60000);
			}
			fatal("/mnt/llm/ not mounted — LLM service unreachable");
		}
	}

	# Tools are optional — the agent works as a chat relay without them
	if(agentlib->pathexists(toolmount))
		log("tools available at " + toolmount);
	else
		log("no " + toolmount + " mount — running in chat-only mode");

	# The agent: its own server, with this activity's grants (-t, -p).
	startharness();
	(taskbrief, taskinstr) := configuresession();

	# Show welcome document on first launch
	showwelcome(actid);

	# Offer guided tour on second launch (keys configured, not first boot)
	if(actid == 0)
		offertour();

	# Sync convcount with messages already in the conversation.
	syncconvcount();

	# Bind any paths already registered in /tool/paths (e.g. from -p flag)
	currentpathsraw = "";
	applypathchanges();

	# Register each available tool as a context resource so the context zone
	# can display and track which tools the agent is using.
	nreg := 0;
	if(agentlib->pathexists(toolmount)) {
		(nil, tls) := sys->tokenize(agentlib->readfile(toolmount + "/tools"), "\n");
		for(t := tls; t != nil; t = tl t) {
			nm := str->tolower(hd t);
			if(nm == "say")
				continue;
			r := writefile(sys->sprint("/mnt/ui/activity/%d/context/ctl", actid),
				"resource add path=" + nm + " label=" + hd t + " type=tool status=idle");
			if(r >= 0)
				nreg++;
		}
	}
	log(sys->sprint("context: registered %d tools as resources", nreg));

	# Register speech resource if speech9p is available
	if(autospeak) {
		ctxpath := sys->sprint("/mnt/ui/activity/%d/context/ctl", actid);
		writefile(ctxpath, "resource add path=speech label=Speech type=tool status=idle");
		log("context: registered speech resource");
	}

	# Register namespace entries (services, devices, filesystems) as resources
	registernamespace();

	inputpath := sys->sprint("/mnt/ui/activity/%d/conversation/input", actid);

	log(sys->sprint("ready — activity %d, session %s, max %d steps, %d existing msgs",
		actid, sess, maxsteps, convcount));

	# Autonomous first turn for TAs. The brief/instructions are already in the
	# system prompt inside <task>/<instructions> tags, but a content-free
	# trigger ("Begin.") leaves the actual assignment buried in the system
	# message — weaker models then reply conversationally ("what should I do?")
	# instead of acting. So we restate the assignment as the first user turn:
	# the model sees its concrete task as the latest message and starts work.
	# This turn is NOT recorded with writemsg(), so it is invisible in the UI;
	# only the agent's response is shown. Fires on brief OR instructions so an
	# instructions-only task still auto-starts.
	if(taskbrief != "" || taskinstr != "") {
		kickoff := "You have been started automatically to carry out an assigned task.";
		if(taskbrief != "")
			kickoff += "\n\nYour assignment:\n" + taskbrief;
		if(taskinstr != "")
			kickoff += "\n\nSpecific instructions:\n" + taskinstr;
		kickoff += "\n\nBegin now. Work autonomously with your tools. Do not greet " +
			"or ask what to do — you already have your assignment above. If you " +
			"genuinely cannot proceed without a specific missing detail, ask one " +
			"concise clarifying question; otherwise make a reasonable assumption " +
			"and proceed.";
		agentturn(kickoff);
	}

	# Main loop: re-open input fd each iteration because 9P offset
	# advances after read, causing subsequent reads to return EOF.
	for(;;) {
		inputfd := sys->open(inputpath, Sys->OREAD);
		if(inputfd == nil)
			fatal("cannot open " + inputpath);
		human := blockread(inputfd);
		inputfd = nil;
		if(human == nil) {
			log("input closed");
			break;
		}
		log("human: " + human);

		# Slash commands (/bind, /unbind, /tools, /help) are handled locally.
		# They update tools9p state and reply immediately; agent is not invoked.
		if(handleslash(human))
			continue;

		# Tour dialogue button clicks (non-blocking — user can also just chat)
		if(handletourchoice(human))
			continue;

		# Record human message in UI
		writemsg("human", human);
		# Revert "complete" → "idle" once the human engages this TA.
		if(!userinteracted)
			setstatus("idle");
		userinteracted = 1;

		# Run agent turn
		agentturn(human);
	}
}

# Guard against path traversal in /tmp/veltro/tasks/agenttype.<id> contents. The
# agenttype is used unsanitised as a path component when opening the prompt
# file, so we restrict it to bare lowercase identifiers.
safeagenttype(t: string): int
{
	if(t == "" || len t > 32)
		return 0;
	for(i := 0; i < len t; i++) {
		c := t[i];
		if(!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
			return 0;
	}
	return 1;
}

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
include "nsconstruct.m";
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

# A task agent's report to activity 0 when it has finished its assignment,
# written to activity 0's input (luciuisrv queues it behind a turn in
# progress).  Activity 0 takes it as a turn of its own, not as words from
# the human, and tells the human the outcome: it delegates and goes back to
# the conversation, instead of polling task status in a loop the human can
# neither see the end of nor interrupt.
TASKEVENT: con "[task-event] ";
# A message arrived (msgwatch, with its triage policy): a turn for the agent,
# shown to the user as a short notice, never as the user's own words.
MSGEVENT: con "[message-event] ";
TASKEVENT_MAX: con 7600;	# the whole event: one 9P write (msize 8K) is one message
TASKEVENT_FILEMAX: con 3500;	# bytes of the task's files carried in the event

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
			if(agentlib->hasprefix(hd sl, "path=/mnt/speech"))
				hasspeech = 1;
	}
	if(!hasspeech) {
		(speechok, nil) := sys->stat("/mnt/speech");
		if(speechok >= 0) {
			cmd := "resource add path=/mnt/speech label=Speech type=service status=idle";
			if(writefile(ctxpath, cmd) >= 0)
				nreg++;
		}
	}

	log(sys->sprint("context: registered %d namespace entries", nreg));
}

# Read one message from a blocking fd (it may take several reads: a read
# is at most msize), strip trailing newline
blockread(fd: ref Sys->FD): string
{
	buf := array[65536] of byte;
	got := array[0] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		nb := array[len got + n] of byte;
		nb[0:] = got;
		nb[len got:] = buf[0:n];
		got = nb;
	}
	if(len got == 0)
		return nil;
	s := string got;
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

# Messages are written from several processes in a turn (the reply as it
# streams, the user's words as they come); each takes the next index, and
# the lock keeps two from taking the same one.
convlock: chan of int;

# Write a message; its index, or -1.
writemsg(role, text: string): int
{
	return writeconv("role=" + role + " text=" + text);
}

writeconv(msg: string): int
{
	path := sys->sprint("/mnt/ui/activity/%d/conversation/ctl", actid);
	if(convlock == nil)
		convlock = chan[1] of int;
	convlock <-= 1;
	idx := -1;
	if(writefile(path, msg) < 0)
		sys->fprint(stderr, "lucibridge: write to %s failed: %r\n", path);
	else
		idx = convcount++;
	<-convlock;
	return idx;
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
	msg := "role=veltro dtype=dialogue";
	if(title != "")
		msg += " title=" + title;
	if(progress != "")
		msg += " progress=" + progress;
	if(options != "")
		msg += " options=" + options;
	msg += " text=" + text;
	idx := writeconv(msg);
	if(idx < 0)
		sys->fprint(stderr, "lucibridge: writedialogue failed\n");
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

# The activity's input is read by one process for the agent's life, so
# what the user types while a turn runs is seen at once: /stop stops the
# turn, an answer goes to the dialogue that asked, anything else is shown
# and kept for after the turn.  Read only between turns, it sat unseen
# until the turn ended, and nothing could stop a turn.
inputc: chan of string;		# nil once the input is closed
answerc: chan of string;		# a dialogue's answer, while one is awaited
awaiting := 0;
Queued: adt {
	text:	string;
	shown:	int;		# already shown as the human's
};
queued: list of ref Queued;
inputclosed := 0;

inputreader()
{
	path := sys->sprint("/mnt/ui/activity/%d/conversation/input", actid);
	for(;;) {
		fd := sys->open(path, Sys->OREAD);
		if(fd == nil) {
			inputc <-= nil;
			return;
		}
		m := blockread(fd);
		fd = nil;
		inputc <-= m;
		if(m == nil)
			return;
	}
}

# The next input: one that came during a turn first, in order.
nextinput(): (string, int)
{
	if(queued != nil) {
		q := hd queued;
		queued = tl queued;
		return (q.text, q.shown);
	}
	if(inputclosed)
		return (nil, 0);
	m := <-inputc;
	if(m == nil)
		inputclosed = 1;
	return (m, 0);
}

# Input that came while a turn ran.
turninput(m: string)
{
	if(m == nil) {
		inputclosed = 1;
		ctl("cancel");
		return;
	}
	if(awaiting) {
		answerc <-= m;
		return;
	}
	if(m == "/stop") {
		log("human: /stop");
		ctl("cancel");
		writemsg("veltro", "(stopping)");
		return;
	}
	shown := 0;
	if(!agentlib->hasprefix(m, TASKEVENT) && !agentlib->hasprefix(m, MSGEVENT) &&
	   (len m == 0 || m[0] != '/')) {
		writemsg("human", m);
		shown = 1;
	}
	r: list of ref Queued;
	for(l := queued; l != nil; l = tl l)
		r = hd l :: r;
	r = ref Queued(m, shown) :: r;
	queued = nil;
	for(; r != nil; r = tl r)
		queued = hd r :: queued;
}

# An answer to a dialogue, during a turn.
readuserinput(): string
{
	awaiting = 1;
	r := <-answerc;
	awaiting = 0;
	return r;
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
			writefile("/mnt/speech/ctl", "voice " + cmdarg);
			ack = "voice: set to " + cmdarg;
		}
	"diff" =>
		ack = cowdiff();
	"promote" =>
		ack = cowpromote(cmdarg);
	"revert" =>
		ack = cowrevert(cmdarg);
	"kept" =>
		(nil, w) := sys->tokenize(cmdarg, " ");
		if(w == nil)
			ack = keptlist();
		else if(tl w != nil && (hd w == "apply" || hd w == "discard"))
			ack = keptdo(hd w, int hd tl w);
		else
			ack = "usage: /kept, /kept apply <n>, /kept discard <n>";
	"help" =>
		ack = "/stop  — stop what the agent is doing (type it while it works)\n" +
		      "/bind <path>  — add namespace path\n" +
		      "/unbind <path>  — remove namespace path\n" +
		      "/tools +name  — add tool\n" +
		      "/tools -name  — remove tool\n" +
		      "/voice on|off  — toggle auto-speak\n" +
		      "/voice <name>  — change voice\n" +
		      "/diff  — show cowfs changes\n" +
		      "/promote [path]  — promote cowfs changes\n" +
		      "/revert [path]  — revert cowfs changes\n" +
		      "/kept [apply|discard <n>]  — changes from an earlier session, not applied";
	* =>
		return 0;	# unknown slash: pass to agent
	}
	# As the agent's: luciuisrv takes no "assistant" role, and every slash
	# command's answer (/help, /bind, /promote, ...) was refused and lost.
	writemsg("veltro", ack);
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

# The overlays an activity stages its changes in, one for each folder it
# may write: /tmp/veltro/cow/<actid>-<key of the folder>.  Only the first
# was found, so a task given two folders had the changes to one of them
# reported, promoted and reverted, and the other's left behind.
cowoverlays(prefix: string): list of string
{
	fd := sys->open("/tmp/veltro/cow", Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of string;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			nm := dirs[i].name;
			if(len nm >= len prefix && nm[0:len prefix] == prefix)
				l = "/tmp/veltro/cow/" + nm :: l;
		}
	}
	return l;
}

myoverlays(): list of string
{
	return cowoverlays(sys->sprint("%d-", actid));
}

# An overlay's changes as lines, each with the folder it is in.
overlaychanges(cowfs: Cowfs, overlay: string): list of string
{
	base := cowbasepath(overlay);
	out: list of string;
	for(c := cowfs->diff(overlay); c != nil; c = tl c) {
		l := hd c;
		if(base != nil && len l > 2 && l[1] == ' ')
			l = l[0:2] + base + "/" + l[2:];
		out = l :: out;
	}
	return revl(out);
}

revl(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

cowdiff(): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return "error: cannot load cowfs module";
	ovs := myoverlays();
	if(ovs == nil)
		return "no cowfs overlay for this activity";
	result := "";
	for(; ovs != nil; ovs = tl ovs)
		for(c := overlaychanges(cowfs, hd ovs); c != nil; c = tl c) {
			if(result != "")
				result += "\n";
			result += hd c;
		}
	if(result == "")
		return "no changes";
	return result;
}

# The overlay a file named for /promote or /revert is in: by its full path
# (under a folder's base), or by a path in the folder (the only overlay).
cowfilein(ovs: list of string, arg: string): (string, string)
{
	for(o := ovs; o != nil; o = tl o) {
		base := cowbasepath(hd o);
		if(base != nil && agentlib->hasprefix(arg, base + "/"))
			return (hd o, arg[len base + 1:]);
	}
	if(len ovs == 1 && arg != "" && arg[0] != '/')
		return (hd ovs, arg);
	return (nil, nil);
}

cowpromote(arg: string): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return "error: cannot load cowfs module";
	ovs := myoverlays();
	if(ovs == nil)
		return "no cowfs overlay for this activity";
	if(arg != "") {
		(overlay, rel) := cowfilein(ovs, arg);
		if(overlay == nil)
			return "error: " + arg + " is not in a folder this activity changed";
		err := cowfs->promotefile(cowbasepath(overlay), overlay, rel);
		if(err != nil)
			return "error: " + err;
		return "promoted: " + arg;
	}
	total := 0;
	conflicts := "";
	for(; ovs != nil; ovs = tl ovs) {
		basepath := cowbasepath(hd ovs);
		if(basepath == nil)
			return "error: cannot determine base path of " + hd ovs;
		(n, err) := cowfs->promote(basepath, hd ovs);
		total += n;
		if(err != nil && agentlib->hasprefix(err, "not applied"))
			conflicts += sys->sprint("\n%s (in %s)", err, basepath);
		else if(err != nil)
			return sys->sprint("error: %s (%d file(s) promoted)", err, total);
	}
	if(conflicts != "")
		return sys->sprint("promoted %d file(s), but not all:%s\n" +
			"Those files were changed after this task copied them, so its version would " +
			"undo that; the file is as it was and the task's change stays staged.  To have " +
			"it made on the current file: \"task revert %d\", then ask task %d to make " +
			"its change again.", total, conflicts, actid, actid);
	return sys->sprint("promoted %d file(s)", total);
}

# The folder an overlay stages changes for: the basepath= line of its
# .cowmeta.  The whole file used to be taken for the path, so a promote
# wrote "basepath=/n/local/..." relative to wherever it ran, and saved that
# as the base, doubling the prefix.  Only an absolute path is a base.
cowbasepath(overlay: string): string
{
	(nil, lines) := sys->tokenize(agentlib->readfile(overlay + "/.cowmeta"), "\n");
	for(; lines != nil; lines = tl lines) {
		v := agentlib->strip(hd lines);
		if(!agentlib->hasprefix(v, "basepath="))
			continue;
		while(agentlib->hasprefix(v, "basepath="))
			v = v[len "basepath=":];
		if(len v > 1 && v[0] == '/')
			return v;
	}
	return nil;
}

cowrevert(arg: string): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return "error: cannot load cowfs module";
	ovs := myoverlays();
	if(ovs == nil)
		return "no cowfs overlay for this activity";
	if(arg != "") {
		(overlay, rel) := cowfilein(ovs, arg);
		if(overlay == nil)
			return "error: " + arg + " is not in a folder this activity changed";
		err := cowfs->revertfile(overlay, rel);
		if(err != nil)
			return "error: " + err;
		return "reverted: " + arg;
	}
	for(; ovs != nil; ovs = tl ovs) {
		err := cowfs->revert(hd ovs);
		if(err != nil)
			return "error: " + err;
	}
	return "all changes reverted";
}

# Changes a task staged and the user neither applied nor discarded before
# InferNode quit are kept (nsconstruct names their overlay kept-...), not
# applied, not lost.  Activity 0 offers them back at start, as Acme's Load
# brings back what was open: each with Apply and Discard, the agent told so
# it can answer for them.  Left unanswered, they are offered again next time.
kept: list of (int, string, int);	# (number, overlay, dialogue)
keptnote := "";				# for the agent, with the first message

offerkept()
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return;
	# This start's tasks have none yet: an overlay named for an activity is
	# an earlier start's, until it is set aside when a task of this one is
	# given the folder.  Set aside now, so its changes are offered.
	ns := load NsConstruct NsConstruct->PATH;
	if(ns != nil)
		for(ovs := cowoverlays(""); ovs != nil; ovs = tl ovs)
			if(!agentlib->hasprefix(hd ovs, "/tmp/veltro/cow/kept-"))
				ns->setasidestale(hd ovs);
	n := 0;
	about := "";
	for(ovs = revl(cowoverlays("kept-")); ovs != nil; ovs = tl ovs) {
		changes := overlaychanges(cowfs, hd ovs);
		if(changes == nil)
			continue;
		if(n == 0)
			writemsg("veltro", "Some changes a task made in your files last time were never applied. " +
				"They are kept as they were: apply or discard each below, or leave them for later.");
		n++;
		text := "";
		for(c := changes; c != nil; c = tl c)
			text += hd c + "\n";
		text = agentlib->strip(text);
		didx := writedialogue(sys->sprint("Not applied, from your last session (%d)", n),
			text, "", sys->sprint("Apply %d,Discard %d", n, n));
		kept = (n, hd ovs, didx) :: kept;
		about += sys->sprint("  %d: %s\n", n, agentlib->strip(text));
	}
	if(n == 0)
		return;
	keptnote = "[Changes a task staged to the user's files in an earlier session were never applied " +
		"nor discarded; the user is shown each with Apply and Discard. They are:\n" + about +
		"Only the user applies or discards them (the buttons, or typing /kept apply <n> or " +
		"/kept discard <n>); you cannot. Mention them if it helps the user.]\n\n";
	log(sys->sprint("offered %d kept change set(s)", n));
}

# Apply or discard kept change set n.  Returns what happened.
keptdo(verb: string, n: int): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return "error: cannot load cowfs module";
	rest: list of (int, string, int);
	result := "";
	for(l := kept; l != nil; l = tl l) {
		(k, overlay, didx) := hd l;
		if(k != n) {
			rest = hd l :: rest;
			continue;
		}
		base := cowbasepath(overlay);
		if(verb == "apply") {
			if(base == nil)
				return "error: cannot determine the folder of these changes";
			(nf, err) := cowfs->promote(base, overlay);
			if(err != nil && agentlib->hasprefix(err, "not applied"))
				return sys->sprint("applied %d file(s) to %s, but %s: those files were changed " +
					"since, and these changes would undo that. Discard %d drops them.", nf, base, err, n);
			if(err != nil)
				return "error: " + err;
			result = sys->sprint("applied %d file(s) to %s", nf, base);
			updatedialogue(didx, "", sys->sprint("Applied (%d)", n), "");
		} else {
			err := cowfs->revert(overlay);
			if(err != nil)
				return "error: " + err;
			result = "discarded the changes to " + base;
			updatedialogue(didx, "", sys->sprint("Discarded (%d)", n), "");
		}
		sys->remove(overlay + "/.cowmeta");
		sys->remove(overlay);
	}
	if(result == "")
		return sys->sprint("no kept changes numbered %d", n);
	kept = rest;
	if(kept == nil)
		keptnote = "";
	return result;
}

keptlist(): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(kept == nil || cowfs == nil)
		return "no changes kept from an earlier session";
	out := "";
	for(l := kept; l != nil; l = tl l) {
		(k, overlay, nil) := hd l;
		out += sys->sprint("%d:\n", k);
		for(c := overlaychanges(cowfs, overlay); c != nil; c = tl c)
			out += "  " + hd c + "\n";
	}
	return agentlib->strip(out) + "\n/kept apply <n> or /kept discard <n>";
}

# "Apply 2", "Discard 2": a kept change set's buttons.
handlekeptchoice(input: string): int
{
	(n, words) := sys->tokenize(input, " ");
	if(n != 2 || kept == nil)
		return 0;
	verb := hd words;
	(k, rest) := str->toint(hd tl words, 10);
	if(rest != "" || (verb != "Apply" && verb != "Discard"))
		return 0;
	writemsg("veltro", keptdo(str->tolower(verb), k));
	return 1;
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
laststop := "";		# how the last turn ended (veltrosrv's stop=)
placeholder := -1;		# the ▌ bubble shown while the first reply is awaited
placeholderused := 0;
curstep := 0;

# Follow text from offset until the session goes idle, rendering each
# message as it arrives: the first reply of a turn fills the placeholder,
# later ones get their own bubble, titled notes become dialogue tiles.
textfollow(offset: big, done: chan of int)
{
	fd := sys->open(sess + "/text", Sys->OREAD);
	if(fd == nil) {
		done <-= 1;
		return;
	}
	buf := array[8192] of byte;

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
	return writemsg("veltro", "");
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
logfollow(offset: big, done: chan of int)
{
	fd := sys->open(sess + "/log", Sys->OREAD);
	if(fd == nil) {
		done <-= 1;
		return;
	}
	buf := array[8192] of byte;
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
			if(agentlib->hasprefix(line, "turn done stop=")) {
				(st, nil) := str->splitl(line[len "turn done stop=":], " ");
				laststop = st;
			}
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

# An unattended campaign has no operator to answer a dialogue: its driver
# creates this marker, and a gated call is denied at once and recorded as
# such, rather than left waiting for an answer that never comes (INFR-442).
# The marker can only make a call fail, never grant one, so a spoofed
# marker cannot widen anything.
HEADLESSDENY: con "/tmp/veltro/.headless-approval-deny";

headlessdeny(): int
{
	(ok, nil) := sys->stat(HEADLESSDENY);
	return ok >= 0;
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
		if(headlessdeny()) {
			log("pretool: denied by headless campaign policy: " + rest);
			writefile(sess + "/approve", "deny " + callid + " headless");
			continue;
		}
		(tool, what) := str->splitl(rest, " ");
		awaiting = 1;	# before the tile: a quick answer is the tile's
		didx := writedialogue("Permission required", tool + ":" + what, "", "Allow,Deny");
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

# Tell activity 0 this task has done its assignment: what it said last, and
# the files it left in its workspace.  The workspace is the task's own, out
# of activity 0's sight, so their contents travel with the event.
notifyparent()
{
	base := sys->sprint("/mnt/ui/activity/%d", actid);
	label := agentlib->strip(agentlib->readfile(base + "/label"));
	status := agentlib->strip(agentlib->readfile(base + "/status"));
	report := "";
	for(i := 0; ; i++) {
		m := agentlib->readfile(sys->sprint("%s/conversation/%d", base, i));
		if(m == nil)
			break;
		if(!agentlib->hasprefix(m, "role=veltro "))
			continue;
		(nil, t) := str->splitstrl(m, "text=");
		if(t != nil) {
			t = agentlib->strip(t[len "text=":]);
			if(t != "" && t != "▌")
				report = t;
		}
	}
	if(report == "")
		report = "(it gave no report)";

	done := "has finished its assignment";
	if(agentlib->hasprefix(status, "failed"))
		done = "could not finish its assignment";
	ev := TASKEVENT + sys->sprint("Task %d \"%s\" %s (status: %s). " +
		"This is a notification from the harness, not a message from the user.\n\n" +
		"Its report:\n%s\n", actid, label, done, status, report);
	files := stagedchanges() + taskfiles();
	tail := "\nTell the user the outcome now, briefly: what was done, and the result " +
		"(show it when it is short, or what the files hold). If the task asked a " +
		"question, relay it: the user can answer in the task's own tab. If you " +
		"have already told the user this outcome (they asked, and you looked), say " +
		"nothing more about it than that it is done.";
	# Fit one write: the files give way first, then the report.
	room := TASKEVENT_MAX - len array of byte (ev + tail);
	if(len array of byte files > room) {
		cut := room;
		if(cut < 0)
			cut = 0;
		files = clipbytes(files, cut) + "\n... (truncated)\n";
	}
	ev = clipbytes(ev, TASKEVENT_MAX - len array of byte (files + tail) - 32);
	ev += files + tail;
	if(writefile("/mnt/ui/activity/0/conversation/input", ev) < 0)
		log(sys->sprint("notify activity 0: %r"));
	else
		log("notified activity 0 of completion");
}

# What the task changed in the user's folders: staged in its overlay, not in
# the folders, until promoted.  Said in the report, or the user was told a
# file had been changed when it had not.
stagedchanges(): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return "";
	changes: list of string;
	for(ovs := myoverlays(); ovs != nil; ovs = tl ovs)
		for(c := overlaychanges(cowfs, hd ovs); c != nil; c = tl c)
			changes = hd c :: changes;
	if(changes == nil)
		return "";
	out := sys->sprint("\nIts changes to the user's files are STAGED, not yet in the files " +
		"(\"task promote %d\" applies them once the user agrees; \"task revert %d\" " +
		"discards them):\n", actid, actid);
	for(changes = revl(changes); changes != nil; changes = tl changes)
		out += "  " + hd changes + "\n";
	return out;
}

# What the user is shown of an arrived message: who, what, a preview.
msgnotice(ev: string): string
{
	out := "";
	(nil, lines) := sys->tokenize(ev, "\n");
	for(; lines != nil; lines = tl lines) {
		l := hd lines;
		if(agentlib->hasprefix(l, "From: ") || agentlib->hasprefix(l, "Subject: ") ||
		   agentlib->hasprefix(l, "Preview: "))
			out += l + "\n";
	}
	if(out == "")
		out = "A message arrived.";
	return agentlib->strip(out);
}

# What a task event says for the user: the event less its instructions to
# the agent.
eventreport(ev: string): string
{
	ev = ev[len TASKEVENT:];
	(head, nil) := str->splitstrl(ev, "\nTell the user the outcome now");
	(first, rest) := str->splitstrl(head, " This is a notification from the harness");
	if(rest != nil) {
		(nil, after) := str->splitstrl(rest, "\n");
		head = first + after;
	}
	return agentlib->strip(head);
}

# s cut to at most n bytes, on a character boundary.
clipbytes(s: string, n: int): string
{
	if(n <= 0)
		return "";
	if(len array of byte s <= n)
		return s;
	b := array of byte s;
	return string b[0:sys->utfbytes(b, n)];
}

# The files a task left in its workspace, with what they hold (bounded).
taskfiles(): string
{
	dir := sys->sprint("%s/%d", AgentLib->SCRATCH_PATH, actid);
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return "";
	out := "";
	budget := TASKEVENT_FILEMAX;
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			nm := d[i].name;
			if(nm == "" || nm[0] == '.' || (d[i].mode & Sys->DMDIR))
				continue;
			out += sys->sprint("\n--- %s/%s (%bd bytes; in the task's workspace) ---\n",
				AgentLib->SCRATCH_PATH, nm, d[i].length);
			if(budget <= 0 || d[i].length > big (2 * TASKEVENT_FILEMAX)) {
				out += "(not shown)\n";
				continue;
			}
			c := agentlib->readfile(dir + "/" + nm);
			if(len c > budget)
				c = c[0:budget] + "\n... (truncated)";
			budget -= len c;
			out += c;
			if(c != "" && c[len c - 1] != '\n')
				out += "\n";
		}
	}
	if(out == "")
		return "";
	return "\nFiles it wrote:" + out;
}

# A task closed while it works stops working: its turn is cancelled, not
# left to run on with no one to see it.
closewatch(turnover: chan of int)
{
	statpath := sys->sprint("/mnt/ui/activity/%d/status", actid);
	for(;;) {
		alt {
		<-turnover =>
			return;
		* =>
			;
		}
		if(agentlib->strip(agentlib->readfile(statpath)) == "hidden") {
			log("activity closed: cancelling the turn");
			ctl("cancel");
			<-turnover;
			return;
		}
		sys->sleep(1000);
	}
}

filelen(path: string): big
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return big 0;
	return d.length;
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
	laststop = "";

	# Where this turn starts in text and log: taken before the input is
	# written, so a quick reply is not skipped.
	textoff := filelen(sess + "/text");
	logoff := filelen(sess + "/log");
	if(writefile(sess + "/input", input) < 0) {
		writemsg("veltro", sys->sprint("(the agent is unavailable: %r)"));
		setstatus("idle");
		return;
	}
	# Show activity at once: a cursor while the first reply is awaited.
	placeholder = writemsg("veltro", "▌");

	done := chan of int;
	spawn textfollow(textoff, done);
	spawn logfollow(logoff, done);
	spawn approver(done);
	turnover := chan[1] of int;
	if(actid > 0)
		spawn closewatch(turnover);
	for(ndone := 0; ndone < 3; ) alt {
	<-done =>
		ndone++;
	m := <-inputc =>
		turninput(m);
	}
	if(actid > 0)
		turnover <-= 1;

	if(placeholder >= 0 && !placeholderused)
		updateliveconvmsg(placeholder, "");

	# For spawned tasks (actid > 0), signal the user only for the initial
	# autonomous turn.  Once the user has sent a message, further
	# completions don't raise urgency — the user is already engaged.
	# "complete" tells the MA this TA finished its autonomous assignment.
	if(laststop == "llm-error" && actid > 0)
		setstatus("failed: the model service could not be reached");
	else if(actid > 0 && !userinteracted)
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
				} else if(agentlib->hasprefix(choice, TASKEVENT) || agentlib->hasprefix(choice, MSGEVENT)) {
					# A task's report or an arrived message, not the user:
					# there is no model to give it to, and saying so to each
					# one only filled the chat with the same line.
					continue;
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
	# It mounts at /mnt/veltro in this namespace, so the namespace must be
	# this activity's alone: activity 0 and the task agents tools9p starts
	# were born in one, and each new agent's mount replaced the last, so
	# after its first delegation activity 0 was talking to its child.
	if(sys->pctl(Sys->FORKNS, nil) < 0)
		fatal(sys->sprint("cannot fork namespace: %r"));
	startharness();
	(taskbrief, taskinstr) := configuresession();

	# Show welcome document on first launch
	showwelcome(actid);

	# Offer guided tour on second launch (keys configured, not first boot)
	if(actid == 0)
		offertour();
	if(actid == 0)
		offerkept();

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
	inputc = chan of string;
	answerc = chan of string;
	spawn inputreader();

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
		notifyparent();
	}

	for(;;) {
		(human, shown) := nextinput();
		if(human == nil) {
			# The activity is closed: stop the agent and give back its
			# model session, so nothing of it keeps running.
			log("input closed");
			ctl("cancel");
			ctl("close");
			break;
		}
		log("human: " + human);

		# A task's report: a turn for the agent, not words from the human.
		if(actid == 0 && agentlib->hasprefix(human, MSGEVENT)) {
			writedialogue("New message", msgnotice(human), "", "");
			agentturn(human);
			continue;
		}
		if(actid == 0 && agentlib->hasprefix(human, TASKEVENT)) {
			agentturn(human);
			# The model could not take it: the outcome is the user's all
			# the same, so it is shown as the task gave it.
			if(laststop == "llm-error")
				writedialogue("Task report", eventreport(human), "", "");
			continue;
		}

		# Slash commands (/bind, /unbind, /tools, /help) are handled locally.
		# They update tools9p state and reply immediately; agent is not invoked.
		if(handleslash(human))
			continue;

		# Tour dialogue button clicks (non-blocking — user can also just chat)
		if(handletourchoice(human))
			continue;
		if(handlekeptchoice(human))
			continue;

		# Record human message in UI (unless it was, as it came)
		if(!shown)
			writemsg("human", human);
		# Revert "complete" → "idle" once the human engages this TA.
		if(!userinteracted)
			setstatus("idle");
		userinteracted = 1;

		# Run agent turn; the first is told of changes kept from before.
		agentturn(keptnote + human);
		keptnote = "";
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

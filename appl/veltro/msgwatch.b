implement Msgwatch;

#
# msgwatch - Message notification watcher daemon for Veltro
#
# Thin relay between /mnt/msg/notify and the Meta Agent.
#
# Lucifer mode (when /mnt/ui is mounted):
#   Reads blocking notifications from /mnt/msg/notify.
#   Writes each notification to /mnt/ui/activity/0/conversation/input
#   so the Meta Agent receives and classifies it.
#
# Headless mode (no /mnt/ui):
#   Creates own LLM session, loads secretary policy,
#   classifies and handles messages autonomously.
#
# Usage: msgwatch [-v] [-p policyfile] [-a actid]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "arg.m";

include "agentlib.m";
	agentlib: AgentLib;

Msgwatch: module {
	PATH: con "/dis/veltro/msgwatch.dis";
	init: fn(nil: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;
verbose := 0;
actid := 0;
policyfile := "/lib/veltro/policies/secretary.txt";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);

	str = load String String->PATH;
	if(str == nil)
		fatal("cannot load String");

	agentlib = load AgentLib AgentLib->PATH;
	if(agentlib == nil)
		fatal("cannot load AgentLib");
	agentlib->init();

	arg := load Arg Arg->PATH;
	if(arg == nil)
		fatal("cannot load Arg");
	arg->init(args);

	while((o := arg->opt()) != 0)
		case o {
		'v' =>
			verbose = 1;
			agentlib->setverbose(1);
		'p' =>
			policyfile = arg->earg();
		'a' =>
			actid = int arg->earg();
		* =>
			sys->fprint(stderr, "usage: msgwatch [-v] [-p policyfile] [-a actid]\n");
			raise "fail:usage";
		}
	arg = nil;

	# Determine mode: Lucifer (has /mnt/ui) or headless
	uipath := sys->sprint("/mnt/ui/activity/%d/conversation/input", actid);
	fd := sys->open(uipath, Sys->OWRITE);
	if(fd != nil) {
		fd = nil;
		log("Lucifer mode: relaying to activity " + string actid);
		luciferloop(uipath);
	} else {
		log("Headless mode: autonomous classification");
		headlessloop();
	}
}

# Lucifer mode: relay notifications to Meta Agent conversation.
# The message-handling policy is loaded here (fire-time) and injected with each
# incoming message, rather than baked into activity 0's system prompt — this
# keeps the base prompt lean, and instructions in the triggering turn drive
# action more reliably than system-prompt text (cf. the autonomous-kickoff
# finding). This is the general fire-time "skill" pattern: a named instruction
# file pulled in only when its event occurs.
luciferloop(inputpath: string)
{
	notifypath := "/mnt/msg/notify";

	policy := agentlib->readfile(policyfile);
	if(policy == nil)
		policy = "";
	policy = agentlib->strip(policy);
	if(policy == "")
		log("warning: empty/unreadable policy " + policyfile + " — relaying raw");

	for(;;) {
		# Blocking read on /mnt/msg/notify
		notifyfd := sys->open(notifypath, Sys->OREAD);
		if(notifyfd == nil) {
			log("cannot open " + notifypath + ", retrying in 5s");
			sys->sleep(5000);
			continue;
		}

		notification := blockread(notifyfd);
		notifyfd = nil;

		if(notification == nil) {
			log("notify closed, retrying in 1s");
			sys->sleep(1000);
			continue;
		}

		log("notification: " + truncate(notification, 80));

		# Route on the deterministic verdict stamped by msg9p (from the message's
		# structured fields). ignore/context never wake the LLM — the whole point
		# of triage. Only wake/preempt are injected into activity 0.
		verdict := nfield(notification, "Triage: ");
		if(verdict == "")
			verdict = "wake";	# unstamped → be safe, wake
		src := nsource(notification);
		id := nfield(notification, "Message ID: ");

		case verdict {
		"ignore" =>
			markseen(src, id);
			log("[triage ignore] flagged seen, NOT dispatched: " + truncate(notification, 50));
			continue;
		"context" =>
			log("[triage context] noted, NOT dispatched: " + truncate(notification, 50));
			continue;
		}

		# wake / preempt: inject the policy + the message as a single turn so
		# activity 0 triages per the policy. NEVER auto-send: drafts are reviewed.
		urgency := "";
		if(verdict == "preempt")
			urgency = "This message is URGENT — handle it before other pending work. ";
		turn := notification;
		if(policy != "")
			turn = policy +
				"\n\n--- An incoming message just arrived. " + urgency +
				"Triage it per the Message Policy above. For actionable messages, create a " +
				"Task Agent with a clear brief; draft any reply but NEVER auto-send it — " +
				"save it for the user to review. ---\n\n" +
				notification;

		inputfd := sys->open(inputpath, Sys->OWRITE);
		if(inputfd == nil) {
			log("cannot open " + inputpath + ": " + sys->sprint("%r"));
			continue;
		}

		data := array of byte turn;
		n := sys->write(inputfd, data, len data);
		inputfd = nil;

		if(n != len data)
			log("short write to input: " + sys->sprint("%r"));
		else
			log("[triage " + verdict + "] relayed to Meta Agent (policy injected)");
	}
}

# Extract the value after a "Prefix" line in a notification ("" if absent).
nfield(notif, prefix: string): string
{
	i := 0;
	n := len notif;
	while(i < n) {
		j := i;
		while(j < n && notif[j] != '\n')
			j++;
		line := notif[i:j];
		if(len line >= len prefix && line[0:len prefix] == prefix)
			return line[len prefix:];
		i = j + 1;
	}
	return "";
}

# Source name from the first line: "[Message notification — <src>]".
nsource(notif: string): string
{
	p := strindex(notif, "— ");
	if(p < 0)
		return "";
	rest := notif[p+2:];
	e := strindex(rest, "]");
	if(e < 0)
		return "";
	return rest[0:e];
}

strindex(hay, needle: string): int
{
	if(needle == "" || len needle > len hay)
		return -1;
	for(i := 0; i <= len hay - len needle; i++)
		if(hay[i:i+len needle] == needle)
			return i;
	return -1;
}

# Mark a message seen via msg9p ctl, so an ignored message is not re-delivered.
markseen(src, id: string)
{
	if(src == "" || id == "")
		return;
	fd := sys->open("/mnt/msg/ctl", Sys->OWRITE);
	if(fd == nil) {
		log("markseen: cannot open /mnt/msg/ctl: " + sys->sprint("%r"));
		return;
	}
	cmd := "flag " + src + " " + id + " seen";
	b := array of byte cmd;
	sys->write(fd, b, len b);
	fd = nil;
}

# Headless mode: classify and handle autonomously
headlessloop()
{
	# Load policy
	policy := agentlib->readfile(policyfile);
	if(policy == nil) {
		log("warning: cannot read policy " + policyfile + ", using defaults");
		policy = "Classify messages as IGNORE (spam), DEFER (legitimate, non-urgent), or NOTIFY (urgent).";
	}

	# Create LLM session for classification
	sessionid := agentlib->createsession();
	if(sessionid == "") {
		fatal("cannot create LLM session for headless classification");
	}
	log("LLM session: " + sessionid);

	# Set system prompt with policy
	systemprompt := "You are a message classifier for an autonomous agent.\n\n" +
		policy + "\n\n" +
		"For each message notification, respond with exactly one line:\n" +
		"IGNORE - for spam, marketing, automated notifications\n" +
		"DECLINE <brief reason> - for solicitations to politely refuse\n" +
		"DEFER <brief reason> - for legitimate but non-urgent messages\n" +
		"NOTIFY <brief reason> - for urgent messages needing attention\n\n" +
		"Then on the next line, if DECLINE/DEFER/NOTIFY, include a suggested reply draft.";

	systempath := "/mnt/llm/" + sessionid + "/system";
	agentlib->setsystemprompt(systempath, systemprompt);

	# Open persistent ask fd
	askpath := "/mnt/llm/" + sessionid + "/ask";
	llmfd := sys->open(askpath, Sys->ORDWR);
	if(llmfd == nil) {
		fatal("cannot open " + askpath);
	}

	notifypath := "/mnt/msg/notify";

	for(;;) {
		notifyfd := sys->open(notifypath, Sys->OREAD);
		if(notifyfd == nil) {
			log("cannot open " + notifypath + ", retrying in 5s");
			sys->sleep(5000);
			continue;
		}

		notification := blockread(notifyfd);
		notifyfd = nil;

		if(notification == nil) {
			log("notify closed, retrying in 1s");
			sys->sleep(1000);
			continue;
		}

		log("notification: " + truncate(notification, 80));

		# Deterministic routing seam (docs/MESSAGE-INTEGRATION.md): not every
		# notification should pay for an LLM round-trip, and safety-critical
		# sources must not wait on a model. Error notifications are logged, not
		# classified. Rule-based routing for urgent sources (e.g. an alarm →
		# immediate escalation) belongs here, ahead of LLM triage of the
		# ambiguous middle.
		if(agentlib->hasprefix(notification, "[Message error")) {
			log("source error (not classified): " + truncate(notification, 80));
			continue;
		}

		# Classify via LLM
		response := agentlib->queryllmfd(llmfd, notification);
		if(response == nil || response == "") {
			log("LLM returned empty response, skipping");
			continue;
		}

		log("classification: " + truncate(response, 120));

		# Parse and act on classification
		handleclassification(response, notification);
	}
}

# Handle a classification result in headless mode
handleclassification(response, notification: string)
{
	line := firstline(response);
	lline := str->tolower(line);

	# Act through the protocol-agnostic msg9p notification plane: flag via
	# /mnt/msg/ctl, reply via /mnt/msg/reply. Both need the source name (from
	# the notification header) and the source-unique id.
	src := extractsource(notification);
	msgid := extractmsgid(notification);

	if(agentlib->hasprefix(lline, "ignore")) {
		# Mark read in place (no task needed).
		if(src != nil && msgid != nil) {
			err := msgctl("flag " + src + " " + msgid + " seen");
			if(err == nil)
				log("IGNORE: marked seen " + src + "/" + msgid);
			else
				log("IGNORE: flag failed for " + src + "/" + msgid + ": " + truncate(err, 60));
		} else {
			log("IGNORE: no source/message ID found");
		}

	} else if(agentlib->hasprefix(lline, "decline")) {
		if(src != nil && msgid != nil) {
			draft := extractdraft(response);
			if(draft != nil) {
				err := msgreply(src, msgid, draft);
				if(err == nil)
					log("DECLINE: replied to " + src + "/" + msgid);
				else
					log("DECLINE: reply failed for " + src + "/" + msgid + ": " + truncate(err, 60));
			} else {
				log("DECLINE: no draft in LLM response for " + src + "/" + msgid);
			}
		} else {
			log("DECLINE: no source/message ID found");
		}

	} else if(agentlib->hasprefix(lline, "defer")) {
		log("DEFER: " + src + "/" + msgid + " — draft saved for user review");
		# In headless mode, just log it. The draft is in the LLM response.

	} else if(agentlib->hasprefix(lline, "notify")) {
		log("NOTIFY: urgent message " + src + "/" + msgid);
		# In headless mode, log urgently. Could write to a file for monitoring.

	} else {
		log("unrecognized classification: " + truncate(line, 60));
	}
}

# ---- Helpers ----

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

# Extract message ID from notification text
# Looks for "Message ID: email/42" or similar patterns
extractmsgid(notification: string): string
{
	lines := splitlines(notification);
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(agentlib->hasprefix(line, "Message ID: ")) {
			id := line[len "Message ID: ":];
			# Extract just the numeric part after source/
			for(i := len id - 1; i >= 0; i--) {
				if(id[i] == '/') {
					return id[i+1:];
				}
			}
			return id;
		}
	}
	return nil;
}

# Extract the source name from the notification header line, e.g.
# "[Message notification — email]" -> "email". The em dash (U+2014) is the
# delimiter msg9p's formatnotification uses. Returns nil if not found.
extractsource(notification: string): string
{
	line := firstline(notification);
	dash := -1;
	for(i := 0; i < len line; i++)
		if(line[i] == 16r2014) {	# em dash
			dash = i;
			break;
		}
	if(dash < 0)
		return nil;
	start := dash + 1;
	while(start < len line && line[start] == ' ')
		start++;
	end := start;
	while(end < len line && line[end] != ']')
		end++;
	if(end <= start)
		return nil;
	return line[start:end];
}

# Write a command to /mnt/msg/ctl (e.g. "flag email 42 seen"). Returns nil on
# success, or the server's error string (e.g. "flag: no source: email").
msgctl(cmd: string): string
{
	fd := sys->open("/mnt/msg/ctl", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("open /mnt/msg/ctl: %r");
	b := array of byte cmd;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write /mnt/msg/ctl: %r");
	return nil;
}

# Send a threaded reply through /mnt/msg/reply (format: <src>\n<id>\n<body>).
# Returns nil on success or the source's error string.
msgreply(src, id, body: string): string
{
	data := src + "\n" + id + "\n" + body;
	fd := sys->open("/mnt/msg/reply", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("open /mnt/msg/reply: %r");
	b := array of byte data;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write /mnt/msg/reply: %r");
	return nil;
}

# Extract draft reply from LLM response (everything after the first line)
extractdraft(response: string): string
{
	for(i := 0; i < len response; i++) {
		if(response[i] == '\n') {
			draft := response[i+1:];
			# Trim leading whitespace
			return agentlib->strip(draft);
		}
	}
	return nil;
}

firstline(s: string): string
{
	for(i := 0; i < len s; i++) {
		if(s[i] == '\n')
			return s[:i];
	}
	return s;
}

splitlines(s: string): list of string
{
	result: list of string;
	start := 0;
	for(i := 0; i < len s; i++) {
		if(s[i] == '\n') {
			result = s[start:i] :: result;
			start = i + 1;
		}
	}
	if(start < len s)
		result = s[start:] :: result;

	# Reverse
	rev: list of string;
	for(; result != nil; result = tl result)
		rev = hd result :: rev;
	return rev;
}

truncate(s: string, max: int): string
{
	if(len s <= max)
		return s;
	return s[:max] + "...";
}

log(msg: string)
{
	if(verbose)
		sys->fprint(stderr, "msgwatch: %s\n", msg);
}

fatal(msg: string)
{
	sys->fprint(stderr, "msgwatch: %s\n", msg);
	raise "fail:" + msg;
}

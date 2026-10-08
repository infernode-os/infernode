implement VeltroSrv;

#
# veltrosrv - the Veltro agent harness, served as files
#
# One agent loop, served at /mnt/veltro.  Every front end (veltro on the
# command line, lucibridge for Lucia, Xenith's Agent window, a shell) is
# a client of these files:
#
#	/mnt/veltro/
#	    new            read: start a session; returns its id
#	    <id>/
#	        ctl        write: cancel | reset | close | persona <type> |
#	                          role <name> | brief <text> | model <m> |
#	                          think <n> | maxsteps <n> | gate on|off
#	                   read: the settings, attr=value
#	        input      write: one user message; starts a turn.  "busy"
#	                   while a turn runs.
#	        text       read: the conversation as the user sees it, as
#	                   messages headed "== user", "== veltro" or
#	                   "== note [title]".  While a turn runs, a read at
#	                   the end waits for more; when the session is idle
#	                   it is the end of the file.  So cat prints the
#	                   conversation and returns once the turn is over.
#	        log        read: the trajectory, one line per event, in the
#	                   form lucibridge -v has always written.  Ends as
#	                   text does.
#	        status     read: idle | working | blocked | <tool>
#	        approve    read: while a turn runs, waits for a gated call,
#	                   then "<callid> <tool> <args>"; write: allow
#	                   <callid> | deny <callid>
#
# The loop is lucibridge's agentturn, moved here with its writes to
# /mnt/ui replaced by appends to text and log; what the grinding tuned
# (the native tool-call fallback, bounded calls, the scratch preview and
# re-scratch guard, fail-streak guidance, say interception, the low
# sampling temperature) is carried as it was.  One addition: a batch of
# read-only tool calls runs concurrently (exectools).
#
# Authority is the namespace.  The serving process forks its namespace
# and applies nsconstruct->restrictns with the grants given on the
# command line, before it serves; the mount lands in the caller's
# namespace only, so the agent cannot name its own approve or ctl.
#
#	veltrosrv [-v] [-n maxsteps] [-m toolmount] [-S scratchdir] [-a tag]
#	          [-t tool,...] [-p path[:ro|:rw],...] [-M mountpoint]
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "arg.m";
	arg: Arg;

include "string.m";
	str: String;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg, Ebadfid: import styxservers;

include "nsconstruct.m";
	nsconstruct: NsConstruct;

include "agentlib.m";

include "audit.m";

include "auditprov.m";
	auditprov: AuditProv;

include "veltrosrv.m";

# ---- Configuration ----

DEFAULT_MAX_STEPS: con 100;
MAX_MAX_STEPS: con 500;
TOOL_TIMEOUT: con 60000;		# ms per tool call
LLM_READ_TIMEOUT: con 300000;	# ms; long for extended thinking
MAX_TOOL_FAILURES: con 3;
AGENT_TEMP: con "0.2";		# measured: ~22% delegation-miss at 0.7, ~0 at 0.2
AGENT_NAME_PATH: con "/lib/veltro/agent-name";
OS_NAME_PATH: con "/lib/veltro/os-name";
META_PROMPT_PATH: con "/lib/veltro/meta.txt";
SCRATCH_PATH: con AgentLib->SCRATCH_PATH;

verbose := 0;
maxsteps := DEFAULT_MAX_STEPS;
toolmount := "/tool";
scratchdir := "";		# -S: backing directory for scratch files
provtag := "";			# -a: prefix for provenance messages ("activity=0")
mountpt := "/mnt/veltro";
agentname := "Veltro";
osname := "InferNode";
ndbtemp := "";			# temperature= from /lib/ndb/llm, read before restriction
stderr: ref Sys->FD;

# Agent provenance (INFR-355).  Optional when auditing is off; fail-closed
# when the install marker says auditing is required.
provrequired := 0;

# ---- Sessions ----

Qroot, Qnew, Qsessdir, Qctl, Qinput, Qtext, Qlog, Qstatus, Qapprove: con iota;

Approval: adt {
	callid, tool, args: string;
	reply: chan of int;		# 1 allow, 0 deny
};

Session: adt {
	id:		int;
	al:		AgentLib;		# its own instance: read cache, prefill marker
	llmid:		string;
	llmfd:		ref Sys->FD;
	persona:	string;		# agents/<type>.txt, layered as == Agent Role ==
	role:		string;		# meta | <name>: a suffix file, lucibridge's way
	brief:		string;		# literal suffix
	model:		string;
	think:		int;
	maxsteps:	int;
	gate:		int;
	text:		string;
	atlinestart:	int;
	log:		string;
	status:		string;
	busy:		int;
	cancel:		int;
	approval:	ref Approval;
	ptext, plog, papprove: list of (int, ref Tmsg.Read);	# parked reads (fid, tm)
	toolsraw, pathsraw: string;
	failtool:	string;
	failcount:	int;
	closed:		int;
};

sessions: list of ref Session;
nextsid := 0;
vers := 0;
user := "inferno";

# Events from a turn to the serving process, which owns the session state.
Ev: adt {
	s: ref Session;
	pick {
	Text =>		t: string;
	Head =>		role: string;
	Log =>		line: string;
	End =>				# end of a message: ensure it ends a line
	Status =>	st: string;
	Approve =>	a: ref Approval;
	Done =>
	}
};
evc: chan of ref Ev;

# ---- Small helpers ----

log(s: ref Session, msg: string)
{
	evc <-= ref Ev.Log(s, msg);
}

fatal(msg: string)
{
	sys->fprint(stderr, "veltrosrv: %s\n", msg);
	raise "fail:" + msg;
}

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

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

strip(s: string): string
{
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t' || s[0] == '\n' || s[0] == '\r'))
		s = s[1:];
	while(len s > 0 && (s[len s - 1] == ' ' || s[len s - 1] == '\t' || s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

# Replace every occurrence of pat with repl (%AGENT% / %OS% injection).
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

readndbfield(path, field: string): string
{
	content := readfile(path);
	prefix := field + "=";
	plen := len prefix;
	for(i := 0; i < len content; ) {
		eol := i;
		while(eol < len content && content[eol] != '\n')
			eol++;
		if(eol - i >= plen && content[i:i+plen] == prefix)
			return content[i+plen:eol];
		i = eol + 1;
	}
	return nil;
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

toolctlmount(mpt: string): string
{
	if(mpt == "/tool")
		return "/mnt/toolctl";
	if(len mpt > 6 && mpt[0:6] == "/tool.")
		return "/mnt/toolctl." + mpt[6:];
	return "/mnt/toolctl";
}

safename(t: string): int
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

# ---- Provenance ----

initprovenance()
{
	(aonok, nil) := sys->stat(Audit->ONFILE);
	provrequired = aonok >= 0;
	(alogok, nil) := sys->stat(Audit->LOGFILE);
	if(!provrequired && alogok < 0)
		return;
	if(provrequired && alogok < 0)
		fatal("this install requires auditing but /mnt/audit/log is not mounted");

	auditprov = load AuditProv AuditProv->PATH;
	err := "cannot load audit provenance module";
	if(auditprov != nil)
		err = auditprov->init();
	if(err != nil) {
		auditprov = nil;
		if(provrequired)
			fatal("required provenance unavailable: " + err);
		return;
	}
	# Dial the content store before restriction: the fd survives it.
	err = auditprov->attach(nil);
	if(err != nil && provrequired)
		fatal("required provenance unavailable: " + err);
}

prov(event, msg: string, payload: array of byte)
{
	if(auditprov == nil) {
		if(provrequired)
			fatal("required provenance module unavailable");
		return;
	}
	if(provtag != "")
		msg = provtag + " " + msg;
	rc := auditprov->log("veltro", event, msg, payload);
	if(provrequired && rc != 0)
		fatal("required provenance write failed");
}

# ---- The agent turn (lucibridge's agentturn, as it was) ----

# Mark text for the user.  The serving process does the appending; see
# ev handling in serveloop.
say(s: ref Session, role, text: string)
{
	evc <-= ref Ev.Head(s, role);
	evc <-= ref Ev.Text(s, text);
	evc <-= ref Ev.End(s);
}

setstatus(s: ref Session, st: string)
{
	evc <-= ref Ev.Status(s, st);
}

writellmfd(s: ref Session, prompt: string)
{
	b := array of byte prompt;
	n := sys->write(s.llmfd, b, len b);
	if(n < 0)
		log(s, sys->sprint("writellmfd failed: %r"));
}

llmreadworker(fd: ref Sys->FD, ch: chan of string)
{
	result := "";
	buf := array[8192] of byte;
	offset := big 0;
	for(;;) {
		n := sys->pread(fd, buf, len buf, offset);
		if(n <= 0)
			break;
		result += string buf[0:n];
		offset += big n;
	}
	ch <-= result;
}

timer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

# Read the complete response from the ask fd at offset 0.  Blocks until
# generation completes, or until the timeout (a network drop must not
# hang the turn).
readllmfd(s: ref Session): string
{
	resultch := chan[1] of string;
	spawn llmreadworker(s.llmfd, resultch);
	timeoutch := chan[1] of int;
	spawn timer(timeoutch, LLM_READ_TIMEOUT);
	alt {
	result := <-resultch =>
		return result;
	<-timeoutch =>
		log(s, sys->sprint("LLM read timed out after %d seconds", LLM_READ_TIMEOUT / 1000));
		return "";
	}
}

# Scratch spill.  With -S the file lands in the backing directory and the
# agent is told the path it sees that directory at (an activity's scratch
# is mounted at SCRATCH_PATH in its tool namespace).
writescratch(s: ref Session, content: string, step: int): string
{
	if(scratchdir == "")
		return s.al->writescratch(content, step);
	sys->create(scratchdir, Sys->OREAD, 8r700 | Sys->DMDIR);
	path := sys->sprint("%s/step%d.txt", scratchdir, step);
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return "(cannot create scratch file)";
	b := array of byte content;
	if(sys->write(fd, b, len b) != len b)
		return "(cannot write scratch file)";
	return sys->sprint("%s/step%d.txt", SCRATCH_PATH, step);
}

firstlines(s: string, n: int): string
{
	out := "";
	count := 0;
	for(i := 0; i < len s && count < n; i++) {
		out[len out] = s[i];
		if(s[i] == '\n')
			count++;
	}
	return out;
}

toolresultstatus(s: ref Session, name, content: string): string
{
	lower := str->tolower(content);
	if(hasprefix(lower, "error:") ||
	   hasprefix(lower, "error —") ||
	   (name == "exec" && (s.al->contains(lower, "(exit:") ||
		s.al->contains(lower, "... (timeout"))) ||
	   (name == "limbo" && s.al->contains(lower, "status: failed")))
		return "error";
	return "success";
}

# Approval gate for destructive operations.
shellword(args, want: string): int
{
	(nil, toks) := sys->tokenize(args, " \t\n;|&{}()");
	for(; toks != nil; toks = tl toks)
		if(hd toks == want)
			return 1;
	return 0;
}

recursiveRmOutsideTmp(s: ref Session, args: string): int
{
	(nil, toks) := sys->tokenize(args, " \t\n;|&{}()");
	sawrm := 0;
	recursive := 0;
	tmptarget := 0;
	outsidetarget := 0;
	for(; toks != nil; toks = tl toks) {
		tok := hd toks;
		if(tok == "rm") {
			sawrm = 1;
			continue;
		}
		if(!sawrm)
			continue;
		if(len tok > 1 && tok[0] == '-') {
			if(s.al->contains(tok[1:], "r"))
				recursive = 1;
			continue;
		}
		if(len tok > 0 && tok[0] == '/') {
			if(tok == "/tmp" || hasprefix(tok, "/tmp/"))
				tmptarget = 1;
			else
				outsidetarget = 1;
		}
	}
	return sawrm && recursive && (outsidetarget || !tmptarget);
}

needsapproval(s: ref Session, toolname, args: string): int
{
	if(!s.gate)
		return 0;
	if(toolname != "exec" && toolname != "write" && toolname != "edit")
		return 0;
	if(toolname == "exec") {
		if(recursiveRmOutsideTmp(s, args))
			return 1;
		if(shellword(args, "bind") || shellword(args, "mount") ||
		   shellword(args, "unmount"))
			return 1;
	}
	if(toolname == "write" || toolname == "edit") {
		if(hasprefix(args, "/dis/") || hasprefix(args, "/lib/") ||
		   hasprefix(args, "/dev/"))
			return 1;
	}
	return 0;
}

# Blocks until the operator answers through the approve file (or cancels).
pretoolapproval(s: ref Session, callid, toolname, args: string): string
{
	if(!needsapproval(s, toolname, args))
		return "allow";
	a := ref Approval(callid, toolname, s.al->truncate(args, 120), chan[1] of int);
	log(s, "pretool: awaiting approval for " + toolname);
	setstatus(s, "blocked");
	evc <-= ref Ev.Approve(s, a);
	ok := <-a.reply;
	setstatus(s, "working");
	if(!ok) {
		log(s, "pretool: user responded: deny");
		return "deny";
	}
	log(s, "pretool: user responded: allow");
	return "allow";
}

# Track consecutive failures of one tool; after MAX_TOOL_FAILURES the
# guidance rides inside the last tool result (so it stays inside the
# TOOL_RESULTS wire format) and the user is told.
updatefailstreak(s: ref Session, tools: list of (string, string, string),
	results: list of (string, string)): string
{
	ntool := 0;
	for(tl0 := tools; tl0 != nil; tl0 = tl tl0)
		ntool++;
	if(ntool != 1) {
		s.failtool = "";
		s.failcount = 0;
		return "";
	}
	(nil, name, nil) := hd tools;
	(nil, content) := hd results;
	lname := str->tolower(name);
	iserror := hasprefix(content, "error:") ||
		hasprefix(content, "ERROR:") ||
		hasprefix(content, "error —");
	if(!iserror) {
		s.failtool = "";
		s.failcount = 0;
		return "";
	}
	if(lname == s.failtool)
		s.failcount++;
	else {
		s.failtool = lname;
		s.failcount = 1;
	}
	if(s.failcount >= MAX_TOOL_FAILURES) {
		msg := sys->sprint("Tool '%s' has failed %d consecutive times.", name, s.failcount);
		say(s, "note Agent stuck", msg + " Consider intervening or letting it try a different approach.");
		s.failtool = "";
		s.failcount = 0;
		return msg + " Try a different approach or different arguments.";
	}
	return "";
}

# ---- Tool execution ----

# A batch is the tool calls of one model response.  Every call is gated,
# intercepted (say) and checked against the read cache first, in the
# model's order; what remains runs concurrently when all of it is
# read-only, and one at a time, in order, when any of it mutates (so
# read -> edit -> read still re-reads, and write foo.b still precedes
# limbo foo.b).  spawn is read-only here: its children run concurrently
# inside the one call already.
readonlytool(name: string): int
{
	case name {
	"read" or "list" or "find" or "search" or "grep" or
	"websearch" or "webfetch" or "spawn" =>
		return 1;
	}
	return 0;
}

calltoolworker(s: ref Session, name, args: string, resultch: chan of string)
{
	resultch <-= s.al->calltool(name, args);
}

# One bounded call: a buffered one-shot channel lets a late sender finish
# rather than hang (#599); the timer starts when the call does.
Call: adt {
	id, name, args: string;
	resultch: chan of string;
	timeoutch: chan of int;
};

launch(s: ref Session, id, name, args: string): ref Call
{
	c := ref Call(id, name, args, chan[1] of string, chan[1] of int);
	spawn calltoolworker(s, name, args, c.resultch);
	spawn timer(c.timeoutch, TOOL_TIMEOUT);
	return c;
}

collect(c: ref Call): string
{
	alt {
	result := <-c.resultch =>
		return result;
	<-c.timeoutch =>
		return sys->sprint("error: tool '%s' timed out after %d seconds",
			c.name, TOOL_TIMEOUT / 1000);
	}
}

# After a call: provenance, cache, spill.  Returns what the model sees.
finish(s: ref Session, step: int, name, args, result: string): string
{
	nm := str->tolower(name);
	prov("toolres", sys->sprint("agent=%s step=%d tool=%s status=%s",
		s.llmid, step + 1, name, toolresultstatus(s, nm, result)), array of byte result);
	s.al->deduprecord(nm, args, result, step);
	log(s, "tool " + name + ": done, " + s.al->truncate(result, 100));
	if(len result > AgentLib->STREAM_THRESHOLD) {
		# Never re-scratch a read of a scratch file: each read would
		# produce another scratch file of similar size, without end.
		isscratchread := nm == "read" &&
			len args >= len SCRATCH_PATH &&
			args[0:len SCRATCH_PATH] == SCRATCH_PATH;
		if(isscratchread) {
			result = result[0:AgentLib->STREAM_THRESHOLD] +
				"\n... (truncated — content continues in " + args + ")";
		} else {
			scratch := writescratch(s, result, step);
			# The first 3 lines stay inline so the model has something to
			# act on; small, so TOOL_RESULTS fits one 9P write (~8KB).
			preview := firstlines(result, 3);
			result = preview +
				sys->sprint("\n... (%d total bytes — full output at %s)",
					len result, scratch);
		}
	}
	return result;
}

exectools(s: ref Session, calls: list of (string, string, string), step: int): list of (string, string)
{
	# Pass 1, in order: say, the gate, the read cache.
	results: list of (string, string);	# reversed
	torun: list of (string, string, string);	# reversed
	allread := 1;
	for(tc := calls; tc != nil; tc = tl tc) {
		(id, name, args) := hd tc;
		nm := str->tolower(name);
		prov("toolcall", sys->sprint("agent=%s step=%d tool=%s",
			s.llmid, step + 1, name), array of byte args);
		if(nm == "say") {
			say(s, "veltro say", args);
			results = (id, "said") :: results;
			prov("toolres", sys->sprint("agent=%s step=%d tool=%s",
				s.llmid, step + 1, name), array of byte "said");
			continue;
		}
		if(pretoolapproval(s, id, nm, args) == "deny") {
			denied := "error: operation denied by operator";
			results = (id, denied) :: results;
			prov("toolres", sys->sprint("agent=%s step=%d tool=%s status=denied",
				s.llmid, step + 1, name), array of byte denied);
			continue;
		}
		# Read cache: identical read-only repeats are answered from the
		# earlier result; a mutating tool invalidates it.
		dcskip := s.al->dedupcheck(nm, args);
		if(dcskip != "") {
			results = (id, dcskip) :: results;
			prov("toolres", sys->sprint("agent=%s step=%d tool=%s status=cached",
				s.llmid, step + 1, name), array of byte dcskip);
			continue;
		}
		# An identical read-only call earlier in this same batch: the
		# sequential loop answered the repeat from the cache, so this
		# does too.
		dup := 0;
		for(tr := torun; tr != nil; tr = tl tr) {
			(nil, tn, ta) := hd tr;
			if(str->tolower(tn) == nm && ta == args && readonlytool(nm)) {
				dup = 1;
				break;
			}
		}
		if(dup) {
			note := sys->sprint("(skipped: identical `%s %s` already ran at step %d — its output is in your earlier results; use that instead of repeating the call)",
				nm, s.al->truncate(args, 120), step);
			results = (id, note) :: results;
			prov("toolres", sys->sprint("agent=%s step=%d tool=%s status=cached",
				s.llmid, step + 1, name), array of byte note);
			continue;
		}
		if(!readonlytool(nm))
			allread = 0;
		results = (id, nil) :: results;	# placeholder, filled below
		torun = (id, name, args) :: torun;
	}

	# Pass 2: run what remains.
	ran: list of (string, string);	# (id, result), reversed
	if(allread) {
		rev: list of (string, string, string);
		for(; torun != nil; torun = tl torun)
			rev = hd torun :: rev;
		launched: list of ref Call;	# reversed
		for(pc := rev; pc != nil; pc = tl pc) {
			(id, name, args) := hd pc;
			setstatus(s, "working");
			log(s, "tool " + name + ": args " + args);
			log(s, "tool " + name + ": calling with " + string len args + " bytes");
			launched = launch(s, id, name, args) :: launched;
		}
		inorder: list of ref Call;
		for(; launched != nil; launched = tl launched)
			inorder = hd launched :: inorder;
		for(; inorder != nil; inorder = tl inorder) {
			c := hd inorder;
			r := collect(c);
			ran = (c.id, finish(s, step, c.name, c.args, r)) :: ran;
		}
	} else {
		rev: list of (string, string, string);
		for(; torun != nil; torun = tl torun)
			rev = hd torun :: rev;
		for(sc := rev; sc != nil; sc = tl sc) {
			(id, name, args) := hd sc;
			setstatus(s, str->tolower(name));
			log(s, "tool " + name + ": args " + args);
			log(s, "tool " + name + ": calling with " + string len args + " bytes");
			r := collect(launch(s, id, name, args));
			setstatus(s, "working");
			ran = (id, finish(s, step, name, args, r)) :: ran;
		}
	}

	# Merge in the model's order.
	out: list of (string, string);
	for(; results != nil; results = tl results) {
		(id, r) := hd results;
		if(r == nil) {
			for(rl := ran; rl != nil; rl = tl rl) {
				(rid, rr) := hd rl;
				if(rid == id) {
					r = rr;
					break;
				}
			}
		}
		out = (id, r) :: out;
	}
	return out;
}

# ---- The turn ----

turn(s: ref Session, input: string)
{
	s.al->dedupreset();	# fresh read-cache per turn
	prov("prompt", sys->sprint("agent=%s", s.llmid), array of byte input);

	# If the tool set changed (via /tool/ctl), reinstall the session's
	# tool definitions so the model knows before this turn.
	if(s.al->pathexists(toolmount)) {
		latest := readfile(toolmount + "/tools");
		if(latest != nil && latest != s.toolsraw) {
			s.toolsraw = latest;
			s.al->initsessiontools(s.llmid, sessiontools(latest));
			log(s, "tools updated: " + latest);
		}
		lp := readfile(toolmount + "/paths");
		if(lp != s.pathsraw) {
			s.pathsraw = lp;
			setsystemprompt(s);
			log(s, "system prompt updated with new paths");
		}
	}

	setstatus(s, "working");
	prompt := input;
	streambase := "/mnt/llm/" + s.llmid;

	hitlimit := 1;
	laststep := 0;
	stopstate := "max-steps";
	for(step := 0; step < s.maxsteps; step++) {
		if(s.cancel) {
			hitlimit = 0;
			stopstate = "cancelled";
			say(s, "note", "(cancelled)");
			break;
		}
		laststep = step + 1;
		log(s, sys->sprint("step %d: writing %d bytes to LLM", step + 1, len array of byte prompt));

		# Start generation; with a streaming llmsrv the write returns at
		# once and /stream carries the text as it arrives.
		writellmfd(s, prompt);

		streampath := streambase + "/stream";
		streamfd := sys->open(streampath, Sys->OREAD);
		streamed := "";
		started := 0;
		if(streamfd != nil) {
			log(s, "stream: reading " + streampath);
			buf := array[512] of byte;
			nchunks := 0;
			for(;;) {
				n := sys->read(streamfd, buf, len buf);
				if(n <= 0)
					break;
				chunk := string buf[0:n];
				streamed += chunk;
				nchunks++;
				if(!started) {
					evc <-= ref Ev.Head(s, "veltro");
					started = 1;
				}
				evc <-= ref Ev.Text(s, chunk);
			}
			log(s, sys->sprint("stream: done (%d chunks, %d bytes)", nchunks, len streamed));
			streamfd = nil;
		} else
			log(s, "stream: not available (old llmsrv); using direct display");

		log(s, "step " + string (step + 1) + ": waiting for LLM response...");
		response := readllmfd(s);
		log(s, sys->sprint("step %d: LLM response %d bytes", step + 1, len array of byte response));
		if(response == "") {
			stopstate = "empty";
			say(s, "note", "(no response from LLM)");
			break;
		}
		prov("llm", sys->sprint("agent=%s step=%d", s.llmid, step + 1), array of byte response);

		log(s, "llm: " + s.al->truncate(response, 200));

		(stopreason, tools, text) := s.al->parsellmresponse(response);

		# 9P-native tool-call fallback: models fine-tuned for coding emit
		# tool invocations as plain text rather than structured calls.
		# parseaction matches the first token against the live /tool
		# registry, so it fires only for real tools.  Never on end_turn:
		# that is the model's terminus, and its wrap-up prose mentions
		# tool names (INFR-21).
		if(stopreason != "tool_use" && stopreason != "end_turn" && text != "") {
			(nativetool, nativeargs) := s.al->parseaction(text);
			if(nativetool != "" && nativetool != "DONE") {
				stopreason = "tool_use";
				nativeid := sys->sprint("native-%s-%d", s.llmid, step);
				tools = (nativeid, nativetool, nativeargs) :: nil;
				text = "";
				log(s, "harness: 9P-native tool call: " + nativetool);
			}
		}

		# Show the text.  What streamed is already on the page; the parsed
		# text completes it (the prefill marker, when there are no tools,
		# is a prefix the stream never carried).
		if(text != "") {
			if(!started)
				say(s, "veltro", text);
			else if(text != streamed) {
				if(hasprefix(text, streamed))
					evc <-= ref Ev.Text(s, text[len streamed:]);
				else if(!(len text > len streamed && text[len text - len streamed:] == streamed))
					evc <-= ref Ev.Text(s, "\n" + text);
			}
		}
		if(started)
			evc <-= ref Ev.End(s);

		if(stopreason != "tool_use" || tools == nil) {
			hitlimit = 0;
			stopstate = stopreason;
			if(stopstate == "")
				stopstate = "end-turn";
			break;
		}

		if(s.cancel) {
			hitlimit = 0;
			stopstate = "cancelled";
			say(s, "note", "(cancelled)");
			break;
		}

		rev := exectools(s, tools, step);

		guidance := updatefailstreak(s, tools, rev);
		if(guidance != "" && rev != nil) {
			last := rev;
			for(tmp := tl rev; tmp != nil; tmp = tl tmp)
				last = tmp;
			(lid, lcontent) := hd last;
			lcontent += "\n\n[SYSTEM NOTE: " + guidance + "]";
			newrev: list of (string, string);
			for(rr := rev; rr != nil; rr = tl rr) {
				if(tl rr == nil)
					newrev = (lid, lcontent) :: newrev;
				else
					newrev = (hd rr) :: newrev;
			}
			rev = nil;
			for(; newrev != nil; newrev = tl newrev)
				rev = (hd newrev) :: rev;
		}
		prompt = s.al->buildtoolresults(rev);
	}

	if(hitlimit)
		say(s, "note", sys->sprint("(reached %d-step limit — send another message to continue)", s.maxsteps));
	prov("agentdone", sys->sprint("agent=%s steps=%d stop=%s", s.llmid, laststep, stopstate), nil);
	log(s, sys->sprint("turn done stop=%s steps=%d", stopstate, laststep));
	evc <-= ref Ev.Done(s);
}

# ---- LLM session setup (lucibridge's initsession) ----

# say is excluded from the definitions: the model answers with end_turn
# text, which avoids the call-then-acknowledge loop that produced
# spurious "..." replies.  A say the model emits anyway is intercepted.
sessiontools(raw: string): list of string
{
	(nil, tls) := sys->tokenize(raw, "\n");
	toollist: list of string;
	for(t := tls; t != nil; t = tl t)
		if(str->tolower(hd t) != "say")
			toollist = hd t :: toollist;
	return toollist;
}

rolesuffix(s: ref Session): string
{
	suffix := "";
	if(s.role != "") {
		p := META_PROMPT_PATH;
		if(s.role != "meta")
			p = "/lib/veltro/agents/" + s.role + ".txt";
		t := readfile(p);
		if(t != "")
			suffix += "\n\n" + strip(t);
	}
	if(s.brief != "")
		suffix += s.brief;
	suffix = substall(suffix, "%AGENT%", agentname);
	suffix = substall(suffix, "%OS%", osname);
	return suffix;
}

setsystemprompt(s: ref Session): string
{
	ns := s.al->discovernamespace();
	persona := "";
	if(s.persona != "")
		persona = readfile("/lib/veltro/agents/" + s.persona + ".txt");
	sysprompt := s.al->buildsystemprompt(ns, persona);
	suffix := rolesuffix(s);

	MAXWRITE: con 65000;
	suffixbytes := array of byte suffix;
	basebytes := array of byte sysprompt;
	if(len basebytes + len suffixbytes > MAXWRITE) {
		room := MAXWRITE - len suffixbytes;
		if(room < 0)
			room = 0;
		# Back up to a UTF-8 character boundary.
		while(room > 0) {
			b := int basebytes[room - 1];
			if(b < 16r80)
				break;
			if((b & 16rC0) != 16r80) {
				room--;
				break;
			}
			room--;
		}
		sysprompt = string basebytes[0:room];
	}
	sysprompt += suffix;
	s.al->setsystemprompt("/mnt/llm/" + s.llmid + "/system", sysprompt);
	return ns + "\n" + sysprompt;
}

llmstart(s: ref Session): string
{
	s.llmid = s.al->createsession();
	if(s.llmid == "")
		return "cannot create LLM session";

	# Low sampling temperature for the agentic loop (see AGENT_TEMP).
	# Precedence: /tmp/veltro/agent_temp (test override) > /lib/ndb/llm
	# temperature= (deployment) > the default.
	tval := strip(readfile("/tmp/veltro/agent_temp"));
	if(tval == "")
		tval = strip(ndbtemp);
	if(tval == "")
		tval = AGENT_TEMP;
	writefile("/mnt/llm/" + s.llmid + "/temperature", tval);

	if(s.model != "")
		writefile("/mnt/llm/" + s.llmid + "/model", s.model);
	if(s.think != 0)
		writefile("/mnt/llm/" + s.llmid + "/thinking", string s.think);

	# Open ask first so the session stays alive while it is set up.
	askpath := "/mnt/llm/" + s.llmid + "/ask";
	s.llmfd = sys->open(askpath, Sys->ORDWR);
	if(s.llmfd == nil)
		return sys->sprint("cannot open %s: %r", askpath);

	nsandprompt := setsystemprompt(s);

	# Anchor every response in the agent's identity: the model's turn is
	# prefilled with "[Name] ", which agentlib strips on display.
	s.al->setprefillpath("/mnt/llm/" + s.llmid + "/prefill", "[" + agentname + "] ");

	if(s.al->pathexists(toolmount)) {
		s.toolsraw = readfile(toolmount + "/tools");
		s.pathsraw = readfile(toolmount + "/paths");
		s.al->initsessiontools(s.llmid, sessiontools(s.toolsraw));
	}

	atype := s.role;
	if(atype == "")
		atype = s.persona;
	if(atype == "")
		atype = "default";
	(ns, sysprompt) := str->splitstrl(nsandprompt, "\n");
	if(sysprompt != nil)
		sysprompt = sysprompt[1:];
	prov("agentstart", sys->sprint("agent=%s agenttype=%s", s.llmid, atype), nil);
	prov("nscaps", sys->sprint("agent=%s", s.llmid), array of byte ns);
	prov("sysprompt", sys->sprint("agent=%s", s.llmid), array of byte sysprompt);
	log(s, sys->sprint("session %s, prompt %d bytes", s.llmid, len array of byte sysprompt));
	return nil;
}

llmstop(s: ref Session)
{
	if(s.llmid != "")
		s.al->closesession(s.llmid);
	s.llmid = "";
	s.llmfd = nil;
}

# ---- Session table ----

newsession(): ref Session
{
	al := load AgentLib AgentLib->PATH;
	if(al == nil)
		return nil;
	al->init();
	al->setverbose(verbose);
	al->settoolmount(toolmount);
	s := ref Session(nextsid++, al, "", nil, "", "", "", "", 0, maxsteps, 1,
		"", 1, "", "idle", 0, 0, nil, nil, nil, nil, "", "", "", 0, 0);
	sessions = s :: sessions;
	vers++;
	return s;
}

findsession(id: int): ref Session
{
	for(l := sessions; l != nil; l = tl l)
		if((hd l).id == id && !(hd l).closed)
			return hd l;
	return nil;
}

# ---- Text and log: append, with blocked readers answered ----

# Lines of model text that would read as a message header get a space.
appendtext(s: ref Session, t: string)
{
	out := "";
	for(i := 0; i < len t; i++) {
		if(s.atlinestart && i + 3 <= len t && t[i:i+3] == "== ")
			out[len out] = ' ';
		out[len out] = t[i];
		s.atlinestart = t[i] == '\n';
	}
	s.text += out;
	wake(s, Qtext);
}

appendhead(s: ref Session, role: string)
{
	if(!s.atlinestart)
		s.text += "\n";
	s.text += "== " + role + "\n";
	s.atlinestart = 1;
	wake(s, Qtext);
}

appendlog(s: ref Session, line: string)
{
	s.log += line + "\n";
	if(verbose)
		sys->fprint(stderr, "veltrosrv: %s\n", line);
	wake(s, Qlog);
}

srv: ref Styxserver;

# Answer the parked reads of a file that now has data for them.
wake(s: ref Session, ft: int)
{
	case ft {
	Qtext =>
		p := s.ptext;
		s.ptext = nil;
		data := array of byte s.text;
		for(; p != nil; p = tl p) {
			(fid, m) := hd p;
			if(int m.offset < len data)
				srv.reply(styxservers->readbytes(m, data));
			else if(!s.busy)
				srv.reply(styxservers->readbytes(m, nil));
			else
				s.ptext = (fid, m) :: s.ptext;
		}
	Qlog =>
		p := s.plog;
		s.plog = nil;
		data := array of byte s.log;
		for(; p != nil; p = tl p) {
			(fid, m) := hd p;
			if(int m.offset < len data)
				srv.reply(styxservers->readbytes(m, data));
			else if(!s.busy)
				srv.reply(styxservers->readbytes(m, nil));
			else
				s.plog = (fid, m) :: s.plog;
		}
	Qapprove =>
		if(s.approval == nil && s.busy)
			return;
		p := s.papprove;
		s.papprove = nil;
		for(; p != nil; p = tl p) {
			(nil, m) := hd p;
			if(s.approval != nil)
				srv.reply(styxservers->readstr(m, approveline(s)));
			else
				srv.reply(styxservers->readbytes(m, nil));
		}
	}
}

approveline(s: ref Session): string
{
	a := s.approval;
	return a.callid + " " + a.tool + " " + a.args + "\n";
}

unpark(l: list of (int, ref Tmsg.Read), fid, tag: int): list of (int, ref Tmsg.Read)
{
	out: list of (int, ref Tmsg.Read);
	for(; l != nil; l = tl l) {
		(f, m) := hd l;
		if((fid >= 0 && f == fid) || (tag >= 0 && m.tag == tag))
			continue;
		out = (f, m) :: out;
	}
	return out;
}

unparkall(fid, tag: int)
{
	for(l := sessions; l != nil; l = tl l) {
		s := hd l;
		s.ptext = unpark(s.ptext, fid, tag);
		s.plog = unpark(s.plog, fid, tag);
		s.papprove = unpark(s.papprove, fid, tag);
	}
}

# ---- ctl ----

ctl(s: ref Session, line: string): string
{
	line = strip(line);
	(verb, rest) := str->splitl(line, " \t");
	rest = str->drop(rest, " \t");
	case verb {
	"cancel" =>
		if(!s.busy)
			return nil;
		s.cancel = 1;
		if(s.approval != nil) {
			s.approval.reply <-= 0;
			s.approval = nil;
		}
	"reset" =>
		if(s.busy)
			return "busy";
		llmstop(s);
		appendhead(s, "note");
		appendtext(s, "(session reset)\n");
	"close" =>
		if(s.busy)
			return "busy";
		llmstop(s);
		s.closed = 1;
		vers++;
	"persona" =>
		if(rest != "" && !safename(rest))
			return "bad persona name";
		if(rest != "" && readfile("/lib/veltro/agents/" + rest + ".txt") == "")
			return "no such persona";
		s.persona = rest;
		if(s.llmid != "")
			setsystemprompt(s);
	"role" =>
		if(rest != "" && !safename(rest))
			return "bad role name";
		if(rest != "" && rest != "meta" && readfile("/lib/veltro/agents/" + rest + ".txt") == "")
			return "no such role";
		s.role = rest;
		if(s.llmid != "")
			setsystemprompt(s);
	"brief" =>
		s.brief += "\n\n" + rest;
		if(s.llmid != "")
			setsystemprompt(s);
		prov("task", sys->sprint("agent=%s", s.llmid), array of byte rest);
	"model" =>
		s.model = rest;
		if(s.llmid != "" && rest != "")
			writefile("/mnt/llm/" + s.llmid + "/model", rest);
	"think" =>
		(n, r) := str->toint(rest, 10);
		if(r != "" || n < 0)
			return "think needs a non-negative integer";
		s.think = n;
		if(s.llmid != "")
			writefile("/mnt/llm/" + s.llmid + "/thinking", string n);
	"maxsteps" =>
		(n, r) := str->toint(rest, 10);
		if(r != "" || n < 1)
			return "maxsteps needs a positive integer";
		if(n > MAX_MAX_STEPS)
			n = MAX_MAX_STEPS;
		s.maxsteps = n;
	"gate" =>
		case rest {
		"on" =>		s.gate = 1;
		"off" =>	s.gate = 0;
		* =>		return "gate on|off";
		}
	* =>
		return "unknown control request";
	}
	return nil;
}

ctlread(s: ref Session): string
{
	gate := "off";
	if(s.gate)
		gate = "on";
	return sys->sprint("persona=%s role=%s model=%s think=%d maxsteps=%d gate=%s llm=%s busy=%d\n",
		s.persona, s.role, s.model, s.think, s.maxsteps, gate, s.llmid, s.busy);
}

# ---- 9P ----

MKPATH(id, ft: int): big
{
	return big ((id << 8) | ft);
}

SESSID(path: big): int
{
	return (int path >> 8) & 16rFFFFFF;
}

FTYPE(path: big): int
{
	return int path & 16rFF;
}

dir(name: string, perm: int, path: big): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = path;
	d.qid.vers = vers;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

dirgen(path: big): (ref Sys->Dir, string)
{
	ft := FTYPE(path);
	sid := SESSID(path);
	case ft {
	Qroot =>	return (dir(".", Sys->DMDIR|8r555, path), nil);
	Qnew =>		return (dir("new", 8r444, path), nil);
	}
	if(findsession(sid) == nil)
		return (nil, Enotfound);
	case ft {
	Qsessdir =>	return (dir(string sid, Sys->DMDIR|8r555, path), nil);
	Qctl =>		return (dir("ctl", 8r644, path), nil);
	Qinput =>	return (dir("input", 8r222, path), nil);
	Qtext =>	return (dir("text", 8r444, path), nil);
	Qlog =>		return (dir("log", 8r444, path), nil);
	Qstatus =>	return (dir("status", 8r444, path), nil);
	Qapprove =>	return (dir("approve", 8r644, path), nil);
	}
	return (nil, Enotfound);
}

SESSFILES: con 6;

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);
		Walk =>
			ft := FTYPE(n.path);
			sid := SESSID(n.path);
			case ft {
			Qroot =>
				case n.name {
				".." =>		;
				"new" =>	n.path = MKPATH(0, Qnew);
				* =>
					(id, r) := str->toint(n.name, 10);
					if(r != "" || findsession(id) == nil) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					n.path = MKPATH(id, Qsessdir);
				}
			Qsessdir =>
				case n.name {
				".." =>		n.path = MKPATH(0, Qroot);
				"ctl" =>	n.path = MKPATH(sid, Qctl);
				"input" =>	n.path = MKPATH(sid, Qinput);
				"text" =>	n.path = MKPATH(sid, Qtext);
				"log" =>	n.path = MKPATH(sid, Qlog);
				"status" =>	n.path = MKPATH(sid, Qstatus);
				"approve" =>	n.path = MKPATH(sid, Qapprove);
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
			* =>
				n.reply <-= (nil, Enotfound);
				continue;
			}
			n.reply <-= dirgen(n.path);
		Readdir =>
			ft := FTYPE(n.path);
			sid := SESSID(n.path);
			case ft {
			Qroot =>
				# new, then the live sessions, oldest first
				live: list of ref Session;
				for(l := sessions; l != nil; l = tl l)
					if(!(hd l).closed)
						live = hd l :: live;
				i := 0;
				sent := 0;
				if(n.offset == 0) {
					n.reply <-= dirgen(MKPATH(0, Qnew));
					sent++;
				}
				i = 1;
				for(; live != nil && sent < n.count; live = tl live) {
					if(i >= n.offset) {
						n.reply <-= dirgen(MKPATH((hd live).id, Qsessdir));
						sent++;
					}
					i++;
				}
			Qsessdir =>
				fts := array[] of {Qctl, Qinput, Qtext, Qlog, Qstatus, Qapprove};
				for(i := n.offset; i < len fts && i < n.offset + n.count; i++)
					n.reply <-= dirgen(MKPATH(sid, fts[i]));
			}
			n.reply <-= (nil, nil);
		}
	}
}

serveloop(tchanc: chan of chan of ref Tmsg, errc: chan of string, caps: ref NsConstruct->Capabilities)
{
	# The agent's namespace, from here on: what was granted, nothing else.
	# A failure is reported to init, which fails; nothing is served.
	if(sys->pctl(Sys->FORKNS, nil) < 0) {
		errc <-= sys->sprint("cannot fork namespace: %r");
		return;
	}
	if(sys->pctl(Sys->NODEVS, nil) < 0) {
		errc <-= sys->sprint("cannot disable device attachment: %r");
		return;
	}
	nserr := nsconstruct->restrictns(caps);
	if(nserr != nil) {
		errc <-= "namespace restriction failed: " + nserr;
		return;
	}
	nsconstruct->emitmanifest(caps, "/tmp/veltro/.ns/manifest");
	if(verbose)
		sys->fprint(stderr, "veltrosrv: namespace restricted\n");
	errc <-= nil;
	tchan := <-tchanc;
	if(tchan == nil)
		return;

Serve:
	for(;;) alt {
	ev := <-evc =>
		s := ev.s;
		pick e := ev {
		Text =>		appendtext(s, e.t);
		Head =>		appendhead(s, e.role);
		Log =>		appendlog(s, e.line);
		End =>
			if(!s.atlinestart)
				appendtext(s, "\n");
		Status =>
			s.status = e.st;
		Approve =>
			s.approval = e.a;
			s.status = "blocked";
			wake(s, Qapprove);
		Done =>
			s.busy = 0;
			s.cancel = 0;
			s.status = "idle";
			wake(s, Qtext);
			wake(s, Qlog);
			wake(s, Qapprove);
		}
	gm := <-tchan =>
		if(gm == nil)
			break Serve;
		pick m := gm {
		Readerror =>
			sys->fprint(stderr, "veltrosrv: fatal read error: %s\n", m.error);
			break Serve;
		Flush =>
			unparkall(-1, m.oldtag);
			srv.reply(ref Rmsg.Flush(m.tag));
		Open =>
			c := srv.getfid(m.fid);
			if(c == nil) {
				srv.open(m);
				break;
			}
			mode := styxservers->openmode(m.mode);
			if(mode < 0) {
				srv.reply(ref Rmsg.Error(m.tag, Ebadarg));
				break;
			}
			qid := Qid(c.path, 0, c.qtype);
			c.open(mode, qid);
			srv.reply(ref Rmsg.Open(m.tag, qid, srv.iounit()));
		Read =>
			(c, err) := srv.canread(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(c.qtype & Sys->QTDIR) {
				srv.read(m);
				break;
			}
			ft := FTYPE(c.path);
			sid := SESSID(c.path);
			if(ft == Qnew) {
				if(m.offset > big 0) {
					srv.reply(styxservers->readbytes(m, nil));
					break;
				}
				s := newsession();
				if(s == nil) {
					srv.reply(ref Rmsg.Error(m.tag, "cannot start session"));
					break;
				}
				srv.reply(styxservers->readstr(m, string s.id + "\n"));
				break;
			}
			s := findsession(sid);
			if(s == nil) {
				srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				break;
			}
			case ft {
			Qctl =>
				srv.reply(styxservers->readstr(m, ctlread(s)));
			Qstatus =>
				srv.reply(styxservers->readstr(m, s.status + "\n"));
			Qtext =>
				data := array of byte s.text;
				if(int m.offset < len data)
					srv.reply(styxservers->readbytes(m, data));
				else if(!s.busy)
					srv.reply(styxservers->readbytes(m, nil));
				else
					s.ptext = (m.fid, m) :: s.ptext;
			Qlog =>
				data := array of byte s.log;
				if(int m.offset < len data)
					srv.reply(styxservers->readbytes(m, data));
				else if(!s.busy)
					srv.reply(styxservers->readbytes(m, nil));
				else
					s.plog = (m.fid, m) :: s.plog;
			Qapprove =>
				if(m.offset > big 0)
					srv.reply(styxservers->readbytes(m, nil));
				else if(s.approval != nil)
					srv.reply(styxservers->readstr(m, approveline(s)));
				else if(!s.busy)
					srv.reply(styxservers->readbytes(m, nil));
				else
					s.papprove = (m.fid, m) :: s.papprove;
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}
		Write =>
			(c, err) := srv.canwrite(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			ft := FTYPE(c.path);
			s := findsession(SESSID(c.path));
			if(s == nil) {
				srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				break;
			}
			data := string m.data;
			case ft {
			Qctl =>
				e := ctl(s, data);
				if(e != nil)
					srv.reply(ref Rmsg.Error(m.tag, e));
				else
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qinput =>
				if(len data > 0 && data[len data - 1] == '\n')
					data = data[0:len data - 1];
				if(strip(data) == "") {
					srv.reply(ref Rmsg.Error(m.tag, "empty message"));
					break;
				}
				if(s.busy) {
					srv.reply(ref Rmsg.Error(m.tag, "busy"));
					break;
				}
				if(s.llmid == "") {
					e := llmstart(s);
					if(e != nil) {
						srv.reply(ref Rmsg.Error(m.tag, e));
						break;
					}
				}
				appendhead(s, "user");
				appendtext(s, data + "\n");
				s.busy = 1;
				s.cancel = 0;
				s.status = "working";
				spawn turn(s, data);
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qapprove =>
				(verb, rest) := str->splitl(strip(data), " \t");
				rest = str->drop(rest, " \t");
				if(s.approval == nil || rest != s.approval.callid) {
					srv.reply(ref Rmsg.Error(m.tag, "no such call awaiting approval"));
					break;
				}
				case verb {
				"allow" =>
					s.approval.reply <-= 1;
					s.approval = nil;
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				"deny" =>
					s.approval.reply <-= 0;
					s.approval = nil;
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				* =>
					srv.reply(ref Rmsg.Error(m.tag, "allow <callid> | deny <callid>"));
				}
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}
		Clunk =>
			unparkall(m.fid, -1);
			srv.clunk(m);
		* =>
			srv.default(gm);
		}
	}
}

# ---- Startup ----

usage()
{
	sys->fprint(stderr, "usage: veltrosrv [-v] [-n maxsteps] [-m toolmount] [-S scratchdir] [-a tag] [-t tools] [-p paths] [-M mountpoint]\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	str = load String String->PATH;
	arg = load Arg Arg->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nsconstruct = load NsConstruct NsConstruct->PATH;
	if(str == nil || arg == nil || styx == nil || styxservers == nil || nsconstruct == nil)
		fatal("cannot load modules");
	styx->init();
	styxservers->init(styx);
	nsconstruct->init();

	toolargs, pathargs: list of string;
	arg->init(args);
	while((c := arg->opt()) != 0)
		case c {
		'v' =>	verbose = 1;
		'n' =>
			(maxsteps, nil) = str->toint(arg->earg(), 10);
			if(maxsteps < 1)
				maxsteps = 1;
			if(maxsteps > MAX_MAX_STEPS)
				maxsteps = MAX_MAX_STEPS;
		'm' =>	toolmount = arg->earg();
		'S' =>	scratchdir = arg->earg();
		'a' =>	provtag = arg->earg();
		't' =>	(nil, toolargs) = sys->tokenize(arg->earg(), ",");
		'p' =>	(nil, pathargs) = sys->tokenize(arg->earg(), ",");
		'M' =>	mountpt = arg->earg();
		* =>	usage();
		}
	if(arg->argv() != nil)
		usage();

	sys->pctl(Sys->FORKFD, nil);

	user = strip(readfile("/dev/user"));
	if(user == "")
		user = "inferno";
	an := strip(readfile(AGENT_NAME_PATH));
	if(an != "")
		agentname = an;
	on := strip(readfile(OS_NAME_PATH));
	if(on != "")
		osname = on;
	ndbtemp = readndbfield("/lib/ndb/llm", "temperature");

	if(!exists(toolmount) || !exists(toolmount + "/tools"))
		sys->fprint(stderr, "veltrosrv: warning: %s not mounted (run tools9p first); chat only\n", toolmount);

	# -t: make the tool server's active set exactly this.
	if(toolargs != nil && exists(toolmount)) {
		(nil, curtl) := sys->tokenize(readfile(toolmount + "/tools"), "\n");
		for(w := toolargs; w != nil; w = tl w)
			if(!member(curtl, hd w))
				writefile(toolctlmount(toolmount) + "/ctl", "add " + hd w);
		for(cl := curtl; cl != nil; cl = tl cl)
			if(!member(toolargs, hd cl))
				writefile(toolctlmount(toolmount) + "/ctl", "remove " + hd cl);
	}

	# -p: register each path with the tool server (so tool workers and
	# /tool/paths see it) and grant it to this namespace.  :ro/:rw become
	# the tool server's "path perm" form.
	pathlist: list of string;
	for(pp := pathargs; pp != nil; pp = tl pp) {
		parg := hd pp;
		bare := parg;
		if(len parg > 3 && (parg[len parg - 3:] == ":ro" || parg[len parg - 3:] == ":rw")) {
			bare = parg[0:len parg - 3];
			parg = bare + " " + parg[len parg - 2:];
		}
		if(exists(toolmount))
			writefile(toolctlmount(toolmount) + "/ctl", "bindpath " + parg);
		pathlist = bare :: pathlist;
	}

	# Read the tool list before restriction so the grants match it:
	# exec needs sh.dis and cmd/; xenith needs /chan.
	(nil, toollist) := sys->tokenize(readfile(toolmount + "/tools"), "\n");
	xgrant := 0;
	for(tl2 := toollist; tl2 != nil; tl2 = tl tl2)
		if(hd tl2 == "xenith")
			xgrant = 1;

	# The agent's name, readable by the user process after FORKNS.
	sys->create("/tmp/veltro", Sys->OREAD, 8r700 | Sys->DMDIR);
	sys->create("/tmp/veltro/.ns", Sys->OREAD, 8r700 | Sys->DMDIR);
	afd := sys->create("/tmp/veltro/.ns/agentname", Sys->OWRITE, 8r644);
	if(afd != nil)
		sys->fprint(afd, "%s", agentname);
	afd = nil;

	# Only the shared session pointer survives when /env is allowlisted.
	if(!exists("/env/VELTRO_SESSION")) {
		efd := sys->create("/env/VELTRO_SESSION", Sys->OWRITE, 8r600);
		if(efd == nil)
			fatal(sys->sprint("cannot create session environment slot: %r"));
	}

	initprovenance();
	if(auditprov != nil)
		pathlist = "/mnt/audit/log" :: pathlist;
	# The loop opens its model session by path after restriction.
	pathlist = "/mnt/llm" :: pathlist;

	caps := ref NsConstruct->Capabilities(
		toollist, pathlist, nil, nil, nil, nil, 0, xgrant, -1, nil, nil);

	# The grants are checked, and the namespace restricted, before
	# anything else is started or required: a bad grant is refused as
	# such, and leaves nothing running.
	evc = chan[64] of ref Ev;
	errc := chan of string;
	tchanc := chan of chan of ref Tmsg;
	spawn serveloop(tchanc, errc, caps);
	if((err := <-errc) != nil)
		fatal(err);
	if(sys->open("/mnt/llm/new", Sys->OREAD) == nil) {
		tchanc <-= nil;
		fatal("/mnt/llm not served (start llmsrv first)");
	}

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		tchanc <-= nil;
		fatal(sys->sprint("cannot create pipe: %r"));
	}
	navops := chan of ref Navop;
	spawn navigator(navops);
	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(fds[0], Navigator.new(navops), MKPATH(0, Qroot));
	srv.msize = 65536 + Styx->IOHDRSZ;
	fds[0] = nil;
	tchanc <-= tchan;

	sys->create(mountpt, Sys->OREAD, 8r755 | Sys->DMDIR);
	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL, nil) < 0)
		fatal(sys->sprint("mount %s failed: %r", mountpt));
	fds[1] = nil;
	if(verbose)
		sys->fprint(stderr, "veltrosrv: serving %s (tools at %s)\n", mountpt, toolmount);
}

member(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

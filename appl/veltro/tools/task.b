implement ToolTask;

#
# task - Task delegation tool for Veltro meta-agent
#
# Creates, monitors, and manages delegated AI tasks.
# Each task gets its own activity, tools9p, and lucibridge.
#
# Commands:
#   create label=<name> [tools=<csv>] [paths=<csv>] [urgency=<0-2>]
#          [category=<text>] [agenttype=<type>]
#          [brief=<text>] [instructions=<text>]
#   status <id>
#   list
#   close <id>
#
# Unknown create args are rejected loudly (with the valid set listed) so the
# caller — typically an LLM — gets a clear signal instead of having silently
# dropped fields. model= is taken and ignored: the model is the server's.
# agenttype= names a prompt under /lib/veltro/agents/<type>.txt and sets
# category-specific defaults (see AGENT_DEFAULTS below).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "../tool.m";

ToolTask: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

UI_MOUNT: con "/mnt/ui";

# Keys accepted by `task create`. Anything else is rejected; this is the
# signal the LLM relies on to self-correct when it hallucinates fields.
# Initialized in init() since Limbo `con` does not support array literals.
createkeys: list of string;

# Per-agenttype defaults applied when a field is omitted. Fields the caller
# supplies always win — agenttype only fills blanks. Each tuple is
# (name, unused, default-tools-csv).
#
# coder: the tool surface a coding loop needs (limbo writes and compiles).
# research: a web-research loop (decompose -> fan out -> synthesize -> cite),
# with search/fetch and spawn for parallel sub-questions.
# verify: an adversarial "run it, don't read it" checker (exec + read tools,
# no write/edit — read-only on the project) that emits a PASS/FAIL/PARTIAL
# verdict backed by captured output.
# Tools must still be in the delegation budget; missing ones are dropped at
# provision time.
agentdefs: list of (string, string, string);

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";

	createkeys = "label" :: "tools" :: "paths" :: "urgency" :: "brief" ::
		"instructions" :: "category" :: "model" :: "agenttype" :: nil;

	# An agent type is a prompt and its tools.  Not a model: the model is
	# the server's (llmsrv -M), and a task that named one the server did
	# not have failed outright ("daedalus" for coder, on a server of one).
	agentdefs =
		("coder", "", "read,write,edit,find,grep,list,limbo") ::
		("research", "", "websearch,webfetch,read,find,grep,memory,plan,todo,gap,spawn,present") ::
		("verify", "", "read,list,find,search,grep,exec,plan,todo,gap,present") ::
		nil;

	return nil;
}

name(): string
{
	return "task";
}

doc(): string
{
	return "task - Create and manage delegated AI tasks\n\n" +
		"Commands:\n" +
		"  create label=<name> [tools=<csv>] [paths=<csv>] [urgency=<0-2>]\n" +
		"         [category=<text>] [agenttype=<type>]\n" +
		"         [brief=<text>] [instructions=<text>]\n" +
		"      Create new task with isolated tools and conversation.\n" +
		"      Tools validated against delegation budget.\n" +
		"      instructions= sets structured directives injected into the TA system prompt.\n" +
		"      The model is the server's; a task cannot choose one (model= is ignored).\n" +
		"      agenttype= picks a prompt under /lib/veltro/agents/<type>.txt and\n" +
		"        its tools (e.g. agenttype=coder ⇒\n" +
		"        tools=read,write,edit,find,grep,list,limbo).\n" +
		"      Unknown args are rejected with the list of valid keys.\n" +
		"      Put tools=/paths=/agenttype= before brief=/instructions=.\n" +
		"      brief=/instructions= consume the rest of the line.\n" +
		"  status <id>     Show task status and urgency\n" +
		"  list            List all active tasks\n" +
		"  result <id>     Get the task agent's final report (its answer)\n" +
		"  close <id>      Archive a completed task\n\n" +
		"Each task gets its own conversation, tools, and filesystem overlay.\n" +
		"Use for work that should happen in parallel or needs isolation.\n\n" +
		"Examples:\n" +
		"  task create label=Review tools=read,list,find,grep\n" +
		"  task create label=Editor instructions=\"Open /lib/veltro/system.txt and edit it\"\n" +
		"  task create label=BugFix agenttype=coder brief=\"fix the bug in cat.b\"\n" +
		"  task create label=Refactor tools=read,write,edit\n" +
		"  task list\n" +
		"  task status 2\n" +
		"  task close 2";
}

schema(): string
{
	return "{" +
		"\"name\":\"task\"," +
		"\"description\":\"Create and manage delegated AI agents that run AUTONOMOUSLY from their brief. Put all work detail in brief=/instructions= at create time; you CANNOT send a task content or commands afterward, and you never do the work yourself. After create, tell the user what you started and end your turn: a [task-event] message brings you the task's report when it finishes. Do not poll status in a loop. Never re-create a task that is already running. A task's writes to the user's folders are staged, not applied: 'promote <id>' applies them once the user agrees (the user is asked to allow it), 'revert <id>' discards them.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\",\"description\":\"One of: create, status, list, result, close, promote, revert. To make a task do work, describe it in args brief=/instructions= at create time. When a task reports done, use 'result <id>' to get its final answer back — do NOT re-create the task to retrieve output.\"}," +
				"\"args\":{\"type\":\"string\",\"description\":\"For create: key=value attributes. Put authority attrs first: label=<name> [tools=<csv>] [paths=<csv>] [urgency=<0-2>] [category=<text>] [agenttype=<type>] [brief=<text>] [instructions=<text>]. brief=/instructions= consume the rest of the line. For status/result/close/promote/revert: the task id. Omit for list.\"}" +
			"}," +
			"\"required\":[\"command\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		return "error: not initialized";
	args = strip(args);
	if(args == "")
		return "error: no command. Use: create, status, list, result, close, promote, revert";

	(cmd, rest) := splitfirst(args);
	cmd = str->tolower(cmd);

	case cmd {
	"create" =>
		return docreate(rest);
	"status" =>
		return dostatus(rest);
	"list" =>
		return dolist();
	"result" =>
		return doresult(rest);
	"close" =>
		return doclose(rest);
	"promote" =>
		return dostaged(rest, "/promote");
	"revert" =>
		return dostaged(rest, "/revert");
	* =>
		# A create with its verb left out ("label=X tools=... brief=..."):
		# models do this, and only a create takes these attributes.
		if(iskeyat(args, 0) && (hasprefix(args, "label=") ||
		   hasprefix(args, "tools=") || hasprefix(args, "brief=")))
			return docreate(args);
		return sys->sprint("error: unknown command '%s'. Use: create, status, list, result, close, promote, revert", cmd);
	}
}

# Parse key=value attributes from argument string
# Handles quoted values: label="Write poetry" tools=read,list
parseattrs(s: string): list of (string, string)
{
	result: list of (string, string);
	i := 0;
	for(;;) {
		# skip whitespace
		while(i < len s && (s[i] == ' ' || s[i] == '\t'))
			i++;
		if(i >= len s)
			break;
		# find key
		kstart := i;
		while(i < len s && s[i] != '=' && s[i] != ' ')
			i++;
		if(i >= len s || s[i] != '=') {
			# bare word — skip
			while(i < len s && s[i] != ' ')
				i++;
			continue;
		}
		key := s[kstart:i];
		i++;	# skip =
		# find value — handle quoted strings
		val := "";
		if(isterminaltextkey(key)) {
			# brief=/instructions= are terminal free text. Treat the rest of
			# the argument string as content so hostile copied text cannot
			# smuggle later tools=/paths=/model= attributes. If the whole
			# terminal value is quoted, strip that single enclosing pair for
			# convenience, but never resume attribute parsing after it.
			val = s[i:];
			while(len val > 0 && (val[0] == ' ' || val[0] == '\t'))
				val = val[1:];
			while(len val > 0 && (val[len val - 1] == ' ' || val[len val - 1] == '\t'))
				val = val[0:len val - 1];
			if(len val >= 2 && (val[0] == '"' || val[0] == '\'') &&
			   val[len val - 1] == val[0])
				val = val[1:len val - 1];
			i = len s;
		} else if(i < len s && (s[i] == '"' || s[i] == '\'')) {
			q := s[i];
			i++;	# skip opening quote
			vstart := i;
			while(i < len s && s[i] != q)
				i++;
			val = s[vstart:i];
			if(i < len s)
				i++;	# skip closing quote
		} else {
			# Unquoted value. Extend it across spaces until the next token
			# that is itself a known key=… . LLMs routinely omit quotes around
			# multi-word brief=/instructions= values; without this, the value
			# would truncate at the first space (brief=research ponies → just
			# "research") and the rest would be silently dropped as bare words.
			vstart := i;
			for(;;) {
				# consume the current word
				while(i < len s && s[i] != ' ' && s[i] != '\t')
					i++;
				# peek past whitespace to the start of the next token
				j := i;
				while(j < len s && (s[j] == ' ' || s[j] == '\t'))
					j++;
				if(j >= len s || iskeyat(s, j))
					break;
				i = j;	# next token is not a known key — fold it into the value
			}
			val = s[vstart:i];
			while(len val > 0 && (val[len val - 1] == ' ' || val[len val - 1] == '\t'))
				val = val[0:len val - 1];
		}
		result = (key, val) :: result;
	}
	return result;
}

isterminaltextkey(key: string): int
{
	return key == "brief" || key == "instructions";
}

# Does a known "key=" token begin at position i (the first non-space char of
# a token)? Used by parseattrs to decide where an unquoted value ends.
iskeyat(s: string, i: int): int
{
	j := i;
	while(j < len s && s[j] != '=' && s[j] != ' ' && s[j] != '\t')
		j++;
	if(j >= len s || s[j] != '=')
		return 0;
	return strlistcontains(createkeys, s[i:j]);
}

getattr(attrs: list of (string, string), key: string): string
{
	for(; attrs != nil; attrs = tl attrs) {
		(k, v) := hd attrs;
		if(k == key)
			return v;
	}
	return "";
}

# The folders text names that the task would see only if granted, that
# this agent holds (held: its own grants, from /tool/paths), and that
# paths= does not give.  Nothing is granted here: the caller refuses the
# create and suggests these, for the agent to grant itself or leave out.
# Prose names a path; it never confers one (a brief can be copied mail
# or a web page).  Only ordinary file trees are suggested: /n/local and
# /usr, never services, control files or task metadata.  A named file
# gives its folder (a writable grant is a cowfs folder), said as such.
ungranted(text, paths: string, held: list of string): list of string
{
	(nil, grants) := sys->tokenize(paths, ",");
	need: list of string;
	(nil, words) := sys->tokenize(text, " \t\n");
	for(; words != nil; words = tl words) {
		w := hd words;
		while(len w > 0 && strchr("\"'`(<[", w[0]))
			w = w[1:];
		while(len w > 0 && strchr("\"'`)>],.;:!?/", w[len w - 1]))
			w = w[0:len w - 1];
		if(!plaintree(w) || !covered(w, held))
			continue;
		(ok, d) := sys->stat(w);
		if(ok < 0 || (d.mode & Sys->DMDIR) == 0) {
			for(i := len w - 1; i > 0 && w[i] != '/'; i--)
				;
			w = w[0:i];
		}
		if(!plaintree(w) || !covered(w, held) || covered(w, grants) || strlistcontains(need, w))
			continue;
		need = w :: need;
	}
	return need;
}

# An ordinary file tree of the user's, below its root: /n/local/<...> or
# /usr/<...>.  Everything else a task sees either way or gets only by
# capability, and is never suggested.
plaintree(p: string): int
{
	if(hasprefix(p, "/n/local/") && len p > len "/n/local/")
		return !hasdotdot(p);
	if(hasprefix(p, "/usr/") && len p > len "/usr/")
		return !hasdotdot(p);
	return 0;
}

hasdotdot(p: string): int
{
	(nil, parts) := sys->tokenize(p, "/");
	for(; parts != nil; parts = tl parts)
		if(hd parts == ".." || hd parts == ".")
			return 1;
	return 0;
}

# The paths of a grants listing (/tool/paths: "<path> <perm>" a line).
heldpaths(listing: string): list of string
{
	held: list of string;
	for(lines := splitlines(listing); lines != nil; lines = tl lines) {
		(nil, f) := sys->tokenize(hd lines, " \t");
		if(f != nil && hd f != "/tmp/veltro/scratch")
			held = hd f :: held;
	}
	return held;
}

plural(l: list of string, one, many: string): string
{
	if(l != nil && tl l != nil)
		return many;
	return one;
}

covered(p: string, grants: list of string): int
{
	for(; grants != nil; grants = tl grants) {
		g := strip(hd grants);
		while(len g > 1 && g[len g - 1] == '/')
			g = g[0:len g - 1];
		if(g != "" && (p == g || hasprefix(p, g + "/")))
			return 1;
	}
	return 0;
}

strchr(set: string, c: int): int
{
	for(i := 0; i < len set; i++)
		if(set[i] == c)
			return 1;
	return 0;
}

docreate(args: string): string
{
	attrs := parseattrs(args);

	# Reject unknown keys before doing any work. The error names the offender
	# and lists the full valid set so a model can correct on the next attempt
	# instead of having the field silently dropped (the v3-era behaviour).
	badkey := firstunknownkey(attrs);
	if(badkey != "")
		return sys->sprint("error: unknown arg '%s' (valid: %s). See INFR-55.",
			badkey, joinstrs(createkeys, ", "));

	label := getattr(attrs, "label");
	if(label == "")
		return "error: label required. Usage: create label=<name> [tools=<csv>]";
	label = safeattrtext(label);
	if(label == "")
		return "error: label contains no safe display text";

	agenttype := str->tolower(getattr(attrs, "agenttype"));
	(deftools, nil) := agentdefaults(agenttype);
	if(agenttype != "" && deftools == "")
		return sys->sprint("error: unknown agenttype '%s' (valid: %s).",
			agenttype, knownagenttypes());

	# model= is taken and ignored: the model is the server's.
	modelnote := "";
	if(getattr(attrs, "model") != "")
		modelnote = " (model= ignored: the model is the server's)";

	toolsarg := getattr(attrs, "tools");
	if(toolsarg == "" && deftools != "")
		toolsarg = deftools;
	urgstr := getattr(attrs, "urgency");

	# Validate tools against budget
	if(toolsarg != "") {
		budgetstr := readfile("/tool/budget");
		if(budgetstr != nil) {
			budget := parsetoollist(budgetstr);
			(nil, reqtoks) := sys->tokenize(toolsarg, ",");
			for(; reqtoks != nil; reqtoks = tl reqtoks) {
				t := strip(hd reqtoks);
				if(t == "")
					continue;
				if(!strlistcontains(budget, t))
					return sys->sprint("error: tool '%s' not in delegation budget", t);
			}
		}
	}

	# A task sees only what paths= grants it. A brief that names a folder
	# of the user's without granting it creates a task that cannot open the
	# folder it was sent to work on, and answers that the path does not
	# exist (mistral-small3.2 did). Refuse it and say what could be granted,
	# before anything is made.  Nothing is granted from the brief: it is
	# text, possibly copied from mail or a page, and a grant is only ever
	# what paths= says (security review, 2026-10).
	need := ungranted(getattr(attrs, "brief") + " " + getattr(attrs, "instructions"),
		getattr(attrs, "paths"), heldpaths(readfile("/tool/paths")));
	if(need != nil) {
		p := joinstrs(need, ",");
		if(getattr(attrs, "paths") != "")
			p = getattr(attrs, "paths") + "," + p;
		# Say whose move it is: told "unless you grant it", mistral-small3.2
		# asked the user to bind a folder that was already bound.
		return sys->sprint("error: not created: the brief names a path in %s.  You have %s, but a task sees only what its create's paths= gives it.  " +
			"The user has nothing to do.  If the task needs %s, call task create again, the same but with paths=%s before brief=; " +
			"it gets the whole folder.  If it should not have %s, leave that path out of the brief.\nsuggest: paths=%s",
			joinstrs(need, " and "), plural(need, "that folder", "those folders"), plural(need, "it", "them"), p,
			plural(need, "it", "them"), p);
	}

	# Idempotency guard (INFR-390): the meta-agent repeatedly re-creates the
	# same-labelled task while waiting on it, spawning duplicate activities.
	# Refuse a duplicate active label and point it at the existing task.
	dupid := findlabelledtask(label);
	if(dupid > 0)
		# Not an error: the work is under way.  Worded as a refusal, it
		# read to the model as a broken tool, and it told the user so.
		return sys->sprint("task \"%s\" already exists as activity %d and is under way: your earlier create worked. Do not create it again; tell the user it has started, and its report will come as a [task-event].", label, dupid);

	# Create activity via /mnt/ui/ctl
	ctlpath := UI_MOUNT + "/ctl";
	err := writefile(ctlpath, "activity create " + label);
	if(err != nil)
		return "error: " + err;

	# Read back the new activity id (last activity in list)
	info := readfile(UI_MOUNT + "/ctl");
	if(info == nil)
		return "error: cannot read /mnt/ui/ctl after create";

	# Parse "activities: id1 id2 ... idN" — idN is the newest
	newid := -1;
	lines := splitlines(strip(info));
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(hasprefix(line, "activities:")) {
			rest := strip(line[len "activities:":]);
			(nil, toks) := sys->tokenize(rest, " ");
			lastid := "";
			for(; toks != nil; toks = tl toks)
				lastid = hd toks;
			if(lastid != "")
				(newid, nil) = str->toint(lastid, 10);
		}
	}

	if(newid < 0)
		(newid, nil) = str->toint(strip(readfile(UI_MOUNT + "/activity/current")), 10);
	if(newid < 0)
		return "error: could not determine new activity id";

	# Set urgency if specified
	if(urgstr != "") {
		writefile(sys->sprint("%s/activity/%d/urgency", UI_MOUNT, newid), urgstr);
	}

	# Write task brief to a file that lucibridge reads at startup.
	# This goes into the LLM system prompt only — no visible chat message.
	brief := getattr(attrs, "brief");
	if(brief == "")
		brief = "Your assignment: " + label + ". Begin working on this now, " +
			"using your tools. Work out the concrete steps yourself and carry " +
			"them out autonomously. Do not greet or ask what to do — the label " +
			"above is your task. If you genuinely cannot proceed without a " +
			"specific missing detail, ask one concise question; otherwise make " +
			"a reasonable assumption and proceed.";
	briefpath := sys->sprint("/tmp/veltro/tasks/brief.%d", newid);
	bfd := sys->create(briefpath, Sys->OWRITE, 8r644);
	if(bfd != nil) {
		bb := array of byte brief;
		sys->write(bfd, bb, len bb);
		bfd = nil;
	}

	# Write structured instructions if provided
	instructions := getattr(attrs, "instructions");
	if(instructions != "") {
		instrpath := sys->sprint("/tmp/veltro/tasks/instructions.%d", newid);
		ifd := sys->create(instrpath, Sys->OWRITE, 8r644);
		if(ifd != nil) {
			ib := array of byte instructions;
			sys->write(ifd, ib, len ib);
			ifd = nil;
		}
	}

	# Model and agenttype are propagated to the child lucibridge via the
	# same /tmp/veltro/tasks/<key>.<id> pattern as brief/instructions. lucibridge
	# reads these files at startup (before opening the LLM session). Files
	# are only written when explicitly set so the absence still means
	# "inherit parent session's model" / "use default task prompt".
	if(agenttype != "") {
		apath := sys->sprint("/tmp/veltro/tasks/agenttype.%d", newid);
		afd := sys->create(apath, Sys->OWRITE, 8r644);
		if(afd != nil) {
			ab := array of byte agenttype;
			sys->write(afd, ab, len ab);
			afd = nil;
		}
	}

	# Push metadata to dashboard if available
	dashctl := "/n/dashboard/ctl";
	dfd := sys->open(dashctl, Sys->OWRITE);
	if(dfd != nil) {
		dfd = nil;
		writefile(dashctl, "synopsis " + string newid + " " + label);
		category := getattr(attrs, "category");
		if(category != "")
			writefile(dashctl, "categorize " + string newid + " " + safeattrtext(category));
		if(instructions != "")
			writefile(dashctl, "instructions " + string newid + " " + safeattrtext(instructions));
	}

	# Delegate provisioning to tools9p's narrow child-provision path.
	# The server runs in the unrestricted parent namespace, but it validates
	# child tools and paths as a subset of the current grants before spawning.
	provcmd := "provision " + string newid;
	if(toolsarg != "")
		provcmd += " tools=" + toolsarg;
	if(getattr(attrs, "paths") != "")
		provcmd += " paths=" + getattr(attrs, "paths");

	# Provisioning is atomic (INFR-405): tools9p validates the request on
	# this write and refuses it outright rather than dropping the tools and
	# paths it will not grant.  The write is answered when the child is
	# confined and its agent started, or with why it was not: the task tool
	# cannot read the hidden manifest, and does not report success while
	# provisioning is still starting.  A refusal or failure must not
	# surface as a created activity — the caller would watch an activity
	# that has no agent behind it, or worse, assume the narrowing it asked
	# for was applied.  The activity goes, and the reason is reported.
	writefile(sys->sprint("%s/activity/%d/status", UI_MOUNT, newid), "provisioning");
	perr := writefile("/tool/provision", provcmd[10:]);
	if(perr != nil) {
		writefile(UI_MOUNT + "/ctl", sys->sprint("activity delete %d", newid));
		return sys->sprint("error: task not created — %s", perr);
	}
	return sys->sprint("created activity %d: %s%s", newid, label, modelnote);
}

dostatus(args: string): string
{
	args = strip(args);
	if(args == "")
		return "error: activity id required";
	(id, nil) := str->toint(args, 10);
	if(id < 0)
		return "error: invalid activity id";

	label := readfile(sys->sprint("%s/activity/%d/label", UI_MOUNT, id));
	status := readfile(sys->sprint("%s/activity/%d/status", UI_MOUNT, id));
	urgstr := readfile(sys->sprint("%s/activity/%d/urgency", UI_MOUNT, id));
	if(label == nil)
		return sys->sprint("error: activity %d not found", id);

	label = strip(label);
	if(status != nil) status = strip(status); else status = "unknown";
	if(urgstr != nil) urgstr = strip(urgstr); else urgstr = "0";

	out := sys->sprint("activity %d: %s [%s] urgency=%s", id, label, status, urgstr);
	# What it is doing: asked how a task was going, the agent had only
	# "working" to say.  What the task has used lately (its context, each
	# with when it was last used) and the last thing it has said.
	recent := recentuse(id, 6);
	if(recent != "")
		out += "\nrecently used (latest first): " + recent;
	docs := taskdocs(id);
	if(docs != "")
		out += sys->sprint("\ndocuments, in its own tab (task %d), not yours: %s", id, docs);
	last := lastsaid(id);
	if(last != "") {
		if(len last > 400)
			last = last[0:400] + "...";
		out += "\nlast said: " + last;
	}
	return out;
}

# The context resources the task used most recently, latest first:
# "path (via tool)" or a tool's name.
recentuse(id, max: int): string
{
	dir := sys->sprint("%s/activity/%d/context/resources", UI_MOUNT, id);
	used: list of (int, string);
	for(i := 0; i < 256; i++) {
		r := readfile(dir + "/" + string i);
		if(r == nil)
			break;
		# key=value words (parseattrs is for task create's arguments,
		# whose values run on to the next key it knows)
		(nil, words) := sys->tokenize(strip(r), " ");
		attrs: list of (string, string);
		for(; words != nil; words = tl words) {
			(k, v) := str->splitl(hd words, "=");
			if(v != "")
				attrs = (k, v[1:]) :: attrs;
		}
		lu := getattr(attrs, "lastused");
		if(lu == "" || getattr(attrs, "type") == "tool")
			continue;	# a tool's use is in the paths' "via"
		what := getattr(attrs, "path");
		via := getattr(attrs, "via");
		if(via != "" && via != "ro" && via != "rw" && via != "cow" && via != "bound")
			what += " (via " + via + ")";
		if(getattr(attrs, "status") == "active")
			what += " [now]";
		used = (int lu, what) :: used;
	}
	# latest first, max of them
	out := "";
	for(n := 0; n < max && used != nil; n++) {
		best := used;
		for(l := used; l != nil; l = tl l) {
			(t, nil) := hd l;
			(bt, nil) := hd best;
			if(t > bt)
				best = l;
		}
		(bt, bw) := hd best;
		if(out != "")
			out += ", ";
		out += bw;
		rest: list of (int, string);
		for(l = used; l != nil; l = tl l)
			if(l != best)
				rest = hd l :: rest;
		used = rest;
		bt = 0;
	}
	return out;
}

# The documents the task has put in its presentation view.
taskdocs(id: int): string
{
	dir := sys->sprint("%s/activity/%d/presentation", UI_MOUNT, id);
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return "";
	out := "";
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			if(!(d[i].mode & Sys->DMDIR))
				continue;
			label := readfile(dir + "/" + d[i].name + "/label");
			if(label != nil)
				label = strip(label);
			if(out != "")
				out += ", ";
			out += sys->sprint("%s \"%s\"", d[i].name, label);
		}
	}
	return out;
}

# The latest thing the task's agent has said (while it works, the reply
# being written).
lastsaid(id: int): string
{
	base := sys->sprint("%s/activity/%d/conversation", UI_MOUNT, id);
	last := "";
	for(m := 0; ; m++) {
		c := readfile(base + "/" + string m);
		if(c == nil)
			break;
		(role, text) := parseconvmsg(c);
		if(role == "veltro" && text != "" && text != "\u258c" && !hasprefix(c, "role=veltro dtype="))
			last = text;
	}
	return last;
}

# Parse a /mnt/ui conversation message file ("role=<r> text=<...>") into
# (role, text). text= consumes the rest.
parseconvmsg(s: string): (string, string)
{
	role := "";
	if(hasprefix(s, "role="))
		(role, nil) = splitfirst(s[len "role=":]);
	text := s;
	(nil, aft) := str->splitstrl(s, "text=");
	if(aft != "")
		text = aft[len "text=":];
	return (strip(role), strip(text));
}

# Return the child task agent's final report — the last non-human message in its
# conversation. task status only exposes state; this gives the parent the
# child's VALUE result so it doesn't have to route answers through scratch files
# or re-create the task (INFR-389).
doresult(args: string): string
{
	args = strip(args);
	if(args == "")
		return "error: activity id required";
	(id, nil) := str->toint(args, 10);
	if(id <= 0)
		return "error: invalid activity id";

	status := readfile(sys->sprint("%s/activity/%d/status", UI_MOUNT, id));
	if(status == nil)
		return sys->sprint("error: activity %d not found", id);
	status = strip(status);

	last := "";
	for(m := 0; m < 100; m++) {
		c := readfile(sys->sprint("%s/activity/%d/conversation/%d", UI_MOUNT, id, m));
		if(c == nil)
			break;
		(role, text) := parseconvmsg(c);
		if(role != "human" && role != "" && text != "")
			last = text;
	}
	if(last == "") {
		if(hasprefix(status, "failed"))
			return sys->sprint("task %d [%s] result: task failed before producing a reply", id, status);
		return sys->sprint("task %d [%s]: no result yet — it has not produced a reply. A [task-event] message will bring you its report when it finishes.", id, status);
	}
	return sys->sprint("task %d [%s] result:\n%s", id, status, last);
}

# Returns the id of an existing non-closed, non-hidden activity whose label
# exactly matches, else -1. Backs the create idempotency guard (INFR-390).
# Normalize a label for duplicate matching: lowercase, keep only alphanumerics,
# so cosmetic differences don't defeat the guard ("Flag: Invoice #4471" and
# "Flag Invoice 4471" both -> "flaginvoice4471").
normlabel(s: string): string
{
	s = str->tolower(s);
	out := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
			out += s[i:i+1];
	}
	return out;
}

findlabelledtask(label: string): int
{
	nlabel := normlabel(label);
	if(nlabel == "")
		return -1;
	info := readfile(UI_MOUNT + "/ctl");
	if(info == nil)
		return -1;
	lines := splitlines(strip(info));
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(hasprefix(line, "activities:")) {
			rest := strip(line[len "activities:":]);
			(nil, toks) := sys->tokenize(rest, " ");
			for(; toks != nil; toks = tl toks) {
				(id, nil) := str->toint(hd toks, 10);
				if(id <= 0) continue;   # skip meta-agent (0) and invalid ids
				lbl := readfile(sys->sprint("%s/activity/%d/label", UI_MOUNT, id));
				st := readfile(sys->sprint("%s/activity/%d/status", UI_MOUNT, id));
				if(lbl != nil) lbl = strip(lbl);
				if(st != nil) st = strip(st);
				if(lbl != nil && normlabel(lbl) == nlabel && st != "hidden" && st != "closed")
					return id;
			}
		}
	}
	return -1;
}

dolist(): string
{
	info := readfile(UI_MOUNT + "/ctl");
	if(info == nil)
		return "no activities";

	result := "";
	lines := splitlines(strip(info));
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(hasprefix(line, "activities:")) {
			rest := strip(line[len "activities:":]);
			(nil, toks) := sys->tokenize(rest, " ");
			for(; toks != nil; toks = tl toks) {
				(id, nil) := str->toint(hd toks, 10);
				if(id < 0) continue;
				label := readfile(sys->sprint("%s/activity/%d/label", UI_MOUNT, id));
				status := readfile(sys->sprint("%s/activity/%d/status", UI_MOUNT, id));
				if(label != nil) label = strip(label); else label = "?";
				if(status != nil) status = strip(status); else status = "?";
				if(status == "hidden") continue;
				if(result != "")
					result += "\n";
				result += sys->sprint("%d: %s [%s]", id, label, status);
			}
		}
	}
	if(result == "")
		return "no active tasks";
	return result;
}

doclose(args: string): string
{
	args = strip(args);
	if(args == "")
		return "error: activity id required";
	(id, nil) := str->toint(args, 10);
	if(id < 0)
		return "error: invalid activity id";
	if(id == 0)
		return "error: cannot close the meta-agent activity";

	err := writefile(UI_MOUNT + "/ctl", "activity delete " + string id);
	if(err != nil)
		return "error: " + err;

	return sys->sprint("activity %d archived", id);
}

# Apply (promote) or discard (revert) the changes a task has staged to the
# user's files.  Its writes to a granted folder go to an overlay, not the
# folder, until then; the task's own tab takes /promote and /revert, and
# this sends the same, a fixed command and nothing else, to its input.
dostaged(args, slash: string): string
{
	args = strip(args);
	(id, nil) := str->toint(args, 10);
	if(args == "" || id <= 0)
		return "error: task id required";
	base := sys->sprint("%s/activity/%d", UI_MOUNT, id);
	status := readfile(base + "/status");
	if(status == nil)
		return sys->sprint("error: activity %d not found", id);
	if(strip(status) == "hidden")
		return sys->sprint("error: task %d is closed", id);
	# The task's event file opened before its messages are counted, so
	# a reply between the two is still heard; each open has its own
	# queue, so this takes nothing from Lucifer's.
	evfd := sys->open(base + "/event", Sys->OREAD);
	nbefore := 0;
	while(readfile(sys->sprint("%s/conversation/%d", base, nbefore)) != nil)
		nbefore++;
	err := writefile(base + "/conversation/input", slash);
	if(err != nil)
		return "error: " + err;
	# The task answers in its conversation; wait a little for it, on its
	# events: each new or changed message is looked at.
	if(evfd != nil) {
		# its reader ends at the task's next event after this returns
		# (a tool call's /prog has only its own pid: nothing to kill)
		evc := chan[1] of int;
		stop := ref Stop(0);
		spawn convevents(evfd, evc, stop);
		evfd = nil;
		tick := chan of int;
		spawn stagedtimer(tick, 5000);
		for(;;) alt {
		<-evc =>
			if((r := stagedreply(base, nbefore)) != nil) {
				stop.done = 1;
				return sys->sprint("task %d: %s", id, r);
			}
		<-tick =>
			stop.done = 1;
			return sys->sprint("task %d: %s sent; the task is busy and will do it when its turn ends", id, slash[1:]);
		}
	}
	if((r := stagedreply(base, nbefore)) != nil)
		return sys->sprint("task %d: %s", id, r);
	return sys->sprint("task %d: %s sent; the task is busy and will do it when its turn ends", id, slash[1:]);
}

# The first message since nbefore that is not the human's, nil if none.
stagedreply(base: string, nbefore: int): string
{
	for(m := nbefore; ; m++) {
		c := readfile(sys->sprint("%s/conversation/%d", base, m));
		if(c == nil)
			return nil;
		(role, text) := parseconvmsg(c);
		if(role != "human" && text != "")
			return text;
	}
}

Stop: adt {
	done:	int;
};

# Each event of the task's that is about its conversation, as a wake on
# evc (one is enough: the waiter looks at every message since).
convevents(fd: ref Sys->FD, evc: chan of int, stop: ref Stop)
{
	buf := array[512] of byte;
	while(!stop.done && (n := sys->read(fd, buf, len buf)) > 0) {
		ev := string buf[0:n];
		if(len ev >= 12 && ev[0:12] == "conversation")
			alt { evc <-= 1 => ; * => ; }
	}
}

stagedtimer(tick: chan of int, ms: int)
{
	sys->sleep(ms);
	alt { tick <-= 1 => ; * => ; }
}

# --- Utility functions ---

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

writefile(path, data: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("cannot open %s: %r", path);
	b := array of byte data;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write %s: %r", path);
	return nil;
}

strip(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[0:len s - 1];
	return s;
}

hasprefix(s, pfx: string): int
{
	return len s >= len pfx && s[0:len pfx] == pfx;
}

splitfirst(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\t')
			return (s[0:i], strip(s[i+1:]));
	return (s, "");
}

splitlines(s: string): list of string
{
	result: list of string;
	start := 0;
	for(i := 0; i < len s; i++) {
		if(s[i] == '\n') {
			if(i > start)
				result = s[start:i] :: result;
			start = i + 1;
		}
	}
	if(start < len s)
		result = s[start:] :: result;
	rev: list of string;
	for(; result != nil; result = tl result)
		rev = hd result :: rev;
	return rev;
}

# Text written into ctl attributes must stay inert display text. The ctl
# parser treats whitespace-delimited words ending in '=' as new attributes, so
# collapse controls and replace '=' before embedding model-supplied metadata.
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

# Return the first attr key that is not in createkeys, or "" if all are valid.
firstunknownkey(attrs: list of (string, string)): string
{
	for(; attrs != nil; attrs = tl attrs) {
		(k, nil) := hd attrs;
		if(!strlistcontains(createkeys, k))
			return k;
	}
	return "";
}

strlistcontains(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

joinstrs(l: list of string, sep: string): string
{
	r := "";
	first := 1;
	for(; l != nil; l = tl l) {
		if(!first)
			r += sep;
		r += hd l;
		first = 0;
	}
	return r;
}

# Look up agenttype defaults. Returns (tools, model). Both empty if unknown.
agentdefaults(t: string): (string, string)
{
	if(t == "")
		return ("", "");
	for(l := agentdefs; l != nil; l = tl l) {
		(name, defmodel, deftools) := hd l;
		if(name == t)
			return (deftools, defmodel);
	}
	return ("", "");
}

knownagenttypes(): string
{
	r := "";
	first := 1;
	for(l := agentdefs; l != nil; l = tl l) {
		(name, nil, nil) := hd l;
		if(!first)
			r += ", ";
		r += name;
		first = 0;
	}
	return r;
}

parsetoollist(s: string): list of string
{
	(nil, toks) := sys->tokenize(s, " \t\r\n,");
	out: list of string;
	for(; toks != nil; toks = tl toks)
		if(hd toks != "")
			out = hd toks :: out;
	return out;
}

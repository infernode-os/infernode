implement ToolTask;

#
# task - Task delegation tool for Veltro meta-agent
#
# Creates, monitors, and manages delegated AI tasks.
# Each task gets its own activity, tools9p, and lucibridge.
#
# Commands:
#   create label=<name> [tools=<csv>] [paths=<csv>] [urgency=<0-2>]
#          [category=<text>] [model=<name>] [agenttype=<type>]
#          [brief=<text>] [instructions=<text>]
#   status <id>
#   list
#   close <id>
#
# Unknown create args are rejected loudly (with the valid set listed) so the
# caller — typically an LLM — gets a clear signal instead of having silently
# dropped fields. Allowed model names live in MODELS; "" inherits from parent.
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

# Recognised models. "" means "inherit parent session's model" (current
# default behaviour). Keep in sync with serve-llm's backend registry.
models: list of string;

# Per-agenttype defaults applied when a field is omitted. Fields the caller
# supplies always win — agenttype only fills blanks. Each tuple is
# (name, default-model, default-tools-csv).
#
# coder: backed by the Daedalus fine-tune (Limbo-capable), with the tool
# surface a coding loop typically needs.
# research: a web-research loop (decompose -> fan out -> synthesize -> cite),
# backed by gpt-oss with search/fetch and spawn for parallel sub-questions.
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

	models = "gpt-oss" :: "daedalus" :: "haiku" :: "sonnet" :: "opus" :: nil;

	agentdefs =
		("coder", "daedalus", "read,write,edit,find,grep,list,limbo") ::
		("research", "gpt-oss", "websearch,webfetch,read,find,grep,memory,plan,todo,gap,spawn,present") ::
		("verify", "gpt-oss", "read,list,find,search,grep,exec,plan,todo,gap,present") ::
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
		"         [category=<text>] [model=<name>] [agenttype=<type>]\n" +
		"         [brief=<text>] [instructions=<text>]\n" +
		"      Create new task with isolated tools and conversation.\n" +
		"      Tools validated against delegation budget.\n" +
		"      instructions= sets structured directives injected into the TA system prompt.\n" +
		"      model= selects the LLM backing the new activity (gpt-oss, daedalus,\n" +
		"        haiku, sonnet, opus). Omit to inherit parent session's model.\n" +
		"      agenttype= picks a prompt under /lib/veltro/agents/<type>.txt and\n" +
		"        fills sensible defaults (e.g. agenttype=coder ⇒ model=daedalus,\n" +
		"        tools=read,write,edit,find,grep,list,limbo).\n" +
		"      Unknown args are rejected with the list of valid keys.\n" +
		"      Put tools=/paths=/model=/agenttype= before brief=/instructions=.\n" +
		"      Unquoted brief=/instructions= consume the rest of the line.\n" +
		"  status <id>     Show task status and urgency\n" +
		"  list            List all active tasks\n" +
		"  close <id>      Archive a completed task\n\n" +
		"Each task gets its own conversation, tools, and filesystem overlay.\n" +
		"Use for work that should happen in parallel or needs isolation.\n\n" +
		"Examples:\n" +
		"  task create label=Review tools=read,list,find,grep\n" +
		"  task create label=Editor instructions=\"Open /lib/veltro/system.txt and edit it\"\n" +
		"  task create label=BugFix agenttype=coder brief=\"fix the bug in cat.b\"\n" +
		"  task create label=Refactor model=daedalus tools=read,write,edit\n" +
		"  task list\n" +
		"  task status 2\n" +
		"  task close 2";
}

schema(): string
{
	return "{" +
		"\"name\":\"task\"," +
		"\"description\":\"Create and manage delegated AI agents that run AUTONOMOUSLY from their brief. Put all work detail in brief=/instructions= at create time; you CANNOT send a task content or commands afterward, and you never do the work yourself. After create, poll status until it reports done, then read its result. Never re-create a task that is already running.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\",\"description\":\"One of: create, status, list, close. These are the ONLY commands — there is no write/run/send. To make a task do work, describe it in args brief=/instructions= at create time.\"}," +
				"\"args\":{\"type\":\"string\",\"description\":\"For create: key=value attributes. Put authority attrs first: label=<name> [tools=<csv>] [paths=<csv>] [urgency=<0-2>] [category=<text>] [model=<name>] [agenttype=<type>] [brief=<text>] [instructions=<text>]. Unquoted brief=/instructions= consume the rest of the line; quote them if more attrs must follow. For status/close: the task id. Omit for list.\"}" +
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
		return "error: no command. Use: create, status, list, close";

	(cmd, rest) := splitfirst(args);
	cmd = str->tolower(cmd);

	case cmd {
	"create" =>
		return docreate(rest);
	"status" =>
		return dostatus(rest);
	"list" =>
		return dolist();
	"close" =>
		return doclose(rest);
	* =>
		return sys->sprint("error: unknown command '%s'. Use: create, status, list, close", cmd);
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
		if(i < len s && (s[i] == '"' || s[i] == '\'')) {
			q := s[i];
			i++;	# skip opening quote
			vstart := i;
			while(i < len s && s[i] != q)
				i++;
			val = s[vstart:i];
			if(i < len s)
				i++;	# skip closing quote
		} else if(isterminaltextkey(key)) {
			# Unquoted brief=/instructions= are terminal free text. Treat the
			# rest of the argument string as content so hostile copied text
			# cannot smuggle later tools=/paths=/model= attributes.
			val = s[i:];
			while(len val > 0 && (val[0] == ' ' || val[0] == '\t'))
				val = val[1:];
			while(len val > 0 && (val[len val - 1] == ' ' || val[len val - 1] == '\t'))
				val = val[0:len val - 1];
			i = len s;
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

	agenttype := str->tolower(getattr(attrs, "agenttype"));
	(deftools, defmodel) := agentdefaults(agenttype);
	if(agenttype != "" && deftools == "" && defmodel == "")
		return sys->sprint("error: unknown agenttype '%s' (valid: %s).",
			agenttype, knownagenttypes());

	model := getattr(attrs, "model");
	if(model == "" && defmodel != "")
		model = defmodel;
	if(model != "" && !knownmodel(model))
		return sys->sprint("error: unknown model '%s' (valid: %s).",
			model, joinmodels());

	toolsarg := getattr(attrs, "tools");
	if(toolsarg == "" && deftools != "")
		toolsarg = deftools;
	urgstr := getattr(attrs, "urgency");

	# Validate tools against budget
	if(toolsarg != "") {
		budgetstr := readfile("/tool/budget");
		if(budgetstr != nil) {
			budgetstr = strip(budgetstr);
			(nil, reqtoks) := sys->tokenize(toolsarg, ",");
			for(; reqtoks != nil; reqtoks = tl reqtoks) {
				t := hd reqtoks;
				if(!contains(budgetstr, t))
					return sys->sprint("error: tool '%s' not in delegation budget", t);
			}
		}
	}

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
	if(model != "") {
		mpath := sys->sprint("/tmp/veltro/tasks/model.%d", newid);
		mfd := sys->create(mpath, Sys->OWRITE, 8r644);
		if(mfd != nil) {
			mb := array of byte model;
			sys->write(mfd, mb, len mb);
			mfd = nil;
		}
	}
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
			writefile(dashctl, "categorize " + string newid + " " + category);
		if(instructions != "")
			writefile(dashctl, "instructions " + string newid + " " + instructions);
	}

	# Delegate provisioning to tools9p's narrow child-provision path.
	# The server runs in the unrestricted parent namespace, but it validates
	# child tools and paths as a subset of the current grants before spawning.
	provcmd := "provision " + string newid;
	if(toolsarg != "")
		provcmd += " tools=" + toolsarg;
	if(getattr(attrs, "paths") != "")
		provcmd += " paths=" + getattr(attrs, "paths");

	# INFR-362: serialize provisioning. Provisioning runs asynchronously in the
	# parent namespace; a sibling `task create` issued in the SAME turn (parallel
	# tool calls — e.g. Mistral emits all at once) would otherwise overlap this
	# child's namespace setup and find /mnt/ui transiently hidden, silently
	# dropping the task. Wait for this child's manifest, which is written only
	# AFTER its restrictns completes — by then the racy bind-replace window is
	# closed. Remove any stale manifest first (/tmp persists across runs).
	manifestp := sys->sprint("/tmp/veltro/.ns/manifest.%d", newid);
	sys->remove(manifestp);
	perr := writefile("/tool/provision", provcmd[10:]);
	if(perr != nil)
		sys->fprint(sys->fildes(2), "task: provision warning: %s\n", perr);
	for(w := 0; w < 120; w++) {		# bounded ~6s
		(mok, nil) := sys->stat(manifestp);
		if(mok >= 0)
			break;
		sys->sleep(50);
	}

	return sys->sprint("created activity %d: %s", newid, label);
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

	return sys->sprint("activity %d: %s [%s] urgency=%s", id, label, status, urgstr);
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

knownmodel(m: string): int
{
	return strlistcontains(models, m);
}

joinmodels(): string
{
	return joinstrs(models, ", ");
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

contains(haystack, needle: string): int
{
	nlen := len needle;
	for(i := 0; i <= len haystack - nlen; i++) {
		if(haystack[i:i+nlen] == needle) {
			# Check word boundary
			if(i > 0 && haystack[i-1] != '\n' && haystack[i-1] != ' ' && haystack[i-1] != ',')
				continue;
			end := i + nlen;
			if(end < len haystack && haystack[end] != '\n' && haystack[end] != ' ' && haystack[end] != ',')
				continue;
			return 1;
		}
	}
	return 0;
}

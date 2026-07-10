implement SubAgent;

#
# subagent.b - Lightweight agent loop for restricted namespace execution
#
# Design:
#   - Runs inside FORKNS + bind-replace restricted namespace
#   - Uses pre-loaded tool modules directly (no tools9p)
#   - Receives system prompt as parameter (no /lib/veltro/ access)
#   - LLM access via fd opened before namespace restriction
#
# Security:
#   - Only pre-loaded tools are accessible
#   - LLM config is immutable (set by parent)
#   - Namespace IS the capability set (restricted via bind-replace)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "string.m";
	str: String;

include "agentlib.m";
	agentlib: AgentLib;

include "tool.m";
include "subagent.m";

# Configuration
STREAM_THRESHOLD: con 4096;
# Under /tmp/veltro — the subtree nsconstruct keeps writable post-restriction
# (plain /tmp/scratch isn't creatable in the child's restricted namespace).
SCRATCH_PATH: con "/tmp/veltro/scratch";

# Per-step truncation length for trajectory log entries. Matches veltro.b's
# LOG_PREVIEW so parent and subagent logs share one format.
LOG_PREVIEW: con 200;

# Bound each MCP /call so a hung/slow backend degrades to a tool-error (the
# reason loop treats it as a failure) instead of stalling the child. Matches
# the agent's MCP_CALL_TIMEOUT_MS.
MCP_CALL_TIMEOUT_MS: con 30000;

stderr: ref Sys->FD;

# Pre-loaded tool storage (set by runloop)
loadedtools: list of Tool;
loadedtoolnames: list of string;

# MCP routing maps (INFR-247), set by spawn.b via setmcp() AFTER restrictns so
# they cover only the /mnt/mcp/<server> servers this child was granted. Used by
# calltool() to route a model-emitted MCP tool name to its owning mount.
mcpmounts: list of (string, string);	# (prefix, mount)
mcptools: list of (string, string);	# (bare-tool, mount)

# LLM ask file descriptor (opened before FORKNS + bind-replace restriction)
# Session is already created and configured - just use this fd
llmaskfd: ref Sys->FD;

# Trajectory log file descriptor (opened before FORKNS, nil = no logging).
# Survives namespace restriction via the same fd-keep pattern as llmaskfd.
logfd: ref Sys->FD;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	stderr = sys->fildes(2);

	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return sys->sprint("cannot load Bufio: %r");

	str = load String String->PATH;
	if(str == nil)
		return sys->sprint("cannot load String: %r");

	# Reasoning runs on the same agentlib loop the parent agent uses
	# (harmony/JSON-aware, with retry) instead of the legacy line-parse/DONE
	# protocol. Loaded here —
	# spawn calls init() in the PARENT namespace, before restriction, so
	# /dis/veltro is reachable; the module then runs fine in the restricted child.
	agentlib = load AgentLib AgentLib->PATH;
	if(agentlib != nil)
		agentlib->init();

	return nil;
}

# Bridge MCP tools into this child (INFR-247). Set by spawn.b AFTER restrictns
# (so the maps cover only granted /mnt/mcp/<server> servers) and before runloop.
setmcp(mounts: list of (string, string), tools: list of (string, string))
{
	mcpmounts = mounts;
	mcptools = tools;
}

# Main agent loop
# Session is already created and configured by spawn.b - just use the ask fd
runloop(task: string, tools: list of Tool, toolnames: list of string,
        systemprompt: string, askfd: ref Sys->FD, lfd: ref Sys->FD, maxsteps: int): string
{
	if(sys == nil) {
		err := init();
		if(err != nil)
			return "ERROR:" + err;
	}

	# Store pre-loaded tools for calltool()
	loadedtools = tools;
	loadedtoolnames = toolnames;

	# Store LLM ask fd (survives NEWNS)
	# Session is already fresh and configured - no reset needed
	llmaskfd = askfd;

	# Store trajectory log fd (survives NEWNS). nil = no logging.
	logfd = lfd;

	if(agentlib == nil)
		return "ERROR:agentlib unavailable in subagent";

	# Build namespace description
	ns := discovernamespace(toolnames);

	# Assemble initial prompt
	prompt := assembleprompt(task, ns, systemprompt);

	logheader(task);

	loopstart := sys->millisec();
	for(step := 0; step < maxsteps; step++) {
		# Query the LLM via agentlib (same harmony/JSON-aware path + retry as the
		# parent agent), then parse with parsellmresponse — NOT the legacy
		# line-parse/DONE protocol, which dropped gpt-oss's final-channel answer.
		response := agentlib->queryllmfd(llmaskfd, prompt);
		logllm(step + 1, len prompt, response);
		if(response == "") {
			logfooter("empty", step + 1, sys->millisec() - loopstart);
			return "ERROR:LLM returned empty response";
		}

		(stopreason, tcalls, text) := agentlib->parsellmresponse(response);

		# Turn complete: the model's text IS the subagent's result.
		if(stopreason == "end_turn" || stopreason == "" || tcalls == nil) {
			logfooter("done", step + 1, sys->millisec() - loopstart);
			if(text != "")
				return text;
			return "ERROR:subagent produced no answer";
		}

		# Intermediate step: dispatch the requested tool calls against the
		# pre-loaded tool modules and feed results back. (A child whose session
		# has no tools registered won't reach here — it just answers above.)
		results: list of (string, string);
		for(tc := tcalls; tc != nil; tc = tl tc) {
			(id, name, targs) := hd tc;
			result := calltool(name, targs);
			logstep(step + 1, name, targs, result);
			if(len result > STREAM_THRESHOLD) {
				scratchfile := writescratch(result, step);
				result = sys->sprint("(output written to %s, %d bytes)", scratchfile, len result);
			}
			results = (id, result) :: results;
		}
		prompt = agentlib->buildtoolresults(revresults(results));
	}

	totaltime := sys->millisec() - loopstart;
	sys->fprint(stderr, "subagent: max steps reached after %dms\n", totaltime);
	logfooter("max-steps", maxsteps, totaltime);
	return sys->sprint("ERROR:max steps (%d) reached without completion", maxsteps);
}

# Reverse a (id, result) list to restore call order (results are accumulated
# head-first in the dispatch loop).
revresults(l: list of (string, string)): list of (string, string)
{
	r: list of (string, string);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# Replace newlines and tabs with spaces (single-line log entries).
# Matches veltro.b's collapsenl so parent and subagent logs share one format.
collapsenl(s: string): string
{
	result := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '\n' || c == '\r' || c == '\t')
			c = ' ';
		# NB: `string c` on an int gives its DECIMAL text ("68"), not the char —
		# use %c so log lines stay human-readable.
		result += sys->sprint("%c", c);
	}
	return result;
}

# Truncate to LOG_PREVIEW chars with "..." marker (matches veltro.b).
preview(s: string): string
{
	if(len s <= LOG_PREVIEW)
		return s;
	return s[0:LOG_PREVIEW] + "...";
}

logheader(task: string)
{
	if(logfd == nil)
		return;
	line := sys->sprint("# subagent task=%s\n", collapsenl(preview(task)));
	data := array of byte line;
	sys->write(logfd, data, len data);
}

# Log the raw LLM exchange (prompt size + response preview) so the empty/short
# response failure mode is diagnosable from the trajectory log.
logllm(step, promptlen: int, response: string)
{
	if(logfd == nil)
		return;
	line := sys->sprint("llm %d: prompt=%db resp=%db :: %s\n",
		step, promptlen, len array of byte response, collapsenl(preview(response)));
	data := array of byte line;
	sys->write(logfd, data, len data);
}

logstep(step: int, tool, toolargs, result: string)
{
	if(logfd == nil)
		return;
	line := sys->sprint("step %d: %s %s -> %s\n",
		step, tool, collapsenl(preview(toolargs)), collapsenl(preview(result)));
	data := array of byte line;
	sys->write(logfd, data, len data);
}

logfooter(status: string, steps, totalms: int)
{
	if(logfd == nil)
		return;
	line := sys->sprint("# end status=%s steps=%d total_ms=%d\n", status, steps, totalms);
	data := array of byte line;
	sys->write(logfd, data, len data);
}

# Discover namespace - list available tools
discovernamespace(toolnames: list of string): string
{
	result := "TOOLS:\n";
	for(t := toolnames; t != nil; t = tl t) {
		if(result != "TOOLS:\n")
			result += "\n";
		result += hd t;
	}

	result += "\n\nPATHS:\n";
	paths := array[] of {"/", "/tmp"};
	for(i := 0; i < len paths; i++) {
		if(pathexists(paths[i]))
			result += paths[i] + "\n";
	}

	return result;
}

# Assemble system prompt with namespace and task
assembleprompt(task, ns, systemprompt: string): string
{
	if(systemprompt == "")
		systemprompt = defaultsystemprompt();

	# Get tool documentation — read txt files directly (upfront composition,
	# no on-demand help). Falls back to module doc() if no txt file exists.
	tooldocs := "";
	namelist := loadedtoolnames;
	modlist := loadedtools;
	while(namelist != nil && modlist != nil) {
		toolname := hd namelist;
		doc := readfile("/lib/veltro/tools/" + toolname + ".txt");
		if(doc == "")
			doc = (hd modlist)->doc();
		if(doc != "" && !hasprefix(doc, "error:"))
			tooldocs += "\n### " + toolname + "\n" + doc + "\n";
		namelist = tl namelist;
		modlist = tl modlist;
	}

	prompt := systemprompt + "\n\n== Your Namespace ==\n" + ns +
		"\n\n== Tool Documentation ==\n" + tooldocs +
		"\n\n== Task ==\n" + task +
		"\n\nComplete the task and provide your final answer directly.";

	return prompt;
}

# Default system prompt
defaultsystemprompt(): string
{
	# Reasoning now runs on the agentlib loop (harmony/JSON tool-use), NOT the old
	# line-parse/DONE protocol. The prompt must NOT tell the model "first word =
	# tool name / emit a tool invocation / say DONE" — under harmony that drove the
	# model to emit a tool call into a discarded channel, leaving an empty final
	# channel (empty /ask response). Just ask for the answer directly; tool calls,
	# if the session has tools, happen via the native harmony tool format.
	return "You are a focused sub-agent running in an isolated sandbox. You have " +
		"one self-contained task. Work it through with your own reasoning (and any " +
		"tools available to you), then respond with your result DIRECTLY as plain " +
		"text — the complete work product the caller needs, concise and finished. " +
		"Do not ask questions, do not narrate your process, do not emit status " +
		"markers like 'DONE' — output only the answer itself.";
}

# Query LLM via passed ask file descriptor
# Uses same fd for both write and pread (clone-based session)
queryllm(prompt: string): string
{
	# Use the ask fd passed from parent (survives NEWNS)
	if(llmaskfd == nil) {
		sys->fprint(stderr, "subagent: llmaskfd is nil\n");
		return "";
	}

	# Write prompt - this blocks until LLM responds
	data := array of byte prompt;
	n := sys->write(llmaskfd, data, len data);
	if(n != len data) {
		sys->fprint(stderr, "subagent: LLM write failed: wrote %d of %d: %r\n", n, len data);
		return "";
	}

	# Read response using pread with explicit offset 0
	result := "";
	buf := array[8192] of byte;
	offset := big 0;
	for(;;) {
		n = sys->pread(llmaskfd, buf, len buf, offset);
		if(n <= 0)
			break;
		result += string buf[0:n];
		offset += big n;
	}
	return result;
}

# Parse tool invocation from LLM response
# Supports heredoc syntax for multi-line content
parseaction(response: string): (string, string)
{
	# Split into lines
	(nil, lines) := sys->tokenize(response, "\n");

	# Look for tool invocation
	for(; lines != nil; lines = tl lines) {
		line := hd lines;

		# Skip empty lines
		line = str->drop(line, " \t");
		if(line == "")
			continue;

		# Strip [Veltro] prefix if present (from prefill)
		if(hasprefix(line, "[Veltro]"))
			line = line[8:];
		line = str->drop(line, " \t");
		if(line == "")
			continue;

		# Check for DONE
		if(str->tolower(line) == "done" || hasprefix(str->tolower(line), "done"))
			return ("DONE", "");

		# Check if line starts with a known tool name
		(first, rest) := splitfirst(line);
		tool := str->tolower(first);

		# Match against loaded tools
		for(t := loadedtoolnames; t != nil; t = tl t) {
			if(tool == hd t) {
				args := str->drop(rest, " \t");
				# Check for heredoc syntax
				(args, lines) = parseheredoc(args, tl lines);
				return (first, args);
			}
		}

	}

	return ("", "");
}

# Parse heredoc content if present in args
parseheredoc(args: string, lines: list of string): (string, list of string)
{
	# Find heredoc marker <<
	markerpos := findheredoc(args);
	if(markerpos < 0)
		return (args, lines);

	# Extract delimiter (word after <<)
	aftermarker := args[markerpos + 2:];
	aftermarker = str->drop(aftermarker, " \t");
	delim := splitfirst(aftermarker).t0;
	if(delim == "")
		delim = "EOF";

	# Args before the heredoc marker
	argsbefore := "";
	if(markerpos > 0)
		argsbefore = strip(args[0:markerpos]);

	# Collect heredoc content from remaining lines
	content := "";
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		# Check for end delimiter (must be alone on line, stripped)
		if(strip(line) == delim) {
			lines = tl lines;
			break;
		}
		if(content != "")
			content += "\n";
		content += line;
	}

	# Combine: args_before + heredoc_content
	result := argsbefore;
	if(result != "" && content != "")
		result += " ";
	result += content;

	return (result, lines);
}

# Find heredoc marker << in string, returns position or -1
findheredoc(s: string): int
{
	if(len s < 2)
		return -1;
	for(i := 0; i < len s - 1; i++) {
		if(s[i] == '<' && s[i+1] == '<') {
			# Make sure it's not <<< (which would be different)
			if(i + 2 >= len s || s[i+2] != '<')
				return i;
		}
	}
	return -1;
}

# Strip leading/trailing whitespace
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

# Strip action line from response
stripaction(response: string): string
{
	result := "";
	(nil, lines) := sys->tokenize(response, "\n");
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		lower := str->tolower(str->drop(line, " \t"));
		if(lower == "done" || hasprefix(lower, "done"))
			continue;
		if(result != "")
			result += "\n";
		result += line;
	}
	return result;
}

# Call tool using pre-loaded modules
calltool(tool, args: string): string
{
	ltool := str->tolower(tool);

	# Handle "help" specially
	if(ltool == "help") {
		# Find tool and return its doc
		namelist := loadedtoolnames;
		modlist := loadedtools;
		while(namelist != nil && modlist != nil) {
			if(hd namelist == args)
				return (hd modlist)->doc();
			namelist = tl namelist;
			modlist = tl modlist;
		}
		return sys->sprint("error: unknown tool: %s", args);
	}

	# Find pre-loaded tool module
	namelist := loadedtoolnames;
	modlist := loadedtools;
	while(namelist != nil && modlist != nil) {
		if(hd namelist == ltool)
			return (hd modlist)->exec(args);
		namelist = tl namelist;
		modlist = tl modlist;
	}

	# MCP fallback (INFR-247): not a pre-loaded native module — try the MCP
	# servers granted to this child. The model emits the registered name
	# (e.g. "osm_geocode_address"); route it (case-sensitive, prefix-tolerant)
	# to its owning /mnt/mcp/<server>/tools/<bare>/call. Only if no MCP match
	# do we fall through to the not-available error.
	if(mcpmounts != nil) {
		(mount, bare, nil) := agentlib->mcpresolve(tool, mcpmounts, mcptools);
		if(mount != "") {
			path := mount + "/tools/" + bare + "/call";
			return agentlib->mcpcall(path, args, MCP_CALL_TIMEOUT_MS);
		}
	}

	return sys->sprint("error: tool not available: %s", ltool);
}

# Write large result to scratch file
writescratch(content: string, step: int): string
{
	ensuredir(SCRATCH_PATH);
	path := sys->sprint("%s/step%d.txt", SCRATCH_PATH, step);

	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return "(cannot create scratch file)";

	data := array of byte content;
	sys->write(fd, data, len data);
	return path;
}

# Helper functions
readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";

	result := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		result += string buf[0:n];
	}
	return result;
}

pathexists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

ensuredir(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil)
		return;

	# Ensure parent
	for(i := len path - 1; i > 0; i--) {
		if(path[i] == '/') {
			ensuredir(path[0:i]);
			break;
		}
	}

	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

splitfirst(s: string): (string, string)
{
	for(i := 0; i < len s; i++) {
		if(s[i] == ' ' || s[i] == '\t')
			return (s[0:i], s[i:]);
	}
	return (s, "");
}

implement Tools9p;

#
# tools9p - Tool Filesystem Server for Veltro Agent
#
# Registry-based 9P file server. Unlike OODA's tools9p which filters from
# a full list, Veltro's tools9p takes an explicit tool list and ONLY serves
# those tools. If a tool isn't in the registry, it doesn't exist.
#
# This is the "build up" model:
#   - Start with nothing
#   - Only serve what was explicitly requested
#   - No concept of "unavailable" tools
#
# Usage:
#   tools9p read list             # Serve only read and list tools
#   tools9p -D read list find     # With debug tracing
#   tools9p -m /mytool read       # Custom mount point
#
# Filesystem structure:
#   /tool/
#   ├── tools        (r)   List available tool names
#   ├── help         (rw)  Write name, read documentation
#   ├── ctl          (rw)  trusted control plane (user/UI only)
#   ├── provision    (rw)  child-task provisioning (narrowing only)
#   ├── _registry    (r)   Space-separated tool names
#   ├── paths        (r)   Bound namespace paths
#   └── <tool>/      (dir) Per-tool directory
#       ├── ctl      (rw)  Write args, read result
#       ├── run      (rw)  Write args, read result (alias of ctl, per INFR-2)
#       │                  e.g. /tool/limbo/run authors Limbo via limbo->exec()
#       ├── doc      (r)   Tool documentation
#       └── schema   (r)   OpenAI function-schema JSON (per INFR-126)
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "arg.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;

include "string.m";
	str: String;

include "tool.m";

include "nsconstruct.m";

Tools9p: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# Qid types for synthetic files
Qroot, Qtools, Qhelp, Qregistry, Qctl, Qpaths, Qbudget, Qactivity, Qprovision,
	Qmeta, Qmetarole, Qmetaxenith, Qmetaactid, Qmetanodevs: con iota;
Qtoolbase: con 100;       # Tool qid blocks start at 100
TOOL_STRIDE: con 5;       # Qids per tool: 0=dir, 1=ctl, 2=doc, 3=schema, 4=run
Qtool_dir: con 0;         # Offset: tool directory
Qtool_ctl: con 1;         # Offset: ctl subfile (write args, read result)
Qtool_doc: con 2;         # Offset: doc subfile (read-only documentation)
Qtool_schema: con 3;      # Offset: schema subfile (OpenAI function-schema JSON)
Qtool_run: con 4;         # Offset: run subfile (write args, read result — alias of ctl, INFR-2)

# Tool info structure
ToolInfo: adt {
	name:    string;         # Tool name (lowercase)
	path:    string;         # Path to .dis module
	mod:     Tool;           # Loaded module (nil if not yet loaded)
	qid:     int;            # Qid for this tool
	result:  array of byte;  # Last execution result
};

stderr: ref Sys->FD;
user: string;
tools: list of ref ToolInfo;     # active (exposed) tools; mutated by serveloop, read by asyncexec (snapshot-safe)
alltools: list of ref ToolInfo;  # pre-loaded inactive tools (available for ctl-add)
extpaths: list of string;  # Extra paths from -p flags (e.g. "/dis/wm")

# Bound namespace paths with per-path permissions.
# Each entry is "path perm" where perm is "ro" or "rw".
# Default perm is "rw" for backward compatibility.
BoundPath: adt {
	path: string;
	perm: string;  # "ro" or "rw"
};
boundpaths: list of ref BoundPath;  # Paths registered via bindpath ctl command
budget: list of string;    # Tools delegatable to child tasks (-b flag)
activityid := 0;           # Activity ID this tools9p serves (-a flag)
mountpt_g := "/tool";      # This instance's mount point (set from -m flag)
verbose := 0;              # Verbose logging (-v flag); forwarded to child lucibridge
# Agent metadata exposed read-only at /tool/meta/ for nsaudit (INFR-18).
# Declared by whoever launches this tools9p — tools9p cannot observe the
# agent process's own pgrp. Defaults are the honest top-level state; the
# provisioning path passes the child values (see provisionchild).
agentrole := "toplevel";   # "toplevel" | "child" (-r flag)
agentnodevs := "unset";    # "set" | "unset" (-N flag sets it)
vers: int;

# Shadow directories for per-invocation namespace restriction
# Must match SHADOW_BASE in nsconstruct.b
SHADOW_BASE: con "/tmp/.veltro-ns/shadow";

# Buffered channel for async shadow dir cleanup; asyncexec sends PID when done
cleanupchan: chan of int;
helpresult: array of byte;  # Last help query result (global, not per-fid)
manifest_written := 0;  # Set after first emitmanifest() call

# Mapping from tool name to .dis path
# Veltro tools are in /dis/veltro/tools/
TOOL_PATHS := array[] of {
	# Core file operations
	("read",    "/dis/veltro/tools/read.dis"),
	("list",    "/dis/veltro/tools/list.dis"),
	("find",    "/dis/veltro/tools/find.dis"),
	("search",  "/dis/veltro/tools/search.dis"),
	("write",   "/dis/veltro/tools/write.dis"),
	("edit",    "/dis/veltro/tools/edit.dis"),
	# Execution
	("exec",    "/dis/veltro/tools/exec.dis"),
	("launch",  "/dis/veltro/tools/launch.dis"),
	("spawn",   "/dis/veltro/tools/spawn.dis"),
	# UI
	("xenith",  "/dis/veltro/tools/xenith.dis"),
	("present", "/dis/veltro/tools/present.dis"),
	("gap",     "/dis/veltro/tools/gap.dis"),
	# New tools (Phase 1c)
	("diff",    "/dis/veltro/tools/diff.dis"),
	("json",    "/dis/veltro/tools/json.dis"),
	("webfetch", "/dis/veltro/tools/webfetch.dis"),
	("git",     "/dis/veltro/tools/git.dis"),
	("grep",    "/dis/veltro/tools/grep.dis"),
	("memory",  "/dis/veltro/tools/memory.dis"),
	("todo",    "/dis/veltro/tools/todo.dis"),
	# Network tools
	("websearch", "/dis/veltro/tools/websearch.dis"),
	# Mail: superseded by mail9p (mounts /mnt/mail). See man/4/mail9p.
	# Web browsing
	("browse",    "/dis/veltro/tools/browse.dis"),
	("charon",    "/dis/veltro/tools/charon.dis"),
	# GPU inference (requires gpusrv mounted at /mnt/gpu)
	("gpu",     "/dis/veltro/tools/gpu.dis"),
	# Speech tools (require /n/speech via speech9p)
	("say",     "/dis/veltro/tools/say.dis"),
	("hear",    "/dis/veltro/tools/hear.dis"),
	# Vision (local GPU or Anthropic cloud API)
	("vision",  "/dis/veltro/tools/vision.dis"),
	("editor", "/dis/veltro/tools/editor.dis"),
	("shell", "/dis/veltro/tools/shell.dis"),
	# Fractal viewer control (requires fractals running)
	("fractal", "/dis/veltro/tools/fractal.dis"),
	# Man page viewer control (requires wm/man running)
	("man", "/dis/veltro/tools/man.dis"),
	# Task delegation (requires luciuisrv)
	("task",    "/dis/veltro/tools/task.dis"),
	# Structured planning
	("plan",    "/dis/veltro/tools/plan.dis"),
	# Credential management (launches GUI, no key access)
	("keyring", "/dis/veltro/tools/keyring.dis"),
	# Wallet operations (crypto/fiat payments via wallet9p)
	("wallet",  "/dis/veltro/tools/wallet.dis"),
	# Paid web fetch (x402 payment-enabled HTTP client)
	("payfetch", "/dis/veltro/tools/payfetch.dis"),
	# Limbo authoring via LLM-as-tool (delegates to devstral-limbo-v3
	# through a private /mnt/llm session). See appl/veltro/tools/limbo.b
	# and docs/LLM-AS-TOOL.md.
	("limbo",   "/dis/veltro/tools/limbo.dis"),
	# Phone bridge tools (mobile builds + desktops mounting a phone).
	# `findtool()` lookups in the auto-grant block below check
	# TOOL_PATHS, so these must be listed here — without them the
	# auto-grant of /phone to subagent namespaces silently no-ops.
	("sms",      "/dis/veltro/tools/sms.dis"),
	("dial",     "/dis/veltro/tools/dial.dis"),
	("contacts", "/dis/veltro/tools/contacts.dis"),
};

usage()
{
	sys->fprint(stderr, "Usage: tools9p [-DvN] [-a activityid] [-r role] [-m mountpoint] [-p path] ... tool [tool ...]\n");
	sys->fprint(stderr, "  -D            Enable 9P debug tracing\n");
	sys->fprint(stderr, "  -v            Verbose logging (forwarded to child lucibridge)\n");
	sys->fprint(stderr, "  -r role       Agent role for /tool/meta: toplevel (default) or child\n");
	sys->fprint(stderr, "  -N            Agent namespace has NODEVS applied (/tool/meta/nodevs=set)\n");
	sys->fprint(stderr, "  -m mountpoint Mount point (default: /tool)\n");
	sys->fprint(stderr, "  -p path       Expose extra path to agent namespace (repeatable)\n");
	sys->fprint(stderr, "                e.g. -p /dis/wm exposes /dis/wm/ for GUI app discovery\n");
	sys->fprint(stderr, "\n");
	sys->fprint(stderr, "Available tools:\n");
	sys->fprint(stderr, "  Core:    read, list, find, search, grep, write, edit\n");
	sys->fprint(stderr, "  Execute: exec, launch, spawn\n");
	sys->fprint(stderr, "  UI:      xenith, ask, present, gap\n");
	sys->fprint(stderr, "  Utils:   diff, json, http, git, memory, todo, websearch\n");
	sys->fprint(stderr, "  Vision:  vision, gpu\n");
	raise "fail:usage";
}

controlmount(mpt: string): string
{
	if(mpt == "/tool")
		return "/mnt/toolctl";
	if(len mpt > 6 && mpt[0:6] == "/tool.")
		return "/mnt/toolctl." + mpt[6:];
	return "/mnt/toolctl";
}

nomod(s: string)
{
	sys->fprint(stderr, "tools9p: can't load %s: %r\n", s);
	raise "fail:load";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);

	styx = load Styx Styx->PATH;
	if(styx == nil)
		nomod(Styx->PATH);
	styx->init();

	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		nomod(Styxservers->PATH);
	styxservers->init(styx);

	str = load String String->PATH;
	if(str == nil)
		nomod(String->PATH);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);
	arg->init(args);

	mountpt := "/tool";

	while((o := arg->opt()) != 0)
		case o {
		'D' =>	styxservers->traceset(1);
		'v' =>	verbose = 1;
		'r' =>
			rarg := arg->earg();
			if(rarg != "toplevel" && rarg != "child") {
				sys->fprint(stderr, "tools9p: -r role must be toplevel or child\n");
				raise "fail:usage";
			}
			agentrole = rarg;
		'N' =>	agentnodevs = "set";
		'm' =>	mountpt = arg->earg();
		'p' =>
			parg := arg->earg();
			explicitperm := "";
			if(len parg > 3 && (parg[len parg - 3:] == ":ro" || parg[len parg - 3:] == ":rw"))
				explicitperm = parg[len parg - 2:];
			(ppath, pperm) := splitpathperm(parg);
			perr := validatepath(ppath);
			if(perr != nil) {
				sys->fprint(stderr, "tools9p: invalid -p path %s: %s\n", ppath, perr);
				raise "fail:usage";
			}
			# Explicit :ro/:rw grants are permission-bearing capabilities.
			# Keep them in boundpaths only so raw exec cannot inherit a
			# read-only grant through the untyped extpaths list.
			if(explicitperm == "")
				extpaths = ppath :: extpaths;
			else if(findboundpath(ppath) == nil)
				boundpaths = ref BoundPath(ppath, pperm) :: boundpaths;
		'a' =>
			aarg := arg->earg();
			(aid, nil) := str->toint(aarg, 10);
			activityid = aid;
		'b' =>
			# Parse comma-separated budget tools
			barg := arg->earg();
			(nil, btoks) := sys->tokenize(barg, ",");
			for(; btoks != nil; btoks = tl btoks)
				budget = hd btoks :: budget;
		* =>	usage();
		}
	args = arg->argv();
	arg = nil;
	mountpt_g = mountpt;

	# Remaining args are tool names to register
	if(args == nil)
		usage();  # Need at least one tool

	if(verbose)
		sys->fprint(stderr, "tools9p[%s]: starting with %d tool args\n", mountpt, len args);

	# Build tool registry from args
	inittools(args);

	if(tools == nil) {
		sys->fprint(stderr, "tools9p: no valid tools specified\n");
		raise "fail:no tools";
	}

	# Clean shadow dirs left by previous session (crash or kill).
	# Current-session dirs are cleaned per-invocation via shadowcleanloop.
	cleanupchan = chan[32] of int;
	cleanshadows();
	spawn shadowcleanloop();

	# Write agent name file so the UI can display it.
	# Done before FORKNS so the file is visible from the user's process.
	sys->create("/tmp/veltro", Sys->OREAD, 8r700 | Sys->DMDIR);
	sys->create("/tmp/veltro/.ns", Sys->OREAD, 8r700 | Sys->DMDIR);
	{
		afd := sys->create("/tmp/veltro/.ns/agentname", Sys->OWRITE, 8r644);
		if(afd != nil) {
			sys->fprint(afd, "Veltro");
			afd = nil;
		}
	}

	sys->pctl(Sys->FORKFD, nil);

	user = rf("/dev/user");
	if(user == nil)
		user = "inferno";

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(stderr, "tools9p: can't create pipe: %r\n");
		raise "fail:pipe";
	}

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	fds[0] = nil;

	pidc := chan of int;
	mounted := chan[1] of int;
	spawn serveloop(tchan, srv, pidc, navops, mounted);
	<-pidc;

	# Ensure mount point exists
	ensuredir(mountpt);

	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(stderr, "tools9p: mount failed: %r\n");
		raise "fail:mount";
	}

	ctlmount := controlmount(mountpt);
	ensuredir(ctlmount);
	if(sys->bind(mountpt, ctlmount, Sys->MREPL) < 0)
		sys->fprint(stderr, "tools9p: control bind %s -> %s failed: %r\n", mountpt, ctlmount);

	# Signal serveloop that mount is complete — safe to FORKNS now
	mounted <-= 1;

	# Emit namespace manifest immediately so the UI shows the agent's
	# namespace before any tool calls. Spawned goroutine does FORKNS +
	# restrictns + emitmanifest — its namespace is discarded after.
	# Each tools9p writes to its own manifest path so activities don't
	# overwrite each other's namespace descriptions.
	spawn emitmanifestnow(manifestpath(mountpt));
}

# Look up tool path by name
toolpath(name: string): string
{
	lname := str->tolower(name);
	for(i := 0; i < len TOOL_PATHS; i++) {
		(n, p) := TOOL_PATHS[i];
		if(n == lname)
			return p;
	}
	return nil;
}

# Initialize tool registry from argument list
inittools(args: list of string)
{
	tools = nil;
	vers = 0;
	qid := Qtoolbase;

	for(; args != nil; args = tl args) {
		name := str->tolower(hd args);
		path := toolpath(name);
		if(path == nil) {
			sys->fprint(stderr, "tools9p: unknown tool '%s', skipping\n", name);
			continue;
		}

		# Check for duplicates
		if(findtool(name) != nil)
			continue;

		ti := ref ToolInfo(name, path, nil, qid, nil);
		tools = ti :: tools;
		qid += TOOL_STRIDE;
	}

	# Reverse to maintain argument order
	rev: list of ref ToolInfo;
	for(t := tools; t != nil; t = tl t)
		rev = hd t :: rev;
	tools = rev;

	# Pre-load all tool modules now, before namespace restriction.
	# Tools like exec need to load sh.dis which won't be visible
	# after restrictns() restricts /dis. Loading eagerly here ensures
	# all tool dependencies are resolved while /dis is unrestricted.
	if(verbose)
		sys->fprint(stderr, "tools9p[%s]: loading %d active tools\n", mountpt_g, len tools);
	for(t = tools; t != nil; t = tl t) {
		ti := hd t;
		err := loadtool(ti);
		if(err != nil)
			sys->fprint(stderr, "tools9p: warning: %s\n", err);
		else if(verbose)
			sys->fprint(stderr, "tools9p[%s]: loaded %s\n", mountpt_g, ti.name);
	}

	# Pre-load ALL remaining known tools into alltools (inactive pool).
	# This must happen before namespace restriction so /dis is accessible.
	# Later ctl-add can activate these without needing to load new modules.
	alltools = nil;
	nall := 0;
	for(i := 0; i < len TOOL_PATHS; i++) {
		(pnm, ppath) := TOOL_PATHS[i];
		if(findtool(pnm) != nil)  # already in active set
			continue;
		ati := ref ToolInfo(pnm, ppath, nil, 0, nil);
		loadtool(ati);  # ignore error (hardware tools may not load)
		alltools = ati :: alltools;
		nall++;
	}
	if(verbose)
		sys->fprint(stderr, "tools9p[%s]: pre-loaded %d inactive tools\n", mountpt_g, nall);
}

# Find tool by name
findtool(name: string): ref ToolInfo
{
	lname := str->tolower(name);
	for(t := tools; t != nil; t = tl t) {
		ti := hd t;
		if(ti.name == lname)
			return ti;
	}
	return nil;
}

# Find tool by qid (aligns to stride base for subfile qids)
findtoolbyqid(qid: int): ref ToolInfo
{
	if(qid < Qtoolbase)
		return nil;
	base := Qtoolbase + ((qid - Qtoolbase) / TOOL_STRIDE) * TOOL_STRIDE;
	for(t := tools; t != nil; t = tl t) {
		ti := hd t;
		if(ti.qid == base)
			return ti;
	}
	return nil;
}

# Find tool in inactive pool (alltools)
findalltool(name: string): ref ToolInfo
{
	lname := str->tolower(name);
	for(t := alltools; t != nil; t = tl t) {
		ti := hd t;
		if(ti.name == lname)
			return ti;
	}
	return nil;
}

# A tool is delegatable to a child if it is loaded anywhere — the active
# set (`tools`, what this agent exposes directly) OR the pre-loaded
# inactive pool (`alltools`). The parent need NOT have the tool active to
# delegate it: the meta-agent's own toolset is intentionally restricted,
# but it holds a broader delegation budget (-b) of tools it may hand to
# task agents, which each get their own tools9p with the tool activated.
# Checking only the active set (the old `findtool` test) wrongly denied
# every budget-only tool (write, edit, exec, websearch, ...), so the meta
# could never delegate the very tools it is meant to delegate.
toolavailable(name: string): int
{
	return findtool(name) != nil || findalltool(name) != nil;
}

# Move a tool from alltools to the active set; return nil on success or error string
ctladd(name: string): string
{
	lname := str->tolower(name);
	if(findtool(lname) != nil)
		return nil;  # already active
	ti := findalltool(lname);
	if(ti == nil)
		return "unknown tool: " + name;
	if(ti.mod == nil)
		return "tool module not loaded: " + name;
	# Assign new qid block (next stride-aligned slot above max)
	maxqid := Qtoolbase - TOOL_STRIDE;
	for(qt := tools; qt != nil; qt = tl qt)
		if((hd qt).qid > maxqid)
			maxqid = (hd qt).qid;
	ti.qid = maxqid + TOOL_STRIDE;
	# Remove from alltools
	newlist: list of ref ToolInfo;
	for(at := alltools; at != nil; at = tl at)
		if((hd at).name != ti.name)
			newlist = hd at :: newlist;
	alltools = newlist;
	tools = ti :: tools;
	vers++;
	return nil;
}

# Move a tool from the active set back to alltools (deactivate)
ctlremove(name: string)
{
	lname := str->tolower(name);
	newlist: list of ref ToolInfo;
	for(t := tools; t != nil; t = tl t) {
		ti := hd t;
		if(ti.name == lname) {
			ti.qid = 0;
			alltools = ti :: alltools;
		} else
			newlist = hd t :: newlist;
	}
	tools = newlist;
	vers++;
}

# Load tool module if not already loaded
# Note: tool exec is now async (spawned), but in practice each tool is
# only invoked by one agent at a time, so no lock is needed.
loadtool(ti: ref ToolInfo): string
{
	if(ti.mod != nil)
		return nil;

	ti.mod = load Tool ti.path;
	if(ti.mod == nil)
		return sys->sprint("cannot load tool %s: %r", ti.name);

	# Initialize the tool module
	err := ti.mod->init();
	if(err != nil)
		return sys->sprint("cannot init tool %s: %s", ti.name, err);

	return nil;
}

strlist_contains(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

# Generate list of bound paths (newline-separated for /tool/paths).
# Format: "path perm" per line (e.g. "/n/local/Users/pdfinn/tmp rw").
genpathlist(): string
{
	result := "";
	for(p := boundpaths; p != nil; p = tl p) {
		bp := hd p;
		if(result != "")
			result += "\n";
		result += bp.path + " " + bp.perm;
	}
	return result;
}

# Find a BoundPath by path string, or nil if not found.
findboundpath(path: string): ref BoundPath
{
	for(bp := boundpaths; bp != nil; bp = tl bp)
		if((hd bp).path == path)
			return hd bp;
	return nil;
}

# Split "path [perm]" into (path, perm). Default perm is "rw".
splitpathperm(s: string): (string, string)
{
	if(len s > 3 && s[len s - 3] == ':' && (s[len s - 2:] == "ro" || s[len s - 2:] == "rw"))
		return (s[0:len s - 3], s[len s - 2:]);

	# Find last space — everything after it is perm if it's "ro" or "rw"
	for(i := len s - 1; i > 0; i--) {
		if(s[i] == ' ') {
			tail := s[i+1:];
			if(tail == "ro" || tail == "rw")
				return (s[0:i], tail);
			break;
		}
	}
	return (s, "rw");
}

pathwithin(grant, want: string): int
{
	if(grant == want)
		return 1;
	if(len want > len grant && want[0:len grant] == grant && want[len grant] == '/')
		return 1;
	return 0;
}

validatepath(p: string): string
{
	if(p == nil || len p == 0)
		return "empty path";
	if(p[0] != '/')
		return "path must be absolute";
	if(p == "/")
		return "root path is not grantable";

	start := 1;
	for(i := 1; i <= len p; i++) {
		if(i == len p || p[i] == '/') {
			comp := p[start:i];
			if(comp == "")
				return "empty path component";
			if(comp == "." || comp == "..")
				return "dot path component";
			start = i + 1;
		}
	}
	return nil;
}

childbudget(): list of string
{
	ok: list of string;
	for(bl := budget; bl != nil; bl = tl bl)
		if(toolavailable(hd bl))
			ok = hd bl :: ok;
	return ok;
}

childpathallowed(path: string): int
{
	# Bare /mnt/msg is deliberately attenuated by nsconstruct to the read-only
	# status surface. It must not act as a lexical parent capability for hidden
	# proposal/control endpoints when an agent provisions a child task.
	if(path == "/mnt/msg/draft" || path == "/mnt/msg/flag") {
		for(ep0 := extpaths; ep0 != nil; ep0 = tl ep0)
			if(hd ep0 == path)
				return 1;
		for(bp0 := boundpaths; bp0 != nil; bp0 = tl bp0)
			if((hd bp0).path == path)
				return 1;
		return 0;
	}
	for(ep := extpaths; ep != nil; ep = tl ep)
		if(pathwithin(hd ep, path))
			return 1;
	for(bp := boundpaths; bp != nil; bp = tl bp)
		if(pathwithin((hd bp).path, path))
			return 1;
	return 0;
}

pathperm(path: string): string
{
	# The narrowest grant controls. Otherwise a broad rw grant can override a
	# more specific ro grant solely because of command-line/list ordering.
	best := "";
	perm := "ro";
	for(bp := boundpaths; bp != nil; bp = tl bp) {
		b := hd bp;
		if(pathwithin(b.path, path) &&
		   (len b.path > len best || (len b.path == len best && b.perm == "ro"))) {
			best = b.path;
			perm = b.perm;
		}
	}
	return perm;
}

genwritepaths(): list of string
{
	paths: list of string;
	for(bp := boundpaths; bp != nil; bp = tl bp)
		if((hd bp).perm == "rw")
			paths = (hd bp).path :: paths;
	return paths;
}

execpaths(): list of string
{
	# Raw shell execution can write through the filesystem directly, bypassing
	# write/edit's /tool/paths checks. Only expose explicit rw grants, which
	# restrictns stages through cowfs via genwritepaths().
	paths: list of string;
	for(bp := boundpaths; bp != nil; bp = tl bp)
		if((hd bp).perm == "rw")
			paths = (hd bp).path :: paths;
	return paths;
}

execwritepaths(): list of string
{
	# Exec always sees baseline read-only config/tool trees that nsconstruct
	# keeps for normal tool operation. Raw shell code can still open those
	# files for write if the backing filesystem permits it, so stage them
	# through cowfs as well as explicit rw grants.
	paths := genwritepaths();
	paths = addpath(paths, "/lib/veltro");
	paths = addpath(paths, "/lib/certs");
	paths = addpath(paths, "/dis/veltro");
	return paths;
}

# Check if any BoundPath has the given path string.
boundpath_contains(path: string): int
{
	return findboundpath(path) != nil;
}

# Generate list of delegatable budget tools (newline-separated for /tool/budget)
genbudgetlist(): string
{
	result := "";
	for(b := budget; b != nil; b = tl b) {
		if(result != "")
			result += "\n";
		result += hd b;
	}
	return result;
}

# Generate list of tool names (newline-separated for /tool/tools)
gentoollist(): string
{
	result := "";
	for(t := tools; t != nil; t = tl t) {
		ti := hd t;
		if(result != "")
			result += "\n";
		result += ti.name;
	}
	return result;
}

# Generate registry list (space-separated for /_registry)
# Used by spawn.b to validate tools without causing deadlock
genregistrylist(): string
{
	result := "";
	for(t := tools; t != nil; t = tl t) {
		ti := hd t;
		if(result != "")
			result += " ";
		result += ti.name;
	}
	return result;
}

# Get documentation for a tool
# First tries /lib/veltro/tools/<name>.txt, then falls back to module doc()
gettooldoc(name: string): string
{
	ti := findtool(name);
	if(ti == nil)
		return "error: unknown tool: " + name;

	# Try file-based documentation first
	docpath := "/lib/veltro/tools/" + ti.name + ".txt";
	doc := readfile(docpath);
	if(doc != nil && len doc > 0)
		return doc;

	# Fallback to module doc()
	err := loadtool(ti);
	if(err != nil)
		return "error: " + err;

	return ti.mod->doc();
}

# Get OpenAI-format function-schema for a tool.
# Returns the tool's schema() output, or a generic fallback if the tool
# hasn't published one yet. The fallback matches the legacy contract
# (single "args" string parameter) so partially-rolled-out toolsets
# remain valid for an OpenAI tool-call client.
gettoolschema(name: string): string
{
	ti := findtool(name);
	if(ti == nil)
		return "error: unknown tool: " + name;

	err := loadtool(ti);
	if(err != nil)
		return "error: " + err;

	s := ti.mod->schema();
	if(s == "" || s == nil)
		return defaultschema(ti.name);
	return s;
}

# Generic legacy schema: one free-form string argument. Used when a
# tool hasn't been migrated to a per-tool schema yet. Matches the shape
# the agentlib bridge formerly hardcoded for every tool.
defaultschema(name: string): string
{
	return "{\"name\":\"" + name + "\"," +
		"\"description\":\"Run the " + name + " tool with the given arguments\"," +
		"\"parameters\":{\"type\":\"object\"," +
		"\"properties\":{\"args\":{\"type\":\"string\"," +
		"\"description\":\"Tool arguments as a single string\"}}," +
		"\"required\":[\"args\"]}}";
}

# Read entire file contents (for documentation files)
readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;

	content := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		content += string buf[0:n];
	}
	if(content == "")
		return nil;
	return content;
}

# Execute a tool with arguments
exectool(name, args: string): string
{
	ti := findtool(name);
	if(ti == nil)
		return "error: unknown tool: " + name;

	err := loadtool(ti);
	if(err != nil)
		return "error: " + err;

	return ti.mod->exec(args);
}

# Async wrapper: runs tool execution in a spawned thread so the
# serveloop continues processing 9P messages while the tool runs.
# The Styx reply is sent from this thread when execution completes.
# Namespace restriction is applied HERE (not in serveloop) so each
# invocation uses the current boundpaths at call time — essential for
# paths bound via the GUI after the server was already running.
asyncexec(srv: ref Styxserver, tag: int, count: int, ti: ref ToolInfo, data: string)
{
	mypid := sys->pctl(Sys->FORKNS, nil);
	if(mypid < 0) {
		ti.result = array of byte "error: cannot fork namespace";
		srv.reply(ref Rmsg.Error(tag, "cannot fork namespace"));
		return;
	}
	# Exec opens only its own wait descriptor inside the trusted wrapper, then
	# applies NODEVS before parsing or running model-supplied shell text.
	if(ti.name != "exec" && sys->pctl(Sys->NODEVS, nil) < 0) {
		ti.result = array of byte "error: cannot disable device attachment";
		srv.reply(ref Rmsg.Error(tag, "cannot disable device attachment"));
		return;
	}
	# Bind our mount point over /tool BEFORE namespace restriction.
	# /tool.N is still visible in the inherited namespace at this point.
	# restrictdir("/", safe) preserves "tool" and captures the current
	# binding — so /tool (now pointing to /tool.N) survives restriction.
	# If this bind were AFTER restriction, /tool.N would already be hidden
	# (not in the safe list) and the bind would fail silently, leaving
	# /tool pointing to the parent instance (wrong activity ID).
	if(mountpt_g != "/tool" && sys->bind(mountpt_g, "/tool", Sys->MREPL) < 0) {
		ti.result = array of byte "error: cannot bind activity tool service";
		srv.reply(ref Rmsg.Error(tag, "cannot bind activity tool service"));
		return;
	}
	nserr := applynsrestriction(ti.name);
	if(nserr != nil) {
		ti.result = array of byte ("error: namespace restriction failed: " + nserr);
		srv.reply(ref Rmsg.Error(tag, "namespace restriction failed"));
		alt {
		cleanupchan <-= mypid => ;
		* => ;
		}
		return;
	}
	result := exectool(ti.name, data);
	# Assign result before replying so it's visible for subsequent reads.
	# NOTE: concurrent writes to the same tool will overwrite each other's
	# result — this is a known limitation. A per-fid result map would fix it.
	rbytes := array of byte result;
	ti.result = rbytes;
	srv.reply(ref Rmsg.Write(tag, count));
	# Signal cleanup goroutine to remove this invocation's shadow dirs.
	# Non-blocking: if buffer is full, drop (dirs cleaned at next startup).
	alt {
		cleanupchan <-= mypid => ;
		* => ;
	}
}

rf(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return nil;
	return string b[0:n];
}

# Remove one shadow dir and its one-level-deep placeholder entries.
# From the parent namespace (no FORKNS), the shadow dir's children are empty
# placeholder dirs/files — the bind mounts over them exist only in child
# goroutine namespaces and are invisible here.
removeshadowdir(dir: string)
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd != nil) {
		for(;;) {
			(n, entries) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++)
				sys->remove(dir + "/" + entries[i].name);
		}
		fd = nil;
	}
	sys->remove(dir);
}

# Remove all shadow dirs created by a specific PID.
# Named SHADOW_BASE/PID-SEQ; we match by "PID-" prefix.
removepidshadows(pid: int)
{
	fd := sys->open(SHADOW_BASE, Sys->OREAD);
	if(fd == nil)
		return;
	prefix := sys->sprint("%d-", pid);
	plen := len prefix;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := dirs[i].name;
			if(len name >= plen && name[0:plen] == prefix)
				removeshadowdir(SHADOW_BASE + "/" + name);
		}
	}
	fd = nil;
}

# Remove ALL shadow dirs — used at startup to clear previous session's dirs.
cleanshadows()
{
	fd := sys->open(SHADOW_BASE, Sys->OREAD);
	if(fd == nil)
		return;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := dirs[i].name;
			if(name != "." && name != "..")
				removeshadowdir(SHADOW_BASE + "/" + name);
		}
	}
	fd = nil;
}

# Goroutine: drains cleanupchan and removes shadow dirs for each completed
# asyncexec invocation.  Runs in the unrestricted parent namespace so it can
# reach SHADOW_BASE regardless of what child goroutines have restricted.
shadowcleanloop()
{
	for(;;) {
		pid := <-cleanupchan;
		if(pid < 0)
			break;
		removepidshadows(pid);
	}
}

# Ensure a directory exists
ensuredir(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil)
		return;

	# Try to create parent first
	for(i := len path - 1; i > 0; i--) {
		if(path[i] == '/') {
			ensuredir(path[0:i]);
			break;
		}
	}

	# Create this directory
	fd = sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
	if(fd == nil)
		sys->fprint(stderr, "tools9p: cannot create directory %s: %r\n", path);
}

# Provision a child task: spawn tools9p + lucibridge in the UNRESTRICTED
# parent namespace.  Called from serveloop via "provision" ctl command.
# args format: "<id> [tools=<csv>] [paths=<csv>]"
ShCommand: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

provisiontask(args: string)
{
	# Parse id and optional key=value attrs
	(nil, toks) := sys->tokenize(args, " ");
	if(toks == nil) {
		sys->fprint(stderr, "tools9p: provision: no activity id\n");
		return;
	}
	idstr := hd toks;
	toks = tl toks;
	(id, nil) := str->toint(idstr, 10);
	if(id < 0) {
		sys->fprint(stderr, "tools9p: provision: invalid id %s\n", idstr);
		return;
	}

	# Parse optional tools= and paths= attrs
	toolsarg := "";
	pathsarg := "";
	for(; toks != nil; toks = tl toks) {
		tok := hd toks;
		if(len tok > 6 && tok[0:6] == "tools=")
			toolsarg = tok[6:];
		else if(len tok > 6 && tok[0:6] == "paths=")
			pathsarg = tok[6:];
	}

	# Build tool list: requested tools must stay within the delegation
	# budget and be loaded (active OR pre-loaded inactive). The budget,
	# not the parent's active set, is the delegation boundary — a child
	# may receive any budget tool even when the parent holds it inactive.
	# Child tasks may narrow, never expand beyond the budget.
	toollist: list of string;
	if(toolsarg != "") {
		(nil, ttoks) := sys->tokenize(toolsarg, ",");
		for(; ttoks != nil; ttoks = tl ttoks) {
			tname := hd ttoks;
			if(!strlist_contains(childbudget(), tname) || !toolavailable(tname)) {
				sys->fprint(stderr, "tools9p: provision: denied tool %s\n", tname);
				continue;
			}
			toollist = tname :: toollist;
		}
	} else {
		# Default: delegate all budget tools
		for(b := childbudget(); b != nil; b = tl b)
			toollist = hd b :: toollist;
	}

	# Baseline tools are read-only namespace navigation. Persistence, recursive
	# delegation, planning state, and UI effects are explicit capabilities and
	# must never appear merely because the subject is a child agent.
	basics := "read" :: "list" :: "find" :: "search" :: "grep" :: nil;
	for(bl := basics; bl != nil; bl = tl bl)
		if(findtool(hd bl) != nil && !strlist_contains(toollist, hd bl))
			toollist = hd bl :: toollist;

	pathcaps: list of ref BoundPath;
	if(pathsarg != "") {
		(nil, ptoks0) := sys->tokenize(pathsarg, ",");
		for(; ptoks0 != nil; ptoks0 = tl ptoks0) {
			raw := hd ptoks0;
			if(raw == "")
				continue;
			(ppath, pperm) := splitpathperm(raw);
			perr := validatepath(ppath);
			if(perr != nil) {
				sys->fprint(stderr, "tools9p: provision: denied invalid path %s: %s\n", ppath, perr);
				continue;
			}
			if(!childpathallowed(ppath)) {
				sys->fprint(stderr, "tools9p: provision: denied path %s\n", ppath);
				continue;
			}
			if(pathperm(ppath) == "ro")
				pperm = "ro";
			pathcaps = ref BoundPath(ppath, pperm) :: pathcaps;
		}
	}

	# Build tools9p args list (reversed, then flip at end)
	mpt := "/tool." + string id;
	rargs: list of string;
	# Tool names go last — prepend in reverse
	for(tl2 := toollist; tl2 != nil; tl2 = tl tl2)
		rargs = hd tl2 :: rargs;
	# Paths go before tools: explicit paths from task create
	if(pathcaps != nil) {
		for(pl := pathcaps; pl != nil; pl = tl pl) {
			bp := hd pl;
			parg := bp.path + ":" + bp.perm;
			rargs = parg :: rargs;
			rargs = "-p" :: rargs;
		}
	}
	# Inherit parent's extpaths (e.g. /dis/wm for app discovery).
	# Without these, the child's restrictns() hides paths the parent
	# exposes, breaking tools like launch that need /dis/wm access.
	for(ep := extpaths; ep != nil; ep = tl ep) {
		rargs = hd ep :: rargs;
		rargs = "-p" :: rargs;
	}
	# Mount point, activity id, verbose, and program name go first
	rargs = mpt :: rargs;
	rargs = "-m" :: rargs;
	rargs = string id :: rargs;
	rargs = "-a" :: rargs;
	# Child agents run with NODEVS applied in the spawn/child path, so the
	# provisioned tools9p declares role=child, nodevs=set at /tool/meta for
	# nsaudit (INFR-18).
	rargs = "child" :: rargs;
	rargs = "-r" :: rargs;
	rargs = "-N" :: rargs;
	if(verbose)
		rargs = "-v" :: rargs;
	rargs = "tools9p" :: rargs;

	sys->fprint(stderr, "tools9p: provisioning activity %d at %s\n", id, mpt);

	# Load and spawn child tools9p as a module (new data segment per load).
	# This avoids the unreliable shell-based approach — direct module loading
	# guarantees the server starts and we can poll for mount readiness.
	t9p := load ShCommand "/dis/veltro/tools9p.dis";
	if(t9p == nil) {
		sys->fprint(stderr, "tools9p: provision: cannot load tools9p.dis: %r\n");
		return;
	}
	spawn t9p->init(nil, rargs);

	# Poll for mount readiness — wait until the trusted control alias exists
	ctlpath := controlmount(mpt) + "/ctl";
	ready := 0;
	for(i := 0; i < 20; i++) {
		sys->sleep(500);
		(ok, nil) := sys->stat(ctlpath);
		if(ok >= 0) {
			ready = 1;
			break;
		}
	}
	if(!ready) {
		sys->fprint(stderr, "tools9p: provision: %s did not mount after 10s\n", mpt);
		return;
	}

	sys->fprint(stderr, "tools9p: provision: %s mounted, starting lucibridge\n", mpt);

	# Load and start lucibridge — this blocks (runs agent loop),
	# which is fine since provisiontask is already a spawned goroutine.
	lb := load ShCommand "/dis/lucibridge.dis";
	if(lb == nil) {
		sys->fprint(stderr, "tools9p: provision: cannot load lucibridge.dis: %r\n");
		return;
	}
	lbargs := "lucibridge" :: "-a" :: string id :: "-s" :: nil;
	if(verbose)
		lbargs = "lucibridge" :: "-v" :: "-a" :: string id :: "-s" :: nil;
	lb->init(nil, lbargs);
}

# Return manifest file path for a given tools9p mount point.
# /tool → /tmp/veltro/.ns/manifest
# /tool.N → /tmp/veltro/.ns/manifest.N
manifestpath(mpt: string): string
{
	if(mpt == "/tool")
		return "/tmp/veltro/.ns/manifest";
	# Extract suffix after "/tool."
	if(len mpt > 6 && mpt[0:6] == "/tool.")
		return "/tmp/veltro/.ns/manifest." + mpt[6:];
	return "/tmp/veltro/.ns/manifest";
}

# Write namespace manifest at startup so the UI shows the agent's
# namespace before any tool calls happen. Runs in a throwaway goroutine
# with its own FORKNS — the restricted namespace is discarded after
# emitmanifest completes.
emitmanifestnow(mpath: string)
{
	nsconstruct := load NsConstruct NsConstruct->PATH;
	if(nsconstruct == nil)
		return;
	nsconstruct->init();
	sys->pctl(Sys->FORKNS, nil);

	hasxenith := 0;
	if(findtool("xenith") != nil)
		hasxenith = 1;
	toolnames: list of string = nil;
	for(t := tools; t != nil; t = tl t)
		toolnames = (hd t).name :: toolnames;
	allpaths := extpaths;
	for(bp := boundpaths; bp != nil; bp = tl bp)
		if(!strlist_contains(allpaths, (hd bp).path))
			allpaths = (hd bp).path :: allpaths;
	if(findtool("say") != nil || findtool("hear") != nil)
		if(!strlist_contains(allpaths, "/n/speech"))
			allpaths = "/n/speech" :: allpaths;
	if(findtool("wallet") != nil || findtool("payfetch") != nil)
		if(!strlist_contains(allpaths, "/n/wallet"))
			allpaths = "/n/wallet" :: allpaths;
	# Auto-grant /phone when any phone-bridge tool is registered. devphone
	# (#f) is bound at /phone by lib/lucifer/boot-mobile.sh (mobile) or
	# is mounted from a paired phone (desktop). Child activity namespaces
	# don't inherit that bind, so restrictns() would otherwise hide /phone
	# and the sms / dial / contacts tools fail with "does not exist".
	if(findtool("sms") != nil || findtool("dial") != nil ||
	   findtool("contacts") != nil)
		if(!strlist_contains(allpaths, "/phone"))
			allpaths = "/phone" :: allpaths;
	for(tl3 := toolnames; tl3 != nil; tl3 = tl tl3)
		allpaths = addtoolpaths(allpaths, hd tl3);
	caps := ref NsConstruct->Capabilities(
		toolnames, allpaths, nil, nil, nil, nil, 0, hasxenith, activityid, genwritepaths()
	, nil);
	{
		nserr := nsconstruct->restrictns(caps);
		if(nserr != nil)
			sys->fprint(stderr, "tools9p: manifest restrictns failed: %s\n", nserr);
		else {
			nsconstruct->emitmanifest(caps, mpath);
			manifest_written = 1;
		}
	} exception e {
	"*" =>
		sys->fprint(stderr, "tools9p: manifest exception: %s\n", e);
	}
}

# Apply namespace restriction to the current (already-forked) namespace.
# Caller (asyncexec) is responsible for FORKNS and the /tool bind
# BEFORE calling this — that ordering ensures /tool.N survives restriction.
applynsrestriction(invokedtool: string): string
{
	nsconstruct := load NsConstruct NsConstruct->PATH;
	if(nsconstruct == nil)
		return sys->sprint("cannot load nsconstruct: %r");
	nsconstruct->init();
	# /chan is an explicit per-operation capability. Browse creates a Xenith
	# window; xenith controls windows. No other invocation sees window contents.
	hasxenith := invokedtool == "xenith" || invokedtool == "browse";
	# Attenuate to the current operation. The agent may have many tools in its
	# menu, but this child namespace receives only the invoked tool's authority.
	# Passing caps.tools lets restrictns() apply the security model:
	#   - sh.dis bound to /dis when exec is in the list (step 1)
	#   - /dis/veltro/tools restricted to registered .dis files (step 2)
	# sh.dis appears ONLY if exec was explicitly passed by the caller.
	toolnames := invokedtool :: nil;
	# Merge extpaths (from -p flags) and boundpaths (from runtime bindpath ctl).
	# Called per-invocation from asyncexec(), so boundpaths always reflects
	# the current state — paths bound via the GUI after startup are captured.
	# Exec is special: it is raw shell authority, so read-only path grants are
	# not exposed to it. Otherwise shell redirection can mutate a supposedly
	# read-only tree. Explicit rw grants remain visible and are staged by cowfs.
	allpaths := extpaths;
	if(invokedtool == "exec")
		allpaths = execpaths();
	else
		for(bp2 := boundpaths; bp2 != nil; bp2 = tl bp2)
			if(!strlist_contains(allpaths, (hd bp2).path))
				allpaths = (hd bp2).path :: allpaths;
	# Auto-grant /n/speech when say or hear tool is registered.
	# speech9p mounts /n/speech in the shared namespace; without this,
	# restrictns() hides it entirely and say/hear tools fail silently.
	if(invokedtool == "say" || invokedtool == "hear")
		if(!strlist_contains(allpaths, "/n/speech"))
			allpaths = "/n/speech" :: allpaths;
	# Auto-grant /phone when sms or dial tool is registered (see
	# companion in emitmanifestnow above — same reason).
	if(invokedtool == "sms" || invokedtool == "dial")
		if(!strlist_contains(allpaths, "/phone"))
			allpaths = "/phone" :: allpaths;
	# Auto-grant /n/wallet when wallet or payfetch tool is registered.
	if(invokedtool == "wallet" || invokedtool == "payfetch")
		if(!strlist_contains(allpaths, "/n/wallet"))
			allpaths = "/n/wallet" :: allpaths;
	allpaths = addtoolpaths(allpaths, invokedtool);
	writepaths := genwritepaths();
	if(invokedtool == "exec")
		writepaths = execwritepaths();
	caps := ref NsConstruct->Capabilities(
		toolnames, allpaths, nil, nil, nil, nil, 0, hasxenith, activityid, writepaths
	, nil);
	{
		nserr := nsconstruct->restrictns(caps);
		if(nserr != nil) {
			sys->fprint(stderr, "tools9p: restrictns failed: %s\n", nserr);
			return nserr;
		} else if(!manifest_written) {
			nsconstruct->emitmanifest(caps, manifestpath(mountpt_g));
			manifest_written = 1;
		}
	} exception e {
	"*" =>
		sys->fprint(stderr, "tools9p: restrictns exception: %s\n", e);
		return e;
	}
	return nil;
}

addtoolpaths(paths: list of string, tool: string): list of string
{
	case tool {
	"charon" =>
		return addpath(paths, "/tmp/veltro/browser");
	"editor" =>
		return addpath(paths, "/tmp/veltro/editor");
	"shell" =>
		return addpath(paths, "/tmp/veltro/shell");
	"fractal" =>
		return addpath(paths, "/tmp/veltro/fractal");
	"man" =>
		return addpath(paths, "/tmp/veltro/man");
	}
	return paths;
}

addpath(paths: list of string, path: string): list of string
{
	if(strlist_contains(paths, path))
		return paths;
	return path :: paths;
}

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver, pidc: chan of int, navops: chan of ref Navop, mounted: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWFD, 1::2::srv.fd.fd::nil);

	restricted := 0;

Serve:
	while((gm := <-tchan) != nil) {
		# Wait for mount completion before allowing tool invocations.
		# Restriction is applied per-invocation in asyncexec() so that
		# paths bound after startup are always captured at call time.
		if(!restricted) {
			alt {
			<-mounted =>
				restricted = 1;
			* =>
				;  # Mount not ready yet, continue serving
			}
		}

		pick m := gm {
		Readerror =>
			sys->fprint(stderr, "tools9p: fatal read error: %s\n", m.error);
			break Serve;

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

			# Clear any previous result data
			c.data = nil;

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
				srv.read(m);  # navigator handles directory reads
				break;
			}

			qtype := TYPE(c.path);

			case qtype {
			Qtools =>
				# List all tool names
				data := array of byte gentoollist();
				srv.reply(styxservers->readbytes(m, data));

			Qhelp =>
				# Return last help query result (stored globally so
				# separate write/read fids see the same data)
				if(helpresult == nil)
					helpresult = array of byte ("Write a tool name to get documentation.\nAvailable: " + gentoollist());
				srv.reply(styxservers->readbytes(m, helpresult));

			Qregistry =>
				# Return space-separated list of tool names
				# This is a synchronous read that doesn't go through 9P message queue,
				# avoiding deadlock when spawn.b validates tools
				data := array of byte genregistrylist();
				srv.reply(styxservers->readbytes(m, data));

			Qctl =>
				srv.reply(styxservers->readbytes(m, array of byte ""));

			Qpaths =>
				srv.reply(styxservers->readbytes(m, array of byte genpathlist()));

			Qbudget =>
				srv.reply(styxservers->readbytes(m, array of byte genbudgetlist()));

			Qactivity =>
				srv.reply(styxservers->readbytes(m, array of byte string activityid));

			Qmetarole =>
				srv.reply(styxservers->readbytes(m, array of byte (agentrole + "\n")));

			Qmetaxenith =>
				xv := "0";
				if(findtool("xenith") != nil)
					xv = "1";
				srv.reply(styxservers->readbytes(m, array of byte (xv + "\n")));

			Qmetaactid =>
				srv.reply(styxservers->readbytes(m, array of byte (string activityid + "\n")));

			Qmetanodevs =>
				srv.reply(styxservers->readbytes(m, array of byte (agentnodevs + "\n")));

			* =>
				# Tool directory/subfile reads
				if(qtype >= Qtoolbase) {
					suboff := toolqtype(qtype).t1;
					ti := findtoolbyqid(qtype);
					if(ti == nil) {
						srv.reply(ref Rmsg.Error(m.tag, Enotfound));
						break;
					}
					case suboff {
					Qtool_dir =>
						srv.read(m);  # directory read via navigator
					Qtool_ctl or Qtool_run =>
						# ctl and run share ti.result: write args to either,
						# read either back. run is the INFR-2 alias.
						if(ti.result == nil)
							ti.result = array of byte "error: no result (write arguments first)";
						srv.reply(styxservers->readbytes(m, ti.result));
					Qtool_doc =>
						doc := gettooldoc(ti.name);
						srv.reply(styxservers->readbytes(m, array of byte doc));
					Qtool_schema =>
						sch := gettoolschema(ti.name);
						srv.reply(styxservers->readbytes(m, array of byte sch));
					* =>
						srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					}
				} else {
					srv.reply(ref Rmsg.Error(m.tag, Eperm));
				}
			}

		Write =>
			(c, merr) := srv.canwrite(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, merr));
				break;
			}

			qtype := TYPE(c.path);
			data := string m.data;

			# Strip trailing newline
			if(len data > 0 && data[len data - 1] == '\n')
				data = data[0:len data - 1];

			case qtype {
			Qhelp =>
				# Write tool name, store documentation globally
				# (so a different fid's read sees it)
				doc := gettooldoc(data);
				helpresult = array of byte doc;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qctl =>
				# Dynamic tool management: "add <name>" or "remove <name>"
				# Namespace path management: "bindpath <path>" or "unbindpath <path>"
				# WARNING: any process with write access to /tool/ctl can escalate
				# agent capabilities. Restrict ctl file permissions if needed.
				if(len data > 4 && data[0:4] == "add ") {
					cerr := ctladd(data[4:]);
					if(cerr != nil)
						srv.reply(ref Rmsg.Error(m.tag, cerr));
					else
						srv.reply(ref Rmsg.Write(m.tag, len m.data));
				} else if(len data > 7 && data[0:7] == "remove ") {
					ctlremove(data[7:]);
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				} else if(len data > 9 && data[0:9] == "bindpath ") {
					# "bindpath <path> [ro|rw]" — default perm is "rw"
					rest := data[9:];
					(bpath, bperm) := splitpathperm(rest);
					perr := validatepath(bpath);
					if(perr != nil) {
						srv.reply(ref Rmsg.Error(m.tag, "invalid path: " + perr));
						break;
					}
					existing := findboundpath(bpath);
					if(existing != nil)
						existing.perm = bperm;  # update perm on re-bind
					else
						boundpaths = ref BoundPath(bpath, bperm) :: boundpaths;
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				} else if(len data > 11 && data[0:11] == "unbindpath ") {
					p := data[11:];
					nl: list of ref BoundPath;
					for(bl := boundpaths; bl != nil; bl = tl bl)
						if((hd bl).path != p)
							nl = hd bl :: nl;
					boundpaths = nl;
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				} else if(len data > 8 && data[0:8] == "setperm ") {
					# "setperm <path> <ro|rw>" — change perm on existing bound path
					rest := data[8:];
					(spath, sperm) := splitpathperm(rest);
					perr := validatepath(spath);
					if(perr != nil) {
						srv.reply(ref Rmsg.Error(m.tag, "invalid path: " + perr));
						break;
					}
					existing2 := findboundpath(spath);
					if(existing2 != nil) {
						existing2.perm = sperm;
						srv.reply(ref Rmsg.Write(m.tag, len m.data));
					} else {
						srv.reply(ref Rmsg.Error(m.tag, "path not bound: " + spath));
					}
				} else if(len data > 11 && data[0:11] == "budget-add ") {
					bname := data[11:];
					if(!strlist_contains(budget, bname))
						budget = bname :: budget;
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				} else if(len data > 14 && data[0:14] == "budget-remove ") {
					bname := data[14:];
					nbl: list of string;
					for(bbl := budget; bbl != nil; bbl = tl bbl)
						if(hd bbl != bname)
							nbl = hd bbl :: nbl;
					budget = nbl;
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				} else if(len data > 10 && data[0:10] == "provision ") {
					# "provision <id> [tools=<csv>] [paths=<csv>]"
					# Spawn child tools9p + lucibridge in the UNRESTRICTED
					# parent namespace (serveloop runs before any restrictns).
					spawn provisiontask(data[10:]);
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				} else {
					srv.reply(ref Rmsg.Error(m.tag, "usage: add|remove <tool> or bindpath|unbindpath <path> [ro|rw] or setperm <path> <ro|rw> or budget-add|budget-remove <tool> or provision <id>"));
				}

			Qprovision =>
				# Agent-visible provisioning is intentionally narrow: the child task
				# may only receive subsets of the current tool/path grants.
				spawn provisiontask(data);
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			* =>
				# Tool ctl writes - execute asynchronously to avoid blocking serveloop.
				# Long-running tools (e.g. spawn with multi-step LLM) can take
				# tens of seconds. Running them inline blocks ALL 9P traffic,
				# which starves Xenith's row.qlock and freezes the UI.
				# The Write reply is deferred until exec completes, so the
				# client still sees blocking semantics — but the serveloop
				# remains free to service other fids.
				if(qtype >= Qtoolbase) {
					suboff := toolqtype(qtype).t1;
					if(suboff != Qtool_ctl && suboff != Qtool_run) {
						srv.reply(ref Rmsg.Error(m.tag, Eperm));
						break;
					}
					ti := findtoolbyqid(qtype);
					if(ti == nil) {
						srv.reply(ref Rmsg.Error(m.tag, Enotfound));
						break;
					}
					spawn asyncexec(srv, m.tag, len m.data, ti, data);
				} else {
					srv.reply(ref Rmsg.Error(m.tag, Eperm));
				}
			}

		Clunk =>
			srv.clunk(m);

		Remove =>
			srv.remove(m);

		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;  # shut down navigator
}

dir(qid: Sys->Qid, name: string, length: big, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid = qid;
	if(qid.qtype & Sys->QTDIR)
		perm |= Sys->DMDIR;
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.length = length;
	return d;
}

dirgen(p: big): (ref Sys->Dir, string)
{
	qtype := TYPE(p);

	case qtype {
	Qroot =>
		return (dir(Qid(p, vers, Sys->QTDIR), "/", big 0, 8r755), nil);

	Qtools =>
		return (dir(Qid(p, vers, Sys->QTFILE), "tools", big 0, 8r444), nil);

	Qhelp =>
		return (dir(Qid(p, vers, Sys->QTFILE), "help", big 0, 8r644), nil);

	Qregistry =>
		return (dir(Qid(p, vers, Sys->QTFILE), "_registry", big 0, 8r444), nil);

	Qctl =>
		return (dir(Qid(p, vers, Sys->QTFILE), "ctl", big 0, 8r644), nil);

	Qpaths =>
		return (dir(Qid(p, vers, Sys->QTFILE), "paths", big 0, 8r444), nil);

	Qbudget =>
		return (dir(Qid(p, vers, Sys->QTFILE), "budget", big 0, 8r444), nil);

	Qactivity =>
		return (dir(Qid(p, vers, Sys->QTFILE), "activity", big 0, 8r444), nil);

	Qprovision =>
		return (dir(Qid(p, vers, Sys->QTFILE), "provision", big 0, 8r644), nil);

	Qmeta =>
		return (dir(Qid(p, vers, Sys->QTDIR), "meta", big 0, 8r555), nil);
	Qmetarole =>
		return (dir(Qid(p, vers, Sys->QTFILE), "role", big 0, 8r444), nil);
	Qmetaxenith =>
		return (dir(Qid(p, vers, Sys->QTFILE), "xenith", big 0, 8r444), nil);
	Qmetaactid =>
		return (dir(Qid(p, vers, Sys->QTFILE), "actid", big 0, 8r444), nil);
	Qmetanodevs =>
		return (dir(Qid(p, vers, Sys->QTFILE), "nodevs", big 0, 8r444), nil);
	}

	# Check if it's a tool directory or subfile
	if(qtype >= Qtoolbase) {
		suboff := toolqtype(qtype).t1;
		ti := findtoolbyqid(qtype);
		if(ti != nil) {
			case suboff {
			Qtool_dir =>
				return (dir(Qid(p, vers, Sys->QTDIR), ti.name, big 0, 8r755), nil);
			Qtool_ctl =>
				return (dir(Qid(p, vers, Sys->QTFILE), "ctl", big 0, 8r644), nil);
			Qtool_doc =>
				return (dir(Qid(p, vers, Sys->QTFILE), "doc", big 0, 8r444), nil);
			Qtool_schema =>
				return (dir(Qid(p, vers, Sys->QTFILE), "schema", big 0, 8r444), nil);
			Qtool_run =>
				return (dir(Qid(p, vers, Sys->QTFILE), "run", big 0, 8r644), nil);
			}
		}
	}

	return (nil, Enotfound);
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);

		Walk =>
			qtype := TYPE(n.path);

			if(qtype == Qroot) {
				case n.name {
				".." =>
					;  # stay at root
				"tools" =>
					n.path = big Qtools;
				"help" =>
					n.path = big Qhelp;
				"_registry" =>
					n.path = big Qregistry;
				"ctl" =>
					n.path = big Qctl;
				"paths" =>
					n.path = big Qpaths;
				"budget" =>
					n.path = big Qbudget;
				"activity" =>
					n.path = big Qactivity;
				"meta" =>
					n.path = big Qmeta;
				"provision" =>
					if(findtool("task") == nil) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					n.path = big Qprovision;
				* =>
					# Check if it's a registered tool name
					ti := findtool(n.name);
					if(ti == nil) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					n.path = big ti.qid;  # tool directory qid
				}
				n.reply <-= dirgen(n.path);
			} else if(qtype == Qmeta) {
				# Walk within the meta directory.
				case n.name {
				".." =>
					n.path = big Qroot;
				"role" =>
					n.path = big Qmetarole;
				"xenith" =>
					n.path = big Qmetaxenith;
				"actid" =>
					n.path = big Qmetaactid;
				"nodevs" =>
					n.path = big Qmetanodevs;
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);
			} else if(qtype >= Qtoolbase) {
				# Walk within a tool directory
				suboff := toolqtype(qtype).t1;
				if(suboff != Qtool_dir) {
					n.reply <-= (nil, "not a directory");
					continue;
				}
				case n.name {
				".." =>
					n.path = big Qroot;
				"ctl" =>
					n.path = big(qtype + Qtool_ctl);
				"doc" =>
					n.path = big(qtype + Qtool_doc);
				"schema" =>
					n.path = big(qtype + Qtool_schema);
				"run" =>
					n.path = big(qtype + Qtool_run);
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);
			} else {
				n.reply <-= (nil, "not a directory");
			}

		Readdir =>
			qtype := TYPE(m.path);

			case qtype {
			Qroot =>
				# Root contains: tools, help, _registry, ctl, paths, budget, activity,
				# optional provision, and tool directories.
				i := n.offset;
				count := n.count;

				# Entry 0: tools
				if(i == 0 && count > 0) {
					n.reply <-= dirgen(big Qtools);
					count--;
					i++;
				}

				# Entry 1: help
				if(i <= 1 && count > 0) {
					n.reply <-= dirgen(big Qhelp);
					count--;
					i++;
				}

				# Entry 2: _registry
				if(i <= 2 && count > 0) {
					n.reply <-= dirgen(big Qregistry);
					count--;
					i++;
				}

				# Entry 3: ctl
				if(i <= 3 && count > 0) {
					n.reply <-= dirgen(big Qctl);
					count--;
					i++;
				}

				# Entry 4: paths
				if(i <= 4 && count > 0) {
					n.reply <-= dirgen(big Qpaths);
					count--;
					i++;
				}

				# Entry 5: budget
				if(i <= 5 && count > 0) {
					n.reply <-= dirgen(big Qbudget);
					count--;
					i++;
				}

				# Entry 6: activity
				if(i <= 6 && count > 0) {
					n.reply <-= dirgen(big Qactivity);
					count--;
					i++;
				}

				# Entry 7: meta (always present)
				if(i <= 7 && count > 0) {
					n.reply <-= dirgen(big Qmeta);
					count--;
					i++;
				}

				if(findtool("task") != nil && i <= 8 && count > 0) {
					n.reply <-= dirgen(big Qprovision);
					count--;
					i++;
				}

				# Remaining entries: registered tool directories
				baseoff := 8;
				if(findtool("task") != nil)
					baseoff = 9;
				idx := 0;
				for(t := tools; t != nil && count > 0; t = tl t) {
					ti := hd t;
					if(i <= baseoff + idx) {
						n.reply <-= dirgen(big ti.qid);
						count--;
					}
					idx++;
				}

				n.reply <-= (nil, nil);

			Qmeta =>
				# meta directory: role, xenith, actid, nodevs
				i := n.offset;
				count := n.count;
				if(i == 0 && count > 0) {
					n.reply <-= dirgen(big Qmetarole);
					count--;
					i++;
				}
				if(i <= 1 && count > 0) {
					n.reply <-= dirgen(big Qmetaxenith);
					count--;
					i++;
				}
				if(i <= 2 && count > 0) {
					n.reply <-= dirgen(big Qmetaactid);
					count--;
					i++;
				}
				if(i <= 3 && count > 0) {
					n.reply <-= dirgen(big Qmetanodevs);
					count--;
				}
				n.reply <-= (nil, nil);

			* =>
				if(qtype >= Qtoolbase) {
					suboff := toolqtype(qtype).t1;
					if(suboff != Qtool_dir) {
						n.reply <-= (nil, "not a directory");
					} else {
						# Tool directory: list ctl, doc, schema and run subfiles
						i := n.offset;
						count := n.count;
						if(i == 0 && count > 0) {
							n.reply <-= dirgen(big(qtype + Qtool_ctl));
							count--;
							i++;
						}
						if(i <= 1 && count > 0) {
							n.reply <-= dirgen(big(qtype + Qtool_doc));
							count--;
							i++;
						}
						if(i <= 2 && count > 0) {
							n.reply <-= dirgen(big(qtype + Qtool_schema));
							count--;
							i++;
						}
						if(i <= 3 && count > 0) {
							n.reply <-= dirgen(big(qtype + Qtool_run));
							count--;
						}
						n.reply <-= (nil, nil);
					}
				} else {
					n.reply <-= (nil, "not a directory");
				}
			}
		}
	}
}

# Extract type from path
TYPE(path: big): int
{
	return int path & 16rFFFF;
}

# Decompose a tool-range qid into (tool_base_qid, subfile_offset)
# Returns (-1, -1) if qid is not in the tool range
toolqtype(qid: int): (int, int)
{
	if(qid < Qtoolbase)
		return (-1, -1);
	off := qid - Qtoolbase;
	return (Qtoolbase + (off / TOOL_STRIDE) * TOOL_STRIDE, off % TOOL_STRIDE);
}

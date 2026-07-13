implement NsConstruct;

#
# nsconstruct.b - Namespace construction for Veltro agents (v3)
#
# SECURITY MODEL (v3): FORKNS + bind-replace
# ============================================
# Replace NEWNS + sandbox with FORKNS + bind-replace (MREPL).
# restrictdir() is the core primitive:
#   1. Create shadow directory
#   2. Bind allowed items from target into shadow
#   3. Bind shadow over target (MREPL)
# Result: target only shows allowed items. Everything else is invisible.
#
# This is an allowlist operation. No file copying, no sandbox directories,
# no cleanup needed. Capability attenuation is natural: children fork an
# already-restricted namespace and can only narrow further.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "nsconstruct.m";

include "cowfs.m";

# Trusted namespace construction state lives outside the agent workspace.
# /tmp is narrowed only after all shadow-backed binds have been installed.
SHADOW_BASE: con "/tmp/.veltro-ns/shadow";
AUDIT_DIR: con "/tmp/.veltro-ns/audit";

# Directory/file permissions
DIR_MODE: con 8r700 | Sys->DMDIR;  # rwx------ directory
FILE_MODE: con 8r600;              # rw------- file

# Per-process shadow sequence counter.
# Combined with PID + millisec to avoid collisions between concurrent goroutines.
# Limbo has no atomic increment, but the ++ is on an int in a single goroutine
# context — callers that may race should coordinate externally.
shadowseq := 0;

# Thread-safe initialization
inited := 0;

init()
{
	if(inited)
		return;

	sys = load Sys Sys->PATH;
	inited = 1;
}

# Core primitive: restrict a directory to only allowed entries
# Creates a shadow dir with only the allowed items, then replaces target
restrictdir(target: string, allowed: list of string, writable: int): string
{
	if(sys == nil)
		init();

	# Create unique shadow dir using PID + sequence + millisec
	# The millisec component prevents collisions from concurrent goroutines
	pid := sys->pctl(0, nil);
	seq := shadowseq++;
	shadowdir := sys->sprint("%s/%d-%d-%d", SHADOW_BASE, pid, seq, sys->millisec());
	err := mkdirp(shadowdir);
	if(err != nil)
		return err;

	for(a := allowed; a != nil; a = tl a) {
		item := hd a;
		# Avoid double-slash when target is "/"
		srcpath: string;
		if(target == "/")
			srcpath = "/" + item;
		else
			srcpath = target + "/" + item;
		dstpath := shadowdir + "/" + item;

		if(target == "/") {
			# Root restriction: skip stat to avoid deadlock on 9P
			# self-mounts like /tool. All root entries are dirs.
			# Bind failures are non-fatal (item may not exist).
			dfd := sys->create(dstpath, Sys->OREAD, DIR_MODE);
			if(dfd != nil)
				dfd = nil;
			sys->bind(srcpath, dstpath, Sys->MREPL);
		} else {
			# Check if source exists and get type
			(ok, dir) := sys->stat(srcpath);
			if(ok < 0)
				continue;  # Skip items that don't exist in target

			# Create mount point matching source type
			if(dir.mode & Sys->DMDIR) {
				dfd := sys->create(dstpath, Sys->OREAD, DIR_MODE);
				if(dfd != nil)
					dfd = nil;
			} else {
				dfd := sys->create(dstpath, Sys->OWRITE, FILE_MODE);
				if(dfd != nil)
					dfd = nil;
			}

			# Bind original into shadow.
			# When the outer target is writable, inner binds also need MCREATE
			# so that file creation inside subdirectories is permitted.
			# Without MCREATE on the inner bind, the kernel returns
			# "mounted directory forbids creation" for any create inside that subdir.
			innerbindflags := Sys->MREPL;
			if(writable)
				innerbindflags |= Sys->MCREATE;
			if(sys->bind(srcpath, dstpath, innerbindflags) < 0)
				return sys->sprint("cannot bind %s: %r", srcpath);
		}
	}

	# Replace target with shadow — only allowed items visible.
	# MCREATE allows file creation at the mount point (needed for /tmp).
	bindflags := Sys->MREPL;
	if(writable)
		bindflags |= Sys->MCREATE;
	if(sys->bind(shadowdir, target, bindflags) < 0)
		return sys->sprint("cannot replace %s: %r", target);

	return nil;
}

# Apply full namespace restriction policy
restrictns(caps: ref Capabilities): string
{
	if(sys == nil)
		init();

	err := validatepaths(caps.paths, "path");
	if(err != nil)
		return err;
	err = validatepaths(caps.writepaths, "write path");
	if(err != nil)
		return err;

	# Set up infrastructure directories first (before any restrictdir calls).
	# These must exist because: (1) restrictdir creates shadow dirs under
	# SHADOW_BASE, and (2) after bind-replace on /tmp, the MREPL mount
	# lacks MCREATE — new subdirectories cannot be created at the mount point.
	# Pre-creating them here ensures they exist as real subdirectories.
	mkdirp("/tmp/veltro");
	mkdirp("/tmp/veltro/scratch");
	mkdirp("/tmp/veltro/memory");
	mkdirp("/tmp/veltro/cow");
	mkdirp("/tmp/veltro/plans");
	mkdirp("/tmp/veltro/tasks");
	mkdirp("/tmp/.veltro-ns");
	mkdirp(SHADOW_BASE);
	mkdirp(AUDIT_DIR);

	# 1. Restrict /dis to: lib/, veltro/ (plus shell+cmd if exec tool is loaded,
	#    plus any /dis/ subdirectories granted via caps.paths e.g. "/dis/wm")
	disallow := "lib" :: "veltro" :: nil;
	if(inlist("exec", caps.tools) || caps.shellcmds != nil) {
		# exec tool needs sh.dis (shell interpreter) to run commands
		disallow = "sh.dis" :: disallow;
		for(c := caps.shellcmds; c != nil; c = tl c)
			disallow = (hd c) + ".dis" :: disallow;
	}
	# Expose /dis/ subdirectories listed in caps.paths (e.g. "/dis/wm" → "wm")
	for(dp := filterpaths(caps.paths, "/dis/"); dp != nil; dp = tl dp) {
		(first, nil) := splitfirst(hd dp);
		if(first != "" && !inlist(first, disallow))
			disallow = first :: disallow;
	}
	err = restrictdir("/dis", disallow, 0);
	if(err != nil)
		return sys->sprint("restrict /dis: %s", err);

	# 2. If tools specified, restrict /dis/veltro/tools/ to granted tools only
	if(caps.tools != nil) {
		toolallow: list of string;
		for(t := caps.tools; t != nil; t = tl t)
			toolallow = (hd t) + ".dis" :: toolallow;
		err = restrictdir("/dis/veltro/tools", toolallow, 0);
		if(err != nil)
			return sys->sprint("restrict /dis/veltro/tools: %s", err);
	}

	# 3. Restrict /dev to: cons, null, time
	# time is read-only clock; required by daytime->now() for TLS cert validation.
	err = restrictdir("/dev", "cons" :: "null" :: "time" :: nil, 0);
	if(err != nil)
		return sys->sprint("restrict /dev: %s", err);

	# 4-5. Restrict /n to explicitly granted entries only.
	# /n is the IMPORT YARD — foreign trees imported intact (docs/NAMESPACE-LAYOUT.md).
	# All /n/ entries are capability-driven — never auto-exposed by existence:
	#   /n/speech — "/n/speech" in caps.paths
	#   /n/git    — "/n/git" in caps.paths
	#   /n/wallet — "/n/wallet" in caps.paths
	#   /n/pres-* — caps.xenith != 0
	#   /n/local  — /n/local/ subpaths in caps.paths
	# NB: the LLM (llm9p) and the UI presentation surface (luciuisrv) are no longer
	# /n entries — their schemas are ours, so they live at /mnt/llm and /mnt/ui
	# (docs/NAMESPACE-LAYOUT.md, INFR-254). Both are handled by the uniform /mnt
	# machinery (step 5b). /n no longer special-cases the agent's services — it
	# collapses to genuine foreign imports.
	(nok, nil) := sys->stat("/n");
	if(nok >= 0) {
		nallow: list of string;

		# MCP providers (mc9p, mcp9p adapters) and the LLM (llm9p) mount under
		# /mnt — they synthesize their own schema (docs/NAMESPACE-LAYOUT.md). All
		# /mnt grants are handled in step 5b below, not here.

		# /n/speech — only if explicitly granted via caps.paths
		if(inlist("/n/speech", caps.paths)) {
			(speechok, nil) := sys->stat("/n/speech");
			if(speechok >= 0)
				nallow = "speech" :: nallow;
		}

		# /n/git — only if explicitly granted via caps.paths
		if(inlist("/n/git", caps.paths)) {
			(gitok, nil) := sys->stat("/n/git");
			if(gitok >= 0)
				nallow = "git" :: nallow;
		}

		# /n/wallet — only if explicitly granted via caps.paths
		if(inlist("/n/wallet", caps.paths)) {
			(walletok, nil) := sys->stat("/n/wallet");
			if(walletok >= 0)
				nallow = "wallet" :: nallow;
		}

		# (The UI presentation surface moved to /mnt/ui — granted + sub-restricted
		# by the uniform /mnt machinery in step 5b, like /mnt/llm and /mnt/mcp.
		# It is no longer a /n entry. INFR-254.)

		# /n/pres-* — only if Xenith (GUI) access is granted
		if(caps.xenith) {
			(presok, nil) := sys->stat("/n/pres-clone");
			if(presok >= 0) {
				nallow = "pres-launch" :: nallow;
				nallow = "pres-keyboard" :: nallow;
				nallow = "pres-pointer" :: nallow;
				nallow = "pres-winname" :: nallow;
				nallow = "pres-clone" :: nallow;
			}
		}

		# /n/local — only if /n/local/ subpaths granted via caps.paths
		localpaths := filterpaths(caps.paths, "/n/local/");
		if(localpaths != nil)
			nallow = "local" :: nallow;

		err = restrictdir("/n", nallow, 0);
		if(err != nil)
			return sys->sprint("restrict /n: %s", err);

		if(inlist("/n/wallet", caps.paths)) {
			werr := restrictwallet();
			if(werr != nil)
				return sys->sprint("restrict /n/wallet: %s", werr);
		}

		# Drill down /n/local to only the granted paths
		if(localpaths != nil) {
			lerr := restrictlocal(localpaths);
			if(lerr != nil)
				return sys->sprint("restrict /n/local: %s", lerr);
		}
	}

	# 5b. Restrict /mnt to explicitly granted application mount points.
	keepmnt := 0;
	# /mnt holds trees WE synthesize (the schema is ours) — MCP adapters at
	# /mnt/mcp/<server>, webfs, etc. (docs/NAMESPACE-LAYOUT.md). Like /n, every
	# entry is capability-driven, never auto-exposed by existence. restrictpath
	# drills as deep as the caps specify, so a "/mnt/mcp/osm" grant exposes ONLY
	# that subtree (least privilege for the sub-agent MCP bridge, INFR-247);
	# caps.mcproviders (generic mc9p) grants the whole /mnt/mcp. "mnt" is added
	# to the root safe-list (step 8) only when something here is granted —
	# otherwise a confined agent sees no /mnt at all.
	# Every /mnt mount is capability-driven (least privilege): a child sees a
	# /mnt subtree ONLY when its capabilities name it. Nothing is granted merely
	# because the directory exists — otherwise a confined child would see /mnt
	# (and the model service under it) regardless of what it was granted.
	#
	# /mnt/llm is NOT granted here by existence. An agent that drives its own LLM
	# session opens it BY PATH after restriction, so it lists "/mnt/llm" in
	# caps.paths (repl does this for its loop) and it is picked up by filterpaths
	# above. A spawned sub-agent instead inherits a pre-opened session FD from its
	# parent (subagent.b llmaskfd) — an open FD survives namespace restriction —
	# so it needs no /mnt/llm mount and must not be handed the whole service tree.
	#
	# /mnt/msg (msg9p) is likewise caps-driven: a message task agent reads
	# /mnt/msg/status by path, so it is granted "/mnt/msg" explicitly via
	# caps.paths (the message policy adds paths=/mnt/msg).
	# SECURITY INVARIANT: changes here must keep the negative, positive, and
	# composition cases in tests/veltro_security_test.b in sync.
	mntpaths := filterpaths(caps.paths, "/mnt/");
	if(caps.mcproviders != nil && !inlist("mcp", mntpaths))
		mntpaths = "mcp" :: mntpaths;	# whole /mnt/mcp for generic mc9p
	# /mnt/ui — presentation surface (luciuisrv), granted only to fixed-function
	# UI tools. Per-invocation caps prevent unrelated tools from inheriting it.
	# Capability-gated exactly as before, now under /mnt. The grant exposes the
	# whole /mnt/ui; the subtree is then narrowed below (activity/ always; ctl if
	# the task tool is granted), preserving the old /mnt/ui least-privilege.
	uimnt := 0;
	if(needsui(caps.tools)) {
		(uimntok, nil) := sys->stat("/mnt/ui");
		if(uimntok >= 0 && !inlist("ui", mntpaths)) {
			mntpaths = "ui" :: mntpaths;
			uimnt = 1;
		}
	}
	# /mnt/factotum — the credential agent. A fixed-function tool can receive it
	# only when the same agent cannot execute arbitrary code. Otherwise exec or
	# shell could query unrelated credentials stored in the shared factotum.
	# Mixed grants fail closed: websearch reports its key unavailable. A future
	# per-credential broker may safely remove this incompatibility (INFR-363).
	if((inlist("git", caps.tools) || inlist("websearch", caps.tools) ||
	    inlist("vision", caps.tools)) &&
	   !inlist("exec", caps.tools) && !inlist("shell", caps.tools)) {
		(facok, nil) := sys->stat("/mnt/factotum");
		if(facok >= 0 && !inlist("factotum", mntpaths))
			mntpaths = "factotum" :: mntpaths;
	}
	if(mntpaths != nil) {
		(mntok, nil) := sys->stat("/mnt");
		if(mntok >= 0) {
			err = restrictpath("/mnt", mntpaths);
			if(err != nil)
				return sys->sprint("restrict /mnt: %s", err);
			keepmnt = 1;
			# /mnt/ui sub-restriction: activity/ always; ctl only if task granted.
			if(uimnt) {
				uiallow := "activity" :: nil;
				if(inlist("task", caps.tools))
					uiallow = "ctl" :: uiallow;
				uerr := restrictdir("/mnt/ui", uiallow, 0);
				if(uerr != nil)
					return sys->sprint("restrict /mnt/ui: %s", uerr);
			}
			# /mnt/msg sub-restriction: granting "/mnt/msg" exposes only the READ
			# surface (status — the inbox). The proposal endpoint (draft), trusted
			# control file (ctl), and flag endpoint are NEVER exposed by the bare
			# grant; they are separate capabilities named explicitly in caps.paths.
			# A draft is inert until trusted code consumes it through approve.
			if(inlist("msg", mntpaths)) {
				msgallow := "status" :: nil;
				msgwrite := 0;
				if(inlist("/mnt/msg/draft", caps.paths)) {
					msgallow = "draft" :: msgallow;
					msgwrite = 1;	# proposal endpoint must be writable
				}
				if(inlist("/mnt/msg/flag", caps.paths)) {
					msgallow = "flag" :: msgallow;
					msgwrite = 1;
				}
				merr := restrictdir("/mnt/msg", msgallow, msgwrite);
				if(merr != nil)
					return sys->sprint("restrict /mnt/msg: %s", merr);
			}
		}
	}

	# Defense-in-depth: drop caller-named MCP tool basenames from every granted
	# /mnt/mcp/<server>/tools listing, so the tool dir (and its /call path) is
	# invisible to the child's mcpdiscover regardless of which servers were
	# granted. The names are caller policy; nsconstruct never interprets them.
	if(caps.mcpdeny != nil) {
		derr := denymcptools(caps.mcpdeny);
		if(derr != nil)
			return sys->sprint("deny mcp tools: %s", derr);
	}

	# 6. Restrict /lib to: veltro/, certs/
	# certs/ is the TLS root CA store; required by x509->verify_certchain().
	(libok, nil) := sys->stat("/lib");
	if(libok >= 0) {
		err = restrictdir("/lib", "veltro" :: "certs" :: nil, 0);
		if(err != nil)
			return sys->sprint("restrict /lib: %s", err);
		# Legacy setup instructions stored API keys here. Keep the application
		# tree but replace its credential directory with an empty namespace.
		(keyok, nil) := sys->stat("/lib/veltro/keys");
		if(keyok >= 0) {
			err = restrictdir("/lib/veltro/keys", nil, 0);
			if(err != nil)
				return sys->sprint("restrict /lib/veltro/keys: %s", err);
		}
	}

	# 7. Restrict /env to the one application-owned session pointer. Environment
	# groups are commonly inherited from the launching shell and may contain
	# credentials. Launchers pre-create VELTRO_SESSION before FORKNS so the bind
	# captures the shared slot that plan/todo legitimately require.
	(envok, nil) := sys->stat("/env");
	if(envok >= 0) {
		err = restrictdir("/env", "VELTRO_SESSION" :: nil, 0);
		if(err != nil)
			return sys->sprint("restrict /env: %s", err);
	}
	# 8. Restrict /prog to this process. The process device otherwise exposes
	# sibling namespaces, descriptors, status, stacks and writable control files.
	# Non-shell tools only need the current process. Inferno sh creates another
	# process and opens /prog/<child>/wait after restriction, so an explicit shell
	# capability temporarily retains full /prog.
	(progok, nil) := sys->stat("/prog");
	if(progok >= 0 && caps.shellcmds == nil) {
		progallow: list of string;
		# The exec wrapper supplies sh with a pre-opened wait FD. Its command
		# process therefore needs no /prog entry, including the wrapper's ctl.
		if(!inlist("exec", caps.tools)) {
			pid := sys->pctl(0, nil);
			progallow = string pid :: nil;
		}
		err = restrictdir("/prog", progallow, 0);
		if(err != nil)
			return sys->sprint("restrict /prog: %s", err);
	}

	# 9. Restrict / to only Inferno system directories.
	# The emu's -r. binds #U (project root) onto / with MAFTER,
	# exposing project files (.env, .git, appl/, emu/, ...).
	# restrictdir("/", safe) replaces the root union with a shadow
	# containing only safe entries. Channels are captured at bind time,
	# so kernel device bindings (#c→/dev, #p→/prog) are preserved
	# through the shadow binds.
	# Do not expose /fd. Tool workers retain the descriptors needed internally,
	# including the tools9p reply channel, but agent code must not enumerate or
	# reopen those inherited capabilities by descriptor number.
	safe := "dev" :: "dis" :: "env" ::
		"lib" :: "n" :: "prog" :: "tmp" :: "tool" :: nil;
	# Raw IP devices are a capability, not ambient process state. Only
	# fixed-function tools that dial directly receive them. In particular, an
	# exec/shell invocation remains networkless even when the same agent also
	# has a web tool available; tools9p passes only the invoked tool in caps.
	if(needsnet(caps.tools)) {
		safe = "net" :: safe;
		(netaltok, nil) := sys->stat("/net.alt");
		if(netaltok >= 0)
			safe = "net.alt" :: safe;
	}
	# /mnt — application mount points (MCP adapters etc.) — only if a /mnt subtree
	# was granted in step 5b; otherwise a confined agent gets no /mnt at all.
	if(keepmnt)
		safe = "mnt" :: safe;
	# Only include /chan (Xenith 9P filesystem) if explicitly granted.
	# /chan exposes ALL window contents — without this gate, any agent
	# could read every open Xenith window regardless of namespace restriction.
	if(caps.xenith)
		safe = "chan" :: safe;

	# Expose additional Inferno root-level directories from caps.paths.
	# e.g. "/appl/veltro" → add "appl" to safe, then restrict /appl to "veltro".
	# Paths under /dis/, /n/, /dev/, /lib/, /tmp/ are already handled above.
	extradirs: list of string;
	for(ep := caps.paths; ep != nil; ep = tl ep) {
		p := hd ep;
		if(len p < 2 || p[0] != '/')
			continue;
		(first, nil) := splitfirst(p[1:]);
		if(first == "")
			continue;
		# Skip top-level dirs already in safe or handled by steps 1–7
		if(inlist(first, safe) || first == "net" || first == "net.alt")
			continue;
		if(!inlist(first, extradirs))
			extradirs = first :: extradirs;
	}
	for(ed := extradirs; ed != nil; ed = tl ed)
		safe = (hd ed) :: safe;

	{
		err = restrictdir("/", safe, 0);
	} exception e {
	"*" =>
		return sys->sprint("restrictdir / exception: %s", e);
	}
	if(err != nil)
		return sys->sprint("restrict /: %s", err);

	# Restrict /tool itself so the confined agent sees a stable capability view
	# without the generic root control file. User/UI mutations happen through the
	# trusted /mnt/toolctl* alias outside the restricted root.
	(toolok, nil) := sys->stat("/tool");
	if(toolok >= 0) {
		toolallow := "tools" :: "help" :: "_registry" :: "paths" :: "budget" :: "activity" :: nil;
		if(inlist("task", caps.tools))
			toolallow = "provision" :: toolallow;
		for(tl2 := caps.tools; tl2 != nil; tl2 = tl tl2)
			if(!inlist(hd tl2, toolallow))
				toolallow = hd tl2 :: toolallow;
		terr := restrictdir("/tool", toolallow, 0);
		if(terr != nil)
			return sys->sprint("restrict /tool: %s", terr);
	}

	# Restrict each extra root-level dir to only the granted sub-paths.
	# e.g. "/appl/veltro" → restrictpath("/appl", "veltro"::nil)
	# This prevents the agent from browsing sibling dirs (e.g. /appl/cmd).
	for(ed = extradirs; ed != nil; ed = tl ed) {
		topdir := "/" + hd ed;
		subpaths := filterpaths(caps.paths, topdir + "/");
		if(subpaths != nil) {
			ederr := restrictpath(topdir, subpaths);
			if(ederr != nil)
				return sys->sprint("restrict %s: %s", topdir, ederr);
		}
	}

	if(caps.actid >= 0 && caps.writepaths != nil) {
		werr := overlaywritepaths(caps.writepaths, caps.actid);
		if(werr != nil)
			return sys->sprint("overlay writes: %s", werr);
	}

	# Preserve the public scratch path while giving every activity disjoint
	# backing storage. A compromised task cannot read or overwrite another
	# activity's spilled tool results, drafts, or temporary files.
	workspaceid := caps.actid;
	if(workspaceid < 0)
		workspaceid = sys->pctl(0, nil);
	scratchdir := sys->sprint("/tmp/veltro/scratch/%d", workspaceid);
	err = mkdirp(scratchdir);
	if(err != nil)
		return sys->sprint("create activity scratch: %s", err);
	if(sys->bind(scratchdir, "/tmp/veltro/scratch", Sys->MREPL|Sys->MCREATE) < 0)
		return sys->sprint("isolate activity scratch: %r");

	# Task briefs contain untrusted message bodies and user instructions. They
	# are exchanged by trusted taskboard/lucibridge processes; ordinary tools
	# must not read another activity's prompt or model selection.
	if(!inlist("task", caps.tools)) {
		err = restrictdir("/tmp/veltro/tasks", nil, 0);
		if(err != nil)
			return sys->sprint("restrict task metadata: %s", err);
	}

	err = restrictdir("/tmp/veltro", tmpveltroallow(caps), 1);
	if(err != nil)
		return sys->sprint("restrict /tmp/veltro: %s", err);

	# 10. Restrict /tmp last. All bind-replace shadows and COW mounts must be
	# constructed first; their backing channels remain valid after the trusted
	# /tmp/.veltro-ns tree is hidden. Agents retain only their workspace.
	err = restrictdir("/tmp", "veltro" :: nil, 1);
	if(err != nil)
		return sys->sprint("restrict /tmp: %s", err);

	return nil;
}

tmpveltroallow(caps: ref Capabilities): list of string
{
	# .ns contains the namespace manifest consumed by Lucifer's context view.
	# It is application metadata, not authority: hiding it prevents tools9p's
	# post-restrict emitmanifest() from writing the live namespace description.
	allow := ".ns" :: "scratch" :: nil;

	for(p := filterpaths(caps.paths, "/tmp/veltro/"); p != nil; p = tl p) {
		(first, nil) := splitfirst(hd p);
		if(first != "" && !inlist(first, allow))
			allow = first :: allow;
	}

	if(inlist("task", caps.tools))
		allow = "tasks" :: allow;
	if(inlist("memory", caps.tools))
		allow = "memory" :: allow;
	if(inlist("plan", caps.tools))
		allow = "plans" :: allow;
	if(inlist("todo", caps.tools))
		allow = "todo.txt" :: allow;

	return allow;
}

# Filter paths that start with a given prefix, stripping the prefix.
# E.g., filterpaths(("/n/local/Users/pdfinn/tmp"::nil), "/n/local/")
# returns ("Users/pdfinn/tmp"::nil)
filterpaths(paths: list of string, prefix: string): list of string
{
	result: list of string;
	plen := len prefix;
	for(; paths != nil; paths = tl paths) {
		p := hd paths;
		if(len p > plen && p[0:plen] == prefix)
			result = p[plen:] :: result;
	}
	return result;
}

# Restrict /n/local to only the granted host paths.
# Each path is relative to /n/local/ (e.g., "Users/pdfinn/tmp").
# Drills down component by component using restrictdir().
restrictlocal(paths: list of string): string
{
	err := restrictpath("/n/local", paths);
	if(err != nil)
		return err;
	return nil;
}

restrictwallet(): string
{
	accts := walletaccounts();
	allow := "accounts" :: "default" :: nil;
	for(a := accts; a != nil; a = tl a)
		if(!inlist(hd a, allow))
			allow = hd a :: allow;

	err := restrictdir("/n/wallet", allow, 0);
	if(err != nil)
		return err;

	acctallow := "address" :: "balance" :: "chain" :: "sign" ::
		"pay" :: "history" :: nil;
	for(a = accts; a != nil; a = tl a) {
		err = restrictdir("/n/wallet/" + hd a, acctallow, 1);
		if(err != nil)
			return err;
	}
	return nil;
}

walletaccounts(): list of string
{
	fd := sys->open("/n/wallet/accounts", Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := string buf[:n];
	(nil, toks) := sys->tokenize(s, " \t\r\n");
	out: list of string;
	for(; toks != nil; toks = tl toks) {
		name := hd toks;
		if(safename(name) && !inlist(name, out))
			out = name :: out;
	}
	return out;
}

safename(s: string): int
{
	if(s == nil || s == "" || s == "." || s == "..")
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '/')
			return 0;
	return 1;
}

# Recursively restrict a directory to only the granted subpaths.
# paths are relative to dir (e.g., "pdfinn/tmp" relative to "/n/local/Users").
# At each level, extracts unique first components as the allowlist,
# then recurses for deeper components.
restrictpath(dir: string, paths: list of string): string
{
	# Pass 1: collect unique first components
	allow: list of string;
	for(p := paths; p != nil; p = tl p) {
		(first, nil) := splitfirst(hd p);
		if(!inlist(first, allow))
			allow = first :: allow;
	}

	# Restrict this level (read-only — /n/local paths are read-only by default)
	err := restrictdir(dir, allow, 0);
	if(err != nil)
		return err;

	# Pass 2: for each first component, collect subpaths and recurse
	for(a := allow; a != nil; a = tl a) {
		name := hd a;
		subpaths: list of string;
		for(q := paths; q != nil; q = tl q) {
			(first, rest) := splitfirst(hd q);
			if(first == name && rest != "")
				subpaths = rest :: subpaths;
		}
		if(subpaths != nil) {
			serr := restrictpath(dir + "/" + name, subpaths);
			if(serr != nil)
				return serr;
		}
	}

	return nil;
}

# Check if string is in a list
inlist(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

denymcptools(deny: list of string): string
{
	fd := sys->open("/mnt/mcp", Sys->OREAD);
	if(fd == nil)
		return nil;	# no MCP servers mounted — nothing to deny
	# Collect server names first; we re-bind tools/ dirs below and shouldn't
	# hold a read fd on the parent across those binds.
	servers: list of string;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if(dirs[i].mode & Sys->DMDIR)
				servers = dirs[i].name :: servers;
	}
	fd = nil;
	for(sl := servers; sl != nil; sl = tl sl) {
		err := restrictmcptools("/mnt/mcp/" + hd sl + "/tools", deny);
		if(err != nil)
			return err;
	}
	return nil;
}

restrictmcptools(toolsdir: string, deny: list of string): string
{
	fd := sys->open(toolsdir, Sys->OREAD);
	if(fd == nil)
		return nil;	# server exposes no tools/ — nothing to do
	allow: list of string;
	denied := 0;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := dirs[i].name;
			if(inlist(name, deny))
				denied++;
			else
				allow = name :: allow;
		}
	}
	fd = nil;
	if(denied == 0)
		return nil;	# nothing denied here — leave tools/ as-is
	return restrictdir(toolsdir, allow, 0);
}

needsnet(tools: list of string): int
{
	networktools := "browse" :: "git" :: "http" :: "payfetch" ::
		"vision" :: "webfetch" :: "websearch" :: nil;
	for(; tools != nil; tools = tl tools)
		if(inlist(hd tools, networktools))
			return 1;
	return 0;
}

needsui(tools: list of string): int
{
	uitools := "gap" :: "keyring" :: "launch" :: "present" ::
		"spawn" :: "task" :: nil;
	for(; tools != nil; tools = tl tools)
		if(inlist(hd tools, uitools))
			return 1;
	return 0;
}

# Split a path into first component and rest.
# "Users/pdfinn/tmp" → ("Users", "pdfinn/tmp")
# "tmp" → ("tmp", "")
splitfirst(p: string): (string, string)
{
	for(i := 0; i < len p; i++) {
		if(p[i] == '/')
			return (p[0:i], p[i+1:]);
	}
	return (p, "");
}

pathwithin(grant, want: string): int
{
	if(grant == want)
		return 1;
	if(len want > len grant && want[0:len grant] == grant && want[len grant] == '/')
		return 1;
	return 0;
}

validatepaths(paths: list of string, what: string): string
{
	for(; paths != nil; paths = tl paths) {
		p := hd paths;
		err := validatepath(p);
		if(err != nil)
			return sys->sprint("invalid %s %s: %s", what, p, err);
		if(!grantpathallowed(p))
			return sys->sprint("invalid %s %s: privileged path not grantable", what, p);
	}
	return nil;
}

validatepath(p: string): string
{
	if(p == nil || len p == 0)
		return "empty path";
	if(p[0] != '/')
		return "path must be absolute";
	if(p == "/")
		return "root path is not grantable";
	for(ci := 0; ci < len p; ci++)
		if(p[ci] == ' ' || p[ci] == '\n' || p[ci] == '\r' || p[ci] == '\t' || p[ci] == ',')
			return "path contains control delimiter";

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

grantpathallowed(path: string): int
{
	if(privilegedcontrolpath(path))
		return 0;
	if(directmailsendpath(path))
		return 0;
	return 1;
}

privilegedcontrolpath(path: string): int
{
	dangerous := array[] of {
		"/tool/ctl",
		"/mnt/toolctl",
		"/mnt/toolctl/ctl",
		"/mnt/ui/ctl",
		"/mnt/msg/ctl",
		"/mnt/msg/pending",
		"/mnt/msg/approve",
		"/mnt/msg/deny",
		"/n/wallet/ctl",
		"/n/wallet/pending",
		"/n/wallet/new",
	};
	for(i := 0; i < len dangerous; i++)
		if(path == dangerous[i])
			return 1;
	if(walletaccountcontrolpath(path))
		return 1;
	if(ftreecontrolpath(path))
		return 1;
	if(tmpveltrointernalpath(path))
		return 1;
	return 0;
}

walletaccountcontrolpath(path: string): int
{
	if(!prefix(path, "/n/wallet/"))
		return 0;
	return componentcount(path) == 4 && pathhascomponent(path, "ctl");
}

ftreecontrolpath(path: string): int
{
	# ftree is a trusted user namespace browser. Its ctl file can bind and
	# unmount in the user's GUI namespace, so it is never an agent grant.
	return path == "/tmp/veltro/ftree" || prefix(path, "/tmp/veltro/ftree/");
}

tmpveltrointernalpath(path: string): int
{
	# Internal Veltro state roots are managed by trusted code. Exposing them as
	# path grants lets an agent spoof manifests, tamper with COW overlays, or
	# read/write task briefs outside the task tool's mediation.
	return path == "/tmp/veltro/.ns" || prefix(path, "/tmp/veltro/.ns/") ||
		path == "/tmp/veltro/cow" || prefix(path, "/tmp/veltro/cow/") ||
		path == "/tmp/veltro/tasks" || prefix(path, "/tmp/veltro/tasks/");
}

directmailsendpath(path: string): int
{
	if(path == "/mnt/mail")
		return 1;
	if(prefix(path, "/mnt/mail/")) {
		if(pathhascomponent(path, "compose") || pathhascomponent(path, "draft-reply"))
			return 1;
		if(mailaccountancestor(path))
			return 1;
	}
	return 0;
}

mailaccountancestor(path: string): int
{
	# /mnt/mail/accounts/<acct> exposes compose.
	if(prefix(path, "/mnt/mail/accounts/") && componentcount(path) <= 4)
		return 1;
	# /mnt/mail/accounts/<acct>/boxes/<box>/<uid> exposes draft-reply.
	if(prefix(path, "/mnt/mail/accounts/") && pathhascomponent(path, "boxes") &&
	   componentcount(path) <= 7)
		return 1;
	return 0;
}

prefix(s, p: string): int
{
	if(len s < len p)
		return 0;
	return s[0:len p] == p;
}

pathhascomponent(path, want: string): int
{
	i := 0;
	n := len path;
	while(i < n) {
		while(i < n && path[i] == '/')
			i++;
		j := i;
		while(j < n && path[j] != '/')
			j++;
		if(j > i && path[i:j] == want)
			return 1;
		i = j;
	}
	return 0;
}

componentcount(path: string): int
{
	nc := 0;
	i := 0;
	n := len path;
	while(i < n) {
		while(i < n && path[i] == '/')
			i++;
		if(i >= n)
			break;
		nc++;
		while(i < n && path[i] != '/')
			i++;
	}
	return nc;
}

overlaywritepaths(paths: list of string, actid: int): string
{
	cowfs := load Cowfs Cowfs->PATH;
	if(cowfs == nil)
		return sys->sprint("cannot load cowfs: %r");

	seq := 0;
	for(p := paths; p != nil; p = tl p) {
		fullpath := hd p;
		(ok, nil) := sys->stat(fullpath);
		if(ok < 0)
			continue;
		overlaydir := sys->sprint("/tmp/veltro/cow/%d-%d", actid, seq);
		seq++;
		merr := mkdirp(overlaydir);
		if(merr != nil)
			return sys->sprint("cowfs overlay %s: %s", overlaydir, merr);

		(mntfd, cerr) := cowfs->start(fullpath, overlaydir);
		if(cerr != nil)
			return sys->sprint("cowfs %s: %s", fullpath, cerr);

		# MCREATE here is safe in a way it is NOT for the plain MREPL
		# binds above (which restrict MCREATE to /tmp): every mutation
		# through a cowfs mount — create, write/copy-up, remove/whiteout —
		# lands in the per-agent ephemeral overlay (overlaydir), never the
		# real base. These are exactly caps.writepaths (write already
		# granted), so creation of new files is intended; cowfs confines
		# it to the overlay and validates create names (safename) so it
		# cannot escape. Without MCREATE the granted overlay would be
		# silently create-only-via-modify, breaking legitimate new-file
		# writes the agent is entitled to.
		if(sys->mount(mntfd, nil, fullpath, Sys->MREPL|Sys->MCREATE, nil) < 0)
			return sys->sprint("cowfs mount %s: %r", fullpath);
	}
	return nil;
}

# Emit namespace manifest for the UI to display.
# Writes to /tmp/veltro/.ns/manifest — one entry per line:
#   path=/dev/time label=System Clock perm=ro
# Must be called AFTER restrictns() from the restricted namespace
# so stat checks reflect exactly what the agent can access.
emitmanifest(caps: ref Capabilities, mpath: string)
{
	if(sys == nil)
		init();

	mkdirp("/tmp/veltro/.ns");

	fd := sys->create(mpath, Sys->OWRITE, FILE_MODE);
	if(fd == nil)
		return;

	# Infrastructure paths — always checked
	infra := array[] of {
		# (path, label, default-perm)
		("/dev/time",      "System Clock",     "ro"),
		("/dev/cons",      "Console",          "rw"),
		("/dev/null",      "Null Device",      "rw"),
		("/lib/certs",     "Certificates",     "ro"),
		("/lib/veltro",    "Veltro Config",    "ro"),
		("/dis/veltro",    "Veltro Tools",     "ro"),
		("/tmp/veltro",    "Veltro Workspace", "rw"),
	};

	for(i := 0; i < len infra; i++) {
		(path, label, perm) := infra[i];
		(ok, nil) := sys->stat(path);
		if(ok >= 0)
			sys->fprint(fd, "path=%s label=%s perm=%s\n", path, label, perm);
	}

	# /n entries — capability-driven (import yard)
	nentries := array[] of {
		("/n/speech", "Speech",           "rw"),
		("/n/git",    "Git",              "rw"),
		# The LLM (llm9p), UI surface (luciuisrv) and MCP providers live under
		# /mnt now — application mount points, schema is ours, not /n imports
		# (docs/NAMESPACE-LAYOUT.md).
		("/mnt/llm",  "LLM Service",      "rw"),
		("/mnt/ui",   "UI Service",       "rw"),
		("/mnt/mcp",  "MCP Providers",    "rw"),
	};

	for(i = 0; i < len nentries; i++) {
		(path, label, perm) := nentries[i];
		(ok, nil) := sys->stat(path);
		if(ok >= 0)
			sys->fprint(fd, "path=%s label=%s perm=%s\n", path, label, perm);
	}

	# /n/local subpaths from caps.paths
	localpaths := filterpaths(caps.paths, "/n/local/");
	for(lp := localpaths; lp != nil; lp = tl lp) {
		fullpath := "/n/local/" + hd lp;
		(ok, nil) := sys->stat(fullpath);
		perm := "ro";
		for(wp := caps.writepaths; wp != nil; wp = tl wp)
			if(pathwithin(hd wp, fullpath))
				perm = "cow";
		if(caps.actid < 0)
			perm = "ro";
		if(ok >= 0)
			sys->fprint(fd, "path=%s label=%s perm=%s\n", fullpath, hd lp, perm);
	}

	# Xenith-related entries
	if(caps.xenith) {
		xpaths := array[] of {
			("/chan",          "Xenith Windows",  "rw"),
		};
		for(i = 0; i < len xpaths; i++) {
			(path, label, perm) := xpaths[i];
			(ok, nil) := sys->stat(path);
			if(ok >= 0)
				sys->fprint(fd, "path=%s label=%s perm=%s\n", path, label, perm);
		}
	}

	# Extra dirs from caps.paths (e.g. /dis/wm, /appl/veltro).
	# These are explicitly granted namespace paths — they MUST appear
	# in the manifest so the Resource view reflects the actual namespace.
	# Skip paths already handled above.
	emitted: list of string;
	for(ii := 0; ii < len infra; ii++) {
		(ip, nil, nil) := infra[ii];
		emitted = ip :: emitted;
	}
	for(ii = 0; ii < len nentries; ii++) {
		(np, nil, nil) := nentries[ii];
		emitted = np :: emitted;
	}
	for(ep := caps.paths; ep != nil; ep = tl ep) {
		p := hd ep;
		if(len p < 2 || p[0] != '/')
			continue;
		# Skip /n/local subpaths (handled above with cow logic)
		if(len p > 9 && p[0:9] == "/n/local/")
			continue;
		if(inlist(p, emitted))
			continue;
		(ok, nil) := sys->stat(p);
		perm := "ro";
		for(wp2 := caps.writepaths; wp2 != nil; wp2 = tl wp2)
			if(pathwithin(hd wp2, p))
				perm = "cow";
		if(caps.actid < 0)
			perm = "ro";
		if(ok >= 0)
			sys->fprint(fd, "path=%s label=%s perm=%s\n", p, p[1:], perm);
	}

	fd = nil;
}

# Verify namespace matches expected security policy
# Checks both positive (expected paths accessible) and negative
# (dangerous paths inaccessible) assertions.
verifyns(expected: list of string): string
{
	if(sys == nil)
		init();

	# Note: We do NOT grep /prog/$pid/ns (the mount table) for path
	# strings like "/n/local" or "#U". After bind-replace, the mount
	# table retains historical entries masked by later MREPL binds.
	# For example, "bind '#U*' /n/local" persists even though
	# restrictdir("/n", ...) hides /n/local. The stat() checks below
	# are the only reliable accessibility test after bind-replace.

	# Negative assertions: verify dangerous paths are NOT accessible
	dangerous := array[] of {
		"/n/local",
		"/.env",
		"/.git",
		"/CLAUDE.md",
		"/tool/ctl",
		"/mnt/toolctl",
		"/mnt/toolctl/ctl",
		"/mnt/msg/ctl",
		"/mnt/msg/pending",
		"/mnt/msg/approve",
		"/mnt/msg/deny",
		"/n/wallet/ctl",
		"/n/wallet/pending",
		"/n/wallet/new",
	};
	for(i := 0; i < len dangerous; i++) {
		(dok, nil) := sys->stat(dangerous[i]);
		if(dok >= 0)
			return sys->sprint("violation: %s still accessible", dangerous[i]);
	}

	# Positive assertions: verify expected paths are accessible
	for(e := expected; e != nil; e = tl e) {
		path := hd e;
		(ok, nil) := sys->stat(path);
		if(ok < 0)
			return sys->sprint("expected path missing: %s", path);
	}

	return nil;
}

# Emit audit log of namespace restriction operations
emitauditlog(id: string, ops: list of string)
{
	if(sys == nil)
		init();

	mkdirp(AUDIT_DIR);

	auditpath := AUDIT_DIR + "/" + id + ".ns";
	fd := sys->create(auditpath, Sys->OWRITE, FILE_MODE);
	if(fd == nil)
		return;

	sys->fprint(fd, "# Veltro Namespace Audit (v3)\n# ID: %s\n\n", id);

	# Write operations in reverse order (oldest first)
	revops: list of string;
	for(; ops != nil; ops = tl ops)
		revops = hd ops :: revops;
	for(; revops != nil; revops = tl revops)
		sys->fprint(fd, "%s\n", hd revops);

	# Dump current namespace state
	pid := sys->pctl(0, nil);
	nscontent := readfile(sys->sprint("/prog/%d/ns", pid));
	if(nscontent != "")
		sys->fprint(fd, "\n# Current namespace:\n%s", nscontent);

	fd = nil;
}

# Helper: create directory with parents
mkdirp(path: string): string
{
	if(sys == nil)
		init();

	# Check if already exists
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return nil;

	# Create parent directories first
	err := mkparent(path);
	if(err != nil)
		return err;

	fd := sys->create(path, Sys->OREAD, DIR_MODE);
	if(fd == nil) {
		# TOCTOU race: a concurrent restrictns (e.g. a tool-call asyncexec
		# overlapping a child tools9p's emitmanifest, both spawned by
		# back-to-back `task` calls) may have created this shared ancestor
		# between our stat() above and this create(). Directory creation is
		# idempotent: if it now exists as a directory, that is success.
		# Without this, the loser of the race returned "cannot create … file
		# exists", which surfaced to the agent as "namespace restriction
		# failed" and dropped a delegated task (more likely with models that
		# batch multiple task tool-calls in one turn).
		(ok2, d2) := sys->stat(path);
		if(ok2 >= 0 && (d2.mode & Sys->DMDIR))
			return nil;
		return sys->sprint("cannot create %s: %r", path);
	}
	fd = nil;
	return nil;
}

# Helper: create parent directory
mkparent(path: string): string
{
	parent := "";
	for(i := len path - 1; i > 0; i--) {
		if(path[i] == '/') {
			parent = path[0:i];
			break;
		}
	}

	if(parent == "" || parent == "/")
		return nil;

	return mkdirp(parent);
}

# Helper: read file contents
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

# Clean up shadow directories for the current process
cleanup()
{
	if(sys == nil)
		init();

	pid := sys->pctl(0, nil);
	prefix := sys->sprint("%d-", pid);

	fd := sys->open(SHADOW_BASE, Sys->OREAD);
	if(fd == nil)
		return;

	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := dirs[i].name;
			if(len name >= len prefix && name[0:len prefix] == prefix) {
				# Remove shadow directory contents then directory itself
				rmdir(SHADOW_BASE + "/" + name);
			}
		}
	}
}

# Helper: recursively remove a directory and its contents
rmdir(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil) {
		for(;;) {
			(n, dirs) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++) {
				child := path + "/" + dirs[i].name;
				if(dirs[i].mode & Sys->DMDIR)
					rmdir(child);
				else
					sys->remove(child);
			}
		}
		fd = nil;
	}
	sys->remove(path);
}

# Helper: check if string contains substring
contains(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++) {
		if(s[i:i+len sub] == sub)
			return 1;
	}
	return 0;
}

implement Llmctl9p;

#
# llmctl9p - In-emu synthetic FS for the LLM backend switcher.
#
# Serves two files:
#   /llm/ctl     (rw)  write "set ollama" / "set sglang" / "set none"
#   /llm/status  (r)   read current backend / health / ndb_url
#
# Both files are thin shells over the host `llmctl` bash tool (which
# owns the actual systemctl + curl + ndb work). The Limbo side does:
#
#   • Validate verbs on writes — reject anything not in the allowed
#     set without crossing to the host.
#   • Call `os <hostpath> <verb>` via Sh->system. The host call is
#     synchronous; a `set sglang` write can take ~60s while flashinfer
#     JIT-compiles. Callers should spawn the write off any UI thread.
#   • Re-run `os <hostpath> status` on every /status read. Cheap.
#
# Usage:
#   llmctl9p [-b /path/to/host/llmctl]
#
# By default the daemon assumes `llmctl` is on the host's PATH. Pass
# -b to override (recommended on Hephaestus where the binary lives in
# the repo checkout rather than /usr/local/bin).
#
# Mount with:
#   mount {llmctl9p -b /home/pdfinn/github.com/infernode-os/infernode/llmctl} /llm
#
# Cross-ref: tracked under INFR-79; the host bash tool lives at the
# repo root (PR #88).
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
	Styxserver, Navigator: import styxservers;
	Eperm, Ebadarg, Enotfound: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

include "sh.m";
	sh: Sh;

Llmctl9p: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

# Qid path numbers — small integers per the nametree convention.
Qdir, Qctl, Qstatus: con iota;

# Default host binary name. Overridable with -b. When the binary is
# on the host PATH (common on field deploys), the default works.
hostbin := "llmctl";

stderr: ref Sys->FD;
user := "inferno";

# Sh->system needs a Draw context for some commands; ours don't need
# graphics, so the saved context can be nil. We keep the variable so
# nothing in this file depends on a draw context at compile time.
ctxt_g: ref Draw->Context;

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	ctxt_g = ctxt;

	arg := load Arg Arg->PATH;
	if(arg == nil) {
		sys->fprint(stderr, "llmctl9p: cannot load %s: %r\n", Arg->PATH);
		raise "fail:load arg";
	}

	styx = load Styx Styx->PATH;
	if(styx == nil) {
		sys->fprint(stderr, "llmctl9p: cannot load %s: %r\n", Styx->PATH);
		raise "fail:load styx";
	}
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) {
		sys->fprint(stderr, "llmctl9p: cannot load %s: %r\n", Styxservers->PATH);
		raise "fail:load styxservers";
	}
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil) {
		sys->fprint(stderr, "llmctl9p: cannot load %s: %r\n", Nametree->PATH);
		raise "fail:load nametree";
	}
	sh = load Sh Sh->PATH;
	if(sh == nil) {
		sys->fprint(stderr, "llmctl9p: cannot load %s: %r\n", Sh->PATH);
		raise "fail:load sh";
	}

	arg->init(args);
	arg->setusage("llmctl9p [-b host-binary-path]");
	while((c := arg->opt()) != 0) {
		case c {
		'b' =>
			hostbin = arg->earg();
		* =>
			arg->usage();
		}
	}

	styx->init();
	styxservers->init(styx);
	nametree->init();

	(tree, treeop) := nametree->start();
	tree.create(big Qdir, dir(".",      Sys->DMDIR | 8r555, Qdir));
	tree.create(big Qdir, dir("ctl",    8r600,              Qctl));     # rw owner only
	tree.create(big Qdir, dir("status", 8r444,              Qstatus)); # r everyone

	(tc, srv) := Styxserver.new(sys->fildes(0),
	                            Navigator.new(treeop),
	                            big Qdir);

	serveloop(tc, srv, tree);
}

dir(name: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

# ── Verb validation ────────────────────────────────────────────
# Whitelist of accepted /ctl payloads. Anything else gets rejected
# with a clear error before we cross to the host — defence in depth
# against an accidentally-writable mount.
allowed_verbs := array[] of {
	"set ollama",
	"set sglang",
	"set none",
};

valid_verb(line: string): int
{
	for(i := 0; i < len allowed_verbs; i++)
		if(line == allowed_verbs[i])
			return 1;
	return 0;
}

# ── Host crossing ──────────────────────────────────────────────
# Runs `os <hostbin> <args>` through Sh->system and returns the
# combined stdout/stderr as a single string. Sh->system swallows the
# exit status; we'd need run() + a custom collector to surface it.
# For status reads that's fine (the host output is self-describing).
# For ctl writes we look for a leading "llmctl:" stderr line as the
# failure signal.

run_host(verb: string): string
{
	cmd := "os " + hostbin + " " + verb;
	return sh->system(ctxt_g, cmd);
}

# ── Serve loop ─────────────────────────────────────────────────

serveloop(tc: chan of ref Tmsg, srv: ref Styxserver, tree: ref Tree)
{
	while((tmsg := <-tc) != nil) {
		pick tm := tmsg {
		Readerror =>
			break;

		Flush =>
			srv.reply(ref Rmsg.Flush(tm.tag));

		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen) {
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			case int c.path {
			Qdir =>
				srv.read(tm);
			Qctl =>
				# /ctl is write-only by convention; return empty on read.
				srv.reply(styxservers->readstr(tm, ""));
			Qstatus =>
				srv.reply(styxservers->readstr(tm, run_host("status")));
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, "phase error -- bad path"));
			}

		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen) {
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			if(int c.path != Qctl) {
				srv.reply(ref Rmsg.Error(tm.tag, Eperm));
				continue;
			}
			line := stripnl(string tm.data);
			if(!valid_verb(line)) {
				srv.reply(ref Rmsg.Error(tm.tag,
					"llmctl9p: bad verb '" + line + "' (allowed: set ollama|sglang|none)"));
				continue;
			}
			# Synchronous host call. `set sglang` can take ~60s on a
			# cold start due to flashinfer JIT compile; the Styx Twrite
			# blocks for the duration. Clients should spawn writes off
			# any UI thread.
			out := run_host(line);
			# llmctl reports failures via "llmctl:" stderr lines and a
			# non-zero exit. Sh->system doesn't surface the exit, so we
			# pattern-match the stderr prefix as a best-effort signal.
			if(failure_in(out)) {
				srv.reply(ref Rmsg.Error(tm.tag, "llmctl9p: " + firstline(out)));
				continue;
			}
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));

		Clunk =>
			srv.clunk(tm);

		* =>
			srv.default(tmsg);
		}
	}
	tree.quit();
}

# ── helpers ────────────────────────────────────────────────────

stripnl(s: string): string
{
	# Strip a single trailing newline if present. Clients typically
	# write "set sglang\n".
	if(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

firstline(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			return s[0:i];
	return s;
}

# Failure signal: llmctl prints messages like
#   "llmctl: sglang failed to become healthy within 90s"
# to stderr and exits non-zero. Sh->system merges stderr with stdout
# but doesn't propagate the exit status, so we look for a "llmctl: "
# prefix on the first non-empty line that doesn't match the success
# shape ("llmctl: sglang active; ndb url=...").

failure_in(s: string): int
{
	for(i := 0; i < len s; i++) {
		if(s[i] == '\n')
			continue;
		# First non-newline run found; check the first line.
		line := firstline(s[i:]);
		# Success messages contain " active" or "already active" or
		# "stopped both"; anything else from llmctl: is a failure.
		if(has(line, "llmctl: ")) {
			if(has(line, "active") || has(line, "stopped both"))
				return 0;
			return 1;
		}
		break;
	}
	return 0;
}

has(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i + len sub] == sub)
			return 1;
	return 0;
}

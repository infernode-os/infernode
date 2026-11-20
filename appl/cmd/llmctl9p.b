implement Llmctl9p;

#
# llmctl9p - In-emu synthetic FS for the LLM backend switcher.
#
# Serves two files:
#   /llm/ctl     (rw)  write "set ollama" / "set sglang" / "set claude" /
#                      "set codex" / "set none"
#   /llm/status  (r)   read current backend / health / ndb_url
#
# Both files are meant as thin shells over the host `llmctl` bash tool
# (which owns the actual systemctl + curl + ndb work).  The crossing to
# the host is switched off: a write of a verb is checked against the
# list and then refused, saying to run llmctl on the host, and a read
# of status says the same.  The code that made the crossing is not kept
# here (it had no caller).  When it is brought back: it must not run in
# the serving loop (a `set sglang` can take a minute, and every other
# request waited behind it), the helper must check its dups and close
# its end of the pipe on every way out, and whether llmctl failed is its
# exit status, not a word looked for in what it printed ("inactive" was
# read as "active").
#
# Usage:
#   llmctl9p [-b /path/to/host/llmctl]
#
# By default the daemon assumes `llmctl` is on the host's PATH. Pass
# -b to override (e.g. when the binary lives in a repo checkout
# rather than /usr/local/bin).
#
# Mount with:
#   mount {llmctl9p -b /path/to/llmctl} /llm
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

Llmctl9p: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

# Qid path numbers — small integers per the nametree convention.
Qdir, Qctl, Qstatus: con iota;

# Default host binary name. Overridable with -b. When the binary is
# on the host PATH (common on field deploys), the default works.
# (Not used while the crossing is off; the option is still taken.)
hostbin := "llmctl";

stderr: ref Sys->FD;
user := "inferno";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	# The files are their server's user's: ctl is mode 600, and with
	# the owner always "inferno" no other user could open their own.
	ufd := sys->open("/dev/user", Sys->OREAD);
	if(ufd != nil) {
		ubuf := array[Sys->NAMEMAX] of byte;
		un := sys->read(ufd, ubuf, len ubuf);
		if(un > 0)
			user = string ubuf[0:un];
	}

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
	"set claude",
	"set codex",
	"set none",
};

valid_verb(line: string): int
{
	for(i := 0; i < len allowed_verbs; i++)
		if(line == allowed_verbs[i])
			return 1;
	return 0;
}

# The verbs, as an error names them: "set ollama|sglang|...".
verbs(): string
{
	r := "";
	for(i := 0; i < len allowed_verbs; i++) {
		if(r != "")
			r += "|";
		r += allowed_verbs[i][len "set ":];
	}
	return "set " + r;
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
			# as the fid was opened: canread and canwrite ask the
			# mode, where "is it open" let a fid opened to read write
			(c, rerr) := srv.canread(tm);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(tm.tag, rerr));
				continue;
			}
			case int c.path {
			Qdir =>
				srv.read(tm);
			Qctl =>
				# /ctl is write-only by convention; return empty on read.
				srv.reply(styxservers->readstr(tm, ""));
			Qstatus =>
				# The host crossing is off (see the head of the file):
				# status reads as a line saying so, which its readers
				# show, and the host's `llmctl status` is the way.
				srv.reply(styxservers->readstr(tm,
					"llmctl9p: host-crossing read disabled — run `llmctl status` on the host directly\n"))
;
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, "phase error -- bad path"));
			}

		Write =>
			(c, werr) := srv.canwrite(tm);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(tm.tag, werr));
				continue;
			}
			if(int c.path != Qctl) {
				srv.reply(ref Rmsg.Error(tm.tag, Eperm));
				continue;
			}
			line := stripnl(string tm.data);
			if(!valid_verb(line)) {
				# the list as it is (it named three of the five), and
				# not the writer's text back at it
				srv.reply(ref Rmsg.Error(tm.tag,
					"llmctl9p: bad verb (allowed: " + verbs() + ")"));
				continue;
			}
			# The host crossing is off: a good verb is refused too,
			# with what to do instead, so that a caller does not take
			# it that the backend was switched.
			srv.reply(ref Rmsg.Error(tm.tag,
				"llmctl9p: host-crossing write disabled — run `llmctl " + line + "` on the host directly"));
			continue;

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

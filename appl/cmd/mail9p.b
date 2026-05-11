implement Mail9p;

#
# mail9p - IMAP/JMAP as a 9P filesystem at /n/mail
#
# Plan-9-style Styx server exposing one or more mail accounts so an
# agent can triage, classify, archive, flag, and (separately) reply to
# mail using ordinary file operations. The namespace-composition model:
# binding the right paths is the capability. There is no permission
# system anywhere in this server — bind triage-only paths for a triage
# agent, bind compose for a reply-allowed agent, and so on.
#
# See INFR-8 for the design ticket and the full namespace shape.
#
# Filesystem layout (this scaffold implements the directories and ctl
# paths; per-message field files and SMTP send come in the next
# implementation pass):
#
#   /n/mail/
#       ctl                    write: connect <name> <server> [-m starttls]
#                              write: disconnect <name>
#                              write: sync <name>
#                              read:  (write-only; reads return empty)
#       accounts/
#           <name>/
#               ctl            read:  status line (connected|disconnected,
#                                     server, mailbox if selected)
#                              write: per-account ops (select <box>,
#                                     search <criteria>, ...)
#               boxes/         [next-pass: contains <boxname>/ dirs with
#                              message UIDs as subdirs]
#
# Per the INFR-8 acceptance criteria the legacy tool at
# appl/veltro/tools/mail.{b,m,sbl,dis} must be deleted once mail9p is
# consumable. That deletion lands together with the IMAP-wiring pass —
# this scaffold establishes the 9P shape without yet replacing the
# tool's functionality.
#
# Architectural guard-rail (binding): the namespace is the only
# enforcement primitive. No permission daemon, no policy engine, no
# per-account ACL. If a capability split cannot be expressed as a path
# split, it does not belong in mail9p. See appl/veltro/SECURITY.md.
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

Mail9p: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

#
# Qid layout. 64 bits packed:
#   bits  0..7   filetype (256 distinct files; we use ~10)
#   bits  8..19  account index (4096 accounts)
#   bits 20..31  mailbox index (4096 boxes per account)
#   bits 32..63  message UID (full IMAP 32-bit UID, reserved for the
#                IMAP-wiring pass)
#
# Files that have no account / box / uid (e.g. /ctl, /accounts) zero
# the higher bits.
#

Qroot:      con 0;	# /
Qrootctl:   con 1;	# /ctl
Qacctsdir:  con 2;	# /accounts
Qacctdir:   con 3;	# /accounts/<name>
Qacctctl:   con 4;	# /accounts/<name>/ctl
Qboxesdir:  con 5;	# /accounts/<name>/boxes

# Account state (in-memory only for this scaffold).
Account: adt {
	name:    string;
	server:  string;
	mode:    int;	# Imap->IMPLICIT_TLS | Imap->STARTTLS
	# IMAP-wiring pass will add: imapconnected, currentmbox, etc.
};

stderr: ref Sys->FD;
user:   string;
vers:   int;

# Account pool. Index into this array == the account index packed
# into qid paths. We grow on demand and never shrink within a process
# lifetime — qid paths must remain stable for the lifetime of a client
# fid, and reusing indices for new accounts would break long-lived
# walks. Disconnect just nils the slot.
accounts: array of ref Account;
naccounts: int;

usage()
{
	sys->fprint(stderr, "Usage: mail9p [-D] [-m mountpt]\n");
	raise "fail:usage";
}

nomod(s: string)
{
	sys->fprint(stderr, "mail9p: can't load %s: %r\n", s);
	raise "fail:load";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);

	styx = load Styx Styx->PATH;
	if(styx == nil) nomod(Styx->PATH);
	styx->init();

	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) nomod(Styxservers->PATH);
	styxservers->init(styx);

	str = load String String->PATH;
	if(str == nil) nomod(String->PATH);

	arg := load Arg Arg->PATH;
	if(arg == nil) nomod(Arg->PATH);
	arg->init(args);

	mountpt := "/n/mail";
	while((o := arg->opt()) != 0)
		case o {
		'D' => styxservers->traceset(1);
		'm' => mountpt = arg->earg();
		*   => usage();
		}
	arg = nil;

	accounts = array[8] of ref Account;
	naccounts = 0;
	vers = 0;

	sys->pctl(Sys->FORKFD, nil);

	user = rf("/dev/user");
	if(user == nil)
		user = "inferno";

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(stderr, "mail9p: can't create pipe: %r\n");
		raise "fail:pipe";
	}

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	srv.msize = 65536 + Styx->IOHDRSZ;
	fds[0] = nil;

	pidc := chan of int;
	spawn serveloop(tchan, srv, pidc);
	<-pidc;

	ensuredir(mountpt);

	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(stderr, "mail9p: mount %s: %r\n", mountpt);
		raise "fail:mount";
	}
}

#
# QID encoding
#

MKPATH(ft, acct, box: int, uid: big): big
{
	p := big ft & big 16rFF;
	p |= (big acct & big 16rFFF) << 8;
	p |= (big box & big 16rFFF) << 20;
	p |= (uid & big 16rFFFFFFFF) << 32;
	return p;
}

FTYPE(path: big):  int { return int (path & big 16rFF); }
ACCT(path: big):   int { return int ((path >> 8) & big 16rFFF); }
BOX(path: big):    int { return int ((path >> 20) & big 16rFFF); }
UID(path: big):    big { return (path >> 32) & big 16rFFFFFFFF; }

# Convenience for files that don't carry account / box / uid.
PROOT:    con big Qroot;
PROOTCTL: con big Qrootctl;
PACCTS:   con big Qacctsdir;

mkacctdir(idx: int): big { return MKPATH(Qacctdir, idx, 0, big 0); }
mkacctctl(idx: int): big { return MKPATH(Qacctctl, idx, 0, big 0); }
mkboxesdir(idx: int): big { return MKPATH(Qboxesdir, idx, 0, big 0); }

#
# Account management
#

newaccount(name, server: string, mode: int): int
{
	# Reject duplicates by name.
	for(i := 0; i < naccounts; i++)
		if(accounts[i] != nil && accounts[i].name == name)
			return -1;

	# Place into first nil slot, else grow.
	idx := -1;
	for(i = 0; i < naccounts; i++) {
		if(accounts[i] == nil) {
			idx = i;
			break;
		}
	}
	if(idx < 0) {
		if(naccounts >= len accounts) {
			ns := array[len accounts * 2] of ref Account;
			ns[0:] = accounts[0:naccounts];
			accounts = ns;
		}
		idx = naccounts++;
	}

	accounts[idx] = ref Account(name, server, mode);
	vers++;
	return idx;
}

findaccountbyname(name: string): (int, ref Account)
{
	for(i := 0; i < naccounts; i++)
		if(accounts[i] != nil && accounts[i].name == name)
			return (i, accounts[i]);
	return (-1, nil);
}

delaccount(name: string): int
{
	(idx, a) := findaccountbyname(name);
	if(idx < 0 || a == nil)
		return -1;
	accounts[idx] = nil;
	vers++;
	return 0;
}

#
# Navigator goroutine: handles Stat, Walk, Readdir over qid paths.
#

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);

		Walk =>
			ft := FTYPE(n.path);

			case ft {
			Qroot =>
				case n.name {
				".." =>
					;	# stay at root
				"ctl" =>
					n.path = PROOTCTL;
				"accounts" =>
					n.path = PACCTS;
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);

			Qacctsdir =>
				case n.name {
				".." =>
					n.path = PROOT;
				* =>
					(idx, a) := findaccountbyname(n.name);
					if(a == nil) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					n.path = mkacctdir(idx);
				}
				n.reply <-= dirgen(n.path);

			Qacctdir =>
				idx := ACCT(n.path);
				case n.name {
				".." =>
					n.path = PACCTS;
				"ctl" =>
					n.path = mkacctctl(idx);
				"boxes" =>
					n.path = mkboxesdir(idx);
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);

			Qboxesdir =>
				# Next-pass: walk into <boxname> here. For the
				# scaffold the directory is empty.
				case n.name {
				".." =>
					n.path = mkacctdir(ACCT(n.path));
					n.reply <-= dirgen(n.path);
				* =>
					n.reply <-= (nil, Enotfound);
				}

			* =>
				# Files are not directories. Only ".." is meaningful.
				case n.name {
				".." =>
					case ft {
					Qrootctl =>
						n.path = PROOT;
					Qacctctl =>
						n.path = mkacctdir(ACCT(n.path));
					* =>
						n.path = PROOT;
					}
					n.reply <-= dirgen(n.path);
				* =>
					n.reply <-= (nil, "not a directory");
				}
			}

		Readdir =>
			ft := FTYPE(m.path);

			# Build the entry list (qid paths). The per-arm code
			# constructs entries in forward order.
			entries: list of big;
			case ft {
			Qroot =>
				# Reverse-add then reverse so the final order is
				# ctl, accounts.
				entries = PROOTCTL :: nil;
				entries = PACCTS :: entries;
				rev0: list of big;
				for(; entries != nil; entries = tl entries)
					rev0 = hd entries :: rev0;
				entries = rev0;

			Qacctsdir =>
				for(i := 0; i < naccounts; i++)
					if(accounts[i] != nil)
						entries = mkacctdir(i) :: entries;
				rev: list of big;
				for(; entries != nil; entries = tl entries)
					rev = hd entries :: rev;
				entries = rev;

			Qacctdir =>
				idx := ACCT(m.path);
				entries = mkboxesdir(idx) :: nil;
				entries = mkacctctl(idx) :: entries;

			Qboxesdir =>
				# Empty in the scaffold; next-pass fills with the
				# IMAP folder list.
				entries = nil;

			* =>
				entries = nil;
			}

			# Emit entries [offset, offset+count). Idiom mirrors
			# llmsrv: send one (dir, "") per accepted entry via
			# n.reply, terminate with (nil, nil). dirgen errors
			# for vanished slots are skipped.
			i := 0;
			for(e := entries; e != nil && n.count > 0; e = tl e) {
				if(i >= n.offset) {
					(d, derr) := dirgen(hd e);
					if(d != nil) {
						n.reply <-= (d, nil);
						n.count--;
					} else if(derr != nil) {
						# Skip; loop continues.
					}
				}
				i++;
			}
			n.reply <-= (nil, nil);
		}
	}
}

#
# dirgen — produce a Sys->Dir for a given qid path. Returns (dir, err);
# (nil, Enotfound) if the path is unknown.
#

# Helper: build a Sys->Dir for a fully-specified qid + name + mode.
# Mirrors llmsrv's `dir()` to avoid per-arm-local-leak issues that
# appeared when dirgen used shared locals (name/mode/isdir) across
# case arms.
mkdir(qid: Sys->Qid, name: string, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid = qid;
	if(qid.qtype & Sys->QTDIR)
		perm |= Sys->DMDIR;
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.length = big 0;
	return d;
}

dirgen(path: big): (ref Sys->Dir, string)
{
	ft := FTYPE(path);

	case ft {
	Qroot =>
		return (mkdir(Sys->Qid(path, vers, Sys->QTDIR), "/", 8r555), nil);

	Qrootctl =>
		return (mkdir(Sys->Qid(path, vers, Sys->QTFILE), "ctl", 8r666), nil);

	Qacctsdir =>
		return (mkdir(Sys->Qid(path, vers, Sys->QTDIR), "accounts", 8r555), nil);

	Qacctdir =>
		idx := ACCT(path);
		if(idx >= naccounts || accounts[idx] == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTDIR), accounts[idx].name, 8r555), nil);

	Qacctctl =>
		idx := ACCT(path);
		if(idx >= naccounts || accounts[idx] == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTFILE), "ctl", 8r666), nil);

	Qboxesdir =>
		idx := ACCT(path);
		if(idx >= naccounts || accounts[idx] == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTDIR), "boxes", 8r555), nil);

	* =>
		return (nil, Enotfound);
	}
}

#
# Server loop: dispatches Tmsg.
#

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);

	while((m := <-tchan) != nil) {
		pick gm := m {
		Readerror =>
			return;

		Attach =>
			srv.attach(gm);

		Walk =>
			srv.walk(gm);

		Open =>
			# Open is handled manually to mirror llmsrv: the
			# framework's srv.open() default applies a permission
			# check that rejects writable ctl files in this server's
			# setup. Walk has already authenticated the fid; trust
			# the mode the client requested.
			c := srv.getfid(gm.fid);
			if(c == nil) {
				srv.open(gm);
				continue;
			}
			omode := styxservers->openmode(gm.mode);
			if(omode < 0) {
				srv.reply(ref Rmsg.Error(gm.tag, Ebadarg));
				continue;
			}
			qid := Sys->Qid(c.path, 0, c.qtype);
			c.open(omode, qid);
			srv.reply(ref Rmsg.Open(gm.tag, qid, srv.iounit()));

		Clunk =>
			srv.clunk(gm);

		Stat =>
			srv.stat(gm);

		Read =>
			(c, err) := srv.canread(gm);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(gm.tag, err));
				continue;
			}

			if(c.qtype & Sys->QTDIR) {
				srv.read(gm);
				continue;
			}

			ft := FTYPE(c.path);
			case ft {
			Qrootctl =>
				# Write-only; reading returns empty.
				srv.reply(styxservers->readbytes(gm, nil));

			Qacctctl =>
				idx := ACCT(c.path);
				if(idx >= naccounts || accounts[idx] == nil) {
					srv.reply(ref Rmsg.Error(gm.tag, Enotfound));
					continue;
				}
				a := accounts[idx];
				status := "disconnected " + a.server + "\n";
				# Next-pass: report selected mailbox, message
				# counts, etc. from a live IMAP connection.
				srv.reply(styxservers->readbytes(gm, array of byte status));

			* =>
				srv.reply(ref Rmsg.Error(gm.tag, Enotfound));
			}

		Write =>
			(c, err) := srv.canwrite(gm);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(gm.tag, err));
				continue;
			}

			ft := FTYPE(c.path);
			case ft {
			Qrootctl =>
				err = handlerootctl(string gm.data);
				if(err != nil) {
					srv.reply(ref Rmsg.Error(gm.tag, err));
					continue;
				}
				srv.reply(ref Rmsg.Write(gm.tag, len gm.data));

			Qacctctl =>
				idx := ACCT(c.path);
				if(idx >= naccounts || accounts[idx] == nil) {
					srv.reply(ref Rmsg.Error(gm.tag, Enotfound));
					continue;
				}
				err = handleacctctl(accounts[idx], string gm.data);
				if(err != nil) {
					srv.reply(ref Rmsg.Error(gm.tag, err));
					continue;
				}
				srv.reply(ref Rmsg.Write(gm.tag, len gm.data));

			* =>
				srv.reply(ref Rmsg.Error(gm.tag, Eperm));
			}

		Remove =>
			srv.reply(ref Rmsg.Error(gm.tag, Eperm));

		* =>
			srv.default(gm);
		}
	}
}

#
# /ctl write commands.
#
#   connect <name> <server> [tls|starttls]
#   disconnect <name>
#   sync <name>
#
# Returns nil on success, error string otherwise.
#

handlerootctl(cmd: string): string
{
	cmd = stripnl(cmd);
	(verb, rest) := splitfield(cmd);

	case verb {
	"connect" =>
		(name, after) := splitfield(rest);
		if(name == "")
			return "connect: name required";
		(server, modearg) := splitfield(after);
		if(server == "")
			return "connect: server required";
		mode := 0;	# Imap->IMPLICIT_TLS (0) — see module/imap.m
		if(modearg == "starttls")
			mode = 1;	# Imap->STARTTLS
		else if(modearg != "" && modearg != "tls")
			return "connect: mode must be tls or starttls";

		if(newaccount(name, server, mode) < 0)
			return "connect: account already exists";
		# Next-pass: trigger IMAP open via factotum credentials here.
		return nil;

	"disconnect" =>
		name := stripnl(rest);
		if(name == "")
			return "disconnect: name required";
		if(delaccount(name) < 0)
			return "disconnect: no such account";
		return nil;

	"sync" =>
		name := stripnl(rest);
		if(name == "")
			return "sync: name required";
		(idx, a) := findaccountbyname(name);
		idx = idx;	# index unused in scaffold; next-pass uses it
		if(a == nil)
			return "sync: no such account";
		# Next-pass: re-fetch mailbox state from IMAP.
		return nil;

	* =>
		return "unknown ctl verb (want: connect|disconnect|sync)";
	}
}

#
# /accounts/<name>/ctl write commands. Scaffold accepts the verbs but
# defers actual IMAP work to the IMAP-wiring pass.
#

handleacctctl(a: ref Account, cmd: string): string
{
	cmd = stripnl(cmd);
	(verb, rest) := splitfield(cmd);

	# `a` and `rest` are unused in the scaffold; the IMAP-wiring pass
	# will dispatch (a, rest) to imap->select / imap->search etc.
	rest = rest;
	a = a;

	case verb {
	"select" =>
		return nil;
	"search" =>
		return nil;
	* =>
		return "unknown account-ctl verb (want: select|search)";
	}
}

#
# Helpers
#

ensuredir(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil)
		return;
	fd = sys->create(path, Sys->OREAD, 8r777 | Sys->DMDIR);
	if(fd == nil) {
		sys->fprint(stderr, "mail9p: can't ensuredir %s: %r\n", path);
		raise "fail:ensuredir";
	}
}

rf(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	# strip trailing newline
	while(n > 0 && (buf[n-1] == byte '\n' || buf[n-1] == byte '\r'))
		n--;
	return string buf[0:n];
}

stripnl(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

# Split into (first whitespace-delimited field, rest with leading
# whitespace trimmed). If no field, returns ("", "").
splitfield(s: string): (string, string)
{
	# trim leading whitespace
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	if(i >= len s)
		return ("", "");
	# find end of field
	j := i;
	while(j < len s && s[j] != ' ' && s[j] != '\t')
		j++;
	field := s[i:j];
	# trim leading whitespace from rest
	while(j < len s && (s[j] == ' ' || s[j] == '\t'))
		j++;
	return (field, s[j:]);
}

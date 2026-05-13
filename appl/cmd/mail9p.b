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

include "imap.m";

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
Qboxdir:    con 6;	# /accounts/<name>/boxes/<box>
Qboxctl:    con 7;	# /accounts/<name>/boxes/<box>/ctl
Qmsgdir:    con 8;	# /accounts/<name>/boxes/<box>/<uid>
# Per-message field files (Chunk C) start at 16 and below the 0x10
# space we leave room for any additional directory types.

# A folder is stable identified by its index into Account.folders.
# Folders that disappear on sync get the .name cleared but their slot
# is never reused, keeping qid paths stable for the process lifetime.
Folder: adt {
	name:     string;	# empty if folder no longer exists
};

# Per-account IMAP state. Each account loads its own Imap module
# instance so the module-level globals in appl/lib/imap.b
# (fd/ibuf/connected/currentmbox) belong to exactly one account.
#
# Concurrency model: all IMAP calls happen from the serveloop. The
# navigator goroutine only reads cached state (folders / msgs /
# currentbox), never calls into a.imap. This keeps the lib's
# module-level globals race-free without explicit locking.
Account: adt {
	name:      string;
	server:    string;	# IMAP server hostname
	smtpserver: string;	# SMTP server (defaults to server)
	mode:      int;		# Imap->IMPLICIT_TLS | Imap->STARTTLS
	imap:      Imap;	# loaded Imap module instance
	connected: int;
	# Append-only folder slots. Sync nils the .name of folders the
	# server no longer reports.
	folders:   array of ref Folder;
	nfolders:  int;
	# Currently SELECTed mailbox, or "" if none.
	currentbox: string;
	# Mailbox state from the last SELECT.
	mbox:      ref Imap->Mailbox;
	# Cached message list for currentbox, in IMAP sequence order.
	# Indexed in the array by (seq - 1). nil before first fetch.
	# UID-to-seq lookup is linear; v1 mailboxes are bounded by the
	# IMAP server's FETCH window so this is fine.
	msgs:      array of ref Imap->Msg;
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
mkboxdir(aidx, bidx: int): big { return MKPATH(Qboxdir, aidx, bidx, big 0); }
mkboxctl(aidx, bidx: int): big { return MKPATH(Qboxctl, aidx, bidx, big 0); }
mkmsgdir(aidx, bidx: int, uid: big): big { return MKPATH(Qmsgdir, aidx, bidx, uid); }

#
# Account management
#

newaccount(name, server, smtpserver: string, mode: int): (int, ref Account)
{
	# Reject duplicates by name.
	for(i := 0; i < naccounts; i++)
		if(accounts[i] != nil && accounts[i].name == name)
			return (-1, nil);

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

	a := ref Account;
	a.name = name;
	a.server = server;
	a.smtpserver = smtpserver;
	a.mode = mode;
	a.imap = nil;
	a.connected = 0;
	a.folders = array[16] of ref Folder;
	a.nfolders = 0;
	a.currentbox = "";
	a.mbox = nil;
	a.msgs = nil;
	accounts[idx] = a;
	vers++;
	return (idx, a);
}

# Find a folder by name; returns (-1, nil) if not present (or deleted).
findfolder(a: ref Account, name: string): (int, ref Folder)
{
	for(i := 0; i < a.nfolders; i++)
		if(a.folders[i] != nil && a.folders[i].name == name)
			return (i, a.folders[i]);
	return (-1, nil);
}

# Append a folder slot, growing the array if needed.
appendfolder(a: ref Account, name: string)
{
	if(a.nfolders >= len a.folders) {
		ns := array[len a.folders * 2] of ref Folder;
		ns[0:] = a.folders[0:a.nfolders];
		a.folders = ns;
	}
	a.folders[a.nfolders++] = ref Folder(name);
}

# Reconcile cached folder list against a fresh server list. Names not
# in the new list are nilled in-place (slot index preserved); new
# names are appended.
mergefolders(a: ref Account, fresh: list of string)
{
	# Mark which existing slots are still present.
	seen := array[a.nfolders] of int;
	for(l := fresh; l != nil; l = tl l) {
		name := hd l;
		found := 0;
		for(i := 0; i < a.nfolders; i++) {
			if(a.folders[i] != nil && a.folders[i].name == name) {
				seen[i] = 1;
				found = 1;
				break;
			}
		}
		if(!found)
			appendfolder(a, name);
	}
	for(i := 0; i < a.nfolders; i++)
		if(a.folders[i] != nil && !seen[i])
			a.folders[i] = nil;
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
	if(a.connected && a.imap != nil)
		a.imap->logout();
	a.imap = nil;
	a.connected = 0;
	accounts[idx] = nil;
	vers++;
	return 0;
}

# Default the SMTP server when only the IMAP server was given. We follow
# the convention `imap.<rest>` → `smtp.<rest>`; if the IMAP server does
# not start with `imap.`, fall back to the IMAP server itself (so a
# generic mail host works).
defaultsmtp(imapserver: string): string
{
	prefix := "imap.";
	if(len imapserver > len prefix && imapserver[0:len prefix] == prefix)
		return "smtp." + imapserver[len prefix:];
	return imapserver;
}

# Load a fresh Imap module instance. Each account has its own loaded
# module so the lib's module-level globals don't collide across accounts.
loadimap(): (Imap, string)
{
	m := load Imap Imap->PATH;
	if(m == nil)
		return (nil, "cannot load " + Imap->PATH);
	return (m, nil);
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
				aidx := ACCT(n.path);
				case n.name {
				".." =>
					n.path = mkacctdir(aidx);
					n.reply <-= dirgen(n.path);
				* =>
					if(aidx >= naccounts || accounts[aidx] == nil) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					(bidx, f) := findfolder(accounts[aidx], n.name);
					if(f == nil) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					n.path = mkboxdir(aidx, bidx);
					n.reply <-= dirgen(n.path);
				}

			Qboxdir =>
				aidx := ACCT(n.path);
				bidx := BOX(n.path);
				case n.name {
				".." =>
					n.path = mkboxesdir(aidx);
					n.reply <-= dirgen(n.path);
				"ctl" =>
					n.path = mkboxctl(aidx, bidx);
					n.reply <-= dirgen(n.path);
				* =>
					# Walk by UID. Only the currently-selected box has
					# a cached msg list; other boxes appear as empty.
					if(aidx >= naccounts || accounts[aidx] == nil) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					a := accounts[aidx];
					if(bidx >= a.nfolders || a.folders[bidx] == nil ||
					   a.folders[bidx].name != a.currentbox) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					uid := strtobig(n.name);
					if(uid <= big 0 || !uidpresent(a, uid)) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					n.path = mkmsgdir(aidx, bidx, uid);
					n.reply <-= dirgen(n.path);
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
					Qboxctl =>
						n.path = mkboxdir(ACCT(n.path), BOX(n.path));
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
				aidx := ACCT(m.path);
				if(aidx < naccounts && accounts[aidx] != nil) {
					a := accounts[aidx];
					for(i := 0; i < a.nfolders; i++)
						if(a.folders[i] != nil)
							entries = mkboxdir(aidx, i) :: entries;
					rev2: list of big;
					for(; entries != nil; entries = tl entries)
						rev2 = hd entries :: rev2;
					entries = rev2;
				}

			Qboxdir =>
				aidx := ACCT(m.path);
				bidx := BOX(m.path);
				entries = mkboxctl(aidx, bidx) :: entries;
				# UID-named message dirs visible only when this folder
				# is the currently-selected box.
				if(aidx < naccounts && accounts[aidx] != nil) {
					a := accounts[aidx];
					if(bidx < a.nfolders && a.folders[bidx] != nil &&
					   a.folders[bidx].name == a.currentbox &&
					   a.msgs != nil) {
						msgs := a.msgs;
						for(i := 0; i < len msgs; i++)
							if(msgs[i] != nil)
								entries = mkmsgdir(aidx, bidx, big msgs[i].uid) :: entries;
					}
				}
				rev3: list of big;
				for(; entries != nil; entries = tl entries)
					rev3 = hd entries :: rev3;
				entries = rev3;

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

	Qboxdir =>
		aidx := ACCT(path);
		bidx := BOX(path);
		if(aidx >= naccounts || accounts[aidx] == nil)
			return (nil, Enotfound);
		a := accounts[aidx];
		if(bidx >= a.nfolders || a.folders[bidx] == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTDIR),
			a.folders[bidx].name, 8r555), nil);

	Qboxctl =>
		aidx := ACCT(path);
		bidx := BOX(path);
		if(aidx >= naccounts || accounts[aidx] == nil)
			return (nil, Enotfound);
		a := accounts[aidx];
		if(bidx >= a.nfolders || a.folders[bidx] == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTFILE), "ctl", 8r666), nil);

	Qmsgdir =>
		aidx := ACCT(path);
		bidx := BOX(path);
		uid := UID(path);
		if(aidx >= naccounts || accounts[aidx] == nil)
			return (nil, Enotfound);
		a := accounts[aidx];
		if(bidx >= a.nfolders || a.folders[bidx] == nil)
			return (nil, Enotfound);
		# UID is the directory name. The message dir is only navigable
		# for currentbox; non-current boxes don't list their messages.
		if(a.folders[bidx].name != a.currentbox || !uidpresent(a, uid))
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTDIR),
			string uid, 8r555), nil);

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
				srv.reply(styxservers->readbytes(gm,
					array of byte acctstatus(a)));

			Qboxctl =>
				# Write-only for now (Chunk D adds search/archive/move).
				srv.reply(styxservers->readbytes(gm, nil));

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
#   connect <name> <server> [tls|starttls] [smtp=<host>]
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
		return doconnect(rest);

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
		(nil, a) := findaccountbyname(name);
		if(a == nil)
			return "sync: no such account";
		return dosync(a);

	* =>
		return "unknown ctl verb (want: connect|disconnect|sync)";
	}
}

# connect <name> <server> [tls|starttls] [smtp=<host>]
doconnect(rest: string): string
{
	(name, r1) := splitfield(rest);
	if(name == "")
		return "connect: name required";
	(server, r2) := splitfield(r1);
	if(server == "")
		return "connect: server required";

	mode := Imap->IMPLICIT_TLS;
	smtpserver := "";

	# Remaining tokens: mode flag and/or smtp=<host>, any order.
	for(rem := r2; rem != ""; ) {
		(tok, after) := splitfield(rem);
		rem = after;
		if(tok == "")
			break;
		if(tok == "tls")
			mode = Imap->IMPLICIT_TLS;
		else if(tok == "starttls")
			mode = Imap->STARTTLS;
		else if(len tok > 5 && tok[0:5] == "smtp=")
			smtpserver = tok[5:];
		else
			return "connect: unrecognised arg: " + tok;
	}
	if(smtpserver == "")
		smtpserver = defaultsmtp(server);

	(idx, a) := newaccount(name, server, smtpserver, mode);
	if(idx < 0)
		return "connect: account already exists";

	(im, lerr) := loadimap();
	if(im == nil) {
		accounts[idx] = nil;
		vers++;
		return "connect: " + lerr;
	}
	a.imap = im;

	# IMAP credentials come from factotum:
	#   proto=pass service=imap dom=<server>
	# Passing nil/nil tells the lib to query factotum itself.
	err := im->open(nil, nil, server, mode);
	if(err != nil) {
		a.imap = nil;
		accounts[idx] = nil;
		vers++;
		return "connect: " + err;
	}
	a.connected = 1;

	# Populate folder list first so doselect can deduplicate against it.
	# Soft-fail: connection is still usable without a folder list, but
	# the user gets fewer signals.
	(fl, ferr) := im->folders();
	if(ferr == nil)
		mergefolders(a, fl);

	# Best-effort INBOX SELECT so the account is usable immediately. A
	# server that returns a different error here still counts as
	# connected — the caller can SELECT a different folder via
	# /accounts/<n>/ctl.
	doselect(a, "INBOX");

	vers++;
	return nil;
}

dosync(a: ref Account): string
{
	if(!a.connected || a.imap == nil)
		return "sync: not connected";
	(fl, ferr) := a.imap->folders();
	if(ferr != nil)
		return "sync: folders: " + ferr;
	mergefolders(a, fl);
	# If a mailbox is currently selected, re-SELECT to refresh counts.
	if(a.currentbox != "") {
		(mbox, serr) := a.imap->select(a.currentbox);
		if(serr == nil && mbox != nil)
			a.mbox = mbox;
	}
	vers++;
	return nil;
}

acctstatus(a: ref Account): string
{
	if(!a.connected)
		return "disconnected " + a.server + "\n";
	s := "connected " + a.server;
	if(a.currentbox != "")
		s += " box=" + a.currentbox;
	if(a.mbox != nil)
		s += sys->sprint(" exists=%d unseen=%d", a.mbox.exists, a.mbox.unseen);
	return s + "\n";
}

#
# /accounts/<name>/ctl write commands.
#
#   select <mailbox>        SELECT a mailbox; updates currentbox/mbox/msgs.
#   sync                    Re-SELECT currentbox to refresh counts.
#
# Search and per-message operations live on the box-level ctl (next
# pass).
#

handleacctctl(a: ref Account, cmd: string): string
{
	cmd = stripnl(cmd);
	(verb, rest) := splitfield(cmd);

	if(!a.connected || a.imap == nil)
		return "not connected";

	case verb {
	"select" =>
		box := stripnl(rest);
		if(box == "")
			return "select: mailbox required";
		return doselect(a, box);
	"sync" =>
		return dosync(a);
	* =>
		return "unknown account-ctl verb (want: select|sync)";
	}
}

# Select a mailbox and populate the cached msg list. Folder slots are
# guaranteed to exist by the time this is called (callers ensure the
# box name appears in a.folders or appendfolder on success).
doselect(a: ref Account, box: string): string
{
	(mbox, err) := a.imap->select(box);
	if(err != nil)
		return "select: " + err;
	a.currentbox = mbox.name;
	a.mbox = mbox;
	a.msgs = nil;
	# Ensure the folder appears in the cached folder list. Servers
	# sometimes report SELECTable mailboxes that LIST omitted.
	if(findfolderidx(a, mbox.name) < 0)
		appendfolder(a, mbox.name);
	# Fetch envelopes for the whole mailbox. For very large mailboxes
	# this should be paginated, but v1 ships the simple path.
	if(mbox.exists > 0) {
		(msgs, ferr) := a.imap->msglist(1, mbox.exists);
		if(ferr != nil)
			return "select ok, msglist: " + ferr;
		a.msgs = msglisttoarray(msgs, mbox.exists);
	}
	vers++;
	return nil;
}

findfolderidx(a: ref Account, name: string): int
{
	(i, nil) := findfolder(a, name);
	return i;
}

msglisttoarray(l: list of ref Imap->Msg, total: int): array of ref Imap->Msg
{
	# Build an array large enough to index by (seq-1). Slots not
	# present in the fetch result remain nil and are skipped during
	# directory enumeration.
	a := array[total] of ref Imap->Msg;
	for(p := l; p != nil; p = tl p) {
		m := hd p;
		if(m != nil && m.seq >= 1 && m.seq <= total)
			a[m.seq - 1] = m;
	}
	return a;
}

# Linear UID lookup over the cached message list. Returns nil if absent.
findmsgbyuid(a: ref Account, uid: big): ref Imap->Msg
{
	if(a.msgs == nil)
		return nil;
	u := int uid;
	for(i := 0; i < len a.msgs; i++)
		if(a.msgs[i] != nil && a.msgs[i].uid == u)
			return a.msgs[i];
	return nil;
}

uidpresent(a: ref Account, uid: big): int
{
	return findmsgbyuid(a, uid) != nil;
}

# Parse a base-10 unsigned integer string into big. Returns big -1 if
# the string is empty or contains non-digits.
strtobig(s: string): big
{
	if(len s == 0)
		return big -1;
	v := big 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < '0' || c > '9')
			return big -1;
		v = v * big 10 + big (c - '0');
	}
	return v;
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

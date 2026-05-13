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

include "smtp.m";

include "factotum.m";

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
Qcompose:   con 9;	# /accounts/<name>/compose (write-only SMTP send)

# Per-message field files start at 16. They share the qid encoding
# with their parent Qmsgdir (account / box / uid all populated).
Qfrom:      con 16;
Qto:        con 17;
Qcc:        con 18;
Qsubject:   con 19;
Qdate:      con 20;
Qflags:     con 21;
Qbody:      con 22;
Qbodyhtml:  con 23;
Qraw:       con 24;
Qdraftreply:con 25;	# write-only; SMTP send wired in Chunk E

# Order matches what the message directory exposes via Readdir.
# Initialised in init() because Limbo `con` cannot bind array literals.
msgfields: array of int;

msgfieldname(ft: int): string
{
	case ft {
	Qfrom =>     return "from";
	Qto =>       return "to";
	Qcc =>       return "cc";
	Qsubject =>  return "subject";
	Qdate =>     return "date";
	Qflags =>    return "flags";
	Qbody =>     return "body";
	Qbodyhtml => return "body.html";
	Qraw =>      return "raw";
	Qdraftreply => return "draft-reply";
	}
	return "";
}

msgfieldperm(ft: int): int
{
	case ft {
	Qflags =>      return 8r666;	# writable in Chunk D
	Qdraftreply => return 8r222;	# write-only (Chunk E)
	}
	return 8r444;
}

msgfieldfromname(s: string): int
{
	case s {
	"from" =>        return Qfrom;
	"to" =>          return Qto;
	"cc" =>          return Qcc;
	"subject" =>     return Qsubject;
	"date" =>        return Qdate;
	"flags" =>       return Qflags;
	"body" =>        return Qbody;
	"body.html" =>   return Qbodyhtml;
	"raw" =>         return Qraw;
	"draft-reply" => return Qdraftreply;
	}
	return -1;
}

# A folder is stable identified by its index into Account.folders.
# Folders that disappear on sync get the .name cleared but their slot
# is never reused, keeping qid paths stable for the process lifetime.
Folder: adt {
	name:     string;	# empty if folder no longer exists
};

# Per-message wrapper. Envelope + flags + sequence come from the
# msglist FETCH at select time; body/raw are lazy-fetched on first
# read and then cached for the lifetime of the box selection.
MsgCache: adt {
	msg:     ref Imap->Msg;
	bodyset: int;
	raw:     string;	# full RFC822 (headers + blank + body)
	body:    string;	# section after first blank line
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
	# Cached message wrappers for currentbox, in IMAP sequence order.
	# Indexed in the array by (seq - 1). nil before first fetch.
	# UID-to-seq lookup is linear; v1 mailboxes are bounded by the
	# IMAP server's FETCH window so this is fine.
	msgs:      array of ref MsgCache;
	# Last `search <criteria>` result, as readable text. Reset on
	# select. Box ctl reads return this so callers can chain writes
	# and reads of the same file.
	lastsearch: string;
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

	msgfields = array[] of {
		Qfrom, Qto, Qcc, Qsubject, Qdate, Qflags,
		Qbody, Qbodyhtml, Qraw, Qdraftreply,
	};

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
mkacctcompose(idx: int): big { return MKPATH(Qcompose, idx, 0, big 0); }
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
				"compose" =>
					n.path = mkacctcompose(idx);
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

			Qmsgdir =>
				aidx := ACCT(n.path);
				bidx := BOX(n.path);
				uid := UID(n.path);
				case n.name {
				".." =>
					n.path = mkboxdir(aidx, bidx);
					n.reply <-= dirgen(n.path);
				* =>
					ftnext := msgfieldfromname(n.name);
					if(ftnext < 0) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					n.path = MKPATH(ftnext, aidx, bidx, uid);
					n.reply <-= dirgen(n.path);
				}

			* =>
				# Files are not directories. Only ".." is meaningful.
				case n.name {
				".." =>
					case ft {
					Qrootctl =>
						n.path = PROOT;
					Qacctctl or Qcompose =>
						n.path = mkacctdir(ACCT(n.path));
					Qboxctl =>
						n.path = mkboxdir(ACCT(n.path), BOX(n.path));
					Qfrom or Qto or Qcc or Qsubject or Qdate or
					Qflags or Qbody or Qbodyhtml or Qraw or Qdraftreply =>
						n.path = mkmsgdir(ACCT(n.path), BOX(n.path), UID(n.path));
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
				entries = mkacctcompose(idx) :: nil;
				entries = mkboxesdir(idx) :: entries;
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
								entries = mkmsgdir(aidx, bidx, big msgs[i].msg.uid) :: entries;
					}
				}
				rev3: list of big;
				for(; entries != nil; entries = tl entries)
					rev3 = hd entries :: rev3;
				entries = rev3;

			Qmsgdir =>
				aidx := ACCT(m.path);
				bidx := BOX(m.path);
				uid := UID(m.path);
				for(i := 0; i < len msgfields; i++)
					entries = MKPATH(msgfields[i], aidx, bidx, uid) :: entries;
				rev4: list of big;
				for(; entries != nil; entries = tl entries)
					rev4 = hd entries :: rev4;
				entries = rev4;

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

	Qcompose =>
		idx := ACCT(path);
		if(idx >= naccounts || accounts[idx] == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTFILE), "compose", 8r222), nil);

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

	Qfrom or Qto or Qcc or Qsubject or Qdate or Qflags or
	Qbody or Qbodyhtml or Qraw or Qdraftreply =>
		aidx := ACCT(path);
		bidx := BOX(path);
		uid := UID(path);
		if(aidx >= naccounts || accounts[aidx] == nil)
			return (nil, Enotfound);
		a := accounts[aidx];
		if(bidx >= a.nfolders || a.folders[bidx] == nil)
			return (nil, Enotfound);
		if(a.folders[bidx].name != a.currentbox || !uidpresent(a, uid))
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTFILE),
			msgfieldname(ft), msgfieldperm(ft)), nil);

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
				aidx := ACCT(c.path);
				if(aidx >= naccounts || accounts[aidx] == nil) {
					srv.reply(ref Rmsg.Error(gm.tag, Enotfound));
					continue;
				}
				srv.reply(styxservers->readbytes(gm,
					array of byte accounts[aidx].lastsearch));

			Qcompose =>
				# Write-only.
				srv.reply(styxservers->readbytes(gm, nil));

			Qfrom or Qto or Qcc or Qsubject or Qdate or Qflags or
			Qbody or Qbodyhtml or Qraw =>
				(data, derr) := readmsgfield(c.path, ft);
				if(derr != nil)
					srv.reply(ref Rmsg.Error(gm.tag, derr));
				else
					srv.reply(styxservers->readbytes(gm, data));

			Qdraftreply =>
				# Write-only; reads return empty.
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

			Qboxctl =>
				err = handleboxctl(c.path, string gm.data);
				if(err != nil) {
					srv.reply(ref Rmsg.Error(gm.tag, err));
					continue;
				}
				srv.reply(ref Rmsg.Write(gm.tag, len gm.data));

			Qflags =>
				err = handleflagswrite(c.path, string gm.data);
				if(err != nil) {
					srv.reply(ref Rmsg.Error(gm.tag, err));
					continue;
				}
				srv.reply(ref Rmsg.Write(gm.tag, len gm.data));

			Qcompose =>
				err = handlecompose(c.path, string gm.data);
				if(err != nil) {
					srv.reply(ref Rmsg.Error(gm.tag, err));
					continue;
				}
				srv.reply(ref Rmsg.Write(gm.tag, len gm.data));

			Qdraftreply =>
				err = handledraftreply(c.path, string gm.data);
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

# Read one of the per-message field files. Returns (data, errstring);
# err is non-nil iff the read should error out (e.g. body fetch failed).
readmsgfield(path: big, ft: int): (array of byte, string)
{
	aidx := ACCT(path);
	bidx := BOX(path);
	uid := UID(path);
	if(aidx >= naccounts || accounts[aidx] == nil)
		return (nil, Enotfound);
	a := accounts[aidx];
	if(bidx >= a.nfolders || a.folders[bidx] == nil)
		return (nil, Enotfound);
	if(a.folders[bidx].name != a.currentbox)
		return (nil, Enotfound);
	m := findmsgbyuid(a, uid);
	if(m == nil)
		return (nil, Enotfound);
	env := m.msg.envelope;

	case ft {
	Qfrom =>
		return (lineof(envstr(env, Qfrom)), nil);
	Qto =>
		return (lineof(envstr(env, Qto)), nil);
	Qcc =>
		return (lineof(envstr(env, Qcc)), nil);
	Qsubject =>
		return (lineof(envstr(env, Qsubject)), nil);
	Qdate =>
		return (lineof(envstr(env, Qdate)), nil);
	Qflags =>
		# Imap->flagstostring formats as e.g. "\\Seen \\Flagged".
		return (lineof(a.imap->flagstostring(m.msg.flags)), nil);
	Qbody =>
		berr := ensurebody(a, m);
		if(berr != nil)
			return (nil, "fetch: " + berr);
		return (array of byte m.body, nil);
	Qbodyhtml =>
		# MIME parsing is out of scope for v1. Surface raw if the
		# consumer wants HTML; document the limitation.
		return (nil, nil);
	Qraw =>
		rerr := ensurebody(a, m);
		if(rerr != nil)
			return (nil, "fetch: " + rerr);
		return (array of byte m.raw, nil);
	}
	return (nil, Enotfound);
}

# Convenience: extract one field from an Envelope by Qid type.
envstr(env: ref Imap->Envelope, ft: int): string
{
	if(env == nil)
		return "";
	case ft {
	Qfrom =>    return env.sender;
	Qto =>      return env.recipient;
	Qcc =>      return env.cc;
	Qsubject => return env.subject;
	Qdate =>    return env.date;
	}
	return "";
}

# Append a trailing newline to a string and return as bytes, unless
# the string already ends in one.
lineof(s: string): array of byte
{
	if(len s == 0)
		return array of byte "\n";
	if(s[len s - 1] == '\n')
		return array of byte s;
	return array of byte (s + "\n");
}

#
# /accounts/<name>/boxes/<box>/ctl write commands.
#
#   search <imap-criteria>     e.g. "UNSEEN" or "FROM alice"
#   archive <uid>              COPY to Archive + mark \Deleted
#   move <uid> <dest-box>      COPY to dest + mark \Deleted
#
# Search results land in Account.lastsearch (readable via the same
# ctl file). Archive/move work on UIDs, looked up via the cached
# message list.
#

handleboxctl(path: big, cmd: string): string
{
	aidx := ACCT(path);
	bidx := BOX(path);
	if(aidx >= naccounts || accounts[aidx] == nil)
		return Enotfound;
	a := accounts[aidx];
	if(!a.connected || a.imap == nil)
		return "not connected";
	if(bidx >= a.nfolders || a.folders[bidx] == nil)
		return Enotfound;
	if(a.folders[bidx].name != a.currentbox)
		return "box not selected (use /accounts/<n>/ctl select)";

	cmd = stripnl(cmd);
	(verb, rest) := splitfield(cmd);

	case verb {
	"search" =>
		criteria := stripnl(rest);
		if(criteria == "")
			return "search: criteria required";
		(seqs, serr) := a.imap->search(criteria);
		if(serr != nil)
			return "search: " + serr;
		# Map seq → uid via the cached message list. Sequences not
		# present in cache are skipped (the cache predates a possible
		# server-side change since SELECT).
		s := "";
		for(l := seqs; l != nil; l = tl l) {
			seq := hd l;
			if(seq >= 1 && seq <= len a.msgs && a.msgs[seq - 1] != nil)
				s += string a.msgs[seq - 1].msg.uid + "\n";
		}
		a.lastsearch = s;
		return nil;

	"archive" =>
		uid := strtobig(stripnl(rest));
		if(uid <= big 0)
			return "archive: uid required";
		return movemsg(a, uid, "Archive");

	"move" =>
		(uidstr, after) := splitfield(rest);
		dest := stripnl(after);
		if(uidstr == "" || dest == "")
			return "move: usage: move <uid> <dest-box>";
		uid := strtobig(uidstr);
		if(uid <= big 0)
			return "move: bad uid";
		return movemsg(a, uid, dest);

	* =>
		return "unknown box-ctl verb (want: search|archive|move)";
	}
}

# Copy + mark \Deleted. EXPUNGE is deferred — keeps Gmail-style
# semantics where the message is still listable until purged.
movemsg(a: ref Account, uid: big, dest: string): string
{
	m := findmsgbyuid(a, uid);
	if(m == nil)
		return "no such uid";
	cerr := a.imap->copy(string m.msg.seq, dest);
	if(cerr != nil)
		return "copy: " + cerr;
	serr := a.imap->store(m.msg.seq, Imap->FDELETED, 1);
	if(serr != nil)
		return "copy ok, store \\Deleted: " + serr;
	# Update local flags so subsequent reads reflect the change.
	m.msg.flags |= Imap->FDELETED;
	vers++;
	return nil;
}

# Write to <uid>/flags. Body is whitespace-separated flag tokens,
# with optional leading + or - to mark add/remove. Bare flags replace
# the message's flag set (add the listed, clear everything else).
handleflagswrite(path: big, body: string): string
{
	aidx := ACCT(path);
	bidx := BOX(path);
	uid := UID(path);
	if(aidx >= naccounts || accounts[aidx] == nil)
		return Enotfound;
	a := accounts[aidx];
	if(!a.connected || a.imap == nil)
		return "not connected";
	if(bidx >= a.nfolders || a.folders[bidx] == nil)
		return Enotfound;
	if(a.folders[bidx].name != a.currentbox)
		return "box not selected";
	m := findmsgbyuid(a, uid);
	if(m == nil)
		return "no such uid";

	(add, remove, replace, perr) := parseflagswrite(body);
	if(perr != nil)
		return perr;

	if(replace != -1) {
		# Compute add/remove diffs from current flags.
		cur := m.msg.flags;
		add = replace & ~cur;
		remove = cur & ~replace;
	}

	if(add != 0) {
		serr := a.imap->store(m.msg.seq, add, 1);
		if(serr != nil)
			return "store add: " + serr;
		m.msg.flags |= add;
	}
	if(remove != 0) {
		serr := a.imap->store(m.msg.seq, remove, 0);
		if(serr != nil)
			return "store remove: " + serr;
		m.msg.flags &= ~remove;
	}
	vers++;
	return nil;
}

# Parse "\Seen \Flagged" → (add, remove=-1, replace=...) replace mode,
# or "+\Seen -\Flagged" → (add, remove, replace=-1) diff mode. Mixing
# +/- with bare tokens is an error.
parseflagswrite(s: string): (int, int, int, string)
{
	(nil, toks) := sys->tokenize(s, " \t\r\n");
	if(toks == nil)
		return (0, 0, 0, "no flags");

	# Decide replace-vs-diff by the first token's leading sign.
	first := hd toks;
	diffmode := len first > 0 && (first[0] == '+' || first[0] == '-');

	add := 0;
	remove := 0;
	replace := 0;
	for(; toks != nil; toks = tl toks) {
		t := hd toks;
		if(len t == 0)
			continue;
		signed := t[0] == '+' || t[0] == '-';
		if(diffmode != signed)
			return (0, 0, 0, "mix of signed and bare flags");
		bits := 0;
		flagname := t;
		if(signed)
			flagname = t[1:];
		case flagname {
		"\\Seen" or "Seen" =>
			bits = Imap->FSEEN;
		"\\Answered" or "Answered" =>
			bits = Imap->FANSWERED;
		"\\Flagged" or "Flagged" =>
			bits = Imap->FFLAGGED;
		"\\Deleted" or "Deleted" =>
			bits = Imap->FDELETED;
		"\\Draft" or "Draft" =>
			bits = Imap->FDRAFT;
		* =>
			return (0, 0, 0, "unknown flag: " + flagname);
		}
		if(signed) {
			if(t[0] == '+')
				add |= bits;
			else
				remove |= bits;
		} else {
			replace |= bits;
		}
	}
	if(diffmode)
		return (add, remove, -1, nil);
	return (0, 0, replace, nil);
}

#
# SMTP send paths.
#
#   /n/mail/<acct>/compose                — write RFC822 message.
#   /n/mail/<acct>/boxes/<box>/<uid>/draft-reply
#     — write a reply body; threading headers (In-Reply-To,
#       References, Subject Re:) are added from the original message.
#

include_smtp(): (Smtp, string)
{
	smtp := load Smtp Smtp->PATH;
	if(smtp == nil)
		return (nil, "cannot load " + Smtp->PATH);
	return (smtp, nil);
}

# Lookup SMTP credentials in factotum. Tries the smtp-specific key
# first, then falls back to the imap key (most providers share creds).
smtpcreds(a: ref Account): (string, string, string)
{
	fac := load Factotum Factotum->PATH;
	if(fac == nil)
		return (nil, nil, "cannot load Factotum");
	fac->init();
	(u, p) := fac->getuserpasswd("proto=pass service=smtp dom=" + a.smtpserver);
	if(u != nil && p != nil)
		return (u, p, nil);
	(u, p) = fac->getuserpasswd("proto=pass service=imap dom=" + a.server);
	if(u != nil && p != nil)
		return (u, p, nil);
	return (nil, nil, "no SMTP creds in factotum (tried service=smtp,imap)");
}

handlecompose(path: big, body: string): string
{
	aidx := ACCT(path);
	if(aidx >= naccounts || accounts[aidx] == nil)
		return Enotfound;
	a := accounts[aidx];
	return smtpsend(a, body, nil);
}

handledraftreply(path: big, body: string): string
{
	aidx := ACCT(path);
	bidx := BOX(path);
	uid := UID(path);
	if(aidx >= naccounts || accounts[aidx] == nil)
		return Enotfound;
	a := accounts[aidx];
	if(!a.connected || a.imap == nil)
		return "not connected";
	if(bidx >= a.nfolders || a.folders[bidx] == nil)
		return Enotfound;
	if(a.folders[bidx].name != a.currentbox)
		return "box not selected";
	m := findmsgbyuid(a, uid);
	if(m == nil)
		return "no such uid";
	env := m.msg.envelope;
	if(env == nil)
		return "no envelope on message";
	rcpt := env.sender;
	if(env.replyto != "")
		rcpt = env.replyto;
	if(rcpt == "")
		return "no sender / reply-to on message";

	subj := env.subject;
	if(subj == "")
		subj = "Re: (no subject)";
	else if(len subj < 3 || str->tolower(subj[0:3]) != "re:")
		subj = "Re: " + subj;

	# Add threading headers and a default Subject. The body the caller
	# wrote may already include its own headers; if so, leave it
	# alone (the consumer knows what they're doing).
	hdrs := "";
	if(!hasheaderfield(body, "Subject:"))
		hdrs += "Subject: " + subj + "\r\n";
	if(!hasheaderfield(body, "To:"))
		hdrs += "To: " + rcpt + "\r\n";
	if(env.messageid != "" && !hasheaderfield(body, "In-Reply-To:"))
		hdrs += "In-Reply-To: " + env.messageid + "\r\n";
	if(env.messageid != "" && !hasheaderfield(body, "References:"))
		hdrs += "References: " + env.messageid + "\r\n";

	final := hdrs + body;
	# Ensure header/body separator if the caller wrote only a body.
	if(!bodyhasblankline(final))
		final = hdrs + "\r\n" + body;

	err := smtpsend(a, final, rcpt :: nil);
	if(err != nil)
		return err;
	# Mark original \Answered.
	a.imap->store(m.msg.seq, Imap->FANSWERED, 1);
	m.msg.flags |= Imap->FANSWERED;
	vers++;
	return nil;
}

# True if `body` contains a header line starting with `field` (case
# insensitive, only checking the leading part of each header line up
# to the first blank-line separator).
hasheaderfield(body, field: string): int
{
	fl := str->tolower(field);
	# Walk header lines only.
	i := 0;
	for(start := 0; start < len body; ) {
		# Find end of line.
		i = start;
		while(i < len body && body[i] != '\n')
			i++;
		line := body[start:i];
		if(len line > 0 && line[len line - 1] == '\r')
			line = line[0:len line - 1];
		if(line == "")
			return 0;	# header section ended
		if(len line >= len field && str->tolower(line[0:len field]) == fl)
			return 1;
		start = i + 1;
	}
	return 0;
}

# True if body contains a blank line (the RFC822 header/body separator).
bodyhasblankline(body: string): int
{
	for(i := 0; i + 1 < len body; i++) {
		if(body[i] == '\n' && body[i+1] == '\n')
			return 1;
		if(i + 3 < len body && body[i] == '\r' && body[i+1] == '\n' &&
		   body[i+2] == '\r' && body[i+3] == '\n')
			return 1;
	}
	return 0;
}

# Open SMTP, authenticate via factotum creds, send, close. Recipients
# (`recips`, nil to extract from To:/Cc: headers in body) and the From:
# address default to the credential user.
smtpsend(a: ref Account, msg: string, recips: list of string): string
{
	(smtp, lerr) := include_smtp();
	if(smtp == nil)
		return lerr;

	(u, p, cerr) := smtpcreds(a);
	if(cerr != nil)
		return cerr;

	# Implicit-TLS port 465 if account uses IMAPS, otherwise plain port 25.
	usessl := 0;
	if(a.mode == Imap->IMPLICIT_TLS)
		usessl = 1;

	(ok, oerr) := smtp->authopen(u, p, a.smtpserver, usessl);
	if(ok < 0)
		return "smtp authopen: " + oerr;

	from := extractheader(msg, "From:");
	if(from == "")
		from = u;
	if(recips == nil)
		recips = parseaddrlist(extractheader(msg, "To:"));

	# sendmail expects each list element to be a logical line block.
	# Pass the whole message as one block; the lib splits on \n.
	(sok, serr) := smtp->sendmail(from, recips, nil, msg :: nil);
	smtp->close();
	if(sok < 0)
		return "smtp sendmail: " + serr;
	return nil;
}

# Extract the first header field value (trimmed) from an RFC822 message.
extractheader(body, field: string): string
{
	fl := str->tolower(field);
	start := 0;
	for(i := 0; i < len body; ) {
		# Find end of line.
		i = start;
		while(i < len body && body[i] != '\n')
			i++;
		line := body[start:i];
		if(len line > 0 && line[len line - 1] == '\r')
			line = line[0:len line - 1];
		if(line == "")
			return "";	# end of headers
		if(len line >= len field && str->tolower(line[0:len field]) == fl) {
			v := line[len field:];
			# trim leading whitespace
			j := 0;
			while(j < len v && (v[j] == ' ' || v[j] == '\t'))
				j++;
			return v[j:];
		}
		start = i + 1;
	}
	return "";
}

# Split a comma-separated address list. v1: assumes each comma is a
# separator (no quoted commas inside display names). Good enough for
# tool-driven sends.
parseaddrlist(s: string): list of string
{
	out: list of string;
	start := 0;
	for(i := 0; i < len s; i++) {
		if(s[i] == ',') {
			a := str->splitstrl(s[start:i], "<");
			# either "addr@dom" or "Name <addr@dom>"
			out = trimaddr(s[start:i]) :: out;
			start = i + 1;
			a = a;
		}
	}
	if(start < len s)
		out = trimaddr(s[start:]) :: out;
	# Reverse
	rev: list of string;
	for(; out != nil; out = tl out)
		rev = hd out :: rev;
	return rev;
}

# Extract `addr@dom` from `Name <addr@dom>` or `addr@dom`, trimming
# surrounding whitespace.
trimaddr(s: string): string
{
	# Trim whitespace.
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t'))
		j--;
	s = s[i:j];
	# If there's a `<...>`, pull out the inside.
	lt := -1;
	gt := -1;
	for(k := 0; k < len s; k++) {
		if(s[k] == '<') lt = k;
		else if(s[k] == '>') gt = k;
	}
	if(lt >= 0 && gt > lt)
		return s[lt+1:gt];
	return s;
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
	a.lastsearch = "";
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

msglisttoarray(l: list of ref Imap->Msg, total: int): array of ref MsgCache
{
	# Build an array large enough to index by (seq-1). Slots not
	# present in the fetch result remain nil and are skipped during
	# directory enumeration.
	a := array[total] of ref MsgCache;
	for(p := l; p != nil; p = tl p) {
		m := hd p;
		if(m != nil && m.seq >= 1 && m.seq <= total)
			a[m.seq - 1] = ref MsgCache(m, 0, "", "");
	}
	return a;
}

# Linear UID lookup over the cached message list. Returns nil if absent.
findmsgbyuid(a: ref Account, uid: big): ref MsgCache
{
	if(a.msgs == nil)
		return nil;
	u := int uid;
	for(i := 0; i < len a.msgs; i++)
		if(a.msgs[i] != nil && a.msgs[i].msg.uid == u)
			return a.msgs[i];
	return nil;
}

# Lazily fetch the full RFC822 message body and cache it on m. Returns
# any IMAP error from the FETCH. Idempotent: subsequent calls noop.
ensurebody(a: ref Account, m: ref MsgCache): string
{
	if(m.bodyset)
		return nil;
	(raw, ferr) := a.imap->fetch(m.msg.seq);
	if(ferr != nil)
		return ferr;
	m.raw = raw;
	m.body = splitbody(raw);
	m.bodyset = 1;
	return nil;
}

# Return the section of an RFC822 message after the first blank line
# (header / body separator). Handles both CRLF and LF terminators.
splitbody(raw: string): string
{
	for(i := 0; i + 1 < len raw; i++) {
		if(raw[i] == '\n' && raw[i+1] == '\n')
			return raw[i+2:];
		if(i + 3 < len raw && raw[i] == '\r' && raw[i+1] == '\n' &&
		   raw[i+2] == '\r' && raw[i+3] == '\n')
			return raw[i+4:];
	}
	return "";
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

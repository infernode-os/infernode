implement Mail9p;

#
# mail9p - IMAP/JMAP as a 9P filesystem at /mnt/mail
#
# Plan-9-style Styx server exposing one or more mail accounts so an
# agent can triage, classify, archive, flag, and (separately) reply to
# mail using ordinary file operations. The namespace-composition model:
# binding the right paths is the capability. There is no permission
# system anywhere in this server — bind triage-only paths for a triage
# agent, bind compose for a reply-allowed agent, and so on.
#
# See INFR-8 for the design ticket. man/4/mail9p documents the
# user-facing shape.
#
#   /mnt/mail/
#       ctl                          connect / disconnect / sync
#       accounts/<name>/
#           ctl                      status / select / sync
#           compose                  write RFC822 → SMTP
#           boxes/<box>/
#               ctl                  search / archive / move
#               <uid>/
#                   from to cc replyto subject date flags
#                   body body.html raw draft-reply
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

include "mailparse.m";
	mailparse: Mailparse;

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
Qdraftreply:con 25;	# a reply's text, sent to the message's sender
Qreplyto:   con 26;	# the Reply-To addresses, where a reply goes if there are any

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
	Qreplyto =>  return "replyto";
	Qcompose =>  return "compose";
	}
	return "";
}

msgfieldperm(ft: int): int
{
	case ft {
	Qflags =>      return 8r666;	# writable in Chunk D
	Qdraftreply => return 8r666;	# written; read back for the send's result
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
	"replyto" =>     return Qreplyto;
	}
	return -1;
}

# A folder is stable identified by its index into Account.folders.
# Folders that disappear on sync get the .name cleared but their slot
# is never reused, keeping qid paths stable for the process lifetime.
Folder: adt {
	name:     string;	# IMAP name; empty if folder no longer exists
	dispname: string;	# 9P-safe entry name (IMAP '/' delimiter shown as ':')
	uidvalidity: int;	# of the mailbox when it was last selected; 0 before
};

# Per-message wrapper. Envelope + flags + UID come from the
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
# Concurrency model: an account's IMAP and SMTP calls are made by one
# process at a time, the holder of its lk (see work), never by the serve
# loop or the navigator, which only read cached state (folders / msgs /
# currentbox).  This keeps the lib's module-level globals race-free, and
# a server that does not answer holds only its own account.
Account: adt {
	idx:       int;		# its place in accounts, for as long as mail9p runs
	live:      int;		# connected once: it has files
	gone:      int;		# disconnected for good
	lk:        chan of int;	# held by the process using its connections
	queue:     list of ref Job;	# requests for them, in the order they came
	working:   int;		# its process is running
	nwait:     int;		# requests in queue or being done
	downat:    int;		# when its connection failed (ms); 0 if it has not
	why:       string;	# and the reason
	lastsend:  string;	# what became of the last message sent
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
	# Cached message wrappers for currentbox, in the server's order:
	# the newest MAXMSGS of them. nil before first fetch.
	# UID lookup is linear.
	msgs:      array of ref MsgCache;
	# Last `search <criteria>` result, as readable text. Reset on
	# select. Box ctl reads return this so callers can chain writes
	# and reads of the same file.
	lastsearch: string;
};

stderr: ref Sys->FD;
user:   string;
vers:   int;
srv:    ref Styxserver;
lk:     chan of int;		# guards pending, nwait and freeslots
pending: list of ref Req;	# requests an account's process will answer
iotime := 30*1000;		# ms a mail server is waited for

MAXACCTS: con 4096;	# places for accounts: the index's 12 bits
MAXBOXES: con 4096;	# and for one account's boxes
MAXMSGS:  con 100000;	# messages of a mailbox that are listed: its newest
RETRY:    con 10*1000;	# ms before a server that failed is tried again

# Account pool. Index into this array == the account index packed
# into qid paths. We grow on demand and never shrink within a process
# lifetime — qid paths must remain stable for the lifetime of a client
# fid.  A place that has had files (a live account) is never given to
# another account: disconnect nils it, and a file opened in it names
# nothing from then on.  It used to be given to the next account
# connected, whose mail a descriptor held on the old account's files
# then read, and through whose SMTP server its compose then sent.
# Only the place of a connect that failed, which never had files, is
# used again (freeslots).
accounts: array of ref Account;
naccounts: int;
freeslots: list of int;

usage()
{
	sys->fprint(stderr, "Usage: mail9p [-D] [-m mountpt] [-t seconds]\n");
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

	mailparse = load Mailparse Mailparse->PATH;
	if(mailparse == nil) nomod(Mailparse->PATH);
	mailparse->init();

	arg := load Arg Arg->PATH;
	if(arg == nil) nomod(Arg->PATH);
	arg->init(args);

	mountpt := "/mnt/mail";
	while((o := arg->opt()) != 0)
		case o {
		'D' => styxservers->traceset(1);
		'm' => mountpt = arg->earg();
		't' =>
			iotime = int arg->earg() * 1000;
			if(iotime <= 0)
				usage();
		*   => usage();
		}
	arg = nil;

	accounts = array[8] of ref Account;
	naccounts = 0;
	vers = 0;

	msgfields = array[] of {
		Qfrom, Qto, Qcc, Qreplyto, Qsubject, Qdate, Qflags,
		Qbody, Qbodyhtml, Qraw, Qdraftreply,
	};
	lk = chan[1] of int;

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

	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	srv.msize = 65536 + Styx->IOHDRSZ;
	srv.replychan = chan of ref Rmsg;
	spawn replier(srv.replychan);
	fds[0] = nil;

	pidc := chan of int;
	spawn serveloop(tchan, pidc);
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

# The account at a place, if there is one with files.
getacct(idx: int): ref Account
{
	if(idx < 0 || idx >= naccounts)
		return nil;
	a := accounts[idx];
	if(a == nil || !a.live)
		return nil;
	return a;
}

# A place for a new account: (-1, nil) if the name is taken, (-2, nil)
# if there are no more places.  The account has no files until it has
# connected (live).
newaccount(name, server, smtpserver: string, mode: int): (int, ref Account)
{
	# Reject duplicates by name, of accounts connecting too.
	for(i := 0; i < naccounts; i++)
		if(accounts[i] != nil && accounts[i].name == name)
			return (-1, nil);

	idx := -1;
	lock();
	if(freeslots != nil) {
		idx = hd freeslots;
		freeslots = tl freeslots;
	}
	unlock();
	if(idx < 0) {
		if(naccounts >= MAXACCTS)
			return (-2, nil);
		if(naccounts >= len accounts) {
			ns := array[len accounts * 2] of ref Account;
			ns[0:] = accounts[0:naccounts];
			accounts = ns;
		}
		idx = naccounts;
	}

	a := ref Account;
	a.idx = idx;
	a.live = 0;
	a.gone = 0;
	a.lk = chan[1] of int;
	a.nwait = 0;
	a.downat = 0;
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
	if(idx == naccounts)
		naccounts++;
	return (idx, a);
}

# Give back the place of an account whose first connection failed: it
# never had files, so nothing can be holding one.
unslot(a: ref Account)
{
	lock();
	if(!a.live && a.idx < naccounts && accounts[a.idx] == a) {
		accounts[a.idx] = nil;
		freeslots = a.idx :: freeslots;
	}
	unlock();
}

# Find a folder by name; returns (-1, nil) if not present (or deleted).
findfolder(a: ref Account, name: string): (int, ref Folder)
{
	for(i := 0; i < a.nfolders; i++)
		if(a.folders[i] != nil && a.folders[i].name == name)
			return (i, a.folders[i]);
	return (-1, nil);
}

# Look up a folder by its 9P-safe display name (what boxes/ exposes). Walk
# and the select ctl resolve client-supplied names this way; the real IMAP
# name (Folder.name) is then used for every IMAP operation.
findfolderbydisp(a: ref Account, dispname: string): (int, ref Folder)
{
	for(i := 0; i < a.nfolders; i++)
		if(a.folders[i] != nil && a.folders[i].dispname == dispname)
			return (i, a.folders[i]);
	return (-1, nil);
}

# Map an IMAP folder name to a 9P-safe directory-entry name. 9P forbids '/'
# in a name; Gmail uses '/' as its hierarchy delimiter (e.g.
# "[Gmail]/All Mail"), which made `ls boxes` fail with "bad character in
# file name". We show '/' as ':'. The mapping need not be reversible — the
# real IMAP name is kept in Folder.name and lookups match the stored
# dispname.
safename(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] == '/')
			r[i] = ':';
		else if(r[i] < ' ' || r[i] == 16r7F)
			r[i] = '?';	# a server may name a mailbox anything
	if(r == "." || r == "..")
		r = ":" + r;
	return r;
}

# Append a folder slot, growing the array if needed.  There are
# MAXBOXES places (a box's index is 12 bits of a file's path): a box
# past them is not listed, where it used to be given the first's place.
appendfolder(a: ref Account, name: string)
{
	if(name == "" || len name > 1024)
		return;
	if(a.nfolders >= MAXBOXES) {
		if(a.nfolders == MAXBOXES)
			sys->fprint(stderr, "mail9p: %s: more than %d boxes; the rest are not listed\n", a.name, MAXBOXES);
		return;
	}
	if(a.nfolders >= len a.folders) {
		ns := array[len a.folders * 2] of ref Folder;
		ns[0:] = a.folders[0:a.nfolders];
		a.folders = ns;
	}
	a.folders[a.nfolders] = ref Folder(name, safename(name), 0);
	a.nfolders++;
}

# Reconcile cached folder list against a fresh server list. Names not
# in the new list are nilled in-place (slot index preserved); new
# names are appended.
mergefolders(a: ref Account, fresh: list of string)
{
	# Snapshot the slot count BEFORE appending. appendfolder() grows
	# a.nfolders, and both the match scan and the stale-removal pass must
	# only consider folders that existed prior to this merge — newly
	# appended ones are present by definition. Indexing `seen` (length
	# orign) by the grown a.nfolders was an array-bounds crash on the first
	# connect, where orign is 0 but a server like Gmail adds ~13 folders.
	orign := a.nfolders;
	seen := array[orign] of int;
	for(l := fresh; l != nil; l = tl l) {
		name := hd l;
		found := 0;
		for(i := 0; i < orign; i++) {
			if(a.folders[i] != nil && a.folders[i].name == name) {
				seen[i] = 1;
				found = 1;
				break;
			}
		}
		if(!found)
			appendfolder(a, name);
	}
	for(i := 0; i < orign; i++)
		if(a.folders[i] != nil && !seen[i])
			a.folders[i] = nil;
}

findaccountbyname(name: string): (int, ref Account)
{
	for(i := 0; i < naccounts; i++)
		if(accounts[i] != nil && accounts[i].live && accounts[i].name == name)
			return (i, accounts[i]);
	return (-1, nil);
}

# The account's files go now; its session is logged out by a process
# of its own, after whatever it is doing.
delaccount(name: string): int
{
	(idx, a) := findaccountbyname(name);
	if(idx < 0 || a == nil)
		return -1;
	a.gone = 1;
	accounts[idx] = nil;
	vers++;
	spawn bye(a, nil);
	return 0;
}

# Default the SMTP server when only the IMAP server was given. We follow
# the convention `imap.<rest>` → `smtp.<rest>`; if the IMAP server does
# not start with `imap.`, fall back to the IMAP server itself (so a
# generic mail host works).
defaultsmtp(imapserver: string): string
{
	imapserver = hostof(imapserver);
	prefix := "imap.";
	if(len imapserver > len prefix && imapserver[0:len prefix] == prefix)
		return "smtp." + imapserver[len prefix:];
	return imapserver;
}

# An IMAP server given as host!port (a local bridge's port, say) is the
# host for its keys and for the SMTP server derived from it.
hostof(server: string): string
{
	for(i := 0; i < len server; i++)
		if(server[i] == '!')
			return server[0:i];
	return server;
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
					if(getacct(aidx) == nil) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					(bidx, f) := findfolderbydisp(accounts[aidx], n.name);
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
					if(getacct(aidx) == nil) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					a := accounts[aidx];
					if(bidx >= a.nfolders || a.folders[bidx] == nil ||
					   a.folders[bidx].name != a.currentbox) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					uid := mailparse->strtobig(n.name);
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
					Qfrom or Qto or Qcc or Qsubject or Qdate or Qreplyto or
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
					if(getacct(i) != nil)
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
				if(getacct(aidx) != nil) {
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
				if(getacct(aidx) != nil) {
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
		if(getacct(idx) == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTDIR), accounts[idx].name, 8r555), nil);

	Qacctctl =>
		idx := ACCT(path);
		if(getacct(idx) == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTFILE), "ctl", 8r666), nil);

	Qboxesdir =>
		idx := ACCT(path);
		if(getacct(idx) == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTDIR), "boxes", 8r555), nil);

	Qcompose =>
		idx := ACCT(path);
		if(getacct(idx) == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTFILE), "compose", 8r666), nil);

	Qboxdir =>
		aidx := ACCT(path);
		bidx := BOX(path);
		if(getacct(aidx) == nil)
			return (nil, Enotfound);
		a := accounts[aidx];
		if(bidx >= a.nfolders || a.folders[bidx] == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTDIR),
			a.folders[bidx].dispname, 8r555), nil);

	Qboxctl =>
		aidx := ACCT(path);
		bidx := BOX(path);
		if(getacct(aidx) == nil)
			return (nil, Enotfound);
		a := accounts[aidx];
		if(bidx >= a.nfolders || a.folders[bidx] == nil)
			return (nil, Enotfound);
		return (mkdir(Sys->Qid(path, vers, Sys->QTFILE), "ctl", 8r666), nil);

	Qmsgdir =>
		aidx := ACCT(path);
		bidx := BOX(path);
		uid := UID(path);
		if(getacct(aidx) == nil)
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

	Qfrom or Qto or Qcc or Qsubject or Qdate or Qflags or Qreplyto or
	Qbody or Qbodyhtml or Qraw or Qdraftreply =>
		aidx := ACCT(path);
		bidx := BOX(path);
		uid := UID(path);
		if(getacct(aidx) == nil)
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
# Nothing here waits for a mail server.  What needs one (a connect, a
# select, a search, a message's text, a flag, a send) is handed to a
# process of the account's, one at a time for each account, which
# answers the request when it is done; meanwhile the loop goes on with
# the next message.  Every IMAP and SMTP call was made from this loop:
# one account's server that stopped answering, or closed a connection
# left idle, held every file of every account, and an exception in a
# call (a count of 2^31 messages, a string ending in a backslash) ended
# the server.
#

serveloop(tchan: chan of ref Tmsg, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);

	for(;;) {
		m := <-tchan;
		if(m == nil || tagof m == tagof Tmsg.Readerror)
			break;
		{
			serve(m);
		} exception e {
		"*" =>
			sys->fprint(stderr, "mail9p: %s\n", e);
			srv.reply(ref Rmsg.Error(m.tag, "mail9p: " + e));
		}
	}
	shutdown();
}

# Replies are written by one process, whoever makes them: a reply
# longer than a pipe takes at once is written in pieces, which two
# writers would mix.
replier(c: chan of ref Rmsg)
{
	for(;;) {
		m := <-c;
		if(m == nil)
			break;
		srv.replydirect(m);
	}
}

serve(m: ref Tmsg)
{
	pick gm := m {
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
			return;
		}
		omode := styxservers->openmode(gm.mode);
		if(omode < 0) {
			srv.reply(ref Rmsg.Error(gm.tag, Ebadarg));
			return;
		}
		qid := Sys->Qid(c.path, 0, c.qtype);
		c.open(omode, qid);
		srv.reply(ref Rmsg.Open(gm.tag, qid, srv.iounit()));

	Flush =>
		# the request flushed is not answered after its flush is: its
		# tag may by then be another request's
		lock();
		for(l := pending; l != nil; l = tl l)
			if((hd l).tag == gm.oldtag)
				(hd l).flushed = 1;
		unlock();
		srv.default(gm);

	Clunk =>
		# a message written to compose or draft-reply and not yet
		# sent (by a read of the same file) is sent now
		cf := takecompose(gm.fid);
		if(cf != nil && cf.state == Gathering && cf.bad == nil && cf.n > 0) {
			cf.state = Sending;
			dispatch(ref Op(OSend, cf.a, cf.path, nil, nil, 0, cf), -1);
		}
		srv.clunk(gm);

	Stat =>
		srv.stat(gm);

	Read =>
		serveread(gm);

	Write =>
		servewrite(gm);

	Remove =>
		takecompose(gm.fid);
		srv.remove(gm);

	* =>
		srv.default(gm);
	}
}

serveread(gm: ref Tmsg.Read)
{
	(c, err) := srv.canread(gm);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(gm.tag, err));
		return;
	}

	if(c.qtype & Sys->QTDIR) {
		srv.read(gm);
		return;
	}

	ft := FTYPE(c.path);
	case ft {
	Qrootctl =>
		# Write-only; reading returns empty.
		srv.reply(styxservers->readbytes(gm, nil));

	Qacctctl =>
		a := getacct(ACCT(c.path));
		if(a == nil) {
			srv.reply(ref Rmsg.Error(gm.tag, Enotfound));
			return;
		}
		srv.reply(styxservers->readbytes(gm, array of byte acctstatus(a)));

	Qboxctl =>
		a := getacct(ACCT(c.path));
		if(a == nil) {
			srv.reply(ref Rmsg.Error(gm.tag, Enotfound));
			return;
		}
		# the last search's answer belongs to the box searched: it
		# was given to a read of any box's ctl
		s := "";
		bidx := BOX(c.path);
		if(bidx < a.nfolders && a.folders[bidx] != nil &&
		   a.folders[bidx].name == a.currentbox)
			s = a.lastsearch;
		srv.reply(styxservers->readbytes(gm, array of byte s));

	Qcompose or Qdraftreply =>
		readcompose(gm, c);

	Qbody or Qraw =>
		(a, mc, merr) := findmsg(c.path);
		if(merr != nil) {
			srv.reply(ref Rmsg.Error(gm.tag, merr));
			return;
		}
		if(mc.bodyset) {
			if(ft == Qbody)
				srv.reply(styxservers->readbytes(gm, array of byte mc.body));
			else
				srv.reply(styxservers->readbytes(gm, array of byte mc.raw));
			return;
		}
		dispatch(ref Op(OBody, a, c.path, nil, gm, 0, nil), gm.tag);

	Qfrom or Qto or Qcc or Qsubject or Qdate or Qflags or
	Qbodyhtml or Qreplyto =>
		(data, derr) := readmsgfield(c.path, ft);
		if(derr != nil)
			srv.reply(ref Rmsg.Error(gm.tag, derr));
		else
			srv.reply(styxservers->readbytes(gm, data));

	* =>
		srv.reply(ref Rmsg.Error(gm.tag, Enotfound));
	}
}

servewrite(gm: ref Tmsg.Write)
{
	(c, err) := srv.canwrite(gm);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(gm.tag, err));
		return;
	}

	ft := FTYPE(c.path);
	case ft {
	Qrootctl =>
		rootctl(gm);

	Qacctctl or Qboxctl or Qflags =>
		a := getacct(ACCT(c.path));
		if(a == nil) {
			srv.reply(ref Rmsg.Error(gm.tag, Enotfound));
			return;
		}
		kind := OAcctctl;
		if(ft == Qboxctl)
			kind = OBoxctl;
		else if(ft == Qflags)
			kind = OFlags;
		dispatch(ref Op(kind, a, c.path, string gm.data, nil, len gm.data, nil), gm.tag);

	Qcompose or Qdraftreply =>
		writecompose(gm, c);

	* =>
		srv.reply(ref Rmsg.Error(gm.tag, Eperm));
	}
}

#
# Requests that wait for a mail server.
#

Req: adt {
	tag:	int;
	flushed:	int;
};

OConnect, OSync, OAcctctl, OBoxctl, OFlags, OBody, OSend, OStatus: con iota;

Op: adt {
	kind:	int;
	a:	ref Account;
	path:	big;
	text:	string;			# a write's text
	rd:	ref Tmsg.Read;		# the read to answer, if it is one
	count:	int;			# a write's count
	cf:	ref Compose;		# OSend's message
};

# A request and who is to be answered: an account's are done in the
# order they came.
Job: adt {
	op:	ref Op;
	r:	ref Req;
};

MAXQUEUE: con 32;	# requests one account has waiting, at most

lock()
{
	lk <-= 1;
}

unlock()
{
	<-lk;
}

# Hand op to its account's process.  tag is the request to answer when
# it is done, or -1 if there is none (a message sent at its file's close).
dispatch(op: ref Op, tag: int)
{
	a := op.a;
	r: ref Req;
	lock();
	if(a.nwait >= MAXQUEUE) {
		unlock();
		e := a.name + ": too many requests waiting for its server";
		if(tag >= 0)
			srv.reply(ref Rmsg.Error(tag, e));
		else if(op.cf != nil)
			notsent(a, op.cf, e);
		return;
	}
	a.nwait++;
	if(tag >= 0) {
		r = ref Req(tag, 0);
		pending = r :: pending;
	}
	rq: list of ref Job;
	for(q := a.queue; q != nil; q = tl q)
		rq = hd q :: rq;
	q = ref Job(op, r) :: nil;
	for(; rq != nil; rq = tl rq)
		q = hd rq :: q;
	a.queue = q;
	start := !a.working;
	a.working = 1;
	unlock();
	if(start)
		spawn worker(a);
}

# An account's process: its requests, one after another, until there
# are none.
worker(a: ref Account)
{
	for(;;) {
		lock();
		if(a.queue == nil) {
			a.working = 0;
			unlock();
			return;
		}
		j := hd a.queue;
		a.queue = tl a.queue;
		unlock();
		work(j.op, j.r);
	}
}

work(op: ref Op, r: ref Req)
{
	a := op.a;
	a.lk <-= 1;
	data: array of byte;
	err: string;
	{
		(data, err) = runop(op);
	} exception e {
	"*" =>
		# whatever went wrong in a call (memory, a parser), the
		# account's connection is not to be trusted after it
		err = a.name + ": " + e;
		markdown(a, e);
		if(op.kind == OConnect)
			unslot(a);
		if(op.cf != nil)
			notsent(a, op.cf, err);
	}
	<-a.lk;

	lock();
	a.nwait--;
	if(r != nil) {
		if(!r.flushed) {
			if(err != nil)
				srv.reply(ref Rmsg.Error(r.tag, err));
			else if(op.rd != nil)
				srv.reply(styxservers->readbytes(op.rd, data));
			else
				srv.reply(ref Rmsg.Write(r.tag, op.count));
		}
		kept: list of ref Req;
		for(l := pending; l != nil; l = tl l)
			if(hd l != r)
				kept = hd l :: kept;
		pending = kept;
	}
	unlock();
}

runop(op: ref Op): (array of byte, string)
{
	a := op.a;
	case op.kind {
	OConnect =>
		err := connect(a);
		if(err != nil) {
			unslot(a);
			return (nil, "connect: " + err);
		}
		a.live = 1;
		vers++;
		return (nil, nil);
	OSend =>
		return sendcompose(op.cf);
	OStatus =>
		return (array of byte a.lastsend, nil);
	}
	# the rest are an account's that is still there
	if(a.gone || getacct(a.idx) != a)
		return (nil, Enotfound);
	case op.kind {
	OSync =>
		return (nil, dosync(a));
	OAcctctl =>
		return (nil, handleacctctl(a, op.text));
	OBoxctl =>
		return (nil, handleboxctl(a, op.path, op.text));
	OFlags =>
		return (nil, handleflagswrite(a, op.path, op.text));
	OBody =>
		return bodyread(a, op.path);
	}
	return (nil, "unknown request");
}

#
# /ctl write commands.
#
#   connect <name> <server> [tls|starttls] [smtp=<host>]
#   disconnect <name>
#   sync <name>
#

rootctl(gm: ref Tmsg.Write)
{
	cmd := stripnl(string gm.data);
	(verb, rest) := splitfield(cmd);
	err: string;

	case verb {
	"connect" =>
		a: ref Account;
		(a, err) = newconnect(rest);
		if(a != nil) {
			dispatch(ref Op(OConnect, a, big 0, nil, nil, len gm.data, nil), gm.tag);
			return;
		}

	"disconnect" =>
		name := stripnl(rest);
		if(name == "")
			err = "disconnect: name required";
		else if(delaccount(name) < 0)
			err = "disconnect: no such account";

	"sync" =>
		name := stripnl(rest);
		(nil, a) := findaccountbyname(name);
		if(name == "")
			err = "sync: name required";
		else if(a == nil)
			err = "sync: no such account";
		else {
			dispatch(ref Op(OSync, a, big 0, nil, nil, len gm.data, nil), gm.tag);
			return;
		}

	* =>
		err = "unknown ctl verb (want: connect|disconnect|sync)";
	}
	if(err != nil)
		srv.reply(ref Rmsg.Error(gm.tag, err));
	else
		srv.reply(ref Rmsg.Write(gm.tag, len gm.data));
}

# connect <name> <server> [tls|starttls] [smtp=<host>]: the account's
# place is made here; its connection is its process's work (connect).
newconnect(rest: string): (ref Account, string)
{
	(name, r1) := splitfield(rest);
	if(name == "")
		return (nil, "connect: name required");
	if(!okname(name))
		return (nil, "connect: the account's name is not a file's name");
	(server, r2) := splitfield(r1);
	if(server == "")
		return (nil, "connect: server required");

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
			return (nil, "connect: unrecognised arg: " + tok);
	}
	if(smtpserver == "")
		smtpserver = defaultsmtp(server);

	(idx, a) := newaccount(name, server, smtpserver, mode);
	if(idx == -2)
		return (nil, sys->sprint("connect: %d accounts have been made, as many as there can be: start mail9p again", MAXACCTS));
	if(idx < 0)
		return (nil, "connect: account already exists");
	return (a, nil);
}

# A name that can be a directory's entry.
okname(s: string): int
{
	if(s == "" || s == "." || s == ".." || len s > 255)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] <= ' ' || s[i] == '/' || s[i] == 16r7F)
			return 0;
	return 1;
}

# Connect the account: a module instance of its own, the login, its
# folders and its mailbox (the one it had, or INBOX).  Each time a new
# instance: nothing of a connection that failed is carried to the next.
connect(a: ref Account): string
{
	(im, lerr) := loadimap();
	if(im == nil)
		return lerr;
	im->timeout(iotime);

	# IMAP credentials come from factotum:
	#   proto=pass service=imap dom=<server>
	# Passing nil/nil tells the lib to query factotum itself.
	err := im->open(nil, nil, a.server, a.mode);
	if(err != nil)
		return err;
	a.imap = im;
	a.connected = 1;
	a.downat = 0;
	a.why = nil;

	# Populate folder list first so doselect can deduplicate against it.
	# Soft-fail: connection is still usable without a folder list, but
	# the user gets fewer signals.
	(fl, ferr) := im->folders();
	if(ferr == nil)
		mergefolders(a, fl);
	else if(!im->isup())
		return a.name + ": " + markdown(a, ferr);

	# Best-effort SELECT so the account is usable immediately. A server
	# that returns a different error here still counts as connected —
	# the caller can SELECT a different folder via /accounts/<n>/ctl.
	box := a.currentbox;
	if(box == "")
		box = "INBOX";
	serr := doselect(a, box);
	if(!a.connected)
		return serr;
	return nil;
}

# The account's connection is over: its files answer with the reason
# until the next use connects again.  What was listed stays listed.
markdown(a: ref Account, why: string): string
{
	im := a.imap;
	a.imap = nil;
	a.connected = 0;
	a.downat = sys->millisec() | 1;
	a.why = why;
	if(im != nil)
		im->hangup();
	vers++;
	return why;
}

# After a call: if the connection went with it (a server that stopped
# answering, hung up, or sent more than is taken), the account is down,
# and the error says whose server it was.
check(a: ref Account, err: string): string
{
	if(err != nil && a.imap != nil && !a.imap->isup()) {
		markdown(a, err);
		return a.name + ": " + err;
	}
	return err;
}

# Before a call: the account's connection, made again if it is down.  A
# server that cannot be reached is not tried again at once: the reason
# is given until RETRY has passed.
ensureup(a: ref Account): string
{
	if(a.gone)
		return Enotfound;
	if(a.connected && a.imap != nil && a.imap->isup())
		return nil;
	if(a.connected)
		markdown(a, "connection closed");
	retry := RETRY;
	if(retry > iotime)
		retry = iotime;
	if(a.downat != 0 && sys->millisec() - a.downat < retry)
		return a.name + ": not connected (" + a.why + ")";
	err := connect(a);
	if(err != nil) {
		if(a.connected)
			markdown(a, err);
		a.downat = sys->millisec() | 1;
		a.why = err;
		return a.name + ": not connected (" + err + ")";
	}
	return nil;
}

dosync(a: ref Account): string
{
	err := ensureup(a);
	if(err != nil)
		return "sync: " + err;
	(fl, ferr) := a.imap->folders();
	if(ferr != nil)
		return "sync: folders: " + check(a, ferr);
	mergefolders(a, fl);
	# The mailbox is selected and listed again: its messages are the
	# ones there now.  Only its counts were read, so a message another
	# client had removed stayed listed.
	if(a.currentbox != "") {
		serr := doselect(a, a.currentbox);
		if(serr != nil)
			return "sync: " + serr;
	}
	vers++;
	return nil;
}

# The account, box and message a message file's path names, or why not.
findmsg(path: big): (ref Account, ref MsgCache, string)
{
	a := getacct(ACCT(path));
	if(a == nil)
		return (nil, nil, Enotfound);
	bidx := BOX(path);
	if(bidx >= a.nfolders || a.folders[bidx] == nil)
		return (nil, nil, Enotfound);
	if(a.folders[bidx].name != a.currentbox)
		return (nil, nil, Enotfound);
	m := findmsgbyuid(a, UID(path));
	if(m == nil)
		return (nil, nil, Enotfound);
	return (a, m, nil);
}

# Read one of the per-message field files that is answered from what
# was listed at select.  Returns (data, errstring).
readmsgfield(path: big, ft: int): (array of byte, string)
{
	(nil, m, err) := findmsg(path);
	if(err != nil)
		return (nil, err);
	env := m.msg.envelope;

	case ft {
	Qfrom or Qto or Qcc or Qsubject or Qdate or Qreplyto =>
		return (lineof(envstr(env, ft)), nil);
	Qflags =>
		return (lineof(flagstr(m.msg.flags)), nil);
	Qbodyhtml =>
		# MIME parsing is out of scope for v1. Surface raw if the
		# consumer wants HTML; document the limitation.
		return (nil, nil);
	}
	return (nil, Enotfound);
}

# A message's text, fetched by its UID and kept.
bodyread(a: ref Account, path: big): (array of byte, string)
{
	(nil, m, err) := findmsg(path);
	if(err != nil)
		return (nil, err);
	berr := ensurebody(a, m);
	if(berr != nil)
		return (nil, "fetch: " + berr);
	if(FTYPE(path) == Qbody)
		return (array of byte m.body, nil);
	return (array of byte m.raw, nil);
}

# A message's flags as text, e.g. "\\Seen \\Flagged" (as imap(2)'s
# flagstostring, which needs a connection's module).
flagstr(flags: int): string
{
	s := "";
	if(flags & Imap->FSEEN) s += " \\Seen";
	if(flags & Imap->FANSWERED) s += " \\Answered";
	if(flags & Imap->FFLAGGED) s += " \\Flagged";
	if(flags & Imap->FDELETED) s += " \\Deleted";
	if(flags & Imap->FDRAFT) s += " \\Draft";
	if(s != "")
		s = s[1:];
	return s;
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
	Qreplyto => return env.replyto;
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
# ctl file). Every message is named to the server by its UID.
#

handleboxctl(a: ref Account, path: big, cmd: string): string
{
	bidx := BOX(path);
	if(bidx >= a.nfolders || a.folders[bidx] == nil)
		return Enotfound;
	if(a.folders[bidx].name != a.currentbox)
		return "box not selected (use /accounts/<n>/ctl select)";
	err := ensureup(a);
	if(err != nil)
		return err;
	# the connection may have been made again, and the box with it
	if(bidx >= a.nfolders || a.folders[bidx] == nil || a.folders[bidx].name != a.currentbox)
		return Enotfound;

	cmd = stripnl(cmd);
	(verb, rest) := splitfield(cmd);

	case verb {
	"search" =>
		criteria := stripnl(rest);
		if(criteria == "")
			return "search: criteria required";
		# The answer is UIDs (UID SEARCH): the ones listed here are
		# given.  A line break in the criteria is refused by imap(2);
		# it used to be the commands after it.
		(uids, serr) := a.imap->uidsearch(criteria);
		if(serr != nil)
			return "search: " + check(a, serr);
		s := "";
		for(l := uids; l != nil; l = tl l)
			if(findmsgbyuid(a, big hd l & big 16rFFFFFFFF) != nil)
				s += a.imap->uidstr(hd l) + "\n";
		a.lastsearch = s;
		return nil;

	"archive" =>
		uid := mailparse->strtobig(stripnl(rest));
		if(uid <= big 0)
			return "archive: uid required";
		return movemsg(a, uid, "Archive");

	"move" =>
		(uidstr, after) := splitfield(rest);
		dest := stripnl(after);
		if(uidstr == "" || dest == "")
			return "move: usage: move <uid> <dest-box>";
		uid := mailparse->strtobig(uidstr);
		if(uid <= big 0)
			return "move: bad uid";
		return movemsg(a, uid, dest);

	* =>
		return "unknown box-ctl verb (want: search|archive|move)";
	}
}

# Copy + mark \Deleted. EXPUNGE is deferred — keeps Gmail-style
# semantics where the message is still listable until purged.
# The destination is one of the account's boxes, by the name boxes/
# shows or the server's: any text was sent as the mailbox's name.
movemsg(a: ref Account, uid: big, dest: string): string
{
	m := findmsgbyuid(a, uid);
	if(m == nil)
		return "no such uid";
	(nil, f) := findfolderbydisp(a, dest);
	if(f == nil)
		(nil, f) = findfolder(a, dest);
	if(f == nil)
		return "no such box: " + dest;
	cerr := a.imap->uidcopy(m.msg.uid, f.name);
	if(cerr != nil)
		return "copy: " + check(a, cerr);
	serr := a.imap->uidstore(m.msg.uid, Imap->FDELETED, 1);
	if(serr != nil)
		return "copy ok, store \\Deleted: " + check(a, serr);
	# Update local flags so subsequent reads reflect the change.
	m.msg.flags |= Imap->FDELETED;
	vers++;
	return nil;
}

# Write to <uid>/flags. Body is whitespace-separated flag tokens,
# with optional leading + or - to mark add/remove. Bare flags replace
# the message's flag set (add the listed, clear everything else).
handleflagswrite(a: ref Account, path: big, body: string): string
{
	(nil, nil, ferr) := findmsg(path);
	if(ferr != nil)
		return ferr;
	(add, remove, replace, perr) := mailparse->parseflagswrite(body);
	if(perr != nil)
		return perr;
	err := ensureup(a);
	if(err != nil)
		return err;
	m: ref MsgCache;
	(nil, m, ferr) = findmsg(path);
	if(ferr != nil)
		return ferr;

	if(replace != -1) {
		# Compute add/remove diffs from current flags.
		cur := m.msg.flags;
		add = replace & ~cur;
		remove = cur & ~replace;
	}

	if(add != 0) {
		serr := a.imap->uidstore(m.msg.uid, add, 1);
		if(serr != nil)
			return "store add: " + check(a, serr);
		m.msg.flags |= add;
	}
	if(remove != 0) {
		serr := a.imap->uidstore(m.msg.uid, remove, 0);
		if(serr != nil)
			return "store remove: " + check(a, serr);
		m.msg.flags &= ~remove;
	}
	vers++;
	return nil;
}

# Flag parser lives in mailparse so tests can exercise it without
# spinning up a mail9p instance.

#
# SMTP send paths.
#
#   /mnt/mail/<acct>/compose                — write RFC822 message.
#   /mnt/mail/<acct>/boxes/<box>/<uid>/draft-reply
#     — write a reply body; threading headers (In-Reply-To,
#       References, Subject Re:) are added from the original message.
#
# A message is everything written to the file between its open and its
# close, however many writes that is.  It is sent when the file is
# closed, or when it is read after being written: the read waits for
# the send and returns "sent", or fails with the reason.  A close cannot
# say what happened; the reason is then printed, and compose read on
# its own gives the account's last send.  Each write used to be sent as
# a message of its own, so one longer than a write went out as its
# first piece.
#

Gathering, Sending, Done: con iota;

MAXCOMPOSE: con 32*1024*1024;

Compose: adt {
	fid:	int;
	path:	big;
	a:	ref Account;	# the account it was opened in
	parts:	list of array of byte;
	n:	int;
	bad:	string;		# why it will not be sent
	state:	int;
	result:	string;		# of the send, once Done: nil if it went
};

composes: list of ref Compose;	# the serve loop's alone

findcompose(fid: int): ref Compose
{
	for(l := composes; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

takecompose(fid: int): ref Compose
{
	cf: ref Compose;
	kept: list of ref Compose;
	for(l := composes; l != nil; l = tl l)
		if((hd l).fid == fid)
			cf = hd l;
		else
			kept = hd l :: kept;
	composes = kept;
	return cf;
}

writecompose(gm: ref Tmsg.Write, c: ref Fid)
{
	cf := findcompose(gm.fid);
	if(cf == nil) {
		a := getacct(ACCT(c.path));
		if(a == nil) {
			srv.reply(ref Rmsg.Error(gm.tag, Enotfound));
			return;
		}
		cf = ref Compose(gm.fid, c.path, a, nil, 0, nil, Gathering, nil);
		composes = cf :: composes;
	}
	if(cf.state != Gathering)
		cf.bad = "the message has been sent: open the file again for another";
	else if(cf.bad == nil && gm.offset != big cf.n)
		cf.bad = "a message is written from its start to its end";
	else if(cf.bad == nil && cf.n + len gm.data > MAXCOMPOSE)
		cf.bad = sys->sprint("a message is at most %d bytes", MAXCOMPOSE);
	if(cf.bad != nil) {
		# nothing of a refused message is sent
		cf.parts = nil;
		srv.reply(ref Rmsg.Error(gm.tag, cf.bad));
		return;
	}
	cf.parts = gm.data :: cf.parts;
	cf.n += len gm.data;
	srv.reply(ref Rmsg.Write(gm.tag, len gm.data));
}

readcompose(gm: ref Tmsg.Read, c: ref Fid)
{
	cf := findcompose(gm.fid);
	if(cf == nil || cf.state == Gathering && cf.n == 0 && cf.bad == nil) {
		# nothing written here: compose tells of the account's last
		# send, once those under way are done
		a := getacct(ACCT(c.path));
		if(a != nil && FTYPE(c.path) == Qcompose)
			dispatch(ref Op(OStatus, a, c.path, nil, gm, 0, nil), gm.tag);
		else
			srv.reply(styxservers->readbytes(gm, nil));
		return;
	}
	if(cf.bad != nil) {
		srv.reply(ref Rmsg.Error(gm.tag, cf.bad));
		return;
	}
	case cf.state {
	Gathering =>
		cf.state = Sending;
		dispatch(ref Op(OSend, cf.a, cf.path, nil, gm, 0, cf), gm.tag);
	Sending =>
		srv.reply(ref Rmsg.Error(gm.tag, "the message is being sent"));
	Done =>
		if(cf.result != nil)
			srv.reply(ref Rmsg.Error(gm.tag, cf.result));
		else
			srv.reply(styxservers->readbytes(gm, array of byte "sent\n"));
	}
}

# Send what was written to a compose or draft-reply file.
sendcompose(cf: ref Compose): (array of byte, string)
{
	a := cf.a;
	msg := array[cf.n] of byte;
	o := cf.n;
	for(l := cf.parts; l != nil; l = tl l) {
		p := hd l;
		o -= len p;
		msg[o:] = p;
	}
	cf.parts = nil;
	err: string;
	dst: string;
	# the file is its account's: one disconnected since is not sent by
	if(a.gone || getacct(a.idx) != a)
		err = Enotfound;
	else if(FTYPE(cf.path) == Qcompose)
		(dst, err) = smtpsend(a, string msg, nil, 0);
	else
		(dst, err) = draftreply(a, cf.path, string msg);
	cf.result = err;
	cf.state = Done;
	if(err != nil) {
		notsent(a, cf, err);
		return (nil, err);
	}
	a.lastsend = "sent to " + dst + "\n";
	return (array of byte "sent\n", nil);
}

notsent(a: ref Account, cf: ref Compose, err: string)
{
	cf.result = err;
	cf.state = Done;
	a.lastsend = "not sent: " + err + "\n";
	sys->fprint(stderr, "mail9p: %s: %s: not sent: %s\n", a.name, msgfieldname(FTYPE(cf.path)), err);
}

include_smtp(): (Smtp, string)
{
	smtp := load Smtp Smtp->PATH;
	if(smtp == nil)
		return (nil, "cannot load " + Smtp->PATH);
	smtp->timeout(iotime);
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
	(u, p) := fac->getuserpasswd("proto=pass service=smtp dom=" + hostof(a.smtpserver));
	if(u != nil && p != nil)
		return (u, p, nil);
	(u, p) = fac->getuserpasswd("proto=pass service=imap dom=" + hostof(a.server));
	if(u != nil && p != nil)
		return (u, p, nil);
	return (nil, nil, "no SMTP creds in factotum (tried service=smtp,imap)");
}

# A reply to the message the file belongs to.  It goes to the message's
# Reply-To addresses, or its From's, as the server gave them (the
# replyto and from files show them); it is From the account, whatever
# the body says; and it carries nothing of the original that would be
# a header of its own.  Returns who it went to.
draftreply(a: ref Account, path: big, body: string): (string, string)
{
	(nil, m, ferr) := findmsg(path);
	if(ferr != nil)
		return (nil, ferr);
	env := m.msg.envelope;
	if(env == nil)
		return (nil, "no envelope on message");
	(smtp, lerr) := include_smtp();
	if(smtp == nil)
		return (nil, lerr);

	# The addresses, not the text shown for them: "Name <user@host>"
	# went into RCPT TO whole, and a name is the sender's own text.
	rcpts := env.replytoaddrs;
	if(rcpts == nil)
		rcpts = env.fromaddrs;
	if(rcpts == nil)
		return (nil, "no sender / reply-to on message");
	dst := "";
	for(l := rcpts; l != nil; l = tl l) {
		if(!smtp->okaddr(hd l))
			return (nil, "the message's sender is not an address a reply can go to");
		if(dst != "")
			dst += ", ";
		dst += hd l;
	}

	# The reply is the account's: a From of the writer's choosing was
	# the envelope's sender too.
	if(mailparse->hasheaderfield(body, "From:"))
		return (nil, "a reply is from the account: leave From out");

	subj := env.subject;
	if(subj == "")
		subj = "Re: (no subject)";
	else if(len subj < 3 || str->tolower(subj[0:3]) != "re:")
		subj = "Re: " + subj;

	# Add threading headers and a default Subject. The body the caller
	# wrote may already include its own headers; if so, leave it
	# alone (the consumer knows what they're doing).  What comes from
	# the original is its sender's text, and with a line break in it
	# would be further headers: it is refused.
	hdrs := "";
	if(!mailparse->hasheaderfield(body, "Subject:")) {
		if(!smtp->okheader(subj))
			return (nil, "the message's subject holds a line break: give the reply a Subject");
		hdrs += "Subject: " + subj + "\r\n";
	}
	if(!mailparse->hasheaderfield(body, "To:"))
		hdrs += "To: " + dst + "\r\n";
	if(env.messageid != "" && !smtp->okheader(env.messageid))
		return (nil, "the message's id holds a line break");
	if(env.messageid != "" && !mailparse->hasheaderfield(body, "In-Reply-To:"))
		hdrs += "In-Reply-To: " + env.messageid + "\r\n";
	if(env.messageid != "" && !mailparse->hasheaderfield(body, "References:"))
		hdrs += "References: " + env.messageid + "\r\n";

	final := hdrs + body;
	# Ensure header/body separator if the caller wrote only a body.
	if(!mailparse->bodyhasblankline(final))
		final = hdrs + "\r\n" + body;

	(nil, err) := smtpsend(a, final, rcpts, 1);
	if(err != nil)
		return (nil, err);
	# Mark original \Answered, if the server takes it: by its UID, and
	# only then shown as answered.
	if(ensureup(a) == nil) {
		(nil, m, ferr) = findmsg(path);
		if(ferr == nil && check(a, a.imap->uidstore(m.msg.uid, Imap->FANSWERED, 1)) == nil) {
			m.msg.flags |= Imap->FANSWERED;
			vers++;
		}
	}
	return (dst, nil);
}

# Header-presence and body/blank-line predicates live in mailparse.

# Open SMTP, authenticate via factotum creds, send, close. Recipients
# (`recips`, nil to extract from the To: header in body) and the
# envelope's sender: the credential user if acctfrom, else the address
# of the message's From: header (the address: "Name <user@host>" went
# into MAIL FROM whole), or the credential user if it has none.
# Returns who it was sent to.
smtpsend(a: ref Account, msg: string, recips: list of string, acctfrom: int): (string, string)
{
	(smtp, lerr) := include_smtp();
	if(smtp == nil)
		return (nil, lerr);

	(u, p, cerr) := smtpcreds(a);
	if(cerr != nil)
		return (nil, cerr);

	from := u;
	if(!acctfrom) {
		from = mailparse->trimaddr(mailparse->extractheader(msg, "From:"));
		if(from == "")
			from = u;
	}
	if(recips == nil)
		recips = mailparse->parseaddrlist(mailparse->extractheader(msg, "To:"));
	dst := "";
	for(l := recips; l != nil; l = tl l) {
		if(dst != "")
			dst += ", ";
		dst += hd l;
	}

	# SMTP as the account's IMAP: implicit TLS (465), or STARTTLS (587).
	# Never in clear: the password goes in AUTH PLAIN.
	mode := Smtp->IMPLICIT_TLS;
	if(a.mode == Imap->STARTTLS)
		mode = Smtp->STARTTLS;
	(ok, oerr) := smtp->authopen(u, p, a.smtpserver, mode);
	if(ok < 0)
		return (nil, "smtp authopen: " + oerr);

	# sendmail expects each list element to be a logical line block.
	# Pass the whole message as one block; the lib splits on \n.
	(sok, serr) := smtp->sendmail(from, recips, nil, msg :: nil);
	smtp->close();
	if(sok < 0)
		return (nil, "smtp sendmail: " + serr);
	return (dst, nil);
}

# Header extraction and address-list parsing live in mailparse.

acctstatus(a: ref Account): string
{
	s := "connected " + a.server;
	if(!a.connected) {
		s = "disconnected " + a.server;
		if(a.why != nil)
			s += " (" + oneline(a.why) + ")";
	}
	if(a.currentbox != "")
		s += " box=" + a.currentbox;
	if(a.mbox != nil) {
		s += sys->sprint(" exists=%d unseen=%d", a.mbox.exists, a.mbox.unseen);
		if(len a.msgs != a.mbox.exists)
			s += sys->sprint(" listed=%d", len a.msgs);
	}
	return s + "\n";
}

oneline(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n' || s[i] == '\r')
			s[i] = ' ';
	return s;
}

#
# /accounts/<name>/ctl write commands.
#
#   select <mailbox>        SELECT a mailbox; updates currentbox/mbox/msgs.
#   sync                    The folders and the mailbox's messages again.
#

handleacctctl(a: ref Account, cmd: string): string
{
	cmd = stripnl(cmd);
	(verb, rest) := splitfield(cmd);

	case verb {
	"select" =>
		box := stripnl(rest);
		if(box == "")
			return "select: mailbox required";
		err := ensureup(a);
		if(err != nil)
			return err;
		# Accept the 9P display name (what boxes/ shows, with ':' for the
		# IMAP '/' delimiter) or the raw IMAP name. Map the former back to
		# the real IMAP name before issuing SELECT.
		(nil, bf) := findfolderbydisp(a, box);
		if(bf != nil)
			box = bf.name;
		return doselect(a, box);
	"sync" =>
		return dosync(a);
	* =>
		return "unknown account-ctl verb (want: select|sync)";
	}
}

# Select a mailbox and list its messages.  The account's box and list
# change only when both are had: the server's selected mailbox and
# currentbox are the same one, or the connection is given up, since
# every operation names a message by its UID in the selected mailbox.
doselect(a: ref Account, box: string): string
{
	(mbox, err) := a.imap->select(box);
	if(err != nil) {
		err = check(a, err);
		# a refused SELECT leaves none selected (RFC 3501 6.3.1):
		# the one before is selected again
		if(a.connected && a.currentbox != "") {
			(nil, e2) := a.imap->select(a.currentbox);
			if(e2 != nil)
				markdown(a, e2);
		}
		return "select: " + err;
	}
	# The newest MAXMSGS are listed.  The server's count sized an
	# array: with 2^31 messages said to exist it could not be made,
	# which ended the server.
	msgs: array of ref MsgCache;
	if(mbox.exists > 0) {
		first := 1;
		if(mbox.exists > MAXMSGS)
			first = mbox.exists - MAXMSGS + 1;
		(l, ferr) := a.imap->msglist(first, mbox.exists);
		if(ferr != nil) {
			markdown(a, ferr);
			return "select ok, msglist: " + a.name + ": " + ferr;
		}
		msgs = msglisttoarray(l);
	}
	# A mailbox whose UIDVALIDITY has changed is not the one its UIDs
	# were read in (RFC 3501 2.3.1.1): it gets a new place among the
	# boxes, and files open in the old one name nothing.
	i := findfolderidx(a, mbox.name);
	if(i >= 0 && a.folders[i].uidvalidity != 0 && a.folders[i].uidvalidity != mbox.uidvalidity) {
		a.folders[i] = nil;
		i = -1;
	}
	# Ensure the folder appears in the cached folder list. Servers
	# sometimes report SELECTable mailboxes that LIST omitted.
	if(i < 0) {
		appendfolder(a, mbox.name);
		i = findfolderidx(a, mbox.name);
	}
	if(i >= 0)
		a.folders[i].uidvalidity = mbox.uidvalidity;
	a.msgs = msgs;
	a.mbox = mbox;
	a.currentbox = mbox.name;
	a.lastsearch = "";
	vers++;
	return nil;
}

findfolderidx(a: ref Account, name: string): int
{
	(i, nil) := findfolder(a, name);
	return i;
}

# The messages listed, in the server's order, MAXMSGS of them at most
# whatever the server sent.
msglisttoarray(l: list of ref Imap->Msg): array of ref MsgCache
{
	n := 0;
	for(p := l; p != nil && n < MAXMSGS; p = tl p)
		if(hd p != nil && (hd p).uid != 0)
			n++;
	a := array[n] of ref MsgCache;
	i := 0;
	for(p = l; p != nil && i < n; p = tl p)
		if(hd p != nil && (hd p).uid != 0)
			a[i++] = ref MsgCache(hd p, 0, "", "");
	return a;
}

# Linear UID lookup over the cached message list. Returns nil if absent.
findmsgbyuid(a: ref Account, uid: big): ref MsgCache
{
	msgs := a.msgs;
	if(msgs == nil)
		return nil;
	u := int uid;
	for(i := 0; i < len msgs; i++)
		if(msgs[i] != nil && msgs[i].msg.uid == u)
			return msgs[i];
	return nil;
}

# Lazily fetch the full RFC822 message body and cache it on m. Returns
# any IMAP error from the FETCH. Idempotent: subsequent calls noop.
# The message is asked for by its UID: by the sequence number it had at
# select, it was whichever message had that number now.
ensurebody(a: ref Account, m: ref MsgCache): string
{
	if(m.bodyset)
		return nil;
	err := ensureup(a);
	if(err != nil)
		return err;
	(raw, ferr) := a.imap->uidfetch(m.msg.uid);
	if(ferr != nil)
		return check(a, ferr);
	m.raw = raw;
	m.body = mailparse->splitbody(raw);
	m.bodyset = 1;
	return nil;
}

uidpresent(a: ref Account, uid: big): int
{
	return findmsgbyuid(a, uid) != nil;
}

# The mount has gone.  Each account is logged out, not for long, and
# everything of the server ends; the sessions, their connections and
# the processes behind them used to stay.
shutdown()
{
	n := 0;
	done := chan[MAXACCTS] of int;
	for(i := 0; i < naccounts; i++) {
		a := accounts[i];
		if(a != nil) {
			a.gone = 1;
			spawn bye(a, done);
			n++;
		}
	}
	tm := chan[1] of int;
	spawn alarm(tm, 3000);
	while(n > 0) alt {
	<-done =>
		n--;
	<-tm =>
		n = 0;
	}
	srv.t.c <-= nil;
	fd := sys->open("/prog/" + string sys->pctl(0, nil) + "/ctl", Sys->OWRITE);
	if(fd == nil)
		fd = sys->open("#p/" + string sys->pctl(0, nil) + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
	exit;
}

alarm(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# Log an account out, after what it is doing.
bye(a: ref Account, done: chan of int)
{
	a.lk <-= 1;
	im := a.imap;
	a.imap = nil;
	a.connected = 0;
	{
		if(im != nil)
			im->logout();
	} exception {
	"*" =>
		;
	}
	<-a.lk;
	if(done != nil)
		done <-= 1;
}

#
# Helpers
#

ensuredir(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil)
		return;
	fd = sys->create(path, Sys->OREAD, 8r755 | Sys->DMDIR);
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

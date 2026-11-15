implement Msg9p;

#
# msg9p - 9P file server for the Veltro message layer
#
# Presents message sources (email, telegram, etc.) as a unified filesystem
# at /mnt/msg/. Each source implements the MsgSrc interface and is loaded
# dynamically via the ctl file.
#
# Filesystem:
#   /mnt/msg/
#   ├── ctl         (rw)  "register <name> <dispath> <config...>"
#   ├── notify      (r)   Blocking read: returns next notification
#   ├── status      (r)   Summary of all sources
#   ├── draft       (w)   Create an immutable pending reply proposal
#   ├── flag        (w)   "<src> <origid> <flag>" (separate capability)
#   ├── pending     (r)   Trusted controller view of pending requests: a line
#   │                     "id src origid len body", then tab-indented lines
#   │                     "To:" and "Subject:" saying whose message, about
#   │                     what, the reply answers (as the source said when the
#   │                     draft was made)
#   ├── approve     (w)   Trusted one-shot approval: "approve <id>"
#   ├── deny        (w)   Trusted one-shot denial: "deny <id>"
#   └── sources/    (dir) Per-source directories (future expansion)
#
# The notify file is the key mechanism: reading it BLOCKS until a
# notification arrives from any registered source. This is the standard
# Inferno event-file pattern.
#
# Usage:
#   msg9p                        Start, mount at /mnt/msg
#   msg9p -m /mnt/msg              Custom mount point
#   msg9p -D                     9P debug tracing
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

include "msgsrc.m";

Msg9p: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

# Qid layout
Qroot, Qctl, Qnotify, Qstatus, Qdraft, Qflag, Qpending, Qapprove, Qdeny, Qsrcdir: con iota;

# Registered source info
SrcInfo: adt {
	name:    string;      # "email", "telegram", etc.
	path:    string;      # dis path
	mod:     MsgSrc;      # loaded module
	stopc:   chan of int;  # stop channel for watch goroutine
};

# Pending reader waiting on notify
PendingRead: adt {
	tag:  int;
	fid:  int;
	count: int;
};

# A reply awaiting approval. The approver decides on what is shown, so
# the request keeps whose message it answers and its subject, asked of
# the source when the draft was made, and the same is asked again before
# it is sent: a source may number its messages anew (a mailbox after an
# expunge), and an id alone then names another message, from someone else.
PendingSend: adt {
	id: int;
	data: string;
	known: int;		# the source said what the message is
	towhom: string;		# its sender
	subject: string;
	thread: string;		# its own id for the message, if it has one
};

# A draft whose message has been looked up, on its way to the serve loop.
Drafted: adt {
	tag:	int;
	n:	int;
	ps:	ref PendingSend;
	err:	string;
};
draftc: chan of ref Drafted;

stderr: ref Sys->FD;
user: string;
mountpt := "/mnt/msg";

# Registered sources
sources: list of ref SrcInfo;

# Notification aggregation channel (all sources feed into this)
notifychan: chan of string;

# Pending readers blocked on /mnt/msg/notify
pendingReaders: list of ref PendingRead;

# Queued notifications when no reader is waiting
notifyq: list of string;
MAXQ: con 64;
ndropped := 0;		# notifications dropped with the queue full
MAXFIELD: con 256;	# characters of one header field in a notification
MAXPENDING: con 16;
pendingSends: list of ref PendingSend;
nextSendID := 1;

# Global reference to the styx server for deferred replies
gsrv: ref Styxserver;

nomod(s: string)
{
	sys->fprint(stderr, "msg9p: can't load %s: %r\n", s);
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

	while((o := arg->opt()) != 0)
		case o {
		'D' =>	styxservers->traceset(1);
		'm' =>	mountpt = arg->earg();
		* =>
			sys->fprint(stderr, "usage: msg9p [-D] [-m mountpt]\n");
			raise "fail:usage";
		}
	arg = nil;

	notifychan = chan of string;
	draftc = chan of ref Drafted;

	sys->pctl(Sys->FORKFD, nil);

	user = readfile("/dev/user");
	if(user == nil)
		user = "inferno";

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(stderr, "msg9p: can't create pipe: %r\n");
		raise "fail:pipe";
	}

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	fds[0] = nil;
	gsrv = srv;

	pidc := chan of int;
	spawn serveloop(tchan, srv, pidc, navops);
	<-pidc;

	# Ensure mount point exists
	ensuredir(mountpt);

	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(stderr, "msg9p: mount failed: %r\n");
		raise "fail:mount";
	}
}

# === Navigator (directory traversal) ===

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(int n.path);
		Walk =>
			walkto(n);
		Readdir =>
			doreaddir(n, int n.path);
		}
	}
}

walkto(n: ref Navop.Walk)
{
	parent := int n.path;

	case parent {
	Qroot =>
		case n.name {
		"ctl" =>
			n.path = big Qctl;
			n.reply <-= dirgen(int n.path);
		"notify" =>
			n.path = big Qnotify;
			n.reply <-= dirgen(int n.path);
		"status" =>
			n.path = big Qstatus;
			n.reply <-= dirgen(int n.path);
		"draft" =>
			n.path = big Qdraft;
			n.reply <-= dirgen(int n.path);
		"flag" =>
			n.path = big Qflag;
			n.reply <-= dirgen(int n.path);
		"pending" =>
			n.path = big Qpending;
			n.reply <-= dirgen(int n.path);
		"approve" =>
			n.path = big Qapprove;
			n.reply <-= dirgen(int n.path);
		"deny" =>
			n.path = big Qdeny;
			n.reply <-= dirgen(int n.path);
		"sources" =>
			n.path = big Qsrcdir;
			n.reply <-= dirgen(int n.path);
		* =>
			n.reply <-= (nil, Enotfound);
		}
	* =>
		n.reply <-= (nil, Enotfound);
	}
}

dirgen(path: int): (ref Sys->Dir, string)
{
	d := ref sys->zerodir;
	d.uid = user;
	d.gid = user;
	d.muid = user;
	d.atime = 0;
	d.mtime = 0;

	case path {
	Qroot =>
		d.name = ".";
		d.mode = Sys->DMDIR | 8r555;
		d.qid.qtype = Sys->QTDIR;
	Qctl =>
		d.name = "ctl";
		d.mode = 8r666;
	Qnotify =>
		d.name = "notify";
		d.mode = 8r444;
	Qstatus =>
		d.name = "status";
		d.mode = 8r444;
	Qdraft =>
		d.name = "draft";
		d.mode = 8r222;
	Qflag =>
		d.name = "flag";
		d.mode = 8r222;
	Qpending =>
		d.name = "pending";
		d.mode = 8r444;
	Qapprove =>
		d.name = "approve";
		d.mode = 8r222;
	Qdeny =>
		d.name = "deny";
		d.mode = 8r222;
	Qsrcdir =>
		d.name = "sources";
		d.mode = Sys->DMDIR | 8r555;
		d.qid.qtype = Sys->QTDIR;
	* =>
		return (nil, Enotfound);
	}

	d.qid.path = big path;
	return (d, nil);
}

doreaddir(n: ref Navop.Readdir, path: int)
{
	case path {
	Qroot =>
		entries := array[] of {Qctl, Qnotify, Qstatus, Qdraft, Qflag, Qpending, Qapprove, Qdeny, Qsrcdir};
		for(i := 0; i < len entries; i++) {
			if(i >= n.offset) {
				(d, err) := dirgen(entries[i]);
				if(d != nil)
					n.reply <-= (d, err);
			}
		}
	Qsrcdir =>
		# Currently flat — no per-source subdirectories in navigator
		;
	}
	n.reply <-= (nil, nil);
}

# === Main serve loop ===

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver, pidc: chan of int,
	navops: chan of ref Navop)
{
	pidc <-= sys->pctl(0, nil);

Serve:
	for(;;) alt {
	gm := <-tchan =>
		if(gm == nil)
			break Serve;

		pick m := gm {
		Readerror =>
			sys->fprint(stderr, "msg9p: read error: %s\n", m.error);
			break Serve;

		Read =>
			(c, err) := srv.canread(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				continue;
			}

			if(c.qtype & Sys->QTDIR) {
				srv.read(m);
				continue;
			}

			path := int c.path;

			case path {
			Qctl =>
				data := array of byte gensrclist();
				srv.reply(styxservers->readbytes(m, data));

			Qstatus =>
				data := array of byte genstatus();
				srv.reply(styxservers->readbytes(m, data));

			Qpending =>
				data := array of byte genpending();
				srv.reply(styxservers->readbytes(m, data));

			Qnotify =>
				# Blocking read: if we have queued notifications,
				# reply immediately. Otherwise, park the reader.
				# A stream: each read is the next notification whatever
				# its offset. Read by offset, a second read on one fd
				# got the tail of the next notification, or nothing,
				# and that notification was gone.
				if(notifyq != nil) {
					# Dequeue oldest (last in reversed list)
					text := dequeue();
					srv.reply(ref Rmsg.Read(m.tag, cutto(array of byte text, m.count)));
				} else {
					# Park — do NOT reply. Reply happens when
					# notification arrives (see notifychan handler).
					pendingReaders = ref PendingRead(m.tag, c.fid, m.count) :: pendingReaders;
				}

			* =>
				srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			}

		Write =>
			(c, merr) := srv.canwrite(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, merr));
				continue;
			}

			path := int c.path;
			data := string m.data;
			# Strip trailing newline
			if(len data > 0 && data[len data - 1] == '\n')
				data = data[:len data - 1];

			case path {
			Qctl =>
				cerr := handlectl(data);
				if(cerr != nil)
					srv.reply(ref Rmsg.Error(m.tag, cerr));
				else
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qdraft =>
				(dsrc, perr) := checkdraft(data);
				if(perr != nil)
					srv.reply(ref Rmsg.Error(m.tag, perr));
				else if(dsrc == nil)
					srv.reply(ref Rmsg.Write(m.tag, len m.data));	# queued already
				else
					spawn drafter(dsrc, m.tag, len m.data, data);
			Qflag =>
				(nil, fargs) := sys->tokenize(data, " \t\r\n");
				ferr := doflag(fargs);
				if(ferr != nil)
					srv.reply(ref Rmsg.Error(m.tag, ferr));
				else
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qapprove =>
				(id, aerr) := approvalid(data, "approve");
				if(aerr != nil)
					srv.reply(ref Rmsg.Error(m.tag, aerr));
				else {
					ps := takepending(id);
					if(ps == nil)
						srv.reply(ref Rmsg.Error(m.tag, "approve: unknown or consumed request"));
					else
						spawn doapproved(srv, m.tag, len m.data, ps);
				}
			Qdeny =>
				(id, derr) := approvalid(data, "deny");
				if(derr != nil)
					srv.reply(ref Rmsg.Error(m.tag, derr));
				else if(takepending(id) == nil)
					srv.reply(ref Rmsg.Error(m.tag, "deny: unknown or consumed request"));
				else
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}

		Clunk =>
			# Cancel any pending reads for this fid
			c := srv.getfid(m.fid);
			if(c != nil && int c.path == Qnotify)
				cancelpending(m.fid);
			srv.clunk(m);

		Flush =>
			# a reader that has given up is not waiting: left parked,
			# it was given the next notification, which nobody read
			cancelflushed(m.oldtag);
			srv.default(gm);

		* =>
			srv.default(gm);
		}

	notification := <-notifychan =>
		# Notification from a source. Wake a pending reader or queue.
		if(pendingReaders != nil) {
			# Wake oldest reader (last in list since we prepend)
			pr := lastpending();
			pendingReaders = droplast(pendingReaders);
			srv.reply(ref Rmsg.Read(pr.tag, cutto(array of byte notification, pr.count)));
		} else {
			# Queue (bounded)
			enqueue(notification);
		}

	d := <-draftc =>
		derr := d.err;
		if(derr == nil)
			derr = queuedraft(d.ps);
		if(derr != nil)
			srv.reply(ref Rmsg.Error(d.tag, derr));
		else
			srv.reply(ref Rmsg.Write(d.tag, d.n));
	}

	navops <-= nil;
}

# === Ctl command handling ===

# register <name> <dispath> [config key=value ...]
# unregister <name>
handlectl(data: string): string
{
	# Send is multi-line — header on first line, body on the rest.
	# Splitting on the first \n preserves bodies that contain whitespace.
	cmdline := data;
	body := "";
	for(i := 0; i < len data; i++)
		if(data[i] == '\n') {
			cmdline = data[0:i];
			body = data[i+1:];
			break;
		}

	(n, toks) := sys->tokenize(cmdline, " \t");
	if(n < 1)
		return Ebadarg;

	cmd := str->tolower(hd toks);
	toks = tl toks;

	case cmd {
	"register" =>
		return doregister(toks);
	"unregister" =>
		if(toks == nil)
			return "usage: unregister <name>";
		return dounregister(hd toks);
	"send" =>
		# send <srcname> <recipient>
		# <body...>
		# Dispatches to MsgSrc.send on the named source. Generic (used
		# by SMS now, more sources planned — same verb).
		if(toks == nil || tl toks == nil)
			return "usage: send <srcname> <recipient>\\n<body>";
		return dosend(hd toks, hd tl toks, body);
	"flag" =>
		# flag <srcname> <origid> <word>
		# Generic flag/setflag across sources. Protocol-agnostic: sources
		# with no flag semantics (SMS) treat it as a no-op rather than
		# erroring. See docs/MESSAGE-INTEGRATION.md.
		return doflag(toks);
	* =>
		return "unknown command: " + cmd;
	}
}

# === reply approval: queue immutable draft; trusted endpoint commits once ===
#
# /mnt/msg/draft (write-only) format:  <srcname>\n<origid>\n<body...>
# Generic, protocol-agnostic proposal: the writer drafts a threaded reply by
# source and original id. Nothing is sent until a trusted controller consumes
# the immutable pending request through /mnt/msg/approve.

# What a writer that got the form wrong needs to know: an agent drafting a
# new email tried it here, again and again, from "unsafe source name".
DRAFTHOW: con " (a draft is a reply to a message here: its first line is the message's source and its second the message's id, as /mnt/msg/status lists them, then the body; a new message to someone cannot be drafted here)";

# A draft as written: the source it names, or nil with no error if the
# same draft is queued already.
checkdraft(data: string): (ref SrcInfo, string)
{
	(src, verr) := validreply(data);
	if(verr != nil)
		return (nil, verr);
	count := 0;
	for(p := pendingSends; p != nil; p = tl p) {
		count++;
		if((hd p).data == data)
			return (nil, nil);
	}
	if(count >= MAXPENDING)
		return (nil, sys->sprint("draft: approval queue full (%d replies await approval)", count));
	return (src, nil);
}

# Ask the source what the draft answers, away from the serve loop (a
# mail source asks its server), and hand the request to the loop.
drafter(src: ref SrcInfo, tag, n: int, data: string)
{
	(nil, r1) := splitfirst(data, '\n');
	(origid, nil) := splitfirst(r1, '\n');
	origid = msgstrip(origid);
	d := ref Drafted(tag, n, ref PendingSend(0, data, 0, "", "", ""), nil);
	{
		(msg, err) := src.mod->fetch(origid);
		if(msg != nil) {
			d.ps.known = 1;
			d.ps.towhom = msg.sender;
			d.ps.subject = msg.subject;
			d.ps.thread = msg.threadid;
		} else if(src.mod->capabilities() & MsgSrc->CAP_FETCH)
			d.err = "draft: " + src.name + " has no message " + origid +
				" (" + err + ")" + DRAFTHOW;
	} exception e {
	"*" =>
		d.err = "draft: " + src.name + ": " + e;
	}
	draftc <-= d;
}

queuedraft(ps: ref PendingSend): string
{
	count := 0;
	for(p := pendingSends; p != nil; p = tl p) {
		count++;
		if((hd p).data == ps.data)
			return nil;
	}
	if(count >= MAXPENDING)
		return sys->sprint("draft: approval queue full (%d replies await approval)", count);
	ps.id = nextSendID++;
	pendingSends = ps :: pendingSends;
	return nil;
}

validreply(data: string): (ref SrcInfo, string)
{
	(src, r1) := splitfirst(data, '\n');
	(origid, nil) := splitfirst(r1, '\n');
	src = msgstrip(src);
	origid = msgstrip(origid);
	if(src == "" || origid == "")
		return (nil, "draft: want <srcname>\\n<origid>\\n<body>" + DRAFTHOW);
	if(!safesrcname(src))
		return (nil, "draft: unsafe source name" + DRAFTHOW);
	if(hascontrol(origid))
		return (nil, "draft: unsafe message id" + DRAFTHOW);
	for(sl := sources; sl != nil; sl = tl sl)
		if((hd sl).name == src) {
			# a source that cannot reply has nothing to approve
			if(((hd sl).mod->capabilities() & MsgSrc->CAP_REPLY) == 0)
				return (nil, "draft: " + src + " cannot send a reply");
			return (hd sl, nil);
		}
	return (nil, "draft: no source: " + src + DRAFTHOW);
}

genpending(): string
{
	result := "";
	for(p := pendingSends; p != nil; p = tl p) {
		ps := hd p;
		(src, r1) := splitfirst(ps.data, '\n');
		(origid, body) := splitfirst(r1, '\n');
		result += sys->sprint("%d %s %s %d %s\n", ps.id, msgstrip(src),
			msgstrip(origid), len body, pendingescape(body));
		# whose message it answers: that is who the reply goes to
		if(ps.known) {
			result += "\tTo: " + previewfield(ps.towhom, MAXFIELD) + "\n";
			result += "\tSubject: " + previewfield(ps.subject, MAXFIELD) + "\n";
		} else
			result += "\tTo: (not known: " + msgstrip(src) +
				" cannot say whose message " + cleanfield(msgstrip(origid)) + " is)\n";
	}
	return result;
}

# Lossless single-line rendering for the trusted approval surface.  Length
# alone made equal-sized proposals indistinguishable to the approver.
pendingescape(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++) {
		case c := s[i] {
		'\\' => out += "\\\\";
		'\n' => out += "\\n";
		'\r' => out += "\\r";
		'\t' => out += "\\t";
		* =>
			if(c < ' ' || c == 16r7f)
				out += sys->sprint("\\x%.2ux", c);
			else
				out += s[i:i+1];
		}
	}
	return out;
}

approvalid(data, verb: string): (int, string)
{
	(nil, toks) := sys->tokenize(data, " \t");
	if(toks == nil)
		return (-1, verb + ": want " + verb + " <id>");
	if(hd toks == verb)
		toks = tl toks;
	if(toks == nil || tl toks != nil)
		return (-1, verb + ": want " + verb + " <id>");
	(id, rest) := str->toint(hd toks, 10);
	if(id <= 0 || rest != "")
		return (-1, verb + ": invalid id");
	return (id, nil);
}

takepending(id: int): ref PendingSend
{
	found: ref PendingSend;
	kept: list of ref PendingSend;
	for(p := pendingSends; p != nil; p = tl p) {
		ps := hd p;
		if(ps.id == id && found == nil)
			found = ps;
		else
			kept = ps :: kept;
	}
	pendingSends = kept;
	return found;
}

doapproved(srv: ref Styxserver, tag, datalen: int, ps: ref PendingSend)
{
	rerr := handlereply(ps);
	if(rerr != nil)
		srv.reply(ref Rmsg.Error(tag, rerr));
	else
		srv.reply(ref Rmsg.Write(tag, datalen));
}

handlereply(ps: ref PendingSend): string
{
	data := ps.data;
	(src, r1) := splitfirst(data, '\n');
	(origid, body) := splitfirst(r1, '\n');
	src = msgstrip(src);
	origid = msgstrip(origid);
	if(src == "" || origid == "")
		return "reply: want <srcname>\\n<origid>\\n<body>";
	if(!safesrcname(src))
		return "reply: unsafe source name";
	if(hascontrol(origid))
		return "reply: unsafe message id";
	for(sl := sources; sl != nil; sl = tl sl)
		if((hd sl).name == src) {
			mod := (hd sl).mod;
			# The approval was given for a reply to the message shown.
			# If the id now names another, nothing is sent.
			if(ps.known) {
				(msg, err) := mod->fetch(origid);
				if(msg == nil)
					return "reply: not sent: message " + origid + " of " + src +
						" is no longer there (" + err + ")";
				if(msg.sender != ps.towhom || msg.subject != ps.subject ||
				   msg.threadid != ps.thread)
					return "reply: not sent: message " + origid + " of " + src +
						" is no longer the one this reply was drafted against (it was from " +
						previewfield(ps.towhom, MAXFIELD) + ", it is from " +
						previewfield(msg.sender, MAXFIELD) + ")";
			}
			return mod->reply(origid, body);
		}
	return "reply: no source: " + src;
}

splitfirst(s: string, c: int): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return (s[0:i], s[i+1:]);
	return (s, "");
}

msgstrip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r' || s[j-1] == '\n'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}

# Find a registered source by name and dispatch a Message through it.
# Recipient + body are wrapped in a Message; sender/timestamp are
# left for the source to fill in (it knows the protocol).
dosend(srcname, recipient, body: string): string
{
	for(sl := sources; sl != nil; sl = tl sl) {
		s := hd sl;
		if(s.name == srcname) {
			m := ref MsgSrc->Message;
			m.source = srcname;
			m.recipient = recipient;
			m.body = body;
			return s.mod->send(m);
		}
	}
	return "source not registered: " + srcname;
}

# flag <srcname> <origid> <word> — map a friendly flag word onto
# MsgSrc.setflag. "seen" marks read (clears the unread bit). Sources with no
# flag semantics (SMS) implement setflag as an idempotent no-op.
doflag(args: list of string): string
{
	if(args == nil || tl args == nil || tl tl args == nil || tl tl tl args != nil)
		return "usage: flag <src> <origid> <seen|unseen|flagged|unflagged|urgent|draft>";
	srcname := hd args;
	origid := hd tl args;
	word := str->tolower(hd tl tl args);
	if(!safesrcname(srcname))
		return "flag: unsafe source name";
	if(hascontrol(origid))
		return "flag: unsafe message id";

	flag := 0;
	add := 0;
	case word {
	"seen" =>      flag = MsgSrc->FUNREAD;  add = 0;	# read = clear unread
	"unseen" =>    flag = MsgSrc->FUNREAD;  add = 1;
	"flagged" =>   flag = MsgSrc->FFLAGGED; add = 1;
	"unflagged" => flag = MsgSrc->FFLAGGED; add = 0;
	"urgent" =>    flag = MsgSrc->FURGENT;  add = 1;
	"unurgent" =>  flag = MsgSrc->FURGENT;  add = 0;
	"draft" =>     flag = MsgSrc->FDRAFT;   add = 1;
	"undraft" =>   flag = MsgSrc->FDRAFT;   add = 0;
	* =>
		return "flag: unknown word '" + word + "' (want seen|unseen|flagged|unflagged|urgent|draft)";
	}

	for(sl := sources; sl != nil; sl = tl sl)
		if((hd sl).name == srcname)
			return (hd sl).mod->setflag(origid, flag, add);
	return "flag: no source: " + srcname;
}

doregister(args: list of string): string
{
	if(args == nil || tl args == nil)
		return "usage: register <name> <dispath> [config...]";

	srcname := hd args;
	dispath := hd tl args;
	if(!safesrcname(srcname))
		return "register: unsafe source name";
	if(!safedispath(dispath))
		return "register: unsafe module path";

	# Check for duplicate
	for(sl := sources; sl != nil; sl = tl sl)
		if((hd sl).name == srcname)
			return "source already registered: " + srcname;

	# Build config string from remaining tokens
	config := "";
	for(a := tl tl args; a != nil; a = tl a) {
		if(config != "")
			config += " ";
		config += hd a;
	}

	# Load the source module
	mod := load MsgSrc dispath;
	if(mod == nil)
		return sys->sprint("cannot load %s: %r", dispath);

	# Initialize
	err := mod->init(config);
	if(err != nil)
		return "init " + srcname + ": " + err;

	# Start watch goroutine. The stop is buffered: unregister tells it from
	# the serve loop, while the wrapper may be waiting for that same loop
	# to take a notification, and each then waited for the other for good.
	stopc := chan[1] of int;
	src := ref SrcInfo(srcname, dispath, mod, stopc);
	sources = src :: sources;

	spawn watchwrapper(src, notifychan, stopc);

	sys->fprint(stderr, "msg9p: registered source '%s' from %s\n", srcname, dispath);
	return nil;
}

safesrcname(s: string): int
{
	if(s == nil || s == "" || s == "." || s == "..")
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')
			continue;
		return 0;
	}
	return 1;
}

safedispath(path: string): int
{
	if(path == nil || path == "" || path[0] != '/' || !hassuffix(path, ".dis"))
		return 0;
	if(hascontrol(path))
		return 0;

	part := "";
	for(i := 1; i <= len path; i++) {
		if(i == len path || path[i] == '/') {
			if(part == "" || part == "." || part == "..")
				return 0;
			part = "";
			continue;
		}
		part[len part] = path[i];
	}
	return 1;
}

hascontrol(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] <= ' ' || s[i] == 16r7f)
			return 1;
	return 0;
}

hassuffix(s, suffix: string): int
{
	return len s >= len suffix && s[len s - len suffix:] == suffix;
}

dounregister(srcname: string): string
{
	newsources: list of ref SrcInfo;
	found := 0;
	for(sl := sources; sl != nil; sl = tl sl) {
		src := hd sl;
		if(src.name == srcname) {
			alt {
			src.stopc <-= 1 =>	# signal watch to stop
				;
			* =>
				;
			}
			src.mod->close();
			found = 1;
		} else
			newsources = src :: newsources;
	}
	if(!found)
		return "source not found: " + srcname;
	sources = newsources;
	sys->fprint(stderr, "msg9p: unregistered source '%s'\n", srcname);
	return nil;
}

# Watch goroutine: bridges MsgSrc.watch() notifications to the aggregated
# notifychan as formatted text strings.
watchwrapper(src: ref SrcInfo, nchan: chan of string, stopc: chan of int)
{
	updates := chan of ref MsgSrc->Notification;
	relaystop := chan[1] of int;	# a source in a read of its own is not listening

	# Start the source's watch in a sub-goroutine
	spawn sourcewatcher(src, updates, relaystop);

	for(;;) alt {
	n := <-updates =>
		if(n == nil)
			return;
		text := formatnotification(src.name, n);
		nchan <-= text;

	<-stopc =>
		relaystop <-= 1;
		return;
	}
}

sourcewatcher(src: ref SrcInfo, updates: chan of ref MsgSrc->Notification,
	stop: chan of int)
{
	src.mod->watch(updates, stop);
}

# Deterministic triage from the structured message fields (flags, headers,
# sender) — NO LLM and no body-keyword guessing. This is the cheap pre-filter
# that decides whether a message is worth waking the agent at all. Verdicts:
#   ignore  — routine/bulk (newsletters, automated, no-reply): never wake
#   context — low-signal/FYI (already-read mail): fold in silently, no wake
#   wake    — directed/unread mail: wake the agent to triage/respond
#   preempt — urgent (FURGENT flag): wake and jump the queue
# The verdict rides in the notification ("Triage: <verdict>"); msgwatch routes
# on it so ignore/context never reach the LLM.
triageverdict(m: ref MsgSrc->Message): string
{
	if(m.flags & MsgSrc->FURGENT)
		return "preempt";
	if(isbulk(m))
		return "ignore";
	if(m.flags & MsgSrc->FFLAGGED)
		return "wake";
	if((m.flags & MsgSrc->FUNREAD) && m.sender != nil && m.sender != "")
		return "wake";
	return "context";
}

# Bulk/automated detection from structured fields (headers + sender), not body.
isbulk(m: ref MsgSrc->Message): int
{
	h := str->tolower(m.headers);
	if(hassub(h, "list-unsubscribe") || hassub(h, "precedence: bulk") ||
	   hassub(h, "precedence:bulk") || hassub(h, "auto-submitted"))
		return 1;
	s := str->tolower(m.sender);
	if(hassub(s, "no-reply") || hassub(s, "noreply") || hassub(s, "donotreply") ||
	   hassub(s, "newsletter") || hassub(s, "notifications@") || hassub(s, "mailer-daemon"))
		return 1;
	return 0;
}

hassub(hay, needle: string): int
{
	if(needle == "" || len needle > len hay)
		return 0;
	for(i := 0; i <= len hay - len needle; i++)
		if(hay[i:i+len needle] == needle)
			return 1;
	return 0;
}

# Format a notification as a structured text message suitable for
# injection into the Meta Agent's conversation.
formatnotification(srcname: string, n: ref MsgSrc->Notification): string
{
	# Every field is bounded: a notification is one read's worth, and one
	# with a 20K subject did not fit a 9P reply, so its reader got an
	# error and the notification was gone.
	if(n.kind == "error")
		return "[Message error — " + cleanfield(srcname) + "]\nDetail: " + previewfield(n.detail, 2*MAXFIELD);

	if(n.msg == nil)
		return "[Message " + cleanfield(n.kind) + " — " + cleanfield(srcname) + "]";

	m := n.msg;

	text := "[Message notification — " + cleanfield(srcname) + "]\n";
	text += "Triage: " + triageverdict(m) + "\n";

	if(m.sender != nil)
		text += "From: " + previewfield(m.sender, MAXFIELD) + "\n";
	if(m.recipient != nil)
		text += "To: " + previewfield(m.recipient, MAXFIELD) + "\n";
	if(m.subject != nil)
		text += "Subject: " + previewfield(m.subject, MAXFIELD) + "\n";
	if(m.timestamp != nil)
		text += "Date: " + previewfield(m.timestamp, MAXFIELD) + "\n";

	# Include preview of body (first 200 chars)
	if(m.body != nil && m.body != "")
		text += "Preview: " + previewfield(m.body, 200) + "\n";

	# whole or not at all: a cut id would name nothing, or another message
	if(len m.id <= MAXFIELD)
		text += "Message ID: " + cleanfield(m.id) + "\n";
	text += "---\n";
	text += "Handle this per your message policy. Draft via /mnt/msg/draft, " +
		"flag via /mnt/msg/flag; the full body (when needed) is in the depth mount.";

	return text;
}

cleanfield(s: string): string
{
	if(s == nil)
		return "";
	out := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < ' ' || c == 16r7f)
			out += " ";
		else
			out += s[i:i+1];
	}
	return out;
}

previewfield(s: string, max: int): string
{
	out := "";
	i := 0;
	for(; i < len s && i < max; i++) {
		c := s[i];
		if(c < ' ' || c == 16r7f)
			out += " ";
		else
			out += s[i:i+1];
	}
	if(i < len s)
		out += "...";
	return out;
}

# === Notify queue management ===

enqueue(s: string)
{
	# Count queue length
	count := 0;
	for(q := notifyq; q != nil; q = tl q)
		count++;
	if(count >= MAXQ) {
		# dropped, and said: on stderr the first time, and counted
		# in status
		if(ndropped++ == 0)
			sys->fprint(stderr, "msg9p: notify queue full (%d): dropping notifications nobody reads\n", MAXQ);
		return;
	}

	# Append to end (build reversed, then reverse)
	notifyq = appendstr(notifyq, s);
}

dequeue(): string
{
	if(notifyq == nil)
		return "";
	# Return first element
	s := hd notifyq;
	notifyq = tl notifyq;
	return s;
}

appendstr(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return hd l :: appendstr(tl l, s);
}

# === Pending reader management ===

lastpending(): ref PendingRead
{
	pr := hd pendingReaders;
	for(l := tl pendingReaders; l != nil; l = tl l)
		pr = hd l;
	return pr;
}

droplast(l: list of ref PendingRead): list of ref PendingRead
{
	if(l == nil)
		return nil;
	if(tl l == nil)
		return nil;
	return hd l :: droplast(tl l);
}

cancelflushed(tag: int)
{
	newlist: list of ref PendingRead;
	for(l := pendingReaders; l != nil; l = tl l)
		if((hd l).tag != tag)
			newlist = hd l :: newlist;
	# newlist is reversed; put it back oldest last
	pendingReaders = nil;
	for(; newlist != nil; newlist = tl newlist)
		pendingReaders = hd newlist :: pendingReaders;
}

# no more of a notification than its reader asked for (the kernel cuts
# a longer reply anyway; one past the message size is an error instead)
cutto(data: array of byte, count: int): array of byte
{
	if(count < 0)
		count = 0;
	if(len data > count)
		return data[0:count];
	return data;
}

cancelpending(fid: int)
{
	newlist: list of ref PendingRead;
	for(l := pendingReaders; l != nil; l = tl l) {
		pr := hd l;
		if(pr.fid != fid)
			newlist = pr :: newlist;
		# else: silently drop — the clunk response handles the fid
	}
	pendingReaders = newlist;
}

# === Status generation ===

gensrclist(): string
{
	if(sources == nil)
		return "no sources registered\n";
	result := "";
	for(sl := sources; sl != nil; sl = tl sl) {
		src := hd sl;
		if(result != "")
			result += "\n";
		result += src.name + " " + src.path;
	}
	return result;
}

genstatus(): string
{
	if(sources == nil) {
		if(ndropped > 0)
			return sys->sprint("no sources registered\n%d notifications dropped (nobody was reading notify)\n", ndropped);
		return "no sources registered\n";
	}
	result := "";
	for(sl := sources; sl != nil; sl = tl sl) {
		src := hd sl;
		if(result != "")
			result += "\n";
		st := src.mod->status();
		result += src.name + ": " + st + " [caps: " + capwords(src.mod->capabilities()) + "]";
	}
	if(ndropped > 0)
		result += sys->sprint("\n%d notifications dropped (nobody was reading notify)", ndropped);
	return result;
}

# Render a MsgSrc capability bitmask as a space-separated word list, for
# /mnt/msg/status (and the Settings Messaging panel) to display.
capwords(caps: int): string
{
	w := "";
	if(caps & MsgSrc->CAP_WATCH)     w += "watch ";
	if(caps & MsgSrc->CAP_ENUMERATE) w += "enumerate ";
	if(caps & MsgSrc->CAP_FETCH)     w += "fetch ";
	if(caps & MsgSrc->CAP_SEND)      w += "send ";
	if(caps & MsgSrc->CAP_REPLY)     w += "reply ";
	if(caps & MsgSrc->CAP_SETFLAG)   w += "setflag ";
	if(w == "")
		return "none";
	return w[:len w - 1];	# trim trailing space
}

# === Helpers ===

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := string buf[:n];
	# Strip trailing whitespace
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
		s = s[:len s - 1];
	return s;
}

ensuredir(path: string)
{
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r777);
	if(fd != nil)
		fd = nil;
}

implement Auditfs;

#
# auditfs - tamper-evident audit-log file server (the security log).
#
# A small 9P (Styx) file server, mounted at /mnt/audit, exposing:
#
#   log     (w)  write "source event msg"; the server seals it into a
#                record: it assigns the sequence number and timestamp
#                (so a writer cannot forge order or backdate) and
#                extends the SHA-256 hash chain (module/auditchain.m).
#   chain   (r)  the sealed records, oldest first.
#   head    (r)  "<tiphash> <seq>" — the anchor to publish/ship off-host.
#   verify  (r)  "ok <count>" or "broken at seq <n>" — recompute the chain.
#   ctl     (w)  "checkpoint" appends a checkpoint marker record.
#
# Access control is by namespace placement: bind only `log` (write-only)
# into a subject's namespace and it can append to its own audit trail but
# cannot read or rewrite history. The chain gives tamper-evidence; an
# externally-anchored head catches a full rewrite.
#
# This is the security-log core. Checkpoint signing (AU-10) is performed
# by factotum, which holds the signer key — auditfs never sees the private
# key (see doc/compliance/audit-log-factotum-signing-DESIGN.md). The vac
# content-store layer for AI-agent provenance is a designed-in follow-on;
# see doc/compliance/audit-log-design.md.
#
# Usage:   auditfs [-f backing-file]
# Mount:   mount {auditfs} /mnt/audit
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "arg.m";

include "daytime.m";
	daytime: Daytime;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	Eperm, Ebadarg, Enotfound: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

include "factotum.m";
	fac: Factotum;

include "auditchain.m";
	ac: Auditchain;

Auditfs: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

# Qid path numbers.
Qdir, Qlog, Qchain, Qhead, Qverify, Qctl, Qpubkey: con iota;

stderr: ref Sys->FD;
user := "inferno";

logpath := "/usr/inferno/audit/log";
logfd: ref Sys->FD;		# append handle to the backing file

tiphash: array of byte;		# current chain tip
seq := 0;			# sequence number of the last record (0 = none)

# Checkpoint signatures (AU-10 non-repudiation) are produced by factotum,
# which holds the signer key — auditfs never sees the private key. When
# factotum is unreachable or holds no audit signer key, checkpoints are
# unsigned chain markers and the head must be anchored externally. The
# public key (not a secret) is published as a plain file and served at
# /mnt/audit/pubkey. See doc/compliance/audit-log-factotum-signing-DESIGN.md.
pubpath := "/usr/inferno/audit/pub";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail("cannot load arg");
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		fail("cannot load daytime");
	styx = load Styx Styx->PATH;
	if(styx == nil)
		fail("cannot load styx");
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		fail("cannot load styxservers");
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil)
		fail("cannot load nametree");
	ac = load Auditchain Auditchain->PATH;
	if(ac == nil)
		fail("cannot load auditchain");
	ac->init();

	# Optional: factotum performs checkpoint signing. Loosely coupled —
	# if it is absent, checkpoints fall back to unsigned chain markers.
	fac = load Factotum Factotum->PATH;
	if(fac != nil)
		fac->init();

	arg->init(args);
	arg->setusage("auditfs [-f backing-file]");
	while((c := arg->opt()) != 0) {
		case c {
		'f' =>
			logpath = arg->earg();
		* =>
			arg->usage();
		}
	}

	# Recompute the chain from any existing backing file; fail loud (to
	# stderr) if it is already broken, but keep serving so an operator
	# can read /mnt/audit/verify and inspect.
	tiphash = ac->genesis();
	data := readfile(logpath);
	(tip, last, broken) := replay(data);
	tiphash = tip;
	seq = last;
	if(broken >= 0)
		sys->fprint(stderr, "auditfs: WARNING chain broken at seq %d in %s\n", broken, logpath);

	# Open the backing file for append (create if absent).
	logfd = sys->open(logpath, Sys->OWRITE);
	if(logfd == nil) {
		logfd = sys->create(logpath, Sys->OWRITE, 8r600);
		if(logfd == nil)
			fail(sys->sprint("cannot open/create %s: %r (create the parent directory)", logpath));
	}

	styx->init();
	styxservers->init(styx);
	nametree->init();

	(tree, treeop) := nametree->start();
	tree.create(big Qdir, dir(".",      Sys->DMDIR | 8r555, Qdir));
	tree.create(big Qdir, dir("log",    8r222, Qlog));    # write-only
	tree.create(big Qdir, dir("chain",  8r444, Qchain));  # read-only
	tree.create(big Qdir, dir("head",   8r444, Qhead));   # read-only
	tree.create(big Qdir, dir("verify", 8r444, Qverify)); # read-only
	tree.create(big Qdir, dir("pubkey", 8r444, Qpubkey)); # read-only
	tree.create(big Qdir, dir("ctl",    8r222, Qctl));    # write-only

	(tc, srv) := Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qdir);
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
			Qlog or Qctl =>
				# write-only files read as empty
				srv.reply(styxservers->readstr(tm, ""));
			Qchain =>
				srv.reply(styxservers->readstr(tm, readfile(logpath)));
			Qhead =>
				srv.reply(styxservers->readstr(tm,
					sys->sprint("%s %d\n", ac->hex(tiphash), seq)));
			Qverify =>
				(nil, nil, broken) := replay(readfile(logpath));
				s: string;
				if(broken >= 0)
					s = sys->sprint("broken at seq %d\n", broken);
				else
					s = sys->sprint("ok %d\n", seq);
				srv.reply(styxservers->readstr(tm, s));
			Qpubkey =>
				# The audit public key is published as a plain file
				# (it is not a secret); empty if not provisioned.
				srv.reply(styxservers->readstr(tm, readfile(pubpath)));
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, "phase error -- bad path"));
			}

		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen) {
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			case int c.path {
			Qlog =>
				err := writelog(stripnl(string tm.data));
				if(err != nil)
					srv.reply(ref Rmsg.Error(tm.tag, err));
				else
					srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
			Qctl =>
				err := writectl(stripnl(string tm.data));
				if(err != nil)
					srv.reply(ref Rmsg.Error(tm.tag, err));
				else
					srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, Eperm));
			}

		Clunk =>
			srv.clunk(tm);

		* =>
			srv.default(tmsg);
		}
	}
	tree.quit();
}

# writelog parses a "source event msg..." write and seals a record.
writelog(s: string): string
{
	(n, toks) := sys->tokenize(s, " ");
	if(n < 2)
		return "auditfs: write must be 'source event [message]'";
	source := hd toks; toks = tl toks;
	event := hd toks; toks = tl toks;
	msg := join(toks);
	return appendrec(source, event, msg);
}

writectl(s: string): string
{
	if(s != "checkpoint")
		return "auditfs: ctl accepts only 'checkpoint'";
	# The signed content commits to the whole history (the tip
	# transitively covers every record). It must match exactly what
	# auditverify recomputes.
	content := sys->sprint("audit-checkpoint %s %d", ac->hex(tiphash), seq);
	cert := factotumsign(array of byte content);
	msg: string;
	if(cert != nil)
		msg = sys->sprint("head=%s seq=%d sig=%s",
			ac->hex(tiphash), seq, ac->hex(cert));
	else
		msg = sys->sprint("head=%s seq=%d", ac->hex(tiphash), seq);
	return appendrec("-", "checkpoint", msg);
}

# factotumsign asks factotum to sign `content` with the audit signer key
# it holds, and returns the certificate string as raw bytes (the caller
# hex-encodes it for the record). Returns nil if factotum is unreachable
# or holds no audit key, so the caller degrades to an unsigned marker.
# auditfs never sees the private key (AU-10). The certificate can exceed
# the factotum RPC frame, so it arrives in chunks until "done".
factotumsign(content: array of byte): array of byte
{
	if(fac == nil)
		return nil;
	afd := fac->open();
	if(afd == nil)
		return nil;
	(o, nil) := fac->rpc(afd, "start",
		array of byte "proto=sign service=audit role=client");
	if(o != "ok")
		return nil;
	(o, nil) = fac->rpc(afd, "write", content);
	if(o != "ok")
		return nil;
	cert := array[0] of byte;
	for(;;){
		(st, chunk) := fac->rpc(afd, "read", nil);
		case st {
		"ok" =>
			cert = concat(cert, chunk);
		"done" =>
			return cert;
		* =>
			return nil;
		}
	}
}

# concat returns a ++ b (slice-assignment to a[i:j] is rejected by the
# compiler, so copy element-wise).
concat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	for(i := 0; i < len a; i++)
		r[i] = a[i];
	for(i = 0; i < len b; i++)
		r[len a + i] = b[i];
	return r;
}

# appendrec seals one record: server-assigned seq + time, chain extend,
# durable append. The serveloop is single-threaded, so seq/tiphash need
# no lock.
appendrec(source, event, msg: string): string
{
	source = clean1(source);
	event = clean1(event);
	msg = cleannl(msg);
	newseq := seq + 1;
	t := daytime->now();
	canon := ac->canon(newseq, t, source, event, msg);
	newhash := ac->extend(tiphash, array of byte canon);
	line := sys->sprint("%d %d %s %s %s %s\n",
		newseq, t, source, event, ac->hex(newhash), msg);
	b := array of byte line;
	sys->seek(logfd, big 0, Sys->SEEKEND);
	if(sys->write(logfd, b, len b) != len b)
		return sys->sprint("auditfs: write failed: %r");
	tiphash = newhash;
	seq = newseq;
	return nil;
}

# replay recomputes the chain over the backing-file contents.
# Returns (tip, lastseq, brokenseq) where brokenseq is -1 if intact.
replay(data: string): (array of byte, int, int)
{
	prev := ac->genesis();
	last := 0;
	(nil, lines) := sys->tokenize(data, "\n");
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(line == "")
			continue;
		(seqf, tf, source, event, hashf, msg, ok) := parserec(line);
		if(!ok)
			return (prev, last, last + 1);
		h := ac->extend(prev, array of byte ac->canon(seqf, tf, source, event, msg));
		if(ac->hex(h) != hashf)
			return (prev, last, seqf);
		prev = h;
		last = seqf;
	}
	return (prev, last, -1);
}

# parserec splits a stored line into its fields. The first five
# space-separated tokens are seq, time, source, event, hash; the rest
# (rejoined) is the message.
parserec(line: string): (int, int, string, string, string, string, int)
{
	(n, toks) := sys->tokenize(line, " ");
	if(n < 5)
		return (0, 0, "", "", "", "", 0);
	seqf := int hd toks; toks = tl toks;
	tf := int hd toks; toks = tl toks;
	source := hd toks; toks = tl toks;
	event := hd toks; toks = tl toks;
	hashf := hd toks; toks = tl toks;
	return (seqf, tf, source, event, hashf, join(toks), 1);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	s := "";
	buf := array[8192] of byte;
	while((m := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:m];
	return s;
}

join(toks: list of string): string
{
	s := "";
	for(; toks != nil; toks = tl toks) {
		if(s != "")
			s += " ";
		s += hd toks;
	}
	return s;
}

# clean1 forces a single space-free token (sources/events are one word).
clean1(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == ' ' || c == '\t' || c == '\n')
			c = '_';
		r[len r] = c;
	}
	if(r == "")
		r = "-";
	return r;
}

# cleannl keeps a record to one line (the server escapes newlines).
cleannl(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '\n' || c == '\r')
			c = ' ';
		r[len r] = c;
	}
	return r;
}

stripnl(s: string): string
{
	if(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

fail(msg: string)
{
	sys->fprint(stderr, "auditfs: %s\n", msg);
	raise "fail:" + msg;
}

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
#                The event "checkpoint" is reserved to the server.
#   chain   (r)  the sealed records, oldest first (streamed by offset).
#   head    (r)  "<tiphash> <seq>" — the anchor to publish/ship off-host.
#   verify  (r)  "ok <count>", "broken at seq <n>", or "diverged: ..."
#                (backing file modified behind the running server).
#   ctl     (w)  "checkpoint" forces a signed root now.
#
# Access control is by namespace placement: bind only `log` (write-only)
# into a subject's namespace and it can append to its own audit trail but
# cannot read or rewrite history. The chain gives tamper-evidence; an
# externally-anchored head catches a full rewrite.
#
# Checkpoints are signed roots (the CT signed-tree-head pattern): the tip
# transitively covers every record, so one signature commits to the whole
# history. The server drives its own cadence — a checkpoint at least
# every CHECKEVERY records, and within CHECKMS of any new record — so the
# unanchored tail stays bounded without an operator in the loop. A
# checkpoint exists only if factotum signs it: an unsigned marker proves
# nothing the chain doesn't already, and the strict verifier
# (auditverify -k) treats one as tampering. On a chain-only install (no
# signer key) the log simply has no checkpoints; verify it against an
# off-host copy of head (auditverify -a).
#
# At startup the server seals an "auditfs start" record carrying the host
# name and the replay outcome, so restarts are visible in the trail and a
# log is readably bound to its host.
#
# A record is put in one canonical text (auditchain's token and text)
# before it is hashed, whatever a writer sent, and a line of the file is
# a record only if it is exactly that text: what is sealed, what is
# stored and what a replay reads are the same bytes.
#
# A file whose chain does not verify is still served and still appended
# to (a log that stops taking records stops every fail-closed writer),
# but not as though it verified: the start record says replay=broken@n,
# sequence numbers go on from the highest in the file, the chain goes on
# from the last record's stored hash (so what is added is bound to the
# file as it was found), verify goes on saying where the break is, and no
# checkpoint is signed over it.  Set such a file aside and start another
# to have signed roots again.
#
# Checkpoint signing (AU-10) is performed by factotum, which holds the
# signer key — auditfs never sees the private key (see
# docs/compliance/audit-log-factotum-signing-DESIGN.md). The vac
# content-store layer for AI-agent provenance is a designed-in follow-on;
# see docs/compliance/audit-log-design.md.
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
chainfd: ref Sys->FD;		# read handle for streaming /mnt/audit/chain

tiphash: array of byte;		# current chain tip
seq := 0;			# sequence number of the last record (0 = none)
knownbreaks: list of int;	# where the file's chain did not verify when read
needsnl := 0;			# the file ends in a fragment: begin a new line first
MAXSEQ: con 16r7fffffff;
MAXREC: con 4096;		# a writer's record; less than any 9P message in use

# Checkpoint cadence: a signed root at least every CHECKEVERY records,
# and (via the ticker) within CHECKMS of any new record. lastattempt
# throttles retries when no signer key is provisioned, so a chain-only
# install pays one failed factotum call per window, not one per write.
CHECKEVERY: con 64;
CHECKMS: con 10*60*1000;
lastcheck := 0;			# seq at the last sealed checkpoint
lastattempt := 0;		# seq at the last checkpoint attempt

# Checkpoint signatures (AU-10 non-repudiation) are produced by factotum,
# which holds the signer key — auditfs never sees the private key. When
# factotum is unreachable or holds no audit signer key, no checkpoint is
# sealed (signed-only) and the head must be anchored externally. The
# public key (not a secret) is fetched from factotum and served at
# /mnt/audit/pubkey. See docs/compliance/audit-log-factotum-signing-DESIGN.md.
pubkey := "";			# audit public key, fetched from factotum and cached

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
	# if it is absent, no checkpoints are sealed (chain-only install).
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
	# can read /mnt/audit/verify and inspect.  A file that is there and
	# cannot be read is not an empty log: it was taken for one, and
	# records numbered from 1 were appended to it.
	tiphash = ac->genesis();
	(data, rerr) := readfile(logpath);
	if(rerr != nil)
		fail(rerr);
	(tiphash, seq, knownbreaks) = replay(data);
	needsnl = len data > 0 && data[len data - 1] != '\n';
	if(knownbreaks != nil)
		sys->fprint(stderr, "auditfs: WARNING chain broken at seq %d in %s\n", hd knownbreaks, logpath);

	# Open the backing file for append (create if absent).
	logfd = sys->open(logpath, Sys->OWRITE);
	if(logfd == nil) {
		logfd = sys->create(logpath, Sys->OWRITE, 8r600);
		if(logfd == nil)
			fail(sys->sprint("cannot open/create %s: %r (create the parent directory)", logpath));
	}
	chainfd = sys->open(logpath, Sys->OREAD);
	if(chainfd == nil)
		fail(sys->sprint("cannot open %s for reading: %r", logpath));

	# Seal a boot record: restarts become visible in the trail itself
	# (a gap-detection aid), and the host identity travels in the chain,
	# so one host's log reads as that host's. Fatal on failure — a log
	# that cannot take this record cannot take any.
	rst := "ok";
	if(knownbreaks != nil)
		rst = sys->sprint("broken@%d", hd knownbreaks);
	err := appendrec("auditfs", "start", sys->sprint("host=%s replay=%s", ac->value(hostname()), rst));
	if(err != nil)
		fail(err);

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

	# The cadence ticker: wakes the serveloop so a dirty chain gets its
	# signed root within CHECKMS even when write traffic stops.
	tick := chan of int;
	pidc := chan of int;
	spawn ticker(tick, pidc);
	tickpid := <-pidc;

	# The ticker goes with the server however the server goes: an
	# exception in the loop left it running, holding the mount's pipe.
	{
		serveloop(tc, srv, tree, tick);
	} exception {
	* =>
		kill(tickpid);
		raise;
	}
	kill(tickpid);
}

ticker(tick: chan of int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;) {
		sys->sleep(CHECKMS);
		tick <-= 1;
	}
}

kill(pid: int)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

hostname(): string
{
	(s, nil) := readfile("/dev/sysname");
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	if(s == "")
		s = "-";
	return s;
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

serveloop(tc: chan of ref Tmsg, srv: ref Styxserver, tree: ref Tree, tick: chan of int)
{
loop:
	for(;;) alt {
	<-tick =>
		# Cadence, time half: seal a signed root within CHECKMS of any
		# new record. An idle chain appends nothing; failures (no
		# signer key — a chain-only install) are silent by design.
		if(seq > lastcheck) {
			lastattempt = seq;
			docheckpoint();
		}

	tmsg := <-tc =>
		if(tmsg == nil)
			break loop;
		pick tm := tmsg {
		Readerror =>
			break loop;

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
				# Stream straight from the backing file at the client's
				# offset: the file is append-only so offsets are stable,
				# and a growing log is never copied whole per read.
				srv.reply(readchain(tm));
			Qhead =>
				srv.reply(styxservers->readstr(tm,
					sys->sprint("%s %d\n", ac->hex(tiphash), seq)));
			Qverify =>
				# A file that cannot be read is not a chain that
				# verifies: its bytes so far were replayed, and "ok"
				# or a break somewhere else was the answer.
				(fdata, ferr) := readfile(logpath);
				if(ferr != nil) {
					srv.reply(ref Rmsg.Error(tm.tag, ferr));
					continue;
				}
				(ftip, flast, fbreaks) := replay(fdata);
				same := flast == seq && ac->hex(ftip) == ac->hex(tiphash) &&
					sameints(fbreaks, knownbreaks);
				s: string;
				if(fbreaks != nil && (same || knownbreaks == nil))
					s = sys->sprint("broken at seq %d\n", hd fbreaks);
				else if(!same) {
					# The file disagrees with the live chain: the
					# backing store was modified behind the running
					# server (truncate-and-rewrite looks exactly like
					# this; so does a second break in a file that
					# was broken when it was read).
					s = sys->sprint("diverged: file at seq %d tip %s, server at seq %d tip %s",
						flast, ac->hex(ftip), seq, ac->hex(tiphash));
					if(fbreaks != nil)
						s += sys->sprint(" (file broken at seq %d)", hd fbreaks);
					s += "\n";
				} else
					s = sys->sprint("ok %d\n", seq);
				srv.reply(styxservers->readstr(tm, s));
			Qpubkey =>
				# Fetch the audit public key from factotum once, then
				# cache it; empty if not provisioned / factotum absent.
				if(pubkey == ""){
					pk := factotumpubkey();
					if(pk != nil && len pk > 0)
						pubkey = string pk + "\n";
				}
				srv.reply(styxservers->readstr(tm, pubkey));
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
				# One write is one record.  A write longer than a
				# 9P message reaches here in pieces, and each piece
				# was sealed as a record of its own: the end of a
				# long field became the source, event and message
				# of the next.  The first piece is refused, which
				# ends the write.
				err: string;
				if(len tm.data > MAXREC)
					err = sys->sprint("auditfs: record longer than %d bytes", MAXREC);
				else
					err = writelog(string tm.data);
				if(err != nil)
					srv.reply(ref Rmsg.Error(tm.tag, err));
				else
					srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
			Qctl =>
				err := writectl(ac->text(string tm.data));
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
	# The write as one line of words first, so that the source and the
	# event are the words a reader of the record sees: split before the
	# controls were dealt with, "checkpoint" followed by a CR was not the
	# reserved event when written and read as it once displayed.
	(n, toks) := sys->tokenize(ac->text(s), " ");
	if(n < 2)
		return "auditfs: write must be 'source event [message]'";
	source := hd toks; toks = tl toks;
	event := hd toks; toks = tl toks;
	# Checkpoint records are minted only by the server: a writer-
	# supplied one would carry verifier semantics it has no authority
	# over (auditverify treats the event specially).
	if(event == "checkpoint")
		return "auditfs: event 'checkpoint' is reserved";
	msg := join(toks);
	err := appendrec(source, event, msg);
	if(err != nil)
		return err;
	# Cadence, count half: force a signed root at least every
	# CHECKEVERY records so the unanchored tail stays bounded under
	# sustained traffic. One attempt per window when signing is
	# unavailable, so a chain-only install pays nothing per write.
	if(seq - lastcheck >= CHECKEVERY && seq - lastattempt >= CHECKEVERY) {
		lastattempt = seq;
		docheckpoint();
	}
	return nil;
}

writectl(s: string): string
{
	if(s != "checkpoint")
		return "auditfs: ctl accepts only 'checkpoint'";
	return docheckpoint();
}

# docheckpoint seals a signed root over the whole history: the tip
# transitively covers every record, so one factotum signature (AU-10)
# commits to all of them. The signed content must match exactly what
# auditverify recomputes. No signer, no checkpoint: an unsigned marker
# proves nothing the chain doesn't already, and the strict verifier
# (-k) rightly reads one as tampering.
docheckpoint(): string
{
	# A signed root says the tip covers every record before it; that is
	# not so of a history that does not verify.
	if(knownbreaks != nil)
		return sys->sprint("auditfs: chain broken at seq %d: no checkpoint is signed over it", hd knownbreaks);
	content := sys->sprint("audit-checkpoint %s %d", ac->hex(tiphash), seq);
	cert := factotumsign(array of byte content);
	if(cert == nil)
		return "auditfs: no signer key in factotum (run /lib/sh/audit-setup)";
	msg := sys->sprint("head=%s seq=%d sig=%s",
		ac->hex(tiphash), seq, ac->hex(cert));
	err := appendrec("-", "checkpoint", msg);
	if(err == nil) {
		lastcheck = seq;
		lastattempt = seq;
	}
	return err;
}

# factotumsign asks factotum to sign `content` with the audit signer key
# it holds, returning the certificate string as raw bytes (the caller
# hex-encodes it for the record). nil if factotum is unreachable or holds
# no audit key, so the caller degrades to an unsigned marker. auditfs
# never sees the private key (AU-10).
factotumsign(content: array of byte): array of byte
{
	return factotumcall("proto=sign service=audit role=client", content);
}

# factotumpubkey fetches the audit public key (not a secret) from factotum.
factotumpubkey(): array of byte
{
	return factotumcall("proto=sign service=audit role=client op=pubkey", nil);
}

# factotumcall drives factotum's sign proto over the rpc file: start, an
# optional content write (nil for pubkey), then read the (possibly chunked)
# result until "done". Returns nil on any failure. The result can exceed
# the RPC frame (an mldsa87 cert is ~6KB), hence the read loop.
factotumcall(params: string, content: array of byte): array of byte
{
	if(fac == nil)
		return nil;
	afd := fac->open();
	if(afd == nil)
		return nil;
	(o, nil) := fac->rpc(afd, "start", array of byte params);
	if(o != "ok")
		return nil;
	if(content != nil){
		(o, nil) = fac->rpc(afd, "write", content);
		if(o != "ok")
			return nil;
	}
	out := array[0] of byte;
	for(;;){
		(st, chunk) := fac->rpc(afd, "read", nil);
		case st {
		"ok" =>
			out = concat(out, chunk);
		"done" =>
			return out;
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
# no lock.  This is the one place a record is made: the fields are put
# in their canonical text here, before they are hashed.
appendrec(source, event, msg: string): string
{
	source = ac->token(source);
	event = ac->token(event);
	msg = ac->text(msg);
	if(seq >= MAXSEQ)
		return "auditfs: sequence numbers used up";
	newseq := seq + 1;
	t := daytime->now();
	canon := ac->canon(newseq, t, source, event, msg);
	newhash := ac->extend(tiphash, array of byte canon);
	line := ac->record(newseq, t, source, event, ac->hex(newhash), msg) + "\n";
	if(needsnl)
		line = "\n" + line;
	b := array of byte line;
	sys->seek(logfd, big 0, Sys->SEEKEND);
	if(sys->write(logfd, b, len b) != len b) {
		err := sys->sprint("auditfs: write failed: %r");
		# Part of the line may be in the file.  The file is what a
		# verifier will read, so go on from what it now holds: the
		# next record began in the middle of the fragment's line, and
		# the server's chain was one no reading of the file gave.
		resync();
		return err;
	}
	needsnl = 0;
	tiphash = newhash;
	seq = newseq;
	return nil;
}

resync()
{
	needsnl = 1;
	(data, err) := readfile(logpath);
	if(err != nil)
		return;
	(tiphash, seq, knownbreaks) = replay(data);
	needsnl = len data > 0 && data[len data - 1] != '\n';
}

# replay recomputes the chain over the backing-file contents.
# Returns (tip, lastseq, breaks): the sequence numbers at which the
# chain does not verify, in the file's order, nil if it is intact.
#
# A record must carry the next number after the highest so far and the
# hash of the chain before it.  One that does not is a break, and the
# replay goes on from that record's own stored hash and number: what
# follows is then checked against what the file says, and a server that
# appends to such a file chains from its end.  (It stopped at the first
# break and gave the chain's state before it; a server started on the
# file then appended from there, numbering its records as ones already
# in the file.)  A line that is no record is a break at the next
# number, and changes nothing else.
replay(data: string): (array of byte, int, list of int)
{
	prev := ac->genesis();
	last := 0;
	breaks: list of int;
	(nil, lines) := sys->tokenize(data, "\n");
	for(; lines != nil; lines = tl lines) {
		(seqf, tf, source, event, hashf, msg, ok) := ac->parse(hd lines);
		if(!ok) {
			breaks = last + 1 :: breaks;
			continue;
		}
		h := ac->extend(prev, array of byte ac->canon(seqf, tf, source, event, msg));
		if(ac->hex(h) != hashf || seqf != last + 1)
			breaks = seqf :: breaks;
		prev = ac->unhex(hashf);
		if(seqf > last)
			last = seqf;
	}
	r: list of int;
	for(; breaks != nil; breaks = tl breaks)
		r = hd breaks :: r;
	return (prev, last, r);
}

sameints(a, b: list of int): int
{
	while(a != nil && b != nil) {
		if(hd a != hd b)
			return 0;
		a = tl a;
		b = tl b;
	}
	return a == nil && b == nil;
}

# readchain answers one styx Read of /mnt/audit/chain directly from the
# backing file at the requested offset — no whole-file copy per read.
readchain(tm: ref Tmsg.Read): ref Rmsg
{
	n := tm.count;
	if(n < 0)
		n = 0;
	if(n > 8*Sys->ATOMICIO)
		n = 8*Sys->ATOMICIO;
	buf := array[n] of byte;
	r := sys->pread(chainfd, buf, n, tm.offset);
	if(r < 0)
		return ref Rmsg.Error(tm.tag, sys->sprint("%r"));
	return ref Rmsg.Read(tm.tag, buf[0:r]);
}

# readfile returns a file's text and nil, or what kept it from being
# read.  A file that is not there is empty.  The bytes are put together
# before they are made a string: a rune cut by the end of a read is one
# rune.  An error in the middle of the file was taken for its end.
readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		err := sys->sprint("cannot open %s: %r", path);
		(ok, nil) := sys->stat(path);
		if(ok < 0)
			return ("", nil);
		return ("", err);
	}
	# Collect chunks and assemble once: += on a string is quadratic,
	# and this runs over the whole (ever-growing) backing file.
	chunks: list of array of byte;
	total := 0;
	for(;;) {
		buf := array[Sys->ATOMICIO] of byte;
		m := sys->read(fd, buf, len buf);
		if(m < 0)
			return ("", sys->sprint("cannot read %s: %r", path));
		if(m == 0)
			break;
		chunks = buf[0:m] :: chunks;
		total += m;
	}
	all := array[total] of byte;
	o := total;
	for(; chunks != nil; chunks = tl chunks) {
		c := hd chunks;
		o -= len c;
		all[o:] = c;
	}
	return (string all, nil);
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

fail(msg: string)
{
	sys->fprint(stderr, "auditfs: %s\n", msg);
	raise "fail:" + msg;
}

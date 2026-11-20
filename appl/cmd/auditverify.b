implement Auditverify;

#
# auditverify - offline verifier for the InferNode audit log.
#
# Recomputes the SHA-256 hash chain over a set of audit records and
# reports the first break, if any.
#
# -k pubkeyfile makes signatures MANDATORY: every checkpoint record
# must carry a signature that verifies under the audit public key, and
# at least one signed checkpoint must be present. (A lenient mode would
# let an attacker who rewrites the whole file simply strip the sig=
# tokens — or the checkpoint records — and still verify clean. If you
# hold the public key, your deployment signs; hold the verifier to it.)
#
# -a anchorfile checks the chain against an externally-saved copy of
# /mnt/audit/head ("<tiphash> <seq>"). The chain must contain at least
# <seq> records and its <seq>-prefix must hash to <tiphash>. This is
# the truncation defence: a hash chain cut back to any prefix is still
# internally consistent, so tail deletion is only detectable against a
# head copied off-host. Anchoring is namespace policy, not machinery:
#   cp /mnt/audit/head somewhere-else
#   auditverify -k pub -a head-copy chainfile
#
# Usage:
#   auditverify [-k pubkeyfile] [-a anchorfile] [chainfile]
# (chainfile defaults to standard input, e.g. `cat /mnt/audit/chain | auditverify`)
#
# A record must be the line auditfs writes for its fields, carry the next
# sequence number after the one before it, and the hash of the chain
# before it; a checkpoint must name the head and the sequence number just
# before it.  At a record that does not, the verifier says so and reads
# on from that record's own stored hash, to say how many breaks there are
# and how far the file goes: a server started on a broken file chains
# from its end the same way (auditfs(4)).  Any break is a failure.
#
# Exit: prints "ok: ..." and succeeds, or prints the fault and raises.
#
# See docs/compliance/audit-log-design.md.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "arg.m";

include "auditchain.m";
	ac: Auditchain;

Auditverify: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail("cannot load arg");
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		fail("cannot load keyring");
	ac = load Auditchain Auditchain->PATH;
	if(ac == nil)
		fail("cannot load auditchain");
	ac->init();

	pubkeyfile := "";
	anchorfile := "";
	arg->init(args);
	arg->setusage("auditverify [-k pubkeyfile] [-a anchorfile] [chainfile]");
	while((c := arg->opt()) != 0) {
		case c {
		'k' =>
			pubkeyfile = arg->earg();
		'a' =>
			anchorfile = arg->earg();
		* =>
			arg->usage();
		}
	}
	args = arg->argv();

	pk: ref Keyring->PK;
	if(pubkeyfile != "") {
		pks := readfile(pubkeyfile);
		pk = kr->strtopk(pks);
		if(pk == nil)
			fail("cannot parse public key " + pubkeyfile);
	}

	anchorhash := "";
	anchorseq := -1;
	if(anchorfile != "") {
		(n, toks) := sys->tokenize(readfile(anchorfile), " \t\n");
		if(n < 2)
			fail("anchor file must hold '<tiphash> <seq>' (a copy of /mnt/audit/head)");
		anchorhash = hd toks;
		anchorseq = int hd tl toks;
		# a number, not whatever digits a word begins with
		if(len anchorhash != 2*Auditchain->HASHLEN || anchorseq < 0 ||
		   string anchorseq != hd tl toks)
			fail("cannot parse anchor " + anchorfile);
	}

	data: string;
	if(args == nil)
		data = readfd(sys->fildes(0));
	else
		data = readfile(hd args);

	(ok, nrec, ncheck, nsig, msg) := verifychain(data, pk, anchorhash, anchorseq);
	if(!ok) {
		sys->fprint(stderr, "auditverify: %s\n", msg);
		raise "fail:verify";
	}
	anchored := "";
	if(anchorseq >= 0)
		anchored = sys->sprint(", anchored at seq %d", anchorseq);
	sys->print("ok: %d records, %d checkpoints, %d signatures verified%s\n",
		nrec, ncheck, nsig, anchored);
}

verifychain(data: string, pk: ref Keyring->PK, anchorhash: string, anchorseq: int): (int, int, int, int, string)
{
	prev := ac->genesis();
	nrec := 0;		# the highest sequence number so far
	ncheck := 0;
	nsig := 0;
	nbreak := 0;
	fault := "";		# the first break
	# seq 0 anchors the empty chain: the head file reads "<genesis> 0".
	anchored := anchorseq == 0 && anchorhash == ac->hex(prev);
	(nil, lines) := sys->tokenize(data, "\n");
	for(; lines != nil; lines = tl lines) {
		(seqf, tf, source, event, hashf, recmsg, okp) := ac->parse(hd lines);
		if(!okp) {
			if(nbreak++ == 0)
				fault = sys->sprint("malformed record after seq %d", nrec);
			continue;
		}
		h := ac->extend(prev, array of byte ac->canon(seqf, tf, source, event, recmsg));
		if(ac->hex(h) != hashf) {
			if(nbreak++ == 0)
				fault = sys->sprint("broken at seq %d", seqf);
		} else if(seqf != nrec + 1) {
			# The hash covers the number, so this is a chain made
			# with a gap or a repeat in it: records taken out and
			# the rest rehashed, or a server that numbered its
			# records from before a break.
			if(nbreak++ == 0)
				fault = sys->sprint("broken at seq %d (it follows seq %d)", seqf, nrec);
		} else if(nbreak == 0 && event == "checkpoint") {
			ncheck++;
			(head, cseq, sig) := parsecheck(recmsg);
			# the signed tip is the chain head just before this
			# record, and the number it names is that record's:
			# the number is signed too, and was not looked at
			if(head != ac->hex(prev) || cseq != string (seqf - 1))
				return (0, nrec, ncheck, nsig,
					sys->sprint("checkpoint head mismatch at seq %d", seqf));
			if(pk != nil) {
				# With the public key in hand, signatures are mandatory:
				# a whole-file rewrite can recompute every chain hash but
				# cannot mint a signature, so tolerating unsigned
				# checkpoints would hand the attacker a clean bypass.
				if(sig == "")
					return (0, nrec, ncheck, nsig,
						sys->sprint("unsigned checkpoint at seq %d (signature required with -k)", seqf));
				content := sys->sprint("audit-checkpoint %s %s", head, cseq);
				cb := array of byte content;
				cert := kr->strtocert(string ac->unhex(sig));
				# Re-hash with the algorithm named in the certificate so
				# SHA-384 (CNSA 2.0, ML-DSA-87) checkpoints verify alongside
				# legacy SHA-256 ones.
				st := digestfor(cert, cb);
				if(cert == nil || kr->verify(pk, cert, st) == 0)
					return (0, nrec, ncheck, nsig,
						sys->sprint("bad checkpoint signature at seq %d", seqf));
				nsig++;
			}
		}
		prev = ac->unhex(hashf);
		if(seqf > nrec)
			nrec = seqf;
		if(nbreak == 0 && seqf == anchorseq) {
			if(hashf != anchorhash)
				return (0, nrec, ncheck, nsig,
					sys->sprint("anchor mismatch at seq %d (history rewritten)", seqf));
			anchored = 1;
		}
	}
	if(nbreak > 0)
		return (0, nrec, ncheck, nsig,
			sys->sprint("%s (breaks: %d; the file's last record is seq %d)", fault, nbreak, nrec));
	if(anchorseq >= 0 && !anchored)
		return (0, nrec, ncheck, nsig,
			sys->sprint("chain does not reach anchor seq %d (truncated?)", anchorseq));
	# Same reasoning as the unsigned-checkpoint rule: a rewrite that
	# drops the checkpoint records entirely must not verify clean.
	if(pk != nil && nsig == 0)
		return (0, nrec, ncheck, nsig,
			"no signed checkpoints (chain is not attributable to the audit key)");
	return (1, nrec, ncheck, nsig, "");
}

# Compute the verify-side digest using the hash named in the certificate.
# A nil cert falls back to SHA-256; the caller rejects it before using the
# result, so the choice is immaterial in that case.
digestfor(cert: ref Keyring->Certificate, buf: array of byte): ref Keyring->DigestState
{
	if(cert != nil && cert.ha == "sha384")
		return kr->sha384(buf, len buf, nil, nil);
	if(cert != nil && cert.ha == "sha512")
		return kr->sha512(buf, len buf, nil, nil);
	return kr->sha256(buf, len buf, nil, nil);
}

parsecheck(msg: string): (string, string, string)
{
	head := "";
	cseq := "";
	sig := "";
	(nil, toks) := sys->tokenize(msg, " ");
	for(; toks != nil; toks = tl toks) {
		(k, v) := splitkv(hd toks);
		case k {
		"head" => head = v;
		"seq" =>  cseq = v;
		"sig" =>  sig = v;
		}
	}
	return (head, cseq, sig);
}

splitkv(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == '=')
			return (s[0:i], s[i+1:]);
	return (s, "");
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("cannot open %s: %r", path));
	return readfd(fd);
}

# The bytes are put together before they are made a string.  Each read
# was converted by itself, so a rune cut by the end of one was two bad
# runes, its record no longer hashed to what the server sealed, and a
# sound chain with any text outside ASCII in it was reported broken.
# And a read that fails is not the end of the file: what had been read
# was verified, and "ok" said of it.
readfd(fd: ref Sys->FD): string
{
	chunks: list of array of byte;
	total := 0;
	for(;;) {
		buf := array[Sys->ATOMICIO] of byte;
		m := sys->read(fd, buf, len buf);
		if(m < 0)
			fail(sys->sprint("read error: %r"));
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
	return string all;
}

fail(msg: string)
{
	sys->fprint(stderr, "auditverify: %s\n", msg);
	raise "fail:" + msg;
}

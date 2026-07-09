implement Auditverify;

#
# auditverify - offline verifier for the InferNode audit log.
#
# Recomputes the SHA-256 hash chain over a set of audit records and
# reports the first break, if any. With -k it also checks every
# checkpoint signature against the audit public key (so an auditor
# verifies the whole history with only the public key — no secret).
#
# Usage:
#   auditverify [-k pubkeyfile] [chainfile]
# (chainfile defaults to standard input, e.g. `cat /mnt/audit/chain | auditverify`)
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
	arg->init(args);
	arg->setusage("auditverify [-k pubkeyfile] [chainfile]");
	while((c := arg->opt()) != 0) {
		case c {
		'k' =>
			pubkeyfile = arg->earg();
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

	data: string;
	if(args == nil)
		data = readfd(sys->fildes(0));
	else
		data = readfile(hd args);

	(ok, nrec, ncheck, nsig, msg) := verifychain(data, pk);
	if(!ok) {
		sys->fprint(stderr, "auditverify: %s\n", msg);
		raise "fail:verify";
	}
	sys->print("ok: %d records, %d checkpoints, %d signatures verified\n",
		nrec, ncheck, nsig);
}

verifychain(data: string, pk: ref Keyring->PK): (int, int, int, int, string)
{
	prev := ac->genesis();
	nrec := 0;
	ncheck := 0;
	nsig := 0;
	(nil, lines) := sys->tokenize(data, "\n");
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(line == "")
			continue;
		(seqf, tf, source, event, hashf, recmsg, okp) := parserec(line);
		if(!okp)
			return (0, nrec, ncheck, nsig,
				sys->sprint("malformed record after seq %d", nrec));
		h := ac->extend(prev, array of byte ac->canon(seqf, tf, source, event, recmsg));
		if(ac->hex(h) != hashf)
			return (0, nrec, ncheck, nsig, sys->sprint("broken at seq %d", seqf));
		if(event == "checkpoint") {
			ncheck++;
			(head, cseq, sig) := parsecheck(recmsg);
			# the signed tip is the chain head just before this record
			if(head != ac->hex(prev))
				return (0, nrec, ncheck, nsig,
					sys->sprint("checkpoint head mismatch at seq %d", seqf));
			if(sig != "" && pk != nil) {
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
		prev = h;
		nrec = seqf;
	}
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

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("cannot open %s: %r", path));
	return readfd(fd);
}

readfd(fd: ref Sys->FD): string
{
	s := "";
	buf := array[8192] of byte;
	while((m := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:m];
	return s;
}

fail(msg: string)
{
	sys->fprint(stderr, "auditverify: %s\n", msg);
	raise "fail:" + msg;
}

implement Secstored;

#
# secstored - Secstore server for InferNode
#
# Implements the Plan 9 secstore server protocol (PAK authentication,
# encrypted file storage).  Compatible with the existing secstore
# client library (appl/lib/secstore.b) and CLI (appl/cmd/auth/secstore.b).
#
# Usage:
#   auth/secstored [-d] [-s storedir] [-a addr]
#
# Options:
#   -d            debug mode (verbose logging)
#   -s storedir   directory for user data (default: /usr/inferno/secstore)
#   -a addr       listen address (default: tcp!localhost!5356)
#
# Storage layout:
#   storedir/
#     <user>/
#       PAK          PAK verifier (version and hexHi) for this user; two
#                    lines while the account moves to a newer version
#       VAULTKEY     the hash of the second factor's vault key, once one
#                    is enrolled: the account's files then change only
#                    in a session that has shown the key
#       2fa/         the client's key slots (twofaslot(2)); not served
#       <filename>   encrypted file blobs
#     Names beginning with a dot are the server's own, while it writes.
#
# Setup:
#   Use auth/secstore-setup to create user accounts.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "dial.m";
	dialler: Dial;

include "keyring.m";
	kr: Keyring;
	DigestState, IPint: import kr;
	AESbsize: import kr;

include "security.m";
	ssl: SSL;
	login: Login;

include "secstore.m";
	secstore: Secstore;

include "encoding.m";
	base64: Encoding;

include "readdir.m";

include "arg.m";

include "string.m";
	str: String;

include "audit.m";
	audit: Audit;

include "daytime.m";
	daytime: Daytime;

Secstored: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

VERSION1: con "secstore";
VERSION3: con "secstore3";	# secstore2 retired: the client never offers it
#
# Version 4 is version 3's exchange with another verifier and another
# session.  The verifier is made from the key the account's files are
# encrypted under (100000 HMACs of the password), where version 3's was
# made from one SHA-256 of it: whoever read the store could try
# passwords against PAK at the cost of an exponentiation each, far less
# than against the files beside it.  And a version 4 session's stores
# and removes are answered, where the older ones were not, so it has
# the requests this server adds: a new verifier, and the second
# factor's lock on the account's files.
#
# An account at an older version logs in once more with it, is given
# its version 4 verifier by the client (VERIFIER), and from the next
# login is at version 4 alone: until then PAK holds both lines.  A
# session of an older version may read and move the account, and no
# more: it does not store or remove.
#
VERSION4: con "secstore4";
#
# Version 5 is version 4's account and verifier, its exchange with an
# ML-KEM-1024 encapsulation beside the PAK and SHA-384 for its proofs
# and session (secstore(2)'s PAK5, which this server calls for both).
# A party that could take logarithms could try passwords against a
# version 4 login it had recorded; at version 5 it has the one guess
# per login it takes part in.  A version 5 session is a version 4 one
# in what it may do.  The version 4 exchange is not spoken: a client
# asking for it is told the account is at version 5 (and an older
# version's exchange is still spoken, for an account to move).  In
# CNSA mode (/env/cnsamode) version 5 alone is spoken.
#
VERSION5: con "secstore5";
Maxfilesize: con 128*1024;
Maxmsg: con 4096;

# Online-guessing throttle (NIST SP 800-53 AC-7; SP 800-171 3.5.x; CC FIA_AFL.1;
# SP 800-63B §5.2.2 rate-limiting). secstored is the only place a password is
# verified over the wire, so the limit belongs here, not in the logon UI (which
# a caller can bypass by reconnecting). Inferno precedent: keyfs.b keeps a
# per-key `failed` counter and disables the key at Maxfail. We follow the same
# shape but the lock is TEMPORARY — a cooldown, not a permanent disable — so a
# single-host boot secstore can never be bricked by a mistyped password. The
# FIDO2 UV/PIN second factor has its own hardware retry counter (twofaslot.b:
# PIN_BLOCKED after the key's 8 lifetime attempts), so this bounds the password
# factor to complete the AC-7 story.
#
# 10 consecutive wrong-password attempts is well under 800-63B's 100-attempt
# ceiling yet tolerant of fat-fingering a long secstore password; a 60s cooldown
# caps sustained online guessing at ~10/min per account. Tune here if an
# integrator needs stricter limits.
Maxfail: con 10;	# consecutive wrong-password attempts before lockout
Locksecs: con 60;	# cooldown window (seconds) once locked

debug := 0;
storedir := "/usr/inferno/secstore";
sname := "secstore";	# server identity for PAK

# Per-account failure state, shared across the spawned per-connection procs.
# Dis scheduling is cooperative (one proc runs until it blocks), and none of the
# guard helpers below yield, so their read-modify-write of this list is atomic
# without an explicit lock. In-memory only: the throttle is per server lifetime,
# which is the right scope for an online rate-limit (offline attack on the blob
# is a separate concern, mitigated by the PAK design + the FIDO2 factor).
Acctguard: adt {
	user:		string;
	fails:		int;	# consecutive wrong-password attempts
	lockeduntil:	int;	# epoch seconds; 0 = not locked
};
guards: list of ref Acctguard;

# PAK parameters — same as client (from secstore.b)
PAKparams: adt {
	q:	ref IPint;
	p:	ref IPint;
	r:	ref IPint;
	g:	ref IPint;
};

paklegacy: ref PAKparams;
pak3: ref PAKparams;

# auditlog emits a security event to the tamper-evident audit log if the
# service is bound into the namespace; returns -1 when the record could
# not be sealed. Authentication events are AU-2 / AU-3 records. Loose
# coupling still holds — an install that never opted in ignores the -1 —
# but when auditing is required (see auditrequired) the caller must
# treat -1 as a hard error.
auditlog(source, event, msg: string): int
{
	if(audit == nil)
		return -1;
	return audit->log(source, event, msg);
}

# a name the client claimed, as one value of a record
auditval(s: string): string
{
	if(audit == nil)
		return "";
	return audit->value(s);
}

# auditrequired reports whether this install opted into auditing (the
# marker audit-setup / AUDITMODE creates). If so, the completeness
# contract applies: an authentication that cannot be sealed into the
# log must not proceed (fail-closed).
auditrequired(): int
{
	(rc, nil) := sys->stat(Audit->ONFILE);
	return rc == 0;
}

# Current epoch seconds, or 0 if no clock is available (throttle then fails open
# rather than risk a permanent lock without a way to time the cooldown).
guardnow(): int
{
	if(daytime == nil)
		return 0;
	return daytime->now();
}

# Find an existing guard for user, or nil. Read-only (does not allocate).
findguard(user: string): ref Acctguard
{
	for(l := guards; l != nil; l = tl l)
		if((hd l).user == user)
			return hd l;
	return nil;
}

# Seconds remaining on user's lockout, or 0 if not locked. Expired locks are
# cleared here (fresh window on next attempt), so a legitimate user is never
# stranded beyond one cooldown.
lockremaining(user: string): int
{
	g := findguard(user);
	if(g == nil || g.lockeduntil == 0)
		return 0;
	now := guardnow();
	if(now == 0)			# no clock — cannot enforce a timed lock
		return 0;
	if(now >= g.lockeduntil){
		g.lockeduntil = 0;
		g.fails = 0;
		return 0;
	}
	return g.lockeduntil - now;
}

# Record a wrong-password attempt for user; lock the account once the threshold
# is reached. Returns the new consecutive-failure count.
recordfail(user: string): int
{
	g := findguard(user);
	if(g == nil){
		g = ref Acctguard(user, 0, 0);
		guards = g :: guards;
	}
	g.fails++;
	now := guardnow();
	if(g.fails >= Maxfail && now > 0)
		g.lockeduntil = now + Locksecs;
	return g.fails;
}

# Clear failure state after a successful authentication.
recordok(user: string)
{
	g := findguard(user);
	if(g != nil){
		g.fails = 0;
		g.lockeduntil = 0;
	}
}

# Note a wrong-password attempt and emit the lock audit event exactly once, at
# the moment the threshold is crossed. Called from every branch that means the
# client failed to prove knowledge of the password (see pakserver).
notefail(user: string)
{
	nf := recordfail(user);
	if(nf == Maxfail){
		log(sys->sprint("account %s locked after %d failed attempts (%ds cooldown)", user, nf, Locksecs));
		auditlog("secstore", "authlock",
			sys->sprint("user=%s fails=%d locksecs=%d", auditval(user), nf, Locksecs));
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	ssl = load SSL SSL->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	dialler = load Dial Dial->PATH;
	str = load String String->PATH;
	audit = load Audit Audit->PATH;	# optional: audit log emitter
	if(audit != nil)
		audit->init();
	daytime = load Daytime Daytime->PATH;	# clock for the lockout cooldown
	if(daytime == nil)
		log("warning: daytime unavailable; failed-attempt lockout disabled");

	login = load Login Login->PATH;
	secstore = load Secstore Secstore->PATH;
	if(kr == nil || ssl == nil || base64 == nil || dialler == nil || str == nil || login == nil || secstore == nil)
		fatal("cannot load required modules");
	secstore->init();

	initPAKparams();

	# Keep secstore protocol compatibility, including cansecstore (m=0), but
	# default InferNode deployments to loopback. Upstream secstore assumes the
	# service lives on a trusted auth network; InferNode's common case is a
	# single host with logon/factotum connecting over localhost. Exposing the
	# service on all interfaces should therefore be explicit via -a.
	#
	# 127.0.0.1 by NUMBER, not "localhost" by name. This is a
	# same-host control connection; making it depend on a name
	# service means the login chain fails on any system where cs is
	# not (yet) running -- which is every bare-metal boot. Hosted
	# systems resolve either form identically.
	#
	addr := "tcp!127.0.0.1!5356";
	arg := load Arg Arg->PATH;
	if(arg != nil){
		arg->init(args);
		arg->setusage("auth/secstored [-d] [-s storedir] [-a addr]");
		while((o := arg->opt()) != 0)
			case o {
			'd' =>	debug++;
			's' =>	storedir = arg->earg();
			'a' =>	addr = arg->earg();
			* =>	arg->usage();
			}
		args = arg->argv();
		if(args != nil)
			arg->usage();
	}

	# Ensure store directory exists
	sys->create(storedir, Sys->OREAD, Sys->DMDIR | 8r700);

	warnremote(addr);
	log(sys->sprint("listening on %s, store=%s", addr, storedir));

	conn := dialler->announce(addr);
	if(conn == nil)
		fatal(sys->sprint("can't announce %s: %r", addr));

	for(;;){
		lconn := dialler->listen(conn);
		if(lconn == nil){
			log(sys->sprint("listen failed: %r"));
			continue;
		}
		spawn serve(lconn);
	}
}

loopbackaddr(addr: string): int
{
	return (len addr >= 14 && addr[0:14] == "tcp!localhost!")
		|| (len addr >= 14 && addr[0:14] == "tcp!127.0.0.1!");
}

warnremote(addr: string)
{
	if(loopbackaddr(addr))
		return;
	log(sys->sprint("warning: non-loopback secstore listener %s is exposed intentionally; reachable clients can probe account existence via cansecstore (m=0) and attempt online password guessing; prefer a private overlay or firewall when using -a", addr));
}

serve(lconn: ref Dial->Connection)
{
	sys->pctl(Sys->NEWPGRP, nil);

	dfd := dialler->accept(lconn);
	if(dfd == nil){
		log("accept failed");
		return;
	}

	if(debug)
		log("new connection");

	# Wrap with SSL
	(err, sslconn) := ssl->connect(dfd);
	if(err != nil){
		log("ssl connect: " + err);
		return;
	}

	if(debug)
		log("ssl ok");

	# PAK authentication
	(user, ver, claimed) := pakserver(sslconn);
	if(user == nil){
		log("PAK auth failed");
		if(claimed != nil)
			auditlog("secstore", "authfail", "user=" + auditval(claimed));
		else
			auditlog("secstore", "authfail", "");
		return;
	}

	log("authenticated: " + user);
	if(auditlog("secstore", "authok", "user=" + auditval(user)) < 0 && auditrequired()){
		log("audit sink unavailable — refusing session (fail-closed)");
		return;
	}

	# Send OK
	sys->fprint(sslconn.dfd, "OK");

	# Handle file operations
	fileloop(sslconn, user, ver);
}

# ── PAK Server Protocol ──────────────────────────────────────

pakserver(conn: ref Dial->Connection): (string, string, string)
{
	fd := conn.dfd;
	params: ref PAKparams;

	# Read client hello: "secstore\tPAK\nC=<user>\nm=<hexm>\n"
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0){
		if(debug)
			log(sys->sprint("PAK initial read failed: n=%d: %r", n));
		return (nil, nil, nil);
	}
	hello := string buf[0:n];

	# Parse the hello
	if(debug)
		log(sys->sprint("PAK hello (%d bytes): %q", len hello, hello));
	(nf, flds) := sys->tokenize(hello, "\n");
	if(debug)
		log(sys->sprint("PAK tokenized: %d fields", nf));
	if(nf < 3){
		writerr(fd, "bad hello");
		return (nil, nil, nil);
	}

	# First line: "<version>\tPAK"
	hdr := hd flds; flds = tl flds;
	if(debug)
		log(sys->sprint("PAK hdr: %q", hdr));
	if(len hdr <= 4 || hdr[len hdr-4:] != "\tPAK"){
		writerr(fd, "bad protocol");
		return (nil, nil, nil);
	}
	ver := hdr[0:len hdr-4];
	params = pakparams(ver);
	if(params == nil){
		writerr(fd, "bad protocol");
		return (nil, nil, nil);
	}
	# the version 4 exchange has no ML-KEM: its accounts are spoken to
	# at version 5, and a client of it told so
	if(ver == VERSION4){
		writerr(fd, "bad protocol: secstore4 is spoken as secstore5");
		return (nil, nil, nil);
	}
	if(ver != VERSION5 && login->cnsamode()){
		writerr(fd, "bad protocol: CNSA mode: secstore5 alone");
		return (nil, nil, nil);
	}

	# C=<user>
	C := ex("C=", hd flds); flds = tl flds;
	if(C == nil){
		writerr(fd, "no user");
		return (nil, nil, nil);
	}

	# m=<hexm>
	hexm := ex("m=", hd flds);
	if(hexm == nil){
		writerr(fd, "no m");
		return (nil, nil, C);
	}

	# Handle cansecstore probe (m=0)
	if(hexm == "0"){
		if(readverifiers(C) != nil)
			sys->fprint(fd, "!account exists");
		else
			sys->fprint(fd, "!no account");
		return (nil, nil, nil);	# probe, not an auth attempt
	}

	# Reject early if this account is in its failed-attempt cooldown, before
	# spending any crypto — this is the AC-7 / FIA_AFL.1 enforcement point.
	rem := lockremaining(C);
	if(rem > 0){
		log(sys->sprint("rejected locked account %s (%ds remaining)", C, rem));
		writerr(fd, sys->sprint("account locked; retry in %ds", rem));
		auditlog("secstore", "authlock", sys->sprint("user=%s reason=throttled remaining=%d", auditval(C), rem));
		return (nil, nil, C);
	}

	# Look up user's PAK verifier
	verifiers := readverifiers(C);
	if(verifiers == nil){
		writerr(fd, "no account");
		return (nil, nil, C);
	}
	hexHi: string;
	for(vl := verifiers; vl != nil; vl = tl vl)
		if((hd vl).t0 == verver(ver))
			hexHi = (hd vl).t1;
	if(hexHi == nil){
		writerr(fd, "account version mismatch");
		return (nil, nil, C);
	}
	Hi := IPint.strtoip(hexHi, 64);
	if(!goodverifier(verver(ver), hexHi)){
		log(sys->sprint("the verifier kept for %s is not one", C));
		writerr(fd, "no account");
		return (nil, nil, C);
	}
	m := IPint.strtoip(hexm, 64);

	# m is the client's, and must be an element of the group: 0 < m < p.
	# Only the string "0" was looked for (the probe, above).  Any other
	# spelling of zero, or p, or a multiple of it, made sigma below 0
	# whatever y was, and the k sent next the hash of things the client
	# knows and the password's verifier: one connection, and the
	# password could be searched for with no further word to this
	# server, the lockout never counting past one.  An m that is no
	# number was a nil dereference.  Counted as a failed attempt.
	if(m == nil || m.cmp(IPint.inttoip(0)) <= 0 || m.cmp(params.p) >= 0){
		log(sys->sprint("rejected m outside the group for %s", C));
		writerr(fd, "bad m");
		auditlog("secstore", "authfail", sys->sprint("user=%s reason=badm", auditval(C)));
		notefail(C);
		return (nil, nil, C);
	}

	# Server picks random y, computes mu = g^y mod p
	y := mod(IPint.random(exponentbits(ver), exponentbits(ver)), params.q);
	if(y.eq(IPint.inttoip(0)))
		y = IPint.inttoip(1);
	mu := params.g.expmod(y, params.p);
	hexmu := mu.iptostr(64);

	# Compute shared secret: sigma = (m * Hi)^y mod p
	sigma := mod(m.mul(Hi), params.p).expmod(y, params.p);
	hexsigma := sigma.iptostr(64);

	kc, session: array of byte;
	if(ver == VERSION5){
		# mu and S; then the client's ML-KEM key, the server's
		# ciphertext for it as the verifier unmasks it, and the
		# server's proof, made from both secrets
		if(sys->fprint(fd, "mu=%s\nS=%s\n", hexmu, sname) < 0)
			return (nil, nil, C);
		n = sys->read(fd, buf, len buf);
		if(n <= 0){
			notefail(C);
			return (nil, nil, C);
		}
		eks := ex("ek=", string buf[0:n]);
		if(eks != nil && len eks > 0 && eks[len eks-1] == '\n')
			eks = eks[0:len eks-1];
		msg: array of byte;
		if(eks != nil)
			msg = base64->dec(eks);
		if(msg == nil || len msg != Keyring->MLKEM1024_PKLEN){
			writerr(fd, "bad ML-KEM key");
			auditlog("secstore", "authfail", sys->sprint("user=%s reason=badkey", auditval(C)));
			notefail(C);
			return (nil, nil, C);
		}
		rl := 32;
		ek := array[len msg] of byte;
		ek[0:] = msg[0:len msg-rl];
		ek[len msg-rl:] = secstore->pak5mask(C, sname, hexm, hexmu, hexsigma, hexHi, msg[len msg-rl:]);
		ct, k: array of byte;
		{
			(ct, k) = kr->mlkem1024_encaps(ek);
		} exception {
		"*" =>
			ct = nil;
		}
		if(ct == nil || k == nil){
			# FIPS 203's check of the key's clear half: it says
			# nothing of the password
			writerr(fd, "bad ML-KEM key");
			auditlog("secstore", "authfail", sys->sprint("user=%s reason=badkey", auditval(C)));
			notefail(C);
			return (nil, nil, C);
		}
		proofs: array of byte;
		(proofs, kc, session) = secstore->pak5keys(C, sname, hexm, hexmu, hexsigma, hexHi, msg, ct, k);
		erasekey(k);
		if(sys->fprint(fd, "ct=%s\nk=%s\n", base64->enc(ct), base64->enc(proofs)) < 0){
			erasekey(session);
			return (nil, nil, C);
		}
	}else{
		# Compute server verification hash
		digest := shorthashver(ver, "server", C, sname, hexm, hexmu, hexsigma, hexHi);
		ks := base64->enc(digest);

		# Send mu, k (server hash), S (server name)
		if(debug)
			log(sys->sprint("PAK sending mu=%s... k=%s S=%s", hexmu[:20], ks, sname));
		if(sys->fprint(fd, "mu=%s\nk=%s\nS=%s\n", hexmu, ks, sname) < 0){
			return (nil, nil, C);
		}
		kc = shorthashver(ver, "client", C, sname, hexm, hexmu, hexsigma, hexHi);
		session = shorthashver(ver, "session", C, sname, hexm, hexmu, hexsigma, hexHi);
	}

	# Read client verification: "k'=<hash>\n"
	n = sys->read(fd, buf, len buf);
	if(n <= 0){
		if(debug)
			log(sys->sprint("PAK client read failed: n=%d", n));
		# The client has already received the server verifier above. A guessing
		# tool can learn that its password guess was wrong from that verifier and
		# then close before sending k'. Count that abort as a failed password proof.
		notefail(C);
		return (nil, nil, C);
	}
	s := string buf[0:n];

	kprime := ex("k'=", s);
	if(kprime == nil){
		# Strip trailing newline
		if(len s > 0 && s[len s - 1] == '\n')
			s = s[:len s - 1];
		kprime = ex("k'=", s);
	}
	if(kprime == nil){
		# An honest client that derived a different session key (wrong password)
		# verifies the server's hash first and writes an error here INSTEAD of a
		# valid k' (secstore.b: "verifier didn't match"). So a normally mistyped
		# password lands here, not the k'-mismatch branch below — count it.
		writerr(fd, "no client verifier");
		notefail(C);
		return (nil, nil, C);
	}
	# Strip trailing newline from kprime
	if(len kprime > 0 && kprime[len kprime - 1] == '\n')
		kprime = kprime[:len kprime - 1];

	# Verify client hash
	if(!secstore->samebytes(base64->dec(kprime), kc)){
		# A client that proceeds with a wrong session key (e.g. a guessing tool
		# that does not self-abort on the server-hash check). Also a failure.
		writerr(fd, "client verifier didn't match");
		notefail(C);
		return (nil, nil, C);
	}

	# Set session secret (direction=1 for server, opposite of client's 0)
	digest := session;

	# Zero sigma
	for(i := 0; i < len hexsigma; i++)
		hexsigma[i] = 0;

	# HMAC-SHA-384 for every version, as the client (secstore(2)): 48
	# bytes each way, as aes_256_gcm needs 32 at the least
	secretin := array[Keyring->SHA384dlen] of byte;
	secretout := array[Keyring->SHA384dlen] of byte;
	# Server reverses client's direction: client out=HMAC("two"), so server in=HMAC("two")
	kr->hmac_sha384(digest, len digest, array of byte "one", secretout, nil);
	kr->hmac_sha384(digest, len digest, array of byte "two", secretin, nil);
	e := ssl->secret(conn, secretin, secretout);
	if(e != nil){
		log("setsecret: " + e);
		return (nil, nil, C);
	}
	erasekey(digest);

	if(sys->fprint(conn.cfd, "alg aes_256_gcm") < 0)
		return (nil, nil, C);

	# Authenticated: clear any accumulated failure state for this account.
	recordok(C);
	# logged in at version 5: the older verifier, kept while the
	# account moved, is done with
	if(ver == VERSION5 && len verifiers > 1){
		e = writeuserfile(C, "PAK", array of byte (VERSION4 + " " + hexHi + "\n"));
		if(e != nil)
			log(sys->sprint("%s: can't drop the older verifier: %s", C, e));
		else
			log(sys->sprint("%s is at version 4's verifier alone", C));
	}
	return (C, ver, C);
}

# ── File Operations ───────────────────────────────────────────

fileloop(conn: ref Dial->Connection, user: string, ver: string)
{
	fd := conn.dfd;
	buf := array[Maxmsg] of byte;
	v4 := ver == VERSION4 || ver == VERSION5;
	shown := 0;	# this session has shown the account's vault key

	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		line := string buf[0:n];
		# Strip trailing newline
		if(len line > 0 && line[len line - 1] == '\n')
			line = line[:len line - 1];

		if(debug)
			log("cmd: " + line);

		# Parse command
		cmd := line;
		arg := "";
		for(i := 0; i < len line; i++){
			if(line[i] == ' '){
				cmd = line[0:i];
				arg = line[i+1:];
				break;
			}
		}

		case cmd {
		"GET" =>
			doget(fd, user, arg);
		"PUT" or "RM" =>
			# A session of an older version reads, and moves the
			# account to version 4, and no more: its stores and
			# removes were never answered, so a refusal could not
			# be said.  It is ended.
			if(!v4){
				log(sys->sprint("%s: %s in a %s session refused: log in at version 4", user, cmd, ver));
				return;
			}
			# Once a second factor is enrolled the account's
			# files change only in a session that has shown its
			# vault key: the password alone proved, the vault
			# could be replaced by one of the password holder's
			# own making, or removed.
			why: string;
			if(enrolled(user) && !shown)
				why = "second factor required: show the vault key to change this account's files";
			if(cmd == "PUT"){
				if(doput(fd, user, arg, why) < 0)
					return;
			}else
				dorm(fd, user, arg, why);
		"VERIFIER" =>
			doverifier(fd, user, ver, arg);
		"VAULT?" =>
			if(!v4)
				writerr(fd, "unknown command");
			else if(enrolled(user))
				sys->fprint(fd, "enrolled");
			else
				sys->fprint(fd, "none");
		"VAULTKEY" =>
			if(!v4){
				writerr(fd, "unknown command");
				break;
			}
			want := readvaultkey(user);
			if(want == nil){
				sys->fprint(fd, "none");
				break;
			}
			if(!sameb(vaulthash(arg), want)){
				log(sys->sprint("%s: wrong vault key", user));
				auditlog("secstore", "authfail", sys->sprint("user=%s reason=vaultkey", auditval(user)));
				writerr(fd, "wrong vault key");
				break;
			}
			shown = 1;
			sys->fprint(fd, "OK");
		"ENROLL2FA" =>
			if(!v4){
				writerr(fd, "unknown command");
				break;
			}
			if(enrolled(user) && !shown){
				writerr(fd, "a second factor is already enrolled: show its vault key first");
				break;
			}
			h := vaulthash(arg);
			if(h == nil){
				writerr(fd, "a vault key is 64 hexadecimal digits");
				break;
			}
			e := writeuserfile(user, "VAULTKEY", array of byte ("sha256 " + hex(h) + "\n"));
			if(e != nil){
				log(sys->sprint("%s: can't enrol: %s", user, e));
				writerr(fd, "can't record the vault key");
				break;
			}
			shown = 1;
			log(sys->sprint("%s: second factor enrolled", user));
			auditlog("secstore", "enroll2fa", "user=" + auditval(user));
			sys->fprint(fd, "OK");
		"UNENROLL2FA" =>
			if(!v4){
				writerr(fd, "unknown command");
				break;
			}
			if(!enrolled(user)){
				sys->fprint(fd, "OK");
				break;
			}
			if(!shown){
				writerr(fd, "second factor required: show the vault key first");
				break;
			}
			if(sys->remove(userpath(user, "VAULTKEY")) < 0){
				writerr(fd, sys->sprint("can't remove the vault key's record: %r"));
				break;
			}
			shown = 0;
			log(sys->sprint("%s: second factor no longer enrolled", user));
			auditlog("secstore", "unenroll2fa", "user=" + auditval(user));
			sys->fprint(fd, "OK");
		"BYE" =>
			return;	# break left only the case, and the session went on
		* =>
			writerr(fd, "unknown command");
		}
	}
}

#
# GET.  The answer is a size and then that many bytes; -1 for a file the
# account does not have; or an error.  Any file that could not be
# opened was -1, so one that was there and could not be read (its mode,
# an I/O error) looked like an account with nothing stored, and the
# client saved a new file over it.
#
doget(fd: ref Sys->FD, user: string, name: string)
{
	data: array of byte;
	if(name == "."){
		(l, e) := listing(user);
		if(e != nil){
			writerr(fd, e);
			return;
		}
		data = array of byte l;
	}else{
		if(!safename(name) || reserved(name)){
			writerr(fd, "not a file's name");
			return;
		}
		path := userpath(user, name);
		(ok, d) := sys->stat(path);
		if(ok < 0){
			e := sys->sprint("%r");
			if(nosuchfile(e))
				sys->fprint(fd, "-1");
			else{
				log(sys->sprint("%s: can't stat %s: %s", user, name, e));
				writerr(fd, "can't read " + name);
			}
			return;
		}
		if(d.mode & Sys->DMDIR){
			writerr(fd, "not a file's name");
			return;
		}
		if(d.length > big Maxfilesize){
			writerr(fd, name + " is too long");
			return;
		}
		rfd := sys->open(path, Sys->OREAD);
		if(rfd == nil){
			log(sys->sprint("%s: can't open %s: %r", user, name));
			writerr(fd, "can't read " + name);
			return;
		}
		data = array[int d.length] of byte;
		total := 0;
		while(total < len data){
			n := sys->read(rfd, data[total:], len data - total);
			if(n < 0){
				log(sys->sprint("%s: can't read %s: %r", user, name));
				writerr(fd, "can't read " + name);
				return;
			}
			if(n == 0)
				break;
			total += n;
		}
		data = data[0:total];
		if(debug)
			log(sys->sprint("GET %s: %d bytes", name, total));
	}

	# Send size, then data
	sys->fprint(fd, "%d", len data);
	for(off := 0; off < len data;){
		chunk := len data - off;
		if(chunk > Maxmsg)
			chunk = Maxmsg;
		sys->write(fd, data[off:off+chunk], chunk);
		off += chunk;
	}
}

nosuchfile(e: string): int
{
	return contains(e, "does not exist") || contains(e, "not found");
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

#
# "GET ." is the account's files, a line each as Plan 9's secstore has
# them: the name, a tab, the size, the date (24 characters), and a hash
# of the file (here its SHA-256, in base 64).  The directory's own
# bytes were sent, stat(5) entries and all, the verifier's among them.
#
listing(user: string): (string, string)
{
	dir := userpath(user, "");
	dfd := sys->open(dir, Sys->OREAD);
	if(dfd == nil)
		return (nil, "can't list the account's files");
	s := "";
	for(;;){
		(n, dirs) := sys->dirread(dfd);
		if(n < 0)
			return (nil, "can't list the account's files");
		if(n == 0)
			break;
		for(i := 0; i < n; i++){
			d := dirs[i];
			if((d.mode & Sys->DMDIR) || !safename(d.name) || reserved(d.name) || d.length > big Maxfilesize)
				continue;
			h := filehash(dir + "/" + d.name);
			if(h == nil)
				continue;
			date := "-";
			if(daytime != nil){
				t := daytime->text(daytime->gmt(d.mtime));
				if(len t >= 28)
					date = t[4:28];
			}
			if(len date != 24)
				date = sys->sprint("%-24.24s", date);
			s += sys->sprint("%s\t%bd %s %s\n", d.name, d.length, date, base64->enc(h));
			if(len s > Maxfilesize)
				return (nil, "too many files to list");
		}
	}
	return (s, nil);
}

filehash(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	state: ref DigestState;
	while((n := sys->read(fd, buf, len buf)) > 0)
		state = kr->sha256(buf, n, nil, state);
	if(n < 0)
		return nil;
	digest := array[Keyring->SHA256dlen] of byte;
	kr->sha256(nil, 0, digest, state);
	return digest;
}

#
# PUT, in a version 4 session: answered OK when the file is in place
# (written beside the old one and renamed over it: it was truncated and
# then written, so a stop between left an empty file), or with why not.
# refuse, if set, is why this session may not store: the request is
# read to its end all the same, so that what follows it is a request.
# -1 when the session cannot go on.
#
doput(fd: ref Sys->FD, user: string, name: string, refuse: string): int
{
	# Read size
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return -1;
	ssize := string buf[0:n];
	if(len ssize > 9 || !alldigits(ssize)){
		writerr(fd, "bad size");
		return -1;
	}
	size := int ssize;
	if(size > Maxfilesize){
		writerr(fd, "file too long");
		return -1;
	}

	# Read data
	data := array[size] of byte;
	for(nr := 0; nr < size;){
		n = sys->read(fd, data[nr:], size - nr);
		if(n <= 0)
			return -1;
		nr += n;
	}

	if(refuse != nil){
		log(sys->sprint("%s: PUT %s refused: %s", user, name, refuse));
		writerr(fd, refuse);
		return 0;
	}
	if(!safename(name) || reserved(name)){
		writerr(fd, "not a file's name");
		return 0;
	}
	if(debug)
		log(sys->sprint("PUT %s: %d bytes", name, size));

	e := writeuserfile(user, name, data);
	if(e != nil){
		log(sys->sprint("%s: PUT %s: %s", user, name, e));
		writerr(fd, "can't store " + name);
		return 0;
	}
	sys->fprint(fd, "OK");
	return 0;
}

dorm(fd: ref Sys->FD, user: string, name: string, refuse: string)
{
	if(refuse != nil){
		log(sys->sprint("%s: RM %s refused: %s", user, name, refuse));
		writerr(fd, refuse);
		return;
	}
	if(!safename(name) || reserved(name)){
		writerr(fd, "not a file's name");
		return;
	}
	if(debug)
		log("RM " + name);
	path := userpath(user, name);
	if(sys->remove(path) < 0){
		e := sys->sprint("%r");
		if(nosuchfile(e))
			writerr(fd, name + " does not exist");
		else{
			log(sys->sprint("%s: RM %s: %s", user, name, e));
			writerr(fd, "can't remove " + name);
		}
		return;
	}
	sys->fprint(fd, "OK");
}

#
# VERIFIER version hexHi: the account's verifier, from a session that
# has proved the password.  A session of an older version gives the
# account its version 4 verifier, which is kept beside the old one
# until a version 4 login has worked (so that a verifier made wrongly
# locks nobody out); a version 4 session replaces its verifier (a new
# password).  The verifier was changed by writing the file PAK, with
# PUT or on the host: PAK is no longer a file of the account's.
#
doverifier(fd: ref Sys->FD, user, ver, arg: string)
{
	(nf, f) := sys->tokenize(arg, " \t");
	if(nf != 2 || hd f != VERSION4 || !goodverifier(VERSION4, hd tl f)){
		writerr(fd, "not a version 4 verifier");
		return;
	}
	text := VERSION4 + " " + hd tl f + "\n";
	if(ver != VERSION4 && ver != VERSION5)
		for(vl := readverifiers(user); vl != nil; vl = tl vl){
			(v, h) := hd vl;
			if(v == ver){
				if(v == VERSION1)
					text += h + "\n";
				else
					text += v + " " + h + "\n";
			}
		}
	e := writeuserfile(user, "PAK", array of byte text);
	if(e != nil){
		log(sys->sprint("%s: can't write the verifier: %s", user, e));
		writerr(fd, "can't record the verifier");
		return;
	}
	log(sys->sprint("%s: version 4 verifier recorded (in a %s session)", user, ver));
	auditlog("secstore", "verifier", sys->sprint("user=%s session=%s", auditval(user), ver));
	sys->fprint(fd, "OK");
}

# a verifier is a number of its group, not 0 or 1
goodverifier(ver, hexHi: string): int
{
	params := pakparams(ver);
	if(params == nil || hexHi == nil || len hexHi > 1024)
		return 0;
	for(i := 0; i < len hexHi; i++){
		c := hexHi[i];
		if(!(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/' || c == '='))
			return 0;
	}
	Hi := IPint.strtoip(hexHi, 64);
	return Hi != nil && Hi.cmp(IPint.inttoip(1)) > 0 && Hi.cmp(params.p) < 0;
}

# the account's second factor is enrolled: its vault key's hash is kept
enrolled(user: string): int
{
	(ok, nil) := sys->stat(userpath(user, "VAULTKEY"));
	return ok >= 0;
}

# the hash kept, or nil
readvaultkey(user: string): array of byte
{
	fd := sys->open(userpath(user, "VAULTKEY"), Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return array[0] of byte;	# enrolled, and nothing matches
	(nf, f) := sys->tokenize(string buf[0:n], " \t\n");
	if(nf != 2 || hd f != "sha256")
		return array[0] of byte;
	h := unhex(hd tl f);
	if(h == nil)
		return array[0] of byte;
	return h;
}

# SHA-256 of a vault key given as 64 hexadecimal digits; nil if it is not
vaulthash(hexkey: string): array of byte
{
	k := unhex(hexkey);
	if(k == nil || len k != 32)
		return nil;
	h := array[Keyring->SHA256dlen] of byte;
	kr->sha256(k, len k, h, nil);
	erasekey(k);
	return h;
}

sameb(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int (a[i] ^ b[i]);
	return d == 0;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

unhex(s: string): array of byte
{
	if(len s == 0 || len s % 2 != 0)
		return nil;
	a := array[len s/2] of byte;
	for(i := 0; i < len a; i++){
		h := hexval(s[2*i]);
		l := hexval(s[2*i+1]);
		if(h < 0 || l < 0)
			return nil;
		a[i] = byte (h<<4 | l);
	}
	return a;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

alldigits(s: string): int
{
	if(len s == 0)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

#
# A file of the account's, written whole beside the one it replaces and
# renamed over it, so that at any moment one of them is a whole file.
# nil, or why not.
#
writeuserfile(user, name: string, data: array of byte): string
{
	sys->create(userpath(user, ""), Sys->OREAD, Sys->DMDIR | 8r700);
	path := userpath(user, name);
	tmp := userpath(user, ".new." + name);
	sys->remove(tmp);
	wfd := sys->create(tmp, Sys->OWRITE, 8r600);
	if(wfd == nil)
		return sys->sprint("can't create %s: %r", tmp);
	if(sys->write(wfd, data, len data) != len data){
		e := sys->sprint("can't write %s: %r", tmp);
		wfd = nil;
		sys->remove(tmp);
		return e;
	}
	sys->fwstat(wfd, sys->nulldir);	# commit (stat(5))
	wfd = nil;
	d := sys->nulldir;
	d.name = name;
	if(sys->wstat(tmp, d) < 0){
		# a file server that will not rename onto a name in use
		sys->remove(path);
		if(sys->wstat(tmp, d) < 0){
			e := sys->sprint("can't rename %s to %s: %r", tmp, name);
			sys->remove(tmp);
			return e;
		}
	}
	return nil;
}

# ── PAK Crypto (mirrors secstore.b client code) ──────────────

initPAKparams()
{
	if(paklegacy != nil && pak3 != nil)
		return;
	lpak := ref PAKparams;
	lpak.q = IPint.strtoip("E0F0EF284E10796C5A2A511E94748BA03C795C13", 16);
	lpak.p = IPint.strtoip("C41CFBE4D4846F67A3DF7DE9921A49D3B42DC33728427AB159CEC8CBB"+
		"DB12B5F0C244F1A734AEB9840804EA3C25036AD1B61AFF3ABBC247CD4B384224567A86"+
		"3A6F020E7EE9795554BCD08ABAD7321AF27E1E92E3DB1C6E7E94FAAE590AE9C48F96D9"+
		"3D178E809401ABE8A534A1EC44359733475A36A70C7B425125062B1142D", 16);
	lpak.r = IPint.strtoip("DF310F4E54A5FEC5D86D3E14863921E834113E060F90052AD332B3241"+
		"CEF2497EFA0303D6344F7C819691A0F9C4A773815AF8EAECFB7EC1D98F039F17A32A7E"+
		"887D97251A927D093F44A55577F4D70444AEBD06B9B45695EC23962B175F266895C67D"+
		"21C4656848614D888A4", 16);
	lpak.g = IPint.strtoip("2F1C308DC46B9A44B52DF7DACCE1208CCEF72F69C743ADD4D23271734"+
		"44ED6E65E074694246E07F9FD4AE26E0FDDD9F54F813C40CB9BCD4338EA6F242AB94CD"+
		"410E676C290368A16B1A3594877437E516C53A6EEE5493A038A017E955E218E7819734"+
		"E3E2A6E0BAE08B14258F8C03CC1B30E0DDADFCF7CEDF0727684D3D255F1", 16);
	paklegacy = lpak;

	lpak = ref PAKparams;
	lpak.q = IPint.strtoip("8CF83642A709A097B447997640129DA299B1A47D1EB3750BA308B0FE64F5FBD3", 16);
	lpak.p = IPint.strtoip("87A8E61DB4B6663CFFBBD19C651959998CEEF608660DD0F25D2CEED4"+
		"435E3B00E00DF8F1D61957D4FAF7DF4561B2AA3016C3D91134096FAA3BF4296D"+
		"830E9A7C209E0C6497517ABD5A8A9D306BCF67ED91F9E6725B4758C022E0B1EF"+
		"4275BF7B6C5BFC11D45F9088B941F54EB1E59BB8BC39A0BF12307F5C4FDB70C5"+
		"81B23F76B63ACAE1CAA6B7902D52526735488A0EF13C6D9A51BFA4AB3AD83477"+
		"96524D8EF6A167B5A41825D967E144E5140564251CCACB83E6B486F6B3CA3F79"+
		"71506026C0B857F689962856DED4010ABD0BE621C3A3960A54E710C375F26375"+
		"D7014103A4B54330C198AF126116D2276E11715F693877FAD7EF09CADB094AE9"+
		"1E1A1597", 16);
	lpak.r = IPint.strtoip("F65B7EA7706034A28A29B9436AF161BBF3632483671C60AEE9B1A6A496FFF904"+
		"FCB09731B6C6E16B551CEC2C063910B04E40795D4BEB474DB762E28CC923AE40"+
		"FDBAF05BF7501D0314C3CBE4BAD7329DD473BDF441E7B8B387B402CD0BE7DC53"+
		"4FA6D3C039BDAD133F59DC899FD570A667C453D08150A35CF5E845087BD9ACFA"+
		"8333343375E8EE52965A84C699C59DFEF852EFB96023BEF0FFB2F99C53AC2D94"+
		"CD2969764698B8DDE401DA6AA6BDB3B03B5506D287090F8E852C05EC0BDB3C0C"+
		"4FBEC1A4AB9FE141E8A7C9EADB17D335921B673615A7FC0C92384946B9AB6452", 16);
	lpak.g = IPint.strtoip("3FB32C9B73134D0B2E77506660EDBD484CA7B18F21EF205407F4793A"+
		"1A0BA12510DBC15077BE463FFF4FED4AAC0BB555BE3A6C1B0C6B47B1BC3773BF"+
		"7E8C6F62901228F8C28CBB18A55AE31341000A650196F931C77A57F2DDF463E5"+
		"E9EC144B777DE62AAAB8A8628AC376D282D6ED3864E67982428EBC831D14348F"+
		"6F2F9193B5045AF2767164E1DFC967C1FB3F2E55A4BD1BFFE83B9C80D052B985"+
		"D182EA0ADB2A3B7313D3FE14C8484B1E052588B9B7D2BBD2DF016199ECD06E15"+
		"57CD0915B3353BBB64E0EC377FD028370DF92B52C7891428CDC67EB6184B523D"+
		"1DB246C32F63078490F00EF8D647D148D47954515E2327CFEF98C582664B4C0F"+
		"6CC41659", 16);
	pak3 = lpak;
}

pakparams(version: string): ref PAKparams
{
	initPAKparams();
	if(version == VERSION3 || version == VERSION4 || version == VERSION5)
		return pak3;
	if(version == VERSION1)
		return paklegacy;
	return nil;
}

hashis256(version: string): int
{
	return version == VERSION3 || version == VERSION4;
}

# the verifier a version's exchange uses: version 5's is version 4's
verver(version: string): string
{
	if(version == VERSION5)
		return VERSION4;
	return version;
}

exponentbits(version: string): int
{
	if(version == VERSION3 || version == VERSION4 || version == VERSION5)
		return 320;
	return 240;
}

mod(a, b: ref IPint): ref IPint
{
	return a.div(b).t1;
}

shaz(s: string, digest: array of byte, state: ref DigestState): ref DigestState
{
	a := array of byte s;
	state = kr->sha1(a, len a, digest, state);
	erasekey(a);
	return state;
}

shaz256(s: string, digest: array of byte, state: ref DigestState): ref DigestState
{
	a := array of byte s;
	state = kr->sha256(a, len a, digest, state);
	erasekey(a);
	return state;
}

shorthash(mess: string, C: string, S: string, m: string, mu: string, sigma: string, Hi: string): array of byte
{
	return shorthashver(VERSION1, mess, C, S, m, mu, sigma, Hi);
}

shorthashver(version: string, mess: string, C: string, S: string, m: string, mu: string, sigma: string, Hi: string): array of byte
{
	if(hashis256(version)){
		state := shaz256(mess, nil, nil);
		state = shaz256(C, nil, state);
		state = shaz256(S, nil, state);
		state = shaz256(m, nil, state);
		state = shaz256(mu, nil, state);
		state = shaz256(sigma, nil, state);
		state = shaz256(Hi, nil, state);
		state = shaz256(mess, nil, state);
		state = shaz256(C, nil, state);
		state = shaz256(S, nil, state);
		state = shaz256(m, nil, state);
		state = shaz256(mu, nil, state);
		state = shaz256(sigma, nil, state);
		digest := array[Keyring->SHA256dlen] of byte;
		shaz256(Hi, digest, state);
		return digest;
	}

	state := shaz(mess, nil, nil);
	state = shaz(C, nil, state);
	state = shaz(S, nil, state);
	state = shaz(m, nil, state);
	state = shaz(mu, nil, state);
	state = shaz(sigma, nil, state);
	state = shaz(Hi, nil, state);
	state = shaz(mess, nil, state);
	state = shaz(C, nil, state);
	state = shaz(S, nil, state);
	state = shaz(m, nil, state);
	state = shaz(mu, nil, state);
	state = shaz(sigma, nil, state);
	digest := array[Keyring->SHA1dlen] of byte;
	shaz(Hi, digest, state);
	return digest;
}

erasekey(a: array of byte)
{
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}

# ── User/File Management ─────────────────────────────────────

# The account's verifiers, (version, hexHi) each: one, or two while it
# moves to a newer version.  A line of one field is version 1's.
readverifiers(user: string): list of (string, string)
{
	if(!safename(user))
		return nil;
	path := storedir + "/" + user + "/PAK";
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		# A verifier being replaced was once removed before the new
		# one, PAK.new, was renamed to it (the login screen's move
		# of an account to a newer version): a stop between the two
		# left an account that could neither be logged in to nor
		# made again.  The rename is finished here.
		(ok, nil) := sys->stat(path + ".new");
		if(ok < 0)
			return nil;
		d := sys->nulldir;
		d.name = "PAK";
		if(sys->wstat(path + ".new", d) < 0)
			return nil;
		log(sys->sprint("%s: PAK.new, left by a move that stopped, is PAK again", user));
		fd = sys->open(path, Sys->OREAD);
		if(fd == nil)
			return nil;
	}
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	vl: list of (string, string);
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nf, flds) := sys->tokenize(hd lines, " \t");
		if(nf == 1)
			vl = (VERSION1, hd flds) :: vl;
		else if(nf >= 2){
			version := hd flds;
			if(version == VERSION1 || version == VERSION3 || version == VERSION4)
				vl = (version, hd tl flds) :: vl;
		}
	}
	return vl;
}

userpath(user: string, name: string): string
{
	if(name == "" || name == nil)
		return storedir + "/" + user;
	return storedir + "/" + user + "/" + name;
}

# One name of a directory, with nothing in it that a line of a listing
# or of the log could be broken by.
safename(name: string): int
{
	if(name == nil || len name == 0 || len array of byte name > 255)
		return 0;
	if(name == ".." || name == ".")
		return 0;
	for(i := 0; i < len name; i++){
		c := name[i];
		if(c == '/' || c == '\\' || c <= ' ' || c == 16r7f || c == 16rFFFD)
			return 0;
	}
	return 1;
}

# The names in an account's directory that are not its files: the
# server's own records and what it writes beside a file it replaces,
# and the client's key slots.  PAK was fetched, stored and removed like
# any file: an account could be given another verifier with PUT.
reserved(name: string): int
{
	return name[0] == '.' || name == "PAK" || name == "PAK.new" || name == "VAULTKEY" || name == "2fa";
}

# ── Utilities ─────────────────────────────────────────────────

ex(tag: string, s: string): string
{
	if(len s < len tag || s[0:len tag] != tag)
		return nil;
	return s[len tag:];
}

writerr(fd: ref Sys->FD, s: string)
{
	sys->fprint(fd, "!%s", s);
}

log(s: string)
{
	sys->fprint(sys->fildes(2), "secstored: %s\n", s);
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "secstored: %s\n", s);
	raise "fail:error";
}

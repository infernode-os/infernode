implement Createsignerkey;

include "sys.m";
	sys: Sys;

include "draw.m";

include "daytime.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";
	login: Login;

include "arg.m";

# signer key never expires
SKexpire:       con 0;

# size in bits of modulus for public keys
PKmodlen:		con 2048;
Minmodlen:		con 2048;

# size in bits of modulus for diffie hellman
DHmodlen:		con 2048;

algs := array[] of {"ed25519", "mldsa65", "mldsa87", "slhdsa192s", "slhdsa256s", "rsa", "elgamal", "dsa"};	# first entry is default (ed25519 for modern security)

Createsignerkey: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# CNSA 2.0: bind the certificate hash to the signing key's strength.
# ML-DSA / SLH-DSA (FIPS 204/205, NIST Cat >=3) keys pair with SHA-384;
# classical keys keep SHA-256 so pre-existing certs verify unchanged. The
# chosen name is stored in the certificate, so any verifier re-hashes to match.
certhash(sk: ref Keyring->SK): string
{
	if(sk != nil && sk.sa != nil)
		case sk.sa.name {
		"mldsa65" or "mldsa87" or "slhdsa192s" or "slhdsa256s" =>
			return "sha384";
		}
	return "sha256";
}

certdigest(sk: ref Keyring->SK, buf: array of byte): ref Keyring->DigestState
{
	if(certhash(sk) == "sha384")
		return kr->sha384(buf, len buf, nil, nil);
	return kr->sha256(buf, len buf, nil, nil);
}

init(nil: ref Draw->Context, argv: list of string)
{
	err: string;

	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		loaderr(Keyring->PATH);
	arg := load Arg Arg->PATH;
	if(arg == nil)
		loaderr(Arg->PATH);

	login = load Login Login->PATH;
	if(login == nil)
		loaderr(Login->PATH);

	arg->init(argv);
	arg->setusage("createsignerkey [-a algorithm] [-c] [-f keyfile] [-e ddmmyyyy] [-b size-in-bits] name-of-owner");
	alg := "";
	# CNSA 2.0 mode, by /env/cnsamode or -c wherever it is among the
	# options: a rule for the key made, not a default.  It chose the
	# algorithm only when none was given, so -a rsa -b 512 made a
	# 512-bit RSA signer in the mode, and -a rsa -c and -c -a rsa made
	# different keys.
	cnsa := login->cnsamode();
	filename := "/keydb/signerkey";
	expire := SKexpire;
	bits := 0;
	while((c := arg->opt()) != 0){
		case c {
		'a' =>
			alg = arg->arg();
			if(alg == nil)
				arg->usage();
			for(i:=0;; i++){
				if(i >= len algs)
					error(sys->sprint("unknown algorithm: %s", alg));
				else if(alg == algs[i])
					break;
			}
		'c' =>
			cnsa = 1;
		'f' or 'k' =>
			filename = arg->earg();
		'e' =>
			s := arg->earg();
			(err, expire) = checkdate(s);
			if(err != nil)
				error(err);
		'b' =>
			s := arg->earg();
			bits = int s;
			# 2048 is the least modulus anything here still takes
			# for a signature (SP 800-131A); it was 32, and a
			# 32-bit signer's own certificate did not verify.
			if(bits < Minmodlen || bits > 4096)
				error(sys->sprint("modulus must be in the range of %d to 4096 bits", Minmodlen));
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();
	arg = nil;

	owner := hd argv;

	if(cnsa){
		if(alg == nil)
			alg = Login->CNSAsig;
		if((err = login->cnsaalg(alg)) != nil)
			error(err);
		if(bits != 0)
			error("CNSA mode: ML-DSA-87 has one size; -b is not taken");
	}
	if(alg == nil)
		alg = algs[0];
	if(bits == 0)
		bits = PKmodlen;
	else if(alg != "rsa" && alg != "elgamal" && alg != "dsa")
		error(sys->sprint("-b: a %s key has one size", alg));

	# generate a local key, self-signed
	info := ref Keyring->Authinfo;
	info.mysk = kr->genSK(alg, owner, bits);
	if(info.mysk == nil)
		error(sys->sprint("algorithm %s not configured in system", alg));
	info.mypk = kr->sktopk(info.mysk);
	info.spk = kr->sktopk(info.mysk);
	myPKbuf := array of byte kr->pktostr(info.mypk);
	state := certdigest(info.mysk, myPKbuf);
	info.cert = kr->sign(info.mysk, expire, state, certhash(info.mysk));
	# sign gives nil when it fails: the file was then written with no certificate
	if(info.cert == nil)
		error("can't sign the key made");

	# The realm's Diffie-Hellman modulus, which auth(2) uses between
	# holders of this signer's certificates: RFC 3526's 2048-bit group,
	# and in CNSA mode its 3072-bit one (the file had 2048 bits in the
	# mode too).  Both have generator 2.
	if(cnsa){
		(p, nil) := login->group(Login->CNSAgroup);
		if(p == nil)
			error("no 3072-bit group");
		info.alpha = IPint.inttoip(2);
		info.p = p;
	}else
		(info.alpha, info.p) = kr->dhparams(DHmodlen);
	if(cnsa && (err = login->cnsakey(info)) != nil)
		error("the key made is not CNSA mode's: " + err);

	if((err = private(filename)) != nil)
		error(err);
	if(kr->writeauthinfo(filename, info) < 0)
		error(sys->sprint("can't write signerkey file %s: %r", filename));
}

loaderr(s: string)
{
	error(sys->sprint("can't load %s: %r", s));
}

error(s: string)
{
	sys->fprint(sys->fildes(2), "createsignerkey: %s\n", s);
	raise "fail:error";
}

#
# A file that is already there keeps its mode when a key is written to
# it: writeauthinfo opens it and truncates it, and makes it, mode 600,
# only if it is not there. A signer's key written over a file made by
# touch(1) was readable by every user of the host. The mode is put
# right before the key goes in, or the file is refused; what is not a
# file on a file server (a pipe, a device, a file2chan) is left alone.
#
private(file: string): string
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		fd = sys->open(file, Sys->OWRITE);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || (d.mode & Sys->DMDIR) || d.dtype != 'U' && d.dtype != 'M')
		return nil;
	if((d.mode & 8r077) == 0)
		return nil;
	nd := sys->nulldir;
	nd.mode = d.mode & ~8r077;
	if(sys->fwstat(fd, nd) < 0)
		return sys->sprint("%s is open to other users (mode %uo) and its mode cannot be changed: %r", file, d.mode & 8r777);
	return nil;
}

#
# ddmmyyyy: the last second of that day, local time.
# The month was not tested for being less than 1 (the day was, twice), so
# month 00 was December of the year before; a day past its month's end
# was a day of the next; the hour was set to 24, the day after; a year
# past 2038 does not fit an expiry time and came out as another year
# (2170 as 2033); and "1x" was day 1.
#
checkdate(word: string): (string, int)
{
	if(len word != 8)
		return ("!date must be in form ddmmyyyy", 0);
	for(i := 0; i < len word; i++)
		if(word[i] < '0' || word[i] > '9')
			return ("!date must be in form ddmmyyyy", 0);

	daytime := load Daytime Daytime->PATH;
	if(daytime == nil)
		loaderr(Daytime->PATH);

	now := daytime->now();

	tm := daytime->local(now);
	tm.sec = 59;
	tm.min = 59;
	tm.hour = 23;

	tm.mday = int word[0:2];
	if(tm.mday > 31 || tm.mday < 1)
		return ("!bad day of month", 0);

	tm.mon = int word[2:4] - 1;
	if(tm.mon > 11 || tm.mon < 0)
		return ("!bad month", 0);

	tm.year = int word[4:8] - 1900;
	if(tm.year < 70)
		return ("!bad year", 0);

	newdate := daytime->tm2epoch(tm);
	# the date as it was taken: tm2epoch counts days and seconds from
	# the fields whatever they are
	back := daytime->gmt(newdate + tm.tzoff);
	if(back.year != tm.year)
		return ("!year too late: an expiry time ends in January 2038", 0);
	if(back.mon != tm.mon || back.mday != tm.mday)
		return ("!no such day in that month", 0);
	# the zone was today's: on that day the clocks may be an hour off it
	newdate -= daytime->local(newdate).tzoff - tm.tzoff;
	if(newdate < now)
		return ("!expiration date must be in the future", 0);

	return (nil, newdate);
}

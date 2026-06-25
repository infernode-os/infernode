implement Createsignerkey;

include "sys.m";
	sys: Sys;

include "draw.m";

include "daytime.m";

include "keyring.m";
	kr: Keyring;

include "arg.m";

# signer key never expires
SKexpire:       con 0;

# size in bits of modulus for public keys
PKmodlen:		con 2048;

# size in bits of modulus for diffie hellman
DHmodlen:		con 2048;

algs := array[] of {"ed25519", "mldsa65", "mldsa87", "slhdsa192s", "slhdsa256s", "rsa", "elgamal", "dsa"};	# first entry is default (ed25519 for modern security)

Createsignerkey: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# CNSA 2.0 strict mode: read the /env/cnsamode policy flag (off by default).
# When set, CNSA-strict parameters (here, ML-DSA-87) become the defaults.
# Non-CNSA deployments leave the flag unset and are unchanged.
cnsamode(): int
{
	fd := sys->open("/env/cnsamode", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[8] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return 0;
	c := buf[0];
	return c != byte '0' && c != byte 'n' && c != byte 'N' && c != byte '\n';
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

	arg->init(argv);
	arg->setusage("createsignerkey [-a algorithm] [-c] [-f keyfile] [-e ddmmyyyy] [-b size-in-bits] name-of-owner");
	alg := algs[0];
	if(cnsamode())
		alg = "mldsa87";	# CNSA 2.0 strict: ML-DSA-87 default (FIPS 204, Cat 5)
	filename := "/keydb/signerkey";
	expire := SKexpire;
	bits := PKmodlen;
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
			# CNSA 2.0 mode: ML-DSA-87 signer (FIPS 204, NIST Category 5).
			alg = "mldsa87";
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
			if(bits < 32 || bits > 4096)
				error("modulus must be in the range of 32 to 4096 bits");
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();
	arg = nil;

	owner := hd argv;

	# generate a local key, self-signed
	info := ref Keyring->Authinfo;
	info.mysk = kr->genSK(alg, owner, bits);
	if(info.mysk == nil)
		error(sys->sprint("algorithm %s not configured in system", alg));
	info.mypk = kr->sktopk(info.mysk);
	info.spk = kr->sktopk(info.mysk);
	myPKbuf := array of byte kr->pktostr(info.mypk);
	state := kr->sha256(myPKbuf, len myPKbuf, nil, nil);
	info.cert = kr->sign(info.mysk, expire, state, "sha256");

	(info.alpha, info.p) = kr->dhparams(DHmodlen);

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

checkdate(word: string): (string, int)
{
	if(len word != 8)
		return ("!date must be in form ddmmyyyy", 0);

	daytime := load Daytime Daytime->PATH;
	if(daytime == nil)
		loaderr(Daytime->PATH);

	now := daytime->now();

	tm := daytime->local(now);
	tm.sec = 59;
	tm.min = 59;
	tm.hour = 24;

	tm.mday = int word[0:2];
	if(tm.mday > 31 || tm.mday < 1)
		return ("!bad day of month", 0);

	tm.mon = int word[2:4] - 1;
	if(tm.mon > 11 || tm.mday < 0)
		return ("!bad month", 0);

	tm.year = int word[4:8] - 1900;
	if(tm.year < 70)
		return ("!bad year", 0);

	newdate := daytime->tm2epoch(tm);
	if(newdate < now)
		return ("!expiration date must be in the future", 0);

	return (nil, newdate);
}

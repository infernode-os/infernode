implement Mkauthinfo;

#
#  sign a new key to produce a certificate
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";
	auth: Auth;

include "daytime.m";
	daytime: Daytime;

include "arg.m";

Mkauthinfo: module{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->open("/dev/cons", sys->OWRITE);

	kr = load Keyring Keyring->PATH;

	auth = load Auth Auth->PATH;
	if(auth == nil)
		nomod(Auth->PATH);

	daytime = load Daytime Daytime->PATH;
	if(daytime == nil) 
		nomod(Daytime->PATH);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);
	arg->init(args);
	arg->setusage("auth/mkauthinfo [-k keyspec] [-e ddmmyyyy] user [keyfile]");
	keyspec := "key=default";
	expiry := 0;
	while((o := arg->opt()) != 0)
		case o {
		'k' =>
			keyspec = arg->earg();
		'e' =>
			expiry = parsedate(arg->earg());
		* =>
			arg->usage();
		}
	args = arg->argv();
	if(args == nil)
		arg->usage();
	user := hd args;
	args = tl args;
	dstfile := "/fd/1";
	if(args != nil)
		dstfile = hd args;
	arg = nil;

	# a key file is lines, the owner one of them: with a newline in the
	# name, or no name, the file written could not be read back, and the
	# command said it had worked
	if(user == nil)
		fatal("the user's name is empty");
	for(i := 0; i < len user; i++)
		if(user[i] < ' ' || user[i] == 16r7f)
			fatal("the user's name has a control character in it");

	sai := auth->key(keyspec);
	if(sai == nil){
		sys->fprint(stderr, "sign: can't find key matching %q: %r\n", keyspec);
		raise "fail:no key";
	}

	info := ref Keyring->Authinfo;
	info.alpha = sai.alpha;
	info.p = sai.p;
	info.mysk = kr->genSKfromPK(sai.spk, user);
	info.mypk = kr->sktopk(info.mysk);
	info.spk = sai.mypk;
	pkbuf := array of byte kr->pktostr(info.mypk);
	state := certdigest(sai.mysk, pkbuf);
	info.cert = kr->sign(sai.mysk, expiry, state, certhash(sai.mysk));
	if((err := private(dstfile, args == nil)) != nil)
		fatal(err);
	if(kr->writeauthinfo(dstfile, info) < 0){
		sys->fprint(stderr, "sign: error writing certificate: %r\n");
		raise "fail:write error";
	}
}

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

#
# The secret key is in what is written. A file that is already there
# keeps its mode (writeauthinfo opens it and truncates it), and one the
# shell made for a redirection of standard output is mode 644: the key
# was then readable by every user of the host. The mode is put right
# before the key goes in, or the file is refused; what is not a file on
# a file server (a pipe, the console, a file2chan) is left alone.
#
private(file: string, stdout: int): string
{
	fd: ref Sys->FD;
	if(stdout)
		fd = sys->fildes(1);
	else{
		fd = sys->open(file, Sys->OREAD);
		if(fd == nil)
			fd = sys->open(file, Sys->OWRITE);
	}
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || (d.mode & Sys->DMDIR) || d.dtype != 'U' && d.dtype != 'M')
		return nil;
	if((d.mode & 8r077) == 0)
		return nil;
	nd := sys->nulldir;
	nd.mode = d.mode & ~8r077;
	if(sys->fwstat(fd, nd) < 0){
		if(stdout)
			file = "standard output";
		return sys->sprint("%s is open to other users (mode %uo) and its mode cannot be changed: %r", file, d.mode & 8r777);
	}
	return nil;
}

#
# ddmmyyyy: the last second of that day, local time.
# The month was not tested for being less than 1 (the day was, twice), so
# month 00 was December of the year before; a day past its month's end
# was a day of the next; a year past 2038 does not fit an expiry time and
# came out as another (2170 as 2033); "1x" was day 1; and the time of day
# was the moment the command ran, so a certificate good until the 5th
# ended part of the way through it.
#
parsedate(s: string): int
{
	now := daytime->now();
	tm := daytime->local(now);
	if(s == "permanent")
		return 0;
	if(len s != 8)
		fatal("bad date format "+s+" (expected DDMMYYYY)");
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			fatal("bad date format "+s+" (expected DDMMYYYY)");
	tm.sec = 59;
	tm.min = 59;
	tm.hour = 23;
	tm.mday = int s[0:2];
	if(tm.mday > 31 || tm.mday < 1)
		fatal(sys->sprint("bad day of month %d", tm.mday));
	tm.mon = int s[2:4] - 1;
	if(tm.mon > 11 || tm.mon < 0)
		fatal(sys->sprint("bad month %d", tm.mon + 1));
	tm.year = int s[4:8] - 1900;
	if(tm.year < 70)
		fatal(sys->sprint("bad year %d (year may be no earlier than 1970)", tm.year + 1900));
	expiry := daytime->tm2epoch(tm);
	# the date as it was taken: tm2epoch counts days and seconds from
	# the fields whatever they are
	back := daytime->gmt(expiry + tm.tzoff);
	if(back.year != tm.year)
		fatal(sys->sprint("year %d is too late: an expiry time ends in January 2038", tm.year + 1900));
	if(back.mon != tm.mon || back.mday != tm.mday)
		fatal(sys->sprint("month %d has no day %d", tm.mon + 1, tm.mday));
	# the zone was today's: on that day the clocks may be an hour off it
	expiry -= daytime->local(expiry).tzoff - tm.tzoff;
	if(expiry <= now)
		fatal("expiry date has already passed");
	return expiry;
}

nomod(mod: string)
{
	fatal(sys->sprint("can't load %s: %r",mod));
}

fatal(msg: string)
{
	sys->fprint(stderr, "mkauthinfo: %s\n", msg);
	raise "fail:error";
}

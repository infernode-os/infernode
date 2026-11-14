implement Passwd;

#
# svc/httpd/passwd [-i iterations] user: a line of httpd(8)'s -P
# password file for user, the password read from standard input (its
# first line): user:pbkdf2-sha256:iterations:salt:hash, salt and hash
# in base64, the salt 16 random bytes, the hash PBKDF2-HMAC-SHA-256.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "keyring.m";
	keyring: Keyring;

include "encoding.m";
	base64: Encoding;

Passwd: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	keyring = load Keyring Keyring->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	arg := load Arg Arg->PATH;
	if(keyring == nil || base64 == nil || arg == nil)
		fatal(sys->sprint("cannot load a module: %r"));
	iters := 100000;
	arg->init(argv);
	arg->setusage("svc/httpd/passwd [-i iterations] user");
	while((o := arg->opt()) != 0)
		case o {
		'i' =>	iters = int arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(len argv != 1 || iters < 1000)
		arg->usage();
	user := hd argv;
	for(i := 0; i < len user; i++)
		if(user[i] == ':' || user[i] <= 16r20 || user[i] == 16r7F)
			fatal("a user's name has no colon, blank or control character");
	if(len user > 64)
		fatal("a user's name is at most 64 characters");

	b := array[1024] of byte;
	n := 0;
	while(n < len b) {
		m := sys->read(sys->fildes(0), b[n:], len b - n);
		if(m <= 0)
			break;
		n += m;
		if(hasnl(b[0:n]))
			break;
	}
	pass := string b[0:n];
	for(i = 0; i < len pass; i++)
		if(pass[i] == '\n' || pass[i] == '\r') {
			pass = pass[0:i];
			break;
		}
	if(pass == nil)
		fatal("no password on standard input");

	salt := array[16] of byte;
	rfd := sys->open("#c/notquiterandom", Sys->OREAD);
	if(rfd == nil)
		rfd = sys->open("/dev/random", Sys->OREAD);
	if(rfd == nil || sys->readn(rfd, salt, len salt) != len salt)
		fatal(sys->sprint("no random bytes for a salt: %r"));
	h := pbkdf2(array of byte pass, salt, iters);
	sys->print("%s:pbkdf2-sha256:%d:%s:%s\n", user, iters, base64->enc(salt), base64->enc(h));
}

hasnl(b: array of byte): int
{
	for(i := 0; i < len b; i++)
		if(b[i] == byte '\n')
			return 1;
	return 0;
}

# PBKDF2-HMAC-SHA-256 (RFC 8018), one block: as httpd checks it
pbkdf2(pass, salt: array of byte, iters: int): array of byte
{
	s := array[len salt + 4] of byte;
	s[0:] = salt;
	s[len salt:] = array[] of {byte 0, byte 0, byte 0, byte 1};
	u := array[Keyring->SHA256dlen] of byte;
	keyring->hmac_sha256(s, len s, pass, u, nil);
	t := array[len u] of byte;
	t[0:] = u;
	v := array[len u] of byte;
	for(i := 1; i < iters; i++) {
		keyring->hmac_sha256(u, len u, pass, v, nil);
		(u, v) = (v, u);
		for(j := 0; j < len t; j++)
			t[j] ^= u[j];
	}
	return t;
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "passwd: %s\n", s);
	raise "fail:" + s;
}

implement SecstoreBadmProbe;

# For tests/host/secstore_badm_test.sh. Speaks secstore3's PAK to
# secstored as a client that knows no password, with an m that is not
# in the group (p, 2p, p-1: sigma 0 or of order 2), reads what the
# server answers, and tries the guesses given against its k off line.
# Prints "m=which: refused: why" when the server sends no verifier for
# such an m, "m=which: recovered: guess" when a guess matches it, and
# "m=which: no match" (or "answered", for p-1) otherwise. Before secstored checked m, m = p made sigma 0 and k a
# function of the password alone.

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "dial.m";

include "encoding.m";
	base64: Encoding;

include "secstore.m";
	secstore: Secstore;

SecstoreBadmProbe: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

# RFC 5114's 2048-bit p, secstore3's
P: con "87A8E61DB4B6663CFFBBD19C651959998CEEF608660DD0F25D2CEED4"+
	"435E3B00E00DF8F1D61957D4FAF7DF4561B2AA3016C3D91134096FAA3BF4296D"+
	"830E9A7C209E0C6497517ABD5A8A9D306BCF67ED91F9E6725B4758C022E0B1EF"+
	"4275BF7B6C5BFC11D45F9088B941F54EB1E59BB8BC39A0BF12307F5C4FDB70C5"+
	"81B23F76B63ACAE1CAA6B7902D52526735488A0EF13C6D9A51BFA4AB3AD83477"+
	"96524D8EF6A167B5A41825D967E144E5140564251CCACB83E6B486F6B3CA3F79"+
	"71506026C0B857F689962856DED4010ABD0BE621C3A3960A54E710C375F26375"+
	"D7014103A4B54330C198AF126116D2276E11715F693877FAD7EF09CADB094AE9"+
	"1E1A1597";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	secstore = load Secstore Secstore->PATH;
	if(kr == nil || base64 == nil || secstore == nil)
		fail(sys->sprint("cannot load modules: %r"));
	secstore->init();

	args = tl args;
	if(len args < 2)
		usage();
	user := hd args;
	args = tl args;
	which := hd args;
	guesses := tl args;
	addr := "tcp!localhost!5356";

	p := IPint.strtoip(P, 16);
	one := IPint.inttoip(1);
	m: ref IPint;
	sigma: ref IPint;	# what sigma is for that m, whatever y and the password
	case which {
	"p" =>
		m = p;
		sigma = IPint.inttoip(0);
	"2p" =>
		m = p.add(p);
		sigma = IPint.inttoip(0);
	"p-1" =>
		m = p.sub(one);	# order 2: m*Hi has order 2q, sigma is +-(Hi**y); not guessable, but out of the group
		sigma = nil;
	* =>
		usage();
	}
	hexm := m.iptostr(64);

	conn := secstore->dial(addr);
	if(conn == nil)
		fail(sys->sprint("dial %s failed: %r", addr));
	if(sys->fprint(conn.dfd, "secstore3\tPAK\nC=%s\nm=%s\n", user, hexm) < 0)
		fail(sys->sprint("hello write failed: %r"));
	buf := array[8192] of byte;
	n := sys->read(conn.dfd, buf, len buf);
	if(n <= 0)
		fail(sys->sprint("server read failed: %r"));
	reply := string buf[0:n];
	if(len reply < 3 || reply[0:3] != "mu="){
		if(len reply > 0 && reply[0] == '!')
			reply = reply[1:];
		sys->print("m=%s: refused: %s\n", which, reply);
		return;
	}
	(nf, flds) := sys->tokenize(reply, "\n");
	if(nf != 3)
		fail("bad server reply: " + reply);
	hexmu := ex("mu=", hd flds);
	ks := ex("k=", hd tl flds);
	S := ex("S=", hd tl tl flds);
	if(sigma == nil){
		sys->print("m=%s: answered\n", which);
		return;
	}
	hexsigma := sigma.iptostr(64);
	for(; guesses != nil; guesses = tl guesses){
		pwhash := secstore->mkseckey2(hd guesses);
		hexHi := secstore->mkverifier(user, "secstore3", pwhash);
		k := base64->enc(shorthash("server", user, S, hexm, hexmu, hexsigma, hexHi));
		if(k == ks){
			sys->print("m=%s: recovered: %s\n", which, hd guesses);
			return;
		}
	}
	sys->print("m=%s: no match\n", which);
}

# secstore3's shorthash: SHA-256 over the fields twice
shorthash(mess, C, S, m, mu, sigma, Hi: string): array of byte
{
	l := mess :: C :: S :: m :: mu :: sigma :: Hi :: mess :: C :: S :: m :: mu :: sigma :: Hi :: nil;
	st: ref Keyring->DigestState;
	d := array[Keyring->SHA256dlen] of byte;
	for(; l != nil; l = tl l){
		a := array of byte hd l;
		if(tl l == nil)
			kr->sha256(a, len a, d, st);
		else
			st = kr->sha256(a, len a, nil, st);
	}
	return d;
}

ex(tag: string, s: string): string
{
	if(len s < len tag || s[0:len tag] != tag)
		return nil;
	return s[len tag:];
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: secstore_badm_probe user p|2p|p-1 guess...\n");
	raise "fail:usage";
}

fail(msg: string)
{
	sys->fprint(sys->fildes(2), "secstore_badm_probe: %s\n", msg);
	raise "fail:" + msg;
}

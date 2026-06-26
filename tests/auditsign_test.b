implement AuditsignTest;

#
# Unit tests for the audit checkpoint-signing path (factotum sign proto +
# mkauditkey). Deterministic — no factotum, no mount: it exercises the
# exact encode (mkauditkey) and decode (proto/sign.b) transforms plus the
# keyring sign/verify roundtrip, so a break here localizes the bug without
# a live factotum. The wire-protocol half is covered by the integration
# recipe in doc/compliance/audit-log-factotum-signing-DESIGN.md.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "testing.m";
	testing: Testing;
	T: import testing;

AuditsignTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/auditsign_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>	;
	"fail:skip" =>	;
	* =>		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# encode/decode MUST match mkauditkey.b and proto/sign.b exactly: sktostr
# newlines map to '@' and base64 padding '=' maps to '~', so the stored
# value is single-line and '='-free.
encode(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'\n' =>	c = '@';
		'=' =>	c = '~';
		}
		r[len r] = c;
	}
	return r;
}

decode(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'@' =>	c = '\n';
		'~' =>	c = '=';
		}
		r[len r] = c;
	}
	return r;
}

hasany(s, set: string): int
{
	for(i := 0; i < len s; i++)
		for(j := 0; j < len set; j++)
			if(s[i] == set[j])
				return 1;
	return 0;
}

# The encoded key value must survive a factotum key line and an 8192-byte
# write: no '=', no newline, no space.
testEncodingSafe(t: ref T)
{
	sk := kr->genSK("mldsa87", "audit", 0);
	t.assertnotnil(skornil(sk), "genSK mldsa87");
	enc := encode(kr->sktostr(sk));
	t.assert(!hasany(enc, "="), "encoded value has no '='");
	t.assert(!hasany(enc, "\n"), "encoded value has no newline");
	t.assert(!hasany(enc, " \t"), "encoded value has no whitespace");
}

# encode then decode must reproduce sktostr exactly, and reconstruct a key
# that signs verifiably — the full mkauditkey -> proto path, minus the wire.
testRoundtripSignVerify(t: ref T)
{
	sk := kr->genSK("mldsa87", "audit", 0);
	if(sk == nil)
		t.fatal("genSK mldsa87 failed");
	skstr := kr->sktostr(sk);

	# round-trip through the on-wire encoding
	dec := decode(encode(skstr));
	t.assertseq(dec, skstr, "decode(encode(sktostr)) == sktostr");

	sk2 := kr->strtosk(dec);
	if(sk2 == nil)
		t.fatal("strtosk after decode failed");

	# sign with the reconstructed key, verify with the matching public key
	pk := kr->sktopk(sk);
	content := array of byte "audit-checkpoint deadbeef 42";
	state := kr->sha256(content, len content, nil, nil);
	cert := kr->sign(sk2, 0, state, "sha256");
	if(cert == nil)
		t.fatal("sign with reconstructed key failed");
	vstate := kr->sha256(content, len content, nil, nil);
	t.assertne(kr->verify(pk, cert, vstate), 0, "cert verifies under the public key");
}

# A signature over different content must NOT verify (no false accept).
testWrongContentRejected(t: ref T)
{
	sk := kr->genSK("mldsa87", "audit", 0);
	if(sk == nil)
		t.fatal("genSK mldsa87 failed");
	sk2 := kr->strtosk(decode(encode(kr->sktostr(sk))));
	pk := kr->sktopk(sk);

	c1 := array of byte "audit-checkpoint aaaa 1";
	cert := kr->sign(sk2, 0, kr->sha256(c1, len c1, nil, nil), "sha256");

	c2 := array of byte "audit-checkpoint bbbb 2";
	t.asserteq(kr->verify(pk, cert, kr->sha256(c2, len c2, nil, nil)), 0,
		"cert does not verify over different content");
}

skornil(sk: ref Keyring->SK): string
{
	if(sk == nil)
		return "";
	return "ok";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->fprint(sys->fildes(2), "cannot load keyring: %r\n");
		raise "fail:cannot load keyring";
	}

	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("EncodingSafe", testEncodingSafe);
	run("RoundtripSignVerify", testRoundtripSignVerify);
	run("WrongContentRejected", testWrongContentRejected);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

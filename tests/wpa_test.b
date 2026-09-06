implement WpaTest;

#
#	wpakey(2) against published test vectors, and the four-way
#	handshake against a synthetic one.
#
#	Every constant asserted here comes from a document, not from this
#	implementation:
#
#	  RFC 6070            PBKDF2-HMAC-SHA1
#	  IEEE 802.11i H.4    the passphrase-to-PSK mapping
#	  IEEE 802.11i H.3    the PRF
#	  RFC 3394 4.1/4.3/4.6  AES key unwrap
#
#	The handshake frames are not from a document -- there is no
#	published four-way capture with its passphrase -- so they were
#	built to the IEEE 802.11 8.5 layouts and their key schedule,
#	MICs and key wrap computed with an independent implementation of
#	the same primitives (Python's hmac/hashlib and the pyca AES key
#	wrap).  What they prove is that this Limbo composes those
#	primitives the way the standard does, which is exactly where a
#	supplicant goes wrong.  What they cannot prove is that any access
#	point agrees; only a board can say that.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "keyring.m";

include "wpakey.m";
	wpakey: Wpakey;
	Supp, Action: import wpakey;

WpaTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/wpa_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

#
#	RFC 6070.  Test case 4 (16777216 rounds) is left out: it is the
#	same code path as case 3 and takes minutes.
#
testPbkdf2(t: ref T)
{
	pw := array of byte "password";
	salt := array of byte "salt";

	t.assertseq(wpakey->hex(wpakey->pbkdf2_sha1(pw, salt, 1, 20)),
		"0c60c80f961f0e71f3a9b524af6012062fe037a6", "RFC 6070 case 1");
	t.assertseq(wpakey->hex(wpakey->pbkdf2_sha1(pw, salt, 2, 20)),
		"ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957", "RFC 6070 case 2");
	t.assertseq(wpakey->hex(wpakey->pbkdf2_sha1(pw, salt, 4096, 20)),
		"4b007901b765489abead49d926f721d065a429c1", "RFC 6070 case 3");

	# Case 5 needs two blocks and a truncated second one.
	t.assertseq(wpakey->hex(wpakey->pbkdf2_sha1(
			array of byte "passwordPASSWORDpassword",
			array of byte "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, 25)),
		"3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038", "RFC 6070 case 5");

	# Case 6 has a NUL in both the password and the salt, which is
	# why these two are byte arrays rather than strings.
	t.assertseq(wpakey->hex(wpakey->pbkdf2_sha1(
			wpakey->unhex("7061737300776f7264"),
			wpakey->unhex("7361006c74"), 4096, 16)),
		"56fa6aa75548099dcc37d7f03425e0c3", "RFC 6070 case 6");
}

#
#	IEEE 802.11i-2004 Annex H.4: passphrase and network name to PSK.
#
testPsk(t: ref T)
{
	t.assertseq(wpakey->hex(wpakey->psk("password", "IEEE")),
		"f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e",
		"802.11i H.4 case 1");
	t.assertseq(wpakey->hex(wpakey->psk("ThisIsAPassword", "ThisIsASSID")),
		"0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af",
		"802.11i H.4 case 2");
	t.assertseq(wpakey->hex(wpakey->psk(
			"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ")),
		"becb93866bb8c3832cb777c2f559807c8c59afcb6eae734885001300a981cc62",
		"802.11i H.4 case 3");
}

#
#	IEEE 802.11i-2004 Annex H.3: the PRF.  The published cases are
#	PRF-192; PRF-512 is the length the handshake actually uses, and
#	the construction makes every shorter output a prefix of every
#	longer one, so asking for 512 bits and checking the first 192
#	against the published value tests the four-block path against a
#	document.
#
testPrf(t: ref T)
{
	jefe := array of byte "Jefe";
	b1 := array of byte "what do ya want for nothing?";
	want1 := "51f4de5b33f249adf81aeb713a3c20f4fe631446fabdfa58";
	t.assertseq(wpakey->hex(wpakey->prf(jefe, "prefix", b1, 192)),
		want1, "802.11i H.3 PRF-192, second case");

	k2 := array[20] of {* => byte 16raa};
	b2 := array[50] of {* => byte 16rdd};
	t.assertseq(wpakey->hex(wpakey->prf(k2, "prefix", b2, 192)),
		"e1ac546ec4cb636f9976487be5c86be17a0252ca5d8d8df1",
		"802.11i H.3 PRF-192, third case");

	long := wpakey->prf(jefe, "prefix", b1, 512);
	t.asserteq(len long, 64, "PRF-512 is 64 bytes");
	t.assertseq(wpakey->hex(long[0:24]), want1, "PRF-512 extends PRF-192");
}

#
#	RFC 3394 section 4.  Section 4.1 is the case the handshake uses
#	-- a 128-bit KEK -- and the others exercise the longer keys and
#	the multi-block loop.
#
testKeyunwrap(t: ref T)
{
	kek128 := wpakey->unhex("000102030405060708090A0B0C0D0E0F");
	ct41 := wpakey->unhex("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5");
	t.assertseq(wpakey->hex(wpakey->aesunwrap(kek128, ct41)),
		"00112233445566778899aabbccddeeff", "RFC 3394 4.1");

	kek192 := wpakey->unhex("000102030405060708090A0B0C0D0E0F1011121314151617");
	ct43 := wpakey->unhex("031D33264E15D33268F24EC260743EDCE1C6C7DDEE725A936BA814915C6762D2");
	t.assertseq(wpakey->hex(wpakey->aesunwrap(kek192, ct43)),
		"00112233445566778899aabbccddeeff0001020304050607", "RFC 3394 4.3");

	kek256 := wpakey->unhex("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F");
	ct46 := wpakey->unhex("28C9F404C4B810F4CBCCB35CFB87F8263F5786E2D80ED326" +
			"CBC7F0E71A99F43BFB988B9B7A02DD21");
	t.assertseq(wpakey->hex(wpakey->aesunwrap(kek256, ct46)),
		"00112233445566778899aabbccddeeff000102030405060708090a0b0c0d0e0f",
		"RFC 3394 4.6");

	# The integrity check is the whole point: a single changed bit
	# must not yield a key.
	bad := array[len ct41] of byte;
	bad[0:] = ct41;
	bad[9] ^= byte 1;
	t.assert(wpakey->aesunwrap(kek128, bad) == nil, "a tampered wrap does not unwrap");

	# Lengths the standard does not allow.
	t.assert(wpakey->aesunwrap(kek128, ct41[0:20]) == nil, "a length that is not a multiple of 8");
	t.assert(wpakey->aesunwrap(kek128, ct41[0:16]) == nil, "too short to be a wrap");
}

#
#	The synthetic handshake.  passphrase "InfernodeTest" on network
#	"infernode", station 02:00:00:00:00:01, access point
#	02:00:00:00:00:02, with fixed nonces.
#
Msg1 :=
	"020000000001020000000002888e0203005f02008a0010000000000000000120212223242526"+
	"2728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f00000000000000000000000000"+
	"00000000000000000000000000000000000000000000000000000000000000000000000000";
Msg2 :=
	"020000000002020000000001888e0203007502010a0010000000000000000180818283848586"+
	"8788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f00000000000000000000000000"+
	"0000000000000000000000000000000000000085fb4de8038d20a744bca597551d770a001630"+
	"140100000fac040100000fac040100000fac020000";
Msg3 :=
	"020000000001020000000002888e020300970213ca0010000000000000000220212223242526"+
	"2728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f00000000000000000000000000"+
	"000000010203040506000000000000000000008f90b88110986fc0357a7686d6e3aad4003815"+
	"84c6e1725d2943eab0c6077a528244284b033e019beca104e441716c3b207839cc93e00b766f"+
	"442636fc7e723153ca1f730f4f2140e99b";
Msg4 :=
	"020000000002020000000001888e0203005f02030a0010000000000000000200000000000000"+
	"0000000000000000000000000000000000000000000000000000000000000000000000000000"+
	"000000000000000000000000000000000000004cf74b8ef267f8f7bcecc40bc0e2b2390000";
Rekey :=
	"020000000001020000000002888e0203007f0213820010000000000000000300000000000000"+
	"0000000000000000000000000000000000000000000000000000000000000000000000000000"+
	"0000000700000000000000000000000000000071b7b94aefaae06922b0c8d94a78ac440020db"+
	"35abcf16ffd8e8e62f80883c8ca72866c8300d8c1c174d86b2011c4ce17e4b";
Rekeyack :=
	"020000000002020000000001888e0203005f0203020010000000000000000300000000000000"+
	"0000000000000000000000000000000000000000000000000000000000000000000000000000"+
	"000000000000000000000000000000000000001b36e9233c2883217e3508d7e06769850000";
Pmk := "8dcf4ea4ad31ab2a87dff1d94f157c0eb0a5a552370bf4256ac30e1e030e7217";
Snonce := 	"808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f";
Tk := "6e223a19d7abf858e281bd5621c13569";
Gtk1 := "000102030405060708090a0b0c0d0e0f";
Gtk2 := "101112131415161718191a1b1c1d1e1f";

testHandshake(t: ref T)
{
	pmk := wpakey->psk("InfernodeTest", "infernode");
	t.assertseq(wpakey->hex(pmk), Pmk, "the master key of the synthetic network");

	smac := wpakey->unhex("020000000001");
	snonce := wpakey->unhex(Snonce);
	supp := Supp.mk(pmk, smac, wpakey->rsnie());

	# Message 1 in, message 2 out.
	(a1, e1) := supp.recv(wpakey->unhex(Msg1), snonce);
	t.assertnil(e1, "message 1 is accepted");
	if(len a1 != 1){
		t.fatal(sys->sprint("message 1 produced %d actions, want 1", len a1));
		return;
	}
	act := hd a1;
	t.asserteq(act.kind, Wpakey->Asend, "message 1 is answered with a frame");
	t.assertseq(wpakey->hex(act.frame), Msg2, "message 2");

	# Message 3 in: the receive key, message 4, a pause, the transmit
	# key, and the group key -- in that order, because message 4 must
	# leave before the transmit key changes.
	(a3, e3) := supp.recv(wpakey->unhex(Msg3), snonce);
	t.assertnil(e3, "message 3 is accepted");
	if(len a3 != 5){
		t.fatal(sys->sprint("message 3 produced %d actions, want 5", len a3));
		return;
	}
	acts := a3;
	act = hd acts; acts = tl acts;
	t.asserteq(act.kind, Wpakey->Actl, "the pairwise receive key is a ctl write");
	t.assertseq(act.text, "rxkey 020000000002 ccmp:" + Tk + "@0", "rxkey");
	act = hd acts; acts = tl acts;
	t.asserteq(act.kind, Wpakey->Asend, "message 4 is a frame");
	t.assertseq(wpakey->hex(act.frame), Msg4, "message 4");
	act = hd acts; acts = tl acts;
	t.asserteq(act.kind, Wpakey->Adelay, "the transmit key waits");
	act = hd acts; acts = tl acts;
	t.asserteq(act.kind, Wpakey->Actl, "the pairwise transmit key is a ctl write");
	t.assertseq(act.text, "txkey 020000000002 ccmp:" + Tk + "@0", "txkey");
	act = hd acts;
	t.asserteq(act.kind, Wpakey->Actl, "the group key is a ctl write");
	t.assertseq(act.text, "rxkey1 020000000002 ccmp:" + Gtk1 + "@60504030201",
		"the group key and its sequence counter");

	# The same frame again is a replay: the counter has not advanced,
	# so nothing may happen.
	(a3b, e3b) := supp.recv(wpakey->unhex(Msg3), snonce);
	t.asserteq(len a3b, 0, "a replayed message 3 does nothing");
	t.assertnotnil(e3b, "and says why");

	# A group rekey with one bit of its MIC changed.
	bad := wpakey->unhex(Rekey);
	bad[18+77] ^= byte 1;
	(ab, eb) := supp.recv(bad, snonce);
	t.asserteq(len ab, 0, "a bad MIC produces no actions");
	t.assertseq(eb, "bad MIC", "and is named");

	# The real one.
	(a5, e5) := supp.recv(wpakey->unhex(Rekey), snonce);
	t.assertnil(e5, "a group rekey is accepted");
	if(len a5 != 2){
		t.fatal(sys->sprint("the rekey produced %d actions, want 2", len a5));
		return;
	}
	acts = a5;
	act = hd acts; acts = tl acts;
	t.asserteq(act.kind, Wpakey->Asend, "the rekey is acknowledged");
	t.assertseq(wpakey->hex(act.frame), Rekeyack, "the acknowledgement");
	act = hd acts;
	t.assertseq(act.text, "rxkey2 020000000002 ccmp:" + Gtk2 + "@7", "the new group key");
}

#
#	Frames that are not this station's business, and frames that are
#	malformed, must be dropped without a word and without state.
#
testIgnored(t: ref T)
{
	pmk := wpakey->psk("InfernodeTest", "infernode");
	smac := wpakey->unhex("020000000001");
	snonce := wpakey->unhex(Snonce);
	supp := Supp.mk(pmk, smac, wpakey->rsnie());

	f := wpakey->unhex(Msg1);

	other := array[len f] of byte;
	other[0:] = f;
	other[0] = byte 16r06;			# addressed to someone else
	(a, e) := supp.recv(other, snonce);
	t.asserteq(len a, 0, "a frame for another station is dropped");
	t.assertnil(e, "silently");

	notEapol := array[len f] of byte;
	notEapol[0:] = f;
	notEapol[12] = byte 16r08;		# IPv4, not EAPOL
	notEapol[13] = byte 16r00;
	(a, e) = supp.recv(notEapol, snonce);
	t.asserteq(len a, 0, "a frame of another protocol is dropped");
	t.assertnil(e, "silently too");

	(a, e) = supp.recv(f[0:20], snonce);
	t.asserteq(len a, 0, "a truncated frame is dropped");
	t.assertnotnil(e, "with a diagnostic");

	# A MIC-bearing frame before any message 1: there is no key to
	# check it with, so it cannot be believed.
	(a, e) = supp.recv(wpakey->unhex(Msg3), snonce);
	t.asserteq(len a, 0, "message 3 without message 1 is dropped");
	t.assertnil(e, "and is not an error, only someone else's handshake");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	wpakey = load Wpakey Wpakey->PATH;
	if(wpakey == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Wpakey->PATH);
		raise "fail:cannot load wpakey";
	}
	wpakey->init();

	run("Pbkdf2", testPbkdf2);
	run("Psk", testPsk);
	run("Prf", testPrf);
	run("Keyunwrap", testKeyunwrap);
	run("Handshake", testHandshake);
	run("Ignored", testIgnored);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

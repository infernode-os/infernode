implement Wpakey;

#
#	WPA2-PSK key derivation and the EAPOL four-way handshake.
#
#	Written from Plan 9's aux/wpa(8) as the specification.  The frame
#	layouts, the flag tests and the order in which the keys are
#	installed are that program's; none of its C is here.
#
#	See module/wpakey.m for what this is for and why the handshake
#	returns actions instead of performing them.
#

include "sys.m";
	sys: Sys;

include "keyring.m";
	keyring: Keyring;

include "wpakey.m";

SHA1dlen:	con Keyring->SHA1dlen;
MD5dlen:	con Keyring->MD5dlen;
Aesbsize:	con Keyring->AESbsize;

init()
{
	sys = load Sys Sys->PATH;
	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		raise "fail:cannot load "+Keyring->PATH;
}

#
#	PBKDF2 with HMAC-SHA1 as the pseudorandom function (RFC 2898
#	section 5.2).  The derived key is the concatenation of blocks
#	T(i) = U(1) xor U(2) xor ... xor U(rounds), where U(1) is the
#	HMAC of the salt with the block number appended big-endian and
#	each later U is the HMAC of the one before.
#
pbkdf2_sha1(pass, salt: array of byte, rounds, dklen: int): array of byte
{
	if(dklen <= 0 || rounds <= 0)
		return nil;
	dk := array[dklen] of byte;
	blk := array[len salt + 4] of byte;
	blk[0:] = salt;
	u := array[SHA1dlen] of byte;
	t := array[SHA1dlen] of byte;
	for(i := 1; (i-1)*SHA1dlen < dklen; i++){
		blk[len salt] = byte (i >> 24);
		blk[len salt + 1] = byte (i >> 16);
		blk[len salt + 2] = byte (i >> 8);
		blk[len salt + 3] = byte i;
		keyring->hmac_sha1(blk, len blk, pass, u, nil);
		t[0:] = u;
		for(j := 1; j < rounds; j++){
			keyring->hmac_sha1(u, len u, pass, u, nil);
			for(k := 0; k < SHA1dlen; k++)
				t[k] ^= u[k];
		}
		o := (i-1)*SHA1dlen;
		n := dklen - o;
		if(n > SHA1dlen)
			n = SHA1dlen;
		dk[o:] = t[0:n];
	}
	return dk;
}

#
#	The pairwise master key of a WPA2 personal network: 4096 rounds
#	of PBKDF2 over the passphrase, salted with the network name.
#	IEEE 802.11i-2004 Annex H.4.
#
psk(passphrase, essid: string): array of byte
{
	return pbkdf2_sha1(array of byte passphrase, array of byte essid, 4096, PMKlen);
}

#
#	The IEEE 802.11 pseudorandom function: HMAC-SHA1 of the label, a
#	NUL, the seed and a counter byte, concatenated until nbits are
#	available.  Every output length is a prefix of every longer one.
#
prf(key: array of byte, label: string, seed: array of byte, nbits: int): array of byte
{
	lb := array of byte label;
	nblk := (nbits + 8*SHA1dlen - 1) / (8*SHA1dlen);
	out := array[nblk*SHA1dlen] of byte;
	buf := array[len lb + 1 + len seed + 1] of byte;
	buf[0:] = lb;
	buf[len lb] = byte 0;
	buf[len lb + 1:] = seed;
	d := array[SHA1dlen] of byte;
	for(i := 0; i < nblk; i++){
		buf[len buf - 1] = byte i;
		keyring->hmac_sha1(buf, len buf, key, d, nil);
		out[i*SHA1dlen:] = d;
	}
	return out[0:(nbits+7)/8];
}

#
#	The pairwise transient key.  The seed orders each pair so that
#	both ends compute the same thing without agreeing who is who.
#
ptk(pmk, smac, amac, snonce, anonce: array of byte): array of byte
{
	seed := array[2*Eaddrlen + 2*Noncelen] of byte;
	if(cmpb(amac, smac) < 0){
		seed[0:] = amac;
		seed[Eaddrlen:] = smac;
	}else{
		seed[0:] = smac;
		seed[Eaddrlen:] = amac;
	}
	o := 2*Eaddrlen;
	if(cmpb(anonce, snonce) < 0){
		seed[o:] = anonce;
		seed[o+Noncelen:] = snonce;
	}else{
		seed[o:] = snonce;
		seed[o+Noncelen:] = anonce;
	}
	return prf(pmk, "Pairwise key expansion", seed, 8*PTKlen);
}

#
#	One AES block encrypted under key, in place.
#
#	keyring offers no single-block cipher, but a one-block CBC
#	encryption under a zero initialisation vector is exactly an ECB
#	encryption, and a state made fresh for each block starts from
#	that zero vector.  aesunwrap above uses the same identity in the
#	other direction.
#
aesblock(key, b: array of byte)
{
	st := keyring->aessetup(key, nil);
	keyring->aescbc(st, b, Aesbsize, Keyring->Encrypt);
}

#
#	Doubling in GF(2^128), which is a shift left by one bit and, when
#	a one was shifted off the top, an exclusive-or with the low byte
#	of the field's polynomial.  RFC 4493 section 2.3 calls this the
#	left-shift-and-xor-Rb step of the subkey generation.
#
dbl(a: array of byte)
{
	carry := (int a[0] >> 7) & 1;
	for(i := 0; i < Aesbsize-1; i++)
		a[i] = byte ((((int a[i] << 1) | ((int a[i+1] >> 7) & 1))) & 16rFF);
	a[Aesbsize-1] = byte ((int a[Aesbsize-1] << 1) & 16rFF);
	if(carry)
		a[Aesbsize-1] ^= byte 16r87;
}

#
#	AES-CMAC, RFC 4493.  Key descriptor version 3 keys the message
#	integrity check with this rather than with HMAC-SHA1.
#
#	CMAC is CBC-MAC -- chain the blocks through the cipher and keep
#	the last output -- with the final block corrected by a subkey,
#	which is what makes it sound for messages whose length is not
#	announced.  Both subkeys come from encrypting a block of zeros
#	and doubling: K1 for a message that fills its last block, K2 for
#	one that must be padded with a one bit and zeros.
#
#	Every step of this is checked against the vectors published in
#	RFC 4493 section 4 by tests/wpa_test.b, which is the only reason
#	it is here rather than refused: an integrity check that is wrong
#	in a way no vector catches is worse than one that is absent.
#
aescmac(key, msg: array of byte): array of byte
{
	if(len key != 16 && len key != 24 && len key != 32)
		return nil;

	k1 := array[Aesbsize] of {* => byte 0};
	aesblock(key, k1);
	dbl(k1);
	k2 := array[Aesbsize] of byte;
	k2[0:] = k1;
	dbl(k2);

	#
	# The last block, padded and corrected.  A message that is a
	# whole number of blocks takes K1 and no padding; anything else,
	# the empty message included, takes a one bit, zeros, and K2.
	#
	nblk := (len msg + Aesbsize - 1) / Aesbsize;
	last := array[Aesbsize] of {* => byte 0};
	sub := k2;
	if(nblk == 0)
		last[0] = byte 16r80;		# the empty message: pad only
	else if((len msg % Aesbsize) == 0){
		last[0:] = msg[(nblk-1)*Aesbsize:];
		sub = k1;
	}else{
		r := len msg - (nblk-1)*Aesbsize;
		last[0:] = msg[(nblk-1)*Aesbsize:];
		last[r] = byte 16r80;		# the rest is already zero
	}
	for(i := 0; i < Aesbsize; i++)
		last[i] ^= sub[i];

	x := array[Aesbsize] of {* => byte 0};
	b := array[Aesbsize] of byte;
	for(i = 0; i < nblk-1; i++){
		for(j := 0; j < Aesbsize; j++)
			b[j] = x[j] ^ msg[i*Aesbsize + j];
		aesblock(key, b);
		x[0:] = b;
	}
	for(i = 0; i < Aesbsize; i++)
		b[i] = x[i] ^ last[i];
	aesblock(key, b);
	return b;
}

#
#	The message integrity check over a whole EAPOL frame whose own
#	MIC field has been zeroed.
#
#	The key descriptor version chooses the algorithm, and the
#	standard has named three: version 1 is WPA with TKIP and
#	HMAC-MD5, version 2 is WPA2 with CCMP and HMAC-SHA1, and version
#	3 is AES-128-CMAC, which is what an access point asks for when
#	protected management frames are in play (IEEE 802.11-2016
#	12.7.2).  All three produce at least MIClen bytes and the field
#	takes the first MIClen of them.
#
#	Any other value is a version this module has never been told
#	about, and returning nil for it is what makes recv refuse the
#	frame rather than compare against arithmetic it invented.
#
mic(vers: int, kck, frame: array of byte): array of byte
{
	case vers {
	1 =>
		d := array[MD5dlen] of byte;
		keyring->hmac_md5(frame, len frame, kck, d, nil);
		return d[0:MIClen];
	2 =>
		d := array[SHA1dlen] of byte;
		keyring->hmac_sha1(frame, len frame, kck, d, nil);
		return d[0:MIClen];
	3 =>
		d := aescmac(kck, frame);
		if(d == nil)
			return nil;
		return d[0:MIClen];
	}
	return nil;
}

#
#	What a key descriptor version asks for, in words, so that a
#	refusal names the thing that was asked for instead of guessing.
#
micname(vers: int): string
{
	case vers {
	1 =>	return "HMAC-MD5, for WPA1 with TKIP";
	2 =>	return "HMAC-SHA1, for WPA2 with CCMP";
	3 =>	return "AES-128-CMAC, for WPA2 with CCMP and protected management frames";
	}
	return "a value the standard does not define";
}

#
#	AES key unwrap, RFC 3394 section 2.2.2, as message 3 of the
#	handshake wraps the group key with the KEK.
#
#	The cipher is applied to single blocks, which keyring does not
#	offer directly: a one-block CBC decryption under a zero
#	initialisation vector is exactly an ECB decryption, and a state
#	made fresh for each block starts from that zero vector.
#
aesunwrap(kek, data: array of byte): array of byte
{
	if(len kek != 16 && len kek != 24 && len kek != 32)
		return nil;
	if(len data < 24 || (len data % 8) != 0)
		return nil;
	n := len data/8 - 1;
	a := array[8] of byte;
	a[0:] = data[0:8];
	r := array[n*8] of byte;
	r[0:] = data[8:];
	b := array[16] of byte;
	for(j := 5; j >= 0; j--){
		for(i := n; i >= 1; i--){
			t := j*n + i;
			b[0:] = a;
			b[8:] = r[(i-1)*8:i*8];
			b[7] ^= byte t;
			b[6] ^= byte (t >> 8);
			b[5] ^= byte (t >> 16);
			b[4] ^= byte (t >> 24);
			st := keyring->aessetup(kek, nil);
			keyring->aescbc(st, b, 16, Keyring->Decrypt);
			a[0:] = b[0:8];
			r[(i-1)*8:] = b[8:16];
		}
	}
	#
	# The integrity check, which is the whole of the standard's
	# guarantee that this was wrapped with this key. Compared without
	# an early exit, like every other check on a value an attacker
	# supplies.
	#
	iv := array[8] of {* => byte 16rA6};
	if(!eqct(a, iv))
		return nil;		# wrong key, or the data was tampered with
	return r;
}

#
#	The RSN information element a WPA2-PSK/CCMP station offers.  The
#	driver does not publish the access point's, so there is nothing
#	to negotiate against and nothing to choose: this is the only
#	suite this supplicant implements.
#
rsnie(): array of byte
{
	return array[] of {
		byte 16r30,				# RSN element
		byte 16r14,				# 20 bytes follow
		byte 16r01, byte 16r00,			# version 1
		byte 16r00, byte 16r0F, byte 16rAC, byte 16r04,	# group cipher CCMP
		byte 16r01, byte 16r00,			# one pairwise cipher
		byte 16r00, byte 16r0F, byte 16rAC, byte 16r04,	# CCMP
		byte 16r01, byte 16r00,			# one authentication suite
		byte 16r00, byte 16r0F, byte 16rAC, byte 16r02,	# PSK
		byte 16r00, byte 16r00,			# no RSN capabilities
	};
}

Supp.mk(pmk, smac, rsne: array of byte): ref Supp
{
	s := ref Supp;
	s.pmk = pmk;
	s.smac = smac;
	s.rsne = rsne;
	s.amac = array[Eaddrlen] of {* => byte 0};
	s.reset();
	return s;
}

Supp.reset(s: self ref Supp)
{
	s.ptk = nil;
	s.lastrepc = big 0;
	s.newptk = 0;
}

#
#	One received EAPOL frame, complete with its ethernet header.
#	snonce is fresh entropy the caller supplies on every call; it is
#	used only if this frame turns out to be message 1, so that the
#	caller need not know which message is which and this module need
#	not know where randomness comes from.
#
#	Returns the actions to perform and, separately, a diagnostic for
#	a frame that was addressed to us and looked like part of a
#	handshake but could not be used.  A frame that is simply not ours
#	returns nothing at all.
#
Supp.recv(s: self ref Supp, frame, snonce: array of byte): (list of ref Action, string)
{
	if(len frame < 2*Eaddrlen + 2)
		return (nil, nil);
	if(get2(frame, 2*Eaddrlen) != Eapoltype)
		return (nil, nil);
	if(cmpb(frame[0:Eaddrlen], s.smac) != 0)
		return (nil, nil);		# not addressed to this station

	m := 2*Eaddrlen + 2;			# the EAPOL frame; the MIC covers it all
	if(len frame - m < 4)
		return (nil, nil);
	vers := int frame[m];
	#
	# The EAPOL protocol version, not the key descriptor version
	# checked below.  IEEE 802.1X-2001 was 1, 802.1X-2004 is 2 and
	# 802.1X-2010 is 3; the frame layout this parses is the same in
	# all three, and an access point new enough to ask for the
	# AES-CMAC descriptor is new enough to stamp 3 here.  Refusing 3
	# would make the descriptor version below unreachable in exactly
	# the case it exists for.
	#
	if(vers < 1 || vers > 3)
		return (nil, nil);
	if(int frame[m+1] != Eapolkey)
		return (nil, nil);		# EAP, which only enterprise networks use
	n := get2(frame, m+2);
	e := m + 4 + n;
	if(e > len frame)
		return (nil, "truncated EAPOL frame");
	if(n < Keydescrlen)
		return (nil, "short key descriptor");

	kd := m + 4;
	kdtype := int frame[kd];
	if(kdtype != 16rFE && kdtype != 16r02)
		return (nil, nil);		# not a key descriptor we know
	flags := get2(frame, kd+1);
	kvers := flags & 7;
	datalen := get2(frame, kd+93);
	if(kd + Keydescrlen + datalen > e)
		return (nil, "key data runs past the frame");
	#
	# Versions 2 and 3 differ only in the integrity check -- HMAC-SHA1
	# against AES-128-CMAC -- and mic() does both.  Both wrap their
	# key data with the same AES key wrap, so nothing below this line
	# has to know which arrived.  Version 1 is the one that would
	# need more: its key data is unwrapped with RC4, which is not
	# implemented, so accepting its earlier messages would only fail
	# later and less clearly.
	#
	if(kvers != 2 && kvers != 3)
		return (nil, sys->sprint(
			"key descriptor version %d (%s) is not implemented; this supplicant does 2 and 3",
			kvers, micname(kvers)));

	amac := copyb(frame, Eaddrlen, 2*Eaddrlen);

	if((flags & Fmic) == 0){
		#
		# Message 1: the access point's nonce, unauthenticated.
		# Deriving a PTK from it costs nothing and commits to
		# nothing; the MIC on message 3 is what proves the
		# access point knew the same PMK.
		#
		if((flags & (Fptk|Fack)) != (Fptk|Fack))
			return (nil, nil);
		if(len snonce != Noncelen)
			return (nil, "no nonce supplied");
		s.amac = amac;
		anonce := copyb(frame, kd+13, kd+45);
		s.ptk = ptk(s.pmk, s.smac, s.amac, snonce, anonce);
		s.newptk = 1;
		reply := mkreply(s, frame, kd, vers,
			(flags & ~(Fack|Fins)) | Fmic, snonce, s.rsne);
		return (ref Action(Asend, reply, nil, 0) :: nil, nil);
	}

	#
	# Everything below carries a MIC, so there must be a PTK to check
	# it with and the check comes before anything else is believed.
	#
	if(s.ptk == nil)
		return (nil, nil);		# a handshake we are not part of
	kck := s.ptk[0:KCKlen];
	msg := copyb(frame, m, e);
	got := copyb(frame, kd+77, kd+93);
	zero(msg, (kd - m) + 77, MIClen);
	want := mic(kvers, kck, msg);
	if(want == nil || !eqct(got, want))
		return (nil, "bad MIC");

	repc := big 0;
	for(i := 0; i < 8; i++)
		repc = (repc << 8) | big int frame[kd+5+i];
	if(repc <= s.lastrepc)
		return (nil, sys->sprint("stale replay counter %bd", repc));
	s.lastrepc = repc;

	#
	# The receive sequence counter is little-endian and 48 bits wide;
	# it belongs to the group key.
	#
	rsc := big 0;
	for(i = 5; i >= 0; i--)
		rsc = (rsc << 8) | big int frame[kd+61+i];

	data := copyb(frame, kd+Keydescrlen, kd+Keydescrlen+datalen);
	if(datalen > 0 && (flags & Fenc) != 0){
		data = aesunwrap(s.ptk[KCKlen:KCKlen+KEKlen], data);
		if(data == nil)
			return (nil, "the wrapped key data did not unwrap");
	}

	(gtk, gtkkid) := findgtk(data, flags);

	acts: list of ref Action;
	if((flags & (Fptk|Fack)) == (Fptk|Fack)){
		#
		# Message 3.  The pairwise key goes in for receive, the
		# acknowledgement goes out under the old key, and only
		# then is the transmit key switched -- in that order, or
		# message 4 is encrypted with a key the access point is
		# not yet using.
		#
		if(!s.newptk)
			return (nil, nil);	# a retransmission; the keys are in
		tk := hex(s.ptk[KCKlen+KEKlen:KCKlen+KEKlen+TKlen]);
		acts = ref Action(Actl, nil,
			sys->sprint("rxkey %s ccmp:%s@0", eaddr(s.amac), tk), 0) :: acts;
		acts = ref Action(Asend,
			mkreply(s, frame, kd, vers, flags & ~(Fack|Fenc|Fins), nil, nil),
			nil, 0) :: acts;
		acts = ref Action(Adelay, nil, nil, 100) :: acts;
		acts = ref Action(Actl, nil,
			sys->sprint("txkey %s ccmp:%s@0", eaddr(s.amac), tk), 0) :: acts;
		s.newptk = 0;
	}else if((flags & (Fptk|Fsec|Fack)) == (Fsec|Fack)){
		# A group rekey: acknowledge it, then install the new key.
		acts = ref Action(Asend,
			mkreply(s, frame, kd, vers, flags & ~(Fenc|Fack), nil, nil),
			nil, 0) :: acts;
	}else
		return (nil, nil);

	if(gtk != nil && len gtk >= TKlen && gtkkid >= 0)
		acts = ref Action(Actl, nil,
			sys->sprint("rxkey%d %s ccmp:%s@%bux", gtkkid, eaddr(s.amac),
				hex(gtk[0:TKlen]), rsc), 0) :: acts;

	return (rev(acts), nil);
}

#
#	The group key arrives as a KDE in the key data: a vendor-specific
#	element carrying the 00-0F-AC-01 selector, a key index and the
#	key itself.  An unencrypted one is ignored -- a group key in the
#	clear is not a group key.
#
findgtk(data: array of byte, flags: int): (array of byte, int)
{
	if((flags & Fenc) == 0)
		return (nil, -1);
	e := len data;
	for(p := 0; p + 2 <= e; ){
		x := p + 2 + int data[p+1];
		if(x > e)
			break;
		if(int data[p] == 16rDD && x >= p + 8 &&
		   int data[p+2] == 16r00 && int data[p+3] == 16r0F &&
		   int data[p+4] == 16rAC && int data[p+5] == 16r01)
			return (copyb(data, p+8, x), int data[p+6] & 3);
		p = x;
	}
	return (nil, -1);
}

#
#	Build a reply out of the frame being answered: the descriptor is
#	copied verbatim and then the fields that must change are changed,
#	which is how the replay counter and key length come back the way
#	the access point sent them.
#
mkreply(s: ref Supp, frame: array of byte, kd, vers, flags: int,
	nonce, data: array of byte): array of byte
{
	body := array[4 + Keydescrlen + len data] of byte;
	body[0] = byte vers;
	body[1] = byte Eapolkey;
	body[2] = byte ((Keydescrlen + len data) >> 8);
	body[3] = byte (Keydescrlen + len data);
	body[4:] = frame[kd:kd+Keydescrlen];

	k := 4;					# the descriptor within body
	body[k+1] = byte (flags >> 8);
	body[k+2] = byte flags;
	zero(body, k+45, 16);			# EAPOL IV
	zero(body, k+61, 8);			# RSC
	if(nonce != nil)
		body[k+13:] = nonce;
	else
		zero(body, k+13, Noncelen);
	body[k+93] = byte ((len data) >> 8);
	body[k+94] = byte (len data);
	if(data != nil)
		body[k+Keydescrlen:] = data;

	zero(body, k+77, MIClen);
	if(flags & Fmic){
		m := mic(flags & 7, s.ptk[0:KCKlen], body);
		if(m != nil)
			body[k+77:] = m;
	}

	#
	# The ethernet header, and the minimum frame the medium accepts.
	#
	n := 2*Eaddrlen + 2 + len body;
	if(n < 60)
		n = 60;
	f := array[n] of {* => byte 0};
	f[0:] = s.amac;
	f[Eaddrlen:] = s.smac;
	f[2*Eaddrlen] = byte (Eapoltype >> 8);
	f[2*Eaddrlen + 1] = byte Eapoltype;
	f[2*Eaddrlen + 2:] = body;
	return f;
}

hexchars := "0123456789abcdef";

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++){
		s[len s] = hexchars[(int a[i] >> 4) & 16rF];
		s[len s] = hexchars[int a[i] & 16rF];
	}
	return s;
}

unhex(s: string): array of byte
{
	if((len s & 1) != 0)
		return nil;
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++){
		hi := hexval(s[2*i]);
		lo := hexval(s[2*i+1]);
		if(hi < 0 || lo < 0)
			return nil;
		a[i] = byte ((hi << 4) | lo);
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

#
#	An ethernet address the way the kernel's ctl files parse one:
#	twelve hexadecimal digits, no separators.
#
eaddr(a: array of byte): string
{
	return hex(a[0:Eaddrlen]);
}

get2(a: array of byte, o: int): int
{
	return (int a[o] << 8) | int a[o+1];
}

copyb(a: array of byte, i, j: int): array of byte
{
	b := array[j-i] of byte;
	b[0:] = a[i:j];
	return b;
}

zero(a: array of byte, o, n: int)
{
	for(i := 0; i < n; i++)
		a[o+i] = byte 0;
}

#
#	Equality without an early exit, for the two comparisons an
#	attacker chooses one side of: the message integrity check and the
#	key unwrap's integrity check. cmpb below is for ordering nonces
#	and addresses, which are public.
#
eqct(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int a[i] ^ int b[i];
	return d == 0;
}

cmpb(a, b: array of byte): int
{
	n := len a;
	if(len b < n)
		n = len b;
	for(i := 0; i < n; i++){
		if(int a[i] < int b[i])
			return -1;
		if(int a[i] > int b[i])
			return 1;
	}
	return len a - len b;
}

rev(l: list of ref Action): list of ref Action
{
	r: list of ref Action;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

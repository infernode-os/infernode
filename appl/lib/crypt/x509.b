implement X509;

include "sys.m";
	sys				: Sys;

include "asn1.m";
	asn1				: ASN1;
	Elem, Tag, Value, Oid,
	Universal, Context,
	BOOLEAN,
	INTEGER,
	BIT_STRING,
	OCTET_STRING,
	OBJECT_ID,
	SEQUENCE,
	UTCTime,
	IA5String,
	GeneralString,
	GeneralizedTime			: import asn1;

include "keyring.m";
	keyring				: Keyring;
	IPint				: import keyring;

include "daytime.m";
	daytime				: Daytime;

include "pkcs.m";
	pkcs				: PKCS;

include "x509.m";

X509_DEBUG 				: con 0;
logfd 					: ref Sys->FD;

# Trust store: root CA certificates, read when first wanted and again
# when the directory's files have changed (storesig)
TrustedRoot: adt {
	signed:	ref Signed;
	cert:	ref Certificate;
};
trust_store: list of ref TrustedRoot;
trust_store_loaded: int;
trust_store_sig: string;

# What a verification takes its roots, CRLs and time from: nil, the
# stores (/lib/certs, /lib/crls) and /dev/time; else these alone
VCtx: adt {
	roots:	list of ref TrustedRoot;
	crls:	list of ref CRLEntry;
	now:	int;
	stores:	int;	# the stores and /dev/time, not these
	work:	int;	# signatures left to check in the search for a path
	usage:	int;	# Usage_*: what the path is for
};

# A path search may check at most this many signatures: a chain of
# certificates that all name each other (one issuer, ten CAs) has
# paths without number, and each would cost a signature
MAXWORK: con 64;

ctxroots(ctx: ref VCtx): list of ref TrustedRoot
{
	if(ctx == nil || ctx.stores) {
		load_trust_store();
		return trust_store;
	}
	return ctx.roots;
}

ctxnow(ctx: ref VCtx): int
{
	if(ctx == nil || ctx.stores)
		return daytime->now();
	return ctx.now;
}

validat(validity: ref Validity, now: int): int
{
	return big now >= validity.not_before && big now <= validity.not_after;
}

# CRL store: lazily loaded certificate revocation lists
CRLEntry: adt {
	signed:	ref Signed;
	crl:	ref CRL;
	checked:	int;	# its signature is a root's, checked when it was given; else its issuer's, checked on the path
};
crl_store: list of ref CRLEntry;
crl_store_loaded: int;
crl_store_sig: string;
crl_store_err: string;	# a file of the store that could not be used

TAG_MASK 				: con 16r1F;
CONSTR_MASK 				: con 16r20;
CLASS_MASK 				: con 16rC0;

# object identifiers

objIdTab = array [] of {
	id_at =>			Oid(array [] of {2,5,4}),
	id_at_commonName => 		Oid(array [] of {2,5,4,3}),
	id_at_countryName => 		Oid(array [] of {2,5,4,6}),
	id_at_localityName => 		Oid(array [] of {2,5,4,7}), 
	id_at_stateOrProvinceName => 	Oid(array [] of {2,5,4,8}),
	id_at_organizationName =>	Oid(array [] of {2,5,4,10}),
	id_at_organizationalUnitName => Oid(array [] of {2,5,4,11}), 
	id_at_userPassword =>		Oid(array [] of {2,5,4,35}),
	id_at_userCertificate =>	Oid(array [] of {2,5,4,36}),
	id_at_cAcertificate =>		Oid(array [] of {2,5,4,37}),
	id_at_authorityRevocationList =>
					Oid(array [] of {2,5,4,38}),
	id_at_certificateRevocationList =>
					Oid(array [] of {2,5,4,39}),
	id_at_crossCertificatePair =>	Oid(array [] of {2,5,4,40}),
# 	id_at_crossCertificatePair => 	Oid(array [] of {2,5,4,58}),
	id_at_supportedAlgorithms =>	Oid(array [] of {2,5,4,52}),
	id_at_deltaRevocationList =>	Oid(array [] of {2,5,4,53}),

	id_ce =>			Oid(array [] of {2,5,29}),
	id_ce_subjectDirectoryAttributes =>
					Oid(array [] of {2,5,29,9}),
	id_ce_subjectKeyIdentifier =>	Oid(array [] of {2,5,29,14}),
	id_ce_keyUsage =>		Oid(array [] of {2,5,29,15}),
	id_ce_privateKeyUsage =>	Oid(array [] of {2,5,29,16}),
	id_ce_subjectAltName =>		Oid(array [] of {2,5,29,17}),
	id_ce_issuerAltName =>		Oid(array [] of {2,5,29,18}),
	id_ce_basicConstraints =>	Oid(array [] of {2,5,29,19}),
	id_ce_cRLNumber =>		Oid(array [] of {2,5,29,20}),
	id_ce_reasonCode =>		Oid(array [] of {2,5,29,21}),
	id_ce_instructionCode =>	Oid(array [] of {2,5,29,23}),
	id_ce_invalidityDate =>		Oid(array [] of {2,5,29,24}),
	id_ce_deltaCRLIndicator =>	Oid(array [] of {2,5,29,27}),
	id_ce_issuingDistributionPoint =>
					Oid(array [] of {2,5,29,28}),
	id_ce_certificateIssuer =>	Oid(array [] of {2,5,29,29}),
	id_ce_nameConstraints =>	Oid(array [] of {2,5,29,30}),
	id_ce_cRLDistributionPoint =>	Oid(array [] of {2,5,29,31}),
	id_ce_certificatePolicies =>	Oid(array [] of {2,5,29,32}),
	id_ce_policyMapping =>		Oid(array [] of {2,5,29,33}),
	id_ce_authorityKeyIdentifier =>
					Oid(array [] of {2,5,29,35}),
	id_ce_policyConstraints	=>	Oid(array [] of {2,5,29,36}),

#	id_mr =>			Oid(array [] of {2,5,?}),
# 	id_mr_certificateMatch =>	Oid(array [] of {2,5,?,35}),
# 	id_mr_certificatePairExactMatch	=>
#					Oid(array [] of {2,5,?,36}),
# 	id_mr_certificatePairMatch =>	Oid(array [] of {2,5,?,37}),
# 	id_mr_certificateListExactMatch	=>
#					Oid(array [] of {2,5,?,38}),
# 	id_mr_certificateListMatch =>	Oid(array [] of {2,5,?,39}),
# 	id_mr_algorithmidentifierMatch =>
#					Oid(array [] of {2,5,?,40})
};

# [public]

init(): string
{
	sys = load Sys Sys->PATH;

	if(X509_DEBUG)
		logfd = sys->fildes(1);

	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		return sys->sprint("load %s: %r", Keyring->PATH);

	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		return sys->sprint("load %s: %r", Daytime->PATH);

	asn1 = load ASN1 ASN1->PATH;
	if(asn1 == nil)
		return sys->sprint("load %s: %r", ASN1->PATH);
	asn1->init();

	pkcs = load PKCS PKCS->PATH;
	if(pkcs == nil)
		return sys->sprint("load %s: %r", PKCS->PATH);
	if((e := pkcs->init()) != nil)
		return sys->sprint("pkcs: %s", e);

	return nil;
}

# [private]

log(s: string)
{
	if(X509_DEBUG)
		sys->fprint(logfd, "x509: %s\n", s);
}

# [private]
# Load root CA DER files from /lib/certs/

# What a store's directory holds, as text: each .der file's name,
# time, length and version.  A store is read again when this is not
# what it was: it was read once in the life of a module instance, so
# a long-lived service went on trusting a root that had been removed
# and never saw one added, or a CRL put there to revoke.  The cost is
# a directory read for each verification.
storesig(dir: string): string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return "";
	sig := dir + "\n";
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			d := dirs[i];
			if(len d.name < 4 || d.name[len d.name - 4:] != ".der")
				continue;
			sig += sys->sprint("%s %d %bd %d %bud\n", d.name, d.mtime, d.length, d.qid.vers, d.qid.path);
		}
	}
	return sig;
}

# The store is built whole and then published: it was marked loaded
# before it was read, so a handshake running beside the first one (two
# fonts fetched at once) found it partly read and the root missing.  Two
# first handshakes may both read it; each sees all of it.
load_trust_store()
{
	certdir := "/lib/certs";
	sig := storesig(certdir);
	if(trust_store_loaded && sig == trust_store_sig)
		return;
	ts: list of ref TrustedRoot;
	fd := sys->open(certdir, Sys->OREAD);
	for(;fd != nil;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := dirs[i].name;
			# only .der files
			if(len name < 4 || name[len name - 4:] != ".der")
				continue;
			path := certdir + "/" + name;
			der := readfile(path, MAXCERTFILE);
			if(der == nil)
				continue;
			(serr, s) := Signed.decode(der);
			if(serr != "")
				continue;
			(cerr, c) := Certificate.decode(s.tobe_signed);
			if(cerr != "" || !algsame(s.alg, c.sig))
				continue;
			ts = ref TrustedRoot(s, c) :: ts;
		}
	}
	trust_store = ts;
	trust_store_sig = sig;
	trust_store_loaded = 1;
}

# [private]
# Read entire file into byte array

readfile(path: string, max: int): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	if(d.length <= big 0 || d.length > big max)
		return nil;
	sz := int d.length;
	buf := array [sz] of byte;
	tot := 0;
	while(tot < sz && (n := sys->read(fd, buf[tot:], sz - tot)) > 0)
		tot += n;
	if(tot <= 0)
		return nil;
	return buf[:tot];
}

MAXCERTFILE: con 65536;
MAXCRLFILE: con 4*1024*1024;	# a busy CA's list of revoked certificates is long


# [private]
# Load CRL DER files from /lib/crls/
#
# A list put there is there to revoke.  One that cannot be read (too
# long, not a CRL, a critical extension that changes what it covers)
# was left out without a word, and the certificates it names verified
# again: it now fails every verification, with an error that names the
# file, as a CRL given to verify_certchain_roots that cannot be used
# fails that call.  One past its nextUpdate is kept and said so once
# on standard error: it still names what it revoked (check_revoked).

load_crl_store()
{
	crldir := "/lib/crls";
	sig := storesig(crldir);
	if(crl_store_loaded && sig == crl_store_sig)
		return;
	cs: list of ref CRLEntry;	# built whole, then published, as the trust store
	cerr: string;
	fd := sys->open(crldir, Sys->OREAD);
	now := big daytime->now();
	for(;fd != nil;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := dirs[i].name;
			if(len name < 4 || name[len name - 4:] != ".der")
				continue;
			path := crldir + "/" + name;
			err: string;
			s: ref Signed;
			crl: ref CRL;
			der := readfile(path, MAXCRLFILE);
			if(der == nil)
				err = sys->sprint("cannot be read, is empty, or is past %d bytes", MAXCRLFILE);
			else
				(err, s) = Signed.decode(der);
			if(err == "")
				(err, crl) = CRL.decode(s.tobe_signed);
			if(err == "" && !algsame(s.alg, crl.sig))
				err = "its two signature algorithms differ";
			if(err != "") {
				sys->fprint(sys->fildes(2), "x509: %s: %s: no certificate verifies until it is put right or removed\n", path, err);
				if(cerr == nil)
					cerr = "CRL store: " + path + ": " + err;
				continue;
			}
			if(crl.next_update != big 0 && crl.next_update < now)
				sys->fprint(sys->fildes(2), "x509: %s: this CRL is past its nextUpdate (%s): still applied, but what its issuer has revoked since is not known here\n",
					path, timetext(crl.next_update, 0));
			# its signature is checked where it is used, under the
			# key of the issuer the path has found (check_revoked):
			# a file here was taken for its issuer's by its name
			cs = ref CRLEntry(s, crl, 0) :: cs;
		}
	}
	crl_store = cs;
	crl_store_err = cerr;
	crl_store_sig = sig;
	crl_store_loaded = 1;
}

# [private]
# Is cert revoked by a CRL of its issuer's?  (1, why) if it is, or if a
# CRL of its issuer's cannot be used; (0, "") if not.  issuer is the
# certificate that issued it on the path being built, with its
# extensions ix (nil: cert is a trust anchor, which the path ends at).
#
# RFC 5280 6.3.3: a CRL is cert's issuer's when it has the issuer's
# name (b) and its signature verifies under the issuer's key (f, g),
# with a keyUsage, where the issuer has one, that has cRLSign (f).  A
# CRL with another name is some other CA's and says nothing of cert: it
# is not looked at.  (One no root had signed had to name a CA among the
# certificates presented, or the call failed whatever was being
# verified: an intermediate's CRL refused every chain that did not go
# through the intermediate, and a CRL a root had not signed refused the
# chains of every other root.)  A CRL with the issuer's name that the
# issuer did not sign, or may not sign, still fails the path: it is
# there to say what that CA has revoked, and what it says cannot be
# known.
#
# A trust anchor's own issuer is not on the path.  A CRL with that
# issuer's name counts when a root of the name signed it (an anchor
# that a root, its issuer, has revoked), and otherwise is another CA's.

check_revoked(cert: ref Certificate, issuer: ref Certificate, ix: ref Xinfo, ctx: ref VCtx): (int, string)
{
	l: list of ref CRLEntry;
	if(ctx != nil && !ctx.stores)
		l = ctx.crls;
	else {
		load_crl_store();
		if(crl_store_err != nil)
			return (1, crl_store_err);
		l = crl_store;
	}
	for(; l != nil; l = tl l) {
		entry := hd l;
		if(!entry.crl.issuer.equal(cert.issuer))
			continue;
		if(!entry.checked) {
			if(issuer == nil) {
				(ok, err) := rootsigned(entry, ctx);
				if(err != nil)
					return (1, err);
				if(!ok)
					continue;
			} else {
				if(ix != nil && ix.ku && !(ix.usage & KeyUsage_CRLSign))
					return (1, "CRL signed by a CA whose keyUsage lacks cRLSign: " + entry.crl.issuer.tostring());
				if(--ctx.work < 0)
					return (1, "certificate path: too many signatures to check");
				(ok, nil) := verify_issued(entry.signed, issuer);
				if(!ok)
					return (1, "CRL not signed by its issuer: " + entry.crl.issuer.tostring());
			}
		}
		# A CRL past its nextUpdate is used all the same, the
		# store's as a caller's: a stale list of revoked
		# certificates still names them.  (The store's were
		# skipped, which let a revoked certificate back in as
		# soon as its CRL aged; nothing here fetches a new one.)
		if(entry.crl.is_revoked(cert.serial_number))
			return (1, "certificate revoked (serial " +
				cert.serial_number.iptostr(16) + ")");
	}
	return (0, "");
}

# [public]
# Is the CRL the CA's (module/x509.m)?  What check_revoked asks of a CRL
# and the issuer a path has found, for a caller that holds both before
# any path is made (a server reading its configuration).
crlof(crlder: array of byte, cader: array of byte): (int, string)
{
	{
		(serr, s) := Signed.decode(crlder);
		if(serr != "")
			return (0, "CRL: " + serr);
		(cerr, crl) := CRL.decode(s.tobe_signed);
		if(cerr != "")
			return (0, "CRL: " + cerr);
		if(!algsame(s.alg, crl.sig))
			return (0, "CRL: signatureAlgorithm is not the algorithm its tbsCertList names: " + crl.issuer.tostring());
		(e, cs) := Signed.decode(cader);
		if(e != "")
			return (0, "certificate: " + e);
		c: ref Certificate;
		(e, c) = Certificate.decode(cs.tobe_signed);
		if(e != "")
			return (0, "certificate: " + e);
		if(!c.subject.equal(crl.issuer))
			return (0, nil);
		(x, xerr) := certinfo(c, cs.tobe_signed);
		if(xerr != nil)
			return (0, "certificate: " + xerr);
		if(x.ku && !(x.usage & KeyUsage_CRLSign))
			return (0, "CRL signed by a CA whose keyUsage lacks cRLSign: " + crl.issuer.tostring());
		(ok, nil) := verify_issued(s, c);
		if(!ok)
			return (0, "CRL not signed by its issuer: " + crl.issuer.tostring());
		return (1, nil);
	} exception ex {
	"*" =>
		return (0, "CRL: internal error: " + ex);
	}
}

# [private]
# Did a trust anchor with the CRL's issuer's name sign it (and may it:
# cRLSign, if it has a keyUsage)?  (1, nil) or (0, nil); (0, why) when
# the work allowed a path is used up.
rootsigned(entry: ref CRLEntry, ctx: ref VCtx): (int, string)
{
	for(t := ctxroots(ctx); t != nil; t = tl t) {
		tr := hd t;
		if(!tr.cert.subject.equal(entry.crl.issuer))
			continue;
		(x, xerr) := certinfo(tr.cert, tr.signed.tobe_signed);
		if(xerr != nil || x.ku && !(x.usage & KeyUsage_CRLSign))
			continue;
		if(--ctx.work < 0)
			return (0, "certificate path: too many signatures to check");
		(ok, nil) := verify_issued(entry.signed, tr.cert);
		if(ok)
			return (1, nil);
	}
	return (0, nil);
}

## SIGNED { ToBeSigned } ::= SEQUENCE {
##	toBeSigned	ToBeSigned,
##	COMPONENTS OF	SIGNATURE { ToBeSigned }}
##
## SIGNATURE {OfSignature} ::= SEQUENCE {
##	algorithmIdentifier	AlgorithmIdentifier,
##	encrypted	ENCRYPTED { HASHED { OfSignature }}}
##
## ENCRYPTED { ToBeEnciphered }	::= BIT STRING ( CONSTRAINED BY {
##	-- must be the result of applying an encipherment procedure --
##	-- to the BER-encoded octets of a value of -- ToBeEnciphered } )

# [public]

Signed.decode(a: array of byte): (string, ref Signed)
{
	# The bytes are a peer's.  Each read below is bounded, and should
	# one not be, the answer is still an error and not an exception in
	# whoever is in the middle of a handshake.
	{
		return signeddecode(a);
	} exception e {
	"*" =>
		return ("signed: internal error: " + e, nil);
	}
}

signeddecode(a: array of byte): (string, ref Signed)
{
parse:
	for(;;) {
		# interpret the enclosing structure
		(ok, tag, i, n) := der_dec1(a, 0, len a);
		if(!ok || n != len a || !tag.constr || 
			tag.class != Universal || tag.num != SEQUENCE)
			break parse;
		s := ref Signed;
		# SIGNED sequence
		istart := i;
		(ok, tag, i, n) = der_dec1(a, i, len a);
		if(!ok || n == len a)
			break parse;
		s.tobe_signed = a[istart:n];
		# AlgIdentifier
		istart = n;
		(ok, tag, i, n) = der_dec1(a, n, len a);
		if(!ok || n == len a 
			|| !tag.constr || tag.class != Universal || tag.num != SEQUENCE) {
			if(X509_DEBUG)
				log("signed: der data: " + 
				sys->sprint("ok=%d, n=%d, constr=%d, class=%d, num=%d", 
				ok, n, tag.constr, tag.class, tag.num));
			break parse;
		}
		(ok, s.alg) = decode_algid(a[istart:n]);
		if(!ok) {
			if(X509_DEBUG)
				log("signed: alg identifier: syntax error");
			break;
		}
		# signature
		(ok, tag, i, n) = der_dec1(a, n, len a);
		if(!ok || n != len a
			|| tag.constr || tag.class != Universal || tag.num != BIT_STRING) {
			if(X509_DEBUG)
				log("signed: signature: " + 
				sys->sprint("ok=%d, n=%d, constr=%d, class=%d, num=%d", 
				ok, n, tag.constr, tag.class, tag.num));
			break parse;
		}
		s.signature = a[i:n];
		# to the end of no error been found
		return ("", s);
	}
	return ("signed: syntax error", nil);
}


# [private]
# RSA PKCS#1 v1.5 verification: decrypt signature and compare DigestInfo suffix
rsa_pkcs1_verify(signature: array of byte, pk: ref PKCS->RSAKey, digestinfo: array of byte): int
{
	# signature is the BIT STRING content: unused-bits byte, then the octets
	if(len signature < 2 || int signature[0] != 0)
		return 0;
	return pkcs1v15_verify(signature[1:], pk, digestinfo);
}

# [private]
# EMSA-PKCS1-v1_5 verification (RFC 8017 section 8.2.2): recompute the
# whole encoded message 00 01 FF..FF 00 DigestInfo and compare it
# exactly. Comparing only a suffix, or accepting short or non-FF
# padding, admits Bleichenbacher-style forgeries.

pkcs1v15_verify(sig: array of byte, pk: ref PKCS->RSAKey, digestinfo: array of byte): int
{
	k := pk.modlen;
	if(len sig != k || len digestinfo > k - 11)
		return 0;
	x := IPint.bebytestoip(sig);
	if(x.cmp(pk.modulus) >= 0)
		return 0;
	yb := x.expmod(pk.exponent, pk.modulus).iptobebytes();
	if(len yb > k)
		return 0;
	em := array [k] of {* => byte 0};
	em[k - len yb:] = yb;
	if(em[0] != byte 0 || em[1] != byte 1)
		return 0;
	pad := k - 3 - len digestinfo;
	for(i := 2; i < 2 + pad; i++)
		if(em[i] != byte 16rFF)
			return 0;
	if(em[2 + pad] != byte 0)
		return 0;
	return bytesequal(em[3 + pad:], digestinfo);
}

# [public]

Signed.verify(s: self ref Signed, pk: ref PublicKey): int
{
	{
		(ok, nil) := sigverify(s, pk);
		return ok;
	} exception {
	"*" =>
		return 0;
	}
}

# DigestInfo's bytes before the digest (RFC 8017 9.2 note 1)
DI_SHA256 := array [] of {
	byte 16r30, byte 16r31, byte 16r30, byte 16r0d,
	byte 16r06, byte 16r09, byte 16r60, byte 16r86,
	byte 16r48, byte 16r01, byte 16r65, byte 16r03,
	byte 16r04, byte 16r02, byte 16r01, byte 16r05,
	byte 16r00, byte 16r04, byte 16r20
};
DI_SHA384 := array [] of {
	byte 16r30, byte 16r41, byte 16r30, byte 16r0d,
	byte 16r06, byte 16r09, byte 16r60, byte 16r86,
	byte 16r48, byte 16r01, byte 16r65, byte 16r03,
	byte 16r04, byte 16r02, byte 16r02, byte 16r05,
	byte 16r00, byte 16r04, byte 16r30
};
DI_SHA512 := array [] of {
	byte 16r30, byte 16r51, byte 16r30, byte 16r0d,
	byte 16r06, byte 16r09, byte 16r60, byte 16r86,
	byte 16r48, byte 16r01, byte 16r65, byte 16r03,
	byte 16r04, byte 16r02, byte 16r03, byte 16r05,
	byte 16r00, byte 16r04, byte 16r40
};

DERNULL := array [] of {byte 16r05, byte 16r00};

# [private]
# Is s's signature pk's?  The one place a signature is checked, for
# Signed.verify and for the path: (1, "") or (0, why).  The algorithm
# is the one s names: RSA PKCS #1 v1.5 or ECDSA, with SHA-256, SHA-384
# or SHA-512, under a key of the same kind.  Anything else does not
# verify.  (Signed.verify had its own copy, with a hash argument it
# did not read, arms for DSS and DH keys, and no SHA-512.)
#
# The algorithm's parameters are NULL or absent: RFC 4055 5 has NULL
# for the RSA ones, RFC 5758 3.2 none for ECDSA, and CAs have written
# each both ways; anything else there is refused.

sigverify(s: ref Signed, pk: ref PublicKey): (int, string)
{
	if(s == nil || s.alg == nil || s.alg.oid == nil || pk == nil)
		return (0, "nothing to verify");
	if(s.alg.parameter != nil && !bytesequal(s.alg.parameter, DERNULL))
		return (0, "signature algorithm " + s.alg.oid.tostring() + " with parameters");
	algid := asn1->oid_lookup(s.alg.oid, pkcs->objIdTab);
	rsa := 0;
	hash := 0;
	case algid {
	PKCS->id_sha256WithRSAEncryption =>	rsa = 1; hash = 256;
	PKCS->id_sha384WithRSAEncryption =>	rsa = 1; hash = 384;
	PKCS->id_sha512WithRSAEncryption =>	rsa = 1; hash = 512;
	PKCS->id_ecdsa_sha256 =>	hash = 256;
	PKCS->id_ecdsa_sha384 =>	hash = 384;
	PKCS->id_ecdsa_sha512 =>	hash = 512;
	* =>
		return (0, "unsupported signature algorithm " + s.alg.oid.tostring());
	}
	digest, pfx: array of byte;
	case hash {
	256 =>
		digest = array [Keyring->SHA256dlen] of byte;
		keyring->sha256(s.tobe_signed, len s.tobe_signed, digest, nil);
		pfx = DI_SHA256;
	384 =>
		digest = array [Keyring->SHA384dlen] of byte;
		keyring->sha384(s.tobe_signed, len s.tobe_signed, digest, nil);
		pfx = DI_SHA384;
	512 =>
		digest = array [Keyring->SHA512dlen] of byte;
		keyring->sha512(s.tobe_signed, len s.tobe_signed, digest, nil);
		pfx = DI_SHA512;
	}
	pick key := pk {
	RSA =>
		if(!rsa)
			return (0, "an RSA key and signature algorithm " + s.alg.oid.tostring());
		if((e := rsasane(key.pk)) != nil)
			return (0, e);
		di := array [len pfx + len digest] of byte;
		di[0:] = pfx;
		di[len pfx:] = digest;
		if(rsa_pkcs1_verify(s.signature, key.pk, di))
			return (1, "");
		return (0, "RSA signature verification failure");
	EC =>
		if(rsa)
			return (0, "an EC key and signature algorithm " + s.alg.oid.tostring());
		# ECDSA takes the hash truncated or zero-extended to the curve
		# size; the libsec verifiers do that for any hash length.  The
		# key's length is its curve (getPublicKey).
		case len key.point {
		65 =>
			(serr, raw) := decode_ecdsa_sig(s.signature, 32);
			if(serr != nil)
				return (0, serr);
			pt := keyring->p256_make_point(key.point);
			if(pt == nil)
				return (0, "bad P-256 key");
			if(keyring->p256_ecdsa_verify(pt, digest, raw))
				return (1, "");
		97 =>
			(serr, raw) := decode_ecdsa_sig(s.signature, 48);
			if(serr != nil)
				return (0, serr);
			if(keyring->p384_ecdsa_verify(key.point, digest, raw))
				return (1, "");
		* =>
			return (0, "unsupported EC key size");
		}
		return (0, "ECDSA signature verification failure");
	}
	return (0, "unsupported key");
}

# [private]
# An ECDSA signature as X.509 carries it, a BIT STRING holding the DER
# of ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER } (RFC 5480
# appendix A), as r and s of fieldlen bytes each (32 for P-256, 48 for
# P-384).
#
# DER, and only that: the two INTEGERs in the fewest bytes (asn1), both
# positive, nothing after them.  A signature in a second encoding of
# the same two numbers (a padded r, a longer length) verified, so a
# certificate's bytes could be changed without its signature failing.

decode_ecdsa_sig(sig: array of byte, fieldlen: int): (string, array of byte)
{
	# sig[0] is unused-bits count from BIT STRING
	if(len sig < 2 || int sig[0] != 0)
		return ("ECDSA signature: bad bit string", nil);
	(err, e) := asn1->decode(sig[1:]);
	if(err != "" || e == nil)
		return ("ECDSA signature: " + err, nil);
	(ok, el) := e.is_seq();
	if(!ok || len el != 2)
		return ("ECDSA signature: not a SEQUENCE of two", nil);
	rawsig := array [fieldlen * 2] of {* => byte 0};
	for(k := 0; k < 2; k++) {
		b: array of byte;
		(ok, b) = (hd el).is_bigint();
		el = tl el;
		# positive: the first byte's top bit clear, and a leading 00
		# only where the next byte needs it (asn1 has refused others)
		if(!ok || len b == 0 || (int b[0] & 16r80))
			return ("ECDSA signature: r or s not a positive INTEGER", nil);
		if(b[0] == byte 0)
			b = b[1:];
		if(len b > fieldlen)
			return ("ECDSA signature: r or s too large", nil);
		rawsig[(k+1)*fieldlen - len b:] = b;
	}
	return ("", rawsig);
}

# [public]

Signed.tostring(s: self ref Signed): string
{
	str := "Signed";

	str += "\nToBeSigned: " + bastr(s.tobe_signed);
	str += "\nAlgorithm: " + s.alg.tostring();
	str += "\nSignature: " + bastr(s.signature);

	return str + "\n";
}

# DER
# a) the definite form of length encoding shall be used, encoded in the minimum number of 
#    octets;
# b) for string types, the constructed form of encoding shall not be used;
# c) if the value of a type is its default value, it shall be absent;
# d) the components of a Set type shall be encoded in ascending order of their tag value;
# e) the components of a Set-of type shall be encoded in ascending order of their octet value;
# f) if the value of a Boolean type is true, the encoding shall have its contents octet 
#    set to "FF"16;
# g) each unused bits in the final octet of the encoding of a Bit String value, if there are 
#    any, shall be set to zero;
# h) the encoding of a Real type shall be such that bases 8, 10, and 16 shall not be used, 
#    and the binary scaling factor shall be zero.

# [private]
# decode ASN1 one record at a time and return (ok, tag, start of data, 
# end of data)

der_dec1(a: array of byte, i, n: int): (int, Tag, int, int)
{
	length: int;
	tag: Tag;
	ok := 1;
	(ok, i, tag) = der_dectag(a, i, n);
	if(ok) {
		(ok, i, length) = der_declen(a, i, n);
		if(ok) {
			# counted without adding: with a length near the
			# largest int, i+length was negative, passed, and
			# Signed.decode sliced the certificate with it
			if(length < 0 || length > n - i)
				ok = 0;
		}
	}
	if(!ok && X509_DEBUG)
		log("der_dec1: syntax error");
	if(!ok)
		return (0, tag, i, i);
	return (ok, tag, i, i+length);
}

# [private]
# der tag decode

der_dectag(a: array of byte, i, n: int): (int, int, Tag)
{
	ok := 1;
	class, num, constr: int;
	if(n-i >= 2) {
		v := int a[i++];
		class = v & CLASS_MASK;
		if(v & CONSTR_MASK)
			constr = 1;
		else
			constr = 0;
		num = v & TAG_MASK;
		if(num == TAG_MASK) {
			# long tag number: for 31 and above, in the fewest bytes
			if(i < n && a[i] == byte 16r80)
				ok = 0;
			else
				(ok, i, num) = uint7_decode(a, i, n);
			if(ok && num < TAG_MASK)
				ok = 0;
		}
	}
	else
		ok = 0;
	if(!ok && X509_DEBUG)
		log("der_declen: syntax error");
	return (ok, i, Tag(class, num, constr));
}

# [private]

int_decode(a: array of byte, i, n, count, unsigned: int): (int, int, int)
{
	ok := 1;
	num := 0;
	if(n-i >= count) {
		if((count > 4) || (unsigned && count == 4 && (int a[i] & 16r80)))
			ok = 0;		# does not fit an int (it was taken, as 0)
		else {
			if(!unsigned && count > 0 && count < 4 && (int a[i] & 16r80))
				num = -1;		# all bits set
			for(j := 0; j < count; j++) {
				v := int a[i++];
				num = (num << 8) | v;
			}
		}
	}
	else
		ok = 0;
	if(!ok && X509_DEBUG)
		log("int_decode: syntax error");
	return (ok, i, num);
}


# [private]

uint7_decode(a: array of byte, i, n: int) : (int, int, int)
{
	ok := 1;
	num := 0;
	more := 1;
	while(more && i < n) {
		v := int a[i++];
		if(num & 16r7F000000) {
			ok = 0;
			break;
		}
		num <<= 7;
		more = v & 16r80;
		num |= (v & 16r7F);
	}
	if(n == i)
		ok = 0;
	if(!ok && X509_DEBUG)
		log("uint7_decode: syntax error");
	return (ok, i, num);
}


# [private]
# der length decode - the definite form of length encoding shall be used, encoded 
# in the minimum number of octets

der_declen(a: array of byte, i, n: int): (int, int, int)
{
	ok := 1;
	num := 0;
	if(i < n) {
		v := int a[i++];
		if(v == 16r80) # indefinite length (it was asked after the
			ok = 0;	# long form, which had already taken it)
		else if(v & 16r80) {
			# the long form in the fewest bytes (X.690 10.1): a
			# certificate with its length written longer verified,
			# as a second encoding of the same certificate
			if(i < n && a[i] == byte 0)
				return (0, i, 0);
			(ok, i, num) = int_decode(a, i, n, v&16r7F, 1);
			if(ok && num < 16r80)
				ok = 0;
		}
		else
			num = v;
	}
	else
		ok = 0;
	if(!ok && X509_DEBUG)
		log("der_declen: syntax error");
	return (ok, i, num);
}

# [private]
# AlgorithmIdentifier ::= SEQUENCE {
#	algorithm OBJECT IDENTIFIER,
#	parameters ANY DEFINED BY algorithm OPTIONAL }
# from its DER: the algorithm, and the parameters as their own DER (nil
# when there are none).  They were not kept at all: an EC key's curve
# went unread, and the two places a certificate names its signature's
# algorithm could not be compared.

decode_algid(a: array of byte): (int, ref AlgIdentifier)
{
	(ok, tag, i, n) := der_dec1(a, 0, len a);
	if(!ok || n != len a || !tag.constr || tag.class != Universal || tag.num != SEQUENCE)
		return (0, nil);
	oend: int;
	(ok, tag, nil, oend) = der_dec1(a, i, n);
	if(!ok || tag.constr || tag.class != Universal || tag.num != OBJECT_ID)
		return (0, nil);
	(err, e) := asn1->decode(a[i:oend]);
	if(err != "" || e == nil)
		return (0, nil);
	oid: ref Oid;
	(ok, oid) = e.is_oid();
	if(!ok)
		return (0, nil);
	params: array of byte;
	if(oend < n) {
		# one value, well formed
		(err, nil) = asn1->decode(a[oend:n]);
		if(err != "")
			return (0, nil);
		params = a[oend:n];
	}
	return (1, ref AlgIdentifier(oid, params));
}

# [private]
# The DER of each element of the SEQUENCE a is, in order (at most max).

derfields(a: array of byte, max: int): (int, array of array of byte)
{
	(ok, tag, i, n) := der_dec1(a, 0, len a);
	if(!ok || n != len a || !tag.constr || tag.class != Universal || tag.num != SEQUENCE)
		return (0, nil);
	f := array[max] of array of byte;
	k := 0;
	while(i < n) {
		e: int;
		(ok, nil, nil, e) = der_dec1(a, i, n);
		if(!ok || k >= max)
			return (0, nil);
		f[k++] = a[i:e];
		i = e;
	}
	return (1, f[0:k]);
}

# [private]
# RFC 5280 4.1.1.2: the signatureAlgorithm beside a certificate's (or
# CRL's) signature "MUST contain the same algorithm identifier as the
# signature field in the sequence tbsCertificate"; 4.1.2.3 says it
# again of the inner one, and 5.1.1.2, 5.1.2.2 of a CRL.  Algorithm
# and parameters, byte for byte.  Only the outer one was read: a
# certificate whose signed part said MD5 with RSA verified as whatever
# the unsigned part named.

algsame(a, b: ref AlgIdentifier): int
{
	if(a == nil || b == nil || a.oid == nil || b.oid == nil)
		return 0;
	return oid_cmp(a.oid, b.oid) && bytesequal(a.parameter, b.parameter);
}

## TBS (Public Key) Certificate is signed by Certificate Authority and contains 
## information of public key usage (as a comparison of Certificate Revocation List 
## and Attribute Certificate).

# [public]
# constructs a certificate by parsing a der encoded certificate
# returns error if parsing is failed or nil if parsing is ok

certsyn(s: string): (string, ref Certificate)
{
	if(0)
		sys->fprint(sys->fildes(2), "cert: %s\n", s);
	return ("certificate syntax: "+s, nil);
}

#	Certificate ::= SEQUENCE {
#		certificateInfo CertificateInfo,
#		signatureAlgorithm AlgorithmIdentifier,
#		signature BIT STRING }
#
#	CertificateInfo ::= SEQUENCE {
#		version [0] INTEGER DEFAULT v1 (0),
#		serialNumber INTEGER,
#		signature AlgorithmIdentifier,
#		issuer Name,
#		validity Validity,
#		subject Name,
#		subjectPublicKeyInfo SubjectPublicKeyInfo }
#	(version v2 has two more fields, optional unique identifiers for
#  issuer and subject; since we ignore these anyway, we won't parse them)
#
#	Validity ::= SEQUENCE {
#		notBefore UTCTime,
#		notAfter UTCTime }
#
#	SubjectPublicKeyInfo ::= SEQUENCE {
#		algorithm AlgorithmIdentifier,
#		subjectPublicKey BIT STRING }
#
#	AlgorithmIdentifier ::= SEQUENCE {
#		algorithm OBJECT IDENTIFER,
#		parameters ANY DEFINED BY ALGORITHM OPTIONAL }
#
#	Name ::= SEQUENCE OF RelativeDistinguishedName
#
#	RelativeDistinguishedName ::= SETOF SIZE(1..MAX) OF AttributeTypeAndValue
#
#	AttributeTypeAndValue ::= SEQUENCE {
#		type OBJECT IDENTIFER,
#		value DirectoryString }
#	(selected attributes have these Object Ids:
#		commonName {2 5 4 3}
#		countryName {2 5 4 6}
#		localityName {2 5 4 7}
#		stateOrProvinceName {2 5 4 8}
#		organizationName {2 5 4 10}
#		organizationalUnitName {2 5 4 11}
#	)
#
#	DirectoryString ::= CHOICE {
#		teletexString TeletexString,
#		printableString PrintableString,
#		universalString UniversalString }
#
#  See rfc1423, rfc2437 for AlgorithmIdentifier, subjectPublicKeyInfo, signature.

Certificate.decode(a: array of byte): (string, ref Certificate)
{
	# as Signed.decode: a peer's bytes are an error at worst
	{
		return certdecode(a);
	} exception e {
	"*" =>
		return ("certificate: internal error: " + e, nil);
	}
}

certdecode(a: array of byte): (string, ref Certificate)
{
parse:
	# break on error
	for(;;) {
		(err, all) := asn1->decode(a);
		if(err != "" || all == nil)
			return certsyn(err);
		c := ref Certificate;

		# a TBSCertificate, which is a SEQUENCE.  (A SEQUENCE of three
		# was taken for a whole Certificate and its first element
		# read, for the SSL 3.0 client, which is gone: a caller gives
		# what Signed.decode found signed.)
		(ok, el) := all.is_seq();
		if(!ok)
			return certsyn("invalid certificate sequence");
		# the fields that are kept as bytes
		(fok, f) := derfields(a, 10);
		if(!fok || len f != len el)
			return certsyn("invalid certificate sequence");
		fi := 0;

		# serialNumber to subjectPublicKeyInfo are six, taken below one
		# after the other (a shorter list was "dereference of nil": the
		# count was asked only when a version came first)
		if(len el < 6)
			return certsyn("short certificate info");
		c.version = 0; # set to default (v1)
		(ok, c.version) = parse_version(hd el);
		if(!ok)
			return certsyn("can't parse version");
		(hasver, nil) := is_context(hd el, 0);
		if(hasver) {
			# a version written out, v1 too: [0] is not the serial
			# number (RFC 5280 4.1.2.1 would have v1 left out)
			el = tl el;
			fi++;
			if(len el < 6)
				return certsyn("short certificate info");
		}
		# serial number
		(ok, c.serial_number) = parse_sernum(hd el);
		if(!ok)
			return certsyn("can't parse serial number");
		el = tl el;
		# signature algorithm
		(ok, c.sig) = decode_algid(f[fi+1]);
		if(!ok)
			return certsyn("can't parse sigalg");
		el = tl el;
		# issuer 
		(ok, c.issuer) = parse_name(hd el);
		if(!ok)
			return certsyn("can't parse issuer");
		el = tl el;
		# validity	
		evalidity := hd el;
		(ok, c.validity) = parse_validity(evalidity);
		if(!ok)
			return certsyn("can't parse validity");
		el = tl el;
		# Subject
		(ok, c.subject) = parse_name(hd el);
		if(!ok)
			return certsyn("can't parse subject");
		el = tl el;
		# SubjectPublicKeyInfo
		(ok, c.subject_pkinfo) = parse_pkinfo(hd el, f[fi+5]);
		if(!ok)
			return certsyn("can't parse subject pk info");
		el = tl el;
		# OPTIONAL for v2 and v3, must be in order
		# issuer unique identifier
		if(c.version == 0 && el != nil)
			return certsyn("bad unique ID");
		if(el != nil) {
			if(c.version < 1) # at least v2
				return certsyn("invalid v1 cert");
			(ok, c.issuer_uid) = parse_uid(hd el, 1);
			if(ok)
				el = tl el;
		}
		# subject unique identifier
		if(el != nil) {
			if(c.version < 1) # v2 or v3
				return certsyn("invalid v1 cert");
			(ok, c.subject_uid) = parse_uid(hd el, 2);
			if(ok)
				el = tl el;
		}
		# extensions
		if(el != nil) {
			if(c.version < 2) # must be v3
				return certsyn("invalid v1/v2 cert");
			e : ref Elem;
			(ok, e) = is_context(hd el, 3);
			if (!ok)
				break parse;
			(ok, c.exts) = parse_extlist(e);
			if(!ok)
				return certsyn("can't parse extension list");
			el = tl el;
		}
		# must be no more left
		if(el != nil)
			return certsyn("unexpected data at end");
		return ("", c);
	}

	return ("certificate: syntax error", nil);
}


# [public]
# converts content of a certificate as visible string

Certificate.tostring(c: self ref Certificate): string
{
	s := "\tTBS Certificate";
	s += "\n\tVersion:\n\t\t" + string c.version;
	s += "\n\tSerialNumber:\n\t\t" + c.serial_number.iptostr(10);
	s += "\n\tSignature: " + c.sig.tostring();
	s += "\n\tIssuer: " + c.issuer.tostring();
	s += "\n\tValidity: " + c.validity.tostring("local");
	s += "\n\tSubject: " + c.subject.tostring();
	s += "\n\tSubjectPKInfo: " + c.subject_pkinfo.tostring();
	s += "\n\tIssuerUID: " + bastr(c.issuer_uid);
	s += "\n\tSubjectUID: " + bastr(c.subject_uid);
	s += "\n\tExtensions: ";
	exts := c.exts;
	while(exts != nil) {
		s += "\t\t" + (hd exts).tostring();
		exts = tl exts;
	}
	return s;
}

# [public]

Certificate.is_expired(c: self ref Certificate, date: int): int
{
	if(big date > c.validity.not_after || big date < c.validity.not_before)
		return 1;

	return 0;
}


# [private]
# version is optional marked by explicit context tag 0; no version is 
# required if default version (v1) is used

parse_version(e: ref Elem): (int, int)
{
	ver := 0;
	(ans, ec) := is_context(e, 0);
	if(ans) {
		ok := 0;
		(ok, ver) = ec.is_int();
		if(!ok || ver < 0 || ver > 2)
			return (0, -1);
	}
	return (1, ver);
}


# [private]

parse_sernum(e: ref Elem): (int, ref IPint)
{
	(ok, a) := e.is_bigint();
	if(ok && len a > 0)
		return (1, derint(a));
	if(X509_DEBUG)
		log("parse_sernum: syntax error");
	return (0, nil);
}

# [private]
# The number an INTEGER's bytes are, two's complement.  A serial number
# is positive (RFC 5280 4.1.2.2), but CAs have issued negative ones and
# the same section asks that they be handled: as the numbers they are.
# (The bytes were read as a magnitude, so -128 in one byte and
# 4294967168 in five were one serial number to a CRL.)

derint(a: array of byte): ref IPint
{
	n := IPint.bebytestoip(a);
	if(int a[0] & 16r80)
		n = n.sub(IPint.inttoip(1).shl(8*len a));
	return n;
}


# [private]

parse_name(e: ref Elem): (int, ref Name)
{
parse:
	for(;;) {
		(ok, el) := e.is_seq();
		if(!ok)
			break parse;
		lrd: list of ref RDName;
		while(el != nil) {
			rd: ref RDName;
			(ok, rd) = parse_rdname(hd el);
			if(!ok)
				break parse;
			lrd = rd :: lrd;
			el = tl el;
		}
		# SEQUENCE
		l: list of ref RDName;
		while(lrd != nil) {
			l = (hd lrd) :: l;
			lrd = tl lrd;
		}
		return (1, ref Name(l));
	}
	if(X509_DEBUG)
		log("parse_name: syntax error");
	return (0, nil);
}


# [private]

parse_rdname(e: ref Elem): (int, ref RDName)
{
parse:
	for(;;) {
		(ok, el) := e.is_set(); # unordered
		if(!ok)
			break parse;
		lava: list of ref AVA;
		while(el != nil) {
			ava: ref AVA;
			(ok, ava) = parse_ava(hd el);
			if(!ok)
				break parse;
			lava = ava :: lava;
			el = tl el;
		}
		return (1, ref RDName(lava));
	}
	if(X509_DEBUG)
		log("parse_rdname: syntax error");
	return (0, nil);
}


# [private]

parse_ava(e: ref Elem): (int, ref AVA)
{
parse:
	for(;;) {
		(ok, el) := e.is_seq();
		if(!ok || len el != 2)
			break parse;
		a := ref AVA;
		(ok, a.oid) = (hd el).is_oid();
		if(!ok)
			break parse;
		el = tl el;
		(ok, a.value) = (hd el).is_string();
		if(!ok || hasnul(a.value))
			break parse;
		return (1, a);
	}
	if(X509_DEBUG)
		log("parse_ava: syntax error");
	return (0, nil);
}


# [private]
# A name with a NUL in it is no name: the certificate, or the CRL, is
# refused.  What reads a name as far as its NUL and what reads all of
# it see two names, which is how "bank.example\0.attacker.example" was
# once a certificate for bank.example.  asn1 gives a string as its
# type has it, NUL and all.

hasnul(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == 0)
			return 1;
	return 0;
}

# [private]
# Validity, per RFC 5280 4.1.2.5: each of notBefore and notAfter is a Time,
# a CHOICE of UTCTime and GeneralizedTime.  CAs use UTCTime through 2049 and
# GeneralizedTime from 2050, and a conforming implementation must accept both.

parse_validity(e: ref Elem): (int, ref Validity)
{
parse:
	for(;;) {
		(ok, el) := e.is_seq();
		if(!ok || len el != 2)
			break parse;
		v := ref Validity;
		(ok, v.not_before) = parse_time(hd el, 0);
		if(!ok)
			break parse;
		el = tl el;
		(ok, v.not_after) = parse_time(hd el, 0);
		if(!ok)
			break parse;
		return (1, v);
	}
	if(X509_DEBUG)
		log("parse_validity: syntax error");
	return (0, nil);
}

# [private]
# Parse a time as format: UTCTime, GeneralizedTime, or either (any other
# int; RFC 5280's Time CHOICE).  Times are seconds since the epoch, GMT, as
# big: a certificate's dates run well past 2038, where an int ends.

parse_time(e: ref Elem, format: int): (int, big)
{
parse:
	for(;;) {
		(ok, date) := e.is_time();
		if(!ok)
			break parse;
		if(e.tag.num != UTCTime && e.tag.num != GeneralizedTime)
			break parse;
		if(format == UTCTime && e.tag.num != UTCTime)
			break parse;
		if(format == GeneralizedTime && e.tag.num != GeneralizedTime)
			break parse; 
		t: big;
		(ok, t) = decode_time(date, e.tag.num);
		if(!ok)
			break parse;
		return (1, t);
	}
	if(X509_DEBUG)
		log("parse_time: syntax error");
	return (0, big 0);
}

# [private]
# A UTCTime or GeneralizedTime as seconds since 1970-01-01 00:00:00
# GMT.  Returns (ok, seconds).  RFC 5280 4.1.2.5 has each in one form:
#	UTCTime		YYMMDDHHMMSSZ; YY >= 50 is 19YY, else 20YY
#	GeneralizedTime	YYYYMMDDHHMMSSZ
# seconds always, Z always, no fraction and no offset from GMT, and
# 5.1.2.4 to 5.1.2.6 say the same of a CRL's.  X.680's other forms
# (no seconds, an offset, a fraction, no zone at all) were taken as
# well, on purpose; a reader that takes them reads the edges of a
# certificate's life differently from one that does not, by hours.
# All 121 roots in /lib/certs are in the two forms.

decode_time(date: string, format: int): (int, big)
{
	year, mon, mday, hour, min, sec: int;
	i := 0;
	n := len date;
parse:
	for(;;) {
		if(format == UTCTime) {
			if(n != 13 || !isdigits(date, 0, 12) || date[12] != 'Z')
				break parse;
			year = get2(date, 0);
			if(year < 50)
				year += 2000;
			else
				year += 1900;
			i = 2;
		}
		else {
			if(n != 15 || !isdigits(date, 0, 14) || date[14] != 'Z')
				break parse;
			year = get2(date, 0)*100 + get2(date, 2);
			i = 4;
		}
		mon = get2(date, i);
		if(mon < 1 || mon > 12)
			break parse;
		i += 2;
		mday = get2(date, i);
		if(mday < 1 || mday > monthdays(year, mon))
			break parse;
		i += 2;
		hour = get2(date, i);
		if(hour > 23)
			break parse;
		i += 2;
		min = get2(date, i);
		if(min > 59)
			break parse;
		i += 2;
		sec = get2(date, i);
		if(sec > 59)
			break parse;
		t := big days_from_civil(year, mon, mday) * big 86400
			+ big (hour*3600 + min*60 + sec);
		return (1, t);
	}
	if(X509_DEBUG)
		log("decode_time: syntax error: " + date +
		sys->sprint(" (year=%d mon=%d mday=%d hour=%d min=%d sec=%d)", 
		year, mon, mday, hour, min, sec));
	return (0, big 0);
}

# [private]

isdigits(s: string, i, n: int): int
{
	if(i < 0 || i+n > len s)
		return 0;
	for(; n > 0; n--) {
		if(s[i] < '0' || s[i] > '9')
			return 0;
		i++;
	}
	return 1;
}

# [private]
# days in month mon (1-12) of year

monthdays(year, mon: int): int
{
	case mon {
	2 =>
		if(year%4 == 0 && (year%100 != 0 || year%400 == 0))
			return 29;
		return 28;
	4 or 6 or 9 or 11 =>
		return 30;
	}
	return 31;
}

# [private]
# Days since 1970-01-01 of the proleptic Gregorian date year-mon-mday
# (mon 1-12), and back.  Howard Hinnant's algorithms; exact for any year
# an int holds, with no loop and no table.

days_from_civil(year, mon, mday: int): int
{
	if(mon <= 2)
		year--;
	era := year;
	if(era < 0)
		era -= 399;
	era /= 400;
	yoe := year - era*400;				# [0, 399]
	mp := (mon + 9) % 12;				# March is 0
	doy := (153*mp + 2)/5 + mday - 1;		# [0, 365]
	doe := yoe*365 + yoe/4 - yoe/100 + doy;		# [0, 146096]
	return era*146097 + doe - 719468;
}

civil_from_days(z: int): (int, int, int)
{
	z += 719468;
	era := z;
	if(era < 0)
		era -= 146096;
	era /= 146097;
	doe := z - era*146097;
	yoe := (doe - doe/1460 + doe/36524 - doe/146096)/365;
	y := yoe + era*400;
	doy := doe - (365*yoe + yoe/4 - yoe/100);
	mp := (5*doy + 2)/153;
	d := doy - (153*mp + 2)/5 + 1;
	m := mp + 3;
	if(m > 12)
		m -= 12;
	if(m <= 2)
		y++;
	return (y, m, d);
}

# [private]
# A Daytime->Tm, in GMT, for a time in seconds since the epoch, good for
# any time a certificate can hold (Daytime's own gmt takes an int).

bgmt(t: big): ref Daytime->Tm
{
	days := t / big 86400;
	secs := int (t - days*big 86400);
	if(secs < 0) {
		secs += 86400;
		days--;
	}
	(y, m, d) := civil_from_days(int days);
	tm := ref Daytime->Tm;
	tm.year = y - 1900;
	tm.mon = m - 1;
	tm.mday = d;
	tm.hour = secs/3600;
	tm.min = (secs/60)%60;
	tm.sec = secs%60;
	tm.wday = int ((days%big 7 + big 11)%big 7);	# 1970-01-01 was a Thursday
	tm.yday = days_from_civil(y, m, d) - days_from_civil(y, 1, 1);
	tm.zone = "GMT";
	tm.tzoff = 0;
	return tm;
}

# [private]
# The time as text: in local time when Daytime can say it, else GMT.

timetext(t: big, local: int): string
{
	if(local && t >= big -16r7FFFFFFF && t <= big 16r7FFFFFFF)
		return daytime->text(daytime->local(int t));
	return daytime->text(bgmt(t));
}


# [private]

parse_pkinfo(e: ref Elem, der: array of byte): (int, ref SubjectPKInfo)
{
parse:
	for(;;) {
		p := ref SubjectPKInfo;
		(ok, el) := e.is_seq();
		if(!ok || len el != 2)
			break parse;
		# the algorithm from its bytes: its parameters name an EC
		# key's curve
		(fok, f) := derfields(der, 2);
		if(!fok || len f != 2)
			break parse;
		(ok, p.alg_id) = decode_algid(f[0]);
		if(!ok)
			break parse;
		unused: int;
		(ok, unused, p.subject_pk) = (hd tl el).is_bitstring();
		if(!ok || unused != 0)
			break parse;
		return (1, p);
	}
	if(X509_DEBUG)
		log("parse_pkinfo: syntax error");
	return (0, nil);
}


# [private]

parse_uid(e: ref Elem, num: int): (int, array of byte)
{
	ok, unused : int;
	uid : array of byte;
	e2 : ref Elem;
parse:
	for(;;) {
		(ok, e2) = is_context(e, num);
		if (!ok)
			break parse;
		e = e2;

		(ok, unused, uid) = e.is_bitstring();
#		if(!ok || unused != 0)
		if(!ok)
			break parse;
		return (1, uid);
	}
	if(X509_DEBUG)
		log("parse_uid: syntax error");
	return (0, nil);
}


# [private]

parse_extlist(e: ref Elem): (int, list of ref Extension)
{
parse:
	# dummy loop for breaking out of
	for(;;) {
		l: list of ref Extension;
		(ok, el) := e.is_seq();
		if(!ok)
			break parse;
		while(el != nil) {
			ext := ref Extension;
			(ok, ext) = parse_extension(hd el);
			if(!ok)
				break parse;
			l = ext :: l;
			el = tl el;
		}
		# sort to order
		nl: list of ref Extension;
		while(l != nil) {
			nl = (hd l) :: nl;
			l = tl l;
		}
		return (1, nl);
	}
	if(X509_DEBUG)
		log("parse_extlist: syntax error");
	return (0, nil);
}


# [private]
# What a critical extension means is asked by the path (certinfo)

parse_extension(e: ref Elem): (int, ref Extension)
{
parse:
	for(;;) {
		ext := ref Extension;
		(ok, el) := e.is_seq();
		# an OID, perhaps a BOOLEAN, an OCTET STRING (an empty
		# SEQUENCE, or the OID alone, was "dereference of nil")
		if(!ok || len el < 2 || len el > 3)
			break parse;
		oid: ref Oid;
		(ok, oid) = (hd el).is_oid(); 
		if(!ok)
			break parse;
		ext.oid = oid; 
		el = tl el;
		# BOOLEAN DEFAULT FALSE
		ext.critical = 0;
		if(len el == 2) {
			(ok, ext.critical) = derbool(hd el);
			if(!ok)
				break parse;
			el = tl el;
		}
		if (len el != 1) {
			break parse;
		}
		(ok, ext.value) = (hd el).is_octetstring();
		if(!ok)
			break parse;
		return (1, ext);
	}
	if(X509_DEBUG)
		log("parse_extension: syntax error");
	return (0, nil);
}

# [private]
# A BOOLEAN of a certificate or CRL: the universal type, and DER's two
# values, 16rFF true and 0 false (X.690 11.1).  BER takes any other
# byte for true; a certificate is DER (RFC 5280 4.1), and a reader
# that takes 16r01 for true where another takes it for malformed is
# not one to decide who is a CA.  FALSE written out where it is the
# default is not DER either, but CAs have written it, and it has only
# the one meaning.
# returns (ok, value)

derbool(e: ref Elem): (int, int)
{
	if(e == nil || e.tag.class != Universal || e.tag.num != BOOLEAN)
		return (0, 0);
	pick v := e.val {
	Bool =>
		if(v.v == 16rFF)
			return (1, 1);
		if(v.v == 0)
			return (1, 0);
	}
	return (0, 0);
}


# [public]

AlgIdentifier.tostring(a: self ref AlgIdentifier): string
{
	return "\n\t\toid: " + a.oid.tostring() + "\n\t\twith parameter: "+ bastr(a.parameter);
}

# [public]

Name.equal(a: self ref Name, b: ref Name): int
{
	rda := a.rd_names;
	rdb := b.rd_names;
	if(len rda != len rdb)
		return 0;
	while(rda != nil && rdb != nil) {
		ok := (hd rda).equal(hd rdb);
		if(!ok)
			return 0;
		rda = tl rda;
		rdb = tl rdb;
	}

	return 1;
}

# [public]
# The sequence of RelativeDistinguishedName's gives a sort of pathname, from most general to 
# most specific.  Each element of the path can be one or more (but usually just one) 
# attribute-value pair, such as countryName="US". We'll just form a "postal-style" address 
# string by concatenating the elements from most specific to least specific, separated by commas.

Name.tostring(a: self ref Name): string
{
	path: string;
	rdn := a.rd_names;
	while(rdn != nil) {
		path += (hd rdn).tostring();
		rdn = tl rdn;
		if(rdn != nil)
			path += ",";
	}
	return path;
}

# [public]
# The allocation of distinguished names is the responsibility of the Naming Authorities. 
# Each user shall therefore trust the Naming Authorities not to issue duplicate distinguished
# names. The comparison shall be unique one to one match but may not in the same order.

RDName.equal(a: self ref RDName, b: ref RDName): int
{
	if(len a.avas != len b.avas)
		return 0;
	aa := a.avas;
	ba := b.avas;
	while(aa != nil) {
		found:= 0;
		rest: list of ref AVA;
		while(ba != nil) {
			ok := (hd aa).equal(hd ba);
			if(!ok)
				rest = (hd ba) :: rest;
			else {
				if(found)
					return 0;
				found = 1;
			}
			ba = tl ba;
		}
		if(found == 0)
			return 0;
		ba = rest;
		aa = tl aa;
	}
	return 1;
}

# [public]

RDName.tostring(a: self ref RDName): string
{
	s: string;
	avas := a.avas;
	while(avas != nil) {
		s += (hd avas).tostring();
		avas = tl avas;
		if(avas != nil)
			s += "-";
	}
	return s;
}

# [public]
# AVA are equal if they have the same type oid and value

AVA.equal(a: self ref AVA, b: ref AVA): int
{
	# TODO: need to match different encoding (T61String vs. IA5String)
	if(a.value != b.value)
		return 0;

	return oid_cmp(a.oid, b.oid);
}

# [public]

AVA.tostring(a: self ref AVA): string
{
	return a.value;
}

# [public]

Validity.tostring(v: self ref Validity, format: string): string
{
	s: string;
	if(format == "local") {
		s = "\n\t\tnot_before[local]: ";
	 	s += timetext(v.not_before, 1);
		s += "\n\t\tnot_after[local]: ";
		s += timetext(v.not_after, 1);
	}
	else if(format == "gmt") {
		s = "\n\t\tnot_before[gmt]: ";
	 	s += timetext(v.not_before, 0);
		s += "\n\t\tnot_after[gmt]: ";
		s += timetext(v.not_after, 0);
	}
	else
		s += "unknown format: " + format;
	return s;	
}

# [public]

SubjectPKInfo.getPublicKey(pkinfo: self ref SubjectPKInfo): (string, int, ref PublicKey)
{
	if(pkinfo == nil || pkinfo.alg_id == nil || pkinfo.alg_id.oid == nil)
		return ("subject public key: syntax error", -1, nil);
	params := pkinfo.alg_id.parameter;
	id := asn1->oid_lookup(pkinfo.alg_id.oid, pkcs->objIdTab);
	case id {
	PKCS->id_pkcs_rsaEncryption =>
		# RFC 3279 2.3.1: "the parameters field MUST have ASN.1 type
		# NULL for this algorithm identifier".  (The OIDs of three
		# signature algorithms, MD2, MD4 and MD5 with RSA, were taken
		# for a key's as well.)
		if(!bytesequal(params, DERNULL))
			return ("subject public key: rsaEncryption without NULL parameters", -1, nil);
		(err, k) := pkcs->decode_rsapubkey(pkinfo.subject_pk);
		if(err != nil)
			return ("subject public key: " + err, -1, nil);
		return ("", id, ref PublicKey.RSA(k));
	PKCS->id_ec_publicKey =>
		# RFC 5480 2.1.1: the parameters are the curve's name
		# (namedCurve: "implicitCurve and specifiedCurve MUST NOT be
		# used in PKIX"), and 2.2: the key is a point of it,
		# uncompressed here.  The curve was not read: a point was
		# taken to be on whichever curve its length suggested, P-256
		# for 65 bytes and P-384 for 97, whatever the certificate
		# said.  The named curve is the rule, and a point of another
		# length is refused.
		if(params == nil)
			return ("subject public key: EC key with no curve named", -1, nil);
		(err, e) := asn1->decode(params);
		oid: ref Oid;
		ok := 0;
		if(err == "" && e != nil)
			(ok, oid) = e.is_oid();
		if(!ok)
			return ("subject public key: EC parameters are not a named curve", -1, nil);
		need := 0;
		case asn1->oid_lookup(oid, pkcs->objIdTab) {
		PKCS->id_prime256v1 =>	need = 65;
		PKCS->id_secp384r1 =>	need = 97;
		* =>
			return ("subject public key: unsupported curve " + oid.tostring(), -1, nil);
		}
		pt := pkinfo.subject_pk;
		if(len pt != need || pt[0] != byte 4)
			return ("subject public key: not an uncompressed point of its curve", -1, nil);
		return ("", id, ref PublicKey.EC(pt));
	}
	return ("subject public key: unsupported algorithm " + pkinfo.alg_id.oid.tostring(), -1, nil);
}

# [public]

SubjectPKInfo.tostring(pkinfo: self ref SubjectPKInfo): string
{
	s := pkinfo.alg_id.tostring();
	s += "\n\t\tencoded key: " + bastr(pkinfo.subject_pk);
	return s;
}

# [public]

Extension.tostring(e: self ref Extension): string
{
	s := "oid: " + e.oid.tostring();
	s += "critical: ";
	if(e.critical)
		s += "true ";
	else
		s += "false ";
	s += bastr(e.value);
	return s;
}

## Certificate PATH
## A list of certificates needed to allow a particular user to obtain
## the public key of another, is known as a certificate path. A
## certificate path logically forms an unbroken chain of trusted
## points in the DIT between two users wishing to authenticate.
## To establish a certification path between user A and user B using
## the Directory without any prior information, each CA may store
## one certificate and one reverse certificate designated as
## corresponding to its superior CA.

# The ASN.1 data byte definitions for certificates and a certificate 
# path is
#
# Certificates	::= SEQUENCE {
#	userCertificate		Certificate,
#	certificationPath	ForwardCertificationPath OPTIONAL }
#
# ForwardCertificationPath ::= SEQUENCE OF CrossCertificates
# CrossCertificates ::=	SET OF Certificate
# 

# [public]
# Verify a certificate chain as presented by a TLS peer (leaf first,
# intermediates in any order, duplicates and extra certificates allowed:
# RFC 8446 section 4.4.2). Succeeds only when a path from the leaf ends at
# a root in the trust store (/lib/certs). Return (1, "") on success or
# (0, reason).

verify_certchain(cs: list of array of byte, usage: int): (int, string)
{
	# The chain is a peer's, and the caller is as a rule in the middle
	# of a handshake with nothing to catch an exception: whatever goes
	# wrong in here is a chain that did not verify.
	{
		return verify_chain(cs, ref VCtx(nil, nil, 0, 1, MAXWORK, usage));
	} exception e {
	"*" =>
		return (0, "certificate chain: internal error: " + e);
	}
}

verify_chain(cs: list of array of byte, ctx: ref VCtx): (int, string)
{
	if(ctx.usage < Usage_Any || ctx.usage > Usage_ClientAuth)
		return (0, "certificate chain: unknown usage");
	nodes: list of ref Node;
	for(l := cs; l != nil; l = tl l) {
		der := hd l;
		if(seen(nodes, der))
			continue;
		(err, s) := Signed.decode(der);
		if(err != "")
			return (0, "certificate: " + err);
		c: ref Certificate;
		(err, c) = Certificate.decode(s.tobe_signed);
		if(err != "")
			return (0, "certificate: " + err);
		if(!algsame(s.alg, c.sig))
			return (0, "certificate: signatureAlgorithm is not the algorithm its tbsCertificate names: " + c.subject.tostring());
		nodes = ref Node(der, s, c, nil, nil, 0) :: nodes;
	}
	if(nodes == nil)
		return (0, "no certificates");
	l2: list of ref Node;
	for(; nodes != nil; nodes = tl nodes)
		l2 = hd nodes :: l2;	# back to presented order
	return verify_leaf(hd l2, tl l2, ctx);
}

# [public]
verify_certchain_roots(cs: list of array of byte, roots: list of array of byte,
	crls: list of array of byte, now: int, usage: int): (int, string)
{
	{
		return verify_roots(cs, roots, crls, now, usage);
	} exception e {
	"*" =>
		return (0, "certificate chain: internal error: " + e);
	}
}

verify_roots(cs: list of array of byte, roots: list of array of byte,
	crls: list of array of byte, now: int, usage: int): (int, string)
{
	ctx := ref VCtx(nil, nil, now, 0, MAXWORK, usage);
	for(r := roots; r != nil; r = tl r) {
		(serr, s) := Signed.decode(hd r);
		if(serr != "")
			return (0, "root: " + serr);
		(cerr, c) := Certificate.decode(s.tobe_signed);
		if(cerr != "")
			return (0, "root: " + cerr);
		if(!algsame(s.alg, c.sig))
			return (0, "root: signatureAlgorithm is not the algorithm its tbsCertificate names: " + c.subject.tostring());
		ctx.roots = ref TrustedRoot(s, c) :: ctx.roots;
	}
	if(ctx.roots == nil)
		return (0, "no roots");
	for(l := crls; l != nil; l = tl l) {
		(serr, s) := Signed.decode(hd l);
		if(serr != "")
			return (0, "CRL: " + serr);
		(cerr, crl) := CRL.decode(s.tobe_signed);
		if(cerr != "")
			return (0, "CRL: " + cerr);
		if(!algsame(s.alg, crl.sig))
			return (0, "CRL: signatureAlgorithm is not the algorithm its tbsCertList names: " + crl.issuer.tostring());
		# A CRL counts only if its issuer signed it.  One that names
		# a root is checked now, once, with that root's key; if the
		# root has a keyUsage it has cRLSign (RFC 5280 6.3.3 (f)).
		# One a root of its name did not sign, and one that names
		# another CA, are checked where they are used, on a path
		# through their issuer (check_revoked), and refuse that path
		# if they fail there: they are not this call's failure, since
		# the chain may be another CA's altogether.
		signed := 0;
		for(t := ctx.roots; t != nil && !signed; t = tl t)
			if((hd t).cert.subject.equal(crl.issuer)) {
				(x, xerr) := certinfo((hd t).cert, (hd t).signed.tobe_signed);
				if(xerr != nil || x.ku && !(x.usage & KeyUsage_CRLSign))
					continue;
				(ok, nil) := verify_issued(s, (hd t).cert);
				signed = ok;
			}
		ctx.crls = ref CRLEntry(s, crl, signed) :: ctx.crls;
	}
	return verify_chain(cs, ctx);
}

# [private]
# Chain validation, RFC 5280 section 6, for a verifier that is asked
# whether a chain ends at a root and names no policy of its own:
# signatures, validity (the trust anchor's too), basicConstraints,
# keyUsage, pathLenConstraint, CRLs, name constraints, and the rule of
# 4.2 that a critical extension is processed or the certificate is
# refused.  It fails closed: an unsupported signature algorithm, an
# extension it cannot read, a constraint on a kind of name it does not
# compare, are errors and not passes.

MAXPATH: con 8;		# intermediates between leaf and trust anchor
MAXEXTS: con 128;	# extensions in one certificate (each is asked for a twin)

Node: adt {
	der:	array of byte;
	s:	ref Signed;
	c:	ref Certificate;
	x:	ref Xinfo;	# what its extensions say, once read
	xerr:	string;		# or why they cannot be taken
	xdone:	int;
};

# A certificate's extensions as the path uses them
Xinfo: adt {
	bc:	int;		# has basicConstraints
	ca:	int;
	pathlen:	int;	# -1: none
	ku:	int;		# has keyUsage
	usage:	int;		# its bits, KeyUsage_*
	san:	int;		# has subjectAltName
	names:	list of ref GName;	# its names
	nc:	ref NameCons;	# nameConstraints, or nil
	explicit:	int;	# policyConstraints' requireExplicitPolicy, or -1
	subject:	list of list of ref Av;	# the subject, with its strings' types
	eku:	int;		# has extendedKeyUsage
	purposes:	list of ref Oid;	# its purposes
};

# An attribute of a distinguished name with the type of its string
Av: adt {
	oid:	ref Oid;
	kind:	int;	# universal tag of the value
	s:	string;
};

# A GeneralName, as far as names are compared here: the form is its
# context tag (RFC 5280 4.2.1.6)
GNother, GNrfc822, GNdns, GNx400, GNdir, GNedi, GNuri, GNip, GNrid: con iota;
GName: adt {
	form:	int;
	s:	string;			# rfc822Name, dNSName, URI
	b:	array of byte;		# iPAddress
	dn:	list of list of ref Av;	# directoryName
};

NameCons: adt {
	permitted:	list of ref GName;
	excluded:	list of ref GName;
};

nodeinfo(n: ref Node): (ref Xinfo, string)
{
	if(!n.xdone) {
		(n.x, n.xerr) = certinfo(n.c, n.s.tobe_signed);
		n.xdone = 1;
	}
	return (n.x, n.xerr);
}

verify_leaf(leaf: ref Node, pool: list of ref Node, ctx: ref VCtx): (int, string)
{
	(nil, xerr) := nodeinfo(leaf);
	if(xerr != nil)
		return (0, "certificate: " + xerr + ": " + leaf.c.subject.tostring());
	if(!validat(leaf.c.validity, ctxnow(ctx)))
		return (0, "certificate expired or not yet valid: " + leaf.c.subject.tostring());
	return findpath(leaf, pool, 0, leaf :: nil, ctx);
}

# n is accepted; find its issuer. depth counts the intermediates already
# on the path below n's issuer (0 when n is the leaf).  path is the
# certificates from n down to the leaf.
findpath(n: ref Node, pool: list of ref Node, depth: int, path: list of ref Node, ctx: ref VCtx): (int, string)
{
	if(is_anchor(n, ctx)) {
		# an anchor is not on a CRL a root signed (one given as an
		# anchor that its own issuer, a root too, has revoked)
		(revoked, reason) := check_revoked(n.c, nil, nil, ctx);
		if(revoked)
			return (0, reason);
		err := check_path(nil, path, ctx);
		if(err != nil)
			return (0, err);
		return (1, "");
	}
	if(depth > MAXPATH)
		return (0, "certificate path too long");
	lasterr := "no trusted root CA for " + n.c.issuer.tostring();

	# a trust anchor that issued n
	for(t := ctxroots(ctx); t != nil; t = tl t) {
		tr := hd t;
		if(!tr.cert.subject.equal(n.c.issuer))
			continue;
		# A root is trusted for as long as it says: RFC 5280 6.1 takes
		# a trust anchor as a name and a key and has no date to ask
		# of it, but a root given as a certificate carries the dates
		# its CA meant, and OpenSSL, Go and NSS hold it to them.  (An
		# expired root in the store went on vouching for chains.)
		if(!validat(tr.cert.validity, ctxnow(ctx))) {
			lasterr = "trust anchor " + tr.cert.subject.tostring() + ": expired or not yet valid";
			continue;
		}
		if(--ctx.work < 0)
			return (0, "certificate path: too many signatures to check");
		(ok, err) := verify_issued(n.s, tr.cert);
		if(ok) {
			# n's revocation, by the CRLs of the issuer just found
			# (the leaf's was asked before any issuer was known, of
			# CRLs that were all roots')
			(tx, nil) := certinfo(tr.cert, tr.signed.tobe_signed);
			(revoked, reason) := check_revoked(n.c, tr.cert, tx, ctx);
			if(revoked)
				return (0, reason);
			(revoked, reason) = check_revoked(tr.cert, nil, nil, ctx);
			if(revoked)
				err = reason;
			else
				err = check_path(tr, path, ctx);
			if(err == nil)
				return (1, "");
		}
		lasterr = "trust anchor " + tr.cert.subject.tostring() + ": " + err;
	}

	# a presented intermediate that issued n; backtrack across alternatives
	# (cross-signed intermediates present more than one candidate)
	for(p := pool; p != nil; p = tl p) {
		cand := hd p;
		if(onpath(path, cand) || !cand.c.subject.equal(n.c.issuer))
			continue;
		err := check_ca(cand, depth, ctx);
		if(err == nil) {
			if(--ctx.work < 0)
				return (0, "certificate path: too many signatures to check");
			(ok, e) := verify_issued(n.s, cand.c);
			if(!ok)
				err = e;
		}
		if(err == nil) {
			# cand's own revocation is asked when its issuer is found
			(cx, nil) := nodeinfo(cand);
			(revoked, reason) := check_revoked(n.c, cand.c, cx, ctx);
			if(revoked)
				err = reason;
		}
		if(err == nil) {
			(ok, e) := findpath(cand, pool, depth+1, cand :: path, ctx);
			if(ok)
				return (1, "");
			err = e;
		}
		lasterr = cand.c.subject.tostring() + ": " + err;
	}
	return (0, lasterr);
}

# n is itself in the trust store (the server sent the root, or is one)
is_anchor(n: ref Node, ctx: ref VCtx): int
{
	for(t := ctxroots(ctx); t != nil; t = tl t)
		if(bytesequal((hd t).signed.tobe_signed, n.s.tobe_signed))
			return 1;
	return 0;
}

onpath(path: list of ref Node, n: ref Node): int
{
	for(; path != nil; path = tl path)
		if(bytesequal((hd path).s.tobe_signed, n.s.tobe_signed))
			return 1;
	return 0;
}

seen(l: list of ref Node, der: array of byte): int
{
	for(; l != nil; l = tl l)
		if(bytesequal((hd l).der, der))
			return 1;
	return 0;
}

bytesequal(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

# May n issue certificates at this depth? nil if so, else why not.
check_ca(n: ref Node, depth: int, ctx: ref VCtx): string
{
	if(!validat(n.c.validity, ctxnow(ctx)))
		return "issuer certificate expired or not yet valid";
	(x, xerr) := nodeinfo(n);
	if(xerr != nil)
		return xerr;
	if(x.ku && !(x.usage & KeyUsage_KeyCertSign))
		return "issuer keyUsage lacks keyCertSign";
	if(!x.bc || !x.ca)
		return "issuer is not a CA (basicConstraints)";
	if(x.pathlen >= 0 && depth > x.pathlen)
		return "issuer pathLenConstraint exceeded";
	return nil;
}

OID_BASICCONSTRAINTS := array [] of {2,5,29,19};
OID_CRLNUMBER := array [] of {2,5,29,20};
OID_AUTHKEYID := array [] of {2,5,29,35};
OID_KEYUSAGE := array [] of {2,5,29,15};
OID_SUBJECTALTNAME := array [] of {2,5,29,17};
OID_NAMECONSTRAINTS := array [] of {2,5,29,30};
OID_EXTKEYUSAGE := array [] of {2,5,29,37};
OID_ANYEXTKEYUSAGE := array [] of {2,5,29,37,0};
OID_SERVERAUTH := array [] of {1,3,6,1,5,5,7,3,1};
OID_CLIENTAUTH := array [] of {1,3,6,1,5,5,7,3,2};
OID_CERTPOLICIES := array [] of {2,5,29,32};
OID_POLICYMAPPINGS := array [] of {2,5,29,33};
OID_POLICYCONSTRAINTS := array [] of {2,5,29,36};
OID_INHIBITANYPOLICY := array [] of {2,5,29,54};
OID_ANYPOLICY := array [] of {2,5,29,32,0};
OID_COMMONNAME := array [] of {2,5,4,3};
OID_EMAILADDRESS := array [] of {1,2,840,113549,1,9,1};

oideq(o: ref Oid, nums: array of int): int
{
	if(o == nil || len o.nums != len nums)
		return 0;
	for(i := 0; i < len nums; i++)
		if(o.nums[i] != nums[i])
			return 0;
	return 1;
}

# What a certificate's extensions say, or why the certificate cannot
# be used (RFC 5280 4.2).  An extension is here either read and acted
# on, or, if it is critical, a reason to refuse: "MUST reject the
# certificate if it encounters a critical extension it does not
# recognize or a critical extension that contains information that it
# cannot process".  Before, only basicConstraints and keyUsage were
# looked at, and those of issuers alone: a CA held to some names by a
# critical nameConstraints issued for any name, and a critical
# extension nobody had heard of changed nothing.
#
# Read: basicConstraints, keyUsage, subjectAltName, nameConstraints,
# and policyConstraints for the one thing in it that can fail a path
# here (see check_path).  Checked for form and otherwise the caller's:
# extendedKeyUsage (the purpose is the application's to ask: TLS does),
# certificatePolicies, policyMappings, inhibitAnyPolicy (see check_path).
# Everything else is refused if critical: among them
# cRLDistributionPoints, which critical says to fetch a CRL this does
# not fetch, and the key identifiers and authorityInfoAccess, which
# 4.2.1 says are never critical.
certinfo(c: ref Certificate, tbs: array of byte): (ref Xinfo, string)
{
	x := ref Xinfo(0, 0, -1, 0, 0, 0, nil, nil, -1, nil, 0, nil);
	if(len c.exts > MAXEXTS)
		return (nil, "too many extensions");
	for(l := c.exts; l != nil; l = tl l) {
		e := hd l;
		# 4.2: "A certificate MUST NOT include more than one instance
		# of a particular extension" (of two basicConstraints the
		# last won, of two subjectAltNames either would do)
		for(m := tl l; m != nil; m = tl m)
			if(oid_cmp(e.oid, (hd m).oid))
				return (nil, "extension " + e.oid.tostring() + " twice");
		ok := 1;
		if(oideq(e.oid, OID_BASICCONSTRAINTS)) {
			x.bc = 1;
			(ok, x.ca, x.pathlen) = parse_basicconstraints(e.value);
			if(!ok)
				return (nil, "bad basicConstraints");
		} else if(oideq(e.oid, OID_KEYUSAGE)) {
			x.ku = 1;
			(ok, x.usage) = parse_keyusage(e.value);
			if(!ok)
				return (nil, "bad keyUsage");
		} else if(oideq(e.oid, OID_SUBJECTALTNAME)) {
			x.san = 1;
			(ok, x.names) = parse_gnames(e.value, 0);
			# 4.2.1.6: at least one entry
			if(!ok || x.names == nil)
				return (nil, "bad subjectAltName");
		} else if(oideq(e.oid, OID_NAMECONSTRAINTS)) {
			(ok, x.nc) = parse_nameconstraints(e.value);
			if(!ok)
				return (nil, "bad nameConstraints");
		} else if(oideq(e.oid, OID_EXTKEYUSAGE)) {
			x.eku = 1;
			(ok, x.purposes) = oidseq(e.value, 0);
			if(!ok)
				return (nil, "bad extendedKeyUsage");
		} else if(oideq(e.oid, OID_CERTPOLICIES)) {
			(ok, nil) = oidseq(e.value, 1);
			if(!ok)
				return (nil, "bad certificatePolicies");
		} else if(oideq(e.oid, OID_POLICYMAPPINGS)) {
			if(!policymappings(e.value))
				return (nil, "bad policyMappings");
		} else if(oideq(e.oid, OID_POLICYCONSTRAINTS)) {
			(ok, x.explicit) = parse_policyconstraints(e.value);
			if(!ok)
				return (nil, "bad policyConstraints");
		} else if(oideq(e.oid, OID_INHIBITANYPOLICY)) {
			(ierr, ie) := asn1->decode(e.value);
			skip := -1;
			if(ierr == "" && ie != nil)
				(ok, skip) = ie.is_int();
			if(ierr != "" || !ok || skip < 0 || ie.tag.num != INTEGER)
				return (nil, "bad inhibitAnyPolicy");
		} else if(e.critical)
			return (nil, "unrecognized critical extension " + e.oid.tostring());
	}
	ok: int;
	(ok, x.subject) = tbssubject(tbs);
	if(!ok)
		return (nil, "bad subject");
	return (x, nil);
}

# BasicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE, pathLenConstraint INTEGER OPTIONAL }
# returns (ok, ca, pathlen or -1)
parse_basicconstraints(der: array of byte): (int, int, int)
{
	(err, e) := asn1->decode(der);
	if(err != "" || e == nil)
		return (0, 0, -1);
	(ok, el) := e.is_seq();
	if(!ok || len el > 2)
		return (0, 0, -1);
	ca := 0;
	pathlen := -1;
	if(el != nil && (hd el).tag.class == Universal && (hd el).tag.num == BOOLEAN) {
		(ok, ca) = derbool(hd el);
		if(!ok)
			return (0, 0, -1);
		el = tl el;
	}
	if(el != nil) {
		if((hd el).tag.class != Universal || (hd el).tag.num != INTEGER || tl el != nil)
			return (0, 0, -1);
		(ok, pathlen) = (hd el).is_int();
		if(!ok || pathlen < 0)
			return (0, 0, -1);
	}
	return (1, ca, pathlen);
}

# KeyUsage ::= BIT STRING, bit 0 the most significant of the first byte
# (RFC 5280 4.2.1.3).  returns (ok, the bits as KeyUsage_*)
parse_keyusage(der: array of byte): (int, int)
{
	(err, e) := asn1->decode(der);
	if(err != "" || e == nil)
		return (0, 0);
	(ok, nil, bits) := e.is_bitstring();
	if(!ok)
		return (0, 0);
	usage := 0;
	for(i := 0; i < 9 && i/8 < len bits; i++)
		if(int bits[i/8] & (16r80 >> (i%8)))
			usage |= 1 << i;
	# "at least one of the bits MUST be set to 1"
	if(usage == 0)
		return (0, 0);
	return (1, usage);
}

# A SEQUENCE SIZE (1..MAX) OF OBJECT IDENTIFIER (extendedKeyUsage), or
# of SEQUENCE { OBJECT IDENTIFIER, ... } (certificatePolicies, whose
# policies may each appear once: 4.2.1.4)
oidseq(der: array of byte, inseq: int): (int, list of ref Oid)
{
	(err, e) := asn1->decode(der);
	if(err != "" || e == nil)
		return (0, nil);
	(ok, el) := e.is_seq();
	if(!ok || el == nil || len el > 256)
		return (0, nil);
	had: list of ref Oid;
	for(; el != nil; el = tl el) {
		o := hd el;
		if(inseq) {
			pl: list of ref Elem;
			(ok, pl) = o.is_seq();
			if(!ok || pl == nil || len pl > 2)
				return (0, nil);
			if(tl pl != nil) {
				(ok, nil) = (hd tl pl).is_seq();	# policyQualifiers
				if(!ok)
					return (0, nil);
			}
			o = hd pl;
		}
		oid: ref Oid;
		(ok, oid) = o.is_oid();
		if(!ok)
			return (0, nil);
		if(inseq)
			for(h := had; h != nil; h = tl h)
				if(oid_cmp(hd h, oid))
					return (0, nil);
		had = oid :: had;
	}
	return (1, had);
}

# PolicyMappings ::= SEQUENCE SIZE (1..MAX) OF SEQUENCE {
#	issuerDomainPolicy, subjectDomainPolicy OBJECT IDENTIFIER }
# neither of them anyPolicy (4.2.1.5, 6.1.4 (a))
policymappings(der: array of byte): int
{
	(err, e) := asn1->decode(der);
	if(err != "" || e == nil)
		return 0;
	(ok, el) := e.is_seq();
	if(!ok || el == nil)
		return 0;
	for(; el != nil; el = tl el) {
		pl: list of ref Elem;
		(ok, pl) = (hd el).is_seq();
		if(!ok || len pl != 2)
			return 0;
		for(; pl != nil; pl = tl pl) {
			oid: ref Oid;
			(ok, oid) = (hd pl).is_oid();
			if(!ok || oideq(oid, OID_ANYPOLICY))
				return 0;
		}
	}
	return 1;
}

# PolicyConstraints ::= SEQUENCE {
#	requireExplicitPolicy [0] INTEGER OPTIONAL,
#	inhibitPolicyMapping  [1] INTEGER OPTIONAL }
# not empty (4.2.1.11).  returns (ok, requireExplicitPolicy or -1)
parse_policyconstraints(der: array of byte): (int, int)
{
	(err, e) := asn1->decode(der);
	if(err != "" || e == nil)
		return (0, -1);
	(ok, el) := e.is_seq();
	if(!ok || el == nil || len el > 2)
		return (0, -1);
	explicit := -1;
	last := -1;
	for(; el != nil; el = tl el) {
		f := hd el;
		if(f.tag.class != Context || f.tag.num <= last || f.tag.num > 1)
			return (0, -1);
		last = f.tag.num;
		v: int;
		(ok, v) = ctxint(f);
		if(!ok)
			return (0, -1);
		if(f.tag.num == 0)
			explicit = v;
	}
	return (1, explicit);
}

# an INTEGER under an implicit context tag, not negative; one too
# large for an int is the largest
ctxint(e: ref Elem): (int, int)
{
	pick v := e.val {
	Octets =>
		b := v.bytes;
		if(len b == 0 || (int b[0] & 16r80))
			return (0, 0);
		n := 0;
		for(i := 0; i < len b; i++) {
			if(n > 16r7fffff)
				return (1, 16r7fffffff);
			n = (n << 8) | int b[i];
		}
		return (1, n);
	}
	return (0, 0);
}

# GeneralNames ::= SEQUENCE OF GeneralName, each under its context tag
# (RFC 5280 4.2.1.6); or one GeneralName, a subtree's base, when
# base is set, where an iPAddress is an address and its mask.
# returns (ok, names)
parse_gnames(der: array of byte, base: int): (int, list of ref GName)
{
	(err, e) := asn1->decode(der);
	if(err != "" || e == nil)
		return (0, nil);
	(ok, el) := e.is_seq();
	if(!ok)
		return (0, nil);
	l: list of ref GName;
	for(; el != nil; el = tl el) {
		g: ref GName;
		(ok, g) = parse_gn(hd el, base);
		if(!ok)
			return (0, nil);
		l = g :: l;
	}
	return (1, l);
}

parse_gn(e: ref Elem, base: int): (int, ref GName)
{
	if(e == nil || e.tag.class != Context || e.tag.num < 0 || e.tag.num > GNrid)
		return (0, nil);
	g := ref GName(e.tag.num, nil, nil, nil);
	pick v := e.val {
	Octets =>
		case g.form {
		GNrfc822 or GNdns or GNuri =>
			# IA5String: ASCII, and a name has no NUL in it
			if(!ia5name(v.bytes))
				return (0, nil);
			g.s = string v.bytes;
		GNip =>
			# 4 or 16 bytes; in a constraint, with a mask as long
			n := len v.bytes;
			if(base)
				n /= 2;
			if(n != 4 && n != 16 || base && len v.bytes != 2*n)
				return (0, nil);
			g.b = v.bytes;
		GNdir =>
			# [4] is explicit: a Name is a CHOICE
			(err, ne) := asn1->decode(v.bytes);
			if(err != "" || ne == nil)
				return (0, nil);
			ok: int;
			(ok, g.dn) = parse_dn(ne);
			if(!ok)
				return (0, nil);
		}
		return (1, g);
	}
	return (0, nil);
}

# [private]
# the bytes of an IA5String that is a name: ASCII, no NUL
ia5name(b: array of byte): int
{
	for(i := 0; i < len b; i++)
		if(b[i] == byte 0 || int b[i] >= 16r80)
			return 0;
	return 1;
}

# A Name with each value's string type kept, for the name constraints
parse_dn(e: ref Elem): (int, list of list of ref Av)
{
	(ok, el) := e.is_seq();
	if(!ok)
		return (0, nil);
	rdns: list of list of ref Av;
	for(; el != nil; el = tl el) {
		sl: list of ref Elem;
		(ok, sl) = (hd el).is_set();
		if(!ok || sl == nil)
			return (0, nil);
		avs: list of ref Av;
		for(; sl != nil; sl = tl sl) {
			al: list of ref Elem;
			(ok, al) = (hd sl).is_seq();
			if(!ok || len al != 2)
				return (0, nil);
			a := ref Av(nil, (hd tl al).tag.num, nil);
			(ok, a.oid) = (hd al).is_oid();
			if(!ok)
				return (0, nil);
			(ok, a.s) = (hd tl al).is_string();
			if(!ok || hasnul(a.s))
				return (0, nil);
			avs = a :: avs;
		}
		rdns = avs :: rdns;
	}
	r: list of list of ref Av;
	for(; rdns != nil; rdns = tl rdns)
		r = hd rdns :: r;
	return (1, r);
}

# The subject of a TBSCertificate that Certificate.decode has taken:
# the fifth field after the version, if there is one
tbssubject(tbs: array of byte): (int, list of list of ref Av)
{
	(err, e) := asn1->decode(tbs);
	if(err != "" || e == nil)
		return (0, nil);
	(ok, el) := e.is_seq();
	if(!ok || el == nil)
		return (0, nil);
	(hasver, nil) := is_context(hd el, 0);
	if(hasver)
		el = tl el;
	for(i := 0; i < 4 && el != nil; i++)
		el = tl el;
	if(el == nil)
		return (0, nil);
	return parse_dn(hd el);
}

# NameConstraints ::= SEQUENCE {
#	permittedSubtrees [0] GeneralSubtrees OPTIONAL,
#	excludedSubtrees  [1] GeneralSubtrees OPTIONAL }
# GeneralSubtree ::= SEQUENCE { base GeneralName,
#	minimum [0] INTEGER DEFAULT 0, maximum [1] INTEGER OPTIONAL }
# RFC 5280 4.2.1.10: one of the two at least; minimum is 0 and there is
# no maximum, and a certificate that says otherwise is refused.
parse_nameconstraints(der: array of byte): (int, ref NameCons)
{
	(err, e) := asn1->decode(der);
	if(err != "" || e == nil)
		return (0, nil);
	(ok, el) := e.is_seq();
	if(!ok || el == nil || len el > 2)
		return (0, nil);
	nc := ref NameCons(nil, nil);
	last := -1;
	for(; el != nil; el = tl el) {
		f := hd el;
		if(f.tag.class != Context || f.tag.num <= last || f.tag.num > 1)
			return (0, nil);
		last = f.tag.num;
		subs: list of ref GName;
		pick v := f.val {
		Octets =>
			# the tag is implicit: what it holds is the subtrees,
			# one after another
			(serr, sl) := asn1->decode_seq(v.bytes);
			if(serr != "" || sl == nil)
				return (0, nil);
			for(; sl != nil; sl = tl sl) {
				gl: list of ref Elem;
				(ok, gl) = (hd sl).is_seq();
				if(!ok || gl == nil)
					return (0, nil);
				g: ref GName;
				(ok, g) = parse_gn(hd gl, 1);
				if(!ok)
					return (0, nil);
				for(gl = tl gl; gl != nil; gl = tl gl) {
					# minimum, written out though it is the default
					m := hd gl;
					n: int;
					(ok, n) = ctxint(m);
					if(m.tag.class != Context || m.tag.num != 0 || !ok || n != 0 || tl gl != nil)
						return (0, nil);
				}
				subs = g :: subs;
			}
		* =>
			return (0, nil);
		}
		if(f.tag.num == 0)
			nc.permitted = subs;
		else
			nc.excluded = subs;
	}
	return (1, nc);
}

# The certificates from a trust anchor (tr, or nil when the first of
# path is itself the anchor) down to the leaf make a path whose
# signatures, dates and CA bits have been checked.  What is asked of
# the path as a whole (RFC 5280 6.1): nil if it stands, else why not.
check_path(tr: ref TrustedRoot, path: list of ref Node, ctx: ref VCtx): string
{
	n := len path;
	xs := array[n+1] of ref Xinfo;	# 0 the anchor (nil if path's first is)
	cs := array[n+1] of ref Certificate;
	i := 1;
	for(p := path; p != nil; p = tl p) {
		xerr: string;
		(xs[i], xerr) = nodeinfo(hd p);
		if(xerr != nil)
			return xerr;
		cs[i++] = (hd p).c;
	}
	if(tr != nil) {
		# The anchor's extensions, when it is a certificate, are held
		# to the same rule, and its name constraints kept (6.2: a
		# trust anchor's constraints may be applied; a root limited
		# to its own names is limited whether it or its issue is the
		# anchor)
		xerr: string;
		(xs[0], xerr) = certinfo(tr.cert, tr.signed.tobe_signed);
		if(xerr != nil)
			return "trust anchor: " + xerr;
		cs[0] = tr.cert;
	}

	# Name constraints, 6.1.3 (b) and (c), 6.1.4 (g): each CA's are
	# applied to every certificate below it.  Applying each CA's by
	# itself is the intersection of the permitted and the union of the
	# excluded.  A certificate issued to its own issuer's name is let
	# by, unless it is the last (6.1.3: "self-issued").
	for(i = 0; i < n; i++) {
		if(xs[i] == nil || xs[i].nc == nil)
			continue;
		for(j := i+1; j <= n; j++) {
			if(j < n && cs[j].subject.equal(cs[j].issuer))
				continue;
			err := nc_check(xs[i].nc, xs[j], j == n);
			if(err != nil)
				return err + " (nameConstraints of " + cs[i].subject.tostring() + ")";
		}
	}

	# What the path is for.  A certificate's extendedKeyUsage, where it
	# has one, names what its key may be used for, and in a CA's
	# certificate it is read as a limit on what the CA may issue for:
	# RFC 5280 4.2.1.12 speaks of end entities only, but the CA/Browser
	# Forum's Baseline Requirements (7.1.2.10.6: a CA certificate for
	# TLS has id-kp-serverAuth) and every browser's verifier hold a
	# chain to it, so that a CA made for signing email or code cannot
	# make a TLS server.  The anchor is not asked: its limits are the
	# store's to state.  anyExtendedKeyUsage allows any.  (Only the
	# leaf was asked, and by the TLS code, not here.)
	if(ctx.usage != Usage_Any) {
		want := OID_SERVERAUTH;
		what := "server authentication";
		if(ctx.usage == Usage_ClientAuth) {
			want = OID_CLIENTAUTH;
			what = "client authentication";
		}
		start := 1;
		if(tr == nil)
			start = 2;	# the first is the anchor itself
		for(i = start; i <= n; i++) {
			if(!xs[i].eku)
				continue;
			allowed := 0;
			for(pl := xs[i].purposes; pl != nil && !allowed; pl = tl pl)
				allowed = oideq(hd pl, want) || oideq(hd pl, OID_ANYEXTKEYUSAGE);
			if(!allowed) {
				if(i == n)
					return "certificate is not for " + what + " (extendedKeyUsage): " + cs[i].subject.tostring();
				return "CA certificate is not for " + what + " (extendedKeyUsage): " + cs[i].subject.tostring();
			}
		}
	}

	# Policies.  Nothing here names a policy it wants (the initial
	# policy set is anyPolicy, and no explicit policy is asked for), so
	# by 6.1.5 (g) a path stands if explicit_policy is still above 0
	# at its end, whatever its policy tree: certificatePolicies,
	# policyMappings and inhibitAnyPolicy shape only the tree.  What
	# can bring explicit_policy to 0 is a policyConstraints with
	# requireExplicitPolicy (6.1.4 (i), 6.1.5 (b)); the path then
	# stands only if the tree is not empty, which is not worked out
	# here: such a path is refused.
	explicit := n + 1;
	if(tr == nil)
		explicit = n;	# the anchor is no part of the path
	first := 1;
	if(tr == nil)
		first = 2;
	for(i = first; i <= n; i++) {
		if(explicit == 0)
			return "the path requires an explicit certificate policy (policyConstraints), which is not evaluated";
		if(i < n) {
			if(explicit > 0 && !cs[i].subject.equal(cs[i].issuer))
				explicit--;
			if(xs[i].explicit >= 0 && xs[i].explicit < explicit)
				explicit = xs[i].explicit;
		} else {
			if(explicit > 0)
				explicit--;
			if(xs[i].explicit == 0)
				explicit = 0;
		}
	}
	if(explicit == 0 && n >= first)
		return "the path requires an explicit certificate policy (policyConstraints), which is not evaluated";
	return nil;
}

# The names of a certificate against a CA's name constraints: nil if
# they are allowed.  The subject (when not empty) is a directoryName;
# the subjectAltName's entries are what they are; and, with no
# subjectAltName, an emailAddress in the subject is an rfc822Name
# (4.2.1.10) and, in the last certificate, a commonName is a dNSName,
# since that is what a TLS client reads it as when there is no
# subjectAltName.
nc_check(nc: ref NameCons, x: ref Xinfo, last: int): string
{
	names := x.names;
	if(x.subject != nil)
		names = ref GName(GNdir, nil, nil, x.subject) :: names;
	if(!x.san)
		for(rd := x.subject; rd != nil; rd = tl rd)
			for(a := hd rd; a != nil; a = tl a) {
				if(oideq((hd a).oid, OID_EMAILADDRESS))
					names = ref GName(GNrfc822, (hd a).s, nil, nil) :: names;
				if(last && oideq((hd a).oid, OID_COMMONNAME) && hostlike((hd a).s))
					names = ref GName(GNdns, (hd a).s, nil, nil) :: names;
			}
	for(; names != nil; names = tl names) {
		g := hd names;
		for(l := nc.excluded; l != nil; l = tl l)
			if((hd l).form == g.form) {
				r := gn_within(hd l, g, 1);
				if(r < 0)
					return "a name constraint on " + gn_form(g.form) + " names is not one this verifier applies";
				if(r)
					return gn_text(g) + " is in an excluded subtree";
			}
		constrained := 0;
		within := 0;
		for(l = nc.permitted; l != nil; l = tl l)
			if((hd l).form == g.form) {
				constrained = 1;
				r := gn_within(hd l, g, 0);
				if(r < 0)
					return "a name constraint on " + gn_form(g.form) + " names is not one this verifier applies";
				if(r)
					within = 1;
			}
		if(constrained && !within)
			return gn_text(g) + " is not in a permitted subtree";
	}
	return nil;
}

# Is name g within the subtree c of its form?  1, 0, or -1 for a form
# not compared here: 4.2.1.10 has a critical constraint on such a form
# refuse a certificate that carries a name of it, and it is refused
# critical or not.  excl says the subtree is an excluded one: where it
# cannot be told whether a name is inside, it is, and where it is a
# permitted one, it is not.
gn_within(c, g: ref GName, excl: int): int
{
	case c.form {
	GNdns =>
		return dns_within(c.s, g.s, excl);
	GNip =>
		if(len c.b != 2*len g.b)
			return 0;	# the other family
		n := len g.b;
		for(i := 0; i < n; i++)
			if((g.b[i] & c.b[n+i]) != (c.b[i] & c.b[n+i]))
				return 0;
		return 1;
	GNdir =>
		return dn_within(c.dn, g.dn, excl);
	}
	return -1;
}

# RFC 5280 4.2.1.10: "Any DNS name that can be constructed by simply
# adding zero or more labels to the left-hand side of the name
# satisfies the name constraint."  A constraint that begins with a dot
# is taken as others take it, for names below it only.  A name whose
# first label is * stands for every name with one label there (as TLS
# reads it): it is within a permitted subtree if they all are, and
# within an excluded one if any of them is.
dns_within(c, name: string, excl: int): int
{
	c = dnscanon(c);
	name = dnscanon(name);
	if(len name < 2 || name[0:2] != "*.")
		return dns_below(c, name);
	rest := name[2:];
	if(dns_below(c, rest))
		return 1;
	if(c != nil && c[0] == '.')
		c = c[1:];
	if(!excl)
		return c == rest;
	return dns_below(rest, c);
}

dns_below(c, name: string): int
{
	if(c == nil)
		return 1;
	if(c[0] == '.')
		return len name > len c && name[len name - len c:] == c;
	if(name == c)
		return 1;
	return len name > len c + 1 && name[len name - len c - 1:] == "." + c;
}

# lower case (names in certificates are ASCII) and no final dot
dnscanon(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		ch := s[i];
		if(ch >= 'A' && ch <= 'Z')
			ch += 'a' - 'A';
		r[len r] = ch;
	}
	if(len r > 1 && r[len r - 1] == '.')
		r = r[0:len r - 1];
	return r;
}

# a commonName that a TLS client could take for a host's name
hostlike(s: string): int
{
	if(s == nil)
		return 0;
	for(i := 0; i < len s; i++) {
		ch := s[i];
		if(!(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9'
		   || ch == '-' || ch == '.' || ch == '*' || ch == '_'))
			return 0;
	}
	return 1;
}

# A directoryName is within a subtree when the subtree's name is the
# beginning of it, RDN for RDN (RFC 5280 7.1).
dn_within(c, name: list of list of ref Av, excl: int): int
{
	for(; c != nil; c = tl c) {
		if(name == nil)
			return 0;
		if(!rdn_equal(hd c, hd name, excl))
			return 0;
		name = tl name;
	}
	return 1;
}

rdn_equal(a, b: list of ref Av, excl: int): int
{
	if(len a != len b)
		return 0;
	for(; a != nil; a = tl a) {
		found := 0;
		for(l := b; l != nil && !found; l = tl l)
			if(oid_cmp((hd a).oid, (hd l).oid) && av_equal(hd a, hd l, excl))
				found = 1;
		if(!found)
			return 0;
	}
	return 1;
}

# Two attribute values, by RFC 5280 7.1's rules as far as they can be
# kept here: letters' case and the amount of white space do not count.
# That is the whole of the rule for ASCII, in any string type (asn1
# gives each as its text: a BMPString's ASCII is a PrintableString's).
# Beyond ASCII the rule (RFC 4518) wants Unicode's tables: such values
# are equal for an excluded subtree and unequal for a permitted one
# unless they are the same text, so that what cannot be compared is
# never a way through.
av_equal(a, b: ref Av, excl: int): int
{
	pa := av_plain(a);
	pb := av_plain(b);
	if(pa == 2 && pb == 2)
		return av_canon(a.s) == av_canon(b.s);
	if(excl)
		return 1;
	return pa && pb && av_canon(a.s) == av_canon(b.s);
}

# 2: ASCII; 1: text beyond ASCII; 0: not comparable (control
# characters, or TeletexString beyond ASCII, whose bytes are read as
# Latin-1 and may have been meant as T.61)
av_plain(a: ref Av): int
{
	r := 2;
	for(i := 0; i < len a.s; i++) {
		ch := a.s[i];
		if(ch < 16r20 || ch == 16r7f || ch == 16rfffd)
			return 0;
		if(ch > 16r7f) {
			if(a.kind == ASN1->TeletexString)
				return 0;
			r = 1;
		}
	}
	return r;
}

av_canon(s: string): string
{
	r := "";
	sp := 0;
	for(i := 0; i < len s; i++) {
		ch := s[i];
		if(ch == ' ') {
			sp = 1;
			continue;
		}
		if(sp && r != nil)
			r[len r] = ' ';
		sp = 0;
		if(ch >= 'A' && ch <= 'Z')
			ch += 'a' - 'A';
		r[len r] = ch;
	}
	return r;
}

gn_form(form: int): string
{
	case form {
	GNother =>	return "otherName";
	GNrfc822 =>	return "rfc822Name";
	GNdns =>	return "dNSName";
	GNx400 =>	return "x400Address";
	GNdir =>	return "directoryName";
	GNedi =>	return "ediPartyName";
	GNuri =>	return "uniformResourceIdentifier";
	GNip =>		return "iPAddress";
	GNrid =>	return "registeredID";
	}
	return "unknown";
}

# a name for an error message: it is a certificate's, and may hold anything
printable(s: string): string
{
	r := "";
	for(i := 0; i < len s && i < 128; i++) {
		ch := s[i];
		if(ch < 16r20 || ch == 16r7f || ch == 16rfffd)
			ch = '?';
		r[len r] = ch;
	}
	return r;
}

gn_text(g: ref GName): string
{
	case g.form {
	GNrfc822 or GNdns or GNuri =>
		return gn_form(g.form) + " " + printable(g.s);
	GNip =>
		s := "";
		for(i := 0; i < len g.b; i++) {
			if(i > 0)
				s += ".";
			s += string int g.b[i];
		}
		return "iPAddress " + s;
	GNdir =>
		s := "";
		for(r := g.dn; r != nil; r = tl r)
			for(a := hd r; a != nil; a = tl a)
				s += "/" + (hd a).oid.tostring() + "=" + printable((hd a).s);
		return "directoryName " + s;
	}
	return "a name of form " + gn_form(g.form);
}

# Verify that child was signed by the key in issuer. Fails closed.
# The issuer's key is one getPublicKey takes: for RSA, at least 2048
# bits with an odd exponent of 3 or more (PKCS->decode_rsapubkey),
# whether the issuer is an intermediate or a root of the store.
verify_issued(child: ref Signed, issuer: ref Certificate): (int, string)
{
	(err, nil, pk) := issuer.subject_pkinfo.getPublicKey();
	if(err != "")
		return (0, "issuer key: " + err);
	return sigverify(child, pk);
}

## Certificate Revocation List (CRL)
##
## A CRL is a time-stampted list identifying revoked certificates. It is signed by a 
## Certificate Authority (CA) and made freely available in a public repository.
##
## Each revoked certificate is identified in a CRL by its certificate serial number. 
## When a certificate-using system uses a certificate (e.g., for verifying a remote 
## user's digital signature), that system not only checks the certificate signature 
## and validity but also acquires a suitably-recent CRL and checks that the certificate 
## serial number is not on that CRL. The meaning of "suitably-recent" may vary with
## local policy, but it usually means the most recently-issued CRL. A CA issues a new 
## CRL on a regular periodic basis (e.g., hourly, daily, or weekly). Entries are added 
## on CRLs as revocations occur, and an entry may be removed when the certificate 
## expiration date is reached.

# [public]

CRL.decode(a: array of byte): (string, ref CRL)
{
	{
		return crldecode(a);
	} exception e {
	"*" =>
		return ("CRL: internal error: " + e, nil);
	}
}

crldecode(a: array of byte): (string, ref CRL)
{
parse:
	# break on error
	for(;;) {
		(err, all) := asn1->decode(a);
		if(err != "" || all == nil)
			break parse;
		c := ref CRL;
		# CRL must be a ASN1 sequence
		(ok, el) := all.is_seq();
		if(!ok || len el < 3)
			break parse;
		(fok, f) := derfields(a, 8);
		if(!fok || len f != len el)
			break parse;
		fi := 0;
		# TBSCertList (RFC 5280 §5.1): version is a plain INTEGER, there
		# only in v2 (1), not [0] as in a certificate.  (It was read as
		# a certificate's and the list never advanced past it, so no
		# CRL OpenSSL makes decoded.)
		c.version = 0;
		if((hd el).tag.class == Universal && (hd el).tag.num == INTEGER) {
			v: int;
			(ok, v) = (hd el).is_int();
			if(!ok || v != 1)
				break parse;
			c.version = v;
			el = tl el;
			fi++;
			if(len el < 3)
				break parse;
		}
		# signature algorithm
		(ok, c.sig) = decode_algid(f[fi]);
		if(!ok)
			break parse;
		el = tl el;
		# issuer: who issues the CRL
		(ok, c.issuer) = parse_name(hd el);
		if(!ok)
			break parse;
		el = tl el;
		# this update
		(ok, c.this_update) = parse_time(hd el, 0);
		if(!ok)
			break parse;
		el = tl el;
		# OPTIONAL, must be in order
		# next_update
		if(el != nil && (hd el).tag.class == Universal
		&& ((hd el).tag.num == UTCTime || (hd el).tag.num == GeneralizedTime)) {
			(ok, c.next_update) = parse_time(hd el, 0);
			if(!ok)
				break parse;
			el = tl el;
		}
		# revoked certificates: OPTIONAL, a SEQUENCE (absent when none is)
		if(el != nil && (hd el).tag.class == Universal && (hd el).tag.num == SEQUENCE) {
			(ok, c.revoked_certs) = parse_revoked_certs(hd el);
			if(!ok)
				break parse;
			el = tl el;
		}
		# crlExtensions [0] EXPLICIT, v2 only
		if(el != nil) {
			(isctx, inner) := is_context(hd el, 0);
			if(!isctx || c.version != 1)
				break parse;
			(ok, c.exts) = parse_extlist(inner);
			if(!ok)
				break parse;
			el = tl el;
			# a critical extension we do not know means a CRL we cannot
			# read as its issuer meant (a delta CRL, a partial scope)
			for(x := c.exts; x != nil; x = tl x)
				if((hd x).critical && !oideq((hd x).oid, OID_CRLNUMBER) && !oideq((hd x).oid, OID_AUTHKEYID))
					return ("CRL: unrecognized critical extension " + (hd x).oid.tostring(), nil);
		}
		# the same of an entry's (RFC 5280 5.3): certificateIssuer,
		# critical, says the entry is another issuer's certificate
		for(rc := c.revoked_certs; rc != nil; rc = tl rc)
			for(x := (hd rc).exts; x != nil; x = tl x)
				if((hd x).critical)
					return ("CRL: unrecognized critical entry extension " + (hd x).oid.tostring(), nil);
		# must be no more left
		if(el != nil)
			break parse;
		return ("", c);
	}
	return ("CRL: syntax error", nil);
}


# [public]

CRL.tostring(c: self ref CRL): string
{
	s := "Certificate Revocation List (CRL)";
	s += "\nVersion: " + string c.version;
	s += "\nSignature: " + c.sig.tostring();
	s += "\nIssuer: " + c.issuer.tostring();
	s += "\nThis Update: " + timetext(c.this_update, 1);
	s += "\nNext Update: " + timetext(c.next_update, 1);
	s += "\nRevoked Certificates: ";
	rcs := c.revoked_certs;
	while(rcs != nil) {
		s += "\t" + (hd rcs).tostring();
		rcs = tl rcs;
	}
	s += "\nExtensions: ";
	exts := c.exts;
	while(exts != nil) {
		s += "\t" + (hd exts).tostring();
		exts = tl exts;
	}
	return s;
}

# [public]

CRL.is_revoked(c: self ref CRL, sn: ref IPint): int
{
	es := c.revoked_certs;
	while(es != nil) {
		if(sn.eq((hd es).user_cert))
			return 1;
		es = tl es;
	}
	return 0;
}

# [public]

RevokedCert.tostring(rc: self ref RevokedCert): string
{
	s := "Revoked Certificate";
	if(rc.user_cert == nil)
		return s + " [Bad Format]\n";
	s += "\nSerial Number: " + rc.user_cert.iptostr(10);
	if(rc.revoc_date != big 0)
		s += "\nRevocation Date: " + timetext(rc.revoc_date, 1);
	if(rc.exts != nil) {
		exts := rc.exts;
		while(exts != nil) {
			s += "\t" + (hd exts).tostring();
			exts = tl exts;
		}
	}
	return s;		
}


# [private]

parse_revoked_certs(e: ref Elem): (int, list of ref RevokedCert)
{
	lc: list of ref RevokedCert;
parse:
	for(;;) {
		(ok, el) := e.is_seq();
		if(!ok)
			break parse;
		while(el != nil) {
			c: ref RevokedCert;
			(ok, c) = parse_revoked(hd el);
			if(!ok)
				break parse;
			lc = c :: lc;	
			el = tl el;
		}

		return (1, lc);
	}
	
	return (0, nil);
}


# [private]

parse_revoked(e: ref Elem): (int, ref RevokedCert)
{
parse:
	for(;;) {
		c := ref RevokedCert;	# (it was declared nil and written through: every entry raised)
		(ok, el) := e.is_seq();
		if(!ok || len el < 2)
			break parse;
		uc: array of byte;
		(ok, uc) = (hd el).is_bigint();
		if(!ok || len uc == 0)
			break parse;
		c.user_cert = derint(uc);
		el = tl el;
		(ok, c.revoc_date) = parse_time(hd el, 0);
		if(!ok)
			break parse;
		el = tl el;
		if(el != nil) {
			(ok, c.exts) = parse_extlist(hd el);
			if(!ok)
				break parse;
		}
		return (1, c);
	}
	return (0, nil);
}


## The extensions field allows addition of new fields to the structure 
## without modification to the ASN.1 definition. An extension field 
## consists of an extension identifier, a criticality flag, and a 
## canonical encoding of a data value of an ASN.1 type associated with 
## the identified extension. For those extensions where ordering of 
## individual extensions within the SEQUENCE is significant, the  
## specification of those individual extensions shall include the rules 
## for the significance of the ordering. When an implementation 
## processing a certificate does not recognize an extension, if the 
## criticality flag is FALSE, it may ignore that extension. If the 
## criticality flag is TRUE, unrecognized extensions shall cause the 
## structure to be considered invalid, i.e. in a certificate, an 
## unrecognized critical extension would cause validation of a signature 
## using that certificate to fail.


# [public]

parse_exts(exts: list of ref Extension): (string, list of ref ExtClass)
{
	ets: list of ref ExtClass;
	l := exts;
	while(l != nil) {
		ext := hd l;
		(err, et) := ExtClass.decode(ext);
		if(err != "")
			return (err, nil);
		# Unknown non-critical extensions decode to nil — skip them
		# (RFC 5280 §4.2); unknown critical ones return err above.
		if(et != nil)
			ets = et :: ets;
		l = tl l;
	}
	lseq: list of ref ExtClass;
	while(ets != nil) {
		lseq = (hd ets) :: lseq;
		ets = tl ets;
	}
	return ("", lseq);
}

# [public]

ExtClass.decode(ext: ref Extension): (string, ref ExtClass)
{
	# an extension's bytes are a certificate's: an error, never an
	# exception (TLS reads a server's subjectAltName through this)
	{
		return extdecode(ext);
	} exception e {
	"*" =>
		return ("extension: internal error: " + e, nil);
	}
}

extdecode(ext: ref Extension): (string, ref ExtClass)
{
	err: string;
	eclass: ref ExtClass;

	oid := asn1->oid_lookup(ext.oid, objIdTab);
	case oid {
	id_ce_authorityKeyIdentifier =>
		(err, eclass) = decode_authorityKeyIdentifier(ext);
		if(err == "" && ext.critical == 1)
			err = "authority key identifier: should be non-critical";
	id_ce_subjectKeyIdentifier =>
		(err, eclass) = decode_subjectKeyIdentifier(ext);
		if(err == "" && ext.critical != 0)
			err = "subject key identifier: should be non-critical";
	id_ce_basicConstraints =>
		(err, eclass) = decode_basicConstraints(ext);
	id_ce_keyUsage =>
		(err, eclass) = decode_keyUsage(ext);
	id_ce_subjectAltName =>
		n: list of ref GeneralName;
		(err, n) = decode_alias(ext);
		if(err == "")
			eclass = ref ExtClass.SubjectAltName(n);
	id_ce_reasonCode =>
		(err, eclass) = decode_reasonCode(ext);
		if(err == "" && ext.critical != 0)
			err = "crl reason: should be non-critical";
	* =>
		# An extension with no class here is nil and no error,
		# critical or not: what a critical extension means for a
		# certificate is the path's to say (certinfo, RFC 5280 4.2),
		# which reads more extensions than have a class.
		;
	}
	if(err != "")
		eclass = nil;
	return (err, eclass);
}

# [public]

ExtClass.tostring(et: self ref ExtClass): string
{
	s: string;

	pick t := et {
	AuthorityKeyIdentifier =>
		s = "Authority Key Identifier: ";
		s += "\n\tid = " + bastr(t.id);
		if(t.issuer != nil)
			s += "\n\tissuer = " + t.issuer.tostring();
		if(t.serial_number != nil)
			s += "\n\tserial_number = " + bastr(t.serial_number.iptobebytes());
	SubjectKeyIdentifier =>
		s = "Subject Key Identifier ";
		s += "\n\tid = " + bastr(t.id);
	BasicConstraints =>
		s = "Basic Constraints: ";
		s += "\n\tca = " + string t.ca;
		s += "\n\tpathlen = " + string t.pathlen;
	KeyUsage =>
		s = "Key Usage: ";
		s += sys->sprint("\n\tusage = 16r%x", t.usage);
	SubjectAltName =>
		s = "Subject Alt Name: ";
		al := t.alias;
		while(al != nil) {
			s += (hd al).tostring() + ",";
			al = tl al;
		}
	ReasonCode =>
		s = "Reason Code: ";
		s += "\n\tcode = " + string t.code;
	}

	return s;
}

# [private]

decode_authorityKeyIdentifier(ext: ref Extension): (string, ref ExtClass)
{
parse:
	for(;;) {
		(err, all) := asn1->decode(ext.value);
		if(err != "")
			break parse;
		(ok, el) := all.is_seq();
		if(!ok)
			break parse;
		ak := ref ExtClass.AuthorityKeyIdentifier;
		# AuthorityKeyIdentifier ::= SEQUENCE {
		#	keyIdentifier             [0] IMPLICIT OCTET STRING OPTIONAL,
		#	authorityCertIssuer       [1] IMPLICIT GeneralNames OPTIONAL,
		#	authorityCertSerialNumber [2] IMPLICIT INTEGER OPTIONAL }
		# each optional, and as a rule the key identifier alone (which
		# was "syntax error"; an empty SEQUENCE was "dereference of
		# nil").  The tags are implicit: the bytes are the values.
		if(el != nil && (hd el).tag.class == Context && (hd el).tag.num == 0) {
			pick v := (hd el).val {
			Octets =>
				ak.id = v.bytes;
			* =>
				break parse;
			}
			el = tl el;
		}
		if(el != nil && (hd el).tag.class == Context && (hd el).tag.num == 1) {
			pick v := (hd el).val {
			Octets =>
				(derr, gel) := asn1->decode_seq(v.bytes);
				if(derr != "" || gel == nil)
					break parse;
				(ok, ak.issuer) = parse_gname(hd gel);
				if(!ok)
					break parse;
			* =>
				break parse;
			}
			el = tl el;
		}
		if(el != nil && (hd el).tag.class == Context && (hd el).tag.num == 2) {
			pick v := (hd el).val {
			Octets =>
				if(len v.bytes == 0)
					break parse;
				ak.serial_number = IPint.bebytestoip(v.bytes);
			* =>
				break parse;
			}
			el = tl el;
		}
		if(el != nil)
			break parse;
		return ("", ak);
	}
	return ("syntax error", nil);	
}


# [private]

decode_subjectKeyIdentifier(ext: ref Extension): (string, ref ExtClass)
{
parse:
	for(;;) {
		(err, all) := asn1->decode(ext.value);
		if(err != "")
			break parse;
		(ok, id) := all.is_octetstring();
		if(!ok)
			break parse;
		return ("", ref ExtClass.SubjectKeyIdentifier(id));

	}
	return ("subject key identifier: syntax error", nil);
}


# [private]

decode_basicConstraints(ext: ref Extension): (string, ref ExtClass)
{
	# the path's own reading (it had a second one here, which gave a
	# depth and no cA: a leaf and a CA with pathLenConstraint 0 were
	# the same value)
	(ok, ca, pathlen) := parse_basicconstraints(ext.value);
	if(!ok)
		return ("basic constraints: syntax error", nil);
	return ("", ref ExtClass.BasicConstraints(ca, pathlen));
}

# [private]

decode_keyUsage(ext: ref Extension): (string, ref ExtClass)
{
parse:
	for(;;) {
		# the BIT STRING's bits as KeyUsage_* (it gave the extension's
		# DER, tag and length and all, as a number)
		(ok, usage) := parse_keyusage(ext.value);
		if(!ok)
			break parse;
		return ("", ref ExtClass.KeyUsage(usage));
	}
	return ("key usage: syntax error", nil);
}


# [private]

decode_alias(ext: ref Extension): (string, list of ref GeneralName)
{
parse:
	for(;;) {
		(err, all) := asn1->decode(ext.value);
		if(err != "")
			break parse;
		(ok, el) := all.is_seq();
		if(!ok)
			break parse;
		l_sa: list of ref GeneralName;
		while(el != nil) {
			gn: ref GeneralName;
			(ok, gn) = parse_gname(hd el);
			if(!ok)
				break parse;
			l_sa = gn :: l_sa;
			el = tl el;
		}
		# reverse order
		sa: list of ref GeneralName;
		while(l_sa != nil) {
			sa = (hd l_sa) :: sa;
			l_sa = tl l_sa;
		}
		return ("", sa);
	}
	return ("alias: syntax error", nil);
}


# [private]

decode_reasonCode(ext: ref Extension): (string, ref ExtClass)
{
parse:
	for(;;) {
		(err, all) := asn1->decode(ext.value);
		if(err != "")
			break parse;
		# CRLReason ::= ENUMERATED (RFC 5280 5.3.1), Reason_*; it was
		# read as a BIT STRING, which no reason code is
		if(all == nil || all.tag.class != Universal || all.tag.num != ASN1->ENUMERATED)
			break parse;
		code := -1;
		pick v := all.val {
		Int =>
			code = v.v;
		}
		if(code < 0 || code > 10 || code == 7)
			break parse;
		return ("", ref ExtClass.ReasonCode(code)); 
	}
	return ("crl reason: syntax error", nil);
}


# [public]

GeneralName.tostring(gn: self ref GeneralName): string
{
	s: string;

	pick g := gn {
	otherName => 
		s = "other name: " + g.str;
	rfc822Name =>
		s = "rfc822 name: " + g.str;
	dNSName =>
		s = "dns name: " + g.str;
	x400Address =>
		s = "x400 address: " + g.str;
	uniformResourceIdentifier =>
		s = "url: " + g.str;
	iPAddress =>
		s = "ip address: " + bastr(g.ip);
	registeredID =>
		s = "oid: " + g.oid.tostring();
	ediPartyName =>
		s = "edi party name: ";
		s += "\n\tname assigner is " + g.nameAssigner.tostring();
		s += "\n\tparty name is " + g.partyName.tostring();
	directoryName =>
		s = "directory name: " + g.dir.tostring();
	}
	return s;
}


# [private]

is_context(e: ref Elem, num: int): (int, ref Elem)
{
	if(e == nil)
		return (0, nil);
	if(e.tag.class == ASN1->Context && e.tag.num == num) {
		pick v := e.val {
		Octets =>
			(err, all) := asn1->decode(v.bytes);
			if(err == "")
				return (1, all);
		}
	}
	return (0, nil);
}



# [private]

parse_gname(e: ref Elem): (int, ref GeneralName)
{
parse:
	for(;;) {
		g: ref GeneralName;
		ok := 1;
		if(e == nil || e.tag.class != ASN1->Context)
			break parse;
		case e.tag.num {
		0 =>
			# otherName [0] IMPLICIT SEQUENCE { type-id OBJECT
			# IDENTIFIER, value [0] EXPLICIT ANY }: kept as its
			# type's OID.  (It was read as a string, which it never
			# is: a certificate with a UPN beside its DNS names had
			# no subjectAltName that could be read.)
			pick ev := e.val {
			Octets =>
				(derr, ol) := asn1->decode_seq(ev.bytes);
				if(derr != "" || len ol != 2)
					break parse;
				oid: ref Oid;
				(ok, oid) = (hd ol).is_oid();
				if(!ok)
					break parse;
				g = ref GeneralName.otherName(oid.tostring());
			* =>
				break parse;
			}
		1 =>
			# rfc822Name [1] IMPLICIT IA5String — raw bytes are the string content
			if(e.tag.class != ASN1->Context || e.tag.num != 1)
				break parse;
			pick ev := e.val {
			Octets =>
				if(!ia5name(ev.bytes))
					break parse;
				g = ref GeneralName.rfc822Name(string ev.bytes);
			* =>
				break parse;
			}
		2 =>
			# dNSName [2] IMPLICIT IA5String — raw bytes are the string content
			if(e.tag.class != ASN1->Context || e.tag.num != 2)
				break parse;
			pick ev := e.val {
			Octets =>
				if(!ia5name(ev.bytes))
					break parse;
				g = ref GeneralName.dNSName(string ev.bytes);
			* =>
				break parse;
			}
		3 =>
			(ok, e) = is_context(e, 3);
			if(!ok)
				break parse;
			str: string;
			(ok, str) = e.is_string();
			if(!ok || hasnul(str))
				break parse;
			g = ref GeneralName.x400Address(str);
		4 =>
			(ok, e) = is_context(e, 4);
			if(!ok)
				break parse;
			dir: ref Name;
			(ok, dir) = parse_name(e);
			if(!ok)
				break parse;
			g = ref GeneralName.directoryName(dir);
		5 =>
			(ok, e) = is_context(e, 5);
			if(!ok)
				break parse;
			el: list of ref Elem;
			(ok, el) = e.is_seq();
			if(!ok || len el < 1 || len el > 3)
				break parse;
			na, pn: ref Name;
			(ok, e) = is_context(hd el, 0);
			if(ok) {
				(ok, na) = parse_name(e);
				if(!ok)
					break parse;
				el = tl el;
			}
			if(el != nil) {
				(ok, e) = is_context(hd el, 1);
				if(!ok)
					break parse;
				(ok, pn) = parse_name(e);
				if(!ok)
					break parse;
			}
			g = ref GeneralName.ediPartyName(na, pn);
		6 =>
			# uniformResourceIdentifier [6] IMPLICIT IA5String — raw bytes are the string
			if(e.tag.class != ASN1->Context || e.tag.num != 6)
				break parse;
			pick ev := e.val {
			Octets =>
				if(!ia5name(ev.bytes))
					break parse;
				g = ref GeneralName.uniformResourceIdentifier(string ev.bytes);
			* =>
				break parse;
			}
		7 =>
			# iPAddress [7] IMPLICIT OCTET STRING — raw bytes are the IP address
			if(e.tag.class != ASN1->Context || e.tag.num != 7)
				break parse;
			pick ev := e.val {
			Octets =>
				g = ref GeneralName.iPAddress(ev.bytes);
			* =>
				break parse;
			}
		8 =>
			(ok, e) = is_context(e, 8);
			if(!ok)
				break parse;
			oid: ref Oid;
			(ok, oid) = e.is_oid();
			if(!ok)
				break parse;			
			g = ref GeneralName.registeredID(oid);
		* =>
			break parse;
		}
		return (1, g);
	}
	return (0, nil);
}



# [private]

oid_cmp(a, b: ref Oid): int
{
	na := len a.nums;
	nb := len b.nums;
	if(na != nb)
		return 0;
	for(i := 0; i < na; i++) {
		if(a.nums[i] != b.nums[i])
			return 0;
	}
	return 1;
}

# [private]
# decode two bytes into an integer [0-99]
# return -1 for an invalid encoding

get2(a: string, i: int): int
{
	a0 := int a[i];
	a1 := int a[i+1];
	if(a0 < '0' || a0 > '9' || a1 < '0' || a1 > '9')
        	return -1;    
	return (a0 - '0')*10 + a1 - '0';
}


# [private]

bastr(a: array of byte) : string
{
	ans := "";
	for(i := 0; i < len a; i++) {
		if(i < len a - 1 && i%10 == 0)
			ans += "\n\t\t";
		ans += sys->sprint("%2x ", int a[i]);
	}
	return ans;
}


# An RSA key a signature is worth checking with: a chain's keys may be
# anyone's, and one of 16384 bits with a 4096-bit exponent costs
# seconds a signature
rsasane(k: ref PKCS->RSAKey): string
{
	if(k == nil || k.modulus == nil || k.exponent == nil)
		return "RSA key missing";
	if(k.modulus.bits() < 2048)
		return "RSA key under 2048 bits";
	if(k.modulus.bits() > 8192)
		return "RSA key past 8192 bits";
	if(k.exponent.bits() > 32)
		return "RSA exponent past 32 bits";
	return nil;
}

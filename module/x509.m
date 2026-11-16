#
# X.509 v3 certificates and CRLs, read and verified (RFC 5280)
#
# The module decodes and verifies; it makes nothing.  (It had an
# encoder for every type and a Signed.sign, none of which had a
# caller or could have worked.)
#

X509: module {

	PATH: con "/dis/lib/crypt/x509.dis";

	init: fn(): string;

	## x509 (id_at) and x509 extention v3 (id_ce) Object Identifiers

	objIdTab			: array of ASN1->Oid;

	id_at,
	id_at_commonName,
	id_at_countryName,
	id_at_localityName,
	id_at_stateOrProvinceName,
	id_at_organizationName,
	id_at_organizationalUnitName,
	id_at_userPassword,
	id_at_userCertificate,
	id_at_cAcertificate,
	id_at_authorityRevocationList,
	id_at_certificateRevocationList,
	id_at_crossCertificatePair,
	id_at_supportedAlgorithms,
	id_at_deltaRevocationList,
	id_ce,
	id_ce_subjectDirectoryAttributes,
	id_ce_subjectKeyIdentifier,
	id_ce_keyUsage,
	id_ce_privateKeyUsage,
	id_ce_subjectAltName,
	id_ce_issuerAltName,
	id_ce_basicConstraints,
	id_ce_cRLNumber,
	id_ce_reasonCode,
	id_ce_instructionCode,
	id_ce_invalidityDate,
	id_ce_deltaCRLIndicator,
	id_ce_issuingDistributionPoint,
	id_ce_certificateIssuer,
	id_ce_nameConstraints,
	id_ce_cRLDistributionPoint,
	id_ce_certificatePolicies,
	id_ce_policyMapping,
	id_ce_authorityKeyIdentifier,
	id_ce_policyConstraints,
	id_mr,
	id_mr_certificateExactMatch,
 	id_mr_certificateMatch,
 	id_mr_certificatePairExactMatch,
 	id_mr_certificatePairMatch,
 	id_mr_certificateListExactMatch,
 	id_mr_certificateListMatch,
 	id_mr_algorithmidentifierMatch	: con iota;

	## Signed (as Public Key, CRL, Attribute Certificates and CertificationRequest)

	Signed: adt {
		tobe_signed		: array of byte;
  		alg			: ref AlgIdentifier;
  		signature		: array of byte; # BIT STRING, DER encoding
		
		decode: fn(a: array of byte): (string, ref Signed);
		# is the signature pk's, by the algorithm alg names?
		# RSA PKCS #1 v1.5 and ECDSA (P-256, P-384), each with
		# SHA-256, SHA-384 or SHA-512; anything else does not verify
		verify: fn(s: self ref Signed, pk: ref PublicKey): int;
		tostring: fn(s: self ref Signed): string;
	};

	## Certificate Path

	# Each returns (1, "") for a chain that verifies and (0, why) for one
	# that does not; none raises an exception, whatever the bytes.
	#
	# verify_certchain: a chain as a TLS peer presents it (the leaf
	# first, the rest in any order) against the roots in /lib/certs,
	# the CRLs in /lib/crls and the time in /dev/time.  The stores are
	# read at the first use and again whenever a file of theirs has
	# been added, removed or changed.
	#
	# usage is what the chain is for, Usage_ServerAuth or
	# Usage_ClientAuth: every certificate of the path below the trust
	# anchor that has an extendedKeyUsage must name it or
	# anyExtendedKeyUsage, the CAs as well as the leaf (CA/Browser
	# Forum Baseline Requirements 7.1.2.10.6, and what browsers apply:
	# a CA limited to signing email does not make TLS servers).
	# Usage_Any asks nothing.
	verify_certchain: fn(cs: list of array of byte, usage: int): (int, string);
	# The same against roots given, not /lib/certs: a chain against
	# the CAs a caller names (DER, each a CA certificate), with the
	# CRLs given (DER) and the time now (seconds since the epoch: a
	# confined caller has no /dev/time).  Neither store is read.
	# Every CRL given must be one the call can check, or the call
	# fails: signed by one of the roots, or by a CA certificate of the
	# chain, which then signs it with the key the path verifies (and
	# with cRLSign, if it has a keyUsage).
	verify_certchain_roots: fn(cs: list of array of byte, roots: list of array of byte,
		crls: list of array of byte, now: int, usage: int): (int, string);

	Usage_Any, Usage_ServerAuth, Usage_ClientAuth: con iota;

	## TBS (Public Key) Certificate

	Certificate: adt {
  		version			: int; # v1(0; default) or v2(1) or v3(2)
  		serial_number		: ref Keyring->IPint;
  		sig			: ref AlgIdentifier;
  		issuer			: ref Name;
  		validity		: ref Validity;
  		subject			: ref Name;
  		subject_pkinfo		: ref SubjectPKInfo;
					# OPTIONAL for v2 and v3; must be in order
  		issuer_uid		: array of byte; # v2
  		subject_uid		: array of byte; # v2 or v3
  		exts			: list of ref Extension; # v3

		# a is a TBSCertificate: Signed.decode's tobe_signed
		decode: fn(a: array of byte): (string, ref Certificate);
		tostring: fn(c: self ref Certificate): string;
		is_expired: fn(c: self ref Certificate, date: int): int;
	};

	AlgIdentifier: adt {
		oid			: ref ASN1->Oid;
		parameter		: array of byte;	# the parameters' DER; nil if absent

		tostring: fn(a: self ref AlgIdentifier): string;
	};

	Name: adt {
		rd_names		: list of ref RDName;

		equal: fn(a: self ref Name, b: ref Name): int;
		tostring: fn(n: self ref Name): string;
	};

	RDName: adt {
		avas			: list of ref AVA;

		equal: fn(a: self ref RDName, b: ref RDName): int;
		tostring: fn(r: self ref RDName): string;
	};

	AVA: adt {
		oid			: ref ASN1->Oid;
		value			: string;
		
		equal: fn(a: self ref AVA, b: ref AVA): int;
		tostring: fn(a: self ref AVA): string;
	};

	Validity: adt {
  		not_before		: big;	# seconds since the epoch, GMT
  		not_after		: big;

		tostring: fn(v: self ref Validity, format: string): string;
	};

	SubjectPKInfo: adt {
  		alg_id			: ref AlgIdentifier;
  		subject_pk		: array of byte; # BIT STRING

		# (error, the algorithm as PKCS->id_pkcs_rsaEncryption or
		# PKCS->id_ec_publicKey, the key)
		getPublicKey: fn(c: self ref SubjectPKInfo): (string, int, ref PublicKey);
		tostring: fn(c: self ref SubjectPKInfo): string;
	};

	Extension: adt{
  		oid			: ref ASN1->Oid;
  		critical		: int; # default false 
  		value			: array of byte;

		tostring: fn(e: self ref Extension): string;
	};

	PublicKey: adt {
		pick {
		RSA =>
			pk		: ref PKCS->RSAKey;
		EC =>
			# an uncompressed point on the curve the key's
			# parameters name: 65 bytes on P-256, 97 on P-384
			point		: array of byte;
		}
	};

	## Certificate Revocation List

	CRL: adt {
		version			: int; # OPTIONAL; v2
		sig			: ref AlgIdentifier;
		issuer			: ref Name; 
		this_update		: big;
		next_update		: big; # OPTIONAL
		revoked_certs		: list of ref RevokedCert; # OPTIONAL
		exts			: list of ref Extension; # OPTIONAL

		# a is a TBSCertList: Signed.decode's tobe_signed
		decode: fn(a: array of byte): (string, ref CRL);
		tostring: fn(c: self ref CRL): string;
		is_revoked: fn(c: self ref CRL, sn: ref Keyring->IPint): int;
	};

	RevokedCert: adt {
		user_cert		: ref Keyring->IPint; # serial_number
		revoc_date		: big; # OPTIONAL
		exts			: list of ref Extension; # OPTIONAL; CRL entry extensions

		tostring: fn(rc: self ref RevokedCert): string;	
	};

	## Certificate Extensions

	# The extensions that have a class here, decoded; the rest are
	# left out.  Whether a certificate may be used with a critical
	# extension is the path's question (verify_certchain), which
	# reads more extensions than these.
	parse_exts: fn(es: list of ref Extension): (string, list of ref ExtClass);

	ExtClass: adt {
		pick {
		AuthorityKeyIdentifier =>
			id		: array of byte; # OCTET STRING
			issuer		: ref GeneralName;
			serial_number	: ref Keyring->IPint;
		SubjectKeyIdentifier =>
			id		: array of byte; # OCTET STRING
		BasicConstraints =>
			ca		: int;
			pathlen		: int;	# pathLenConstraint, or -1
		KeyUsage =>
			usage		: int;
		SubjectAltName =>
			alias		: list of ref GeneralName;
		ReasonCode =>
			code		: int;
		}

		# nil and no error for an extension with no class here
		decode: fn(ext: ref Extension): (string, ref ExtClass);
		tostring: fn(et: self ref ExtClass): string;
	};

	# key usage: ExtClass.KeyUsage.usage is the or of these, one bit for
	# each of RFC 5280 4.2.1.3's, digitalSignature (bit 0) the lowest.
	# (They were iota << 1: 0, 2, 4, 6, ... which are not bits.)
	KeyUsage_DigitalSignature, KeyUsage_NonRepudiation, KeyUsage_KeyEncipherment,
	KeyUsage_DataEncipherment, KeyUsage_KeyAgreement, KeyUsage_KeyCertSign, 
	KeyUsage_CRLSign, KeyUsage_EncipherOnly, KeyUsage_DecipherOnly : con 1 << iota;

	# CRL reason: ExtClass.ReasonCode.code is one of these, CRLReason's
	# values (RFC 5280 5.3.1; 7 is not used)
	Reason_Unspecified, Reason_KeyCompromise, Reason_CACompromise, 
	Reason_AffiliationChanged, Reason_Superseded, Reason_CessationOfOperation, 
	Reason_CertificateHold : con iota;
	Reason_RemoveFromCRL : con 8;

	# General Name
	GeneralName: adt {
		pick {
		otherName or 		# [0]
		rfc822Name or 		# [1]
		dNSName or 		# [2]
		x400Address or 		# [3]
		uniformResourceIdentifier => # [6]
			str		: string;	# otherName: its type's OID as text
		iPAddress =>		# [7]
			ip		: array of byte;
		registeredID =>		# [8]
			oid		: ref ASN1->Oid;
		ediPartyName =>		# [5]
			nameAssigner	: ref Name; # [0]
			partyName	: ref Name; # [1]
		directoryName =>	# [4]
			dir		: ref Name;
		}

		tostring: fn(g: self ref GeneralName): string;
	};
};

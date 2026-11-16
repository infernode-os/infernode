#!/usr/bin/env python3
# Makes tests/host/mldsa/vectors.txt, the known answers dsatest.c holds
# libsec/mldsa*.c to, from OpenSSL.  Run: python3 gen.py > vectors.txt
#
# libsec's mldsa65_sign and mldsa87_sign are FIPS 204's Sign_internal
# (Algorithm 7) with the caller's message as M' and rnd from the
# generator: Keyring signs a digest of its own format with them.  OpenSSL
# makes the same bytes when told to take the message as it is
# (message-encoding 0) and given rnd (test-entropy); Python's
# cryptography package (46 or later, OpenSSL 3.5 or later) does not pass
# those on, so they are set through ../slhdsa/ossl.py.  Where that cannot
# be done the package's sign_mu makes a signature to be verified, and the
# line says so with "-" for RND and SKSUM.
#
#   kat SET XI PK SKSUM MSG RND SIG
#       ML-DSA.KeyGen_internal(XI) (Algorithm 6) gives PK and a secret
#       key whose SHAKE256-256 is SKSUM; Sign_internal(sk, MSG, RND) is
#       SIG; SIG verifies
#   sig SET EXPECT WHAT PK MSG SIG
#       Verify_internal(PK, MSG, SIG) is EXPECT
# SET is 65 or 87; MSG is hex, "-" for none.
import sys, os, hashlib, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "slhdsa"))
import ossl
from cryptography.hazmat.primitives.asymmetric import mldsa
from cryptography.hazmat.backends.openssl.backend import backend

have = ossl.available() is None
rnd = random.Random(204)
hx = lambda b: b.hex() or "-"
print("# ML-DSA-65 and -87 known answers from %s, made by" % backend.openssl_version_text())
print("# tests/host/mldsa/gen.py" + (": Sign_internal with the randomness given." if have else "; signatures by sign_mu, to be verified only."))
print("#   kat SET XI PK SKSUM MSG RND SIG")
print("#   sig SET EXPECT WHAT PK MSG SIG")
for name, alg, Priv, Pub in ((65, "ML-DSA-65", mldsa.MLDSA65PrivateKey, mldsa.MLDSA65PublicKey),
		(87, "ML-DSA-87", mldsa.MLDSA87PrivateKey, mldsa.MLDSA87PublicKey)):
	for i in range(4):
		xi = rnd.randbytes(32)
		msg = [b"", rnd.randbytes(32), rnd.randbytes(64), rnd.randbytes(700)][i]
		key = Priv.from_seed_bytes(xi)
		pk = key.public_key().public_bytes_raw()
		tr = hashlib.shake_256(pk).digest(64)
		mu = hashlib.shake_256(tr + msg).digest(64)
		if have:
			opk, sk = ossl.keygen(alg, xi)
			if opk != pk:
				sys.exit("gen.py: the two ways into OpenSSL give different keys")
			r = bytes(32) if i == 0 else rnd.randbytes(32)	# the first: FIPS 204's deterministic variant
			sig = ossl.sign(alg, sk, msg, params=[(b"message-encoding", 0), (b"test-entropy", r)])
			sksum, r = hashlib.shake_256(sk).hexdigest(32), r.hex()
		else:
			sig = key.sign_mu(mu)
			sksum = r = "-"
		Pub.from_public_bytes(pk).verify_mu(sig, mu)	# raises if not
		print("kat %d %s %s %s %s %s %s" % (name, xi.hex(), pk.hex(), sksum, hx(msg), r, sig.hex()))
		if i == 1:
			# FIPS 204's pure signature of msg (Algorithm 2: M' = 0 || 0 || msg)
			# is, to this code, a signature of 00 00 || msg and not of msg
			s = key.sign(msg)
			print("sig %d 0 pure-of-msg %s %s %s" % (name, pk.hex(), hx(msg), s.hex()))
			print("sig %d 1 pure-as-internal %s %s %s" % (name, pk.hex(), hx(b"\0\0" + msg), s.hex()))

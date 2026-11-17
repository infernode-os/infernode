#!/usr/bin/env python3
# Makes tests/host/mldsa/vectors.txt, the known answers dsatest.c holds
# libsec/mldsa*.c to, from OpenSSL.  Run: python3 gen.py > vectors.txt
#
# libsec's mldsa65_sign and mldsa87_sign are FIPS 204's ML-DSA.Sign
# (Algorithm 2), the pure signature with an empty context string, with
# rnd from the generator; the _ctx forms take a context string, and
# mldsa_sign_internal is Algorithm 7 on M' whole.  Python's cryptography
# package (46 or later, OpenSSL 3.5 or later) makes the pure signature
# through its own ML-DSA API, but with randomness of its own; to give
# OpenSSL the randomness (test-entropy), and for the internal interface
# (message-encoding 0), ../slhdsa/ossl.py reaches the same OpenSSL.
# Where that cannot be done the package's own sign makes a signature to
# be verified, the line says so with "-" for RND and SKSUM, and there
# are no ctx or int lines.
#
#   kat SET XI PK SKSUM MSG RND SIG
#       ML-DSA.KeyGen_internal(XI) (Algorithm 6) gives PK and a secret
#       key whose SHAKE256-256 is SKSUM; ML-DSA.Sign(sk, MSG, "") with
#       RND as rnd is SIG; SIG verifies
#   ctx SET XI MSG CTX RND SIG
#       ML-DSA.Sign(sk, MSG, CTX) with RND is SIG; a CTX of more than
#       255 bytes is refused (SIG is then not looked at)
#   int SET XI MP RND SIG
#       ML-DSA.Sign_internal(sk, MP, RND) (Algorithm 7) is SIG
#   sig SET EXPECT WHAT PK MSG SIG
#       ML-DSA.Verify(PK, MSG, SIG, "") is EXPECT
# SET is 65 or 87; MSG, CTX and MP are hex, "-" for none.
import sys, os, hashlib, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "slhdsa"))
import ossl
from cryptography.hazmat.primitives.asymmetric import mldsa
from cryptography.hazmat.backends.openssl.backend import backend

have = ossl.available() is None
rnd = random.Random(204)
hx = lambda b: b.hex() or "-"
print("# ML-DSA-65 and -87 known answers from %s, made by" % backend.openssl_version_text())
print("# tests/host/mldsa/gen.py" + (": ML-DSA.Sign and Sign_internal with the randomness given." if have else "; signatures by the package's sign, to be verified only."))
print("#   kat SET XI PK SKSUM MSG RND SIG")
print("#   ctx SET XI MSG CTX RND SIG")
print("#   int SET XI MP RND SIG")
print("#   sig SET EXPECT WHAT PK MSG SIG")
for name, alg, Priv, Pub in ((65, "ML-DSA-65", mldsa.MLDSA65PrivateKey, mldsa.MLDSA65PublicKey),
		(87, "ML-DSA-87", mldsa.MLDSA87PrivateKey, mldsa.MLDSA87PublicKey)):
	for i in range(4):
		xi = rnd.randbytes(32)
		msg = [b"", rnd.randbytes(32), rnd.randbytes(64), rnd.randbytes(700)][i]
		key = Priv.from_seed_bytes(xi)
		pub = key.public_key()
		pk = pub.public_bytes_raw()
		if have:
			opk, sk = ossl.keygen(alg, xi)
			if opk != pk:
				sys.exit("gen.py: the two ways into OpenSSL give different keys")
			r = bytes(32) if i == 0 else rnd.randbytes(32)	# the first: FIPS 204's deterministic variant
			sig = ossl.sign(alg, sk, msg, params=[(b"test-entropy", r)])
			sksum, rh = hashlib.shake_256(sk).hexdigest(32), r.hex()
		else:
			sig = key.sign(msg)
			sksum = rh = "-"
		pub.verify(sig, msg)	# the package's own ML-DSA: raises if not
		print("kat %d %s %s %s %s %s %s" % (name, xi.hex(), pk.hex(), sksum, hx(msg), rh, sig.hex()))
		if have:
			# under context strings: one byte, a text, the longest, and one too long
			for c in ([b"\0", b"InferNode", rnd.randbytes(255)] if i == 1 else [rnd.randbytes(rnd.randrange(1, 255))]):
				r = rnd.randbytes(32)
				s = ossl.sign(alg, sk, msg, ctx=c, params=[(b"test-entropy", r)])
				pub.verify(s, msg, c)
				print("ctx %d %s %s %s %s %s" % (name, xi.hex(), hx(msg), c.hex(), r.hex(), s.hex()))
			if i == 1:
				print("ctx %d %s %s %s %s %s" % (name, xi.hex(), hx(msg), rnd.randbytes(256).hex(), r.hex(), s.hex()))
			# the internal interface, M' as it comes
			r = rnd.randbytes(32)
			s = ossl.sign(alg, sk, msg, params=[(b"message-encoding", 0), (b"test-entropy", r)])
			print("int %d %s %s %s %s" % (name, xi.hex(), hx(msg), r.hex(), s.hex()))
			if i == 1:
				# Sign_internal's signature of msg is not the pure signature of msg,
				# and its signature of 0 || 0 || msg is
				print("sig %d 0 internal-of-msg %s %s %s" % (name, pk.hex(), hx(msg), s.hex()))
				s = ossl.sign(alg, sk, b"\0\0" + msg, params=[(b"message-encoding", 0), (b"test-entropy", r)])
				print("sig %d 1 internal-of-00-00-msg %s %s %s" % (name, pk.hex(), hx(msg), s.hex()))
		if i == 1:
			# the package's own pure signatures, hedged with its randomness
			s = key.sign(msg)
			print("sig %d 1 pure-of-msg %s %s %s" % (name, pk.hex(), hx(msg), s.hex()))
			print("sig %d 0 pure-of-other-msg %s %s %s" % (name, pk.hex(), hx(msg + b"x"), s.hex()))
			s = key.sign(msg, b"ctx")
			print("sig %d 0 pure-under-a-context %s %s %s" % (name, pk.hex(), hx(msg), s.hex()))

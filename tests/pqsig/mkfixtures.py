#!/usr/bin/env python3
# Makes the fixtures of tests/pqsig_test.b: keys and Inferno certificates
# (keyring-certtostr(2)'s text) made outside libsec, for Keyring's
# slhdsa192s, slhdsa256s, mldsa65, mldsa87 and ed25519.  Run in this
# directory:
#	python3 mkfixtures.py
#
# Keyring->sign(sk, exp, state, "sha256") signs the SHA-256 of the
# state's bytes followed by "owner exp".  The algorithms here sign bytes,
# and are given the digest's 32: as the message of FIPS 204's and FIPS
# 205's pure signature with an empty context string, and of Ed25519.
# (They were given the digest as a number's bytes, so one beginning 00
# was signed as 31; ML-DSA was Sign_internal, with no header on M'.)
#
# Two messages: MSG, and MSG0, whose digest begins with a zero byte.
#
#   ALG.pk (ALG.sk for SLH-DSA)	the key, in pktostr's (sktostr's) text:
#		SLH-DSA's from fixed seeds by tests/host/slhdsa/slh_ref.py
#		(FIPS 205 written out in Python), the others' by Python's
#		cryptography package (OpenSSL)
#   ALG.cert	a certificate on MSG (not for slhdsa192s, whose cert0 is
#		enough of 21K)
#   ALG.cert0	a certificate on MSG0 (not for slhdsa256s: 40K)
#   slhdsa192s.oldcert	a certificate on MSG in the format libsec made
#		before it was held to FIPS 205: refused
#   mldsa65.oldcert, mldsa87.oldcert	a certificate on MSG as Keyring
#		made them before: FIPS 204's Sign_internal on the digest
#		(mu = H(tr || digest)): refused
#   ed25519.oldcert0	a certificate on MSG0 as Keyring made them before:
#		a signature of the digest's last 31 bytes: refused
import sys, os, hashlib, base64
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "slhdsa"))
from slh_ref import SLH, P192, P256, slh_sign, slh_verify

MSG = b"InferNode post-quantum certificate fixture"
OWNER = "pqsig"
EXP = 0

def digest(msg):
	return hashlib.sha256(msg + ("%s %d" % (OWNER, EXP)).encode()).digest()

# MSG0: MSG and the least number that makes the digest begin 00
i = 0
while digest(MSG + b" %d" % i)[0] != 0:
	i += 1
MSG0 = MSG + b" %d" % i
print("MSG0 is %r" % MSG0)
if digest(MSG)[0] == 0:
	raise SystemExit("choose another MSG: its digest begins with a zero byte too")

b64 = lambda b: base64.b64encode(b).decode()

def cert(alg, sig):
	return "%s\nsha256\n%s\n%d\n%s\n" % (alg, OWNER, EXP, b64(sig))

def put(name, text):
	with open(name, "w") as f:
		f.write(text)
	print("wrote", name)

for alg, par, salt in (("slhdsa192s", P192, 1), ("slhdsa256s", P256, 2)):
	n = par.n
	seed = hashlib.shake_256(b"pqsig fixture key %d" % salt).digest(3 * n)
	pk, sk = SLH(par).keygen(seed[:n], seed[n:2*n], seed[2*n:])
	put(alg + ".sk", "%s\n%s\n%s\n%s\n" % (alg, OWNER, b64(sk), b64(pk)))
	# hedged, with fixed bytes as the randomness
	addrnd = hashlib.shake_256(b"pqsig fixture randomness %d" % salt).digest(n)
	if alg == "slhdsa192s":
		sig = slh_sign(par, digest(MSG0), sk, b"", addrnd)
		assert slh_verify(par, digest(MSG0), sig, pk)
		put(alg + ".cert0", cert(alg, sig))
		old = SLH(par, 'old', 'old', 'old').sign(digest(MSG), sk)
		assert not slh_verify(par, digest(MSG), old, pk)
		put(alg + ".oldcert", cert(alg, old))
	else:
		sig = slh_sign(par, digest(MSG), sk, b"", addrnd)
		assert slh_verify(par, digest(MSG), sig, pk)
		put(alg + ".cert", cert(alg, sig))

try:
	from cryptography.hazmat.primitives.asymmetric import mldsa, ed25519
except ImportError:
	print("no cryptography package with ML-DSA: the mldsa and ed25519 fixtures are left as they are")
	sys.exit(0)
for alg, Priv, salt in (("mldsa65", mldsa.MLDSA65PrivateKey, 3), ("mldsa87", mldsa.MLDSA87PrivateKey, 4)):
	xi = hashlib.shake_256(b"pqsig fixture key %d" % salt).digest(32)
	key = Priv.from_seed_bytes(xi)
	pk = key.public_key().public_bytes_raw()
	put(alg + ".pk", "%s\n%s\n%s\n" % (alg, OWNER, b64(pk)))
	for name, msg in ((".cert", MSG), (".cert0", MSG0)):
		sig = key.sign(digest(msg))		# ML-DSA.Sign, pure, no context
		key.public_key().verify(sig, digest(msg))
		put(alg + name, cert(alg, sig))
	tr = hashlib.shake_256(pk).digest(64)
	mu = hashlib.shake_256(tr + digest(MSG)).digest(64)
	put(alg + ".oldcert", cert(alg, key.sign_mu(mu)))

key = ed25519.Ed25519PrivateKey.from_private_bytes(hashlib.shake_256(b"pqsig fixture key 5").digest(32))
pk = key.public_key().public_bytes_raw()
put("ed25519.pk", "ed25519\n%s\n%s\n" % (OWNER, b64(pk)))
put("ed25519.cert", cert("ed25519", key.sign(digest(MSG))))
put("ed25519.cert0", cert("ed25519", key.sign(digest(MSG0))))
put("ed25519.oldcert0", cert("ed25519", key.sign(digest(MSG0)[1:])))

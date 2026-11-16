#!/usr/bin/env python3
# Makes the fixtures of tests/pqsig_test.b: keys and Inferno certificates
# (keyring-certtostr(2)'s text) made outside libsec, for Keyring's
# slhdsa192s, slhdsa256s, mldsa65 and mldsa87.  Run in this directory:
#	python3 mkfixtures.py
#
# Keyring->sign(sk, exp, state, "sha256") signs the SHA-256 of the
# state's bytes followed by "owner exp", as the bytes of that number
# (leading zero bytes dropped).
#
#   slhdsa192s.sk, slhdsa256s.sk	a secret key (sktostr's text) made from
#		fixed seeds by tests/host/slhdsa/slh_ref.py, FIPS 205
#		written out in Python
#   slhdsa192s.sum, slhdsa256s.sum	the SHA-256 of the certificate that
#		key makes on MSG: SLH-DSA here is deterministic, so
#		Keyring must make these bytes
#   slhdsa192s.oldcert	a certificate on MSG from that key in the format
#		libsec made before it was held to FIPS 205 (the reference
#		with its three 'old' switches, on the bare digest): it
#		must be refused
#   mldsa65.pk, mldsa65.cert, mldsa87.pk, mldsa87.cert
#		a public key and a certificate on MSG made by OpenSSL
#		(Python's cryptography package; skipped without it): what
#		ML-DSA signs here is mu = H(tr || digest), FIPS 204's
#		Sign_internal on the digest, and such a certificate must
#		go on verifying
import sys, os, hashlib, base64
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "slhdsa"))
from slh_ref import SLH, P192, P256, slh_sign, slh_verify

MSG = b"InferNode post-quantum certificate fixture"
OWNER = "pqsig"
EXP = 0

def signed():
	d = hashlib.sha256(MSG + ("%s %d" % (OWNER, EXP)).encode()).digest()
	if d[0] == 0:
		raise SystemExit("choose another MSG: the digest begins with a zero byte")
	return d

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
	sig = slh_sign(par, signed(), sk)
	assert slh_verify(par, signed(), sig, pk)
	put(alg + ".sum", hashlib.sha256(cert(alg, sig).encode()).hexdigest() + "\n")
	if alg == "slhdsa192s":
		old = SLH(par, 'old', 'old', 'old').sign(signed(), sk)
		assert not slh_verify(par, signed(), old, pk)
		put(alg + ".oldcert", cert(alg, old))

try:
	from cryptography.hazmat.primitives.asymmetric import mldsa
except ImportError:
	print("no cryptography package with ML-DSA: the mldsa fixtures are left as they are")
	sys.exit(0)
for alg, Priv, salt in (("mldsa65", mldsa.MLDSA65PrivateKey, 3), ("mldsa87", mldsa.MLDSA87PrivateKey, 4)):
	xi = hashlib.shake_256(b"pqsig fixture key %d" % salt).digest(32)
	key = Priv.from_seed_bytes(xi)
	pk = key.public_key().public_bytes_raw()
	tr = hashlib.shake_256(pk).digest(64)
	mu = hashlib.shake_256(tr + signed()).digest(64)
	sig = key.sign_mu(mu)
	key.public_key().verify_mu(sig, mu)
	put(alg + ".pk", "%s\n%s\n%s\n" % (alg, OWNER, b64(pk)))
	put(alg + ".cert", cert(alg, sig))

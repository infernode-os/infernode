#!/usr/bin/env python3
# libsec's ML-DSA against OpenSSL's (Python's cryptography package), live:
# random keys and messages, each side verifying the other's signatures
# (as Sign_internal's: mu = H(tr || message)), and, where OpenSSL can be
# given the signing randomness (../slhdsa/ossl.py), the same signature
# byte for byte.  Run by tests/host/mldsa_test.sh; exit 77 without the
# package.
#   cross.py DSATEST [ROUNDS]
import sys, os, subprocess, hashlib, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "slhdsa"))
try:
	from cryptography.hazmat.primitives.asymmetric import mldsa
	from cryptography.exceptions import InvalidSignature
except ImportError:
	print("SKIP: no Python cryptography package with ML-DSA")
	sys.exit(77)
import ossl
exact = ossl.available() is None
rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 30
proc = subprocess.Popen([sys.argv[1], "cli"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def cmd(*a, lines=1):
	proc.stdin.write(" ".join(a) + "\n"); proc.stdin.flush()
	d = {}
	for i in range(lines):
		l = proc.stdout.readline()
		if not l:
			print("FAIL: dsatest cli ended"); sys.exit(1)
		k, v = l.rstrip("\n").split(" ", 1); d[k] = v
	return d
hx = lambda b: b.hex() or "-"
fails = 0
def check(ok, what):
	global fails
	if not ok:
		fails += 1
		if fails < 10:
			print("FAIL: " + what)
rnd = random.Random(int.from_bytes(os.urandom(4), "big"))
for p, alg, Priv, Pub in ((65, "ML-DSA-65", mldsa.MLDSA65PrivateKey, mldsa.MLDSA65PublicKey), (87, "ML-DSA-87", mldsa.MLDSA87PrivateKey, mldsa.MLDSA87PublicKey)):
	for i in range(rounds):
		xi = os.urandom(32)
		ref = Priv.from_seed_bytes(xi)
		refpk = ref.public_key().public_bytes_raw()
		r = cmd("keygen", str(p), xi.hex(), lines=3)
		pk = bytes.fromhex(r["pk"]); sk = bytes.fromhex(r["sk"])
		check(r["rc"] == "0" and pk == refpk, alg + ": key from xi differs from OpenSSL's")
		tr = hashlib.shake_256(pk).digest(64)
		msg = os.urandom(rnd.choice((0, 1, 32, 48, 64, 300)))
		mu = hashlib.shake_256(tr + msg).digest(64)
		r32 = os.urandom(32)
		s = cmd("sign", str(p), sk.hex(), hx(msg), r32.hex(), lines=2)
		sig = bytes.fromhex(s["sig"])
		try:
			Pub.from_public_bytes(pk).verify_mu(sig, mu); ok = True
		except InvalidSignature:
			ok = False
		check(s["rc"] == "0" and ok, alg + ": OpenSSL refuses libsec's signature")
		if exact:
			osk = ossl.keygen(alg, xi)[1]
			check(osk == sk, alg + ": secret key from xi differs from OpenSSL's")
			check(ossl.sign(alg, osk, msg, params=[(b"message-encoding", 0), (b"test-entropy", r32)]) == sig,
				alg + ": signature differs from OpenSSL's Sign_internal with the same rnd")
		osig = ref.sign_mu(mu)
		check(cmd("verify", str(p), pk.hex(), hx(msg), osig.hex())["ok"] == "1", alg + ": libsec refuses OpenSSL's signature")
		bad = bytearray(osig); bad[rnd.randrange(len(bad))] ^= 1 << rnd.randrange(8)
		check(cmd("verify", str(p), pk.hex(), hx(msg), bytes(bad).hex())["ok"] == "0", alg + ": a changed signature accepted")
proc.stdin.close(); proc.wait()
if fails:
	sys.exit(1)
print("%d keys of each set equal OpenSSL's, each verifying the other's signatures%s" % (rounds, "; signatures equal byte for byte given OpenSSL's randomness" if exact else ""))

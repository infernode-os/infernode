#!/usr/bin/env python3
# libsec's ML-KEM against OpenSSL's (Python's cryptography package), live:
# random keys, each side encapsulating to the other's key.  Run by
# tests/host/mlkem_test.sh; exit 77 without the package.
#   cross.py KEMTEST [ROUNDS]
import sys, os, subprocess, hashlib
try:
	from cryptography.hazmat.primitives.asymmetric import mlkem
except ImportError:
	print("SKIP: no Python cryptography package with ML-KEM")
	sys.exit(77)
rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 20
proc = subprocess.Popen([sys.argv[1], "cli"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def cmd(*a, lines=1):
	proc.stdin.write(" ".join(a) + "\n"); proc.stdin.flush()
	d = {}
	for i in range(lines):
		l = proc.stdout.readline()
		if not l:
			print("FAIL: kemtest cli ended"); sys.exit(1)
		k, v = l.rstrip("\n").split(" ", 1); d[k] = v
	return d
fails = 0
def check(ok, what):
	global fails
	if not ok:
		fails += 1
		if fails < 10:
			print("FAIL: " + what)
for p, Priv, Pub in ((768, mlkem.MLKEM768PrivateKey, mlkem.MLKEM768PublicKey), (1024, mlkem.MLKEM1024PrivateKey, mlkem.MLKEM1024PublicKey)):
	name = "ML-KEM-%d" % p
	for i in range(rounds):
		d = os.urandom(32); z = os.urandom(32)
		ref = Priv.from_seed_bytes(d + z)
		refek = ref.public_key().public_bytes_raw()
		r = cmd("keygen", str(p), (d + z).hex(), lines=3)
		ek = bytes.fromhex(r["ek"]); dk = bytes.fromhex(r["dk"])
		check(r["rc"] == "0" and ek == refek, name + ": key from (d, z) differs from OpenSSL's")
		# libsec encapsulates to OpenSSL's key
		e = cmd("encaps", str(p), refek.hex(), os.urandom(32).hex(), lines=3)
		ct = bytes.fromhex(e["ct"])
		check(e["rc"] == "0" and ref.decapsulate(ct) == bytes.fromhex(e["ss"]), name + ": OpenSSL does not decapsulate libsec's ciphertext to its secret")
		# OpenSSL encapsulates to libsec's key
		a, b = Pub.from_public_bytes(ek).encapsulate()
		ss, ct = (a, b) if len(a) == 32 else (b, a)
		dd = cmd("decaps", str(p), dk.hex(), ct.hex(), lines=2)
		check(dd["rc"] == "0" and bytes.fromhex(dd["ss"]) == ss, name + ": libsec does not decapsulate OpenSSL's ciphertext to its secret")
		bad = bytearray(ct); bad[os.urandom(1)[0] % len(bad)] ^= 1 << (i % 8); bad = bytes(bad)
		dd = cmd("decaps", str(p), dk.hex(), bad.hex(), lines=2)
		check(dd["rc"] == "0" and bytes.fromhex(dd["ss"]) == hashlib.shake_256(z + bad).digest(32), name + ": a changed ciphertext does not give J(z || c)")
proc.stdin.close(); proc.wait()
if fails:
	sys.exit(1)
print("%d keys of each set equal OpenSSL's; each side decapsulates the other's ciphertexts" % rounds)

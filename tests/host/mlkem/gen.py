#!/usr/bin/env python3
# Makes tests/host/mlkem/vectors.txt, the known answers kemtest.c holds
# libsec/mlkem*.c to, from OpenSSL (Python's cryptography package, 46 or
# later with OpenSSL 3.5 or later).  Run: python3 gen.py > vectors.txt
#
#   kat SET D Z EK CT K BADCT BADK
#       ML-KEM.KeyGen_internal(D, Z) (FIPS 203 Algorithm 16) gives the
#       encapsulation key EK; decapsulating CT, which OpenSSL made for
#       EK, gives K; decapsulating BADCT (CT with one bit changed) gives
#       BADK, which is J(Z || BADCT) (implicit rejection, Algorithm 18)
# SET is 768 or 1024.
import sys, os, hashlib, random
from cryptography.hazmat.primitives.asymmetric import mlkem
from cryptography.hazmat.backends.openssl.backend import backend

rnd = random.Random(203)
print("# ML-KEM-768 and -1024 known answers from %s, made by" % backend.openssl_version_text())
print("# tests/host/mlkem/gen.py.")
print("#   kat SET D Z EK CT K BADCT BADK")
for name, Priv, Pub in ((768, mlkem.MLKEM768PrivateKey, mlkem.MLKEM768PublicKey),
		(1024, mlkem.MLKEM1024PrivateKey, mlkem.MLKEM1024PublicKey)):
	for i in range(5):
		d = rnd.randbytes(32)
		z = rnd.randbytes(32)
		key = Priv.from_seed_bytes(d + z)
		ek = key.public_key().public_bytes_raw()
		a, b = Pub.from_public_bytes(ek).encapsulate()
		k, ct = (a, b) if len(a) == 32 else (b, a)
		if key.decapsulate(ct) != k:
			sys.exit("gen.py: OpenSSL does not decapsulate its own ciphertext")
		bad = bytearray(ct)
		bad[rnd.randrange(len(bad))] ^= 1 << rnd.randrange(8)
		bad = bytes(bad)
		badk = key.decapsulate(bad)
		if badk != hashlib.shake_256(z + bad).digest(32) or badk == k:
			sys.exit("gen.py: OpenSSL's rejection is not J(z || c)")
		print("kat %d %s %s %s %s %s %s %s" % (name, d.hex(), z.hex(), ek.hex(), ct.hex(), k.hex(), bad.hex(), badk.hex()))

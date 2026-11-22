#!/usr/bin/env python3
# Known answers for tests/host/ed25519_test.sh: Ed25519 signatures (RFC
# 8032; they are deterministic) made by Python's cryptography.
#
#	python3 gen.py > vectors.txt
#
# Each line: seed, public key, message, signature, in hexadecimal ("-"
# for a message of no bytes).  The first three keys and messages are RFC
# 8032 section 7.1's TEST 1, 2 and 3; the rest are from a fixed seed,
# with messages of 0 to 300 bytes.
import hashlib
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

def line(seed, msg):
	sk = Ed25519PrivateKey.from_private_bytes(seed)
	pk = sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
	sig = sk.sign(msg)
	print(seed.hex(), pk.hex(), msg.hex() or "-", sig.hex())
	return pk

rfc = [
	("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", ""),
	("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "72"),
	("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7", "af82"),
]
first = True
for seed, msg in rfc:
	pk = line(bytes.fromhex(seed), bytes.fromhex(msg))
	if first:
		# RFC 8032 7.1 TEST 1's public key
		assert pk.hex() == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
		first = False

def prg(tag, n):
	out = b""
	i = 0
	while len(out) < n:
		out += hashlib.sha256(b"ed25519 vectors %s %d" % (tag, i)).digest()
		i += 1
	return out[:n]

for i in range(120):
	n = [0, 1, 2, 31, 32, 33, 63, 64, 65, 111, 112, 113, 127, 128, 129, 300][i % 16] + (i // 16)
	line(prg(b"seed%d" % i, 32), prg(b"msg%d" % i, n))

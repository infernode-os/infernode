#!/usr/bin/env python3
# Makes tests/host/sha3/vectors.txt, the known answers sha3test.c holds
# libsec/sha3.c to, from Python's hashlib.  Run: python3 gen.py > vectors.txt
#
#   ALG MSG OUTLEN PIECE OUT
# ALG is sha3_256, sha3_512, shake128 or shake256; MSG is hex ("-" for
# none); OUT is the first OUTLEN bytes of output.  The SHAKEs are also
# absorbed and squeezed PIECE bytes at a time.  Lengths lie either side
# of every rate (72, 136, 168 bytes) and of two blocks.
import hashlib, random
rnd = random.Random(202)
lens = list(range(0, 12)) + [71, 72, 73, 134, 135, 136, 137, 143, 144, 145, 167, 168, 169, 271, 272, 273, 335, 336, 337, 400, 1000]
print("# SHA-3 and SHAKE known answers from Python's hashlib, made by tests/host/sha3/gen.py")
print("#   ALG MSG OUTLEN PIECE OUT")
for n in lens:
	m = rnd.randbytes(n)
	h = m.hex() or "-"
	print("sha3_256 %s 32 1 %s" % (h, hashlib.sha3_256(m).hexdigest()))
	print("sha3_512 %s 64 1 %s" % (h, hashlib.sha3_512(m).hexdigest()))
	for outlen in ((1, 32, 135, 136, 137, 167, 168, 169, 500) if n in (0, 1, 136, 168, 337) else (32, 137, 169)):
		for alg, f in (("shake128", hashlib.shake_128), ("shake256", hashlib.shake_256)):
			print("%s %s %d %d %s" % (alg, h, outlen, rnd.choice([1, 7, 64, 135, 136, 137, 168, 169]), f(m).hexdigest(outlen)))

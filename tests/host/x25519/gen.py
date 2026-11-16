#!/usr/bin/env python3
# Makes vectors.txt for tests/host/x25519_test.sh:
#
#	python3 gen.py > vectors.txt
#
# x25519 K U OUT	OpenSSL's X25519 (Python's cryptography) of scalar K
#			and point U, 32 bytes each in hexadecimal
# contract L0 L1 L2 L3 L4 OUT	the field element with those five 51-bit
#			limbs (hexadecimal; they may hold a bit or two more),
#			reduced mod 2^255-19, as 32 little-endian bytes
#
# The first x25519 line is the one the code before failed: the scalar is
# 5l-1 (a fixed point of clamping, -1 mod the group's order l), so the
# result is the point itself, and the point's low limb is 2^51-1, where
# the final subtraction of p borrowed and the borrow was added.
import random
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey

random.seed(25519)
p = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493

def x(k, u):
	return X25519PrivateKey.from_private_bytes(k).exchange(X25519PublicKey.from_public_bytes(u))

out = []
k = (5*L - 1).to_bytes(32, 'little')
u = (2**51 - 1 + 24 * 2**51).to_bytes(32, 'little')
r = x(k, u)
assert r == u
out.append('x25519 %s %s %s' % (k.hex(), u.hex(), r.hex()))
# RFC 7748 6.1
a = bytes.fromhex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a')
b = bytes.fromhex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb')
A = X25519PrivateKey.from_private_bytes(a).public_key().public_bytes_raw()
B = X25519PrivateKey.from_private_bytes(b).public_key().public_bytes_raw()
assert x(a, B).hex() == '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'
out.append('x25519 %s %s %s' % (a.hex(), B.hex(), x(a, B).hex()))
out.append('x25519 %s %s %s' % (b.hex(), A.hex(), x(b, A).hex()))
for i in range(60):
	k = random.randbytes(32)
	u = X25519PrivateKey.from_private_bytes(random.randbytes(32)).public_key().public_bytes_raw()
	out.append('x25519 %s %s %s' % (k.hex(), u.hex(), x(k, u).hex()))

def contract(l):
	v = sum(l[i] << (51*i) for i in range(5)) % p
	return v.to_bytes(32, 'little')

M = 2**51 - 1
cases = []
# every low limb near the top of its range, where the subtraction of p borrows
for i in range(1, 41):
	for hi in ([0, 0, 0, 0], [M, M, M, M], [1, 0, 0, 0], [0, 0, 0, M], [M, 0, M, 0]):
		cases.append([2**51 - i] + hi)
# p-1, p, p+1, 2^255-1, 2p-1 and limbs a bit over 51 bits
cases += [[M-19, M, M, M, M], [M-18, M, M, M, M], [M-17, M, M, M, M], [M, M, M, M, M],
	[2*M - 37, 2*M, 2*M, 2*M, 2*M], [2**52, 2**52, 2**52, 2**52, 2**52], [0, 0, 0, 0, 0], [18, 0, 0, 0, 0], [19, 0, 0, 0, 0]]
for i in range(400):
	cases.append([random.getrandbits(52) for j in range(5)])
for i in range(200):
	cases.append([2**51 - random.randrange(1, 64)] + [random.choice([0, M, random.getrandbits(51)]) for j in range(4)])
for l in cases:
	out.append('contract %x %x %x %x %x %s' % (l[0], l[1], l[2], l[3], l[4], contract(l).hex()))
print('\n'.join(out))

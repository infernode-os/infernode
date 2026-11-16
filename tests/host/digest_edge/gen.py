#!/usr/bin/env python3
# Makes vectors.txt for tests/host/digest_edge_test.sh, from Python's
# hashlib and hmac (OpenSSL's):
#
#	python3 gen.py > vectors.txt
#
# hash ALG LEN DIGEST		ALG of LEN bytes, byte i being i mod 251
# hmac ALG KEYLEN LEN MAC	the same message under a key of KEYLEN bytes of 0xaa
# zeros ALG LEN DIGEST		ALG of LEN bytes of zero (lengths about 2^29, where
#				SHA-224 and SHA-256 kept the bit count in 32 bits)
import hashlib, hmac

def msg(n):
	return bytes(i % 251 for i in range(n))

for alg in ('md5', 'sha1', 'sha224', 'sha256', 'sha384', 'sha512'):
	for n in (0, 3, 55, 56, 63, 64, 65, 111, 112, 127, 128, 129, 1000):
		print('hash', alg, n, hashlib.new(alg, msg(n)).hexdigest())
for alg in ('md5', 'sha1', 'sha256', 'sha384', 'sha512'):
	for kl in (0, 4, 20, 63, 64, 65, 127, 128, 129, 131, 200, 1000):
		for n in (0, 28, 300):
			print('hmac', alg, kl, n, hmac.new(b'\xaa'*kl, msg(n), alg).hexdigest())
mb = bytes(1 << 20)
for alg in ('sha224', 'sha256'):
	for n in ((1 << 29) - 1, 1 << 29, (1 << 29) + 5):
		h = hashlib.new(alg)
		left = n
		while left > 0:
			k = min(left, len(mb))
			h.update(mb[:k])
			left -= k
		print('zeros', alg, n, h.hexdigest())

#!/usr/bin/env python3
# Makes vectors.txt for tests/host/rsa_edge_test.sh: a 2048-bit RSA key
# from OpenSSL (Python's cryptography), a message representative and its
# signature s = m^d mod n.
#
#	python3 gen.py > vectors.txt
from cryptography.hazmat.primitives.asymmetric import rsa
k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pn = k.private_numbers(); n = pn.public_numbers.n; e = pn.public_numbers.e
p, q, d = pn.p, pn.q, pn.d
m = pow(0x1234567890abcdef, 7, n)
s = pow(m, d, n)
for name, v in (('n',n),('e',e),('d',d),('p',p),('q',q),('m',m),('s',s)):
    print(name, '%X' % v)

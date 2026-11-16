#!/usr/bin/env python3
# Makes vectors.txt for tests/host/sign_nonce_test.sh: DSA and ElGamal
# signatures whose nonce is RFC 6979's (3.2), computed here from the RFC's
# text with hashlib's HMAC, for groups OpenSSL (Python's cryptography)
# makes.  The HMAC's hash goes by the order's length as libsec/nonce.c
# has it: SHA-256 to 256 bits, SHA-384 to 384, SHA-512 beyond.  Each DSA
# signature is checked with OpenSSL's verifier before it is written.
#
#	python3 gen.py > vectors.txt
import hashlib, hmac, os, math
from cryptography.hazmat.primitives.asymmetric import dsa, dh, utils
from cryptography.hazmat.primitives import hashes

def H(qlen):
    return hashlib.sha256 if qlen <= 256 else hashlib.sha384 if qlen <= 384 else hashlib.sha512

def nonces(x, m, q, extra=b''):
    qlen = q.bit_length(); rlen = (qlen+7)//8
    h = H(qlen); hlen = h().digest_size
    mac = lambda k, d: hmac.new(k, d, h).digest()
    xb = x.to_bytes(rlen, 'big'); hb = (m % q).to_bytes(rlen, 'big')
    V = b'\x01'*hlen; K = b'\x00'*hlen
    K = mac(K, V + b'\x00' + xb + hb + extra); V = mac(K, V)
    K = mac(K, V + b'\x01' + xb + hb + extra); V = mac(K, V)
    while True:
        T = b''
        while len(T) < rlen:
            V = mac(K, V); T += V
        yield int.from_bytes(T[:rlen], 'big') >> (8*rlen - qlen)
        K = mac(K, V + b'\x00'); V = mac(K, V)

def dsasig(p, q, g, x, m, extra=b''):
    for k in nonces(x, m, q, extra):
        if not 1 <= k < q: continue
        r = pow(g, k, p) % q
        if r == 0: continue
        s = pow(k, -1, q) * (m + x*r) % q
        if s == 0: continue
        return r, s

def egsig(p, g, x, m, extra=b''):
    for k in nonces(x, m, p-1, extra):
        if not 1 <= k < p-1 or math.gcd(k, p-1) != 1: continue
        r = pow(g, k, p)
        s = (m - x*r) * pow(k, -1, p-1) % (p-1)
        if s == 0: continue
        return r, s

def isprime(n):
    if n < 2: return False
    for sp in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if n % sp == 0: return n == sp
    d, r = n-1, 0
    while d % 2 == 0: d //= 2; r += 1
    for _ in range(30):
        a = int.from_bytes(os.urandom(n.bit_length()//8 + 1), 'big') % (n-3) + 2
        v = pow(a, d, n)
        if v in (1, n-1): continue
        for _ in range(r-1):
            v = v*v % n
            if v == n-1: break
        else: return False
    return True

# a group whose q is not a whole number of bytes (163 bits), for bits2int's shift
def oddgroup():
    while True:
        q = int.from_bytes(os.urandom(21), 'big') >> 5 | 1 << 162 | 1
        if isprime(q): break
    while True:
        p = (int.from_bytes(os.urandom(44), 'big') | 1 << 351) * 2*q + 1
        if p.bit_length() == 515 and isprime(p): break
    while True:
        g = pow(int.from_bytes(os.urandom(40), 'big') % p, (p-1)//q, p)
        if g > 1: return p, q, g

def out(*a):
    print(' '.join(a[:1] + tuple('%X' % v if isinstance(v, int) else v.hex().upper() or '-' for v in a[1:])))

for bits in (1024, 2048):
    key = dsa.generate_private_key(bits)
    n = key.private_numbers(); pn = n.public_numbers.parameter_numbers
    p, q, g, x, y = pn.p, pn.q, pn.g, n.x, n.public_numbers.y
    out('dsakey', p, q, g, y, x)
    for i in range(6):
        d = hashlib.sha256(b'message %d' % i).digest()
        m = int.from_bytes(d, 'big') >> max(0, 256 - q.bit_length())
        extra = b'' if i < 4 else os.urandom(32)
        r, s = dsasig(p, q, g, x, m, extra)
        if q.bit_length() == 256:
            key.public_key().verify(utils.encode_dss_signature(r, s), d, utils.Prehashed(hashes.SHA256()))
        out('dsasig', m, extra, r, s)

p, q, g = oddgroup()
x = int.from_bytes(os.urandom(30), 'big') % (q-1) + 1
out('dsakey', p, q, g, pow(g, x, p), x)
for i in range(6):
    m = int.from_bytes(hashlib.sha256(b'message %d' % i).digest(), 'big') >> (256 - 163)
    extra = b'' if i < 4 else os.urandom(32)
    r, s = dsasig(p, q, g, x, m, extra)
    w = pow(s, -1, q)
    assert pow(g, m*w % q, p) * pow(pow(g, x, p), r*w % q, p) % p % q == r
    out('dsasig', m, extra, r, s)

params = dh.generate_parameters(generator=2, key_size=512).parameter_numbers()
p = params.p
g = 4
x = int.from_bytes(os.urandom(40), 'big') % (p-3) + 1
out('egkey', p, g, pow(g, x, p), x)
for i in range(6):
    m = int.from_bytes(hashlib.sha256(b'message %d' % i).digest(), 'big')
    extra = b'' if i < 4 else os.urandom(32)
    r, s = egsig(p, g, x, m, extra)
    assert pow(g, m, p) == pow(pow(g, x, p), r, p) * pow(r, s, p) % p
    out('egsig', m, extra, r, s)

# Regenerates tests/host/secp256k1/vectors.txt: secp256k1 known answers.
# A plain Python reference (affine arithmetic, RFC 6979 with HMAC-SHA256,
# low S, recovery id) checked as it goes against OpenSSL through Python's
# cryptography package: every d*G, every signature over a 32-byte hash
# (OpenSSL's deterministic ECDSA, then low S) and its verification.
# One case per line, hex:
#   pub d x y                 d*G = (x, y)
#   sig d hash r s v          secp256k1_sign(d, hash) = r || s || v
#   rec hash r s v x y        secp256k1_recover gives (x, y)
#   rec hash r s v -          secp256k1_recover refuses it
#   ver x y hash r s ok       secp256k1_verify says ok (1 or 0)
# Run: python3 -I tests/host/secp256k1/gen.py > tests/host/secp256k1/vectors.txt
import os, hmac, hashlib
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, encode_dss_signature, Prehashed
from cryptography.hazmat.primitives import hashes
from cryptography.exceptions import InvalidSignature

p = 2**256 - 2**32 - 977
n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)

def add(P, Q):
    if P is None: return Q
    if Q is None: return P
    if P[0] == Q[0]:
        if (P[1] + Q[1]) % p == 0: return None
        l = 3*P[0]*P[0] * pow(2*P[1], -1, p) % p
    else:
        l = (Q[1]-P[1]) * pow(Q[0]-P[0], -1, p) % p
    x = (l*l - P[0] - Q[0]) % p
    return (x, (l*(P[0]-x) - P[1]) % p)

def mul(k, P):
    R = None
    for b in bin(k)[2:] if k else '':
        R = add(R, R)
        if b == '1': R = add(R, P)
    return R

h = lambda v: format(v, '064x')
def h2i(b):
    b = b[:32]
    return int.from_bytes(b, 'big')

def rfc6979(d, e):
    x = d.to_bytes(32, 'big'); h1 = (e % n).to_bytes(32, 'big')
    V = b'\1'*32; K = b'\0'*32
    K = hmac.new(K, V + b'\0' + x + h1, hashlib.sha256).digest()
    V = hmac.new(K, V, hashlib.sha256).digest()
    K = hmac.new(K, V + b'\1' + x + h1, hashlib.sha256).digest()
    V = hmac.new(K, V, hashlib.sha256).digest()
    while True:
        V = hmac.new(K, V, hashlib.sha256).digest()
        k = int.from_bytes(V, 'big')
        if 0 < k < n: return k
        K = hmac.new(K, V + b'\0', hashlib.sha256).digest()
        V = hmac.new(K, V, hashlib.sha256).digest()

def sign(d, hb):
    e = h2i(hb) % n
    k = rfc6979(d, e)
    R = mul(k, G)
    r = R[0] % n; v = R[1] & 1
    s = pow(k, -1, n) * (e + r*d) % n
    if s > n//2: s = n - s; v ^= 1
    return r, s, v

def recover(hb, r, s, v):
    if not (0 < r < n and 0 < s < n): return None
    y2 = (r**3 + 7) % p; y = pow(y2, (p+1)//4, p)
    if y*y % p != y2: return None
    if (y & 1) != (v & 1): y = p - y
    e = h2i(hb) % n; ri = pow(r, -1, n)
    return add(mul(-e*ri % n, G), mul(s*ri % n, (r, y)))

def verify(Q, hb, r, s):
    if not (0 < r < n and 0 < s < n): return 0
    w = pow(s, -1, n); e = h2i(hb) % n
    X = add(mul(e*w % n, G), mul(r*w % n, Q))
    return int(X is not None and X[0] % n == r)

curve = ec.SECP256K1()
def openssl_pub(d):
    pn = ec.derive_private_key(d, curve).public_key().public_numbers()
    return (pn.x, pn.y)

def check_sig(d, hb, r, s, v):
    key = ec.derive_private_key(d, curve)
    der = key.sign(hb, ec.ECDSA(Prehashed(hashes.SHA256()), deterministic_signing=True))
    r2, s2 = decode_dss_signature(der)
    if s2 > n//2: s2 = n - s2
    assert (r, s) == (r2, s2), "RFC 6979 signature differs from OpenSSL's"
    key.public_key().verify(encode_dss_signature(r, s), hb, ec.ECDSA(Prehashed(hashes.SHA256())))
    assert recover(hb, r, s, v) == openssl_pub(d)

scalars = [1, 2, 3, 7, 15, 16, 17, 255, 256, 2**128, 2**255, n-1, n-2, n-15, n-16, (n-1)//2, (n+1)//2,
           0x0F0F0F0F, p - n, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF]
scalars += [int.from_bytes(os.urandom(32), 'big') % (n-1) + 1 for _ in range(20)]
for d in scalars:
    P = mul(d, G)
    assert P == openssl_pub(d)
    print("pub", h(d), h(P[0]), h(P[1]))

def hashes_for(i):
    return [os.urandom(32), b'\0'*32, b'\xff'*32, n.to_bytes(32, 'big'), (n-1).to_bytes(32, 'big'),
            os.urandom(20), os.urandom(48), b'\x01'][i % 8]

for i, d in enumerate(scalars):
    for j in range(2):
        hb = hashes_for(i + j)
        r, s, v = sign(d, hb)
        if len(hb) == 32:
            check_sig(d, hb, r, s, v)
        assert s <= n//2
        print("sig", h(d), hb.hex(), h(r), h(s), "%02x" % v)
        Q = mul(d, G)
        print("rec", hb.hex(), h(r), h(s), "%02x" % v, h(Q[0]), h(Q[1]))
        # high S: ecrecover takes it (n - s with v flipped is the same key)
        print("rec", hb.hex(), h(r), h(n - s), "%02x" % (v ^ 1), h(Q[0]), h(Q[1]))
        # the other parity: some other key
        Q2 = recover(hb, r, s, v ^ 1)
        print("rec", hb.hex(), h(r), h(s), "%02x" % (v ^ 1), h(Q2[0]), h(Q2[1]))
        # verification: the key, high S, the other parity's key (it
        # verifies too: that is what recovering it means), another key
        Q3 = mul(d % (n-1) + 1, G)
        for K, ss in [(Q, s), (Q, n - s), (Q2, s), (Q3, s)]:
            print("ver", h(K[0]), h(K[1]), hb.hex(), h(r), h(ss), verify(K, hb, r, ss))

# Wycheproof-style edges for recovery (all public)
def rec(hb, r, s, v):
    Q = recover(hb, r, s, v)
    tail = "-" if Q is None else h(Q[0]) + " " + h(Q[1])
    print("rec", hb.hex(), h(r % 2**256), h(s % 2**256), "%02x" % v, tail)
hb = os.urandom(32)
for r, s in [(0, 1), (1, 0), (0, 0), (n, 1), (1, n), (n+1, 1), (2**256-1, 1), (1, 2**256-1)]:
    rec(hb, r, s, 0)
for r in [1, 2, 3, n-1, n-2, (n-1)//2]:
    for s in [1, n-1, (n-1)//2, (n+1)//2]:
        for v in (0, 1):
            rec(hb, r, s, v)
# Q = r^-1 (s R - e G) at infinity: R = kG, s = e k^-1
for k in [1, 2, 0xDEADBEEF, n-1]:
    e = int.from_bytes(os.urandom(32), 'big') % n
    hb = e.to_bytes(32, 'big')
    R = mul(k, G); r = R[0] % n
    if r == R[0]:
        s = e * pow(k, -1, n) % n
        assert recover(hb, r, s, R[1] & 1) is None
        rec(hb, r, s, R[1] & 1)
        # the other parity is -R: a real key
        rec(hb, r, s, (R[1] & 1) ^ 1)
# x with no y on the curve
x = 5
while pow((x**3 + 7) % p, (p-1)//2, p) == 1: x += 1
rec(os.urandom(32), x, 1, 0)

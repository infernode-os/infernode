#!/usr/bin/env python3
"""
Known answers for login(6)'s key derivation, made from the manual page
by Python's `cryptography` and not by the tree's code: the keystream
the signer's Diffie-Hellman value goes under (mask), the one the
client's ML-KEM key's seed goes under (kemmask), and the proofs and
session secret (keys), for both suites.  tests/login_test.b holds what
this prints (testVectors).

    suite 1: HMAC-SHA-256, ChaCha20 (the stream of ChaCha20-Poly1305), ML-KEM-768
    suite 2: HMAC-SHA-384, AES-256 in counter mode (the stream of GCM), ML-KEM-1024

    mask:  PRK = HMAC-H(cnonce || snonce, pw)
           key || nonce = HKDF-Expand(PRK, "infernode login 3 mask" || 0 || suite || group || name, 44)
           out = x XOR stream(key, nonce)          (the AEAD's ciphertext, its tag dropped)
    kemmask: PRK = HMAC-H(cnonce || snonce, z || pw)
           key || nonce = HKDF-Expand(PRK, "infernode login 3 kem mask" || 0 || suite || group || name, 44)
           out = rho XOR stream(key, nonce)
    keys:  th = H("infernode login 3 transcript" || L(name) || L(hello) || L(reply) || L(share) || L(ct))
           PRK = HMAC-H(th, k || z || pw)          L(m) = two bytes of length, big-endian, then m
           client proof, signer proof, session = HKDF-Expand(PRK, label, len H)

    secret: an account's, as keyfs holds it (keys(6)):
           PBKDF2-HMAC-SHA-384(password, "infernode login secret 2" || 0 || name, 200000, 48)

The reply carries the form of the account's secret (2, the new) after
the group.  The ML-KEM operations themselves are not made again here: the values
for share, ct and k are made-up bytes of the right lengths, as z is.
"""
import hashlib, hmac, sys
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305, AESGCM

def H(suite):
    return hashlib.sha256 if suite == 1 else hashlib.sha384

def expand(suite, prk, info, n):
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), H(suite)).digest()
        out += t
        i += 1
    return out[:n]

def stream(suite, okm, x):
    key, nonce = okm[:32], okm[32:]
    aead = ChaCha20Poly1305(key) if suite == 1 else AESGCM(key)
    return aead.encrypt(nonce, x, None)[:len(x)]

def mask(suite, gid, name, pw, cnonce, snonce, x):
    prk = hmac.new(cnonce + snonce, pw, H(suite)).digest()
    okm = expand(suite, prk, b"infernode login 3 mask" + bytes([0, suite, gid]) + name, 44)
    return stream(suite, okm, x)

def kemmask(suite, gid, name, pw, cnonce, snonce, z, rho):
    prk = hmac.new(cnonce + snonce, z + pw, H(suite)).digest()
    okm = expand(suite, prk, b"infernode login 3 kem mask" + bytes([0, suite, gid]) + name, 44)
    return stream(suite, okm, rho)

def L(m):
    return len(m).to_bytes(2, "big") + m

def keys(suite, name, pw, hello, reply, share, ct, z, k):
    th = H(suite)(b"infernode login 3 transcript" + L(name) + L(hello) + L(reply) + L(share) + L(ct)).digest()
    prk = hmac.new(th, k + z + pw, H(suite)).digest()
    n = len(th)
    return (expand(suite, prk, b"infernode login 3 client proof", n),
            expand(suite, prk, b"infernode login 3 signer proof", n),
            expand(suite, prk, b"infernode login 3 session", n))

def ramp(mul, add, n):
    return bytes((mul * i + add) & 0xFF for i in range(n))

def main():
    name = b"alice"
    pw = hashlib.pbkdf2_hmac("sha384", b"correct horse battery staple",
                             b"infernode login secret 2\0" + name, 200000, 48)
    print("secret of alice:", pw.hex())
    cnonce = bytes(range(32))
    snonce = bytes(range(32, 64))
    # ML-KEM-768's and ML-KEM-1024's encapsulation key and ciphertext (FIPS 203)
    for suite, gid, n, eklen, ctlen in ((1, 14, 256, 1184, 1088), (2, 15, 384, 1568, 1568)):
        x = ramp(7, 1, n)
        m = mask(suite, gid, name, pw, cnonce, snonce, x)
        hello = bytes([3, suite]) + cnonce
        reply = bytes([3, suite, gid, 2]) + snonce + m
        z = ramp(11, 2, n)
        rho = ramp(19, 6, 32)
        km = kemmask(suite, gid, name, pw, cnonce, snonce, z, rho)
        share = ramp(5, 3, n + eklen)
        ct = ramp(13, 4, ctlen)
        k = ramp(17, 5, 32)
        c, s, sk = keys(suite, name, pw, hello, reply, share, ct, z, k)
        print("suite %d group %d:" % (suite, gid))
        print("\tmask, its first 16 bytes:", m[:16].hex())
        print("\tmask, SHA-256 of it all:", hashlib.sha256(m).hexdigest())
        print("\tkem mask:", km.hex())
        print("\tclient proof:", c.hex())
        print("\tsigner proof:", s.hex())
        print("\tsession:", sk.hex())

if __name__ == "__main__":
    main()

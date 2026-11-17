#!/usr/bin/env python3
"""
Known answers for login(6)'s key derivation, made from the manual page
by Python's `cryptography` and not by the tree's code: the keystream
the signer's Diffie-Hellman value goes under (mask) and the proofs and
session secret (keys), for both suites.  tests/login_test.b holds what
this prints (testVectors).

    suite 1: HMAC-SHA-256, ChaCha20 (the stream of ChaCha20-Poly1305)
    suite 2: HMAC-SHA-384, AES-256 in counter mode (the stream of GCM)

    mask:  PRK = HMAC-H(cnonce || snonce, pw)
           key || nonce = HKDF-Expand(PRK, "infernode login 2 mask" || 0 || suite || group || name, 44)
           out = x XOR stream(key, nonce)          (the AEAD's ciphertext, its tag dropped)
    keys:  th = H("infernode login 2 transcript" || L(name) || L(hello) || L(reply) || L(share))
           PRK = HMAC-H(th, z || pw)               L(m) = two bytes of length, big-endian, then m
           client proof, signer proof, session = HKDF-Expand(PRK, label, len H)
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

def mask(suite, gid, name, pw, cnonce, snonce, x):
    prk = hmac.new(cnonce + snonce, pw, H(suite)).digest()
    okm = expand(suite, prk, b"infernode login 2 mask" + bytes([0, suite, gid]) + name, 44)
    key, nonce = okm[:32], okm[32:]
    aead = ChaCha20Poly1305(key) if suite == 1 else AESGCM(key)
    return aead.encrypt(nonce, x, None)[:len(x)]

def L(m):
    return len(m).to_bytes(2, "big") + m

def keys(suite, name, pw, hello, reply, share, z):
    th = H(suite)(b"infernode login 2 transcript" + L(name) + L(hello) + L(reply) + L(share)).digest()
    prk = hmac.new(th, z + pw, H(suite)).digest()
    n = len(th)
    return (expand(suite, prk, b"infernode login 2 client proof", n),
            expand(suite, prk, b"infernode login 2 signer proof", n),
            expand(suite, prk, b"infernode login 2 session", n))

def main():
    name = b"alice"
    pw = hashlib.sha256(b"correct horse battery staple").digest()
    cnonce = bytes(range(32))
    snonce = bytes(range(32, 64))
    for suite, gid, n in ((1, 14, 256), (2, 15, 384)):
        x = bytes((7 * i + 1) & 0xFF for i in range(n))
        m = mask(suite, gid, name, pw, cnonce, snonce, x)
        hello = bytes([2, suite]) + cnonce
        reply = bytes([2, suite, gid]) + snonce + m
        share = bytes((5 * i + 3) & 0xFF for i in range(n))
        z = bytes((11 * i + 2) & 0xFF for i in range(n))
        c, s, k = keys(suite, name, pw, hello, reply, share, z)
        print("suite %d group %d:" % (suite, gid))
        print("\tmask, its first 16 bytes:", m[:16].hex())
        print("\tmask, SHA-256 of it all:", hashlib.sha256(m).hexdigest())
        print("\tclient proof:", c.hex())
        print("\tsigner proof:", s.hex())
        print("\tsession:", k.hex())

if __name__ == "__main__":
    main()

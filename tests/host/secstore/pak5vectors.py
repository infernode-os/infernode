#!/usr/bin/env python3
"""
Known answers for secstore version 5's key derivation (secstore(2)'s
PAK5, appl/lib/secstore.b), made from its description by Python's
`hashlib`, `hmac` and `cryptography` and not by the tree's code.
tests/secstore_crypto_test.b holds what this prints (testPak5Vectors).

    tr0 = "secstore5 transcript" || L(version) || L(C) || L(S) || L(m) || L(mu)
    kemmask: PRK = HMAC-SHA-384(SHA-384(tr0), sigma || Hi)
             key || nonce = HKDF-Expand(PRK, "secstore5 kem mask", 44)
             out = seed XOR AES-256-CTR(key, nonce) (GCM's stream, its tag dropped)
    keys:    th = SHA-384(tr0 || L(ek) || L(ct))
             PRK = HMAC-SHA-384(th, k || sigma || Hi)
             server proof, client proof, session = HKDF-Expand(PRK, label, 48)

L(x) is x's length in two bytes, big-endian, then x; version is the
hello's first word, secstore5 (or secstore6, the same exchange with
version 6's verifier).  The ML-KEM
operations are not made here: ek, ct and k are made-up bytes of
ML-KEM-1024's lengths.
"""
import hashlib, hmac
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def L(x):
    return len(x).to_bytes(2, "big") + x

def expand(prk, info, n):
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha384).digest()
        out += t
        i += 1
    return out[:n]

def ramp(mul, add, n):
    return bytes((mul * i + add) & 0xFF for i in range(n))

def main():
    C, S, m, mu = b"alice", b"secstore", b"m-text", b"mu-text"
    sigma, Hi = b"sigma-text", b"Hi-text"
    tr0 = b"secstore5 transcript" + L(b"secstore5") + L(C) + L(S) + L(m) + L(mu)
    prk = hmac.new(hashlib.sha384(tr0).digest(), sigma + Hi, hashlib.sha384).digest()
    okm = expand(prk, b"secstore5 kem mask", 44)
    rho = ramp(19, 6, 32)
    masked = AESGCM(okm[:32]).encrypt(okm[32:], rho, None)[:32]
    ek, ct, k = ramp(5, 3, 1568), ramp(13, 4, 1568), ramp(17, 5, 32)
    th = hashlib.sha384(tr0 + L(ek) + L(ct)).digest()
    prk = hmac.new(th, k + sigma + Hi, hashlib.sha384).digest()
    print("kem mask:", masked.hex())
    print("server proof:", expand(prk, b"secstore5 server proof", 48).hex())
    print("client proof:", expand(prk, b"secstore5 client proof", 48).hex())
    print("session:", expand(prk, b"secstore5 session", 48).hex())

def v6():
    # version 6's root and verifier key (secstore(2) mkfilekey6, mkseckey6),
    # and a file in SGCM3 under that root
    user, pw = b"alice", b"correct horse battery staple"
    root = hashlib.pbkdf2_hmac("sha384", pw, b"secstore filekey 6\0" + user, 200000, 48)
    h6 = hmac.new(root, b"secstore6 verifier", hashlib.sha384).digest()
    salt, nonce = ramp(3, 1, 16), ramp(5, 2, 12)
    key = hmac.new(root, b"secstore file 3" + salt, hashlib.sha384).digest()[:32]
    magic = b"SGCM3\n"
    blob = magic + salt + nonce + AESGCM(key).encrypt(nonce, b"key proto=pass service=x !password=y\n", magic + salt)
    print("root6 of alice:", root.hex())
    print("h6 of alice:", h6.hex())
    print("sgcm3 file:", blob.hex())

if __name__ == "__main__":
    main()
    v6()

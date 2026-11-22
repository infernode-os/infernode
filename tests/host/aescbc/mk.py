#!/usr/bin/env python3
#
# Inputs for tests/host/aescbc_test.sh, made in the directory given, which
# holds "plain" and "enc" (auth/aescbc -e -k pw of it):
#
#   enc.flip      enc with one bit of its ciphertext changed
#   enc.trunc     enc cut at 5000 bytes
#   enc.short     the first 40 bytes of enc
#   legacy        the format before the header: IV, AES-128-CBC(plain || 16 X)
#                 under SHA1("aescbc file" + password)[:16]  (needs Python's
#                 cryptography; left out without it)
#   legacy.cut    legacy cut at 5008 bytes
#   forged        a header-less file made from enc and the 16 bytes its
#                 plaintext begins with, with NO key. CBC: P = D(C) xor Cprev,
#                 so D(C0) is known for the known block, and
#                 (Cprev xor P0 xor M) followed by C0 decrypts to M, for any M.
#                 The last pair says sixteen X's, which was the old format's
#                 whole check.
#
import os, sys, hashlib

d = sys.argv[1]
def rd(n): return open(os.path.join(d, n), "rb").read()
def wr(n, b): open(os.path.join(d, n), "wb").write(bytes(b))

enc = rd("enc")
plain = rd("plain")
f = bytearray(enc); f[48 + 16 * 100 + 3] ^= 0x01
wr("enc.flip", f)
wr("enc.trunc", enc[:5000])
wr("enc.short", enc[:40])

known = plain[:16]
cprev = enc[32:48]      # ciphertext of the random block
c0 = enc[48:64]         # ciphertext of the plaintext's first block
def pair(m):
    return bytes(x ^ y ^ z for x, y, z in zip(cprev, known, m)) + c0
out = bytes(range(16))
for m in (b"echo owned      ", b"; chosen by me; ", b"\n" + b"#" * 15):
    out += pair(m)
out += pair(b"X" * 16)
wr("forged", out)

try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
except ImportError:
    sys.exit(0)
key = hashlib.sha1(b"aescbc file" + b"pw").digest()[:16]
p = plain[:10192]       # whole blocks
iv = bytes(range(16, 32))
e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
leg = iv + e.update(p + b"X" * 16) + e.finalize()
wr("legacy", leg)
wr("plain.legacy", p)
wr("legacy.cut", leg[:5008])

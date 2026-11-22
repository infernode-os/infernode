# Regenerates tests/host/gcm/vectors.txt: AES-GCM known answers from
# OpenSSL, through Python's cryptography package.  One case per line:
#   gcm KEY IV AAD PT CT TAG     (hex; "-" for empty; OpenSSL takes IVs of 8 bytes or more)
# Keys of 16, 24 and 32 bytes; IVs of 12 bytes and of 8, 16, 60 and 128
# (J0 by GHASH); data and AAD at every length to 70 bytes and past a few
# thousand (4097), so each block boundary and partial block is crossed.
# Run: python3 -I tests/host/gcm/gen.py > tests/host/gcm/vectors.txt
import os, random
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
r = random.Random(1)
def rb(n):
    return bytes(r.getrandbits(8) for _ in range(n))
h = lambda b: b.hex() if b else "-"
def case(kl, ivl, al, pl):
    key, iv, aad, pt = rb(kl), rb(ivl), rb(al), rb(pl)
    enc = Cipher(algorithms.AES(key), modes.GCM(iv)).encryptor()
    if aad:
        enc.authenticate_additional_data(aad)
    ct = enc.update(pt) + enc.finalize()
    print("gcm", h(key), h(iv), h(aad), h(pt), h(ct), h(enc.tag))
for kl in (16, 24, 32):
    for pl in list(range(0, 71)) + [255, 256, 257, 1027, 4097]:
        case(kl, 12, r.choice([0, 1, 2, 13, 16, 17, 32, 33]), pl)
    for al in range(0, 50):
        case(kl, 12, al, r.choice([0, 1, 16, 31]))
    for ivl in (8, 16, 60, 128):
        for pl in (0, 1, 16, 33, 100):
            case(kl, ivl, 20, pl)

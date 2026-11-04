# Regenerates tests/host/ecc/vectors.txt: P-256 and P-384 known answers from
# OpenSSL, through Python's cryptography package.  One case per line:
#   pub  BITS d x y                 d*G = (x, y)
#   ecdh BITS d x y z               x-coordinate of d*(x, y) is z
#   sig  BITS x y hash r s          (r, s) is OpenSSL's ECDSA signature of hash by (x, y)
# Run: python3 -I tests/host/ecc/gen.py > tests/host/ecc/vectors.txt
import os, sys, hashlib
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, Prehashed
from cryptography.hazmat.primitives import hashes
curves = {256: (ec.SECP256R1(), 32, 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551, hashes.SHA256()),
          384: (ec.SECP384R1(), 48, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973, hashes.SHA384())}
h = lambda v, nb: format(v, '0%dx' % (2*nb))
for bits, (curve, nb, n, hal) in curves.items():
    scalars = [1, 2, 3, 15, 16, 17, 255, 256, n-1, n-2, n-15, n-16, 2**(8*nb-1) % n, (n-1)//2, 0x0F0F0F0F % n]
    scalars += [int.from_bytes(os.urandom(nb), 'big') % (n-1) + 1 for _ in range(5)]
    scalars_done = []
    for d in scalars:
        scalars_done.append(d)
        k = ec.derive_private_key(d, curve)
        pn = k.public_key().public_numbers()
        # base mult
        print("pub", bits, h(d, nb), h(pn.x, nb), h(pn.y, nb))
        # ECDH against a random peer
        k2 = ec.generate_private_key(curve)
        p2 = k2.public_key().public_numbers()
        ss = k.exchange(ec.ECDH(), k2.public_key())
        print("ecdh", bits, h(d, nb), h(p2.x, nb), h(p2.y, nb), ss.hex())
        # an ECDSA signature by OpenSSL, over a hash of each length
        for hl, halg in [((32, hashes.SHA256()), (48, hashes.SHA384()), (64, hashes.SHA512()))[len(scalars_done) % 3]]:
            dig = os.urandom(hl)
            sig = k.sign(dig, ec.ECDSA(Prehashed(halg)))
            r, s = decode_dss_signature(sig)
            print("sig", bits, h(pn.x, nb), h(pn.y, nb), dig.hex(), h(r, nb), h(s, nb))

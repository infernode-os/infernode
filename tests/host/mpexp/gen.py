#!/usr/bin/env python3
#
# Known answers for libmp's mpexp (tests/host/mpexp_test.sh): each line
# is "b e m r" in hex with r = pow(b, e, m) from Python.  Seeded, so the
# file it makes is the same each time:
#
#	python3 tests/host/mpexp/gen.py > tests/host/mpexp/vectors.txt
#
import random

rng = random.Random(20261104)
out = []

def add(b, e, m):
    out.append("%x %x %x %x" % (b, e, m, pow(b, e, m)))

def odd(bits):
    return rng.getrandbits(bits) | (1 << (bits - 1)) | 1

# small and edge moduli
for m in (1, 3, 5, 7, 0xffffffff, 0x100000001, 0xffffffffffffffff,
          (1 << 64) + 1, (1 << 127) - 1, (1 << 128) + 1, (1 << 255) - 19,
          (1 << 521) - 1, (1 << 1024) + 1, (1 << 2048) - 1):
    bs = (0, 1, 2, m - 1, m, m + 1, 3 * m + 2)
    if m.bit_length() > 600:
        bs = (2, m - 1, 3 * m + 2)
    for b in bs:
        for e in ((1, 2, 3, 65537, (1 << 64) - 1, m - 2 if m > 2 else 1)
                  if m.bit_length() <= 128 else (1, 2, 65537, m - 2)):
            add(b, e, m)

# every size of modulus around the limb boundaries, random operands
for bits in list(range(2, 200)) + [255, 256, 257, 383, 384, 385, 511, 512, 513,
                                   767, 768, 769, 1023, 1024, 1025, 1535, 1536,
                                   2047, 2048, 2049, 3071, 3072, 4095, 4096]:
    m = odd(bits)
    if bits < 200:
        ebs = (1, 7, 22, 23, 64, 89, 90, bits, bits + 33)
    else:
        ebs = (23, 307, 938, bits)
    for ebits in ebs:
        add(rng.getrandbits(bits + 8), rng.getrandbits(ebits) | (1 << (ebits - 1)), m)

# exponents whose windows are zero, one, or all ones
for bits in (1024, 2048):
    m = odd(bits)
    b = rng.getrandbits(bits) % m
    for e in ((1 << 2048), (1 << 2048) + 1, (1 << 2048) - 1,
              int("f0" * 128, 16), int("01" * 256, 16), int("80" + "00" * 255, 16)):
        add(b, e, m)

# even moduli and the general path
for bits in (64, 512, 2048):
    m = rng.getrandbits(bits) | (1 << (bits - 1))
    m &= ~1
    add(rng.getrandbits(bits), rng.getrandbits(bits), m)

print("\n".join(out))

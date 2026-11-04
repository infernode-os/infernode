#!/usr/bin/env python3
# Known answers for libmp's mpexp from Python's pow, one "b e m r" line
# each, in hex (a negative base with a leading -).  Deterministic: the
# same seed every run.  Run by tests/host/mpexp_test.sh.
import random
import sys

r = random.Random(20261104)

def h(x):
    return ('-' if x < 0 else '') + format(abs(x), 'x')

def num(bits):
    return r.getrandbits(bits) | (1 << (bits - 1))

cases = []
# the sizes cryptography uses, and around the digit boundaries
for mb in [3, 31, 32, 33, 64, 65, 127, 160, 255, 256, 257, 512, 1024, 1536, 2048, 3072, 4096]:
    for eb in [1, 2, 17, 32, 33, 160, 256, mb]:
        for _ in range(2 if mb <= 1024 else 1):
            m = num(mb) | 1
            if r.random() < 0.25:
                m &= ~1        # even: the plain path
                m |= 2
            b = r.getrandbits(mb + 8) - (r.getrandbits(mb) if r.random() < 0.2 else 0)
            e = num(eb)
            cases.append((b, e, m))
# edges: modulus 1, base 0, 1, m-1, m, -m, exponents of all ones
for mb in [32, 64, 2048]:
    m = num(mb) | 1
    for b in [0, 1, m - 1, m, -m, -1, m + 1]:
        for e in [1, 2, (1 << 64) - 1, (1 << mb) - 1]:
            cases.append((b, e, m))
for e in [1, 5, (1 << 100) - 1]:
    cases.append((-7, e, 1))
    cases.append((7, e, 1))
m = (1 << 2048) - 1        # all ones, odd
cases.append((3, (1 << 2048) - 3, m))

for b, e, m in cases:
    print(h(b), h(e), h(m), h(pow(b, e, m)))

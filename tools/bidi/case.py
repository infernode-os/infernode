#!/usr/bin/env python3
"""case.py - lib/bidi/case and lib/bidi/casex from the Unicode Character Database.

    tools/bidi/case.py UnicodeData.txt SpecialCasing.txt

lib/bidi/case: "cp upper lower title" in hex for every code point with a
simple case mapping (0 where it has none; title 0 when it is the upper).
lib/bidi/casex: the unconditional one-to-many mappings of SpecialCasing.txt,
"cp kind a b c" (kind 1 upper, 2 lower, 3 title; 0 pads).  The conditional
ones (Final_Sigma, Turkish, Lithuanian) are rules in /dis/lib/bidi.dis,
which reads both at init for text-transform.
"""
import sys

rows = []
for line in open(sys.argv[1], encoding='utf-8'):
    f = line.split(';')
    cp = int(f[0], 16)
    up, lo, ti = f[12], f[13], f[14].strip()
    if not (up or lo or ti):
        continue
    u = int(up, 16) if up else 0
    l = int(lo, 16) if lo else 0
    t = int(ti, 16) if ti else 0
    if t == u:
        t = 0
    rows.append((cp, u, l, t))
rows.sort()
with open('lib/bidi/case', 'w') as out:
    out.write('# simple case mappings from UnicodeData.txt: cp upper lower title (0: none; title 0: as upper)\n')
    for r in rows:
        out.write('%X %X %X %X\n' % r)

xrows = []
for line in open(sys.argv[2], encoding='utf-8'):
    line = line.split('#')[0].strip()
    if not line:
        continue
    f = [x.strip() for x in line.split(';')]
    if len(f) > 4 and f[4]:
        continue        # conditional: a rule in bidi.b
    cp = int(f[0], 16)
    lo = [int(x, 16) for x in f[1].split()]
    ti = [int(x, 16) for x in f[2].split()]
    up = [int(x, 16) for x in f[3].split()]
    for kind, seq in ((1, up), (2, lo), (3, ti)):
        if len(seq) > 1 or (kind == 3 and seq != up):
            seq = (seq + [0, 0, 0])[:3]
            xrows.append((cp, kind, seq[0], seq[1], seq[2]))
xrows.sort()
with open('lib/bidi/casex', 'w') as out:
    out.write('# unconditional one-to-many case mappings from SpecialCasing.txt: cp kind a b c (kind 1 upper, 2 lower, 3 title)\n')
    for r in xrows:
        out.write('%X %X %X %X %X\n' % r)
print(len(rows), 'simple,', len(xrows), 'special')

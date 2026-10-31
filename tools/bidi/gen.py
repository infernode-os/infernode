#!/usr/bin/env python3
"""gen.py - the bidi tables in lib/bidi from the Unicode Character Database.

    tools/bidi/gen.py DerivedBidiClass.txt BidiMirroring.txt BidiBrackets.txt ArabicShaping.txt

Writes lib/bidi/classes (ranges of code points with a Bidi_Class other
than L, "first last class" in hex, merged), lib/bidi/mirror (pairs),
lib/bidi/brackets (open close, as pairs of the opening and closing
code points) and lib/bidi/joining (ranges of code points with a
Joining_Type other than U, as numbers: 1 C, 2 D, 3 R, 4 L, 5 T; T is
derived from the general category as the file's header says).  The
files are read by /dis/lib/bidi.dis at init.
"""
import re, sys, unicodedata

classes, mirror, brackets, shaping = sys.argv[1:5]

def parse(path):
    for line in open(path, encoding='utf-8'):
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        yield [f.strip() for f in line.split(';')]

# classes: the file lists every code point (assigned and the default
# ranges for unassigned ones); keep everything that is not L
ranges = []
for f in parse(classes):
    cp, cls = f[0], f[1]
    if cls == 'L':
        continue
    if '..' in cp:
        a, b = (int(x, 16) for x in cp.split('..'))
    else:
        a = b = int(cp, 16)
    ranges.append((a, b, cls))
ranges.sort()
merged = []
for a, b, cls in ranges:
    if merged and merged[-1][2] == cls and merged[-1][1] + 1 == a:
        merged[-1] = (merged[-1][0], b, cls)
    else:
        merged.append((a, b, cls))
with open('lib/bidi/classes', 'w') as out:
    out.write('# Bidi_Class of code points other than L (UAX #9), from DerivedBidiClass.txt\n')
    for a, b, cls in merged:
        out.write('%X %X %s\n' % (a, b, cls))

with open('lib/bidi/mirror', 'w') as out:
    out.write('# Bidi_Mirroring_Glyph pairs, from BidiMirroring.txt\n')
    for f in parse(mirror):
        out.write('%X %X\n' % (int(f[0], 16), int(f[1], 16)))

with open('lib/bidi/brackets', 'w') as out:
    out.write('# Bidi_Paired_Bracket: opening closing, from BidiBrackets.txt\n')
    for f in parse(brackets):
        if f[2] == 'o':
            out.write('%X %X\n' % (int(f[0], 16), int(f[1], 16)))
jt = {}
for f in parse(shaping):
    jt[int(f[0], 16)] = 'UCDRLT'.index(f[2])
for cp in range(0x110000):
    if cp not in jt and unicodedata.category(chr(cp)) in ('Mn', 'Me', 'Cf') and cp != 0x200C:
        jt[cp] = 5
jranges = []
for cp in sorted(jt):
    t = jt[cp]
    if t == 0:
        continue
    if jranges and jranges[-1][1] == cp - 1 and jranges[-1][2] == t:
        jranges[-1][1] = cp
    else:
        jranges.append([cp, cp, t])
with open('lib/bidi/joining', 'w') as out:
    out.write('# Joining_Type of code points other than U, from ArabicShaping.txt: 1 C, 2 D, 3 R, 4 L, 5 T\n')
    for a, b, t in jranges:
        out.write('%X %X %d\n' % (a, b, t))
print(len(merged), 'class ranges', len(jranges), 'joining ranges')

#!/usr/bin/env python3
"""gen.py - the bidi tables in lib/bidi from the Unicode Character Database.

    tools/bidi/gen.py DerivedBidiClass.txt BidiMirroring.txt BidiBrackets.txt

Writes lib/bidi/classes (ranges of code points with a Bidi_Class other
than L, "first last class" in hex, merged), lib/bidi/mirror (pairs) and
lib/bidi/brackets (open close, as pairs of the opening and closing
code points).  The files are read by /dis/lib/bidi.dis at init.
"""
import re, sys

classes, mirror, brackets = sys.argv[1:4]

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
print(len(merged), 'class ranges')

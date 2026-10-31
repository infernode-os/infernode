#!/usr/bin/env python3
"""linebreak.py - lib/bidi/linebreak from the Unicode Character Database.

    tools/bidi/linebreak.py LineBreak.txt

Writes lib/bidi/linebreak: ranges of code points with a Line_Break
class the layout breaks lines by (UAX #14), "first last class" in hex
with the class as a number; everything else is AL (alphabetic, 0).
Read by /dis/lib/bidi.dis at init.  The numbers match module/bidi.m.
"""
import sys

classes = ['AL', 'ID', 'OP', 'CL', 'CP', 'QU', 'GL', 'NS', 'EX', 'IS', 'BA', 'BB', 'HY',
           'ZW', 'WJ', 'CM', 'ZWJ', 'H2', 'H3', 'JL', 'JV', 'JT', 'EB', 'EM', 'PO', 'PR', 'SY', 'IN', 'NU', 'CJ', 'SP', 'BK', 'CR', 'LF', 'NL']
num = {c: i for i, c in enumerate(classes)}
ranges = []
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.split('#', 1)[0].strip()
    if not line:
        continue
    cp, cls = [f.strip() for f in line.split(';')]
    if cls not in num or cls == 'AL':
        continue
    if '..' in cp:
        a, b = (int(x, 16) for x in cp.split('..'))
    else:
        a = b = int(cp, 16)
    ranges.append((a, b, num[cls]))
ranges.sort()
merged = []
for a, b, c in ranges:
    if merged and merged[-1][2] == c and merged[-1][1] + 1 == a:
        merged[-1] = (merged[-1][0], b, c)
    else:
        merged.append((a, b, c))
with open('lib/bidi/linebreak', 'w') as out:
    out.write('# Line_Break classes other than AL, from LineBreak.txt: first last class, the class as in bidi.m (%s)\n' % ' '.join('%d %s' % (i, c) for i, c in enumerate(classes)))
    for a, b, c in merged:
        out.write('%X %X %d\n' % (a, b, c))
print(len(merged), 'ranges')

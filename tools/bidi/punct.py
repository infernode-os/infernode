#!/usr/bin/env python3
"""punct.py - lib/bidi/punct from the Unicode Character Database.

    tools/bidi/punct.py UnicodeData.txt

Writes lib/bidi/punct: ranges of code points whose General_Category is
punctuation (Pc, Pd, Ps, Pe, Pi, Pf, Po), "first last" in hex, merged.
CSS's ::first-letter takes punctuation before and after the letter
(CSS 2.2 section 5.12.2).  Read by /dis/lib/bidi.dis at init.
"""
import sys

ranges = []
prev = None
for line in open(sys.argv[1], encoding='utf-8'):
    f = line.split(';')
    cp = int(f[0], 16)
    cat = f[2]
    name = f[1]
    if name.endswith(', First>'):
        prev = (cp, cat)
        continue
    if name.endswith(', Last>') and prev:
        if cat.startswith('P'):
            ranges.append((prev[0], cp))
        prev = None
        continue
    if cat.startswith('P'):
        ranges.append((cp, cp))
ranges.sort()
merged = []
for a, b in ranges:
    if merged and merged[-1][1] + 1 == a:
        merged[-1] = (merged[-1][0], b)
    else:
        merged.append((a, b))
with open('lib/bidi/punct', 'w') as out:
    out.write('# code points with General_Category P* (punctuation), from UnicodeData.txt: first last\n')
    for a, b in merged:
        out.write('%X %X\n' % (a, b))
print(len(merged), 'ranges')

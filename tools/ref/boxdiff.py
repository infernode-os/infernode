#!/usr/bin/env python3
"""boxdiff.py - where Charon's layout of a page first parts from Chromium's.

    tools/ref/boxdiff.py [-W width] [-H height] [-t tolerance] url

Lists every element, in document order, whose border box differs from
Chromium's (scripts off) by more than the tolerance (default 2px), and
those one of them has a box and the other none.  The first lines are
the ones to look at: a wrong height early on moves everything after.
"""
import argparse, os, subprocess, sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

def parse(text):
    r = {}
    order = []
    for l in text.splitlines():
        f = l.split()
        if len(f) < 3 or f[0] != 'B':
            continue
        order.append(f[1])
        r[f[1]] = None if f[2] == 'none' else tuple(int(x) for x in f[2:6])
    return order, r

ap = argparse.ArgumentParser()
ap.add_argument('-W', type=int, default=1024)
ap.add_argument('-H', type=int, default=768)
ap.add_argument('-t', type=int, default=2)
ap.add_argument('-n', type=int, default=40)
ap.add_argument('url')
a = ap.parse_args()
ch = subprocess.run(['node', os.path.join(ROOT, 'tools/ref/boxes.js'), a.url, str(a.W), str(a.H)],
                    capture_output=True, text=True, timeout=120).stdout
emu = os.path.join(ROOT, 'emu/Linux/o.emu')
cr = subprocess.run(['setsid', '-w', 'timeout', '120', emu, '-c1', '-pheap=1024m', '-pmain=1024m', '-pimage=1024m', '-r' + ROOT, '/dis/tests/charonshot.dis',
                     '-b', '%dx%d' % (a.W, a.H), '/tmp/boxdiff.img', a.url],
                    capture_output=True, text=True).stdout
corder, c = parse(ch)
_, g = parse(cr)
if not c or not g:
    sys.exit('no boxes: chromium %d, charon %d' % (len(c), len(g)))
n = 0
print('%-60s %-22s %s' % ('element', 'chromium x y w h', 'charon'))
for p in corder:
    if p not in g:
        continue
    x, y = c[p], g[p]
    if x is None and y is None:
        continue
    if x is None or y is None or max(abs(i - j) for i, j in zip(x, y)) > a.t:
        print('%-60s %-22s %s' % (p[-60:], x and ' '.join(map(str, x)) or 'none', y and ' '.join(map(str, y)) or 'none'))
        n += 1
        if n >= a.n:
            break

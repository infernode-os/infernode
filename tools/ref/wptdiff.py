#!/usr/bin/env python3
"""wptdiff.py - one WPT reftest in Charon: test | reference | differences.

    tools/ref/wptdiff.py wptroot test.html [out.png]

Serves wptroot over HTTP, renders the test and its (first) reference at
800x600, prints where they differ, and writes the three side by side.
"""
import os, re, subprocess, sys, threading, functools, http.server, socketserver
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wptrun

ROOT = wptrun.ROOT
root = os.path.abspath(sys.argv[1])
test = os.path.join(root, sys.argv[2])
out = sys.argv[3] if len(sys.argv) > 3 else '/tmp/wptdiff.png'
wptrun.WPTROOT = root
refs, fuzzy, js = wptrun.parse(test)
if not refs:
    sys.exit('no reference')
port = wptrun.serve(root)
ims = []
for f in (test, refs[0][1]):
    png = os.path.join(ROOT, 'tmp', 'wptdiff-%d.png' % len(ims))
    subprocess.run([os.path.join(ROOT, 'tools/charon-shot.sh'),
                    'http://127.0.0.1:%d/%s' % (port, os.path.relpath(f, root)), png, '800x600'],
                   capture_output=True)
    ims.append(np.asarray(Image.open(png).convert('RGB')))
a, b = ims
d = np.abs(a.astype(int) - b.astype(int)).max(axis=2)
ys, xs = np.nonzero(d)
print('reference', os.path.relpath(refs[0][1], root), 'fuzzy', fuzzy)
if len(ys) == 0:
    print('identical')
else:
    print('%d pixels differ, max %d, in x %d..%d y %d..%d' % (len(ys), d.max(), xs.min(), xs.max(), ys.min(), ys.max()))
diff = (a * 0.25 + 191).astype(np.uint8)
diff[d > 0] = (255, 0, 0)
side = np.full((600, 2420, 3), 128, np.uint8)
side[:, :800], side[:, 810:1610], side[:, 1620:] = a, b, diff
Image.fromarray(side).save(out)

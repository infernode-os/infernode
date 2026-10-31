#!/usr/bin/env python3
"""acid2.py - Acid2 in Charon against Chromium.

    tools/ref/acid2.py wptroot [out.png]

Serves the web-platform-tests checkout (which carries acid/acid2),
renders test.html#top at 800x600 in both, and prints how many pixels of
the face (the top-left 400x300) differ.  Anti-aliasing along the nose's
diagonals and in "Hello World!" accounts for about 1400; a broken face is
thousands.  out.png: Charon | Chromium | differences.
"""
import os, subprocess, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wptrun

ROOT = wptrun.ROOT
wptrun.WPTROOT = os.path.abspath(sys.argv[1])
out = sys.argv[2] if len(sys.argv) > 2 else '/tmp/acid2.png'
port = wptrun.serve(wptrun.WPTROOT)
url = 'http://127.0.0.1:%d/acid/acid2/test.html#top' % port
a, c = os.path.join(ROOT, 'tmp', 'acid2-charon.png'), os.path.join(ROOT, 'tmp', 'acid2-chromium.png')
subprocess.run([os.path.join(ROOT, 'tools/charon-shot.sh'), url, a, '800x600'], capture_output=True)
subprocess.run(['node', os.path.join(ROOT, 'tools/ref/shot.js'), url, c, '800', '600'], capture_output=True)
x = np.asarray(Image.open(a).convert('RGB'))[:300, :400].astype(int)
y = np.asarray(Image.open(c).convert('RGB'))[:300, :400].astype(int)
d = np.abs(x - y).max(axis=2)
print('Acid2: %d pixels of the face differ from Chromium' % int((d > 0).sum()))
m = x.copy()
m[d > 0] = (255, 0, 0)
side = np.full((300, 1220, 3), 128, np.uint8)
side[:, :400], side[:, 410:810], side[:, 820:] = x, y, m
Image.fromarray(side).save(out)

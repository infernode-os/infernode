#!/usr/bin/env python3
"""mkvectors.py - the JPEG vectors for tests/readjpg_test.b.

Each vector is written with libjpeg-turbo (jtool, a small C program
against its API: sampling factors, scan scripts, restart intervals,
colour spaces Pillow cannot ask for) or Pillow, and decoded by
libjpeg-turbo with its defaults (islow IDCT, fancy upsampling); that
decoding, made RGB, is kept beside it as a PNG.  Four-component images
are taken as Adobe inverted CMYK and made RGB as readjpg makes them
(r = c*k/255, rounded).  The vectors list gives each name and the
largest colour difference allowed, or "err" for a file readjpg must
refuse.

    JTOOL=~/ref/jpg/jtool python3 mkvectors.py

jtool.c is beside this file: cc -O2 -o jtool jtool.c -ljpeg (with
libjpeg-turbo's headers; the references were made with 2.1.5).
"""
import os, subprocess, struct, sys
from PIL import Image

JTOOL = os.environ.get('JTOOL', os.path.expanduser('~/ref/jpg/jtool'))
HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)

# name: (W, H, colour space, sampling, quality, mode, restart, optimize, arith, seed)
# mode: 0 sequential interleaved, 1 progressive (spectral selection and
# successive approximation), 2 sequential one scan per component,
# 3 progressive without successive approximation
V = {
	'b444':        (64, 48, 'ycc', '1x1,1x1,1x1', 90, 0, '0', 0, 0, 1),
	'b420':        (61, 37, 'ycc', '2x2,1x1,1x1', 85, 0, '0', 0, 0, 2),
	'b422':        (33, 21, 'ycc', '2x1,1x1,1x1', 85, 0, '0', 0, 0, 3),
	'b440':        (33, 21, 'ycc', '1x2,1x1,1x1', 85, 0, '0', 0, 0, 4),
	'b411':        (45, 19, 'ycc', '4x1,1x1,1x1', 85, 0, '0', 0, 0, 5),
	'bmixed':      (29, 23, 'ycc', '2x2,1x2,2x1', 80, 0, '0', 0, 0, 6),
	'b1x1':        (1, 1, 'ycc', '2x2,1x1,1x1', 85, 0, '0', 0, 0, 7),
	'b17x9':       (17, 9, 'ycc', '2x2,1x1,1x1', 85, 0, '0', 0, 0, 8),
	'b3x5':        (3, 5, 'ycc', '2x2,1x1,1x1', 85, 0, '0', 0, 0, 9),
	'b4x4-422':    (4, 4, 'ycc', '2x1,1x1,1x1', 85, 0, '0', 0, 0, 10),
	'bq5':         (48, 32, 'ycc', '2x2,1x1,1x1', 5, 0, '0', 0, 0, 11),
	'bq100':       (48, 32, 'ycc', '2x2,1x1,1x1', 100, 0, '0', 1, 0, 12),
	'bopt':        (64, 40, 'ycc', '2x2,1x1,1x1', 75, 0, '0', 1, 0, 13),
	'bgray':       (50, 30, 'gray', '1x1', 80, 0, '0', 0, 0, 14),
	'brgb':        (40, 30, 'rgb', '1x1,1x1,1x1', 85, 0, '0', 0, 0, 15),
	'bcmyk':       (30, 20, 'cmyk', '1x1,1x1,1x1,1x1', 90, 0, '0', 0, 0, 16),
	'bycck':       (30, 20, 'ycck', '2x2,1x1,1x1,2x2', 90, 0, '0', 0, 0, 17),
	'brst1':       (61, 37, 'ycc', '2x2,1x1,1x1', 85, 0, '1', 0, 0, 18),
	'brst2r':      (61, 45, 'ycc', '2x2,1x1,1x1', 85, 0, '2r', 0, 0, 19),
	'bmulti':      (61, 37, 'ycc', '2x2,1x1,1x1', 85, 2, '0', 0, 0, 20),
	'bmulti-rst':  (61, 37, 'ycc', '2x2,1x1,1x1', 85, 2, '5', 0, 0, 21),
	'p420':        (120, 90, 'ycc', '2x2,1x1,1x1', 85, 1, '0', 1, 0, 22),
	'p444':        (96, 64, 'ycc', '1x1,1x1,1x1', 85, 1, '0', 1, 0, 23),
	'p422':        (77, 45, 'ycc', '2x1,1x1,1x1', 85, 1, '0', 1, 0, 24),
	'p440':        (45, 77, 'ycc', '1x2,1x1,1x1', 85, 1, '0', 1, 0, 25),
	'p333x41':     (333, 41, 'ycc', '2x2,1x1,1x1', 70, 1, '0', 1, 0, 26),
	'pgray':       (70, 50, 'gray', '1x1', 85, 1, '0', 1, 0, 27),
	'pspectral':   (88, 56, 'ycc', '2x2,1x1,1x1', 85, 3, '0', 1, 0, 28),
	'pq5':         (64, 48, 'ycc', '2x2,1x1,1x1', 5, 1, '0', 1, 0, 29),
	'pq100':       (64, 48, 'ycc', '2x2,1x1,1x1', 100, 1, '0', 1, 0, 30),
	'prst3':       (90, 60, 'ycc', '2x2,1x1,1x1', 85, 1, '3', 1, 0, 31),
	'prst1r':      (90, 60, 'ycc', '2x2,1x1,1x1', 85, 1, '1r', 1, 0, 32),
	'pcmyk':       (30, 20, 'cmyk', '1x1,1x1,1x1,1x1', 90, 1, '0', 1, 0, 33),
	'p1x1':        (1, 1, 'ycc', '2x2,1x1,1x1', 85, 1, '0', 1, 0, 34),
	'pmixed':      (29, 23, 'ycc', '2x2,1x2,2x1', 80, 1, '0', 1, 0, 35),
	'arith':       (32, 24, 'ycc', '2x2,1x1,1x1', 85, 0, '0', 0, 1, 36),
}
ERR = {'arith'}

def run(*a):
	subprocess.run([str(x) for x in a], check=True, capture_output=True)

def ref(jpg, png):
	run(JTOOL, 'dec', jpg, '/tmp/mkv.pnm')
	d = open('/tmp/mkv.pnm', 'rb').read()
	if d.startswith(b'P7'):
		head, rest = d.split(b'\n', 2)[1], d.split(b'\n', 2)[2]
		w, h, _ = (int(x) for x in head.split())
		px = bytearray()
		for i in range(w*h):
			c, m, y, k = rest[4*i:4*i+4]
			for v in (c, m, y):
				t = v*k + 128
				px.append(((t >> 8) + t) >> 8)
		Image.frombytes('RGB', (w, h), bytes(px)).save(png)
	else:
		Image.open('/tmp/mkv.pnm').save(png)

lines = []
for name, (w, h, cs, samp, q, mode, rst, opt, arith, seed) in V.items():
	run(JTOOL, 'enc', name + '.jpg', w, h, cs, samp, q, mode, rst, opt, arith, seed)
	if name in ERR:
		lines.append('%s err' % name)
		continue
	ref(name + '.jpg', name + '.png')
	lines.append('%s 0' % name)

# Pillow's own progressive (libjpeg's default scan script) and baseline
im = Image.open('p420.png').resize((96, 72))
im.save('pil-prog.jpg', quality=75, progressive=True, subsampling=2)
ref('pil-prog.jpg', 'pil-prog.png')
lines.append('pil-prog 0')
im.save('pil-base.jpg', quality=90, subsampling=1, optimize=True)
ref('pil-base.jpg', 'pil-base.png')
lines.append('pil-base 0')

# 12-bit samples: refused, not misread (the precision byte of a baseline frame)
d = bytearray(open('b420.jpg', 'rb').read())
i = d.index(b'\xff\xc0')
d[i+4] = 12
open('p12bit.jpg', 'wb').write(d)
lines.append('p12bit err')
# lossless: refused
d = bytearray(open('b420.jpg', 'rb').read())
d[i+1] = 0xC3
open('lossless.jpg', 'wb').write(d)
lines.append('lossless err')

open('vectors', 'w').write('\n'.join(lines) + '\n')
total = sum(os.path.getsize(f) for f in os.listdir('.') if f.endswith(('.jpg', '.png')))
print(len(lines), 'vectors,', total, 'bytes')

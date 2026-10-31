#!/usr/bin/env python3
#
# charon-wpt-score.py — score one rendered fixture PNG (as written by
# p9img2png.py: 8-bit RGB, filter 0) for tools/charon-wpt.sh.
#
# PASS: no red pixels and at least MINGREEN green ones.
#
import sys, struct, zlib
MINGREEN = 9000
def pixels(path):
    d = open(path, 'rb').read()
    off = 8; idat = b''
    while off < len(d):
        n, = struct.unpack('>I', d[off:off+4]); t = d[off+4:off+8]
        if t == b'IHDR': w, h = struct.unpack('>II', d[off+8:off+16])
        if t == b'IDAT': idat += d[off+8:off+8+n]
        off += 12 + n
    raw = zlib.decompress(idat)
    return w, h, raw
w, h, raw = pixels(sys.argv[1])
red = green = 0
stride = 1 + 3*w
for y in range(h):
    row = raw[y*stride+1:(y+1)*stride]
    for x in range(0, 3*w, 3):
        r, g, b = row[x], row[x+1], row[x+2]
        if r > 200 and g < 60 and b < 60: red += 1
        elif g > 100 and r < 60 and b < 60: green += 1
ok = red == 0 and green >= MINGREEN
print(f"{'PASS' if ok else 'FAIL'} red={red} green={green}")

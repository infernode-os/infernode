#!/bin/sh
#
# imgfilters_test.sh — i420(1), topng(1) and tojpg(1): a picture from a
# video frame, through filters that know nothing of where it came from.
#
# A frame of colour bars, I420 as a feed serves it, is turned into
# image(6) by i420 and checked pixel by pixel against BT.601 full range;
# topng's PNG is decoded (zlib; its rows are unfiltered) and must be the
# same pixels, and an x8r8g8b8 image(6) through the draw device too; tojpg's JPEG must be a JPEG of the right size, and with
# PIL, decoded, within 16 of them (JPEG's error at quality 90). A short frame and a bad size
# are refused.
#
# Runs on any emulator build, headless included. Needs python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "imgfilters_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null || { echo "imgfilters_test: SKIP (no python3)"; exit 77; }

dir=$(mktemp -d "$ROOT/.imgfilters.XXXXXX")
trap 'rm -rf "$dir"' EXIT
name=${dir##*/}
W=64
H=48

# an image(6) of other channels, x8r8g8b8, for topng's draw-device path
python3 - "$dir/x8.bit" <<'PY'
import sys
w, h = 8, 4
px = bytearray()
for y in range(h):
    for x in range(w):
        px += bytes([30*x % 256, 60, 200, 0])	# blue green red x
open(sys.argv[1], "wb").write(b"%11s %11d %11d %11d %11d " % (b"x8r8g8b8", 0, 0, w, h) + px)
PY

python3 - "$dir/bars.i420" $W $H <<'PY'
import sys
f, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
# eight bars: white yellow cyan green magenta red blue black, as RGB
bars = [(235,235,235),(235,235,16),(16,235,235),(16,235,16),(235,16,235),(235,16,16),(16,16,235),(16,16,16)]
def ycc(r, g, b):
    y = round(0.299*r + 0.587*g + 0.114*b)
    cb = round(128 - 0.168736*r - 0.331264*g + 0.5*b)
    cr = round(128 + 0.5*r - 0.418688*g - 0.081312*b)
    return y, cb, cr
Y = bytearray(); U = bytearray(); V = bytearray()
for y in range(h):
    for x in range(w):
        Y.append(ycc(*bars[x*8//w])[0])
for y in range(h//2):
    for x in range(w//2):
        _, cb, cr = ycc(*bars[(2*x)*8//w])
        U.append(cb); V.append(cr)
open(f, "wb").write(bytes(Y + U + V))
PY

with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
i420 $W $H < /$name/bars.i420 > /$name/bars.bit
topng < /$name/bars.bit > /$name/bars.png
tojpg -q 90 < /$name/bars.bit > /$name/bars.jpg
read 100 < /$name/bars.i420 | i420 $W $H > /$name/short.bit >[2] /$name/short.err
i420 0 $H < /$name/bars.i420 > /dev/null >[2] /$name/size.err
topng < /$name/x8.bit > /$name/x8.png >[2] /$name/x8.err
echo halt > /dev/sysctl" >/dev/null 2>&1

python3 - "$dir" $W $H <<'PY'
import sys, zlib, struct, os
d, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fail = 0
def check(name, ok, why=""):
    global fail
    print(("PASS: " if ok else "FAIL: ") + name + ("" if ok else ": " + why))
    fail |= not ok
# what each pixel should be: the I420 back to RGB, full-range BT.601, as i420 does it
raw = open(os.path.join(d, "bars.i420"), "rb").read()
cw, ch = (w+1)//2, (h+1)//2
def cl(v): return max(0, min(255, v))
def td(a, b): return -(-a // b) if a < 0 else a // b	# Limbo's /: toward zero
want = []
for y in range(h):
    for x in range(w):
        Y = raw[y*w+x]; cb = raw[w*h + (y//2)*cw + x//2] - 128; cr = raw[w*h + cw*ch + (y//2)*cw + x//2] - 128
        r = Y + td(91881*cr + 32768, 65536)
        g = Y - td(22554*cb + 46802*cr - 32768, 65536)
        b = Y + td(116130*cb + 32768, 65536)
        want.append((cl(r), cl(g), cl(b)))
# image(6): header, then blue, green, red
bit = open(os.path.join(d, "bars.bit"), "rb").read()
hdr = bit[:60].decode()
check("i420 writes an r8g8b8 image(6) of the frame's size", hdr.split() == ["r8g8b8", "0", "0", str(w), str(h)], hdr)
px = bit[60:]
got = [(px[3*i+2], px[3*i+1], px[3*i]) for i in range(w*h)]
check("i420's pixels are the frame's colours", got == want, "first difference at %s" % next((i for i in range(w*h) if got[i] != want[i]), None))
# the eight bars' middles are the colours they were made from, within the round trip
bars = [(235,235,235),(235,235,16),(16,235,235),(16,235,16),(235,16,235),(235,16,16),(16,16,235),(16,16,16)]
worst = max(abs(a-b) for k in range(8) for a, b in zip(got[(h//2)*w + (2*k+1)*w//16], bars[k]))
check("each bar's colour within 3 of what was made (got %d)" % worst, worst <= 3)
# PNG: decode, compare
png = open(os.path.join(d, "bars.png"), "rb").read()
check("topng writes a PNG", png[:8] == b"\x89PNG\r\n\x1a\n")
pos, idat, pw = 8, b"", None
while pos < len(png):
    n = struct.unpack(">I", png[pos:pos+4])[0]; kind = png[pos+4:pos+8]
    if kind == b"IHDR": pw, ph = struct.unpack(">II", png[pos+8:pos+16])
    if kind == b"IDAT": idat += png[pos+8:pos+8+n]
    pos += 12 + n
check("the PNG is the picture's size", (pw, ph) == (w, h), "%s" % ((pw, ph),))
rows = zlib.decompress(idat)
pp = []
for y in range(h):
    row = rows[y*(3*w+1):(y+1)*(3*w+1)]
    pp += [(row[1+3*x], row[2+3*x], row[3+3*x]) for x in range(w)]
check("the PNG's pixels are the picture's, exactly", pp == got)
# JPEG: its markers and size; with PIL, its pixels
jpg = open(os.path.join(d, "bars.jpg"), "rb").read()
check("tojpg writes a JPEG", jpg[:2] == b"\xff\xd8" and jpg[-2:] == b"\xff\xd9")
i = jpg.find(b"\xff\xc0")
jh, jw = struct.unpack(">HH", jpg[i+5:i+9]) if i >= 0 else (0, 0)
check("the JPEG is baseline, of the picture's size", (jw, jh) == (w, h), "%s" % ((jw, jh),))
try:
    from PIL import Image
    im = Image.open(os.path.join(d, "bars.jpg")).convert("RGB")
    jp = list(im.getdata())
    err = max(abs(a-b) for k in range(8) for a, b in zip(jp[(h//2)*w + (2*k+1)*w//16], got[(h//2)*w + (2*k+1)*w//16]))
    check("the JPEG's bar colours within 16 of the picture's (got %d)" % err, err <= 16)
except ImportError:
    print("(no PIL: the JPEG's pixels not checked)")
# an image(6) of other channels through the draw device
x8 = open(os.path.join(d, "x8.png"), "rb").read()
k = x8.find(b"IDAT")
if k < 0:
    check("topng takes an x8r8g8b8 image(6) (the draw device)", False, open(os.path.join(d, "x8.err"), "rb").read().decode(errors="replace"))
else:
    n = struct.unpack(">I", x8[k-4:k])[0]
    rw = zlib.decompress(x8[k+4:k+4+n])
    first = [tuple(rw[1+3*x:4+3*x]) for x in range(3)]
    check("topng takes an x8r8g8b8 image(6), through the draw device", first == [(200,60,0),(200,60,30),(200,60,60)], "%s" % first)
check("a short frame is refused", b"short frame" in open(os.path.join(d, "short.err"), "rb").read())
check("a size of 0 is refused", b"bad size" in open(os.path.join(d, "size.err"), "rb").read())
sys.exit(fail)
PY

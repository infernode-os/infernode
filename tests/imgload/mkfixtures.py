# Fixtures for tests/imgload_test.b: 8x8, top half red, bottom half
# blue (grey formats: white over black; XBM black over white).
# Needs Pillow 11.2 or later (AVIF): python3 mkfixtures.py .
import sys
from PIL import Image
d = sys.argv[1]
rgb = Image.new("RGB", (8, 8), (0, 0, 255))
rgb.paste((255, 0, 0), (0, 0, 8, 4))
grey = Image.new("L", (8, 8), 0)
grey.paste(255, (0, 0, 8, 4))
rgb.save(d + "/rb.png")
rgb.save(d + "/rb.jpg", quality=95, subsampling=0)
rgb.convert("P").save(d + "/rb.gif")
rgb.save(d + "/rb.webp", lossless=True)
rgb.save(d + "/rbl.webp", quality=95)
rgb.save(d + "/rb.avif", quality=95)
rgb.save(d + "/rb.ppm")
grey.save(d + "/wb.pgm")
# XBM by hand: a set bit is foreground (black), so black over white
open(d + "/bw.xbm", "w").write("#define bw_width 8\n#define bw_height 8\nstatic char bw_bits[] = {\n 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00 };\n")
open(d + "/rb.pic", "wb").write(b"TYPE=dump\nWINDOW=0 0 8 8\nNCHAN=3\nCHAN=rgb\n\n" + rgb.tobytes())
open(d + "/rb.svg", "w").write('''<?xml version="1.0" encoding="UTF-8"?>
<!-- top half red, bottom half blue -->
<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
<rect x="0" y="0" width="8" height="4" fill="#ff0000"/>
<rect x="0" y="4" width="8" height="4" fill="#0000ff"/>
</svg>
''')

# For tests/readwebp_test.b: WebP of each kind the decoder reads, and
# in webp.md5 what libwebp (through Pillow) decodes each to: its size,
# its frames, and the MD5 of every frame's R, G, B and A planes in turn.
import hashlib, math, random
from PIL import ImageDraw
random.seed(7)
ph = Image.new("RGB", (45, 37))
px = ph.load()
for y in range(37):
	for x in range(45):
		n = random.randrange(-24, 25)
		px[x, y] = (max(0, min(255, int(128 + 100*math.sin(x/5.0)) + n)),
			max(0, min(255, 6*y + n)), max(0, min(255, 255 - 5*x + n)))
dr = ImageDraw.Draw(ph)
dr.ellipse([8, 6, 30, 28], fill=(250, 240, 20))
dr.line([0, 36, 44, 0], fill=(0, 0, 0), width=2)
pha = ph.convert("RGBA")
pa = pha.load()
for y in range(37):
	for x in range(45):
		r, g, b, _ = pa[x, y]
		dist = ((x - 22)**2 + (y - 18)**2) ** 0.5
		pa[x, y] = (r, g, b, 0 if 30 < x < 40 and 5 < y < 15 else max(0, min(255, int(255 - 8*dist))))
pal = Image.new("RGB", (37, 23), (10, 20, 30))
dr = ImageDraw.Draw(pal)
dr.rectangle([3, 3, 20, 15], fill=(200, 0, 0))
dr.ellipse([15, 5, 35, 21], fill=(0, 180, 60))
dr.line([0, 22, 36, 0], fill=(255, 255, 255))
ph.save(d + "/webp-lossy.webp", quality=60)
pha.save(d + "/webp-lossya.webp", quality=60, alpha_quality=80)
pha.save(d + "/webp-lossless.webp", lossless=True, quality=100, method=6)
pal.save(d + "/webp-pal.webp", lossless=True)
# An animation put together by hand, for what encoders seldom write:
# a frame disposed of to the background, frames smaller than the
# canvas, blended over what is left
import io, struct
def chunk(id, data):
	return id + struct.pack("<I", len(data)) + data + b"\0" * (len(data) & 1)
def vp8l(im):
	b = io.BytesIO()
	im.save(b, "WEBP", lossless=True, exact=True)
	return b.getvalue()[12:]	# its VP8L chunk
def anmf(x, y, im, ms, blend, dispose):
	w, h = im.size
	hdr = struct.pack("<I", x//2)[:3] + struct.pack("<I", y//2)[:3] + struct.pack("<I", w-1)[:3] + \
		struct.pack("<I", h-1)[:3] + struct.pack("<I", ms)[:3] + bytes([(0 if blend else 2) | dispose])
	return chunk(b"ANMF", hdr + vp8l(im))
f1 = Image.new("RGBA", (30, 20), (40, 90, 200, 255))
f2 = Image.new("RGBA", (14, 10), (0, 0, 0, 0))
ImageDraw.Draw(f2).ellipse([0, 0, 13, 9], fill=(255, 220, 0, 160))
f3 = Image.new("RGBA", (12, 12), (200, 30, 30, 90))
ImageDraw.Draw(f3).rectangle([3, 3, 8, 8], fill=(10, 200, 10, 255))
body = b"WEBP" + chunk(b"VP8X", bytes([0x12, 0, 0, 0]) + struct.pack("<I", 30-1)[:3] + struct.pack("<I", 20-1)[:3]) + \
	chunk(b"ANIM", struct.pack("<IH", 0xffffffff, 0)) + \
	anmf(0, 0, f1, 50, False, 0) + anmf(4, 2, f2, 60, True, 1) + anmf(10, 6, f3, 70, True, 0)
open(d + "/webp-anim.webp", "wb").write(b"RIFF" + struct.pack("<I", len(body)) + body)
from PIL import ImageSequence
with open(d + "/webp.md5", "w") as out:
	for name in ("webp-lossy", "webp-lossya", "webp-lossless", "webp-pal", "webp-anim"):
		im = Image.open(d + "/" + name + ".webp")
		h = hashlib.md5()
		n = 0
		for fr in ImageSequence.Iterator(im):
			for c in fr.convert("RGBA").split():
				h.update(c.tobytes())
			n += 1
		out.write("%s %d %d %d %s\n" % (name, im.size[0], im.size[1], n, h.hexdigest()))

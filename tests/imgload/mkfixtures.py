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

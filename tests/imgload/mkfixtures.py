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
# Alpha that is not RGBA's: grey and alpha (Apple's logos), white over
# black at half alpha; a palette whose tRNS has a translucent entry and
# two transparent ones (pngquant's icons): red, opaque, over blue at
# alpha 128, the right column transparent (index 2), the bottom row
# transparent too (index 3)
la = Image.new("LA", (8, 8), (0, 128))
la.paste((255, 255), (0, 0, 8, 4))
la.save(d + "/wbla.png")
pa = Image.new("P", (8, 8), 1)
pa.putpalette([255, 0, 0, 0, 0, 255, 0, 255, 0, 255, 255, 0])
pa.paste(0, (0, 0, 8, 4))
pa.paste(2, (7, 0, 8, 8))
pa.paste(3, (0, 7, 8, 8))
pa.save(d + "/rbpa.png", transparency=bytes([255, 128, 0, 0]))
open(d + "/refs.svg", "w").write('''<?xml version="1.0" encoding="UTF-8"?>
<!-- 40 by 10, four cells: a red square clipped to its left half (the
clip path after it), a green square with its middle masked out, a blue
square drawn by use, a yellow one by use of a symbol -->
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" height="10">
<rect x="0" y="0" width="10" height="10" fill="#ff0000" clip-path="url(#left)"/>
<defs>
<mask id="hole"><rect x="10" y="0" width="10" height="10" fill="#ffffff"/><rect x="13" y="3" width="4" height="4" fill="#000000"/></mask>
<rect id="sq" width="10" height="10" fill="#0000ff"/>
</defs>
<rect x="10" y="0" width="10" height="10" fill="#00ff00" mask="url(#hole)"/>
<use xlink:href="#sq" x="20" y="0"/>
<symbol id="sym" viewBox="0 0 1 1"><rect width="1" height="1" fill="#ffff00"/></symbol>
<use href="#sym" x="30" y="0" width="10" height="10"/>
<clipPath id="left"><rect x="0" y="0" width="5" height="10"/></clipPath>
</svg>
''')
# A GIF whose transparent index follows a colour, across each row: red,
# clear, white, clear (paulgraham.com's titles): the clear pixels clear
gt = Image.new("P", (4, 1), 0)
gt.putpalette([255, 0, 0, 0, 0, 0, 255, 255, 255])
gt.putpixel((1, 0), 1)
gt.putpixel((2, 0), 2)
gt.putpixel((3, 0), 1)
gt.save(d + "/clear.gif", transparency=1)

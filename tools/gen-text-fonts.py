#!/usr/bin/env python3
#
# gen-text-fonts.py — Xenith's reading faces as Inferno bitmap fonts.
#
# Renders Go, Go Mono (fonts/go) and Noto Serif (fonts/noto) at 14, 16
# and 18 pixels to the em, and at twice those into k8 subfonts, one per 256-codepoint block,
# and writes fonts/combined/{go,gomono,serif}.N.font. See
# docs/THEME-RESEARCH.md for why these faces and sizes.
#
# Renders Go Medium, Bold, Italic and Bold Italic the same way, as
# fonts/combined/go.{medium,bold,italic,bolditalic}.N.font, at those
# sizes and 22 (and 44). A program finds a style by putting its name
# before the size in the regular face's file name.
#
# A font file sends a character to the first range holding it and does
# not fall through when the subfont lacks the glyph, so each manifest
# lists only the runs the face covers (with the offset of each run into
# its block's subfont), then DejaVu's manifest of the nearest size for
# everything else (libdraw aligns baselines across sizes).
#
# Line height is 1.25 em, or more if the faces' Latin-1 letters need it,
# the extra split above and below; every face at a size has the same
# height and ascent, and every subfont is rendered to them.
#
# Needs FreeType (for fonts/dejavu/ttf2subfont) and fontTools. Go's
# TrueType files are in fonts/go; Noto Serif's is not kept (fonts/noto
# ignores its sources), so fetch it first:
#   curl -L -o fonts/noto/NotoSerif-Regular.ttf \
#	https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoSerif/hinted/ttf/NotoSerif-Regular.ttf
#
# Usage, from the root of the tree:
#   cc -O2 -o /tmp/ttf2subfont fonts/dejavu/ttf2subfont.c \
#	`pkg-config --cflags --libs freetype2`
#   python3 tools/gen-text-fonts.py /tmp/ttf2subfont

import math
import os
import subprocess
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.ttLib import TTFont

# The faces Font chooses between: 14, 16 and 18 to the em, and twice
# those for 2x displays (Xenith binds them over 14, 16 and 18 when
# $displayscale is 2)
TEXT = [14, 16, 18, 28, 32, 36]
# Go's other weights and slopes, for programs that set a document
# rather than edit text (Xenith's Render): the text sizes, and 22 (44)
# for first-level headings. Not offered by Font.
STYLED = [14, 16, 18, 22, 28, 32, 36, 44]
FACES = [
	# name, source, subfont directory, manifest name, DejaVu fallback
	# family (combined/<family>.N.font), sizes
	("Go", "go/Go-Regular.ttf", "go/Go", "go", "unicode.sans", TEXT),
	("GoMono", "go/Go-Mono.ttf", "go/GoMono", "gomono", "unicode.sans", TEXT),
	("NotoSerif", "noto/NotoSerif-Regular.ttf", "noto/NotoSerif", "serif", "unicode.sans", TEXT),
	("GoMedium", "go/Go-Medium.ttf", "go/GoMedium", "go.medium", "unicode.sans.bold", STYLED),
	("GoBold", "go/Go-Bold.ttf", "go/GoBold", "go.bold", "unicode.sans.bold", STYLED),
	("GoItalic", "go/Go-Italic.ttf", "go/GoItalic", "go.italic", "unicode.sans", STYLED),
	("GoBoldItalic", "go/Go-Bold-Italic.ttf", "go/GoBoldItalic", "go.bolditalic", "unicode.sans.bold", STYLED),
]
# blocks (high bytes) to take from the face when it has them
BLOCKS = {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x1E, 0x1F,
	0x20, 0x21, 0x22, 0x23, 0x25, 0x26, 0xFB}
# the DejaVu sizes there are; the gaps are filled from the largest
# no larger than the face
DEJAVU = [12, 14, 18, 24, 32, 48]


def main():
	if len(sys.argv) != 2:
		sys.exit("usage: gen-text-fonts.py ttf2subfont")
	t2s = os.path.abspath(sys.argv[1])
	os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fonts"))
	# One box for every face, so Font changes face and not line height:
	# as high and as deep as their Latin-1 letters reach (rounded up;
	# ttf2subfont's own metrics round down and cut descenders short).
	top = bottom = 0
	for name, ttf, outdir, man, fam, sizes in FACES:
		tt = TTFont(ttf)
		upm = tt["head"].unitsPerEm
		gs = tt.getGlyphSet()
		cmap = tt.getBestCmap()
		for c in range(0x20, 0x100):
			if c in cmap:
				pen = BoundsPen(gs)
				gs[cmap[c]].draw(pen)
				if pen.bounds:
					top = max(top, pen.bounds[3] / upm)
					bottom = max(bottom, -pen.bounds[1] / upm)
	for name, ttf, outdir, man, fam, sizes in FACES:
		os.makedirs(outdir, exist_ok=True)
		cps = sorted(c for c in TTFont(ttf).getBestCmap()
			if (c >> 8) in BLOCKS and c >= 0x20)
		blocks = sorted(set(c >> 8 for c in cps))
		for size in sizes:
			fallback = max(z for z in DEJAVU if z <= size)
			a = math.ceil(top * size)
			d = math.ceil(bottom * size)
			height = max(a + d, round(1.25 * size))
			ascent = a + (height - a - d) // 2
			lines = ["%d\t%d" % (height, ascent),
				"0x0000\t0x001F\t../10646/9x15/9x15.2400-2426"]
			for b in blocks:
				base = b << 8
				sub = "%s/%s.%d.%04X" % (outdir, name, size, base)
				subprocess.run([t2s, "-p", str(size), "-r", "72",
					"-start", "0x%04X" % base, "-end", "0x%04X" % (base + 0xFF),
					"-height", str(height), "-ascent", str(ascent),
					ttf, sub], check=True, capture_output=True)
				run = [c for c in cps if c >> 8 == b]
				s = p = run[0]
				for c in run[1:] + [None]:
					if c is not None and c == p + 1:
						p = c
						continue
					off = s - base
					lines.append("0x%04X\t0x%04X\t%s../%s" %
						(s, p, "%d\t" % off if off else "", sub))
					if c is not None:
						s = p = c
			with open("combined/%s.%d.font" % (fam, fallback)) as f:
				lines += f.read().splitlines()[2:]
			with open("combined/%s.%d.font" % (man, size), "w") as f:
				f.write("\n".join(lines) + "\n")
			print("%s.%d.font: height %d ascent %d" % (man, size, height, ascent))


main()

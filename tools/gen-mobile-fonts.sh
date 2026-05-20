#!/bin/bash
#
# gen-mobile-fonts.sh — generate larger DejaVu subfonts for hellaphone.
#
# The prebuilt sizes in fonts/dejavu/ stop at 24pt. The Lucifer-on-
# Android user feedback is that even bound-to-24 the text is still
# small at 388dpi. Generate additional sizes (32pt by default;
# extend at the call site if more are wanted) so the boot-mobile.sh
# binds can target a larger ceiling.
#
# Usage (from repo root):
#   ./tools/gen-mobile-fonts.sh           # generates 32pt
#   ./tools/gen-mobile-fonts.sh 32 40     # generates multiple sizes
#
# Prereqs:
#   * fonts/dejavu/ttf2subfont built (run `mk` in fonts/dejavu first,
#     or build with cc -O2 ttf2subfont.c -lfreetype)
#   * DejaVu TTFs reachable. Defaults to the Ubuntu/Debian path
#     /usr/share/fonts/truetype/dejavu/ ; override via DEJAVU_DIR env.
#
# Outputs:
#   fonts/dejavu/{DejaVuSans,DejaVuSansBold,DejaVuSansMono}/
#       <face>.<size>.<block>          (binary subfont per Unicode block)
#   fonts/combined/
#       unicode.sans.<size>.font
#       unicode.sans.bold.<size>.font
#       unicode.mono.<size>.font       (NEW — proportional-mono mobile tier)
#       unicode.<size>.font            (mono alias, used by wm/shell etc.)
#
# The manifest files are derived from the existing 24pt versions —
# same fallback layout, just the DejaVu blocks bumped to the new size.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/fonts/dejavu"

: "${DEJAVU_DIR:=/usr/share/fonts/truetype/dejavu}"
SANS_TTF="$DEJAVU_DIR/DejaVuSans.ttf"
BOLD_TTF="$DEJAVU_DIR/DejaVuSans-Bold.ttf"
MONO_TTF="$DEJAVU_DIR/DejaVuSansMono.ttf"

for f in "$SANS_TTF" "$BOLD_TTF" "$MONO_TTF"; do
	if [ ! -f "$f" ]; then
		echo "::error::missing TTF: $f (set DEJAVU_DIR to override)" >&2
		exit 1
	fi
done

if [ ! -x ./ttf2subfont ]; then
	echo "::error::./ttf2subfont not built. Run `mk` in fonts/dejavu first." >&2
	exit 1
fi

# DejaVu blocks the existing 12/14/18/24pt subfonts cover. Must match
# the .font manifest entries — keep in sync if the manifest gets new
# blocks.
BLOCKS="0000 0100 0200 0300 0400 1E00 2000 2100 2200 2300 2400 2500 2600 2700 FB00"

SIZES="${*:-32}"

gen_face_size() {
	face="$1"
	ttf="$2"
	sub_dir="$3"
	sz="$4"

	mkdir -p "$sub_dir"
	for blk in $BLOCKS; do
		out="$sub_dir/$face.$sz.$blk"
		lo=$(printf "%d" "0x${blk}")
		hi=$((lo + 0xff))
		echo "  $out"
		./ttf2subfont -p "$sz" -r 72 -start "$lo" -end "$hi" \
			"$ttf" "$out" || {
				echo "::error::ttf2subfont failed for $out" >&2
				exit 1
			}
	done
}

# Copy a 24pt manifest to a new size, rewriting (a) the DejaVu block
# references to the new size and (b) the header height/ascent line to
# the new size's metrics. Other entries (10646/9x15 fallbacks,
# NotoSansCJK at 14, NerdFont at 14) keep their original sizes —
# they're fallback scripts/icons, not what we're scaling up here.
#
# Header metrics come from ttf2subfont -info at the new size. For
# DejaVuSans at the four prebuilt sizes the (height, ascent) pairs
# observed: 12→14/11, 14→16/13, 18→21/16, 24→28/21, 32→36/29,
# 40→45/36.
rewrite_manifest() {
	src="$1"    # e.g. fonts/combined/unicode.sans.24.font
	dst="$2"
	face="$3"  # e.g. DejaVuSans
	sz="$4"    # e.g. 32

	# Probe the actual height/ascent from ttf2subfont -info.
	# The face's TTF is at the variable named "${face}_TTF"; resolve.
	case "$face" in
		DejaVuSans)     ttf=$SANS_TTF ;;
		DejaVuSansBold) ttf=$BOLD_TTF ;;
		DejaVuSansMono) ttf=$MONO_TTF ;;
		*) echo "::error::unknown face $face" >&2; exit 1 ;;
	esac
	metrics=$(./ttf2subfont -info -p "$sz" -r 72 -start 0 -end 0 "$ttf" 2>&1 \
		| sed -n 's/.*height=\([0-9]*\) ascent=\([0-9]*\).*/\1\t\2/p')
	if [ -z "$metrics" ]; then
		echo "::error::could not probe metrics for $face $sz" >&2
		exit 1
	fi

	# Rewrite. Header line is the first non-blank, non-comment line
	# of the .font file. Use a Python helper rather than wrestling
	# with awk-inside-shell quoting.
	python3 - "$src" "$dst" "$metrics" "$face" "$sz" <<'PY'
import sys
src, dst, metrics, face, sz = sys.argv[1:6]
with open(src) as fh:
    lines = fh.readlines()
out = [metrics + "\n"]
needle = "/" + face + "/" + face + ".24."
replace = "/" + face + "/" + face + "." + sz + "."
for line in lines[1:]:
    out.append(line.replace(needle, replace))
with open(dst, "w") as fh:
    fh.writelines(out)
PY
}

for sz in $SIZES; do
	echo "=== generating size $sz ==="
	gen_face_size DejaVuSans     "$SANS_TTF" DejaVuSans     "$sz"
	gen_face_size DejaVuSansBold "$BOLD_TTF" DejaVuSansBold "$sz"
	gen_face_size DejaVuSansMono "$MONO_TTF" DejaVuSansMono "$sz"

	echo "=== combined manifest at $sz ==="
	rewrite_manifest \
		"$ROOT/fonts/combined/unicode.sans.24.font" \
		"$ROOT/fonts/combined/unicode.sans.$sz.font" \
		DejaVuSans "$sz"
	rewrite_manifest \
		"$ROOT/fonts/combined/unicode.sans.bold.24.font" \
		"$ROOT/fonts/combined/unicode.sans.bold.$sz.font" \
		DejaVuSansBold "$sz"

	# Proportional-mono (the unicode.<n>.font slot used by terminals,
	# editors, acme, xenith — see grep -r 'unicode.14.font' appl/).
	# The 24pt version of this manifest is unicode.14.font's content
	# regenerated at 24 — we don't ship one. Generate from sans
	# manifest, then rewrite to mono paths.
	sed -E "s|/DejaVuSans/DejaVuSans\\.$sz\\.|/DejaVuSansMono/DejaVuSansMono.$sz.|g" \
		"$ROOT/fonts/combined/unicode.sans.$sz.font" \
		> "$ROOT/fonts/combined/unicode.$sz.font"
done

echo "done"

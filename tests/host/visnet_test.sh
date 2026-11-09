#!/bin/bash
#
# tests/host/visnet_test.sh
#
# A real detector through appl/lib/visnet.b and $Tensor, against an
# independent reference: tools/vision/refdetect.py letterboxes the same
# picture in numpy, runs the ONNX with onnxruntime, decodes and keeps the
# best boxes; tests/visnet_run.b does it all in InferNode. The two lists
# must agree (class, score to 0.002, box to 0.5 pixel), from a PPM of
# the reference's own pixels and from the JPEG InferNode decodes itself,
# under -c1 and -c0.
#
# Needs a model directory made by tools/vision/onnx2vis.py and its ONNX,
# a picture, and a Python with numpy, onnx, onnxruntime and Pillow:
#
#   VISION_ONNX     the .onnx       (yolox_nano.onnx, sha256 c789161e...)
#   VISION_MODEL    its directory   (onnx2vis.py VISION_ONNX VISION_MODEL)
#   VISION_PICTURE  a picture       (YOLOX's assets/dog.jpg, sha256 5a952205...)
#   VISION_PYTHON   the Python      (default python3)
#
# Skips if any is missing.
#
# Run from project root: ./tests/host/visnet_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

PY="${VISION_PYTHON:-python3}"
for v in VISION_ONNX VISION_MODEL VISION_PICTURE; do
	[ -n "${!v:-}" ] && [ -e "${!v}" ] || { echo "SKIP: $v not set to something that exists"; exit 77; }
done
"$PY" -c 'import numpy, onnx, onnxruntime, PIL' 2>/dev/null || { echo "SKIP: $PY lacks numpy, onnx, onnxruntime or Pillow"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/visnet_run.dis" ] || { echo "SKIP: tests/visnet_run.dis not built"; exit 77; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0

"$PY" -I "$ROOT/tools/vision/refdetect.py" --ppm "$T/pic.ppm" "$VISION_ONNX" "$VISION_MODEL" "$VISION_PICTURE" > "$T/want" 2>"$T/ref.err" ||
	{ echo "FAIL: refdetect: $(tail -1 "$T/ref.err")"; exit 1; }
[ -s "$T/want" ] || { echo "FAIL: the reference found nothing in $VISION_PICTURE"; exit 1; }

# host paths, as the emulator sees them through #U*
host() { echo "/tmp/h$1"; }

compare() {
	"$PY" -I - "$1" "$2" <<'EOF'
import sys
def recs(p):
    out = []
    for l in open(p):
        if l.startswith("class="):
            kv = dict(f.split("=", 1) for f in l.split())
            out.append((kv["class"], float(kv["score"]), [float(kv[k]) for k in ("x0", "y0", "x1", "y1")]))
    return out
want, got = recs(sys.argv[1]), recs(sys.argv[2])
if len(want) != len(got):
    sys.exit("%d found, the reference %d" % (len(got), len(want)))
for (wc, ws, wb), (gc, gs, gb) in zip(want, got):
    if wc != gc or abs(ws - gs) > 0.002 or max(abs(a - b) for a, b in zip(wb, gb)) > 0.5:
        sys.exit("%s %.4f %s, the reference %s %.4f %s" % (gc, gs, gb, wc, ws, wb))
EOF
}

for c in 1 0; do
	for pic in "$T/pic.ppm" "$VISION_PICTURE"; do
		with_timeout 300 "$EMU" -c$c -r"$ROOT" sh -c "mkdir -p /tmp/h; bind '#U*' /tmp/h; /tests/visnet_run.dis $(host "$VISION_MODEL") $(host "$pic"); echo DONE; echo halt > '#c/sysctl'" > "$T/got" 2>"$T/err"
		what="-c$c $(basename "$pic")"
		if ! grep -q '^DONE' "$T/got"; then
			echo "FAIL: $what: no end ($(grep -v fsqid "$T/err" | tail -1))"
			fail=1
		elif why=$(compare "$T/want" "$T/got" 2>&1); then
			echo "PASS: $what: $(grep -c '^class=' "$T/got") found, as the reference ($(grep '^class=' "$T/got" | cut -d' ' -f1 | sed 's/class=//' | tr '\n' ' '))"
		else
			echo "FAIL: $what: $why"
			fail=1
		fi
	done
done
exit $fail

#!/bin/sh
#
# mkengines.sh model.onnx modeldir: TensorRT engines for trtsrv (#1086), one
# a place, in modeldir/engines: gpu.plan, dla0.plan, dla1.plan, and
# modeldir/engines/sha256 (a line each: hash place), which visionfs gives
# trtsrv with each engine so it refuses one that is not the one built.
#
# The network is first made ready for the DLAs by tools/vision/trtonnx.py
# (cut at its heads, the SPP pools as 5x5 chains, space to depth as a
# convolution; checked exact against the original). Engines are FP16, built
# with detailed profiling so that trtsrv can see where every layer runs; a
# DLA engine whose layers are not all the DLA's (but the reformatting
# copies at its edges) is not kept.
#
# Needs a Jetson (trtexec, the DLAs) and VISION_PYTHON with onnx and
# onnxruntime.
#
set -e
[ $# -eq 2 ] || { echo "usage: mkengines.sh model.onnx modeldir" >&2; exit 2; }
onnx=$1
dir=$2
here=$(cd "$(dirname "$0")" && pwd)
py=${VISION_PYTHON:-python3}
trtexec=${TRTEXEC:-/usr/src/tensorrt/bin/trtexec}
mkdir -p "$dir/engines"
heads="$dir/engines/heads.onnx"
"$py" -I "$here/../vision/trtonnx.py" "$onnx" "$heads"
: > "$dir/engines/sha256"
for place in gpu dla0 dla1; do
	case $place in
	gpu)	x= ;;
	dla*)	x="--useDLACore=${place#dla} --allowGPUFallback" ;;
	esac
	"$trtexec" --onnx="$heads" --saveEngine="$dir/engines/$place.plan" --fp16 \
		--profilingVerbosity=detailed --exportLayerInfo="$dir/engines/$place.layers.json" $x \
		> "$dir/engines/$place.log" 2>&1 || { echo "mkengines: $place: trtexec failed: $dir/engines/$place.log" >&2; exit 1; }
	"$py" -I - "$dir/engines/$place.layers.json" "$place" <<'PY'
import json, sys, collections
layers = json.load(open(sys.argv[1]))["Layers"]
types = collections.Counter(l["LayerType"] for l in layers)
place = sys.argv[2]
if place.startswith("dla") and set(types) - {"DLA", "Reformat"}:
    sys.exit("mkengines: %s: layers off the DLA: %s" % (place, dict(types)))
if place == "gpu" and "DLA" in types:
    sys.exit("mkengines: gpu: a layer on a DLA")
print("mkengines: %s: %s" % (place, dict(types)))
PY
	echo "$(sha256sum "$dir/engines/$place.plan" | cut -d' ' -f1) $place" >> "$dir/engines/sha256"
	grep 'Throughput: [0-9]' "$dir/engines/$place.log" | sed "s/.*Throughput/mkengines: $place: throughput/"
done
cat "$dir/engines/sha256"

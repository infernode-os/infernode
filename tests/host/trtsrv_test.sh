#!/bin/bash
#
# tests/host/trtsrv_test.sh
#
# trtsrv (tools/trtsrv), the Jetson's GPU and DLAs as 9P files for
# vision(4) (#1086), mounted from InferNode on the pipe of its host
# command (mount -A {os trtsrv ... >[1=0]}), never on the network:
#
#   - each engine of the model directory (engines/, from mkengines.sh)
#     loaded on its place, listed in ctl with its shapes and hash
#   - on each place, gpu, dla0 and dla1, the picture's detections the CPU
#     engine's (tests/trtcheck: the same classes, scores within 0.02,
#     boxes within 6 pixels), and the round trip timed
#   - an engine not the one recorded refused; a DLA engine asked to run
#     on the GPU, and the GPU engine asked for a DLA, refused
#
# Needs a Jetson: trtsrv built (cargo build --release in tools/trtsrv),
# VISION_MODEL with engines/ (tools/trtsrv/mkengines.sh) and
# VISION_PICTURE. Skips without them.
#
# Run from project root: ./tests/host/trtsrv_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
T="$ROOT/tools/trtsrv/target/release/trtsrv"
[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -x "$T" ] || { echo "SKIP: trtsrv not built (cargo build --release in tools/trtsrv)"; exit 77; }
for v in VISION_MODEL VISION_PICTURE; do
	[ -n "${!v:-}" ] && [ -e "${!v}" ] || { echo "SKIP: $v not set to something that exists"; exit 77; }
done
[ -f "$VISION_MODEL/engines/sha256" ] || { echo "SKIP: no engines in $VISION_MODEL (tools/trtsrv/mkengines.sh)"; exit 77; }
[ -f "$ROOT/dis/tests/trtcheck.dis" ] || { echo "SKIP: dis/tests/trtcheck.dis not built"; exit 77; }

W="$ROOT/tmp/trtsrv_test.$$"
rm -rf "$W"; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT
E=/tmp/trtsrv_test.$$
ln -s "$VISION_MODEL" "$W/model"
cp "$VISION_PICTURE" "$W/picture"
loads=""
while read -r sha place; do
	loads="$loads load $place $place $VISION_MODEL/engines/$place.plan $sha"
done < "$VISION_MODEL/engines/sha256"
dsha=$(awk '$2 == "dla0" {print $1}' "$VISION_MODEL/engines/sha256")
gsha=$(awk '$2 == "gpu" {print $1}' "$VISION_MODEL/engines/sha256")
cat > "$W/run.sh" <<RUN
load std
mkdir -p /mnt/trt
mount -A {os $T$loads >[1=0]} /mnt/trt
echo '-- ctl'; cat /mnt/trt/ctl
for p in gpu dla0 dla1 { echo '-- '\$p; /dis/tests/trtcheck.dis $E/model $E/picture /mnt/trt \$p 10 }
echo '-- refusals'
echo load x gpu $VISION_MODEL/engines/gpu.plan 0000 > /mnt/trt/ctl; echo HASH-\$status
echo load x gpu $VISION_MODEL/engines/dla0.plan $dsha > /mnt/trt/ctl; echo DLAONGPU-\$status
echo load x dla0 $VISION_MODEL/engines/gpu.plan $gsha > /mnt/trt/ctl; echo GPUONDLA-\$status
echo TRT-DONE
echo halt > '#c/sysctl'
RUN
with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "$E/run.sh" > "$W/log" 2>&1 < /dev/null
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
part() { sed -n "/^-- $1\$/,/^-- /p" "$W/log" | grep -v '^-- '; }
grep -q '^TRT-DONE' "$W/log" || { echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -15; exit 1; }
for p in gpu dla0 dla1; do
	part ctl | grep -q "^model $p place=$p in=3x416x416 out=85x52x52,85x26x26,85x13x13 sha256=" && ok "$p: loaded on its place, its shapes and hash in ctl" || bad "$p: ctl: $(part ctl | grep "model $p")"
	f=$(part $p | grep '^found')
	n=$(echo "$f" | grep -c .)
	same=$(echo "$f" | python3 -c '
import sys, re
ok = 0
for l in sys.stdin:
    m = re.match(r"found cpu: (\S+) ([\d.]+) ([\d,]+) \| \S+: (\S+) ([\d.]+) ([\d,]+)", l.strip())
    if not m: continue
    a, b = [int(x) for x in m.group(3).split(",")], [int(x) for x in m.group(6).split(",")]
    if m.group(1) == m.group(4) and abs(float(m.group(2)) - float(m.group(5))) <= 0.02 and max(abs(x - y) for x, y in zip(a, b)) <= 6:
        ok += 1
print(ok)')
	[ "$n" -ge 1 ] && [ "$same" = "$n" ] && ok "$p: the CPU engine's $n detections, scores within 0.02, boxes within 6 px" || bad "$p: detections differ: $f"
	echo "      $(part $p | grep '^place=' | cut -c1-200)"
done
grep -q '^HASH-..*' "$W/log" && ok "an engine not the one recorded refused" || bad "hash: $(grep '^HASH-' "$W/log")"
grep -q '^DLAONGPU-..*' "$W/log" && ok "a DLA engine asked to run on the GPU refused" || bad "$(grep '^DLAONGPU-' "$W/log")"
grep -q '^GPUONDLA-..*' "$W/log" && ok "the GPU engine asked for a DLA refused" || bad "$(grep '^GPUONDLA-' "$W/log")"
exit $fail

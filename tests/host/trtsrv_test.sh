#!/bin/bash
#
# tests/host/trtsrv_test.sh
#
# trtsrv (tools/trtsrv), the Jetson's GPU and DLAs as 9P files for
# vision(4) (#1086), mounted from InferNode on the pipe of its host
# command (mount -A {os trtsrv >[1=0]}), never on the network; engines
# put in through its files, never by a host path:
#
#   - each engine of the model directory (engines/, from mkengines.sh)
#     copied into trtsrv's engines/ and loaded on its place, listed in ctl
#     with its type, shapes and hash, and its upload gone once loaded
#   - on each place, gpu, dla0 and dla1, the picture's detections the CPU
#     engine's (tests/trtcheck: the same classes, scores within 0.02,
#     boxes within 6 pixels), and the round trip timed
#   - through vision(4): `engine /mnt/trt` to its ctl, places and a
#     model's info listing gpu dla0 dla1; a session on each place finding
#     the picture's records as a CPU session does (the same classes,
#     scores within 0.02); a session on the GPU following a clip, every
#     frame looked at; a place with no engine refused; `engine none`
#     refused while a session is on a place
#   - an engine not the one recorded refused; a DLA engine asked to run
#     on the GPU, and the GPU engine asked for a DLA, refused; a load with
#     no engine written refused
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
"${VISION_PYTHON:-python3}" -I "$ROOT/tests/host/vision/mkclip.py" "$VISION_PICTURE" "$W/clip.y4m" 5 >/dev/null 2>&1 || { echo "SKIP: cannot make the clip (VISION_PYTHON with numpy and Pillow)"; exit 77; }
loads=""
while read -r sha place; do
	loads="$loads
cp $E/model/engines/$place.plan /mnt/trt/engines/$place
echo load $place $place $sha > /mnt/trt/ctl"
done < "$VISION_MODEL/engines/sha256"
dsha=$(awk '$2 == "dla0" {print $1}' "$VISION_MODEL/engines/sha256")
gsha=$(awk '$2 == "gpu" {print $1}' "$VISION_MODEL/engines/sha256")
cat > "$W/run.sh" <<RUN
load std
mkdir -p /mnt/trt
mount -A {os $T >[1=0]} /mnt/trt
$loads
echo '-- uploads'; ls /mnt/trt/engines
echo '-- ctl'; cat /mnt/trt/ctl
for p in gpu dla0 dla1 { echo '-- '\$p; /dis/tests/trtcheck.dis $E/model $E/picture /mnt/trt \$p 10 }
echo '-- vision'
visionfs load m $E/model
echo engine /mnt/trt > /mnt/vision/ctl; echo ENGINE-\$status
cat /mnt/vision/ctl /mnt/vision/models/m/info
for p in cpu gpu dla0 dla1 {
	{
		id=\`{read}
		echo place \$p > /mnt/vision/\$id/ctl
		echo '-- visctl-'\$p; grep '^place ' /mnt/vision/\$id/ctl
		cat $E/picture > /mnt/vision/\$id/image
		echo '-- vis-'\$p; cat /mnt/vision/\$id/detections
		echo '-- visstatus-'\$p; cat /mnt/vision/\$id/status
	} < /mnt/vision/clone
}
mkdir -p /mnt/video; mount {vid9p $E/clip.y4m} /mnt/video
{
	id=\`{read}
	echo place gpu > /mnt/vision/\$id/ctl
	{ echo src /mnt/video/0 > /mnt/vision/\$id/ctl; echo '-- visfeed'; cat } < /mnt/vision/\$id/detections
	echo '-- visfeedstats'; cat /mnt/vision/\$id/stats
	echo place nowhere > /mnt/vision/\$id/ctl; echo NOPLACE-\$status
	echo place dla0 > /mnt/vision/\$id/ctl
	echo engine none > /mnt/vision/ctl; echo INUSE-\$status
} < /mnt/vision/clone
echo '-- refusals'
cp $E/model/engines/gpu.plan /mnt/trt/engines/x; echo load x gpu 0000 > /mnt/trt/ctl; echo HASH-\$status
rm /mnt/trt/engines/x; cp $E/model/engines/dla0.plan /mnt/trt/engines/x; echo load x gpu $dsha > /mnt/trt/ctl; echo DLAONGPU-\$status
rm /mnt/trt/engines/x; cp $E/model/engines/gpu.plan /mnt/trt/engines/x; echo load x dla0 $gsha > /mnt/trt/ctl; echo GPUONDLA-\$status
echo load y gpu $gsha > /mnt/trt/ctl; echo NOUPLOAD-\$status
echo TRT-DONE
echo halt > '#c/sysctl'
RUN
with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "$E/run.sh" > "$W/log" 2>&1 < /dev/null
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
part() { sed -n "/^-- $1\$/,/^-- /p" "$W/log" | grep -v '^-- '; }
grep -q '^TRT-DONE' "$W/log" || { echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -15; exit 1; }
[ -z "$(part uploads)" ] && ok "each upload gone once loaded" || bad "uploads left: $(part uploads | tr '\n' ' ')"
for p in gpu dla0 dla1; do
	part ctl | grep -E -q "^model $p place=$p type=f(16|32) in=3x416x416 out=85x52x52,85x26x26,85x13x13 sha256=" && ok "$p: loaded on its place, its shapes and hash in ctl" || bad "$p: ctl: $(part ctl | grep "model $p")"
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
grep -q '^ENGINE-$' "$W/log" && grep -q '^engine trt /mnt/trt$' "$W/log" && grep -q '^places cpu gpu dla0 dla1$' "$W/log" && ok "vision(4): the engine tree attached, its places listed" || bad "vision ctl: $(grep -E '^ENGINE-|^engine|^places' "$W/log" | tr '\n' ' ')"
grep -q 'places=cpu,gpu,dla0,dla1 ' "$W/log" && ok "vision(4): the model's info lists its places" || bad "info: $(grep 'places=' "$W/log")"
for p in gpu dla0 dla1; do
	c=$(part vis-cpu | sed 's/ x0=.*//' | sort)
	g=$(part vis-$p | sed 's/ x0=.*//' | sort)
	same=$(python3 -c '
import sys
a=[l.split() for l in sys.argv[1].splitlines() if l]; b=[l.split() for l in sys.argv[2].splitlines() if l]
ok = len(a) == len(b) and len(a) > 0 and all(x[0] == y[0] and abs(float(x[1][6:]) - float(y[1][6:])) <= 0.02 for x, y in zip(a, b))
print(1 if ok else 0)' "$c" "$g")
	[ "$(part visctl-$p)" = "place $p" ] && ok "vision(4): a session's ctl reads back place $p" || bad "vision $p: ctl reads back '$(part visctl-$p)'"
	[ "$same" = 1 ] && part visstatus-$p | grep -q "place=$p" && ok "vision(4): a session on $p finds what one on the CPU does" || bad "vision $p: $(part vis-$p | tr '\n' '|') against $(part vis-cpu | tr '\n' '|'); $(part visstatus-$p)"
done
frames=$(part visfeed | cut -d' ' -f1 | uniq | tr '\n' ' ')
[ "$frames" = "frame=0 frame=1 frame=2 frame=3 frame=4 " ] && part visfeed | grep -q '^frame=3 pts=300 class=dog' && ok "vision(4): a session on the GPU follows a clip, every frame" || bad "feed on gpu: $frames; $(part visfeedstats)"
echo "      $(part visfeedstats)"
grep -q '^NOPLACE-..*' "$W/log" && ok "vision(4): a place with no engine refused" || bad "$(grep '^NOPLACE-' "$W/log")"
grep -q '^INUSE-..*' "$W/log" && ok "vision(4): engine none refused while a session is on a place" || bad "$(grep '^INUSE-' "$W/log")"
grep -q '^HASH-..*' "$W/log" && ok "an engine not the one recorded refused" || bad "hash: $(grep '^HASH-' "$W/log")"
grep -q '^DLAONGPU-..*' "$W/log" && ok "a DLA engine asked to run on the GPU refused" || bad "$(grep '^DLAONGPU-' "$W/log")"
grep -q '^GPUONDLA-..*' "$W/log" && ok "the GPU engine asked for a DLA refused" || bad "$(grep '^GPUONDLA-' "$W/log")"
grep -q '^NOUPLOAD-..*' "$W/log" && ok "a load with no engine written refused" || bad "$(grep '^NOUPLOAD-' "$W/log")"
exit $fail

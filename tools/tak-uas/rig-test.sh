#!/bin/bash
# rig-test.sh — end-to-end regression suite for the TAK/UAS video rig.
# Run from the Mac (repo root); orchestrates minipc + hephaestus over ssh.
# Every check states an invariant and prints PASS/FAIL with the measurement.
#
#   ./tools/tak-uas/rig-test.sh          # full battery (~90 s)
#
# Invariants tested (numbering used in reports):
#   T1  sim: gz clock advancing; SITL autopilot heartbeat; single stack
#   T3  manto: ingest ≈10 fps; drop_infer=0; pose=telemetry; GPU ~0% (DLA)
#   T4  broadcast: fresh joiner decodes both framings (RFC4571 + TS)
#   T5  phone: MAVLink + video sockets ESTABLISHED
#   T6  spectator: emu + vdec alive, vdec cputime advancing (decoding)
#   T8  hygiene: no UDP loss delta; no leaked frame-reader emus on heph
set -u
cd "$(cd "$(dirname "$0")/../.." && pwd)"
pass=0; fail=0
ok()  { echo "  PASS $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

echo "== T1 sim (minipc) =="
ssh -o BatchMode=yes -o ConnectTimeout=30 minipc '
c1=$(timeout 4 gz topic -e -t /clock -n 1 2>/dev/null | grep -oaE "sec: [0-9]+" | head -1); sleep 2
c2=$(timeout 4 gz topic -e -t /clock -n 1 2>/dev/null | grep -oaE "sec: [0-9]+" | head -1)
if [ -n "$c1" ] && [ "$c1" != "$c2" ]; then echo OK1; else echo NO1; fi
export PATH="$HOME/.local/bin:$PATH"
timeout 10 python3 -c "
from pymavlink import mavutil
import time
m=mavutil.mavlink_connection(\"udpin:127.0.0.1:14550\"); t0=time.time()
while time.time()-t0<6:
    hb=m.recv_match(type=\"HEARTBEAT\",blocking=True,timeout=2)
    if hb and hb.get_srcComponent()==1: print(\"OK2\"); break
else: print(\"NO2\")" 2>/dev/null
echo "N$(pgrep -c arducopter)"' 2>/dev/null > /tmp/rt1.out
grep -q OK1 /tmp/rt1.out && ok "T1.1 gz clock advancing" || bad "T1.1 gz clock frozen (wedge? see UAS-163)"
grep -q OK2 /tmp/rt1.out && ok "T1.2 SITL heartbeat"     || bad "T1.2 no SITL heartbeat"
grep -q "^N1$" /tmp/rt1.out && ok "T1.3 single SITL"     || bad "T1.3 arducopter count != 1"

echo "== T3 manto (hephaestus) =="
ssh -o BatchMode=yes -o ConnectTimeout=60 -o ServerAliveInterval=10 hephaestus '
N=/mnt/orin-ssd/pdfinn/github.com/NERVsystems/nerva3
S=$(timeout 26 "$N/emu/Linux/o.emu" -r"$N" sh -c "mkdir -p /tmp/rt; mount -A tcp!127.0.0.1!6630 /tmp/rt; cat /tmp/rt/feeds/gz-uas/stats; sleep 8; echo @@; cat /tmp/rt/feeds/gz-uas/stats; echo @@; cat /tmp/rt/feeds/gz-uas/status" 2>/dev/null)
f1=$(echo "$S" | grep -oE "frames_in=[0-9]+" | head -1 | cut -d= -f2); f2=$(echo "$S" | grep -oE "frames_in=[0-9]+" | tail -1 | cut -d= -f2)
echo "D$((f2-f1))"
echo "$S" | grep -oE "drop_infer=[0-9]+|pose=[a-z]+" | sort -u
timeout 4 tegrastats --interval 1000 2>/dev/null | head -1 | grep -oE "GR3D_FREQ [0-9]+"' 2>/dev/null > /tmp/rt3.out
d=$(grep -oE "^D[0-9]+" /tmp/rt3.out | tr -d D)
[ -n "$d" ] && [ "$d" -ge 60 ] && [ "$d" -le 100 ] && ok "T3.1 ingest ${d}f/8s ≈10fps" || bad "T3.1 ingest rate (${d:-none}/8s)"
grep -q "drop_infer=0" /tmp/rt3.out && ok "T3.2 drop_infer=0" || bad "T3.2 inference drops"
grep -q "pose=telemetry" /tmp/rt3.out && ok "T3.3 georef pose" || bad "T3.3 pose stale (takconnector proxy down?)"
g=$(grep -oE "GR3D_FREQ [0-9]+" /tmp/rt3.out | awk '{print $2}')
[ -n "$g" ] && [ "$g" -le 30 ] && ok "T3.4 GPU ${g}% (DLA carrying)" || bad "T3.4 GPU ${g:-?}% (inference on GPU?)"

echo "== T4 broadcast fresh joins =="
nc -z 127.0.0.1 5602 2>/dev/null || ssh -f -N -L 5602:127.0.0.1:5602 -o ExitOnForwardFailure=yes hephaestus 2>/dev/null
rm -f /tmp/rt4.y4m
timeout 14 ./tools/vdec/target/release/vdec tcp://127.0.0.1:5602 --limit 12 --y4m /tmp/rt4.y4m --quiet 2>/dev/null
b=$(wc -c < /tmp/rt4.y4m 2>/dev/null | tr -d " ")
[ "${b:-0}" -gt 16000000 ] && ok "T4.1 TS joiner decodes ($b B)" || bad "T4.1 TS joiner ($b B — INFR-396 regression?)"
ssh -o BatchMode=yes -o ConnectTimeout=30 hephaestus '
rm -f /tmp/rt4_*.jpg
timeout 6 gst-launch-1.0 -q tcpclientsrc host=127.0.0.1 port=5601 ! "application/x-rtp-stream,media=video,encoding-name=H264,payload=96" ! rtpstreamdepay ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! jpegenc ! multifilesink location=/tmp/rt4_%03d.jpg 2>/dev/null
n=$(ls /tmp/rt4_*.jpg 2>/dev/null | wc -l); u=$(md5sum /tmp/rt4_*.jpg 2>/dev/null | awk "{print \$1}" | sort -u | wc -l); echo "J$n U$u"' 2>/dev/null > /tmp/rt4.out
n=$(grep -oE "J[0-9]+" /tmp/rt4.out | tr -d J); u=$(grep -oE "U[0-9]+" /tmp/rt4.out | tr -d U)
[ -n "$n" ] && [ "$n" -ge 30 ] && [ "$n" = "$u" ] && ok "T4.2 RFC4571 joiner ($n frames, all unique)" || bad "T4.2 RFC4571 joiner (n=${n:-0} u=${u:-0})"

echo "== T5 phone links (minipc) =="
ssh -o BatchMode=yes -o ConnectTimeout=30 minipc '
echo "V$(ss -tn 2>/dev/null | grep :5601 | grep -ic estab) M$(ss -tn 2>/dev/null | grep 15762 | grep -ic estab)"' 2>/dev/null > /tmp/rt5.out
grep -qE "V[1-9]" /tmp/rt5.out && ok "T5.1 phone video ESTAB" || bad "T5.1 phone video not connected (plugin retry pending? HUD closed?)"
grep -qE "M[1-9]" /tmp/rt5.out && ok "T5.2 phone MAVLink ESTAB" || bad "T5.2 phone MAVLink down"

echo "== T6 spectator (this Mac) =="
pgrep -x o.emu >/dev/null && ok "T6.1 emu alive" || bad "T6.1 emu dead (watchdog running?)"
V=$(pgrep -x vdec | head -1)
if [ -n "$V" ]; then
  t1=$(ps -o time= -p "$V" | tr -d " "); sleep 5; t2=$(ps -o time= -p "$V" | tr -d " ")
  [ "$t1" != "$t2" ] && ok "T6.2 vdec decoding (cputime $t1->$t2)" || bad "T6.2 vdec STALLED"
else bad "T6.2 vdec dead (watchdog will heal in ~25s; re-run)"; fi

echo "== T8 hygiene =="
ssh -o BatchMode=yes -o ConnectTimeout=30 hephaestus '
a=$(nstat -az 2>/dev/null | awk "/UdpRcvbufErrors/{print \$2}"); sleep 5
b=$(nstat -az 2>/dev/null | awk "/UdpRcvbufErrors/{print \$2}"); echo "L$((b-a))"
n=0; for p in $(pgrep -x o.emu); do tr "\0" " " </proc/$p/cmdline 2>/dev/null | grep -q "feeds/gz-uas/frame" && n=$((n+1)); done; echo "E$n"' 2>/dev/null > /tmp/rt8.out
grep -q "^L0$" /tmp/rt8.out && ok "T8.1 zero UDP loss (5s)" || bad "T8.1 UDP drops: $(grep -oE 'L[0-9]+' /tmp/rt8.out)"
e=$(grep -oE "^E[0-9]+" /tmp/rt8.out | tr -d E)
[ -n "$e" ] && [ "$e" -le 1 ] && ok "T8.2 no leaked frame-readers ($e)" || bad "T8.2 leaked emus on heph: $e"

echo
echo "=== RESULT: $pass PASS, $fail FAIL ==="
exit $fail

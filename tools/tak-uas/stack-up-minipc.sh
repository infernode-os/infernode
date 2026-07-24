#!/bin/bash
# stack-up-minipc.sh — bring up the minipc (simulation / UXV) side of the
# TAK/UAS video stack. Idempotent: starts only what's missing. Order matters:
# sim first (camstream subscribes to the gz camera topic).
#
#   sim            Gazebo (ao_targets world) + ArduCopter SITL + mavproxy
#                  fan-out (14550/51/52) + CoT bridges  — via sim-up.sh
#   camstream      gz camera -> x264 RTP -> hephaestus:5610 (manto ingest)
#   phone mavproxy udpin:14552 -> tcpin:15762 (nerv-gcs MAVLink; SITL's own
#                  5762 does not accept the plugin reliably — use this)
#   adb reverses   phone localhost:5762 -> minipc:15762 (MAVLink)
#                  phone localhost:5601 -> minipc:5601  (video)
#   video tunnel   minipc:5601 -> hephaestus:5601 (annotated RFC4571)
#
# After a WEDGE (gazebo /clock frozen + world-control service timeouts —
# see UAS-163): reboot the minipc, then run this script.
set -u
NS=/home/pdfinn/nerva-sim
MAVPROXY=/home/pdfinn/nerva-sim/venv/bin/mavproxy.py

up()   { ss -ltn 2>/dev/null | grep -q ":$1 "; }
gzok() {
  c1=$(timeout 4 gz topic -e -t /clock -n 1 2>/dev/null | grep -oaE 'sec: [0-9]+' | head -1)
  sleep 2
  c2=$(timeout 4 gz topic -e -t /clock -n 1 2>/dev/null | grep -oaE 'sec: [0-9]+' | head -1)
  [ -n "$c1" ] && [ "$c1" != "$c2" ]
}

# 1. sim (gazebo + SITL + fan-out + CoT bridges)
if up 5760 && gzok; then echo "sim: already up (SITL + clock advancing)"; else
  if pgrep -f 'gz sim' >/dev/null && ! gzok; then
    echo "sim: GAZEBO WEDGED (clock frozen) — reboot the minipc, then re-run. (UAS-163)"; exit 1
  fi
  ( cd "$NS/sim-host" && setsid nohup bash sim-up.sh </dev/null >/tmp/simup.log 2>&1 & )
  echo "sim: starting (sim-up.sh)…"
  for i in $(seq 1 20); do sleep 5; up 5760 && break; done
  up 5760 && echo "sim: STARTED" || { echo "sim: FAILED — /tmp/simup.log"; exit 1; }
fi

# 2. camstream (after sim: needs the camera topic)
if pgrep -x gz_cam_stream >/dev/null; then echo "camstream: already up"; else
  setsid nohup bash "$NS/camstream/camstream.sh" </dev/null >/tmp/camstream.log 2>&1 &
  sleep 4
  pgrep -x gz_cam_stream >/dev/null && echo "camstream: STARTED" || { echo "camstream: FAILED — /tmp/camstream.log"; exit 1; }
fi

# 3. phone MAVLink mavproxy (tcpin:15762)
if up 15762; then echo "phone-mavproxy: already up (15762)"; else
  setsid nohup "$MAVPROXY" --master=udpin:127.0.0.1:14552 --out=tcpin:0.0.0.0:15762 \
      --daemon --non-interactive </dev/null >/tmp/mavproxy-phone.log 2>&1 &
  sleep 6
  up 15762 && echo "phone-mavproxy: STARTED" || echo "phone-mavproxy: FAILED — /tmp/mavproxy-phone.log"
fi

# 4. video tunnel minipc:5601 -> hephaestus:5601
if up 5601; then echo "video-tunnel: already up (5601)"; else
  ssh -f -N -L 5601:127.0.0.1:5601 -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 hephaestus \
    && echo "video-tunnel: STARTED" || echo "video-tunnel: FAILED (is hephaestus broadcast up?)"
fi

# 5. adb reverses (idempotent; no-op if phone absent)
if adb get-state >/dev/null 2>&1; then
  adb reverse tcp:5601 tcp:5601   >/dev/null 2>&1
  adb reverse tcp:5762 tcp:15762  >/dev/null 2>&1
  echo "adb reverses: $(adb reverse --list 2>/dev/null | tr '\n' ' ')"
  echo "NB: if nerv-gcs sits on a STALE link (mock-alpha, frozen video), restart ATAK:"
  echo "    adb shell am force-stop com.atakmap.app.civ && adb shell monkey -p com.atakmap.app.civ 1"
else
  echo "adb: no phone attached (skipping reverses)"
fi

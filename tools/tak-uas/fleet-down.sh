#!/bin/bash
#
# fleet-down.sh — clean teardown of the 3-UAS sim rig (safe kill patterns:
# gazebo by ruby-comm cmdline match, broadcast legs by pid, never a pkill -f
# with a string that appears in our own remote command line).
set -u
MINIPC="${MINIPC:-minipc}"
HEPH="${HEPH:-hephaestus}"

echo "== heph: broadcasts down (mantod stays — it serves other consumers) =="
ssh -o BatchMode=yes "$HEPH" '
  for g in $(pgrep -x gst-launch-1.0); do kill "$g" 2>/dev/null; done
  for e in $(pgrep -x o.emu); do grep -qa "feeds/gz-uas" /proc/$e/cmdline 2>/dev/null && kill "$e" 2>/dev/null; done
  echo "  broadcasts stopped"'

echo "== minipc: sim + camstreams + tunnels + phone leg down =="
ssh -o BatchMode=yes "$MINIPC" '
  for p in $(pgrep -x ruby); do grep -q "gz sim" /proc/$p/cmdline 2>/dev/null && kill -9 "$p"; done
  pkill -x arducopter 2>/dev/null
  pkill -x gz_cam_stream 2>/dev/null
  for p in $(pgrep -x python3; pgrep -x python; pgrep -x mavproxy.py); do
    c=$(tr "\0" " " </proc/$p/cmdline 2>/dev/null)
    case "$c" in *mavproxy.py*|*sim_vehicle*|*run_in_terminal*|*cot_bridge*) kill "$p" 2>/dev/null;; esac
  done
  for p in $(pgrep -x ssh); do
    c=$(tr "\0" " " </proc/$p/cmdline 2>/dev/null)
    case "$c" in *" -N -L560"*) kill "$p" 2>/dev/null;; esac
  done
  echo "  sim + plumbing stopped"'
echo "done. (mantod on $HEPH left running; stop by pid if needed.)"

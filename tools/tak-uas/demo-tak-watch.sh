#!/bin/bash
# demo-tak-watch.sh — self-healing wrapper for the emu spectator.
#
# The compressed leg's decoder (vdec) dies whenever manto-broadcast on the
# perception node restarts (vdec reads a single TCP stream and does not
# reconnect). The phone reconnects by itself; the emu needs this watchdog:
# when vdec is gone (or the emu itself died), tear down and relaunch
# demo-tak.sh. Detection→recovery is ~15 s.
#
# Run from the repo root:  ./tools/tak-uas/demo-tak-watch.sh
set -u
MODE="${1:-raw}"   # raw: watch emu only; live: also watch vdec incl. stall
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
last=""; still=0
while true; do
  # stall detection (live mode): vdec alive but cputime frozen — recycle
  V=""
  [ "$MODE" = live ] && V=$(pgrep -x vdec | head -1)
  if [ -n "$V" ]; then
    t=$(ps -o time= -p "$V" 2>/dev/null | tr -d " ")
    if [ "$t" = "$last" ]; then still=$((still+1)); else still=0; fi
    last="$t"
    if [ "$still" -ge 3 ]; then
      echo "$(date +%T) watch: vdec STALLED (cputime frozen) — recycling"
      kill "$V" 2>/dev/null; still=0; last=""
    fi
  fi
  dead=0
  pgrep -x o.emu >/dev/null || dead=1
  [ "$MODE" = live ] && { pgrep -x vdec >/dev/null || dead=1; }
  if [ "$dead" = 1 ]; then
    echo "$(date +%T) watch: emu=$(pgrep -x o.emu | wc -l | tr -d " ") vdec=$(pgrep -x vdec | wc -l | tr -d " ") — relaunching spectator"
    for p in $(pgrep -x o.emu); do kill "$p" 2>/dev/null; done
    for p in $(pgrep -x vdec);  do kill "$p" 2>/dev/null; done
    sleep 2
    nohup ./demo-tak.sh >/tmp/demo-tak.log 2>&1 &
    sleep 20   # let it boot before re-checking
  fi
  sleep 5
done

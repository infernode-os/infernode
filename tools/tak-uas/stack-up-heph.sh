#!/bin/bash
# stack-up-heph.sh — bring up the hephaestus (perception node) side of the
# TAK/UAS video stack. Idempotent: checks each service and starts only what's
# missing. Run as pdfinn on hephaestus (no sudo needed).
#
#   mantod            manto: ingest rtp://:5610 (CPU decode), YOLO on DLA0,
#                     serve /mnt/vision on 9P 127.0.0.1:6630, argus :6640
#   manto-broadcast   one x264 encode of the annotated feed, fanned out:
#                     RFC4571 tcp :5601 (nerv-gcs) + MPEG-TS tcp :5602 (emu)
#   takconnector-proxy host 0.0.0.0:7089 -> takconnector container (georef
#                     telemetry for manto + CoT bridges; container is
#                     deliberately unpublished in its compose file)
#
# Canonical copies of the helper scripts live in the InferNode repo under
# tools/tak-uas/; deploy to ~/bin on this host.
set -u
LOG=/mnt/orin-ssd/pdfinn
NERVA3=/mnt/orin-ssd/pdfinn/github.com/NERVsystems/nerva3
MANTOD=/mnt/orin-ssd/pdfinn/github.com/NERVsystems/manto/target/release/mantod

up() { ss -ltn 2>/dev/null | grep -q ":$1 "; }

# 1. mantod (9P vision tree on 6630)
if up 6630; then echo "mantod: already up (6630)"; else
  ( cd "$NERVA3" && setsid nohup "$MANTOD" --config tmp/loop/mantod-live.toml --loop \
      </dev/null >"$LOG/mantod.log" 2>&1 & )
  sleep 6
  up 6630 && echo "mantod: STARTED (DLA)" || { echo "mantod: FAILED — $LOG/mantod.log"; exit 1; }
fi

# 2. manto-broadcast (5601 RFC4571 + 5602 TS), supervised
if up 5601 && up 5602; then echo "broadcast: already up (5601+5602)"; else
  setsid bash -c 'while true; do bash /home/pdfinn/bin/manto-broadcast.sh gz-uas 5601 5602; sleep 2; done' \
      </dev/null >"$LOG/mbcast-sup.log" 2>&1 &
  sleep 8
  up 5601 && up 5602 && echo "broadcast: STARTED" || { echo "broadcast: FAILED — $LOG/mbcast-sup.log"; exit 1; }
fi

# 3. takconnector host proxy (7089)
if up 7089; then echo "takproxy: already up (7089)"; else
  setsid bash /home/pdfinn/bin/takconnector-proxy.sh </dev/null >"$LOG/takproxy.log" 2>&1 &
  sleep 3
  up 7089 && echo "takproxy: STARTED" || echo "takproxy: FAILED (is docker/takconnector up?)"
fi

# health summary
echo "--- health ---"
timeout 5 curl -s http://127.0.0.1:7089/health 2>/dev/null | grep -o '"status":"healthy"' | head -1 || echo "takconnector: unhealthy/unreachable"
timeout 16 "$NERVA3/emu/Linux/o.emu" -r"$NERVA3" sh -c \
  'mkdir -p /tmp/su; mount -A tcp!127.0.0.1!6630 /tmp/su; cat /tmp/su/feeds/gz-uas/stats; sleep 3; cat /tmp/su/feeds/gz-uas/stats' \
  2>/dev/null | grep -oE 'frames_in=[0-9]+' | uniq -c | awk 'END{if(NR>1) print "feed: LIVE (frames_in climbing)"; else print "feed: FROZEN or single sample — check camstream on minipc"}'

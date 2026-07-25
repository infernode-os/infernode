#!/bin/bash
#
# fleet-up.sh — bring up the ENTIRE 3-UAS sim rig, idempotently, from the Mac.
#
#   minipc:  gazebo world (3 gimbal-deconflicted iris) + 3 SITLs (sysid 1/2/3)
#            + aggregator mavproxy + 3 camstreams (RTP 5610/5611/5612 -> heph)
#            + phone mavproxy leg (14552 -> tcpin:15762) + tunnels + adb plumbing
#   heph:    mantod (3 feeds, pose paired off nerv-gcs.mav-N CoT) + 3 broadcasts
#            (RFC4571 5601/5603/5605 + TS twins 5602/5604/5606)
#   phone:   ATAK + nerv-gcs plugin (video follows focus; 9P surface :7777)
#
# Idempotent: every phase checks before acting; safe to re-run to heal a
# partially-dead rig. Run fleet-down.sh for a clean teardown.
#
# HARD-WON RULES ENCODED HERE (do not "simplify" them away):
#   - gazebo's process comm is "ruby": pkill gz kills NOTHING and stacks
#     worlds whose same-name topics interleave into one insane stream.
#   - never pkill -f <string that appears in our own remote cmdline> — it
#     kills the ssh session (recurring self-kill trap).
#   - kill broadcast legs by PID (gst + its feeder emu), never by name.
#   - mavproxy MUST be the sim venv one; bare mavproxy.py is not on PATH.
#   - the phone MAVLink leg is phone_leg.py (raw passthrough), NEVER a second
#     mavproxy or an aggregator tcpin: MAVProxy intercepts RC_CHANNELS_OVERRIDE
#     from TCP GCS clients — sticks die and LOITER settles on SITL's low
#     throttle baseline.
#   - adb wedge (screencap 0 bytes, installs hang): pkill -9 -x adb,
#     start-server, and RE-ADD every reverse — the wedge silently eats them.
#   - every `adb install -r` of the plugin re-trips ATAK's approval gate:
#     the operator must re-enable NERV GCS in ATAK's Plugins manager.
set -u
MINIPC="${MINIPC:-minipc}"
HEPH="${HEPH:-hephaestus}"
NERVA3=/mnt/orin-ssd/pdfinn/github.com/NERVsystems/nerva3
MANTOD=../manto/target/release/mantod
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()   { echo "  PASS $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }
ssh_m(){ ssh -o BatchMode=yes -o ConnectTimeout=20 "$MINIPC" "$@"; }
ssh_h(){ ssh -o BatchMode=yes -o ConnectTimeout=25 "$HEPH" "$@"; }

echo "== phase 0: reachability =="
ssh_m 'echo minipc-ok' >/dev/null 2>&1 && ok "minipc ssh" || { bad "minipc ssh"; exit 1; }
ssh_h 'echo heph-ok'   >/dev/null 2>&1 && ok "heph ssh"   || { bad "heph ssh"; exit 1; }

echo "== phase 1: sim (gazebo + 3 SITLs + aggregator) =="
GZ=$(ssh_m 'for p in $(pgrep -x ruby); do grep -q "gz sim" /proc/$p/cmdline 2>/dev/null && echo 1; done | wc -l | tr -d " "')
AC=$(ssh_m 'pgrep -cx arducopter' 2>/dev/null || echo 0)
if [ "${GZ:-0}" = "1" ] && [ "${AC:-0}" = "3" ]; then
  ok "sim already up (1 gazebo, 3 SITLs)"
else
  echo "  sweeping stale sim (gazebo=$GZ arducopter=$AC) + booting fleet"
  ssh_m '
    for p in $(pgrep -x ruby); do grep -q "gz sim" /proc/$p/cmdline 2>/dev/null && kill -9 "$p"; done
    pkill -x arducopter 2>/dev/null; pkill -x gz_cam_stream 2>/dev/null
    for p in $(pgrep -x python3; pgrep -x python; pgrep -x mavproxy.py); do
      c=$(tr "\0" " " </proc/$p/cmdline 2>/dev/null)
      case "$c" in *"out=tcpin:0.0.0.0:15762"*) : ;; *mavproxy.py*|*sim_vehicle*|*run_in_terminal*|*udp_relay*) kill "$p" 2>/dev/null;; esac
    done
    sleep 3
    cd ~/nerva-sim/sim-host
    setsid nohup bash sim-up-fleet.sh </dev/null >/tmp/fleetup.log 2>&1 &
    disown; echo booted'
  for i in $(seq 1 16); do
    sleep 15
    N=$(ssh_m 'ss -ltn 2>/dev/null | grep -cE ":5760 |:5770 |:5780 "' 2>/dev/null)
    [ "${N:-0}" = "3" ] && break
  done
  [ "${N:-0}" = "3" ] && ok "3 SITL serials up" || bad "SITLs did not come up (see minipc:/tmp/fleetup.log)"
fi
SYS=$(ssh_m 'export PATH="$HOME/.local/bin:$PATH"; timeout 15 python3 -c "
from pymavlink import mavutil
import time
m=mavutil.mavlink_connection(\"udpin:127.0.0.1:14550\")
seen=set(); t0=time.time()
while time.time()-t0<10:
    h=m.recv_match(type=\"HEARTBEAT\",blocking=True,timeout=2)
    if h and h.get_srcSystem() not in (0,255): seen.add(h.get_srcSystem())
print(sorted(seen))"' 2>/dev/null)
[ "$SYS" = "[1, 2, 3]" ] && ok "sysids $SYS" || bad "sysids: ${SYS:-none} (want [1, 2, 3])"
NT=$(ssh_m 'timeout 8 gz topic -l 2>/dev/null | grep -c "camera/image$"')
[ "${NT:-0}" = "3" ] && ok "exactly 3 camera topics" || bad "camera topics: ${NT:-0} (stacked gazebos?)"

echo "== phase 2: camstreams (3 vehicles -> heph RTP 5610/5611/5612) =="
CS=$(ssh_m 'pgrep -cx gz_cam_stream' 2>/dev/null || echo 0)
if [ "${CS:-0}" = "3" ]; then ok "3 camstreams running"; else
  ssh_m 'pkill -x gz_cam_stream 2>/dev/null; sleep 2; cd ~/nerva-sim/camstream
    for spec in "iris_with_gimbal 5610" "iris_b 5611" "iris_c 5612"; do
      setsid nohup bash camstream-fleet.sh $spec </dev/null >/tmp/cam_${spec// /_}.log 2>&1 & disown
    done; sleep 5; pgrep -cx gz_cam_stream'
  CS=$(ssh_m 'pgrep -cx gz_cam_stream')
  [ "${CS:-0}" = "3" ] && ok "3 camstreams launched" || bad "camstreams: ${CS:-0}"
fi

echo "== phase 3: mantod (3 feeds, nerv-gcs.mav-N pose) =="
MR=$(ssh_h 'pgrep -cx mantod' 2>/dev/null || echo 0)
if [ "${MR:-0}" -ge 1 ]; then ok "mantod running"; else
  scp -o BatchMode=yes "$HERE/fleet-assets/mantod-fleet.toml" "$HEPH:$NERVA3/tmp/loop/mantod-live.toml" >/dev/null 2>&1
  ssh_h "cd $NERVA3 && setsid nohup $MANTOD --config tmp/loop/mantod-live.toml --loop </dev/null >/tmp/mantod.log 2>&1 & disown; sleep 6; pgrep -cx mantod" >/dev/null
  MR=$(ssh_h 'pgrep -cx mantod')
  [ "${MR:-0}" -ge 1 ] && ok "mantod started" || bad "mantod failed (heph:/tmp/mantod.log)"
fi
FEEDS=$(ssh_h "for f in gz-uas gz-uas-b gz-uas-c; do timeout 8 $NERVA3/emu/Linux/o.emu -r$NERVA3 sh -c \"mkdir -p /tmp/fu_\$f; mount -A tcp!127.0.0.1!6630 /tmp/fu_\$f; cat /tmp/fu_\$f/feeds/\$f/stats\" 2>/dev/null | grep -oE 'frames_in=[0-9]+'; done | wc -l | tr -d ' '")
[ "${FEEDS:-0}" = "3" ] && ok "3 manto feeds serving stats" || bad "manto feeds stats: ${FEEDS:-0}/3"

echo "== phase 4: broadcasts (5601/5603/5605 + TS twins) =="
BG=$(ssh_h 'pgrep -cx gst-launch-1.0' 2>/dev/null || echo 0)
if [ "${BG:-0}" = "3" ]; then ok "3 broadcasts running"; else
  ssh_h 'for g in $(pgrep -x gst-launch-1.0); do kill "$g" 2>/dev/null; done
    for e in $(pgrep -x o.emu); do grep -qa "feeds/gz-uas" /proc/$e/cmdline 2>/dev/null && kill "$e" 2>/dev/null; done
    sleep 3; cd ~/bin
    for spec in "gz-uas 5601 5602" "gz-uas-b 5603 5604" "gz-uas-c 5605 5606"; do
      setsid bash -c "exec nohup ./manto-broadcast.sh $spec >/tmp/bc_${spec%% *}.log 2>&1" &
    done; sleep 14' >/dev/null 2>&1
  BG=$(ssh_h 'pgrep -cx gst-launch-1.0')
  [ "${BG:-0}" = "3" ] && ok "3 broadcasts launched" || bad "broadcasts: ${BG:-0}"
fi
LP=$(ssh_h 'ss -ltn 2>/dev/null | grep -cE ":560[1-6] "')
[ "${LP:-0}" = "6" ] && ok "all 6 broadcast ports listening" || bad "broadcast ports: ${LP:-0}/6"

echo "== phase 5: minipc plumbing (tunnels, phone mavlink leg, adb) =="
for P in 5601 5603 5605; do
  UP=$(ssh_m "ss -ltn 2>/dev/null | grep -c \":$P \"")
  if [ "${UP:-0}" -ge 1 ]; then ok "tunnel $P up"; else
    ssh_m "nohup ssh -N -L$P:127.0.0.1:$P -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ConnectTimeout=10 $HEPH >/tmp/tun_$P.log 2>&1 & sleep 4; ss -ltn | grep -c \":$P \"" >/dev/null
    UP=$(ssh_m "ss -ltn 2>/dev/null | grep -c \":$P \"")
    [ "${UP:-0}" -ge 1 ] && ok "tunnel $P launched" || bad "tunnel $P failed"
  fi
done
ML=$(ssh_m 'ss -ltn 2>/dev/null | grep -c :15762')
if [ "${ML:-0}" -ge 1 ]; then ok "phone mavlink leg up (15762)"; else
  scp -o BatchMode=yes "$HERE/phone_leg.py" "$MINIPC:~/nerva-sim/phone_leg.py" >/dev/null 2>&1
  ssh_m 'nohup python3 $HOME/nerva-sim/phone_leg.py 14552 15762 >/tmp/phone_leg.log 2>&1 & sleep 3' >/dev/null 2>&1
  ML=$(ssh_m 'ss -ltn 2>/dev/null | grep -c :15762')
  [ "${ML:-0}" -ge 1 ] && ok "phone mavlink leg launched" || bad "phone mavlink leg failed"
fi
ADB=$(ssh_m 'timeout 10 adb devices 2>/dev/null | grep -c "device$"')
if [ "${ADB:-0}" -lt 1 ]; then
  echo "  adb wedged/absent — recovering"
  ssh_m 'pkill -9 -x adb 2>/dev/null; sleep 2; adb start-server >/dev/null 2>&1; sleep 3'
  ADB=$(ssh_m 'timeout 10 adb devices 2>/dev/null | grep -c "device$"')
fi
[ "${ADB:-0}" -ge 1 ] && ok "phone via adb" || bad "no phone on adb"
ssh_m 'for P in 5601 5603 5605; do adb reverse tcp:$P tcp:$P >/dev/null 2>&1; done
       adb reverse tcp:5762 tcp:15762 >/dev/null 2>&1
       adb forward tcp:7777 tcp:7777 >/dev/null 2>&1
       adb reverse --list 2>/dev/null | wc -l' >/dev/null 2>&1
RV=$(ssh_m 'adb reverse --list 2>/dev/null | grep -cE "5601|5603|5605|5762"')
[ "${RV:-0}" = "4" ] && ok "4 adb reverses set" || bad "adb reverses: ${RV:-0}/4"

echo "== phase 6: phone GCS =="
scp -o BatchMode=yes "$HERE/ninep.py" "$MINIPC:/tmp/ninep.py" >/dev/null 2>&1
SURF=$(ssh_m 'python3 /tmp/ninep.py cat version 2>/dev/null | head -1')
if [ -n "$SURF" ]; then ok "9P surface: $SURF"; else
  echo "  surface down — restarting ATAK (plugin gate may need the operator)"
  ssh_m 'adb shell am force-stop com.atakmap.app.civ 2>/dev/null; sleep 3
         adb shell monkey -p com.atakmap.app.civ -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1' >/dev/null 2>&1
  sleep 35
  SURF=$(ssh_m 'adb forward tcp:7777 tcp:7777 >/dev/null 2>&1; python3 /tmp/ninep.py cat version 2>/dev/null | head -1')
  if [ -n "$SURF" ]; then ok "9P surface after ATAK restart"; else
    bad "9P surface down — if the plugin was reinstalled, RE-ENABLE 'NERV GCS' in ATAK's Plugins manager"
  fi
fi

echo
echo "=== RESULT: $pass PASS, $fail FAIL ==="
echo "Operate: 9p attention picks the bird (echo mav-2 > attention via tools' ninep.py);"
echo "         video + HUD + AR follow focus. Spectate on Mac: ./demo-tak.sh"
exit "$fail"

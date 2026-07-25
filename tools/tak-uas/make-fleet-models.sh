#!/bin/bash
#
# make-fleet-models.sh — install the 3-vehicle fleet's Gazebo assets onto the
# sim host (minipc): the gimbal-DECONFLICTED model clones, the fleet world,
# and the per-vehicle sysid parm files.
#
# The clones are stock ardupilot_gazebo models with three classes of edit that
# exist nowhere upstream (each was a live-debugging casualty before it became
# an edit — see docs/TAK-UAS-VIDEO.md):
#   1. unique FDM ports (9012/9022) so SITL -I1/-I2 bind their own vehicles;
#   2. unique nested gimbal model names (gimbal_b/gimbal_c) — identical names
#      share name-derived topics across vehicles;
#   3. unique JOINT-COMMAND topics (/gimbal_b/cmd_* etc) — these are explicit
#      strings in iris_with_gimbal's sdf (6 occurrences), NOT name-derived:
#      left shared, all three autopilots cross-command all three gimbals and
#      every camera "bounces".
# Mesh-bearing dirs are cloned from the stock models on the host; only the
# edited .sdf/.config text is carried in the repo (fleet-assets/models/).
set -eu
MINIPC="${MINIPC:-minipc}"
HERE="$(cd "$(dirname "$0")" && pwd)"
A="$HERE/fleet-assets"

echo "== clone mesh-bearing dirs from stock on $MINIPC =="
ssh -o BatchMode=yes "$MINIPC" '
  cd ~/ardupilot_gazebo/models
  for s in b c; do
    [ -d "iris_with_gimbal_$s" ] || cp -r iris_with_gimbal "iris_with_gimbal_$s"
    [ -d "gimbal_small_3d_$s" ]  || cp -r gimbal_small_3d  "gimbal_small_3d_$s"
  done
  mkdir -p ~/nerva-sim/sim-host/worlds'

echo "== overlay the exact edited model texts =="
for m in iris_with_gimbal_b iris_with_gimbal_c gimbal_small_3d_b gimbal_small_3d_c; do
  scp -o BatchMode=yes "$A/models/$m/model.sdf" "$A/models/$m/model.config" \
      "$MINIPC:~/ardupilot_gazebo/models/$m/" >/dev/null
  echo "  $m"
done

echo "== install world + parm files =="
scp -o BatchMode=yes "$A/ao_fleet.sdf" "$MINIPC:~/nerva-sim/sim-host/worlds/" >/dev/null
scp -o BatchMode=yes "$A"/sysid[123].parm "$A/flight.parm" "$MINIPC:~/nerva-sim/sim-host/" >/dev/null

echo "== verify de-confliction markers on the host =="
ssh -o BatchMode=yes "$MINIPC" '
  cd ~/ardupilot_gazebo/models
  for s in b c; do
    n=$(grep -c "gimbal_$s/cmd_" iris_with_gimbal_$s/model.sdf)
    p=$(grep -oE "fdm_port_in>[0-9]+" iris_with_gimbal_$s/model.sdf | head -1)
    echo "  iris_$s: cmd-topics=$n (want 6) $p"
  done'
echo "fleet models installed."

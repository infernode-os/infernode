#!/usr/bin/env bash
# sim-up-fleet.sh — 3-vehicle NERVA sim (iris ×3, gimbals ×3). Mirrors
# sim-up.sh; see that file for the architecture prose.
#   vehicle 1: iris_with_gimbal   FDM 9002  SITL -I0 tcp:5760  SYSID 1
#   vehicle 2: iris_b (model _b)  FDM 9012  SITL -I1 tcp:5770  SYSID 2
#   vehicle 3: iris_c (model _c)  FDM 9022  SITL -I2 tcp:5780  SYSID 3
# One aggregating mavproxy fans ALL THREE out on 14550/14551/14552, so the
# phone-side mavproxy (tcpin:15762) presents a 3-vehicle roster to nerv-gcs.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ORIN_IP="${ORIN_IP:-10.147.17.120}"
WORLD="$DIR/worlds/ao_fleet.sdf"
AP="${ARDUPILOT_DIR:-$HOME/ardupilot}"
APGZ="${ARDUPILOT_GAZEBO_DIR:-$HOME/ardupilot_gazebo}"
VENV="${VENV:-$HOME/nerva-sim/venv}"
PY="$VENV/bin/python"; MAVPROXY="$VENV/bin/mavproxy.py"
HOME_LAT=47.5200; HOME_LON=-121.9750; HOME_ALT=380; HOME_HDG=0
RUN=/tmp/nerva-sim; mkdir -p "$RUN"; : > "$RUN/pids"
log(){ echo "fleet-up: $*"; }; save(){ echo "$1" >> "$RUN/pids"; }
export GZ_SIM_SYSTEM_PLUGIN_PATH="$APGZ/build"
export GZ_SIM_RESOURCE_PATH="$APGZ/models:$APGZ/worlds"
export GZ_IP=127.0.0.1
log "Gazebo headless: ao_fleet.sdf (3 birds)"
nohup gz sim -r -s "$WORLD" -v3 > "$RUN/gazebo.log" 2>&1 & save $!
sleep 15
for i in 0 1 2; do
  n=$((i+1))
  log "SITL instance $i (vehicle $n, sysid $n)"
  ( cd "$AP" && nohup Tools/autotest/sim_vehicle.py -v ArduCopter -f gazebo-iris \
      --model JSON --no-rebuild --no-mavproxy -I$i \
      --custom-location="$HOME_LAT,$HOME_LON,$HOME_ALT,$HOME_HDG" \
      --add-param-file="$APGZ/config/gazebo-iris-gimbal.parm" \
      --add-param-file="$DIR/flight.parm" \
      --add-param-file="$DIR/sysid$n.parm" \
      > "$RUN/sitl$i.log" 2>&1 & save $! )
  sleep 20
done
log "aggregating mavproxy (3 masters) -> 14550/14551/14552"
nohup "$MAVPROXY" --master=tcp:127.0.0.1:5760 --master=tcp:127.0.0.1:5770 --master=tcp:127.0.0.1:5780 \
  --out=udp:127.0.0.1:14550 --out=udp:127.0.0.1:14551 --out=udp:127.0.0.1:14552 \
  --daemon --non-interactive > "$RUN/mavproxy.log" 2>&1 & save $!
sleep 8
log "telemetry bridge (vehicle mav-1) -> $ORIN_IP:7089"
nohup "$PY" "$DIR/../mav_cot_bridge.py" --mav udpin:127.0.0.1:14550 \
  --takurl "http://$ORIN_IP:7089/api/events" --vehicle mav-1 --rate 5 --stale 30 \
  > "$RUN/mavcot.log" 2>&1 & save $!
nohup "$PY" "$DIR/../uas_cot_executor.py" --mav udp:127.0.0.1:14551 \
  --takurl "http://$ORIN_IP:7089" --target-prefix hilsim. \
  > "$RUN/executor.log" 2>&1 & save $!
log "UP: 3 vehicles. SITL masters 5760/5770/5780; fanout 14550-2."

#!/bin/bash
#
# check-phone-rc-path.sh — live-rig regression check for the RC-override
# delivery bug: MAVProxy INTERCEPTS RC_CHANNELS_OVERRIDE arriving from TCP
# GCS clients (re-targeting it to its own selected vehicle), which killed
# stick flight on mav-2/3 and let an untouched LOITER settle into the
# ground. The phone leg must therefore be a raw passthrough (phone_leg.py).
#
# Method: stream a distinctive throttle override (1777) for sysid 1 into the
# phone-facing port 15762 — the byte-identical path the handset uses — and
# watch the vehicle's EFFECTIVE RC (RC_CHANNELS.chan3_raw) on its own SITL
# serial. Delivery = 1777 visible. mav-1 disarmed on the ground is unaffected
# by a 2-second throttle override; the override is explicitly released after.
#
# Needs the rig up (fleet-up.sh). Run from the Mac.
set -u
MINIPC="${MINIPC:-minipc}"

OUT=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$MINIPC" 'export PATH="$HOME/.local/bin:$PATH"; timeout 40 python3 - << "PYEOF"
from pymavlink import mavutil
import time, threading
ph = mavutil.mavlink_connection("tcp:127.0.0.1:15762"); ph.wait_heartbeat(timeout=12)
d  = mavutil.mavlink_connection("tcp:127.0.0.1:5763");  d.wait_heartbeat(timeout=10)
d.mav.request_data_stream_send(1,1,mavutil.mavlink.MAV_DATA_STREAM_ALL,4,1)
stop=False
def pump():
    while not stop:
        ph.mav.rc_channels_override_send(1,1,1500,1500,1777,1500,0,0,0,0)
        time.sleep(0.1)
t=threading.Thread(target=pump); t.start()
time.sleep(1.5)
while d.recv_match(blocking=False) is not None: pass
seen=[]
t0=time.time()
while time.time()-t0<3:
    r=d.recv_match(type="RC_CHANNELS", blocking=True, timeout=1)
    if r and r.get_srcSystem()==1: seen.append(r.chan3_raw)
stop=True; t.join()
for _ in range(3):
    ph.mav.rc_channels_override_send(1,1,0,0,0,0,0,0,0,0); time.sleep(0.1)
print("DELIVERED" if 1777 in seen else f"DROPPED {seen[:6]}")
PYEOF' 2>&1)

case "$OUT" in
  *DELIVERED*) echo "PASS phone RC path delivers overrides end-to-end"; exit 0;;
  *) echo "FAIL phone RC path: $OUT"; echo "     (a mavproxy crept back into the phone leg? see phone_leg.py header)"; exit 1;;
esac

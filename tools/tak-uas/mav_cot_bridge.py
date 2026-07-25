#!/usr/bin/env python3
"""HEADLESS-TEST-ONLY MAVLink -> CoT bridge (SITL drone into the TAK world model).

Purpose: when NO phone/nerv-gcs is driving a vehicle (a headless CI/eval rig),
publish the SITL drone's telemetry as CoT so it appears in the TAK world model.
When the phone IS in use, nerv-gcs owns CoT publishing — do NOT run this then.

NON-CONFLICT by construction:
  * UID namespace is `hilsim.<vehicle>` — DISTINCT from nerv-gcs's
    `nerv-gcs.<vehicle>`, so this can never collide/fight over the same TAK
    entity even if both are somehow live.
  * On startup it checks TAK for any live `nerv-gcs.*` vehicle and WARNS
    (the phone is probably active — you likely don't want this running).
  * It is a deliberately-run tool, not a service. Ring-fence as test tooling
    if it ever lands in a repo (see nerva3 CLAUDE.md ring-fence rule).

Usage: mav_cot_bridge.py --mav udp:127.0.0.1:14550 --takurl http://<tc>:7089/api/events
"""
import argparse
import sys
import time
from pymavlink import mavutil
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--mav", default="udpin:127.0.0.1:14550")
ap.add_argument("--takurl", required=True)
ap.add_argument("--vehicle", default="mav-1")
ap.add_argument("--sysid", type=int, default=0,
                help="only track this MAVLink system id (0 = any; needed on a multi-vehicle fan-out)")
ap.add_argument("--rate", type=float, default=1.0)
ap.add_argument("--stale", type=float, default=4.0)
# Static gimbal fallback for rigs whose autopilot doesn't stream a gimbal
# attitude (GIMBAL_DEVICE_ATTITUDE_STATUS / MOUNT_ORIENTATION). The Gazebo
# gimbal camera on the SAR bench is nadir (-90).
ap.add_argument("--gimbal-pitch", type=float, default=-90.0)
ap.add_argument("--gimbal-yaw", type=float, default=0.0)
args = ap.parse_args()

UID = f"hilsim.{args.vehicle}"  # DISTINCT from nerv-gcs.<vehicle>

COT = (
    '<event version="2.0" uid="{uid}" type="a-f-A-M-H-Q" how="m-g" '
    'time="{t}" start="{t}" stale="{stale}">'
    '<point lat="{lat:.7f}" lon="{lon:.7f}" hae="{hae:.1f}" ce="5.0" le="10.0"/>'
    '<detail><contact callsign="HILSIM-{veh}"/>'
    '<track course="{course:.1f}" speed="{speed:.1f}"/>'
    '<_uas altitude="{hae:.1f}" altitudeAgl="{agl:.1f}" groundSpeed="{speed:.1f}" '
    'gimbalPitch="{gpitch:.1f}" gimbalYaw="{gyaw:.1f}" '
    'batteryPercent="{batt}" isFlying="{flying}" armed="{armed}" flightMode="{mode}" '
    'isConnected="true" gpsStatus="{gpsstatus}" satelliteCount="{sats}" '
    'waypointCurrent="{wpcur}" waypointCount="{wpcount}" dataAge="0"/>'
    '<remarks>headless SITL bridge (test-only); nerv-gcs owns CoT when phone is up</remarks>'
    '</detail></event>'
)

# ArduCopter custom_mode -> name (the modes we use)
COPTER_MODES = {0: "STABILIZE", 3: "AUTO", 4: "GUIDED", 5: "LOITER", 6: "RTL",
                9: "LAND", 16: "POSHOLD"}


def iso(ts):
    # Real milliseconds: manto pairs camera frames to these poses by nearest-t
    # (SPEC §7.1) — whole-second truncation is too coarse for that.
    ms = int(ts * 1000) % 1000
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts)) + f".{ms:03d}Z"


def quat_to_pitch_yaw_deg(q):
    """MAVLink attitude quaternion [w,x,y,z] -> (pitch, yaw) degrees."""
    import math
    w, x, y, z = q
    sinp = 2.0 * (w * y - z * x)
    sinp = max(-1.0, min(1.0, sinp))
    pitch = math.degrees(math.asin(sinp))
    yaw = math.degrees(math.atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z)))
    return pitch, yaw


def post(xml):
    req = urllib.request.Request(args.takurl, data=xml.encode(),
                                 headers={"Content-Type": "application/xml"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status


# non-conflict guard: warn if a nerv-gcs vehicle is already live
try:
    base = args.takurl.rsplit("/api/events", 1)[0] + "/api/events"
    with urllib.request.urlopen(base, timeout=5) as r:
        import json
        evs = json.load(r).get("events", [])
    if any(e["uid"].startswith("nerv-gcs.") for e in evs):
        print("WARN: nerv-gcs.* vehicles already in TAK — the phone may be publishing; "
              "this headless bridge is probably unnecessary.", file=sys.stderr)
except Exception:
    pass

m = mavutil.mavlink_connection(args.mav)
m.wait_heartbeat()
print(f"bridge: mav connected, publishing {UID} -> {args.takurl}", file=sys.stderr)

def _newpos():
    return {"lat": 0.0, "lon": 0.0, "hae": 0.0, "agl": 0.0, "course": 0.0, "speed": 0.0,
            "batt": 100, "armed": False, "mode": "GUIDED", "sats": 0, "fix": 0,
            "wpcur": 0, "wpcount": 0,
            "gpitch": args.gimbal_pitch, "gyaw": args.gimbal_yaw, "gimbal_live": False}

# Per-vehicle state and publish clocks, keyed by MAVLink source system.
# One CoT track per vehicle: uid hilsim.mav-<sysid> — a single blended dict
# under one uid made the marker hop between vehicles (the cycling-HILSIM bug).
vehicles = {}
last = {}
n = 0
while True:
    msg = m.recv_match(type=["GLOBAL_POSITION_INT", "VFR_HUD", "SYS_STATUS",
                             "GPS_RAW_INT", "HEARTBEAT", "MISSION_CURRENT",
                             "GIMBAL_DEVICE_ATTITUDE_STATUS", "MOUNT_ORIENTATION"],
                       blocking=True, timeout=2)
    if msg:
        sid = msg.get_srcSystem()
        if sid in (0, 255) or (args.sysid and sid != args.sysid):
            msg = None
    if msg:
        t = msg.get_type()
        pos = vehicles.setdefault(sid, _newpos())
        if t == "GIMBAL_DEVICE_ATTITUDE_STATUS":
            gp, gy = quat_to_pitch_yaw_deg(msg.q)
            pos["gpitch"], pos["gyaw"] = gp, gy
            if not pos["gimbal_live"]:
                pos["gimbal_live"] = True
                print("bridge: live gimbal attitude from GIMBAL_DEVICE_ATTITUDE_STATUS", file=sys.stderr)
        elif t == "MOUNT_ORIENTATION" and not pos["gimbal_live"]:
            # Legacy mount message: degrees directly (pitch, yaw relative).
            pos["gpitch"], pos["gyaw"] = msg.pitch, msg.yaw
        if t == "MISSION_CURRENT":
            pos["wpcur"] = msg.seq
            if getattr(msg, "total", 0):
                pos["wpcount"] = msg.total
        if t == "GLOBAL_POSITION_INT":
            pos["lat"] = msg.lat / 1e7; pos["lon"] = msg.lon / 1e7
            pos["hae"] = msg.alt / 1000.0; pos["agl"] = msg.relative_alt / 1000.0
            pos["course"] = (msg.hdg / 100.0) if msg.hdg != 65535 else 0.0
        elif t == "VFR_HUD":
            pos["speed"] = msg.groundspeed
        elif t == "SYS_STATUS":
            pos["batt"] = msg.battery_remaining if msg.battery_remaining >= 0 else 100
        elif t == "GPS_RAW_INT":
            pos["sats"] = msg.satellites_visible
            pos["fix"] = msg.fix_type  # 3 = 3D fix
        elif t == "HEARTBEAT" and msg.type != mavutil.mavlink.MAV_TYPE_GCS:
            pos["armed"] = bool(msg.base_mode & mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED)
            pos["mode"] = COPTER_MODES.get(msg.custom_mode, pos["mode"])
    now = time.time()
    for sid, pos in vehicles.items():
        if now - last.get(sid, 0.0) < 1.0 / args.rate or pos["lat"] == 0.0:
            continue
        veh = f"mav-{sid}"
        uid = f"hilsim.{veh}"
        gpsstatus = "FIX_3D" if pos["fix"] >= 3 else ("NO_FIX" if pos["fix"] < 2 else "FIX_2D")
        xml = COT.format(uid=uid, veh=veh, t=iso(now), stale=iso(now + args.stale),
                         lat=pos["lat"], lon=pos["lon"], hae=pos["hae"], agl=pos["agl"],
                         gpitch=pos["gpitch"], gyaw=pos["gyaw"],
                         course=pos["course"], speed=pos["speed"], batt=int(pos["batt"]),
                         flying=str(pos["agl"] > 1.0).lower(), armed=str(pos["armed"]).lower(),
                         mode=pos["mode"], gpsstatus=gpsstatus, sats=pos["sats"],
                         wpcur=pos["wpcur"], wpcount=pos["wpcount"])
        try:
            code = post(xml)
            n += 1
            if n % 5 == 1:
                print(f"  {uid} @ {pos['lat']:.6f},{pos['lon']:.6f} agl {pos['agl']:.1f}m -> {code}", file=sys.stderr)
        except Exception as e:
            print(f"  post failed: {e}", file=sys.stderr)
        last[sid] = now

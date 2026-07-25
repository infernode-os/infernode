#!/usr/bin/env python3
"""Regression test for the HILSIM CoT bridge glitches (found live 2026-07):

  1. THE CYCLING MARKER: a single blended state dict published every
     vehicle's position under ONE uid (hilsim.mav-1), so the marker hopped
     between aircraft. The bridge must publish one track per source system.
  2. CROSS-BLEED: no vehicle's position may ever appear under another
     vehicle's uid.

Runs the REAL bridge (subprocess) against synthetic 3-vehicle MAVLink and a
local HTTP sink standing in for takconnector. Self-contained: stdlib +
pymavlink. Exit 0 = PASS.

  usage: python3 test_mav_cot_bridge.py [path-to-mav_cot_bridge.py]
"""
import http.server
import os
import re
import socket
import subprocess
import sys
import threading
import time

BRIDGE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "mav_cot_bridge.py")

# Vehicles: sysid -> latitude (distinct, recognizable)
LATS = {1: 47.001, 2: 47.002, 3: 47.003}

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p

# ---- HTTP sink (stands in for takconnector) ----
posts = []
class Sink(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # the bridge pre-checks for nerv-gcs.* tracks
        body = b'{"count":0,"events":[]}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        posts.append(self.rfile.read(n).decode(errors="replace"))
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass

hport = free_port()
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", hport), Sink)
threading.Thread(target=httpd.serve_forever, daemon=True).start()

# ---- the real bridge under test ----
mport = free_port()
proc = subprocess.Popen(
    [sys.executable, BRIDGE, "--mav", f"udpin:127.0.0.1:{mport}",
     "--takurl", f"http://127.0.0.1:{hport}/api/events",
     "--rate", "20", "--stale", "2"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# ---- synthetic 3-vehicle telemetry ----
from pymavlink import mavutil  # noqa: E402
conns = {}
for sid in LATS:
    conns[sid] = mavutil.mavlink_connection(
        f"udpout:127.0.0.1:{mport}", source_system=sid, source_component=1)

t0 = time.time()
while time.time() - t0 < 5.0:
    for sid, lat in LATS.items():
        c = conns[sid]
        c.mav.heartbeat_send(mavutil.mavlink.MAV_TYPE_QUADROTOR,
                             mavutil.mavlink.MAV_AUTOPILOT_ARDUPILOTMEGA, 81, 4, 3)
        c.mav.global_position_int_send(
            int((time.time() - t0) * 1000), int(lat * 1e7), int(-121.5 * 1e7),
            500_000, 25_000, 0, 0, 0, 36000)
    time.sleep(0.2)

proc.terminate()
proc.wait(timeout=5)
httpd.shutdown()

# ---- verdicts ----
fails = []
tracks = {}  # uid -> set of lats
for xml in posts:
    uid = re.search(r'uid="([^"]+)"', xml)
    lat = re.search(r'lat="([0-9.\-]+)"', xml)
    if not uid or not lat:
        continue
    tracks.setdefault(uid.group(1), set()).add(round(float(lat.group(1)), 6))

expect_uids = {f"hilsim.mav-{s}" for s in LATS}
if not posts:
    fails.append("bridge posted nothing")
if set(tracks) != expect_uids:
    fails.append(f"uid set {sorted(tracks)} != {sorted(expect_uids)} "
                 "(single blended uid = the cycling-marker regression)")
for uid, lats in tracks.items():
    if len(lats) != 1:
        fails.append(f"{uid} published {len(lats)} distinct positions {sorted(lats)} "
                     "(cross-bleed = the marker-hopping regression)")
    sid = int(uid.rsplit("-", 1)[-1]) if uid.rsplit("-", 1)[-1].isdigit() else None
    if sid in LATS and lats and abs(next(iter(lats)) - LATS[sid]) > 1e-4:
        fails.append(f"{uid} position {lats} != vehicle {sid}'s {LATS[sid]} (wrong vehicle)")

if fails:
    print("FAIL mav_cot_bridge regression:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print(f"PASS mav_cot_bridge: {len(posts)} posts, one steady track per vehicle "
      f"({', '.join(sorted(tracks))})")

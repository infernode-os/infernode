#!/usr/bin/env python3
"""phone_leg.py — RAW MAVLink passthrough: TCP server (phone via adb reverse)
<-> the aggregator's udp:14552 out-peer.

Exists because MAVProxy's GCS-link handling INTERCEPTS RC_CHANNELS_OVERRIDE
from TCP clients and re-targets it to its own selected vehicle (sysid 1) —
proven live: overrides for mav-2 vanished through two different mavproxy
tcpin configurations, while the same bytes injected at a mavproxy UDP
out-peer socket routed correctly by target_system. This bridge does NO
parsing at all — bytes phone->aggregator-peer and back — so there is
nothing to intercept. MAVLink is self-framing; raw TCP chunking is fine.
"""
import select
import socket
import sys

UDP_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 14552
TCP_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 15762

u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u.bind(("127.0.0.1", UDP_PORT))
t = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
t.bind(("0.0.0.0", TCP_PORT))
t.listen(4)

clients = []
agg = None  # aggregator's source (host, port) — learned from first datagram
print(f"phone_leg: udp:{UDP_PORT} <-> tcp:{TCP_PORT}", file=sys.stderr, flush=True)

while True:
    rd, _, _ = select.select([u, t] + clients, [], [], 5.0)
    for s in rd:
        if s is u:
            data, addr = u.recvfrom(65535)
            agg = addr
            for c in clients[:]:
                try:
                    c.sendall(data)
                except OSError:
                    clients.remove(c)
                    c.close()
        elif s is t:
            c, peer = t.accept()
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            clients.append(c)
            print(f"phone_leg: client {peer}", file=sys.stderr, flush=True)
        else:
            try:
                data = s.recv(65535)
            except OSError:
                data = b""
            if not data:
                clients.remove(s)
                s.close()
                continue
            if agg is not None:
                u.sendto(data, agg)

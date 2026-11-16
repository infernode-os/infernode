#!/usr/bin/env python3
"""Scripted NTP servers on 127.0.0.1 for tests/host/sntp_test.sh.

  fake_ntp.py PORTFILE SECONDS

One UDP port a case; "name port" lines are written to PORTFILE once all
are bound.  Each answers a request as its case says:

  good     a server's answer: mode 4, the request's transmit timestamp
           given back as its originate timestamp; the year 2030
  v4       the same from a version 4 server; 2034
  leap     the same with a leap second pending (LI 1); 2035
  burst    to the first request: four answers to nobody's request, one
           too short to be a packet, then a good one; 2029
  garbage  an originate timestamp that is not the request's, as from a
           sender who never saw the request; 2031
  replay   the request before's transmit timestamp given back; 2031
  mode6    a control message (mode 6) with the right originate; 2031
  mode5    a broadcast (mode 5) with the right originate; 2031
  li3      the server's clock is not set (LI 3); 2032
  kod      a kiss-of-death: stratum 0, DENY; 2033
  zero     no transmit timestamp
  other    a good answer, sent from another port than the one asked
  ro       as good, for the run whose clock cannot be written; 2028
"""
import calendar
import select
import socket
import struct
import sys
import time

EPOCH = 86400 * (365 * 70 + 17)


def t(y):
    return calendar.timegm((y, 1, 1, 0, 0, 0)) + EPOCH


def pkt(b0, stratum, secs, org, clockid=b"\x7f\x00\x00\x01"):
    return struct.pack(">BBbbII4s", b0, stratum, 6, -20, 0, 0, clockid) + \
        struct.pack(">Q", (secs - 10) << 32 if secs else 0) + org + \
        struct.pack(">QQ", secs << 32, secs << 32)


BAD = bytes.fromhex("deadbeefcafef00d")
prev = {}


def answers(name, req, n):
    xmt = req[40:48] if len(req) >= 48 else bytes(8)
    if name == "good":
        return [pkt(0x0C, 2, t(2030), xmt)]
    if name == "v4":
        return [pkt(0x24, 2, t(2034), xmt)]
    if name == "leap":
        return [pkt(0x4C, 2, t(2035), xmt)]
    if name == "burst":
        if n > 0:
            return []
        return [pkt(0x0C, 2, t(2031), BAD)] * 4 + [b"\x0c" * 20, pkt(0x0C, 2, t(2029), xmt)]
    if name == "garbage":
        return [pkt(0x0C, 2, t(2031), BAD)]
    if name == "replay":
        p = prev.get(name, bytes(8))
        prev[name] = xmt
        return [pkt(0x0C, 2, t(2031), p)]
    if name == "mode6":
        return [pkt(0x0E, 2, t(2031), xmt)]
    if name == "mode5":
        return [pkt(0x0D, 2, t(2031), xmt)]
    if name == "li3":
        return [pkt(0xCC, 2, t(2032), xmt)]
    if name == "kod":
        return [pkt(0x0C, 0, t(2033), xmt, b"DENY")]
    if name == "zero":
        return [pkt(0x0C, 2, 0, xmt)]
    if name in ("other", "ro"):
        return [pkt(0x0C, 2, t(2028), xmt)]
    return []


names = ["good", "v4", "leap", "burst", "garbage", "replay", "mode6", "mode5",
         "li3", "kod", "zero", "other", "ro"]
socks = {}
for name in names:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    socks[s] = name
elsewhere = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
elsewhere.bind(("127.0.0.1", 0))
with open(sys.argv[1] + ".tmp", "w") as f:
    for s, name in socks.items():
        f.write("%s %d\n" % (name, s.getsockname()[1]))
import os
os.rename(sys.argv[1] + ".tmp", sys.argv[1])

seen = {}
end = time.time() + float(sys.argv[2])
while time.time() < end:
    r, _, _ = select.select(list(socks), [], [], 0.5)
    for s in r:
        data, addr = s.recvfrom(2048)
        name = socks[s]
        n = seen.get(name, 0)
        seen[name] = n + 1
        print("%s: request %d: b0=%#x org=%s xmt=%s" % (name, n + 1, data[0] if data else 0,
              data[24:32].hex(), data[40:48].hex()), flush=True)
        for p in answers(name, data, n):
            (elsewhere if name == "other" else s).sendto(p, addr)

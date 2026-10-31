#!/usr/bin/env python3
"""NMEA for tests/host/gpsfs_test.sh.

  fake_feed.py track PATH        write a recorded log: three times a
                                 second apart, each RMC GGA GSA GSV GST
  fake_feed.py feed PATH         write sentences to feed: a fix, a
                                 second, then the fix lost
  fake_feed.py nmea LOG          serve NMEA over TCP on loopback, as a
                                 phone app does; print the port
  fake_feed.py gpsd LOG          serve as gpsd does: a VERSION line, then
                                 NMEA once a ?WATCH asks for it; print
                                 the port; what the client sent goes in LOG
  fake_feed.py port              print a UDP port free on loopback
  fake_feed.py udpnmea PORT      send to PORT, five times a second for a
                                 minute, as a marine gateway does: a fix
                                 with magnetic variation, a heading and an
                                 AIS ship, a datagram a sentence
  fake_feed.py udpgdl90 PORT     the same, as an ADS-B receiver does:
                                 GDL 90 heartbeat, own-ship and a traffic
                                 report, the specification's N825V
  fake_feed.py garmin PATH       write Garmin Aviation output, two groups
"""
import socket
import sys
import threading
import time


def cs(body):
    s = 0
    for c in body.encode():
        s ^= c
    return "$%s*%02X\r\n" % (body, s)


def epoch(t, lat):
    return [
        cs("GPRMC,%s,A,%s,N,07425.0000,W,5.0,90.0,311026,,,A" % (t, lat)),
        cs("GPGGA,%s,%s,N,07425.0000,W,1,07,1.1,76.0,M,-34.0,M,," % (t, lat)),
        cs("GPGSA,A,3,04,09,12,,,,,,,,,,2.0,1.1,1.6"),
        cs("GPGSV,1,1,03,04,45,270,38,09,10,020,22,12,05,300,"),
        cs("GPGST,%s,1.0,3.0,2.0,0.0,3.0,4.0,6.5" % t),
    ]


def track():
    out = []
    for i, lat in enumerate(["4047.0400", "4047.0460", "4047.0520"]):
        out += epoch("14320%d.00" % i, lat)
    return out


def serve(mode, log):
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", 0))
    ls.listen(4)
    print(ls.getsockname()[1], flush=True)

    def client(c):
        with c:
            if mode == "gpsd":
                c.sendall(b'{"class":"VERSION","release":"3.25","rev":"fake","proto_major":3,"proto_minor":15}\r\n')
                got = b""
                while b"\n" not in got:
                    d = c.recv(1024)
                    if not d:
                        return
                    got += d
                with open(log, "ab") as f:
                    f.write(got)
                if b'"nmea":true' not in got:
                    return
                c.sendall(b'{"class":"DEVICES","devices":[]}\r\n')
            # one position, then hold the connection open
            c.sendall("".join(epoch("101500.00", "5130.0000")).encode())
            time.sleep(60)

    while True:
        c, _ = ls.accept()
        threading.Thread(target=client, args=(c,), daemon=True).start()


# GDL 90 (the specification's CRC-16-CCITT and framing)
_tab = []
for i in range(256):
    c = (i << 8) & 0xFFFF
    for _ in range(8):
        c = ((c << 1) ^ (0x1021 if c & 0x8000 else 0)) & 0xFFFF
    _tab.append(c)


def gdlframe(msg):
    c = 0
    for x in msg:
        c = (_tab[c >> 8] ^ ((c << 8) & 0xFFFF) ^ x) & 0xFFFF
    body = bytes(msg) + bytes([c & 0xFF, c >> 8])
    out = bytearray([0x7E])
    for x in body:
        if x in (0x7E, 0x7D):
            out += bytes([0x7D, x ^ 0x20])
        else:
            out.append(x)
    out.append(0x7E)
    return bytes(out)


def s24(v):
    return (v & 0xFFFFFF).to_bytes(3, "big")


def report(mid, addr, lat, lon, feet, knots, fpm, track, nacp, emitter, callsign):
    alt = (feet + 1000) // 25
    misc = 0x9  # airborne, true track
    hv = knots
    vv = (fpm // 64) & 0xFFF
    return bytes([mid, 0x00]) + addr.to_bytes(3, "big") + \
        s24(round(lat * 0x800000 / 180)) + s24(round(lon * 0x800000 / 180)) + \
        bytes([alt >> 4, ((alt & 0xF) << 4) | misc, (10 << 4) | nacp,
               hv >> 4, ((hv & 0xF) << 4) | (vv >> 8), vv & 0xFF,
               round(track * 256 / 360) & 0xFF, emitter]) + \
        callsign.ljust(8).encode() + bytes([0])


N825V = bytes([0x14, 0x00, 0xAB, 0x45, 0x49, 0x1F, 0xEF, 0x15, 0xA8, 0x89, 0x78,
               0x0F, 0x09, 0xA9, 0x07, 0xB0, 0x01, 0x20, 0x01, 0x4E, 0x38, 0x32,
               0x35, 0x56, 0x20, 0x20, 0x20, 0x00])

AIS1 = "!AIVDM,1,1,,A,139Lg00P1s0ef3PN`kp3K2h1P000,0*32\r\n"


def udpsend(port, datagrams):
    so = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    end = time.time() + 60
    while time.time() < end:
        for d in datagrams():
            so.sendto(d, ("127.0.0.1", port))
        time.sleep(0.2)


def nmeadatagrams():
    t = time.strftime("%H%M%S.00", time.gmtime())
    d = time.strftime("%d%m%y", time.gmtime())
    return [s.encode() for s in [
        cs("GPRMC,%s,A,5332.5920,N,00959.2560,E,6.0,90.0,%s,2.0,E,A" % (t, d)),
        cs("GPGGA,%s,5332.5920,N,00959.2560,E,1,09,0.8,4.0,M,45.0,M,," % t),
        cs("HEHDT,92.5,T"),
        AIS1,
    ]]


def gdldatagrams():
    hb = gdlframe(bytes([0x00, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00]))
    own = gdlframe(report(10, 0xA1B2C3, 40.0, -74.0, 3000, 100, 0, 90.0, 9, 1, "N123AB"))
    return [hb + own + gdlframe(N825V)]


def garmin():
    g = ["z00673", "AN 40 4106", "BW 074 2393", "C090", "D045", "E00123", "GL0012",
         "I0900", "KKJFK ", "L0900", "QW129", "S-----", "T---------", "l000123"]
    one = "\x02" + "".join(r + "\r\n" for r in g) + "\x03"
    return one + one.replace("z00673", "z00700")


def feed():
    return [
        cs("GPRMC,090000.00,A,3352.0000,S,15112.0000,E,0.0,0.0,311026,,,A"),
        cs("GPRMC,090001.00,A,3352.0010,S,15112.0000,E,0.0,0.0,311026,,,A"),
        cs("GPRMC,090002.00,V,,,,,,,311026,,,N"),
    ]


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode in ("track", "feed"):
        with open(sys.argv[2], "w") as f:
            f.write("".join(track() if mode == "track" else feed()))
    elif mode == "garmin":
        with open(sys.argv[2], "w", newline="") as f:
            f.write(garmin())
    elif mode == "port":
        so = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        so.bind(("127.0.0.1", 0))
        print(so.getsockname()[1])
    elif mode == "udpnmea":
        udpsend(int(sys.argv[2]), nmeadatagrams)
    elif mode == "udpgdl90":
        udpsend(int(sys.argv[2]), gdldatagrams)
    else:
        serve(mode, sys.argv[2])

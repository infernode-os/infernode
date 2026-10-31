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


def feed():
    return [
        cs("GPRMC,090000.00,A,3352.0000,S,15112.0000,E,0.0,0.0,311026,,,A"),
        cs("GPRMC,090001.00,A,3352.0010,S,15112.0000,E,0.0,0.0,311026,,,A"),
        cs("GPRMC,090002.00,V,,,,,,,311026,,,N"),
    ]


if __name__ == "__main__":
    if sys.argv[1] in ("track", "feed"):
        with open(sys.argv[2], "w") as f:
            f.write("".join(track() if sys.argv[1] == "track" else feed()))
    else:
        serve(sys.argv[1], sys.argv[2])

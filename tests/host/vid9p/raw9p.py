#!/usr/bin/env python3
# raw9p.py PORT COUNT N PATH: a 9P2000 client that is not a mount, for
# tests/host/vid9p_ctl_test.sh.  N connections in turn: version, attach,
# walk to PATH, open it for reading, and one Tread at offset 1 whose
# count is COUNT as given (a kernel mount never asks for more than a
# message holds; this asks for what it likes).  Prints one line each:
# "error TEXT", "data N" or "hungup".
import socket, struct, sys, time

port, count, n = int(sys.argv[1]), int(sys.argv[2], 0), int(sys.argv[3])
path = sys.argv[4].split("/")

def msg(t, tag, body):
    return struct.pack("<IBH", 7 + len(body), t, tag) + body

def s(x):
    x = x.encode()
    return struct.pack("<H", len(x)) + x

def rd(so):
    h = b""
    while len(h) < 4:
        c = so.recv(4 - len(h))
        if not c:
            return None
        h += c
    size = struct.unpack("<I", h)[0]
    b = b""
    while len(b) < size - 4:
        c = so.recv(size - 4 - len(b))
        if not c:
            return None
        b += c
    return b

for i in range(n):
    so = socket.create_connection(("127.0.0.1", port))
    so.settimeout(5)
    try:
        so.sendall(msg(100, 0xffff, struct.pack("<I", 8192) + s("9P2000"))); rd(so)
        so.sendall(msg(104, 1, struct.pack("<II", 0, 0xffffffff) + s("none") + s(""))); rd(so)
        so.sendall(msg(110, 2, struct.pack("<IIH", 0, 1, len(path)) + b"".join(s(p) for p in path))); rd(so)
        so.sendall(msg(112, 3, struct.pack("<IB", 1, 0))); rd(so)
        so.sendall(msg(116, 4, struct.pack("<IQI", 1, 1, count & 0xffffffff)))
        r = rd(so)
        if r is None:
            print("hungup")
        elif r[0] == 107:
            print("error", r[5:].decode("utf-8", "replace"))
        else:
            print("data", len(r) - 7)
    except Exception as e:
        print("hungup", e)
    so.close()
    time.sleep(0.3)

#!/usr/bin/env python3
"""A fake rtl_tcp, for tests/host/sdrfs_test.sh.

    fake_rtl_tcp.py serve LOG [TUNER]   listen on 127.0.0.1, print the port,
                                        serve one client at a time as rtl_tcp
                                        does, logging to LOG
    fake_rtl_tcp.py http                listen and answer as something that is
                                        not rtl_tcp; print the port
    fake_rtl_tcp.py busy                listen, accept and say nothing, as
                                        rtl_tcp does while another client
                                        holds it; print the port

rtl_tcp (librtlsdr) greets a client with 12 bytes, "RTL0", the tuner type
and the number of its gains (big-endian 32-bit), then sends samples until
the client hangs up: 8-bit unsigned I then Q.  It takes commands of 5
bytes, a code and a big-endian 32-bit value.  The fake paces its samples
at the rate it was last given, starting from rtl_tcp's own default of
2048000, and logs each connection, each command and each hang-up, one a
line:

    connect N
    cmd freq 1090000000        (ppm signed, the others as given)
    hangup N bytes=B

Its samples let the test check what it reads: sample k (counted from the
connection) has I = k mod 256 and Q = 255 - I, so a whole number of
samples has I + Q = 255 at every even offset and I rising by one.
"""
import socket
import struct
import sys
import threading
import time

NAMES = {1: "freq", 2: "rate", 3: "gainmode", 4: "gain", 5: "ppm",
         6: "ifgain", 7: "testmode", 8: "agc", 9: "direct", 10: "offset",
         11: "xtal", 12: "tunerxtal", 13: "gainindex", 14: "biastee"}
GAINS = {1: 14, 2: 5, 3: 23, 4: 1, 5: 29, 6: 29}

PATTERN = bytes(b for k in range(256) for b in (k, 255 - k))  # 256 samples


def listen():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(4)
    print(s.getsockname()[1], flush=True)
    return s


def serve(logpath, tuner):
    s = listen()
    log = open(logpath, "a", buffering=1)
    n = 0
    while True:
        c, _ = s.accept()
        n += 1
        log.write("connect %d\n" % n)
        client(c, n, tuner, log)


def client(c, n, tuner, log):
    state = {"rate": 2048000, "done": False}
    lock = threading.Lock()

    def commands():
        buf = b""
        while True:
            try:
                d = c.recv(4096)
            except OSError:
                d = b""
            if not d:
                break
            buf += d
            while len(buf) >= 5:
                code, v = struct.unpack(">BI", buf[:5])
                buf = buf[5:]
                if code == 5:
                    v = struct.unpack(">i", struct.pack(">I", v))[0]
                if code == 2:
                    with lock:
                        state["rate"] = v
                with lock:
                    log.write("cmd %s %d\n" % (NAMES.get(code, str(code)), v))
        state["done"] = True

    sent = 0
    try:
        c.sendall(b"RTL0" + struct.pack(">II", tuner, GAINS.get(tuner, 0)))
        t = threading.Thread(target=commands, daemon=True)
        t.start()
        start = time.monotonic()
        while not state["done"]:
            with lock:
                rate = state["rate"]
            # as many bytes as the rate allows by now, in 16 KB pieces
            due = int((time.monotonic() - start) * rate * 2)
            if due - sent < 16384:
                time.sleep(0.005)
                continue
            k = 16384
            off = sent % len(PATTERN)
            chunk = (PATTERN[off:] + PATTERN * 65)[:k]
            c.sendall(chunk)
            sent += k
    except OSError:
        pass
    c.close()
    with lock:
        log.write("hangup %d bytes=%d\n" % (n, sent))


def http():
    s = listen()
    while True:
        c, _ = s.accept()
        try:
            c.sendall(b"HTTP/1.0 400 Bad Request\r\n\r\n")
        except OSError:
            pass
        c.close()


def busy():
    s = listen()
    held = []
    while True:
        c, _ = s.accept()
        held.append(c)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "serve":
        serve(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5)
    elif len(sys.argv) == 2 and sys.argv[1] == "http":
        http()
    elif len(sys.argv) == 2 and sys.argv[1] == "busy":
        busy()
    else:
        sys.exit("usage: fake_rtl_tcp.py serve LOG [TUNER] | http | busy")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""A WebSocket server for tests/host/websocket_test.sh, standard library only.

Written from RFC 6455, apart from appl/lib/websocket.b, so the client is
checked against a second reading of the RFC rather than its own.

For each connection:
  - the upgrade: GET, Upgrade, Connection, version 13, a 16-byte key;
    the request's Authorization is logged
  - sends a text message, "hello <Authorization>", in two fragments with
    a ping between them; logs the pong (and whether it was masked)
  - then echoes every text and binary message back; logs each
  - answers a close with a close of the same code, and hangs up

Every frame from the client must be masked; one that is not is logged as
"unmasked" and the connection closed with 1002.

Prints the port it listens on, then serves until killed.
"""

import argparse
import base64
import hashlib
import socket
import ssl
import struct
import sys
import threading

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

log_lock = threading.Lock()


def log(path, line):
    with log_lock:
        with open(path, "a") as f:
            f.write(line + "\n")


def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b


def frame(op, data, fin=True):
    h = bytes([(0x80 if fin else 0) | op])
    n = len(data)
    if n < 126:
        h += bytes([n])
    elif n < 65536:
        h += bytes([126]) + struct.pack(">H", n)
    else:
        h += bytes([127]) + struct.pack(">Q", n)
    return h + data


def readframe(s):
    b0, b1 = recvn(s, 2)
    fin, op = b0 >> 7, b0 & 0xF
    masked, n = b1 >> 7, b1 & 0x7F
    if n == 126:
        (n,) = struct.unpack(">H", recvn(s, 2))
    elif n == 127:
        (n,) = struct.unpack(">Q", recvn(s, 8))
    mask = recvn(s, 4) if masked else b"\0\0\0\0"
    data = bytes(c ^ mask[i & 3] for i, c in enumerate(recvn(s, n)))
    return fin, op, masked, data


def handshake(s, logf):
    req = b""
    while b"\r\n\r\n" not in req:
        c = s.recv(1)
        if not c:
            raise EOFError
        req += c
    lines = req.decode("latin-1").split("\r\n")
    hdrs = {}
    for l in lines[1:]:
        if ":" in l:
            k, v = l.split(":", 1)
            hdrs[k.strip().lower()] = v.strip()
    ok = (lines[0].startswith("GET ") and lines[0].endswith(" HTTP/1.1")
          and hdrs.get("upgrade", "").lower() == "websocket"
          and "upgrade" in hdrs.get("connection", "").lower()
          and hdrs.get("sec-websocket-version") == "13"
          and len(base64.b64decode(hdrs.get("sec-websocket-key", ""))) == 16)
    if not ok:
        log(logf, "bad-upgrade " + lines[0])
        s.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        return None
    log(logf, "upgrade " + lines[0].split(" ")[1])
    accept = base64.b64encode(hashlib.sha1(hdrs["sec-websocket-key"].encode() + GUID).digest())
    s.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
              b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
    return hdrs


def serve(s, logf):
    try:
        hdrs = handshake(s, logf)
        if hdrs is None:
            return
        auth = hdrs.get("authorization", "")
        log(logf, "authorization " + auth)
        hello = ("hello " + auth).encode()
        s.sendall(frame(0x1, hello[:5], fin=False) + frame(0x9, b"are-you-there")
                  + frame(0x0, hello[5:]))
        while True:
            fin, op, masked, data = readframe(s)
            if not masked:
                log(logf, "unmasked")
                s.sendall(frame(0x8, struct.pack(">H", 1002)))
                return
            if op == 0xA:
                log(logf, "pong " + data.decode())
            elif op == 0x1:
                log(logf, "text " + data.decode())
                s.sendall(frame(0x1, data))
            elif op == 0x2:
                log(logf, "binary %d %s" % (len(data), hashlib.sha256(data).hexdigest()[:16]))
                s.sendall(frame(0x2, data))
            elif op == 0x8:
                code = struct.unpack(">H", data[:2])[0] if len(data) >= 2 else 1005
                log(logf, "close %d %s" % (code, data[2:].decode()))
                s.sendall(frame(0x8, data[:2]))
                return
    except (EOFError, ConnectionError, ssl.SSLError) as e:
        log(logf, "gone " + type(e).__name__)
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cert")
    ap.add_argument("--key")
    ap.add_argument("--log", required=True)
    a = ap.parse_args()
    ctx = None
    if a.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(a.cert, a.key)
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", 0))
    ls.listen(8)
    print(ls.getsockname()[1], flush=True)
    while True:
        c, _ = ls.accept()
        if ctx:
            try:
                c = ctx.wrap_socket(c, server_side=True)
            except (ssl.SSLError, OSError) as e:
                log(a.log, "tls-refused " + type(e).__name__)
                c.close()
                continue
        threading.Thread(target=serve, args=(c, a.log), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())

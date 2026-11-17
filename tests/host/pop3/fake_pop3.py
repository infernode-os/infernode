#!/usr/bin/env python3
#
# A fake POP3 server for tests/host/pop3_tls_test.sh, over TLS from the
# start (as port 995 is): USER, PASS, STAT, LIST, UIDL, RETR, TOP, DELE,
# QUIT, for a mailbox of two messages.  It prints its port, then serves
# one connection after another until killed.  Each command goes to --log,
# a line each, PASS's password left out.
#
# --scen:
#   ok        as above
#   ssl3      no TLS: a ClientHello is answered with an SSL 3.0 ServerHello
#             that has an empty session id and names RC4_128_MD5, then a
#             ChangeCipherSpec, which is how a server with no key or
#             certificate finished a handshake with the SSL 3.0 client POP3
#             used.  What the client sends after it is logged, a record a
#             line: "record 21" is its alert; "record 23" would be data.
#   longline  message 1 has a line of 5000 bytes
#   nouidl    UIDL's ids are paths ("../../x")
#   stall     PASS is never answered
#
# usage: fake_pop3.py --cert C --key K --log F [--scen S]

import argparse, os, socket, ssl, struct, threading, time

MSGS = [
    b"From: alice@example.com\r\nSubject: one\r\n\r\nFirst message.\r\n.. a line that began with a dot\r\n",
    b"From: carol@example.org\r\nSubject: two\r\n\r\nSecond message.\r\n",
]


def serve(f, log, scen):
    def send(s):
        f.write(s if isinstance(s, bytes) else s.encode())
        f.flush()

    send("+OK fake POP3 ready\r\n")
    while True:
        l = f.readline()
        if not l:
            return
        l = l.decode(errors="replace").rstrip("\r\n")
        verb, _, arg = l.partition(" ")
        verb = verb.upper()
        log.write("%s%s\n" % (verb, "" if verb == "PASS" or not arg else " " + arg))
        log.flush()
        if verb == "USER":
            send("+OK\r\n")
        elif verb == "PASS":
            if scen == "stall":
                time.sleep(120)
                return
            send("+OK logged in\r\n" if arg == "x" else "-ERR no: %s\r\n" % arg)
        elif verb == "STAT":
            send("+OK %d %d\r\n" % (len(MSGS), sum(len(m) for m in MSGS)))
        elif verb == "LIST":
            send("+OK\r\n" + "".join("%d %d\r\n" % (i + 1, len(m)) for i, m in enumerate(MSGS)) + ".\r\n")
        elif verb == "UIDL" and arg:
            send("+OK %s %s\r\n" % (arg, "../../x" if scen == "nouidl" else "uid" + arg))
        elif verb == "UIDL":
            send("+OK\r\n" + "".join("%d uid%d\r\n" % (i + 1, i + 1) for i in range(len(MSGS))) + ".\r\n")
        elif verb in ("RETR", "TOP"):
            m = MSGS[int(arg.split()[0]) - 1]
            if scen == "longline" and arg.split()[0] == "1":
                m += b"x" * 5000 + b"\r\n"
            send(b"+OK\r\n" + m + b".\r\n")
        elif verb == "DELE":
            send("+OK deleted\r\n")
        elif verb == "QUIT":
            send("+OK bye\r\n")
            return
        else:
            send("-ERR unknown\r\n")


def ssl3(c, log):
    c.settimeout(10)
    h = c.recv(5)
    if len(h) == 5:
        n = struct.unpack(">H", h[3:5])[0]
        while n > 0:
            d = c.recv(n)
            if not d:
                break
            n -= len(d)
    hello = b"\x03\x00" + os.urandom(32) + b"\x00" + b"\x00\x04" + b"\x00"
    hs = b"\x02" + len(hello).to_bytes(3, "big") + hello
    c.sendall(b"\x16\x03\x00" + struct.pack(">H", len(hs)) + hs)
    c.sendall(b"\x14\x03\x00\x00\x01\x01")
    try:
        while True:
            h = c.recv(5)
            if len(h) < 5:
                break
            n = struct.unpack(">H", h[3:5])[0]
            body = b""
            while len(body) < n:
                d = c.recv(n - len(body))
                if not d:
                    break
                body += d
            log.write("record %d\n" % h[0])
            log.flush()
    except OSError:
        pass
    log.write("closed\n")
    log.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--scen", default="ok")
    a = ap.parse_args()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    log = open(a.log, "a")
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(4)
    print(s.getsockname()[1], flush=True)

    def handle(c):
        c.settimeout(150)
        try:
            if a.scen == "ssl3":
                ssl3(c, log)
                return
            serve(ctx.wrap_socket(c, server_side=True).makefile("rwb"), log, a.scen)
        except (ssl.SSLError, OSError, ValueError, IndexError) as e:
            log.write("error %s\n" % e)
            log.flush()
        finally:
            try:
                c.close()
            except OSError:
                pass

    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()

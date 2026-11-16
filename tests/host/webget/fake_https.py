#!/usr/bin/env python3
#
# An HTTPS server for tests/host/webget_https_test.sh: any GET is answered
# with one short page (its Content-Length given).  It prints its port,
# then serves one connection after another until killed; each request's
# first line goes to --log.
#
# usage: fake_https.py --cert C --key K --log F

import argparse, socket, ssl, threading

BODY = b"webget fetched this over TLS\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--log", required=True)
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
        c.settimeout(30)
        try:
            t = ctx.wrap_socket(c, server_side=True)
            f = t.makefile("rwb")
            first = f.readline().decode(errors="replace").rstrip("\r\n")
            log.write("%s\n" % first)
            log.flush()
            while True:
                l = f.readline()
                if not l or l in (b"\r\n", b"\n"):
                    break
            f.write(b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n" % len(BODY) + BODY)
            f.flush()
            try:
                t.unwrap()
            except (ssl.SSLError, OSError):
                pass
        except (ssl.SSLError, OSError) as e:
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

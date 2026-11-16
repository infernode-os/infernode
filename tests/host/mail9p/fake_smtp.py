#!/usr/bin/env python3
#
# A fake SMTP submission server for tests/host/mail9p_imap_test.sh: TLS
# from the start (--mode tls), STARTTLS offered and taken (--mode
# starttls), not offered (--mode nostarttls), or offered and refused
# (--mode refuse).  EHLO, AUTH PLAIN, MAIL, RCPT, DATA, RSET, QUIT.
#
# It prints its port, then serves one connection after another until
# killed.  Each command goes to --log, a line each: AUTH as the user it
# names (never the password), DATA as the message's Subject line, and
# what a client sent after it was refused STARTTLS.  With --wire F every
# line received goes to F as Python shows its bytes, "cmd b'...'" for a
# command and "data b'...'" for a line of a message (the credential
# line as "cred"), for tests that look at what is on the wire.
#
# --scen makes it a server that is broken or refuses, for
# tests/host/mail9p_hostile_test.sh:
#   authfail   the credentials are refused (535)
#   authstall  the credentials are never answered
#   authecho   they are refused in a reply that says them back
#   blank      EHLO's reply is followed by an empty line
#   data250    DATA is answered 250, not 354
#
# usage: fake_smtp.py --mode tls|starttls|nostarttls|refuse --cert C --key K --log F
#            [--wire F] [--scen S]

import argparse, base64, socket, ssl, threading, time

SCEN = "ok"
WIRE = None


def serve(f, log, intls, mode):
    def send(s):
        f.write(s.encode())
        f.flush()

    def line(what="cmd"):
        l = f.readline()
        if l and WIRE is not None:
            if what == "cred":
                WIRE.write("cred\n")
            else:
                WIRE.write("%s %r\n" % (what, l))
            WIRE.flush()
        return None if not l else l.decode(errors="replace").rstrip("\r\n")

    while True:
        l = line()
        if l is None:
            return None
        verb = l.split(" ", 1)[0].upper()
        if verb == "AUTH":
            log.write("AUTH PLAIN\n")
            send("334 \r\n")
            cred = line("cred") or ""
            creds = base64.b64decode(cred).split(b"\0")
            log.write("user %s\n" % (creds[1].decode() if len(creds) == 3 else "?"))
            log.flush()
            if SCEN == "authfail":
                send("535 5.7.8 bad credentials\r\n")
            elif SCEN == "authecho":
                send("535 5.7.8 %s is not accepted\r\n" % cred)
            elif SCEN == "authstall":
                time.sleep(120)
                return None
            else:
                send("235 2.7.0 Authentication successful\r\n")
        elif verb == "DATA" and SCEN == "data250":
            log.write("DATA\n")
            send("250 2.0.0 Ok\r\n")
        elif verb == "DATA":
            log.write("DATA\n")
            send("354 End data with <CR><LF>.<CR><LF>\r\n")
            while True:
                d = line("data")
                if d is None or d == ".":
                    break
                if d.lower().startswith("subject:"):
                    log.write("data %s\n" % d)
            send("250 2.0.0 Ok: queued\r\n")
        else:
            log.write("%s\n" % l)
            if verb == "EHLO":
                send("250-fake.smtp\r\n")
                if not intls and mode in ("starttls", "refuse"):
                    send("250-STARTTLS\r\n")
                send("250 AUTH PLAIN\r\n")
                if SCEN == "blank":
                    send("\n")
            elif verb == "STARTTLS" and not intls:
                if mode == "refuse":
                    send("454 4.7.0 TLS not available\r\n")
                    return "refused"
                send("220 2.0.0 Ready to start TLS\r\n")
                return "tls"
            elif verb == "QUIT":
                send("221 2.0.0 Bye\r\n")
                return None
            else:
                send("250 2.0.0 Ok\r\n")
        log.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["tls", "starttls", "nostarttls", "refuse"], required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--wire")
    ap.add_argument("--scen", default="ok")
    a = ap.parse_args()
    global SCEN, WIRE
    SCEN = a.scen
    if a.wire:
        WIRE = open(a.wire, "a")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    log = open(a.log, "a")
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(4)
    print(s.getsockname()[1], flush=True)
    # one thread a connection: a session left open (an account not
    # disconnected) does not keep the next waiting
    def handle(c):
        c.settimeout(150)
        try:
            if a.mode == "tls":
                f = ctx.wrap_socket(c, server_side=True).makefile("rwb")
                f.write(b"220 fake.smtp ESMTP\r\n")
                f.flush()
                serve(f, log, True, a.mode)
                return
            f = c.makefile("rwb", buffering=0)
            f.write(b"220 fake.smtp ESMTP\r\n")
            r = serve(f, log, False, a.mode)
            if r == "tls":
                f = ctx.wrap_socket(c, server_side=True).makefile("rwb")
                serve(f, log, True, a.mode)
            elif r == "refused" or a.mode == "nostarttls":
                # what a client sends after: nothing, if it gave up
                rest = b""
                try:
                    while True:
                        d = c.recv(4096)
                        if not d:
                            break
                        rest += d
                except OSError:
                    pass
                log.write("after: %s\n" % (rest.decode(errors="replace").strip().replace("\r\n", " | ") or "nothing"))
        except (ssl.SSLError, OSError, ValueError) as e:
            log.write("error %s\n" % e)
        finally:
            log.flush()
            try:
                c.close()
            except OSError:
                pass

    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()

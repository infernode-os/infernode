#!/usr/bin/env python3
#
# A fake IMAP server for tests/host/mail9p_imap_test.sh: enough of RFC 3501
# for mail9p's account files (LOGIN, LIST, SELECT, FETCH of the message
# list and of a message, SEARCH, STORE, COPY, LOGOUT), over TLS from the
# start (--mode tls), over STARTTLS (--mode starttls), or refusing
# STARTTLS (--mode refuse).  Two messages in INBOX; INBOX and Archive.
#
# It prints the port it listens on, then serves one connection after
# another until killed.  Every command is written to --log, a line each,
# LOGIN's password left out.
#
# usage: fake_imap.py --mode tls|starttls|refuse --cert C --key K --log F

import argparse, socket, ssl, sys

MSGS = [
    {"uid": 101, "flags": ["\\Seen"],
     "date": "Mon, 26 Oct 2026 10:00:00 +0000",
     "from": ("Alice Example", "alice", "example.com"),
     "to": ("Bob", "bob", "example.com"),
     "subject": "Lunch on Friday",
     "body": "Shall we meet at noon?\r\n"},
    {"uid": 102, "flags": [],
     "date": "Tue, 27 Oct 2026 09:30:00 +0000",
     "from": ("Carol", "carol", "example.org"),
     "to": ("Bob", "bob", "example.com"),
     "subject": "The report",
     "body": "It is attached, in spirit.\r\n"},
]
BOXES = ["INBOX", "Archive"]


def raw(m):
    n, u, h = m["from"]
    tn, tu, th = m["to"]
    return ("Date: %s\r\nFrom: %s <%s@%s>\r\nTo: %s <%s@%s>\r\n"
            "Subject: %s\r\nMessage-ID: <%d@fake>\r\n\r\n%s"
            % (m["date"], n, u, h, tn, tu, th, m["subject"], m["uid"],
               m["body"])).encode()


def envelope(m):
    def addr(a):
        return '(("%s" NIL "%s" "%s"))' % a
    f = addr(m["from"])
    return '("%s" "%s" %s %s %s %s NIL NIL NIL "<%d@fake>")' % (
        m["date"], m["subject"], f, f, f, addr(m["to"]), m["uid"])


class Session:
    def __init__(self, f, log):
        self.f = f
        self.log = log
        self.selected = None

    def send(self, s):
        if isinstance(s, str):
            s = s.encode()
        self.f.write(s)
        self.f.flush()

    def line(self):
        l = self.f.readline()
        if not l:
            return None
        return l.decode(errors="replace").rstrip("\r\n")

    def run(self):
        while True:
            l = self.line()
            if l is None:
                return
            parts = l.split(" ", 2)
            tag = parts[0]
            cmd = parts[1].upper() if len(parts) > 1 else ""
            args = parts[2] if len(parts) > 2 else ""
            if cmd == "LOGIN":
                self.log.write("LOGIN %s\n" % args.split(" ")[0])
            else:
                self.log.write("%s %s\n" % (cmd, args))
            self.log.flush()
            if not self.command(tag, cmd, args):
                return

    def command(self, tag, cmd, args):
        if cmd == "LOGIN":
            a = args.split(" ")
            if len(a) == 2 and a[0].strip('"') == "alice" and a[1].strip('"') == "x":
                self.send("%s OK LOGIN completed\r\n" % tag)
            else:
                self.send("%s NO [AUTHENTICATIONFAILED] Invalid credentials\r\n" % tag)
        elif cmd == "LIST":
            for b in BOXES:
                self.send('* LIST (\\HasNoChildren) "/" "%s"\r\n' % b)
            self.send("%s OK LIST completed\r\n" % tag)
        elif cmd == "SELECT":
            box = args.strip('"')
            if box not in BOXES:
                self.send("%s NO no such mailbox\r\n" % tag)
                return True
            self.selected = box
            n = len(MSGS) if box == "INBOX" else 0
            unseen = sum(1 for m in MSGS if "\\Seen" not in m["flags"])
            self.send("* %d EXISTS\r\n* 0 RECENT\r\n" % n)
            if box == "INBOX":
                self.send("* OK [UNSEEN %d]\r\n" % unseen)
            self.send("* OK [UIDVALIDITY 7]\r\n* OK [UIDNEXT 103]\r\n")
            self.send("%s OK [READ-WRITE] SELECT completed\r\n" % tag)
        elif cmd == "FETCH":
            seqs, what = args.split(" ", 1)
            if "ENVELOPE" in what:
                lo, hi = (int(x) for x in seqs.split(":"))
                for i in range(lo, hi + 1):
                    m = MSGS[i - 1]
                    self.send("* %d FETCH (FLAGS (%s) UID %d RFC822.SIZE %d ENVELOPE %s)\r\n"
                              % (i, " ".join(m["flags"]), m["uid"], len(raw(m)), envelope(m)))
            else:
                i = int(seqs)
                b = raw(MSGS[i - 1])
                if what.startswith("BODY[HEADER]"):
                    b = b[:b.index(b"\r\n\r\n") + 4]
                self.send(b"* %d FETCH (%s {%d}\r\n" % (i, what.encode(), len(b)) + b + b")\r\n")
            self.send("%s OK FETCH completed\r\n" % tag)
        elif cmd == "SEARCH":
            hits = [str(i + 1) for i, m in enumerate(MSGS)
                    if args.upper().startswith("FROM ")
                    and args.split(" ", 1)[1].strip('"').lower() in m["from"][1]]
            self.send("* SEARCH%s\r\n" % "".join(" " + h for h in hits))
            self.send("%s OK SEARCH completed\r\n" % tag)
        elif cmd == "STORE":
            seq, action, flags = args.split(" ", 2)
            m = MSGS[int(seq) - 1]
            fl = flags.strip("()").split()
            if action.startswith("+"):
                m["flags"] = sorted(set(m["flags"]) | set(fl))
            elif action.startswith("-"):
                m["flags"] = [f for f in m["flags"] if f not in fl]
            else:
                m["flags"] = fl
            self.send("* %s FETCH (FLAGS (%s))\r\n" % (seq, " ".join(m["flags"])))
            self.send("%s OK STORE completed\r\n" % tag)
        elif cmd == "COPY":
            self.send("%s OK COPY completed\r\n" % tag)
        elif cmd == "LOGOUT":
            self.send("* BYE logging out\r\n%s OK LOGOUT completed\r\n" % tag)
            return False
        else:
            self.send("%s OK %s completed\r\n" % (tag, cmd))
        return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["tls", "starttls", "refuse"], required=True)
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
    while True:
        c, _ = s.accept()
        c.settimeout(30)
        try:
            if a.mode == "tls":
                t = ctx.wrap_socket(c, server_side=True)
                f = t.makefile("rwb")
                f.write(b"* OK [CAPABILITY IMAP4rev1] fake ready\r\n")
                f.flush()
            else:
                c.sendall(b"* OK [CAPABILITY IMAP4rev1 STARTTLS] fake ready\r\n")
                buf = b""
                while b"\r\n" not in buf:
                    d = c.recv(1)
                    if not d:
                        raise EOFError
                    buf += d
                tag, cmd = (buf.decode().split() + ["", ""])[:2]
                log.write("%s\n" % cmd)
                log.flush()
                if a.mode == "refuse" or cmd.upper() != "STARTTLS":
                    c.sendall(b"%s NO STARTTLS not offered\r\n" % tag.encode())
                    rest = c.recv(4096)
                    log.write("after NO: %s\n" % (rest.decode(errors="replace").strip() or "nothing"))
                    log.flush()
                    c.close()
                    continue
                c.sendall(b"%s OK Begin TLS negotiation now\r\n" % tag.encode())
                t = ctx.wrap_socket(c, server_side=True)
                f = t.makefile("rwb")
            Session(f, log).run()
        except (ssl.SSLError, OSError, EOFError, ValueError, IndexError) as e:
            log.write("error %s\n" % e)
            log.flush()
        finally:
            try:
                c.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()

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
# With --expunge FILE (tests/host/msg_email_bind_test.sh): when FILE
# appears holding a UID, that message is gone before the next command and
# the ones after it have moved down a sequence number, as a session sees
# after another client's expunge.  SEARCH UID n answers with the
# message's sequence number.
#
# The commands by UID (UID FETCH, UID STORE, UID COPY, UID SEARCH) act on
# the message with that UID, and say nothing of one that has gone.
#
# --msgs 3 adds a third message, from Mallory with a Reply-To elsewhere;
# --who X marks the subjects and bodies, so that two servers' mail differs.
# --validity N is the mailbox's UIDVALIDITY (7 without it).
#
# --scen makes it a server that is hostile or broken, for
# tests/host/mail9p_hostile_test.sh (all need --msgs 3):
#   exists     SELECT says 2147483647 messages exist
#   biglit     LIST's answer begins a literal of 1.5GB and stops
#   backslash  message 2's envelope is a quoted string ending in a backslash
#   spoof      message 3's subject is a literal holding the rest of an
#              envelope: a From and Reply-To of its sender's choosing
#   tagforge   message 2's line has two literals, the second "A004 OK ..."
#   envcrlf    message 3's subject is a literal holding the rest of an
#              envelope, with CR LF in its address and its message id
#   addrcrlf   message 3's address and id are literals with CR LF in them
#   unsol      a message's text is followed by another message's, unasked
#   stall      SELECT is never answered
#   close      the connection is closed in answer to SELECT
#   idleclose  the first connection is closed after the list's FETCH, as
#              a server closes one left idle
#   novalidity each SELECT has a new UIDVALIDITY
#
# usage: fake_imap.py --mode tls|starttls|refuse --cert C --key K --log F
#            [--expunge FILE] [--msgs 3] [--who X] [--scen S] [--validity N]

import argparse, os, socket, ssl, sys, threading, time

EXPUNGE = None
SCEN = "base"
CONNS = 0
VALIDITY = 7


def expunge():
    if EXPUNGE is None or not os.path.exists(EXPUNGE):
        return
    try:
        uid = int(open(EXPUNGE).read().strip())
    except ValueError:
        return
    os.remove(EXPUNGE)
    MSGS[:] = [m for m in MSGS if m["uid"] != uid]

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


MALLORY = {"uid": 103, "flags": [],
           "date": "Wed, 28 Oct 2026 08:00:00 +0000",
           "from": ("Mallory", "mallory", "evil.example"),
           "to": ("Bob", "bob", "example.com"),
           "replyto": ("Collector", "collector", "elsewhere.example"),
           "subject": "Figures",
           "body": "Send me the figures.\r\n"}


def raw(m):
    n, u, h = m["from"]
    tn, tu, th = m["to"]
    return ("Date: %s\r\nFrom: %s <%s@%s>\r\nTo: %s <%s@%s>\r\n"
            "Subject: %s\r\nMessage-ID: <%d@fake>\r\n\r\n%s"
            % (m["date"], n, u, h, tn, tu, th, m["subject"], m["uid"],
               m["body"])).encode()


def addr(a):
    return '(("%s" NIL "%s" "%s"))' % a


def envelope(m):
    f = addr(m["from"])
    r = addr(m["replyto"]) if "replyto" in m else f
    return '("%s" "%s" %s %s %s %s NIL NIL NIL "<%d@fake>")' % (
        m["date"], m["subject"], f, f, r, addr(m["to"]), m["uid"])


# One line of the message list: the message's own, or a scenario's.
def listline(i, m):
    date = m["date"].encode()
    f = addr(m["from"]).encode()
    to = addr(m["to"]).encode()
    head = b'* %d FETCH (UID %d FLAGS () RFC822.SIZE 9 ENVELOPE ("%s" ' % (i, m["uid"], date)
    if SCEN == "backslash" and m["uid"] == 102:
        return b'* %d FETCH (FLAGS () UID %d RFC822.SIZE 9 ENVELOPE ("x\\\r\n' % (i, m["uid"])
    if SCEN == "spoof" and m["uid"] == 103:
        # a subject sent as a literal, as servers send one with a quote
        # in it: the sender's bytes, here the rest of an envelope
        subj = b'(("Alice Example" NIL "alice" "example.com")) NIL NIL NIL NIL NIL NIL "<x>" "'
        return (head + b'{%d}\r\n' % len(subj) + subj + b' ' + f + b' ' + f + b' ' + f + b' ' + to
                + b' NIL NIL NIL "<103@fake>"))\r\n')
    if SCEN == "tagforge" and m["uid"] == 102:
        subj = b'say "hi"'
        name = b'A004 OK "x'
        return (head + b'{%d}\r\n' % len(subj) + subj + b' (({%d}\r\n' % len(name) + name
                + b' NIL "carol" "example.org")) NIL NIL NIL NIL NIL NIL "<102@fake>"))\r\n')
    if SCEN == "envcrlf" and m["uid"] == 103:
        subj = (b'(("" NIL "mallory" "evil.example>\r\nRCPT TO:<victim@third.example")) NIL NIL NIL NIL NIL NIL '
                b'"<103@fake>\r\nX-Injected: yes" "')
        return (head + b'{%d}\r\n' % len(subj) + subj + b' NIL NIL NIL NIL NIL NIL NIL NIL))\r\n')
    if SCEN == "addrcrlf" and m["uid"] == 103:
        mbox = b'mallory'
        host = b'evil.example>\r\nRCPT TO:<victim@third.example'
        mid = b'<103@fake>\r\nX-Injected: yes'
        a = b'((NIL NIL {%d}\r\n' % len(mbox) + mbox + b' {%d}\r\n' % len(host) + host + b'))'
        return (head + b'"Figures" ' + a + b' ' + a + b' ' + a + b' ' + to
                + b' NIL NIL NIL {%d}\r\n' % len(mid) + mid + b'))\r\n')
    return ("* %d FETCH (FLAGS (%s) UID %d RFC822.SIZE %d ENVELOPE %s)\r\n"
            % (i, " ".join(m["flags"]), m["uid"], len(raw(m)), envelope(m))).encode()


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
            expunge()
            if not self.command(tag, cmd, args):
                return

    def byuid(self, uid):
        for i, m in enumerate(MSGS):
            if str(m["uid"]) == uid:
                return i + 1, m
        return 0, None

    def uidcommand(self, tag, args):
        global VALIDITY
        sub, _, rest = args.partition(" ")
        sub = sub.upper()
        if sub == "SEARCH":
            hits = [str(m["uid"]) for m in MSGS
                    if rest.upper() == "ALL" or rest.upper().startswith("FROM ")
                    and rest.split(" ", 1)[1].strip('"').lower() in m["from"][1]]
            self.send("* SEARCH%s\r\n" % "".join(" " + h for h in hits))
        elif sub == "FETCH":
            uid, what = rest.split(" ", 1)
            i, m = self.byuid(uid)
            if m is not None:
                b = raw(m)
                self.send(b"* %d FETCH (UID %d BODY[] {%d}\r\n" % (i, m["uid"], len(b)) + b + b")\r\n")
                if SCEN == "unsol":
                    # another message's text, which nobody asked for
                    o = raw(MSGS[0])
                    self.send(b"* 1 FETCH (FLAGS (\\Seen) BODY[] {%d}\r\n" % len(o) + o + b")\r\n")
        elif sub == "STORE":
            uid, action, flags = rest.split(" ", 2)
            i, m = self.byuid(uid)
            if m is not None:
                fl = flags.strip("()").split()
                if action.startswith("+"):
                    m["flags"] = sorted(set(m["flags"]) | set(fl))
                elif action.startswith("-"):
                    m["flags"] = [f for f in m["flags"] if f not in fl]
                self.send("* %d FETCH (UID %d FLAGS (%s))\r\n" % (i, m["uid"], " ".join(m["flags"])))
        elif sub == "COPY":
            pass
        else:
            self.send("%s BAD UID %s\r\n" % (tag, sub))
            return True
        self.send("%s OK UID %s completed\r\n" % (tag, sub))
        return True

    def command(self, tag, cmd, args):
        global VALIDITY
        if cmd == "UID":
            return self.uidcommand(tag, args)
        if cmd == "LOGIN":
            a = args.split(" ")
            if len(a) == 2 and a[0].strip('"') in ("alice", "alice@example.com") and a[1].strip('"') == "x":
                self.send("%s OK LOGIN completed\r\n" % tag)
            else:
                self.send("%s NO [AUTHENTICATIONFAILED] Invalid credentials\r\n" % tag)
        elif cmd == "LIST":
            if SCEN == "biglit":
                self.send("* OK {1500000000}\r\n")
                time.sleep(120)
                return False
            for b in BOXES:
                self.send('* LIST (\\HasNoChildren) "/" "%s"\r\n' % b)
            self.send("%s OK LIST completed\r\n" % tag)
        elif cmd == "SELECT":
            box = args.strip('"')
            if box not in BOXES:
                self.send("%s NO no such mailbox\r\n" % tag)
                return True
            if SCEN == "stall":
                time.sleep(120)
                return False
            if SCEN == "close":
                self.log.write("closing without an answer\n")
                self.log.flush()
                return False
            self.selected = box
            n = len(MSGS) if box == "INBOX" else 0
            if SCEN == "exists":
                n = 2147483647
            if SCEN == "novalidity":
                VALIDITY += 1
            unseen = sum(1 for m in MSGS if "\\Seen" not in m["flags"])
            self.send("* %d EXISTS\r\n* 0 RECENT\r\n" % n)
            if box == "INBOX":
                self.send("* OK [UNSEEN %d]\r\n" % unseen)
            self.send("* OK [UIDVALIDITY %d]\r\n* OK [UIDNEXT 104]\r\n" % VALIDITY)
            self.send("%s OK [READ-WRITE] SELECT completed\r\n" % tag)
        elif cmd == "FETCH":
            seqs, what = args.split(" ", 1)
            if "ENVELOPE" in what:
                lo, hi = (int(x) for x in seqs.split(":"))
                for i in range(lo, min(hi, len(MSGS)) + 1):
                    self.send(listline(i, MSGS[i - 1]))
                if SCEN == "idleclose" and CONNS == 1:
                    self.send("%s OK FETCH completed\r\n" % tag)
                    self.log.write("closing the idle connection\n")
                    self.log.flush()
                    time.sleep(0.5)
                    return False
            else:
                i = int(seqs)
                b = raw(MSGS[i - 1])
                if what.startswith("BODY[HEADER]"):
                    b = b[:b.index(b"\r\n\r\n") + 4]
                self.send(b"* %d FETCH (%s {%d}\r\n" % (i, what.encode(), len(b)) + b + b")\r\n")
                if SCEN == "unsol":
                    o = raw(MSGS[0])
                    self.send(b"* 1 FETCH (FLAGS (\\Seen) BODY[] {%d}\r\n" % len(o) + o + b")\r\n")
            self.send("%s OK FETCH completed\r\n" % tag)
        elif cmd == "SEARCH" and args.upper().startswith("UID "):
            hits = [str(i + 1) for i, m in enumerate(MSGS)
                    if str(m["uid"]) == args.split(" ", 1)[1].strip()]
            self.send("* SEARCH%s\r\n" % "".join(" " + h for h in hits))
            self.send("%s OK SEARCH completed\r\n" % tag)
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
    ap.add_argument("--expunge")
    ap.add_argument("--msgs", type=int, default=2)
    ap.add_argument("--who", default="")
    ap.add_argument("--scen", default="base")
    ap.add_argument("--validity", type=int)
    a = ap.parse_args()
    global EXPUNGE, SCEN, VALIDITY
    if a.validity is not None:
        VALIDITY = a.validity
    EXPUNGE = a.expunge
    SCEN = a.scen
    if a.msgs >= 3:
        MSGS.append(MALLORY)
        BOXES.append("Sent")
    if a.who:
        for m in MSGS:
            m["subject"] = a.who + " " + m["subject"]
            m["body"] = a.who + " " + m["body"]
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
        global CONNS
        CONNS += 1
        c.settimeout(150)
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
                    return
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

    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()

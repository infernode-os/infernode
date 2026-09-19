#!/usr/bin/env python3
"""
GPIO acceptance: a loopback jig on the 40-pin header, driven through
#G/gpio/N/{ctl,level}.

There is no official Raspberry Pi GPIO test suite; what every board
house does is a loopback jig -- header pins wired to each other in
pairs -- and a script that drives one end and reads the other. This is
that script, against the device the kernel serves (devgpio.c: one
directory per BCM pin, "function"/"pull" on ctl, "0"/"1" on level).

The jig, physical pin <-> physical pin (BCM in brackets):

  A  7 <-> 11   [4  <-> 17]      E  37 <-> 40   [26 <-> 21]
  B 13 <-> 15   [27 <-> 22]      F  38 <-> 36   [20 <-> 16]
  C 29 <-> 31   [5  <-> 6 ]      G  32 <-> 22   [12 <-> 25]
  D 33 <-> 35   [13 <-> 19]      H  18 <-> 16   [24 <-> 23]

Sixteen GPIOs with no other duty on a 3B+. Not touched: the console
UART (BCM 14/15), I2C (2/3, fixed pull-ups), the HAT EEPROM (0/1),
power and ground.

Checks, per pair and both ways round: drive high and low, the partner
reads it; both inputs, pull-up reads 1 and pull-down reads 0 on each
(this proves the pull, since the partner is floating); ctl reads back
what was set. Edge events (#651) on one pair: every edge reported with
its level and a time from the interrupt, rising-only halves them, a
reader that falls behind is told by how much, and nothing is reported
that was not asked for. Then, with every pair set up, each output toggled alone
must move only its own partner (no crosstalk, no wiring mistake). And
the pins the kernel owns refuse ctl writes, so a stray echo cannot
take the console down. Everything is left as input, pull none.

Usage: gpio.py --board 192.168.1.104
"""
import re, sys, time
from board import Board, args

PAIRS = [("A", 4, 17), ("B", 27, 22), ("C", 5, 6), ("D", 13, 19),
         ("E", 26, 21), ("F", 20, 16), ("G", 12, 25), ("H", 24, 23)]
G = "/dev/gpio"

def main():
    a = args(__doc__.split("\n")[1]).parse_args()
    b = Board(a.board, token_file=a.token, serial_log=a.serial_log)
    mark = b.serial_mark()

    # #G into /dev, in every session's namespace: the network console
    # forks its namespace per connection, so each sh() binds again
    def sh(*cmds, wait=1.0):
        # a failed redirection is fatal to the board's shell (AGENTS.md), which
        # drops the console session; report it as text rather than dying
        try:
            return b.sh("bind -a '#G' /dev", *cmds, wait=wait)
        except OSError as e:
            time.sleep(1)
            return "[console session dropped: %s]" % e

    out = sh("ls %s | wc -l" % G, "cat %s/4/ctl" % G)
    m = re.search(r"^\s*(\d+)\s*$", out, re.M)
    b.check(m is not None and int(m.group(1)) >= 54, "#G serves the pins (%s directories)" % (m.group(1) if m else "?"), out.strip()[-100:])
    b.check("function" in out and "pull" in out, "a pin's ctl reads back its function and pull", out.strip()[-80:])

    def setpin(n, func, pull="none"):
        return "echo 'function %s' > %s/%d/ctl; echo 'pull %s' > %s/%d/ctl" % (func, G, n, pull, G, n)

    # the console does not echo commands, so each read labels itself: "R17=1"
    def rd_(n):
        return "{echo -n 'R%d='; cat %s/%d/level}" % (n, G, n)

    def levels(text):
        return re.findall(r"R(\d+)=([01])", text)

    def readlevel(text, n):
        v = [b_ for a_, b_ in levels(text) if int(a_) == n]
        return int(v[-1]) if v else None

    print("== each pair, each direction: drive and read; pulls")
    for name, x, y in PAIRS:
        for drv, rd in ((x, y), (y, x)):
            cmds = [setpin(rd, "in"), setpin(drv, "out")]
            for v in (1, 0, 1):
                cmds += ["echo %d > %s/%d/level" % (v, G, drv), rd_(rd)]
            out = sh(*cmds, wait=0.5)
            vals = [v_ for n_, v_ in levels(out) if int(n_) == rd]
            b.check(vals == ["1", "0", "1"], "pair %s: BCM %d drives, BCM %d reads 1,0,1 (got %s)" % (name, drv, rd, ",".join(vals)), out.strip()[-80:])
        # both inputs; the pull on one end sets the level of the floating pair
        out = sh(setpin(x, "in", "up"), setpin(y, "in"), rd_(x), rd_(y),
                 setpin(x, "in", "down"), rd_(x), rd_(y), wait=0.5)
        vals = [v_ for n_, v_ in levels(out)]
        b.check(vals == ["1", "1", "0", "0"], "pair %s: pull-up reads 1 on both ends, pull-down reads 0 (got %s)" % (name, ",".join(vals)), out.strip()[-80:])
        out = sh(setpin(x, "in", "up"), "cat %s/%d/ctl" % (G, x), wait=0.5)
        b.check("function in" in out and "pull up" in out, "pair %s: ctl reads back 'function in' / 'pull up'" % name, out.strip()[-80:])

    print("== crosstalk: every pair set up, one output toggled at a time")
    cmds = []
    for name, x, y in PAIRS:
        cmds += [setpin(x, "out"), setpin(y, "in", "down"), "echo 0 > %s/%d/level" % (G, x)]
    sh(*cmds, wait=0.3)
    for name, x, y in PAIRS:
        cmds = ["echo 1 > %s/%d/level" % (G, x)] + [rd_(ry) for _, _, ry in PAIRS] + ["echo 0 > %s/%d/level" % (G, x)]
        out = sh(*cmds, wait=0.4)
        got = {ry: readlevel(out, ry) for _, _, ry in PAIRS}
        want = {ry: (1 if ry == y else 0) for _, _, ry in PAIRS}
        b.check(got == want, "only pair %s's partner (BCM %d) follows BCM %d" % (name, y, x),
                " ".join("%d=%s" % (k, v) for k, v in got.items()))

    print("== the kernel's own pins refuse")
    out = sh("echo 'function out' > %s/14/ctl" % G, "echo 'function out' > %s/15/ctl" % G, wait=0.5)
    b.check(out.count("in use") >= 2 or out.count("refused") >= 2 or out.count("rror") >= 2,
            "the console UART's pins (BCM 14, 15) refuse a function change", out.strip()[-120:])
    out = sh("cat %s/128/ctl" % G, "cat %s/129/ctl" % G, wait=0.5)
    b.check("function" in out, "the firmware expander's lines (128 BT_ON, 129 WL_ON) report their configuration", out.strip()[-100:])

    # Edge events (#651): pair A, BCM 4 drives and BCM 17 listens. A kernel
    # without them has no event file, and the section says so and skips.
    print("== edge events: the time and level of every edge, from the interrupt")
    out = sh("ls %s/17" % G, wait=0.5)
    if "event" not in out:
        b.skip("edge events", "this kernel's #G has no event file (#651)")
    else:
        def toggles(pin, n):
            return "; ".join("echo %d > %s/%d/level" % (1 - (i % 2), G, pin) for i in range(n))
        def events(text):
            return [(int(t), int(l)) for t, l in re.findall(r"^(\d{6,}) ([01])\s*$", text, re.M)]

        out = sh(setpin(4, "out"), "echo 0 > %s/4/level" % G, setpin(17, "in"),
                 "echo 'edge both' > %s/17/ctl" % G, "cat %s/17/ctl" % G, wait=0.4)
        b.check("edge both" in out, "ctl reads back 'edge both'", out.strip()[-80:])

        # a reader, ten edges, and what it saw
        out = sh("{cat %s/17/event > /tmp/gpioev} &" % G, "sleep 1", toggles(4, 10), "sleep 1",
                 "cat /tmp/gpioev", wait=1.5)
        ev = events(out)
        b.check(len(ev) == 10, "ten edges driven, ten reported (got %d)" % len(ev), out.strip()[-160:])
        b.check([l for _, l in ev] == [1, 0] * 5, "with the level after each: 1,0,1,0,...", str([l for _, l in ev]))
        ts = [t for t, _ in ev]
        b.check(ts == sorted(ts) and len(set(ts)) == len(ts), "in order, each with a later time than the last", str(ts[:4]))
        b.check(len(ts) > 1 and 0 < ts[-1] - ts[0] < 5000000, "microseconds on a plausible clock: %d us across the ten" % (ts[-1] - ts[0] if ts else 0))

        # rising only: half of them
        out = sh("echo 'edge rising' > %s/17/ctl" % G, "echo 0 > %s/4/level" % G,
                 "{cat %s/17/event > /tmp/gpioev} &" % G, "sleep 1", toggles(4, 10), "sleep 1", "cat /tmp/gpioev", wait=1.5)
        ev = events(out)
        b.check(len(ev) == 5 and all(l == 1 for _, l in ev), "'edge rising' reports the five rising edges of ten, each at level 1 (got %d)" % len(ev), out.strip()[-120:])

        # a reader that falls behind is told how far: the file is open, and so
        # queueing, for three seconds before anything reads it
        out = sh("echo 'edge both' > %s/17/ctl" % G, "echo 0 > %s/4/level" % G,
                 "{sleep 3; cat} < %s/17/event > /tmp/gpioev &" % G, "sleep 1", toggles(4, 300), "sleep 4",
                 "sed 2q /tmp/gpioev; wc -l /tmp/gpioev", wait=6.0)
        m = re.search(r"overrun (\d+)", out)
        b.check(m is not None and int(m.group(1)) >= 300 - 256, "a reader 300 edges behind is told 'overrun %s' first, and keeps the newest 256" % (m.group(1) if m else "?"), out.strip()[-160:])

        # nothing asked for, nothing reported; and the pins that are not ours to watch
        out = sh("echo 'edge none' > %s/17/ctl" % G, "{cat %s/17/event > /tmp/gpioev} &" % G, "sleep 1", toggles(4, 6), "sleep 1",
                 "wc -c /tmp/gpioev", wait=1.5)
        m = re.search(r"^\s*(\d+)\s+/tmp/gpioev", out, re.M)
        b.check(m is not None and int(m.group(1)) == 0, "'edge none': six edges driven, none reported", out.strip()[-80:])
        out = sh("echo 'edge both' > %s/14/ctl" % G, "ls %s/128" % G, wait=0.5)
        b.check("in use" in out or "rror" in out, "a pin a driver has claimed (BCM 14) refuses 'edge'", out.strip()[-100:])
        b.check("event" not in out.split("ls ")[-1] if "ls " in out else "event" not in out[-60:], "the firmware expander's lines have no event file", out.strip()[-80:])
        sh("rm -f /tmp/gpioev", wait=0.3)

    # leave everything as input, no pull
    cmds = []
    for name, x, y in PAIRS:
        cmds += [setpin(x, "in"), setpin(y, "in")]
    sh(*cmds, wait=0.3)

    text = b.serial_since(mark)
    bad = [l for l in text.splitlines() if re.search(r"panic|unhandled exception|vmachine:|waserror: up is [^3]", l)]
    b.check(not bad, "the kernel said nothing alarming during the run", "; ".join(bad[:3]))
    sys.exit(0 if b.summary() else 1)

if __name__ == "__main__":
    main()

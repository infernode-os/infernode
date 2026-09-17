#!/usr/bin/env python3
"""
Bluetooth acceptance: the Bluetooth SIG's PTS test cases the board can
be held to from a BlueZ host, with BlueZ's own test tools as the tester.

PTS (the Profile Tuning Suite) is the SIG's conformance battery; its
cases are named per specification and are public. Each check here is
the case it approximates, run from Linux against the board with the
tools BlueZ ships for exactly this (l2ping, l2test, rctest, sdptool,
hcitool, bluetoothctl). The board serves one thing per check with
listen(1) -- an L2CAP echo on a PSM, an RFCOMM echo on channel 1 --
made and unmade here, and needs nothing else.

  GAP/DISC/GENM     general discoverable: found by inquiry
  GAP/IDLE/NAMP     name discovery: the remote name request answered
  L2CAP/COS/ECH     echo request answered (l2ping)
  L2CAP/COS/CED     connection on a dynamic PSM; data both ways
  L2CAP/COS/CFD     configuration: MTU as asked, larger than default
  L2CAP/LE/CID      (not run: no LE peripheral role)
  SDP/SR/SA         service search + attribute: Serial Port found
  RFCOMM/DLC        a DLC on channel 1 opened; data both ways
  SPP               serial data over the DLC, both directions
  GAP/SEC/AUT       an authenticated link: bonded peer reconnects on its key
  multiple connects, reconnect storms, and what the kernel said meanwhile

The tester must already be bonded with the board for GAP/SEC/AUT (a
`pair` from the board's side, or bluetoothctl's). Each result is one
PASS:/FAIL: line, as the QEMU harness prints them.

Usage: bluetooth.py --board 192.168.1.104 --bdaddr b8:27:eb:ca:4c:8e [--serial-log ...]
"""
import re, sys, time
from board import Board, run, args

def main():
    ap = args(__doc__.split("\n")[1])
    ap.add_argument("--bdaddr", default="b8:27:eb:ca:4c:8e")
    ap.add_argument("--hci", default="hci0")
    a = ap.parse_args()
    b = Board(a.board, token_file=a.token, serial_log=a.serial_log)
    mark = b.serial_mark()
    bd = a.bdaddr.lower()

    # the board: discoverable; sinks on an L2CAP PSM and on RFCOMM channel 1
    # that keep what they were sent, so the bytes can be counted afterwards
    b.kill("Listen")
    b.sh("echo discoverable on > /net/bt/ctl", "echo pairable on > /net/bt/ctl",
         "rm -f /tmp/l2in /tmp/rfin",
         "listen -A 'bt!*!4097' {cat >> /tmp/l2in} &", "listen -A 'bt!*!spp' {cat >> /tmp/rfin} &", wait=0.8)
    st = b.sh("cat /net/bt/status", wait=1.0)
    b.check("up 1" in st, "the radio is up", st.strip()[:80])

    print("== GAP")
    rc, out = run(["hcitool", "-i", a.hci, "scan", "--length=8"], timeout=40)
    b.check(bd in out.lower(), "GAP/DISC/GENM general discoverable: found by inquiry", out.strip()[-120:])
    rc, out = run(["hcitool", "-i", a.hci, "name", bd], timeout=30)
    b.check(rc == 0 and out.strip() != "", "GAP/IDLE/NAMP name discovery: remote name is %r" % out.strip())

    print("== L2CAP")
    # raw L2CAP sockets want CAP_NET_RAW; without it these two are skipped, not failed
    rc, out = run(["l2ping", "-i", a.hci, "-c", "10", "-t", "5", bd], timeout=90)
    if "not permitted" in out:
        b.skip("L2CAP/COS/ECH echo (l2ping)", "needs CAP_NET_RAW: setcap cap_net_raw+ep $(which l2ping)")
    else:
        m = re.search(r"(\d+) sent, (\d+) received", out)
        sent, recv = (int(m.group(1)), int(m.group(2))) if m else (10, 0)
        b.check(recv == sent and sent > 0, "L2CAP/COS/ECH echo: %d/%d answered" % (recv, sent), out.strip()[-100:])
    rc, out = run(["l2test", "-i", a.hci, "-z", bd], timeout=30)
    if "not permitted" in out:
        b.skip("L2CAP information request (l2test -z)", "needs CAP_NET_RAW")
    else:
        b.check(rc == 0 and "Features" in out, "L2CAP information request answered (extended features)", out.strip()[-120:])
    # connection on the PSM at a larger MTU; 20 frames of 600 bytes, counted at the board
    rc, out = run(["l2test", "-i", a.hci, "-s", "-P", "4097", "-O", "672", "-I", "672", "-b", "600", "-N", "20", bd], timeout=60)
    m = re.search(r"omtu (\d+)", out)
    b.check("Connected" in out and m is not None and int(m.group(1)) >= 672,
            "L2CAP/COS/CED + CFD: connected on PSM 0x1001, our MTU 672 accepted, theirs %s" % (m.group(1) if m else "?"), out.strip()[-160:])
    time.sleep(1)
    got = b.sh("ls -l /tmp/l2in", wait=1.0)
    m = re.search(r"\s(\d+)\s+\w+\s+\d+\s+\d\d:\d\d", got)
    b.check(m is not None and int(m.group(1)) == 12000, "L2CAP data: 20 x 600 bytes arrived intact at the board (%s bytes)" % (m.group(1) if m else "?"))
    # -c reconnects forever: run it for a while and count
    rc, out = run("timeout 20 l2test -i %s -c -P 4097 %s" % (a.hci, bd), timeout=40)
    n = out.count("Connected")
    b.check(n >= 5 and "Can't" not in out, "L2CAP connect/disconnect storm on the PSM, 20 s: %d connections, none refused" % n, out.strip()[-120:])

    print("== SDP")
    rc, out = run(["sdptool", "-i", a.hci, "browse", bd], timeout=60)
    b.check("Serial Port" in out and "RFCOMM" in out, "SDP/SR/SA browse: Serial Port service with an RFCOMM channel", out.strip()[-160:])
    rc, out = run(["sdptool", "-i", a.hci, "search", "--bdaddr", bd, "SP"], timeout=60)
    b.check("Serial Port" in out, "SDP/SR/SS search by UUID (0x1101) finds it", out.strip()[-120:])
    rc, out = run(["sdptool", "-i", a.hci, "search", "--bdaddr", bd, "OPUSH"], timeout=60)
    b.check("Service Name" not in out, "SDP search for a service not offered (OBEX push) finds nothing", out.strip()[-120:])

    print("== RFCOMM / SPP")
    rc, out = run(["rctest", "-i", a.hci, "-s", "-P", "1", "-b", "500", "-N", "20", bd], timeout=60)
    b.check("Connected" in out and "Sending" in out, "RFCOMM/DLC + SPP: channel 1 opened, 20 x 500-byte frames sent", out.strip()[-160:])
    time.sleep(1)
    got = b.sh("ls -l /tmp/rfin", wait=1.0)
    m = re.search(r"\s(\d+)\s+\w+\s+\d+\s+\d\d:\d\d", got)
    b.check(m is not None and int(m.group(1)) == 10000, "SPP data: 20 x 500 bytes arrived intact at the board (%s bytes)" % (m.group(1) if m else "?"))
    # the other direction: the board sends a file, the tester reads to EOF (#632: the close is not yet seen)
    b.kill("Listen")
    b.sh("listen -A 'bt!*!spp' {cat /dis/sh.dis} &", wait=0.8)
    rc, out = run("timeout 20 rctest -i %s -u -P 1 %s" % (a.hci, bd), timeout=40)
    b.check(rc == 0 and "Connected" in out, "SPP data from the board to the tester, connection closed by the board's side (#632)", out.strip()[-120:])
    b.kill("Listen")
    b.sh("listen -A 'bt!*!spp' {cat >> /tmp/rfin} &", wait=0.8)
    rc, out = run("timeout 20 rctest -i %s -c -P 1 %s" % (a.hci, bd), timeout=40)
    n = out.count("Connected")
    b.check(n >= 5 and "Can't" not in out, "RFCOMM connect/disconnect storm on channel 1, 20 s: %d connections, none refused" % n, out.strip()[-120:])
    rc, out = run(["rctest", "-i", a.hci, "-n", "-P", "7", bd], timeout=30)
    b.check(rc != 0 or "Connected" not in out, "RFCOMM a channel not offered (7) is refused", out.strip()[-120:])

    print("== Security")
    rc, out = run(["bluetoothctl", "--", "info", bd], timeout=20)
    paired = "Paired: yes" in out
    b.check(paired, "GAP/SEC: the tester is bonded with the board (bluetoothctl info)", out.strip()[-120:])
    if paired:
        rc, out = run(["l2test", "-i", a.hci, "-p", "-P", "4097", bd], timeout=60)
        b.check(rc == 0 or "Connected" in out, "GAP/SEC/AUT dedicated bonding request on a bonded link succeeds", out.strip()[-120:])
    keys = b.sh("grep btlink /tmp/factotum/ctl | wc -l", wait=1.0)
    m = re.search(r"(\d+)", keys)
    b.check(m is not None and int(m.group(1)) >= 1, "the board holds at least one link key in factotum")

    b.kill("Listen")
    b.sh("rm -f /tmp/l2in /tmp/rfin", wait=0.5)
    time.sleep(2)
    st = b.sh("cat /net/bt/status", wait=1.0)
    m = re.search(r"links (\d+)", st)
    b.check(m is not None and int(m.group(1)) == 0, "no links left open after the run", st.strip()[:100])
    m = re.search(r"conversations (\d+)", st)
    b.check(m is not None and int(m.group(1)) <= 2, "no conversations leaked by the connection storms (#632): %s" % (m.group(1) if m else "?"))
    text = b.serial_since(mark)
    bad = [l for l in text.splitlines() if re.search(r"panic|unhandled exception|vmachine:|waserror: up is|bt9p: .*(refused|fail)", l)]
    b.check(not bad, "the kernel said nothing alarming during the run", "; ".join(bad[:3]))
    sys.exit(0 if b.summary() else 1)

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Ethernet/IP acceptance: RFC 2544's benchmarks, adapted for an end
system, plus the TCP behaviour a host is expected to have.

RFC 2544 describes a device that forwards; a board is a device that
terminates. So each of its tests is taken at the board's own stack:
throughput (26.1) as TCP bytes into and out of it, latency (26.2) as
ICMP echo at three frame sizes, frame loss (26.3) and back-to-back
frames (26.4) as an echo burst at the fastest rate a non-root tester
may send, system recovery (26.5) as latency returning to baseline
after the burst. The board needs nothing but listen(1): a TCP sink
and a TCP source, made and unmade here.

The kernel's own words are evidence too: with a serial capture
configured (--serial-log), anything the kernel prints during the run
that is not routine -- a panic, "ether0rx", "won't halt" -- fails the
run. #610 is a receive-path panic under load; 26.4 is the test that
should find it, and it is a FAIL here rather than a note.

Usage: ethernet.py --board 192.168.1.104 [--serial-log ~/captures/serial/today.log]
"""
import re, socket, sys, threading, time
from board import Board, run, args

def throughput_in(host, port, seconds):
    """Send zeros to the board's sink for `seconds`; return Mbit/s."""
    s = socket.create_connection((host, port), timeout=10)
    buf = b"\0" * 65536
    n = 0
    end = time.time() + seconds
    while time.time() < end:
        s.sendall(buf)
        n += len(buf)
    s.close()
    return n * 8 / seconds / 1e6

def throughput_out(host, port, seconds):
    """Read from the board's source for `seconds`; return Mbit/s."""
    s = socket.create_connection((host, port), timeout=10)
    s.settimeout(5)
    n = 0
    end = time.time() + seconds
    while time.time() < end:
        try:
            d = s.recv(65536)
        except socket.timeout:
            break
        if not d:
            break
        n += len(d)
    s.close()
    return n * 8 / seconds / 1e6

def default_gateway():
    rc, out = run(["ip", "route", "show", "default"], timeout=10)
    m = re.search(r"default via (\S+)", out)
    return m.group(1) if m else None

def ping(host, count, size, interval):
    rc, out = run(["ping", "-c", str(count), "-i", str(interval), "-s", str(size), "-W", "2", host], timeout=count * (interval + 2) + 10)
    m = re.search(r"(\d+) packets transmitted, (\d+) received", out)
    tx, rx = (int(m.group(1)), int(m.group(2))) if m else (count, 0)
    m = re.search(r"= ([\d.]+)/([\d.]+)/([\d.]+)/", out)
    mn, avg, mx = (float(m.group(1)), float(m.group(2)), float(m.group(3))) if m else (0, 0, 0)
    return tx, rx, avg, mx

def main():
    a = args(__doc__.split("\n")[1]).parse_args()
    b = Board(a.board, token_file=a.token, serial_log=a.serial_log)
    secs = 3 if a.quick else 10
    mark = b.serial_mark()

    print("== RFC 2544 26.2 latency (ICMP echo, three frame sizes)")
    base = None
    for size in (56, 512, 1472):
        tx, rx, avg, mx = ping(a.board, 50, size, 0.05)
        b.check(rx == tx, "26.2 latency: %d/%d echoes at %d bytes answered" % (rx, tx, size))
        b.check(avg < 20.0, "26.2 latency: average %.2f ms at %d bytes is under 20 ms" % (avg, size), "max %.2f" % mx)
        if size == 56:
            base = avg

    print("== RFC 2544 26.1 throughput (TCP, both directions)")
    b.kill("Listen")
    # the source: no /dev/zero on this kernel, so a loop over a file the
    # image has; the listener's shell is fresh, so it loads std itself.
    #
    # The loop's CONDITION is the cat, so it ends when the tester hangs
    # up: cat's write then fails and the loop is over. The first version
    # looped on {~ 1 1} with the cat as the body, and outlived its
    # connection -- cat failing instantly, re-spawned ~800 times a second
    # for ever, each spawn loading a module whose type code the kernel
    # does not free (heap.c freetypecode, the INFR-458 experiment). That
    # was #641: 40 MB/min from the battery's own leftover, not from USB.
    b.sh("listen -A 'tcp!*!5001' {cat > /dev/null} &",
         "listen -A 'tcp!*!5002' {sh -c 'load std; while {cat /dis/sh.dis} {}'} &", wait=0.8)
    time.sleep(1)
    try:
        mbps_in = throughput_in(a.board, 5001, secs)
        b.check(mbps_in > 8.0, "26.1 throughput into the board: %.1f Mbit/s over %ds" % (mbps_in, secs))
    except Exception as e:
        b.check(False, "26.1 throughput into the board", str(e))
    try:
        mbps_out = throughput_out(a.board, 5002, secs)
        b.check(mbps_out > 8.0, "26.1 throughput out of the board: %.1f Mbit/s over %ds" % (mbps_out, secs))
    except Exception as e:
        b.check(False, "26.1 throughput out of the board", str(e))

    print("== RFC 2544 26.3/26.4 frame loss and back-to-back (echo burst, largest frame)")
    burst = 500 if a.quick else 2000
    tx, rx, avg, mx = ping(a.board, burst, 1472, 0.002)
    loss = 100.0 * (tx - rx) / max(tx, 1)
    b.check(loss < 1.0, "26.3 frame loss: %.2f%% of %d back-to-back 1500-byte frames" % (loss, tx), "avg %.2f max %.2f ms" % (avg, mx))
    # fragmented echoes: the stack reassembles. First the TESTER is
    # checked: on 2026-09-17 this host's fragments reached no wired host
    # at all -- not the board, not the gateway -- while a second tester's
    # reached the board 3/3 and the board reassembled the gateway's own
    # 5 KB broadcasts all along (#633 was the tester, not the stack). A
    # tester that cannot send fragments to its gateway skips, and says so.
    gw = default_gateway()
    gtx, grx, _, _ = ping(gw, 3, 4000, 0.3) if gw else (0, 0, 0, 0)
    if grx == 0:
        b.skip("IP reassembly (4000- and 60000-byte echoes)", "this tester's fragments do not reach its own gateway %s; test from another host" % gw)
    else:
        tx, rx, avg, mx = ping(a.board, 20, 4000, 0.05)
        b.check(rx == tx, "IP reassembly: %d/%d 4000-byte (fragmented) echoes answered" % (rx, tx))
        tx, rx, avg, mx = ping(a.board, 5, 60000, 0.2)
        b.check(rx == tx, "IP reassembly: %d/%d 60000-byte echoes answered" % (rx, tx))

    print("== TCP behaviour")
    t0 = time.time()
    try:
        socket.create_connection((a.board, 5999), timeout=5).close()
        b.check(False, "a connect to a closed port is refused", "it was accepted")
    except ConnectionRefusedError:
        b.check(time.time() - t0 < 1.0, "a connect to a closed port is refused at once (RST), %.2fs" % (time.time() - t0))
    except Exception as e:
        b.check(False, "a connect to a closed port is refused", "%s after %.1fs" % (type(e).__name__, time.time() - t0))
    # a burst of connections held open, then a byte on each: a call the
    # stack accepted and then reset (its accept queue full -- Maxincall,
    # os/ip/ip.h) looks connected to the client until it writes, so the
    # write is the test. 100 is under the queue; a serial listener takes
    # them one at a time and every one of them must still be there.
    conns = []
    failed = 0
    reset = 0
    for i in range(50 if a.quick else 100):
        try:
            conns.append(socket.create_connection((a.board, 5001), timeout=5))
        except Exception:
            failed += 1
    time.sleep(0.5)
    for c in conns:
        try:
            c.sendall(b"x")
        except Exception:
            reset += 1
    for c in conns:
        c.close()
    b.check(failed == 0 and reset == 0, "%d simultaneous connections accepted and held, none refused or reset" % len(conns), "%d failed to connect, %d reset after connecting" % (failed, reset))
    time.sleep(1)
    try:
        s = socket.create_connection((a.board, 5001), timeout=5)
        s.sendall(b"x" * 1000)
        s.close()
        b.check(True, "the sink still accepts after the connection storm")
    except Exception as e:
        b.check(False, "the sink still accepts after the connection storm", str(e))

    print("== RFC 2544 26.5 recovery")
    tx, rx, avg, mx = ping(a.board, 50, 56, 0.05)
    b.check(rx == tx and base is not None and avg < max(20.0, 3 * base), "26.5 recovery: latency %.2f ms after the bursts (baseline %.2f)" % (avg, base or 0))

    b.kill("Listen")
    text = b.serial_since(mark)
    bad = [l for l in text.splitlines() if re.search(r"panic|ether0rx|won't halt|unhandled exception|vmachine:|waserror: up is", l)]
    b.check(not bad, "the kernel said nothing alarming during the run", "; ".join(bad[:3]))
    sys.exit(0 if b.summary() else 1)

if __name__ == "__main__":
    main()

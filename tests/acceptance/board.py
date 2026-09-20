#!/usr/bin/env python3
"""
The board under test, from the tester's side.

Acceptance tests here run on a Linux host (the tester) against a
board running InferNode (the device under test). Nothing is ported to
the board: the standard tools stay on Linux, and the board is asked
only to be a peer -- a TCP sink, an RFCOMM echo, a station -- which
Inferno's listen(1) gives in one line. This module is how a test asks
it: commands over the network console (osinit.b netshell, tcp!*!17010,
token as the first line), and the serial capture, if there is one, for
what the kernel says while the test runs.

    b = Board("192.168.1.104", token_file="~/pitools/netcons.token")
    b.sh("listen -A 'tcp!*!5001' {cat > /dev/null} &")
    ...
    b.kill("Listen")

Results are printed as the QEMU harness prints them -- PASS:/FAIL: one
line each, a Passed:/Failed: summary -- so the same eyes and greps work.
"""
import os, socket, sys, time, subprocess

class Board:
    def __init__(self, host, port=17010, token_file="~/pitools/netcons.token", serial_log=None):
        self.host, self.port = host, port
        self.token = open(os.path.expanduser(token_file)).read().strip()
        self.serial_log = os.path.expanduser(serial_log) if serial_log else None
        self.passed = self.failed = 0

    def sh(self, *cmds, wait=1.5, until=None, limit=900):
        """Run shell lines on the board in one console session; return the transcript."""
        c = socket.create_connection((self.host, self.port), timeout=10)
        c.settimeout(3.0)
        out = self._drain(c, 0.6)
        if "token:" not in out:
            c.close()
            raise RuntimeError("netconsole: unexpected greeting %r" % out[:80])
        c.sendall((self.token + "\n").encode())
        self._drain(c, 0.8)
        text = ""
        for cmd in cmds:
            c.sendall((cmd + "\n").encode())
            text += self._drain(c, wait)
        # a command with no fixed duration (checksumming a card) says when it
        # is done; keep reading until it has, or until the limit
        t0 = time.time()
        while until and until not in text and time.time() - t0 < limit:
            text += self._drain(c, 1.0)
        c.close()
        return text

    def kill(self, *modules):
        """kill(1) on the board by module name, quietly."""
        self.sh("kill " + " ".join(modules) + " >[2] /dev/null", wait=0.8)

    def serial_since(self, mark):
        if not self.serial_log or not os.path.exists(self.serial_log):
            return ""
        data = open(self.serial_log, "rb").read().decode("latin1")
        return data[mark:]

    def serial_mark(self):
        if not self.serial_log or not os.path.exists(self.serial_log):
            return 0
        return os.path.getsize(self.serial_log)

    def check(self, ok, name, detail=""):
        if ok:
            self.passed += 1
            print("PASS: " + name, flush=True)
        else:
            self.failed += 1
            print("FAIL: " + name + ((" (" + detail + ")") if detail else ""), flush=True)
        return ok

    def skip(self, name, why):
        print("SKIP: " + name + " (" + why + ")", flush=True)

    def summary(self):
        print("Passed: %d  Failed: %d" % (self.passed, self.failed), flush=True)
        return self.failed == 0

    @staticmethod
    def _drain(c, w):
        time.sleep(w)
        out = b""
        try:
            while True:
                b = c.recv(65536)
                if not b:
                    break
                out += b
        except socket.timeout:
            pass
        return out.decode(errors="replace")

def run(cmd, timeout=120):
    """A tester-side command; returns (returncode, stdout+stderr)."""
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        dec = lambda x: x.decode(errors="replace") if isinstance(x, bytes) else (x or "")
        return -1, dec(e.stdout) + dec(e.stderr) + "\n[timeout]"

def args(desc):
    import argparse
    ap = argparse.ArgumentParser(description=desc)
    ap.add_argument("--board", default=os.environ.get("BOARD", "192.168.1.104"))
    ap.add_argument("--token", default=os.environ.get("BOARD_TOKEN", "~/pitools/netcons.token"))
    ap.add_argument("--serial-log", default=os.environ.get("BOARD_SERIAL"))
    ap.add_argument("--quick", action="store_true", help="shorter runs")
    return ap

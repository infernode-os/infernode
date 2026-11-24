#!/usr/bin/env python3
# A 9front machine under QEMU for tests/host/dp9ik_live_test.sh, driven at
# its serial console as a person at it would be.
#
#   nine.py provision STOCK.qcow2 OUT.qcow2
#	OUT, an overlay on 9front's own image, made a cpu and auth server:
#	sysname cirno, authdom 9front, glenda's password glendapass9f,
#	the key file in AES form (dp9ik's), the network up at boot.
#   nine.py serve IMAGE.qcow2 RCPUPORT AUTHPORT
#	boots an overlay of IMAGE with rcpu and the ticket service on the
#	host's loopback at the ports given, prints READY, and runs until its
#	standard input closes; lines on it are typed at the console.
#
# What provisioning had to learn (each one cost a run to find):
#  - an empty /adm/keys is read as the old DES form, in which no account
#    has an AES key: the auth server answers dp9ik with tickets under a
#    random key ("pak-fail no AES key" in /sys/log/auth) and every client
#    says "bad key".  auth/convkeys -a puts the file in AES form, but not
#    an empty one: an account is made, the file converted, keyfs started
#    again (a reboot) and the password set again, now with its AES key
#  - cpurc finds the auth server through an ndb sys= entry for the machine
#  - the network is configured by /cfg/$sysname/cpustart, or not at all
#  - passwords are typed a character at a time: the console drops some
#    typed at full speed in raw mode
#  - wrkey asks whether to keep legacy p9sk1 (no)
import os, pty, re, select, signal, subprocess, sys, tempfile, time

PW = "glendapass9f"
CPU = r"cirno# $"
TERM = r"\n(term|cpu)?% $"
BOOT = r"bootargs is [^\n]*\] ?$"

class VM:
    def __init__(self, image, fwd=(), log=None):
        self.buf = b""
        self.logf = open(log or os.devnull, "ab")
        net = "user,id=n0" + "".join(f",hostfwd=tcp:127.0.0.1:{h}-:{g}" for h, g in fwd)
        args = ["qemu-system-x86_64", "-m", "1024", "-smp", "2", "-nographic", "-monitor", "none",
                "-drive", f"file={image},if=virtio,format=qcow2", "-netdev", net,
                "-device", "virtio-net-pci,netdev=n0", "-serial", "stdio"]
        if os.path.exists("/dev/kvm") and os.access("/dev/kvm", os.W_OK):
            args[1:1] = ["-enable-kvm", "-cpu", "host"]
        else:
            args[1:1] = ["-cpu", "max"]
        pid, fd = pty.fork()
        if pid == 0:
            os.execvp(args[0], args)
        self.pid, self.fd = pid, fd

    def expect(self, pat, timeout=300):
        rx = re.compile(pat.encode())
        end = time.time() + timeout
        while True:
            m = rx.search(self.buf)
            if m:
                out, self.buf = self.buf[:m.end()], self.buf[m.end():]
                return out.decode(errors="replace")
            left = end - time.time()
            if left <= 0:
                raise TimeoutError(f"no /{pat}/ in {self.buf[-600:]!r}")
            r, _, _ = select.select([self.fd], [], [], min(left, 1))
            if r:
                try:
                    d = os.read(self.fd, 65536)
                except OSError:
                    d = b""
                if not d:
                    raise EOFError("qemu exited")
                self.logf.write(d); self.logf.flush(); self.buf += d

    def line(self, s):
        os.write(self.fd, (s + "\r").encode())

    def slow(self, s):
        for ch in s:
            os.write(self.fd, ch.encode()); time.sleep(0.15)
        os.write(self.fd, b"\r")

    def cmd(self, s, prompt=CPU, t=120):
        self.line(s)
        return self.expect(prompt, t)

    def dialog(self, s, answers, prompt=CPU):
        self.line(s)
        for _ in range(30):
            o = self.expect(r"(\]: ?$|: ?$|" + prompt + ")", 120)
            if re.search(prompt.encode().decode() + "", o[-20:]):
                return
            tail = o[-90:]
            for k, a in answers:
                if k in tail:
                    self.slow(a) if k == "assword" else self.line(a)
                    break
            else:
                self.line("")
        raise TimeoutError("dialog did not end: " + s)

    def boot(self, prompt=CPU):
        self.expect(BOOT, 900); self.line("")
        o = self.expect(r"(user\[[^\]]*\]: ?$|" + prompt + ")", 900)
        if "user[" in o:
            self.line("")
            self.expect(prompt, 600)
        time.sleep(8)

    def reboot(self, prompt=CPU):
        self.line("fshalt -r")
        self.boot(prompt)

    def halt(self):
        self.line("fshalt")
        try:
            self.expect(r"done halting", 180)
        except (TimeoutError, EOFError):
            pass
        self.close()

    def close(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
            os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass

def overlay(base, out):
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", os.path.abspath(base), out], check=True)

def provision(stock, out, log):
    overlay(stock, out)
    v = VM(out, log=log)
    try:
        # a terminal at first: make it a cpu server with nvram
        v.boot(TERM)
        v.cmd("9fs 9fat", TERM)
        v.cmd("echo 'service=cpu' >> /n/9fat/plan9.ini; echo 'nvram=#S/sdF0/nvram' >> /n/9fat/plan9.ini", TERM)
        v.cmd("echo 'ipnet=qemu ip=10.0.2.0 ipmask=255.255.255.0 ipgw=10.0.2.2 auth=10.0.2.15 authdom=9front cpu=10.0.2.15 fs=10.0.2.15 dns=10.0.2.3' >> /lib/ndb/local", TERM)
        v.cmd("echo 'sys=cirno ip=10.0.2.15 auth=10.0.2.15 authdom=9front' >> /lib/ndb/local", TERM)
        v.cmd("mkdir -p /cfg/cirno; echo ip/ipconfig > /cfg/cirno/cpustart", TERM)
        v.cmd("touch /adm/keys; chmod 600 /adm/keys", TERM)
        v.dialog("auth/wrkey", [("authid", "glenda"), ("authdom", "9front"), ("secstore", ""),
                                ("p9sk1", "no"), ("assword", PW)], TERM)
        v.reboot()
        user = [("Plan 9 password", "y"), ("Inferno/POP", "n"), ("assword", PW)]
        v.dialog("auth/changeuser glenda", user)
        v.dialog("auth/convkeys -a /adm/keys", [("assword", PW)])
        v.reboot()
        v.dialog("auth/changeuser glenda", user)
        v.line("auth/debug")
        v.expect(r"skip test\]: $", 120); v.slow(PW)
        o = v.expect(r"(succeeded|do not agree)", 120)
        if "succeeded" not in o:
            raise RuntimeError("auth/debug: " + o[-300:])
        v.halt()
    except BaseException:
        v.close()
        raise
    print("provisioned", out)

def serve(image, rcpuport, authport, log):
    d = tempfile.mkdtemp(prefix="nine.")
    ov = os.path.join(d, "run.qcow2")
    overlay(image, ov)
    v = VM(ov, fwd=((int(rcpuport), 17019), (int(authport), 567)), log=log)
    try:
        v.boot()
        print("READY", flush=True)
        for ln in sys.stdin:
            print(v.cmd(ln.rstrip("\n")), flush=True)
    finally:
        v.close()
        os.remove(ov); os.rmdir(d)

if __name__ == "__main__":
    log = os.environ.get("NINE_LOG")
    if sys.argv[1:2] == ["provision"] and len(sys.argv) == 4:
        provision(sys.argv[2], sys.argv[3], log)
    elif sys.argv[1:2] == ["serve"] and len(sys.argv) == 5:
        serve(sys.argv[2], sys.argv[3], sys.argv[4], log)
    else:
        sys.exit("usage: nine.py provision STOCK OUT | serve IMAGE RCPUPORT AUTHPORT")

#!/usr/bin/env python3
# Two InferNode nodes, each with a root, a home and keys of its own,
# driven at their consoles as an administrator and a user drive them
# (twonode_auth_test.sh): node A the signer (keyfs, logind, keysrv,
# secstored, an export), node B a user's machine.
#
#   drive.py EMU ROOT WORKDIR MODE SECPORT EXPORTPORT
#
# MODE is default or cnsa (CNSAMODE on both nodes).  Prints a line
# "ok: what" or "FAIL: what" for each check, and the seconds each
# step a person waits on took ("time: what N.NN").  Passwords are
# typed the moment their prompt is printed, as a paste or a quick
# typist would: none may be echoed.
import os, pty, re, select, signal, subprocess, sys, time

EMU, ROOT, WORK, MODE, SECPORT, EXPORT = sys.argv[1:7]
fails = 0

def report(ok, what):
    global fails
    print(("ok: " if ok else "FAIL: ") + what, flush=True)
    if not ok:
        fails += 1

def timed(what, secs):
    print(f"time: {what} {secs:.2f}", flush=True)

class Node:
    def __init__(self, name, root, env):
        self.name, self.buf = name, b""
        self.log = open(root + ".console", "ab")
        pid, fd = pty.fork()
        if pid == 0:
            e = dict(os.environ); e.update(env)
            os.chdir(root)
            os.execve(EMU, [EMU, "-c1", "-r" + root, "/dis/sh.dis", "-l"], e)
        self.pid, self.fd = pid, fd
        self.expect(r"; $", 60)

    def expect(self, pat, timeout=60):
        rx, end = re.compile(pat.encode()), time.time() + timeout
        while True:
            m = rx.search(self.buf)
            if m:
                out, self.buf = self.buf[:m.end()], self.buf[m.end():]
                return out.decode(errors="replace")
            left = end - time.time()
            if left <= 0:
                raise TimeoutError(f"{self.name}: no /{pat}/ in {self.buf[-400:]!r}")
            r, _, _ = select.select([self.fd], [], [], min(left, 0.5))
            if r:
                try:
                    d = os.read(self.fd, 65536)
                except OSError:
                    d = b""
                self.log.write(d); self.log.flush(); self.buf += d

    def line(self, s):
        os.write(self.fd, (s + "\n").encode())

    def cmd(self, s, timeout=120, prompt=None):
        self.buf = b""
        t0 = time.time()
        self.line(s)
        if prompt is None:
            self.expect(re.escape(s) + r"\r?\n", 10)
            prompt = r"; $"
        return self.expect(prompt, timeout), time.time() - t0

    def close(self):
        try:
            self.line("echo halt > /dev/sysctl"); time.sleep(0.5)
        except OSError:
            pass
        try:
            os.kill(self.pid, signal.SIGKILL); os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass

def mknode(n):
    r = f"{WORK}/{MODE}.{n}"
    os.makedirs(r + "/home")
    for d in ("dis", "lib", "fonts", "locale", "module", "man", "icons"):
        os.symlink(f"{ROOT}/{d}", f"{r}/{d}")
    for d in ("mnt", "n"):
        subprocess.run(["cp", "-a", f"{ROOT}/{d}", r], check=True)
    os.makedirs(r + "/keydb"); os.makedirs(r + "/tmp"); os.makedirs(r + "/usr")
    subprocess.run(["cp", "-a", f"{ROOT}/usr/inferno", r + "/usr/inferno"], check=True)
    try:
        os.remove(r + "/usr/inferno/keyring/default")
    except FileNotFoundError:
        pass
    return r

def flat(o):
    return " ".join(o.split())[-200:]

def secret(N, pw, pat, timeout=120):
    """typed at once; the time from its Enter to pat"""
    t0 = time.time(); N.line(pw); out = N.expect(pat, timeout)
    return out, time.time() - t0

rA, rB = mknode("A"), mknode("B")
env = {"CNSAMODE": "1"} if MODE == "cnsa" else {}
A = Node("A", rA, {"HOME": rA + "/home", **env})
B = Node("B", rB, {"HOME": rB + "/home", **env})
# distinct words, so that any part of one echoed is found on a console
pws = ["Qmk7-master-key", "Zal1-alice-pw-one", "Wnd3-nodea-pw", "Kal2-alice-pw-two", "secstore-pw-alice"]
WRONG = ["Vxx9-not-alices", "Yzz8-not-the-pw"]
try:
    # ---- A: the signer, as its administrator sets it up.  No mkdir
    # of /mnt/keys or /mnt/keysrv: keyfs makes the one, the tree ships
    # the other.
    # the emulator's user is the host's (root here, runner in CI): its home is /usr/$user
    A.cmd("user=`{cat /dev/user}; auth/createsignerkey authsrv; mkdir -p /usr/$user/keyring /usr/$user/share; echo hello from A > /usr/$user/share/hello; cat /dev/null > /keydb/keys", 120)
    o, _ = A.cmd("svc/auth", 20, prompt=r"(Key: |; $)")
    report("Key:" in o, "svc/auth asks for the master key on a fresh tree" + ("" if "Key:" in o else ": " + flat(o)))
    A.line(pws[0]); A.expect(r"Confirm key: ", 20)
    A.line(pws[0]); o = A.expect(r"; $", 60)
    report("mount on" not in o, "keyfs mounts on /mnt/keys, which it made" + ("" if "mount on" not in o else ": " + flat(o)))
    time.sleep(1)
    for u, pw in (("alice", pws[1]), ("nodea", pws[2])):
        A.cmd("auth/changelogin " + u, 20, prompt=r"secret: ")
        A.line(pw); A.expect(r"confirm: ", 20)
        o, dt = secret(A, pw, r"(expires.*: |; $)", 60)
        if "expires" in o:
            A.line(""); o += A.expect(r"; $", 20)
        report("written" in o, f"changelogin {u}")
        timed(f"changelogin {u}", dt)
    o, _ = A.cmd("ls -l /mnt/keys/alice/secret")
    report(" 48 " in o, "alice's secret is 48 bytes (PBKDF2-HMAC-SHA-384)")
    if MODE == "cnsa":
        report(b"mldsa87" in open(rA + "/keydb/signerkey", "rb").read(), "in CNSA mode the signer's key is ML-DSA-87")
    A.cmd(f"auth/secstored -a 'tcp!127.0.0.1!{SECPORT}' >[2] /dev/null &")

    def login(N, who, user, pw, want=True):
        N.cmd("getauthinfo default", 20, prompt=r"signer.*: ")
        N.line("127.0.0.1"); N.expect(r"user name.*: ", 20)
        N.line(user); N.expect(r"password: ", 20)
        o, dt = secret(N, pw, r"(save in file.*: |use signer.*: |; $)", 120)
        got = "save in file" in o
        if got:
            N.line("yes"); N.expect(r"; $", 30)
        elif "use signer" in o:
            os.write(N.fd, b"\x04"); N.expect(r"; $", 30)
        report(got == want, f"{who}: getauthinfo as {user} " + ("gives a certificate" if want else "refused") + ("" if got == want else ": " + flat(o)))
        timed(f"{who} login" + ("" if want else " refused"), dt)
    B.cmd("user=`{cat /dev/user}; mkdir -p /usr/$user/keyring /n/a /n/fa /n/fb /n/fc")
    login(A, "A", "nodea", pws[2])
    # the export authenticates with the certificate A has just been given
    A.cmd(f"styxlisten 'tcp!*!{EXPORT}' export /usr/$user/share &")
    login(B, "B", "alice", pws[1])
    login(B, "B", "alice", WRONG[0], False)

    # ---- authenticated 9P between them
    time.sleep(1)
    o, dt = B.cmd(f"mount -c tcp!127.0.0.1!{EXPORT} /n/a; cat /n/a/hello; echo by B > /n/a/fromB; cat /n/a/fromB; unmount /n/a", 60)
    report("hello from A" in o and "by B" in o, "B mounts A's export, reads and writes" + ("" if "by B" in o else ": " + flat(o)))
    timed("mount, read, write, unmount", dt)

    # ---- secstore on A from B
    A.cmd(f"auth/secstore-setup -k '{pws[4]}' -u alice >[2] /dev/null", 120)
    S = f"tcp!127.0.0.1!{SECPORT}"
    o, dt = B.cmd(f"auth/factotum -s fa -m /n/fa -S {S} -u alice -P '{pws[4]}'; cat /n/fa/ctl", 120)
    report("can't" not in o and "rror" not in o, "B's factotum unlocks secstore on A" + ("" if "can't" not in o else ": " + flat(o)))
    report("step 3" not in o and "ssl ok" not in o, "nothing of secstore's progress printed")
    timed("secstore unlock", dt)
    B.cmd("echo 'key proto=pass service=demo user=alice !password=s3cret' > /n/fa/ctl")
    o, dt = B.cmd("echo sync > /n/fa/ctl", 120)
    report("not saved" not in o and "rror" not in o, "a key added is saved to secstore" + ("" if "rror" not in o else ": " + flat(o)))
    o, dt = B.cmd(f"auth/factotum -s fb -m /n/fb -S {S} -u alice -P '{pws[4]}'; cat /n/fb/ctl", 120)
    report("service=demo" in o, "a second factotum has the key from A" + ("" if "service=demo" in o else ": " + flat(o)))
    o, dt = B.cmd(f"auth/factotum -s fc -m /n/fc -S {S} -u alice -P '{WRONG[1]}'; cat /n/fc/ctl", 120)
    report("service=demo" not in o, "a wrong secstore password has no keys")
    report("creating" not in o and "secstore setup" not in o, "and makes no account on B's disk (the server is A's)" + ("" if "creating" not in o else ": " + flat(o)))
    # ---- the password changed from B through keysrv on A, with no mkdir of /mnt/keysrv
    B.cmd("auth/passwd -s 127.0.0.1", 60, prompt=r"(Inferno secret: |; $)")
    B.line(pws[1]); o = B.expect(r"(new secret.*: |; $)", 120)
    if "new secret" in o:
        B.line(pws[3]); o += B.expect(r"(confirm: |; $)", 60)
        if "confirm" in o:
            o2, dt = secret(B, pws[3], r"; $", 120); o += o2
            timed("passwd", dt)
    report("secret changed" in o, "passwd changes alice's password through keysrv" + ("" if "secret changed" in o else ": " + flat(o)))
    login(B, "B", "alice", pws[3])
    login(B, "B", "alice", pws[1], False)
except (TimeoutError, OSError) as e:
    report(False, f"the session stopped: {e}")
finally:
    A.close(); B.close()

# nothing typed for a secret is on either console
for n, r in (("A", rA), ("B", rB)):
    text = open(r + ".console", "rb").read().decode(errors="replace")
    # secstore's password is given on command lines (-P, -k): not typed
    leaked = [p for p in pws[:4] + WRONG[:1] if p[:4] in text]
    report(not leaked, f"no secret echoed on {n}'s console" + ("" if not leaked else f": {leaked}"))
sys.exit(1 if fails else 0)

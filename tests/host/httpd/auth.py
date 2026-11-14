#!/usr/bin/env python3
#
# tests/host/httpd/auth.py: httpd(8)'s client certificates, passwords
# and rules, from outside.  Run by tests/host/httpd_auth_test.sh:
#
#   auth.py RULES DEFAULTS PLAINRULES LOCKOUT WORKDIR
#
# RULES:      -A -P -x rules (below) -p /led/ctl, TLS
# DEFAULTS:   -A -P -p /led/ctl, no -x
# PLAINRULES: -x with only "/open none", no TLS
# LOCKOUT:    -P -x "/ password", for the ten-failures lockout
#
import os, re, socket, ssl, sys, time, base64, threading

R, D, PL, LO = (int(x) for x in sys.argv[1:5])
W = sys.argv[5]
SITE = W + "/site"
fails = 0

def check(ok, what, detail=""):
    global fails
    if ok:
        print("PASS: " + what)
    else:
        fails += 1
        print("FAIL: " + what + (": " + detail if detail else ""))
    sys.stdout.flush()

def ctx(cert=None):
    c = ssl.create_default_context(cafile=W + "/server.pem")
    c.minimum_version = ssl.TLSVersion.TLSv1_3
    if cert:
        c.load_cert_chain(W + "/" + cert + ".chain", W + "/" + cert + ".key")
    return c

class Resp:
    status = 0; headers = {}; body = b""; err = None

def request(port, path, cert=None, user=None, method="GET", extra="", body=b"", tls=True, raw=None, keep=None):
    r = Resp()
    r.headers = {}
    try:
        if keep is not None:
            s = keep
        else:
            s = socket.create_connection(("127.0.0.1", port), timeout=20)
            if tls:
                s = ctx(cert).wrap_socket(s, server_hostname="localhost")
        if raw is None:
            h = "%s %s HTTP/1.1\r\nHost: localhost\r\n" % (method, path)
            if user:
                h += "Authorization: Basic %s\r\n" % base64.b64encode(user.encode()).decode()
            if body or method == "POST":
                h += "Content-Length: %d\r\n" % len(body)
            if keep is None:
                h += "Connection: close\r\n"
            raw = (h + extra + "\r\n").encode() + body
        s.sendall(raw)
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = s.recv(65536)
            if not d:
                raise EOFError("closed")
            buf += d
        head, rest = buf.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        r.status = int(lines[0].split()[1])
        for l in lines[1:]:
            k, v = l.split(":", 1)
            r.headers[k.strip().lower()] = v.strip()
        n = int(r.headers.get("content-length", "0"))
        while len(rest) < n and method != "HEAD":
            d = s.recv(65536)
            if not d:
                break
            rest += d
        r.body = rest[:n]
        if keep is None:
            s.close()
    except (ssl.SSLError, ConnectionResetError, EOFError, BrokenPipeError, OSError) as e:
        r.err = repr(e)
    return r

def st(*a, **k):
    r = request(*a, **k)
    return r.status if r.err is None else ("refused " + r.err[:60])

def certs():
    check(st(R, "/public/ok.txt") == 200, "none: a public path with no certificate or password")
    r = request(R, "/")
    check(r.status == 401 and r.headers.get("www-authenticate") == 'Basic realm="Test site", charset="UTF-8"',
          "password or cert, neither given: 401 and the challenge", repr(r.headers.get("www-authenticate")))
    check(st(R, "/admin/x.txt") == 403, "cert, none given: 403 (no challenge a browser could answer)")
    check(st(R, "/", cert="alice") == 200, "a client certificate does for a password")
    r = request(R, "/admin/x.txt", cert="alice")
    check(r.status == 200 and r.body == b"admin\n", "cert: alice's certificate (from the CA) reads /admin")
    check(st(R, "/admin/x.txt", cert="bob") == 200, "cert: bob's (through the intermediate, sent with it)")
    check(st(R, "/fp/x.txt", cert="alice") == 200, "cert=sha256: the fingerprint named takes alice")
    check(st(R, "/fp/x.txt", cert="bob") == 403, "and not bob")
    check(st(R, "/bob/x.txt", cert="bob") == 200, "cert=bob-phone: bob")
    check(st(R, "/bob/x.txt", cert="alice") == 401, "and not alice (401: the path takes bob's password too)")
    for c, why in (("srvonly", "a certificate for server authentication only"), ("other", "one from another CA"),
                   ("revoked", "one the CA's CRL revokes"), ("bobleaf", "bob's without its intermediate"),
                   ("selfsigned", "a self-signed one with alice's name")):
        r = request(R, "/admin/x.txt", cert=c)
        check(r.err is not None, "refused at the handshake: " + why, "%s %s" % (r.status, r.err))
    check(alive(), "still serving after the refused certificates")

def alive():
    return st(R, "/public/ok.txt") == 200

def passwords():
    r = request(R, "/", user="alice:opensesame")
    check(r.status == 200 and r.body == b"home\n", "password: alice's")
    for u, why in (("alice:wrong", "a wrong password"), ("mallory:opensesame", "a user that is not one"),
                   ("alice:", "an empty password"), ("alice:opensesame ", "a trailing blank")):
        check(st(R, "/", user=u) == 401, "401: " + why)
    check(st(R, "/admin/x.txt", user="alice:opensesame") == 403, "a password where a certificate is needed: 403")
    check(st(R, "/bob/x.txt", user="bob:bobpass") == 200, "password=bob: bob")
    check(st(R, "/bob/x.txt", user="alice:opensesame") == 403, "password=bob: alice's right password still 403")
    for h, why in (("Basic !!!!", "not base64"), ("Bearer abc", "another scheme"), ("Basic " + base64.b64encode(b"nocolon").decode(), "no colon"),
                   ("Basic " + base64.b64encode(b"\xff\xfe:x").decode(), "not UTF-8"), ("Basic " + base64.b64encode(b"al\x01ice:x").decode(), "a control character"),
                   ("Basic " + "A" * 2000, "too long"), ("basic " + base64.b64encode(b"alice:opensesame").decode(), "the scheme in lower case (taken)")):
        want = 200 if "taken" in why else 401
        check(st(R, "/", extra="Authorization: %s\r\n" % h) == want, "Authorization %s: %d" % (why, want))
    check(st(R, "/", extra="Authorization: Basic YWxpY2U6b3BlbnNlc2FtZQ==\r\nAuthorization: Basic Ym9iOmJvYnBhc3M=\r\n") == 400,
          "two Authorization headers: 400")
    # one connection: refused, then the same with the password (as a browser does)
    s = ctx().wrap_socket(socket.create_connection(("127.0.0.1", R), timeout=20), server_hostname="localhost")
    a = request(R, "/", keep=s)
    b = request(R, "/", user="alice:opensesame", keep=s)
    check(a.status == 401 and b.status == 200, "401 keeps the connection, and the next request on it gets in")
    s.close()
    # the cost: the first check runs PBKDF2 (100000 iterations), the next is cached
    t0 = time.time(); request(R, "/", user="carol:carolpass"); t1 = time.time()
    request(R, "/", user="carol:carolpass"); t2 = time.time()
    check(t2 - t1 < (t1 - t0), "a checked password taken again without its hash (%.0f ms, then %.0f ms)" % ((t1-t0)*1000, (t2-t1)*1000))
    # an unknown user costs a hash too: no faster than a known one's wrong password
    t0 = time.time(); request(R, "/", user="nobody%d:x" % time.time()); t1 = time.time()
    t2 = time.time(); request(R, "/", user="carol:wrong"); t3 = time.time()
    check((t1 - t0) > 0.3 * (t3 - t2), "an unknown user takes a hash's time too (%.0f ms against %.0f)" % ((t1-t0)*1000, (t3-t2)*1000))
    # the file read again when it changes
    check(st(R, "/", user="dave:davepass") == 401, "dave not yet a user")
    open(SITE + "/../pw", "a").write(open(W + "/dave.pw").read())
    time.sleep(1.1)
    check(st(R, "/", user="dave:davepass") == 200, "the password file changed: dave in, no restart")

def rules():
    for p in ("/ADMIN/x.txt", "/Admin/x.txt", "/aDmIn/x.txt", "//admin/x.txt", "/admin/X.TXT", "/public/../admin/x.txt",
              "/public/%2e%2e/admin/x.txt", "/admin./x.txt", "/admin%20/x.txt", "/admin%5cx.txt", "/public%5c..%5cadmin/x.txt",
              "/ADMIN~1/x.txt", "https://localhost/admin/x.txt", "/admin%2fx.txt"):
        got = st(R, p, raw=("GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" % p).encode())
        check(got in (400, 403, 404), "no way into /admin without a certificate: %s" % p, str(got))
    check(st(R, "/publicx.txt") == 401, "/publicx is not under /public: the / rule (a password)")
    check(st(R, "/public") == 301, "/public itself is none")
    check(st(R, "/admin", method="HEAD") == 403, "HEAD as GET")
    check(st(R, "/admin/x.txt", method="POST", user="alice:opensesame") == 403, "a POST to /admin with a password: 403")
    check(st(R, "/admin/nothere", ) == 403, "a path under /admin that is not there: 403, not 404 (nothing said of what is)")
    check(st(R, "/admin/nothere", cert="alice") == 404, "the same with a certificate: 404")
    # method rules
    check(st(R, "/led/ctl", user="alice:opensesame") == 200, "GET /led: a password does")
    check(st(R, "/led/ctl", method="POST", body=b"on", user="alice:opensesame") == 403, "POST /led: a password does not")
    check(st(R, "/led/ctl", method="POST", body=b"on", cert="bob") == 403, "POST /led: bob's certificate does not (cert=alice-laptop)")
    check(st(R, "/led/ctl", method="POST", body=b"on", cert="alice") in (200, 204) and open(SITE + "/led/ctl").read() == "on",
          "POST /led: alice's certificate writes it")
    # defaults (no -x): GET needs a password or a certificate, POST a certificate
    check(st(D, "/public/ok.txt") == 401, "defaults: every page needs a password or certificate")
    check(st(D, "/public/ok.txt", user="bob:bobpass") == 200, "defaults: a password does")
    check(st(D, "/public/ok.txt", cert="bob") == 200, "defaults: a certificate does")
    check(st(D, "/led/ctl", method="POST", body=b"x", user="alice:opensesame") == 403, "defaults: a POST needs a certificate")
    check(st(D, "/led/ctl", method="POST", body=b"x", cert="bob") in (200, 204), "defaults: a POST with one")
    # a rules file without /: what no rule names is refused
    check(st(PL, "/open/x.txt", tls=False) == 200, "-x: /open none")
    check(st(PL, "/secret/x.txt", tls=False) == 403, "-x: a path no rule names is refused")
    check(st(PL, "/", tls=False) == 403, "-x: / too")
    # the log names who
    time.sleep(0.5)
    log = open(W + "/access.log").read()
    check(re.search(r' - alice \[.*"GET / HTTP/1.1" 200 ', log) is not None, "the log's user field: alice")
    check(re.search(r' - cert:alice-laptop \[.*"GET /admin/x.txt HTTP/1.1" 200 ', log) is not None, "the log's user field: cert:alice-laptop")

def lockout():
    check(st(LO, "/", user="bob:bobpass") == 200, "bob in before the guessing")
    for i in range(10):
        st(LO, "/", user="alice:guess%d" % i)
    r = request(LO, "/", user="alice:opensesame")
    check(r.status == 429 and r.headers.get("retry-after") == "600", "ten wrong passwords from one address: the right one refused (429)", str(r.status))
    raw = socket.create_connection(("127.0.0.1", LO))
    s = ctx().wrap_socket(raw, server_hostname="localhost")
    s.sendall(b"GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\nAuthorization: Basic " + base64.b64encode(b"alice:opensesame") + b"\r\n\r\n")
    line = s.recv(100).split(b"\r\n")[0]
    s.close()
    check(line == b"HTTP/1.1 429 Too Many Requests", "its status line names it", repr(line))
    check(st(LO, "/", user="bob:bobpass") == 200, "bob, already in (his password cached), not locked out by another's guesses")
    check(st(LO, "/", user="carol:carolpass") == 429, "carol, not yet in, is")
    check(st(R, "/", user="alice:opensesame") == 200, "another server's count is its own")
    # many guesses at once: each costs a hash, one at a time, and the server answers its other clients
    res = []
    def guess():
        res.append(st(LO, "/", user="x%d:y" % threading.get_ident()))
    ts = [threading.Thread(target=guess) for i in range(12)]	# under -s 16
    for t in ts: t.start()
    for t in ts: t.join()
    check(all(x == 429 for x in res), "locked out: guesses refused without a hash", str(set(res)))
    check(alive(), "the other server still serving")

def tlsdetail():
    # the CertificateRequest names the CA, so a browser offers only its certificates
    import subprocess
    out = subprocess.run(["openssl", "s_client", "-connect", "127.0.0.1:%d" % R, "-tls1_3", "-servername", "localhost"],
                         input=b"", capture_output=True, timeout=20).stdout.decode("latin-1")
    check("Acceptable client certificate CA names" in out and "CN = Test Client CA" in out,
          "the CertificateRequest names the CA", re.findall(r"Acceptable.*\n.*", out)[:1].__repr__())
    check("Test Intermediate" not in out.split("Acceptable client certificate CA names")[-1].split("Requested Signature")[0],
          "and only the roots given")

def review():
    # identity: /alias is /admin bound again, as a host that folds case
    # or keeps 8.3 names makes /ADMIN or /ADMINI~1 of it
    check(st(R, "/alias/x.txt", user="alice:opensesame") == 403, "the protected directory under another name: its rule, by identity")
    check(st(R, "/alias/x.txt", cert="alice") == 200, "and served under it with the certificate")
    for p in ("/ADMINI~1/x.txt", "/con", "/NUL.txt", "/public/com1", "/lpt9.log", "/CONOUT$"):
        got = st(R, p, raw=("GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" % p).encode())
        check(got == 400, "refused: %s" % p, str(got))
    # what a request is served from: a .gz copy, an index page
    check(st(R, "/report.txt.gz", user="alice:opensesame") == 403, "name.gz under name's rule (an exact-file rule)")
    check(st(R, "/report.txt", user="alice:opensesame", extra="Accept-Encoding: gzip\r\n") == 403, "and name itself")
    check(st(R, "/report.txt.gz", cert="alice") == 200, "both with the certificate")
    check(st(R, "/idx/", user="alice:opensesame") == 403, "a directory under its index.html's rule")
    check(st(R, "/idx/", cert="alice") == 200, "and with it")
    # the wiki's form writes the wiki: a POST rule on the wiki holds
    check(st(R, "/magic/wikipost", method="POST", body=b"title=x&version=0&text=y", user="alice:opensesame",
             extra="Content-Type: application/x-www-form-urlencoded\r\n") == 403, "the wiki's form under the wiki's POST rule")
    check(st(R, "/magic/wikipost", method="POST", body=b"title=x&version=0&text=y", cert="alice",
             extra="Content-Type: application/x-www-form-urlencoded\r\n") not in (401, 403), "and taken with its certificate")
    # listings: what a client may not have is not named
    r = request(R, "/mixed/", user="alice:opensesame")
    check(r.status == 200 and b"open.txt" in r.body and b"locked/" not in r.body,
          "a listing leaves out what its client may not have", repr(r.body[-200:]))
    r = request(R, "/mixed/", cert="alice")
    check(b"locked/" in r.body, "and names it for one who may")
    # event streams: UTF-8 kept, at most half an address's connections
    s = ctx().wrap_socket(socket.create_connection(("127.0.0.1", R), timeout=20), server_hostname="localhost")
    s.sendall(b"GET /ev/feed HTTP/1.1\r\nHost: a\r\nAccept: text/event-stream\r\nAuthorization: Basic " + base64.b64encode(b"alice:opensesame") + b"\r\n\r\n")
    buf = b""
    while b"data:" not in buf or b"\n\n" not in buf.split(b"data:", 1)[1]:
        buf += s.recv(4096)
    check("data: café ☕\n".encode() in buf, "an event's UTF-8 as it was", repr(buf[-40:]))
    streams = [s]
    for i in range(7):
        t = ctx().wrap_socket(socket.create_connection(("127.0.0.1", R), timeout=20), server_hostname="localhost")
        t.sendall(b"GET /ev/feed HTTP/1.1\r\nHost: a\r\nAccept: text/event-stream\r\nAuthorization: Basic " + base64.b64encode(b"alice:opensesame") + b"\r\n\r\n")
        t.recv(100)
        streams.append(t)
    r = request(R, "/ev/feed", user="alice:opensesame", extra="Accept: text/event-stream\r\n")
    check(r.status == 503, "a ninth event stream from one address: 503 (eight is half of -s 16)", str(r.status))
    check(alive(), "and other requests are served")
    for t in streams:
        t.close()
    # each stream's end is found at its next write (the feed answers
    # its readers one at a time, a second each): wait for the slots
    got = None
    for i in range(25):
        time.sleep(1)
        s = ctx().wrap_socket(socket.create_connection(("127.0.0.1", R), timeout=20), server_hostname="localhost")
        s.sendall(b"GET /ev/feed HTTP/1.1\r\nHost: a\r\nAccept: text/event-stream\r\nAuthorization: Basic " + base64.b64encode(b"alice:opensesame") + b"\r\n\r\n")
        got = s.recv(100)
        s.close()
        if got.startswith(b"HTTP/1.1 200"):
            break
    check(got is not None and got.startswith(b"HTTP/1.1 200"), "streams closed: a new one taken", repr(got[:20] if got else got))
    # a body trickled in: the whole of it within the deadline, not each byte
    s = ctx(cert="alice").wrap_socket(socket.create_connection(("127.0.0.1", R), timeout=60), server_hostname="localhost")
    s.sendall(b"POST /led/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: 100\r\n\r\n")
    t0 = time.time()
    closed = False
    while time.time() - t0 < 45:
        try:
            s.sendall(b"x")
            s.settimeout(5)
            if s.recv(10) == b"":
                closed = True
                break
        except socket.timeout:
            continue
        except (OSError, ssl.SSLError):
            closed = True
            break
    check(closed and time.time() - t0 < 40, "a body sent a byte at a time: hung up within its deadline", "%.0fs" % (time.time() - t0))
    s.close()
    # more in the ClientHello's record than the ClientHello
    inb, outb = ssl.MemoryBIO(), ssl.MemoryBIO()
    c = ssl.create_default_context(cafile=W + "/server.pem").wrap_bio(inb, outb, server_hostname="localhost")
    try:
        c.do_handshake()
    except ssl.SSLWantReadError:
        pass
    rec = outb.read()
    body = rec[5:] + b"\x14\x00\x00\x20" + b"\x00" * 32
    rec = rec[0:3] + len(body).to_bytes(2, "big") + body
    s = socket.create_connection(("127.0.0.1", R), timeout=10)
    s.sendall(rec)
    d = s.recv(100)
    check(d[:1] == b"\x15" or d == b"", "a Finished after the ClientHello in its record: an alert", repr(d[:8]))
    s.close()

def wedge():
    # a password whose check outlasts its connection's deadline (made
    # to take about 45 s here, from the speed measured): the connection
    # is killed while the authenticator works, and the authenticator
    # must still be there for the next login
    t0 = time.time(); request(R, "/", user="carol:wrong"); per = (time.time() - t0) / 100000
    iters = int(45 / max(per, 1e-7))
    line = "slow:pbkdf2-sha256:%d:%s:%s\n" % (iters, base64.b64encode(b"saltsaltsaltsalt").decode(), base64.b64encode(b"h" * 32).decode())
    open(W + "/pw", "a").write(line)
    time.sleep(1.1)
    s = ctx().wrap_socket(socket.create_connection(("127.0.0.1", R), timeout=120), server_hostname="localhost")
    s.sendall(b"GET / HTTP/1.1\r\nHost: a\r\nAuthorization: Basic " + base64.b64encode(b"slow:guess") + b"\r\n\r\n")
    t0 = time.time()
    try:
        d = s.recv(100)
    except Exception:
        d = b""
    took = time.time() - t0
    check(d == b"" and took < 40, "a check longer than the deadline: its connection hung up", "%r after %.0fs" % (d[:20], took))
    t0 = time.time()
    r = request(R, "/", user="alice:opensesame")
    check(r.status == 200, "and the authenticator answers the next login (%.0f s later)" % (time.time() - t0), str(r.status))

for f in (certs, passwords, rules, tlsdetail, review, lockout, wedge):
    try:
        f()
    except Exception as e:
        import traceback
        traceback.print_exc()
        check(False, f.__name__ + " raised", repr(e))
print("%d failed" % fails)
sys.exit(min(fails, 100))

#!/usr/bin/env python3
#
# tests/host/httpd/attack.py: svc/httpd/httpd from outside, over raw
# sockets and TLS.  Run by tests/host/httpd_test.sh, which starts the
# servers and makes the site:
#
#   attack.py PLAIN TLS REDIRECT FLOOD CAFILE SITEDIR EMULOG
#
# PLAIN:    -L -p /post/ctl -w /wiki, on 127.0.0.1
# TLS:      the same site over TLS 1.3, -S 600
# REDIRECT: -r <TLS port>
# FLOOD:    -n 6 -s 3, for the admission limits
#
# Each check prints PASS: or FAIL:; the exit status is the failures.
#

import os, random, socket, ssl, sys, time, threading, hashlib

PLAIN, TLSP, REDIR, FLOOD = (int(x) for x in sys.argv[1:5])
CAFILE, SITE, EMULOG = sys.argv[5], sys.argv[6], sys.argv[7]
HOST = "127.0.0.1"
fails = 0

def check(ok, what, detail=""):
    global fails
    if ok:
        print("PASS: " + what)
    else:
        fails += 1
        print("FAIL: " + what + (": " + detail if detail else ""))
    sys.stdout.flush()

def connect(port, tls=False, timeout=10):
    s = socket.create_connection((HOST, port), timeout=timeout)
    if tls:
        ctx = ssl.create_default_context(cafile=CAFILE)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.set_alpn_protocols(["h2", "http/1.1"])
        s = ctx.wrap_socket(s, server_hostname="localhost")
    return s

class Resp:
    def __init__(self):
        self.status = 0; self.reason = ""; self.headers = {}; self.hlist = []
        self.body = b""; self.raw = b""; self.closed = False

def recvall(s, n):
    out = b""
    while len(out) < n:
        d = s.recv(n - len(out))
        if not d:
            break
        out += d
    return out

class Reader:
    def __init__(self, s):
        self.s = s; self.buf = b""; self.eof = False
    def more(self):
        try:
            d = self.s.recv(65536)
        except (ConnectionResetError, ssl.SSLError, BrokenPipeError):
            d = b""
        if not d:
            self.eof = True
        self.buf += d
        return d
    def line(self):
        while b"\r\n" not in self.buf:
            if not self.more():
                return None
        l, self.buf = self.buf.split(b"\r\n", 1)
        return l
    def take(self, n):
        while len(self.buf) < n:
            if not self.more():
                break
        d, self.buf = self.buf[:n], self.buf[n:]
        return d
    def rest(self):
        while self.more():
            pass
        d, self.buf = self.buf, b""
        return d

# one response from r; head: a HEAD's (no body)
def response(r, head=False):
    resp = Resp()
    l = r.line()
    if l is None:
        resp.closed = True
        return resp
    parts = l.decode("latin-1").split(" ", 2)
    resp.status = int(parts[1]); resp.reason = parts[2] if len(parts) > 2 else ""
    while True:
        h = r.line()
        if h is None:
            resp.closed = True
            return resp
        if h == b"":
            break
        k, v = h.decode("latin-1").split(":", 1)
        resp.headers[k.strip().lower()] = v.strip()
        resp.hlist.append((k.strip().lower(), v.strip()))
    if resp.status == 100:
        return response(r, head)
    if head or resp.status in (204, 304) or resp.status < 200:
        return resp
    if "content-length" in resp.headers:
        resp.body = r.take(int(resp.headers["content-length"]))
    elif resp.headers.get("transfer-encoding") == "chunked":
        while True:
            n = int(r.line(), 16)
            if n == 0:
                r.line()
                break
            resp.body += r.take(n)
            r.line()
    else:
        resp.body = r.rest()
    return resp

def raw(port, data, tls=False, timeout=10, head=False):
    s = connect(port, tls, timeout)
    s.sendall(data)
    r = Reader(s)
    resp = response(r, head)
    s.close()
    return resp

def get(port, path, tls=False, extra="", method="GET", host="localhost"):
    return raw(port, ("%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n%s\r\n" % (method, path, host, extra)).encode("latin-1"),
               tls, head=(method == "HEAD"))

def status(port, data, tls=False):
    try:
        return raw(port, data, tls).status
    except (socket.timeout, ConnectionResetError, ssl.SSLError) as e:
        return -1

def alive(port=PLAIN, tls=False):
    try:
        return get(port, "/hello.txt", tls).body == open(SITE + "/hello.txt", "rb").read()
    except Exception as e:
        return False

def fileof(p):
    return open(SITE + p, "rb").read()

# ---------------------------------------------------------------- files

def files():
    for tls, port, name in ((False, PLAIN, "plain"), (True, TLSP, "tls")):
        r = get(port, "/hello.txt", tls)
        check(r.status == 200 and r.body == fileof("/hello.txt"), name + ": a file")
        check(r.headers.get("content-type") == "text/plain; charset=utf-8", name + ": its type", r.headers.get("content-type", ""))
        check(r.headers.get("x-content-type-options") == "nosniff", name + ": nosniff")
        r = get(port, "/big.bin", tls)
        check(r.status == 200 and hashlib.sha256(r.body).digest() == hashlib.sha256(fileof("/big.bin")).digest(),
              name + ": 5 MB byte for byte", "%d bytes" % len(r.body))
        r = get(port, "/hello.txt", tls, method="HEAD")
        check(r.status == 200 and r.headers.get("content-length") == str(len(fileof("/hello.txt"))) and r.body == b"",
              name + ": HEAD has the length and no body")
    r = get(TLSP, "/hello.txt", True)
    check(r.headers.get("strict-transport-security") == "max-age=600", "tls: -S sends HSTS")
    check("strict-transport-security" not in get(PLAIN, "/hello.txt").headers, "plain: no HSTS")
    check(get(PLAIN, "/").body == fileof("/index.html"), "index.html for /")
    r = get(PLAIN, "/sub")
    check(r.status == 301 and r.headers.get("location") == "/sub/", "a directory without its slash: 301 to it", r.headers.get("location", ""))
    r = get(PLAIN, "/sub?x=1")
    check(r.headers.get("location") == "/sub/?x=1", "the 301 keeps the query")
    r = get(PLAIN, "/sub/")
    check(r.status == 200 and b"a.txt" in r.body and b"&lt;script&gt;" in r.body and b"<script>" not in r.body,
          "-L lists a directory, names escaped")
    check(b".hidden" not in r.body, "the listing leaves out dotfiles")
    check("default-src 'none'" in r.headers.get("content-security-policy", ""), "a listing has a CSP")
    check(get(PLAIN, "/sub/%3cscript%3e.txt").status == 200, "a percent-encoded name")
    check(get(PLAIN, "/sp%20ace.txt").body == fileof("/sp ace.txt"), "a name with a blank")
    check(get(PLAIN, "/%e2%82%ac.txt").body == fileof("/€.txt"), "a UTF-8 name")
    check(get(PLAIN, "/nothere").status == 404, "not there: 404")
    check(get(PLAIN, "/hello.txt", host="[::1]:%d" % PLAIN).status == 200, "an IPv6 Host")
    check(get(PLAIN, "/hello.txt", host="[::1").status == 400, "a broken IPv6 Host: 400")
    check(get(PLAIN, "/.hidden").status == 404, "a dotfile: 404")
    check(get(PLAIN, "/sub/.hidden/x").status == 404, "a dot directory: 404")
    r = get(PLAIN, "/nothere")
    check(b"/nothere" not in r.body, "an error page does not echo the path")

def ranges():
    big = fileof("/big.bin")
    r = get(PLAIN, "/big.bin", extra="Range: bytes=100-199\r\n")
    check(r.status == 206 and r.body == big[100:200] and r.headers.get("content-range") == "bytes 100-199/%d" % len(big), "a range")
    r = get(PLAIN, "/big.bin", extra="Range: bytes=-10\r\n")
    check(r.status == 206 and r.body == big[-10:], "a suffix range")
    r = get(PLAIN, "/big.bin", extra="Range: bytes=%d-\r\n" % (len(big) - 5))
    check(r.status == 206 and r.body == big[-5:], "an open range")
    r = get(PLAIN, "/big.bin", extra="Range: bytes=0-0\r\n")
    check(r.status == 206 and r.body == big[0:1], "one byte")
    r = get(PLAIN, "/big.bin", extra="Range: bytes=%d-\r\n" % len(big))
    check(r.status == 416 and r.headers.get("content-range") == "bytes */%d" % len(big), "past the end: 416")
    r = get(PLAIN, "/big.bin", extra="Range: bytes=0-1,5-6\r\n")
    check(r.status == 200 and len(r.body) == len(big), "several ranges: the whole file")
    for bad in ("bytes=5-1", "bytes=x-", "bytes=--1", "items=0-1", "bytes=99999999999999999999-"):
        r = get(PLAIN, "/hello.txt", extra="Range: %s\r\n" % bad)
        check(r.status == 200 and r.body == fileof("/hello.txt"), "range %r ignored" % bad, str(r.status))
    r = get(PLAIN, "/big.bin", extra="Range: bytes=0-1\r\nIf-Range: \"stale\"\r\n")
    check(r.status == 200 and len(r.body) == len(big), "If-Range not matching: the whole file")

def conditional():
    r = get(PLAIN, "/hello.txt")
    et, lm = r.headers.get("etag"), r.headers.get("last-modified")
    check(et and lm, "ETag and Last-Modified")
    check(get(PLAIN, "/hello.txt", extra="If-None-Match: %s\r\n" % et).status == 304, "If-None-Match: 304")
    check(get(PLAIN, "/hello.txt", extra="If-None-Match: \"a\", W/%s\r\n" % et).status == 304, "If-None-Match list, weak: 304")
    check(get(PLAIN, "/hello.txt", extra="If-None-Match: \"other\"\r\n").status == 200, "If-None-Match other: 200")
    check(get(PLAIN, "/hello.txt", extra="If-Modified-Since: %s\r\n" % lm).status == 304, "If-Modified-Since: 304")
    check(get(PLAIN, "/hello.txt", extra="If-Modified-Since: Thu, 01 Jan 1970 00:00:01 GMT\r\n").status == 200, "If-Modified-Since long ago: 200")
    check(get(PLAIN, "/hello.txt", extra="If-Modified-Since: garbage\r\n").status == 200, "If-Modified-Since garbage: 200")
    check(get(PLAIN, "/hello.txt", extra="If-None-Match: \"other\"\r\nIf-Modified-Since: %s\r\n" % lm).status == 200,
          "If-None-Match decides over If-Modified-Since")

def stream():
    r = get(PLAIN, "/sysname")
    check(r.status == 200 and r.headers.get("transfer-encoding") == "chunked" and len(r.body) > 0,
          "a file of no known length: chunked", repr(r.headers))
    check(r.headers.get("cache-control") == "no-store" and "etag" not in r.headers, "and not cached")
    r = raw(PLAIN, b"GET /sysname HTTP/1.0\r\n\r\n")
    check(r.status == 200 and "transfer-encoding" not in r.headers and len(r.body) > 0, "under HTTP/1.0: to the end")

def connections():
    s = connect(PLAIN)
    rd = Reader(s)
    ok = True
    for i in range(5):
        s.sendall(b"GET /hello.txt HTTP/1.1\r\nHost: a\r\n\r\n")
        if response(rd).body != fileof("/hello.txt"):
            ok = False
    check(ok, "five requests on one connection")
    s.sendall(b"GET /hello.txt HTTP/1.1\r\nHost: a\r\n\r\n" * 3 + b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
    got = [response(rd).status for i in range(4)]
    check(got == [200] * 4, "four pipelined", str(got))
    check(rd.rest() == b"", "Connection: close closes")
    s.close()
    r = raw(PLAIN, b"GET /hello.txt HTTP/1.0\r\n\r\n")
    check(r.status == 200 and r.headers.get("connection") == "close", "HTTP/1.0 closes")
    s = connect(PLAIN)
    rd = Reader(s)
    s.sendall(b"GET /hello.txt HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
    r1 = response(rd)
    s.sendall(b"GET /hello.txt HTTP/1.0\r\n\r\n")
    r2 = response(rd)
    check(r1.headers.get("connection") == "keep-alive" and r2.status == 200, "HTTP/1.0 keep-alive")
    s.close()
    # a connection kept to its limit of 100 requests is closed after it
    s = connect(PLAIN)
    rd = Reader(s)
    s.sendall(b"GET /hello.txt HTTP/1.1\r\nHost: a\r\n\r\n" * 1001)
    n = 0
    while True:
        r = response(rd)
        if r.closed:
            break
        n += 1
    check(n == 1000, "1000 requests on a connection, then it closes", str(n))
    s.close()
    # many at once
    res = []
    def one():
        res.append(alive())
    ts = [threading.Thread(target=one) for i in range(40)]
    for t in ts: t.start()
    for t in ts: t.join()
    check(all(res) and len(res) == 40, "40 clients at once", str(res.count(False)))
    res.clear()
    def onetls():
        res.append(alive(TLSP, True))
    ts = [threading.Thread(target=onetls) for i in range(15)]
    for t in ts: t.start()
    for t in ts: t.join()
    check(all(res) and len(res) == 15, "15 TLS clients at once", str(res.count(False)))

def methods():
    check(get(PLAIN, "/hello.txt", method="PUT").status == 405, "PUT: 405")
    r = get(PLAIN, "/hello.txt", method="DELETE")
    check(r.status == 405 and r.headers.get("allow") == "GET, HEAD", "DELETE: 405, Allow")
    check(get(PLAIN, "/hello.txt", method="TRACE").status == 405, "TRACE: 405")
    check(get(PLAIN, "/hello.txt", method="BREW").status == 501, "an unknown method: 501")
    check(get(PLAIN, "/hello.txt", method="get").status == 501, "a lower-case method: 501")
    check(raw(PLAIN, b"OPTIONS * HTTP/1.1\r\nHost: a\r\n\r\n").status == 501, "OPTIONS *: 501")
    check(raw(PLAIN, b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\n\r\nabc").status == 400, "a GET with a body: 400")

def posts():
    open(SITE + "/post/ctl", "wb").write(b"")
    body = b"led on\n"
    r = raw(PLAIN, b"POST /post/ctl HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
    check(r.status in (200, 204) and fileof("/post/ctl") == body, "POST to a -p path writes its body", str(r.status))
    r = raw(PLAIN, b"POST /hello.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\nX")
    check(r.status == 405 and fileof("/hello.txt") != b"X", "POST elsewhere: 405, nothing written")
    check("POST" in raw(PLAIN, b"DELETE /post/ctl HTTP/1.1\r\nHost: a\r\n\r\n").headers.get("allow", ""), "Allow names POST where it is taken")
    r = raw(PLAIN, b"POST /post/ctl HTTP/1.1\r\nHost: localhost:%d\r\nOrigin: http://evil.example\r\nContent-Length: 3\r\n\r\nbad" % PLAIN)
    check(r.status == 403 and fileof("/post/ctl") == body, "a POST from another origin: 403")
    r = raw(PLAIN, b"POST /post/ctl HTTP/1.1\r\nHost: localhost:%d\r\nSec-Fetch-Site: cross-site\r\nContent-Length: 3\r\n\r\nbad" % PLAIN)
    check(r.status == 403, "Sec-Fetch-Site cross-site: 403")
    r = raw(PLAIN, b"POST /post/ctl HTTP/1.1\r\nHost: localhost:%d\r\nOrigin: http://localhost:%d\r\nContent-Length: 2\r\n\r\nok" % (PLAIN, PLAIN))
    check(r.status in (200, 204) and fileof("/post/ctl") == b"ok", "a POST from the site itself")
    r = raw(PLAIN, b"POST /post/ctl HTTP/1.1\r\nHost: localhost\r\nOrigin: null\r\nContent-Length: 2\r\n\r\nno")
    check(r.status == 403, "Origin: null: 403")
    check(raw(PLAIN, b"POST /post/ctl HTTP/1.1\r\nHost: a\r\n\r\n").status == 411, "POST without a length: 411")
    check(raw(PLAIN, b"POST /post/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: 999999\r\n\r\n").status == 413, "POST too large: 413")
    s = connect(PLAIN)
    s.sendall(b"POST /post/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n")
    rd = Reader(s)
    l = rd.line()
    rd.line()
    s.sendall(b"cont")
    r = response(rd)
    check(l == b"HTTP/1.1 100 Continue" and r.status in (200, 204) and fileof("/post/ctl") == b"cont", "Expect: 100-continue")
    s.close()
    check(raw(PLAIN, b"POST /post/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nExpect: magic\r\n\r\nx").status == 417, "another Expect: 417")

def wiki():
    r = get(PLAIN, "/wiki/my_first_wiki_page/edit.html")
    check(r.status == 200 and b'action="/magic/wikipost"' in r.body, "the wiki's edit form")
    import re
    v = re.search(rb'name="version" value="(\d+)"', r.body).group(1)
    form = b"title=my+first+wiki+page&version=" + v + b"&author=t&comment=c&base=http%3A%2F%2Fevil.example&text=Edited+by+the+test.%0D%0A"
    r = raw(PLAIN, b"POST /magic/wikipost HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\n" % len(form) + form)
    check(r.status == 303 and r.headers.get("location") == "/wiki/my_first_wiki_page/index.html",
          "an edit posted: 303 to the page, not the form's base", "%d %s" % (r.status, r.headers.get("location")))
    r = get(PLAIN, "/wiki/my_first_wiki_page/index.html")
    check(b"Edited" in r.body and b"test." in r.body, "the page has the edit", "%d %r" % (r.status, r.body[-200:]))
    form = b"title=x%0AD999&version=0&text=y"
    r = raw(PLAIN, b"POST /magic/wikipost HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\n" % len(form) + form)
    check(r.status in (303, 422, 500), "a title with a newline does not add a header line", str(r.status))
    r = raw(PLAIN, b"POST /magic/wikipost HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nabc")
    check(r.status == 415, "the wiki takes a form alone: 415")
    r = raw(PLAIN, b"POST /magic/wikipost HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 9\r\n\r\ntitle=%zz")
    check(r.status == 400, "bad form encoding: 400")
    check(get(TLSP, "/magic/wikipost", True, method="POST").status == 405, "no -w: no wiki")

def redirect():
    r = get(REDIR, "/sub/a.txt?q=1", host="example.org")
    check(r.status == 301 and r.headers.get("location") == "https://example.org:%d/sub/a.txt?q=1" % TLSP, "-r: 301 to https", r.headers.get("location", ""))
    r = get(REDIR, "/x", host="example.org:80")
    check(r.headers.get("location") == "https://example.org:%d/x" % TLSP, "-r drops the Host's port")
    check(get(REDIR, "/x", host="evil.example/x").status == 400, "-r: a Host that is not one refused")
    check(get(REDIR, "/x", host="a\"b").status == 400, "-r: a Host with a quote refused")
    check(raw(REDIR, b"GET /x HTTP/1.0\r\n\r\n").status == 400, "-r: no Host: 400")

# ---------------------------------------------------------------- attacks

def traversal():
    bad = ["/../hello.txt", "/sub/../../etc/passwd", "/%2e%2e/%2e%2e/dis/sh.dis", "/%2E%2e/x", "/sub/..%2f..%2fx",
           "/..%2F..%2Fdis", "/sub/%2e%2e%2f%2e%2e%2fdis/sh.dis", "/./hello.txt", "/sub/./a.txt", "/%2e/hello.txt",
           "/sub/%c0%ae%c0%ae/x", "/%c0%afetc", "/hello.txt%00.html", "/%00", "/a%0d%0aSet-Cookie:x",
           "/%ff", "/a%", "/a%4", "/a%g0", "http://localhost/../x", "/a\x01b", "/\x7f"]
    for p in bad:
        st = status(PLAIN, ("GET %s HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n" % p).encode("latin-1"))
        check(st == 400, "refused: %r" % p, str(st))
    for p in ["/dis/sh.dis", "/dev/sysname", "/prog", "/n/local", "/#c/sysname", "/%23c/sysname", "/%23U*/etc/passwd",
              "/%23s", "/env", "/link.txt", "/etcdir/hostname", "/sub/escape/hostname", "/%252e%252e/hello.txt"]:
        r = get(PLAIN, p)
        check(r.status in (400, 403, 404), "nothing outside the site: %s" % p, "%d %r" % (r.status, r.body[:60]))
    # absolute-form with an authority
    r = raw(PLAIN, b"GET http://localhost/hello.txt HTTP/1.1\r\nHost: localhost\r\n\r\n")
    check(r.status == 200 and r.body == fileof("/hello.txt"), "absolute-form taken")
    check(status(PLAIN, b"GET http://bad host/x HTTP/1.1\r\nHost: a\r\n\r\n") == 400, "absolute-form with a bad authority: 400")
    check(status(PLAIN, b"GET /hello.txt#frag HTTP/1.1\r\nHost: a\r\n\r\n") == 400, "a fragment: 400")
    check(get(PLAIN, "/" + "a/" * 1100).status == 400, "a path past 2K: 400")

def parsing():
    cases = [
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n", 501, "CL and TE"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", 501, "TE"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nTransfer-Encoding : chunked\r\n\r\n", 400, "space before a colon"),
        (b"POST /post/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab", 400, "two lengths"),
        (b"POST /post/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: +2\r\n\r\nab", 400, "a signed length"),
        (b"POST /post/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: 2, 2\r\n\r\nab", 400, "a list as a length"),
        (b"POST /post/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: 0x2\r\n\r\nab", 400, "a hex length"),
        (b"POST /post/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: 99999999999999999999999\r\n\r\n", 400, "a huge length"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nX: a\r\n b\r\n\r\n", 400, "a folded header"),
        (b"GET /hello.txt HTTP/1.1\nHost: a\n\n", 400, "bare LF"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\rX: b\r\n\r\n", 400, "bare CR"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nX: a\x00b\r\n\r\n", 400, "NUL in a header"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nX: a\x01b\r\n\r\n", 400, "a control character in a header"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nBad Name: x\r\n\r\n", 400, "a blank in a header name"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\r\n: x\r\n\r\n", 400, "an empty header name"),
        (b"GET /hello.txt HTTP/1.1\r\n\r\n", 400, "HTTP/1.1 without Host"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", 400, "two Hosts"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a b\r\n\r\n", 400, "a blank in Host"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a:99999\r\n\r\n", 400, "a bad port in Host"),
        (b"GET /hello.txt HTTP/1.1\r\nHost: a/b\r\n\r\n", 400, "a slash in Host"),
        (b"GET /hello.txt HTTP/2.0\r\nHost: a\r\n\r\n", 505, "HTTP/2.0"),
        (b"GET /hello.txt HTTP/1.1x\r\nHost: a\r\n\r\n", 505, "HTTP/1.1x"),
        (b"GET /hello.txt FTP/1.0\r\n\r\n", 400, "not HTTP"),
        (b"GET  /hello.txt HTTP/1.1\r\nHost: a\r\n\r\n", 400, "two blanks"),
        (b"GET /hello.txt  HTTP/1.1\r\nHost: a\r\n\r\n", 400, "two blanks after the path"),
        (b"GET /hello.txt\r\n\r\n", 400, "HTTP/0.9"),
        (b"GET\r\n\r\n", 400, "a method alone"),
        (b"GET hello.txt HTTP/1.1\r\nHost: a\r\n\r\n", 400, "a relative target"),
        (b"\r\n\r\nGET /hello.txt HTTP/1.1\r\nHost: a\r\n\r\n", 400, "two empty lines first"),
        (b"GET /x HTTP/1.1\r\nHost: a\r\n" + b"X: " + b"a" * 9000 + b"\r\n\r\n", 431, "a header line of 9000"),
        (b"GET /x HTTP/1.1\r\nHost: a\r\n" + b"".join(b"X%d: y\r\n" % i for i in range(70)) + b"\r\n", 431, "70 headers"),
        (b"GET /x HTTP/1.1\r\nHost: a\r\n" + b"".join(b"X%d: %s\r\n" % (i, b"y" * 400) for i in range(50)) + b"\r\n", 431, "20K of headers"),
        (b"GET /" + b"a" * 9000 + b" HTTP/1.1\r\nHost: a\r\n\r\n", 414, "a request line of 9000"),
        (b"\xff\xfe GET / HTTP/1.1\r\n\r\n", 400, "binary"),
    ]
    for data, want, what in cases:
        st = status(PLAIN, data)
        check(st == want, "%s: %d" % (what, want), str(st))
    check(status(PLAIN, b"\r\nGET /hello.txt HTTP/1.1\r\nHost: a\r\n\r\n") == 200, "one empty line first is ignored")
    # a refused request ends its connection: what follows is not run
    s = connect(PLAIN)
    s.sendall(b"GET /hello.txt HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /hello.txt HTTP/1.1\r\nHost: a\r\n\r\n")
    rd = Reader(s)
    r1 = response(rd)
    r2 = response(rd)
    check(r1.status == 501 and r2.closed, "after a smuggling attempt nothing else is answered")
    s.close()

def slow():
    # slowloris: a header a byte at a time, for ever
    s = connect(PLAIN, timeout=30)
    s.sendall(b"GET /hello.txt HTTP/1.1\r\nHost: a\r\n")
    t0 = time.time()
    closed = False
    while time.time() - t0 < 25:
        try:
            s.sendall(b"X")
            s.settimeout(1)
            d = s.recv(100)
            if d == b"":
                closed = True
                break
        except socket.timeout:
            continue
        except (ConnectionResetError, BrokenPipeError, OSError):
            closed = True
            break
    took = time.time() - t0
    check(closed and took < 13, "slowloris hung up within the header deadline", "%.1fs" % took)
    s.close()
    # a connection that says nothing
    s = connect(PLAIN, timeout=30)
    t0 = time.time()
    try:
        d = s.recv(10)
    except Exception:
        d = b""
    took = time.time() - t0
    check(d == b"" and took < 13, "a silent connection hung up", "%.1fs" % took)
    # TLS: a ClientHello begun and never finished
    s = socket.create_connection((HOST, TLSP), timeout=30)
    s.sendall(b"\x16\x03\x01\x02\x00\x01")
    t0 = time.time()
    try:
        d = s.recv(10)
    except Exception:
        d = b""
    took = time.time() - t0
    check(took < 13, "a TLS handshake left unfinished hung up", "%.1fs" % took)
    # a body promised and not sent
    s = connect(PLAIN, timeout=60)
    s.sendall(b"POST /post/ctl HTTP/1.1\r\nHost: a\r\nContent-Length: 10\r\n\r\nab")
    t0 = time.time()
    try:
        d = s.recv(1000)
    except Exception:
        d = b""
    took = time.time() - t0
    check(took < 33, "a body not sent: hung up within the I/O deadline", "%.1fs" % took)
    # a file whose reads never return (a 9P server that does not
    # answer): the connection's process is killed at its I/O deadline
    s = connect(PLAIN, timeout=60)
    s.sendall(b"GET /block HTTP/1.1\r\nHost: a\r\n\r\n")
    t0 = time.time()
    try:
        d = s.recv(1000)
    except Exception:
        d = b""
    took = time.time() - t0
    check(took < 33, "a file that never answers: hung up within the I/O deadline", "%.1fs" % took)
    check(alive(), "still serving after the slow clients")

def flood():
    # FLOOD has -n 6 -s 3: a fourth connection from us is closed unanswered
    held = [connect(FLOOD) for i in range(3)]
    time.sleep(0.5)
    extra = connect(FLOOD)
    extra.sendall(b"GET /hello.txt HTTP/1.1\r\nHost: a\r\n\r\n")
    try:
        d = extra.recv(100)
    except Exception:
        d = b""
    check(d == b"", "past -s, a connection is closed unanswered", repr(d[:30]))
    for s in held:
        s.close()
    extra.close()
    time.sleep(1)
    check(alive(FLOOD), "once they close, connections are taken again")
    # 300 connections opened and dropped
    for i in range(300):
        try:
            s = socket.create_connection((HOST, PLAIN), timeout=5)
            if i % 3 == 0:
                s.sendall(b"GET /hel")
            s.close()
        except OSError:
            pass
    time.sleep(1)
    check(alive(), "still serving after 300 connections dropped")

def tlsattacks():
    # TLS 1.2 refused
    s = socket.create_connection((HOST, TLSP), timeout=10)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    try:
        ctx.wrap_socket(s, server_hostname="localhost")
        ok = False
    except ssl.SSLError as e:
        ok = "VERSION" in str(e).upper()
    check(ok, "TLS 1.2 refused")
    # plain HTTP to the TLS port
    try:
        d = raw(TLSP, b"GET / HTTP/1.1\r\nHost: a\r\n\r\n")
        ok = d.status == 0
    except Exception:
        ok = True
    check(ok, "plain HTTP to the TLS port gets no HTTP")
    # the ALPN agreed
    s = connect(TLSP, True)
    check(s.selected_alpn_protocol() == "http/1.1", "ALPN http/1.1", str(s.selected_alpn_protocol()))
    check(s.version() == "TLSv1.3", "TLS 1.3")
    s.close()
    # only h2 offered: no protocol in common
    s = socket.create_connection((HOST, TLSP), timeout=10)
    ctx = ssl.create_default_context(cafile=CAFILE)
    ctx.set_alpn_protocols(["h2"])
    try:
        ctx.wrap_socket(s, server_hostname="localhost")
        ok = False
    except ssl.SSLError as e:
        ok = "NO_APPLICATION_PROTOCOL" in str(e).upper()
    check(ok, "only h2 offered: refused (no_application_protocol)")
    # a ClientHello that says it is a megabyte
    s = socket.create_connection((HOST, TLSP), timeout=10)
    s.sendall(b"\x16\x03\x01\x40\x00" + b"\x01\x10\x00\x00" + b"\x00" * 16380)
    try:
        d = s.recv(100)
    except Exception:
        d = b""
    check(len(d) < 10, "a ClientHello of a megabyte refused")
    s.close()
    # garbage
    rnd = random.Random(7)
    for i in range(200):
        try:
            s = socket.create_connection((HOST, TLSP), timeout=5)
            n = rnd.randint(1, 3000)
            data = bytes(rnd.getrandbits(8) for _ in range(n))
            if i % 2:
                data = b"\x16\x03\x01" + bytes([n >> 8 & 0xff, n & 0xff]) + data
            s.sendall(data)
            s.shutdown(socket.SHUT_WR)
            s.settimeout(5)
            while s.recv(4096):
                pass
            s.close()
        except OSError:
            pass
    check(alive(TLSP, True), "200 garbage TLS connections, still serving")

def fuzz():
    rnd = random.Random(11)
    seeds = [b"GET /hello.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=1-5\r\nIf-None-Match: \"x\"\r\n\r\n",
             b"POST /post/ctl HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\nOrigin: http://localhost\r\n\r\nfuzz",
             b"HEAD /sub/ HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
             b"POST /magic/wikipost HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 30\r\n\r\ntitle=fuzz&version=0&text=hi%2"]
    toks = [b"\r\n", b"\n", b"\r", b"\x00", b" ", b"%", b"%00", b"%2e%2e/", b"../", b":", b"\t", b"\xff", b"Content-Length: 99\r\n",
            b"Transfer-Encoding: chunked\r\n", b"Host: x\r\n", b"Range: bytes=-0\r\n", b"Expect: 100-continue\r\n", b"9" * 30]
    bad = 0
    for i in range(1500):
        m = bytearray(rnd.choice(seeds))
        for k in range(rnd.randint(1, 4)):
            op = rnd.randint(0, 3)
            pos = rnd.randint(0, len(m))
            if op == 0 and len(m):
                m[rnd.randrange(len(m))] = rnd.getrandbits(8)
            elif op == 1:
                m[pos:pos] = rnd.choice(toks)
            elif op == 2:
                del m[pos:pos + rnd.randint(1, 10)]
            else:
                m = m[:pos]
        try:
            s = socket.create_connection((HOST, PLAIN), timeout=20)
            s.sendall(bytes(m))
            s.shutdown(socket.SHUT_WR)
            rd = Reader(s)
            l = rd.line()
            if l is not None and not l.startswith(b"HTTP/1.1 "):
                bad += 1
                print("    odd answer to %r: %r" % (bytes(m)[:80], l[:80]))
            rd.rest()
            s.close()
        except socket.timeout:
            bad += 1
            print("    no end to %r" % bytes(m)[:80])
        except OSError:
            pass
    check(bad == 0, "1500 mutated requests: each answered with a status line or closed", "%d odd" % bad)
    check(alive() and alive(TLSP, True), "still serving after the fuzz")
    check(fileof("/hello.txt") == b"hello, world\n", "and the site is unchanged")

def gzipped():
    css, gz = fileof("/style.css"), fileof("/style.css.gz")
    r = get(PLAIN, "/style.css", extra="Accept-Encoding: gzip, deflate, br\r\n")
    check(r.status == 200 and r.body == gz and r.headers.get("content-encoding") == "gzip", "a client taking gzip gets name.gz")
    check(r.headers.get("content-type") == "text/css; charset=utf-8" and r.headers.get("vary") == "Accept-Encoding",
          "its type the file's, Vary: Accept-Encoding", repr((r.headers.get("content-type"), r.headers.get("vary"))))
    import gzip as gz_
    check(gz_.decompress(r.body) == css, "and it is the file")
    r = get(PLAIN, "/style.css")
    check(r.body == css and "content-encoding" not in r.headers and r.headers.get("vary") == "Accept-Encoding",
          "a client not taking it gets the file, Vary too")
    for h in ("gzip;q=0", "gzip; q=0.0", "identity", "deflate"):
        r = get(PLAIN, "/style.css", extra="Accept-Encoding: %s\r\n" % h)
        check(r.body == css and "content-encoding" not in r.headers, "Accept-Encoding: %s: the file" % h)
    for h in ("*", "gzip;q=0.5", "x-gzip"):
        r = get(PLAIN, "/style.css", extra="Accept-Encoding: %s\r\n" % h)
        check(r.body == gz, "Accept-Encoding: %s: name.gz" % h)
    r = get(PLAIN, "/style.css", extra="Accept-Encoding: gzip\r\nRange: bytes=0-9\r\n")
    check(r.status == 206 and r.body == gz[0:10] and r.headers.get("content-encoding") == "gzip", "a range of name.gz")
    r = get(PLAIN, "/style.css", extra="Accept-Encoding: gzip\r\n", method="HEAD")
    check(r.headers.get("content-length") == str(len(gz)), "HEAD: name.gz's length")
    r = get(PLAIN, "/style.css.gz", extra="Accept-Encoding: gzip\r\n")
    check(r.body == gz and "content-encoding" not in r.headers and r.headers.get("content-type") == "application/gzip",
          "name.gz asked for itself: as it is")
    check("vary" not in get(PLAIN, "/hello.txt", extra="Accept-Encoding: gzip\r\n").headers, "no copy: no Vary")

def caching():
    r = get(TLSP, "/style.css", True)
    check(r.headers.get("cache-control") == "max-age=600", "-C: Cache-Control on a file", r.headers.get("cache-control", ""))
    r = get(TLSP, "/index.html", True)
    check("cache-control" not in r.headers and "etag" in r.headers, "-C: none on a page (asked about each time)")
    check("cache-control" not in get(PLAIN, "/style.css").headers, "no -C: no Cache-Control")

def events():
    def open_stream(path, tls=False, port=PLAIN):
        s = connect(port, tls, timeout=30)
        s.sendall(("GET %s HTTP/1.1\r\nHost: a\r\nAccept: text/event-stream\r\n\r\n" % path).encode())
        rd = Reader(s)
        hdrs = {}
        st = rd.line()
        while True:
            l = rd.line()
            if not l:
                break
            k, v = l.decode().split(":", 1)
            hdrs[k.lower()] = v.strip()
        return s, rd, st, hdrs
    def chunk(rd):
        n = int(rd.line(), 16)
        d = rd.take(n)
        rd.line()
        return d
    s, rd, st, h = open_stream("/events/fast")
    check(st == b"HTTP/1.1 200 OK" and h.get("content-type") == "text/event-stream" and h.get("cache-control") == "no-store",
          "Accept: text/event-stream: an event stream", repr(h))
    t0 = time.time()
    evs = [chunk(rd) for i in range(3)]
    took = time.time() - t0
    check(evs == [b"data: line one\ndata: line two\n\n"] * 3, "each read an event, its lines data:", repr(evs[0]))
    check(2 < took < 6, "as the file gives them (a read a second)", "%.1fs" % took)
    s.close()	# gone mid-stream: its reader, waiting in a read, must be killed (the leak check at the end)
    s, rd, st, h = open_stream("/events/fast", tls=True, port=TLSP)
    check(chunk(rd).startswith(b"data: line one"), "an event stream over TLS")
    s.close()
    # silence: a comment every 15 s, then the event at 17 s, no deadline
    s, rd, st, h = open_stream("/events/slow")
    t0 = time.time()
    beat = chunk(rd)
    t1 = time.time() - t0
    ev = chunk(rd)
    t2 = time.time() - t0
    check(beat == b": keep-alive\n\n" and 13 < t1 < 17, "15 s of silence: a comment", "%r at %.1fs" % (beat, t1))
    check(ev == b"data: ping\n\n" and 15 < t2 < 20, "a file that waits 17 s: its event, not hung up", "%r at %.1fs" % (ev, t2))
    s.close()
    r = raw(PLAIN, b"HEAD /events/fast HTTP/1.1\r\nHost: a\r\nAccept: text/event-stream\r\nConnection: close\r\n\r\n", head=True)
    check(r.status == 200 and r.headers.get("content-type") == "text/event-stream", "HEAD of a stream: its headers")
    check(alive(), "still serving after the streams")

def suites():
    import re
    m = re.search(r"TLS suites, fastest first: (\w+)", open(EMULOG).read())
    names = {"1301": "TLS_AES_128_GCM_SHA256", "1302": "TLS_AES_256_GCM_SHA384", "1303": "TLS_CHACHA20_POLY1305_SHA256"}
    check(m is not None, "the TLS server timed its suites")
    if m:
        s = connect(TLSP, True)
        got = s.cipher()[0]
        s.close()
        # OpenSSL offers AES-256-GCM, ChaCha20, AES-128-GCM, in that order
        check(got == names.get(m.group(1)), "the suite fastest here chosen, whatever the client put first",
              "%s, fastest %s" % (got, m.group(1)))

def clock():
    def date(r):
        import email.utils
        return email.utils.parsedate_to_datetime(r.headers["date"]).timestamp()
    d = date(get(PLAIN, "/hello.txt"))
    check(abs(d - time.time()) < 5, "Date is the time", "%.0f s off" % (d - time.time()))
    step = os.path.join(os.path.dirname(SITE), "step")
    open(step + ".tmp", "w").write("%d" % int((time.time() + 3600) * 1e6))
    os.rename(step + ".tmp", step)
    for i in range(50):
        if os.path.exists(os.path.join(os.path.dirname(SITE), "stepped")):
            break
        time.sleep(0.2)
    time.sleep(0.5)
    d = date(get(PLAIN, "/hello.txt"))
    check(abs(d - (time.time() + 3600)) < 10, "the clock stepped an hour after start: Date follows it (timesync)",
          "%.0f s from an hour ahead" % (d - time.time() - 3600))
    check(abs(date(get(TLSP, "/hello.txt", True)) - (time.time() + 3600)) < 10, "in a TLS connection too")

for f in (files, gzipped, caching, events, suites, ranges, conditional, stream, connections, methods, posts, wiki, redirect,
          traversal, parsing, slow, flood, tlsattacks, fuzz, clock):
    try:
        f()
    except Exception as e:
        import traceback
        traceback.print_exc()
        check(False, f.__name__ + " raised", repr(e))
print("%d failed" % fails)
sys.exit(min(fails, 100))

#!/usr/bin/env python3
# A web server on 127.0.0.1 for fetch_tools_test.sh: pages that behave,
# and ones that do not answer, promise a body they never send, or ask
# to be paid.  usage: server.py LOGFILE  (prints its port)
import socket, sys, threading, time, urllib.parse

logf = open(sys.argv[1], "a", buffering=1)
def log(s):
    logf.write(s + "\n")

def answer(c, status, hdrs, body):
    h = "HTTP/1.1 %s\r\n" % status
    hdrs = dict(hdrs)
    hdrs.setdefault("Content-Length", str(len(body)))
    hdrs.setdefault("Connection", "close")
    for k, v in hdrs.items():
        h += "%s: %s\r\n" % (k, v)
    c.sendall(h.encode("latin1") + b"\r\n" + body)

def held(c, what, t0):
    # until the client goes: how long it took is the test
    c.settimeout(None)
    try:
        c.recv(1)
    except OSError:
        pass
    log("CLOSED %s %d" % (what, int((time.time() - t0) * 1000)))

def handle(c):
    try:
        data = b""
        c.settimeout(10)
        while b"\r\n\r\n" not in data:
            d = c.recv(65536)
            if not d:
                return
            data += d
        head, _, rest = data.partition(b"\r\n\r\n")
        lines = head.decode("latin1").split("\r\n")
        method, target = lines[0].split(" ")[0:2]
        hdrs = {}
        for l in lines[1:]:
            k, _, v = l.partition(":")
            hdrs[k.strip().lower()] = v.strip()
        n = int(hdrs.get("content-length", "0"))
        while len(rest) < n:
            d = c.recv(65536)
            if not d:
                break
            rest += d
        path = urllib.parse.urlparse(target).path
        log("REQ %s %s host=%s ua=%s" % (method, path, hdrs.get("host", ""), hdrs.get("user-agent", "")))
        t0 = time.time()
        if path == "/page":
            answer(c, "200 OK", {"Content-Type": "text/html"},
                b"<!doctype html><title>A page</title><h1>Heading</h1><p>the page's words</p>")
        elif path == "/redir":
            answer(c, "302 Found", {"Location": "/page"}, b"")
        elif path == "/errtext":
            answer(c, "200 OK", {"Content-Type": "text/plain"}, b"error: these are the page's words, not the tool's\n")
        elif path == "/big":
            answer(c, "200 OK", {"Content-Type": "text/plain"}, b"0123456789abcdef" * (600 * 1024 // 16))
        elif path == "/echo":
            answer(c, "200 OK", {"Content-Type": "text/plain"}, method.encode() + b" [" + rest + b"]")
        elif path == "/pay":
            answer(c, "402 Payment Required", {"Content-Type": "application/json"},
                b'{"x402Version":1,"accepts":[{"scheme":"exact","network":"base","maxAmountRequired":"1000",'
                b'"resource":"http://fetch.test/pay","payTo":"0x0000000000000000000000000000000000000001",'
                b'"asset":"0x0000000000000000000000000000000000000002","maxTimeoutSeconds":60}]}')
        elif path == "/hang":
            held(c, path, t0)
        elif path == "/clstall":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 67108864\r\n\r\n")
            held(c, path, t0)
        else:
            answer(c, "404 Not Found", {"Content-Type": "text/plain"}, b"nope")
    except Exception as e:
        log("ERR %r" % (e,))
    finally:
        try:
            c.close()
        except OSError:
            pass

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(64)
print(s.getsockname()[1], flush=True)
while True:
    c, a = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()

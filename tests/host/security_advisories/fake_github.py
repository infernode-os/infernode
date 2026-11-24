#!/usr/bin/env python3
"""A stand-in for GitHub's repository security advisories API.

    fake_github.py PORTFILE LOG [ISA-ID=GHSA-ID ...]

Listens on the loopback, writes its port to PORTFILE, and answers

    GET  /repos/O/R/security-advisories   the advisories it holds, two
                                          pages of them (a Link header)
    POST /repos/O/R/security-advisories   a new draft, kept, its id
                                          answered

Each ISA-ID=GHSA-ID argument is an advisory it holds from the start,
whose description names that ISA id.  Every request is logged to LOG as
one line: method, path, the bearer token, and for a POST the JSON body.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

portfile, logfile = sys.argv[1], sys.argv[2]
held = []
for arg in sys.argv[3:]:
    isa, ghsa = arg.split("=")
    held.append({"ghsa_id": ghsa, "state": "draft",
                 "description": "text\n\nInferNode advisory id: %s\n" % isa})
made = [0]
ALPHA = "23456789cfghjmpqrvwx"


def newid():
    made[0] += 1
    n = made[0]
    tail = ""
    for _ in range(4):
        tail = ALPHA[n % 20] + tail
        n //= 20
    return "GHSA-cfgh-jmpq-" + tail


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def log(self, body=None):
        with open(logfile, "a") as f:
            f.write("%s %s %s%s\n" % (
                self.command, self.path,
                self.headers.get("Authorization", "-"),
                (" " + json.dumps(body, sort_keys=True)) if body is not None else ""))

    def answer(self, code, obj, link=None):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if link:
            self.send_header("Link", link)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.log()
        if "/security-advisories" not in self.path:
            return self.answer(404, {"message": "Not Found"})
        host = "http://127.0.0.1:%d" % self.server.server_port
        base = self.path.split("?")[0]
        if "page=2" in self.path:
            return self.answer(200, held[1:])
        link = '<%s%s?per_page=100&page=2>; rel="next"' % (host, base)
        return self.answer(200, held[:1], link if len(held) > 1 else None)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n))
        self.log(body)
        for k in ("summary", "description", "vulnerabilities"):
            if not body.get(k):
                return self.answer(422, {"message": "missing " + k})
        adv = {"ghsa_id": newid(), "state": "draft",
               "description": body["description"]}
        held.append(adv)
        adv = dict(adv, html_url="https://example.invalid/" + adv["ghsa_id"])
        return self.answer(201, adv)


srv = HTTPServer(("127.0.0.1", 0), H)
with open(portfile, "w") as f:
    f.write(str(srv.server_port))
srv.serve_forever()

#!/usr/bin/env python3
"""
Scripted OpenAI-compatible model for tests/host/wiki9p_test.sh.

llmsrv runs with `-b openai -u http://127.0.0.1:<port>/v1` against this
server.  The reply is chosen by the last user message: the source an
ingest names, a question, or a lint.  Every request is appended to the log
as one JSON object per line.

Usage: mock_model.py LOGFILE   (prints the bound port, then serves)
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RAW = "/mnt/wikia/raw/"


def reply(text):
    if "(from " + RAW + "alpha.md)" in text:
        return ("===PAGE===\nTITLE: Project X\nTYPE: entity\nCOMMENT: from alpha\n---\n"
                "Project X is led by Alice. It started in 2024.\nSee [Alice].\n"
                "===PAGE===\nTITLE: Alice\nTYPE: entity\n---\n"
                "Alice leads [Project X].\n")
    if "(from " + RAW + "beta.md)" in text:
        return ("===PAGE===\nTITLE: Project X\nTYPE: entity\nCOMMENT: from beta\n---\n"
                "Project X is led by Bob since 2026, after Alice.\nSee [Alice], [Bob].\n"
                "===PAGE===\nTITLE: Bob\nTYPE: entity\n---\n"
                "Bob leads [Project X].\n")
    if "QUESTION:" in text:
        return "Bob leads Project X [Project X]."
    if "Audit this wiki" in text:
        return "CONTRADICTIONS: none\nORPHANS: none\n"
    return "unexpected prompt"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send(json.dumps({"data": [{"id": "mock"}]}).encode(), "application/json")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        users = [m.get("content") for m in body.get("messages", [])
                 if m.get("role") == "user" and isinstance(m.get("content"), str)]
        text = reply(users[-1] if users else "")
        with open(LOG, "a") as f:
            f.write(json.dumps({"messages": len(body.get("messages", [])),
                                "reply": text}) + "\n")
        usage = {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
        if body.get("stream"):
            events = [
                {"choices": [{"index": 0, "delta": {"role": "assistant", "content": text},
                              "finish_reason": None}]},
                {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                 "usage": usage},
            ]
            out = ("".join("data: " + json.dumps(e) + "\n\n" for e in events)
                   + "data: [DONE]\n\n").encode()
            self.send(out, "text/event-stream")
        else:
            out = json.dumps({"choices": [{"index": 0, "finish_reason": "stop",
                                           "message": {"role": "assistant", "content": text}}],
                              "usage": usage}).encode()
            self.send(out, "application/json")

    def send(self, out, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, format, *args):
        pass


def main():
    global LOG
    LOG = sys.argv[1]
    open(LOG, "w").close()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

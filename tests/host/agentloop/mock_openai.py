#!/usr/bin/env python3
"""
Scripted OpenAI-compatible backend for the agent-loop characterization test.

llmsrv runs with `-b openai -u http://127.0.0.1:<port>/v1` against this
server, so the real llmsrv and llmclient sit between the loop under test
and the script.  Each scenario is a list of model turns.  A request's
scenario is named by "SCENARIO:<name>" in its most recent such user
message; its turn is the number of assistant messages after that message.

Every request body is appended to the log (one JSON object per line) so
the test can compare what each loop sent back to the model.

Usage: mock_openai.py LOGFILE   (prints the bound port, then serves)
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIX = "/usr/agentloop"


def tool(name, args):
    return {"name": name, "args": args}


# A turn is either {"content": str} or {"tools": [tool(...)], "content"?: str}.
SCENARIOS = {
    "text_only": [
        {"content": "Hello from the mock."},
    ],
    "single_read": [
        {"tools": [tool("read", FIX + "/a.txt")]},
        {"content": "Read it."},
    ],
    "text_and_tool": [
        {"content": "Let me look.", "tools": [tool("read", FIX + "/a.txt")]},
        {"content": "Done looking."},
    ],
    "two_reads": [
        {"tools": [tool("read", FIX + "/a.txt"), tool("read", FIX + "/b.txt")]},
        {"content": "Read both."},
    ],
    "dup_read": [
        {"tools": [tool("read", FIX + "/a.txt")]},
        {"tools": [tool("read", FIX + "/a.txt")]},
        {"content": "Read twice."},
    ],
    "dup_in_batch": [
        {"tools": [tool("read", FIX + "/a.txt"), tool("read", FIX + "/a.txt")]},
        {"content": "Same file twice in one batch."},
    ],
    "big_output": [
        {"tools": [tool("read", FIX + "/big.txt")]},
        {"content": "Read the big one."},
    ],
    "unknown_tool": [
        {"tools": [tool("nosuchtool", "anything")]},
        {"content": "That tool does not exist."},
    ],
    "error_streak": [
        {"tools": [tool("read", FIX + "/missing1")]},
        {"tools": [tool("read", FIX + "/missing2")]},
        {"tools": [tool("read", FIX + "/missing3")]},
        {"tools": [tool("read", FIX + "/missing4")]},
        {"content": "Giving up."},
    ],
    "say": [
        {"tools": [tool("say", "spoken words")]},
        {"content": "Said it."},
    ],
    # A mutating call and a read of its result in one batch: the batch
    # must run in order, so the read sees the write.
    "write_then_read": [
        {"tools": [tool("write", FIX + "/c.txt gamma"), tool("read", FIX + "/c.txt")]},
        {"content": "Wrote and read."},
    ],
    # The agent probes for the harness's own mount: it must not exist in
    # the tool's namespace.
    # A read of something every agent namespace carries, for a stack
    # booted with its own grants (the full Lucifer boot).
    "read_system": [
        {"tools": [tool("read", "/lib/veltro/system.txt")]},
        {"content": "Read the system prompt."},
    ],
    "probe_mount": [
        {"tools": [tool("list", "/mnt/veltro")]},
        {"content": "Probed."},
    ],
    "approval_deny": [
        {"tools": [tool("write", "/dis/agentloop-probe.txt probe")]},
        {"content": "Write was handled."},
    ],
}

# Scenarios whose model never stops calling tools: every turn is the same.
LOOPING = {
    "step_cap": {"tools": [tool("list", FIX)]},
}

LOG = None


def scenario_of(body):
    msgs = body.get("messages", [])
    idx, name = None, None
    for i, m in enumerate(msgs):
        if m.get("role") != "user":
            continue
        c = m.get("content")
        if isinstance(c, list):
            c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
        mt = re.search(r"SCENARIO:([a-z_]+)", c or "")
        if mt:
            idx, name = i, mt.group(1)
    if name is None:
        return None, 0
    turn = sum(1 for m in msgs[idx + 1:] if m.get("role") == "assistant")
    return name, turn


def reply_for(name, turn):
    if name in LOOPING:
        return LOOPING[name]
    script = SCENARIOS.get(name)
    if script is None:
        return {"content": "unknown scenario " + name}
    if turn >= len(script):
        return {"content": "(script exhausted)"}
    return script[turn]


def calls_of(name, turn, r):
    out = []
    for i, t in enumerate(r.get("tools", [])):
        out.append({
            "id": "call_%s_%d_%d" % (name, turn, i),
            "type": "function",
            "function": {"name": t["name"],
                         "arguments": json.dumps({"args": t["args"]})},
        })
    return out


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"data": [{"id": "mock"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        name, turn = scenario_of(body)
        with open(LOG, "a") as f:
            f.write(json.dumps({"scenario": name, "turn": turn, "body": body}) + "\n")
        r = reply_for(name, turn) if name else {"content": "no scenario"}
        calls = calls_of(name, turn, r) if name else []
        finish = "tool_calls" if calls else "stop"
        text = r.get("content", "")
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        if body.get("stream"):
            delta = {"role": "assistant"}
            if text:
                delta["content"] = text
            if calls:
                delta["tool_calls"] = [dict(c, index=i) for i, c in enumerate(calls)]
            events = [
                {"choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
                {"choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
                 "usage": usage},
            ]
            out = ("".join("data: " + json.dumps(e) + "\n\n" for e in events)
                   + "data: [DONE]\n\n").encode()
            ctype = "text/event-stream"
        else:
            msg = {"role": "assistant", "content": text or None}
            if calls:
                msg["tool_calls"] = calls
            out = json.dumps({"choices": [{"index": 0, "message": msg,
                                           "finish_reason": finish}],
                              "usage": usage}).encode()
            ctype = "application/json"
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

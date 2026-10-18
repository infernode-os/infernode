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

# What raw_write writes, and the test expects back byte for byte.
RAWTEXT = '\n"quoted" first line\n\tsys->print("%d\\n", i);\n'


def tool(name, args):
    """args: a string (sent as {"args": ...}) or a dict (sent as is)."""
    return {"name": name, "args": args}


# A turn is either {"content": str} or {"tools": [tool(...)], "content"?: str}.
SCENARIOS = {
    "text_only": [
        {"content": "Hello from the mock."},
    ],
    # A reply in markdown, as models write them (xenith_agent_test).
    "markdown_reply": [
        {"content": "## Findings\n\nThe file holds **one** word:\n\n"
                    "- `alpha`, in *a.txt*\n- nothing else\n\n"
                    "```\ncat a.txt\n```\n\n"
                    "| file | words |\n|---|---|\n| a.txt | 1 |\n"},
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
    # Six reads of different files in one batch run concurrently; each
    # result must be its own file's, not another call's.
    "many_reads": [
        {"tools": [tool("read", FIX + "/f%d.txt" % i) for i in range(1, 7)]},
        {"content": "Read six."},
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
    # The same gated write in an unattended campaign: the driver answers
    # nothing, and the call is denied as no one is there to ask (INFR-442).
    "approval_headless": [
        {"tools": [tool("write", "/dis/agentloop-probe.txt probe")]},
        {"content": "Write was handled."},
    ],
    # The same, with the tool's own schema as a native model sends it.
    "approval_deny_json": [
        {"tools": [tool("write", {"path": "/dis/agentloop-probe.txt",
                                  "content": "probe"})]},
        {"content": "Write was handled."},
    ],
    # A read, a write to the same file and the read again, in one batch:
    # the second read must run, not be answered with the first's result.
    "read_write_read": [
        {"tools": [tool("read", FIX + "/a.txt"),
                   tool("write", FIX + "/a.txt omega"),
                   tool("read", FIX + "/a.txt")]},
        {"content": "Read, wrote, read."},
    ],
    # Activity 0 delegates (agent_delegation_test): a task whose brief names
    # the child's own scenario, so the child runs child_read.
    "delegate": [
        {"tools": [tool("task", {"command": "create",
                                 "args": "label=Child tools=read brief=SCENARIO:child_read go"})]},
        {"content": "Started Child."},
    ],
    # The task agent: a read with its own tools, then a report whose text
    # names the scenario activity 0 runs on the completion event.
    "child_read": [
        {"tools": [tool("read", "/lib/veltro/system.txt")]},
        {"content": "Child is done. SCENARIO:parent_report"},
    ],
    "compact_summary": [
        {"content": "Earlier: the user asked for files to be read; some were."},
    ],
    # A tool turned on after the agent started (/tools +find, Settings):
    # offered to the model, it must also be callable.
    "late_tool": [
        {"tools": [tool("find", {"args": "/lib/veltro system.txt"})]},
        {"content": "Found with a late tool."},
    ],
    # The limbo tool's own model: one program that compiles, one that does not.
    "limbo_ok": [
        {"content": "```limbo\nimplement Hello;\n\ninclude \"sys.m\";\n\tsys: Sys;\n"
                    "include \"draw.m\";\n\nHello: module\n{\n\tinit: fn(nil: ref Draw->Context, nil: list of string);\n};\n\n"
                    "init(nil: ref Draw->Context, nil: list of string)\n{\n\tsys = load Sys Sys->PATH;\n"
                    "\tsys->print(\"hello\\n\");\n}\n```\n"},
    ],
    "limbo_bad": [
        {"content": "```limbo\nimplement Bad;\n\ninclude \"sys.m\";\n\tsys: Sys;\n"
                    "include \"draw.m\";\n\nBad: module\n{\n\tinit: fn(nil: ref Draw->Context, nil: list of string);\n};\n\n"
                    "init(nil: ref Draw->Context, nil: list of string)\n{\n\tundeclared = 3;\n}\n```\n"},
    ],
    # Activity 0 asks for Limbo through the limbo tool, whose compile gate
    # must say whether the code compiles.
    "gate": [
        {"tools": [tool("limbo", "SCENARIO:limbo_ok go"), tool("limbo", "SCENARIO:limbo_bad go")]},
        {"content": "Gate checked."},
    ],
    # A native write's content is the file, as is: a leading blank line, a
    # leading quote, and a \\n inside a string literal all survive; an edit's
    # old and new likewise.
    "raw_write": [
        {"tools": [tool("write", {"path": "/tmp/veltro/scratch/raw.b",
                                  "content": RAWTEXT})]},
        {"tools": [tool("edit", {"path": "/tmp/veltro/scratch/raw.b",
                                 "old": 'print("%d\\n", i);', "new": 'print("%d\\t%d\\n", i, j);'})]},
        {"content": "Wrote it raw."},
    ],
    # Checking files with the limbo tool: one compiles, one does not.
    "compile_check": [
        {"tools": [tool("limbo", "compile /tmp/veltro/scratch/good.b"),
                   tool("limbo", "compile /tmp/veltro/scratch/bad.b")]},
        {"content": "Compiled the files."},
    ],
    # A task granted what every agent reads anyway: created, not refused.
    "grant_baseline": [
        {"tools": [tool("task", {"command": "create",
                                 "args": "label=Reader paths=/lib/veltro tools=read brief=SCENARIO:text_only go"})]},
        {"content": "Granted the baseline."},
    ],
    # A task edits a file in a folder the user granted: the change is
    # staged; activity 0, told so, promotes it on the user's word.
    "delegate_edit": [
        {"tools": [tool("task", {"command": "create",
                                 "args": "label=Editor tools=edit,read paths=/usr/deltest/notes brief=SCENARIO:child_edit go"})]},
        {"content": "Started the editor."},
    ],
    "child_edit": [
        {"tools": [tool("edit", {"path": "/usr/deltest/notes/todo.txt",
                                 "old": "- milk", "new": "- milk\n- bread"})]},
        {"content": "Edited the list. SCENARIO:parent_promote"},
    ],
    "parent_promote": [
        {"tools": [tool("task", {"command": "promote", "args": "2"})]},
        {"content": "Promoted the edit."},
    ],
    # A task that never stops working (its model calls a tool every turn),
    # closed while it works.
    "delegate_loop": [
        {"tools": [tool("task", {"command": "create",
                                 "args": "label=Looper tools=list brief=SCENARIO:step_cap go"})]},
        {"content": "Started the looper."},
    ],
    # Activity 0 on the completion event: its own tools still work.
    "parent_report": [
        {"tools": [tool("task", {"command": "status", "args": "1"})]},
        {"content": "Reported the child."},
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
                         "arguments": json.dumps(t["args"] if isinstance(t["args"], dict)
                                                else {"args": t["args"]})},
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
        msgs = body.get("messages", [])
        # llmsrv compacting a session: a summary, not a scenario's turn.
        if not body.get("tools") and msgs and str(msgs[-1].get("content", "")).startswith(
                "Summarize this conversation"):
            name, turn = "compact_summary", 0
        # As a real API does: a tool result must answer a tool call that
        # is in the history before it.
        called = set()
        for m in msgs:
            for c in m.get("tool_calls") or []:
                called.add(c.get("id"))
            if m.get("role") == "tool" and m.get("tool_call_id") not in called:
                msg = json.dumps({"error": {"message": "tool message %s answers no tool call"
                                            % m.get("tool_call_id")}}).encode()
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(msg)))
                self.end_headers()
                self.wfile.write(msg)
                return
        if name == "backend_down":
            # The model service failing (as an unreachable or overloaded one
            # does): the user must be told so, not shown the error as a reply.
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
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

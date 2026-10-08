#!/usr/bin/env python3
"""
Turn the mock backend's request log and the emulator's output into one
golden text per (front end, scenario).

    normalize.py FRONTEND REQLOG EMULOG OUTDIR

For each request: the tools offered, then every message after the
scenario's user message.  The system prompt and the scenario message
itself are left out: they carry the live namespace and change whenever
a tool or a prompt does, which is not what this test pins.  Session
ids, scratch file names and byte counts of scratch files are replaced
with fixed tokens.
"""
import json
import os
import re
import sys

SUBS = [
    (re.compile(r"/tmp/veltro/scratch/[^\s\"')]+"), "<scratch>"),
    (re.compile(r"/tmp/activity/\d+/scratch/[^\s\"')]+"), "<scratch>"),
    (re.compile(r"native-[0-9a-f]+-[0-9]+"), "native-<id>"),
    (re.compile(r"\b[0-9a-f]{32}\b"), "<llm>"),
]


def norm(s):
    if s is None:
        return ""
    if isinstance(s, list):
        s = " ".join(p.get("text", "") for p in s if isinstance(p, dict))
    for rx, rep in SUBS:
        s = rx.sub(rep, s)
    return s


def msgline(m):
    role = m.get("role")
    out = []
    if role == "assistant":
        c = norm(m.get("content"))
        if c:
            out.append("assistant: " + c)
        for tc in m.get("tool_calls") or []:
            fn = tc.get("function", {})
            out.append("assistant-call %s %s %s" % (tc.get("id"), fn.get("name"),
                                                   fn.get("arguments")))
    elif role == "tool":
        out.append("tool-result %s:" % m.get("tool_call_id"))
        out.extend("  | " + l for l in norm(m.get("content")).split("\n"))
    else:
        out.append("%s: " % role)
        out.extend("  | " + l for l in norm(m.get("content")).split("\n"))
    return out


def scenario_msgs(msgs):
    start = 0
    for i, m in enumerate(msgs):
        c = m.get("content")
        if m.get("role") == "user" and "SCENARIO:" in norm(c):
            start = i
    return msgs[start + 1:]


def main():
    frontend, reqlog, emulog, outdir = sys.argv[1:5]
    per = {}
    for line in open(reqlog):
        d = json.loads(line)
        name = d.get("scenario") or "none"
        per.setdefault(name, []).append(d)

    # Emulator output, sliced per scenario by the driver's markers.
    outputs = {}
    cur = None
    for line in open(emulog, errors="replace"):
        line = line.rstrip("\n")
        mt = re.match(r"^--- BEGIN (\w+)$", line)
        if mt:
            cur = mt.group(1)
            outputs[cur] = []
            continue
        if re.match(r"^--- END (\w+)$", line):
            cur = None
            continue
        if cur:
            outputs[cur].append(norm(line))

    os.makedirs(outdir, exist_ok=True)
    for name in sorted(set(per) | set(outputs)):
        if name == "none":
            continue
        lines = ["# %s %s" % (frontend, name)]
        reqs = per.get(name, [])
        lines.append("requests %d" % len(reqs))
        # A looping scenario repeats one request shape: show the first
        # three and the last, which is enough to pin the cap.
        shown = list(enumerate(reqs))
        if len(shown) > 4:
            shown = shown[:3] + shown[-1:]
        for i, d in shown:
            b = d["body"]
            lines.append("")
            lines.append("== request %d (turn %d)" % (i, d["turn"]))
            tools = sorted(t["function"]["name"] for t in b.get("tools", []))
            lines.append("tools: " + " ".join(tools))
            msgs = scenario_msgs(b.get("messages", []))
            # Only what this request added since the previous one.
            if i > 0:
                prev = scenario_msgs(reqs[i - 1]["body"].get("messages", []))
                if msgs[:len(prev)] == prev:
                    msgs = msgs[len(prev):]
                else:
                    lines.append("(history rewritten)")
            for m in msgs:
                lines.extend(msgline(m))
        lines.append("")
        lines.append("== output")
        lines.extend("  | " + l for l in outputs.get(name, []))
        with open(os.path.join(outdir, "%s-%s.txt" % (frontend, name)), "w") as f:
            f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()

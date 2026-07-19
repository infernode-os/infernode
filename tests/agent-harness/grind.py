#!/usr/bin/env python3
# grind.py — host orchestrator for the InferNode agent grinding harness.
#
# For each scenario, stage it, boot a fresh headless emu running grind-driver
# against the live LLM backend (claude-gate by default, or any OpenAI-
# compatible URL), parse the driver's @@ state bundle, score it against the
# scenario's expects/forbid checks, and write a Markdown scorecard + JSONL.
#
# One scenario per emu boot = clean-room isolation (no state bleed between
# scenarios), at the cost of ~30-40s boot each. The backend is a parameter, so
# the same suite runs against the gate (sonnet/opus/haiku) or a local Ollama
# model (gpt-oss/mistral) to guard against shared-prompt regressions.
#
# Usage:
#   grind.py [--scenarios FILE] [--model sonnet] [--url URL]
#            [--only NAME[,NAME...]] [--timeout SECS] [--out DIR] [--keep]
#
# Stdlib + PyYAML only. No dependency on the offline tests/model-eval harness.

import argparse
import datetime
import json
import os
import re
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
DRIVER_INEMU = "/tests/agent-harness/grind-driver"
STAGE = Path(os.path.expanduser("~/.infernode/grind/current"))
DEFAULT_URL = "http://127.0.0.1:11435/v1"


def find_emu():
    for rel in ("emu/MacOSX/o.emu", "emu/Linux/o.emu"):
        p = REPO / rel
        if p.exists():
            return str(p)
    raise SystemExit("grind: no emu binary found under emu/{MacOSX,Linux}/")


def ensure_mountpoints():
    # git does not preserve empty directories, so a fresh checkout/worktree
    # lacks the Inferno mountpoint dirs (/n etc.). Without /n, `mount {mntgen}
    # /n` fails, trfs can't mount /n/local, and every staged read silently
    # returns empty (all scenario params default). Create them idempotently.
    for d in ("n", "mnt", "tmp"):
        (REPO / d).mkdir(exist_ok=True)


# ── staging ─────────────────────────────────────────────────────────

def stage_scenario(sc, model, url, rz):
    STAGE.mkdir(parents=True, exist_ok=True)
    (STAGE / "url").write_text(url + "\n")
    (STAGE / "model").write_text((sc.get("model") or model) + "\n")
    (STAGE / "rz").write_text(rz + "\n")
    (STAGE / "settle").write_text(str(sc.get("settle", 4)) + "\n")
    # prompt is optional: message-arrival scenarios (msg: watch) are driven by
    # the incoming message, not a user prompt.
    (STAGE / "prompt").write_text(sc.get("prompt", "") or "")
    # msg: none | inbox | watch — enable the /mnt/msg mock inbox / msgwatch.
    (STAGE / "msg").write_text((sc.get("msg", "none") or "none") + "\n")
    # matrix: <composition-name> pre-starts the matrix runtime headless.
    (STAGE / "matrixcomp").write_text((sc.get("matrix", "none") or "none") + "\n")
    probes = []
    for chk in (sc.get("expects", {}).get("probe_contains") or []):
        probes.append(chk["path"])
    (STAGE / "probefiles").write_text("\n".join(probes) + ("\n" if probes else ""))


# ── run one scenario in a fresh emu ─────────────────────────────────

def run_emu(emu, timeout):
    # emu does not self-exit after the driver finishes: llmsrv/lucibridge/
    # tools9p run as background procs and keep the VM alive. So we stream the
    # driver's output and terminate emu the instant it prints @@GRIND done
    # (or on timeout). Start a new process group so we can kill the whole tree.
    cmd = [emu, "-c1", "-pheap=1024m", "-pmain=1024m", "-pimage=1024m",
           f"-r{REPO}", "sh", "-c", f"run {DRIVER_INEMU}"]
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, cwd=str(REPO), stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, bufsize=1, text=True,
                         start_new_session=True)
    lines, done, killed = [], False, False
    # Completion signals: emu block-buffers stdout to the pipe, so the tiny
    # trailing "@@GRIND done" can sit unflushed. "@@TRAJLOG end" is the last dump
    # marker and is reliably flushed by the large trajectory cat preceding it —
    # treat either as "the dump is complete, stop and reap emu."
    END_MARKERS = ("@@GRIND done", "@@TRAJLOG end")
    try:
        while True:
            left = timeout - (time.monotonic() - t0)
            if left <= 0:
                killed = True
                break
            r, _, _ = select.select([p.stdout], [], [], min(left, 3.0))
            if not r:
                if p.poll() is not None:
                    break
                continue
            line = p.stdout.readline()
            if line == "":
                break
            lines.append(line)
            if line.strip() in END_MARKERS:
                done = True
                break
    finally:
        if p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGTERM)
                p.wait(timeout=5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                p.wait()
    rc = p.returncode if p.returncode is not None else -1
    return "".join(lines), rc, done, (killed and not done), time.monotonic() - t0


# ── parse the @@ state bundle ───────────────────────────────────────

ACT_RE = re.compile(r"@@ACT id=(\S+) status=\[(.*?)\] urgency=\[(.*?)\] label=\[(.*?)\]")
PRES_RE = re.compile(r"@@PRES a=(\S+) path=(\S+) type=\[(.*?)\] label=\[(.*?)\]")
MSG_RE = re.compile(r"@@MSG a=(\S+) i=(\S+)")


def parse_state(out):
    st = {"lifecycle": {}, "activities": [], "messages": [], "presentation": [],
          "probes": {}, "matrix": None, "msg_pending": None, "sent": [],
          "trajlog": "", "raw_lines": out.count("\n")}
    lines = out.splitlines()
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("@@GRIND "):
            parts = ln.split(None, 2)
            if len(parts) >= 2:
                st["lifecycle"][parts[1]] = parts[2] if len(parts) > 2 else ""
        elif ln.startswith("@@ACT "):
            m = ACT_RE.match(ln)
            if m:
                st["activities"].append({"id": m.group(1), "status": m.group(2),
                                         "urgency": m.group(3), "label": m.group(4)})
        elif ln.startswith("@@PRES "):
            m = PRES_RE.match(ln)
            if m:
                st["presentation"].append({"a": m.group(1),
                                           "id": m.group(2).rstrip("/").split("/")[-1],
                                           "type": m.group(3), "label": m.group(4)})
        elif ln.startswith("@@MSG "):
            m = MSG_RE.match(ln)
            body = []
            i += 1
            while i < len(lines) and lines[i] != "@@ENDMSG":
                body.append(lines[i])
                i += 1
            raw = "\n".join(body).rstrip("\n")
            st["messages"].append({"a": m.group(1) if m else "?",
                                   "i": m.group(2) if m else "?",
                                   **parse_msg(raw)})
        elif ln.startswith("@@PROBE "):
            parts = ln.split()
            path = parts[1]
            present = (len(parts) > 2 and parts[2] == "exists")
            body = []
            i += 1
            while i < len(lines) and lines[i] != "@@ENDPROBE":
                body.append(lines[i])
                i += 1
            st["probes"][path] = "\n".join(body).rstrip("\n") if present else None
        elif ln == "@@MATRIX begin":
            body = []
            i += 1
            while i < len(lines) and lines[i] != "@@MATRIX end":
                body.append(lines[i])
                i += 1
            st["matrix"] = "\n".join(body).rstrip("\n")
        elif ln == "@@MSGPENDING begin":
            body = []
            i += 1
            while i < len(lines) and lines[i] != "@@MSGPENDING end":
                body.append(lines[i])
                i += 1
            st["msg_pending"] = "\n".join(body).strip()
        elif ln == "@@SENT begin":
            body = []
            i += 1
            while i < len(lines) and lines[i] != "@@SENT end":
                if lines[i].strip():
                    body.append(lines[i].strip())
                i += 1
            st["sent"] = body
        elif ln == "@@TRAJLOG begin":
            body = []
            i += 1
            while i < len(lines) and lines[i] != "@@TRAJLOG end":
                body.append(lines[i])
                i += 1
            st["trajlog"] = "\n".join(body)
        i += 1
    st["tools"] = parse_trajectory_tools(st["trajlog"])
    return st


def parse_msg(raw):
    """A conversation message file is 'role=<r> text=<...>' possibly with more
    key=val fields before text=. text= runs to the end of the block."""
    role = ""
    mrole = re.search(r"role=(\S+)", raw)
    if mrole:
        role = mrole.group(1)
    text = raw
    idx = raw.find("text=")
    if idx >= 0:
        text = raw[idx + len("text="):]
    return {"role": role, "text": text.strip()}


# Each real model tool call appears in lucibridge -v output as the llmsrv wire
# form TOOL:<id>:<name>:<args>, with a unique tool_use id. Count those (dedup by
# id) for an accurate per-call trajectory; ignore the lucibridge "tool <name>:
# calling/done" execution echoes, which fire twice per call.
TOOL_CALL_RE = re.compile(r"\bTOOL:(\S+?):([a-z_]+):")


def parse_trajectory_tools(log):
    seen, tools = set(), []
    for ln in log.splitlines():
        m = TOOL_CALL_RE.search(ln)
        if m and m.group(1) not in seen:
            seen.add(m.group(1))
            tools.append(m.group(2))
    return tools


# ── scoring ─────────────────────────────────────────────────────────

def final_reply(st):
    for msg in reversed(st["messages"]):
        if msg["a"] == "0" and msg["role"] in ("veltro", "assistant"):
            return msg["text"]
    return ""


def as_list(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def score(sc, st, completed, killed):
    reasons = []
    reply = final_reply(st)
    exp = sc.get("expects", {}) or {}
    forbid = sc.get("forbid", {}) or {}

    if st["lifecycle"].get("ready", "").strip() != "yes":
        reasons.append("stack never reached readiness")
    if not completed:
        reasons.append("driver did not finish (no completion marker)" +
                       (" [emu killed at timeout]" if killed else ""))

    for want in as_list(exp.get("reply_contains")):
        if want.lower() not in reply.lower():
            reasons.append(f"reply missing {want!r}")
    if exp.get("reply_regex") and not re.search(exp["reply_regex"], reply):
        reasons.append(f"reply !~ /{exp['reply_regex']}/")
    if exp.get("reply_is") and reply.strip() != exp["reply_is"].strip():
        reasons.append(f"reply != {exp['reply_is']!r} (got {reply[:60]!r})")

    labels = [a["label"] for a in st["activities"]]
    for want in as_list(exp.get("activity_spawned")):
        if not any(want.lower() in lb.lower() for lb in labels):
            reasons.append(f"no activity spawned with label ~ {want!r}")
    child = [a for a in st["activities"] if a["id"] != "0"]
    if exp.get("activities_min") is not None and len(child) < exp["activities_min"]:
        reasons.append(f"child activities {len(child)} < {exp['activities_min']}")
    if exp.get("activities_max") is not None and len(child) > exp["activities_max"]:
        reasons.append(f"child activities {len(child)} > {exp['activities_max']}")
    if exp.get("no_duplicate_activities"):
        labs = [a["label"] for a in child]
        dupes = sorted({l for l in labs if labs.count(l) > 1})
        if dupes:
            reasons.append(f"duplicate task labels (INFR-390): {dupes}")

    for want in as_list(exp.get("trajectory_tool")):
        if want not in st["tools"]:
            reasons.append(f"tool {want!r} not used")
    for bad in as_list(forbid.get("trajectory_tool")):
        if bad in st["tools"]:
            reasons.append(f"forbidden tool {bad!r} was used")
    if forbid.get("reply_regex") and re.search(forbid["reply_regex"], reply):
        reasons.append(f"reply matched forbidden /{forbid['reply_regex']}/")

    for chk in as_list(exp.get("probe_contains")):
        content = st["probes"].get(chk["path"])
        if content is None:
            reasons.append(f"probe {chk['path']} missing")
        elif chk["text"] not in content:
            reasons.append(f"probe {chk['path']} lacks {chk['text']!r}")

    for want in as_list(exp.get("artifact_type")):
        if not any(a["type"] == want for a in st["presentation"]):
            reasons.append(f"no presentation artifact of type {want!r}")
    if exp.get("matrix_contains") and (st["matrix"] is None
                                       or exp["matrix_contains"] not in st["matrix"]):
        reasons.append(f"matrix composition lacks {exp['matrix_contains']!r}")

    # message-handling checks
    if exp.get("draft_pending") and not st["msg_pending"]:
        reasons.append("no draft reply queued in /mnt/msg/pending")
    # nothing_sent defaults on for any msg scenario: a non-empty /tmp/veltro/sent
    # means a reply was auto-sent without approval (a hard failure).
    if exp.get("nothing_sent", sc.get("msg", "none") != "none") and st["sent"]:
        reasons.append(f"reply auto-sent without approval: {st['sent']}")

    return (len(reasons) == 0), reasons, reply


# ── reporting ───────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenarios", default=str(Path(__file__).parent / "scenarios" / "core.yaml"))
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--rz", default="low")
    ap.add_argument("--only", default="", help="comma-separated scenario names")
    ap.add_argument("--timeout", type=int, default=300)
    # Durable grindhouse archive by default: every session (scorecard + JSONL +
    # per-scenario raw trajectory) is recorded for later evaluation.
    ap.add_argument("--out", default=os.path.expanduser("~/.infernode/grindhouse"))
    ap.add_argument("--no-record", action="store_true",
                    help="skip writing per-scenario raw trajectory logs")
    args = ap.parse_args()

    emu = find_emu()
    ensure_mountpoints()
    data = yaml.safe_load(Path(args.scenarios).read_text())
    scenarios = data.get("scenarios", data if isinstance(data, list) else [])
    if args.only:
        want = set(args.only.split(","))
        scenarios = [s for s in scenarios if s["name"] in want]
    if not scenarios:
        raise SystemExit("grind: no scenarios selected")

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    outdir = Path(args.out) / f"{stamp}-{args.model}"
    outdir.mkdir(parents=True, exist_ok=True)
    jsonl = open(outdir / "results.jsonl", "w", buffering=1)
    manifest = {"stamp": stamp, "model": args.model, "url": args.url,
                "scenarios_file": args.scenarios, "count": len(scenarios)}
    (outdir / "manifest.json").write_text(json.dumps(manifest, indent=2))

    results = []
    print(f"grind: {len(scenarios)} scenario(s), model={args.model}, url={args.url}")
    print(f"grind: recording -> {outdir}\n")
    for n, sc in enumerate(scenarios, 1):
        name = sc["name"]
        print(f"[{n}/{len(scenarios)}] {name} ... ", end="", flush=True)
        stage_scenario(sc, args.model, args.url, args.rz)
        # Retry emu crash-flakes: a run that exits on its own before finishing
        # (not our timeout) is the known nondeterministic emu segfault, not a
        # real result. `killed` means WE hit the timeout (a genuine hang) — don't
        # retry those. Up to 3 attempts.
        for attempt in range(1, 4):
            out, rc, completed, killed, dur = run_emu(emu, sc.get("timeout", args.timeout))
            st = parse_state(out)
            crashed = (not completed) and (not killed)
            if not crashed or attempt == 3:
                break
            print(f"[emu crash-flake, retry {attempt}] ", end="", flush=True)
        if not args.no_record:
            (outdir / f"{name}.trajectory.log").write_text(out)  # full session record
        ok, reasons, reply = score(sc, st, completed, killed)
        rec = {"name": name, "category": sc.get("category", ""), "model": args.model,
               "pass": ok, "reasons": reasons, "reply": reply[:400],
               "activities": st["activities"], "tools": st["tools"],
               "msg_pending": st["msg_pending"], "sent": st["sent"],
               "matrix": st["matrix"], "lifecycle": st["lifecycle"],
               "duration_s": round(dur, 1), "emu_rc": rc, "killed": killed}
        results.append(rec)
        jsonl.write(json.dumps(rec) + "\n")
        print(("PASS" if ok else "FAIL") + f"  ({dur:.0f}s)" +
              ("" if ok else "  :: " + "; ".join(reasons)))
    jsonl.close()

    npass = sum(1 for r in results if r["pass"])
    write_scorecard(outdir, args, results, npass)
    print(f"\ngrind: {npass}/{len(results)} passed -> {outdir/'scorecard.md'}")
    sys.exit(0 if npass == len(results) else 1)


def write_scorecard(outdir, args, results, npass):
    lines = [f"# Grind scorecard — {args.model}", "",
             f"- backend url: `{args.url}`",
             f"- scenarios: {len(results)}  passed: **{npass}**  failed: **{len(results)-npass}**",
             "", "| scenario | category | result | tools | dur | notes |",
             "|---|---|---|---|---|---|"]
    for r in results:
        notes = "" if r["pass"] else "; ".join(r["reasons"])
        tools = ",".join(dict.fromkeys(r["tools"]))  # distinct, in call order
        lines.append(f"| {r['name']} | {r['category']} | "
                     f"{'✅' if r['pass'] else '❌'} | {tools} | "
                     f"{r['duration_s']:.0f}s | {notes} |")
    (outdir / "scorecard.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()

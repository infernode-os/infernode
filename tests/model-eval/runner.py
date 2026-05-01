#!/usr/bin/env python3
"""
Model evaluation runner for the InferNode/Veltro harness.

Drives scenarios from scenarios.yaml against a list of models served by
an OpenAI-compatible endpoint (default: Ollama on the Jetson at
http://localhost:11434). Records per-scenario / per-model outcomes and
emits a Markdown report.

Usage:
  python runner.py --models mistral-small3.2:24b qwen2.5:32b \\
                   --scenarios scenarios.yaml \\
                   --runs 5 \\
                   --temperature 0.0 \\
                   --tools-dir /path/to/lib/veltro/tools \\
                   --output report.md

This is a *thin* runner — it does not aim to perfectly replicate
production lucibridge; it isolates the model + tool-description
behavior so improvements can be measured without rebuilding emu.
"""

from __future__ import annotations
import argparse
import json
import os
import re
import sys
import time
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("error: pyyaml is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)


SCHEMA = {"type": "object",
          "properties": {"args": {"type": "string"}},
          "required": ["args"]}

DEFAULT_PEERS = [
    ("read", "read - Read file contents"),
    ("write", "write - Write file contents"),
    ("say", "say - Speak text aloud"),
    ("memory", "memory - Persistent key-value storage"),
    ("webfetch", "webfetch - Fetch and read web pages"),
    ("plan", "plan - Structured planning"),
    ("todo", "todo - Task tracking"),
    ("git", "git - Git access"),
    ("grep", "grep - Search file contents"),
    ("find", "find - Find files by glob"),
    ("list", "list - List directory"),
    ("exec", "exec - Run command in Inferno sh"),
    ("spawn", "spawn - Parallel subagent"),
    ("json", "json - Query JSON data"),
    ("diff", "diff - Compare two files"),
    ("edit", "edit - Edit file contents"),
    ("websearch", "websearch - Web search"),
    ("mail", "mail - IMAP email"),
    ("hear", "hear - Speech-to-text"),
    ("man", "man - Manual page viewer"),
    ("task", "task - Delegated AI task"),
    ("gap", "gap - Knowledge gap tracking"),
]

DIRECTED_TOOLS = ["present", "launch", "shell", "editor", "charon",
                  "fractal", "gpu", "wallet", "xenith"]


def summarize_doc(path: Path) -> str:
    """Mirror agentlib.b's tooldocsummary: first paragraph, skipping `== … ==` headers."""
    if not path.exists():
        return ""
    doc = path.read_text()
    out, in_para = "", False
    for line in doc.split("\n"):
        s = line.strip()
        if not s:
            if in_para:
                break
            continue
        if (not in_para and len(s) >= 4
                and s.startswith("==") and s.endswith("==")):
            continue
        out = (out + " " + s) if out else s
        in_para = True
    return out


def build_tools(tools_dir: Path) -> list[dict]:
    """Construct the JSON tool-definition array sent to the LLM."""
    out = []
    for name in DIRECTED_TOOLS:
        out.append({
            "type": "function",
            "function": {
                "name": name,
                "description": summarize_doc(tools_dir / f"{name}.txt"),
                "parameters": SCHEMA,
            },
        })
    seen = set(DIRECTED_TOOLS)
    for n, d in DEFAULT_PEERS:
        if n in seen:
            continue
        seen.add(n)
        out.append({
            "type": "function",
            "function": {"name": n, "description": d, "parameters": SCHEMA},
        })
    return out


SYSTEM_PROMPT = (
    "You are Veltro, an AI agent inside InferNode. Use tools to act, "
    "do not just describe what you would do. When the user asks for a demo, "
    "pick a sensible default and execute it without asking for clarification."
)


def fake_tool_result(name: str, args: str) -> str:
    """Synthetic tool result. We use a neutral 'ok' for most paths;
    success-shaped for actions, and error-shaped where simulated_failure
    is requested."""
    try:
        inner = json.loads(args).get("args", "")
    except Exception:
        inner = args
    if name == "present":
        if inner.startswith("create"):
            return "created artifact"
        if inner.startswith("write"):
            return "wrote content to artifact"
        return "ok"
    if name == "launch":
        return f"launched {inner.split()[0] if inner else ''} app"
    if name == "editor":
        if inner.startswith("read"):
            target = inner.split()[1] if len(inner.split()) > 1 else "body"
            if target in ("body", "addr"):
                return "Hello world\n"
            return f"error: read target must be 'body' or 'addr'; got {target!r}"
        return "ok"
    return "ok"


def call(url: str, model: str, messages: list[dict], tools: list[dict],
         temperature: float, timeout: int = 180) -> dict:
    payload = {
        "model": model,
        "messages": messages,
        "tools": tools,
        "tool_choice": "auto",
        "temperature": temperature,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["choices"][0]


def run_loop(url: str, model: str, scenario: dict,
             tools: list[dict], temperature: float,
             max_turns: int = 4) -> dict:
    """Execute one scenario over an agent loop. Returns a record with
    every tool call attempted and any final text content."""
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    all_calls = []
    all_content = []
    final_finish = ""

    # Setup turns establish prior context (tool calls + fake results).
    # turn_kind: "simulated_failure" overrides the synthetic tool result
    # with an error string, so error-recovery scenarios can be tested.
    for t in scenario.get("setup_turns", []):
        if isinstance(t, str):
            user_msg, force_failure = t, False
        elif isinstance(t, dict):
            user_msg = t.get("prompt", "")
            force_failure = t.get("turn_kind") == "simulated_failure"
        else:
            continue
        messages.append({"role": "user", "content": user_msg})
        for _ in range(max_turns):
            try:
                choice = call(url, model, messages, tools, temperature)
            except Exception as e:
                return {"error": str(e), "calls": all_calls,
                        "content": "\n".join(all_content), "finish": "error"}
            msg = choice["message"]
            tcs = msg.get("tool_calls") or []
            if not tcs:
                break
            messages.append({"role": "assistant",
                             "content": msg.get("content", "") or "",
                             "tool_calls": tcs})
            for tc in tcs:
                if force_failure:
                    res = "error: simulated failure for testing — try a different argument shape"
                else:
                    res = fake_tool_result(
                        tc["function"]["name"], tc["function"]["arguments"])
                messages.append({"role": "tool", "tool_call_id": tc["id"],
                                 "content": res})

    # Real probe turn
    messages.append({"role": "user", "content": scenario["prompt"]})
    for _ in range(max_turns):
        try:
            choice = call(url, model, messages, tools, temperature)
        except Exception as e:
            return {"error": str(e), "calls": all_calls,
                    "content": "\n".join(all_content), "finish": "error"}
        msg = choice["message"]
        tcs = msg.get("tool_calls") or []
        content = msg.get("content", "") or ""
        if content:
            all_content.append(content)
        for tc in tcs:
            all_calls.append({
                "name": tc["function"]["name"],
                "args": tc["function"]["arguments"],
            })
        final_finish = choice.get("finish_reason", "")
        if not tcs:
            break
        messages.append({"role": "assistant", "content": content,
                         "tool_calls": tcs})
        for tc in tcs:
            messages.append({"role": "tool", "tool_call_id": tc["id"],
                             "content": fake_tool_result(
                                 tc["function"]["name"],
                                 tc["function"]["arguments"])})
    return {"calls": all_calls, "content": "\n".join(all_content),
            "finish": final_finish}


# -------- Grading --------

def _inner_args(args_field: str) -> str:
    try:
        return json.loads(args_field).get("args", "")
    except Exception:
        return args_field


def _check_one(call: dict, expects: dict) -> bool:
    if "tool" in expects and call["name"] != expects["tool"]:
        return False
    inner = _inner_args(call["args"])
    if "args_starts_with" in expects and not inner.startswith(expects["args_starts_with"]):
        return False
    if "args_contains" in expects and expects["args_contains"] not in inner:
        return False
    if "args_contains_all" in expects:
        if not all(s in inner for s in expects["args_contains_all"]):
            return False
    if "args_excludes" in expects:
        if any(s in inner for s in expects["args_excludes"]):
            return False
    if "args_in_set" in expects and inner.strip() not in expects["args_in_set"]:
        return False
    return True


def grade(scenario: dict, run: dict) -> tuple[str, str]:
    """Return (status, label). status is PASS/FAIL/ERR/<custom-class>."""
    if "error" in run:
        return ("ERR", run["error"][:60])

    expects = scenario.get("expects")
    pass_ = True
    if expects:
        if "multi_call" in expects:
            wanted = expects["multi_call"]
            calls = run["calls"]
            # Order-respecting: wanted[i] must be matched by some call at index >= i
            pos = 0
            for w in wanted:
                while pos < len(calls) and not _check_one(calls[pos], w):
                    pos += 1
                if pos >= len(calls):
                    pass_ = False
                    break
                pos += 1
        else:
            # Single-shape: any call must match
            pass_ = any(_check_one(c, expects) for c in run["calls"])

    if pass_:
        return ("PASS", "")

    # Try classify_other
    classifiers = scenario.get("classify_other", {}) or {}
    for label, spec in classifiers.items():
        if _matches_classifier(run, spec):
            return (label, "")

    return ("FAIL", f"calls={[c['name'] for c in run['calls']]}")


def _matches_classifier(run: dict, spec: dict) -> bool:
    if not isinstance(spec, dict):
        return False
    content = run.get("content", "") or ""
    if "content_contains" in spec and spec["content_contains"] not in content:
        return False
    if "content_contains_any" in spec:
        if not any(s in content for s in spec["content_contains_any"]):
            return False
    if "content_matches_regex" in spec:
        if not re.search(spec["content_matches_regex"], content, re.IGNORECASE):
            return False
    if "tool" in spec and not any(c["name"] == spec["tool"] for c in run["calls"]):
        return False
    if "tool_args_contains" in spec:
        wanted = spec["tool_args_contains"]
        if isinstance(wanted, str):
            wanted = [wanted]
        if not any(any(w in _inner_args(c["args"]) for w in wanted) for c in run["calls"]):
            return False
    if "tool_args_matches_regex" in spec:
        rx = re.compile(spec["tool_args_matches_regex"])
        if not any(rx.search(_inner_args(c["args"])) for c in run["calls"]):
            return False
    if "tool_args_starts_with_none_of" in spec:
        prefixes = spec["tool_args_starts_with_none_of"]
        for c in run["calls"]:
            inner = _inner_args(c["args"])
            if not any(inner.startswith(p) for p in prefixes):
                return True
        return False
    return True


# -------- Reporting --------

def render_report(rows: list[tuple], models: list[str], scenarios: list[dict]) -> str:
    """Build a markdown report. rows: (model, scenario_name, run_idx, status)."""
    out = []
    out.append("# Model Evaluation Report\n")
    out.append(f"_Generated {time.strftime('%Y-%m-%d %H:%M:%S')}_\n")

    # Per-model scorecard
    out.append("\n## Per-model summary\n")
    out.append("| Model | PASS | FAIL | OTHER (classified) | ERR |")
    out.append("|---|---|---|---|---|")
    for m in models:
        ms = [r for r in rows if r[0] == m]
        c = Counter(r[3] for r in ms)
        passes = c.get("PASS", 0)
        fails = c.get("FAIL", 0)
        errs = c.get("ERR", 0)
        other = sum(v for k, v in c.items() if k not in ("PASS", "FAIL", "ERR"))
        total = sum(c.values())
        out.append(f"| `{m}` | {passes}/{total} | {fails} | {other} | {errs} |")

    # Scenario × model matrix
    out.append("\n## Pass rate by scenario × model\n")
    header = "| Scenario | " + " | ".join(f"`{m}`" for m in models) + " |"
    sep = "|" + "|".join(["---"] * (len(models) + 1)) + "|"
    out.append(header)
    out.append(sep)
    by = defaultdict(lambda: defaultdict(list))
    for m, sc, _, status in rows:
        by[sc][m].append(status)
    for s in scenarios:
        n = s["name"]
        cells = []
        for m in models:
            statuses = by[n][m]
            if not statuses:
                cells.append("—")
                continue
            p = sum(1 for x in statuses if x == "PASS")
            cells.append(f"{p}/{len(statuses)}")
        out.append(f"| `{n}` | " + " | ".join(cells) + " |")

    # Per-scenario non-PASS classification (the row reads "what failure
    # mode is most common across models for this scenario?")
    out.append("\n## Failure-mode breakdown by scenario\n")
    out.append("Reading by row: scenarios where many models share the same failure")
    out.append("mode point at *harness* issues (tool description, error message,")
    out.append("protocol). Scenarios with widely varying failure modes across")
    out.append("models point at *model-fit* issues.\n")
    for s in scenarios:
        n = s["name"]
        rows_for_n = [(m, status) for (m, sc, _, status) in rows if sc == n and status != "PASS"]
        if not rows_for_n:
            continue
        out.append(f"\n### `{n}`")
        out.append(f"_{s.get('description', '')}_\n")
        c = Counter(status for _, status in rows_for_n)
        for status, count in c.most_common():
            models_hit = sorted(set(m for m, s2 in rows_for_n if s2 == status))
            out.append(f"- **{status}** × {count} ({', '.join(models_hit)})")

    return "\n".join(out) + "\n"


# -------- Main --------

def _safe_print(msg: str) -> None:
    """Print to stdout, surviving BrokenPipeError if stdout is gone (SSH dropped)."""
    try:
        print(msg, flush=True)
    except (BrokenPipeError, OSError):
        # Detach stdout so future prints don't keep raising
        sys.stdout = open(os.devnull, "w")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:11434/v1/chat/completions")
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--scenarios", default=str(Path(__file__).parent / "scenarios.yaml"))
    ap.add_argument("--tools-dir", default=str(Path(__file__).parent.parent.parent / "lib" / "veltro" / "tools"))
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--temperature", type=float, default=0.0)
    ap.add_argument("--output", default="-")
    ap.add_argument("--results-jsonl", default=None,
                    help="Append per-run results here as JSON lines so a crash leaves partial data behind")
    args = ap.parse_args()

    scenarios_data = yaml.safe_load(Path(args.scenarios).read_text())
    scenarios = scenarios_data["scenarios"]
    tools = build_tools(Path(args.tools_dir))

    # Default JSONL path next to the report so nothing is ever lost
    jsonl_path = args.results_jsonl
    if jsonl_path is None and args.output != "-":
        jsonl_path = str(Path(args.output).with_suffix(".jsonl"))

    rows = []  # (model, scenario_name, run_idx, status)
    jsonl_fp = open(jsonl_path, "a", buffering=1) if jsonl_path else None  # line-buffered
    try:
        for m in args.models:
            for s in scenarios:
                for run_idx in range(args.runs):
                    run = run_loop(args.url, m, s, tools, args.temperature)
                    status, label = grade(s, run)
                    rows.append((m, s["name"], run_idx, status))

                    # Append to JSONL immediately so partial results survive a crash
                    if jsonl_fp:
                        rec = {
                            "model": m,
                            "scenario": s["name"],
                            "run": run_idx,
                            "status": status,
                            "label": label,
                            "calls": run.get("calls", []),
                            "content_len": len(run.get("content", "")),
                        }
                        try:
                            jsonl_fp.write(json.dumps(rec) + "\n")
                        except Exception:
                            pass

                    msg = f"  {m:30s} {s['name']:32s} run {run_idx + 1:2d}/{args.runs}: {status}"
                    if label:
                        msg += f" — {label}"
                    _safe_print(msg)
    finally:
        if jsonl_fp:
            jsonl_fp.close()

    report = render_report(rows, args.models, scenarios)
    if args.output == "-":
        _safe_print("\n" + report)
    else:
        Path(args.output).write_text(report)
        try:
            print(f"\nreport written to {args.output}", file=sys.stderr)
        except (BrokenPipeError, OSError):
            pass


if __name__ == "__main__":
    main()

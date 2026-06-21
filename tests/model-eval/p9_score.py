#!/usr/bin/env python3
"""
9P-path harness test — scorer.

Reads the records emitted by the in-emu Limbo driver (p9drive.b), which
ran each scenario through InferNode llmsrv over 9P, and scores them by
reusing runner.py's grade()/render_report(). Identical scoring to the
HTTP runner; only the transport that produced the records differs.

  records.jsonl : one JSON object per line:
      {"model": str, "scenario": str, "run": int,
       "calls": [{"name": str, "args": str}], "content": str, "finish": str}

Usage: p9_score.py records.jsonl [out.md]
"""
import json, sys
from pathlib import Path
import runner

def main():
    recs_path = Path(sys.argv[1])
    out_path = sys.argv[2] if len(sys.argv) > 2 else "-"

    scen = {s["name"]: s for s in
            __import__("yaml").safe_load(
                (Path(runner.__file__).parent / "scenarios.yaml").read_text())["scenarios"]}
    scen_list = list(scen.values())

    rows = []          # (model, scenario, run_idx, status)
    models = []
    for line in recs_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        m = r["model"]
        if m not in models:
            models.append(m)
        sdef = scen.get(r["scenario"])
        if not sdef:
            continue
        run = {"calls": r.get("calls", []),
               "content": r.get("content", ""),
               "finish": r.get("finish", "")}
        if r.get("error"):
            run["error"] = r["error"]
        status, _label = runner.grade(sdef, run)
        rows.append((m, r["scenario"], r.get("run", 0), status))

    report = runner.render_report(rows, models, scen_list)
    if out_path == "-":
        sys.stdout.write(report)
    else:
        Path(out_path).write_text(report)
        print(f"wrote {out_path} ({len(rows)} runs, {len(models)} models)")

if __name__ == "__main__":
    main()

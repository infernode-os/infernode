#!/usr/bin/env python3
"""
9P-path harness test — input prep.

Emits the tool catalogue and a flattened scenario list for the in-emu
Limbo driver (p9drive.b) that runs each scenario through InferNode
llmsrv over 9P. Reuses runner.py so the tools, system prompt, and
scenario semantics stay identical to the HTTP runner — only the
transport changes (9P instead of OpenAI HTTP).

  tools.json     : [{name, description, input_schema}]  (llmsrv /tools format)
  scenarios.json : [{name, system, turns:[{prompt, fail}], probe}]
  system.txt     : SYSTEM_PROMPT
"""
import json, sys
from pathlib import Path
import runner  # sibling module — reuse its loaders/semantics

HERE = Path(__file__).parent
TOOLS_DIR = HERE.parent.parent / "lib" / "veltro" / "tools"

def main():
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE

    # Tools: convert runner.build_tools() (OpenAI shape) -> llmsrv flat shape.
    oa = runner.build_tools(TOOLS_DIR)
    tools = [{"name": t["function"]["name"],
              "description": t["function"]["description"],
              "input_schema": t["function"]["parameters"]} for t in oa]
    (out_dir / "tools.json").write_text(json.dumps(tools))

    # Scenarios: flatten setup_turns into a uniform turn list.
    scen = yaml_scenarios()
    flat = []
    for s in scen:
        turns = []
        for t in s.get("setup_turns", []) or []:
            if isinstance(t, str):
                turns.append({"prompt": t, "fail": 0})
            elif isinstance(t, dict):
                turns.append({"prompt": t.get("prompt", ""),
                              "fail": 1 if t.get("turn_kind") == "simulated_failure" else 0})
        flat.append({"name": s["name"], "turns": turns, "probe": s["prompt"]})
    (out_dir / "scenarios.json").write_text(json.dumps(flat))
    (out_dir / "system.txt").write_text(runner.SYSTEM_PROMPT)
    print(f"wrote {len(tools)} tools, {len(flat)} scenarios to {out_dir}")

def yaml_scenarios():
    import yaml
    return yaml.safe_load((HERE / "scenarios.yaml").read_text())["scenarios"]

if __name__ == "__main__":
    main()

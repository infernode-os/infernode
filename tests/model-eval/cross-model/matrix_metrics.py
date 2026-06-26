#!/usr/bin/env python3
"""matrix_metrics.py — aggregate the cross-model compatibility matrix.

Reads workspace/exp/matrix-logs/<model>__<task>__r<rep>.log (+ _timing) and
emits a per-run table plus per-model and per-task summaries, flagging
MODEL-FAMILY-SPECIFIC breakage (the point of the run). Objective signals only;
final answers are extracted for human eyeballing.

Usage: python3 matrix_metrics.py [logs_dir]
"""
import os, re, sys, glob, collections

LOGS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "matrix-logs")

# Per-task expectation: what "format_ok" means for each.
EXPECT = {
    "t0_trivia":   "light",     # no tool steps, identifies as Veltro
    "t1_read":     "done",
    "t2_find":     "found",     # find must not return "no matches"
    "t3_grep":     "done",
    "t4_verify":   "verdict",   # routed verify + a VERDICT line
    "t5_research": "cited",     # routed research + FINDINGS & SOURCES
    "t6_agentic":  "done",
}

def clean(s): return s.replace("\r", "")

def parse_timing(path):
    """START/END <model> <task> r<rep> <epoch> -> {(m,task,rep): seconds}"""
    starts, out = {}, {}
    if not os.path.exists(path): return out
    for line in clean(open(path).read()).splitlines():
        p = line.split()
        if len(p) >= 5 and p[0] in ("START", "END"):
            key = (p[1], p[2], p[3]); ep = int(p[4])
            if p[0] == "START": starts[key] = ep
            elif key in starts: out[key] = ep - starts[key]
    return out

def analyze(text, task):
    t = clean(text)
    steps   = len(re.findall(r"veltro: step", t))
    done    = "agentloop done" in t
    routed  = (re.search(r"intent routing -> (\w+) agent", t) or [None, ""])
    routed  = routed[1] if hasattr(routed, "__getitem__") and routed else ""
    m = re.search(r"intent routing -> (\w+) agent", t); routed = m.group(1) if m else ""
    verdict = bool(re.search(r"VERDICT:\s*(PASS|FAIL|PARTIAL)", t))
    findings= "FINDINGS" in t.upper()
    sources = "SOURCES" in t.upper()
    nomatch = "no matches found" in t
    dedup   = len(re.findall(r"dedup skip", t))
    toolerr = len(re.findall(r"\berror:", t))
    veltroid= bool(re.search(r"\bVeltro\b", t))
    think   = bool(re.search(r"<think>|Thinking", t))   # qwen3.6 reasoning leakage into output?

    exp = EXPECT.get(task, "done")
    if   exp == "light":   ok = (steps <= 1) and veltroid
    elif exp == "found":   ok = done and not nomatch
    elif exp == "verdict": ok = verdict and (routed == "verify")
    elif exp == "cited":   ok = findings and sources and (routed == "research")
    else:                  ok = done
    return dict(steps=steps, done=done, routed=routed, verdict=verdict,
                findings=findings, sources=sources, nomatch=nomatch, dedup=dedup,
                toolerr=toolerr, think=think, ok=ok)

def final_answer(text, n=400):
    """Best-effort: text after the last 'veltro: step' marker, trimmed."""
    t = clean(text)
    parts = re.split(r"veltro: step \d+", t)
    tail = parts[-1] if parts else t
    tail = "\n".join(l for l in tail.splitlines()
                      if l.strip() and not l.startswith(("agentlib:", "veltro:", "<-", "->")))
    return tail.strip()[:n]

def main():
    timing = parse_timing(os.path.join(LOGS, "_timing"))
    rows = []
    for path in sorted(glob.glob(os.path.join(LOGS, "*__*__r*.log"))):
        base = os.path.basename(path)[:-4]
        m = re.match(r"(.+)__(t\d_\w+)__r(\d+)", base)
        if not m: continue
        model, task, rep = m.group(1), m.group(2), m.group(3)
        a = analyze(open(path, errors="replace").read(), task)
        a["secs"] = timing.get((model, task, "r"+rep), "")
        a.update(model=model, task=task, rep=rep, answer=final_answer(open(path, errors="replace").read()))
        rows.append(a)

    if not rows:
        print(f"No matrix logs in {LOGS}"); return

    # Per-run table
    print("=== PER-RUN ===")
    print(f"{'model':22} {'task':12} {'rep':3} {'ok':3} {'steps':5} {'route':8} {'dedup':5} {'err':3} {'think':5} {'secs':6}")
    for r in rows:
        print(f"{r['model'][:22]:22} {r['task']:12} {r['rep']:3} "
              f"{'Y' if r['ok'] else 'n':3} {r['steps']:5} {r['routed'][:8]:8} "
              f"{r['dedup']:5} {r['toolerr']:3} {'Y' if r['think'] else '-':5} {str(r['secs']):6}")

    # Per-model summary
    print("\n=== PER-MODEL SUMMARY ===")
    bym = collections.defaultdict(list)
    for r in rows: bym[r['model']].append(r)
    print(f"{'model':40} {'ok%':5} {'avgsteps':8} {'avgsecs':8} {'thinks':6}")
    for model, rs in bym.items():
        okp = 100*sum(x['ok'] for x in rs)//len(rs)
        avs = sum(x['steps'] for x in rs)/len(rs)
        secs = [x['secs'] for x in rs if isinstance(x['secs'], int)]
        avsec = sum(secs)/len(secs) if secs else 0
        th = sum(x['think'] for x in rs)
        print(f"{model[:40]:40} {okp:4}% {avs:8.1f} {avsec:8.1f} {th:6}")

    # Family-specific flags (the point of the run)
    print("\n=== FAMILY-SPECIFIC FLAGS ===")
    flags = []
    for model, rs in bym.items():
        for r in rs:
            if r['task'] == 't2_find' and r['nomatch']:
                flags.append(f"{model}: find returned 'no matches' on t2 (arg-format tolerance?)")
            if r['task'] == 't4_verify' and r['routed'] != 'verify':
                flags.append(f"{model}: t4 did NOT route to verify (classifier saw '{r['routed'] or 'none'}')")
            if r['task'] == 't5_research' and r['routed'] != 'research':
                flags.append(f"{model}: t5 did NOT route to research (saw '{r['routed'] or 'none'}')")
            if r['task'] == 't5_research' and not (r['findings'] and r['sources']):
                flags.append(f"{model}: t5 missing FINDINGS/SOURCES discipline")
            if r['task'] == 't0_trivia' and r['steps'] > 1:
                flags.append(f"{model}: t0 trivia triggered {r['steps']} steps (spurious tool use)")
            if r['task'] == 't4_verify' and not r['verdict']:
                flags.append(f"{model}: t4 produced no VERDICT line")
    for f in sorted(set(flags)): print("  ! " + f)
    if not flags: print("  (none — all families behaved within harness expectations)")

    # Answers for eyeballing
    print("\n=== FINAL ANSWERS (eyeball) ===")
    for r in rows:
        print(f"\n--- {r['model']} / {r['task']} r{r['rep']} (ok={'Y' if r['ok'] else 'n'}) ---")
        print(r['answer'] or "(empty)")

if __name__ == "__main__":
    main()

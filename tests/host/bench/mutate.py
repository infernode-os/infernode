#!/usr/bin/env python3
"""
Plant one known bug in each of N Limbo functions, for veltro_edit_bench.sh.

    mutate.py SEED N OUTDIR SRC...

For each task k it writes OUTDIR/k/orig/<name>.b (the original),
OUTDIR/k/work/<name>.b (the file with the bug) and OUTDIR/k/task (one
line: the request the agent is given).  A bug is one of:

    compare   a comparison inverted (== and !=, < and >=, > and <=)
    logic     && and || exchanged
    offbyone  "+ 1" made "- 1", or "- 1" made "+ 1"

made on one line inside a top-level function, which the request names,
with the kind of bug, but not the line.  Lines in comments and strings
are not chosen.  The same seed makes the same tasks.
"""
import os
import random
import re
import sys

FUNC = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(.*\)(\s*:\s*.*)?$")
SWAPS = {
    "compare": [("==", "!="), ("!=", "=="), ("<=", ">"), (">=", "<")],
    "logic": [("&&", "||"), ("||", "&&")],
    "offbyone": [("+ 1", "- 1"), ("- 1", "+ 1")],
}
WHAT = {
    "compare": "one comparison operator was inverted",
    "logic": "one && was changed to || or one || to &&",
    "offbyone": "one + 1 was changed to - 1 or one - 1 to + 1",
}


def candidates(lines):
    """(line index, function, kind, old, new) for every line a bug can go on."""
    out = []
    fn = None
    depth = 0
    for i, line in enumerate(lines):
        if depth == 0:
            m = FUNC.match(line)
            if m:
                fn = m.group(1)
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            depth = 0
            continue
        code = line.split("#", 1)[0]
        if '"' in code or "'" in code:
            continue
        for kind, swaps in SWAPS.items():
            for old, new in swaps:
                # one occurrence, so the fix is unambiguous
                if code.count(old) == 1 and (kind != "compare" or "if(" in code or "while(" in code):
                    if kind == "compare" and old in ("<=", ">=") and code.count(old[0]) != 1:
                        continue
                    if kind == "compare" and old in ("==", "!=") and ("<=" in code or ">=" in code):
                        continue
                    out.append((i, fn, kind, old, new))
    return [c for c in out if c[1]]


def main():
    seed, n, outdir, srcs = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4:]
    rng = random.Random(seed)
    pool = []
    for src in srcs:
        lines = open(src, encoding="utf-8", errors="replace").read().split("\n")
        for c in candidates(lines):
            pool.append((src, lines, c))
    rng.shuffle(pool)
    used = set()
    k = 0
    for src, lines, (i, fn, kind, old, new) in pool:
        if k >= n:
            break
        if (src, fn) in used:
            continue
        used.add((src, fn))
        name = os.path.basename(src)
        bad = list(lines)
        bad[i] = bad[i].replace(old, new, 1)
        d = os.path.join(outdir, str(k))
        os.makedirs(os.path.join(d, "orig"), exist_ok=True)
        os.makedirs(os.path.join(d, "work"), exist_ok=True)
        open(os.path.join(d, "orig", name), "w").write("\n".join(lines))
        open(os.path.join(d, "work", name), "w").write("\n".join(bad))
        open(os.path.join(d, "task"), "w").write(
            "In /usr/bench/%d/%s, in the function %s, %s, which broke it. "
            "Find that change and undo it, changing nothing else in the file. "
            "Then say which line it was.\n" % (k, name, fn, WHAT[kind]))
        open(os.path.join(d, "kind"), "w").write(kind + "\n")
        k += 1
    print(k)


if __name__ == "__main__":
    main()

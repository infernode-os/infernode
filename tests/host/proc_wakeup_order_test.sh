#!/bin/sh
# Once ready() publishes a process to another core, a stack- or owner-backed
# Rendez can disappear.  Pin the rule that neither wake path touches it later.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

python3 - "$ROOT/os/port/proc.c" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1]).read_text()

def body(name, next_name):
    match = re.search(r"\n(?:int|void)\n%s\([^)]*\)\n\{(.*?)\n\}\n\n(?:int|void)\n%s\(" %
                      (name, next_name), src, re.S)
    if not match:
        raise SystemExit("FAIL: cannot isolate %s" % name)
    return match.group(1)

wakeup = body("wakeup", "swiproc")
if wakeup.rfind("unlock(&r->l);") > wakeup.find("ready(p);"):
    raise SystemExit("FAIL: wakeup touches Rendez after publishing the process")

swiproc = body("swiproc", "notkilled")
ready = swiproc.find("ready(p);")
if ready < 0:
    raise SystemExit("FAIL: swiproc no longer wakes its interrupted process")
for release in ("unlock(&r->l);", "unlock(&p->rlock);"):
    if swiproc.find(release) < 0 or swiproc.find(release) > ready:
        raise SystemExit("FAIL: swiproc publishes before %s" % release)
if "ready(p);\n\t\t\tsplx(s);\n\t\t\treturn;" not in swiproc:
    raise SystemExit("FAIL: swiproc accesses wait state after ready")

print("PASS: native wake paths release wait storage before ready")
PY

#!/bin/sh
# Source contract for the queue-bloat fix.  The native boot gate exercises
# qwrite/qbwrite behavior; this pins the security-relevant ordering that is
# otherwise only reachable by repeatedly noting a blocked kernel writer.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

python3 - "$ROOT/os/port/qio.c" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1]).read_text()

def function(name, following):
    match = re.search(r"\n%s\(.*?\n\{(.*?)\n\}\n\n/\*\n \*  %s" %
                      (name, following), src, re.S)
    if not match:
        raise SystemExit("FAIL: cannot isolate %s" % name)
    return match.group(1)

qb = function("qbwrite", "write to a queue")
guard = qb.find("while(q->len >= q->limit && q->noblock == 0)")
enqueue = qb.find("/* queue the block */")
if guard < 0 or enqueue < 0 or guard > enqueue:
    raise SystemExit("FAIL: qbwrite does not stop a full queue before enqueue")
if "sleep(&q->wr, qnotfull, q);" not in qb[guard:enqueue]:
    raise SystemExit("FAIL: qbwrite preflight does not wait for queue space")

qi = function("qiwrite", "be extremely careful")
if "(q->state & Qclosed) != 0 || q->len >= q->limit" not in qi:
    raise SystemExit("FAIL: interrupt-level queue writes can exceed the limit")

print("PASS: qio blocks before retry enqueue and bounds interrupt writes")
PY

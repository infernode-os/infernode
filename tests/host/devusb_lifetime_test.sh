#!/bin/sh
# Source contract for 9front 3a81671b's endpoint publication and sparse-ID
# lifetime rules.  QEMU's USB/hot-plug gates exercise the resulting paths.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

python3 - "$ROOT/os/port/devusb.c" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1]).read_text()

def body(name, _next_name):
    match = re.search(r"\n(?:static )?[^\n]+\n%s\([^)]*\)\n\{" % name, src)
    if not match:
        raise SystemExit("FAIL: cannot isolate %s" % name)
    start = match.end()
    depth = 1
    for pos in range(start, len(src)):
        if src[pos] == "{":
            depth += 1
        elif src[pos] == "}":
            depth -= 1
            if depth == 0:
                return src[start:pos]
    raise SystemExit("FAIL: unterminated %s" % name)

newdev = body("newdev", "settopology")
if newdev.find("ep->dev = d;") > newdev.find("eppublish(ep);"):
    raise SystemExit("FAIL: device endpoint is published before initialization")
if "incref(&ep->r);" not in newdev:
    raise SystemExit("FAIL: newdev does not return a held endpoint reference")

newdevep = body("newdevep", "epdataperm")
for field in ("ep->ep0 = ep0;", "ep->dev = d;", "d->eps[i] = ep;"):
    if newdevep.find(field) < 0 or newdevep.find(field) > newdevep.find("eppublish(ep);"):
        raise SystemExit("FAIL: child endpoint is published before %s" % field)
if newdevep.count("incref(") < 2:
    raise SystemExit("FAIL: child/caller endpoint references are not both held")

getep = body("getep", "putep")
if getep.find("qlock(&epslck);") > getep.find("ep = eps[i];"):
    raise SystemExit("FAIL: endpoint lookup reads the table before locking")

putep = body("putep", "dumpeps")
if "while(epmax > 0 && eps[epmax-1] == nil)" not in putep:
    raise SystemExit("FAIL: sparse endpoint release does not repair epmax")

newid = body("newusbid", "newdev")
if "used[128]" not in newid or "used[id] == 0" not in newid:
    raise SystemExit("FAIL: USB IDs are not allocated from the live-device map")

print("PASS: devusb publishes initialized referenced endpoints and reuses sparse IDs")
PY

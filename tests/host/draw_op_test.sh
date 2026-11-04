#!/bin/sh
# A Drawop and its following draw request are protocol state and consumer;
# they must be reserved in one bufimage call so failure/concurrency cannot
# leak the operator into another drawing command.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
files = [root / "libdraw" / name for name in
         ("draw.c", "line.c", "ellipse.c", "poly.c", "string.c", "path.c")]
for path in files:
    text = path.read_text()
    if "_setdrawop" in text:
        raise SystemExit("FAIL: %s still queues Drawop separately" % path.name)
    if "_bufimageop" not in text:
        raise SystemExit("FAIL: %s does not reserve Drawop with its command" % path.name)

init = (root / "libdraw" / "init.c").read_text()
match = re.search(r"_bufimageop\([^)]*\)\n\{(.*?)\n\}", init, re.S)
if not match:
    raise SystemExit("FAIL: _bufimageop helper is missing")
body = match.group(1)
if "bufimage(d, 2+n)" not in body or "return a+2;" not in body:
    raise SystemExit("FAIL: non-default Drawop is not one atomic reservation")

print("PASS: draw operators and commands share one display-buffer reservation")
PY

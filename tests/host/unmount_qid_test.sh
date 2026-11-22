#!/bin/sh
# Directory unmount sources must retain their walked Qid.  A remote 9P
# server can return a different Qid from open; files such as /srv/cs still
# require open to resolve their underlying channel.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
portdat = (root / "os" / "port" / "portdat.h").read_text()
sysfile = (root / "os" / "port" / "sysfile.c").read_text()
chan = (root / "os" / "port" / "chan.c").read_text()

if "Aunmount" not in portdat:
    raise SystemExit("FAIL: no distinct unmount lookup mode")
if "namec(old, Aunmount, OREAD, 0)" not in sysfile:
    raise SystemExit("FAIL: kunmount still opens every source")

match = re.search(r"case Aunmount:(.*?)case Abind:", chan, re.S)
if not match:
    raise SystemExit("FAIL: directory unmount does not share bind lookup semantics")
body = match.group(1)
if "QTDIR" not in body or "goto Open" not in body:
    raise SystemExit("FAIL: Aunmount does not distinguish directories from files")

open_case = re.search(r"case Aopen:\s*case Acreate:\s*case Aunmount:", chan)
if not open_case:
    raise SystemExit("FAIL: non-directory unmount sources are not opened")

print("PASS: unmount preserves walked directory Qids and opens file indirections")
PY

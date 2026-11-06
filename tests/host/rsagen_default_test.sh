#!/bin/sh
# Standalone RSA key generation must not silently create legacy 1024-bit keys.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
src = (root / "appl" / "cmd" / "auth" / "rsagen.b").read_text()
manual = (root / "man" / "8" / "ai2key").read_text()

match = re.search(r"nbits\s*:=\s*(\d+)\s*;", src)
if not match:
    raise SystemExit("FAIL: cannot find auth/rsagen default")
if int(match.group(1)) < 4096:
    raise SystemExit("FAIL: auth/rsagen defaults below 4096 bits")
if "(default 4096)" not in manual:
    raise SystemExit("FAIL: rsagen manual does not state the hardened default")

print("PASS: auth/rsagen defaults to a 4096-bit modulus")
PY

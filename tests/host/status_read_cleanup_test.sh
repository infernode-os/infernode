#!/bin/sh
# Temporary status buffers must be released when readstr raises: an invalid
# or interrupted read must not become a repeatable kernel-memory leak.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
targets = {
    "os/port/netif.c": ("netifread", 2),
    "os/bcm/ether4330.c": ("etherbcmifstat", 1),
    "os/bcm2711/ethergenet.c": ("genetifstat", 1),
    "os/mpfs/ethergem.c": ("gemifstat", 1),
    "os/virtio/ethervirtio.c": ("vnetifstat", 1),
    "os/bcm/uartmini.c": ("status", 1),
    "os/bcm/uartpl011.c": ("status", 1),
    "os/virt/uartpl011.c": ("status", 1),
    "os/riscv64/uart16550.c": ("status", 1),
}

def function_body(text, name):
    match = re.search(r"\n%s\([^;]*?\)\n\{" % re.escape(name), text, re.S)
    if not match:
        raise SystemExit("FAIL: cannot isolate %s" % name)
    start = match.end() - 1
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    raise SystemExit("FAIL: unterminated %s" % name)

for rel, (name, expected) in targets.items():
    body = function_body((root / rel).read_text(), name)
    allocations = list(re.finditer(r"p\s*=\s*malloc\([^;]+\);", body))
    protected = 0
    for i, alloc in enumerate(allocations):
        end = allocations[i + 1].start() if i + 1 < len(allocations) else len(body)
        section = body[alloc.end():end]
        read = section.find("readstr(")
        if read < 0:
            continue
        before = section[:read]
        after = section[read:]
        if "if(waserror())" not in before or "free(p);" not in before:
            raise SystemExit("FAIL: %s:%s leaks its status buffer on read error" % (rel, name))
        free = after.find("free(p);")
        pop = after.find("poperror();")
        if free < 0 or pop < free:
            raise SystemExit("FAIL: %s:%s does not release and pop cleanup" % (rel, name))
        protected += 1
    if protected != expected:
        raise SystemExit("FAIL: %s:%s protects %d/%d status buffers" %
                         (rel, name, protected, expected))

print("PASS: Ethernet and UART status reads clean temporary buffers on error")
PY

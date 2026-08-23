#!/bin/sh
# Deterministic tests for escape-room evidence verification and canary scans.
set -eu

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

python3 - "$ROOT" <<'PY'
import hashlib
import importlib.util
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "grind", root / "tests/agent-harness/grind.py")
grind = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grind)

payload = b"sealed tool result"
sha = hashlib.sha256(payload).hexdigest()
score = "a" * 40 + ":3"
events = grind.AUDIT_EVENTS

with tempfile.TemporaryDirectory() as td:
    evidence = Path(td)
    (evidence / "pre.head").write_text("b" * 64 + " 2\n")
    (evidence / "post.head").write_text("c" * 64 + " 10\n")
    (evidence / "pubkey").write_text("synthetic-public-key\n")
    (evidence / "verify-pre").write_text("ok: anchored\n")
    (evidence / "verify-post").write_text("ok: anchored\n")
    lines = []
    seq = 1
    for event in events:
        msg = "sig=x" if event == "checkpoint" else "activity=0"
        if event == "toolres":
            msg += f" content={score} sha256={sha} size={len(payload)}"
        lines.append(f"{seq} 1 lucibridge {event} {'d' * 64} {msg}")
        seq += 1
    lines.append(f"{seq} 1 auditfs checkpoint {'e' * 64} head=x seq=1 sig=x")
    seq += 1
    lines.append(f"{seq} 1 auditfs checkpoint {'f' * 64} head=y seq=2 sig=y")
    (evidence / "chain").write_text("\n".join(lines) + "\n")
    (evidence / f"payload-{score}").write_bytes(payload)

    errors, payloads, records = grind.verify_audit_bundle(
        evidence, {"audit": "verified"}, events)
    assert not errors, errors
    assert payloads == [(score, payload)]
    assert len(records) == len(lines)

    (evidence / f"payload-{score}").write_bytes(b"tampered")
    errors, _, _ = grind.verify_audit_bundle(evidence, {"audit": "verified"}, events)
    assert any("SHA-256 mismatch" in error for error in errors), errors

canary = b"0123456789abcdef" * 4 + b"\n"
hits = grind.scan_canaries(
    {"root": {"value": canary}},
    [("parent", "clean"), ("child", b"prefix " + canary + b" suffix")])
assert hits == [{"canary": "root", "channel": "child"}], hits
print("grind_escape_test: PASS")
PY

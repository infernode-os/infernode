#!/bin/bash
#
# nsaudit path semantics must be component-aware. A grant for /tmp/veltro
# must not cover /tmp/veltroevil, and /n/local/foo must not cover
# /n/local/foobar. These are audit-tool checks, not namespace enforcement.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

SH="/dis/sh.dis"
[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
[[ -f "$ROOT/dis/nsaudit.dis" ]] || { echo "SKIP: nsaudit.dis not found"; exit 77; }

run_nsaudit() {
	timeout 30 "$EMU" -r"$ROOT" "$SH" -c \
		"path=(/dis/veltro /dis/cmd /dis .); nsaudit -m $*" \
		</dev/null 2>&1 || true
}

out="$(run_nsaudit /tests/nsaudit-rules/durable-host-mutation /tmp/veltroevil/file)"
echo "$out" | grep -q 'reads_fs=no' || {
	echo "FAIL: /tmp/veltro grant was treated as read access to /tmp/veltroevil" >&2
	echo "$out" >&2
	exit 1
}
echo "$out" | grep -q 'writes_fs=no' || {
	echo "FAIL: /tmp/veltro grant was treated as write access to /tmp/veltroevil" >&2
	echo "$out" >&2
	exit 1
}

out="$(run_nsaudit /tests/nsaudit-rules/durable-host-mutation)"
echo "$out" | grep -q 'violation=DURABLE_HOST_MUTATION' || {
	echo "FAIL: durable /n/local grant did not trigger durable mutation rule" >&2
	echo "$out" >&2
	exit 1
}

echo "PASS: nsaudit path containment is component-aware"

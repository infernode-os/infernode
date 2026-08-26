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

# Live /tool/paths uses "path ro|rw" records, while old fixtures contain a
# bare path (implicitly rw). The permission token is metadata, not part of the
# path, and a read-only grant must not become write authority.
out="$(timeout 30 "$EMU" -r"$ROOT" "$SH" -c \
	"path=(/dis/veltro /dis/cmd /dis .); rm -r /tmp/nsperm >[2] /dev/null; mkdir -p /tmp/nsperm/meta; echo write > /tmp/nsperm/tools; echo '/tmp/veltro/sample ro' > /tmp/nsperm/paths; echo child > /tmp/nsperm/meta/role; echo 0 > /tmp/nsperm/meta/xenith; echo 7 > /tmp/nsperm/meta/actid; echo set > /tmp/nsperm/meta/nodevs; nsaudit -m /tmp/nsperm" \
	</dev/null 2>&1 || true)"
echo "$out" | grep -q 'authority=invalid_path_grant' && {
	echo "FAIL: nsaudit treated a live path permission as path text" >&2
	echo "$out" >&2
	exit 1
}
echo "$out" | grep -q 'writes_fs=/tmp/veltro/sample' && {
	echo "FAIL: read-only live path record became write authority" >&2
	echo "$out" >&2
	exit 1
}

out="$(timeout 30 "$EMU" -r"$ROOT" "$SH" -c \
	"path=(/dis/veltro /dis/cmd /dis .); echo '/tmp/veltro/sample rw' > /tmp/nsperm/paths; nsaudit -m /tmp/nsperm" \
	</dev/null 2>&1 || true)"
echo "$out" | grep -q 'writes_fs=/tmp/veltro/sample' || {
	echo "FAIL: writable live path record did not become write authority" >&2
	echo "$out" >&2
	exit 1
}

echo "PASS: nsaudit path containment is component-aware"

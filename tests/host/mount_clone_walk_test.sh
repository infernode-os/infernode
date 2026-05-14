#!/bin/bash
#
# Regression test for zero-element clone walks in device walkers.
#
# `cclone()` calls `walk(..., 0)`. Several C walkers historically used
# `sizeof(Walkqid) + (nname-1)*sizeof(Qid)` unguarded, which can
# under-allocate the base Walkqid header when `nname == 0`.
#
# A simple `mount -ac {mntgen} /n` goes through that clone path. This
# test keeps that smoke check in the normal host suite.
#

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

TIMEOUT=20
LOG=$(mktemp /tmp/mount-clone-walk.XXXXXX)
SCRIPT="$ROOT/tmp_mount_clone_walk_test.sh"

cleanup() {
	rm -f "$LOG" "$SCRIPT"
}
trap cleanup EXIT

if [[ ! -x "$EMU" ]]; then
	echo "SKIP: no emulator at $EMU"
	exit 77
fi

cat >"$SCRIPT" <<'EOF'
load std
mount -ac {mntgen} /n >[2] /dev/null
ls /n >[2] /dev/null
echo OK
EOF

timeout "$TIMEOUT" "$EMU" -r"$ROOT" sh /tmp_mount_clone_walk_test.sh >"$LOG" 2>&1 || RC=$?
RC=${RC:-0}
OUT=$(cat "$LOG")

if [[ "$RC" -ne 0 && "$RC" -ne 124 ]]; then
	echo "FAIL: emulator exited with rc=$RC"
	echo "$OUT"
	exit 1
fi

if ! grep -q '^OK$' "$LOG"; then
	echo "FAIL: expected OK marker after mount clone walk smoke"
	echo "$OUT"
	exit 1
fi

echo "PASS: mount clone walk smoke"

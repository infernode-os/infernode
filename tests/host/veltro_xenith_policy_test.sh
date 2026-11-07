#!/bin/sh
# Pin the Xenith tool's narrow, auditable ctl allowlist.  Xenith executes ctl
# in the desktop namespace, so a newly allowed file/document command is a
# capability-boundary change even when the agent owns the window.
set -eu
. "$(dirname "$0")/common.sh"

SRC="$ROOT/appl/veltro/tools/xenith.b"
ALLOW=$(awk '
	/^CTLOK := array/ { inlist = 1 }
	inlist { print }
	inlist && /^};/ { exit }
' "$SRC")

for verb in name get put dump dumpdir image content contentcmd; do
	if printf '%s\n' "$ALLOW" | grep -q "\"$verb\""; then
		echo "FAIL: Xenith agent ctl allows $verb"
		exit 1
	fi
done

for verb in clean show grow moveto tocol; do
	if ! printf '%s\n' "$ALLOW" | grep -q "\"$verb\""; then
		echo "FAIL: expected layout command $verb is absent"
		exit 1
	fi
done

grep -q "a window's name is a label, not a file" "$SRC" || {
	echo "FAIL: created-window names are no longer pinned to labels"
	exit 1
}
grep -q '== "/+Errors"' "$SRC" || {
	echo "FAIL: synthetic-window read fallback is no longer +Errors-only"
	exit 1
}

echo "PASS: Xenith agent controls remain layout-only"

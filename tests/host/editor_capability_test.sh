#!/bin/bash

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }

log=$(mktemp)
trap 'rm -f "$log"' EXIT
timeout 15 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	'path=(/dis/veltro /dis/cmd /dis .); mkdir -p /tmp/veltro/editor/1; tools9p editor & sleep 2; echo open /appl/veltro/veltro.b > /tool/editor/run; sleep 2; echo HIDDEN; cat /tool/editor/run; echo open /lib/veltro/meta.txt > /tool/editor/run; sleep 2; echo VISIBLE; cat /tool/editor/run; cat /tmp/veltro/editor/ctl; echo 1 /lib/veltro/meta.txt 1 > /tmp/veltro/editor/index; echo save > /tool/editor/run; sleep 2; echo SAVE; cat /tool/editor/run; echo name /lib/veltro/new.txt > /tool/editor/run; sleep 2; echo NAME; cat /tool/editor/run' \
	</dev/null >"$log" 2>&1
rc=$?
emu_timeout_ok "$rc" || { cat "$log"; exit 1; }

grep -q 'path is outside the agent namespace: /appl/veltro/veltro.b' "$log" || { echo "FAIL: hidden path was accepted"; cat "$log"; exit 1; }
grep -q 'open /lib/veltro/meta.txt' "$log" || { echo "FAIL: visible path was not forwarded"; cat "$log"; exit 1; }
grep -q '/lib/veltro/meta.txt is not covered by an rw path grant' "$log" || { echo "FAIL: save to ungranted path was accepted"; cat "$log"; exit 1; }
grep -q '/lib/veltro/new.txt is not covered by an rw path grant' "$log" || { echo "FAIL: name to ungranted path was accepted"; cat "$log"; exit 1; }

echo "PASS: editor deputy enforces read visibility and write grants"

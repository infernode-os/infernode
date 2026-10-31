#!/bin/bash

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }

log=$(mktemp)
trap 'rm -f "$log"' EXIT
# a real editor, headless: it posts #seditor/fs, which tools9p mounts at
# /mnt/editor for the editor tool; /edit is its tree in this name space
timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	'path=(/dis/veltro /dis/cmd /dis .); wm/editor & sleep 2; tools9p editor & sleep 2; echo open /appl/veltro/veltro.b > /tool/editor/run; echo HIDDEN; cat /tool/editor/run; echo open /lib/veltro/meta.txt > /tool/editor/run; echo VISIBLE; cat /tool/editor/run; echo INDEX; cat /edit/index; echo save > /tool/editor/run; echo SAVE; cat /tool/editor/run; echo name /lib/veltro/new.txt > /tool/editor/run; echo NAME; cat /tool/editor/run; echo name /tmp/veltro/scratch/../escape > /tool/editor/run; echo TRAVERSAL; cat /tool/editor/run; echo DONE' \
	</dev/null >"$log" 2>&1
rc=$?
emu_timeout_ok "$rc" || { cat "$log"; exit 1; }

grep -q 'path is outside the agent namespace: /appl/veltro/veltro.b' "$log" || { echo "FAIL: hidden path was accepted"; cat "$log"; exit 1; }
grep -q '^1 /lib/veltro/meta.txt ' "$log" || { echo "FAIL: visible path was not opened in the editor"; cat "$log"; exit 1; }
grep -q '/lib/veltro/meta.txt is not covered by an rw path grant' "$log" || { echo "FAIL: save to ungranted path was accepted"; cat "$log"; exit 1; }
grep -q '/lib/veltro/new.txt is not covered by an rw path grant' "$log" || { echo "FAIL: name to ungranted path was accepted"; cat "$log"; exit 1; }
grep -q 'invalid path: dot path component' "$log" || { echo "FAIL: traversal name path was accepted"; cat "$log"; exit 1; }

echo "PASS: editor deputy enforces read visibility and write grants"

#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }

log=$(mktemp)
trap 'rm -f "$log"' EXIT
timeout 15 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	'path=(/dis/veltro /dis/cmd /dis .); tools9p read exec webfetch &sleep 2; echo /net/tcp > /tool/read/run; sleep 1; echo READNET; cat /tool/read/run; echo /dis/veltro/tools/webfetch.dis > /tool/read/run; sleep 1; echo READOTHER; cat /tool/read/run; echo ls /net > /tool/exec/run; sleep 1; echo EXECNET; cat /tool/exec/run; echo DONE' \
	</dev/null >"$log" 2>&1
rc=$?
output=$(cat "$log")

[[ $rc -eq 0 || $rc -eq 124 ]] || { echo "$output"; exit 1; }
grep -q DONE <<<"$output" || { echo "FAIL: tools9p test did not complete"; echo "$output"; exit 1; }

if grep -Eq 'cannot open.*/net|/net.*does not exist' <<<"$output"; then
	echo "PASS: read and exec invocations cannot reach raw network devices"
else
	echo "FAIL: a non-network invocation may have reached /net"; echo "$output"; exit 1
fi

if grep -Eq 'cannot open.*webfetch.dis|webfetch.dis.*does not exist' <<<"$output"; then
	echo "PASS: read invocation cannot load a sibling tool module"
else
	echo "FAIL: sibling tool module remained visible"; echo "$output"; exit 1
fi

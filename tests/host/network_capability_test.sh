#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }

log=$(mktemp)
trap 'rm -f "$log"' EXIT
timeout 15 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	'path=(/dis/veltro /dis/cmd /dis .); tools9p read exec webfetch browse &sleep 2; echo /net/tcp > /tool/read/run; sleep 1; echo READNET; cat /tool/read/run; echo /dis/veltro/tools/webfetch.dis > /tool/read/run; sleep 1; echo READOTHER; cat /tool/read/run; echo http://127.0.0.1:1/ > /tool/browse/run; sleep 1; echo BROWSEPRIVATE; cat /tool/browse/run; echo DONE' \
	</dev/null >"$log" 2>&1
rc=$?
output=$(cat "$log")

emu_timeout_ok "$rc" || { echo "$output"; exit 1; }
grep -q DONE <<<"$output" || { echo "FAIL: tools9p test did not complete"; echo "$output"; exit 1; }

if grep -Eq 'cannot open.*/net|/net.*does not exist' <<<"$output"; then
	echo "PASS: read invocation cannot reach raw network devices"
else
	echo "FAIL: a non-network invocation may have reached /net"; echo "$output"; exit 1
fi

if grep -q 'private or reserved destination denied' <<<"$output"; then
	echo "PASS: browser transport rejects private destinations"
else
	echo "FAIL: browser did not enforce public destination policy"; echo "$output"; exit 1
fi

if grep -Eq 'cannot open.*webfetch.dis|webfetch.dis.*does not exist' <<<"$output"; then
	echo "PASS: read invocation cannot load a sibling tool module"
else
	echo "FAIL: sibling tool module remained visible"; echo "$output"; exit 1
fi

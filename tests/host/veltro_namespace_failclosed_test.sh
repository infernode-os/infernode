#!/bin/sh

set -eu

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
. "$ROOT/tests/host/common.sh"

if [ ! -x "$EMU" ]; then
	echo "SKIP: emulator not found at $EMU"
	exit 0
fi

output=$(
	"$EMU" -r"$ROOT" /dis/veltro/veltro.dis -p /.. test 2>&1 || true
)

echo "$output"
echo "$output" | grep -q "namespace restriction failed"
if echo "$output" | grep -q "starting with task"; then
	echo "FAIL: veltro continued after namespace restriction failure" >&2
	exit 1
fi

echo "PASS: veltro fails closed on namespace restriction failure"

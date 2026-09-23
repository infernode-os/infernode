#!/bin/sh
# Source pin complementing the behavioral timeout cases in lucibridge_test.b.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/appl/cmd/lucibridge.b"

grep -q 'result := calltoolbounded(name, eargs);' "$SRC"
grep -q 'resultch := chan\[1\] of string;' "$SRC"
grep -q 'timeoutch := chan\[1\] of int;' "$SRC"

if grep -q 'result := agentlib->calltool(name, eargs);' "$SRC"; then
	echo "lucibridge_tool_timeout_test: FAIL (agent loop bypasses timeout)" >&2
	exit 1
fi

echo "lucibridge_tool_timeout_test: PASS"

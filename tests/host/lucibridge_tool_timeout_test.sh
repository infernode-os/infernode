#!/bin/sh
# Source pin complementing the behavioral timeout cases in lucibridge_test.b.
#
# The agent loop lives in veltrosrv.b now.  Every tool call it makes must
# go through the bounded launch/collect pair, on buffered one-shot channels
# so a late sender can finish rather than hang (#599); and lucibridge, a
# client, must not call tools itself (its one call is the tour's task).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/appl/veltro/veltrosrv.b"
fail() { echo "lucibridge_tool_timeout_test: FAIL ($1)" >&2; exit 1; }

grep -q 'c := ref Call(id, name, args, chan\[1\] of string, chan\[1\] of int);' "$SRC" ||
	fail "tool result channels are not buffered one-shots"
grep -q 'r := collect(c);' "$SRC" || fail "parallel batch does not collect through the bound"
grep -q 'r := collect(launch(s, id, name, args));' "$SRC" || fail "sequential batch does not go through the bound"
[ "$(grep -c 'al->calltool(' "$SRC")" = 1 ] || fail "a tool call in veltrosrv.b bypasses launch"
grep -q 'resultch <-= s.al->calltool(name, args);' "$SRC" || fail "the one direct call is not the worker's"

if grep 'calltool(' "$ROOT/appl/cmd/lucibridge.b" | grep -v -q '"task"'; then
	fail "lucibridge calls tools itself"
fi

echo "lucibridge_tool_timeout_test: PASS"

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

grep -q 'c := ref Call(tc.id, tc.name, tc.args, chan\[1\] of string, chan\[1\] of int);' "$SRC" ||
	fail "tool result channels are not buffered one-shots"
grep -q 'r := collect(c);' "$SRC" || fail "parallel batch does not collect through the bound"
grep -q 'r := collect(launch(s, tc));' "$SRC" || fail "sequential batch does not go through the bound"
# Two direct calls, both behind launch's bound: the worker's own (no tool
# broker) and the broker's, which the worker hands its call to.  They are
# callraw: the call's arguments are the one canonical form the gate judged,
# given to the tool as they are.  Nothing calls calltool, which would read
# them again.
[ "$(grep -c 'al->callraw(' "$SRC")" = 2 ] || fail "a tool call in veltrosrv.b bypasses launch"
[ "$(grep -c 'al->calltool(' "$SRC")" = 0 ] || fail "veltrosrv.b calls a tool with arguments read a second time"
grep -q 'resultch <-= s.al->callraw(name, args);' "$SRC" || fail "the worker does not make the direct call"
grep -q 'resultch <-= bal->callraw(name, args);' "$SRC" || fail "the broker does not answer the worker's channel"
grep -q 'brokerc <-= (name, args, resultch);' "$SRC" || fail "the worker does not hand its call to the broker"

if grep 'calltool(' "$ROOT/appl/cmd/lucibridge.b" | grep -v -q '"task"'; then
	fail "lucibridge calls tools itself"
fi

echo "lucibridge_tool_timeout_test: PASS"

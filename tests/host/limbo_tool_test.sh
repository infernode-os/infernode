#!/bin/sh
#
# limbo_tool_test.sh — the agent's limbo tool compiling through tools9p,
# in the name space a tool call is given.
#
# tests/limbo_tool_test.b drives the tool in-process; this is the same
# compiler path where it is used: the compiler runs in a process of its
# own whose name space has an empty directory over the services, devices
# and tool files, and whose descriptors are a pipe of its own.  A source
# that compiles is said to, one that does not comes back with the
# compiler's errors, and six compiles made at once all answer (made in the
# call's thread, on the descriptors all calls share, all but one waited
# for ever).
#
set -eu
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/tools9p.dis dis/veltro/tools/limbo.dis dis/tests/tool9call.dis dis/limbo.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

SCR="$ROOT/tmp/veltro/scratch/0"
G="lt$$"
OUT="$ROOT/tmp/limbo-tool-test.$$.out"
SCRIPT="$ROOT/tmp/limbo-tool-test.$$.sh"
trap 'rm -f "$SCR/$G-good.b" "$SCR/$G-bad.b" "$OUT" "$SCRIPT"' EXIT HUP INT TERM
mkdir -p "$SCR"
cat > "$SCR/$G-good.b" <<'EOF2'
implement Good;
include "sys.m";
	sys: Sys;
include "draw.m";
Good: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->print("good\n");
}
EOF2
printf 'implement Bad;\nthis is not Limbo\n' > "$SCR/$G-bad.b"

cat > "$SCRIPT" <<EOF2
load std
path=(/dis/veltro /dis/cmd /dis .)
tools9p -m /tool read limbo >[2] /dev/null &
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 { if {! ftest -f /tool/limbo/ctl} { sleep 1 } }
echo '== good'
/dis/tests/tool9call.dis limbo compile /tmp/veltro/scratch/$G-good.b
echo '== bad'
/dis/tests/tool9call.dis limbo compile /tmp/veltro/scratch/$G-bad.b
echo '== atonce'
for i in 1 2 3 4 5 6 { /dis/tests/tool9call.dis limbo compile /tmp/veltro/scratch/$G-good.b & }
sleep 25
echo '== left'
ls /tmp/veltro/scratch
echo LIMBO_TOOL_DONE
EOF2

with_timeout 100 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "sh /tmp/limbo-tool-test.$$.sh; echo halt > /dev/sysctl" \
	</dev/null >"$OUT" 2>&1 || true
grep -q '^LIMBO_TOOL_DONE$' "$OUT" || { echo "FAIL: the run did not finish"; cat "$OUT"; exit 1; }

status=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; status=1; }
section() { awk -v a="== $1" '$0 == a { on = 1; next } on && /^== / { exit } on { print }' "$OUT"; }

section good | grep -q '^status: compiled' && ok "a source that compiles is said to" || bad "a source that compiles is said to"
if section bad | grep -q '^status: failed' && section bad | grep -q "$G-bad.b:"; then
	ok "one that does not comes back with the compiler's errors"
else
	bad "one that does not comes back with the compiler's errors"
fi
n=$(section atonce | grep -c '^status: compiled' || true)
[ "$n" -eq 6 ] && ok "six compiles made at once all answer" || bad "six compiles made at once all answer ($n did)"
if section left | grep -q 'limbo-gate'; then
	bad "nothing of the compiler's is left in the workspace"
else
	ok "nothing of the compiler's is left in the workspace"
fi

[ $status -eq 0 ] && echo "limbo_tool_test: PASS" || { echo "--- output"; cat "$OUT"; }
exit $status

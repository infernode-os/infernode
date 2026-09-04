#!/bin/sh
# Regression test for INFR-421 (follow-up): the exec tool must not abandon a
# command that overruns its deadline.
#
# exec.b spawns the command in a worker goroutine and returns after a 5s
# timeout (or a 16KB output cap).  It used to just stop reading, leaving the
# command running unsupervised outside the tool's accounting.  Two such
# abandoned limbo.dis compiles are what were still JIT-compiling when the
# emulator faulted in the escape campaign, and INFR-434's step-9 exec never
# returned because a state-modifying command was left blocked with nothing to
# release it.
#
# The fix makes the worker a process-group leader (NEWPGRP), reports its pid,
# and — if the command is still running when the tool stops reading — writes
# "killgrp" to /prog/<pid>/ctl so the whole subtree dies with the tool call.
#
# This test checks two things without needing the full tools9p COW stack
# (which the tools9p_* tests already exercise):
#   1. source contract — exec.b wires the pid channel, NEWPGRP and killgrp;
#   2. mechanism — killgrp on a NEWPGRP leader actually terminates the group.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
set -u

fails=0
E="$ROOT/appl/veltro/tools/exec.b"
grep -q 'sys->pctl(Sys->NEWPGRP, nil)'          "$E" || { echo "FAIL: exec.b worker is not a process-group leader"; fails=$((fails+1)); }
grep -q 'killgrp(workerpid)'                    "$E" || { echo "FAIL: exec.b does not kill the worker group when still running"; fails=$((fails+1)); }
grep -q 'killgrp(pid: int)'                     "$E" || { echo "FAIL: exec.b has no killgrp helper"; fails=$((fails+1)); }
grep -q '"killgrp"'                             "$E" || { echo "FAIL: exec.b killgrp does not write the killgrp control message"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "PASS: source contract (exec.b kills the worker group on timeout/overrun)"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }
[ -x "$LIMBO" ] || {
	echo "SKIP: native limbo not built — source contract only"
	[ "$fails" -eq 0 ] && exit 0 || exit 1
}

WORK="$ROOT/tmp/exec_killgrp_mech"
SRC="$WORK.b"
DIS="$WORK.dis"
trap 'rm -f "$SRC" "$DIS"' EXIT HUP INT TERM

cat >"$SRC" <<'EOF'
implement KillgrpMech;
include "sys.m";
	sys: Sys;
include "draw.m";
KillgrpMech: module { init: fn(nil: ref Draw->Context, nil: list of string); };

# Mirror exec.b: a worker becomes a process-group leader, reports its pid,
# spawns a long child, and idles.  killgrp on that pid must take out both.
worker(pidch: chan of int)
{
	pid := sys->pctl(Sys->NEWPGRP, nil);
	pidch <-= pid;
	spawn longchild();
	sys->sleep(60000);
}
longchild() { sys->sleep(60000); }

exists(pid: int): int
{
	fd := sys->open("/prog/" + string pid + "/status", Sys->OREAD);
	if(fd == nil) return 0;
	return 1;
}
killgrp(pid: int)
{
	ctl := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(ctl == nil) return;
	msg := array of byte "killgrp";
	sys->write(ctl, msg, len msg);
}
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	pidch := chan of int;
	spawn worker(pidch);
	wpid := <-pidch;
	sys->sleep(500);
	before := exists(wpid);
	killgrp(wpid);
	sys->sleep(500);
	after := exists(wpid);
	if(before == 1 && after == 0)
		sys->print("MECH: PASS\n");
	else
		sys->print("MECH: FAIL before=%d after=%d\n", before, after);
}
EOF

"$LIMBO" -I"$ROOT/module" -o "$DIS" "$SRC" || {
	echo "FAIL: could not compile the mechanism probe"; exit 1; }

OUT="$(timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis -c "${DIS#$ROOT}" 2>&1)"
if echo "$OUT" | grep -q '^MECH: PASS$'; then
	echo "PASS: killgrp terminates a NEWPGRP worker group"
else
	echo "FAIL: killgrp did not terminate the group"
	echo "$OUT" | grep -vE '^JIT|sdl3_pre' | tail -5
	exit 1
fi

[ "$fails" -eq 0 ] || exit 1

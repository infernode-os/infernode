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
# "killtree" to /prog/<pid>/ctl so the whole descendant process-group tree
# dies with the tool call, including commands that called NEWPGRP themselves.
#
# This test checks two things without needing the full tools9p COW stack
# (which the tools9p_* tests already exercise):
#   1. source contract — exec.b wires the pid channel, NEWPGRP and killtree;
#   2. mechanism — killtree reaches a descendant that escaped into NEWPGRP.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
set -u

fails=0
E="$ROOT/appl/veltro/tools/exec.b"
grep -q 'sys->pctl(Sys->NEWPGRP, nil)'          "$E" || { echo "FAIL: exec.b worker is not a process-group leader"; fails=$((fails+1)); }
grep -q 'killtree(workerpid)'                   "$E" || { echo "FAIL: exec.b does not kill the worker tree when still running"; fails=$((fails+1)); }
grep -q 'killtree(pid: int)'                    "$E" || { echo "FAIL: exec.b has no killtree helper"; fails=$((fails+1)); }
grep -q '"killtree"'                            "$E" || { echo "FAIL: exec.b killtree does not write the killtree control message"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "PASS: source contract (exec.b kills the worker tree on timeout/overrun)"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }
[ -x "$LIMBO" ] || {
	echo "SKIP: native limbo not built — source contract only"
	[ "$fails" -eq 0 ] && exit 0 || exit 1
}

WORK="$ROOT/tmp/exec_killtree_mech"
SRC="$WORK.b"
DIS="$WORK.dis"
trap 'rm -f "$SRC" "$DIS"' EXIT HUP INT TERM

cat >"$SRC" <<'EOF'
implement KilltreeMech;
include "sys.m";
	sys: Sys;
include "draw.m";
KilltreeMech: module { init: fn(nil: ref Draw->Context, nil: list of string); };

# Mirror exec.b: a worker becomes a process-group leader, then its child calls
# NEWPGRP again. killtree on the worker must cross that group boundary.
worker(pidch, childch: chan of int)
{
	pid := sys->pctl(Sys->NEWPGRP, nil);
	pidch <-= pid;
	spawn longchild(childch);
	sys->sleep(60000);
}
longchild(childch: chan of int)
{
	childch <-= sys->pctl(Sys->NEWPGRP, nil);
	sys->sleep(60000);
}

exists(pid: int): int
{
	fd := sys->open("/prog/" + string pid + "/status", Sys->OREAD);
	if(fd == nil) return 0;
	return 1;
}
killtree(pid: int)
{
	ctl := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(ctl == nil) return;
	msg := array of byte "killtree";
	sys->write(ctl, msg, len msg);
}
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	pidch := chan of int;
	childch := chan of int;
	spawn worker(pidch, childch);
	wpid := <-pidch;
	cpid := <-childch;
	sys->sleep(500);
	before := exists(wpid) && exists(cpid);
	killtree(wpid);
	sys->sleep(500);
	after := exists(wpid) || exists(cpid);
	if(before == 1 && after == 0)
		sys->print("MECH: PASS\n");
	else
		sys->print("MECH: FAIL before=%d survivor=%d\n", before, after);
}
EOF

"$LIMBO" -I"$ROOT/module" -o "$DIS" "$SRC" || {
	echo "FAIL: could not compile the mechanism probe"; exit 1; }

OUT="$(timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis -c "${DIS#$ROOT}" 2>&1)"
if echo "$OUT" | grep -q '^MECH: PASS$'; then
	echo "PASS: killtree terminates a descendant NEWPGRP"
else
	echo "FAIL: killtree did not terminate the descendant group"
	echo "$OUT" | grep -vE '^JIT|sdl3_pre' | tail -5
	exit 1
fi

[ "$fails" -eq 0 ] || exit 1

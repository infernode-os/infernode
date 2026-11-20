#!/bin/sh
#
# tools9p_call_test.sh — a tool call's own descriptors and name space,
# and what the control files say, through tests/tools9p/call.sh:
#
#  - a call's descriptors are its own: a program exec runs, beside six
#    other calls, has /dev/null as its input and nothing of theirs open
#    (every call shared the serve loop's table, and the program kept
#    whatever was in slot 0 at that moment: the console, another call's
#    open directory, a mount's pipe);
#  - /tool/paths says of a grant what the name space does: a service
#    under /mnt is not bound read-only and is not listed ro; a grant
#    under /tmp/veltro is, and stays ro;
#  - budget-remove takes a tool's name in any case (Exec was left in the
#    budget, and the revocation answered as done);
#  - cancel refuses an activity that is not being provisioned;
#  - a task create runs in a restricted name space, in each form the
#    task tool takes for a create (it ran in the server's own);
#  - a task made starts with no memory and no plans: the stores an
#    earlier task of its number left are removed, by the tool server
#    (the task tool's own call cannot see them), and no other task's;
#  - a descriptor held on a tool's ctl is not a descriptor on the tool
#    added after that one was removed (the new tool took the old one's
#    qids, and a write on the old descriptor called it).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/tools9p.dis dis/veltro/tools/exec.dis dis/veltro/tools/task.dis dis/tests/spawnfake.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

T=tmp/tools9p_call_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${SPAWN_KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
with_timeout 90 "$EMU" -r"$ROOT" /dis/sh.dis -c "bind -c /$T /tmp; /tests/tools9p/call.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$ROOT/$T/$1" 2>/dev/null || true; }
n() { f "$1" | grep -c "$2" || true; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; tail -30 "$LOG"; exit 1; }

if f r.fds | grep -q '^fd 0 .*null' && f r.fds | grep -q '^fd 1 ' &&
   ! f r.fds | grep -q -E '/lib/veltro|/prog/|cons$' && [ "$(n r.fds '^fd ')" -le 6 ]; then
	pass "a call's command has /dev/null as its input and no other call's descriptors"
else
	fail "descriptors: $(f r.fds | tr '\n' '|')"
fi

if f r.paths | grep -qx '/mnt/acme rw' && f r.paths | grep -qx '/tmp/veltro/vproj ro'; then
	pass "/tool/paths lists a grant as the name space has it"
else
	fail "paths: $(f r.paths | tr '\n' '|')"
fi

if f r.budget.before | grep -qx exec && ! f r.budget | grep -qx exec && f r.budget | grep -qx read; then
	pass "budget-remove takes the tool's name in any case"
else
	fail "budget: before $(f r.budget.before | tr '\n' ' '), after $(f r.budget | tr '\n' ' ')"
fi

if f err.cancel | grep -q 'is not being provisioned'; then
	pass "cancel refuses an activity that is not being provisioned"
else
	fail "cancel: '$(f err.cancel)'"
fi

if [ "$(n ui.log '^restricted')" -ge 3 ] && [ "$(n ui.log '^unrestricted')" = 0 ] &&
   f r.create | grep -q -i 'nope'; then
	pass "a task create runs in a restricted name space, in each of its forms"
else
	fail "task create: $(n ui.log '^restricted') requests restricted, $(n ui.log '^unrestricted') not; result: $(f r.create | head -2)"
fi

id=$(sed -n 's/^tools9p: provisioning activity \([0-9]*\) at .*/\1/p' "$LOG" | tail -1)
if [ "$id" = 7 ] && ! f r.stores | grep -q -x -E '/tmp/veltro/memory/7|/tmp/veltro/plans/a7' &&
   f r.stores | grep -q -x '/tmp/veltro/memory/8' && f r.stores | grep -q -x '/tmp/veltro/plans/a8'; then
	pass "a task made has no memory or plans of an earlier task of its number"
else
	fail "task stores: provisioned '$id'; left: $(f r.stores | tr '\n' ' ')"
fi

if f r.hold | grep -q 'hold: open' && ! f r.hold | grep -q 'hold: result' &&
   f r.hold | grep -q 'hold: write:' && f r.list | grep -q 'entries'; then
	pass "a descriptor on a removed tool's ctl is not one on the tool added after"
else
	fail "held descriptor: $(f r.hold | tr '\n' '|' | cut -c1-300); list: $(f r.list | head -1)"
fi

if [ $failed != 0 ]; then
	echo "--- emulator output:"
	tail -30 "$LOG"
	exit 1
fi
echo "tools9p_call_test: PASS"

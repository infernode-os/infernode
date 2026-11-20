#!/bin/sh
#
# spawn_life_test.sh — a subagent's life, its name space and its model
# session are its parent's to bound: the spawn tool through a real
# tools9p (tests/spawn/life.sh), subagents on a scripted model
# (tests/spawnfake.b):
#
#  - a subagent's model session is closed when it has answered (each
#    was left open until the model service restarted);
#  - its /tool is files of its own: no /tool/read of its parent's tool
#    server, no grant of its parent's listed, no /mnt, itself alone in
#    /prog (a child given read read its parent's files and last result
#    through /tool/read/ctl);
#  - a path the agent does not hold, or /mnt/llm, is refused, and so is
#    a timeout that does not fit, and a section refused after another:
#    each before any subagent is started;
#  - a tool whose effect needs the user's approval (sms, dial, task) is
#    not given to a subagent though the delegation budget holds it: a
#    subagent's calls are not seen by the coordinator that asks;
#  - a path the agent holds is granted;
#  - a subagent past its timeout is stopped: no request to its model
#    after, its session closed (it went on, up to fifty steps);
#  - one that goes without a result is an error (it was an empty
#    answer);
#  - a caller killed in its call does not leave an answer for another
#    request to take ("unexpected reply tag" from the mount);
#  - a subagent scheduled with every= keeps its name space (its tool
#    still lists its scratch seconds later), no more than eight are
#    scheduled at once, and when the tool server is killed they stop:
#    no request to the model after, sessions closed, and no process of
#    the spawn tool, a subagent or its servers left.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/tools9p.dis dis/veltro/tools/spawn.dis dis/veltro/tools/plan.dis dis/tests/spawnfake.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

T=tmp/spawn_life_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${SPAWN_KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
with_timeout 110 "$EMU" -r"$ROOT" /dis/sh.dis -c "bind -c /$T /tmp; /tests/spawn/life.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$ROOT/$T/$1" 2>/dev/null || true; }
n() { f "$1" | grep -c "$2" || true; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; tail -30 "$LOG"; exit 1; }

if f r.text | grep -q 'answer of text' && f log.1 | grep -q 'ctl s0 close'; then
	pass "a subagent answers, and its model session is closed"
else
	fail "text: $(f r.text | head -3); close: $(n log.1 'ctl s0 close')"
fi

if f r.parentread | grep -q secret &&
   f r.probe | grep -q "'/tool/read' file does not exist" &&
   ! f r.probe | grep -q 'secret' &&
   ! f r.probe | grep -q '/usr/inferno' &&
   f r.probe | grep -q "cannot open /mnt: '/mnt' file does not exist" &&
   f r.probe | grep -q '^1 entries:' && f r.probe | grep -q 'PROBE DONE'; then
	pass "a subagent's /tool is its own: no tool of its parent's server, no /mnt, itself alone in /prog"
else
	fail "probe: $(f r.probe | tr '\n' '|' | cut -c1-900)"
fi

if f r.llm | grep -q "^error: path /mnt/llm is one of the agent's own services" &&
   f r.outside | grep -q "^error: path /usr/inferno is outside this agent's grants" &&
   f r.later | grep -q '^error: exec/shell subagents cannot receive path grants' &&
   f r.overflow | grep -q '^error: timeout too long' &&
   [ "$(n log.1 ' new ')" = "$(n log.2 ' new ')" ]; then
	pass "the model service, a path the agent does not hold, a later section and a timeout that does not fit are refused before any subagent is started"
else
	fail "llm: $(f r.llm | head -2); outside: $(f r.outside | head -2); later: $(f r.later | head -2); overflow: $(f r.overflow | head -2); sessions $(n log.1 ' new ') then $(n log.2 ' new ')"
fi

if f r.sms | grep -q '^error: tool sms may not be given to a subagent' &&
   f r.dial | grep -q '^error: tool dial may not be given to a subagent' &&
   f r.task | grep -q '^error: tool task may not be given to a subagent' &&
   [ "$(n log.1 ' new ')" = "$(n log.2 ' new ')" ]; then
	pass "sms, dial and task are not given to a subagent, though the budget holds them"
else
	fail "sms: $(f r.sms | head -2); dial: $(f r.dial | head -2); task: $(f r.task | head -2)"
fi

if f r.granted | grep -q 'secret'; then
	pass "a path the agent holds is granted"
else
	fail "granted: $(f r.granted | head -5)"
fi

s=$(f log.3 | sed -n 's/.* ask \(s[0-9]*\) 1 chatty.*/\1/p' | tail -1)
if f r.timeout | grep -q 'timed out after 2s and was stopped' && [ -n "$s" ] &&
   [ "$(n log.3 " ask $s ")" = "$(n log.4 " ask $s ")" ] && f log.4 | grep -q "ctl $s close"; then
	pass "a subagent past its timeout is stopped: no request to its model after, its session closed"
else
	fail "timeout: $(f r.timeout | head -2); session $s asked $(n log.3 " ask $s ") times, then $(n log.4 " ask $s "); closed $(n log.4 "ctl $s close")"
fi

if f r.killed | grep -q '^error: subagent ended without finishing its result'; then
	pass "a subagent that goes without a result is an error"
else
	fail "killed: '$(f r.killed | head -3)'"
fi

if f r.callkill | grep -q 'callkill: killed' && ! grep -q 'unexpected reply tag' "$LOG"; then
	pass "a caller killed in its call leaves no answer for another request"
else
	fail "callkill: $(f r.callkill); $(grep 'unexpected reply tag' "$LOG" | head -2)"
fi

s=$(f log.5 | sed -n 's/.* ask \(s[0-9]*\) 1 ticktool.*/\1/p' | tail -1)
late=$(f log.5 | grep " ask $s " | grep 'res=' | tail -1)
if f r.sched | grep -q '^scheduled: every 1000 ms, as process group [0-9]*; it ends with' && [ -n "$s" ] &&
   [ "$(n log.5 " ask $s ")" -ge 6 ] && echo "$late" | grep -q 'res=' &&
   ! echo "$late" | grep -q -E 'res=error|does not exist'; then
	pass "a scheduled subagent runs on, in a name space it can still use"
else
	fail "sched: $(f r.sched | head -2); session $s asked $(n log.5 " ask $s ") times; its last tool result: $late"
fi

if f r.cap1 | grep -q 'scheduled: every 3600000 ms' && f r.cap2 | grep -q '^error: too many scheduled subagents: 6 are running and at most 8 may'; then
	pass "no more than eight subagents are scheduled at once"
else
	fail "cap1: $(f r.cap1 | head -2); cap2: $(f r.cap2 | head -2)"
fi

left=$(f ps.end | grep -c -E 'ToolSpawn|SubAgent|AgentLib|Cowfs|Tools9p' || true)
closed=$(f log.7 | grep -c 'ctl s[0-9]* close' || true)
opened=$(n log.7 ' new ')
if f ps.sched | grep -q ToolSpawn && [ "$left" = 0 ] &&
   [ "$(n log.6 ' ask ')" = "$(n log.7 ' ask ')" ] && [ "$closed" = "$opened" ]; then
	pass "with the tool server gone its subagents stop: no request after, $closed of $opened sessions closed, no process left"
else
	fail "after the tool server: $left processes left ($(f ps.end | grep -E 'ToolSpawn|SubAgent|AgentLib|Cowfs|Tools9p' | head -5 | tr '\n' '|')); asks $(n log.6 ' ask ') then $(n log.7 ' ask '); $closed of $opened sessions closed"
fi

if [ $failed != 0 ]; then
	echo "--- emulator output:"
	tail -30 "$LOG"
	exit 1
fi
echo "spawn_life_test: PASS"

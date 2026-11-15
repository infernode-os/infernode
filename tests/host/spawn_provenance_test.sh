#!/bin/sh
#
# spawn_provenance_test.sh — where the install requires auditing
# (/usr/inferno/audit/on), a subagent is recorded or is not started: the
# spawn tool through a real tools9p, auditfs and ventisrv
# (tests/spawn/provenance.sh), the subagent on a scripted model
# (tests/spawnfake.b):
#
#  - with the sink mounted and the store up, the chain has the spawn
#    and what the child was granted (spawn, subcaps), the child's own
#    restriction (a second nsrestrict) and its own trajectory
#    (substart, subtask, subllm, subdone);
#  - with no sink the tool call is refused, and with the sink back and
#    the store gone the spawn is refused: in neither is a model session
#    opened;
#  - with the switch off and no sink it runs, as it always did.
#
# A spawn runs in a tool call's name space, which has no /usr and had no
# /mnt/audit: it asked there for the switch and the sink, found neither,
# and every subagent ran with nothing of it in the chain, required or
# not.  The tool server now says whether auditing is required
# (/tool/meta/audit) and binds the sink into the spawn tool's call.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/tools9p.dis dis/veltro/tools/spawn.dis dis/auditfs.dis dis/ventisrv.dis dis/tests/spawnfake.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 (to find a free port) not found"; exit 77; }
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

T=tmp/spawn_provenance_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${SPAWN_KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
with_timeout 90 "$EMU" -r"$ROOT" /dis/sh.dis -c "bind -c /$T /tmp; port=$PORT; /tests/spawn/provenance.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$ROOT/$T/$1" 2>/dev/null || true; }
n() { f "$1" | grep -c "$2" || true; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; tail -30 "$LOG"; exit 1; }

if f meta.recorded | grep -qx required && f r.recorded | grep -q 'answer of text' &&
   f chain.recorded | grep -q ' veltro spawn [0-9a-f]* child=sub-' &&
   f chain.recorded | grep -q ' veltro subcaps [0-9a-f]* child=sub-' &&
   [ "$(n chain.recorded ' veltro nsrestrict ')" -ge 3 ] &&
   f chain.recorded | grep ' veltro nsrestrict ' | tail -1 | grep -q ' activity=0 ' &&
   f chain.recorded | grep -q ' veltro substart [0-9a-f]* agent=sub-' &&
   f chain.recorded | grep -q ' veltro subtask [0-9a-f]* agent=sub-' &&
   f chain.recorded | grep -q ' veltro subllm [0-9a-f]* agent=sub-' &&
   f chain.recorded | grep -q ' veltro subdone [0-9a-f]* agent=sub-.*status=done' &&
   ! f chain.recorded | grep -q 'content=unstored'; then
	pass "required and recordable: the spawn, the child's grants, its restriction and its trajectory are in the chain"
else
	fail "recorded: meta '$(f meta.recorded)'; result: $(f r.recorded | head -2); chain events: $(f chain.recorded | sed 's/^[^ ]* [^ ]* \([a-z]* [a-z]*\).*/\1/' | tr '\n' ',')"
fi

if f err.nosink | grep -q 'namespace restriction failed' && grep -q 'required audit sink unavailable' "$LOG" &&
   [ "$(n log.nosink ' new ')" = "$(n log.recorded ' new ')" ]; then
	pass "required with no sink: the tool call is refused and nothing is started"
else
	fail "nosink: $(f err.nosink | head -2); result: $(f r.nosink | head -2); sessions $(n log.recorded ' new ') then $(n log.nosink ' new ')"
fi

if f r.killstore | grep -q kill &&
   f r.nostore | grep -q '^error: auditing is required but the provenance store cannot be reached' &&
   [ "$(n log.nostore ' new ')" = "$(n log.recorded ' new ')" ]; then
	pass "required with no content store: the spawn is refused and nothing is started"
else
	fail "nostore: $(f r.nostore | head -2); store: $(f r.killstore | head -1); sessions $(n log.recorded ' new ') then $(n log.nostore ' new ')"
fi

if f meta.off | grep -qx off && f r.off | grep -q 'answer of text'; then
	pass "not required, no sink: a subagent runs"
else
	fail "off: meta '$(f meta.off)'; result: $(f r.off | head -2)"
fi

if [ $failed != 0 ]; then
	echo "--- emulator output:"
	tail -30 "$LOG"
	exit 1
fi
echo "spawn_provenance_test: PASS"

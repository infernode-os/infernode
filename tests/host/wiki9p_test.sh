#!/bin/bash
#
# wiki9p, the LLM-maintained wiki (/mnt/wikia), end to end against a
# scripted model (tests/host/wiki9p/mock_model.py): the real llmsrv,
# wikifs over a scratch copy of services/wikia, and wiki9p over both.
#
#   - an ingest whose reply has two pages writes both, and both are
#     listed at once (wikifs reloads its map after adding a page);
#   - a second ingest updates a page, keeping the first version;
#   - the result of ctl and query is read on the fid that wrote the
#     command, and the read waits for it (it used to come back empty);
#   - status answers with nothing bound on raw (it used to deadlock
#     listing wiki9p's own directory from the serve loop);
#   - the agent's wiki tool, through tools9p, gets the answer.
#
# Run from the project root: tests/host/wiki9p_test.sh

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

for f in dis/llmsrv.dis dis/wikifs.dis dis/veltro/wiki9p.dis dis/veltro/tools9p.dis dis/veltro/tools/wiki.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }

WORK=$(mktemp -d)
SCRATCH="tmp/wiki9ptest.$$"
SCRIPT="tests/inferno/.wiki9ptest.$$.sh"
SERVER_PID=
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	rm -rf "$WORK" "$ROOT/$SCRATCH" "$ROOT/$SCRIPT"
}
trap cleanup EXIT

mkdir -p "$ROOT/$SCRATCH/src"
cp -r "$ROOT/services/wikia" "$ROOT/$SCRATCH/store"
echo 'Alpha report: Project X is led by Alice, started 2024.' > "$ROOT/$SCRATCH/src/alpha.md"
echo 'Beta memo: Bob took over Project X from Alice in 2026.' > "$ROOT/$SCRATCH/src/beta.md"

python3 -I "$ROOT/tests/host/wiki9p/mock_model.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
for i in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || { echo "FAIL: mock model did not start"; exit 1; }
PORT=$(cat "$WORK/port")

# A command and its result on one fid: {echo cmd >[1=0]; cat} <>[0] file
cat > "$ROOT/$SCRIPT" <<INFERNO
load std
path=(/dis /dis/veltro .)
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
mkdir -p /mnt/wiki
mount {wikifs -d /$SCRATCH/store} /mnt/wiki
/dis/veltro/wiki9p.dis &
while {! ftest -e /mnt/wikia/ctl} {sleep 1}
while {! ftest -e /mnt/llm/new} {sleep 1}
echo '== status'
cat /mnt/wikia/status
bind /$SCRATCH/src /mnt/wikia/raw
echo '== ingest alpha'
{echo ingest /mnt/wikia/raw/alpha.md >[1=0]; cat} <>[0] /mnt/wikia/ctl
echo
echo '== pages 1'
ls /mnt/wiki
echo '== ingest beta'
{echo ingest /mnt/wikia/raw/beta.md >[1=0]; cat} <>[0] /mnt/wikia/ctl
echo
echo '== project x'
cat /mnt/wiki/project_x/current
echo
echo '== versions'
ls /mnt/wiki/project_x
echo '== query'
{echo 'Who leads Project X?' >[1=0]; cat} <>[0] /mnt/wikia/query
echo
echo '== lint'
{echo lint >[1=0]; cat} <>[0] /mnt/wikia/ctl
echo '== tool'
/dis/veltro/tools9p.dis wiki &
while {! ftest -e /tool/wiki} {sleep 1}
echo 'query Who leads Project X?' > /tool/wiki/ctl
cat /tool/wiki/ctl
echo
echo '== end'
INFERNO

LOG="$WORK/emu.log"
"$EMU" -r"$ROOT" /dis/sh.dis "/$SCRIPT" </dev/null > "$LOG" 2>&1 &
EMU_PID=$!
for i in $(seq 240); do grep -q '^== end' "$LOG" && break; sleep 0.5; done
kill -9 "$EMU_PID" 2>/dev/null; wait "$EMU_PID" 2>/dev/null

section() {	# the lines of one == section
	awk -v s="== $1" '$0 == s {on = 1; next} /^== / {on = 0} on' "$LOG"
}

PASSED=0; FAILED=0
check() {	# description, then a command that must succeed
	local what="$1"; shift
	if "$@"; then echo "PASS: $what"; PASSED=$((PASSED+1))
	else echo "FAIL: $what"; FAILED=$((FAILED+1)); fi
}
has() { section "$1" | grep -q -- "$2"; }
hasnot() { ! section "$1" | grep -q -- "$2"; }

grep -q '^== end' "$LOG" || { echo "FAIL: the run did not finish"; cat "$LOG"; exit 1; }

check "status answers with nothing bound on raw" has status 'raw sources: (none bound)'
check "ingest reports both pages of one reply" has 'ingest alpha' 'created/updated 2 pages'
check "both pages are listed at once" has 'pages 1' '/mnt/wiki/alice'
check "the first page is listed" has 'pages 1' '/mnt/wiki/project_x'
check "an update ingest reports its pages" has 'ingest beta' 'created/updated 2 pages'
check "the updated page holds the new text" has 'project x' 'led by Bob'
check "the update replaces the old text" hasnot 'project x' 'led by Alice\.'
versions() { [ "$(section versions | grep -c '/project_x/[0-9]')" = 2 ]; }
check "the page keeps both versions" versions
check "a query's answer is read on its fid" has query 'Bob leads Project X \[Project X\]\.'
check "lint's report is read on its fid" has lint 'CONTRADICTIONS: none'
check "the wiki tool gets the answer through tools9p" has tool 'Bob leads Project X'
check "each request is a fresh session (system and user only)" \
	sh -c "! grep -v '\"messages\": 2,' '$WORK/req.log' | grep -q ."

if [ "$FAILED" -gt 0 ]; then
	echo "--- emu output"; cat "$LOG"
	echo "--- model requests"; cat "$WORK/req.log"
fi
echo "Total: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]

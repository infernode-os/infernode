#!/bin/sh
#
# veltro_edit_bench.sh — how often the agent fixes a known bug, and at
# what cost.
#
# A measure, not a test: it calls a real model, and reports.  Real Limbo
# functions from the tree each have one bug planted (bench/mutate.py:
# a comparison inverted, && and || exchanged, an off-by-one), and the
# agent is told the file, the function and the kind of change, not the
# line.  A task is solved when the file the agent leaves (its staged
# copy) is the original, byte for byte.
#
#	VELTRO_LIVE_URL=http://127.0.0.1:11435/v1 tests/host/veltro_edit_bench.sh
#	BENCH_N=20 BENCH_SEED=7 VELTRO_LIVE_MODEL=sonnet ... veltro_edit_bench.sh
#	BENCH_ROOT=/other/tree ...	run another tree's build (its dis/), as is
#
# It prints one line a task (solved, steps, tool calls, seconds) and the
# totals; BENCH_OUT=<file> keeps them as tab-separated lines.

set -e
. "$(dirname "$0")/common.sh"
set -u

[ -n "${VELTRO_LIVE_URL:-}" ] || { echo "SKIP: VELTRO_LIVE_URL not set (this calls a real model)"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
TREE=${BENCH_ROOT:-$ROOT}
MODEL=${VELTRO_LIVE_MODEL:-haiku}
N=${BENCH_N:-12}
SEED=${BENCH_SEED:-1}
HERE="$(cd "$(dirname "$0")" && pwd)"

WORK="$(mktemp -d)"
EMU_PID=
SCRIPT=
cleanup() {
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	rm -rf "$TREE/usr/bench" "$TREE/tmp/veltro/cow"
	[ "${KEEP:-0}" = 1 ] && echo "work kept in $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

# The functions the bugs go in: commands and libraries a reader can
# follow without the rest of the tree.
SRCS="appl/cmd/wc.b appl/cmd/cat.b appl/cmd/sort.b appl/cmd/uniq.b appl/cmd/tail.b
appl/cmd/grep.b appl/cmd/tr.b appl/cmd/basename.b appl/cmd/cmp.b appl/cmd/comm.b
appl/cmd/fmt.b appl/cmd/strings.b appl/lib/arg.b appl/lib/strinttab.b appl/lib/names.b"
set --
for f in $SRCS; do [ -f "$ROOT/$f" ] && set -- "$@" "$ROOT/$f"; done
n=$(python3 -I "$HERE/bench/mutate.py" "$SEED" "$N" "$WORK/tasks" "$@")

rm -rf "$TREE/usr/bench" "$TREE/tmp/veltro/cow"
mkdir -p "$TREE/usr/bench"
for k in $(seq 0 $((n - 1))); do
	mkdir -p "$TREE/usr/bench/$k"
	cp "$WORK/tasks/$k/work/"* "$TREE/usr/bench/$k/"
done

SCRIPT="$TREE/tests/inferno/.veltro_edit_bench.$$.sh"
{
	cat <<EOF
#!/dis/sh.dis
load std
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u $VELTRO_LIVE_URL -M $MODEL &
sleep 1
/dis/veltro/tools9p.dis read list grep find edit write &
sleep 1
/dis/veltro/veltrosrv.dis -p /usr/bench
EOF
	for k in $(seq 0 $((n - 1))); do
		task=$(cat "$WORK/tasks/$k/task" | sed "s/'/''/g")
		cat <<EOF
id=\`{cat /mnt/veltro/new}
echo '@@ task $k'
echo '$task' > /mnt/veltro/\$id/input
cat /mnt/veltro/\$id/text > /dev/null
grep 'turn done|^tool [a-z]*: args' /mnt/veltro/\$id/log
grep -i 'model unavailable|did not answer' /mnt/veltro/\$id/text
echo '@@ end $k'
echo close > /mnt/veltro/\$id/ctl
EOF
	done
	echo 'echo DRIVER_DONE'
} > "$SCRIPT"

LOG="$WORK/emu.log"
start=$(date +%s)
"$EMU" -c1 -r"$TREE" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" > "$LOG" 2>&1 &
EMU_PID=$!
while kill -0 "$EMU_PID" 2>/dev/null; do
	grep -q '^DRIVER_DONE$' "$LOG" 2>/dev/null && break
	[ $(( $(date +%s) - start )) -gt $((n * 300)) ] && break
	sleep 1
done
kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true
EMU_PID=

# The staged copy of a file, where the agent's writes are; the file as it
# was given, when it wrote nothing.
staged() {	# k name
	for o in "$TREE"/tmp/veltro/cow/*/; do
		[ -f "$o/$1/$2" ] && { echo "$o/$1/$2"; return; }
	done
	echo "$TREE/usr/bench/$1/$2"
}

solved=0; steps=0; calls=0
[ -n "${BENCH_OUT:-}" ] && : > "$BENCH_OUT"
for k in $(seq 0 $((n - 1))); do
	name=$(ls "$WORK/tasks/$k/orig")
	sec=$(awk -v s="@@ task $k" -v e="@@ end $k" '$0==s{p=1;next} $0==e{p=0} p' "$LOG")
	st=$(echo "$sec" | sed -n 's/.*turn done.*steps=\([0-9]*\).*/\1/p' | tail -1)
	nc=$(echo "$sec" | grep -c '^tool [a-z]*: args' || true)
	ok=0
	cmp -s "$(staged "$k" "$name")" "$WORK/tasks/$k/orig/$name" && ok=1
	solved=$((solved + ok)); steps=$((steps + ${st:-0})); calls=$((calls + nc))
	printf '%s\t%s\t%s\t%s\tsteps=%s\tcalls=%s\n' "$k" "$(cat "$WORK/tasks/$k/kind")" "$name" \
		"$([ $ok = 1 ] && echo solved || echo unsolved)" "${st:-?}" "$nc" | tee -a "${BENCH_OUT:-/dev/null}"
done
elapsed=$(( $(date +%s) - start ))
echo "veltro_edit_bench: $solved/$n solved, $steps steps, $calls tool calls, ${elapsed}s (model $MODEL, seed $SEED, tree $TREE)"

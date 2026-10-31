#!/bin/sh
# A failed name lookup must not leak kernel memory.
#
# namec() parses the name into an Elemlist -- a copy of the string and
# two index arrays, three blocks -- after its waserror(), and the handler
# frees them. The struct was initialised to nil before waserror() and
# was not volatile, so clang folded the nils into the handler and the
# three free(nil) calls vanished: every lookup that failed leaked ~400
# bytes of main pool. Measured at 3 blocks per failing `ftest -e`,
# repeatable, in an emulator that had been "flat" in every soak because
# nothing in those soaks ever missed. Agents probing optional files,
# shell PATH misses under a 9P-served /dis, a poller waiting for a file
# to appear -- all of them paid it. The bare-metal kernel shares the
# code (os/port/chan.c) and had the same bug in devwalk and mntwalk on
# top; those were fixed the same way and verified from the compiler's
# output only -- a runtime leak check on the kernel is still an open gap.
#
# Runs 100 successful lookups so lazily loaded modules are resident,
# then 1000 misses in a kernel device (#c) and 1000 under a 9P mount
# (memfs), reading /dev/memory between. Compares the main pool's live
# block count (nalloc - nfree), not bytes: the chan freelist absorbs the
# first few dozen misses and byte counts move with arena growth.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in ftest memfs mkdir; do
	[ -f "$ROOT/dis/$f.dis" ] || { echo "SKIP: /dis/$f.dis not built"; exit 77; }
done

mkdir -p "$ROOT/tmp"
SCRIPT="$ROOT/tmp/walk_leak_test.$$.sh"
LOG="$(mktemp)"
trap 'rm -f "$SCRIPT" "$LOG"; rm -rf "$ROOT/tmp/walk_leak.$$"' EXIT HUP INT TERM

# Nested loops rather than seq: no pipe, no extra process per iteration.
L='for(i in 1 2 3 4 5 6 7 8 9 10){ for(j in 1 2 3 4 5 6 7 8 9 10){ for(k in 1 2 3 4 5 6 7 8 9 10){'
E='} } }'
cat >"$SCRIPT" <<EOF
load std
mkdir -p /tmp/walk_leak.$$
memfs /tmp/walk_leak.$$
for(i in 1 2 3 4 5 6 7 8 9 10){ for(j in 1 2 3 4 5 6 7 8 9 10){ ftest -e /dev/null } }
echo '@@MEM warm'
cat /dev/memory
$L ftest -e '#c/nonexistent' $E
echo '@@MEM device'
cat /dev/memory
$L ftest -e /tmp/walk_leak.$$/nonexistent $E
echo '@@MEM mount'
cat /dev/memory
echo '@@DONE'
EOF

SDL_VIDEODRIVER=dummy timeout 300 "$EMU" -c1 -r"$ROOT" sh "/tmp/$(basename "$SCRIPT")" >"$LOG" 2>&1
rc=$?
if ! emu_timeout_ok "$rc"; then
	echo "FAIL: emulator exited with rc=$rc"
	sed -n '1,40p' "$LOG"
	exit 1
fi
if ! grep -q '^@@DONE' "$LOG"; then
	echo "FAIL: script did not run to completion"
	sed -n '1,40p' "$LOG"
	exit 1
fi

# The main pool line is the first line of each /dev/memory read.
live() { awk '/ main$/ { n++; if (n == '"$1"') print $4 - $5 }' "$LOG"; }
m0="$(live 1)"; m1="$(live 2)"; m2="$(live 3)"
if [ -z "$m0" ] || [ -z "$m1" ] || [ -z "$m2" ]; then
	echo "FAIL: could not read three main pool samples"
	grep ' main$' "$LOG"
	exit 1
fi
d1=$((m1 - m0)); d2=$((m2 - m1))
echo "main pool live blocks: $m0 -> $m1 (+$d1, 1000 device misses) -> $m2 (+$d2, 1000 9P misses)"

# Before the fix each loop grew the pool by ~3000 blocks; the shell's
# own churn over 1000 iterations is under 50 once warmed up.
fails=0
if [ "$d1" -ge 300 ]; then
	echo "FAIL: failed lookups in a kernel device leak main pool memory (+$d1 blocks per 1000)"
	fails=$((fails + 1))
fi
if [ "$d2" -ge 300 ]; then
	echo "FAIL: failed lookups under a 9P mount leak main pool memory (+$d2 blocks per 1000)"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] || exit 1
echo "PASS: failed name lookups do not leak"

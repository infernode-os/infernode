#!/bin/sh
# Regression test: a type's compiled initialize/destroy code must be reused
# once the type is freed (#649).
#
# Hosted amd64 carves type code from 2 MB slabs that have to stay near the
# text segment (see typecom_alloc in comp-amd64.c), and for a long time
# freetypecode() in heap.c did nothing with it: every command run loaded a
# module, compiled its types into the slab and dropped them, and the slab
# only grew -- about 1.5 KB a command, 15 MB for ten thousand.
# freetypejit() now puts a freed block on a free list keyed by its size,
# which typecom() keeps in a header in front of the code, and the next type
# compiled reuses it.
#
# The arm64 twin of this test is arm64_jit_typecode_leak_test.sh.  Like it,
# this measures resident size: the same 4000 commands must not cost the JIT
# megabytes more than they cost the interpreter.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
set -u

[ "$OBJTYPE" = amd64 ] || { echo "SKIP: amd64 JIT test"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
[ -r /proc/self/status ] || { echo "SKIP: needs /proc/<pid>/status"; exit 77; }

# Source pin: enforced even where the measurement below has to skip.
fails=0
if ! grep -q '^freetypejit(Type \*t)' "$ROOT/libinterp/comp-amd64.c"; then
	echo "FAIL: comp-amd64.c does not define freetypejit()"
	fails=$((fails + 1))
fi
if [ "$(grep -c 'freetypejit(t);' "$ROOT/libinterp/heap.c")" -lt 2 ]; then
	echo "FAIL: heap.c does not release a type's JIT code on hosted amd64"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] || exit 1
echo "PASS: source contract (a freed type's JIT code is released on amd64)"

mkdir -p "$ROOT/tmp"
REPRO="$ROOT/tmp/amd64_jit_typecode_leak_repro.sh"
LOG="$(mktemp)"
trap 'rm -f "$REPRO" "$LOG"' EXIT HUP INT TERM

# The slab is mapped and zeroed 2 MB at a time, so resident size moves in
# 2 MB steps and the run has to be long enough to cross several: before the
# fix the 4000 commands measured here cost about 6 MB.
cat >"$REPRO" <<'EOF'
#!/dis/sh.dis

load std
path=(/dis .)

for (i in `{seq 1 100}) {
	cat /dev/null
	ls /dis/sh.dis > /dev/null
}
echo '@@LEAK mark early'
sleep 3
for (i in `{seq 1 2000}) {
	cat /dev/null
	ls /dis/sh.dis > /dev/null
}
echo '@@LEAK mark late'
sleep 60
echo '@@LEAK done'
EOF

# growth <cflag>: run the repro and print resident growth in kB between
# the two marks, or nothing if it could not be measured.
growth() {
	: >"$LOG"
	"$EMU" "$1" -r"$ROOT" /dis/sh.dis /tmp/amd64_jit_typecode_leak_repro.sh >"$LOG" 2>&1 &
	emupid=$!
	early=""
	late=""
	waited=0
	while [ "$waited" -lt 300 ]; do
		if [ -z "$early" ] && grep -q '@@LEAK mark early' "$LOG" 2>/dev/null; then
			sleep 1
			early="$(awk '/^VmRSS:/ { print $2 }' "/proc/$emupid/status" 2>/dev/null)"
		fi
		if grep -q '@@LEAK mark late' "$LOG" 2>/dev/null; then
			sleep 1
			late="$(awk '/^VmRSS:/ { print $2 }' "/proc/$emupid/status" 2>/dev/null)"
			break
		fi
		[ -d "/proc/$emupid" ] || break
		sleep 1
		waited=$((waited + 1))
	done
	kill -9 "$emupid" 2>/dev/null
	wait "$emupid" 2>/dev/null
	if [ -n "$early" ] && [ -n "$late" ] && [ "$early" -gt 0 ]; then
		echo $((late - early))
	fi
}

jit="$(growth -c1)"
if ! grep -q '^@@LEAK mark late$' "$LOG"; then
	echo "FAIL: repro did not reach the late mark under the JIT"
	sed -n '1,40p' "$LOG"
	exit 1
fi
interp="$(growth -c0)"
if [ -z "$jit" ] || [ -z "$interp" ]; then
	echo "SKIP: could not sample resident size (jit='$jit' interp='$interp')"
	exit 77
fi

# Whatever the interpreter grows by over the same commands is not type code,
# so the JIT is measured against that rather than against zero.  2 MB is one
# slab: noise, not a leak.
limit=$((interp + 2048))
echo "resident growth over 4000 commands: JIT ${jit} kB, interpreter ${interp} kB (limit ${limit} kB)"
if [ "$jit" -gt "$limit" ]; then
	echo "FAIL: the JIT grows more than the interpreter -- compiled type code is leaking"
	exit 1
fi

echo "PASS: a freed type's compiled code is reused"

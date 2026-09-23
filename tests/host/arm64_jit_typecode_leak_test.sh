#!/bin/sh
# Regression test: a type's compiled initialize/destroy code must be released
# when the type is freed.
#
# On hosted 64-bit builds the JIT maps that code rather than mallocs it, and
# for a long time nothing released it: heap.c skipped free() and said "this
# leaks type code on module unload".  It did.  A command run loads a module,
# compiles its types and drops them again, and each type left a page behind --
# about 52 KB a command on Linux/arm64, 52 MB for a thousand, in any
# long-running system that runs commands.  Hosted arm64 now unmaps it:
# typecom() keeps the mapping's length in a header in front of the code and
# freetypejit() unmaps by it.
#
# Adjacent anonymous mappings merge, so the leak never showed in a count of
# mappings (INFR-421's test, for module text).  It shows in resident size,
# which is what this measures: the same 400 commands must not cost megabytes.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
set -u

[ "$OBJTYPE" = arm64 ] || { echo "SKIP: arm64 JIT test"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
[ -r /proc/self/status ] || { echo "SKIP: needs /proc/<pid>/status"; exit 77; }

# Source pin: enforced even where the measurement below has to skip.
fails=0
if ! grep -q '^freetypejit(Type \*t)' "$ROOT/libinterp/comp-arm64.c"; then
	echo "FAIL: comp-arm64.c does not define freetypejit()"
	fails=$((fails + 1))
fi
if ! grep -q 'freetypejit(t);' "$ROOT/libinterp/heap.c"; then
	echo "FAIL: heap.c does not release a type's JIT code on arm64"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] || exit 1
echo "PASS: source contract (a freed type's JIT code is unmapped on arm64)"

mkdir -p "$ROOT/tmp"
REPRO="$ROOT/tmp/arm64_jit_typecode_leak_repro.sh"
LOG="$(mktemp)"
trap 'rm -f "$REPRO" "$LOG"' EXIT HUP INT TERM

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
for (i in `{seq 1 400}) {
	cat /dev/null
	ls /dis/sh.dis > /dev/null
}
echo '@@LEAK mark late'
sleep 60
echo '@@LEAK done'
EOF

"$EMU" -c1 -r"$ROOT" /dis/sh.dis /tmp/arm64_jit_typecode_leak_repro.sh >"$LOG" 2>&1 &
emupid=$!

sample() {
	awk '/^VmRSS:/ { print $2 }' "/proc/$emupid/status" 2>/dev/null
}

early=""
late=""
waited=0
while [ "$waited" -lt 300 ]; do
	if [ -z "$early" ] && grep -q '@@LEAK mark early' "$LOG" 2>/dev/null; then
		sleep 1
		early="$(sample)"
	fi
	if grep -q '@@LEAK mark late' "$LOG" 2>/dev/null; then
		sleep 1
		late="$(sample)"
		break
	fi
	[ -d "/proc/$emupid" ] || break
	sleep 1
	waited=$((waited + 1))
done
kill -9 "$emupid" 2>/dev/null
wait "$emupid" 2>/dev/null

if ! grep -q '^@@LEAK mark late$' "$LOG"; then
	echo "FAIL: repro did not reach the late mark"
	sed -n '1,40p' "$LOG"
	exit 1
fi
if [ -z "$early" ] || [ -z "$late" ] || [ "$early" -eq 0 ]; then
	echo "SKIP: could not sample resident size (early='$early' late='$late')"
	exit 77
fi

# 800 further commands leaked about 41 MB before the fix.  4 MB of headroom
# is far above allocator noise and far below that.
limit=$((early + 4096))
echo "resident size: after 200 commands=${early} kB, after 1000=${late} kB (limit ${limit} kB)"
if [ "$late" -gt "$limit" ]; then
	echo "FAIL: resident size grows with commands run -- compiled type code is leaking"
	exit 1
fi

echo "PASS: a freed type's compiled code is released"

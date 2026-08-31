#!/bin/sh
# Regression test for INFR-421: a compiled module's executable text must be
# released when the module is freed.
#
# freemod() skips free(m->prog) on amd64/arm64 because a compiled module's
# text is an mmap'd JIT mapping rather than pool memory.  Until the matching
# freejitcode() was added, nothing unmapped it, so every module load/unload
# cycle leaked one PROT_EXEC mapping for the life of the process.  Ordinary
# command execution drives that without bound (each `ls` reloads Ls), so an
# agent could exhaust vm.max_map_count (65530 by default) and the JIT's
# near-text address window.
#
# The test runs a fixed number of module reloads and asserts the emulator's
# executable-mapping count does not grow with them.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
set -u

[ "$OBJTYPE" = amd64 ] || { echo "SKIP: amd64 JIT test"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
[ -r /proc/self/maps ] || { echo "SKIP: needs /proc/<pid>/maps"; exit 77; }

# Source pin.  The behavioural check below needs a readable /proc/<pid>/maps
# for the emulator, which some sandboxes and yama ptrace_scope settings deny.
# These assertions have no such dependency, so the contract stays enforced
# even when the measurement has to skip.
fails=0
if ! grep -q 'freejitcode(m->prog, m->jitsize)' "$ROOT/libinterp/load.c"; then
	echo "FAIL: freemod() does not release compiled module text"
	fails=$((fails + 1))
fi
for c in comp-amd64 comp-arm64; do
	if ! grep -q '^freejitcode(void \*p, ulong size)' "$ROOT/libinterp/$c.c"; then
		echo "FAIL: $c.c does not define freejitcode()"
		fails=$((fails + 1))
	fi
done
if ! grep -q 'ulong	jitsize;' "$ROOT/include/interp.h"; then
	echo "FAIL: Module has no jitsize field to size the unmap with"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] || exit 1
echo "PASS: source contract (freemod releases JIT text on amd64/arm64)"

REPRO="$ROOT/tmp/amd64_jit_code_leak_repro.sh"
LOG="$(mktemp)"
trap 'rm -f "$REPRO" "$LOG"' EXIT HUP INT TERM

# Report the executable-mapping count at a low and a high reload count from
# inside one process, so the two samples are directly comparable.
cat >"$REPRO" <<'EOF'
#!/dis/sh.dis

load std
path=(/dis .)

for (i in `{seq 1 100}) {
	ls /dis > /dev/null
}
echo '@@LEAK mark early'
for (i in `{seq 1 400}) {
	ls /dis > /dev/null
}
echo '@@LEAK mark late'
# Stay alive so the host side can sample /proc/<pid>/maps at this point.
sleep 60
echo '@@LEAK done'
EOF

"$EMU" -c1 -r"$ROOT" /dis/sh.dis /tmp/amd64_jit_code_leak_repro.sh >"$LOG" 2>&1 &
emupid=$!

# emu rewrites its argv, so track the pid we spawned directly.
sample() {
	awk '$2 ~ /x/ { n++ } END { print n+0 }' "/proc/$emupid/maps" 2>/dev/null
}

early=""
late=""
waited=0
while [ "$waited" -lt 300 ]; do
	if [ -z "$early" ] && grep -q '@@LEAK mark early' "$LOG" 2>/dev/null; then
		early="$(sample)"
	fi
	if grep -q '@@LEAK mark late' "$LOG" 2>/dev/null; then
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
	echo "SKIP: could not sample executable mappings (early='$early' late='$late')"
	exit 77
fi

# 400 further reloads leaked ~400 mappings before the fix.  Allow generous
# headroom for legitimately resident modules and allocator noise, while
# still failing decisively on per-reload growth.
limit=$((early + 64))
echo "executable mappings: after 100 reloads=$early, after 500=$late (limit $limit)"
if [ "$late" -gt "$limit" ]; then
	echo "FAIL: JIT mappings grow with module reloads — compiled module text is leaking"
	exit 1
fi

echo "PASS: compiled module text is released on unload"

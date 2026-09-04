#!/bin/sh
# devfs_fsinfo_init_test.sh - INFR-421
#
# The host filesystem device (emu/port/devfs-posix.c) keeps its per-Chan
# state in an Fsinfo, allocated with smalloc().  smalloc() is emu's pool
# allocator and does NOT zero, so a recycled block arrives holding the
# previous occupant's bytes.  Fsinfo embeds a QLock (oq) that fsread()
# takes on every directory read, so a stale block meant qlock() either
# spun for ever on a non-zero use.val or wrote through a stale tail
# pointer:
#
#	SEGV: addr=aaaaaaaaaaaaaaca  PC in qlock+0x34
#
# A fresh arena is zero-filled by the host, so the fault only appeared
# once a long-running emu had recycled enough memory - an agent campaign
# churning namespace shadow directories, thousands of walks each
# allocating and freeing an Fsinfo.  The fix routes both allocation sites
# through fsinfoalloc(), which zeroes the struct.
#
# Part 1 is a source pin: it cannot observe behaviour, only that no call
# site bypasses the zeroing constructor.
# Part 2 is a contract test: it drives the walk/read/stat paths that
# allocate and free Fsinfo, so a constructor that stopped zeroing, or
# that dropped the fd = -1 default, fails here.

set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

DEVFS="$ROOT/emu/port/devfs-posix.c"
failures=0

fail() {
    echo "FAIL: $1"
    failures=$((failures + 1))
}

pass() {
    echo "PASS: $1"
}

[ -f "$DEVFS" ] || { echo "SKIP: $DEVFS not found"; exit 77; }

# --- Part 1: source pin ------------------------------------------------

# Every Fsinfo must come from the zeroing constructor.  Allow the one
# occurrence inside fsinfoalloc() itself.
bare=$(grep -c 'smalloc(sizeof(Fsinfo))' "$DEVFS" || true)
if [ "$bare" -eq 1 ]; then
    pass "single smalloc(sizeof(Fsinfo)) site"
else
    fail "expected exactly 1 smalloc(sizeof(Fsinfo)) (inside fsinfoalloc), found $bare"
fi

if grep -q 'memset(f, 0, sizeof(Fsinfo))' "$DEVFS"; then
    pass "fsinfoalloc zeroes the struct"
else
    fail "fsinfoalloc must zero Fsinfo - the QLock oq is used uninitialised otherwise"
fi

# Both call sites must use it: fsattach and fswalk.
sites=$(grep -c '= fsinfoalloc();' "$DEVFS" || true)
if [ "$sites" -eq 2 ]; then
    pass "fsattach and fswalk both use fsinfoalloc"
else
    fail "expected 2 fsinfoalloc() call sites (fsattach, fswalk), found $sites"
fi

if grep -q '^fsinfoalloc(void)' "$DEVFS"; then
    pass "fsinfoalloc defined"
else
    fail "fsinfoalloc definition not found"
fi

# --- Part 2: contract test -------------------------------------------

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }

mkdir -p "$ROOT/tmp"
SCRIPT="$ROOT/tmp/infr421-fsinfo.sh"
LOG="$ROOT/tmp/infr421-fsinfo.log"
CHURN="$ROOT/tmp/infr421-churn"

rm -rf "$CHURN" "$LOG"
mkdir -p "$CHURN"

# Nested tree shaped like the veltro shadow trees that exposed this:
# shadow/<a>/.veltro-ns/shadow/<b>/... Each level is a separate walk,
# so each read allocates a fresh Fsinfo.
i=1
while [ "$i" -le 12 ]; do
    d="$CHURN/$i/.veltro-ns/shadow/inner"
    mkdir -p "$d"
    echo "payload-$i" > "$d/file"
    i=$((i + 1))
done

# Exactly 10 bytes, for the stat assertion below.
printf '0123456789' > "$CHURN/statprobe"

cat > "$SCRIPT" <<'EOS'
#!/dis/sh.dis
load std

base = /tmp/infr421-churn

# Walk and read every level, repeatedly.  Each walk allocates a fresh
# Fsinfo and each directory read takes FS(c)->oq, so this is the path
# that faulted; the repetition recycles pool blocks.
for pass in 1 2 3 4 5 {
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 {
		ls $base >/dev/null
		ls $base/$i >/dev/null
		ls $base/$i/.veltro-ns >/dev/null
		ls $base/$i/.veltro-ns/shadow >/dev/null
		ls $base/$i/.veltro-ns/shadow/inner >/dev/null
	}
}

for i in 1 2 3 4 5 6 7 8 9 10 11 12 {
	got = `{cat $base/$i/.veltro-ns/shadow/inner/file}
	if {~ $got payload-^$i} {
		echo VERIFIED
	}
}

# Stat a file through a walked-but-unopened chan.  fsstat() consults
# FS(c)->fd when it is >= 0, so without the fd = -1 default it fstat()s
# descriptor 0 and reports emu's stdin instead of the file.
echo -n 'STATPROBE '
ls -l $base/statprobe

echo '=== SCRIPT DONE ==='
EOS

# emu never self-exits while a proc is backgrounded, so bound it and
# poll the log for the sentinel.
( "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tmp/infr421-fsinfo.sh" > "$LOG" 2>&1 ) &
emupid=$!

waited=0
while [ "$waited" -lt 60 ]; do
    if grep -q '=== SCRIPT DONE ===' "$LOG" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$emupid" 2>/dev/null; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done
kill -9 "$emupid" 2>/dev/null || true
wait "$emupid" 2>/dev/null || true

if grep -qE 'SEGV|panic:|Segmentation' "$LOG"; then
    fail "emulator faulted during directory churn:"
    grep -E 'SEGV|panic:|Segmentation' "$LOG" | head -5
else
    pass "no fault during directory churn"
fi

if grep -q '=== SCRIPT DONE ===' "$LOG"; then
    pass "directory churn completed (no spin in qlock)"
else
    fail "workload did not complete within 60s - see $LOG"
fi

verified=$(grep -c '^VERIFIED' "$LOG" 2>/dev/null || true)
if [ "$verified" -eq 12 ]; then
    pass "all 12 files read correctly through freshly walked chans"
else
    fail "expected 12 verified file reads, got $verified"
fi

# statprobe is 10 bytes.  With fd defaulting to 0 instead of -1, fsstat
# reports emu's stdin: size 0 and the wrong mode.
if grep -q '^STATPROBE .* 10 ' "$LOG"; then
    pass "stat through unopened chan reports the file (fd = -1 default held)"
else
    fail "stat reported the wrong file - Fsinfo fd default is not -1: $(grep '^STATPROBE' "$LOG" || echo 'no STATPROBE line')"
fi

if grep -q 'fsqid: top-bit dev' "$LOG"; then
    fail "fsqid saw a bogus dev - Fsinfo fields uninitialised"
else
    pass "no fsqid dev warnings"
fi

rm -rf "$CHURN" "$SCRIPT"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
exit 0

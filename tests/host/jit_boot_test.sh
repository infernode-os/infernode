#!/bin/bash
#
# JIT Boot Smoke Test
#
# Launches the emulator with -c1 (JIT enabled) through the full Lucifer
# boot sequence (skipping wm/logon for CI) and checks for crashes, heap
# corruption, and exception storms. Catches the four classes of JIT
# allocator bug fixed in 963d3a98, 51220b73, a8b3a357:
#   - exNomem from jitmalloc VMA exhaustion
#   - SIGSEGV from negative case-table count after failed compile
#   - SIGSEGV from NULL typecom init/destroy pointer
#   - alloc:D2B heap corruption
#
# Also catches intermittent boot-time nil-derefs (INFR-25). The crash
# at c95970a2 was ~13% flaky over a 60s wait; running the boot multiple
# times sharply increases detection. STRESS_RUNS controls the iteration
# count (default 3); each iteration kills the emu as soon as boot
# completes (lucifer: INIT seen) rather than waiting the full BOOT_WAIT.
#
# Environment:
#   STRESS_RUNS   number of boot iterations (default 3)
#   BOOT_WAIT     per-iteration ceiling in seconds (default 30)
#
# Exit 0 = pass, exit 1 = fail.
#

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMU="$ROOT/emu/Linux/o.emu"
STRESS_RUNS="${STRESS_RUNS:-3}"
BOOT_WAIT="${BOOT_WAIT:-30}"
BOOTSCRIPT=$(mktemp /tmp/jit-boot-script.XXXXXX)

if [[ ! -x "$EMU" ]]; then
    echo "SKIP: no Linux emulator at $EMU"
    exit 0
fi

# Create a headless boot script that skips wm/logon (no interactive login
# possible in CI) but runs everything else: tools9p, luciuisrv, lucifer.
sed 's/^wm\/logon/#wm\/logon  # skipped for CI/' \
    "$ROOT/lib/lucifer/boot.sh" > "$BOOTSCRIPT"
# Copy into emu root so the emu can see it
cp "$BOOTSCRIPT" "$ROOT/tmp_jit_boot_test.sh"

cleanup() {
    rm -f "$BOOTSCRIPT" "$ROOT/tmp_jit_boot_test.sh"
}
trap cleanup EXIT

echo "JIT boot smoke test (stress=$STRESS_RUNS, wait=${BOOT_WAIT}s)..."

# Run one boot iteration. Sets RUN_RESULT to PASS/FAIL and leaves the
# full boot log at $LOG. Kills the emu as soon as either lucifer: INIT
# or a crash marker is seen so iterations cost ~5s instead of the full
# BOOT_WAIT — letting CI run several without inflating wall time.
run_one_boot() {
    local log=$1
    "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m \
        -r"$ROOT" sh -l /tmp_jit_boot_test.sh \
        > "$log" 2>&1 < /dev/null &
    local emu_pid=$!

    local elapsed=0
    local deadline=$((BOOT_WAIT * 2))   # tick is 0.5s
    while [[ $elapsed -lt $deadline ]]; do
        if grep -qE '\] Broken: |exNomem|SIGSEGV|alloc:D2B|panic:|POOL CORRUPTION' "$log" 2>/dev/null; then
            break
        fi
        if grep -q 'lucifer: INIT' "$log" 2>/dev/null; then
            break
        fi
        if ! kill -0 $emu_pid 2>/dev/null; then
            break
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done

    kill -9 $emu_pid 2>/dev/null || true
    wait $emu_pid 2>/dev/null || true
}

# Check the log of one iteration. Sets RUN_FAIL=1 on any failure and
# prints diagnostics. The full log is dumped at the call site only when
# every iteration completes — keeps CI output compact for the common
# happy path.
check_one_boot() {
    local log=$1
    local iter=$2
    RUN_FAIL=0

    for pat in "exNomem" "SIGSEGV" "alloc:D2B" "panic:" "POOL CORRUPTION"; do
        if grep -q "$pat" "$log"; then
            echo "FAIL[run $iter]: found '$pat' in boot log"
            grep "$pat" "$log" | head -3
            RUN_FAIL=1
        fi
    done

    local tools
    tools=$(grep -c 'tools9p\[/tool\]: loaded' "$log" || true)
    if [[ "$tools" -lt 12 ]]; then
        echo "FAIL[run $iter]: only $tools/12 tools9p plugins loaded"
        RUN_FAIL=1
    fi

    if ! grep -q "lucifer: INIT" "$log"; then
        echo "FAIL[run $iter]: Lucifer did not initialize"
        RUN_FAIL=1
    fi

    if grep -q '\[Sh\] Broken:' "$log"; then
        echo "FAIL[run $iter]: boot shell died"
        grep '\[Sh\] Broken:' "$log"
        RUN_FAIL=1
    fi

    # Catches intermittent nil-derefs in wallet9p, factotum, lucibridge
    # etc (INFR-25). [Sh] death is most critical (stops tools9p loading)
    # but any module crash during boot is a real bug.
    if grep -qE '\] Broken: "dereference of nil"' "$log"; then
        if ! grep -q '\[Sh\] Broken: "dereference of nil"' "$log"; then
            echo "FAIL[run $iter]: module crashed during boot (nil deref)"
            grep -E '\] Broken: "dereference of nil"' "$log"
            RUN_FAIL=1
        fi
    fi
}

FAIL=0
FAILED_LOG=""
for ((i = 1; i <= STRESS_RUNS; i++)); do
    LOG=$(mktemp /tmp/jit-boot-test.XXXXXX)
    run_one_boot "$LOG"
    check_one_boot "$LOG" "$i"
    if [[ "$RUN_FAIL" -ne 0 ]]; then
        FAIL=1
        # Keep the first failing log for diagnostics; discard subsequent.
        if [[ -z "$FAILED_LOG" ]]; then
            FAILED_LOG="$LOG"
        else
            rm -f "$LOG"
        fi
    else
        MODS=$(grep -c '^JIT compiled ' "$LOG" || true)
        TOOLS=$(grep -c 'tools9p\[/tool\]: loaded' "$LOG" || true)
        echo "PASS[run $i]: $MODS modules JIT-compiled, $TOOLS tools loaded"
        rm -f "$LOG"
    fi
done

if [[ "$FAIL" -ne 0 ]]; then
    # Dump the full boot log so the failing shell command is visible in CI.
    # tail -20 was not enough to localise [Sh] Broken: messages — see INFR-25.
    echo "--- full boot log (first failing run) ---"
    cat "$FAILED_LOG"
    echo "--- end boot log ---"
    rm -f "$FAILED_LOG"
fi

exit $FAIL

#!/bin/bash
#
# tests/host/sel4_test.sh
#
# The seL4 target (docs/SEL4.md): build its system image with the pinned
# Microkit SDK (tools/sel4/fetch.sh, os/sel4/build.sh) and boot it under
# QEMU's virt machine, asserting on the serial console: seL4 reaches user
# space, Microkit's monitor starts, and the component reports.
#
# Also checks the pin: a tarball whose hash is not the manifest's is
# refused and not unpacked.
#
# Needs clang, ld.lld and curl (or a cached SDK); qemu-system-aarch64 for
# the boot, which is skipped without it.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASSED=0; FAILED=0; SKIPPED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }
skip() { echo "SKIP: $1"; SKIPPED=$((SKIPPED+1)); }
finish() { echo ""; echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"; [ "$FAILED" -eq 0 ]; exit $?; }

for t in clang ld.lld; do
	command -v $t >/dev/null 2>&1 || { skip "$t not installed"; finish; }
done

# The pin: a tarball that is not the manifest's is refused.
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/tools/sel4" "$SCRATCH/tmp/sel4"
cp "$ROOT/tools/sel4/fetch.sh" "$SCRATCH/tools/sel4/"
cp "$ROOT/tools/sel4/manifest.txt" "$SCRATCH/tools/sel4/"
URL="$(sed -n 's/^url //p' "$ROOT/tools/sel4/manifest.txt")"
echo "not the SDK" > "$SCRATCH/tmp/sel4/$(basename "$URL")"
"$SCRATCH/tools/sel4/fetch.sh" >/dev/null 2>"$SCRATCH/err"; st=$?
if [ $st -eq 1 ] && grep -q 'manifest says' "$SCRATCH/err" && [ ! -d "$SCRATCH/tmp/sel4/sdk" ]; then
	pass "a tarball not matching the manifest is refused and not unpacked"
else
	fail "a bad tarball: status $st, $(cat "$SCRATCH/err")"
fi

IMG="$("$ROOT/os/sel4/build.sh" qemu_virt_aarch64 debug 2>"$SCRATCH/build.err")"
if [ -f "$IMG" ]; then
	pass "system image built: ${IMG#$ROOT/}"
else
	fail "build: $(tail -5 "$SCRATCH/build.err")"; finish
fi

QEMU="$(command -v qemu-system-aarch64 2>/dev/null)"
[ -n "$QEMU" ] || { skip "qemu-system-aarch64 not installed"; finish; }

LOG="$SCRATCH/serial.log"
"$QEMU" -machine virt,virtualization=on -cpu cortex-a53 -m size=2G \
	-display none -monitor none -serial "file:$LOG" \
	-device loader,file="$IMG",addr=0x70000000,cpu-num=0 </dev/null &
QPID=$!
for _ in $(seq 1 60); do
	grep -q 'inferno component started' "$LOG" 2>/dev/null && break
	sleep 0.5
done
kill $QPID 2>/dev/null; wait $QPID 2>/dev/null

check() { if grep -q "$1" "$LOG"; then pass "$2"; else fail "$2 (no '$1' on the console)"; fi; }
check 'Booting all finished, dropped to user space' "seL4 reaches user space"
check 'MON|INFO: Microkit Monitor started' "Microkit's monitor starts"
check 'sel4: inferno component started' "the component runs and reports"
[ "$FAILED" -eq 0 ] || { echo "--- console:"; tr -d '\r' < "$LOG" | tail -30; }
finish

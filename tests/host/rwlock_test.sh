#!/bin/bash
#
# tests/host/rwlock_test.sh
#
# os/port/qlock.c's RWlock (the bare-metal kernel's) on the host, under
# real concurrency (tests/host/rwlock/rwlocktest.c: threads as Procs,
# sched() and ready() a semaphore each, the structs taken from
# os/port/portdat.h):
#
#   - canrlock never fails while no writer holds or waits, however many
#     readers pass through rlock beside it. It used to punt whenever it
#     could not take the lock's x at once, which every reader takes for a
#     moment, and os/ip drops a packet when canrlock fails: an ICMP echo
#     over loopback was lost while TCP used the same interface (bcm2837
#     CI, its reader then blocked for good).
#   - with writers too, a writer is alone, readers never see one inside,
#     both sides make progress and the lock ends idle.
#
# No emulator or cross compiler is needed.
#
# Run from project root: ./tests/host/rwlock_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# the structs, as the kernel has them
awk '/^struct QLock$/,/^};/; /^struct RWlock$/,/^};/' "$ROOT/os/port/portdat.h" >"$TMP/structs.h"
grep -q writers "$TMP/structs.h" || { echo "FAIL: no struct RWlock with writers in os/port/portdat.h"; exit 1; }
grep -v '^#include' "$ROOT/os/port/qlock.c" >"$TMP/qlock_body.c"
cp "$ROOT/tests/host/rwlock/rwlocktest.c" "$TMP/"

if ! $CC -O2 -g -w -pthread -I"$TMP" -o "$TMP/rwlocktest" "$TMP/rwlocktest.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: rwlocktest does not compile"
	exit 1
fi
if "$TMP/rwlocktest"; then
	echo "rwlock: ALL PASS"
	exit 0
fi
echo "rwlock: FAILED"
exit 1

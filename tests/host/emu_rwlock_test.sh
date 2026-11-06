#!/bin/bash
#
# tests/host/emu_rwlock_test.sh
#
# emu/port/lock.c's RWlock (the emulator's) on the host, under real
# concurrency (tests/host/emu_rwlock/rwlocktest.c: threads as Procs,
# osblock() and osready() a semaphore each as emu's are, the structs
# taken from the platform's lib9.h):
#
#   - canrlock never fails while no writer holds or waits, however many
#     readers pass through rlock beside it. It used to punt whenever it
#     could not take the lock's x at once, which every reader takes for a
#     moment, so devcons's kernel print went to the console instead of
#     /dev/kprint while another reader held the lock.
#   - with writers too, a writer is alone, readers never see one inside,
#     both sides make progress and the lock ends idle.
#   - a writer holding the lock, and one waiting behind readers, make
#     canrlock refuse; with them gone it takes the lock again.
#   - every platform's lib9.h has the RWLock lock.c now needs.
#
# tests/host/rwlock_test.sh does the same for the bare-metal kernel's
# os/port/qlock.c. No emulator is needed.
#
# Run from project root: ./tests/host/emu_rwlock_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

# every lib9.h's RWLock has the writer count
bad=0
for h in "$ROOT"/*/*/include/lib9.h; do
	grep -q '^struct RWLock' "$h" || continue
	if ! awk '/^struct RWLock$/,/^} RWLock;/' "$h" | grep -q '[[:space:]]writers;'; then
		echo "FAIL: ${h#$ROOT/}: struct RWLock has no writers"
		bad=1
	fi
done
[ $bad = 0 ] || exit 1

case "$(uname -s)" in
Darwin)	sys=MacOSX ;;
*)	sys=Linux ;;
esac
case "$(uname -m)" in
x86_64|amd64)	arch=amd64 ;;
aarch64|arm64)	arch=arm64 ;;
riscv64)	arch=riscv64 ;;
*)		arch=amd64 ;;
esac
LIB9="$ROOT/$sys/$arch/include/lib9.h"
[ -f "$LIB9" ] || LIB9="$ROOT/Linux/amd64/include/lib9.h"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# the structs, as emu has them
{
	echo 'typedef struct QLock QLock;'
	awk '/^struct Lock \{$/,/^} Lock;/ { if(/^struct Lock/) printf "typedef "; print }
	     /^struct QLock$/,/^};/
	     /^struct RWLock$/,/^} RWLock;/ { if(/^struct RWLock/) printf "typedef "; print }' "$LIB9"
} >"$TMP/structs.h"
grep -q writers "$TMP/structs.h" || { echo "FAIL: no struct RWLock with writers in ${LIB9#$ROOT/}"; exit 1; }
grep -v '^#include' "$ROOT/emu/port/lock.c" >"$TMP/lock_body.c"
cp "$ROOT/tests/host/emu_rwlock/rwlocktest.c" "$TMP/"

if ! $CC -O2 -g -w -pthread -I"$TMP" -o "$TMP/rwlocktest" "$TMP/rwlocktest.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: rwlocktest does not compile"
	exit 1
fi
if "$TMP/rwlocktest"; then
	echo "emu_rwlock: ALL PASS"
	exit 0
fi
echo "emu_rwlock: FAILED"
exit 1

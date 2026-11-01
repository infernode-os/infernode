#!/bin/bash
#
# tests/host/kernelpins_test.sh
#
# Bugs that only a board under load shows, held by reading the source.
# Each was hours on the bench (2026-11-01), and each is one line someone
# could tidy back:
#
#   idlehands    core 0 in wfi: ready()'s sev does not end that, so a
#                process needing core 0 waited a clock tick each time:
#                gigabit input at 300 Mbit/s with nothing lost.
#   runproc      back round the run queue lock at splhi with no pause:
#                ready() starved until lock() panicked "lock loop".
#   nlocks       a proc preempted between winning a lock and recording it,
#                pinned to a core with a spinner at PriLock: deadlock,
#                "lock loop ... held by pc 0x0", within the hour.
#   up           a parameter called up: it is a macro, and clang then
#                deleted the rest of the function, loop exit and all.
#   kfs idle     kfs marks itself clean only when idle for longer than a
#                drive's write-back, or the mark can reach the medium
#                ahead of the data it speaks for.
#   ceilings     the pools' ceilings must not add up to more than there
#                is, and no heap may take the kernel's share.
#
# Usage: tests/host/kernelpins_test.sh
#

set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT" || exit 1
fail=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fail=1; }

idle=$(sed -n '/^idlehands(void)/,/^}/p' os/arm64/main.c | grep -v '^[[:space:]]*\*\|/\*')
if echo "$idle" | grep -q '"wfi' ; then no "idlehands has a wfi: sev will not wake it"
elif echo "$idle" | grep -q '"wfe'; then ok "every core idles in wfe"
else no "idlehands has no wfe"; fi

retry=$(sed -n '/^runproc(void)/,/^}/p' os/port/proc.c | grep -A22 'if(p == 0 || p->mach) {' | grep -v '^[[:space:]]*\*\|/\*')
if echo "$retry" | grep -q 'spllo' && echo "$retry" | grep -q 'microdelay'; then ok "runproc's retry lets go, with interrupts on"
else no "runproc's retry spins on the run queue lock"; fi

if grep -q 'up->nlocks == 0' os/port/proc.c && grep -q 'up->nlocks == 0' os/port/portclock.c && grep -q 'up->nlocks++' os/port/taslock.c; then ok "no proc is preempted holding a spin lock"
else no "a proc can be preempted holding a spin lock"; fi

bad=$(grep -rnE '\b(int|long|ulong|uint|char\*?|void\*?|Proc\*?|\*)[[:space:]]+\*?up[[:space:]]*[,);]' \
	os/bcm os/bcm2712 os/bcm2711 os/bcm2837 os/arm64 --include='*.c' --include='*.h' 2>/dev/null | grep -v '^\S*:[0-9]*:[[:space:]]*\*\|/\*\|\bProc\s*\*up\b')
if [ -z "$bad" ]; then ok "nothing is called up but up"; else echo "$bad"; no "a variable or parameter called up"; fi

m=$(sed -n '/#ifdef POOLBYNEED/,/#else/p' os/arm64/main.c)
if echo "$m" | grep -q 'mem - mainmax - imagmax' && echo "$m" | grep -q 'heapreserve = mainmax + imagmax'; then ok "the pools fit in memory, and the heaps leave the kernel its share"
else no "POOLBYNEED: the ceilings no longer fit in memory"; fi
if grep -q 'heapreserve != 0' os/port/alloc.c; then ok "poolalloc keeps the reserve"; else no "poolalloc ignores heapreserve"; fi

idle=$(sed -n 's/^Idlems: con \([0-9]*\);.*/\1/p' appl/cmd/disk/kfs.b)
flush=$(sed -n 's/^[[:space:]]*Flushms[[:space:]]*= \([0-9]*\),.*/\1/p' os/bcm2712/nvme.c)
if [ -n "$idle" ] && [ -n "$flush" ] && [ "$idle" -gt "$flush" ]; then ok "kfs waits $idle ms, the drive flushes every $flush"
else no "kfs's idle mark ($idle ms) must outlast the drive's write-back ($flush ms)"; fi

exit $fail

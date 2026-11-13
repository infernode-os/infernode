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
#   lock window  a proc preempted between winning a lock and recording it,
#                pinned to a core with a spinner at PriLock: deadlock,
#                "lock loop ... held by pc 0x0", within the hour (#640,
#                closed in master by taking PriLock before the tas).
#   up           a parameter called up: it is a macro, and clang then
#                deleted the rest of the function, loop exit and all.
#   kfs idle     kfs marks itself clean only when idle for longer than a
#                drive's write-back, or the mark can reach the medium
#                ahead of the data it speaks for.
#   ceilings     the pools' ceilings must not add up to more than there
#                is, and no heap may take the kernel's share.
#   ssthresh     after a loss, half the flight (RFC 5681), in a field as
#                wide as cwind: set to one segment, the window grew back
#                a segment a round trip and never doubled; a ushort
#                wraps half a scaled window (2026-11-10).
#   loopback     the loopback queue holds several of TCP's 512K windows:
#                at 128K it dropped 95% of a Pi 4's loopback traffic
#                (2026-11-10).
#   usable       TCP's usable window is unsigned: with more in flight than
#                the window allows, the difference wrapped to 4G and the
#                sender sent past the window, all of it dropped
#                (2026-11-10, devssl over loopback at 1 MB/s).
#   sack         TCP counts an ACK that SACKs new data as a duplicate, and
#                takes a segment for lost once more than three segments
#                above it are SACKed; its record of the highest SACKed
#                starts at snd.una.  A 9P peer sends its ACKs with its next
#                requests and SACKs all that follows a hole in one or two:
#                at 1% loss three in four losses waited for the timer, and
#                with the record left at 0 the rule was off in half the
#                sequence space (2026-11-11).
#   clock        the time of day is tod.c's (the hardware counter), not
#                boot time plus the tick count; the tick is armed before
#                timerintr() arms its deadline, not after; every overdue
#                tick is counted. Each ARM board lost 2.6 to 4.5 s an
#                hour (2026-11-13).
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

l=$(sed -n '/^lock(Lock/,/^}/p' os/port/taslock.c | grep -v '^[[:space:]]*\*\|/\*')
# Closed either way: interrupts off from the test-and-set until the
# priority is raised, or (master's #640) PriLock raised before it, so a
# holder preempted after winning is already in line with the spinner.
tasline=$(echo "$l" | grep -n '_tas(&l->key) == 0' | tail -1 | cut -d: -f1)	# the loop's, not the early no-process path's
priline=$(echo "$l" | grep -n 'up->pri = PriLock' | head -1 | cut -d: -f1)
if echo "$l" | grep -B1 '_tas(&l->key) == 0' | grep -q 'splhi' && echo "$l" | tail -3 | grep -q 'splx'; then ok "a lock is taken and recorded with interrupts off"
elif [ -n "$tasline" ] && [ -n "$priline" ] && [ "$priline" -lt "$tasline" ]; then ok "a lock is taken at PriLock: the holder cannot be passed over by a spinner"
else no "lock() can be preempted between taking a lock and recording it"; fi

bad=$(grep -rnE '\b(int|long|ulong|uint|char\*?|void\*?|Proc\*?|\*)[[:space:]]+\*?up[[:space:]]*[,);]' \
	os/bcm os/bcm2712 os/bcm2711 os/bcm2837 os/arm64 --include='*.c' --include='*.h' 2>/dev/null | grep -v '^\S*:[0-9]*:[[:space:]]*\*\|/\*\|\bProc\s*\*up\b')
if [ -z "$bad" ]; then ok "nothing is called up but up"; else echo "$bad"; no "a variable or parameter called up"; fi

m=$(sed -n '/#ifdef POOLBYNEED/,/#else/p' os/arm64/main.c)
if echo "$m" | grep -q 'mem - mainmax - imagmax' && echo "$m" | grep -q 'heapreserve = mainmax + imagmax'; then ok "the pools fit in memory, and the heaps leave the kernel its share"
else no "POOLBYNEED: the ceilings no longer fit in memory"; fi
if grep -q 'heapreserve != 0' os/port/alloc.c; then ok "poolalloc keeps the reserve"; else no "poolalloc ignores heapreserve"; fi

rx=$(sed -n '/^tcprxmit(Conv \*s)/,/^}/p' os/ip/tcp.c)
if grep -Eq '^[[:space:]]*u32int[[:space:]]+ssthresh;' os/ip/tcp.c && echo "$rx" | grep -q 'ssthresh = flight/2'; then ok "a loss halves ssthresh from the flight, in 32 bits"
else no "tcprxmit's ssthresh is not half the flight in a u32int"; fi
lbq=$(sed -n 's/.*lb->q = qopen(\([0-9*]*\), Qmsg.*/\1/p' os/ip/loopbackmedium.c)
if [ -n "$lbq" ] && [ $(( lbq )) -ge $(( 4*512*1024 )) ]; then ok "the loopback queue holds four 512K windows ($(( lbq )) bytes)"
else no "the loopback queue is ${lbq:-not found}: less than four of TCP's 512K windows"; fi
out=$(sed -n '/^tcpoutput(Conv \*s)/,/^}/p' os/ip/tcp.c)
unguarded=$(echo "$out" | grep -B1 'usable -= sent;' | grep -vc -e 'usable -= sent;' -e 'if(usable > sent)' -e '^--$')
if echo "$out" | grep -q 'usable -= sent;' && [ "$unguarded" = 0 ]; then ok "TCP's usable window never wraps below what is in flight"
else no "tcpoutput subtracts what is in flight from an unsigned usable window without a check"; fi
upd=$(sed -n '/^update(Conv \*s, Tcp \*seg)/,/^}/p' os/ip/tcp.c)
if echo "$upd" | grep -q 'newsack ||' && echo "$upd" | grep -q 'sackhigh - tcb->snd.una >' \
   && [ "$(grep -c 'snd.sackhigh = tcb->snd.una;' os/ip/tcp.c)" -ge 2 ] && grep -q 'rsackr\[tcph->nrsack++\]' os/ip/tcp.c
then ok "TCP takes SACKs as duplicates and as loss by bytes, the record starting at snd.una"
else no "TCP's loss detection does not use the peer's SACK blocks (or sackhigh is not started at snd.una)"; fi

idle=$(sed -n 's/^Idlems: con \([0-9]*\);.*/\1/p' appl/cmd/disk/kfs.b)
flush=$(sed -n 's/^[[:space:]]*Flushms[[:space:]]*= \([0-9]*\),.*/\1/p' os/bcm2712/nvme.c)
if [ -n "$idle" ] && [ -n "$flush" ] && [ "$idle" -gt "$flush" ]; then ok "kfs waits $idle ms, the drive flushes every $flush"
else no "kfs's idle mark ($idle ms) must outlast the drive's write-back ($flush ms)"; fi

for f in os/arm64/clockgt.c os/bcm2837/clock.c; do
	ci=$(sed -n '/^clockintr(Ureg/,/^}/p' $f | grep -v '^[[:space:]]*\*\|/\*')
	a=$(echo "$ci" | grep -n 'armtick();' | cut -d: -f1 | xargs)
	t=$(echo "$ci" | grep -n 'timerintr(u, 0);' | cut -d: -f1)
	if [ -n "$t" ] && [ $(echo $a | wc -w) -eq 1 ] && [ "$a" -lt "$t" ]; then ok "$f arms the tick before timerintr's deadline"
	else no "$f: clockintr must call armtick() once, before timerintr(), or the tick runs late and the clock loses it"; fi
done
sec=$(sed -n '/^seconds(void)/,/^}/p' os/port/devcons.c)
if echo "$sec" | grep -q 'todget' && ! grep -q 'boottime' os/port/devcons.c; then ok "the time of day is the hardware counter's"
else no "seconds() is not todget()'s: the time of day loses every missed tick"; fi
if sed -n '/^timerintr(Ureg/,/^}/p' os/port/portclock.c | grep -q 'm->ticks += callhzclock - 1'; then ok "timerintr counts every overdue tick"
else no "timerintr runs hzclock once however many ticks were due"; fi

exit $fail

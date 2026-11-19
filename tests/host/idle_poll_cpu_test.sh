#!/bin/sh
#
# idle_poll_cpu_test.sh — an emulator with a web page loaded and one
# small program polling beside it uses next to no CPU.  idle_cpu_test.sh
# is the page alone; this is the page and a proc that wakes twice a
# second, lists a directory and drops the listing, as lib/layers'
# watcher does (tests/idlepoll.b).
#
# Each wake allocates, so the heap is never unchanged, and the idle
# collector counted its round from the heap's last change: interrupted
# at every wake, its round never ended, and it went round the heap for
# as long as the emulator sat there.  A desktop left three days with a
# camera window's watcher and a page's timers running had used 52 hours
# of CPU, 600,000 idle passes a second.  The native kernel had already
# met this (os/port/dis.c, Idlegcgap): a round is counted from where it
# began, and rounds are spaced apart.
#
# The page is laid out and the poller started, then the emulator's CPU
# time is taken over 15 seconds and must be under a fifth of that.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "idle_poll_cpu_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/tests/idlepoll.dis" ] || { echo "idle_poll_cpu_test: SKIP (no dis/tests/idlepoll.dis)"; exit 77; }

page="$ROOT/tmp/idle_poll_cpu_page.html"
mkdir -p "$ROOT/tmp"
{
	echo '<!doctype html><title>Idle</title><body>'
	i=0
	while [ $i -lt 2000 ]; do
		echo "<p>$i some words to set, enough of them that a line wraps in a column of seven hundred pixels or so, and more.</p>"
		i=$((i+1))
	done
} >"$page"
trap 'rm -f "$page"' EXIT

# the process's CPU time in seconds, from ps (Linux and macOS formats)
cpusecs() {
	ps -o time= -p "$1" | awk '{ n = split($1, a, /[-:]/); s = 0;
		if (n == 2) s = a[1]*60 + a[2];
		else if (n == 3) s = a[1]*3600 + a[2]*60 + a[3];
		else if (n == 4) s = a[1]*86400 + a[2]*3600 + a[3]*60 + a[4];
		printf "%d\n", s }'
}

# the emulator itself (not under timeout(1): its pid is the one measured)
SDL_VIDEODRIVER=dummy "$EMU" -c1 -pheap=1536m -r"$ROOT" /dis/sh.dis -c \
	"load std; wm/charon -h file:///tmp/idle_poll_cpu_page.html & /dis/tests/idlepoll.dis 500 /dis & sleep 130; echo halt > /dev/sysctl" \
	</dev/null >/dev/null 2>&1 &
pid=$!
# Laid out, and whatever that left collected, before it is measured (as
# idle_cpu_test.sh): wait for a quiet 5 seconds, up to 90; an emulator
# that never goes quiet is the failure.
sleep 10
quiet=0
waited=10
while [ $waited -lt 90 ]; do
	q0=$(cpusecs $pid)
	sleep 5
	waited=$((waited + 5))
	q1=$(cpusecs $pid)
	if [ $((q1 - q0)) -le 1 ]; then quiet=1; break; fi
done
if [ $quiet = 0 ]; then
	kill $pid 2>/dev/null
	echo "FAIL: idle with a page loaded and a poller: still busy after ${waited}s"
	exit 1
fi
a=$(cpusecs $pid)
sleep 15
b=$(cpusecs $pid)
kill $pid 2>/dev/null
wait $pid 2>/dev/null
used=$((b - a))
if [ "$used" -le 3 ]; then
	echo "PASS: idle with a page loaded and a poller: ${used}s of CPU in 15s"
	exit 0
fi
echo "FAIL: idle with a page loaded and a poller: ${used}s of CPU in 15s"
exit 1

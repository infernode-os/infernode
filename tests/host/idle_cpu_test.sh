#!/bin/sh
#
# idle_cpu_test.sh — an emulator with a web page loaded and nothing to
# do uses next to no CPU.  The idle collector went round the whole heap
# again and again while nothing changed: headless Charon with a long
# page, untouched, used 99% of a core.  The page is laid out, then the
# emulator's CPU time is taken over 15 seconds of idleness and must be
# under a fifth of that.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "idle_cpu_test: SKIP (no emu)"; exit 77; }

page="$ROOT/tmp/idle_cpu_page.html"
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
	"load std; wm/charon -h file:///tmp/idle_cpu_page.html & sleep 70; echo halt > /dev/sysctl" \
	</dev/null >/dev/null 2>&1 &
pid=$!
sleep 30	# laid out, and whatever that left collected
a=$(cpusecs $pid)
sleep 15
b=$(cpusecs $pid)
kill $pid 2>/dev/null
wait $pid 2>/dev/null
used=$((b - a))
if [ "$used" -le 3 ]; then
	echo "PASS: idle with a page loaded: ${used}s of CPU in 15s"
	exit 0
fi
echo "FAIL: idle with a page loaded: ${used}s of CPU in 15s"
exit 1

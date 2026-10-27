#!/bin/bash
#
# presentation_tabstrip_test.sh — an app opened in Lucifer's presentation
# zone has the tab strip ("Tasks · tetris") above it, every time.
#
# lucipres draws the strip; presrender is a second window in the zone,
# below the strip.  Both are spawned at boot and either can join the
# zone's wmsrv first.  preswmloop took the first join for lucipres, so
# when presrender won, lucipres was given presrender's window, below the
# strip, where the app covered it: the strip stayed blank for the whole
# session while the app drew and its appstatus read running.  It did so
# in about one boot in three, so one boot proves nothing: this boots
# Lucifer headless RUNS times (default 6, JOBS at once), launches
# wm/tetris in the zone in each, screenshots it with scap and fails if
# any shot has no tab text in the strip.
#
# Run from project root: ./tests/host/presentation_tabstrip_test.sh [-v]
#	TABSTRIP_RUNS=n TABSTRIP_JOBS=n to change how many boots, how many at once

set -u
. "$(dirname "$0")/common.sh"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1
RUNS=${TABSTRIP_RUNS:-6}
JOBS=${TABSTRIP_JOBS:-3}

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/lucipres.dis dis/wm/tetris.dis dis/scap.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# At 1280x800 the presentation zone starts at x 385 and its tab strip
# is y 44 to 68 (header 40, a separator, the strip mainfont.height+12).
DRIVER="echo 'activity create Main' > /mnt/ui/ctl
echo 'create id=a type=app label=tetris dis=/dis/wm/tetris.dis' > /mnt/ui/activity/0/presentation/ctl
echo 'center id=a' > /mnt/ui/activity/0/presentation/ctl
sleep 10
echo APPSTATUS \`{cat /mnt/ui/activity/0/presentation/a/appstatus}
scap /tmp/tab.img
echo SHOT_DONE
echo halt > /dev/sysctl"

# one boot: its own HOME, as the shot lands under it
boot() {
	local n=$1 home="$WORK/home$n"
	mkdir -p "$home"
	HOME="$home" SDL_VIDEODRIVER=dummy with_timeout 100 "$EMU" -c1 \
		-pheap=1024m -pmain=1024m -pimage=1024m -g1280x800 -r"$ROOT" \
		/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 45; $DRIVER" \
		</dev/null >"$WORK/log$n" 2>&1
	find "$home" -name tab.img 2>/dev/null | head -1 >"$WORK/shot$n"
}

# the number of bright (text) pixels in x0 y0 x1 y1 of a screenshot
bright() {
	python3 -I - "$1" "$2" "$3" "$4" "$5" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read(); off = 0
if data[:11] == b'compressed\n':
    off = 11
hdr = data[off:off+60]; off += 60
chan = hdr[0:11].strip().decode()
minx, miny, maxx, maxy = (int(hdr[i:i+12]) for i in (12, 24, 36, 48))
w = maxx - minx
bpp = {'x8r8g8b8': 4, 'a8r8g8b8': 4, 'r8g8b8': 3}[chan]
if data[:11] != b'compressed\n':
    rows = data[off:]
else:
    rows = bytearray(); yy = miny
    while yy < maxy:
        bmaxy = int(data[off:off+12]); nb = int(data[off+12:off+24]); off += 24
        blk = data[off:off+nb]; off += nb; i = 0
        while i < len(blk):
            c = blk[i]; i += 1
            if c >= 128:
                n = c - 128 + 1; rows += blk[i:i+n]; i += n
            else:
                n = (c >> 2) + 3; o = ((c & 3) << 8 | blk[i]) + 1; i += 1
                for _ in range(n):
                    rows.append(rows[-o])
        yy = bmaxy
x0, y0, x1, y1 = (int(a) for a in sys.argv[2:6])
n = 0
for y in range(y0, y1):
    for x in range(x0, x1):
        p = ((y - miny) * w + (x - minx)) * bpp
        if rows[p] + rows[p+1] + rows[p+2] > 450:
            n += 1
print(n)
PY
}

n=1
while [ $n -le "$RUNS" ]; do
	j=0
	while [ $j -lt "$JOBS" ] && [ $n -le "$RUNS" ]; do
		boot $n &
		n=$((n + 1)); j=$((j + 1))
	done
	wait
done

passed=0 failed=0 skipped=0
for n in $(seq "$RUNS"); do
	log="$WORK/log$n"
	shot=$(cat "$WORK/shot$n" 2>/dev/null)
	if ! grep -q SHOT_DONE "$log" || [ -z "$shot" ]; then
		echo "SKIP: run $n: Lucifer did not boot in time"
		skipped=$((skipped + 1))
		[ $VERBOSE = 1 ] && tail -20 "$log"
		continue
	fi
	if ! grep -q '^APPSTATUS running' "$log"; then
		echo "FAIL: run $n: tetris not running ($(grep '^APPSTATUS' "$log"))"
		failed=$((failed + 1))
		continue
	fi
	got=$(bright "$shot" 385 44 700 68 2>/dev/null || echo 0)
	if [ "$got" -ge 20 ]; then
		echo "PASS: run $n: tab strip drawn over the app ($got text pixels)"
		passed=$((passed + 1))
	else
		echo "FAIL: run $n: tab strip blank over the app ($got text pixels)"
		failed=$((failed + 1))
		[ $VERBOSE = 1 ] && grep -i 'lucipres\|presrender' "$log" | head -20
	fi
done

echo "Total: $passed passed, $failed failed, $skipped skipped"
[ $failed -gt 0 ] && exit 1
[ $passed -eq 0 ] && exit 77
exit 0

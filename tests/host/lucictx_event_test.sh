#!/bin/sh
#
# lucictx_event_test.sh — Lucifer's context zone follows tools9p's
# event file (#1020): a folder granted through /mnt/toolctl/ctl is drawn
# in the zone within a second and a half, and nothing in the zone
# changes after that.  The zone used to poll /tool every five seconds.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/lucictx.dis dis/scap.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/tmp"
cat > "$H/tmp/drv.sh" <<'DRV'
load std
sleep 2
scap /tmp/before.img
echo bindpath /usr/inferno ro > /mnt/toolctl/ctl
sleep 1
scap /tmp/granted.img
sleep 6
scap /tmp/later.img
echo R done > '#c/cons'
echo halt > /dev/sysctl
DRV

LOG=$H/log
cd "$ROOT"
SDL_VIDEODRIVER=dummy HOME=$H with_timeout 300 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1280x800 -r"$ROOT" \
	/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 45; run /tmp/drv.sh" \
	</dev/null >"$LOG" 2>&1 || true

grep -q '^R done' "$LOG" || { echo "FAIL: the driver did not finish"; tail -20 "$LOG"; exit 1; }

python3 - "$H/tmp" "$ROOT/tools/p9img2png.py" <<'PY'
import sys, importlib.util
d, lib = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('p9', lib)
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)
a, b, c = (P.load('%s/%s.img' % (d, n)) for n in ('before', 'granted', 'later'))
# the context zone: the right-hand quarter, below the top bar
def changed(x, y):
    n = 0
    for yy in range(150, y.h - 8, 2):
        for xx in range(int(x.w * 0.76), x.w - 4, 2):
            n += x.px(xx, yy) != y.px(xx, yy)
    return n
failed = 0
n1 = changed(a, b)
if n1 > 100:
    print('PASS: the grant is drawn in the context zone within 1.5s (%d pixels)' % n1)
else:
    print('FAIL: the context zone did not change after the grant (%d pixels)' % n1); failed = 1
n2 = changed(b, c)
if n2 == 0:
    print('PASS: nothing in the zone changes after that')
else:
    print('FAIL: the zone changed again with nothing done (%d pixels)' % n2); failed = 1
if not failed:
    print('lucictx_event_test: PASS')
sys.exit(failed)
PY

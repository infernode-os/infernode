#!/bin/sh
#
# dialpad_test.sh — wm/dialpad under wm/wm (tests/dialpad/drive.sh),
# dialling a phone file of the driver's own: taps type the number and
# Call writes "dial <number>" to it, a press slid to another key types
# that key, delete takes one back and held clears, the keyboard types
# and Enter calls, Call with no number dials the last again, button 3
# (a touch held) on 0 is +, and a call the phone file reports connected
# turns Call into a red Hang up that writes "hangup", green again once
# the call has ended (by pixel).  Runs on a headless emulator: its
# in-memory screen (-g) is enough.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/dialpad.dis dis/scap.dis icons/ui/phone.svg icons/ui/phone-off.svg; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

T=tmp/dialpad_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pimage=512m -g800x600 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; wm/wm sh /tests/dialpad/drive.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; tail -20 "$LOG"; exit 1; }

# the writes the phone file had, in order
want='dial 5551234
dial 96
dial 123
dial 123
dial +44
hangup'
n=0
echo "$want" | while IFS= read -r w; do
	n=$((n + 1))
	got=$(sed -n "${n}p" "$ROOT/$T/writes" 2>/dev/null)
	case $n in
	1)	what="taps type the number and Call dials it" ;;
	2)	what="a slide to another key types it; delete takes one back, held clears" ;;
	3)	what="the keyboard types; Escape clears, Enter calls" ;;
	4)	what="Call with no number dials the last again" ;;
	5)	what="button 3 on 0 is +" ;;
	6)	what="a connected call's Call hangs up" ;;
	esac
	if [ "$got" = "$w" ]; then pass "$what ($got)"; else echo "FAIL: $what: '$got', not '$w'"; fi
done | tee "$ROOT/$T/results"
grep -q '^FAIL' "$ROOT/$T/results" && failed=1
[ "$(wc -l < "$ROOT/$T/writes")" -eq 6 ] || fail "writes: $(tr '\n' '|' < "$ROOT/$T/writes")"

# the colour at x y of a screenshot, as RRGGBB
pixel() {
	python3 -I - "$1" "$2" "$3" <<'PY'
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
x, y = int(sys.argv[2]), int(sys.argv[3])
p = ((y - miny) * w + (x - minx)) * bpp
print('%02X%02X%02X' % (rows[p+2], rows[p+1], rows[p]))
PY
}

# a corner of the Call key, clear of its glyph
set -- $(grep '^call ' "$ROOT/$T/keys")
x=$(($2 + 4)); y=$(($3 + 4))
during=$(pixel "$ROOT/$T/incall.img" $x $y 2>/dev/null || echo none)
after=$(pixel "$ROOT/$T/ended.img" $x $y 2>/dev/null || echo none)
red() { [ "$1" != none ] && [ $((0x$(echo "$1" | cut -c1-2))) -gt $((0x$(echo "$1" | cut -c3-4))) ]; }
green() { [ "$1" != none ] && [ $((0x$(echo "$1" | cut -c3-4))) -gt $((0x$(echo "$1" | cut -c1-2))) ]; }
red "$during" && pass "Call is red while a call is connected ($during)" || fail "during a call, Call is $during"
green "$after" && pass "Call is green again once it has ended ($after)" || fail "after the call, Call is $after"

exit $failed

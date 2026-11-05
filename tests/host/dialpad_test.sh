#!/bin/sh
#
# dialpad_test.sh — wm/dialpad under wm/wm (tests/dialpad/drive.sh),
# dialling a phone file of the driver's own: taps type the number and
# Call writes "dial <number>" to it, a press slid to another key types
# that key, delete takes one back and held clears, the keyboard types
# and Enter calls, Call with no number dials the last again, button 3
# (a touch held) on 0 is +, the star key shown a sextile dials *,
# and a call the phone file reports connected
# turns Call into a red Hang up that writes "hangup", green again once
# the call has ended (by pixel), and digits in a call go down the line
# ("dtmf <digit>").  The touch tones are caught from its audio device
# and decoded as an exchange decodes them: the keys pressed, in order,
# a tone each, at the standard frequencies.  Runs on a headless
# emulator: its in-memory screen (-g) is enough.
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
# the address book the microphone key's names are found in
printf 'Mom\tmobile\t+15551230001\nMom\twork\t+15551230002\nSarah Smith\tmobile\t+15551230003\nSarah Smith\twork\t+15551230004\n# contacts: 4 numbers\n' > "$ROOT/$T/contacts"
INFERNODE_AUDIO_FAKE=1 SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=512m -pimage=512m -g800x600 -r"$ROOT" \
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
dial *67#
dial +44
dtmf 1
dtmf 2
hangup
dial 5551212
dial +15551230004
dial +15551230001'
n=0
echo "$want" | while IFS= read -r w; do
	n=$((n + 1))
	got=$(sed -n "${n}p" "$ROOT/$T/writes" 2>/dev/null)
	case $n in
	1)	what="taps type the number and Call dials it" ;;
	2)	what="a slide to another key types it; delete takes one back, held clears" ;;
	3)	what="the keyboard types; Escape clears, Enter calls" ;;
	4)	what="Call with no number dials the last again" ;;
	5)	what="the star key (a sextile) dials a star, and hash a hash" ;;
	6)	what="button 3 on 0 is +" ;;
	7|8)	what="in a call a digit is sent down the line" ;;
	9)	what="a connected call's Call hangs up" ;;
	10)	what="a number said is put on the keypad, and Call dials it" ;;
	11)	what="\"call Sarah at work\" said dials her work number once the countdown ends" ;;
	12)	what="a touch stops a said call and types nothing; Call then dials Mom's mobile" ;;
	esac
	if [ "$got" = "$w" ]; then pass "$what ($got)"; else echo "FAIL: $what: '$got', not '$w'"; fi
done | tee "$ROOT/$T/results"
grep -q '^FAIL' "$ROOT/$T/results" && failed=1
[ "$(wc -l < "$ROOT/$T/writes")" -eq 12 ] || fail "writes: $(tr '\n' '|' < "$ROOT/$T/writes")"

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

# The sextile at the star key's centre: the middle of its ink (what
# differs from the key's fill) within a pixel of the key's middle.
inkmid() {	# shot minx miny maxx maxy
	python3 -I - "$@" <<'PY'
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
def px(x, y):
    p = ((y - miny) * w + (x - minx)) * bpp
    return rows[p:p+3]
x0, y0, x1, y1 = (int(a) for a in sys.argv[2:6])
fill = px(x0 + 3, y0 + 3)
xs = []; ys = []
for y in range(y0 + 2, y1 - 2):
    for x in range(x0 + 2, x1 - 2):
        if sum(abs(a - b) for a, b in zip(px(x, y), fill)) > 60:
            xs.append(x); ys.append(y)
if not xs:
    print('none'); sys.exit()
print(min(xs) + max(xs) - (x0 + x1), min(ys) + max(ys) - (y0 + y1))	# twice the offset
PY
}
set -- $(grep '^star ' "$ROOT/$T/keys")
off=$(inkmid "$ROOT/$T/star.img" $2 $3 $4 $5 2>/dev/null || echo none)
set -- $off
if [ $# = 2 ] && [ $1 -ge -2 ] && [ $1 -le 2 ] && [ $2 -ge -2 ] && [ $2 -le 2 ]; then
	pass "the sextile is at the star key's centre (within a pixel)"
else
	fail "the sextile is off the star key's centre: twice the offset is '$off'"
fi

# The touch tones, decoded as an exchange decodes them: each step's
# sound (tests/dialpad/drive.sh keeps it as raw 16-bit stereo) cut into
# tones where it falls quiet between them, each 20 ms of a tone read by
# Goertzel at the eight DTMF frequencies, its strongest row and column
# tone standing well clear of the others; a tone's keys in turn, the
# tones space-separated, with each tone's length and the loudest sample.
dtmf() {	# file [rate]
	python3 -I - "$@" <<'PY'
import sys, struct, math
RATE = int(sys.argv[2]) if len(sys.argv) > 2 else 44100
LOW = [697, 770, 852, 941]; HIGH = [1209, 1336, 1477, 1633]
GRID = "123A456B789C*0#D"
def goertzel(x, f):
    k = 2 * math.cos(2 * math.pi * f / RATE); s1 = s2 = 0.0
    for v in x:
        s0 = v + k * s1 - s2; s2 = s1; s1 = s0
    return s1 * s1 + s2 * s2 - k * s1 * s2
try:
    raw = open(sys.argv[1], 'rb').read()
except OSError:
    raw = b''
n = len(raw) // 4
left = [struct.unpack_from('<h', raw, 4 * i)[0] for i in range(n)]
b = 44
env = [max(abs(v) for v in left[i:i + b]) for i in range(0, n - b + 1, b)]
peak = max(env) if env else 0
segs = []; start = None
for i, e in enumerate(env):
    on = e > 0.2 * peak
    if on and start is None:
        start = i
    if not on and start is not None:
        segs.append((start * b, i * b)); start = None
if start is not None:
    segs.append((start * b, len(env) * b))
tones = []; lens = []
for a, z in segs:
    keys = ''
    win = RATE // 50	# 20 ms, at any rate: 697 Hz apart from 770 Hz
    for w in range(a, z - win + 1, win):
        x = left[w:w + win]
        lo = [goertzel(x, f) for f in LOW]; hi = [goertzel(x, f) for f in HIGH]
        l = max(range(4), key=lambda i: lo[i]); h = max(range(4), key=lambda i: hi[i])
        if lo[l] < 8 * sorted(lo)[-2] or hi[h] < 8 * sorted(hi)[-2]:
            continue
        k = GRID[l * 4 + h]
        if not keys or keys[-1] != k:
            keys += k
    tones.append(keys or '?'); lens.append(round((z - a) * 1000 / RATE))
print(' '.join(tones) + '|' + (str(min(lens)) if lens else '0') + '|' + str(peak))
PY
}
tonecheck() {	# step, want (a pattern), what
	r=$(dtmf "$ROOT/$T/audio.$1" 2>/dev/null || echo 'error|0|0')
	got=${r%%|*}; rest=${r#*|}; shortest=${rest%%|*}; peak=${rest#*|}
	case $got in
	$2)	if [ "$shortest" -ge 115 ] && [ "$peak" -gt 1000 ] && [ "$peak" -lt 32767 ]; then
			pass "$3 ($got; each at least ${shortest}ms, peak $peak)"
		else
			fail "$3: tones '$got', shortest ${shortest}ms, peak $peak"
		fi ;;
	*)	fail "$3: the tones heard were '$got', not '$2'" ;;
	esac
}
tonecheck digits '5 5 5 1 2 3 4' "each tap sounds its key's pair, a tap each (5 5 5 three tones)"
case $(dtmf "$ROOT/$T/audio.slide" 2>/dev/null | cut -d'|' -f1) in
'89 7 6'|'9 7 6')	pass "a press slid from 8 to 9 sounds 9 once there" ;;
*)	fail "slide: tones '$(dtmf "$ROOT/$T/audio.slide" 2>/dev/null)'" ;;
esac
tonecheck keyboard '1 2 3' "keys typed sound too"
tonecheck star '\* 6 7 #' "the star and hash keys sound theirs"
tonecheck plus '0 4 4' "0 held for + sounds 0's pair"
tonecheck intones '1 2' "a digit sent in a call sounds as it goes"
# The frequencies themselves, finer than a decoder needs: the whole of
# the first tone of a step scanned a hertz at a time; its loudest low
# and high frequencies within 3 Hz of the standard pair.
hz() {	# step
	python3 -I - "$1" <<'PY'
import sys, struct, math
RATE = 44100
raw = open(sys.argv[1], 'rb').read()
left = [struct.unpack_from('<h', raw, 4 * i)[0] for i in range(len(raw) // 4)]
peak = max(abs(v) for v in left)
i = 0
while abs(left[i]) < 0.2 * peak:
    i += 1
x = left[i:i + RATE * 110 // 1000]
def power(f):
    k = 2 * math.cos(2 * math.pi * f / RATE); s1 = s2 = 0.0
    for v in x:
        s0 = v + k * s1 - s2; s2 = s1; s1 = s0
    return s1 * s1 + s2 * s2 - k * s1 * s2
lo = max(range(650, 1000), key=power)
hi = max(range(1150, 1700), key=power)
print(lo, hi)
PY
}
freqcheck() {	# step key low high
	set -- "$1" "$2" "$3" "$4" $(hz "$ROOT/$T/audio.$1" 2>/dev/null || echo 0 0)
	if [ $(($5 - $3)) -ge -3 ] && [ $(($5 - $3)) -le 3 ] && [ $(($6 - $4)) -ge -3 ] && [ $(($6 - $4)) -le 3 ]; then
		pass "$2 is $3 Hz and $4 Hz (heard $5 and $6)"
	else
		fail "$2 should be $3 Hz and $4 Hz: heard $5 and $6"
	fi
}
freqcheck digits 5 770 1336
freqcheck star '*' 941 1209
freqcheck intones 1 697 1209
freqcheck plus 0 941 1336
r=$(dtmf "$ROOT/$T/audio.redial" 2>/dev/null | cut -d'|' -f1)
[ -z "$r" ] && pass "Call and delete make no tone" || fail "Call made tones '$r'"

# A long number is shown whole, its digits smaller, not cut at its
# start: after the last step the number is Mom's, +15551230001, and the
# leftmost glyph is its +: shorter than the digits beside it, and far
# taller than an ellipsis's dots, which a number cut short begins with.
plusfirst() {	# shot minx miny maxx maxy
	python3 -I - "$@" <<'PY'
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
def px(x, y):
    p = ((y - miny) * w + (x - minx)) * bpp
    return rows[p:p+3]
x0, y0, x1, y1 = (int(a) for a in sys.argv[2:6])
fill = px(x0, y0)
cols = {}
for x in range(x0, x1):
    for y in range(y0, y1):
        if sum(abs(a - b) for a, b in zip(px(x, y), fill)) > 60:
            cols.setdefault(x, []).append(y)
xs = sorted(cols)
if not xs:
    print('none'); sys.exit()
groups = [[xs[0]]]
for x in xs[1:]:
    if x - groups[-1][-1] <= 1:
        groups[-1].append(x)
    else:
        groups.append([x])
def height(g):
    ys = [y for x in g for y in cols[x]]
    return max(ys) - min(ys) + 1
first = height(groups[0]); rest = max(height(g) for g in groups[1:]) if len(groups) > 1 else 0
print(first, rest, xs[0] - x0, x1 - 1 - xs[-1])
PY
}
set -- $(grep '^number ' "$ROOT/$T/keys")
set -- $(plusfirst "$ROOT/$T/nobody.img" $2 $3 $4 $5 2>/dev/null || echo none)
if [ $# = 4 ] && [ $(($1 * 10)) -lt $(($2 * 8)) ] && [ $(($1 * 10)) -ge $(($2 * 4)) ]; then
	pass "a long number is shown whole, its + first (glyph $1 high beside digits $2)"
else
	fail "the number's start is not its +: '$*'"
fi

# The tones set the audio device's output format only: the format is
# the device's, and a bare "rate" changes the microphone's as well,
# under whatever is recording.
if grep -q '^out rate 44100$' "$ROOT/$T/audioctl" 2>/dev/null && ! grep -v '^out ' "$ROOT/$T/audioctl" | grep -q .; then
	pass "the tones set the output's format and leave the microphone's"
else
	fail "audioctl was written: $(tr '\n' '|' < "$ROOT/$T/audioctl" 2>/dev/null)"
fi

# Without -a the tones are a stream of audio(3)'s mix, role tone: what
# the speaker played (the fake hardware, 48 kHz) holds 1 then 9
r=$(dtmf "$ROOT/$T/mixed.raw" 48000 2>/dev/null | cut -d'|' -f1)
[ "$r" = "1 9" ] && pass "without -a the tones are a stream of the shared device's, and heard ($r)" ||
	fail "the shared device's speaker heard '$r', not '1 9'"

# the microphone key asked speech9p's hear to start each time
n=$(grep -c '^start 5000$' "$ROOT/$T/hearwrites" 2>/dev/null)
[ "$n" = 4 ] && pass "the microphone key starts hear each time (start 5000)" ||
	fail "hear was written: $(tr '\n' '|' < "$ROOT/$T/hearwrites" 2>/dev/null)"

exit $failed

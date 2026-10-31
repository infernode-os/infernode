#!/bin/sh
#
# location_test.sh — #g (emu/port/devlocation.c), the host's location
# service as an NMEA receiver, through tests/gps/location.sh: with no
# service (a desktop) it is there and says unavailable, and opening nmea
# is refused with the reason; with the stub's fake service
# ($INFERNODE_LOCATION_FAKE, emu/port/locationbridge-stub.c) the first
# reader starts it (status ok while read), each fix comes as RMC, GST and
# GGA with good checksums and NMEA's fields (ddmm.mmmmm, hemispheres,
# the date, knots, accuracy as GST errors), and gpsfs(4) reads it back
# as the position, altitude, speed and accuracy given; a reader left
# keeps it running when another stops, and the last to go stops it.  The Android and iOS bridges
# feed the same device and cannot run here.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/gpsfs.dis" ] || { echo "SKIP: dis/gpsfs.dis not built"; exit 77; }
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }

T=tmp/location_test.$$
D="$ROOT/$T"
mkdir -p "$D/none" "$D/fake"
trap 'rm -rf "$D"' EXIT
cd "$ROOT"
(unset INFERNODE_LOCATION_FAKE
with_timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis /tests/gps/location.sh "/$T/none" none \
	</dev/null >"$D/none/log" 2>&1) || true
(export INFERNODE_LOCATION_FAKE='-33.856800 151.215300 12.5 4.5'
with_timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis /tests/gps/location.sh "/$T/fake" fake \
	</dev/null >"$D/fake/log" 2>&1) || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$D/$1" 2>/dev/null || true; }

for r in none fake; do
	grep -q '^R done' "$D/$r/log" || { fail "the $r driver did not finish"; tail -20 "$D/$r/log"; exit 1; }
done

[ "$(f none/ls | tr '\n' ' ')" = "#g/nmea #g/status " ] && pass "its files" ||
	fail "ls: $(f none/ls | tr '\n' ' ')"
[ "$(f none/status.before)" = unavailable ] && pass "no service: unavailable" ||
	fail "status: '$(f none/status.before)'"
f none/err.open | grep -q 'no location service on this host' &&
	pass "no service: opening nmea refused, with the reason" || fail "open: '$(f none/err.open)'"

[ "$(f fake/status.before)" = stopped ] && [ "$(f fake/status.reading)" = ok ] &&
	pass "the first reader starts it" ||
	fail "status: '$(f fake/status.before)' then '$(f fake/status.reading)'"

if python3 -I - "$D/fake/raw" <<'PY'
import re, sys, time
lines = [l.rstrip("\r\n") for l in open(sys.argv[1], newline="") if l.strip()]
assert len(lines) >= 3, lines
raw = open(sys.argv[1], newline="").read()
assert "\r\n" in raw, "CRLF"
for l in lines:
    m = re.fullmatch(r"\$([^*]*)\*([0-9A-F]{2})", l)
    assert m, l
    s = 0
    for c in m.group(1).encode():
        s ^= c
    assert s == int(m.group(2), 16), "checksum " + l
kinds = [l[3:6] for l in lines[:3]]
assert kinds == ["RMC", "GST", "GGA"], kinds
rmc = lines[0][1:].split("*")[0].split(",")
assert re.fullmatch(r"\d{6}\.\d\d", rmc[1]) and rmc[2] == "A", rmc
assert rmc[3] == "3351.40800" and rmc[4] == "S", rmc
assert rmc[5] == "15112.91800" and rmc[6] == "E", rmc
assert rmc[7] == "1.94" and rmc[8] == "0.0", rmc      # 1 m/s in knots
assert rmc[9] == time.strftime("%d%m%y", time.gmtime()), rmc
gst = lines[1][1:].split("*")[0].split(",")
assert gst[6] == "3.2" and gst[7] == "3.2", gst       # 4.5/sqrt 2
gga = lines[2][1:].split("*")[0].split(",")
assert gga[6] == "1" and gga[9] == "12.5" and gga[10] == "M", gga
PY
then pass "each fix as RMC, GST and GGA, with NMEA's fields and good checksums"
else fail "raw: $(f fake/raw | head -3)"
fi

fix=$(f fake/fix)
echo "$fix" | grep -Eq '^time=[0-9-]+T[0-9:.]+Z lat=-33\.85(6[0-9]|5[0-9])[0-9]{2} lon=151\.215300 alt=12\.5 speed=1\.00 course=0\.0 mode=3d q=gps err=4\.5$' &&
	pass "gpsfs reads it back: position, altitude, speed, accuracy" || fail "fix: '$fix'"
[ "$(f fake/status.onestill)" = ok ] && pass "a reader left keeps it running" ||
	fail "status after one stopped: '$(f fake/status.onestill)'"

[ "$(f fake/status.after)" = stopped ] && pass "the last reader to go stops it" ||
	fail "status after the last: '$(f fake/status.after)'"

[ $failed = 0 ] && echo "location_test: PASS"
exit $failed

#!/bin/sh
#
# gpsfs_test.sh — gpsfs(4), a GPS receiver at /mnt/gps, through
# tests/gps/drive.sh: its files listed; a recorded log read as a source
# gives the last fix (attr=value), the position, the satellites in view
# and used, the command read back from ctl; a log replayed at the pace
# of its times, event giving each fix as it comes and nmea each
# sentence; a network feed of NMEA and gpsd (asked for NMEA by ?WATCH)
# as sources; refused: a baud rate for a file with no ctl, a missing
# file, an unknown command, a baud rate that is no number, a sentence
# with a bad checksum written to feed; stop; sentences written to feed
# taken as the receiver's, event telling of the fix and of its loss,
# position then refused; a second gpsfs finds it served.  The fake
# feeds are tests/host/gps/fake_feed.py.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/gpsfs.dis" ] || { echo "SKIP: dis/gpsfs.dis not built"; exit 77; }
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }

T=tmp/gpsfs_test.$$
D="$ROOT/$T"
mkdir -p "$D"
PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; rm -rf "$D"' EXIT

F="$ROOT/tests/host/gps/fake_feed.py"
python3 -I "$F" track "$D/track.nmea"
python3 -I "$F" feed "$D/feed.nmea"
# serve mode -> its port
serve() {
	pf="$D/$1.port"
	python3 -I "$F" "$1" "$D/$1.log" > "$pf" 2>"$D/$1.err" &
	PIDS="$PIDS $!"
	for i in $(seq 50); do [ -s "$pf" ] && break; sleep 0.1; done
	head -1 "$pf"
}
PN=$(serve nmea)
PG=$(serve gpsd)
[ -n "$PN" ] && [ -n "$PG" ] || { echo "FAIL: a fake feed did not start"; cat "$D"/*.err; exit 1; }

cd "$ROOT"
with_timeout 90 "$EMU" -r"$ROOT" /dis/sh.dis /tests/gps/drive.sh "/$T" "$PN" "$PG" \
	</dev/null >"$D/log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$D/$1" 2>/dev/null || true; }
has() { f "$1" | grep -q -- "$2"; }

grep -q '^R done' "$D/log" || { fail "the driver did not finish"; tail -20 "$D/log"; exit 1; }

[ "$(f ls | tr '\n' ' ')" = "/mnt/gps/ctl /mnt/gps/event /mnt/gps/feed /mnt/gps/fix /mnt/gps/nmea /mnt/gps/position /mnt/gps/satellites /mnt/gps/status " ] &&
	pass "its files" || fail "ls: $(f ls | tr '\n' ' ')"
[ "$(f status.start)" = "state=nosource link=none sentences=0 bad=0" ] &&
	pass "nothing at first" || fail "status: $(f status.start)"

want="time=2026-10-31T14:32:02Z lat=40.784200 lon=-74.416667 alt=76.0 speed=2.57 course=90.0 mode=3d q=gps sats=7 hdop=1.1 vdop=1.6 pdop=2.0 err=5.0 verr=6.5"
[ "$(f fix.file)" = "$want" ] && pass "a log as a source: the last fix" ||
	fail "fix: '$(f fix.file)'"
[ "$(f position.file)" = "40.784200 -74.416667" ] && pass "position" ||
	fail "position: '$(f position.file)'"
[ "$(f satellites.file | tr '\n' '|')" = "gps 4 45 270 38 1|gps 9 10 20 22 1|gps 12 5 300 - 1|" ] &&
	pass "satellites in view and used" || fail "satellites: '$(f satellites.file | tr '\n' '|')'"
[ "$(f ctl.file)" = "source /$T/track.nmea" ] && pass "ctl reads the command" ||
	fail "ctl: '$(f ctl.file)'"
has status.file "^state=fix link=closed source=/$T/track.nmea sentences=15 bad=0 age=" &&
	pass "status: the log read to its end" || fail "status: '$(f status.file)'"

early=$(f events.early | tr -d ' '); late=$(f events.late | tr -d ' ')
[ "${early:-9}" -le 2 ] && [ "$late" = 3 ] &&
	pass "a replay is paced by its times ($early fixes after a second, $late at the end)" ||
	fail "replay: $early fixes after a second, $late at the end"
# a new source: its first fix is given at its first sentence, before
# the receiver is known to send more; the next once all have come
[ "$(f events | sed -n 1p)" = "time=2026-10-31T14:32:00Z lat=40.784000 lon=-74.416667 speed=2.57 course=90.0 mode=2d q=gps" ] &&
	[ "$(f events | sed -n 2p)" = "time=2026-10-31T14:32:01Z lat=40.784100 lon=-74.416667 alt=76.0 speed=2.57 course=90.0 mode=3d q=gps sats=7 hdop=1.1 vdop=1.6 pdop=2.0 err=5.0 verr=6.5" ] &&
	pass "event gives each fix" || fail "events: $(f events | tr '\n' '|')"
[ "$(f nmea | grep -c .)" -ge 15 ] && f nmea | head -1 | grep -q '^\$GPRMC,143200.00,A' &&
	! f nmea | grep -q "$(printf '\r')" &&
	pass "nmea gives each sentence, as a line" || fail "nmea: $(f nmea | head -3)"

[ -z "$(f err.tcp)" ] && [ "$(f position.tcp)" = "51.500000 -74.416667" ] &&
	pass "a network feed as a source" || fail "tcp: '$(f err.tcp)' '$(f position.tcp)'"
[ -z "$(f err.gpsd)" ] && [ "$(f position.gpsd)" = "51.500000 -74.416667" ] &&
	grep -q '^?WATCH={"enable":true,"nmea":true}' "$D/gpsd.log" &&
	pass "gpsd as a source, asked for NMEA" ||
	fail "gpsd: '$(f err.gpsd)' '$(f position.gpsd)' sent '$(f gpsd.log)'"
has status.gpsd "link=open source=tcp!127.0.0.1!$PG " && pass "status names the source" ||
	fail "status: '$(f status.gpsd)'"

has err.baud "track.nmeactl: b4800" && pass "a baud rate for a file with no ctl refused" ||
	fail "baud: '$(f err.baud)'"
has err.missing "does not exist" && pass "a missing source refused" || fail "missing: '$(f err.missing)'"
has err.bogus "unknown command bogus" && pass "an unknown command refused" || fail "bogus: '$(f err.bogus)'"
has err.badbaud "bad baud rate 4k8" && pass "a baud rate that is no number refused" ||
	fail "badbaud: '$(f err.badbaud)'"
has err.feed "bad sentence: checksum mismatch" && pass "a bad sentence written to feed refused" ||
	fail "feed: '$(f err.feed)'"

[ -z "$(f ctl.stop)" ] && has status.stop "link=none" && ! has status.stop "source=" &&
	pass "stop" || fail "stop: '$(f ctl.stop)' '$(f status.stop)'"

[ "$(f events.feed | tr '\n' '|')" = "time=2026-10-31T09:00:00Z lat=-33.866667 lon=151.200000 speed=0.00 course=0.0 mode=2d q=gps|time=2026-10-31T09:00:01Z lat=-33.866683 lon=151.200000 speed=0.00 course=0.0 mode=2d q=gps|time=2026-10-31T09:00:02Z mode=none|" ] &&
	pass "feed: each fix, and its loss, told by event" ||
	fail "events.feed: '$(f events.feed | tr '\n' '|')'"
[ -z "$(f position.lost)" ] && has err.lost "no fix" && pass "position refused with no fix" ||
	fail "lost: '$(f position.lost)' '$(f err.lost)'"
has again "served already" && pass "a second gpsfs finds it served" || fail "again: '$(f again)'"

[ $failed = 0 ] && echo "gpsfs_test: PASS"
exit $failed

#!/bin/sh
#
# timesync_test.sh — the GPS as a clock: gpsfs(4)'s time file and
# timesync(8), through tests/gps/timesync.sh, with a fake marine gateway
# (tests/host/gps/fake_feed.py) whose clock is an hour ahead: the time
# file pairs the fix's time with this host's at its arrival, marked
# sync=yes, its offset the hour; timesync steps the clock by it, and a
# second run finds it right and leaves it; a name space without the
# mount reaches the posted #sgps/fs; a recording's time file says
# sync=no and timesync refuses it.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/gpsfs.dis dis/timesync.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }

T=tmp/timesync_test.$$
D="$ROOT/$T"
mkdir -p "$D"
PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; rm -rf "$D"' EXIT
F="$ROOT/tests/host/gps/fake_feed.py"
python3 -I "$F" track "$D/track.nmea"
PORT=$(python3 -I "$F" port)
python3 -I "$F" udpnmea "$PORT" 3600 2>"$D/udp.err" &
PIDS="$PIDS $!"

cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -r"$ROOT" /dis/sh.dis /tests/gps/timesync.sh "/$T" "$PORT" \
	</dev/null >"$D/log" 2>&1 || true
HOSTUS=$(python3 -c 'import time; print(int(time.time() * 1000000))')

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$D/$1" 2>/dev/null || true; }

grep -q '^R done' "$D/log" || { fail "the driver did not finish"; tail -20 "$D/log"; exit 1; }

python3 -I - "$D" "$HOSTUS" <<'PY' || failed=1
import re, sys
D, hostus = sys.argv[1], int(sys.argv[2])
def f(n):
    try:
        return open(D + "/" + n).read()
    except OSError:
        return ""
bad = 0
def check(ok, what, got):
    global bad
    print(("PASS: " if ok else "FAIL: ") + what + ("" if ok else ": " + repr(got)))
    bad |= not ok
t = f("time.live")
m = re.match(r"time=\S+Z gps=(\d+) local=(\d+) offset=(-?\d+) sync=yes\n$", t)
check(bool(m) and abs(int(m.group(3)) - 3600 * 10**6) < 1500000 and
      int(m.group(1)) - int(m.group(2)) == int(m.group(3)),
      "the time file: the fix's time beside the host's, an hour apart, sync=yes", t)
o = f("out.set")
check(re.match(r"timesync: clock slow by 3599\.\d+|timesync: clock slow by 3600\.\d+", o) is not None
      and o.endswith(": set\n"), "timesync steps the clock by the hour", o + f("err.set"))
c = f("clock.after").strip()
check(c.isdigit() and abs(int(c) - hostus - 3600 * 10**6) < 30 * 10**6,
      "the clock after: an hour ahead of the host's", c)
a = f("out.again")
check(a.startswith("timesync: clock ") and a.endswith(": left\n"), "a second run leaves it", a + f("err.again"))
p = f("out.posted")
check(p.endswith(": left\n"), "a name space without the mount uses the posted #sgps/fs", p + f("err.posted"))
r = f("time.recorded")
check("sync=no" in r, "a recording's time file says sync=no", r)
e = f("err.recorded")
check("not a live receiver's" in e, "and timesync refuses it", e)
sys.exit(bad)
PY

[ $failed = 0 ] && echo "timesync_test: PASS"
exit $failed

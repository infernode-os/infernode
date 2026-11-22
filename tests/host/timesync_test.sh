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
# The gateway is a UDP port listened to, which anyone on the network can
# send to: its time file says sync=no, and timesync refuses it, until
# the source command says sync (it said sync=yes as a serial receiver's
# does, so any host on the network chose the clock).
#
# And times that are not the receiver's, as records scripted by
# tests/timerec.b:
#   - one sample in five a year ahead leaves the clock (the largest of
#     the samples was taken: the clock went a year ahead);
#   - samples that agree on nothing are refused;
#   - a time a hundred years back is refused as before this system was
#     built (it was set: the clock went negative);
#   - a clock that has been set is not stepped ten days without -m;
#   - a record with no offset= is no sample (it was a sample of no
#     offset: "left"), an empty file "no fix yet";
#   - one record an hour behind that is never replaced is applied once
#     under -p (it was applied every period, an hour back each time).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/gpsfs.dis dis/timesync.dis dis/tests/timerec.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }

T=tmp/timesync_test.$$
D="$ROOT/$T"
mkdir -p "$D"
PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
F="$ROOT/tests/host/gps/fake_feed.py"
mkdir -p "$D/empty"
python3 -I "$F" track "$D/track.nmea"
PORT=$(python3 -I "$F" port)
python3 -I "$F" udpnmea "$PORT" 3600 2>"$D/udp.err" &
PIDS="$PIDS $!"

cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 140 "$EMU" -r"$ROOT" /dis/sh.dis /tests/gps/timesync.sh "/$T" "$PORT" \
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
ns = f("time.nosync")
check(re.match(r"time=\S+Z gps=\d+ local=\d+ offset=-?\d+ sync=no\n$", ns) is not None,
      "a UDP port listened to: its time file says sync=no", ns)
check("not a live receiver's" in f("err.nosync") and f("out.nosync") == "",
      "and timesync does not set the clock from it", f("out.nosync") + f("err.nosync"))
check(f("ctl.sync").startswith("source udp!*!") and f("ctl.sync").endswith(" sync\n"),
      "the source command with sync reads back", f("ctl.sync"))
t = f("time.live")
m = re.match(r"time=\S+Z gps=(\d+) local=(\d+) offset=(-?\d+) sync=yes\n$", t)
check(bool(m) and abs(int(m.group(3)) - 3600 * 10**6) < 1500000 and
      int(m.group(1)) - int(m.group(2)) == int(m.group(3)),
      "the time file: the fix's time beside the host's, an hour apart, sync=yes", t)
o = f("out.set")
check(re.match(r"timesync: clock slow by 3599\.\d+|timesync: clock slow by 3600\.\d+", o) is not None
      and o.endswith(": set\n"), "timesync steps the clock by the hour", o + f("err.set"))
c = f("clock.after").strip()
# (the host's clock is read when the emulator has ended, most of two
# minutes after this step)
check(c.isdigit() and abs(int(c) - hostus - 3600 * 10**6) < 150 * 10**6,
      "the clock after: an hour ahead of the host's", c)
a = f("out.again")
check(a.startswith("timesync: clock ") and a.endswith(": left\n"), "a second run leaves it", a + f("err.again"))
p = f("out.posted")
check(p.endswith(": left\n"), "a name space without the mount uses the posted #sgps/fs", p + f("err.posted"))
r = f("time.recorded")
check("sync=no" in r, "a recording's time file says sync=no", r)
e = f("err.recorded")
check("not a live receiver's" in e, "and timesync refuses it", e)

def clock(n):
    c = f(n).strip()
    return int(c) - hostus if c.isdigit() else None
def near(n, secs):
    c = clock(n)
    return c is not None and abs(c - secs * 10**6) < 150 * 10**6
H = 3600
o = f("out.median")
check(o.endswith(": left\n") and near("clock.median", H),
      "one sample in five a year ahead: the clock is left", (o, f("err.median"), clock("clock.median")))
e = f("err.disagree")
check("disagree" in e and f("out.disagree") == "", "samples 100 s apart are refused as disagreeing", e + f("out.disagree"))
e = f("err.floor")
check("before this system was built" in e and f("out.floor") == "" and near("clock.floor", H),
      "a time a hundred years back is refused, and the clock left", (e, f("out.floor"), clock("clock.floor")))
e = f("err.floor0")
check("before this system was built" in e and f("out.floor0") == "" and near("clock.floor0", H),
      "with -m 0 too", (e, f("out.floor0"), clock("clock.floor0")))
e = f("err.bound")
check("more than the 86400 s a clock already set is stepped" in e and f("out.bound") == "" and near("clock.bound", H),
      "a clock that has been set is not stepped ten days", (e, f("out.bound"), clock("clock.bound")))
o = f("out.allowed")
check(o.endswith(": set\n") and near("clock.allowed", H + 864000), "with -m it is", (o, f("err.allowed"), clock("clock.allowed")))
o = f("out.back")
check(o.endswith(": set\n") and near("clock.back", H), "and back, with -m 0", (o, f("err.back"), clock("clock.back")))
e = f("err.nooffset")
check("that is none" in e and f("out.nooffset") == "", "a record with no offset is no sample", e + f("out.nooffset"))
e = f("err.empty")
check("no fix with a time yet" in e, "an empty time file is no fix yet", e)
e = f("err.noclock")
check("/dev/time" in e and f("out.noclock") == "", "a clock that cannot be read is said, and nothing set", e + f("out.noclock"))
ts = lambda x: [l for l in x.split("\n") if l.startswith("timesync:")]
e1, e2 = f("err.remount.1"), f("err.remount.2")
check(ts(e1) != [] and ts(e2) == ts(e1) and f("out.remount") == "",
      "-p, and gpsfs started again: its posted files mounted again, the errors stop", (e1[-300:], e2[len(e1):][:300], f("out.remount")))
o = f("out.stale")
check(o.count(": set\n") == 1 and near("clock.stale", 0),
      "a record an hour behind, never replaced, is applied once", (o, f("err.stale")[:200], clock("clock.stale")))
sys.exit(bad)
PY

[ $failed = 0 ] && echo "timesync_test: PASS"
exit $failed

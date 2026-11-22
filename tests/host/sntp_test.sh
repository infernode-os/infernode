#!/bin/sh
#
# sntp_test.sh - ip/sntp (sntp(8)) against scripted servers on the
# loopback (tests/host/sntp/fake_ntp.py), a port a case.
#
# sntp's request carried nothing a reply could be matched to, and the
# reply's originate timestamp was never looked at: any datagram with the
# server's address on it set the clock, to any time from 2005 to 2036.
# The request now carries 64 random bits as its transmit timestamp and a
# reply is taken only if it gives them back (RFC 4330 section 5).
#
#  - the request's transmit timestamp is not zero and differs each time,
#    and its originate timestamp says nothing
#  - a server's answer sets the clock: versions 1 and 4, a leap second
#    pending (the version was read with the leap indicator's bits in it,
#    so these two were "no response")
#  - a good answer behind four that answer nobody's request and one too
#    short is taken (each refused datagram used up a try)
#  - refused, the clock left, and said so: an originate timestamp that
#    is not the request's, or an earlier request's; mode 6 (read as mode
#    2 and taken) and mode 5; a server whose clock is not set; a
#    kiss-of-death (it was warned of, then used); no transmit timestamp
#  - an answer from another port than the one asked is not seen
#  - a clock that cannot be written is an error (it was success)
#
# The clock written is the emulator's own (its offset from the host's).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/ip/sntp.dis dis/tests/timerec.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

N=sntp_test.$$
W="$ROOT/tmp/$N"
rm -rf "$W"
mkdir -p "$W"
SRV=
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
E=/tmp/$N

python3 -I "$ROOT/tests/host/sntp/fake_ntp.py" "$W/ports" 80 > "$W/server.log" 2>&1 &
SRV=$!
for i in $(seq 1 50); do [ -s "$W/ports" ] && break; sleep 0.1; done
[ -s "$W/ports" ] || { echo "FAIL: the fake servers did not start: $(cat "$W/server.log")"; exit 1; }
port() { sed -n "s/^$1 //p" "$W/ports"; }

REFUSED="garbage replay mode6 mode5 li3 kod zero other"
SET="good v4 leap burst"
{
	echo "load std"
	# those that must be refused, at once: each takes its four tries
	for c in $REFUSED; do
		echo "{ip/sntp -d 'udp!127.0.0.1!$(port $c)' > $E/out.$c >[2=1]; echo \$status > $E/st.$c} &"
	done
	echo "sleep 19"
	echo "cat /dev/time > $E/clock.refused"
	# a good answer years from a clock that is set: not taken without -m
	echo "ip/sntp 'udp!127.0.0.1!$(port good)' > $E/out.step >[2=1]"
	echo "echo \$status > $E/st.step"
	echo "cat /dev/time > $E/clock.step"
	for c in $SET; do
		echo "ip/sntp -d -m 0 'udp!127.0.0.1!$(port $c)' > $E/out.$c >[2=1]"
		echo "echo \$status > $E/st.$c"
		echo "cat /dev/time > $E/clock.$c"
	done
	# a clock that refuses to be written
	echo "/dis/tests/timerec.dis rot 0"
	echo "@{pctl forkns; bind /chan/rot /dev/time; ip/sntp -m 0 'udp!127.0.0.1!$(port ro)' > $E/out.ro >[2=1]; echo \$status > $E/st.ro}"
	echo "cat /dev/time > $E/clock.ro"
	echo "echo done > $E/done"
	echo "echo halt > /dev/sysctl"
} > "$W/run.sh"
with_timeout 70 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "$E/run.sh" </dev/null >"$W/log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$W/$1" 2>/dev/null || true; }
[ -f "$W/done" ] || { fail "the session did not finish: $(tail -5 "$W/log" | tr '\n' ' ')"; exit 1; }

python3 -I - "$W" <<'PY' || failed=1
import calendar, re, sys, time
W = sys.argv[1]
def f(n):
    try:
        return open(W + "/" + n).read()
    except OSError:
        return ""
bad = 0
def check(ok, what, got=""):
    global bad
    print(("PASS: " if ok else "FAIL: ") + what + ("" if ok else ": " + repr(got)[:300]))
    bad |= not ok
def year(y):
    return calendar.timegm((y, 1, 1, 0, 0, 0))
def clock(n):
    c = f(n).strip()
    return int(c) // 10**6 if c.isdigit() else -1

# the requests
reqs = re.findall(r"org=([0-9a-f]{16}) xmt=([0-9a-f]{16})", f("server.log"))
xmts = [x for _, x in reqs]
check(len(reqs) >= 10 and all(o == "0" * 16 for o, _ in reqs) and "0" * 16 not in xmts and len(set(xmts)) == len(xmts),
      "each request's transmit timestamp is its own %d random bits, its originate timestamp nothing" % 64, reqs[:4])

why = {
    "garbage": "originate timestamp is not this request's",
    "replay": "originate timestamp is not this request's",
    "mode6": "mode 6, not a server's",
    "mode5": "mode 5, not a server's",
    "li3": "clock is not set",
    "kod": "kiss-of-death (stratum 0): DENY",
    "zero": "no transmit timestamp",
}
for c, w in why.items():
    o = f("out." + c)
    check("no acceptable reply" in o and w in o and "no acceptable reply" in f("st." + c),
          "%s: refused, saying why" % c, (o[-300:], f("st." + c)))
o = f("out.other")
check("no response from server" in o and "timeout" in f("st.other"), "an answer from another port is not seen", o[-200:])
c = clock("clock.refused")
check(abs(c - time.time()) < 300, "and none of them set the clock", c)

o = f("out.step")
check("more than the 86400 s" in o and "step too large" in f("st.step") and abs(clock("clock.step") - time.time()) < 300,
      "an answer years from a clock already set is refused without -m, and the clock left", (o[-300:], f("st.step"), clock("clock.step")))
for c, y in (("good", 2030), ("v4", 2034), ("leap", 2035), ("burst", 2029)):
    check(abs(clock("clock." + c) - year(y)) < 60 and f("st." + c).strip() == "",
          "%s: the clock is set to %d" % (c, y), (clock("clock." + c), f("st." + c), f("out." + c)[-300:]))
o = f("out.ro")
check("the clock was not set" in o and "clock not set" in f("st.ro") and abs(clock("clock.ro") - year(2029)) < 60,
      "a clock that cannot be written is an error", (o, f("st.ro"), clock("clock.ro")))
sys.exit(bad)
PY

[ $failed = 0 ] && echo "sntp_test: PASS"
exit $failed

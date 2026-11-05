#!/bin/sh
#
# sdrfs_test.sh — sdrfs(4), an RTL-SDR at /mnt/sdr through rtl_tcp, against
# a fake rtl_tcp (tests/host/sdr/fake_rtl_tcp.py), through
# tests/sdr/drive.sh: its files; settings kept before a source and sent
# whole when it is dialled; a source dialled to see it is rtl_tcp (its
# tuner and gains) and hung up on while nothing listens; the first reader
# of iq dialling and the last hanging up; reads in whole samples, in
# order; two readers on one stream, a setting written while they read
# sent at once; a reader that does not read losing the oldest, still in
# whole samples; refused: something that is not rtl_tcp, nothing
# listening, an rtl_tcp that does not greet (busy with another
# client), bad settings, a write with one bad line (none of it done);
# stop; a second sdrfs finds it served.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/sdrfs.dis" ] || { echo "SKIP: dis/sdrfs.dis not built"; exit 77; }
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }

T=tmp/sdrfs_test.$$
D="$ROOT/$T"
mkdir -p "$D"
PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; rm -rf "$D"' EXIT

F="$ROOT/tests/host/sdr/fake_rtl_tcp.py"
start() {	# name args... -> its port
	pf="$D/$1.port"; n=$1; shift
	python3 -I "$F" "$@" > "$pf" 2>"$D/$n.err" &
	PIDS="$PIDS $!"
	for i in $(seq 50); do [ -s "$pf" ] && break; sleep 0.1; done
	head -1 "$pf"
}
PR=$(start rtl serve "$D/rtl.log" 6)
PH=$(start http http)
PB=$(start busy busy)
PN=$(python3 -I "$ROOT/tests/host/gps/fake_feed.py" port)	# nothing there
[ -n "$PR" ] && [ -n "$PH" ] && [ -n "$PB" ] || { echo "FAIL: a fake did not start"; cat "$D"/*.err; exit 1; }

cd "$ROOT"
with_timeout 90 "$EMU" -r"$ROOT" /dis/sh.dis /tests/sdr/drive.sh "/$T" "$PR" "$PH" "$PN" "$PB" \
	</dev/null >"$D/log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$D/$1" 2>/dev/null || true; }
has() { f "$1" | grep -q -- "$2"; }
# the log between the Nth connect and its hangup
conn() { awk -v n="$1" '$1=="connect"{c=$2} c==n{print} $1=="hangup"&&$2==n{exit}' "$D/rtl.log"; }
# whole samples of the fake's pattern: I+Q=255, I rising by one
samples() {
	python3 -I - "$D/$1" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
ok = len(b) > 0 and len(b) % 2 == 0
for i in range(0, len(b) - 1, 2):
    if b[i] + b[i+1] != 255 or (i and b[i] != (b[i-2] + 1) % 256):
        ok = False
        break
print("ok" if ok else "bad %d" % len(b))
EOF
}

grep -q '^R done' "$D/log" || { fail "the driver did not finish"; tail -20 "$D/log"; exit 1; }

[ "$(f ls | tr '\n' ' ')" = "/mnt/sdr/ctl /mnt/sdr/gains /mnt/sdr/iq /mnt/sdr/status " ] &&
	pass "its files" || fail "ls: $(f ls | tr '\n' ' ')"
[ "$(f status.start)" = "link=none readers=0 bytes=0 dropped=0" ] &&
	pass "nothing at first" || fail "status: $(f status.start)"
[ "$(f ctl.start | tr '\n' '|')" = "freq 100000000|rate 2048000|gain auto|ppm 0|agc off|direct off|biastee off|" ] &&
	pass "ctl gives every setting (rtl_tcp's defaults)" || fail "ctl: $(f ctl.start | tr '\n' '|')"
[ -z "$(f iq.nosource)" ] && has err.nosource "no source" &&
	pass "iq with no source refused" || fail "iq: '$(f err.nosource)'"

has status.idle "^link=idle source=tcp!127.0.0.1!$PR tuner=R828D gains=29 readers=0 " &&
	pass "a source dialled: rtl_tcp, its tuner and number of gains" || fail "status: $(f status.idle)"
[ "$(f ctl.source | tr '\n' '|')" = "source tcp!127.0.0.1!$PR|freq 1090000000|rate 250000|gain 38.6|ppm -3|agc off|direct off|biastee off|" ] &&
	pass "settings kept; the gain the nearest the tuner has" || fail "ctl: $(f ctl.source | tr '\n' '|')"
[ "$(f gains | wc -l | tr -d ' ')" = 29 ] && [ "$(f gains | head -1)" = 0.0 ] && [ "$(f gains | tail -1)" = 49.6 ] &&
	pass "gains: the R828D's 29" || fail "gains: $(f gains | tr '\n' ' ')"
! conn 1 | grep -q '^cmd' && conn 1 | grep -q '^hangup 1 ' &&
	pass "the source command's dial, hung up with nothing listening" || fail "conn 1: $(conn 1 | tr '\n' '|')"

want="cmd rate 250000|cmd freq 1090000000|cmd gainmode 1|cmd gain 386|cmd ppm -3|cmd agc 0|cmd direct 0|cmd biastee 0|"
[ "$(conn 2 | grep '^cmd' | tr '\n' '|')" = "$want" ] &&
	pass "the first reader dials; every setting sent" || fail "conn 2: $(conn 2 | tr '\n' '|')"
conn 2 | grep -q '^hangup 2 ' && pass "the last reader gone: hung up" || fail "conn 2 not hung up: $(conn 2 | tr '\n' '|')"
for i in 1 2 3; do
	[ "$(samples iq.$i)" = ok ] || fail "iq.$i: $(samples iq.$i)"
done
python3 -I - "$D" <<'EOF' && pass "reads in whole samples, in order" || fail "reads not one stream"
import sys
b = b"".join(open(sys.argv[1] + "/iq.%d" % i, "rb").read() for i in (1, 2, 3))
sys.exit(0 if len(b) >= 3 * 1024 and all(b[i] + b[i+1] == 255 and (i == 0 or b[i] == (b[i-2] + 1) % 256) for i in range(0, len(b), 2)) else 1)
EOF
has status.closed1 "^link=idle .* readers=0 bytes=[1-9]" && pass "status: idle again, bytes counted" ||
	fail "status: $(f status.closed1)"

has status.two "link=open .* readers=2 " && pass "two readers on one stream" || fail "status: $(f status.two)"
[ "$(conn 3 | grep -c '^connect')" = 1 ] && conn 3 | grep -q '^cmd freq 162025000$' && conn 3 | grep -q '^cmd biastee 1$' &&
	pass "one dial for both; settings written while they read sent at once" || fail "conn 3: $(conn 3 | tr '\n' '|')"
has status.gone "^link=idle .* readers=0 " && conn 3 | grep -q '^hangup 3 ' &&
	pass "both gone: hung up" || fail "status: $(f status.gone); conn 3: $(conn 3 | tail -1)"

has status.dropped "dropped=[1-9]" && pass "a reader that does not read loses the oldest" ||
	fail "status: $(f status.dropped)"
[ "$(samples iq.late)" = ok ] && pass "still in whole samples after a loss" || fail "iq.late: $(samples iq.late)"

has err.notrtl "not rtl_tcp" && pass "something that is not rtl_tcp refused" || fail "notrtl: '$(f err.notrtl)'"
has err.nothing "dial tcp!127.0.0.1!$PN" && pass "nothing listening refused" || fail "nothing: '$(f err.nothing)'"
has err.busy "not greeted in 2 seconds: rtl_tcp busy" && pass "an rtl_tcp busy with another client: refused after -w" ||
	fail "busy: '$(f err.busy)'"
! has ctl.refused "^source" && pass "a refused source leaves none" || fail "ctl: $(f ctl.refused | head -1)"
has err.freq "bad frequency 0" && has err.rate "bad rate 500000" && has err.gain "bad gain loud" &&
	has err.direct "direct: off, i or q" && has err.bogus "unknown command bogus" &&
	pass "bad settings refused" ||
	fail "refusals: '$(f err.freq)' '$(f err.rate)' '$(f err.gain)' '$(f err.direct)' '$(f err.bogus)'"
has err.half "bad rate 1" && has ctl.after "^freq 162025000$" &&
	pass "a write with a bad line: none of it done" || fail "half: '$(f err.half)' $(f ctl.after | head -1)"

[ "$(f status.stop | cut -d' ' -f1)" = link=none ] && ! has status.stop "source=" && pass "stop" ||
	fail "stop: $(f status.stop)"
has again "served already" && pass "a second sdrfs finds it served" || fail "again: '$(f again)'"

[ $failed = 0 ] && echo "sdrfs_test: PASS"
exit $failed

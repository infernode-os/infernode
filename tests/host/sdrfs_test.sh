#!/bin/sh
#
# sdrfs_test.sh — sdrfs(4), an RTL-SDR at /mnt/sdr through rtl_tcp, against
# a fake rtl_tcp (tests/host/sdr/fake_rtl_tcp.py), through
# tests/sdr/drive.sh: its files; settings kept before a source and sent
# whole when it is dialled; a source dialled to see it is rtl_tcp (its
# tuner and gains), its settings sent and the connection held; a reader
# within -l taking it, and -l after the last reader a hang-up (rtl_tcp
# takes 5s to take a new client); each open's header first, in a read
# of its own (rate, enc cu8, freq, an empty line, padded to 4 bytes as
# auplay(1) checks), then reads in whole samples, in order, bytes= what
# readers were given; two readers on one stream, which starts tuned
# (the samples before a new dial's settings took skipped); a setting
# written while they read sent at once; a gain ending neither stream, a
# frequency ending both with end of file after what they had, a reopen
# on the held connection with the new frequency in its header;
# sdr/iqhdr reading a recording's header, and tuning the radio back to
# it; a reader that does not read losing the oldest, still in whole
# samples; localhost dialled as 127.0.0.1; refused: something that is
# not rtl_tcp, nothing listening, an rtl_tcp that does not greet (busy
# with another client), bad settings, an enc not cu8, a write with one
# bad line (none of it done); stop; a second sdrfs finds it served.
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

# a header: its lines joined by |, then "pad" if it and its empty line
# are a multiple of 4 bytes (auplay(1) refuses one that is not), then
# how much follows it, "notwhole" if that is not whole samples in order
hdr() {
	python3 -I - "$D/$1" <<'EOF'
import sys
try:
    b = open(sys.argv[1], "rb").read()
except OSError:
    b = b""
e = b.find(b"\n\n")
if not b.startswith(b"rate") or e < 0:
    print("none")
    sys.exit()
h, r = b[:e + 2], b[e + 2:]
lines = "|".join(l.decode().rstrip(" ") for l in h[:-2].split(b"\n"))
pad = "pad" if len(h) % 4 == 0 else "unpadded %d" % len(h)
whole = len(r) % 2 == 0 and all(r[i] + r[i+1] == 255 and (i == 0 or r[i] == (r[i-2] + 1) % 256) for i in range(0, len(r), 2))
print("%s %s rest=%d%s" % (lines, pad, len(r), "" if whole else " notwhole"))
EOF
}

grep -q '^R done' "$D/log" || { fail "the driver did not finish"; tail -20 "$D/log"; exit 1; }

[ "$(f ls | tr '\n' ' ')" = "/mnt/sdr/ctl /mnt/sdr/gains /mnt/sdr/iq /mnt/sdr/status " ] &&
	pass "its files" || fail "ls: $(f ls | tr '\n' ' ')"
[ "$(f status.start)" = "link=none readers=0 bytes=0 dropped=0 skipped=0" ] &&
	pass "nothing at first" || fail "status: $(f status.start)"
[ "$(f ctl.start | tr '\n' '|')" = "freq 100000000|rate 2048000|enc cu8|gain auto|ppm 0|agc off|direct off|biastee off|" ] &&
	pass "ctl gives every setting (rtl_tcp's defaults)" || fail "ctl: $(f ctl.start | tr '\n' '|')"
[ -z "$(f iq.nosource)" ] && has err.nosource "no source" &&
	pass "iq with no source refused" || fail "iq: '$(f err.nosource)'"

has status.idle "^link=open source=tcp!127.0.0.1!$PR tuner=R828D gains=29 readers=0 " &&
	pass "a source dialled: rtl_tcp, its tuner and number of gains; held" || fail "status: $(f status.idle)"
[ "$(f ctl.source | tr '\n' '|')" = "source tcp!127.0.0.1!$PR|freq 1090000000|rate 250000|enc cu8|gain 38.6|ppm -3|agc off|direct off|biastee off|" ] &&
	pass "settings kept; the gain the nearest the tuner has" || fail "ctl: $(f ctl.source | tr '\n' '|')"
[ "$(f gains | wc -l | tr -d ' ')" = 29 ] && [ "$(f gains | head -1)" = 0.0 ] && [ "$(f gains | tail -1)" = 49.6 ] &&
	pass "gains: the R828D's 29" || fail "gains: $(f gains | tr '\n' ' ')"

want="cmd rate 250000|cmd freq 1090000000|cmd ppm -3|cmd biastee 0|cmd agc 0|cmd direct 0|cmd gainmode 1|cmd gain 386|"
[ "$(conn 1 | grep '^cmd' | tr '\n' '|')" = "$want" ] &&
	pass "the source's dial: every setting sent, the gain last" || fail "conn 1: $(conn 1 | tr '\n' '|')"
[ "$(grep -c '^connect' "$D/rtl.log")" = 4 ] &&
	pass "the reader took the held connection: one dial a phase" || fail "connects: $(grep '^connect' "$D/rtl.log" | tr '\n' ' ')"
[ "$(hdr iq.hdr)" = "rate 250000|enc cu8|freq 1090000000 pad rest=0" ] &&
	pass "an open's header first, in a read of its own, padded to 4 bytes" || fail "iq.hdr: $(hdr iq.hdr)"
for i in 1 2 3; do
	[ "$(samples iq.$i)" = ok ] || fail "iq.$i: $(samples iq.$i)"
done
python3 -I - "$D" <<'EOF' && pass "reads in whole samples, in order" || fail "reads not one stream"
import sys
b = b"".join(open(sys.argv[1] + "/iq.%d" % i, "rb").read() for i in (1, 2, 3))
sys.exit(0 if len(b) >= 3 * 1024 and all(b[i] + b[i+1] == 255 and (i == 0 or b[i] == (b[i-2] + 1) % 256) for i in range(0, len(b), 2)) else 1)
EOF
n=$(cat "$D/iq.1" "$D/iq.2" "$D/iq.3" | wc -c | tr -d ' ')
has status.closed1 "^link=open .* readers=0 bytes=$n " && pass "the reader gone: still held; bytes= what it was given ($n)" ||
	fail "status: $(f status.closed1) (read $n)"
[ "$(f iq.1 | wc -c | tr -d ' ')" = 16384 ] && pass "a read filled from several of the stream's pieces" ||
	fail "iq.1: $(f iq.1 | wc -c) bytes"
has status.hungup "^link=idle .* readers=0 " && conn 1 | grep -q '^hangup 1 ' &&
	pass "-l after the last reader: hung up" || fail "status: $(f status.hungup); conn 1: $(conn 1 | tail -1)"

has status.two "link=open .* readers=2 " && pass "two readers on one stream" || fail "status: $(f status.two)"
[ "$(conn 2 | grep -c '^connect')" = 1 ] && conn 2 | grep -q '^cmd freq 162025000$' && conn 2 | grep -q '^cmd biastee 1$' &&
	pass "one dial for both; settings written while they read sent at once" || fail "conn 2: $(conn 2 | tr '\n' '|')"
conn 2 | grep '^cmd' | tr '\n' '|' | grep -q "cmd direct 0|cmd gainmode 1|cmd gain 197|$" &&
	pass "direct written: the gain sent again after it" || fail "conn 2: $(conn 2 | grep '^cmd' | tr '\n' '|')"
has status.two "skipped=[1-9]" && pass "a new stream starts tuned: samples before its dial's settings took skipped" ||
	fail "status: $(f status.two)"
has status.gain "link=open .* readers=2 " && conn 2 | grep -q '^cmd gain 197$' &&
	pass "a gain written: sent, and neither stream ended" || fail "status: $(f status.gain)"
has status.retune "link=open .* readers=0 " && [ "$(f ended.retune | grep -c ended)" = 2 ] &&
	pass "a frequency written: both streams ended" || fail "status: $(f status.retune); ended: $(f ended.retune | tr '\n' ' ')"
case "$(hdr iq.two1)" in
"rate 250000|enc cu8|freq 1090000000 pad rest="*[0-9]) pass "a stream ended: its header, then whole samples, then end of file ($(hdr iq.two1))";;
*) fail "iq.two1: $(hdr iq.two1)";;
esac
[ "$(hdr hdr.retuned)" = "rate 250000|enc cu8|freq 162025000 pad rest=0" ] &&
	pass "reopened: the new frequency in its header" || fail "hdr.retuned: $(hdr hdr.retuned)"
[ "$(conn 2 | grep -c '^connect')" = 1 ] && pass "reopened on the held connection: no dial" || fail "conn 2: $(conn 2 | grep '^connect')"
[ "$(f iqhdr.two1 | tr '\n' '|')" = "rate 250000|enc cu8|freq 1090000000|" ] &&
	pass "sdr/iqhdr: a recording's header lines" || fail "iqhdr: $(f iqhdr.two1 | tr '\n' '|')"
has status.gone "^link=open .* readers=0 " &&
	pass "both gone: held" || fail "status: $(f status.gone)"
has status.gone2 "^link=idle .* readers=0 " && conn 2 | grep -q '^hangup 2 ' &&
	pass "then hung up" || fail "status: $(f status.gone2); conn 2: $(conn 2 | tail -1)"

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
has err.enc "bad enc cs16: cu8 only" && [ -z "$(f err.enccu8)" ] &&
	pass "enc cu8 taken; nothing else" || fail "enc: '$(f err.enc)' '$(f err.enccu8)'"
has err.half "bad rate 1" && has ctl.after "^freq 162025000$" &&
	pass "a write with a bad line: none of it done" || fail "half: '$(f err.half)' $(f ctl.after | head -1)"

[ "$(f status.stop | cut -d' ' -f1)" = link=none ] && ! has status.stop "source=" && pass "stop" ||
	fail "stop: $(f status.stop)"
[ -z "$(f err.localhost)" ] && has ctl.localhost "^source tcp!127.0.0.1!$PR$" &&
	pass "localhost dialled as 127.0.0.1" || fail "localhost: '$(f err.localhost)' $(f ctl.localhost | head -1)"
has ctl.iqhdr "^freq 1090000000$" && has ctl.iqhdr "^rate 250000$" &&
	pass "sdr/iqhdr's lines written to ctl: tuned back to the recording" || fail "ctl: $(f ctl.iqhdr | tr '\n' '|')"
has again "served already" && pass "a second sdrfs finds it served" || fail "again: '$(f again)'"

[ $failed = 0 ] && echo "sdrfs_test: PASS"
exit $failed

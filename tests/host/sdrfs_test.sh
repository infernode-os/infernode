#!/bin/sh
#
# sdrfs_test.sh — sdrfs(4), an RTL-SDR at /mnt/sdr through rtl_tcp, against
# a fake rtl_tcp (tests/host/sdr/fake_rtl_tcp.py), through
# tests/sdr/drive.sh: its files; settings kept before a source and sent
# whole when it is dialled; a source dialled to see it is rtl_tcp (its
# tuner and gains), its settings sent and the connection held; a reader
# within -l taking it, and -l after the last reader a hang-up (rtl_tcp
# takes 5s to take a new client); reads in whole samples, in order,
# bytes= what readers were given; two readers on one stream, a setting
# written while they read sent at once and the samples tuned before it
# skipped; a reader that does not read losing the oldest, still in
# whole samples; localhost dialled as 127.0.0.1; refused: something that is not rtl_tcp, nothing
# listening, an rtl_tcp that does not greet (busy with another
# client), bad settings, a write with one bad line (none of it done);
# stop; a second sdrfs finds it served; a server that is not posted
# (-S) gone whole two seconds after its mount, its reader and its
# timers with it (they stayed, and rtl_tcp, which takes one client,
# stayed taken).  Each open of iq starts with a
# header (#1094): rate, enc cu8 and freq in audio(6)'s form, given by a
# read of its own; a setting it does not say (ppm) ends no stream, a
# retune ends every one, and opened again a stream has the new header
# on the held connection; enc cu8 taken by ctl, any other refused.
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
# whole samples of the fake's pattern: I+Q=255, I rising by one.
# With "lossy", I may jump: what a reader that fell behind is given is
# in whole samples, and in order, but not without gaps.  A read of 16K
# is two 9P reads, and the oldest chunk may be dropped between them.
# The chunks are what each read of the socket gave: of the fake's 16K
# pieces as they were sent, a multiple of 256 samples, so a gap did not
# show in I; on a busy machine TCP gives them in other sizes, and the
# check, which asked for no gap, failed there (CI: "bad 16384").
samples() {
	python3 -I - "$D/$1" "${2:-}" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
lossy = sys.argv[2] == "lossy"
if b.startswith(b"rate"):
    b = b[b.index(b"\n\n") + 2:]	# a header, checked by hdr
ok = len(b) > 0 and len(b) % 2 == 0
for i in range(0, len(b) - 1, 2):
    if b[i] + b[i+1] != 255 or (i and not lossy and b[i] != (b[i-2] + 1) % 256):
        ok = False
        break
print("ok" if ok else "bad %d" % len(b))
EOF
}

# a header's lines, joined by |, if it is padded to a multiple of 4 bytes
hdr() {
	python3 -I - "$D/$1" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
i = b.find(b"\n\n")
h = b[:i + 2] if i >= 0 else b""
if i < 0 or len(h) % 4:
    print("bad %r" % b[:80])
else:
    print("|".join(l.strip() for l in h.decode().split("\n") if l.strip()))
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
# (the fifth is the unposted server's, at the end)
[ "$(grep -c '^connect' "$D/rtl.log")" = 5 ] &&
	pass "the reader took the held connection: one dial a phase" || fail "connects: $(grep '^connect' "$D/rtl.log" | tr '\n' ' ')"
[ "$(hdr iq.hdr)" = "rate 250000|enc cu8|freq 1090000000" ] && [ "$(wc -c < "$D/iq.hdr" | tr -d ' ')" = 40 ] &&
	pass "iq starts with its header, alone in the first read" || fail "iq.hdr: $(hdr iq.hdr)"
for i in 1 2 3; do
	[ "$(samples iq.$i)" = ok ] || fail "iq.$i: $(samples iq.$i)"
done
python3 -I - "$D" <<'EOF' && pass "reads in whole samples, in order" || fail "reads not one stream"
import sys
b = b"".join(open(sys.argv[1] + "/iq.%d" % i, "rb").read() for i in (1, 2, 3))
sys.exit(0 if len(b) >= 3 * 1024 and all(b[i] + b[i+1] == 255 and (i == 0 or b[i] == (b[i-2] + 1) % 256) for i in range(0, len(b), 2)) else 1)
EOF
n=$(cat "$D/iq.hdr" "$D/iq.1" "$D/iq.2" "$D/iq.3" | wc -c | tr -d ' ')
has status.closed1 "^link=open .* readers=0 bytes=$n " && pass "the reader gone: still held; bytes= what it was given ($n)" ||
	fail "status: $(f status.closed1) (read $n)"
[ "$(f iq.1 | wc -c | tr -d ' ')" = 16384 ] && pass "a read filled from several of the stream's pieces" ||
	fail "iq.1: $(f iq.1 | wc -c) bytes"
has status.hungup "^link=idle .* readers=0 " && conn 1 | grep -q '^hangup 1 ' &&
	pass "-l after the last reader: hung up" || fail "status: $(f status.hungup); conn 1: $(conn 1 | tail -1)"

has status.two "link=open .* readers=2 " && pass "two readers on one stream" || fail "status: $(f status.two)"
has status.ppm "link=open .* readers=2 " && pass "a setting the header does not say ends no stream" || fail "status: $(f status.ppm)"
has status.retuned "^link=open .* readers=0 " && pass "a retune ends every stream; the connection held" || fail "status: $(f status.retuned)"
[ "$(hdr iq.r1)" = "rate 250000|enc cu8|freq 1090000000" ] && [ "$(samples iq.r1)" = ok ] &&
	pass "the ended stream: its own header, then whole samples, then its end" || fail "iq.r1: $(hdr iq.r1) $(samples iq.r1)"
[ "$(hdr iq.r2)" = "rate 250000|enc cu8|freq 162025000" ] && [ "$(samples iq.r2)" = ok ] &&
	pass "opened again: the new frequency's header" || fail "iq.r2: $(hdr iq.r2) $(samples iq.r2)"
[ "$(conn 2 | grep -c '^connect')" = 1 ] && conn 2 | grep -q '^cmd freq 162025000$' && conn 2 | grep -q '^cmd biastee 1$' &&
	pass "one dial for both; settings written while they read sent at once" || fail "conn 2: $(conn 2 | tr '\n' '|')"
conn 2 | grep '^cmd' | tr '\n' '|' | grep -q "cmd direct 0|cmd gainmode 1|cmd gain 386|$" &&
	pass "direct written: the gain sent again after it" || fail "conn 2: $(conn 2 | grep '^cmd' | tr '\n' '|')"
has status.gone "skipped=[1-9]" && pass "samples arriving as a setting took: skipped" || fail "status: $(f status.gone)"
has status.gone "^link=open .* readers=0 " &&
	pass "both gone: held" || fail "status: $(f status.gone)"
has status.gone2 "^link=idle .* readers=0 " && conn 2 | grep -q '^hangup 2 ' &&
	pass "then hung up" || fail "status: $(f status.gone2); conn 2: $(conn 2 | tail -1)"

has status.dropped "dropped=[1-9]" && pass "a reader that does not read loses the oldest" ||
	fail "status: $(f status.dropped)"
[ "$(samples iq.late lossy)" = ok ] && pass "still in whole samples after a loss" || fail "iq.late: $(samples iq.late lossy)"

has err.notrtl "not rtl_tcp" && pass "something that is not rtl_tcp refused" || fail "notrtl: '$(f err.notrtl)'"
has err.nothing "dial tcp!127.0.0.1!$PN" && pass "nothing listening refused" || fail "nothing: '$(f err.nothing)'"
has err.busy "not greeted in 2 seconds: rtl_tcp busy" && pass "an rtl_tcp busy with another client: refused after -w" ||
	fail "busy: '$(f err.busy)'"
! has ctl.refused "^source" && pass "a refused source leaves none" || fail "ctl: $(f ctl.refused | head -1)"
has err.freq "bad frequency 0" && has err.rate "bad rate 500000" && has err.gain "bad gain loud" &&
	has err.direct "direct: off, i or q" && has err.bogus "unknown command bogus" &&
	has err.enc "cu8 is the only encoding" && [ "$(f ctl.after | grep -c '^enc cu8$')" = 1 ] &&
	pass "bad settings refused" ||
	fail "refusals: '$(f err.freq)' '$(f err.rate)' '$(f err.gain)' '$(f err.direct)' '$(f err.bogus)' '$(f err.enc)'"
has err.half "bad rate 1" && has ctl.after "^freq 162025000$" &&
	pass "a write with a bad line: none of it done" || fail "half: '$(f err.half)' $(f ctl.after | head -1)"

[ "$(f status.stop | cut -d' ' -f1)" = link=none ] && ! has status.stop "source=" && pass "stop" ||
	fail "stop: $(f status.stop)"
[ -z "$(f err.localhost)" ] && has ctl.localhost "^source tcp!127.0.0.1!$PR$" &&
	pass "localhost dialled as 127.0.0.1" || fail "localhost: '$(f err.localhost)' $(f ctl.localhost | head -1)"
has again "served already" && pass "a second sdrfs finds it served" || fail "again: '$(f again)'"

b=$(f procs.before | tr -d ' '); u=$(f procs.during | tr -d ' '); a=$(f procs.after | tr -d ' ')
[ -z "$(f err.unposted)" ] && [ -n "$b" ] && [ "${u:-0}" -gt "$b" ] && [ "$a" -le "$b" ] && grep -q '^hangup 5' "$D/rtl.log" &&
	pass "an unposted server ends whole with its mount ($b sdrfs processes before, $u while it ran, $a after)" ||
	fail "an unposted server after its mount went: $b processes before, $u while it ran, $a after; '$(f err.unposted)'"

[ $failed = 0 ] && echo "sdrfs_test: PASS"
exit $failed

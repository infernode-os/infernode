#!/bin/sh
#
# sdr_demod_test.sh — sdr(1)'s demodulators, sdr/fm and sdr/am, on
# synthetic samples (tests/host/sdr/synth_iq.py) as an RTL-SDR gives
# them, through tests/sdr/demod.sh: a tone sent by wide FM, narrow FM and
# AM comes out as that tone, clean (its SINAD), at the rate and in the
# channels asked for, with noise 40 dB down and a second carrier as
# strong 400 kHz up that must not be heard; bad rates and bandwidths
# refused; and the same through sdrfs(4) from a fake rtl_tcp
# (tests/host/sdr/fake_rtl_tcp.py) in real time, nothing dropped.  Run
# under the JIT and the interpreter.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/sdr/fm.dis dis/sdr/am.dis dis/lib/sdrdsp.dis dis/sdrfs.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }
python3 -I -c 'import numpy' 2>/dev/null || { echo "SKIP: python3 numpy not found"; exit 77; }

T=tmp/sdr_demod_test.$$
D="$ROOT/$T"
mkdir -p "$D"
PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; rm -rf "$D"' EXIT

S="$ROOT/tests/host/sdr/synth_iq.py"
# kind rate seconds deviation-or-depth tone offset
python3 -I "$S" fm 2400000 2 50000 1000 20000 "$D/wfm.u8"
python3 -I "$S" fm 2048000 2 3000 700 -5000 "$D/nfm.u8"
python3 -I "$S" am 2400000 2 0.6 800 1500 "$D/am.u8"

python3 -I "$ROOT/tests/host/sdr/fake_rtl_tcp.py" serve "$D/rtl.log" 6 "$D/wfm.u8" > "$D/rtl.port" 2>"$D/rtl.err" &
PIDS="$PIDS $!"
for i in $(seq 50); do [ -s "$D/rtl.port" ] && break; sleep 0.1; done
PR=$(head -1 "$D/rtl.port")
[ -n "$PR" ] || { echo "FAIL: the fake rtl_tcp did not start"; cat "$D/rtl.err"; exit 1; }

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$D/$1" 2>/dev/null || true; }
has() { f "$1" | grep -q -- "$2"; }
# tone=F sinad=S peak=P n=N of a sound
tone() { python3 -I "$S" tone "$D/$1" "$2" "$3"; }
val() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
# a sound's tone is want, its SINAD at least min dB
check() {	# what file rate chans want min
	m=$(tone "$2" "$3" "$4")
	t=$(val "$m" tone)
	s=$(val "$m" sinad)
	if [ "$t" -ge $(($5 - 5)) ] && [ "$t" -le $(($5 + 5)) ] &&
		python3 -I -c "import sys; sys.exit(0 if float('$s') >= $6 else 1)"; then
		pass "$1: $m"
	else
		fail "$1: $m, want tone=$5 sinad>=$6"
	fi
}
# a sound lasts secs at rate, in chans
size() {	# what file rate chans secs
	n=$(wc -c < "$D/$2")
	want=$(($3 * $4 * 2 * $5))
	if [ "$n" -ge $((want - want / 100)) ] && [ "$n" -le $((want + want / 100)) ]; then
		pass "$1: $n bytes"
	else
		fail "$1: $n bytes, want about $want"
	fi
}

cd "$ROOT"
for c in 1 0; do
	echo "-c$c"
	rm -f "$D"/*.pcm "$D"/err.* "$D"/status.*
	with_timeout 120 "$EMU" -c$c -r"$ROOT" /dis/sh.dis /tests/sdr/demod.sh "/$T" "$PR" \
		</dev/null >"$D/log" 2>&1 || true
	grep -q '^R done' "$D/log" || { fail "the driver did not finish"; tail -20 "$D/log"; continue; }

	check "wide FM, 48k out" wfm.pcm 48000 2 1000 50
	size "wide FM: 2 seconds of 48k stereo" wfm.pcm 48000 2 2
	check "wide FM, /dev/audio's 8000 by default" wfm8.pcm 8000 2 1000 45
	size "wide FM: 2 seconds of 8000 stereo" wfm8.pcm 8000 2 2
	check "wide FM, 22050 out" wfm22.pcm 22050 2 1000 45
	size "wide FM: 2 seconds of 22050 stereo" wfm22.pcm 22050 2 2
	check "narrow FM" nfm.pcm 22050 2 700 35
	check "AM, one channel" am.pcm 22050 1 800 40
	size "AM: 2 seconds of 22050 mono" am.pcm 22050 1 2

	has err.low "rate in 10000 too low" && pass "a rate in too low refused" || fail "low: '$(f err.low)'"
	has err.rate "usage" && pass "a bad rate refused" || fail "rate: '$(f err.rate)'"
	has err.bw "usage" && pass "a bad bandwidth refused" || fail "bw: '$(f err.bw)'"

	check "through sdrfs, in real time" live.pcm 48000 2 1000 45
	has status.live "dropped=0 " && has status.live "readers=1 " &&
		pass "through sdrfs: nothing dropped" || fail "status: $(f status.live)"
done

[ $failed = 0 ] && echo "sdr_demod_test: PASS"
exit $failed

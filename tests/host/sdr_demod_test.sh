#!/bin/sh
#
# sdr_demod_test.sh — sdr(1)'s demodulators, sdr/fm and sdr/am, on
# synthetic samples (tests/host/sdr/synth_iq.py) as an RTL-SDR gives
# them, a header put on by sdr/rawiq and read back by sdr/iqhdr,
# through tests/sdr/demod.sh: a tone sent by wide FM, narrow FM and AM
# comes out as that tone, clean (its SINAD), at the rate and in the
# channels asked for, the rate in taken from the header, with noise
# 40 dB down and a second carrier as strong 400 kHz up that must not be
# heard; the sound's own header (audio(6)) read by auplay(1)'s parse,
# -R leaving it out; input with no header, an enc not cu8, -r, bad
# rates and bandwidths refused; and the same through sdrfs(4) from a
# fake rtl_tcp (tests/host/sdr/fake_rtl_tcp.py) in real time, nothing
# dropped, sdr/fm ending at a retune.  Run under the JIT and the
# interpreter.
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
	rm -f "$D"/*.pcm "$D"/*.au "$D"/*.iq "$D"/*.hdr "$D"/auhdr.* "$D"/err.* "$D"/status.* "$D"/live.*
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

	[ "$(f wfm.hdr | tr '\n' '|')" = "rate 2400000|enc cu8|freq 98000000|" ] &&
		[ "$(f nfm.hdr | tr '\n' '|')" = "rate 2048000|enc cu8|" ] &&
		pass "sdr/rawiq's header read back by sdr/iqhdr" || fail "iqhdr: $(f wfm.hdr | tr '\n' '|') $(f nfm.hdr | tr '\n' '|')"
	python3 -I - "$D" <<'EOF' && pass "sdr/rawiq: its header padded to 4 bytes, the samples after it unchanged" || fail "wfm.iq not wfm.u8 with a header"
import sys
d = sys.argv[1]
b = open(d + "/wfm.iq", "rb").read()
e = b.find(b"\n\n") + 2
sys.exit(0 if e % 4 == 0 and b[e:] == open(d + "/wfm.u8", "rb").read() else 1)
EOF
	[ "$(f auhdr.fm | sed 's/ *$//' | tr '\n' '|')" = "rate 22050|chans 2|bits 16|enc pcm|" ] &&
		[ "$(f auhdr.am | sed 's/ *$//' | tr '\n' '|')" = "rate 8000|chans 1|bits 16|enc pcm|" ] &&
		pass "the sound's header as auplay reads it" || fail "auplay: '$(f auhdr.fm)' '$(f auhdr.am)'"
	python3 -I - "$D/wfm.au" "$D/wfm.au.pcm" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(b[b.find(b"\n\n") + 2:])
EOF
	check "wide FM with its header" wfm.au.pcm 22050 2 1000 45

	has err.nohdr "no header" && has err.amnohdr "no header" && has err.empty "no header" &&
		pass "input with no header refused" || fail "no header: '$(f err.nohdr)' '$(f err.amnohdr)' '$(f err.empty)'"
	has err.enc "enc cs16: cu8" && has err.amenc "enc cs16: cu8" &&
		pass "an enc not cu8 refused" || fail "enc: '$(f err.enc)' '$(f err.amenc)'"
	has err.r "usage" && ! has err.r "-r" && pass "-r is gone" || fail "-r: '$(f err.r)'"
	has err.low "rate in 10000 too low" && pass "a rate in too low refused" || fail "low: '$(f err.low)'"
	has err.rate "usage" && has err.norate "usage" && pass "sdr/rawiq: a bad rate, or none, refused" ||
		fail "rate: '$(f err.rate)' '$(f err.norate)'"
	has err.bw "usage" && pass "a bad bandwidth refused" || fail "bw: '$(f err.bw)'"
	has err.iqhdr "no header" && pass "sdr/iqhdr: no header refused" || fail "iqhdr: '$(f err.iqhdr)'"

	check "through sdrfs, in real time" live.pcm 48000 2 1000 45
	has status.live "dropped=0 " && has status.live "readers=1 " &&
		pass "through sdrfs: nothing dropped" || fail "status: $(f status.live)"
	[ "$(f live.end)" = "ended " ] && pass "through sdrfs: a retune ends sdr/fm, cleanly" || fail "live: '$(f live.end)'"
done

[ $failed = 0 ] && echo "sdr_demod_test: PASS"
exit $failed

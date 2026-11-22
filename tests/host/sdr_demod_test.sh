#!/bin/sh
#
# sdr_demod_test.sh — sdr(1)'s demodulators, sdr/fm and sdr/am, on
# synthetic samples (tests/host/sdr/synth_iq.py) as an RTL-SDR gives
# them, through tests/sdr/demod.sh: a tone sent by wide FM, narrow FM and
# AM comes out as that tone, clean (its SINAD), at the rate and in the
# channels asked for, with noise 40 dB down and a second carrier as
# strong 400 kHz up that must not be heard.  The rate in is the
# samples' header's (#1094): sdr/rawiq gives a capture one, a header
# split across reads is read whole, the sound starts with audio(6)'s
# header (rate, chans, bits, enc) or with -R not, auplay takes that
# header for audioctl through a pipe, and sdr/iqhdr gives a recording's
# header as ctl commands.  Refused: input with no header, an enc not
# cu8, -r (gone), bad rates and bandwidths.  Then through sdrfs(4) from
# a fake rtl_tcp (tests/host/sdr/fake_rtl_tcp.py) in real time, nothing
# dropped, and sdr/iqhdr retuning it.  Run under the JIT and the
# interpreter.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/sdr/fm.dis dis/sdr/am.dis dis/sdr/rawiq.dis dis/sdr/iqhdr.dis dis/lib/sdrdsp.dis dis/sdrfs.dis; do
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

# a sound's audio(6) header is want (lines joined by |), padded to a
# multiple of 4 bytes; the sound after it into file.pcm
auhdr() {	# file want
	python3 -I - "$D/$1" "$2" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
i = b.find(b"\n\n")
if i < 0:
    print("no header"); sys.exit(1)
h = b[:i + 2]
lines = [l.strip() for l in h.decode().split("\n") if l.strip()]
open(sys.argv[1][:-3] + ".pcm", "wb").write(b[i + 2:])
if "|".join(lines) != sys.argv[2] or len(h) % 4:
    print("header %r (%d bytes)" % (h, len(h))); sys.exit(1)
EOF
}

cd "$ROOT"
for c in 1 0; do
	echo "-c$c"
	rm -rf "$D"/*.pcm "$D"/*.au "$D"/*.iq "$D"/err.* "$D"/status.* "$D"/dev "$D"/iqhdr.out "$D"/ctl.*
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

	m=$(auhdr wfm.au 'rate 48000|chans 2|bits 16|enc pcm') &&
		pass "wide FM: the sound's header says its format" || fail "wfm.au: $m"
	check "wide FM, after its header" wfm.pcm 48000 2 1000 50
	m=$(auhdr am.au 'rate 22050|chans 1|bits 16|enc pcm') &&
		pass "AM: the sound's header, one channel" || fail "am.au: $m"
	check "AM, after its header" am.pcm 22050 1 800 40
	check "AM, its header read a byte at a time" amsplit.pcm 22050 1 800 40
	size "AM: the split header's 2 seconds" amsplit.pcm 22050 1 2
	[ "$(f iqhdr.out | tr '\n' '|')" = "rate 2400000|enc cu8|freq 99500000|" ] &&
		pass "sdr/iqhdr: the header as commands" || fail "iqhdr: $(f iqhdr.out | tr '\n' '|')"
	[ "$(f dev/audioctl | tr -s ' \n' '  ')" = "rate 44100 chans 2 bits 16 enc pcm " ] &&
		[ "$(wc -c < "$D/dev/audio")" -gt 300000 ] &&
		pass "auplay through a pipe: the header to audioctl, the sound to audio" ||
		fail "auplay: audioctl '$(f dev/audioctl)', audio $(wc -c < "$D/dev/audio" 2>/dev/null) bytes"

	has err.low "rate in 10000 too low" && pass "a rate in too low refused" || fail "low: '$(f err.low)'"
	has err.nohdr "no header: it does not start with rate" && pass "samples with no header refused" || fail "nohdr: '$(f err.nohdr)'"
	has err.empty "no header: no input" && pass "no input refused" || fail "empty: '$(f err.empty)'"
	has err.enc "enc s16, not cu8" && pass "an enc not cu8 refused" || fail "enc: '$(f err.enc)'"
	has err.r "usage" && pass "-r is gone: the rate is the header's" || fail "-r: '$(f err.r)'"
	has err.rate "usage" && pass "a bad rate refused" || fail "rate: '$(f err.rate)'"
	has err.bw "usage" && pass "a bad bandwidth refused" || fail "bw: '$(f err.bw)'"
	has err.iqhdr "no header" && pass "sdr/iqhdr: no header refused" || fail "iqhdr: '$(f err.iqhdr)'"

	m=$(auhdr live.au 'rate 48000|chans 2|bits 16|enc pcm') &&
		pass "through sdrfs: the rate taken from iq's header" || fail "live.au: $m"
	check "through sdrfs, in real time" live.pcm 48000 2 1000 45
	has status.live "dropped=0 " && has status.live "readers=1 " &&
		pass "through sdrfs: nothing dropped" || fail "status: $(f status.live)"
	has ctl.iqhdr "^rate 2400000$" && has ctl.iqhdr "^freq 99500000$" &&
		pass "sdr/iqhdr retunes sdrfs to a recording's" || fail "ctl: $(f ctl.iqhdr | tr '\n' '|')"
done

[ $failed = 0 ] && echo "sdr_demod_test: PASS"
exit $failed

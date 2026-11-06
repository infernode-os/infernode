#!/bin/sh
#
# devspeech_test.sh -- the emulator's own speech engine (#W,
# emu/port/devspeech.c) through tests/speech/native.sh: speech(4)'s
# engine files (ctl read: name native, rate 16000, what is built in);
# with flite, synthesis that is speech (voiced frames, a pitch in a
# voice's range, longer for more words) and a second voice lower than
# the first; a voice not built in, a model or language that is not a
# name, a bad verb and a read of audio refused; an utterance's end
# reaching every reader of text (with whisper.cpp and a model fetched
# by tools/speech-models.sh, the engine's own sentence heard back as
# its words; without, the reason none can be); and speech9p over #W,
# its say heard from the shared device's fake speaker.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/veltro/speech9p.dis" ] || { echo "SKIP: speech9p not built"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

T=tmp/devspeech_test.$$
mkdir -p "$ROOT/$T"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
INFERNODE_AUDIO_FAKE=1 SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; run /tests/speech/native.sh" \
	</dev/null >"$T/log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$T/n.$1" 2>/dev/null || true; }
has() { grep -q -- "$2" "$T/n.$1" 2>/dev/null; }

if ! grep -q '^R done' "$T/log"; then
	if grep -q "'#W'.*does not exist\|#W/ctl.*does not exist" "$T/log"; then
		echo "SKIP: $EMU has no #W"; exit 77
	fi
	fail "the driver did not finish"; grep -v '^fs:' "$T/log" | tail -20; exit 1
fi

has ctl '^name native$' && has ctl '^rate 16000$' && has ctl '^stt ' && has ctl '^tts ' &&
	pass "ctl: name native, rate 16000, what is built in ($(grep -h '^stt\|^tts' "$T/n.ctl" | tr '\n' ' '))" ||
	fail "ctl: $(f ctl | tr '\n' '|')"
[ -s "$T/n.bad.model" ] && [ -s "$T/n.bad.lang" ] && [ -s "$T/n.bad.verb" ] && [ -s "$T/n.bad.audio" ] &&
	pass "a model or language that is not a name, a bad verb and a read of audio refused" ||
	fail "refusals: model '$(f bad.model)' lang '$(f bad.lang)' verb '$(f bad.verb)' audio '$(f bad.audio)'"

# speech in 16 kHz mono: ms, the fraction of 20 ms frames loud, the
# pitch of the voiced frames (autocorrelation), its median
voiced() {
	python3 -I - "$1" <<'PY'
import sys, struct, math
try: raw = open(sys.argv[1], 'rb').read()
except OSError: raw = b''
x = struct.unpack('<%dh' % (len(raw)//2), raw[:len(raw)//2*2])
W = 320; fr = [x[i:i+W] for i in range(0, len(x) - 2*W, W)]
loud = [i for i, f in enumerate(fr) if math.sqrt(sum(v*v for v in f)/W) > 800]
f0 = []
for i in loud[::2]:
    f = x[i*W:i*W+2*W]
    def ac(L): return sum(f[j]*f[j+L] for j in range(len(f)-L))
    best = max(range(40, 200), key=ac)
    if ac(best) > 0.4 * ac(0): f0.append(16000 / best)
f0.sort()
print(len(x)*1000//16000, (100*len(loud)//len(fr)) if fr else 0, int(f0[len(f0)//2]) if f0 else 0)
PY
}
if has ctl '^tts flite'; then
	has voices '^slt$' && has voices '^rms$' && pass "the voices built in listed" || fail "voices: $(f voices | tr '\n' ' ')"
	set -- $(voiced "$T/n.short.raw"); sms=$1
	set -- $(voiced "$T/n.long.raw"); lms=$1; lloud=$2; lf0=$3
	[ "$lloud" -ge 40 ] && [ "$lf0" -ge 140 ] && [ "$lf0" -le 300 ] &&
		pass "synthesis is speech: ${lms} ms, ${lloud}% of it loud, pitch about ${lf0} Hz (slt)" ||
		fail "synthesis: ${lms} ms, ${lloud}% loud, pitch ${lf0} Hz"
	[ "$sms" -gt 200 ] && [ "$lms" -gt $((sms * 3)) ] && pass "longer for more words (${sms} ms, then ${lms} ms)" ||
		fail "lengths: ${sms} ms and ${lms} ms"
	set -- $(voiced "$T/n.rms.raw"); rf0=$3
	[ "$rf0" -ge 70 ] && [ "$rf0" -lt "$lf0" ] && pass "voice rms: lower, about ${rf0} Hz" || fail "rms's pitch ${rf0} Hz, slt's ${lf0}"
	[ -s "$T/n.bad.voice" ] && pass "a voice not built in refused" || fail "voice nobody was taken"
	ms=$(python3 -I - "$T/n.speaker.raw" <<'PY'
import sys, struct
try: raw = open(sys.argv[1], 'rb').read()
except OSError: raw = b''
x = [struct.unpack_from('<h', raw, 4*i)[0] for i in range(len(raw)//4)]
print(sum(1 for i in range(0, len(x) - 960, 960) if max(abs(v) for v in x[i:i+960]) > 1500) * 20)
PY
)
	[ "$ms" -ge 600 ] && pass "speech9p over #W: say played as speech through the shared device (${ms} ms loud)" ||
		fail "speech9p over #W played ${ms} ms"
	has ctl.voice '^voice awb$' && pass "speech's voice reaches #W" || fail "#W's voice after speech's: $(f ctl.voice | grep voice)"
	[ "$(f speech.voices)" = "$(f voices)" ] && pass "speech's voices are #W's" || fail "speech's voices: $(f speech.voices | tr '\n' ' ')"
else
	echo "SKIP: synthesis ($EMU was built without flite)"
fi

for r in 1 2; do
	if has ctl '^stt whisper'; then
		if [ -f "$ROOT/lib/speech/models/ggml-tiny.en.bin" ]; then
			grep -qi 'final confidence=[0-9.]* .*quick brown fox' "$T/n.text.$r" &&
				pass "reader $r: the engine's own sentence heard back: $(head -1 "$T/n.text.$r")" ||
				fail "reader $r: $(f text.$r | tr '\n' '|')"
		else
			echo "SKIP: recognition (no model: tools/speech-models.sh ggml-tiny.en.bin)"
		fi
	else
		has text.$r '^error no recogniser built in' && pass "reader $r: told there is no recogniser built in" ||
			fail "reader $r: $(f text.$r | tr '\n' '|')"
	fi
done
has ctl.after '^utterances 1$' && pass "the utterance counted" || fail "ctl after: $(f ctl.after | tr '\n' '|')"

exit $failed

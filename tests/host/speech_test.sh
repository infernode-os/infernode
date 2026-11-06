#!/bin/sh
#
# speech_test.sh — speech(4), /mnt/speech, on the shared audio device
# with its fake hardware ($INFERNODE_AUDIO_FAKE) and the fake engine
# (tests/speechfake.b), through tests/speech/drive.sh: the engine found;
# talk's readers told each change; push to talk carrying the microphone
# to the engine (its peak seen there) and its partial and final to both
# readers of listen; say queued, read as speaking then idle, its sound
# played (the fake engine's 440 Hz, 100 ms a word, decoded from what the
# speaker played); with duplex half the microphone not given to the
# engine while speech plays, with full it is; cancel stopping speech at
# once and dropping the queue; a chime played; hear, the old interface,
# giving the words of the next final; ask, an agent's, waiting for the
# user without opening the microphone (talk reads "off asked"), given
# only an utterance begun after it, and opening the microphone itself
# only with agentmic on; the settings kept in a file and read by a
# speech9p started again; the engine's voices; bad ctl and talk writes
# refused.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/speech9p.dis dis/tests/speechfake.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

T=tmp/speech_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
printf 'call sarah at work\nhalf\nfull\nhello there\nwhat time is it\ndictated before\nagent opened\nhey veltro what time is it\nthe weather is nice\nhey veltro\nopen the mail\nHey, Voltro. Call home.\nVeltro, read my messages\na dictated line\nveltro stop the music\nnot heard\n' > "$T/script"
python3 -I - "$T/tone.raw" <<'PY'
import sys, struct, math
with open(sys.argv[1], 'wb') as f:
    for i in range(int(48000 * 0.6)):
        v = int(7000 * math.sin(2 * math.pi * 700 * i / 48000))
        f.write(struct.pack('<hh', v, v))
PY

INFERNODE_AUDIO_FAKE=1 SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; run /tests/speech/drive.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$T/$1" 2>/dev/null || true; }
has() { grep -q -- "$2" "$T/$1" 2>/dev/null; }
num() { sed -n "s/^$2 //p" "$T/$1" 2>/dev/null | head -1; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; tail -20 "$LOG"; exit 1; }

has ctl.start '^engine ok' && has ctl.start '^duplex half' && has ctl.start '^talk off' &&
	pass "ctl: the engine answers, duplex half, talk off" || fail "ctl at start: $(f ctl.start | tr '\n' '|')"
has ctl.talking '^talk on' && pass "talk start turns talk on" || fail "ctl while talking: $(f ctl.talking | tr '\n' '|')"
[ "$(head -3 "$T/talk.log" 2>/dev/null | tr '\n' ' ')" = "off on off " ] &&
	pass "a reader of talk is told each change (off on off)" || fail "talk's reader saw: $(f talk.log | tr '\n' ' ')"

for r in 1 2; do
	if has listen.$r '^partial confidence=0.40 call$' && has listen.$r '^final confidence=0.93 call sarah at work$'; then
		pass "listener $r heard the partial and the final"
	else
		fail "listener $r: $(f listen.$r | tr '\n' '|')"
	fi
done
heard=$(num talk.engine heard); peak=$(num talk.engine peak)
[ "${heard:-0}" -ge 300 ] && [ "${peak:-0}" -ge 3000 ] &&
	pass "push to talk carried the microphone to the engine (${heard} ms, peak $peak)" ||
	fail "the engine heard ${heard:-?} ms, peak ${peak:-?}"

has say.during '^speaking one two three' && pass "say: speaking while it plays" || fail "say while speaking: $(f say.during)"
has say.after '^idle' && pass "say: idle once played" || fail "say after: $(f say.after)"

# how long hz sounds in a 48 kHz stereo recording (20 ms blocks)
tonems() {
	python3 -I - "$1" "$2" <<'PY'
import sys, struct, math
try:
    raw = open(sys.argv[1], 'rb').read()
except OSError:
    raw = b''
hz = float(sys.argv[2]); R = 48000; W = R // 50
x = [struct.unpack_from('<h', raw, 4*i)[0] for i in range(len(raw)//4)]
def lv(a):
    k = 2*math.cos(2*math.pi*hz/R); s1 = s2 = 0.0
    for v in x[a:a+W]:
        s0 = v + k*s1 - s2; s2 = s1; s1 = s0
    return 2*math.sqrt(max(0, s1*s1 + s2*s2 - k*s1*s2))/W
print(sum(20 for a in range(0, len(x) - W + 1, W) if lv(a) > 2000))
PY
}
ms=$(tonems "$T/say.raw" 440)
[ "$ms" -ge 240 ] && [ "$ms" -le 360 ] && pass "say's sound played, as speech: three words, ${ms} ms of the engine's tone" ||
	fail "say played ${ms} ms of the engine's tone, not about 300"

half=$(num half.engine peak); full=$(num full.engine peak)
[ "${half:-99999}" -lt 1000 ] && pass "duplex half: the microphone not given to the engine while speech plays (peak ${half})" ||
	fail "duplex half: the engine heard peak ${half:-?}"
[ "${full:-0}" -ge 3000 ] && pass "duplex full: it is (peak ${full})" || fail "duplex full: the engine heard peak ${full:-?}"

ms=$(tonems "$T/cancel.raw" 440)
[ "$ms" -ge 600 ] && [ "$ms" -le 1500 ] && pass "cancel stopped speech at once, the queue with it (${ms} ms of 3 s, and nothing after)" ||
	fail "cancel: ${ms} ms of speech played"
has cancel.say '^idle' && pass "say is idle after a cancel" || fail "after cancel say said: $(f cancel.say)"

a=$(tonems "$T/chime.raw" 660); b=$(tonems "$T/chime.raw" 880)
[ "$a" -ge 40 ] && [ "$b" -ge 40 ] && pass "chime start played (660 then 880 Hz)" || fail "chime: 660 Hz ${a} ms, 880 Hz ${b} ms"

[ "$(f hear.words)" = "hello there" ] && pass "hear, the old interface: the words of what was said" || fail "hear gave '$(f hear.words)'"
# ask: an agent's, waiting for the user
[ "$(head -2 "$T/talk.ask" 2>/dev/null | tr '\n' '|')" = "off|off asked|" ] &&
	pass "talk reads off asked while an agent waits (the indicator's cue)" || fail "talk while asked: $(f talk.ask | tr '\n' '|')"
has ctl.asking '^asked 1' && has ctl.asking '^talk off' && pass "ctl: asked 1, talk still off" || fail "ctl while asked: $(f ctl.asking | tr '\n' '|')"
[ "$(num ask.before.engine starts)" = "$(num ask.none.engine starts)" ] && [ ! -s "$T/ask.none" ] &&
	pass "ask with nothing said: the microphone not opened, nothing heard" ||
	fail "ask alone: engine starts $(num ask.before.engine starts) to $(num ask.none.engine starts), heard '$(f ask.none)'"
[ "$(f ask.words)" = "what time is it" ] && pass "ask: the words of what the user said after it" || fail "ask gave '$(f ask.words)'"
[ ! -s "$T/ask.earlier" ] && pass "ask: an utterance begun before it is not given to it" || fail "ask was given '$(f ask.earlier)'"
[ "$(f ask.open)" = "agent opened" ] && pass "agentmic on: an ask opens the microphone itself" || fail "agentmic on: ask gave '$(f ask.open)'"
grep -qx 'voice fakevoice' "$T/settings.kept" && grep -qx 'lang fr' "$T/settings.kept" && grep -qx 'model ggml-tiny.en.bin' "$T/settings.kept" &&
	grep -qx 'duplex full' "$T/settings.kept" && grep -qx 'agentmic on' "$T/settings.kept" &&
	pass "the settings kept in the settings file" || fail "settings file: $(f settings.kept | tr '\n' '|')"
cp "$T/settings.kept" "$T/settings.again"
INFERNODE_AUDIO_FAKE=1 SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; mkdir -p /mnt/speechengine /mnt/speech; /tests/speechfake.dis /mnt/speechengine; /dis/veltro/speech9p.dis -s /tmp/settings.again; cat /mnt/speech/ctl > /tmp/ctl.second; echo start > /mnt/speech/talk; echo stop > /mnt/speech/talk; cat /mnt/speechengine/ctl > /tmp/second.engine; echo R second" \
	</dev/null >"$ROOT/$T/log.second" 2>&1 || true
has ctl.second '^voice fakevoice' && has ctl.second '^lang fr' && has ctl.second '^duplex full' && has ctl.second '^agentmic on' &&
	pass "a speech9p started again has them" || fail "the second speech9p: $(f ctl.second | tr '\n' '|')"
has second.engine '^voice fakevoice' && has second.engine '^lang fr' && has second.engine '^model ggml-tiny.en.bin' &&
	pass "and gives the engine the voice, language and model before an utterance" || fail "the engine after: $(f second.engine | tr '\n' '|')"
grep -qx 'agentmic off' "$T/settings" && pass "agentmic back off, kept" || fail "settings at the end: $(f settings | tr '\n' '|')"

# the wake phrase
has ctl.wakeoff '^wake off$' && pass "the wake phrase is off unless set" || fail "ctl: $(f ctl.wakeoff | grep wake)"
has ctl.wakeon '^wake hey veltro$' && grep -qx 'wake hey veltro' "$T/settings.wake" &&
	pass "set, and kept" || fail "wake on: $(f ctl.wakeon | grep wake), kept: $(f settings.wake | grep wake)"
[ "$(head -2 "$T/talk.wake" | tr '\n' '|')" = "off|off wake|" ] && pass "talk reads off wake while it listens for it (the indicator's cue)" ||
	fail "talk: $(f talk.wake | tr '\n' '|')"
cmds=$(grep '^command ' "$T/listen.wake" | tr '\n' '|')
[ "$cmds" = "command what time is it|command open the mail|command Call home|command read my messages|command stop the music|" ] &&
	pass "the words after the phrase, as commands: $cmds" || fail "commands: $cmds"
grep -q 'weather\|hey veltro\|not heard' "$T/listen.wake" && fail "what was not for it reached listen: $(grep 'weather\|hey veltro\|not heard' "$T/listen.wake" | tr '\n' '|')" ||
	pass "nothing else said reached listen (not the phrase, not what had none)"
grep -q '^partial' "$T/listen.wake" && ! grep -q '^partial confidence=0.40 a$' "$T/listen.wake" &&
	fail "standby's partials reached listen: $(grep '^partial' "$T/listen.wake" | tr '\n' '|')" ||
	pass "standby's partials not posted"
grep -qx 'final confidence=0.93 a dictated line' "$T/listen.wake" && pass "push to talk while it waits as ever" || fail "talk's final: $(f listen.wake | tr '\n' '|')"
grep -q 'on wake\|^on$' "$T/talk.wake" && tail -1 "$T/talk.wake" | grep -qx off && pass "standby again after talk, off at the end" ||
	fail "talk: $(f talk.wake | tr '\n' '|')"
has ctl.wakeoff2 '^wake off$' && [ "$(num wake.before.engine starts)" = "$(num wake.after.engine starts)" ] &&
	pass "off: the microphone shut, nothing more to the engine" ||
	fail "wake off: $(f ctl.wakeoff2 | grep wake), engine starts $(num wake.before.engine starts) then $(num wake.after.engine starts)"

[ "$(f voices)" = "fake" ] && pass "voices are the engine's" || fail "voices: $(f voices)"
[ -s "$T/ctl.bad" ] && pass "a bad ctl write refused" || fail "duplex sideways was taken"
[ -s "$T/talk.bad" ] && pass "a bad talk write refused" || fail "talk shout was taken"
has ctl.end '^duplex half' && has ctl.end '^talk off' && pass "nothing bad changed a setting" || fail "ctl at the end: $(f ctl.end | tr '\n' '|')"

# A line: an open line on an audio path of its own, beside the room's
printf 'hello is anyone there\nthe second thing\n' > "$T/script.line"
INFERNODE_AUDIO_FAKE=1 SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; run /tests/speech/line.sh" \
	</dev/null >"$T/log.line" 2>&1 || true
if grep -q '^R done' "$T/log.line"; then
	has l.ctl '^line open$' && has l.ctl '^audio #A/mix$' && has l.ctl '^duplex half$' && has l.roomctl '^duplex full$' &&
		pass "a line beside the room's speech: its own files and settings, open, on the audio path named" ||
		fail "line ctl: $(f l.ctl | tr '\n' '|'); room: $(f l.roomctl | grep duplex)"
	[ "$(head -1 "$T/l.talk")" = "off line" ] && pass "its talk reads off line" || fail "line talk: $(f l.talk | tr '\n' '|')"
	grep -qx 'final confidence=0.93 hello is anyone there' "$T/l.listen" && grep -qx 'final confidence=0.93 the second thing' "$T/l.listen" &&
		pass "every utterance on the line heard with no key, to its listen" || fail "line listen: $(f l.listen | tr '\n' '|')"
	[ "$(f l.ask)" = "hello is anyone there" ] && pass "an agent's ask on the line answered by the far end" || fail "line ask: '$(f l.ask)'"
	[ ! -s "$T/l.roomlisten" ] && pass "the room's listen heard none of it" || fail "the room heard: $(f l.roomlisten | tr '\n' '|')"
	ms=$(tonems "$T/l.say.raw" 440)
	[ "$ms" -ge 240 ] && pass "say on the line played on its audio path (${ms} ms)" || fail "line say: ${ms} ms"
else
	fail "the line driver did not finish"; tail -5 "$T/log.line"
fi

# The host's programs, through speechcmd(4): espeak-ng speaking for
# real, and a stand-in for whisper-cli answering with the size of the
# WAV it was handed (whisper itself is not packaged here)
if ! command -v espeak-ng >/dev/null 2>&1; then
	echo "SKIP: speechcmd with the host's programs (no espeak-ng)"
	exit $failed
fi
[ -f "$ROOT/dis/veltro/speechcmd.dis" ] || { fail "speechcmd.dis not built"; exit 1; }
cat > "$ROOT/$T/whisper" <<'SH'
#!/bin/sh
# a stand-in for whisper-cli: the size of the WAV given with -f
while [ $# -gt 0 ]; do
	[ "$1" = -f ] && { echo "heard $(wc -c < "$2" | tr -d ' ') bytes"; exit 0; }
	shift
done
echo "no -f" >&2; exit 1
SH
chmod +x "$ROOT/$T/whisper"
LOG2="$ROOT/$T/log.cmd"
INFERNODE_AUDIO_FAKE=1 SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; sttcmd=$ROOT/$T/whisper; run /tests/speech/cmd.sh" \
	</dev/null >"$LOG2" 2>&1 || true
grep -q '^R done' "$LOG2" || { fail "the speechcmd driver did not finish"; tail -20 "$LOG2"; exit 1; }
has cmd.ctl '^tts espeak-ng' && pass "speechcmd: the synthesiser named in its ctl" || fail "speechcmd's ctl: $(f cmd.ctl | tr '\n' '|')"
has cmd.saying '^speaking hello from the host' && pass "speechcmd: say speaking" || fail "say while espeak spoke: $(f cmd.saying)"
spoke=$(python3 -I - "$T/cmd.say.raw" <<'PY'
import sys, struct
raw = open(sys.argv[1], 'rb').read()
x = [struct.unpack_from('<h', raw, 4*i)[0] for i in range(len(raw)//4)]
loud = sum(1 for v in x if abs(v) > 500)
print(len(x) * 1000 // 48000, loud * 1000 // 48000)
PY
)
set -- $spoke
[ "${2:-0}" -ge 300 ] && pass "speechcmd: espeak-ng's speech played through the shared device (${1} ms, ${2} ms of it loud)" ||
	fail "espeak-ng's speech: ${1:-0} ms played, ${2:-0} ms loud"
bytes=$(sed -n 's/^final heard \([0-9]*\) bytes$/\1/p' "$T/cmd.listen" | head -1)
[ "${bytes:-0}" -ge 16044 ] && pass "speechcmd: the utterance went to the recogniser as a WAV (${bytes} bytes, its words back as the final)" ||
	fail "the recogniser's final: $(f cmd.listen | tr '\n' '|')"
[ -s "$T/cmd.voices" ] && pass "speechcmd: the synthesiser's voices listed" || fail "no voices from espeak-ng"
[ ! -s "$T/cmd.voice.ok" ] && pass "speechcmd: a voice set through speech's ctl" || fail "voice en-us: $(f cmd.voice.ok)"
[ -s "$T/cmd.voice.bad" ] && pass "speechcmd: a voice that is not a name refused (nothing reaches the host's shell)" || fail "voice 'a;rm' was taken"

exit $failed

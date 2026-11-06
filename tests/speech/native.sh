#!/dis/sh.dis
#
# The emulator's own speech engine (#W, devspeech), for
# tests/host/devspeech_test.sh; not a test itself.  /tmp is the test's
# directory; each step leaves what it saw in /tmp/n.<step>.
#
load std

fn tts {
	(name text) = $*
	{echo $text >[1=0]; cat} <> '#W/tts' > /tmp/n.$name.raw
}

cat '#W/ctl' > /tmp/n.ctl
cat '#W/voices' > /tmp/n.voices
# synthesis: a short and a longer sentence, then another voice
tts short 'Hello.'
tts long 'Hello. This is the speech engine built into the emulator, saying a longer sentence.'
echo voice rms > '#W/ctl'
tts rms 'Hello. This is the speech engine built into the emulator, saying a longer sentence.'
echo voice slt > '#W/ctl'
# refused: a voice not built in, a model or language that is not a name, a bad verb
{echo voice nobody > '#W/ctl'} >[2] /tmp/n.bad.voice
{echo model ../../etc/passwd > '#W/ctl'} >[2] /tmp/n.bad.model
{echo 'lang a;b' > '#W/ctl'} >[2] /tmp/n.bad.lang
{echo frobnicate > '#W/ctl'} >[2] /tmp/n.bad.verb
{cat '#W/audio'} >[2] /tmp/n.bad.audio

# an utterance: its sound to the recogniser, the final (or why not) to
# every reader of text.  With a model (tools/speech-models.sh) and
# whisper.cpp built in, the sound is the engine's own saying a sentence.
cat '#W/text' > /tmp/n.text.1 &
cat '#W/text' > /tmp/n.text.2 &
sleep 1
if {ftest -e /lib/speech/models/ggml-tiny.en.bin} {echo model ggml-tiny.en.bin > '#W/ctl'}
tts said 'The quick brown fox jumps over the lazy dog.'
echo start > '#W/ctl'
cat /tmp/n.said.raw > '#W/audio'
echo end > '#W/ctl'
if {grep -s '^stt whisper' '#W/ctl'} {sleep 30} {sleep 2}
cat '#W/ctl' > /tmp/n.ctl.after

# speech(4) over it: say played through the shared device as speech
mkdir -p /mnt/speech
/dis/veltro/speech9p.dis -E '#W' -s /tmp/settings
dd -if '#A/fakeout' -of /dev/null -bs 65536 >[2] /dev/null
echo 'One, two, three, four.' > /mnt/speech/say
sleep 4
cp '#A/fakeout' /tmp/n.speaker.raw
cat /mnt/speech/voices > /tmp/n.speech.voices
echo voice awb > /mnt/speech/ctl
cat '#W/ctl' > /tmp/n.ctl.voice
echo R done

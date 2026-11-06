#!/dis/sh.dis
#
# speech(4) with the fake audio hardware (the emulator run with
# $INFERNODE_AUDIO_FAKE) and the fake engine (tests/speechfake.b), for
# tests/host/speech_test.sh.  Not a test itself.  /tmp is the test's
# directory: tone.raw (a 48 kHz stereo 700 Hz tone, the microphone) and
# script (the engine's finals) are put there first; each step leaves
# what it saw in /tmp/<step>.* and a line "R <step>" in the log.
#
load std

fn fakespeaker { dd -if '#A/fakeout' -of /dev/null -bs 65536 >[2] /dev/null }
fn mic { cp /tmp/tone.raw '#A/fakein' }
fn engctl { cat /mnt/speechengine/ctl > /tmp/$1.engine }

mkdir -p /mnt/speechengine /mnt/speech
/tests/speechfake.dis /mnt/speechengine /tmp/script
/dis/veltro/speech9p.dis -E /mnt/speechengine -s /tmp/settings
cat /mnt/speech/ctl > /tmp/ctl.start
echo R started

# talk: every change to every reader of talk
cat /mnt/speech/talk > /tmp/talk.log &
# listen: two readers, each every line
cat /mnt/speech/listen > /tmp/listen.1 &
cat /mnt/speech/listen > /tmp/listen.2 &
sleep 1

# push to talk: the microphone to the engine, its words to every listener
echo start > /mnt/speech/talk
cat /mnt/speech/ctl > /tmp/ctl.talking
mic
sleep 1
echo stop > /mnt/speech/talk
sleep 1
engctl talk
echo R talk

# say: the engine's sound, played as speech
fakespeaker
echo one two three > /mnt/speech/say
sleep 0
cat /mnt/speech/say > /tmp/say.during
sleep 2
cat /mnt/speech/say > /tmp/say.after
cp '#A/fakeout' /tmp/say.raw
echo R say

# duplex half: the microphone is not given to the engine while speech plays
echo 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen' > /mnt/speech/say
sleep 0
echo start > /mnt/speech/talk
mic
sleep 1
echo stop > /mnt/speech/talk
sleep 1
engctl half
sleep 1
echo duplex full > /mnt/speech/ctl
echo 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen' > /mnt/speech/say
sleep 0
echo start > /mnt/speech/talk
mic
sleep 1
echo stop > /mnt/speech/talk
sleep 1
engctl full
echo duplex half > /mnt/speech/ctl
sleep 2
echo R duplex

# cancel: stops speech at once, the queue with it
fakespeaker
echo 'a b c d e f g h i j k l m n o p q r s t u v w x y z a b c d' > /mnt/speech/say
echo 'and then this' > /mnt/speech/say
sleep 1
echo x > /mnt/speech/cancel
cat /mnt/speech/say > /tmp/cancel.say
sleep 2
cp '#A/fakeout' /tmp/cancel.raw
echo R cancel

# chime
fakespeaker
echo start > /mnt/speech/chime
sleep 1
cp '#A/fakeout' /tmp/chime.raw
echo R chime

# hear, the old interface: start, then the words
{echo start 1500 >[1=0]; cat} <> /mnt/speech/hear > /tmp/hear.words &
sleep 0
mic
sleep 3
echo R hear

# ask, an agent's: it waits for the user to begin an utterance, and does
# not open the microphone
cat /mnt/speech/talk > /tmp/talk.ask &
sleep 0
engctl ask.before
{echo start 1500 >[1=0]; cat} <> /mnt/speech/ask > /tmp/ask.none &
sleep 0
cat /mnt/speech/ctl > /tmp/ctl.asking
sleep 2
engctl ask.none
echo R ask.none

# the user answers: pushes to talk after the ask
{echo start 8000 >[1=0]; cat} <> /mnt/speech/ask > /tmp/ask.words &
sleep 1
echo start > /mnt/speech/talk
mic
sleep 1
echo stop > /mnt/speech/talk
sleep 1
echo R ask.words

# what the user began before the ask is not the agent's
echo start > /mnt/speech/talk
{echo start 2500 >[1=0]; cat} <> /mnt/speech/ask > /tmp/ask.earlier &
sleep 0
mic
sleep 1
echo stop > /mnt/speech/talk
sleep 3
echo R ask.earlier

# agentmic on: an ask opens the microphone itself, for its time
echo agentmic on > /mnt/speech/ctl
{echo start 1500 >[1=0]; cat} <> /mnt/speech/ask > /tmp/ask.open &
sleep 0
mic
sleep 3
echo R ask.open

# the settings kept (speech_test.sh starts speech9p again on them, in an
# emulator of its own: sh keeps a module it has loaded, globals and all)
echo voice fakevoice > /mnt/speech/ctl
echo lang fr > /mnt/speech/ctl
echo model ggml-tiny.en.bin > /mnt/speech/ctl
echo duplex full > /mnt/speech/ctl
cp /tmp/settings /tmp/settings.kept
echo agentmic off > /mnt/speech/ctl
echo duplex half > /mnt/speech/ctl
echo R settings

cat /mnt/speech/voices > /tmp/voices
{echo duplex sideways > /mnt/speech/ctl} >[2] /tmp/ctl.bad
{echo shout > /mnt/speech/talk} >[2] /tmp/talk.bad
cat /mnt/speech/ctl > /tmp/ctl.end
echo R done

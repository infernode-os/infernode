#!/dis/sh.dis
#
# speech(4) over speechcmd(4), the host's programs: espeak-ng speaking,
# and for whisper-cli a stand-in the test wrote ($sttcmd, a host path)
# that answers with the size of the WAV it was given.  For
# tests/host/speech_test.sh; not a test itself.
#
load std

fn fakespeaker { dd -if '#A/fakeout' -of /dev/null -bs 65536 >[2] /dev/null }

mkdir -p /mnt/speechengine /mnt/speech
/dis/veltro/speechcmd.dis -t espeak-ng -s $sttcmd
/dis/veltro/speech9p.dis -E /mnt/speechengine -s /tmp/settings.cmd
cat /mnt/speechengine/ctl > /tmp/cmd.ctl
cat /mnt/speech/listen > /tmp/cmd.listen &
sleep 1

fakespeaker
echo 'hello from the host' > /mnt/speech/say
sleep 0
cat /mnt/speech/say > /tmp/cmd.saying
sleep 4
cp '#A/fakeout' /tmp/cmd.say.raw
echo R say

echo start > /mnt/speech/talk
cp /tmp/tone.raw '#A/fakein'
sleep 1
echo stop > /mnt/speech/talk
sleep 3
echo R talk

cat /mnt/speech/voices > /tmp/cmd.voices
{echo voice en-us > /mnt/speech/ctl} >[2] /tmp/cmd.voice.ok
{echo 'voice a;rm' > /mnt/speechengine/ctl} >[2] /tmp/cmd.voice.bad
echo R done

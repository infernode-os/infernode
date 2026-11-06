#!/dis/sh.dis
#
# speech(4) on a line: a second speech9p, an open line (-o) on an audio
# path named (-a), beside the room's, for tests/host/speech_test.sh; not
# a test itself.  The line's audio path is the shared device's own mix
# here, standing in for a call's or a radio's.
#
load std

fn mic { cp /tmp/tone.raw '#A/fakein' }

mkdir -p /mnt/speechengine /mnt/speech /mnt/voice/line
/tests/speechfake.dis /mnt/speechengine /tmp/script.line
/dis/veltro/speech9p.dis -E /mnt/speechengine -s /tmp/settings.room
/dis/veltro/speech9p.dis -o -a '#A/mix' -m /mnt/voice/line -E /mnt/speechengine -s /tmp/settings.line
echo duplex full > /mnt/speech/ctl
cat /mnt/voice/line/ctl > /tmp/l.ctl
cat /mnt/speech/ctl > /tmp/l.roomctl
cat /mnt/voice/line/talk > /tmp/l.talk &
cat /mnt/voice/line/listen > /tmp/l.listen &
cat /mnt/speech/listen > /tmp/l.roomlisten &
sleep 1
# an agent on the line asks, and the far end answers: no key
{echo start 8000 >[1=0]; cat} <> /mnt/voice/line/ask > /tmp/l.ask &
sleep 1
mic
sleep 2
mic
sleep 2
dd -if '#A/fakeout' -of /dev/null -bs 65536 >[2] /dev/null
echo 'One, two, three.' > /mnt/voice/line/say
sleep 2
cp '#A/fakeout' /tmp/l.say.raw
echo R done

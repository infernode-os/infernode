#!/dis/sh.dis
#
# dictate(1) against speech(4) on the fake audio hardware and the fake
# engine (tests/speechfake.b), for tests/host/dictate_test.sh; not a
# test itself.  /tmp holds tone.raw (the microphone) and script (the
# engine's finals).
#
load std

fn mic { cp /tmp/tone.raw '#A/fakein' }

mkdir -p /mnt/speechengine /mnt/speech
/tests/speechfake.dis /mnt/speechengine /tmp/script
/dis/veltro/speech9p.dis -E /mnt/speechengine -s /tmp/settings

# dictate turns talk on; the user turns it off; the words are typed
dictate -o /tmp/typed.1 >[2] /tmp/err.1 &
sleep 1
cat /mnt/speech/ctl > /tmp/ctl.1
mic
sleep 1
echo stop > /mnt/speech/talk
sleep 2
echo R one

# -w: waits for someone else to turn talk on
dictate -w -o /tmp/typed.2 >[2] /tmp/err.2 &
sleep 1
cat /mnt/speech/ctl > /tmp/ctl.2
echo start > /mnt/speech/talk
mic
sleep 1
echo stop > /mnt/speech/talk
sleep 2
echo R wait

# with talk on already, it does not take the utterance
echo start > /mnt/speech/talk
dictate -o /tmp/typed.3 >[2] /tmp/err.3
echo stop > /mnt/speech/talk
sleep 2
ls /prog | wc -l > /tmp/nprog.a
sleep 1
ls /prog | wc -l > /tmp/nprog.b
echo R done

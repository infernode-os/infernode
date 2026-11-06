#!/dis/sh.dis
#
# Lucifer's microphone (dictate(1) and speech(4)'s talk), for
# tests/host/dictate_test.sh; not a test itself: run in the shell that
# booted Lucifer, once it is up, with the fake audio hardware.  The
# fake engine (tests/speechfake.b) is made speech's engine through its
# ctl.  The screen is captured at each step as /tmp/<step>.img.
#
load std

fn mic { cp /tmp/tone.raw '#A/fakein' }
fn shot { sleep 2; scap /tmp/$1.img; echo R $1 }
fn ctrlspace { cat /tmp/nul > /dev/keyboard }	# Ctrl+Space: a NUL, as the emulator sends it
fn tapmic { echo m 1004 20 1 > /dev/pointer; echo m 1004 20 0 > /dev/pointer }

while {! ftest -e /mnt/speech/talk} {sleep 1}
mkdir -p /mnt/fakeengine
/tests/speechfake.dis /mnt/fakeengine /tmp/script
echo engine /mnt/fakeengine > /mnt/speech/ctl
cat /mnt/speech/ctl > /tmp/ctl.start
# the pointer over the chat, so typing goes there; what the chat sends
# read here (a message an open), its agent's bridge stopped (with no
# model it keeps nothing)
fn sent { cat /mnt/ui/activity/0/conversation/input > /tmp/sent.$1 & }
echo m 200 400 0 > /dev/pointer
kill Lucibridge >[2] /dev/null
shot off

# Ctrl+Space: the microphone on, for dictation
ctrlspace
sleep 1
cat /mnt/speech/ctl > /tmp/ctl.key
shot on
mic
sleep 1
ctrlspace
sleep 3
sent key
echo > /dev/keyboard
sleep 3
echo R key

# a tap on it does the same
tapmic
sleep 1
cat /mnt/speech/ctl > /tmp/ctl.tap
mic
sleep 1
tapmic
sleep 3
sent tap
echo > /dev/keyboard
sleep 3
echo R tap

# an agent asks: the microphone lit; a tap answers it, nothing typed
{echo start 20000 >[1=0]; cat} <> /mnt/speech/ask > /tmp/ask.words &
shot asked
tapmic
sleep 1
cat /mnt/speech/ctl > /tmp/ctl.answer
mic
sleep 1
tapmic
sleep 3
sent ask
echo > /dev/keyboard
sleep 3
shot after
echo R done

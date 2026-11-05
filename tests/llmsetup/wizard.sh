#!/dis/sh.dis
#
# Lucifer's first-run LLM setup, for tests/host/llmsetup_phone_test.sh
# (not a test itself): run in the shell that booted Lucifer with no LLM
# configured.  The wizard's dialogue is copied to /tmp/dialogue, the
# Remote 9P option chosen, and the answer copied to /tmp/answer.
#
load std
while {! ftest -f /mnt/ui/activity/0/conversation/1} {sleep 1}
cat /mnt/ui/activity/0/conversation/1 > /tmp/dialogue
echo -n Remote 9P > /mnt/ui/activity/0/conversation/input
while {! ftest -f /mnt/ui/activity/0/conversation/2} {sleep 1}
sleep 1
cat /mnt/ui/activity/0/conversation/2 > /tmp/answer
echo R done

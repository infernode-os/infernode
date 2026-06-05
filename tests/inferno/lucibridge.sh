#!/dis/sh.dis
load std

# Mount LLM service (llmsrv must be running)
mkdir -p /mnt/llm
mount -A tcp!127.0.0.1!5640 /mnt/llm

# Start UI server
luciuisrv
sleep 1

# Create activity for the bridge
echo 'activity create BridgeTest' > /mnt/ui/ctl
echo activity created:
cat /mnt/ui/activity/0/label

# Start bridge in background (no /tool mount = chat-only mode)
lucibridge -v -a 0 &
sleep 2

# Send human input
echo 'What is the meaning of life?' > /mnt/ui/activity/0/conversation/input
sleep 8

# Check conversation messages
echo msg 0:
cat /mnt/ui/activity/0/conversation/0
echo msg 1:
cat /mnt/ui/activity/0/conversation/1

# Send a second message to test multi-turn
echo 'Summarize in one sentence.' > /mnt/ui/activity/0/conversation/input
sleep 8

echo msg 2:
cat /mnt/ui/activity/0/conversation/2
echo msg 3:
cat /mnt/ui/activity/0/conversation/3

echo PASS

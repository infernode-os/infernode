#!/dis/sh.dis
load std

# Mount LLM service (llmsrv must be running)
mkdir -p /mnt/llm
# Environmental skip-guard (INFR-312): needs a live LLM backend served
# over 9P at the address below. On a bare host the dial is refused; the
# mount runs inside `if {! ...}` so its failure is caught as status
# rather than aborting the script, and we skip cleanly instead of
# reporting a false failure.
if {! mount -A tcp!127.0.0.1!5640 /mnt/llm} {
	raise 'skip:no llm backend at tcp!127.0.0.1!5640 (start serve-llm/llmsrv first)'
}

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

#!/dis/sh.dis
load std

# Mount LLM service
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

# Create activity
echo 'activity create Chat' > /mnt/ui/ctl
echo activity:
cat /mnt/ui/activity/current

# Create LLM session
cat /mnt/llm/new

# Simulate human message
echo 'role=human text=What is the capital of France?' > /mnt/ui/activity/0/conversation/ctl
echo human msg:
cat /mnt/ui/activity/0/conversation/0

# Send to LLM and write response back
echo 'What is the capital of France?' > /mnt/llm/0/ask
resp := `{cat /mnt/llm/0/ask}
echo 'role=veltro text='^$resp > /mnt/ui/activity/0/conversation/ctl
echo veltro msg:
cat /mnt/ui/activity/0/conversation/1

echo PASS

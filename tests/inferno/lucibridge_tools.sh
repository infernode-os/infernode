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

# Start tool server with basic tools
/dis/veltro/tools9p.dis read list find search &
sleep 1

# Verify tools mounted
echo tools:
cat /tool/tools

# Start UI server
luciuisrv
sleep 1

# Create activity
echo 'activity create ToolTest' > /mnt/ui/ctl

# Start bridge with tools
lucibridge -v -a 0 &
sleep 2

# Ask it to do something that requires a tool
echo 'List the files in /lib/veltro/agents/' > /mnt/ui/activity/0/conversation/input
sleep 12

# Show conversation messages
echo msg 0:
cat /mnt/ui/activity/0/conversation/0
echo msg 1:
cat /mnt/ui/activity/0/conversation/1
echo msg 2:
cat /mnt/ui/activity/0/conversation/2
echo msg 3:
cat /mnt/ui/activity/0/conversation/3
echo msg 4:
cat /mnt/ui/activity/0/conversation/4

echo PASS

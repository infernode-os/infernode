#!/dis/sh.dis
load std
mkdir -p /mnt/llm
# Environmental skip-guard (INFR-312): needs a live LLM backend served
# over 9P at the address below. On a bare host the dial is refused; the
# mount runs inside `if {! ...}` so its failure is caught as status
# rather than aborting the script, and we skip cleanly instead of
# reporting a false failure.
if {! mount -A tcp!127.0.0.1!5640 /mnt/llm} {
	raise 'skip:no llm backend at tcp!127.0.0.1!5640 (start serve-llm/llmsrv first)'
}
echo ls:
ls /mnt/llm
echo new session:
cat /mnt/llm/new
echo ls after clone:
ls /mnt/llm
echo model:
cat /mnt/llm/0/model
echo ask:
echo 'Hello from Lucifer' > /mnt/llm/0/ask
cat /mnt/llm/0/ask
echo PASS

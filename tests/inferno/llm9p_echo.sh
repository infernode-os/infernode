#!/dis/sh.dis
load std
mkdir -p /mnt/llm
mount -A tcp!127.0.0.1!5640 /mnt/llm
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

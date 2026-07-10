#!/dis/sh.dis
# Live integration test for native llmsrv with factotum
load std

# Bootstrap services
mount -ac {mntgen} /n >[2] /dev/null
bind -a '#I' /net >[2] /dev/null
ndb/cs
auth/factotum

echo '=== Factotum ==='
cat /mnt/factotum/proto

# Provision API key (host-side conditional logic)
factotumkey=`{os sh -c 'k=${ANTHROPIC_API_KEY:-}; if [ -n "$k" ]; then echo "key proto=pass service=anthropic user=apikey !password=$k"; fi'}
# Environmental skip-guard (INFR-312): this is a live integration test —
# without an API key there is no backend for llmsrv to serve, so the
# session/ask reads below fail. Skip cleanly rather than report a false
# failure on a bare host / CI without secrets.
if {~ $#factotumkey 0} {
	raise 'skip:no ANTHROPIC_API_KEY in environment (live llmsrv backend unavailable)'
}
echo $factotumkey > /mnt/factotum/ctl >[2] /dev/null
echo 'PASS: API key provisioned'

# Start native llmsrv
llmsrv >[2] /dev/null &
sleep 1

echo '=== LLM Service ==='
ls /mnt/llm

echo '=== Session Test ==='
id=`{cat /mnt/llm/new}
echo 'session id:' $id
echo 'model:' `{cat /mnt/llm/$id/model}

echo '=== LLM Query ==='
echo 'Say hello in exactly 5 words.' > /mnt/llm/$id/ask
cat /mnt/llm/$id/ask

echo '=== Usage ==='
cat /mnt/llm/$id/usage

echo '=== ALL PASS ==='

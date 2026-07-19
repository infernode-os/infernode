#!/dis/sh.dis
# INFR-4: verify /mnt/llm/$id/model accepts writes (and reads reflect them).
#
# The per-session model file is rw (mode 0666). Writing resolves the short
# aliases haiku/sonnet/opus to full model ids and otherwise stores the value
# verbatim; reading returns the current model. This path never touches the LLM
# backend, so the test runs with the keyless `openai` backend and needs no
# network or API key — it exercises the styx read/write handlers directly.
# Prerequisite verification for INFR-2 (per-session model routing).
load std

llmsrv -b openai -u http://127.0.0.1:1/v1 >[2] /dev/null &
sleep 2

id=`{cat /mnt/llm/new}
if {~ $#id 0} {
	raise 'skip:llmsrv did not start (/mnt/llm/new unreadable)'
}

# Session names are bearer capabilities, not enumerable numeric identifiers.
# Keep this check backend-free so the isolation boundary can run in CI.
badchars=`{echo -n $id | sed 's/[0-9a-f]//g'}
nchars=`{echo -n $id | wc -c}
if {! ~ $#badchars 0} {
	raise 'fail:session token contains non-hex characters: '^$id
}
if {! ~ $nchars 32} {
	raise 'fail:session token is not 128 bits: '^$id
}
root=`{ls /mnt/llm}
if {! ~ $#root 2} {
	raise 'fail:session token disclosed by root listing'
}
if {test -e /mnt/llm/0/model} {
	raise 'fail:legacy numeric session path is walkable'
}
if {test -e /mnt/llm/00000000000000000000000000000000/model} {
	raise 'fail:guessed session token is walkable'
}

# Server default model.
m=`{cat /mnt/llm/$id/model}
if {! ~ $"m claude-sonnet-4-5-20250929} {
	raise 'fail:unexpected default model: '^$"m
}

# Alias resolved on write.
echo opus > /mnt/llm/$id/model
m=`{cat /mnt/llm/$id/model}
if {! ~ $"m claude-opus-4-5-20251101} {
	raise 'fail:opus alias not resolved on write: '^$"m
}

# Arbitrary id stored verbatim (forward-compat with unknown model names).
echo my-custom-model-xyz > /mnt/llm/$id/model
m=`{cat /mnt/llm/$id/model}
if {! ~ $"m my-custom-model-xyz} {
	raise 'fail:custom model not stored verbatim: '^$"m
}

# Write is repeatable; second alias resolves too.
echo haiku > /mnt/llm/$id/model
m=`{cat /mnt/llm/$id/model}
if {! ~ $"m claude-haiku-4-5-20251001} {
	raise 'fail:haiku alias not resolved on write: '^$"m
}

# Revocation removes the capability immediately.
echo close > /mnt/llm/$id/ctl
if {test -e /mnt/llm/$id/model} {
	raise 'fail:closed session token remains walkable'
}

echo PASS

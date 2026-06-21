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

echo PASS

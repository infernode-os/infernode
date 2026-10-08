#!/dis/sh.dis
# llmsrv.sh — (re-)start the LLM service from /lib/ndb/llm.
#
# Run in the background by Lucifer's boot (lib/lucifer/boot.sh) and by a
# standalone Xenith (tools/xen), so both reach the model the same way:
# a remote /mnt/llm mounted over 9P, or a local llmsrv on the configured
# backend.  Needs std loaded.
#
# Local boot must NEVER block on remote InferNode availability — see
# docs/postmortems/2026-05-04-local-boot-decoupled-from-remote-llm.md.
# A probe of /mnt/llm/new would walk into a potentially-degraded 9P
# export and block indefinitely (no protocol-level timeout); run this in
# a backgrounded subshell so the caller comes up regardless.

llmmode=`{sed -n 's/^mode=//p' /lib/ndb/llm >[2] /dev/null}
if {~ $llmmode remote} {
	llmdial=`{sed -n 's/^dial=//p' /lib/ndb/llm}
	llmauth=`{sed -n 's/^auth=//p' /lib/ndb/llm >[2] /dev/null}
	llmkey=`{sed -n 's/^keyfile=//p' /lib/ndb/llm >[2] /dev/null}
	if {~ $llmkey ''} { llmkey=/lib/keyring/serve-llm }
	if {~ $llmauth keyring} {
		# Biometric secstore opportunistic unlock (INFR-169
		# follow-up). If /phone/bio_status reports available
		# and the on-disk keyfile is missing, ask the OS
		# secure-element to release the slot. The user sees a
		# FaceID/TouchID prompt. /tmp/serve-llm is tmpfs in
		# the per-boot namespace, so it never hits flash.
		if {! ftest -f $llmkey} {
			if {~ `{cat /phone/bio_status >[2] /dev/null} available} {
				if {bioget serve-llm /tmp/serve-llm >[2] /dev/null} {
					llmkey=/tmp/serve-llm
				}
			}
		}
		if {ftest -f $llmkey} {
			mount -k $llmkey $llmdial /mnt/llm >[2] /dev/null
		}{
			echo 'boot: keyring auth requested but keyfile not found at' $llmkey
		}
	}{
		mount -A $llmdial /mnt/llm >[2] /dev/null
	}
}{
	llmbackend=`{sed -n 's/^backend=//p' /lib/ndb/llm >[2] /dev/null}
	llmurl=`{sed -n 's/^url=//p' /lib/ndb/llm >[2] /dev/null}
	llmmodel=`{sed -n 's/^model=//p' /lib/ndb/llm >[2] /dev/null}
	# backend=cli/codex are the host-side CLI gateways (claude-gate,
	# codex-gate) — OpenAI-shaped on localhost, so llmsrv dials them
	# the same way.
	if {~ $llmbackend openai cli codex} {
		if {! ~ $llmmodel ''} {
			llmsrv -b openai -u $llmurl -M $llmmodel >[2] /dev/null
		}{
			llmsrv -b openai -u $llmurl >[2] /dev/null
		}
	}{
		if {! ~ $llmmodel ''} {
			llmsrv -M $llmmodel >[2] /dev/null
		}{
			llmsrv >[2] /dev/null
		}
	}
}

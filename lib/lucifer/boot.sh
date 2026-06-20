# InferNode GUI boot sequence
# Runs AFTER profile (invoked as: sh -l /lib/lucifer/boot.sh)


# Warm trfs cache for the secstore overlay so logon and secstored can
# find PAK/factotum files on second launch (trfs may not have read-ahead
# the directory contents yet when the overlay bind was set up in profile).
user=`{cat /dev/user}
ls /usr/inferno/secstore >[2] /dev/null
if {! ~ $user ''} {
	ls /usr/inferno/secstore/$user >[2] /dev/null
}

# Login screen (unlocks secstore, loads keys into factotum).
#
# Skippable via $skiplogon. Mobile dev iteration (hellaphone) sets
# this from /lib/lucifer/boot-mobile.sh when the Activity passes
# --no-logon — typing a password on every UI rebuild is wasted
# iteration time. Default behaviour is unchanged (variable unset =
# logon runs). When $skiplogon is 1, secstore stays locked and
# factotum starts empty; downstream code that needs keys (LLM
# keyring mounts, etc.) will fail in expected ways.
if {! ~ $skiplogon 1} {
	wm/logon
}{
	echo 'boot: skiplogon=1 — wm/logon bypassed (dev mode; no factotum, no secstore)'
}

# (Re-)start LLM service in the background.
#
# Local boot must NEVER block on remote InferNode availability — see
# docs/postmortems/2026-05-04-local-boot-decoupled-from-remote-llm.md.
# The previous version probed `ftest -f /mnt/llm/new`; that walk into a
# potentially-degraded 9P export blocks indefinitely (no protocol-level
# timeout) and wedges the entire desktop boot. Run the whole LLM setup
# in a backgrounded subshell so the desktop comes up regardless.
{
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
		if {~ $llmbackend openai} {
			llmsrv -b openai -u $llmurl -M $llmmodel >[2] /dev/null
		}{
			if {! ~ $llmmodel ''} {
				llmsrv -M $llmmodel >[2] /dev/null
			}{
				llmsrv >[2] /dev/null
			}
		}
	}
} &

# Wallet service
/dis/veltro/wallet9p.dis >[2] /dev/null &
sleep 1

# Message layer — msg9p mounts /mnt/msg and aggregates Notifications from
# every registered MsgSrc into /mnt/msg/notify, which lucibridge / agents
# block-read for unified inbound alerts (mail, sms, …). Register the
# sources we ship by default; failures here are non-fatal (the source's
# own init() returns an error if the backing channel isn't available,
# e.g. sms on a build without /phone bound). stderr stays attached so
# mount/register failures surface in the console.
/dis/veltro/msg9p.dis &
sleep 1
echo 'register sms /dis/veltro/sources/sms.dis' > /mnt/msg/ctl

# GUI services
luciuisrv
echo activity create Main > /mnt/ui/ctl
sleep 1
/dis/veltro/tools9p -v -m /tool -b read,list,find,search,grep,write,edit,exec,launch,spawn,diff,json,webfetch,git,say,editor,fractal,memory,todo,plan,websearch,mail,keyring,present,gap,limbo,sms,dial,contacts -p /dis/wm read list find present say hear task memory gap keyring editor shell limbo sms dial contacts
# /tmp is bound by lib/sh/profile; on Windows the bind has hit edge
# cases where it silently failed and the redirect below produced no log
# file (GH #230 sphynkx report). Force /tmp into existence and pre-create
# the log so the background redirect always has a writable target. If
# /tmp truly doesn't exist after this, the mkdir will print to stderr
# instead of being silenced.
mkdir -p /tmp
> /tmp/lucibridge.log
lucibridge -a 0 -v -s >[2] /tmp/lucibridge.log &
sleep 1
echo 'create id=tasks type=taskboard label=Tasks' > /mnt/ui/activity/0/presentation/ctl
# (No auto-spawn of /dis/wm/shell in Activity 0 — the Main agent
#  doesn't have shell authority, so the tab either sits empty or, on
#  mobile, slides a shell in front of a context that shouldn't have
#  it. The old `mobile SMS test affordance` from c71663e8 became
#  redundant once Veltro picked up the sms / dial tools (INFR-150 /
#  INFR-151 / INFR-169). Users that genuinely want a shell open a
#  fresh task activity for it.)
lucifer

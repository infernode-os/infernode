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

# Email source — registered only when an account is configured, so we never
# hardcode a provider. The Settings "Messaging" panel writes the config line
# (server=/smtpserver=/folder=) to /lib/veltro/sources/email.conf; the
# credentials live in factotum via the keyring "Email Account" entry. Both the
# register here and the source's init() soft-fail if the server or creds are
# absent (same posture as sms above). See docs/MESSAGE-INTEGRATION.md.
if {ftest -f /lib/veltro/sources/email.conf} {
	echo register email /dis/veltro/sources/email.dis `{cat /lib/veltro/sources/email.conf} > /mnt/msg/ctl
}

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

# Speech stack. speechshim9p adapts external host helper CLIs
# (whisper-stream, kokoro, openwakeword) to the speech provider contract
# at /n/speechshim; speech9p serves the stable /n/speech surface and is
# pointed at the shim as its provider. Any other provider serving the
# same contract (a parakeet export, a remote 9P mount) can replace it
# with one ctl write. Helpers are external installs and every path
# soft-fails with an error record, so starting both unconditionally is
# safe. speech9p must come before lucibridge, which registers the speech
# resource tile only if /n/speech is mounted at its startup.
> /tmp/speechshim9p.log
/dis/veltro/speechshim9p >[2] /tmp/speechshim9p.log
> /tmp/speech9p.log
/dis/veltro/speech9p >[2] /tmp/speech9p.log
echo provider /n/speechshim > /n/speech/ctl
echo duplex half > /n/speech/ctl

# Host speech-helper configuration. The installer writes its chosen stack
# to $prefix/speech.ctl.sh (Kokoro TTS + Parakeet realtime STT when it
# could be built, whisper fallback otherwise) and boot replays that file
# verbatim — the installer is the single source of truth, so new helper
# stacks need no boot.sh change. $speechhelperbin (preset by
# boot-speechtest.sh) bypasses the file and takes the legacy hardcoded
# path, because the test boots point it at fake helper bins.
#
# Legacy path: $speechhelperbin names the bin/ dir created by
# tools/install-speech-helpers.sh — a HOST path, because the shim execs
# the helpers through devcmd. Without any of this the shim keeps its
# built-in defaults — bare command names that are not on the host PATH —
# and the wake helper can never exec, which silently makes voice mode
# unable to hear anything at all.
#
# The prefix is a host path, so it is probed through /n/local (the host root).
# The wake phrase is "hey jarvis" — the only pretrained openWakeWord model
# shipped today (see tools/install-speech-helpers.sh).
speechctlfile=()
if {~ $#speechhelperbin 0} {
	speechprefix=`{echo 'echo ${INFERNODE_SPEECH_HOME:-$HOME/.local/share/infernode-speech}' | os sh >[2] /dev/null}
	if {ftest -f /n/local^$speechprefix^/speech.ctl.sh} {
		speechctlfile=/n/local^$speechprefix^/speech.ctl.sh
	}
	if {ftest -d /n/local^$speechprefix^/bin} {
		speechhelperbin=$speechprefix^/bin
	}
}
if {! ~ $#speechctlfile 0} {
	sh $speechctlfile
	echo 'boot: speech configured from' $speechctlfile
}{
	if {! ~ $#speechhelperbin 0} {
		# engine kokoro routes speech9p's say through the provider's
		# Kokoro instead of the robotic host `say` command (engine cmd).
		echo engine kokoro > /n/speech/ctl
		echo kokorobin $speechhelperbin/kokoro-cli > /n/speech/ctl
		echo whisperstreambin $speechhelperbin/whisper-stream-cli > /n/speech/ctl
		echo wakebin $speechhelperbin/openwakeword-cli > /n/speech/ctl
		echo whispermodel $speechhelperbin/../models/ggml-base.en.bin > /n/speech/ctl
		echo voice af_bella > /n/speech/ctl
		echo 'wakeword hey jarvis' > /n/speech/ctl
		echo wakethreshold 0.5 > /n/speech/ctl
		echo 'boot: speech helpers configured from' $speechhelperbin
	}{
		echo 'boot: no speech helpers found — voice mode will not hear or speak.'
		echo 'boot: run tools/install-speech-helpers.sh, then restart.'
	}
}

> /tmp/lucibridge.log
lucibridge -a 0 -v -s >[2] /tmp/lucibridge.log &
sleep 1

# Voice-mode daemon — resident and idle until /mnt/ui/input-mode becomes
# "v" (via /voice mode on, or a spoken control intent). Pre-spawned here
# so entering voice mode has no first-use startup latency. $voicetestargs
# (set by boot-speechtest.sh) puts the daemon in its LLM-free test mode:
# finals are answered with a canned TTS phrase instead of an LLM turn.
> /tmp/voicemode.log
if {! ~ $#voicetestargs 0} {
	voicemode $voicetestargs >[2] /tmp/voicemode.log &
}{
	voicemode >[2] /tmp/voicemode.log &
}
echo 'create id=tasks type=taskboard label=Tasks' > /mnt/ui/activity/0/presentation/ctl

# Plumbing — route file-opens to the presentation view.  The stock Inferno
# plumber matches /lib/lucifer/plumbing and forwards to the 'presentation'
# port; lucipres consumes it (plumbreceiver) and opens each file as the
# right artifact.  This is the shared path for every picker: the ftree file
# tree, the context panel, an agent, or the `plumb` command.
#
# The plumber publishes /chan/plumb.* via file2chan, which needs /chan on
# the srv device (#s); emu leaves /chan as the snarf device (#^).  Bind a
# named srv instance first, exactly as acme/xenith do (bind -bc
# '#splumber' /chan).  This runs in the boot namespace, so lucifer,
# lucipres (the consumer) and ftree (a client) — all forked after this —
# inherit the same /chan and see the same ports.  Start the plumber before
# lucifer so the 'presentation' port exists when lucipres opens it.
# $noplumber=1 skips the plumber (regression-test hook, like $skiplogon):
# tests/host/presentation_fileopen_test.sh uses it to verify the UI still
# comes up — Tasks tab and all — when no plumber is present, since the plumb
# consumer must never gate lucipres's init (see lucipres plumbreceiver).
if {! ~ $noplumber 1} {
	bind -bc '#splumber' /chan
	plumber /lib/lucifer/plumbing &
	sleep 1
}{
	echo 'boot: noplumber=1 — plumber not started (pickers use the /mnt/ui fallback)'
}

# (No auto-spawn of /dis/wm/shell in Activity 0 — the Main agent
#  doesn't have shell authority, so the tab either sits empty or, on
#  mobile, slides a shell in front of a context that shouldn't have
#  it. The old `mobile SMS test affordance` from c71663e8 became
#  redundant once Veltro picked up the sms / dial tools (INFR-150 /
#  INFR-151 / INFR-169). Users that genuinely want a shell open a
#  fresh task activity for it.)
lucifer

# GUI speech-test boot — the full lucifer desktop with voicemode in its
# LLM-free test mode: wake ("hey jarvis"), live partials in a bordered
# unsent conversation turn, and every final transcript answered by speaking
# a canned phrase.
# No login, no API key, no LLM traffic — for dogfooding the speech stack
# without per-turn cost. Same pattern as boot-mobile.sh: set variables,
# then hand off to the canonical boot.sh via `run`.
#
# Invoked by tools/speech-test.sh --gui as:
#
#   sh -l /lib/lucifer/boot-speechtest.sh <helpers-bin|-> <-e|-> <phrase>
#
# $1  HOST path to the speech-helpers bin dir from
#     tools/install-speech-helpers.sh ('-' = leave helpers unconfigured;
#     point /n/speech/ctl at a provider manually, e.g. a remote mount)
# $2  '-e' to answer with the transcript itself instead of the phrase
# $3  the canned TTS phrase spoken for every final transcript
#
# voicemode runs with -d in this mode; its trace lands in
# /tmp/voicemode.log inside the emu namespace.

if {! ~ $1 -} {
	speechhelperbin = $1
}
voicetestargs = ('-d' '-p' $3)
if {~ $2 -e} {
	voicetestargs = ('-d' '-e' '-p' $3)
}

# Test mode needs no secstore keys (nothing calls the LLM), so skip the
# password prompt — same dev-mode semantics as boot-mobile --no-logon.
skiplogon = 1
echo 'boot-speechtest: LLM-free voice test mode (skiplogon=1)'

run /lib/lucifer/boot.sh

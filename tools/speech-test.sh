#!/usr/bin/env bash
#
# speech-test.sh — boot InferNode in speech test mode: microphone -> STT
# (live partials) -> a hard-coded TTS phrase for every final transcript.
# No LLM, no login, no API key.
#
# Headless (default): thin wrapper around /dis/speechtest.dis
# (appl/cmd/speechtest.b), which bootstraps speechshim9p + speech9p
# itself and prints partials/finals to this terminal.
#
# GUI (--gui): boots the full lucifer desktop via
# /lib/lucifer/boot-speechtest.sh with voicemode in LLM-free test mode —
# say "hey jarvis", speak, watch the bordered unsent turn update, hear
# the canned phrase. Esc-V / Voice-chip click toggle voice mode as usual.
#
# Usage:
#   tools/speech-test.sh                            # headless, defaults
#   tools/speech-test.sh --gui                      # full desktop, no LLM
#   tools/speech-test.sh -p 'Hello from InferNode'  # custom phrase
#   tools/speech-test.sh -e                         # echo the transcript back
#   tools/speech-test.sh -n 3                       # exit after 3 turns (headless)
#
# Remote topologies (headless only; see docs/SPEECH-REMOTE-AUDIO.md;
# mounts are unauthenticated — trusted networks only):
#   # remote STT+TTS provider:
#   tools/speech-test.sh --no-helpers \
#       -M 'tcp!fast-box!7770 /n/remotespeech' -c 'provider /n/remotespeech'
#   # remote microphone (e.g. InferNode on a phone exporting /dev/audio):
#   tools/speech-test.sh \
#       -M 'tcp!phone!7771 /n/phoneaudio' \
#       -c 'capturedev /n/phoneaudio/audio' -c 'micmode device'
#
# The terminal app needs macOS microphone permission (TCC) for local
# capture; approve the prompt on first run. Ctrl-C exits.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="${INFERNODE_SPEECH_HOME:-$HOME/.local/share/infernode-speech}"

case "$(uname -s)" in
Darwin) EMU="$ROOT/emu/MacOSX/o.emu" ;;
Linux)  EMU="$ROOT/emu/Linux/o.emu" ;;
*)      echo "error: unsupported platform $(uname -s)" >&2; exit 1 ;;
esac
if [ ! -x "$EMU" ]; then
	echo "error: emulator not built: $EMU" >&2
	exit 1
fi

args=(-b)
usehelpers=1
gui=0
phrase='Speech test complete. I heard you.'
echoflag=-
headlessonly=""
while [ $# -gt 0 ]; do
	case "$1" in
	-g|--gui)     gui=1; shift ;;
	-p|--phrase)  phrase="$2"; args+=(-p "$2"); shift 2 ;;
	-n|--turns)   headlessonly="$headlessonly -n"; args+=(-n "$2"); shift 2 ;;
	-c|--ctl)     headlessonly="$headlessonly -c"; args+=(-c "$2"); shift 2 ;;
	-M|--mount)   headlessonly="$headlessonly -M"; args+=(-M "$2"); shift 2 ;;
	-e|--echo)    echoflag=-e; args+=(-e); shift ;;
	-d|--debug)   headlessonly="$headlessonly -d"; args+=(-d); shift ;;
	--no-helpers) usehelpers=0; shift ;;
	-h|--help)    sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)            echo "error: unknown option $1 (see -h)" >&2; exit 2 ;;
	esac
done

helperbin=-
configfile=-
if [ "$usehelpers" = 1 ]; then
	if [ -d "$HELPERS/bin" ]; then
		helperbin="$HELPERS/bin"
		if [ -f "$HELPERS/speech.ctl.sh" ]; then
			configfile="/n/local$HELPERS/speech.ctl.sh"
		fi
	else
		echo "note: $HELPERS/bin not found — run tools/install-speech-helpers.sh," >&2
		echo "      or pass --no-helpers with -c/-M lines for a remote provider" >&2
	fi
fi

if [ "$gui" = 1 ]; then
	if [ -n "$headlessonly" ]; then
		echo "error: headless-only option(s):$headlessonly — not supported with --gui" >&2
		exit 2
	fi
	exec "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m "-r$ROOT" \
		sh -l /lib/lucifer/boot-speechtest.sh "$helperbin" "$echoflag" "$phrase"
fi

if [ "$configfile" != - ]; then
	args=(-b -C "$configfile" "${args[@]:1}")
elif [ "$helperbin" != - ]; then
	args=(-b -H "$helperbin" "${args[@]:1}")
fi

exec "$EMU" -c1 "-r$ROOT" /dis/speechtest.dis "${args[@]}"

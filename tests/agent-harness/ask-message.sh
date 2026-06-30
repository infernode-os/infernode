#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# TESTING HARNESS ONLY — NEVER SHIP IN A RELEASE.
#
# CI enforces this (see CLAUDE.md "ring-fence rule"):
#   release.yml refuses to package any path containing agent-harness;
#   ci.yml refuses such a file outside tests/agent-harness/.
# ─────────────────────────────────────────────────────────────────
#
# ask-message.sh — host launcher for the EVENT-DRIVEN message bridge used by the
# external behavioural-evaluation harness (nerv-bloom). Boots emu with the
# tests/agent-harness/ask-message profile, which brings up the headless agent
# stack + the message layer (msg9p + injectable source + msgwatch), injects ONE
# scenario message through the REAL triage/delegate pipeline, and prints the task
# agent's DRAFTED reply framed by ___NERVA_REPLY_BEGIN___ / ___NERVA_REPLY_END___.
#
# Usage:
#   ask-message.sh --body "<message body>" [--sender X] [--subject Y] [--flags N]
#   ask-message.sh --body-file <path>      [--sender X] [--subject Y] [--flags N]
#   ask-message.sh --help
#
# FLAGS is the MsgSrc bitmask (FUNREAD=1 FFLAGGED=2 FURGENT=4); default 3
# (unread+flagged => triaged "wake"). A local llmsrv (per ~/.infernode/lib/ndb/llm)
# backs /mnt/llm.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
case "$(uname -s)" in
	Linux)   EMU="$ROOT/emu/Linux/o.emu" ;;
	Darwin)  EMU="$ROOT/emu/MacOSX/o.emu" ;;
	*)       echo "ask-message: unsupported platform $(uname -s)" >&2; exit 1 ;;
esac
PROFILE_INF="/tests/agent-harness/ask-message"
PROFILE_HOST="$ROOT/tests/agent-harness/ask-message"

print_help() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

SENDER="someone@example.com"
SUBJECT="Message"
FLAGS="3"
BODY=""
BODY_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--sender)    SENDER="${2:-}"; shift 2 ;;
		--subject)   SUBJECT="${2:-}"; shift 2 ;;
		--flags)     FLAGS="${2:-}"; shift 2 ;;
		--body)      BODY="${2:-}"; shift 2 ;;
		--body-file) BODY_FILE="${2:-}"; shift 2 ;;
		-h|--help)   print_help; exit 0 ;;
		*) echo "ask-message: unknown arg: $1 (try --help)" >&2; exit 2 ;;
	esac
done

[ -x "$EMU" ]          || { echo "ask-message: emu missing at $EMU" >&2; exit 1; }
[ -f "$PROFILE_HOST" ] || { echo "ask-message: profile missing at $PROFILE_HOST" >&2; exit 1; }

if [ -n "$BODY_FILE" ]; then
	[ -f "$BODY_FILE" ] || { echo "ask-message: --body-file not found: $BODY_FILE" >&2; exit 1; }
	BODY="$(cat "$BODY_FILE")"
fi
[ -n "$BODY" ] || { echo "ask-message: --body (or --body-file) required" >&2; exit 2; }

# Flatten newlines in the body — the profile passes it as a single emu argument.
BODY_ONE="$(printf '%s' "$BODY" | tr '\n' ' ')"

exec "$EMU" -c1 -pheap=512m -pmain=512m -pimage=256m -r"$ROOT" \
	sh "$PROFILE_INF" "$SENDER" "$SUBJECT" "$FLAGS" "$BODY_ONE"

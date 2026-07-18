#!/bin/bash
# serve-claude-gate.sh — launch the claude-gate OpenAI-compatible gateway.
#
# Bootstraps a private venv on first run, refuses to leak ANTHROPIC_API_KEY
# into the CLI (which would silently bill the API instead of the
# subscription), and execs the daemon in the foreground (systemd- and
# terminal-friendly; logs to stderr).
#
# Usage:
#   serve-claude-gate.sh              # 127.0.0.1:11435, claude-agent-sdk backend
#   serve-claude-gate.sh --mock       # deterministic mock backend (tests)
#   serve-claude-gate.sh --help
#
# Auth: the Claude Code CLI's own login is used. Either `claude` is already
# logged in for this user, or set CLAUDE_CODE_OAUTH_TOKEN (from
# `claude setup-token`) in the environment / systemd unit.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="$HERE/.venv"

print_help() {
	sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h|--help) print_help; exit 0 ;;
	--mock) export CLAUDE_GATE_MOCK=1; shift ;;
esac

if ! command -v claude >/dev/null 2>&1 && [ "${CLAUDE_GATE_MOCK:-}" != "1" ]; then
	echo "serve-claude-gate: 'claude' CLI not on PATH — install Claude Code first" >&2
	exit 1
fi

if [ ! -x "$VENV/bin/python" ]; then
	echo "serve-claude-gate: bootstrapping venv at $VENV" >&2
	python3 -m venv "$VENV"
	"$VENV/bin/pip" install --quiet --upgrade pip
	"$VENV/bin/pip" install --quiet -r "$HERE/requirements.txt"
fi

# Billing guard: an inherited API key overrides subscription auth in the CLI.
unset ANTHROPIC_API_KEY

exec "$VENV/bin/python" "$HERE/claude_gate.py"

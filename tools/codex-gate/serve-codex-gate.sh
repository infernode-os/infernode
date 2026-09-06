#!/bin/bash
# serve-codex-gate.sh — launch the codex-gate OpenAI-compatible gateway.
#
# Bootstraps a private venv on first run, refuses to leak OPENAI_API_KEY
# into the CLI (which can bill the API instead of the ChatGPT plan), and
# execs the daemon in the foreground (systemd- and terminal-friendly; logs
# to stderr).
#
# Usage:
#   serve-codex-gate.sh              # 127.0.0.1:11436, codex CLI backend
#   serve-codex-gate.sh --mock       # deterministic mock backend (tests)
#   serve-codex-gate.sh --inventory  # hash the CLI's model-side state, exit
#   serve-codex-gate.sh --help
#
# Auth: the Codex CLI's own login is used — run `codex login` once for this
# user (ChatGPT sign-in). The gate never handles credentials itself.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="$HERE/.venv"

print_help() {
	sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h|--help) print_help; exit 0 ;;
	--mock) export CODEX_GATE_MOCK=1; shift ;;
esac

# The umask matters here: a campaign's gateway writes its own logs and the CLI
# writes into CODEX_HOME, which holds an OAuth credential (INFR-412/413).
umask 077

if ! command -v "${CODEX_GATE_BIN:-codex}" >/dev/null 2>&1 && [ "${CODEX_GATE_MOCK:-}" != "1" ]; then
	echo "serve-codex-gate: '${CODEX_GATE_BIN:-codex}' CLI not on PATH — install the Codex CLI first" >&2
	exit 1
fi

if [ ! -x "$VENV/bin/python" ]; then
	echo "serve-codex-gate: bootstrapping venv at $VENV" >&2
	python3 -m venv "$VENV"
	"$VENV/bin/pip" install --quiet --upgrade pip
	"$VENV/bin/pip" install --quiet -r "$HERE/requirements.txt"
fi

# Billing guard: an inherited API key can override ChatGPT auth in the CLI.
unset OPENAI_API_KEY

# Remaining arguments (--inventory [HOME]) go to the gate; the server mode
# takes none.
exec "$VENV/bin/python" "$HERE/codex_gate.py" "$@"

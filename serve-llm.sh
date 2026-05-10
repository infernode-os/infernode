#!/bin/bash
# serve-llm.sh — Headless InferNode LLM 9P gateway (for systemd).
#
# Replaces the standalone llm9p Go daemon with the canonical Limbo
# llmsrv inside emu, loading lib/sh/serve-profile.
#
# Backend config is read inside emu from
#   ~/.infernode/lib/ndb/llm
# (same file the desktop uses).
#
# Usage:
#   serve-llm.sh                  # listen with keyring auth (default)
#   serve-llm.sh --anon-lan       # listen with no authentication
#                                 # (the pre-INFR-16 default; trusted nets only)
#   serve-llm.sh --gen-key        # generate the signer keyfile, then exit
#   serve-llm.sh --help
#
# Default listener: tcp!*!5640 with Inferno Ed25519 keyring auth.
# Clients dial with: mount -k <keyfile> tcp!host!5640 /n/llm
#
# Logs go to stderr; under systemd they land in the journal.
# See docs/HEADLESS-LLM-DAEMON.md §Hardening for the full key-distribution
# story and the trade-offs of --anon-lan.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# Pick the right emu for this platform.
case "$(uname -s)" in
	Linux)   EMU="$ROOT/emu/Linux/o.emu" ;;
	Darwin)  EMU="$ROOT/emu/MacOSX/o.emu" ;;
	*)       echo "serve-llm: unsupported platform $(uname -s)" >&2; exit 1 ;;
esac

PROFILE_REL="lib/sh/serve-profile"
PROFILE_HOST="$ROOT/$PROFILE_REL"
PROFILE_INF="/$PROFILE_REL"

# Keyfile lives under the user's per-machine state, parallel to the
# desktop's ~/.infernode/lib/ndb config. serve-profile binds
# $infhome/lib/keyring over /lib/keyring inside emu, so the in-emu
# path is /lib/keyring/serve-llm.
KEY_HOSTPATH="${HOME}/.infernode/lib/keyring/serve-llm"
KEY_INFPATH="/lib/keyring/serve-llm"

print_help() {
	sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Argument parsing ───────────────────────────────────────────
LISTEN_MODE="keyring"
GEN_KEY=0
for arg in "$@"; do
	case "$arg" in
		--anon-lan) LISTEN_MODE="anon" ;;
		--gen-key)  GEN_KEY=1 ;;
		-h|--help)  print_help; exit 0 ;;
		*) echo "serve-llm: unknown arg: $arg (try --help)" >&2; exit 2 ;;
	esac
done

# ── Sanity checks (always) ─────────────────────────────────────
[ -x "$EMU" ]          || { echo "serve-llm: emu missing at $EMU" >&2; exit 1; }
[ -f "$PROFILE_HOST" ] || { echo "serve-llm: profile missing at $PROFILE_HOST" >&2; exit 1; }

# ── --gen-key path ─────────────────────────────────────────────
# One-shot key generation. createsignerkey.dis writes to a path inside
# the in-emu namespace; we use the in-tree $ROOT/usr/inferno/keyring/
# (which is the natural Inferno location and where test-distributed.sh
# also writes) as a staging spot, then mv to the user's $HOME.
if [ "$GEN_KEY" -eq 1 ]; then
	if [ -f "$KEY_HOSTPATH" ]; then
		echo "serve-llm: keyfile already exists at $KEY_HOSTPATH (refusing to overwrite)" >&2
		echo "serve-llm: delete it manually if you really want to regenerate" >&2
		exit 1
	fi
	mkdir -p "$(dirname "$KEY_HOSTPATH")"
	OWNER="${USER:-$(id -un)}@$(hostname -s | tr -d '.')"
	# tr -d '.': createsignerkey rejects '.' in the owner string (it's
	# a domain-name separator in the keyring's signer protocol).

	STAGE_HOSTPATH="$ROOT/usr/inferno/keyring/serve-llm.staging.$$"
	STAGE_INFPATH="/usr/inferno/keyring/serve-llm.staging.$$"
	mkdir -p "$(dirname "$STAGE_HOSTPATH")"

	echo "serve-llm: generating Ed25519 signer key for $OWNER -> $KEY_HOSTPATH" >&2

	# emu may not exit cleanly after the key is written; cap with timeout.
	# Direct invocation of createsignerkey.dis (no sh -c indirection).
	timeout 30 "$EMU" -c1 "-r$ROOT" \
		/dis/auth/createsignerkey.dis \
		-a ed25519 -f "$STAGE_INFPATH" "$OWNER" \
		</dev/null >&2 || true

	if [ ! -s "$STAGE_HOSTPATH" ]; then
		echo "serve-llm: key generation failed (staging file missing or empty)" >&2
		echo "serve-llm: try running by hand:" >&2
		echo "  $EMU -r$ROOT /dis/auth/createsignerkey.dis -a ed25519 -f $STAGE_INFPATH $OWNER" >&2
		rm -f "$STAGE_HOSTPATH"
		exit 1
	fi

	mv "$STAGE_HOSTPATH" "$KEY_HOSTPATH"
	chmod 600 "$KEY_HOSTPATH"
	echo "serve-llm: wrote $KEY_HOSTPATH ($(wc -c < "$KEY_HOSTPATH") bytes; mode 600)" >&2
	echo "serve-llm: clients dial with: mount -k $KEY_HOSTPATH tcp!<host>!5640 /n/llm" >&2
	exit 0
fi

# ── Locate Ollama on PATH (it runs outside emu, on the host) ──
# Set OLLAMA_BIN=/full/path/to/ollama if it lives somewhere unusual
# (e.g. an external SSD on a Jetson).
if [ -n "${OLLAMA_BIN:-}" ] && [ -x "$OLLAMA_BIN" ]; then
	export PATH="$(dirname "$OLLAMA_BIN"):$PATH"
elif ! command -v ollama >/dev/null 2>&1; then
	for p in /usr/local/bin /usr/bin; do
		if [ -x "$p/ollama" ]; then
			export PATH="$p:$PATH"
			break
		fi
	done
fi

# Pre-flight: warn (don't fail) if Ollama isn't reachable yet — systemd
# will Restart=always us, so a transient race is fine.
if ! curl -sf -m 5 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
	echo "serve-llm: WARN ollama at 127.0.0.1:11434 not responding" >&2
fi

# ── Validate keyring mode has a keyfile ────────────────────────
if [ "$LISTEN_MODE" = "keyring" ] && [ ! -s "$KEY_HOSTPATH" ]; then
	cat >&2 <<EOF
serve-llm: ERROR no keyfile at $KEY_HOSTPATH

  Anonymous-attach defaults were removed in INFR-16. To proceed, either:

    1. Generate a signer keyfile (recommended):
         $0 --gen-key

    2. Listen without authentication (only on a trusted network):
         $0 --anon-lan

  See docs/HEADLESS-LLM-DAEMON.md §Hardening for the trade-offs.
EOF
	exit 1
fi

# ── Hand off to emu, passing intent via env ──────────────────────
export SERVE_LLM_AUTH="$LISTEN_MODE"
export SERVE_LLM_KEY="$KEY_INFPATH"

case "$LISTEN_MODE" in
	keyring) echo "serve-llm: $(date -Iseconds) listen=keyring keyfile=$KEY_HOSTPATH" >&2 ;;
	anon)    echo "serve-llm: $(date -Iseconds) listen=ANONYMOUS (--anon-lan) anyone reaching :5640 can mount /n/llm" >&2 ;;
esac

echo "serve-llm: emu=$EMU root=$ROOT profile=$PROFILE_INF" >&2
exec "$EMU" -c1 "-r$ROOT" sh "$PROFILE_INF"

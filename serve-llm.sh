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
#   serve-llm.sh --cnsa           # force CNSA 2.0 strict crypto (see below)
#   serve-llm.sh --classical      # force classical crypto (see below)
#   serve-llm.sh --help
#
# Default listener: tcp!*!5640 with Inferno keyring auth.
# Clients dial with: mount -k <keyfile> tcp!host!5640 /mnt/llm
#
# CNSA 2.0 strict mode upgrades both crypto layers in lockstep:
#   - session key agreement: ML-KEM-1024  (FIPS 203, instead of ML-KEM-768)
#   - signer keyfile:        ML-DSA-87    (FIPS 204, instead of Ed25519)
# It is read from the host CNSAMODE env var (on unless unset/0/n/N — the same
# rule the emu's keyring.c applies) and overridden by --cnsa / --classical.
# Both ends of a mount MUST agree: a strict listener will not complete a
# handshake with a classical client, and a CNSA-strict listener cannot use an
# Ed25519 keyfile. Regenerate the keyfile with --gen-key whenever you switch
# modes; the alg is chosen by the mode in force at generation time.
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
	# Print the comment header (from line 2 up to, but not including, the
	# first `set -euo pipefail`), stripping leading "# ". Range-free so the
	# header can grow without a hard-coded end line drifting out of sync.
	sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/!p;}' "$0" | sed 's/^# \{0,1\}//'
}

# ── Argument parsing ───────────────────────────────────────────
LISTEN_MODE="keyring"
GEN_KEY=0

# CNSA 2.0 strict mode (ML-KEM-1024 key agreement + ML-DSA-87 signer key).
# Default follows the host CNSAMODE env var using the SAME "on unless
# unset/0/n/N" rule the emu's keyring.c cnsamode() applies, so a fleet-wide
# `Environment=CNSAMODE=1` in the systemd unit Just Works. --cnsa/--classical
# override it explicitly.
cnsa_truthy() {  # mirror keyring.c: set, non-empty, first char not 0/n/N
	case "${1:-}" in
		""|0*|n*|N*) return 1 ;;
		*)           return 0 ;;
	esac
}
if cnsa_truthy "${CNSAMODE:-}"; then CNSA=1; else CNSA=0; fi

for arg in "$@"; do
	case "$arg" in
		--anon-lan)  LISTEN_MODE="anon" ;;
		--gen-key)   GEN_KEY=1 ;;
		--cnsa)      CNSA=1 ;;
		--classical) CNSA=0 ;;
		-h|--help)   print_help; exit 0 ;;
		*) echo "serve-llm: unknown arg: $arg (try --help)" >&2; exit 2 ;;
	esac
done

# Re-pin CNSAMODE to the resolved decision so EVERY emu we spawn (key
# generation below and the listener at the end) reads exactly the policy we
# settled on — regardless of how, or whether, the caller's environment set it.
# emu reflects this into Inferno /env/cnsamode for the Limbo tools
# (createsignerkey, tls); keyring.c reads it via getenv for the native STS
# handshake. "1"/"0" both reflect cleanly and are read consistently at both
# layers.
export CNSAMODE="$CNSA"

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

	# Signer algorithm follows the resolved CNSA decision. Pass it
	# explicitly rather than leaning on createsignerkey's /env/cnsamode
	# default so the keyfile alg is unambiguous from the command alone and
	# never silently inherits a stray host CNSAMODE: -c forces ML-DSA-87,
	# -a ed25519 forces classical.
	if [ "$CNSA" -eq 1 ]; then
		GEN_ALG_ARGS=(-c)            # ML-DSA-87, FIPS 204, NIST Category 5
		GEN_ALG_LABEL="ML-DSA-87 (CNSA 2.0 strict)"
	else
		GEN_ALG_ARGS=(-a ed25519)
		GEN_ALG_LABEL="Ed25519 (classical)"
	fi

	echo "serve-llm: generating $GEN_ALG_LABEL signer key for $OWNER -> $KEY_HOSTPATH" >&2

	# emu may not exit cleanly after the key is written; cap with timeout.
	# Direct invocation of createsignerkey.dis (no sh -c indirection).
	#
	# Bash writes a "Killed   timeout 30 ..." notification to its own
	# fd 2 whenever a waited-for child dies via SIGKILL — which happens
	# here once `timeout` escalates after emu fails to shut down within
	# the deadline (the keyfile has *already* been written cleanly by
	# that point; emu just doesn't tear down promptly). That diagnostic
	# is misleading on the docs-friction path: a first-time user reading
	# `docs/HEADLESS-LLM-DAEMON.md` §Step 4 sees "Killed" and reasonably
	# suspects key generation failed. So we redirect bash's own fd 2 to
	# /dev/null around the timeout invocation, but route emu's stderr
	# through a saved real-stderr fd (9) so the user still sees emu's
	# own diagnostics. See INFR-125.
	exec 9>&2
	exec 2>/dev/null
	timeout 30 "$EMU" -c1 "-r$ROOT" \
		/dis/auth/createsignerkey.dis \
		"${GEN_ALG_ARGS[@]}" -f "$STAGE_INFPATH" "$OWNER" \
		</dev/null >&9 2>&9 &
	gen_pid=$!
	set +e
	wait "$gen_pid"
	gen_ec=$?
	set -e
	exec 2>&9
	exec 9>&-

	# 0       = clean exit
	# 124     = timeout fired (SIGTERM after grace)
	# 137     = SIGKILL escalation
	# anything else is unexpected and worth surfacing.
	if [ ! -s "$STAGE_HOSTPATH" ]; then
		echo "serve-llm: key generation failed (staging file missing or empty; createsignerkey exit=$gen_ec)" >&2
		echo "serve-llm: try running by hand:" >&2
		echo "  CNSAMODE=$CNSAMODE $EMU -r$ROOT /dis/auth/createsignerkey.dis ${GEN_ALG_ARGS[*]} -f $STAGE_INFPATH $OWNER" >&2
		rm -f "$STAGE_HOSTPATH"
		exit 1
	fi
	case "$gen_ec" in
		0|124|137) : ;;
		*) echo "serve-llm: WARN createsignerkey returned unexpected exit $gen_ec (staged file looks ok, proceeding)" >&2 ;;
	esac

	mv "$STAGE_HOSTPATH" "$KEY_HOSTPATH"
	chmod 600 "$KEY_HOSTPATH"
	echo "serve-llm: wrote $KEY_HOSTPATH ($(wc -c < "$KEY_HOSTPATH") bytes; mode 600; alg=$GEN_ALG_LABEL)" >&2
	echo "serve-llm: clients dial with: mount -k $KEY_HOSTPATH tcp!<host>!5640 /mnt/llm" >&2
	if [ "$CNSA" -eq 1 ]; then
		echo "serve-llm: NOTE this is a CNSA-strict keyfile — the client node must also run in CNSA mode (CNSAMODE=1) or the handshake will fail." >&2
	fi
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

# Crypto mode only governs the keyring handshake; --anon-lan attaches with
# -A and never runs it, so CNSA is meaningless there.
if [ "$CNSA" -eq 1 ]; then CRYPTO="CNSA-strict (ML-KEM-1024 + ML-DSA-87)"; else CRYPTO="classical (ML-KEM-768 + Ed25519)"; fi

case "$LISTEN_MODE" in
	keyring) echo "serve-llm: $(date -Iseconds) listen=keyring crypto=$CRYPTO keyfile=$KEY_HOSTPATH" >&2 ;;
	anon)    echo "serve-llm: $(date -Iseconds) listen=ANONYMOUS (--anon-lan) anyone reaching :5640 can mount /mnt/llm" >&2 ;;
esac

echo "serve-llm: emu=$EMU root=$ROOT profile=$PROFILE_INF" >&2
exec "$EMU" -c1 "-r$ROOT" sh "$PROFILE_INF"

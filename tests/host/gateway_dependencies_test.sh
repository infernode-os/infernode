#!/bin/sh
# Gateways must reconcile an existing venv with their exact security pins.

set -eu

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gateway-dependencies.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

check_gate()
{
	name="$1"
	launcher="$2"
	gate_py="$3"
	log="$WORK/$name.log"
	dir="$WORK/$name"

	mkdir -p "$dir/.venv/bin"
	cp "$ROOT/tools/$name/requirements.txt" "$dir/requirements.txt"
	cp "$ROOT/tools/$name/$launcher" "$dir/$launcher"

	cat > "$dir/.venv/bin/pip" <<'EOF'
#!/bin/sh
echo "pip: $*" >> "$TEST_LOG"
EOF
	cat > "$dir/.venv/bin/python" <<'EOF'
#!/bin/sh
echo "python: $*" >> "$TEST_LOG"
EOF
	chmod +x "$dir/.venv/bin/pip" "$dir/.venv/bin/python" "$dir/$launcher"

	TEST_LOG="$log" "$dir/$launcher" --mock

	first="$(sed -n '1p' "$log")"
	second="$(sed -n '2p' "$log")"
	case "$first" in
	"pip: install --quiet -r $dir/requirements.txt") ;;
	*) fail "$name did not reconcile its existing venv first: $first" ;;
	esac
	case "$second" in
	"python: $dir/$gate_py") ;;
	*) fail "$name did not start through the reconciled venv: $second" ;;
	esac
	[ "$(wc -l < "$log")" -eq 2 ] ||
		fail "$name ran unexpected environment commands"
}

grep -qx 'aiohttp==3.14.4' "$ROOT/tools/claude-gate/requirements.txt" ||
	fail "claude-gate does not pin the audited aiohttp release"
grep -qx 'claude-agent-sdk==0.2.164' "$ROOT/tools/claude-gate/requirements.txt" ||
	fail "claude-gate does not pin the audited SDK release"
grep -qx 'aiohttp==3.14.4' "$ROOT/tools/codex-gate/requirements.txt" ||
	fail "codex-gate does not pin the audited aiohttp release"

check_gate claude-gate serve-claude-gate.sh claude_gate.py
check_gate codex-gate serve-codex-gate.sh codex_gate.py

echo "gateway dependency pins and existing-venv reconciliation: PASS"

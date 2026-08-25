#!/bin/sh
set -eu

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

mkdir -p "$WORK/tests/agent-harness" "$WORK/emu/Linux" "$WORK/emu/MacOSX"
cp "$ROOT/tests/agent-harness/serve-agent.sh" "$WORK/tests/agent-harness/serve-agent.sh"
touch "$WORK/tests/agent-harness/serve-agent"
cat > "$WORK/fake-emu" <<'EOF'
#!/bin/sh
printf 'CNSAMODE=%s\n' "${CNSAMODE-unset}"
printf 'SERVE_LLM_AUTH=%s\n' "${SERVE_LLM_AUTH-unset}"
printf 'ARGS=%s\n' "$*"
EOF
chmod +x "$WORK/tests/agent-harness/serve-agent.sh" "$WORK/fake-emu"
cp "$WORK/fake-emu" "$WORK/emu/Linux/o.emu"
cp "$WORK/fake-emu" "$WORK/emu/MacOSX/o.emu"

WRAPPER="$WORK/tests/agent-harness/serve-agent.sh"

check_mode() {
	input=$1
	want=$2
	if [ "$input" = unset ]; then
		out=$(unset CNSAMODE; "$WRAPPER" --anon-lan 2>&1)
	else
		out=$(CNSAMODE="$input" "$WRAPPER" --anon-lan 2>&1)
	fi
	echo "$out" | grep -q "^CNSAMODE=$want$" || {
		echo "serve_agent_cnsa_test: input=$input: expected CNSAMODE=$want" >&2
		echo "$out" >&2
		exit 1
	}
	echo "$out" | grep -q "  cnsa    = $want " || {
		echo "serve_agent_cnsa_test: input=$input: startup banner disagrees" >&2
		echo "$out" >&2
		exit 1
	}
	echo "$out" | grep -q '^SERVE_LLM_AUTH=anon$' || {
		echo "serve_agent_cnsa_test: auth mode not propagated" >&2
		exit 1
	}
}

check_mode unset 0
check_mode 0 0
check_mode no 0
check_mode Never 0
check_mode 1 1
check_mode yes 1

printf 'serve_agent_cnsa_test: PASS\n'

#!/bin/sh
# tests/host/codex_gate_test.sh — codex-gate mock-mode host tests.
#
# Exercises the OpenAI-compatible surface and the prompt-level tool bridge
# (tool_calls emission → results replayed on the next request) with
# CODEX_GATE_MOCK=1: deterministic, no codex CLI, no billing.
# Skips (exit 77) when python3/aiohttp are unavailable.
#
# Run from project root: ./tests/host/codex_gate_test.sh

set -eu

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
GATE="$ROOT/tools/codex-gate/codex_gate.py"
PORT=21436

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"; exit 77
fi
if ! python3 -c "import aiohttp" 2>/dev/null; then
    echo "SKIP: aiohttp not available"; exit 77
fi
[ -f "$GATE" ] || { echo "FAIL: $GATE missing" >&2; exit 1; }

echo "=== codex-gate mock-mode tests ==="

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

CODEX_GATE_MOCK=1 CODEX_GATE_PORT=$PORT python3 "$GATE" >/dev/null 2>&1 &
GATE_PID=$!
trap 'kill $GATE_PID 2>/dev/null || true' EXIT

# Wait for the listener.
i=0
while ! curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    i=$((i+1))
    [ $i -lt 30 ] || fail "gate did not come up on :$PORT"
    sleep 0.2
done

BASE="http://127.0.0.1:$PORT"

# 1. /health reports the mock backend
out="$(curl -sf "$BASE/health")"
echo "$out" | grep -q '"backend": "mock"' || fail "health: wrong backend ($out)"
echo "$out" | grep -q '"held_turns": 0' || fail "health: held_turns missing ($out)"
pass "health reports mock backend"

# 2. /v1/models lists the aliases llmsrv's model picker shows
out="$(curl -sf "$BASE/v1/models")"
echo "$out" | grep -q '"gpt-5-codex"' || fail "models: gpt-5-codex missing ($out)"
pass "models lists aliases"

# 3. Plain completion — OpenAI shape llmclient.b parses
out="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"gpt-5-codex","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"system","content":"sys"},{"role":"user","content":"hello"}]}')"
echo "$out" | grep -q '"content": "MOCK_REPLY: hello"' || fail "plain: bad content ($out)"
echo "$out" | grep -q '"finish_reason": "stop"' || fail "plain: bad finish_reason"
echo "$out" | grep -q '"total_tokens"' || fail "plain: usage missing"
pass "plain completion round-trips"

# 4. Tool bridge: tool_calls emission, then results replayed by llmsrv
r1="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"gpt-5-codex","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"user","content":"MOCK_TOOL_CALL geo {\"q\":\"Oslo\"}"}],
    "tools":[{"type":"function","function":{"name":"geo","description":"d",
        "parameters":{"type":"object","properties":{"q":{"type":"string"}}}}}],
    "tool_choice":"auto"}')"
echo "$r1" | grep -q '"finish_reason": "tool_calls"' || fail "bridge: no tool_calls ($r1)"
echo "$r1" | grep -q '"name": "geo"' || fail "bridge: wrong tool name"
# arguments must be a JSON *string* (llmclient.b picks String)
echo "$r1" | grep -q '"arguments": "{' || fail "bridge: arguments not a string"
tid="$(echo "$r1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["tool_calls"][0]["id"])')"
pass "tool_calls emitted"

# The gate is stateless — nothing is held between the two requests.
out="$(curl -sf "$BASE/health")"
echo "$out" | grep -q '"held_turns": 0' || fail "bridge: gate should hold nothing ($out)"
pass "no turn held (stateless gate)"

r2="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"gpt-5-codex","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"user","content":"MOCK_TOOL_CALL geo {\"q\":\"Oslo\"}"},
        {"role":"assistant","content":"","tool_calls":[{"id":"'"$tid"'","type":"function",
            "function":{"name":"geo","arguments":"{\"q\":\"Oslo\"}"}}]},
        {"role":"tool","content":"59.91N","tool_call_id":"'"$tid"'"}]}')"
echo "$r2" | grep -q 'TOOL_RESULT_WAS: 59.91N' || fail "bridge: continuation lost result ($r2)"
echo "$r2" | grep -q '"finish_reason": "stop"' || fail "bridge: continuation bad finish"
pass "continuation replays tool results"

# 5. Error results are flagged to the model
r2="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"gpt-5-codex","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"user","content":"q"},
        {"role":"tool","content":"Error: boom","tool_call_id":"call_x"}]}')"
echo "$r2" | grep -q '(is_error)' || fail "error result not flagged ($r2)"
pass "tool errors propagate is_error"

# 6. Streaming: single-chunk SSE with delta + [DONE]
r="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"gpt-5-codex","max_tokens":64,"temperature":0.0,"stream":true,
    "messages":[{"role":"user","content":"hi"}]}')"
echo "$r" | grep -q '"content": "MOCK_REPLY: hi"' || fail "stream: delta missing ($r)"
echo "$r" | grep -q 'data: \[DONE\]' || fail "stream: no [DONE]"
pass "SSE streaming shape"

# 7. The prompt-level tool protocol parses into OpenAI tool_calls
python3 - "$ROOT" <<'PY' || fail "tool-reply parser"
import sys, importlib.util
spec = importlib.util.spec_from_file_location(
    "codex_gate", sys.argv[1] + "/tools/codex-gate/codex_gate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c, calls = m.parse_tool_reply('{"content":"","tool_calls":[{"name":"geo","arguments":"{\\"q\\":\\"Oslo\\"}"}]}')
assert calls == [("geo", {"q": "Oslo"})], calls
c, calls = m.parse_tool_reply('```json\n{"content":"hi","tool_calls":[]}\n```')
assert (c, calls) == ("hi", []), (c, calls)
c, calls = m.parse_tool_reply('just prose')          # degraded, never fatal
assert (c, calls) == ("just prose", []), (c, calls)
PY
pass "tool-reply parser handles fences and prose"

# 8. codex exec argv: sandboxed, private workdir, prompt on stdin
python3 - "$ROOT" <<'PY' || fail "argv shape"
import sys, importlib.util
spec = importlib.util.spec_from_file_location(
    "codex_gate", sys.argv[1] + "/tools/codex-gate/codex_gate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
argv = m.build_argv("gpt-5-codex", "/tmp/s.json", "/tmp/last.txt", "PROMPT")
assert argv[:2] == ["codex", "exec"], argv
assert "--sandbox" in argv and argv[argv.index("--sandbox") + 1] == "read-only", argv
assert argv[argv.index("--cd") + 1] == m.WORKDIR, argv
assert argv[argv.index("--output-schema") + 1] == "/tmp/s.json", argv
assert argv[-1] == "-", argv
assert "PROMPT" not in argv, argv
# No schema (no tools in the request) ⇒ no --output-schema flag at all.
argv = m.build_argv("", None, "/tmp/last.txt", "PROMPT")
assert "--output-schema" not in argv, argv
assert "-m" not in argv, argv
PY
pass "codex exec argv is sandboxed and stdin-fed"

# 9. Subscription guard: the gate serves the host's `codex login`, never an
#    API key. It refuses to start while OPENAI_API_KEY is set (which the CLI
#    can prefer over the ChatGPT sign-in), and never passes one to the child.
out="$(OPENAI_API_KEY=sk-nope python3 "$GATE" 2>&1 || true)"
echo "$out" | grep -q "OPENAI_API_KEY is set" || fail "gate started with an API key set ($out)"
pass "gate refuses to start with OPENAI_API_KEY set"

python3 - "$ROOT" <<'PY' || fail "API key reaches the CLI"
import os, sys, importlib.util
os.environ["OPENAI_API_KEY"] = "sk-nope"
os.environ["CODEX_GATE_MOCK"] = "1"          # skip the startup guard, test the plumbing
spec = importlib.util.spec_from_file_location(
    "codex_gate", sys.argv[1] + "/tools/codex-gate/codex_gate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert "OPENAI_API_KEY" not in m.child_env(), "API key leaked into the codex child env"
src = open(sys.argv[1] + "/tools/codex-gate/codex_gate.py").read()
for bad in ("Authorization", "Bearer"):
    assert bad not in src, "gate builds an auth header: " + bad
PY
pass "no API key reaches the codex CLI, no auth header anywhere"

echo "=== codex-gate mock-mode tests: all green ==="

#!/bin/sh
# tests/host/claude_gate_test.sh — claude-gate mock-mode host tests.
#
# Exercises the OpenAI-compatible surface and the hanging tool bridge
# (tool_calls emission → held turn → result delivery → continuation)
# with CLAUDE_GATE_MOCK=1: deterministic, no claude CLI, no billing.
# Skips (exit 77) when python3/aiohttp are unavailable.
#
# Run from project root: ./tests/host/claude_gate_test.sh

set -eu

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
GATE="$ROOT/tools/claude-gate/claude_gate.py"
PORT=21435

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"; exit 77
fi
if ! python3 -c "import aiohttp" 2>/dev/null; then
    echo "SKIP: aiohttp not available"; exit 77
fi
[ -f "$GATE" ] || { echo "FAIL: $GATE missing" >&2; exit 1; }

echo "=== claude-gate mock-mode tests ==="

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

CLAUDE_GATE_MOCK=1 CLAUDE_GATE_PORT=$PORT python3 "$GATE" >/dev/null 2>&1 &
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
pass "health reports mock backend"

# 2. /v1/models lists the aliases llmsrv's model picker shows
out="$(curl -sf "$BASE/v1/models")"
echo "$out" | grep -q '"sonnet"' || fail "models: sonnet missing"
echo "$out" | grep -q '"opus"'   || fail "models: opus missing"
pass "models lists aliases"

# 3. Plain completion — OpenAI shape llmclient.b parses
out="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"sonnet","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"system","content":"sys"},{"role":"user","content":"hello"}]}')"
echo "$out" | grep -q '"content": "MOCK_REPLY: hello"' || fail "plain: bad content ($out)"
echo "$out" | grep -q '"finish_reason": "stop"' || fail "plain: bad finish_reason"
echo "$out" | grep -q '"total_tokens"' || fail "plain: usage missing"
pass "plain completion round-trips"

# 4. Tool bridge: tool_calls emission, held turn, continuation
r1="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"sonnet","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"user","content":"MOCK_TOOL_CALL geo {\"q\":\"Oslo\"}"}],
    "tools":[{"type":"function","function":{"name":"geo","description":"d",
        "parameters":{"type":"object","properties":{"q":{"type":"string"}}}}}],
    "tool_choice":"auto"}')"
echo "$r1" | grep -q '"finish_reason": "tool_calls"' || fail "bridge: no tool_calls ($r1)"
echo "$r1" | grep -q '"name": "geo"' || fail "bridge: wrong tool name"
# arguments must be a JSON *string* (llmclient.b picks String)
echo "$r1" | grep -q '"arguments": "{' || fail "bridge: arguments not a string"
tid="$(echo "$r1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["tool_calls"][0]["id"])')"

out="$(curl -sf "$BASE/health")"
echo "$out" | grep -q '"held_turns": 1' || fail "bridge: turn not held ($out)"
pass "tool_calls emitted + turn held"

r2="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"sonnet","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"user","content":"MOCK_TOOL_CALL geo {\"q\":\"Oslo\"}"},
        {"role":"assistant","content":"","tool_calls":[{"id":"'"$tid"'","type":"function",
            "function":{"name":"geo","arguments":"{\"q\":\"Oslo\"}"}}]},
        {"role":"tool","content":"59.91N","tool_call_id":"'"$tid"'"}]}')"
echo "$r2" | grep -q 'TOOL_RESULT_WAS: 59.91N' || fail "bridge: continuation lost result ($r2)"
echo "$r2" | grep -q '"finish_reason": "stop"' || fail "bridge: continuation bad finish"
out="$(curl -sf "$BASE/health")"
echo "$out" | grep -q '"held_turns": 0' || fail "bridge: turn not released ($out)"
pass "continuation resolves held turn"

# 5. Error results propagate is_error to the handler
r1="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"sonnet","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"user","content":"MOCK_TOOL_CALL geo {\"q\":\"x\"}"}],
    "tools":[{"type":"function","function":{"name":"geo","description":"d",
        "parameters":{"type":"object","properties":{"q":{"type":"string"}}}}}]}')"
tid="$(echo "$r1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["tool_calls"][0]["id"])')"
r2="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"sonnet","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"tool","content":"Error: boom","tool_call_id":"'"$tid"'"}]}')"
echo "$r2" | grep -q '(is_error)' || fail "error result not flagged ($r2)"
pass "tool errors propagate is_error"

# 6. Orphan tool result (no held turn) falls back to a fresh replay
r="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"sonnet","max_tokens":64,"temperature":0.0,
    "messages":[{"role":"user","content":"earlier question"},
        {"role":"tool","content":"stale","tool_call_id":"toolu_gone"}]}')"
echo "$r" | grep -q 'MOCK_REPLY' || fail "orphan result: replay path broken ($r)"
pass "orphan tool result replays as fresh query"

# 7. Streaming: single-chunk SSE with delta + [DONE]
r="$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d '{
    "model":"sonnet","max_tokens":64,"temperature":0.0,"stream":true,
    "messages":[{"role":"user","content":"hi"}]}')"
echo "$r" | grep -q '"content": "MOCK_REPLY: hi"' || fail "stream: delta missing ($r)"
echo "$r" | grep -q 'data: \[DONE\]' || fail "stream: no [DONE]"
pass "SSE streaming shape"

echo "=== claude-gate mock-mode tests: all green ==="

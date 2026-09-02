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
echo "$out" | grep -q '"idle_timeout_seconds": 300' || fail "health: idle timeout missing ($out)"
pass "health reports mock backend"

# 2. /v1/models lists the aliases llmsrv's model picker shows
out="$(curl -sf "$BASE/v1/models")"
echo "$out" | grep -q '"default"' || fail "models: default missing ($out)"
pass "models lists stable CLI default"

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

# A real Codex reasoning turn can exceed llmclient's no-progress window before
# producing its final structured message. The gate commits SSE headers first
# and sends comments while the CLI runs, so that valid work is not mistaken
# for a dead connection.
SLOW_PORT=$((PORT+2))
CODEX_GATE_MOCK=1 CODEX_GATE_MOCK_DELAY=0.25 \
CODEX_GATE_HEARTBEAT=0.05 CODEX_GATE_PORT=$SLOW_PORT \
    python3 "$GATE" >/dev/null 2>&1 &
SLOW_PID=$!
trap 'kill $GATE_PID $SLOW_PID 2>/dev/null || true' EXIT
i=0
while ! curl -sf -m 1 "http://127.0.0.1:$SLOW_PORT/health" >/dev/null 2>&1; do
    i=$((i+1))
    [ $i -lt 30 ] || fail "slow gate did not come up on :$SLOW_PORT"
    sleep 0.2
done
r="$(curl -sf --no-buffer "http://127.0.0.1:$SLOW_PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' -d '{
    "model":"default","stream":true,
    "messages":[{"role":"user","content":"slow"}]}')"
echo "$r" | grep -q ': codex-gate working' || fail "stream: heartbeat missing ($r)"
echo "$r" | grep -q '"content": "MOCK_REPLY: slow"' || fail "stream: delayed reply missing ($r)"
kill "$SLOW_PID" 2>/dev/null || true
wait "$SLOW_PID" 2>/dev/null || true
pass "SSE heartbeat covers long Codex turns"

python3 - "$ROOT" <<'PY' || fail "cancelled codex process cleanup"
import asyncio
import importlib.util
import sys

spec = importlib.util.spec_from_file_location(
    "codex_gate", sys.argv[1] + "/tools/codex-gate/codex_gate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class Proc:
    returncode = None
    killed = False
    waited = False
    pid = 12345
    def __init__(self):
        self.stdout = asyncio.StreamReader()
        self.stderr = asyncio.StreamReader()
        self.stdin = self.Stdin()
        self.exited = asyncio.Event()
    class Stdin:
        def write(self, data):
            pass
        async def drain(self):
            pass
        def close(self):
            pass
    def kill(self):
        self.killed = True
        self.returncode = -9
        self.exited.set()
    async def wait(self):
        self.waited = True
        await self.exited.wait()
        return self.returncode

async def check():
    proc = Proc()
    async def create(*args, **kwargs):
        return proc
    m.asyncio.create_subprocess_exec = create
    m.os.killpg = lambda pid, sig: proc.kill()
    task = asyncio.create_task(m.run_codex("default", "prompt", None))
    await asyncio.sleep(0)
    await asyncio.sleep(0)
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("cancelled run_codex returned normally")
    assert proc.killed and proc.waited, (proc.killed, proc.waited)

asyncio.run(check())
PY
pass "cancelled streams reap codex exec"

# 7. A terminal usage-limit failure is structured and distinct from model
#    output. Disable recovery here to exercise the exhausted-policy response.
ERROR_PORT=$((PORT+1))
CODEX_GATE_MOCK=1 \
CODEX_GATE_MOCK_ERROR='usage limit reached; retry after reset' \
CODEX_GATE_QUOTA_MAX_WAIT=0 \
CODEX_GATE_PORT=$ERROR_PORT python3 "$GATE" >/dev/null 2>&1 &
ERROR_PID=$!
ERROR_BODY="$(mktemp "${TMPDIR:-/tmp}/codex-gate-error.XXXXXX")"
trap 'kill $GATE_PID $ERROR_PID 2>/dev/null || true; rm -f "$ERROR_BODY"' EXIT
i=0
while ! curl -sf -m 1 "http://127.0.0.1:$ERROR_PORT/health" >/dev/null 2>&1; do
    i=$((i+1))
    [ $i -lt 30 ] || fail "error-injection gate did not come up on :$ERROR_PORT"
    sleep 0.2
done
status="$(curl -s -o "$ERROR_BODY" -w '%{http_code}' \
    "http://127.0.0.1:$ERROR_PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"default","messages":[{"role":"user","content":"hello"}]}')"
[ "$status" = 429 ] || fail "fault injection returned HTTP $status"
grep -q '"type": "usage_limit"' "$ERROR_BODY" || \
    fail "fault injection lost structured usage-limit type"
grep -q '"retryable": true' "$ERROR_BODY" || \
    fail "fault injection is not marked retryable"
if grep -q 'retry after reset' "$ERROR_BODY"; then
    fail "raw provider quota text escaped into the response"
fi
pass "usage-limit exhaustion returns structured HTTP 429"

stream_error="$(curl -sf --no-buffer \
    "http://127.0.0.1:$ERROR_PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"default","stream":true,"messages":[{"role":"user","content":"hello"}]}')"
echo "$stream_error" | grep -q '"type": "usage_limit"' || \
    fail "streaming quota failure lost structured error ($stream_error)"
if echo "$stream_error" | grep -q '"content"'; then
    fail "streaming quota failure was emitted as assistant content"
fi
pass "streaming usage-limit error is not assistant content"

# 8. A transient limit pauses and retries the exact request. While sleeping,
#    /health exposes machine-readable state; the successful response contains
#    no quota text and requires no client-side transcript mutation.
RECOVER_PORT=$((PORT+3))
RECOVER_BODY="$(mktemp "${TMPDIR:-/tmp}/codex-gate-recover.XXXXXX")"
CODEX_GATE_MOCK=1 \
CODEX_GATE_MOCK_ERROR='usage limit reached; try again in 1 second' \
CODEX_GATE_MOCK_ERROR_COUNT=1 \
CODEX_GATE_QUOTA_BACKOFF=0.05 \
CODEX_GATE_QUOTA_MAX_WAIT=5 \
CODEX_GATE_PORT=$RECOVER_PORT python3 "$GATE" >/dev/null 2>&1 &
RECOVER_PID=$!
trap 'kill $GATE_PID $ERROR_PID $RECOVER_PID 2>/dev/null || true; rm -f "$ERROR_BODY" "$RECOVER_BODY"' EXIT
i=0
while ! curl -sf -m 1 "http://127.0.0.1:$RECOVER_PORT/health" >/dev/null 2>&1; do
    i=$((i+1))
    [ $i -lt 30 ] || fail "recovery gate did not come up on :$RECOVER_PORT"
    sleep 0.2
done
curl -sf "http://127.0.0.1:$RECOVER_PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"default","messages":[{"role":"user","content":"resume me"}]}' \
    >"$RECOVER_BODY" &
RECOVER_CURL_PID=$!
sleep 0.2
out="$(curl -sf "http://127.0.0.1:$RECOVER_PORT/health")"
echo "$out" | grep -q '"state": "paused_quota"' || \
    fail "gateway did not expose quota pause ($out)"
echo "$out" | grep -q '"paused_turns": 1' || \
    fail "gateway did not count paused turn ($out)"
wait "$RECOVER_CURL_PID"
grep -q 'MOCK_REPLY: resume me' "$RECOVER_BODY" || \
    fail "paused request did not resume"
if grep -qi 'usage limit' "$RECOVER_BODY"; then
    fail "quota text was returned as model output"
fi
out="$(curl -sf "http://127.0.0.1:$RECOVER_PORT/health")"
echo "$out" | grep -q '"state": "ready"' || fail "gateway did not return to ready"
echo "$out" | grep -q '"state": "resumed"' || fail "gateway lost resume evidence"
pass "usage-limit pause resumes the same request"

python3 - "$ROOT" <<'PY' || fail "bounded quota exhaustion"
import asyncio
import importlib.util
import sys

spec = importlib.util.spec_from_file_location(
    "codex_gate", sys.argv[1] + "/tools/codex-gate/codex_gate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.QUOTA_MAX_WAIT = 0.12
m.QUOTA_BACKOFF = 0.05
m.QUOTA_MAX_BACKOFF = 0.05
calls = 0

async def fail():
    global calls
    calls += 1
    raise m.CodexError("usage limit reached")

async def check():
    try:
        await m.run_with_quota_recovery(fail)
    except m.UsageLimitError:
        pass
    else:
        raise AssertionError("unbounded quota retry returned")
    assert calls >= 2, calls
    assert m._last_quota_pause["state"] == "exhausted", m._last_quota_pause
    assert m._last_quota_pause["duration_seconds"] >= 0.12, m._last_quota_pause
    assert not m._quota_pauses, m._quota_pauses

    # An operator who has reset quota can wake the same held request instead
    # of waiting for stale provider reset metadata to expire.
    m.QUOTA_MAX_WAIT = 5
    m.QUOTA_BACKOFF = 5
    m.QUOTA_MAX_BACKOFF = 5
    wake_calls = 0
    async def wake_once():
        nonlocal wake_calls
        wake_calls += 1
        if wake_calls == 1:
            raise m.CodexError("usage limit reached")
        return "resumed"
    held = asyncio.create_task(m.run_with_quota_recovery(wake_once))
    for _ in range(100):
        if m._quota_pauses:
            break
        await asyncio.sleep(0.01)
    assert m.request_quota_retry() == 1
    assert await asyncio.wait_for(held, 1) == "resumed"
    assert wake_calls == 2, wake_calls
    assert m._last_quota_pause["state"] == "resumed", m._last_quota_pause
    assert not m._quota_pauses and not m._quota_wakes

    # The campaign control can target a delegated child without spending the
    # one-shot fault on its parent request.
    selector = "You are a task execution agent working autonomously."
    m.MOCK_ERROR = "usage limit reached"
    m.MOCK_ERROR_COUNT = 1
    m.MOCK_ERROR_SYSTEM_MATCH = selector
    m._mock_errors_remaining = 1
    parent = await m.mock_turn("default", "parent", "create child", [], [])
    assert parent[0].startswith("MOCK_REPLY:"), parent
    try:
        await m.mock_turn("default", selector, "child brief", [], [])
    except m.CodexError as error:
        assert "usage limit" in str(error)
    else:
        raise AssertionError("selected child mock did not fail")
    resumed = await m.mock_turn("default", selector, "child brief", [], [])
    assert resumed[0] == "MOCK_REPLY: child brief", resumed

asyncio.run(check())
PY
pass "quota retries are bounded and can target a delegated child"

# 9. The prompt-level tool protocol parses into OpenAI tool_calls
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

# 9. codex exec argv: sandboxed, private workdir, prompt on stdin
python3 - "$ROOT" <<'PY' || fail "argv shape"
import sys, importlib.util
spec = importlib.util.spec_from_file_location(
    "codex_gate", sys.argv[1] + "/tools/codex-gate/codex_gate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
argv = m.build_argv("gpt-5-codex", "/tmp/s.json", "/tmp/last.txt", "PROMPT")
assert argv[:2] == ["codex", "exec"], argv
assert "--sandbox" in argv and argv[argv.index("--sandbox") + 1] == "read-only", argv
disabled = [argv[i + 1] for i, a in enumerate(argv) if a == "--disable"]
assert "shell_tool" in disabled, argv
assert "--strict-config" in argv, argv
assert any(a.startswith("developer_instructions=") for a in argv), argv
assert argv[argv.index("--cd") + 1] == m.WORKDIR, argv
assert argv[argv.index("--output-schema") + 1] == "/tmp/s.json", argv
assert argv[-1] == "-", argv
assert "PROMPT" not in argv, argv
# The advertised default must not become `codex -m default`.
argv = m.build_argv("default", None, "/tmp/last.txt", "PROMPT")
assert "-m" not in argv, argv
# No schema (no tools in the request) ⇒ no --output-schema flag at all.
argv = m.build_argv("", None, "/tmp/last.txt", "PROMPT")
assert "--output-schema" not in argv, argv
assert "-m" not in argv, argv
PY
pass "codex exec argv is sandboxed and stdin-fed"

# A CLI that starts a turn and then stops producing events must not consume the
# rest of a child campaign deadline. The gate kills its whole process group and
# returns a terminal error while retaining the longer total limit for active
# extended-reasoning turns.
python3 - "$ROOT" <<'PY' || fail "idle Codex process was not reaped"
import asyncio
import importlib.util
import os
import stat
import sys
import tempfile

root = sys.argv[1]
with tempfile.TemporaryDirectory() as td:
    fake = os.path.join(td, "fake-codex")
    with open(fake, "w") as stream:
        stream.write("#!/bin/sh\ncat >/dev/null\nprintf '{\\\"type\\\":\\\"turn.started\\\"}\\n'\nsleep 30\n")
    os.chmod(fake, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    os.environ["CODEX_GATE_BIN"] = fake
    os.environ["CODEX_GATE_TIMEOUT"] = "5"
    os.environ["CODEX_GATE_IDLE_TIMEOUT"] = "0.1"
    os.environ["CODEX_GATE_WORKDIR"] = td
    spec = importlib.util.spec_from_file_location(
        "codex_gate_idle", root + "/tools/codex-gate/codex_gate.py")
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)

    async def check():
        try:
            await gate.run_codex("default", "prompt", None)
        except gate.CodexError as error:
            assert "IDLE_TIMEOUT" in str(error), error
        else:
            raise AssertionError("hung CLI returned")

    asyncio.run(check())
PY
pass "silent Codex turns fail within the idle deadline"

# 10. Subscription guard: the gate serves the host's `codex login`, never an
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

# 11. A logged-out CLI must prevent readiness rather than serving a static
# model list that makes llmctl report a healthy but unusable backend.
python3 - "$ROOT" <<'PY' || fail "login readiness check"
import sys, importlib.util
spec = importlib.util.spec_from_file_location(
    "codex_gate", sys.argv[1] + "/tools/codex-gate/codex_gate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.MOCK = False
class Result:
    stdout = "Logged in using ChatGPT"
    stderr = ""
    returncode = 0
m.subprocess.run = lambda *args, **kwargs: Result()
m.check_codex_auth()
Result.returncode = 1
Result.stderr = "Not logged in"
try:
    m.check_codex_auth()
except SystemExit as e:
    assert "Not logged in" in str(e), e
else:
    raise AssertionError("logged-out CLI accepted")
Result.returncode = 0
Result.stderr = ""
Result.stdout = "Logged in using an API key"
try:
    m.check_codex_auth()
except SystemExit as e:
    assert "not logged in with ChatGPT" in str(e), e
else:
    raise AssertionError("API-key login accepted as ChatGPT OAuth")
PY
pass "startup readiness requires a ChatGPT OAuth login"

# 11. The CLI's own plugin/skill/MCP surface is pinned, not inherited.
#     Codex CLI 0.149.0 filled a fresh CODEX_HOME (auth.json only) with 144
#     plugin-cache files, 60 system-skill files and a shell snapshot during
#     the escape-room campaign (INFR-413). None of it was recorded anywhere.
python3 - "$ROOT" <<'PY' || fail "gateway hardening"
import importlib.util
import json
import os
import sys
import tempfile

root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "codex_gate", root + "/tools/codex-gate/codex_gate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# Every hardening flag reaches the child, and none of them is droppable: a
# CLI that rejects one must fail loudly, exactly as with --sandbox.
argv = m.build_argv("gpt-5-codex", "/tmp/s.json", "/tmp/last.txt", "PROMPT")
for flag in ("--ephemeral", "--ignore-user-config", "--ignore-rules"):
    assert flag in argv, (flag, argv)
    assert flag not in m.OPTIONAL_FLAGS, flag
assert "--sandbox" not in m.OPTIONAL_FLAGS
disabled = [argv[i + 1] for i, a in enumerate(argv) if a == "--disable"]
for feature in ("plugins", "apps", "skill_search", "memories",
                "shell_snapshot", "shell_tool", "hooks", "multi_agent"):
    assert feature in disabled, (feature, disabled)
assert disabled == list(m.disabled_features()), (disabled, m.disabled_features())
# The recorded profile is built from the same function as the argv, so a
# campaign manifest cannot describe flags the gate did not actually pass.
flags = m.profile_flags()
assert flags == argv[2:2 + len(flags)], (flags, argv)

# Turning hardening off is deliberate and visible — but the adapter's own
# security contract (no native shell) is not part of the switch.
os.environ["CODEX_GATE_HARDEN"] = "0"
m.HARDEN = False
assert m.disabled_features() == ("shell_tool",), m.disabled_features()
assert "--ephemeral" not in m.profile_flags(), m.profile_flags()
m.HARDEN = True
del os.environ["CODEX_GATE_HARDEN"]

# An isolated Codex home holds the dedicated login and nothing else.
with tempfile.TemporaryDirectory() as td:
    home = os.path.join(td, "codex-home")
    os.mkdir(home, 0o700)
    open(os.path.join(home, "auth.json"), "w").write("{}")
    assert m.codex_home_violations(home, m.home_allowlist()) == []

    for name in ("config.toml", "AGENTS.md", "mcp.json"):
        path = os.path.join(home, name)
        open(path, "w").write("x")
        violations = m.codex_home_violations(home, m.home_allowlist())
        assert any(name in v for v in violations), (name, violations)
        os.unlink(path)

    for name in ("plugins", "skills", "rules", "shell_snapshots"):
        path = os.path.join(home, name)
        os.mkdir(path)
        violations = m.codex_home_violations(home, m.home_allowlist())
        assert any(name in v and "directory" in v for v in violations), \
            (name, violations)
        os.rmdir(path)

    # It also holds an OAuth credential, so a readable home is a violation.
    os.chmod(home, 0o755)
    violations = m.codex_home_violations(home, m.home_allowlist())
    assert any("credentials" in v for v in violations), violations
    os.chmod(home, 0o700)

    # The post-campaign inventory accounts for what the CLI created itself.
    os.makedirs(os.path.join(home, "plugins", "cache"))
    open(os.path.join(home, "plugins", "cache", "catalog.json"), "w").write("[]")
    inventory = m.codex_home_inventory(home)
    assert inventory["files"] == 2, inventory
    paths = sorted(e["path"] for e in inventory["entries"])
    assert paths == ["auth.json", "plugins/cache/catalog.json"], paths
    assert all(len(e["sha256"]) == 64 for e in inventory["entries"]), inventory
    assert inventory["credential_files"] == 1, inventory
    assert inventory["persistent_cli_state_files"] == 1, inventory
    assert inventory["persistent_cli_state"] is True, inventory
    before = inventory["sha256"]
    open(os.path.join(home, "plugins", "cache", "catalog.json"), "w").write("[1]")
    assert m.codex_home_inventory(home)["sha256"] != before

# `codex features list` output → the effective state the manifest records.
features = m.parse_features(
    "plugins                     stable             false\n"
    "shell_tool                  stable             false\n"
    "web_search                  stable             true\n")
assert features == {"plugins": False, "shell_tool": False, "web_search": True}, features
PY
pass "hardening flags, home preflight and state inventory"

# 12. The pinned feature names must exist in the installed CLI. This is the
#     forward-compatibility gate: a renamed flag would otherwise silently stop
#     disabling anything. Deterministic and offline — `codex features list`
#     evaluates local configuration and bills nothing.
if command -v codex >/dev/null 2>&1; then
    python3 - "$ROOT" <<'PY' || fail "pinned features not known to the installed CLI"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location(
    "codex_gate", sys.argv[1] + "/tools/codex-gate/codex_gate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.MOCK = False
features, digest = m.effective_features(m.DEFAULT_DISABLED_FEATURES)
assert len(digest) == 64, digest
for feature in m.DEFAULT_DISABLED_FEATURES:
    assert feature in features, "installed CLI does not know " + feature
    assert features[feature] is False, feature
try:
    m.effective_features(("no_such_feature_xyz",))
except SystemExit as e:
    assert "rejected" in str(e), e
else:
    raise AssertionError("an unknown feature name was accepted silently")
PY
    pass "pinned feature names validate against the installed codex CLI"
else
    echo "skip: codex CLI not on PATH — pinned feature names not validated"
fi

# 13. /health carries the pinned profile, so a campaign manifest records the
#     configuration the trial actually ran under.
out="$(curl -sf "$BASE/health")"
echo "$out" | grep -q '"hardened": true' || fail "health: no hardening flag ($out)"
echo "$out" | grep -q '"disabled_features"' || fail "health: no feature list ($out)"
echo "$out" | grep -q '"shell_tool"' || fail "health: shell_tool not pinned ($out)"
echo "$out" | grep -q '"exec_flags"' || fail "health: no exec flags ($out)"
echo "$out" | grep -q '"adapter_instructions_sha256"' || fail "health: adapter contract unhashed ($out)"
echo "$out" | grep -q '"quota_recovery": true' || fail "health: quota recovery not advertised ($out)"
echo "$out" | grep -q '"session_stateless": true' || fail "health: session statelessness not explicit ($out)"
pass "health reports the pinned CLI profile"

# 14. grind.py's gateway preflight refuses an unpinned gateway.
python3 - "$ROOT" "$PORT" <<'PY' || fail "grind gateway preflight"
import importlib.util
import sys

root, port = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "grind", root + "/tests/agent-harness/grind.py")
grind = importlib.util.module_from_spec(spec); spec.loader.exec_module(grind)

url = "http://127.0.0.1:%s/v1" % port
# The mock backend is not codex-cli, so the escape-room requirement rejects it
# before anything else — that guard already existed and must keep working.
for requirements, expect in (
        ({"backend": "codex-cli"}, "backend"),
        ({"hardened": True, "backend": "mock"}, None),
        ({"quota_recovery": True, "backend": "mock"}, None),
        ({"idle_timeout_max": 300, "backend": "mock"}, None),
        ({"idle_timeout_max": 299, "backend": "mock"}, "idle timeout"),
        ({"disabled_features": ["plugins"], "backend": "mock"}, None),
        ({"disabled_features": ["no_such_feature"], "backend": "mock"}, "does not disable"),
        ({"codex_version": "codex-cli 9.9.9", "backend": "mock"}, "pins")):
    try:
        grind.gateway_preflight(url, "default", requirements)
    except RuntimeError as e:
        assert expect and expect in str(e), (requirements, e)
    else:
        assert expect is None, (requirements, "was accepted")
PY
pass "grind preflight rejects a gateway that is not pinned as required"

echo "=== codex-gate mock-mode tests: all green ==="

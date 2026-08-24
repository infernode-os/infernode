#!/usr/bin/env python3
# codex-gate — OpenAI-compatible /v1 gateway over the ChatGPT Codex CLI.
#
# Purpose: let InferNode's llmsrv (`-b openai -u http://127.0.0.1:11436/v1`)
# reach OpenAI's Codex models through the locally-authenticated `codex` CLI
# (ChatGPT subscription billing) instead of a raw API key.  Sibling of
# tools/claude-gate/ — same wire contract, same place in the stack:
#
#   llmsrv -b openai -u http://127.0.0.1:11436/v1
#      │  OpenAI chat-completions (HTTP, localhost only)
#      ▼
#   codex-gate  ──  codex exec --json  ──▶  ChatGPT login
#
# The hard part both gates solve is the tool-calling inversion: llmsrv wants
# a backend that RETURNS tool calls to the caller (nerva runs its own tool
# loop, with its own policy enforcement), while a CLI agent harness wants to
# run the loop itself.  claude-gate bridges it with a live in-process MCP
# server whose handler parks on a future.  The Codex CLI has no in-process
# MCP server, and `codex exec` cancels MCP tool calls non-interactively
# unless the sandbox is disabled wholesale — which is not a trade InferNode
# should make by default.  So this gate bridges at the *prompt* level:
#
#   1. Tool definitions from the request are rendered into the prompt.
#   2. `codex exec --output-schema` constrains the final agent message to
#      {"content": str, "tool_calls": [{"name", "arguments"}]}.
#   3. A non-empty tool_calls array becomes an OpenAI `tool_calls` response
#      with finish_reason=tool_calls; llmsrv turns it into the `TOOL:` lines
#      the agent already parses, and the agent executes them under its own
#      policy exactly as with Ollama.
#   4. llmsrv owns the transcript and sends it in full every call, so the
#      tool results come back as ordinary role=tool messages on the next
#      request and are replayed into a fresh `codex exec`.
#
# Consequence worth knowing: this gate is STATELESS.  There are no held
# turns to orphan (a restart mid-tool-loop costs nothing), but there is also
# no live CLI session across a tool round-trip — each request is one
# `codex exec`.  /health reports held_turns for surface parity with
# claude-gate; it is always 0.
#
# Endpoints (bind 127.0.0.1 only — no auth of its own):
#   POST /v1/chat/completions    (non-streaming + single-chunk SSE)
#   GET  /v1/models
#   GET  /health
#
# Config (env):
#   CODEX_GATE_HOST       default 127.0.0.1
#   CODEX_GATE_PORT       default 11436
#   CODEX_GATE_MOCK       "1" = deterministic mock backend (tests; no CLI)
#   CODEX_GATE_MOCK_ERROR non-empty = fail every mock turn with this message
#   CODEX_GATE_BIN        codex binary (default "codex", found on PATH)
#   CODEX_GATE_MODEL      default model; empty = let the CLI use its own
#   CODEX_GATE_MODELS     comma-separated list advertised on /v1/models
#   CODEX_GATE_TIMEOUT    seconds one `codex exec` may run (default 900)
#   CODEX_GATE_CONCURRENCY  max simultaneous codex processes (default 4)
#   CODEX_GATE_SANDBOX    --sandbox value (default read-only)
#   CODEX_GATE_WORKDIR    --cd value (default ~/.cache/codex-gate/workdir)
#   CODEX_GATE_CODEX_HOME CODEX_HOME for the child (isolates ~/.codex; you
#                         must copy auth.json in yourself if you set it)
#   CODEX_GATE_EXEC_ARGS  extra args appended to every `codex exec`
#   CODEX_GATE_PROMPT_ARGV  "1" = pass the prompt as argv, not on stdin
#   CODEX_GATE_DEBUG      verbose logging
#
# Billing guard: OPENAI_API_KEY in the environment can make the CLI bill the
# API instead of the ChatGPT plan.  serve-codex-gate.sh unsets it; we also
# refuse to start unless CODEX_GATE_ALLOW_API_KEY=1 explicitly overrides.

import asyncio
import json
import logging
import os
import shlex
import subprocess
import tempfile
import time
import uuid

from aiohttp import web

log = logging.getLogger("codex-gate")

HOST = os.environ.get("CODEX_GATE_HOST", "127.0.0.1")
PORT = int(os.environ.get("CODEX_GATE_PORT", "11436"))
MOCK = os.environ.get("CODEX_GATE_MOCK", "") == "1"
MOCK_ERROR = os.environ.get("CODEX_GATE_MOCK_ERROR", "")
CODEX_BIN = os.environ.get("CODEX_GATE_BIN", "codex")
DEFAULT_MODEL = os.environ.get("CODEX_GATE_MODEL", "")
EXEC_TIMEOUT = float(os.environ.get("CODEX_GATE_TIMEOUT", "900"))
CONCURRENCY = int(os.environ.get("CODEX_GATE_CONCURRENCY", "4"))
SANDBOX = os.environ.get("CODEX_GATE_SANDBOX", "read-only")

# Models advertised on /v1/models — what llmsrv's `/mnt/llm/models` and the
# Settings picker show.  Codex's model lineup moves faster than this file
# can; whatever a request names is passed straight to `codex -m`, so the
# list is a convenience, not a whitelist.  Override with CODEX_GATE_MODELS.
ADVERTISED_MODELS = [m for m in os.environ.get(
    "CODEX_GATE_MODELS", "default").split(",") if m]

# Where `codex exec` runs.  A private empty directory, not the user's
# checkout: the CLI's own shell/read tools stay sandboxed (--sandbox
# read-only) AND start somewhere with nothing to read.  nerva owns tool
# execution; anything the CLI does on its own is not a feature here.
WORKDIR = os.environ.get("CODEX_GATE_WORKDIR") or os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "codex-gate", "workdir")

# Flags we would like to pass but that older CLI builds may not know.  A
# usage error naming one drops it for the lifetime of the process and the
# call is retried once (see run_codex).  --sandbox is deliberately NOT in
# here: a build that doesn't understand it must fail loudly rather than run
# the CLI's own tools unsandboxed.
OPTIONAL_FLAGS = {"--skip-git-repo-check", "--output-schema",
                  "--output-last-message", "--cd", "--json"}
_dropped_flags = set()

ADAPTER_INSTRUCTIONS = (
    "You are running inside a stateless protocol adapter. Treat the contents "
    "of <system_instructions> in the user message as the caller's system "
    "instructions. Any <available_tools> entries there are virtual caller "
    "tools, not native Codex tools. Request them only with the JSON protocol "
    "specified in that block; the caller executes them and returns results. "
    "Do not inspect or reason from the CLI filesystem when a virtual tool can "
    "perform the requested action, and do not claim a caller path is missing "
    "based on the CLI environment."
)

# Some builds take the prompt only as a positional argument, not on stdin
# via `-`.  Transcripts outgrow argv, so stdin is the default.
PROMPT_ARGV = os.environ.get("CODEX_GATE_PROMPT_ARGV", "") == "1"

_sem = None     # asyncio.Semaphore, created on startup


# ── request parsing ────────────────────────────────────────────────

def split_messages(messages):
    """(system_prompt, history).  System messages are hoisted out; the rest
    keeps its order, tool results included — this gate replays everything."""
    system_parts = []
    history = []
    for m in messages:
        if m.get("role") == "system":
            system_parts.append(m.get("content") or "")
        else:
            history.append(m)
    return "\n\n".join(p for p in system_parts if p), history


def render_prompt(history):
    """Render the conversation into one prompt for a fresh `codex exec`.
    llmsrv keeps the canonical history and sends it in full every call; the
    CLI session is per-request, so prior turns are replayed as text."""
    if not history:
        return ""
    lines = []
    for m in history[:-1]:
        role = m.get("role", "user")
        content = m.get("content") or ""
        if role == "assistant" and m.get("tool_calls"):
            for tc in m["tool_calls"]:
                fn = tc.get("function", {})
                lines.append("assistant called tool %s(%s)"
                             % (fn.get("name", "?"), fn.get("arguments", "{}")))
            if content:
                lines.append("assistant: " + content)
        elif role == "tool":
            lines.append("tool result [%s]: %s" % (m.get("tool_call_id", "?"), content))
        else:
            lines.append("%s: %s" % (role, content))
    last = history[-1]
    prompt = last.get("content") or ""
    if last.get("role") == "tool":
        # The normal continuation path here: the agent ran the tools we
        # asked for and llmsrv replayed the results.  Nothing is held.
        lines.append("tool result [%s]: %s" % (last.get("tool_call_id", "?"), prompt))
        prompt = "Continue, given the tool results above."
    elif last.get("role") == "assistant":
        lines.append("assistant: " + prompt)
        prompt = "Continue."
    if lines:
        return ("<conversation_history>\n" + "\n".join(lines) +
                "\n</conversation_history>\n\n" + prompt)
    return prompt


# ── prompt-level tool protocol ─────────────────────────────────────

# `arguments` is a JSON *string* rather than an object: strict structured
# outputs cannot express "any object", and llmclient.b wants a string on
# the way back out anyway.
TOOL_SCHEMA = {
    "type": "object",
    "properties": {
        "content": {
            "type": "string",
            "description": "Your reply to the user. Empty when calling tools.",
        },
        "tool_calls": {
            "type": "array",
            "description": "Tools to run. Empty when replying to the user.",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "arguments": {
                        "type": "string",
                        "description": "Arguments as a JSON object, encoded as a string.",
                    },
                },
                "required": ["name", "arguments"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["content", "tool_calls"],
    "additionalProperties": False,
}


def tool_instructions(tooldefs):
    """The tool manifest + protocol, appended to the system instructions."""
    manifest = []
    for td in tooldefs:
        fn = td.get("function", {})
        manifest.append({
            "name": fn.get("name", "tool"),
            "description": fn.get("description", ""),
            "parameters": fn.get("parameters") or {"type": "object", "properties": {}},
        })
    return (
        "<available_tools>\n"
        + json.dumps(manifest, indent=2)
        + "\n</available_tools>\n\n"
        "The entries above are virtual caller tools. They are not native Codex\n"
        "tools and will not appear in your CLI runtime tool list. The caller\n"
        "executes them and returns their results on the next turn. When a listed\n"
        "tool can perform the requested action, you MUST request it using the\n"
        "JSON protocol below. Do not test its availability in the CLI environment.\n"
        "The caller's filesystem and services are different from the CLI's.\n\n"
        "Reply with a single JSON object and nothing else:\n"
        '  to call tools: {\"content\": \"\", \"tool_calls\": '
        '[{\"name\": \"<tool>\", \"arguments\": \"<json object as a string>\"}]}\n'
        '  to answer:     {\"content\": \"<your answer>\", \"tool_calls\": []}\n'
    )


def strip_fence(text):
    """Unwrap a ```/```json fence if the model added one anyway."""
    t = text.strip()
    if not t.startswith("```"):
        return t
    nl = t.find("\n")
    if nl < 0:
        return t
    body = t[nl + 1:]
    end = body.rfind("```")
    return (body[:end] if end >= 0 else body).strip()


def parse_tool_reply(text):
    """(content, [(name, args-dict), ...]).  A reply that isn't the agreed
    JSON object is treated as plain content — degraded, never fatal."""
    try:
        obj = json.loads(strip_fence(text))
    except Exception:
        return text, []
    if not isinstance(obj, dict):
        return text, []
    calls = []
    for tc in obj.get("tool_calls") or []:
        if not isinstance(tc, dict) or not tc.get("name"):
            continue
        raw = tc.get("arguments")
        if isinstance(raw, dict):
            args = raw
        else:
            try:
                args = json.loads(raw or "{}")
            except Exception:
                args = {}
            if not isinstance(args, dict):
                args = {}
        calls.append((tc["name"], args))
    content = obj.get("content")
    if not isinstance(content, str):
        content = ""
    if not calls and not content:
        return text, []
    return content, calls


# ── OpenAI response shaping ────────────────────────────────────────

def completion_body(model, text, tool_calls, finish_reason, usage_tokens):
    msg = {"role": "assistant", "content": text}
    if tool_calls:
        msg["tool_calls"] = tool_calls
    return {
        "id": "chatcmpl-" + uuid.uuid4().hex[:16],
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "message": msg,
            "finish_reason": finish_reason,
        }],
        "usage": {
            "prompt_tokens": 0,
            "completion_tokens": usage_tokens,
            "total_tokens": usage_tokens,
        },
    }


def toolcalls_json(calls):
    """calls: [(name, args-dict)] → OpenAI tool_calls.  `arguments` MUST be
    a JSON string — llmclient.b picks String."""
    out = []
    for i, (name, args) in enumerate(calls):
        out.append({
            "index": i,
            "id": "call_" + uuid.uuid4().hex[:16],
            "type": "function",
            "function": {
                "name": name,
                "arguments": json.dumps(args, separators=(",", ":")),
            },
        })
    return out


async def respond(request, model, text, calls, usage_tokens, stream):
    tcs = toolcalls_json(calls) if calls else None
    finish = "tool_calls" if tcs else "stop"
    body = completion_body(model, text, tcs, finish, usage_tokens)

    if not stream:
        return web.json_response(body)

    # Single-chunk SSE: llmclient's SSE parser accumulates deltas, so one
    # complete delta chunk + usage + [DONE] is valid and sufficient.
    resp = web.StreamResponse(headers={
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    })
    await resp.prepare(request)
    choice = body["choices"][0]
    delta = {"role": "assistant", "content": choice["message"]["content"]}
    if choice["message"].get("tool_calls"):
        delta["tool_calls"] = choice["message"]["tool_calls"]
    chunk = {
        "id": body["id"], "object": "chat.completion.chunk",
        "created": body["created"], "model": body["model"],
        "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
    }
    await resp.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
    fin = {
        "id": body["id"], "object": "chat.completion.chunk",
        "created": body["created"], "model": body["model"],
        "choices": [{"index": 0, "delta": {}, "finish_reason": choice["finish_reason"]}],
        "usage": body["usage"],
    }
    await resp.write(b"data: " + json.dumps(fin).encode() + b"\n\n")
    await resp.write(b"data: [DONE]\n\n")
    await resp.write_eof()
    return resp


# ── codex CLI backend ──────────────────────────────────────────────

class CodexError(Exception):
    pass


def child_env():
    env = dict(os.environ)
    env.pop("OPENAI_API_KEY", None)      # never bill the API by accident
    home = os.environ.get("CODEX_GATE_CODEX_HOME")
    if home:
        env["CODEX_HOME"] = home
    return env


def check_codex_auth():
    """Refuse readiness when the CLI cannot use a ChatGPT login."""
    if MOCK:
        return
    try:
        result = subprocess.run(
            [CODEX_BIN, "login", "status"], env=child_env(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=10, check=False)
    except FileNotFoundError:
        raise SystemExit("codex-gate: codex CLI not found (%s)" % CODEX_BIN)
    except subprocess.TimeoutExpired:
        raise SystemExit("codex-gate: timed out checking codex login status")
    status = (result.stdout + "\n" + result.stderr).strip()
    if result.returncode != 0:
        detail = status.splitlines()
        detail = detail[-1] if detail else "not logged in"
        raise SystemExit("codex-gate: codex login unavailable: %s" % detail)
    if "chatgpt" not in status.lower():
        raise SystemExit(
            "codex-gate: Codex is not logged in with ChatGPT; run `codex login` "
            "or explicitly allow API-key mode with CODEX_GATE_ALLOW_API_KEY=1")


def unknown_flag(stderr):
    """The flag a clap usage error is complaining about, if it's one of ours."""
    for flag in OPTIONAL_FLAGS - _dropped_flags:
        if ("unexpected argument '%s'" % flag) in stderr or \
           ("unexpected argument \"%s\"" % flag) in stderr or \
           ("unrecognized" in stderr and flag in stderr):
            return flag
    return None


def build_argv(model, schema_path, last_message_path, prompt):
    # Native CLI shell access competes with the virtual caller-tool protocol:
    # the model otherwise tries to read the gateway VM instead of requesting
    # Veltro's read tool. Keep it disabled even though the CLI sandbox is also
    # read-only; the gateway must return requested effects to the caller.
    argv = [CODEX_BIN, "exec", "--sandbox", SANDBOX,
            "--disable", "shell_tool", "--strict-config", "-c",
            "developer_instructions=" + json.dumps(ADAPTER_INSTRUCTIONS)]
    def add(flag, value=None):
        if flag in _dropped_flags:
            return
        if value is None and flag not in ("--json", "--skip-git-repo-check"):
            return                      # optional value absent — skip the flag
        argv.append(flag)
        if value is not None:
            argv.append(value)
    add("--json")
    add("--skip-git-repo-check")
    add("--cd", WORKDIR)
    add("--output-last-message", last_message_path)
    add("--output-schema", schema_path)
    # "default" is the stable model-picker entry. Codex model names evolve;
    # omitting -m lets the installed CLI choose its configured current model.
    if model and model != "default":
        argv += ["-m", model]
    argv += shlex.split(os.environ.get("CODEX_GATE_EXEC_ARGS", ""))
    argv.append(prompt if PROMPT_ARGV else "-")
    return argv


def parse_events(stdout):
    """(agent_text, usage_tokens, error).  Tolerates both `codex exec --json`
    event dialects: the current {"type": "item.completed", "item": {...}}
    stream and the older {"msg": {"type": ...}} one."""
    text_parts = []
    usage = 0
    error = None
    for line in stdout.splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        msg = ev.get("msg") if isinstance(ev.get("msg"), dict) else ev
        kind = msg.get("type") or ev.get("type") or ""
        if kind in ("item.completed", "item.updated"):
            item = msg.get("item") or {}
            if item.get("type") in ("agent_message", "assistant_message"):
                t = item.get("text") or item.get("message") or ""
                if t:
                    text_parts.append(t)
            continue
        if kind == "agent_message":
            t = msg.get("message") or msg.get("text") or ""
            if t:
                text_parts.append(t)
        elif kind in ("turn.completed", "token_count", "turn_complete"):
            u = msg.get("usage") or msg.get("info") or {}
            if isinstance(u, dict):
                usage = (int(u.get("input_tokens", 0) or 0) +
                         int(u.get("output_tokens", 0) or 0)) or usage
        elif kind in ("error", "turn.failed", "stream_error"):
            err = msg.get("error")
            if isinstance(err, dict):
                err = err.get("message")
            error = err or msg.get("message") or "codex reported an error"
    return "\n".join(text_parts), usage, error


async def run_codex(model, prompt, schema):
    """One `codex exec`.  Returns (final_text, usage_tokens)."""
    tmpdir = tempfile.mkdtemp(prefix="codex-gate-")
    schema_path = os.path.join(tmpdir, "schema.json")
    last_path = os.path.join(tmpdir, "last-message.txt")
    if schema is not None:
        with open(schema_path, "w") as f:
            json.dump(schema, f)
    else:
        schema_path = None

    # Each usage error names one unknown flag, so a CLI that rejects two of
    # them needs two retries.  Bounded by the number of droppable flags —
    # the loop only continues when an attempt actually dropped something.
    for _ in range(len(OPTIONAL_FLAGS) + 1):
        argv = build_argv(model, schema_path, last_path, prompt)
        log.debug("exec: %s", " ".join(argv))
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv, cwd=WORKDIR, env=child_env(),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE)
        except FileNotFoundError:
            raise CodexError("codex CLI not found (%s) — install it or set "
                             "CODEX_GATE_BIN" % CODEX_BIN)
        try:
            out, err = await asyncio.wait_for(
                proc.communicate(prompt.encode()), timeout=EXEC_TIMEOUT)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise CodexError("codex exec exceeded CODEX_GATE_TIMEOUT (%.0fs)"
                             % EXEC_TIMEOUT)

        stdout = out.decode("utf-8", "replace")
        stderr = err.decode("utf-8", "replace")
        if proc.returncode != 0:
            flag = unknown_flag(stderr)
            if flag:
                log.warning("codex CLI rejects %s — dropping it", flag)
                _dropped_flags.add(flag)
                if flag == "--output-schema":
                    schema_path = None
                continue
            _, _, event_err = parse_events(stdout)
            tail = stderr.strip().splitlines()[-1] if stderr.strip() else ""
            raise CodexError(event_err or tail or
                             "codex exec failed (rc=%d)" % proc.returncode)

        text, usage, event_err = parse_events(stdout)
        if event_err and not text:
            raise CodexError(event_err)
        # --output-last-message is the authoritative final message when the
        # CLI supports it; the event stream is the fallback.
        try:
            with open(last_path) as f:
                last = f.read()
            if last.strip():
                text = last
        except OSError:
            pass
        if not text.strip() and stderr.strip():
            raise CodexError(stderr.strip().splitlines()[-1])
        return text, usage
    raise CodexError("codex exec failed")


async def codex_turn(model, system_prompt, prompt, tooldefs):
    """(content, [(name, args)], usage_tokens)."""
    full = prompt
    instructions = system_prompt
    if tooldefs:
        instructions = (instructions + "\n\n" if instructions else "") + \
            tool_instructions(tooldefs)
    if instructions:
        full = ("<system_instructions>\n" + instructions +
                "\n</system_instructions>\n\n" + prompt)

    async with _sem:
        text, usage = await run_codex(model, full, TOOL_SCHEMA if tooldefs else None)

    if tooldefs:
        content, calls = parse_tool_reply(text)
        return content, calls, usage
    return text, [], usage


# ── mock backend (CODEX_GATE_MOCK=1) ───────────────────────────────

async def mock_turn(model, system_prompt, prompt, tooldefs, trailing_tools):
    """Deterministic stand-in mirroring claude-gate's mock, adapted to this
    gate's stateless shape: tool results arrive in the request, not on a
    held turn.  `MOCK_TOOL_CALL <name> <json>` triggers one tool call."""
    if MOCK_ERROR:
        raise CodexError(MOCK_ERROR)
    if trailing_tools:
        content = trailing_tools[-1].get("content") or ""
        suffix = " (is_error)" if is_error_result(content) else ""
        return "TOOL_RESULT_WAS: %s%s" % (content, suffix), [], 7
    if tooldefs and "MOCK_TOOL_CALL" in prompt:
        parts = prompt.split("MOCK_TOOL_CALL", 1)[1].strip().split(" ", 1)
        name = parts[0]
        try:
            args = json.loads(parts[1]) if len(parts) > 1 else {}
        except Exception:
            args = {}
        return "", [(name, args)], 3
    return "MOCK_REPLY: " + prompt[-200:], [], 5


def is_error_result(content):
    return content.startswith("Error:") or content.startswith("error:")


# ── HTTP handlers ──────────────────────────────────────────────────

async def chat_completions(request):
    try:
        body = await request.json()
    except Exception:
        return web.json_response(
            {"error": {"message": "invalid JSON body"}}, status=400)

    messages = body.get("messages") or []
    tooldefs = body.get("tools") or []
    stream = bool(body.get("stream"))
    model = body.get("model") or DEFAULT_MODEL

    system_prompt, history = split_messages(messages)
    prompt = render_prompt(history)
    if not prompt:
        return web.json_response(
            {"error": {"message": "no user content in messages"}}, status=400)

    try:
        if MOCK:
            trailing = [m for m in history if m.get("role") == "tool"]
            content, calls, usage = await mock_turn(
                model, system_prompt, prompt, tooldefs, trailing)
        else:
            content, calls, usage = await codex_turn(
                model, system_prompt, prompt, tooldefs)
    except CodexError as e:
        log.error("turn failed: %s", e)
        return web.json_response(
            {"error": {"message": "codex-gate: %s" % e, "type": "gate_error"}},
            status=502)
    except Exception as e:                              # noqa: BLE001
        log.exception("turn failed")
        return web.json_response(
            {"error": {"message": "codex-gate: %s" % e, "type": "gate_error"}},
            status=502)

    return await respond(request, model, content, calls, usage, stream)


async def models(request):
    data = [{"id": m, "object": "model", "owned_by": "openai"}
            for m in ADVERTISED_MODELS]
    return web.json_response({"object": "list", "data": data})


async def health(request):
    return web.json_response({
        "status": "ok",
        "backend": "mock" if MOCK else "codex-cli",
        # No live CLI session spans a tool round-trip here (see the module
        # comment); the key stays for parity with claude-gate's /health.
        "held_turns": 0,
        "stateless": True,
    })


def main():
    logging.basicConfig(
        level=logging.DEBUG if os.environ.get("CODEX_GATE_DEBUG") else logging.INFO,
        format="codex-gate: %(levelname)s %(message)s")

    if os.environ.get("OPENAI_API_KEY") and not MOCK \
            and os.environ.get("CODEX_GATE_ALLOW_API_KEY") != "1":
        raise SystemExit(
            "codex-gate: OPENAI_API_KEY is set — the CLI may bill the API "
            "instead of your ChatGPT plan. Unset it (serve-codex-gate.sh "
            "does) or set CODEX_GATE_ALLOW_API_KEY=1 to override.")

    allow_api_key = os.environ.get("OPENAI_API_KEY") and \
        os.environ.get("CODEX_GATE_ALLOW_API_KEY") == "1"
    if not allow_api_key:
        check_codex_auth()

    if not MOCK:
        try:
            os.makedirs(WORKDIR, exist_ok=True)
        except OSError as e:
            raise SystemExit("codex-gate: cannot create workdir %s: %s"
                             % (WORKDIR, e))

    app = web.Application()
    app.router.add_post("/v1/chat/completions", chat_completions)
    app.router.add_get("/v1/models", models)
    app.router.add_get("/health", health)

    async def make_sem(app):
        global _sem
        _sem = asyncio.Semaphore(CONCURRENCY)
    app.on_startup.append(make_sem)

    log.info("listening on http://%s:%d/v1 (%s backend)",
             HOST, PORT, "mock" if MOCK else "codex-cli")
    web.run_app(app, host=HOST, port=PORT, print=None)


if __name__ == "__main__":
    main()

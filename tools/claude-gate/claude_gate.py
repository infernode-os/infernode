#!/usr/bin/env python3
# claude-gate — OpenAI-compatible /v1 gateway over the Claude Agent SDK.
#
# Purpose: let InferNode's llmsrv (`-b openai -u http://127.0.0.1:11435/v1`)
# reach Anthropic models through the locally-authenticated Claude Code CLI
# (subscription / Agent-SDK-credit billing) instead of a raw API key.
#
# The hard part this daemon solves is the tool-calling inversion: llmsrv
# expects a Messages-shaped backend that RETURNS tool calls to the caller
# (nerva runs its own tool loop, with its own policy enforcement), while the
# Agent SDK wants to run the loop itself.  Bridge: every tool def in the
# request is registered as an in-process SDK MCP tool whose handler parks on
# a future ("hanging handler").  When Claude calls it, the pending HTTP
# request is answered with an OpenAI `tool_calls` response and the SDK query
# stays alive, blocked inside the handler.  The next HTTP request carries
# the tool results (role=tool messages); they resolve the futures and the
# query continues to the final text.
#
# Endpoints (bind 127.0.0.1 only — no auth of its own):
#   POST /v1/chat/completions    (non-streaming + single-chunk SSE)
#   GET  /v1/models
#   GET  /health
#
# Config (env):
#   CLAUDE_GATE_HOST          default 127.0.0.1
#   CLAUDE_GATE_PORT          default 11435
#   CLAUDE_GATE_MOCK          "1" = deterministic mock backend (tests; no CLI)
#   CLAUDE_GATE_HOLD_TIMEOUT  seconds a turn may sit waiting for tool results
#                             before it is reaped (default 1800 — nerva's
#                             human-on-the-loop authorization can be slow)
#   CLAUDE_GATE_MODEL         default model when the request names none
#
# Billing guard: if ANTHROPIC_API_KEY is set, the CLI silently prefers it
# over subscription auth.  serve-claude-gate.sh unsets it; we also refuse to
# start unless CLAUDE_GATE_ALLOW_API_KEY=1 explicitly overrides.

import asyncio
import dataclasses
import json
import logging
import os
import time
import uuid

from aiohttp import web

log = logging.getLogger("claude-gate")

HOST = os.environ.get("CLAUDE_GATE_HOST", "127.0.0.1")
PORT = int(os.environ.get("CLAUDE_GATE_PORT", "11435"))
MOCK = os.environ.get("CLAUDE_GATE_MOCK", "") == "1"
HOLD_TIMEOUT = float(os.environ.get("CLAUDE_GATE_HOLD_TIMEOUT", "1800"))
DEFAULT_MODEL = os.environ.get("CLAUDE_GATE_MODEL", "sonnet")

# Models advertised on /v1/models — the CLI accepts these aliases directly,
# and llmsrv/Settings surface them in the model picker via /mnt/llm/models.
ADVERTISED_MODELS = ["sonnet", "opus", "haiku"]

# Claude Code built-in tools that must never run under the gate: nerva owns
# tool execution and policy.  Belt (tools=[] where the SDK supports it) and
# braces (explicit disallow list for older SDKs).
BUILTIN_TOOLS = [
    "Bash", "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Glob",
    "Grep", "WebFetch", "WebSearch", "Task", "TodoWrite", "KillShell",
    "BashOutput", "ExitPlanMode",
]


# ── turn state ─────────────────────────────────────────────────────

class Rendezvous:
    """Meeting point between an SDK tool handler and the tool result that
    arrives on a later HTTP request.  Either side may arrive first."""

    def __init__(self):
        self.future = asyncio.get_event_loop().create_future()

    def resolve(self, content: str, is_error: bool):
        if not self.future.done():
            self.future.set_result((content, is_error))

    async def wait(self):
        return await self.future


class Turn:
    """One in-flight generation: an SDK query (or mock task) plus the queue
    of events the currently-waiting HTTP request consumes."""

    def __init__(self, model: str):
        self.id = "turn-" + uuid.uuid4().hex[:12]
        self.model = model
        self.events = asyncio.Queue()      # ("tool_calls", [...] ) | ("final", text, usage) | ("error", msg)
        self.text_acc = ""                 # assistant text since the last emit
        self.rendezvous = {}               # argkey -> [Rendezvous FIFO]
        self.id_to_argkey = {}             # tool_use id -> argkey
        self.task = None                   # backend driver task
        self.last_activity = time.monotonic()

    def touch(self):
        self.last_activity = time.monotonic()

    @staticmethod
    def argkey(name: str, args) -> str:
        return name + "\x00" + json.dumps(args, sort_keys=True, separators=(",", ":"))

    def handler_rendezvous(self, name: str, args) -> Rendezvous:
        """Called from inside an SDK tool handler: park until the result
        for this (name, args) call arrives."""
        rv = Rendezvous()
        self.rendezvous.setdefault(self.argkey(name, args), []).append(rv)
        return rv

    def register_tool_use(self, tool_use_id: str, name: str, args):
        self.id_to_argkey[tool_use_id] = self.argkey(name, args)

    def deliver_result(self, tool_use_id: str, content: str, is_error: bool) -> bool:
        key = self.id_to_argkey.get(tool_use_id)
        if key is None:
            return False
        fifo = self.rendezvous.get(key)
        if not fifo:
            # Handler hasn't fired yet — pre-resolve by creating the slot.
            rv = Rendezvous()
            rv.resolve(content, is_error)
            self.rendezvous.setdefault(key, []).append(rv)
            return True
        fifo[0].resolve(content, is_error)
        # Consumed entries are popped by the handler side after wait().
        return True

    def pop_rendezvous(self, name: str, args):
        key = self.argkey(name, args)
        fifo = self.rendezvous.get(key)
        if fifo:
            return fifo.pop(0)
        rv = Rendezvous()
        self.rendezvous.setdefault(key, []).append(rv)
        return rv

    def cancel(self):
        if self.task is not None and not self.task.done():
            self.task.cancel()


class TurnTable:
    """Held turns, addressable by tool_call id for continuation requests."""

    def __init__(self):
        self.by_toolcall = {}   # tool_use id -> Turn
        self.turns = set()

    def hold(self, turn: Turn, tool_use_ids):
        self.turns.add(turn)
        for tid in tool_use_ids:
            self.by_toolcall[tid] = turn

    def find(self, tool_use_id: str):
        return self.by_toolcall.get(tool_use_id)

    def drop(self, turn: Turn):
        self.turns.discard(turn)
        for tid in [t for t, v in self.by_toolcall.items() if v is turn]:
            del self.by_toolcall[tid]

    async def reap_stale(self):
        while True:
            await asyncio.sleep(60)
            now = time.monotonic()
            for turn in list(self.turns):
                if now - turn.last_activity > HOLD_TIMEOUT:
                    log.warning("reaping stale turn %s (idle %.0fs)",
                                turn.id, now - turn.last_activity)
                    turn.cancel()
                    self.drop(turn)


TURNS = TurnTable()


# ── request parsing ────────────────────────────────────────────────

def split_messages(messages):
    """(system_prompt, history, trailing_tool_results).  History keeps the
    original dicts; trailing tool-role messages are the continuation
    payload when a turn is held."""
    system_parts = []
    history = []
    for m in messages:
        if m.get("role") == "system":
            system_parts.append(m.get("content") or "")
        else:
            history.append(m)
    trailing_tools = []
    while history and history[-1].get("role") == "tool":
        trailing_tools.insert(0, history.pop())
    return "\n\n".join(p for p in system_parts if p), history, trailing_tools


def render_transcript(history):
    """Render prior turns into a prompt for a fresh SDK query.  llmsrv keeps
    the canonical history and sends it in full every call; the SDK session
    is per-turn, so earlier turns are replayed as text."""
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
        # Recovery path: gate restarted mid-loop; replay results as text.
        lines.append("tool result [%s]: %s" % (last.get("tool_call_id", "?"), prompt))
        prompt = "Continue, given the tool results above."
    if lines:
        return ("<conversation_history>\n" + "\n".join(lines) +
                "\n</conversation_history>\n\n" + prompt)
    return prompt


def map_model(model: str) -> str:
    if not model:
        return DEFAULT_MODEL
    return model


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


def toolcalls_json(tool_uses):
    """tool_uses: list of (id, name, args-dict) → OpenAI tool_calls.
    `arguments` MUST be a JSON string — llmclient.b picks String."""
    out = []
    for i, (tid, name, args) in enumerate(tool_uses):
        out.append({
            "index": i,
            "id": tid,
            "type": "function",
            "function": {
                "name": name,
                "arguments": json.dumps(args, separators=(",", ":")),
            },
        })
    return out


async def respond_event(request, turn, event, stream):
    """Translate a turn event into the HTTP response for this request."""
    kind = event[0]
    if kind == "error":
        TURNS.drop(turn)
        return web.json_response(
            {"error": {"message": event[1], "type": "gate_error"}}, status=502)

    if kind == "tool_calls":
        tool_uses = event[1]
        tcs = toolcalls_json(tool_uses)
        text = event[2]
        body = completion_body(turn.model, text, tcs, "tool_calls", event[3])
        TURNS.hold(turn, [t[0] for t in tool_uses])
        turn.touch()
    else:  # final
        body = completion_body(turn.model, event[1], None, "stop", event[2])
        TURNS.drop(turn)

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


# ── SDK backend ────────────────────────────────────────────────────

if not MOCK:
    from claude_agent_sdk import (  # noqa: E402
        AssistantMessage, ClaudeAgentOptions, ResultMessage, TextBlock,
        ToolUseBlock, create_sdk_mcp_server, query, tool,
    )

    _OPT_FIELDS = {f.name for f in dataclasses.fields(ClaudeAgentOptions)}

    def make_options(**kw):
        dropped = [k for k in kw if k not in _OPT_FIELDS]
        if dropped:
            log.debug("ClaudeAgentOptions: dropping unsupported %s", dropped)
        return ClaudeAgentOptions(**{k: v for k, v in kw.items() if k in _OPT_FIELDS})

    def build_mcp_tools(turn, tooldefs):
        handlers = []
        for td in tooldefs:
            fn = td.get("function", {})
            name = fn.get("name", "tool")
            desc = fn.get("description", "")
            schema = fn.get("parameters") or {"type": "object", "properties": {}}

            def make_handler(tool_name):
                async def handler(args):
                    rv = turn.pop_rendezvous(tool_name, args)
                    turn.touch()
                    content, is_error = await rv.wait()
                    turn.touch()
                    out = {"content": [{"type": "text", "text": content}]}
                    if is_error:
                        out["is_error"] = True
                    return out
                return handler

            handlers.append(tool(name, desc, schema)(make_handler(name)))
        return handlers

    async def sdk_turn(turn, system_prompt, prompt, tooldefs):
        try:
            mcp_servers = {}
            allowed = []
            if tooldefs:
                server = create_sdk_mcp_server(
                    name="nerva", version="1.0.0",
                    tools=build_mcp_tools(turn, tooldefs))
                mcp_servers["nerva"] = server
                allowed = ["mcp__nerva__" + td.get("function", {}).get("name", "")
                           for td in tooldefs]

            options = make_options(
                model=map_model(turn.model),
                system_prompt=system_prompt or None,
                mcp_servers=mcp_servers,
                allowed_tools=allowed,
                disallowed_tools=list(BUILTIN_TOOLS),
                tools=[],                        # dropped if SDK predates it
                permission_mode="bypassPermissions",
                setting_sources=[],              # never load host CLAUDE.md etc.
                strict_mcp_config=True,          # ignore host MCP configs
                max_turns=100,
                env={"MCP_TOOL_TIMEOUT": str(int(HOLD_TIMEOUT * 1000))},
            )

            usage_tokens = 0
            async for message in query(prompt=prompt, options=options):
                if isinstance(message, AssistantMessage):
                    tool_uses = []
                    for block in message.content:
                        if isinstance(block, TextBlock):
                            turn.text_acc += block.text
                        elif isinstance(block, ToolUseBlock):
                            # The SDK reports MCP tools as mcp__nerva__<name>;
                            # nerva dispatches on the bare name, and the
                            # handler's rendezvous key uses it too.
                            name = block.name
                            if name.startswith("mcp__nerva__"):
                                name = name[len("mcp__nerva__"):]
                            turn.register_tool_use(block.id, name, block.input)
                            tool_uses.append((block.id, name, block.input))
                    if tool_uses:
                        text, turn.text_acc = turn.text_acc, ""
                        await turn.events.put(("tool_calls", tool_uses, text, usage_tokens))
                elif isinstance(message, ResultMessage):
                    u = getattr(message, "usage", None) or {}
                    usage_tokens = int(u.get("input_tokens", 0)) + int(u.get("output_tokens", 0))
                    text = turn.text_acc or (getattr(message, "result", None) or "")
                    if getattr(message, "is_error", False) and not text:
                        await turn.events.put(("error", "claude-gate: SDK error result"))
                        return
                    await turn.events.put(("final", text, usage_tokens))
                    return
            await turn.events.put(("final", turn.text_acc, usage_tokens))
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.exception("sdk turn %s failed", turn.id)
            await turn.events.put(("error", "claude-gate: %s" % e))


# ── mock backend (CLAUDE_GATE_MOCK=1) ──────────────────────────────

async def mock_turn(turn, system_prompt, prompt, tooldefs):
    """Deterministic stand-in: `MOCK_TOOL_CALL <name> <json>` in the prompt
    triggers one tool round-trip; otherwise echoes."""
    try:
        if tooldefs and "MOCK_TOOL_CALL" in prompt:
            parts = prompt.split("MOCK_TOOL_CALL", 1)[1].strip().split(" ", 1)
            name = parts[0]
            args = json.loads(parts[1]) if len(parts) > 1 else {}
            tid = "toolu_mock_" + uuid.uuid4().hex[:8]
            turn.register_tool_use(tid, name, args)
            rv = turn.pop_rendezvous(name, args)
            await turn.events.put(("tool_calls", [(tid, name, args)], "", 0))
            content, is_error = await rv.wait()
            suffix = " (is_error)" if is_error else ""
            await turn.events.put(("final", "TOOL_RESULT_WAS: %s%s" % (content, suffix), 7))
        else:
            await turn.events.put(("final", "MOCK_REPLY: " + prompt[-200:], 5))
    except asyncio.CancelledError:
        raise
    except Exception as e:
        await turn.events.put(("error", "mock: %s" % e))


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

    system_prompt, history, trailing_tools = split_messages(messages)

    # Continuation: trailing tool-role messages matching a held turn.
    if trailing_tools:
        turn = None
        for tm in trailing_tools:
            turn = TURNS.find(tm.get("tool_call_id", ""))
            if turn is not None:
                break
        if turn is not None:
            turn.touch()
            for tm in trailing_tools:
                content = tm.get("content") or ""
                is_error = content.startswith("Error:") or content.startswith("error:")
                turn.deliver_result(tm.get("tool_call_id", ""), content, is_error)
            event = await turn.events.get()
            return await respond_event(request, turn, event, stream)
        log.warning("tool results with no held turn — replaying as fresh query")
        history = history + trailing_tools

    # Fresh turn.
    turn = Turn(model)
    prompt = render_transcript(history)
    if not prompt:
        return web.json_response(
            {"error": {"message": "no user content in messages"}}, status=400)

    driver = mock_turn if MOCK else sdk_turn
    turn.task = asyncio.create_task(driver(turn, system_prompt, prompt, tooldefs))
    event = await turn.events.get()
    return await respond_event(request, turn, event, stream)


async def models(request):
    data = [{"id": m, "object": "model", "owned_by": "anthropic"}
            for m in ADVERTISED_MODELS]
    return web.json_response({"object": "list", "data": data})


async def health(request):
    return web.json_response({
        "status": "ok",
        "backend": "mock" if MOCK else "claude-agent-sdk",
        "held_turns": len(TURNS.turns),
    })


def main():
    logging.basicConfig(
        level=logging.DEBUG if os.environ.get("CLAUDE_GATE_DEBUG") else logging.INFO,
        format="claude-gate: %(levelname)s %(message)s")

    if os.environ.get("ANTHROPIC_API_KEY") and not MOCK \
            and os.environ.get("CLAUDE_GATE_ALLOW_API_KEY") != "1":
        raise SystemExit(
            "claude-gate: ANTHROPIC_API_KEY is set — the CLI would bill the "
            "API instead of your subscription. Unset it (serve-claude-gate.sh "
            "does) or set CLAUDE_GATE_ALLOW_API_KEY=1 to override.")

    app = web.Application()
    app.router.add_post("/v1/chat/completions", chat_completions)
    app.router.add_get("/v1/models", models)
    app.router.add_get("/health", health)

    async def start_reaper(app):
        app["reaper"] = asyncio.create_task(TURNS.reap_stale())
    app.on_startup.append(start_reaper)

    log.info("listening on http://%s:%d/v1 (%s backend)",
             HOST, PORT, "mock" if MOCK else "claude-agent-sdk")
    web.run_app(app, host=HOST, port=PORT, print=None)


if __name__ == "__main__":
    main()

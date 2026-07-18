# claude-gate — Anthropic models via the Claude Code CLI (subscription billing)

`tools/claude-gate/` is a host-side daemon that lets the whole InferNode LLM
stack — llmsrv, lucifer, and agents built on `/mnt/llm` — use Anthropic
models through the locally-authenticated **Claude Code CLI** instead of a
raw API key. On the wire it is an OpenAI-compatible endpoint on localhost,
so from InferNode's side it is just another `-b openai` backend:

```
agent ──/mnt/msg──▶ (agent loop stays in the agent)
   │
   ▼ /mnt/llm
llmsrv -b openai -u http://127.0.0.1:11435/v1
   │  OpenAI chat-completions (HTTP, localhost only)
   ▼
claude-gate (tools/claude-gate/claude_gate.py, aiohttp)
   │  Claude Agent SDK  (claude-agent-sdk, spawns the claude CLI)
   ▼
claude CLI ── subscription login / CLAUDE_CODE_OAUTH_TOKEN ──▶ Anthropic
```

**Daemon model in one paragraph:** one gate per host, listening on
`127.0.0.1:11435`, no authentication of its own (the localhost boundary is
the trust boundary; remote consumers go through llmsrv's authenticated 9P
export, never by exposing this port). Each incoming chat-completions request
becomes a Claude Agent SDK query, which drives the host's `claude` CLI under
the host's own login. The daemon is stateless between conversations except
for **held turns** — tool-calling turns kept alive while InferNode executes
the tools (see below).

## Why a gateway (and not a new llmclient backend)

The CLI/Agent SDK is an agent harness, not a Messages endpoint: it wants to
run the tool loop itself and execute tools via MCP. InferNode's agents
require the opposite — the agent owns the loop, the tool policy, and
human-on-the-loop authorization. The gate bridges the inversion with a
**hanging tool handler**:

1. Every OpenAI `tools` entry in a request is registered as an in-process
   SDK MCP tool.
2. When Claude calls one, the handler does *not* execute anything — the gate
   answers the pending HTTP request with an ordinary OpenAI `tool_calls`
   response and parks the handler on a future. The SDK query stays alive.
3. llmsrv turns that into the `TOOL:` lines the agent already parses; the
   agent executes the tools through its own policy layer exactly as with
   Ollama.
4. The next HTTP request carries the `role=tool` results; they resolve the
   futures (matched by `tool_call_id`) and the query runs on to final text.

Correlation is unambiguous because llmsrv sessions are strictly sequential.
Held turns survive long waits (validated ≥90s; `CLAUDE_GATE_HOLD_TIMEOUT`,
default 1800s, bounds them — generous because tool authorization can park a
call on a human).

## HTTP API

All endpoints bind `127.0.0.1` only.

| Endpoint | Method | Purpose |
|---|---|---|
| `/v1/chat/completions` | POST | OpenAI chat completions. Accepts `messages`, `tools` (OpenAI function format), `model`, `stream`. Returns `choices[0].message.content` / `.tool_calls` (`arguments` is a JSON string), `finish_reason` `stop`/`tool_calls`, `usage.total_tokens`. `stream:true` yields single-chunk SSE ending in `data: [DONE]`. |
| `/v1/models` | GET | Advertised model aliases (`sonnet`, `opus`, `haiku`) — what llmsrv's `/mnt/llm/models` and the Settings picker show. Full `claude-*` ids are also accepted on requests. |
| `/health` | GET | Liveness + gauges. |

`/health` response:

```json
{"status": "ok", "backend": "claude-agent-sdk", "held_turns": 0}
```

- `status` — always `"ok"` if the daemon is serving.
- `backend` — `"claude-agent-sdk"` normally; `"mock"` when started with
  `CLAUDE_GATE_MOCK=1` (deterministic test backend, no CLI, no billing).
- `held_turns` — number of tool-calling turns currently parked waiting for
  results. Nonzero while an agent is mid-tool-loop is normal; a value that
  never drains suggests an orphaned turn (self-reaped after
  `CLAUDE_GATE_HOLD_TIMEOUT`, default 30 min).

## Lifecycle & startup

**InferNode does not start the gate.** emu never manages host daemons; the
gate must already be listening when llmsrv dials it. If it isn't, asks fail
with a connection error and the Veltro greeting reports "The Claude CLI
gateway is configured, but I can't reach it." Three ways to run it:

1. **Manual (any host)** — `tools/claude-gate/serve-claude-gate.sh` runs it
   in the foreground (first run bootstraps a private venv). Good for dev.
2. **Linux, systemd (recommended on servers)** — install the unit once, then
   `llmctl set claude` starts it on demand (and points ndb at it):
   ```sh
   mkdir -p ~/.config/systemd/user
   cp tools/claude-gate/claude-gate.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   llmctl set claude
   systemctl --user enable claude-gate    # optional: autostart at login
   ```
3. **macOS, launchd (autostart at login)** — install the LaunchAgent:
   ```sh
   cp tools/claude-gate/com.nervsystems.claude-gate.plist ~/Library/LaunchAgents/
   # edit the checkout path inside the plist if yours differs, then:
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nervsystems.claude-gate.plist
   ```
   Logs land in `/tmp/claude-gate.log`. Remove with
   `launchctl bootout gui/$(id -u)/com.nervsystems.claude-gate`.

Config (env, read at start): `CLAUDE_GATE_HOST` / `CLAUDE_GATE_PORT`
(default `127.0.0.1:11435`), `CLAUDE_GATE_MODEL` (default `sonnet`),
`CLAUDE_GATE_HOLD_TIMEOUT` (seconds, default 1800), `CLAUDE_GATE_MOCK`,
`CLAUDE_GATE_DEBUG`.

## Setup (pointing InferNode at it)

```sh
claude login                      # once — or export CLAUDE_CODE_OAUTH_TOKEN
tools/claude-gate/serve-claude-gate.sh   # or systemd/launchd per above
```

Then either set it from **Settings → LLM → Backend → "Claude CLI"** (writes
`backend=cli` + `url=http://127.0.0.1:11435/v1` to `/lib/ndb/llm`), or edit
`~/.infernode/lib/ndb/llm` directly and restart llmsrv. Plain
`backend=openai` with the same URL also works (useful when older checkouts
share the ndb).

Headless auth for systemd/launchd: `claude setup-token` on any machine,
then put `CLAUDE_CODE_OAUTH_TOKEN=...` in `~/.config/claude-gate/env`
(mode 600).

On Linux with the `/llm` synthfs mounted (llmctl9p), the Settings "Claude
CLI" Apply hands off to `llmctl set claude` automatically; `llmctl set
ollama|sglang` switches back (restoring `backend=openai`), and
`llmctl status` / `llmctl health claude` report on it.

## Billing — read this once

Headless CLI / Agent SDK usage does **not** draw from the interactive
subscription pool. Since 2026-06-15 it consumes the plan's monthly **Agent
SDK credit** (Max 5x: $100/mo, Max 20x: $200/mo) metered at standard API
token rates, with overage billed beyond it. Fine for interactive traffic;
do the math before fleet-scale experiments. All consumers of one gate share
one credit pool and one auth identity.

**ANTHROPIC_API_KEY silently outranks subscription auth in the CLI.** The
serve script unsets it, and the gate refuses to start if it leaks through
(`CLAUDE_GATE_ALLOW_API_KEY=1` overrides deliberately).

## ndb / config reference

| key | value | meaning |
|---|---|---|
| `backend=` | `cli` | CLI gateway. Boot profiles launch `llmsrv -b openai` for it (`lib/lucifer/boot.sh`, `lib/sh/profile`, `lib/sh/serve-profile` match `openai cli`). |
| `url=` | `http://127.0.0.1:11435/v1` | Override port via `CLAUDE_GATE_PORT` (gate) + `CLAUDE_GATE_URL` (llmctl). |
| `model=` | `sonnet` \| `opus` \| `haiku` | Aliases pass straight to the CLI; full `claude-*` ids also work. |

## Limitations / notes

- **Per-turn transcript replay.** llmsrv owns conversation history and sends
  it in full each call; the gate replays prior turns as text into a fresh
  SDK query (the within-turn tool loop stays live — no replay there).
  Cross-call CLI session reuse (`--resume` + prefix hashing) is a possible
  future optimization, not correctness-relevant.
- **`temperature`/`max_tokens` are accepted and ignored** — current Anthropic
  models don't take sampling params, and the CLI owns generation limits.
- The gate strips the SDK's `mcp__nerva__` prefix from tool names so the
  agent's dispatcher sees the bare names it registered.
- Claude Code's built-in tools (Bash/Read/Write/…) are disabled
  (`tools=[]` + explicit disallow list); host settings, CLAUDE.md files, and
  host MCP configs are never loaded (`setting_sources=[]`,
  `strict_mcp_config`).
- A gate restart mid-tool-loop orphans held turns; the next request with
  stale tool results falls back to a fresh query with the results replayed
  as text (degraded but non-fatal; the agent's loop recovers).

## Tests

```sh
./tests/host/claude_gate_test.sh    # mock-mode: OpenAI surface + tool bridge
./tests/host/llmctl_test.sh         # llmctl incl. set claude / backend=cli
```

Live end-to-end (needs a logged-in CLI; bills the Agent SDK credit): start
the gate, then inside emu `llmsrv -b openai -u http://127.0.0.1:11435/v1`
and ask through `/mnt/llm`.

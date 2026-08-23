# codex-gate — OpenAI models via the ChatGPT Codex CLI (subscription billing)

`tools/codex-gate/` is a host-side daemon that lets the whole InferNode LLM
stack — llmsrv, lucifer, and agents built on `/mnt/llm` — use OpenAI models
through the locally-authenticated **Codex CLI** instead of a raw API key. On
the wire it is an OpenAI-compatible endpoint on localhost, so from
InferNode's side it is just another `-b openai` backend:

```
agent ──/mnt/msg──▶ (agent loop stays in the agent)
   │
   ▼ /mnt/llm
llmsrv -b openai -u http://127.0.0.1:11436/v1
   │  OpenAI chat-completions (HTTP, localhost only)
   ▼
codex-gate (tools/codex-gate/codex_gate.py, aiohttp)
   │  one `codex exec --json` per request
   ▼
codex CLI ── `codex login` (ChatGPT sign-in) ──▶ OpenAI
```

It is the sibling of [claude-gate](CLAUDE-GATE.md) and occupies exactly the
same slot in the stack: one gate per host, listening on `127.0.0.1:11436`,
no authentication of its own (the localhost boundary is the trust boundary;
remote consumers go through llmsrv's authenticated 9P export, never by
exposing this port).

## Why a gateway (and not a new llmclient backend)

Same reason as claude-gate: the CLI is an agent harness, not a Messages
endpoint. It wants to run the tool loop itself; InferNode's agents require
the opposite — the agent owns the loop, the tool policy, and
human-on-the-loop authorization.

## How the tool bridge differs from claude-gate

claude-gate registers each requested tool as an in-process SDK MCP tool
whose handler parks on a future, so one CLI session stays live across a tool
round-trip ("held turns"). The Codex CLI offers no in-process MCP server,
and `codex exec` cancels MCP tool calls non-interactively unless approvals
*and* the sandbox are disabled wholesale — not a trade a default install
should make. So this gate bridges at the **prompt** level:

1. The request's tool definitions are rendered into the prompt as an
   `<available_tools>` manifest.
2. `codex exec --output-schema` constrains the final agent message to
   `{"content": str, "tool_calls": [{"name", "arguments"}]}`.
3. A non-empty `tool_calls` array becomes an ordinary OpenAI `tool_calls`
   response with `finish_reason: tool_calls`. llmsrv turns that into the
   `TOOL:` lines the agent already parses, and the agent executes the tools
   through its own policy layer exactly as with Ollama.
4. llmsrv owns the transcript and re-sends it in full, so the results arrive
   as `role=tool` messages on the next request and are replayed into a fresh
   `codex exec`.

**The gate is therefore stateless.** There are no held turns to orphan (a
restart mid-tool-loop costs nothing) and no `CODEX_GATE_HOLD_TIMEOUT`; the
price is that no CLI session spans a tool round-trip — each request is one
`codex exec` with the transcript replayed. `/health` still reports
`held_turns` for surface parity with claude-gate; it is always 0.

A reply that isn't the agreed JSON object is treated as plain content rather
than an error — degraded, never fatal.

## HTTP API

All endpoints bind `127.0.0.1` only.

| Endpoint | Method | Purpose |
|---|---|---|
| `/v1/chat/completions` | POST | OpenAI chat completions. Accepts `messages`, `tools` (OpenAI function format), `model`, `stream`. Returns `choices[0].message.content` / `.tool_calls` (`arguments` is a JSON string), `finish_reason` `stop`/`tool_calls`, `usage.total_tokens`. `stream:true` yields single-chunk SSE ending in `data: [DONE]`. |
| `/v1/models` | GET | Advertised model ids — what llmsrv's `/mnt/llm/models` and the Settings picker show. Set with `CODEX_GATE_MODELS`; whatever a request names is passed straight to `codex -m`, so the list is a convenience, not a whitelist. |
| `/health` | GET | Liveness + gauges. |

`/health` response:

```json
{"status": "ok", "backend": "codex-cli", "held_turns": 0, "stateless": true}
```

- `status` — always `"ok"` if the daemon is serving.
- `backend` — `"codex-cli"` normally; `"mock"` when started with
  `CODEX_GATE_MOCK=1` (deterministic test backend, no CLI, no billing).
- `held_turns` — always 0 here (see above); present so monitoring can treat
  both gates alike.

## Lifecycle & startup

**InferNode does not start the gate.** emu never manages host daemons; the
gate must already be listening when llmsrv dials it. If it isn't, asks fail
with a connection error and the Veltro greeting reports "The Codex CLI
gateway is configured, but I can't reach it." Three ways to run it:

1. **Manual (any host)** — `tools/codex-gate/serve-codex-gate.sh` runs it in
   the foreground (first run bootstraps a private venv). Good for dev.
2. **Linux, systemd (recommended on servers)** — install the unit once, then
   `llmctl set codex` starts it on demand (and points ndb at it):
   ```sh
   mkdir -p ~/.config/systemd/user
   cp tools/codex-gate/codex-gate.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   llmctl set codex
   systemctl --user enable codex-gate     # optional: autostart at login
   ```
3. **macOS, launchd (autostart at login)** — install the LaunchAgent:
   ```sh
   cp tools/codex-gate/com.nervsystems.codex-gate.plist ~/Library/LaunchAgents/
   # edit the checkout path inside the plist if yours differs, then:
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nervsystems.codex-gate.plist
   ```
   Logs land in `/tmp/codex-gate.log`. Remove with
   `launchctl bootout gui/$(id -u)/com.nervsystems.codex-gate`.

Config (env, read at start):

| var | default | meaning |
|---|---|---|
| `CODEX_GATE_HOST` / `CODEX_GATE_PORT` | `127.0.0.1:11436` | listen address |
| `CODEX_GATE_BIN` | `codex` | the CLI binary |
| `CODEX_GATE_MODEL` | *(empty)* | model when the request names none; empty = let the CLI use its own configured default (no `-m` passed) |
| `CODEX_GATE_MODELS` | `gpt-5-codex,gpt-5-codex-mini` | advertised on `/v1/models` |
| `CODEX_GATE_TIMEOUT` | `900` | seconds one `codex exec` may run |
| `CODEX_GATE_CONCURRENCY` | `4` | max simultaneous codex processes |
| `CODEX_GATE_SANDBOX` | `read-only` | `--sandbox` value |
| `CODEX_GATE_WORKDIR` | `~/.cache/codex-gate/workdir` | `--cd` value |
| `CODEX_GATE_CODEX_HOME` | *(unset)* | `CODEX_HOME` for the child, to isolate `~/.codex` (you must copy `auth.json` in yourself) |
| `CODEX_GATE_EXEC_ARGS` | *(empty)* | extra args appended to every `codex exec` |
| `CODEX_GATE_PROMPT_ARGV` | *(unset)* | `1` = pass the prompt as argv instead of stdin |
| `CODEX_GATE_MOCK`, `CODEX_GATE_DEBUG` | — | test backend, verbose logs |

## Setup (pointing InferNode at it)

```sh
codex login                            # once — ChatGPT sign-in
tools/codex-gate/serve-codex-gate.sh   # or systemd/launchd per above
```

On a fresh install the first-run wizard offers **Codex CLI** directly, so a
user on a subscription never has to reach for an API key. Otherwise set
it from **Settings → LLM → Backend → "Codex CLI"** (writes
`backend=codex` + `url=http://127.0.0.1:11436/v1` to `/lib/ndb/llm`), or
edit `~/.infernode/lib/ndb/llm` directly and restart llmsrv. Plain
`backend=openai` with the same URL also works (useful when older checkouts
share the ndb).

On Linux with the `/llm` synthfs mounted (llmctl9p), the Settings "Codex
CLI" Apply hands off to `llmctl set codex` automatically; `llmctl set
ollama|sglang|claude` switches away, and `llmctl status` / `llmctl health
codex` report on it.

## Billing — read this once

Headless CLI usage draws on the account the CLI is logged into. On a ChatGPT
plan that means the plan's Codex usage allowance; when it is exhausted the
CLI's own behaviour (rate-limit or overage) is what you get — the gate does
not meter. All consumers of one gate share one allowance and one auth
identity.

**OPENAI_API_KEY can silently outrank ChatGPT auth in the CLI**, billing the
API instead of the plan. The serve script unsets it, and the gate refuses to
start if it leaks through (`CODEX_GATE_ALLOW_API_KEY=1` overrides
deliberately).

## ndb / config reference

| key | value | meaning |
|---|---|---|
| `backend=` | `codex` | Codex CLI gateway. Boot profiles launch `llmsrv -b openai` for it (`lib/lucifer/boot.sh`, `lib/sh/profile`, `lib/sh/serve-profile` match `openai cli codex`). |
| `url=` | `http://127.0.0.1:11436/v1` | Override port via `CODEX_GATE_PORT` (gate) + `CODEX_GATE_URL` (llmctl). |
| `model=` | e.g. `gpt-5-codex` | Passed straight to `codex -m`; leave empty to use the CLI's configured default. |

## Limitations / notes

- **Per-request transcript replay.** llmsrv owns conversation history and
  sends it in full each call; the gate replays it as text into a fresh
  `codex exec`. Unlike claude-gate there is no live session even within a
  tool loop. `codex exec resume` + prefix hashing is a possible future
  optimization, not correctness-relevant.
- **`temperature`/`max_tokens` are accepted and ignored** — the CLI owns
  generation limits.
- **The CLI's own tools cannot be disabled**, only sandboxed. `codex exec`
  runs with `--sandbox read-only` (override with `CODEX_GATE_SANDBOX`) and
  `--cd` pointed at a private empty directory, so its shell/read tools start
  somewhere with nothing to read and cannot write. The prompt also tells the
  model to ask for a tool rather than work around one. This is a weaker
  fence than claude-gate's explicit disallow list — if that matters for your
  deployment, run the gate as a user with nothing to read.
- **Global CLI instructions still load.** A `~/.codex/AGENTS.md` (or config
  in `~/.codex/config.toml`) applies to gate traffic too. Set
  `CODEX_GATE_CODEX_HOME` to a directory holding only `auth.json` to isolate
  it.
- **Flag compatibility.** `--json`, `--skip-git-repo-check`, `--cd`,
  `--output-last-message` and `--output-schema` are dropped automatically if
  the installed CLI rejects them (the call is retried without). `--sandbox`
  is deliberately *not* auto-dropped: a build that doesn't understand it
  fails loudly rather than running the CLI's tools unsandboxed. The gate
  also parses both `codex exec --json` event dialects (the current
  `item.completed` stream and the older `msg`-wrapped one).

## Tests

```sh
./tests/host/codex_gate_test.sh     # mock-mode: OpenAI surface + tool bridge
./tests/host/llmctl_test.sh         # llmctl incl. set codex / backend=codex
```

Live end-to-end (needs a logged-in CLI; uses your plan's allowance): start
the gate, then inside emu `llmsrv -b openai -u http://127.0.0.1:11436/v1`
and ask through `/mnt/llm`.

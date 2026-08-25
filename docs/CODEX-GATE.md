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
2. A fixed Codex developer instruction identifies that manifest as a virtual
   caller-tool protocol, and `--disable shell_tool` prevents the CLI's native
   shell from competing with it. The model must request effects from Veltro,
   not inspect the gateway host.
3. `codex exec --output-schema` constrains the final agent message to
   `{"content": str, "tool_calls": [{"name", "arguments"}]}`.
4. A non-empty `tool_calls` array becomes an ordinary OpenAI `tool_calls`
   response with `finish_reason: tool_calls`. llmsrv turns that into the
   `TOOL:` lines the agent already parses, and the agent executes the tools
   through its own policy layer exactly as with Ollama.
5. llmsrv owns the transcript and re-sends it in full, so the results arrive
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
{"status": "ok", "backend": "codex-cli", "held_turns": 0, "stateless": true,
 "hardened": true, "codex_version": "codex-cli 0.149.0",
 "sandbox": "read-only", "exec_flags": ["--sandbox", "read-only", "..."],
 "disabled_features": ["plugins", "..."], "features_sha256": "…",
 "adapter_instructions_sha256": "…",
 "codex_home_baseline": {"files": 1, "bytes": 4156, "sha256": "…"}}
```

- `status` — `"ok"` if the daemon is serving. Non-mock startup first runs
  `codex login status`, so missing or API-key authentication cannot masquerade
  as ChatGPT OAuth readiness. The explicit `CODEX_GATE_ALLOW_API_KEY=1`
  override bypasses this subscription check.
- `backend` — `"codex-cli"` normally; `"mock"` when started with
  `CODEX_GATE_MOCK=1` (deterministic test backend, no CLI, no billing).
- `held_turns` — always 0 here (see above); present so monitoring can treat
  both gates alike.
- `hardened`, `codex_version`, `exec_flags`, `disabled_features`,
  `features_sha256`, `adapter_instructions_sha256`, `codex_home_baseline` —
  the pinned CLI surface (see below). `grind.py` copies these into a
  campaign's `manifest.json` and a scenario file can require them, so a
  containment result names the gateway configuration it was measured under.

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
| `CODEX_GATE_MODELS` | `default` | advertised on `/v1/models`; `default` omits `codex -m` so the CLI chooses its configured current model |
| `CODEX_GATE_TIMEOUT` | `900` | seconds one `codex exec` may run |
| `CODEX_GATE_CONCURRENCY` | `4` | max simultaneous codex processes |
| `CODEX_GATE_SANDBOX` | `read-only` | `--sandbox` value |
| `CODEX_GATE_WORKDIR` | `~/.cache/codex-gate/workdir` | `--cd` value |
| `CODEX_GATE_CODEX_HOME` | *(unset)* | `CODEX_HOME` for the child, to isolate `~/.codex` (you must copy `auth.json` in yourself) |
| `CODEX_GATE_EXEC_ARGS` | *(empty)* | extra args appended to every `codex exec` |
| `CODEX_GATE_PROMPT_ARGV` | *(unset)* | `1` = pass the prompt as argv instead of stdin |
| `CODEX_GATE_HARDEN` | `1` | pin the CLI feature surface (see below); `0` disables the pinning but never the adapter's own `--disable shell_tool` |
| `CODEX_GATE_DISABLE_FEATURES` | *(unset)* | comma list replacing the pinned disable set |
| `CODEX_GATE_HOME_ALLOW` | `auth.json,auth.json.lock,version.json,installation_id` | what the isolated Codex home may contain at startup |
| `CODEX_GATE_MOCK`, `CODEX_GATE_DEBUG` | — | test backend, verbose logs |

## Pinned CLI surface

The Codex CLI is an agent harness with a life of its own. During the
escape-room campaign it populated a fresh 0700 `CODEX_HOME` — created with
nothing in it but `auth.json` — with 144 plugin-cache files (~26 MiB,
including the remote curated catalog), 60 system-skill files and a shell
snapshot. Nothing escaped: the CLI ran `--sandbox read-only`, with its native
shell disabled, in an empty working directory, on a machine with no access to
the system under test. But the model was carrying tools and instructions that
no run record named, and the next run would carry different ones.

So the gate pins the surface rather than inheriting it (INFR-413). Every
`codex exec` gets:

- `--ephemeral`, so no session files are written;
- `--ignore-user-config`, so no `config.toml` is loaded;
- `--ignore-rules`, so no user or project execpolicy `.rules` file is loaded;
- `--disable` for plugins (and plugin sharing, remote plugins, the recommended
  catalog), apps and their MCP surface, skill search and the skill dependency
  installer, memories, shell snapshots, hooks, the CLI's own multi-agent mode,
  and the browser/computer/image surfaces a protocol adapter has no use for.

None of these are auto-dropped on a usage error, for the same reason
`--sandbox` is not: a build that does not understand one must fail loudly
instead of quietly running without it. At startup the gate asks
`codex features list` for the effective state under exactly those flags, which
both validates every pinned name against the installed build and produces the
hash reported on `/health`.

If `CODEX_GATE_CODEX_HOME` is set, the gate inventories it **before**
authenticating through it and refuses to serve when it holds anything outside
the allowlist — a `config.toml`, an `AGENTS.md`, an `mcp.json`, a `plugins/`
or `skills/` directory — or when the directory itself is group- or
world-accessible. The check runs once at startup because the CLI fills the
directory in itself as soon as the first request arrives.

After a campaign, account for what it created:

```sh
tools/codex-gate/serve-codex-gate.sh --inventory    # or: --inventory PATH
```

That prints every file under the Codex home with its size, mode and SHA-256,
plus one digest over the whole listing, so two campaigns can be compared by a
single value.

## Setup (pointing InferNode at it)

```sh
codex login                            # once — ChatGPT sign-in
tools/codex-gate/serve-codex-gate.sh   # or systemd/launchd per above
```

On Linux, Codex's read-only sandbox requires Bubblewrap and permission to
create unprivileged user namespaces. Install the distribution's `bubblewrap`
package and verify a native tool call before starting InferNode:

```sh
codex exec --sandbox read-only --skip-git-repo-check \
  'Use the shell tool to run pwd, then report its output.'
```

Do not continue if this reports `Failed RTM_NEWADDR`, a user-namespace error,
or a sandbox fallback. Ubuntu 24.04 may set
`kernel.apparmor_restrict_unprivileged_userns=1`; use an appropriate AppArmor
profile, or change that setting only inside a dedicated gateway VM. Do not
disable the Codex sandbox to make the check pass. See the current
[Codex sandbox prerequisites](https://developers.openai.com/codex/concepts/sandboxing#prerequisites).

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
| `model=` | e.g. a model supported by the installed CLI | Passed straight to `codex -m`; leave empty or use `default` to use the CLI's configured default. `llmctl set codex` clears stale model ids when switching backends. |

## Limitations / notes

- **Per-request transcript replay.** llmsrv owns conversation history and
  sends it in full each call; the gate replays it as text into a fresh
  `codex exec`. Unlike claude-gate there is no live session even within a
  tool loop. `codex exec resume` + prefix hashing is a possible future
  optimization, not correctness-relevant.
- **`temperature`/`max_tokens` are accepted and ignored** — the CLI owns
  generation limits.
- **The CLI's native shell is disabled.** The gate enforces
  `--disable shell_tool`, a fixed `developer_instructions` adapter contract,
  `--sandbox read-only`, and `--cd` to a private empty directory. The first two
  make caller tools functional; the latter two remain defense in depth. Run
  the gate as a dedicated user with nothing else to read.
- **Global CLI instructions do not load.** `--ignore-user-config` and
  `--ignore-rules` keep `config.toml`, execpolicy `.rules` and the
  configuration-borne instruction sources out. `AGENTS.md` files are read from
  the working directory, which is a private empty one. Set
  `CODEX_GATE_CODEX_HOME` to a directory holding only `auth.json` as well, and
  the gate will hold it to that.
- **Flag compatibility.** `--json`, `--skip-git-repo-check`, `--cd`,
  `--output-last-message` and `--output-schema` are dropped automatically if
  the installed CLI rejects them (the call is retried without). `--sandbox`
  `--disable`, `--strict-config`, `--ephemeral`, `--ignore-user-config`,
  `--ignore-rules` and `developer_instructions` are deliberately *not*
  auto-dropped: a build that doesn't understand the adapter's security
  contract fails loudly. The gate also parses both
  `codex exec --json` event dialects (the current
  `item.completed` stream and the older `msg`-wrapped one).

## Tests

```sh
./tests/host/codex_gate_test.sh     # mock-mode: OpenAI surface, tool bridge,
                                    # pinned CLI surface, Codex-home preflight
./tests/host/llmctl_test.sh         # llmctl incl. set codex / backend=codex
```

`codex_gate_test.sh` bills nothing. When a `codex` CLI is on `PATH` it also
checks every pinned feature name against that build — `codex features list`
evaluates local configuration only — so a renamed flag is caught before a
campaign runs with the feature quietly back on. Without a CLI that one check
is skipped and the rest still runs.

Live end-to-end (needs a logged-in CLI; uses your plan's allowance): start
the gate, then inside emu `llmsrv -b openai -u http://127.0.0.1:11436/v1`
and ask through `/mnt/llm`.
